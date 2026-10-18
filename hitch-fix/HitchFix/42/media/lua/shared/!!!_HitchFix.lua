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
-- 4. Night Vision Framework checks your worn items every 30 player updates to see whether one is
--    night-vision goggles. For every worn item it makes a dozen Java calls and string searches,
--    about 1.8 ms per check with a full outfit, even with no goggles anywhere. Whether an item
--    is goggles depends only on its item type, so here the answer is remembered per type, and
--    forgotten whenever a mod registers a new goggle type.
--
-- 5. This Is Your Life's journal looks through your whole inventory on every tick for a
--    freshly crafted journal that isn't tagged yet (retryJournalAdoption, the second of the three
--    OnTick handlers in TIYLSurvivorJournal.lua), about 40 microseconds a tick. Here that one
--    handler runs at most every JOURNAL_MS, so a new journal is adopted within a second. The
--    other two run every tick as before. If the file doesn't register exactly three OnTick
--    handlers, nothing is throttled. (1.2 had Take A Bath And Shower's grime moodle here; it is
--    in UI Throttle 1.1 now.)
--
-- 6. Better Building Plus calls require("BetterBuildingPlus/Scaffold").tick() on every tick
--    (server/BetterBuildingPlus/networking/server.lua). Scaffold.tick() itself only does work
--    once a second (its own TICK_MS gate), but the require on every tick goes through the
--    game's Java-side module lookup: about 70-90 microseconds a tick in a profile, 7.5 ms/s.
--    Here that handler runs at most every BBP_TICK_MS, so the scaffold teardown still happens
--    about once a second, at most a quarter of a second later than before.
--
-- 7. A probe, not a fix. LG Extended Electricity's OnTick took about 350 ms on each of four
--    ticks right after a save loaded. For the first PROBE_SECONDS of play this times that
--    handler and, inside it, LGEE.rebuild (its sweep, with the per-tick budget it was given), and
--    prints a line for each slow tick, so the next run shows whether the sweep or the rest of the
--    handler is the slow part. Nothing is changed, and after PROBE_SECONDS the original
--    LGEE.rebuild is put back.
--
-- 8. A second probe, not a fix. In the test save, ISCharacterScreen:render (the Info tab of the
--    character window) cost about 58 ms/s, about 1.1 ms on every UI frame, with the character
--    window closed. For the first PROBE_SECONDS this counts which panels it is drawn for and
--    prints, every 10 s, each one's type, whether it and its parent are visible, and its size, so
--    the next run shows who draws it. Nothing is changed, and the original is put back after.
--
-- 9. (1.8) Inside the probe of part 7: which stage of LG Extended Electricity's sweep is slow.
--    1.7 capped the sweep's work budget, and the four ~350 ms ticks after a load stayed the
--    same at a budget of 100, 2 or 1, so the time is spent after the budgeted walk. LGEE times
--    its own stages (walk, setRelays, publish, fuel line, broadcast) into LGEE.perf when its
--    Debug option is on. For the probe's PROBE_SECONDS this answers that option as on (only
--    that option; LGEE says it "reaches no decision"), and each slow tick's line gets the time
--    per stage, the time outside them, the relay count before and after, and whether another
--    sweep is pending. With Debug on LGEE also prints its own power-decision lines. After
--    PROBE_SECONDS LGEE.getOption is put back. 1.7's cap is gone.
--
-- 10. (1.9) LG Extended Electricity's player-structure walk, remembered for the first minute.
--    1.8 showed the four ~350 ms ticks after a load are all in LGEE's "walk" stage. The one
--    part of that walk its work budget does not split is the walk over player-built
--    structures (walkPlayerStructures), which runs whole once per lap and asks the game's
--    region map about every square of every structure in reach. The four slow ticks are four
--    laps back to back, each asking the same questions. LGEE.visitPlayerStructures takes a
--    place and a range and calls back once per square it finds. For the first
--    LGEE_REGION_SECONDS this remembers those squares per place and range, and a repeat of
--    the same question gets the same squares handed to LGEE's callback without asking the
--    game again. LGEE's own code still decides everything from those squares. What is
--    remembered is dropped whenever an object is added or removed anywhere (building or
--    knocking down a wall changes the structures) and after LGEE_REGION_KEEP_MS in any case,
--    since the game may still be filling in its region map; the four laps come about 0.4 s
--    apart, well inside that. After LGEE_REGION_SECONDS the
--    original is put back. The probe line of part 7 says how many walks were asked and
--    how many answered from memory.
--    1.9's run showed those walks take about 8 ms in all, so this is off by default from 1.10.
--
-- 11. (1.10) Inside the probe of part 7: where in LG Extended Electricity's walk stage the time
--    goes. The walk is LGEE's local advanceWalk: buildings (each building's plan, its relays,
--    then measuring its chunks), the player-structure walk, paid cord runs, every running
--    machine's own circle under the takeover, then what the new relay set lost. Its local
--    functions can't be reached from outside, but the global LGEE functions they call can. For
--    the probe's PROBE_SECONDS, the LGEE functions in LGEE_WALK_FNS (the ones the walk's call
--    tree reaches, from its source) are wrapped. Outside the walk stage a wrapper just calls
--    through. Inside it, each outermost call is counted and timed (the first
--    WALK_TIMED_CALLS calls per tick, then every WALK_SAMPLE_EVERY-th, scaled up), and the
--    time of each function's first and last call since the walk began is kept. Each slow
--    tick's line then lists the costliest functions, the walk time spent in none of them (the
--    walk's own local code and its direct calls into the game), and the order in which the
--    functions were first and last called, which tells which part of the walk the time falls
--    in. Nothing is changed, and the originals are put back after PROBE_SECONDS.
--
-- 12. (1.11) LG Extended Electricity's machine circles, re-used when nothing they depend on
--    changed. 1.10 showed each of the four slow ticks after a load is one call of
--    LGEE.discRegistrations, about 340 to 400 ms. Under LGEE's takeover each running machine
--    lights a circle, and LGEE works out where to put its registrations with a greedy cover
--    (LGEE.cover). LGEE normally translates one pre-worked shape, but when another generator
--    stands on one of that shape's positions it covers that circle the slow way, square by
--    square. It keeps the answer, but drops it whenever a generator is filed or removed
--    anywhere (its generatorEpoch), which happens on each of the first laps as chunks stream
--    in, so the same circle is covered four times. The answer depends only on the call's
--    arguments and on what LGEE's canHost says about each square within the circle's radius
--    plus the engine radius (canHost is passed in, and only refuses squares holding a
--    generator). So this wraps LGEE.discRegistrations and, for a cover (radius above the
--    engine radius, no `out` list), asks canHost about each of those squares first: about
--    2,400 cheap lookups for a 20-tile circle. If every answer matches the ones from the last
--    time the same circle was covered, it hands back a copy of that answer instead of
--    covering again; otherwise it calls the original and keeps what it returns. So the result
--    is always the one LGEE would have worked out. At most LGEE_DISC_KEEP circles are kept.
--    1.12: 1.11's run never matched: each of the four passes saw different answers. So each circle
--    now keeps up to LGEE_DISC_VARIANTS answers, one per set of canHost answers, and a pass that
--    must work one out says why (a circle not seen before, or which squares changed and how).
--    The answers are also kept on disk (Zomboid/Lua/HitchFix_LGEE_circles.txt, as plain numbers
--    that LGEE's own relayKey and chunkKey turn back into registrations) so the next load, which
--    streams the same chunks in the same order, finds them. The file is used only when LGEE's
--    cover gives the same answer on a small fixed test as when the file was written.
--
-- 1.13 (review fixes): a caught handler its mod takes off the event (Tuna's racks, AmmoMaker's
-- clean-up) stops being run, and a re-add runs it once, not twice. The first rack rescan runs
-- when the game starts instead of 10 s in, so a rack beside you at load works without Chunk
-- Load Sieve. Night vision answers are also forgotten every NV_FORGET_MS, in case another mod
-- registers goggles without going through the framework's functions.
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
local ENABLE_NV = true
local ENABLE_TIYL_JOURNAL = true
local ENABLE_BBP_TICK = true
local ENABLE_LGEE_PROBE = true
local ENABLE_CHARSCREEN_PROBE = true
local ENABLE_LGEE_STAGES = true
local ENABLE_LGEE_REGION_CACHE = false  -- 1.9's run: worth about 8 ms per load, off from 1.10
local ENABLE_LGEE_WALK_STEPS = true
local ENABLE_LGEE_DISC_CACHE = true
local ENABLE_LGEE_DISC_FILE = true   -- keep part 12's circle covers on disk between sessions

local AMMO_PER_TICK = 200   -- casing entries looked at per tick
local PLANTS_PER_TICK = 20  -- plants checked per tick
local RACK_REACH = 9        -- the racks scan 8 squares around the player; one more for big racks
local RESCAN_TICKS = 600    -- how often the area around the player is rescanned for racks
local NV_FORGET_MS = 10000  -- night vision: answers are forgotten this often in any case (1.13)
local JOURNAL_MS = 1000     -- This Is Your Life: look for an untagged journal at most this often
local BBP_TICK_MS = 250     -- Better Building Plus: its scaffold tick at most this often (it acts once a second)
local PROBE_SECONDS = 120   -- LG Extended Electricity probe: how long after start it times ticks
local PROBE_SLOW_MS = 30    -- and which ticks it prints
local PROBE_MAX_LINES = 20
local LGEE_REGION_SECONDS = 60  -- LG Extended Electricity: remember its structure walks this long after start
local LGEE_REGION_KEEP_MS = 5000 -- and each answer at most this long (the game's region map may still be filling in)
local LGEE_STAGES = { "  .walk", "  .setRelays", "  .publish", "  .fuel line", "  .broadcast" }
local WALK_TIMED_CALLS = 200   -- LGEE walk steps: time each of a function's first calls per tick,
local WALK_SAMPLE_EVERY = 16   -- then every 16th, counted 16 times
local WALK_LINE_FNS = 6        -- costliest functions named per line
local WALK_ORDER_FNS = 14      -- functions named in the first/last-call order
local LGEE_DISC_KEEP = 64      -- LGEE machine circles kept (part 12)
local LGEE_DISC_VARIANTS = 8   -- and answers kept per circle, one per set of canHost answers seen
local LGEE_DISC_WRITE_MS = 3000 -- written to disk once nothing new has been worked out for this long
-- The LGEE functions LGEE's walk (advanceWalk and what it calls) reaches, from its 42.20 source.
-- getOption, markStart and markEnd are left out (parts 9 and 11 use them), and so are log and logFault.
local LGEE_WALK_FNS = {
	"advanceRelayDiff", "noteRelay", "visitPlayerStructures",
	"discRegistrations", "discPlan", "cover", "stackCover", "stackBands",
	"planCover", "planRelays", "planAllCover", "planAllRelays", "planFloors", "newPlan", "planAdd", "planHost",
	"squareId", "key", "relayKey", "chunkKey", "chunkCoords", "reaches",
	"isRunning", "takeoverActive", "isNight", "streetLightDraw", "applianceDraw",
	"assertLampAt", "lampSquares", "lampWalk", "onLights", "registrationSquares",
	"engineRadius", "engineRange", "exteriorReach", "radius", "rerating", "reratingActive",
	"psrCanBill", "worldHour", "ticksFor", "ticksPerSecond", "acceptSerial",
}

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

local wants = {}  -- event name -> list of { file, take = function(fn, w) -> true if taken }
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
						local taken = endsWith(path, w.file) and w.take(fn, w)
						if taken then
							w.fn = fn
							takenBy[fn] = w
							-- a take that hands back fn itself only counts the handler
							if taken ~= fn then say("caught " .. w.file) end
							-- take may hand back a wrapper to register in the handler's place
							if type(taken) == "function" then
								w.wrapper = taken
								local P = LuaEventProfiler
								if P and P.sourceOf then P.sourceOf[taken] = fn end
								return realAdd(taken)
							end
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
					-- a take that keeps fn itself (racks) or registers its own handler in its place
					-- (casings) undoes that here, so a removed handler stops and a re-add runs once
					local removed = w.removed
					w.removed = nil
					if removed then removed() end
					if w.wrapper then
						local wrapper = w.wrapper
						w.wrapper = nil
						return realRemove(wrapper)
					end
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
	want("EveryTenMinutes", "ammomaker_itemCleanUp.lua", function(fn, w)
		-- only the version this was written against: it also defines this global
		if type(ammoMakerItemCleanUpAddModData) ~= "function" then return false end
		Events.EveryTenMinutes.Add(ammoCleanUp)
		w.removed = function()   -- AmmoMaker took its clean-up off: so does this (1.13)
			Events.EveryTenMinutes.Remove(ammoCleanUp)
			ammo = nil
		end
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
local rescanned = false -- the first rescan runs at once, not RESCAN_TICKS in (1.13)
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
		if not rescan and (tick % RESCAN_TICKS == 0 or not rescanned) then
			rescanned = true
			rescan = { x = math.floor(p:getX()), y = math.floor(p:getY()), z = math.floor(p:getZ()), row = -RACK_REACH }
		end
		if rescan then
			local ok = pcall(rescanStep)
			if not ok then rescan = nil end
		end
	end
	local near = p ~= nil and rackNear(p)
	for _, h in ipairs(rackHandlers) do
		if h.gone then
			-- taken off the event during this loop
		elseif near then
			h.tail = 31   -- after the last rack goes out of reach: one more sweep empties its list
			h.fn()
		elseif h.tail > 0 then
			h.tail = h.tail - 1
			h.fn()
		end
	end
end

if ENABLE_RACKS then
	local function takeRack(fn, w)
		local h = { fn = fn, tail = 31 }
		rackHandlers[#rackHandlers + 1] = h
		-- Tuna took its handler off the event: stop calling it (1.13). A new list, so a handler
		-- removing itself while racksTick goes through the old one doesn't skip the next.
		w.removed = function()
			h.gone = true
			local keep = {}
			for _, o in ipairs(rackHandlers) do if o ~= h then keep[#keep + 1] = o end end
			rackHandlers = keep
		end
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

-- 4. Night Vision Framework --------------------------------------------------------------------

local nvStats = { types = 0 }
local nvByType = {}  -- full type -> true / false
local nvForgotAt = nil

-- Forget every remembered answer. Night Vision Framework's own registrations come through the
-- wrapped functions below; this also covers a mod that writes NV.Shared.REGISTERED_NIGHT_VISION_ITEMS
-- directly or calls a copy of RegisterNightVisionItem saved before the wrap, at the cost of one
-- full check per worn item type every NV_FORGET_MS.
local function nvForget()
	nvByType = {}
	nvStats.types = 0
end

local function patchNV()
	local S = NV and NV.Shared
	if not ENABLE_NV or type(S) ~= "table" or S.__hitchFix then return end
	local orig = S.IsNVTaggedItem
	if type(orig) ~= "function" then return end
	-- only the framework's own function, not one another mod put in its place
	if not endsWith(fileOf(orig), "nvframework_shared.lua") then
		say("night vision left alone: IsNVTaggedItem comes from " .. tostring(fileOf(orig)))
		return
	end
	S.__hitchFix = true
	nvForget()
	S.IsNVTaggedItem = function(item)
		if not item then return false end
		local ft = type(item.getFullType) == "function" and item:getFullType() or nil
		if not ft then return orig(item) end
		local v = nvByType[ft]
		if v == nil then
			v = orig(item) and true or false
			nvByType[ft] = v
			nvStats.types = nvStats.types + 1
		end
		return v
	end
	-- a new goggle type, or the framework clearing its own cache, makes every answer stale
	local function forgetting(name)
		local f = S[name]
		if type(f) ~= "function" then return end
		S[name] = function(...)
			nvForget()
			return f(...)
		end
	end
	forgetting("RegisterNightVisionItem")
	forgetting("ClearScriptNightVisionCache")
	say("night vision goggle check remembered per item type")
end

-- 5. This Is Your Life journal ----------------------------------------------------------------

local TIYL_FILE = "ThisIsYourLife/TIYLSurvivorJournal.lua"
local TIYL_SLOT = 2      -- retryJournalAdoption is the second OnTick handler that file adds
local tiylSeen = 0       -- OnTick handlers that file has added
local tiylOk = false     -- set at game start: the file looks as expected

if ENABLE_TIYL_JOURNAL then
	local function takeTiyl(fn)
		tiylSeen = tiylSeen + 1
		if tiylSeen ~= TIYL_SLOT then return fn end -- registered unchanged
		local lastAt = nil
		return function(...)
			if tiylOk then
				local now = getTimestampMs()
				if lastAt and now >= lastAt and now - lastAt < JOURNAL_MS then return end
				lastAt = now
			end
			return fn(...)
		end
	end
	-- One more than expected, so a fourth handler is noticed and the patch stands down.
	for _ = 1, 4 do want("OnTick", TIYL_FILE, takeTiyl) end
end

-- 6. Better Building Plus scaffold tick -------------------------------------------------------

if ENABLE_BBP_TICK then
	want("OnTick", "BetterBuildingPlus/networking/server.lua", function(fn)
		local lastAt = nil
		return function(...)
			local now = getTimestampMs()
			if lastAt and now >= lastAt and now - lastAt < BBP_TICK_MS then return end
			lastAt = now
			return fn(...)
		end
	end)
end

-- 7. LG Extended Electricity startup probe -------------------------------------------------

local probe = nil  -- { untilMs, sweepMs, budget, lines, slow, worst, origRebuild } while running

local function probeEnd()
	local p = probe
	probe = nil
	if p.origRebuild and LGEE and LGEE.rebuild == p.wrapRebuild then LGEE.rebuild = p.origRebuild end
	if p.origOption and LGEE and LGEE.getOption == p.wrapOption then LGEE.getOption = p.origOption end
	if p.walkUndo then p.walkUndo() end
	say(string.format("LGEE probe done: %d ticks over %d ms, worst %d ms", p.slow, PROBE_SLOW_MS, p.worst))
end

local function probeStart()
	if not ENABLE_LGEE_PROBE or probe then return end
	local p = { untilMs = getTimestampMs() + PROBE_SECONDS * 1000, lines = 0, slow = 0, worst = 0, sweepMs = 0 }
	if type(LGEE) == "table" and type(LGEE.rebuild) == "function" then
		local orig = LGEE.rebuild
		p.origRebuild = orig
		p.wrapRebuild = function(budget, ...)
			local t0 = getTimestampMs()
			local function done(...)
				if probe == p then
					p.sweepMs = p.sweepMs + (getTimestampMs() - t0)
					p.budget = budget
				end
				return ...
			end
			return done(orig(budget, ...))
		end
		LGEE.rebuild = p.wrapRebuild
	end
	-- Part 9: LGEE's own stage timing, by answering its Debug option as on.
	if ENABLE_LGEE_STAGES and type(LGEE) == "table" and type(LGEE.getOption) == "function"
		and type(LGEE.perf) == "table" then
		local origOption = LGEE.getOption
		p.origOption = origOption
		p.wrapOption = function(name, ...)
			if name == "Debug" and probe == p then return true end
			return origOption(name, ...)
		end
		LGEE.getOption = p.wrapOption
	end
	probe = p
	if H.walkStepsStart then H.walkStepsStart(p) end
end

-- Part 9: LGEE.perf totals per stage, and the line that compares two of them.
local function stagesNow(p)
	if not p.wrapOption or type(LGEE) ~= "table" or type(LGEE.perf) ~= "table" then return nil end
	local t = {}
	for i = 1, #LGEE_STAGES do
		local row = LGEE.perf[LGEE_STAGES[i]]
		t[i] = type(row) == "table" and tonumber(row.total) or 0
	end
	return t
end

local function relayCount()
	if type(LGEE) == "table" and type(LGEE.relayCount) == "function" then
		local ok, n = pcall(LGEE.relayCount)
		if ok then return n end
	end
	return nil
end

-- Part 10: LGEE's player-structure walk, remembered for the first minute -------------------

local rc = nil  -- { untilMs, orig, wrapper, entries, walks, walkMs, replays, replayMs } while running

local function regionClear()
	if rc then rc.entries = {} end
end

local function regionEnd()
	local c = rc
	rc = nil
	if LGEE and LGEE.visitPlayerStructures == c.wrapper then LGEE.visitPlayerStructures = c.orig end
	local avg = c.walks > 0 and c.walkMs / c.walks or 0
	say(string.format("LGEE structure walks done: %d asked of the game (%d ms), %d answered from memory (%d ms, about %d ms saved)",
		c.walks, c.walkMs, c.replays, c.replayMs, math.max(0, math.floor(c.replays * avg - c.replayMs + 0.5))))
end

local function regionStart()
	if not ENABLE_LGEE_REGION_CACHE or rc then return end
	if type(LGEE) ~= "table" or type(LGEE.visitPlayerStructures) ~= "function" then
		if type(LGEE) == "table" then say("LG Extended Electricity has no visitPlayerStructures; its structure walk is left alone") end
		return
	end
	local c = { untilMs = getTimestampMs() + LGEE_REGION_SECONDS * 1000, entries = {},
		walks = 0, walkMs = 0, replays = 0, replayMs = 0 }
	local orig = LGEE.visitPlayerStructures
	c.orig = orig
	c.wrapper = function(gx, gy, gz, radius, radiusSquared, vertical, visit, ...)
		if rc ~= c or type(visit) ~= "function" then
			return orig(gx, gy, gz, radius, radiusSquared, vertical, visit, ...)
		end
		local key = tostring(gx) .. "," .. tostring(gy) .. "," .. tostring(gz) .. "," .. tostring(radius)
			.. "," .. tostring(radiusSquared) .. "," .. tostring(vertical)
		local t0 = getTimestampMs()
		local e = c.entries[key]
		if e and t0 - e.atMs > LGEE_REGION_KEEP_MS then
			c.entries[key] = nil
			e = nil
		end
		if e then
			local l = e.list
			for i = 1, #l, 3 do visit(l[i], l[i + 1], l[i + 2]) end
			c.replays = c.replays + 1
			c.replayMs = c.replayMs + (getTimestampMs() - t0)
			return e.walked, e.examined
		end
		local list = {}
		local n = 0
		local function record(x, y, z, ...)
			list[n + 1], list[n + 2], list[n + 3] = x, y, z
			n = n + 3
			return visit(x, y, z, ...)
		end
		local walked, examined = orig(gx, gy, gz, radius, radiusSquared, vertical, record, ...)
		c.walks = c.walks + 1
		c.walkMs = c.walkMs + (getTimestampMs() - t0)
		-- Kept only if nothing was built or knocked down while it ran.
		if rc == c then c.entries[key] = { list = list, walked = walked, examined = examined, atMs = t0 } end
		return walked, examined
	end
	LGEE.visitPlayerStructures = c.wrapper
	rc = c
end

if ENABLE_LGEE_REGION_CACHE then
	Events.OnObjectAdded.Add(regionClear)
	Events.OnObjectAboutToBeRemoved.Add(regionClear)
	if Events.OnTileRemoved then Events.OnTileRemoved.Add(regionClear) end
end

local function regionNow()
	if not rc then return nil end
	return { rc.walks, rc.walkMs, rc.replays, rc.replayMs }
end

local function regionLine(r0)
	local r1 = r0 and regionNow()
	if not r1 then return "" end
	return string.format("; structure walks: %d asked (%d ms), %d from memory (%d ms)",
		r1[1] - r0[1], r1[2] - r0[2], r1[3] - r0[3], r1[4] - r0[4])
end

local function stagesLine(p, before, relays0)
	local after = before and stagesNow(p)
	if not after then return "" end
	local parts, marked = {}, 0
	for i = 1, #LGEE_STAGES do
		local d = (after[i] or 0) - (before[i] or 0)
		marked = marked + d
		parts[#parts + 1] = string.gsub(LGEE_STAGES[i], "^%s*%.", "") .. " " .. d
	end
	local pending = "?"
	if type(LGEE.sweepPending) == "function" then
		local ok, v = pcall(LGEE.sweepPending)
		if ok then pending = v and "yes" or "no" end
	end
	return string.format("; stages: %s, outside them %d ms; relays %s -> %s; another sweep pending: %s",
		table.concat(parts, ", "), p.sweepMs - marked, tostring(relays0), tostring(relayCount()), pending)
end

-- Part 11: which LGEE functions the walk stage spends its time in --------------------------

local ws = nil  -- { tick, touched, walkMs, inWalk, walkT0, firstT0, depth } while the probe runs

local function walkStepsStart(p)
	if not ENABLE_LGEE_WALK_STEPS or type(LGEE) ~= "table"
		or type(LGEE.markStart) ~= "function" or type(LGEE.markEnd) ~= "function" then return end
	local w = { tick = 0, touched = {}, walkMs = 0, inWalk = false, walkT0 = 0, firstT0 = nil, depth = 0 }
	local undo, n = {}, 0
	local function put(name, wrapper)
		local orig = LGEE[name]
		LGEE[name] = wrapper
		undo[#undo + 1] = { name = name, orig = orig, wrapper = wrapper }
	end
	local origStart, origEnd = LGEE.markStart, LGEE.markEnd
	put("markStart", function(name, ...)
		if name == "  .walk" and ws == w then
			w.inWalk, w.depth = true, 0
			w.walkT0 = getTimestampMs()
			if not w.firstT0 then w.firstT0 = w.walkT0 end
		end
		return origStart(name, ...)
	end)
	put("markEnd", function(name, ...)
		if name == "  .walk" and ws == w and w.inWalk then
			w.inWalk = false
			w.walkMs = w.walkMs + (getTimestampMs() - w.walkT0)
		end
		return origEnd(name, ...)
	end)
	for i = 1, #LGEE_WALK_FNS do
		local name = LGEE_WALK_FNS[i]
		local orig = LGEE[name]
		if type(orig) == "function" then
			n = n + 1
			local r = { name = name, tick = -1, calls = 0, ms = 0, sampled = false, first = 0, last = 0 }
			local function finish(t0, weight, ...)
				local t1 = getTimestampMs()
				w.depth = 0
				r.ms = r.ms + (t1 - t0) * weight
				r.last = t1 - w.firstT0
				return ...
			end
			put(name, function(...)
				if ws ~= w or not w.inWalk or w.depth > 0 then return orig(...) end
				if r.tick ~= w.tick then
					r.tick, r.calls, r.ms, r.sampled = w.tick, 0, 0, false
					r.first = getTimestampMs() - w.firstT0
					r.last = r.first
					w.touched[#w.touched + 1] = r
				end
				local c = r.calls + 1
				r.calls = c
				local weight = 1
				if c > WALK_TIMED_CALLS then
					if c % WALK_SAMPLE_EVERY ~= 0 then return orig(...) end
					weight, r.sampled = WALK_SAMPLE_EVERY, true
				end
				w.depth = 1
				return finish(getTimestampMs(), weight, orig(...))
			end)
		end
	end
	p.walkUndo = function()
		if ws == w then ws = nil end
		for i = #undo, 1, -1 do
			local u = undo[i]
			if LGEE[u.name] == u.wrapper then LGEE[u.name] = u.orig end
		end
	end
	p.walkFns = n
	ws = w
end
H.walkStepsStart = walkStepsStart

-- Called as each probed tick starts: forget the last tick's figures.
local function walkTickStart()
	local w = ws
	if not w then return end
	w.tick = w.tick + 1
	w.touched, w.walkMs, w.inWalk, w.firstT0, w.depth = {}, 0, false, nil, 0
end

local function walkLine()
	local w = ws
	if not w or w.walkMs <= 0 and #w.touched == 0 then return "" end
	local list = {}
	for i = 1, #w.touched do list[i] = w.touched[i] end
	table.sort(list, function(a, b) return a.ms > b.ms end)
	local parts, inside = {}, 0
	for i = 1, #list do
		local r = list[i]
		inside = inside + r.ms
		if i <= WALK_LINE_FNS and r.ms > 0 then
			parts[#parts + 1] = string.format("%s %s%d ms (%d calls)", r.name, r.sampled and "about " or "",
				math.floor(r.ms + 0.5), r.calls)
		end
	end
	local order = {}
	for i = 1, #w.touched do list[i] = w.touched[i] end
	table.sort(list, function(a, b) return a.first < b.first end)
	for i = 1, math.min(#list, WALK_ORDER_FNS) do
		local r = list[i]
		order[#order + 1] = string.format("%s %d-%d", r.name, r.first, r.last)
	end
	return string.format("; walk steps (%d ms): %s; in no LGEE function %d ms; first-last call ms: %s",
		w.walkMs, #parts > 0 and table.concat(parts, ", ") or "none over 0 ms",
		math.max(0, math.floor(w.walkMs - inside + 0.5)), #order > 0 and table.concat(order, ", ") or "none")
end

-- Part 12: LGEE's slow circle covers, re-used when every canHost answer is the same ----------

local DISC_FILE = "HitchFix_LGEE_circles.txt"
local dc = nil  -- see discStart

-- Every canHost answer that isn't plain true within `reach` of the centre, in a fixed order.
local function discAnswers(cx, cy, z, reach, canHost)
	local parts, n = {}, 0
	local r2 = reach * reach
	for dy = -reach, reach do
		local y = cy + dy
		for dx = -reach, reach do
			if dx * dx + dy * dy <= r2 then
				local x = cx + dx
				local v = canHost(x, y, z)
				if v ~= true then
					n = n + 1
					parts[n] = x .. "," .. y .. "=" .. tostring(v)
				end
			end
		end
	end
	return table.concat(parts, ";")
end

-- What changed between two answer strings, for the console: "x,y=false new, x,y=false gone".
local function discWhy(old, new)
	local a, b = {}, {}
	for p in string.gmatch(old, "[^;]+") do a[p] = true end
	for p in string.gmatch(new, "[^;]+") do b[p] = true end
	local out, n = {}, 0
	for p in pairs(b) do if not a[p] then n = n + 1 if #out < 4 then out[#out + 1] = p .. " new" end end end
	for p in pairs(a) do if not b[p] then n = n + 1 if #out < 4 then out[#out + 1] = p .. " gone" end end end
	return n .. " changed (" .. table.concat(out, ", ") .. ")"
end

-- A registration list as plain numbers, if LGEE's own stamp (relayKey, chunkKey) rebuilds it exactly.
local function discPack(list)
	local CH = LGEE.CHUNK
	if type(CH) ~= "number" or type(LGEE.relayKey) ~= "function" or type(LGEE.chunkKey) ~= "function" then return nil end
	local nums = {}
	for i = 1, #list do
		local r = list[i]
		for k in pairs(r) do
			if k ~= "x" and k ~= "y" and k ~= "z" and k ~= "kx" and k ~= "ky" and k ~= "key" and k ~= "chunkKey" then return nil end
		end
		for _, k in ipairs({ "x", "y", "z", "kx", "ky" }) do
			local v = r[k]
			if type(v) ~= "number" or v ~= math.floor(v) then return nil end
			nums[#nums + 1] = v
		end
	end
	return nums
end

local function discUnpack(nums)
	local CH, out = LGEE.CHUNK, {}
	for i = 1, #nums, 5 do
		local r = { x = nums[i], y = nums[i + 1], z = nums[i + 2], kx = nums[i + 3], ky = nums[i + 4] }
		r.key = LGEE.relayKey(r)
		r.chunkKey = LGEE.chunkKey(r.kx * CH, r.ky * CH)
		out[#out + 1] = r
	end
	return out
end

local function copyList(list)
	local out = {}
	for i = 1, #list do
		local r, t = list[i], {}
		for k, v in pairs(r) do t[k] = v end
		out[i] = t
	end
	return out
end

local function discWrite(c)
	if not c.fingerprint or type(getFileWriter) ~= "function" then return end
	local ok = pcall(function()
		local w = getFileWriter(DISC_FILE, true, false)
		w:write("HitchFixCircles 1 " .. c.fingerprint .. "\n")
		for key, vs in pairs(c.entries) do
			for i = 1, #vs do
				local v = vs[i]
				if v.nums then
					local s = {}
					for j = 1, #v.nums do s[j] = tostring(v.nums[j]) end
					w:write("C|" .. key .. "|" .. v.sig .. "|" .. table.concat(s, ",") .. "\n")
				end
			end
		end
		w:close()
	end)
	c.dirty = false
	if not ok then say("could not write " .. DISC_FILE .. "; circle covers are kept for this session only") end
end

local function discRead(c)
	if not c.fingerprint or type(getFileReader) ~= "function" then return 0 end
	local n = 0
	pcall(function()
		local r = getFileReader(DISC_FILE, false)
		if not r then return end
		local head = r:readLine()
		if head ~= "HitchFixCircles 1 " .. c.fingerprint then
			r:close()
			if head then say("LGEE circle covers file is from another LGEE version or format; starting afresh") end
			return
		end
		while true do
			local line = r:readLine()
			if not line then break end
			local key, sig, nums = string.match(line, "^C|([^|]*)|([^|]*)|([%d,%-]*)$")
			if key then
				local list = {}
				for v in string.gmatch(nums, "[^,]+") do list[#list + 1] = tonumber(v) end
				if #list % 5 == 0 then
					local vs = c.entries[key]
					if not vs then vs = {}; c.entries[key] = vs; c.count = c.count + 1 end
					vs[#vs + 1] = { sig = sig, nums = list, fromFile = true }
					n = n + 1
				end
			end
		end
		r:close()
	end)
	return n
end

local function discStart()
	if not ENABLE_LGEE_DISC_CACHE or dc then return end
	if type(LGEE) ~= "table" then return end
	if type(LGEE.discRegistrations) ~= "function" then
		say("LG Extended Electricity has no discRegistrations; its circle covers are left alone")
		return
	end
	local c = { entries = {}, count = 0, worked = 0, workedMs = 0, reused = 0, fromFile = 0, checkMs = 0,
		missNew = 0, missChanged = 0, whys = {}, lastWhy = nil, dirty = false, changedAt = 0 }
	local orig = LGEE.discRegistrations
	c.orig = orig
	-- LGEE's cover on a small fixed input, so answers kept on disk are only used with the same cover code.
	if ENABLE_LGEE_DISC_FILE then
		local ok, fp = pcall(function()
			local regs = orig(1000003, 1000005, 0, 3, 2, function() return true end)
			local s = {}
			for i = 1, #regs do
				local r = regs[i]
				s[#s + 1] = tostring(r.x) .. "." .. tostring(r.y) .. "." .. tostring(r.kx) .. "." .. tostring(r.ky) .. "." .. tostring(r.key)
			end
			return tostring(LGEE.CHUNK) .. "/" .. tostring(LGEE.COVER_MAX_RADIUS) .. "/" .. table.concat(s, ";")
		end)
		if ok and type(fp) == "string" and not string.find(fp, "[|\n]") then c.fingerprint = fp end
		c.loaded = discRead(c)
	end
	c.wrapper = function(cx, cy, z, r, engine, canHost, out, ...)
		if dc ~= c or out ~= nil or type(canHost) ~= "function" or type(r) ~= "number"
			or type(engine) ~= "number" or r <= engine then
			return orig(cx, cy, z, r, engine, canHost, out, ...)
		end
		local t0 = getTimestampMs()
		local ok, sig = pcall(discAnswers, cx, cy, z, r + engine + 1, canHost)
		if not ok then return orig(cx, cy, z, r, engine, canHost, out, ...) end
		local key = tostring(cx) .. "," .. tostring(cy) .. "," .. tostring(z) .. "," .. tostring(r)
			.. "," .. tostring(engine)
		local vs = c.entries[key]
		local hit = nil
		if vs then
			for i = 1, #vs do
				if vs[i].sig == sig then hit = vs[i] break end
			end
		end
		if hit then
			local list = hit.list and copyList(hit.list) or discUnpack(hit.nums)
			hit.used = t0
			c.reused = c.reused + 1
			if hit.fromFile then c.fromFile = c.fromFile + 1 end
			c.checkMs = c.checkMs + (getTimestampMs() - t0)
			return list
		end
		-- Why it has to be worked out: a circle not seen before, or what changed since the last time.
		if vs and #vs > 0 then
			local last = vs[1]
			for i = 2, #vs do if (vs[i].used or 0) > (last.used or 0) then last = vs[i] end end
			c.missChanged = c.missChanged + 1
			c.lastWhy = "circle at " .. key .. ": " .. discWhy(last.sig, sig)
		else
			c.missNew = c.missNew + 1
			c.lastWhy = "circle at " .. key .. ": not seen before"
		end
		if #c.whys < 6 then c.whys[#c.whys + 1] = c.lastWhy end
		local t1 = getTimestampMs()
		c.checkMs = c.checkMs + (t1 - t0)
		local result = orig(cx, cy, z, r, engine, canHost, out, ...)
		c.worked = c.worked + 1
		c.workedMs = c.workedMs + (getTimestampMs() - t1)
		if type(result) == "table" then
			if not vs then
				if c.count >= LGEE_DISC_KEEP then c.entries, c.count = {}, 0 end
				vs = {}
				c.entries[key] = vs
				c.count = c.count + 1
			end
			if #vs >= LGEE_DISC_VARIANTS then
				local oldest = 1
				for i = 2, #vs do if (vs[i].used or 0) < (vs[oldest].used or 0) then oldest = i end end
				table.remove(vs, oldest)
			end
			local nums = discPack(result)
			table.insert(vs, 1, { sig = sig, nums = nums, list = (not nums) and copyList(result) or nil, used = t1 })
			if nums then c.dirty, c.changedAt = true, t1 end
		end
		return result
	end
	LGEE.discRegistrations = c.wrapper
	dc = c
end

-- Called every tick: write the file once nothing new has been worked out for a few seconds.
local function discTick(now)
	local c = dc
	if c and c.dirty and now - c.changedAt >= LGEE_DISC_WRITE_MS then discWrite(c) end
end

local function discNow()
	if not dc then return nil end
	return { dc.worked, dc.workedMs, dc.reused, dc.checkMs, dc.fromFile, dc.lastWhy }
end

local function discLine(d0)
	local d1 = d0 and discNow()
	if not d1 or d1[1] == d0[1] and d1[3] == d0[3] then return "" end
	local s = string.format("; circle covers: %d worked out (%d ms), %d re-used (%d from file; %d ms checking)",
		d1[1] - d0[1], d1[2] - d0[2], d1[3] - d0[3], d1[5] - d0[5], d1[4] - d0[4])
	if d1[1] > d0[1] and d1[6] then s = s .. "; worked out because " .. d1[6] end
	return s
end

local discReportAt = nil
local function discReport()
	discReportAt = nil
	if not dc then return end
	say(string.format("LGEE circle covers so far: %d worked out (%d ms; %d not seen before, %d with changed answers), %d re-used (%d from file, %d ms checking); %d kept from file at start",
		dc.worked, dc.workedMs, dc.missNew, dc.missChanged, dc.reused, dc.fromFile, dc.checkMs, dc.loaded or 0))
	for i = 1, #dc.whys do say("  worked out because " .. dc.whys[i]) end
end

if ENABLE_LGEE_PROBE then
	want("OnTick", "LGExtendedElectricity/LGEEGrid.lua", function(fn)
		return function(...)
			local p = probe
			if not p then return fn(...) end
			p.sweepMs, p.budget = 0, nil
			local before = stagesNow(p)
			local relays0 = relayCount()
			local regions0 = regionNow()
			local discs0 = discNow()
			walkTickStart()
			local t0 = getTimestampMs()
			local function done(...)
				local now = getTimestampMs()
				local spent = now - t0
				if spent > p.worst then p.worst = spent end
				if spent >= PROBE_SLOW_MS then
					p.slow = p.slow + 1
					if p.lines < PROBE_MAX_LINES then
						p.lines = p.lines + 1
						say(string.format("LGEE probe: tick %d ms, sweep %d ms (budget %s), rest %d ms",
							spent, p.sweepMs, p.budget and tostring(p.budget) or "-", spent - p.sweepMs)
							.. stagesLine(p, before, relays0) .. walkLine() .. regionLine(regions0) .. discLine(discs0))
					end
				end
				if now >= p.untilMs then probeEnd() end
				return ...
			end
			return done(fn(...))
		end
	end)
end

-- 8. Character screen probe -----------------------------------------------------------------

local cs = nil  -- { untilMs, nextMs, orig, wrapper, seen = { [self] = calls } } while running

local function csDescribe(o)
	if type(o) ~= "table" then return tostring(o) end
	local function ask(f) local ok, v = pcall(f) return ok and tostring(v) or "?" end
	local parent = o.parent
	return string.format("%s visible=%s reallyVisible=%s at %s,%s size %sx%s, parent %s (visible=%s)",
		tostring(o.Type), ask(function() return o:isVisible() end), ask(function() return o:isReallyVisible() end),
		ask(function() return o:getAbsoluteX() end), ask(function() return o:getAbsoluteY() end),
		ask(function() return o:getWidth() end), ask(function() return o:getHeight() end),
		type(parent) == "table" and tostring(parent.Type) or "none",
		type(parent) == "table" and ask(function() return parent:isVisible() end) or "-")
end

local function csEnd()
	local c = cs
	cs = nil
	if ISCharacterScreen and ISCharacterScreen.render == c.wrapper then ISCharacterScreen.render = c.orig end
	say("character screen probe done")
end

local function csStart()
	if not ENABLE_CHARSCREEN_PROBE or cs then return end
	if type(ISCharacterScreen) ~= "table" or type(ISCharacterScreen.render) ~= "function" then return end
	local now = getTimestampMs()
	local c = { untilMs = now + PROBE_SECONDS * 1000, nextMs = now + 10000, seen = {}, n = 0 }
	c.orig = ISCharacterScreen.render
	c.wrapper = function(self, ...)
		local p = cs
		if p == c then
			p.n = p.n + 1
			p.seen[self] = (p.seen[self] or 0) + 1
		end
		return c.orig(self, ...)
	end
	ISCharacterScreen.render = c.wrapper
	cs = c
end

local function csTick()
	local c = cs
	if not c then return end
	local now = getTimestampMs()
	if now < c.nextMs then return end
	c.nextMs = now + 10000
	say("character screen probe: " .. c.n .. " draws in 10 s")
	for o, n in pairs(c.seen) do
		say("  " .. n .. " x " .. csDescribe(o))
	end
	c.n, c.seen = 0, {}
	if now >= c.untilMs then csEnd() end
end

-- Driver ------------------------------------------------------------------------------------

local tick = 0
local lastStats = nil
local function onTick()
	tick = tick + 1
	if tick == 1 then csStart() end
	if cs then csTick() end
	if rc and getTimestampMs() >= rc.untilMs then regionEnd() end
	if discReportAt and getTimestampMs() >= discReportAt then discReport() end
	if dc then discTick(getTimestampMs()) end
	if ammo then ammoRun(AMMO_PER_TICK) end
	if farm then farmRun(PLANTS_PER_TICK) end
	if #rackHandlers > 0 then
		racksTick(getSpecificPlayer(0), tick)
	end

	local t = getTimestampMs()
	if ENABLE_NV then
		if not nvForgotAt or t < nvForgotAt then nvForgotAt = t
		elseif t - nvForgotAt >= NV_FORGET_MS then nvForgotAt = t; nvForget() end
	end
	if not lastStats then lastStats = t return end
	if t - lastStats >= 600000 then
		lastStats = t
		say(string.format("casings: %d entries, %d removed in %d passes; farming: %d plants, %d passes; racks known: %d; night vision item types: %d",
			ammoStats.entries, ammoStats.removed, ammoStats.passes, farmStats.plants, farmStats.passes, rackCount, nvStats.types))
	end
end

local function onStart()
	discStart()
	if dc then discReportAt = getTimestampMs() + PROBE_SECONDS * 1000 end
	probeStart()
	regionStart()
	patchFarming()
	patchNV()
	if ENABLE_TIYL_JOURNAL and tiylSeen > 0 then
		tiylOk = tiylSeen == 3
		if not tiylOk then
			say("This Is Your Life's journal added " .. tiylSeen .. " tick handlers, not the 3 this was written for; left alone")
		end
	end
	local caught, listed = {}, {}
	for name, list in pairs(wants) do
		for _, w in ipairs(list) do
			if w.fn and w.wrapper ~= w.fn and not listed[w.file]
				and (w.file ~= TIYL_FILE or tiylOk) then
				listed[w.file] = true
				caught[#caught + 1] = w.file
			end
		end
	end
	if probe and probe.wrapOption then caught[#caught + 1] = "LGEE stage timing" end
	if dc then caught[#caught + 1] = "LGEE circle covers re-used (" .. (dc.loaded or 0) .. " from file)" end
	if probe and probe.walkFns then caught[#caught + 1] = "LGEE walk steps (" .. probe.walkFns .. " functions)" end
	if rc then caught[#caught + 1] = "LGEE structure walks (first minute)" end
	say("active (1.13), caught: " .. (#caught > 0 and table.concat(caught, ", ") or "nothing")
		.. (ChunkLoadSieve and ChunkLoadSieve.watch and "; racks found by Chunk Load Sieve" or "; racks found by rescan only"))
end

Events.OnGameStart.Add(onStart)
if Events.OnServerStarted then Events.OnServerStarted.Add(patchFarming) end
Events.OnTick.Add(onTick)

H.stats = function()
	return ammoStats, farmStats, rackCount
end
