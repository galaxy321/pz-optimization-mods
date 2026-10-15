--
-- Chunk Load Sieve (performance patch).
--
-- LoadGridsquare fires for every square of every chunk that loads, thousands of times a second
-- while driving. Several mods hook it only to look for one kind of thing: a generator, a gas
-- pump, a container, an object with mod data. Each hook costs its own walk over the square, on
-- every square, even though almost none of them hold what it is looking for.
--
-- This file wraps Events.LoadGridsquare.Add. When a handler from one of the files listed in RULES
-- registers, it is NOT attached to the event. Instead one shared handler looks at each square
-- once and calls a captured handler only when the square has what that handler needs. Each gate
-- below is a superset of the condition under which the original handler does anything, so a
-- handler that is skipped would have returned without effect (exceptions are noted per rule).
--
-- Handlers from files not listed pass straight through to the real event, unchanged.
--
-- The file name starts with "!!!_" so it sorts after "!!!LuaEventProfiler.lua" (if installed)
-- and before every listed mod's files.
--
-- 1.1: the per-square path is written for Kahlua, where every Java call and every Lua function
-- call is expensive: one pass over the objects, sprite names looked up once per sprite and
-- cached, handlers grouped by fact so a square with nothing of interest runs no handler loop at
-- all, and TABAS gated on its own registry instead of running on every square.
--
-- 1.2: ChunkLoadSieve.watch(test, onSquare) lets another patch ask for squares holding a sprite
-- of its choice (test(sprite, name) -> true), answered from the same object pass and sprite cache
-- at no extra cost per square. Hitch Fix uses it to find the Tuna racks.
--

if ChunkLoadSieve then return end
ChunkLoadSieve = {}
local S = ChunkLoadSieve

local ENABLED = true      -- false: capture nothing, every mod behaves as if this patch were absent
local STATS_SECONDS = 120 -- print how many squares each captured handler was called for; 0 = never

-- Sprite names from the mods' own sources.
local KIND_BY_NAME = {
	-- GasPumpIndicator.lua, PUMP_POS
	location_shop_fossoil_01_12 = "pump", location_shop_fossoil_01_13 = "pump",
	location_shop_fossoil_01_14 = "pump", location_shop_fossoil_01_15 = "pump",
	location_shop_gas2go_01_12 = "pump", location_shop_gas2go_01_13 = "pump",
	location_shop_gas2go_01_14 = "pump", location_shop_gas2go_01_15 = "pump",
	-- OnanCore.lua, O.PART_SPRITES
	onan_genset_01_0 = "onanPart", onan_genset_01_3 = "onanPart",
	-- LGEPCore.lua, EP.GHOST_SPRITE
	LGEP_ghost = "ghostName",
}

