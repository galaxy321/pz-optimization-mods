--
-- Hitch Fix (performance patch).
--
-- Three jobs that each freeze a frame for a few to a few dozen milliseconds, spread out or skipped:
--
-- 1. AmmoMaker's casing clean-up (server/ammomaker_itemCleanUp.lua) runs every ten in-game
--    minutes over a list of every casing ever dropped, re-parsing each entry from a string. An
--    entry whose casing was picked up is never removed, so the list only grows. Here the same
--    clean-up runs a slice of the list per tick, each entry is parsed once, and an entry whose
--    square is loaded but no longer holds its casing is dropped (there is nothing left for it to
--    clean).
--
-- 2. Vanilla farming (SFarmingSystem:checkPlant) checks every plant in one frame every ten
--    in-game minutes. Here the same per-plant checks run a slice of the plants per tick. A pass
--    still running when the next one starts (sleeping, fast-forward) is finished first, so the
--    plants see the same sequence of checks as before.
--
-- 3. Tuna's gun racks and equipment racks each scan every object in 17x17 squares around the
--    player twice a second, even with no rack anywhere near. Here their OnTick handlers are held
--    back while no rack is within reach, and run as before when one is. Rack squares are found by
--    Chunk Load Sieve as chunks load (no extra cost per square), when an object is placed, and by
--    a slow rescan around the player spread one row per tick.
--
-- The handlers are caught as they register (by file name), the same way as Chunk Load Sieve.
-- The file name sorts after "!!!_ChunkLoadSieve.lua" and before every patched mod's files.
--

if HitchFix then return end
HitchFix = {}
local H = HitchFix

local ENABLE_AMMO = true
local ENABLE_FARMING = true
local ENABLE_RACKS = true

local AMMO_PER_TICK = 200   -- casing entries looked at per tick
local PLANTS_PER_TICK = 20  -- plants checked per tick
local RACK_REACH = 9        -- the racks scan 8 squares around the player; one more for big racks
local RESCAN_TICKS = 600    -- how often the area around the player is rescanned for racks

local function say(s) print("[HitchFix] " .. s) end

local function fileOf(fn)
	local P = LuaEventProfiler
	local orig = P and P.originalOf and P.originalOf[fn]
	local ok, name = pcall(getFilenameOfClosure, orig or fn)
	if ok and name then return (string.gsub(tostring(name), "\\", "/")) end
	return nil
end

local function endsWith(path, tail)
	return path ~= nil and #path >= #tail and string.sub(path, -#tail) == tail
end

-- Handler capture --------------------------------------------------------------------------

local wants = {}  -- event name -> list of { file, take = function(fn) -> true if taken }
local takenBy = {} -- fn -> want

