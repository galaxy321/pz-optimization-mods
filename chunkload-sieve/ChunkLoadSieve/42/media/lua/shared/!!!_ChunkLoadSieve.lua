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
-- and before the listed mods' files in the same folder. Build 42 loads each mod's shared files in
-- mod-list order, so for targets in another mod's shared folder (LG Extended Electricity, RC
-- Structure Framework, Vanilla Foods Expanded) this mod must sit above that mod in the list; a
-- miss is named at start (SHARED_TARGETS below).
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
-- 1.3: damnlib's forced vehicle spawns (DAMN_Spawns.lua) are gated on its own list of spawn
-- points, the same way as the TABAS tubs. Fitted Barricades' two handlers and Fitted Sheets'
-- one are gated too: on special objects (their own first check), or for Fitted Barricades'
-- server one on isServer() (it returns at once in singleplayer).
--
-- 1.4: LG Extended Electricity, two parts (see the LGEE section below).
--   * A generator nobody has plugged in is not filed when its square loads. LGEE files every
--     generator it sees, and each new one makes it forget its plans for the whole grid and
--     start its current pass again, even for a machine in a field 2 km from the base. Such a
--     generator can't power anything, and plugging it in or starting it files it at that moment
--     (LGEEHook.lua), so nothing is lost but its early entry in the list.
--   * A chunk that loads, or an object removed, far from every generator and relay LGEE knows
--     does not ask it for a sweep. Every other part of those handlers still runs, and its own
--     25-second maintenance pass still comes round. A request with a reason is never dropped.
--
-- 1.5: LGEE's saved generator list is trimmed as the save loads, before LGEE reads it: entries
-- that were off, not wired to a building, not tripped, not plumbed and not a solar bank are
-- removed. The list never forgets a generator it once saw, so it held every world generator ever
-- driven past. The saved rows don't say whether a generator was connected, so a connected one
-- that was off goes too; LGEE files it again when its square loads or it is started.
--
-- 1.6: LG Extended Plumbing's per-square scan (LGEPPlumbing.lua) runs from a 2 ms tick budget
-- after each chunk has loaded, and only near plumbing. This was the separate LGEP Chunk Load
-- Patch mod; turn that one off (see the LGEP section below).
--
-- 1.7: three things for working out what a general version would be worth.
--   * Census: every handler added to LoadGridsquare, LoadChunk, ReuseGridsquare or
--     OnObjectAboutToBeRemoved is listed in
--     the console with its file and what the sieve did with it, so the whole list of chunk-load
--     handlers comes from the game itself.
--   * MODE (below, or Zomboid\Lua\ChunkLoadSieve_mode.txt): "full" is the sieve as before;
--     "machinery" takes every LoadGridsquare handler and calls them all, on every square, from
--     one handler, with no rules and none of the LGEE/LGEP parts; "measure" changes nothing and
--     only times. Every mode times all LoadGridsquare Lua per square, between a first and a last
--     listener, and prints it with the stats line, so three runs compare like for like.
--   * ChunkLoadSieve.rule(file, need): add a rule from another file. Also rules for RC Structure
--     Framework's four handlers.
--
-- 1.8: OnObjectAboutToBeRemoved handlers of LG Extended Plumbing, LG Extended Electricity and Take
-- A Bath And Shower are skipped for trees and bushes, which the game removes in numbers as chunks
-- load, and the two that only act on a multiplayer client are skipped elsewhere (see below).
--

-- This mod's id. build-dev.sh makes a copy with id ChunkLoadSieveDev for testing next to the
-- Workshop copy; the two can't both run, so whichever file loads first wins and the other says so.
local SELF_ID = "ChunkLoadSieve"
local VERSION = "1.8"

if ChunkLoadSieve then
	print("[ChunkLoadSieve] " .. SELF_ID .. " " .. VERSION .. " NOT ACTIVE: Chunk Load Sieve "
		.. tostring(ChunkLoadSieve.version or "1.6 or older") .. " (" .. tostring(ChunkLoadSieve.id or "ChunkLoadSieve")
		.. ") loaded first; enable only one of them")
	return
end
ChunkLoadSieve = { id = SELF_ID, version = VERSION }
local S = ChunkLoadSieve

local ENABLED = true      -- false: capture nothing, every mod behaves as if this patch were absent
local STATS_SECONDS = 120 -- print how many squares each captured handler was called for; 0 = never

-- LG Extended Electricity (1.4). Each can be turned off on its own.
local ENABLE_LGEE_DORMANT = true -- don't file a generator that isn't plugged in, running or marked by any mod
local ENABLE_LGEE_FAR = true     -- no sweep request from chunks or removals far from LGEE's generators and relays
local LGEE_MARGIN = 200          -- tiles past LGEE's longest range still counted as near (big buildings)
local ENABLE_LGEE_PRUNE = true   -- on load, drop saved generators that were off, unwired and not a solar bank

-- Object removals (1.8): skip some mods' OnObjectAboutToBeRemoved handlers for trees and bushes.
local ENABLE_REMOVAL_GATE = true

-- LG Extended Plumbing (1.6, was the LGEP Chunk Load Patch mod).
local ENABLE_LGEP_QUEUE = true   -- read LGEP's per-square scan from a tick budget instead of during chunk loads
local LGEP_LAZY = true           -- and only for chunks near a mirror, a plumbed barrel or a pipe
local LGEP_BUDGET_MS = 2         -- ms of that scan per tick: lower is smoother, higher catches up faster

-- 1.7: "full" (rules and every part above), "machinery" (one handler calls every LoadGridsquare
-- handler on every square: no rules, no LGEE or LGEP parts, no watch()), or "measure" (nothing
-- captured, only the census and the timing). A first line of "full", "machinery" or "measure"
-- in Zomboid\Lua\ChunkLoadSieve_mode.txt wins over this, so a test run can switch modes
-- without editing the mod.
local MODE = "full"
do
	local ok, reader = pcall(getFileReader, "ChunkLoadSieve_mode.txt", false)
	if ok and reader then
		local okL, line = pcall(function() return reader:readLine() end)
		pcall(function() reader:close() end)
		line = okL and line and string.match(tostring(line), "^%s*(%a+)") or nil
		if line == "full" or line == "machinery" or line == "measure" then MODE = line; S.modeFromFile = true end
	end
end
if MODE ~= "full" then
	ENABLE_LGEE_DORMANT, ENABLE_LGEE_FAR, ENABLE_LGEE_PRUNE, ENABLE_LGEP_QUEUE = false, false, false, false
	ENABLE_REMOVAL_GATE = false
end
S.mode = MODE

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

--------------------------------------------------------------------------------
-- LG Extended Electricity
--------------------------------------------------------------------------------

-- nil until first asked; false when LGEE doesn't have what this was written against.
local lgeeOk = nil

local function lgeeReady()
	if lgeeOk == nil then
		local EE = LGEE
		lgeeOk = type(EE) == "table" and type(EE.isConnected) == "function"
			and type(EE.isForeignGenerator) == "function" and type(EE.KEY_FUEL) == "string"
		if not lgeeOk then
			print("[ChunkLoadSieve] LG Extended Electricity looks different from the version this was"
				.. " written for; its generators are filed as usual")
		end
	end
	return lgeeOk
end

local lgeeDormant = 0  -- generators not filed since the last stats line

