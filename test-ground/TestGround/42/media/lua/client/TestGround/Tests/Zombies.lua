-- Test Ground 1.13.0: zombie count: stress and the natural zone.
require "TestGround/Core"
local TG = TestGroundInternal
if TG.loaded.Zombies then return end
TG.loaded.Zombies = true
local S = TG.S
local K, Steps, T, busy, floor, isDead = TG.K, TG.Steps, TG.T, TG.busy, TG.floor, TG.isDead
local near, removeZombies, teleport, try, walkTo, zombiesList = TG.near, TG.removeZombies, TG.teleport, TG.try, TG.walkTo, TG.zombiesList
Steps.stress = {
	begin = function(r, st)
		st.count = math.max(1, floor(st.a or 500))
		st.seconds = st.b or 60
		st.dist = tonumber(st.args[4]) or 20
		r.holdSweep = true
		removeZombies()
		-- ghost mode: the noise draws them and they crowd round, but they don't attack, so 500 of
		-- them can't pull you down (the 1.8.0 check lost its player to a much smaller crowd)
		pcall(function() r.p:setGhostMode(true) end)
		local home = r.plan.start
		if home and not near(r.p, home, 3) then teleport(r.p, home.x, home.y, home.z) end
		st.c = { x = floor(r.p:getX()), y = floor(r.p:getY()), z = floor(r.p:getZ()) }
		st.made, st.peakAlive, st.peakSeen, st.heals, st.guardKills = 0, 0, 0, 0, 0
		st.nextLure = 0
	end,
	tick = function(r, st, t)
		local el = t - st.t0
		TG.cantDie(r, st)
		if st.made < st.count then
			for _ = 1, math.min(K.STRESS_BATCH, st.count - st.made) do
				st.made = st.made + 1
				r.spawnedZombies = true
				local a = st.made * 2.39996   -- golden angle: an even ring whatever N is
				local d = st.dist + (st.made % 16)
				local x, y = floor(st.c.x + math.cos(a) * d), floor(st.c.y + math.sin(a) * d)
				try("spawn zombie", function()
					addZombiesInOutfit(x, y, st.c.z, 1, nil, 50, false, false, false, false, false, false, 1, false, 0, false, false)
				end)
			end
			if st.made >= st.count then
				st.spawnedMs = el
				T.trace(string.format("stress: %d spawned in %.1f s", st.count, el / 1000))
			end
		end
		if el >= st.nextLure then
			st.nextLure = el + TG.FIGHT_LURE_MS
			local list = zombiesList()
			TG.lure(r.p, list)
			local alive = TG.aliveCount()
			if alive > st.peakAlive then st.peakAlive = alive end
			local seen = TG.visibleZombies(r.p)
			if seen and seen > st.peakSeen then st.peakSeen = seen end
			T.trace(string.format("stress: %d alive, %s seen", alive, tostring(seen)))
		end
		if el >= st.seconds * 1000 then
			local alive = TG.aliveCount()
			local removed = removeZombies()
			local bodies = TG.removeCorpses(st.c, 45)
			r.holdSweep = false
			pcall(function() r.p:setGhostMode(false) end)
			TG.keepAlive(r.p)
			st.result = string.format("%d of %d spawned (in %.1f s), up to %d alive and %d seen at once, %d still up at the end; %s; %d removed, %d bodies cleared",
				st.made, st.count, (st.spawnedMs or el) / 1000, st.peakAlive, st.peakSeen, alive,
				st.guarding and string.format("can't-die mode gave way (%s), %d put down after that", st.guarding, st.guardKills) or
					string.format("can't-die mode held (%d heals)", st.heals),
				removed, bodies)
			return true
		end
		return false
	end,
}

-- weapon = <item id> (1.9.4; default Base.BaseballBat, "none" for bare hands): spawned once per
-- run into the inventory and held in both hands for real fights, taken away at the end of the run.
K.DEFAULT_WEAPON = "Base.BaseballBat"
-- A step may say weapon=<id> and Perk=level pairs (Blunt=0 LongBlunt=5 Strength=8 ...) after its
-- numbers, so one plan compares weapons and skill levels step by step; skill levels are put back
-- at the end of the run.