-- Facts a gate may ask about a square:
--   generator   square:getGenerator() ~= nil
--   special     the square has special objects (doors, windows, generators...)
--   vehicle     a vehicle stands on the square
--   worldItems  items lying on the ground
--   modData     an object has mod data
--   container   an object has at least one container
--   pump / onanPart / ghostName   an object's sprite is one of KIND_BY_NAME
--   tabas       the square is in Take A Bath And Shower's tub registry
local RULES = {
	-- OnanServer.lua:164 - returns at once unless there is a generator, or an object whose sprite
	-- is an engine half (O.partOrientation).
	{ file = "OnanGenSet/OnanServer.lua", need = { "generator", "onanPart" } },
	-- OnanSound.lua:152 - only a generator.
	{ file = "OnanGenSet/OnanSound.lua", need = { "generator" } },
	-- GasPumpIndicator.lua:222 - only objects with a PUMP_POS sprite.
	{ file = "GasPumpIndicator.lua", need = { "pump" } },
	-- LGEPClient.lua:149 - hide() returns unless EP.isGhost: the ghost key in mod data, or the
	-- ghost sprite, or (isGhost's own rule) an object with no sprite name.
	{ file = "LGExtendedPlumbing/LGEPClient.lua", need = { "modData", "ghostName" } },
	-- LGEEGrid.lua:697 - files a generator, and when FuelLine is on looks for an object with mod
	-- data. Its per-chunk option cache refreshes on the next square that does pass.
	{ file = "LGExtendedElectricity/LGEEGrid.lua", need = { "generator", "modData" } },
	-- LGEEAgree.lua:160 - multiplayer clients only, and only a generator.
	{ file = "LGExtendedElectricity/LGEEAgree.lua", need = { "generator" } },
	-- PZM_Puker_Decals.lua:300 - puke is always placed together with an expiry in the floor's mod
	-- data (line ~251), and a floor without mod data has no expiry to clear. Not covered: puke
	-- with no saved expiry at all, which the mod repairs as a "defensive migration" path.
	{ file = "PZM_Puker_Decals.lua", need = { "modData" } },
	-- vfx_agingmanager.lua:1123 - skips squares with no ground items and no containers. A stale
	-- queue entry for a skipped square is rejected by its own queue check (line ~1227).
	{ file = "vfx_agingmanager.lua", need = { "worldItems", "container" } },
	-- vfx_storydistribution.lua:197 - only containers inside a building.
	{ file = "vfx_storydistribution.lua", need = { "container" } },
	-- vfx_birthday_world.lua:136 and vfx_birthday.lua:332 - only ground items.
	{ file = "vfx_birthday_world.lua", need = { "worldItems" } },
	{ file = "vfx_birthday.lua", need = { "worldItems" } },
	-- qolc_reasonable_alarms.lua:155 - doors and windows (special objects), or a vehicle.
	{ file = "qolc_reasonable_alarms.lua", need = { "special", "vehicle" } },
	-- TABAS_STubFluidContainerSystem.lua:356 - returns unless TFC_Utils.hasTfcData(square), which is
	-- GetTFCSystemData().Registered["x-y-z"].
	{ file = "TABAS_STubFluidContainerSystem.lua", need = { "tabas" } },
}

local Events = Events
local event = Events and Events.LoadGridsquare
if not ENABLED or type(event) ~= "table" or type(event.Add) ~= "function" then return end

local realAdd, realRemove = event.Add, event.Remove

local captured = {}   -- list of { fn, rule, path, calls, faulted, stamp }
local byFn = {}       -- original fn -> entry
local lists = {}      -- fact -> list of entries that need it

-- Which facts to compute; refreshed whenever a handler is captured or removed.
local wGenerator, wSpecial, wVehicle, wWorldItems = false, false, false, false
local wModData, wContainer, wNames, wTabas = false, false, false, false
local wWatch = false

-- watch(): { test, onSquare, stamp }, see the 1.2 note at the top.
local watchers = {}

local function fileOf(fn)
	-- A handler wrapped by the Lua Event Profiler carries its original in originalOf.
	local P = LuaEventProfiler
	local orig = P and P.originalOf and P.originalOf[fn]
	local ok, name = pcall(getFilenameOfClosure, orig or fn)
	if ok and name then return (string.gsub(tostring(name), "\\", "/")) end
	return nil
end

local function ruleFor(path)
	if not path then return nil end
	for _, rule in ipairs(RULES) do
		local f = rule.file
		if #path >= #f and string.sub(path, -#f) == f then return rule end
	end
	return nil
end

local function rebuild()
	lists = {}
	for _, e in ipairs(captured) do
		for _, fact in ipairs(e.rule.need) do
			local l = lists[fact]
			if not l then l = {}; lists[fact] = l end
			l[#l + 1] = e
		end
	end
	wGenerator = lists.generator ~= nil
	wSpecial = lists.special ~= nil
	wVehicle = lists.vehicle ~= nil
	wWorldItems = lists.worldItems ~= nil
	wModData = lists.modData ~= nil
	wContainer = lists.container ~= nil
	wNames = lists.pump ~= nil or lists.onanPart ~= nil or lists.ghostName ~= nil
	wTabas = lists.tabas ~= nil
end

-- Sprite -> kind string, or false. Sprites are shared by every tile of the same type, so after
-- the first few chunks this is one table lookup per object instead of a getName() call.
local kindOfSprite = {}

local function classify(spr)
	local name = spr:getName()
	local kind = (name and KIND_BY_NAME[name]) or false
	if not kind and name and LGEP and name == LGEP.GHOST_SPRITE then kind = "ghostName" end
	if not kind then
		for i = 1, #watchers do
			local w = watchers[i]
			local ok, hit = pcall(w.test, spr, name)
			if ok and hit then kind = w break end
		end
	end
	kindOfSprite[spr] = kind
	return kind
end

-- Take A Bath And Shower's tub registry, keyed "x-y-z". Mirrored as a set of x values so most
-- squares need one getX() to rule out; the registry itself is read for the exact answer.
local tabasXs = {}
local tabasAny = false
local tabasOk = true

local function refreshTabas()
	if not wTabas then return end
	if type(GetTFCSystemData) ~= "function" then tabasOk = false return end
	local ok, gData = pcall(GetTFCSystemData)
	local reg = ok and gData and gData.Registered
	local xs, any = {}, false
	if type(reg) == "table" then
		for id in pairs(reg) do
			local x = tonumber(string.match(tostring(id), "^([^%-]+)%-"))
			if x then xs[x] = true; any = true else tabasOk = false end
		end
	end
	tabasXs, tabasAny = xs, any
end

local function fault(e, err)
	if e.faulted then return end
	e.faulted = true
	print("[ChunkLoadSieve] ERROR in captured handler " .. tostring(e.path) .. ": " .. tostring(err))
end

local squares = 0

-- Calls every handler listening on `fact` that has not run for this square yet.
local function fire(fact, square)
	local l = lists[fact]
	for i = 1, #l do
		local e = l[i]
		if e.stamp ~= squares then
			e.stamp = squares
			e.calls = e.calls + 1
			local ok, err = pcall(e.fn, square)
			if not ok then fault(e, err) end
		end
	end
end

local function dispatch(square)
	if not square then return end
	squares = squares + 1

	if wGenerator or wSpecial then
		local sp = square:getSpecialObjects()
		if sp and sp:size() > 0 then
			-- getGenerator() looks only in this list, so an empty list means no generator.
			if wGenerator and square:getGenerator() then fire("generator", square) end
			if wSpecial then fire("special", square) end
		end
	end

	if wVehicle and square:getVehicleContainer() then fire("vehicle", square) end

	if wWorldItems then
		local w = square:getWorldObjects()
		if w and w:size() > 0 then fire("worldItems", square) end
	end

	if wModData or wContainer or wNames or wWatch then
		local md, cont, pump, onan, ghost = false, false, false, false, false
		local objects = square:getObjects()
		for i = 0, objects:size() - 1 do
			local o = objects:get(i)
			if wNames or wWatch then
				local spr = o:getSprite()
				if spr then
					local kind = kindOfSprite[spr]
					if kind == nil then kind = classify(spr) end
					if kind then
						if kind == "pump" then pump = true
						elseif kind == "onanPart" then onan = true
						elseif kind == "ghostName" then ghost = true
						elseif kind.stamp ~= squares then
							kind.stamp = squares
							local ok, err = pcall(kind.onSquare, square)
							if not ok and not kind.faulted then
								kind.faulted = true
								print("[ChunkLoadSieve] ERROR in a watch: " .. tostring(err))
							end
						end
					end
				else
					ghost = true -- EP.isGhost treats an object with no sprite name as a candidate
				end
			end
			if wModData and not md and o:hasModData() then md = true end
			if wContainer and not cont and o:getContainerCount() > 0 then cont = true end
		end
		if md then fire("modData", square) end
		if cont and lists.container then fire("container", square) end
		if pump and lists.pump then fire("pump", square) end
		if onan and lists.onanPart then fire("onanPart", square) end
		if ghost and lists.ghostName then fire("ghostName", square) end
	end

	if wTabas then
		if not tabasOk then
			fire("tabas", square)
		elseif tabasAny then
			local x = square:getX()
			if tabasXs[x] then fire("tabas", square) end
		end
	end
end

event.Add = function(fn)
	if type(fn) == "function" and not byFn[fn] then
		local path = fileOf(fn)
		local rule = ruleFor(path)
		if rule then
			local e = { fn = fn, rule = rule, path = path, calls = 0, stamp = -1 }
			captured[#captured + 1] = e
			byFn[fn] = e
			rebuild()
			refreshTabas()
			print("[ChunkLoadSieve] captured " .. rule.file)
			return
		end
	end
	return realAdd(fn)
end

if type(realRemove) == "function" then
	event.Remove = function(fn)
		local e = byFn[fn]
		if e then
			byFn[fn] = nil
			for i = #captured, 1, -1 do
				if captured[i] == e then table.remove(captured, i) end
			end
			rebuild()
			return
		end
		return realRemove(fn)
	end
end

realAdd(dispatch)

local ticks = 0
local lastStats = nil
local function onTick()
	ticks = ticks + 1
	-- A tub is registered by a player standing next to it, so its chunk is already loaded; the
	-- set only has to catch up before that chunk loads again.
	if ticks % 30 == 0 then refreshTabas() end

	if STATS_SECONDS <= 0 then return end
	local t = getTimestampMs()
	if not lastStats then lastStats = t return end
	if t - lastStats < STATS_SECONDS * 1000 then return end
	lastStats = t
	print(string.format("[ChunkLoadSieve] %d squares in the last %d s; calls per captured handler:", squares, STATS_SECONDS))
	for _, e in ipairs(captured) do
		print(string.format("[ChunkLoadSieve]   %8d  %s", e.calls, e.rule.file))
		e.calls = 0
	end
	squares = 0
	for _, e in ipairs(captured) do e.stamp = -1 end
end

local function onStart()
	local names = {}
	for _, e in ipairs(captured) do names[#names + 1] = e.rule.file end
	print("[ChunkLoadSieve] active (1.2), " .. #captured .. " handlers captured: " .. table.concat(names, ", "))
	refreshTabas()
end

Events.OnGameStart.Add(onStart)
Events.OnTick.Add(onTick)

S.captured = captured
S.refreshTabas = refreshTabas

-- Calls onSquare(square) for each loading square that holds an object whose sprite passes
-- test(sprite, name). Each sprite is tested once; register before the world loads.
function S.watch(test, onSquare)
	watchers[#watchers + 1] = { test = test, onSquare = onSquare, stamp = -1 }
	kindOfSprite = {}
	wWatch = true
end