-- True when LGEEGrid.lua's LoadGridsquare handler would only file a generator nobody has plugged
-- in. That handler (notice, LGEEGrid.lua:620) does two things: files square:getGenerator(), and
-- with FuelLine on, files an object holding EE.KEY_FUEL. Both are checked here.
-- Not skipped: a running or plugged-in generator, a solar mod's battery bank (isForeignGenerator),
-- and any generator with mod data, since some mod has marked it.
local function lgeeSkip(square)
	if not ENABLE_LGEE_DORMANT or not lgeeReady() then return false end
	local g = square:getGenerator()
	if not g then return false end
	local EE = LGEE
	if g:isActivated() or EE.isConnected(g) or EE.isForeignGenerator(g) then return false end
	if g:hasModData() then
		for _ in pairs(g:getModData()) do return false end
	end
	local objects = square:getObjects()
	for i = 0, objects:size() - 1 do
		local o = objects:get(i)
		if o:hasModData() and o:getModData()[EE.KEY_FUEL] == true then return false end
	end
	lgeeDormant = lgeeDormant + 1
	return true
end

-- Facts a gate may ask about a square:
--   generator   square:getGenerator() ~= nil
--   special     the square has special objects (doors, windows, generators...)
--   vehicle     a vehicle stands on the square
--   worldItems  items lying on the ground
--   modData     an object has mod data
--   container   an object has at least one container
--   pump / onanPart / ghostName   an object's sprite is one of KIND_BY_NAME
--   tabas       the square is in Take A Bath And Shower's tub registry
--   damnSpawn   the square is one of damnlib's forced vehicle spawn points
--   server      this is a server (isServer()); never true in singleplayer
--   room        the square is in a room (square:getRoom() ~= nil), 1.7
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
	-- 1.4: and skips a square whose only business is a generator nobody has plugged in (lgeeSkip).
	{ file = "LGExtendedElectricity/LGEEGrid.lua", need = { "generator", "modData" }, skip = lgeeSkip },
	-- LGEEAgree.lua:160 - multiplayer clients only, and only a generator.
	{ file = "LGExtendedElectricity/LGEEAgree.lua", need = { "generator" } },
	-- PZM_Puker_Decals.lua:300 - puke is always placed together with an expiry in the floor's mod
	-- data (line ~251), and a floor without mod data has no expiry to clear. Not covered: puke
	-- with no saved expiry at all, which the mod repairs as a "defensive migration" path.
	{ file = "PZM_Puker_Decals.lua", need = { "modData" } },
	-- vfx_agingmanager.lua:1460 - skips squares with no ground items and no containers. A stale
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
	-- DAMN_Spawns.lua (damnlib) - checkSquare does nothing unless DAMN.Spawns.byLocation has an
	-- entry keyed "x_y" for the square, a list filled by vehicle mods as their files load.
	{ file = "server/DAMN_Spawns.lua", need = { "damnSpawn" } },
	-- FB_Client.lua:190 (Fitted Barricades) - FB.trackSquare returns when the square's special
	-- objects list is empty. The map's own barricades are made by Java's MapObjects hooks
	-- (MOBarricade.lua) while the square loads, before any LoadGridsquare handler runs.
	{ file = "FittedBarricades/FB_Client.lua", need = { "special" } },
	-- FB_Build.lua:257 (Fitted Barricades) - returns unless isServer().
	{ file = "FittedBarricades/FB_Build.lua", need = { "server" } },
	-- FT_Server.lua:116 (Fitted Sheets) - sweepSquare returns when the special objects list is
	-- empty (windows and curtains are special objects). Its LoadChunk sweep is not touched.
	{ file = "FittedSheets/FT_Server.lua", need = { "special" } },
	-- 1.7, RC Structure Framework.
	-- RoofPieces.lua:81 - repairSquare only walks the square's special objects.
	{ file = "RCStructureFramework/RoofPieces.lua", need = { "special" } },
	-- SpritePropertyPatcher.lua:63 - returns when the special objects list is empty.
	{ file = "RCStructureFramework/SpritePropertyPatcher.lua", need = { "special" } },
	-- RoomLighting.lua:214 - needs a light switch and square:getRoom() being one of its rooms
	-- (frameworkRoomOfSquare), so a square with no room has nothing for it.
	{ file = "RCStructureFramework/RoomLighting.lua", need = { "room" } },
	-- TemplateStamp.lua:939 - sweepStrayPreview only looks at objects with mod data (its preview tag).
	{ file = "RCStructureFramework/TemplateStamp.lua", need = { "modData" } },
}

-- Every fact a rule may name (see the list above RULES).
local FACTS = { generator = true, special = true, vehicle = true, worldItems = true, modData = true,
	container = true, pump = true, onanPart = true, ghostName = true, tabas = true, damnSpawn = true,
	server = true, room = true }

-- 1.5: what makes a saved LGEE generator row worth keeping (EE.saveRegistry, LGEEGrid.lua:7966).
local KEEP_FIELDS = { "running", "extended", "tripped", "tripGroup", "tripStopped", "lineShare",
	"debt", "debtTries", "debtNeutral", "bank", "bankTripGroup", "bankTripStopped", "bankOn" }

