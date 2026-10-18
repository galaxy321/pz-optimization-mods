-- Test Ground 1.13.0: the crafting-station check (Entity Loop Fix).
require "TestGround/Core"
local TG = TestGroundInternal
if TG.loaded.Station then return end
TG.loaded.Station = true
local S = TG.S
local K, Steps, T, floor, now, point = TG.K, TG.Steps, TG.T, TG.floor, TG.now, TG.point
local split, teleport = TG.split, TG.teleport
function K.stationOk(o)
	local ok, yes = pcall(function()
		return o:hasComponent(ComponentType.CraftBench) or o:hasComponent(ComponentType.DryingLogic)
			or o:hasComponent(ComponentType.DryingCraftLogic) or o:hasComponent(ComponentType.FurnaceLogic)
	end)
	return ok and yes == true
end
function K.stationScript(want)
	local sm = getScriptManager()
	if want then
		local ok, s = pcall(function() return sm:getGameEntityScript(want) end)
		return ok and s or nil, want
	end
	local best, bestName
	pcall(function()
		local all = sm:getAllGameEntities()
		for i = 0, all:size() - 1 do
			local s = all:get(i)
			local name = s:getFullName()
			local bench = s:containsComponent(ComponentType.CraftBench) or s:containsComponent(ComponentType.DryingCraftLogic)
			if bench then
				local dry = string.find(string.lower(name), "dry", 1, true) ~= nil
				if dry then best, bestName = s, name; return end
				if not best then best, bestName = s, name end
			end
		end
	end)
	return best, bestName
end
function K.stationUser(o)
	local ok, u = pcall(function() return o:getUsingPlayer() end)
	if not ok then return "?" end
	return u ~= nil
end
-- A window showing this entity, anywhere in ISEntityUI's tables (its layout isn't known here)
function K.stationWindow(o, root, depth, seen)
	if type(root) ~= "table" or depth > 3 then return nil end
	seen = seen or {}
	if seen[root] then return nil end
	seen[root] = true
	if root.entity == o and type(root.close) == "function" then return root end
	for _, v in pairs(root) do
		local w = K.stationWindow(o, v, depth + 1, seen)
		if w then return w end
	end
	return nil