Steps.natural = {
	begin = function(r, st)
		st.seconds = st.a or 60
		st.mode = (st.args[3] == "run" or st.args[2] == "run") and "run" or "stand"
		st.ring = tonumber(st.args[4]) or 25
		local z = r.plan.zone or r.plan.start
		if not z then st.skip = "no zone in the plan (zone = x,y,z; the survey writes TestGround_natural.txt)"; return end
		if not near(r.p, z, 3) then teleport(r.p, z.x, z.y, z.z) end
		pcall(function() r.p:setGhostMode(false) end)
		st.c = { x = z.x, y = z.y, z = z.z or 0 }
		st.intensity = nil
		pcall(function() st.intensity = getWorld():getMetaGrid():getChunkDataFromTile(z.x, z.y):getZombieIntensity() end)
		st.heals, st.guardKills, st.legs, st.peakNear, st.peakSeen = 0, 0, 0, 0, 0
		st.guarding = "natural zombies are always guarded"
		st.nextNoise, st.nextCount, st.leg = 0, 0, 0
	end,
	tick = function(r, st, t)
		local el = t - st.t0
		if el >= st.nextCount then
			st.nextCount = el + 1000
			local px, py, n = r.p:getX(), r.p:getY(), 0
			for _, z in ipairs(zombiesList()) do
				if not isDead(z) then
					local dx, dy = z:getX() - px, z:getY() - py
					if dx * dx + dy * dy < 40 * 40 then n = n + 1 end
				end
			end
			if n > st.peakNear then st.peakNear = n end
			local seen = TG.visibleZombies(r.p)
			if seen and seen > st.peakSeen then st.peakSeen = seen end
		end
		TG.cantDie(r, st)   -- after the count, so the ones it puts down are counted first
		if el >= st.nextNoise then
			st.nextNoise = el + 4000
			K.tryOnce("addSound", function() getWorldSoundManager():addSound(r.p, floor(r.p:getX()), floor(r.p:getY()), floor(r.p:getZ()), K.NATURAL_NOISE, K.NATURAL_NOISE) end)
		end
		if st.mode == "run" and not busy(r.p) then
			st.leg = st.leg + 1
			local a = st.leg * math.pi / 3
			local x, y = floor(st.c.x + math.cos(a) * st.ring), floor(st.c.y + math.sin(a) * st.ring)
			K.tryOnce("setRunning", function() r.p:setRunning(true) end)
			K.tryOnce("setPathfindRunning", function() r.p:setPathfindRunning(true) end)
			if walkTo(r.p, x, y, st.c.z) then st.legs = st.legs + 1 end
		end
		if el >= st.seconds * 1000 then
			ISTimedActionQueue.clear(r.p)
			K.tryOnce("setRunning", function() r.p:setRunning(false) end)
			K.tryOnce("setPathfindRunning", function() r.p:setPathfindRunning(false) end)
			TG.keepAlive(r.p)
			st.result = string.format("%s at %d,%d (zombie intensity there %s), up to %d zombies within 40 tiles and %d seen at once, %d put down as they came within 2.2 tiles%s, %d heals",
				st.mode == "run" and string.format("ran %d legs round a %d-tile ring", st.legs, st.ring) or "stood",
				st.c.x, st.c.y, st.intensity and string.format("%.2f", st.intensity) or "unknown",
				st.peakNear, st.peakSeen, st.guardKills, st.healFailed and ", HEALING FAILED" or "", st.heals)
			return true
		end
		return false
	end,
}

-- loot: for each loot point, walk next to the container (vanilla luautils.walkAdj), wait while
-- the loot window shows it (containers fill on first look), then move up to 3 items into your
-- inventory and back with vanilla transfer actions, so the save keeps its loot between runs.