local function want(eventName, file, take)
	local list = wants[eventName]
	if not list then
		list = {}
		wants[eventName] = list
		local ev = Events and Events[eventName]
		if type(ev) ~= "table" or type(ev.Add) ~= "function" then return end
		local realAdd, realRemove = ev.Add, ev.Remove
		ev.Add = function(fn)
			if type(fn) == "function" and not takenBy[fn] then
				local path = nil
				for _, w in ipairs(list) do
					if not w.fn then
						path = path or fileOf(fn)
						if endsWith(path, w.file) and w.take(fn) then
							w.fn = fn
							takenBy[fn] = w
							say("caught " .. w.file)
							return
						end
					end
				end
			end
			return realAdd(fn)
		end
		if type(realRemove) == "function" then
			ev.Remove = function(fn)
				local w = takenBy[fn]
				if w then
					takenBy[fn] = nil
					w.fn = nil
					if w.removed then w.removed() end
					return
				end
				return realRemove(fn)
			end
		end
	end
	list[#list + 1] = { file = file, take = take }
end

-- 1. AmmoMaker casings ---------------------------------------------------------------------

local AMMO_ID = "droppedCasings"
local ammo = nil         -- the pass in progress: { t, keys, i, now, life, cell, changed }
local parsed = {}        -- entry string -> { type, x, y, z, time }
local ammoStats = { passes = 0, removed = 0, entries = 0 }
local ammoFault = false

local function ammoAllowed()
	local mode = getWorld():getGameMode()
	return (mode == "Multiplayer" and isServer()) or mode ~= "Multiplayer"
end

local function parse(s)
	local c = parsed[s]
	if c then return c end
	local f = {}
	for field in string.gmatch(s, "([^;]+)") do f[#f + 1] = field end
	c = { f[1], tonumber(f[2]), tonumber(f[3]), tonumber(f[4]), tonumber(f[5]) }
	parsed[s] = c
	return c
end

local function ammoEntry(k)
	local t = ammo.t
	local s = t[k]
	if type(s) ~= "string" then return end
	local c = parse(s)
	if not (c[2] and c[3] and c[4] and c[5]) then return end
	if ammo.now - c[5] <= ammo.life then return end
	local sq = ammo.cell:getGridSquare(c[2], c[3], c[4])
	if not sq then return end   -- not loaded: kept for later, as before
	local wos = sq:getWorldObjects()
	for j = wos:size() - 1, 0, -1 do
		local wo = wos:get(j)
		local item = wo and wo:getItem()
		if item and c[1] == "ammomaker." .. item:getType() then
			sq:transmitRemoveItemFromSquare(wo)
			wo:removeFromWorld()
			wo:removeFromSquare()
			break
		end
	end
	t[k] = nil
	parsed[s] = nil
	ammo.changed = true
	ammoStats.removed = ammoStats.removed + 1
end

local function ammoStep(budget)
	local keys = ammo.keys
	local last = math.min(#keys, ammo.i + budget - 1)
	for i = ammo.i, last do ammoEntry(keys[i]) end
	ammo.i = last + 1
	if ammo.i > #keys then
		if ammo.changed then ModData.add(AMMO_ID, ammo.t) end
		ammo = nil
	end
end

local function ammoRun(budget)
	local ok, err = pcall(ammoStep, budget)
	if not ok then
		ammo = nil
		if not ammoFault then
			ammoFault = true
			say("ERROR in the casing clean-up: " .. tostring(err))
		end
	end
end

local function ammoCleanUp()
	while ammo do ammoRun(math.huge) end   -- a pass still running: finish it first
	if not ammoAllowed() then return end
	local t = ModData.get(AMMO_ID)
	if not t then return end
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	ammoStats.passes = ammoStats.passes + 1
	ammoStats.entries = #keys
	ammo = {
		t = t, keys = keys, i = 1, changed = false,
		now = getWorld():getWorldAgeDays(),
		life = 1 / 24 * SandboxVars.ammomakerOptions.DroppedCasingsLifetime,
		cell = getWorld():getCell(),
	}
end

if ENABLE_AMMO then
	want("EveryTenMinutes", "ammomaker_itemCleanUp.lua", function(fn)
		-- only the version this was written against: it also defines this global
		if type(ammoMakerItemCleanUpAddModData) ~= "function" then return false end
		Events.EveryTenMinutes.Add(ammoCleanUp)
		return true
	end)
end

-- 2. Vanilla farming -------------------------------------------------------------------------

local farm = nil   -- { sys, list, i, phase }
local farmFault = false
local farmStats = { passes = 0, plants = 0 }

local function stillThere(sys, o)
	return o ~= nil and o.x ~= nil and sys:getLuaObjectAt(o.x, o.y, o.z) == o
end

local function snapshot(sys)
	local list = {}
	for i = 1, sys:getLuaObjectCount() do
		local o = sys:getLuaObjectByIndex(i)
		if not o then break end
		list[#list + 1] = o
	end
	return list
end

local function farmStep(budget)
	local sys, list = farm.sys, farm.list
	local n = 0
	while n < budget do
		local i = farm.i
		if i > #list then
			if farm.phase == 1 then
				-- vanilla's second loop (plowFadeCheck) runs over the list as the first left it,
				-- last object first
				local l2 = snapshot(sys)
				local rev = {}
				for j = #l2, 1, -1 do rev[#rev + 1] = l2[j] end
				farm.list, farm.i, farm.phase = rev, 1, 2
				list = rev
			else
				farm = nil
				return
			end
		else
			local o = list[i]
			farm.i = i + 1
			if stillThere(sys, o) then
				if farm.phase == 1 then sys:checkPlant2(o) else sys:plowFadeCheck(o) end
				n = n + 1
			end
		end
	end
end

local function farmRun(budget)
	local ok, err = pcall(farmStep, budget)
	if not ok then
		farm = nil
		if not farmFault then
			farmFault = true
			say("ERROR in the sliced farming check: " .. tostring(err))
		end
	end
end

local function patchFarming()
	local F = SFarmingSystem
	if not ENABLE_FARMING or type(F) ~= "table" or F.__hitchFix then return end
	if type(F.checkPlant) ~= "function" or type(F.checkPlant2) ~= "function"
			or type(F.plowFadeCheck) ~= "function" then return end
	-- only vanilla's own checkPlant, not one another mod put in its place
	if not endsWith(fileOf(F.checkPlant), "Farming/SFarmingSystem.lua") then
		say("farming left alone: checkPlant comes from " .. tostring(fileOf(F.checkPlant)))
		return
	end
	F.__hitchFix = true
	F.checkPlant = function(self)
		while farm do farmRun(math.huge) end
		local list = snapshot(self)
		farmStats.passes = farmStats.passes + 1
		farmStats.plants = #list
		farm = { sys = self, list = list, i = 1, phase = 1 }
	end
	say("farming checks spread over ticks")
end

-- 3. Tuna racks -------------------------------------------------------------------------------

local racks = {}        -- "x,y,z" -> { x, y, z }
local rackCount = 0
local rackHandlers = {} -- { fn, tail }
local rackSprite = {}   -- sprite -> true / false
local nearX, nearY, nearZ, nearValue = nil, nil, nil, false   -- rackNear's answer for this square

local function isRackSprite(spr, name)
	name = name or spr:getName()
	if name and string.sub(name, 1, 19) == "tuna_weaponrack_01_" then return true end
	local props = spr:getProperties()
	return props ~= nil and props:has("TunaERPiece") == true
end

local function rackSpriteCached(spr)
	local v = rackSprite[spr]
	if v == nil then
		local ok, hit = pcall(isRackSprite, spr)
		v = ok and hit == true
		rackSprite[spr] = v
	end
	return v
end

local function addRack(x, y, z)
	local k = x .. "," .. y .. "," .. z
	if not racks[k] then
		racks[k] = { x = x, y = y, z = z }
		rackCount = rackCount + 1
		nearX = nil
	end
end

local function rackSquare(square)
	addRack(square:getX(), square:getY(), square:getZ())
end

local function squareHasRack(sq)
	local objs = sq:getObjects()
	for i = 0, objs:size() - 1 do
		local spr = objs:get(i):getSprite()
		if spr and rackSpriteCached(spr) then return true end
	end
	return false
end

local function rackNear(p)
	local x, y, z = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
	if x == nearX and y == nearY and z == nearZ then return nearValue end
	nearX, nearY, nearZ = x, y, z
	nearValue = false
	if rackCount > 0 then
		for _, r in pairs(racks) do
			if r.z == z and math.abs(r.x - x) <= RACK_REACH and math.abs(r.y - y) <= RACK_REACH then
				nearValue = true
				break
			end
		end
	end
	return nearValue
end

-- Rescan of the area around the player, one row of squares per tick.
local rescan = nil   -- { x, y, z, row }
local function rescanStep()
	local cell = getCell()
	if not cell then rescan = nil return end
	local r = rescan
	local y = r.y + r.row
	for x = r.x - RACK_REACH, r.x + RACK_REACH do
		local sq = cell:getGridSquare(x, y, r.z)
		local k = x .. "," .. y .. "," .. r.z
		if sq and squareHasRack(sq) then
			addRack(x, y, r.z)
		elseif sq and racks[k] then
			racks[k] = nil   -- picked up
			rackCount = rackCount - 1
			nearX = nil
		end
	end
	r.row = r.row + 1
	if r.row > RACK_REACH then rescan = nil end
end

local function racksTick(p, tick)
	if p then
		if not rescan and tick % RESCAN_TICKS == 0 then
			rescan = { x = math.floor(p:getX()), y = math.floor(p:getY()), z = math.floor(p:getZ()), row = -RACK_REACH }
		end
		if rescan then
			local ok = pcall(rescanStep)
			if not ok then rescan = nil end
		end
	end
	local near = p ~= nil and rackNear(p)
	for _, h in ipairs(rackHandlers) do
		if near then
			h.tail = 31   -- after the last rack goes out of reach: one more sweep empties its list
			h.fn()
		elseif h.tail > 0 then
			h.tail = h.tail - 1
			h.fn()
		end
	end
end

if ENABLE_RACKS then
	local function takeRack(fn)
		rackHandlers[#rackHandlers + 1] = { fn = fn, tail = 31 }
		return true
	end
	want("OnTick", "client/Tuna_WeaponRack.lua", takeRack)
	want("OnTick", "client/Tuna_ER_Render.lua", takeRack)

	if ChunkLoadSieve and ChunkLoadSieve.watch then
		ChunkLoadSieve.watch(function(spr, name)
			local hit = isRackSprite(spr, name)
			rackSprite[spr] = hit
			return hit
		end, rackSquare)
	end
	if Events.OnObjectAdded then
		Events.OnObjectAdded.Add(function(o)
			local spr = o and o.getSprite and o:getSprite()
			if spr and rackSpriteCached(spr) then
				local sq = o:getSquare()
				if sq then rackSquare(sq) end
			end
		end)
	end
end

-- Driver ------------------------------------------------------------------------------------

local tick = 0
local lastStats = nil
local function onTick()
	tick = tick + 1
	if ammo then ammoRun(AMMO_PER_TICK) end
	if farm then farmRun(PLANTS_PER_TICK) end
	if #rackHandlers > 0 then
		racksTick(getSpecificPlayer(0), tick)
	end

	local t = getTimestampMs()
	if not lastStats then lastStats = t return end
	if t - lastStats >= 600000 then
		lastStats = t
		say(string.format("casings: %d entries, %d removed in %d passes; farming: %d plants, %d passes; racks known: %d",
			ammoStats.entries, ammoStats.removed, ammoStats.passes, farmStats.plants, farmStats.passes, rackCount))
	end
end

local function onStart()
	patchFarming()
	local caught = {}
	for name, list in pairs(wants) do
		for _, w in ipairs(list) do
			if w.fn then caught[#caught + 1] = w.file end
		end
	end
	say("active (1.0), caught: " .. (#caught > 0 and table.concat(caught, ", ") or "nothing")
		.. (ChunkLoadSieve and ChunkLoadSieve.watch and "; racks found by Chunk Load Sieve" or "; racks found by rescan only"))
end

Events.OnGameStart.Add(onStart)
if Events.OnServerStarted then Events.OnServerStarted.Add(patchFarming) end
Events.OnTick.Add(onTick)

H.stats = function()
	return ammoStats, farmStats, rackCount
end