local function pruneLgee()
	if not ENABLE_LGEE_PRUNE then return end
	local EE = LGEE
	if type(EE) ~= "table" or type(EE.MODDATA_KEY) ~= "string" or not ModData or not ModData.getOrCreate then return end
	if type(EE.isAuthority) == "function" and not EE.isAuthority() then return end
	if type(EE.getOption) == "function" and not EE.getOption("Enabled") then return end
	local md = ModData.getOrCreate(EE.MODDATA_KEY)
	local reg = md and md.registry
	if reg == nil then return end
	local gens = type(reg) == "table" and reg.generators
	if type(gens) ~= "table" then
		print("[ChunkLoadSieve] LG Extended Electricity's saved list looks different from the version this was written for; left alone")
		return
	end
	local drop, total = {}, 0
	for key, row in pairs(gens) do
		total = total + 1
		local keep = type(row) ~= "table"
		if not keep then
			for i = 1, #KEEP_FIELDS do
				local v = row[KEEP_FIELDS[i]]
				if v ~= nil and v ~= false then keep = true break end
			end
		end
		if not keep then drop[#drop + 1] = key end
	end
	for i = 1, #drop do gens[drop[i]] = nil end
	print(string.format("[ChunkLoadSieve] LGEE: removed %d of %d saved generators that were off, unwired and not a solar bank",
		#drop, total))
end

if ENABLED and Events and Events.OnInitGlobalModData and Events.OnInitGlobalModData.Add then
	-- Registered as this file loads, so it runs before LGEE's own handler, which reads the list.
	Events.OnInitGlobalModData.Add(function()
		local ok, err = pcall(pruneLgee)
		if not ok then print("[ChunkLoadSieve] ERROR trimming LGEE's saved list: " .. tostring(err)) end
	end)
end

local Events = Events
local event = Events and Events.LoadGridsquare
if not ENABLED or type(event) ~= "table" or type(event.Add) ~= "function" then return end

local realAdd, realRemove = event.Add, event.Remove
-- LoadChunk's own Add/Remove, before anything here wraps them: used only for its timing stamps.
local chunkEvent = Events.LoadChunk
local chunkAdd = chunkEvent and chunkEvent.Add
local chunkRemove = chunkEvent and chunkEvent.Remove

local captured = {}   -- list of { fn, rule, path, calls, faulted, stamp }
local byFn = {}       -- original fn -> entry
local lists = {}      -- fact -> list of entries that need it

-- Which facts to compute; refreshed whenever a handler is captured or removed.
local wGenerator, wSpecial, wVehicle, wWorldItems = false, false, false, false
local wModData, wContainer, wNames, wTabas = false, false, false, false
local wDamn, wServer, wRoom = false, false, false
local isServerNow = nil   -- isServer(), read on the first square of each game
local wWatch = false

-- watch(): { test, onSquare, stamp }, see the 1.2 note at the top.
local watchers = {}

-- Our own wrappers -> the handler they wrap, so a second wrapper still sees whose it is (1.8).
local wrappedOf = {}
local fileCache = setmetatable({}, { __mode = "k" })  -- fn -> path, or false when unknown

-- True when path is f or ends in "/" .. f, so "GasPumpIndicator.lua" does not match
-- "XGasPumpIndicator.lua".
local function pathEnds(path, f)
	if not path then return false end
	local n, m = #path, #f
	if n < m or string.sub(path, -m) ~= f then return false end
	return n == m or string.sub(path, n - m, n - m) == "/"
end

local fileOfRaw
local function fileOf(fn)
	local c = fileCache[fn]
	if c ~= nil then return c or nil end
	c = fileOfRaw(fn)
	fileCache[fn] = c or false
	return c
end

fileOfRaw = function(fn)
	while wrappedOf[fn] do fn = wrappedOf[fn] end
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
		if pathEnds(path, rule.file) then return rule end
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
	wDamn = lists.damnSpawn ~= nil
	wServer = lists.server ~= nil
	wRoom = lists.room ~= nil
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

-- damnlib's spawn points, keyed "x_y". Mirrored the same way as the tubs: a set of x values.
local damnXs = {}
local damnAny = false
local damnOk = true

local function refreshDamn()
	if not wDamn then return end
	local list = DAMN and DAMN.Spawns and DAMN.Spawns.byLocation
	if type(list) ~= "table" then damnOk = false return end
	local xs, any = {}, false
	for id in pairs(list) do
		local x = tonumber(string.match(tostring(id), "^([^_]+)_"))
		if x then xs[x] = true; any = true else damnOk = false end
	end
	damnXs, damnAny = xs, any
end

local function fault(e, err)
	if e.faulted then return end
	e.faulted = true
	print("[ChunkLoadSieve] ERROR in captured handler " .. tostring(e.path) .. ": " .. tostring(err))
end

local squares = 0
-- The game has started (OnGameStart, or OnServerStarted on a dedicated server).
local started = false
-- The tub and spawn-point lists have been read after the start, at the first 30-tick refresh, so
-- entries other mods add in their own OnGameStart are in. Until then those handlers get every square.
local listsReady = false

-- Calls every handler listening on `fact` that has not run for this square yet.
local function fire(fact, square)
	local l = lists[fact]
	for i = 1, #l do
		local e = l[i]
		if e.stamp ~= squares then
			e.stamp = squares
			local skip = e.rule.skip
			local skipped = false
			if skip then
				local ok, res = pcall(skip, square)
				skipped = ok and res == true
			end
			if not skipped then
				e.calls = e.calls + 1
				local ok, err = pcall(e.fn, square)
				if not ok then fault(e, err) end
			end
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

	if wRoom and square:getRoom() then fire("room", square) end

	if wTabas then
		if not tabasOk or not listsReady then
			fire("tabas", square)
		elseif tabasAny then
			local x = square:getX()
			if tabasXs[x] then fire("tabas", square) end
		end
	end

	if wServer then
		if isServerNow == nil then isServerNow = (isServer and isServer()) and true or false end
		if isServerNow then fire("server", square) end
	end

	if wDamn then
		if not damnOk or not listsReady then
			fire("damnSpawn", square)
		elseif damnAny then
			if damnXs[square:getX()] then fire("damnSpawn", square) end
		end
	end
end

--------------------------------------------------------------------------------
-- LG Extended Plumbing: the square scan, from a tick budget (1.6)
--------------------------------------------------------------------------------
-- Was the separate LGEP Chunk Load Patch mod (1.2.0); the behaviour is the same.
--
-- LGEPPlumbing.lua (server) runs notice() on every square of every chunk from LoadGridsquare,
-- about 20 microseconds a square. Its handler is held here instead of being attached, and:
--
-- 1. WHEN. Each chunk is noted on LoadChunk (raised once all its squares are in) and its squares
--    are handed to the original handler a level at a time on OnTick, under LGEP_BUDGET_MS.
--
-- 2. WHERE (LGEP_LAZY). Nothing in that mod does anything until a player plumbs a barrel in: a
--    supply needs EP.isIncluded, and a mirror is only made for a fixture that has a supply. So
--    a chunk is read only when it is near a mirror, a plumbed barrel or a pipe (hot); every other
--    chunk is skipped (cold), and read in full if it turns hot while still loaded.
--    Mirrors come from the mod's own saved list of every mirror address. Plumbed barrels come
--    from a list saved with the world, kept by wrapping LGEP.setIncluded, where the plumb and
--    unplumb menu actions end. A barrel plumbed before this was installed, somewhere no mirror or
--    pipe covers, is picked up the next time it is unplumbed and plumbed again.
--
-- Not done on purpose: remembering chunks "once per session". The mod forgets mirrors and
-- fixtures whose chunk unloaded and files them again on the next load, and notice() also
-- repairs barrels the engine gutted on unload. Squares are looked up again by coordinates when
-- their turn comes, never kept: a recycled square is reused at a different place.

local LGEP_FILE = "LGExtendedPlumbing/LGEPPlumbing.lua"
local LGEP_INDEX_MS = 5000      -- how often the hot-chunk index is rebuilt from the mod's records
local LGEP_MAX_LEVELS = 8       -- hard cap of chunk levels per tick, in case the clock is coarse
-- Saved under the old mod's key, so its list of plumbed barrels carries over.
local LGEP_STORE = "LGEPChunkLoadPatch"
local LGEP_CHUNK = 8

local lgepHandler = nil         -- the captured notice handler
local lgepLevels, lgepColdChunks = 0, 0 -- for the stats line
local lgepMs = 0                          -- ms spent reading the queue (1.7), for the stats line

local function lgepLog(msg) print("[ChunkLoadSieve] LGEP: " .. msg) end

local function lgepChunkKey(cx, cy) return cx * 65536 + cy end

local hot = {}            -- chunk key -> true
local indexBuiltAt = nil
local addressMemo = {}    -- address -> list of chunk keys it heats
local lazyBroken = false  -- the index could not be built: read everything in full
local plumbed = nil       -- saved: "x,y,z" -> true for every barrel plumbed in

local function lazyOn() return LGEP_LAZY and not lazyBroken end

-- Chunks covering a box of tiles, grown by `margin` chunks.
local function boxChunks(list, minX, minY, maxX, maxY, margin)
	for cx = math.floor(minX / LGEP_CHUNK) - margin, math.floor(maxX / LGEP_CHUNK) + margin do
		for cy = math.floor(minY / LGEP_CHUNK) - margin, math.floor(maxY / LGEP_CHUNK) + margin do
			list[#list + 1] = lgepChunkKey(cx, cy)
		end
	end
end

-- The map building at a point, as a box, or nil. EP.mapBuildingAt answers from the map's
-- building index when the square is not loaded, so this works for a mirror far away.
local function buildingBox(x, y, z)
	local EP = LGEP
	if not (EP and EP.mapBuildingAt and EP.buildingBounds) then return nil end
	local ok, b = pcall(function()
		local def = EP.mapBuildingAt(x, y, z)
		return def and EP.buildingBounds(def) or nil
	end)
	if ok and b and b.minX then return b end
	return nil
end

local function reachChunks()
	local EP = LGEP
	local reach = 12
	if EP and EP.getOption then
		local ok, r = pcall(EP.getOption, "Reach")
		if ok and type(r) == "number" then reach = r end
	end
	return math.ceil(reach / LGEP_CHUNK)
end

-- An address heats its own building, and the ground within `margin` chunks of it (a
-- player-built structure has no building, and its scope is decided by Reach).
local function heatAround(memoKey, x, y, z, margin)
	local list = addressMemo[memoKey]
	if not list then
		list = {}
		boxChunks(list, x, y, x, y, margin)
		local b = buildingBox(x, y, z)
		if b then boxChunks(list, b.minX, b.minY, b.maxX, b.maxY, 1) end
		addressMemo[memoKey] = list
	end
	for i = 1, #list do hot[list[i]] = true end
end

local function parseKey(key)
	if type(key) ~= "string" then return nil end
	local x, y, z = string.match(key, "^(-?%d+),(-?%d+),(-?%d+)$")
	if not x then return nil end
	return tonumber(x), tonumber(y), tonumber(z)
end

local function rebuildIndex()
	local EP = LGEP
	hot = {}
	if not EP then return end
	local margin = reachChunks()

	-- Every mirror this save has, loaded or not: the mod keeps the list for its uninstall.
	if ModData and ModData.getOrCreate and EP.PIPE_STORE then
		local store = ModData.getOrCreate(EP.PIPE_STORE)
		if store and type(store.mirrors) == "table" then
			for key in pairs(store.mirrors) do
				local x, y, z = parseKey(key)
				if x then heatAround(key, x, y, z, margin) end
			end
		end
	end

	-- Every barrel (or dispenser) a player has plumbed in since this was installed.
	if plumbed then
		for key in pairs(plumbed) do
			local x, y, z = parseKey(key)
			if x then heatAround("p:" .. key, x, y, z, margin) end
		end
	end

	-- Every pipe piece, and the chunks either side of it.
	local function pipes(rows)
		if type(rows) ~= "table" then return end
		for _, row in pairs(rows) do
			if row.x and row.y then
				local list = {}
				boxChunks(list, row.x, row.y, row.x, row.y, 1)
				for i = 1, #list do hot[list[i]] = true end
			end
		end
	end
	pipes(EP.floorPipes)
	pipes(EP.wallPipes)
end

-- Chunk levels still to read: {x, y = first square, z = level, key, last}.
local queue, head, tail = {}, 1, 0
-- Chunks currently waiting, so a chunk that loads twice before its turn is read once.
local pending = {}
-- Chunks skipped as cold, read in full if they turn hot while loaded: key -> {x, y, lo, hi}.
local readCold = {}

local function enqueueLevels(key, x0, y0, lo, hi)
	pending[key] = true
	for z = lo, hi do
		tail = tail + 1
		queue[tail] = { x = x0, y = y0, z = z, key = key, last = (z == hi) }
	end
end

local function enqueue(chunk)
	if not chunk or not chunk.getGridSquare then return end
	local lo, hi = 0, 0
	if chunk.getMinLevel and chunk.getMaxLevel then lo, hi = chunk:getMinLevel(), chunk:getMaxLevel() end

	-- The chunk's world position, from any square it holds (Kahlua exposes methods, not fields,
	-- so chunk.wx is not readable).
	local x0, y0
	for z = lo, hi do
		for lx = 0, LGEP_CHUNK - 1 do
			for ly = 0, LGEP_CHUNK - 1 do
				local square = chunk:getGridSquare(lx, ly, z)
				if square then
					x0 = math.floor(square:getX() / LGEP_CHUNK) * LGEP_CHUNK
					y0 = math.floor(square:getY() / LGEP_CHUNK) * LGEP_CHUNK
					break
				end
			end
			if x0 then break end
		end
		if x0 then break end
	end
	if not x0 then return end

	local key = lgepChunkKey(math.floor(x0 / LGEP_CHUNK), math.floor(y0 / LGEP_CHUNK))
	if pending[key] then return end

	if lazyOn() and not hot[key] then
		readCold[key] = { x = x0, y = y0, lo = lo, hi = hi }
		lgepColdChunks = lgepColdChunks + 1
		return
	end
	readCold[key] = nil
	enqueueLevels(key, x0, y0, lo, hi)
end

-- After the index grows: a chunk skipped as cold and still loaded is read in full, so the
-- fixtures in a building that has just been plumbed are not missed.
local function promoteCold()
	local cell = getCell()
	if not cell then return end
	local gone = nil
	for key, c in pairs(readCold) do
		if cell:getGridSquare(c.x, c.y, 0) == nil and cell:getGridSquare(c.x, c.y, c.lo) == nil then
			gone = gone or {}
			gone[#gone + 1] = key
		elseif hot[key] and not pending[key] then
			gone = gone or {}
			gone[#gone + 1] = key
			enqueueLevels(key, c.x, c.y, c.lo, c.hi)
		end
	end
	if gone then
		for i = 1, #gone do readCold[gone[i]] = nil end
	end
end

local function readLevel(handler, cell, item)
	for dx = 0, LGEP_CHUNK - 1 do
		for dy = 0, LGEP_CHUNK - 1 do
			local square = cell:getGridSquare(item.x + dx, item.y + dy, item.z)
			-- nil means the chunk has gone again; its next load will queue it afresh.
			if square then handler(square) end
		end
	end
end

local function refreshIndex(force)
	if not LGEP_LAZY then return end
	local t = getTimestampMs()
	if not force and indexBuiltAt and t - indexBuiltAt < LGEP_INDEX_MS then return end
	indexBuiltAt = t
	local ok, err = pcall(rebuildIndex)
	if not ok then
		lgepLog("ERROR building the plumbed-area index, reading everything in full: " .. tostring(err))
		lazyBroken = true
		return
	end
	pcall(promoteCold)
end

-- Plumbing in and out. The menu sends a command and the server's handler calls EP.setIncluded
-- through the LGEP table (LGEPPlumbing ~3472), so replacing the table entry is enough. The
-- original runs first and decides; the result is read back off the world afterwards, because
-- the original can refuse (EP.canPlumbHere) and only what actually happened goes on the list.
local function recordPlumbing(x, y, z, included)
	if not plumbed then return end
	local EP = LGEP
	local key = x .. "," .. y .. "," .. z
	local now = false
	if included then
		local source = EP.sourceAt and EP.sourceAt(x, y, z)
		if source and EP.isIncluded and EP.isIncluded(source) then
			now = true
		elseif EP.isFedPlumbed then
			local square = getCell():getGridSquare(x, y, z)
			now = square ~= nil and EP.isFedPlumbed(square) == true
		end
	end
	if now then plumbed[key] = true else plumbed[key] = nil end
	-- Rebuilt now rather than on the next lap, so the building turns hot straight away.
	indexBuiltAt = nil
end

local function wrapSetIncluded()
	local EP = LGEP
	-- The flag is the old mod's, so the two never both wrap it.
	if not EP or not EP.setIncluded or EP.setIncludedWrappedByCLP then return end
	local original = EP.setIncluded
	EP.setIncluded = function(x, y, z, included)
		local r1, r2 = original(x, y, z, included)
		local ok, err = pcall(recordPlumbing, x, y, z, included)
		if not ok then lgepLog("ERROR recording a plumb action: " .. tostring(err)) end
		return r1, r2
	end
	EP.setIncludedWrappedByCLP = true
end

local function lgepOnChunk(chunk)
	if not lgepHandler then return end
	if not indexBuiltAt then refreshIndex(true) end
	local ok, err = pcall(enqueue, chunk)
	if not ok then lgepLog("ERROR queueing a chunk: " .. tostring(err)) end
end

local function lgepOnTick()
	local handler = lgepHandler
	if not handler then return end
	refreshIndex(indexBuiltAt == nil)
	if head > tail then return end
	local cell = getCell()
	if not cell then return end

	local started = getTimestampMs()
	local levels = 0
	while head <= tail and levels < LGEP_MAX_LEVELS do
		local item = queue[head]
		queue[head] = nil
		head = head + 1
		levels = levels + 1
		local ok, err = pcall(readLevel, handler, cell, item)
		if not ok then lgepLog("ERROR reading a chunk level: " .. tostring(err)) end
		if item.last then pending[item.key] = nil end
		if getTimestampMs() - started >= LGEP_BUDGET_MS then break end
	end
	lgepLevels = lgepLevels + levels
	lgepMs = lgepMs + (getTimestampMs() - started)

	if head > tail then
		-- Empty: start the indices again so they do not grow for the whole session.
		queue, head, tail = {}, 1, 0
	end
end

-- A new world is a new map. Also where the plumb/unplumb wrapper goes in: by this event every
-- mod's files have run, no chunk has loaded and no player can have opened a menu.
local function lgepOnInitModData()
	if not lgepHandler then return end
	wrapSetIncluded()
	hot, addressMemo, readCold, indexBuiltAt = {}, {}, {}, nil
	queue, head, tail, pending = {}, 1, 0, {}
	plumbed = nil
	if ModData and ModData.getOrCreate then
		local store = ModData.getOrCreate(LGEP_STORE)
		if type(store.plumbed) ~= "table" then store.plumbed = {} end
		plumbed = store.plumbed
	end
end

-- Called from event.Add below with the plumbing mod's handler: held, and run from the queue.
local function lgepTake(fn)
	lgepHandler = fn
	-- The profiler reports the queue's time under the plumbing mod, where the work is.
	local P = LuaEventProfiler
	if P and P.sourceOf then P.sourceOf[lgepOnTick] = fn end
	Events.LoadChunk.Add(lgepOnChunk)
	Events.OnTick.Add(lgepOnTick)
	print("[ChunkLoadSieve] captured " .. LGEP_FILE .. " (read from a " .. LGEP_BUDGET_MS
		.. " ms tick budget" .. (LGEP_LAZY and ", only near plumbing)" or ")"))
end

if ENABLE_LGEP_QUEUE and Events.OnInitGlobalModData and Events.OnInitGlobalModData.Add then
	Events.OnInitGlobalModData.Add(lgepOnInitModData)
end

--------------------------------------------------------------------------------
-- Census and timing (1.7)
--------------------------------------------------------------------------------
-- census: one entry per handler added to a chunk-load event: { event, fn, path, how }.
-- how: "caught" (a rule), "queued" (LGEP), "held" (machinery mode) or "passed" (left on the event).
local census = {}
-- After the start, additions are printed as they come, once per function and event: some mods
-- add and remove the same handler over and over during play (VFE), often inside a timed window.
local lateSeen = {}   -- event -> set of functions
local function seenOn(eventName)
	local t = lateSeen[eventName]
	if not t then t = setmetatable({}, { __mode = "k" }); lateSeen[eventName] = t end
	return t
end

local function censusNote(eventName, fn, path, how)
	local c = { event = eventName, fn = fn, path = path or "?", how = how }
	census[#census + 1] = c
	if started and not seenOn(eventName)[fn] then
		seenOn(eventName)[fn] = true
		print("[ChunkLoadSieve] census (late) " .. eventName .. " " .. how .. " " .. c.path)
	end
	return c
end

local function censusDrop(eventName, fn)
	for i = #census, 1, -1 do
		local c = census[i]
		if c.event == eventName and c.fn == fn then table.remove(census, i) return end
	end
end

-- Timing: a listener added first stamps the clock, one kept last adds the difference, so every
-- LoadGridsquare handler in between is timed, the game's own calls into Lua included. The clock
-- counts whole ms; summed over thousands of squares the error averages out.
local lgsT0 = nil
local lgsMs, lgsSquares = 0, 0           -- this stats window
local lgsMsAll, lgsSquaresAll = 0, 0     -- since the game started
local function stampFirst()
	lgsT0 = getTimestampMs()
end
local function stampLast()
	local t0 = lgsT0
	if not t0 then return end
	lgsT0 = nil
	local d = getTimestampMs() - t0
	lgsMs = lgsMs + d
	lgsSquares = lgsSquares + 1
end
-- The same for LoadChunk (1.8): every LoadChunk handler, timed per chunk.
local lcT0 = nil
local lcMs, lcChunks = 0, 0
local function chunkFirst() lcT0 = getTimestampMs() end
local function chunkLast()
	local t0 = lcT0
	if not t0 then return end
	lcT0 = nil
	lcMs = lcMs + (getTimestampMs() - t0)
	lcChunks = lcChunks + 1
end
local function keepChunkLast()
	if not started or type(chunkAdd) ~= "function" then return end
	if type(chunkRemove) == "function" then chunkRemove(chunkLast) end
	chunkAdd(chunkLast)
end
if type(chunkAdd) == "function" then chunkAdd(chunkFirst) end

local lastAtEnd = false
local function keepLast()
	if not started then return end
	if type(realRemove) == "function" then realRemove(stampLast) end
	realAdd(stampLast)
	lastAtEnd = true
end

-- Machinery mode: every handler, called on every square from here, no rules.
local held = {}       -- list of { fn, path, faulted }
local heldBy = {}     -- fn -> entry
local function dispatchAll(square)
	squares = squares + 1
	for i = 1, #held do
		local e = held[i]
		local ok, err = pcall(e.fn, square)
		if not ok and not e.faulted then
			e.faulted = true
			print("[ChunkLoadSieve] ERROR in handler " .. tostring(e.path) .. ": " .. tostring(err))
		end
	end
end

-- Some mods (RC Structure Framework) remove and add the same handler during play; it is caught
-- again each time but announced once.
local announced = setmetatable({}, { __mode = "k" })
local function capture(fn, rule, path)
	local e = { fn = fn, rule = rule, path = path, calls = 0, stamp = -1 }
	captured[#captured + 1] = e
	byFn[fn] = e
	rebuild()
	if not started then refreshTabas(); refreshDamn() end
	if not announced[fn] then
		announced[fn] = true
		print("[ChunkLoadSieve] captured " .. rule.file)
	end
end

event.Add = function(fn)
	if type(fn) ~= "function" then return realAdd(fn) end
	if byFn[fn] or heldBy[fn] then return end
	local path = fileOf(fn)
	if MODE == "machinery" then
		local e = { fn = fn, path = path }
		held[#held + 1] = e
		heldBy[fn] = e
		censusNote("LoadGridsquare", fn, path, "held")
		return
	end
	if MODE == "full" then
		if ENABLE_LGEP_QUEUE and not lgepHandler and pathEnds(path, LGEP_FILE) then
			lgepTake(fn)
			censusNote("LoadGridsquare", fn, path, "queued")
			return
		end
		local rule = ruleFor(path)
		if rule then
			capture(fn, rule, path)
			censusNote("LoadGridsquare", fn, path, "caught")
			return
		end
	end
	censusNote("LoadGridsquare", fn, path, "passed")
	local r = realAdd(fn)
	if lastAtEnd then keepLast() end
	return r
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
			censusDrop("LoadGridsquare", fn)
			return
		end
		local h = heldBy[fn]
		if h then
			heldBy[fn] = nil
			for i = #held, 1, -1 do
				if held[i] == h then table.remove(held, i) end
			end
			censusDrop("LoadGridsquare", fn)
			return
		end
		censusDrop("LoadGridsquare", fn)
		return realRemove(fn)
	end
end

-- Adds a rule from another file: file is the end of the handler's path, need a list of facts.
-- A handler already left on the event is taken off it and caught now. Full mode only.
function S.rule(file, need)
	if type(file) ~= "string" or type(need) ~= "table" or #need == 0 then return false end
	for _, f in ipairs(need) do
		if not FACTS[f] then print("[ChunkLoadSieve] rule for " .. file .. " ignored: no fact called " .. tostring(f)) return false end
	end
	local rule = { file = file, need = need }
	table.insert(RULES, 1, rule)
	if MODE ~= "full" or type(realRemove) ~= "function" then return true end
	for _, c in ipairs(census) do
		if c.event == "LoadGridsquare" and c.how == "passed" and ruleFor(c.path) == rule then
			realRemove(c.fn)
			c.how = "caught"
			capture(c.fn, rule, c.path)
		end
	end
	return true
end

realAdd(stampFirst)
if MODE == "full" then realAdd(dispatch) elseif MODE == "machinery" then realAdd(dispatchAll) end

--------------------------------------------------------------------------------
-- LG Extended Electricity: sweep requests from far away (1.4)
--------------------------------------------------------------------------------
-- LGEEGrid.lua's LoadChunk handler (line 11501) and OnObjectAboutToBeRemoved handler (11645) end
-- in a bare EE.requestSweep(), and every request starts a full pass over the powered buildings
-- half a second later. While driving, chunks arrive all the time, so a pass is always running.
-- A chunk far from every generator and relay can't change what that pass works out, so the
-- handler is run with a requestSweep that drops only that bare call: a call with a reason or
-- marked urgent goes through, and so does everything else the handler does.

local FAR_FILE = "LGExtendedElectricity/LGEEGrid.lua"
local CELL = 128           -- tiles per side of a cell in the near set
local NEAR_REFRESH = 600   -- ticks between rebuilds of the near set

local near = nil           -- set of cell keys near a generator or relay; nil = can't tell
local nearCells = 0
local nearTicks = 0
local farDropped, farPassed = 0, 0
local farOk = nil

local function cellKey(cx, cy) return cx * 100000 + cy end

local function lgeeReach()
	local EE = LGEE
	local r = 0
	for _, name in ipairs({ "radius", "generatorRange", "cordRadius", "circleRadius" }) do
		local f = EE[name]
		if type(f) == "function" then
			local ok, v = pcall(f)
			if ok and type(v) == "number" and v > r then r = v end
		end
	end
	return r
end

-- Every cell within reach + LGEE_MARGIN of a generator in LGEE's registry or a relay in its wire
-- store. Returns nil (treat everything as near) if either can't be read.
local function buildNear()
	local EE = LGEE
	if type(EE) ~= "table" or type(EE.eachKnownGenerator) ~= "function"
		or type(EE.wireStoreForTest) ~= "function" then return nil end
	local xs, ys = {}, {}
	local ok = pcall(EE.eachKnownGenerator, function(_, pos)
		xs[#xs + 1] = pos.x; ys[#ys + 1] = pos.y
	end)
	if not ok then return nil end
	local okW, wires = pcall(EE.wireStoreForTest)
	if not okW or type(wires) ~= "table" then return nil end
	for _, w in pairs(wires) do
		local x, y = type(w) == "table" and tonumber(w.x), type(w) == "table" and tonumber(w.y)
		if not (x and y) then return nil end
		xs[#xs + 1] = x; ys[#ys + 1] = y
	end
	-- Points in the same cell give the same answer (a cell's corners stand in for them).
	local r = lgeeReach() + LGEE_MARGIN + CELL
	local set, n, seen = {}, 0, {}
	for i = 1, #xs do
		local px, py = math.floor(xs[i] / CELL), math.floor(ys[i] / CELL)
		local pk = cellKey(px, py)
		if not seen[pk] then
			seen[pk] = true
			local x0, x1 = math.floor((px * CELL - r) / CELL), math.floor((px * CELL + CELL + r) / CELL)
			local y0, y1 = math.floor((py * CELL - r) / CELL), math.floor((py * CELL + CELL + r) / CELL)
			for cx = x0, x1 do
				for cy = y0, y1 do
					local k = cellKey(cx, cy)
					if not set[k] then set[k] = true; n = n + 1 end
				end
			end
		end
	end
	nearCells = n
	return set
end

local function refreshNear()
	if not ENABLE_LGEE_FAR then near = nil return end
	-- Switched off, LGEE's passes put its street lamps back as chunks arrive; leave those alone.
	local EE = LGEE
	if type(EE) == "table" and type(EE.getOption) == "function" then
		local ok, on = pcall(EE.getOption, "Enabled")
		if ok and not on then near = nil return end
	end
	near = buildNear()
	if near == nil and farOk ~= false then
		farOk = false
		print("[ChunkLoadSieve] can't read LG Extended Electricity's generator list; its sweep requests are left alone")
	elseif near ~= nil then
		farOk = true
	end
end

local function isFar(x, y)
	if not near or not x or not y then return false end
	return not near[cellKey(math.floor(x / CELL), math.floor(y / CELL))]
end

-- Runs fn(...) with LGEE.requestSweep dropping its bare form.
local function runQuiet(fn, ...)
	local EE = LGEE
	local real = EE.requestSweep
	local dropped = false
	EE.requestSweep = function(reason, urgent)
		if reason == nil and not urgent then dropped = true return end
		return real(reason, urgent)
	end
	local ok, err = pcall(fn, ...)
	if EE.requestSweep ~= real then EE.requestSweep = real end
	if dropped then farDropped = farDropped + 1 end
	if not ok then error(err, 0) end
end

local farWrapped = {}  -- event name -> { [handler] = wrapper }
local farAny = false   -- a handler was caught

local function chunkXY(chunk)
	local EE = LGEE
	if type(EE.chunkCoords) ~= "function" then return nil end
	local ok, cx, cy = pcall(EE.chunkCoords, chunk)
	if ok and cx and cy then return cx * (EE.CHUNK or 8), cy * (EE.CHUNK or 8) end
	return nil
end

local function objectXY(object)
	local sq = object and object:getSquare()
	if sq then return sq:getX(), sq:getY() end
	return nil
end

local function farGate(eventName, whereOf)
	local ev = Events and Events[eventName]
	if type(ev) ~= "table" or type(ev.Add) ~= "function" then return end
	local add, remove = ev.Add, ev.Remove
	local map = {}
	farWrapped[eventName] = map
	ev.Add = function(fn)
		if ENABLE_LGEE_FAR and type(fn) == "function" and not map[fn] then
			local path = fileOf(fn)
			if pathEnds(path, FAR_FILE) then
				local w = function(arg)
					if near and type(LGEE) == "table" and type(LGEE.requestSweep) == "function" then
						local okW, x, y = pcall(whereOf, arg)
						if okW and isFar(x, y) then return runQuiet(fn, arg) end
					end
					farPassed = farPassed + 1
					return fn(arg)
				end
				map[fn] = w
				farAny = true
				local P = LuaEventProfiler
				if P and P.sourceOf then P.sourceOf[w] = fn end
				print("[ChunkLoadSieve] caught " .. FAR_FILE .. " " .. eventName)
				return add(w)
			end
		end
		return add(fn)
	end
	if type(remove) == "function" then
		ev.Remove = function(fn)
			local w = map[fn]
			if w then map[fn] = nil return remove(w) end
			return remove(fn)
		end
	end
end

if ENABLE_LGEE_FAR then
	farGate("LoadChunk", chunkXY)
	farGate("OnObjectAboutToBeRemoved", objectXY)
end

--------------------------------------------------------------------------------
-- Object removals: trees and bushes (1.8)
--------------------------------------------------------------------------------
-- When chunks load, the game's vegetation (erosion) pass replaces trees, bushes and grass, and
-- every one removed raises OnObjectAboutToBeRemoved. Several mods hook that event for their own
-- objects only: a barrel, a tub, a generator. None of them can be a tree or a bush, so those
-- handlers are skipped for vegetation: an IsoTree, or an object whose sprite has the vegitation
-- flag (the game's own spelling). Each rule below is read from the handler it names.

local REMOVAL_RULES = {
	-- LGEPPlumbing.lua:6012 - acts on a ghost (LGEP's own sprite or key), a water source
	-- (IsoThumpable only), a fed fixture (a scripted entity on its list) or a fixture with the
	-- waterPiped flag. A tree or bush is none of these, so it only computes a key and returns.
	{ file = "LGExtendedPlumbing/LGEPPlumbing.lua", skip = "veg" },
	-- LGEPClient.lua:1062 - only sends anything when EP.isNetworkClient() (isClient() and not
	-- isServer()); everything before that is tests without side effects.
	{ file = "LGExtendedPlumbing/LGEPClient.lua", skip = "notNetClient" },
	-- LGEEGrid.lua:11645 - marks the square's power draw dirty and asks for a sweep for any
	-- removal, then files generator or fuel-holder changes. A tree or bush draws no power and is
	-- neither, so the square's draw has not changed.
	{ file = "LGExtendedElectricity/LGEEGrid.lua", skip = "veg" },
	-- LGEEAgree.lua:182 - returns at once unless EE.isNetworkClient(), then only for a generator.
	{ file = "LGExtendedElectricity/LGEEAgree.lua", skip = "notNetClient" },
	-- TABAS_STubFluidContainerSystem.lua:337 - returns unless TABAS_Iso.isBathObject (a bathtub sprite).
	{ file = "TABAS_STubFluidContainerSystem.lua", skip = "veg" },
	-- TABAS_ShowerFx.lua:549 - returns unless TABAS_Iso.isShowerObject (a shower or bath sprite).
	{ file = "TABAS_ShowerFx.lua", skip = "veg" },
	-- TABAS_TubEdge.lua:589 - besides bathtubs, reacts to a wall (WallN/WallW) or anything solid
	-- (solid, solidtrans) next to a tub. Skipped only for vegetation with none of those flags.
	{ file = "TABAS_TubEdge.lua", skip = "vegNotSolid" },
}

local vegOfSprite = {}   -- sprite -> true/false, the vegitation flag
local netClient = nil    -- isClient() and not isServer(), read once per game

local function isVegetation(o)
	if instanceof(o, "IsoTree") then return true end
	local spr = o:getSprite()
	if not spr then return false end
	local v = vegOfSprite[spr]
	if v == nil then
		local props = spr:getProperties()
		v = (props ~= nil and props:has(IsoFlagType.vegitation)) and true or false
		vegOfSprite[spr] = v
	end
	return v
end

local function solidOrWall(o)
	local props = o:getProperties()
	if not props then return false end
	return props:has(IsoFlagType.solid) or props:has(IsoFlagType.solidtrans)
		or props:has("WallN") or props:has("WallW")
end

local function skipRemoval(kind, o)
	if kind == "notNetClient" then
		if netClient == nil then netClient = (isClient() and not isServer()) and true or false end
		return not netClient
	end
	if not isVegetation(o) then return false end
	if kind == "vegNotSolid" then return not solidOrWall(o) end
	return true
end

local removalRules = {}  -- list of { rule, skipped, called }

local function removalGate()
	local ev = Events and Events.OnObjectAboutToBeRemoved
	if type(ev) ~= "table" or type(ev.Add) ~= "function" then return end
	local add, remove = ev.Add, ev.Remove
	local map = {}
	ev.Add = function(fn)
		if type(fn) == "function" and not map[fn] then
			local path = fileOf(fn)
			local rule = nil
			if path then
				for _, r in ipairs(REMOVAL_RULES) do
					if pathEnds(path, r.file) then rule = r break end
				end
			end
			if rule then
				local e = { rule = rule, skipped = 0, called = 0 }
				removalRules[#removalRules + 1] = e
				local kind = rule.skip
				local w = function(object)
					if object then
						local ok, skip = pcall(skipRemoval, kind, object)
						if ok and skip then e.skipped = e.skipped + 1 return end
					end
					e.called = e.called + 1
					return fn(object)
				end
				map[fn] = w
				wrappedOf[w] = fn
				local P = LuaEventProfiler
				if P and P.sourceOf then P.sourceOf[w] = fn end
				print("[ChunkLoadSieve] removals: caught " .. rule.file)
				return add(w)
			end
		end
		return add(fn)
	end
	if type(remove) == "function" then
		ev.Remove = function(fn)
			local w = map[fn]
			if w then map[fn] = nil return remove(w) end
			return remove(fn)
		end
	end
end

if ENABLE_REMOVAL_GATE then removalGate() end

-- Census of the per-chunk events (1.7): handlers are listed and left exactly as they were.
local function censusWrap(eventName)
	local ev = Events and Events[eventName]
	if type(ev) ~= "table" or type(ev.Add) ~= "function" then return end
	local add, remove = ev.Add, ev.Remove
	ev.Add = function(fn)
		if type(fn) == "function" then censusNote(eventName, fn, fileOf(fn), "passed") end
		local r = add(fn)
		if eventName == "LoadChunk" then keepChunkLast() end
		return r
	end
	if type(remove) == "function" then
		ev.Remove = function(fn)
			censusDrop(eventName, fn)
			return remove(fn)
		end
	end
end
censusWrap("LoadChunk")
censusWrap("ReuseGridsquare")
censusWrap("OnObjectAboutToBeRemoved") -- fires for trees and bushes regrowing as chunks load

local ticks = 0
local lastStats = nil
local function onTick()
	ticks = ticks + 1
	-- A tub is registered by a player standing next to it, so its chunk is already loaded; the
	-- set only has to catch up before that chunk loads again.
	if ticks % 30 == 0 then
		refreshTabas(); refreshDamn()
		if started then listsReady = true end
	end
	if ENABLE_LGEE_FAR and farAny then
		nearTicks = nearTicks + 1
		if nearTicks >= NEAR_REFRESH then nearTicks = 0; refreshNear() end
	end

	if STATS_SECONDS <= 0 then return end
	local t = getTimestampMs()
	if not lastStats then lastStats = t return end
	if t - lastStats < STATS_SECONDS * 1000 then return end
	local secs = (t - lastStats) / 1000
	lastStats = t
	lgsMsAll, lgsSquaresAll = lgsMsAll + lgsMs, lgsSquaresAll + lgsSquares
	-- One line, the same in every mode, for comparing runs (1.7).
	print(string.format("[ChunkLoadSieve] timing mode=%s window %.0f s: LoadGridsquare Lua %d ms over %d squares"
		.. " = %.2f ms/s, %.1f us/square; LGEP queue %d ms = %.2f ms/s; since start %d ms over %d squares (%.1f us/square)",
		MODE, secs, lgsMs, lgsSquares, lgsMs / secs, lgsSquares > 0 and lgsMs * 1000 / lgsSquares or 0,
		lgepMs, lgepMs / secs, lgsMsAll, lgsSquaresAll, lgsSquaresAll > 0 and lgsMsAll * 1000 / lgsSquaresAll or 0))
	print(string.format("[ChunkLoadSieve] timing LoadChunk mode=%s window %.0f s: %d ms over %d chunks = %.2f ms/s, %.0f us/chunk",
		MODE, secs, lcMs, lcChunks, lcMs / secs, lcChunks > 0 and lcMs * 1000 / lcChunks or 0))
	lgsMs, lgsSquares, lgepMs, lcMs, lcChunks = 0, 0, 0, 0, 0
	if MODE == "machinery" then
		print(string.format("[ChunkLoadSieve] %d squares in the last %d s; %d handlers called on each", squares, STATS_SECONDS, #held))
	elseif MODE == "full" then
		print(string.format("[ChunkLoadSieve] %d squares in the last %d s; calls per captured handler:", squares, STATS_SECONDS))
	end
	for _, e in ipairs(captured) do
		print(string.format("[ChunkLoadSieve]   %8d  %s", e.calls, e.rule.file))
		e.calls = 0
	end
	if ENABLE_LGEE_DORMANT and lgeeOk then
		print(string.format("[ChunkLoadSieve]   LGEE: %d unplugged generators not filed", lgeeDormant))
		lgeeDormant = 0
	end
	if lgepHandler then
		print(string.format("[ChunkLoadSieve]   LGEP: %d chunk levels read from the queue, %d chunks skipped away from plumbing",
			lgepLevels, lgepColdChunks))
		lgepLevels, lgepColdChunks = 0, 0
	end
	for _, e in ipairs(removalRules) do
		print(string.format("[ChunkLoadSieve]   removals: %s skipped %d, ran %d", e.rule.file, e.skipped, e.called))
		e.skipped, e.called = 0, 0
	end
	if ENABLE_LGEE_FAR and farAny then
		print(string.format("[ChunkLoadSieve]   LGEE: %d far sweep requests dropped, %d near passed (%d cells near)",
			farDropped, farPassed, nearCells))
		farDropped, farPassed = 0, 0
	end
	squares = 0
	for _, e in ipairs(captured) do e.stamp = -1 end
	for _, w in ipairs(watchers) do w.stamp = -1 end
end

-- Targets in another mod's shared folder. Build 42 loads each mod's shared files in mod-list
-- order, so these are caught only when this mod sits above theirs in the list (client and server
-- files load after every shared file, so they are always caught).
-- noServer: the mod never registers it on a dedicated server; noClient: nor on a multiplayer
-- client; feature: it registers only while that feature is on in the mod's settings.
local RCSF = "RC Structure Framework"
local SHARED_TARGETS = {
	{ file = "LGExtendedElectricity/LGEEAgree.lua", mod = "LGExtendedElectricity", name = "LG Extended Electricity" },
	{ file = "RCStructureFramework/RoofPieces.lua", mod = "RCStructureFramework", name = RCSF, feature = true },
	{ file = "RCStructureFramework/SpritePropertyPatcher.lua", mod = "RCStructureFramework", name = RCSF, feature = true },
	-- RoomLighting.lua:284 returns on a dedicated server; TemplateStamp.lua:943 adds only if not isServer().
	{ file = "RCStructureFramework/RoomLighting.lua", mod = "RCStructureFramework", name = RCSF, feature = true, noServer = true },
	{ file = "RCStructureFramework/TemplateStamp.lua", mod = "RCStructureFramework", name = RCSF, noServer = true },
	-- vfx_birthday.lua:67 - registers only if not isClient().
	{ file = "vfx_birthday.lua", mod = "VanillaFoodsExpanded", name = "Vanilla Foods Expanded", noClient = true },
}

local function checkMissed(active)
	local server = isServer and isServer() and true or false
	local client = isClient and isClient() and not server or false
	for _, t in ipairs(SHARED_TARGETS) do
		if active[t.mod] and not (t.noServer and server) and not (t.noClient and client) then
			local seen = false
			for _, c in ipairs(census) do
				if pathEnds(c.path, t.file) then seen = true break end
			end
			if not seen then
				print("[ChunkLoadSieve] missed " .. t.file .. ": move Chunk Load Sieve above " .. t.name .. " in the mod list"
					.. (t.feature and " (unless that feature is turned off in its settings)" or ""))
			end
		end
	end
end

local function printCensus()
	local counts, order = {}, {}
	for _, c in ipairs(census) do
		print("[ChunkLoadSieve] census " .. c.event .. " " .. c.how .. " " .. c.path)
		local k = c.event
		if not counts[k] then counts[k] = {}; order[#order + 1] = k end
		counts[k][c.how] = (counts[k][c.how] or 0) + 1
	end
	local parts = {}
	for _, k in ipairs(order) do
		local hs = {}
		for how, n in pairs(counts[k]) do hs[#hs + 1] = n .. " " .. how end
		table.sort(hs)
		parts[#parts + 1] = k .. " (" .. table.concat(hs, ", ") .. ")"
	end
	print("[ChunkLoadSieve] census: " .. (#parts > 0 and table.concat(parts, "; ") or "no chunk-load handlers"))
end

local function onStart()
	if started then return end   -- OnGameStart and OnServerStarted can both fire
	isServerNow = nil
	netClient = nil
	local names = {}
	for _, e in ipairs(captured) do names[#names + 1] = e.rule.file end
	if lgepHandler then names[#names + 1] = LGEP_FILE .. " (queued)" end
	print("[ChunkLoadSieve] active (" .. VERSION .. ", mode " .. MODE .. (SELF_ID ~= "ChunkLoadSieve" and (", " .. SELF_ID) or "") .. "), " .. #names .. " handlers captured: " .. table.concat(names, ", ")
		.. (MODE == "machinery" and ("; " .. #held .. " held, called on every square") or ""))
	-- Another copy of this mod enabled under a different id (the Workshop copy next to the dev one).
	local active = {}
	pcall(function()
		local list = getActivatedMods()
		for i = 0, list:size() - 1 do
			local id = string.gsub(tostring(list:get(i)), "^\\", "")
			active[id] = true
			if id ~= SELF_ID and (id == "ChunkLoadSieve" or id == "ChunkLoadSieveDev") then
				print("[ChunkLoadSieve] the mod " .. id .. " is also enabled; it stood down because this copy (" .. SELF_ID
					.. ") loaded first. Turn one of them off")
			end
		end
	end)
	if S.modeFromFile then
		print("[ChunkLoadSieve] mode " .. MODE .. " comes from Zomboid/Lua/ChunkLoadSieve_mode.txt"
			.. (MODE ~= "full" and "; the sieve is NOT filtering. Delete that file to turn it back on" or ""))
	end
	printCensus()
	pcall(checkMissed, active)
	for _, c in ipairs(census) do seenOn(c.event)[c.fn] = true end
	started = true
	keepLast()
	keepChunkLast()
	lgsT0, lcT0 = nil, nil
	lcMs, lcChunks = 0, 0
	lgsMs, lgsSquares, lgsMsAll, lgsSquaresAll, lgepMs = 0, 0, 0, 0, 0
	lastStats = getTimestampMs()
	if ENABLE_LGEP_QUEUE and not lgepHandler and LGEP and not (isClient and isClient()) then
		if LGEP_CLP and LGEP_CLP.captured then
			lgepLog("the old LGEP Chunk Load Patch mod is still on and is handling the plumbing scan;"
				.. " turn it off, this does the same job")
		else
			lgepLog("did not find LG Extended Plumbing's square scan; standing down, it runs as usual")
		end
	end
	refreshTabas()
	refreshDamn()
	if ENABLE_LGEE_FAR and farAny then refreshNear() end
end

Events.OnGameStart.Add(onStart)
-- A dedicated server never raises OnGameStart.
if Events.OnServerStarted then Events.OnServerStarted.Add(onStart) end
Events.OnTick.Add(onTick)

S.captured = captured
S.refreshTabas = refreshTabas
S.refreshDamn = refreshDamn
S.refreshNear = refreshNear
S.pruneLgee = pruneLgee

-- Calls onSquare(square) for each loading square that holds an object whose sprite passes
-- test(sprite, name). Each sprite is tested once; register before the world loads.
function S.watch(test, onSquare)
	watchers[#watchers + 1] = { test = test, onSquare = onSquare, stamp = -1 }
	kindOfSprite = {}
	wWatch = true
end
-- Outside full mode there is no object pass to answer from, so watch() is not offered and
-- callers (Hitch Fix) behave as if the sieve were absent.
if MODE ~= "full" then S.watch = nil end