end
local function yn(v) return v == "?" and "unknown" or (v and "set" or "clear") end
Steps.station = {
	begin = function(r, st)
		local p = r.p
		st.wait = K.STATION_WAIT_S
		local want
		for _, w in ipairs(split(st.text or "", " ")) do
			local k, v = string.match(w, "^(%a+)=(.+)$")
			if k == "wait" and tonumber(v) then st.wait = tonumber(v) end
			if k == "type" then want = v end
		end
		st.notes, st.phase, st.pt = {}, "find", now()
		local spot = point(st.args[2] or "")
		if spot then
			st.at = spot
			teleport(p, spot.x + 2, spot.y, spot.z)
		else
			st.spawn = true
			st.at = { x = floor(p:getX()) + 2, y = floor(p:getY()), z = floor(p:getZ()) }
			st.script, st.typeName = K.stationScript(want)
			if not st.script then st.skip = want and ("no entity type " .. want .. " in the game's scripts") or "no crafting station type found in the game's scripts"; return end
		end
	end,
	tick = function(r, st, t, dt)
		local p, cell = r.p, getCell()
		local sq = cell:getGridSquare(st.at.x, st.at.y, st.at.z)
		local function note(s)
			st.notes[#st.notes + 1] = s
			T.trace("station: " .. s)
		end
		if st.phase == "find" then
			if not sq then
				if t - st.pt > 15000 then st.skip = string.format("the square %d,%d,%d didn't load", st.at.x, st.at.y, st.at.z); return true end
				return false
			end
			if st.spawn then
				local ok, err = K.tryOnce("put down a station", function()
					local o = IsoThumpable.new(cell, sq, K.STATION_SPRITE, false, {})
					GameEntityFactory.CreateIsoObjectEntity(o, st.script, true)
					o:getModData().TestGroundStation = true
					sq:AddSpecialObject(o)
					st.obj = o
				end)
				if not ok or not st.obj then st.skip = "couldn't put down a " .. tostring(st.typeName) .. ": " .. tostring(err or K.broken["put down a station"]); return true end
				note(string.format("put down a %s at %d,%d,%d (in the entity engine: %s)", st.typeName, st.at.x, st.at.y, st.at.z,
					tostring(select(2, pcall(function() return st.obj:isValidEngineEntity() end)))))
			else
				pcall(function()
					local objs = sq:getObjects()
					for i = 0, objs:size() - 1 do
						local o = objs:get(i)
						if K.stationOk(o) then st.obj = o; return end
					end
				end)
				if not st.obj then st.skip = string.format("no crafting station on %d,%d,%d", st.at.x, st.at.y, st.at.z); return true end
				pcall(function() st.typeName = st.obj:getEntityScript():getFullName() end)
				st.typeName = st.typeName or "station"
				note(string.format("found a %s at %d,%d,%d", st.typeName, st.at.x, st.at.y, st.at.z))
			end
			st.phase, st.pt = "open", t
			return false
		end
		local o = st.obj
		if st.phase == "open" then
			if t - st.pt < 1000 then return false end
			if ISEntityUI and ISEntityUI.OpenWindow then
				local ok, res = pcall(ISEntityUI.OpenWindow, p, o)
				if ok then st.openVia, st.window = "the entity window (ISEntityUI.OpenWindow)", type(res) == "table" and res or nil
				else note("ISEntityUI.OpenWindow failed: " .. tostring(res)) end
			end
			st.phase, st.pt = "opened", t
			return false
		end
		if st.phase == "opened" then
			if t - st.pt < 1000 then return false end
			if K.stationUser(o) ~= true then
				-- no window, or one that doesn't set it: what the window does, directly
				if K.tryOnce("setUsingPlayer", function() o:setUsingPlayer(p) end) then
					st.openVia = (st.openVia and st.openVia .. ", which left it clear; then " or "") .. "setUsingPlayer"
				end
			end
			st.afterOpen = K.stationUser(o)
			note("opened via " .. tostring(st.openVia or "nothing") .. "; using player " .. yn(st.afterOpen))
			st.phase, st.pt = "close", t
			return false
		end
		if st.phase == "close" then
			if t - st.pt < 2000 then return false end
			local w = st.window or K.stationWindow(o, ISEntityUI, 0)
			if w then
				local ok = pcall(function() w:close() end)
				st.closeVia = ok and "closing the window" or "the window's close failed"
			else
				st.closeVia = "no window to close"
			end
			st.phase, st.pt = "closed", t
			return false
		end
		if st.phase == "closed" then
			if t - st.pt < 1000 then return false end
			st.afterClose = K.stationUser(o)
			note(st.closeVia .. "; using player " .. yn(st.afterClose))
			local dx = K.STATION_AWAY
			if not cell:getGridSquare(st.at.x + dx, st.at.y, st.at.z) then dx = -dx end
			teleport(p, st.at.x + dx, st.at.y, st.at.z)
			note(string.format("moved %d tiles away; waiting %d s", math.abs(dx), st.wait))
			st.phase, st.pt, st.nextRead = "away", t, t + 1000
			return false
		end
		if st.phase == "away" then
			if t >= st.nextRead then
				st.nextRead = t + 1000
				local u = K.stationUser(o)
				if u == false and not st.clearedAt then
					st.clearedAt = (t - st.pt) / 1000
					note(string.format("using player cleared %.0f s after moving away", st.clearedAt))
				end
			end
			if t - st.pt < st.wait * 1000 then return false end
			local final = K.stationUser(o)
			if st.spawn then
				pcall(function() o:setUsingPlayer(nil) end)
				K.tryOnce("take the station off", function() sq:transmitRemoveItemFromSquare(o) end)
			end
			local home = r.plan.start or r.home
			if home then teleport(p, home.x, home.y, home.z) end
			st.result = string.format("%s at %d,%d,%d (%s): using player %s after opening (via %s), %s after %s; moved %d tiles away, %s",
				st.typeName, st.at.x, st.at.y, st.at.z, st.spawn and "put down for the step, taken off after" or "already there",
				yn(st.afterOpen), tostring(st.openVia or "nothing"), yn(st.afterClose), st.closeVia, K.STATION_AWAY,
				st.clearedAt and string.format("cleared after %.0f s (watched %d s)", st.clearedAt, st.wait)
					or (final == true and string.format("STILL SET after %d s", st.wait) or string.format("%s after %d s", yn(final), st.wait)))
			return true
		end
		return false
	end,
}

-- "fight": real fighting on its own, to iterate on it without the baseline (about 2 minutes).
-- Game speed stays 1: swings are timed in real milliseconds, so fast-forward would change the fight.
K.FIGHT_FILE = "TestGround_fight.txt"
K.FIGHT_PLAN = {
	"# Test Ground real-fight plan: 3, then 6, then 12 zombies, you swing yourself in can't-die mode; then a gun fight",
	"label = fight",
	"start = westpoint",
	"settle = 3",
	"zombies = none",
	"time = 12",
	"weather = clear",
	"measure = 0",
	"god = 0                  # can't-die mode, so hits register",
	"weapon = Base.BaseballBat # item id, or none for bare hands; a weapon mod's id works too",
	"# per step: weapon=<item id> and Perk=level pairs, e.g. step = realfight 6 30 axe_6 weapon=Base.Axe Axe=5 Strength=6",
	"step = realfight 3 25 fight_3",
	"step = realfight 6 30 fight_6",
	"step = realfight 12 40 fight_12",
	"# since 1.12.7: one knocked down every 6 s, so the floor attack (head x3, legs x0.05) is tested",
	"step = realfight 6 40 fight_floor knockdown=6",
	"# since 1.13.2: ranged, a loaded 9 mm pistol, 8 zombies from 15 tiles out (gunfight N S [weapon=] [range=])",
	"step = gunfight 8 40 gun_pistol",
}

K.CHANGES = { run = true, survey = true, baseline = true, fight = true, build = true, treescan = true }
-- "build": Better Building Plus under real conditions (no god mode, real build actions).
K.BUILD_FILE = "TestGround_build.txt"
K.BUILD_PLAN = {
	"# Test Ground build plan: Better Building Plus builds a 3x3 wooden room with a floor and a door",
	"# through its own build actions; then frames standing inside it and gliding past it.",
	"label = build",
	"start = westpoint",
	"settle = 5",
	"zombies = none",
	"time = 12",
	"weather = clear",
	"god = 0",
	"# buildsite = x,y,z     # default: the nearest clear spot to the start",
	"buildspeed = real       # this plan measures the builder itself; fast (x20) or instant when a build is only the setting",
	"step = idle 10 before_build",
	"step = build 3 3 300 build_bbp Woodwork=3",
	"step = visit 20 build_inside",
	"step = passby 30 20 build_pass",
}

TG.yn = yn
