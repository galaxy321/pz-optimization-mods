-- Test Ground 1.13.2: ranged fighting: the gun fight.
require "TestGround/Core"
require "TestGround/Tests/Melee"
local TG = TestGroundInternal
if TG.loaded.Gun then return end
TG.loaded.Gun = true
local K, Steps, T, floor, isDead = TG.K, TG.Steps, TG.T, TG.floor, TG.isDead
local near, now, removeZombies, teleport, try, zombiesList = TG.near, TG.now, TG.removeZombies, TG.teleport, TG.try, TG.zombiesList

-- gunfight N S: N zombies spawned in a ring K.GUN_RANGE tiles out (range=R to change it) come at
-- you; you stand and shoot them with the plan's gun (default K.GUN_WEAPON, a 9 mm pistol, loaded),
-- aiming and firing through the attack input like a player, in "can't die" mode. Ammo is topped up
-- by script when the gun runs dry (counted as reloads, so the reload animation isn't measured), a
-- jam is cleared the same way. At most K.GUN_CROWD at arm's length (the rest are put down). The
-- shots are loud: the world's own zombies are kept away by the usual sweep.
K.GUN_WEAPON = "Base.Pistol"
K.GUN_RANGE = 15
K.GUN_CROWD = 1
K.GUN_GROUP = "ranged"
-- 1.13.10 (1.13.2's gunfight: 2 hits in 101 shots, none past a tile). In build 42 a shot goes where
-- the reticle is (BallisticsController reads the mouse; the target must be within 2.75 tiles of it
-- or of the muzzle line), not where the player faces, and accuracy drops with the aiming delay,
-- which only falls while aiming and climbs with each shot. So: the mouse is put on the target's
-- chest every tick, and a shot waits until the aiming delay is down (or K.GUN_AIM_WAIT_MS passed).
K.GUN_AIM_DELAY_OK = 1      -- fire once getAimingDelay() is at or below this
K.GUN_AIM_WAIT_MS = 1500    -- or after this long aiming at the same target
K.GUN_CHEST_Z = 0.5         -- the mouse goes this far above the zombie's feet
-- Puts the mouse on the zombie; returns true when the game took it (the mouse reads back near it).
function K.gunMouseOn(p, z)
	local ok, hit = pcall(function()
		local pn = p:getPlayerNum()
		local zz = (z.getZ and z:getZ() or p:getZ()) + K.GUN_CHEST_Z
		local x = isoToScreenX(pn, z:getX(), z:getY(), zz)
		local y = isoToScreenY(pn, z:getX(), z:getY(), zz)
		setMouseXY(floor(x), floor(y))
		return math.abs(getMouseX() - floor(x)) <= 2 and math.abs(getMouseY() - floor(y)) <= 2
	end)
	return ok and hit, (not ok) and tostring(hit) or nil
end
K.GROUPS[K.GUN_GROUP] = K.GROUPS[K.GUN_GROUP] or {}
table.insert(K.GROUPS[K.GUN_GROUP], "gunfight")

local function gunOpts(st)
	local o = K.stepOpts(st)
	for w in string.gmatch(st.text or "", "%S+") do
		local k, v = string.match(w, "^([%w_]+)=(%S+)$")
		if k and string.lower(k) == "range" and tonumber(v) then o.range = math.max(3, tonumber(v)) end
	end
	-- stepOpts reads any Perk=number pair as a skill; range isn't one
	local skills = {}
	for _, sk in ipairs(o.skills) do if string.lower(sk.name) ~= "range" then skills[#skills + 1] = sk end end
	o.skills = skills
	return o
end

-- Full magazine, round chambered, not jammed. Returns true when anything had to be done.
function K.gunLoad(w)
	local did = false
	pcall(function()
		local max = w:getMaxAmmo()
		if max and max > 0 and w:getCurrentAmmoCount() <= 0 then
			w:setCurrentAmmoCount(max)
			did = true
		end
		if w.setContainsClip and w.isContainsClip and not w:isContainsClip() then w:setContainsClip(true); did = true end
		if w.haveChamber and w:haveChamber() and not w:isRoundChambered() then w:setRoundChambered(true); did = true end
	end)
	return did
end
function K.gunUnjam(w)
	local ok, jam = pcall(function() return w:isJammed() end)
	if ok and jam then pcall(function() w:setJammed(false) end); return true end
	return false
end

local function spawnRing(c, count, radius)
	if TG.S.run then TG.S.run.spawnedZombies = true end
	for i = 1, count do
		local angle = (i / count) * 2 * math.pi
		local x = floor(c.x + math.cos(angle) * radius)
		local y = floor(c.y + math.sin(angle) * radius)
		try("spawn zombie", function()
			addZombiesInOutfit(x, y, c.z, 1, nil, 50, false, false, false, false, false, false, 1, false, 0, false, false)
		end)
	end
end

function K.gunHook(r, st)
	st.ghooks = {}
	local p = r.p
	local function add(name, fn)
		if Events[name] and Events[name].Add then Events[name].Add(fn); st.ghooks[name] = fn end
	end
	add("OnWeaponSwing", function(c)
		if c ~= p then return end
		st.shots = st.shots + 1
		st.swungAt = now()
	end)
	add("OnWeaponHitCharacter", function(w, target, weapon, dmg)
		if w ~= p then return end
		st.hits = st.hits + 1
		st.dmg = st.dmg + (tonumber(dmg) or 0)
		pcall(function()
			local d = math.sqrt((target:getX() - p:getX()) ^ 2 + (target:getY() - p:getY()) ^ 2)
			st.hitDist = st.hitDist + d
			if d > st.farHit then st.farHit = d end
		end)
	end)
end
function K.gunUnhook(st)
	for name, fn in pairs(st.ghooks or {}) do pcall(function() Events[name].Remove(fn) end) end
	st.ghooks = {}
end

Steps.gunfight = {
	begin = function(r, st)
		st.count = math.max(1, floor(st.a or 8))
		st.seconds = st.b or 40
		local o = gunOpts(st)
		st.aim = string.find(" " .. (st.text or "") .. " ", " aim=face ", 1, true) and "face" or "mouse"
		st.range = o.range or K.GUN_RANGE
		r.holdSweep = true
		removeZombies()
		pcall(function() r.p:setGhostMode(false) end)
		local home = r.plan.start
		if home and not near(r.p, home, 3) then teleport(r.p, home.x, home.y, home.z) end
		local c = { x = floor(r.p:getX()), y = floor(r.p:getY()), z = floor(r.p:getZ()) }
		st.c = c
		spawnRing(c, st.count, st.range)
		r.fightAt, r.fightRadius = c, st.range + 10
		st.mine = {}
		for _, z in ipairs(zombiesList()) do st.mine[#st.mine + 1] = z end
		st.spawned = #st.mine
		st.shots, st.hits, st.dmg, st.hitDist, st.farHit, st.reloads, st.unjams, st.attempts = 0, 0, 0, 0, 0, 0, 0, 0
		st.heals, st.nextLure = 0, 500
		st.mouseSet, st.mouseMiss, st.delaySum, st.delayN, st.waitedOut = 0, 0, 0, 0, 0
		pcall(function() st.mouse0 = { getMouseX(), getMouseY() } end)   -- 1.13.11: put back at the end
		st.weapon = K.armWeapon(r, st, o.weapon or K.GUN_WEAPON)
		st.skillSet = K.setSkills(r, o.skills)
		local w = r.weaponItem
		st.ranged = false
		if w then pcall(function() st.ranged = w:isRanged() == true end) end
		if w and st.ranged then K.gunLoad(w) end
		pcall(function() st.maxRange = w and w:getMaxRange(r.p) end)
		st.maxRange = tonumber(st.maxRange) or st.range
		pcall(function() st.weapon = st.weapon .. " (" .. tostring(w:getDisplayName()) .. ")" end)
		st.hits0 = r.hitsTaken or 0
		local okK, k0 = K.tryOnce("zombie kills", function() return r.p:getZombieKills() end)
		st.kills0 = okK and k0 or nil
		K.gunHook(r, st)
		if not st.ranged then T.trace("gunfight: " .. tostring(st.weapon) .. " isn't a ranged weapon; it is swung like a melee one") end
	end,
	tick = function(r, st, t)
		local el = t - st.t0
		local p = r.p
		TG.cantDie(r, st)
		st.thinned = (st.thinned or 0) + K.crowdCap(p, K.GUN_CROWD)
		if not st.clearedAt and el > 1000 and K.aliveOf(st.mine) == 0 then st.clearedAt = el end
		K.holdAim(p, st)
		if el >= st.nextLure then
			st.nextLure = el + TG.FIGHT_LURE_MS
			TG.lure(p, zombiesList())
		end
		local w = r.weaponItem
		if w and st.ranged then
			if K.gunLoad(w) then st.reloads = st.reloads + 1 end
			if K.gunUnjam(w) then st.unjams = st.unjams + 1 end
		end
		-- the nearest standing zombie in range: face it and fire when the gun is ready
		local px, py = p:getX(), p:getY()
		local best, bd = nil, 1e9
		for _, z in ipairs(zombiesList()) do
			if not isDead(z) and not K.zProne(z) then
				local d = math.sqrt((z:getX() - px) ^ 2 + (z:getY() - py) ^ 2)
				if d < bd then best, bd = z, d end
			end
		end
		if best and bd <= st.maxRange then
			K.tryOnce("face zombie", function() p:faceThisObject(best) end)
			if st.aim == "mouse" then
				local on, err = K.gunMouseOn(p, best)
				if on then st.mouseSet = st.mouseSet + 1 else
					st.mouseMiss = st.mouseMiss + 1
					if err and not st.mouseErr then st.mouseErr = err; T.trace("gunfight: can't move the mouse onto the target: " .. err) end
				end
			end
			if best ~= st.aimAt then st.aimAt, st.aimSince = best, t end
			local okD, delay = pcall(function() return p:getAimingDelay() end)
			delay = okD and tonumber(delay) or nil
			local steady = (not st.ranged) or delay == nil or delay <= K.GUN_AIM_DELAY_OK or t - st.aimSince >= K.GUN_AIM_WAIT_MS
			if steady and K.readyToSwing(p, st) then
				if delay then st.delaySum, st.delayN = st.delaySum + delay, st.delayN + 1 end
				if delay and delay > K.GUN_AIM_DELAY_OK then st.waitedOut = st.waitedOut + 1 end
				local ok, err = K.swing(p, st)
				if ok then st.attempts = st.attempts + 1
				elseif not st.fireFails then
					st.fireFails = tostring(err)
					T.trace("gunfight: the attack input fails: " .. st.fireFails)
				end
			end
		end
		if el >= st.seconds * 1000 then
			K.releaseAim(p)
			if st.mouse0 and st.mouseSet > 0 then pcall(setMouseXY, st.mouse0[1], st.mouse0[2]) end
			K.gunUnhook(st)
			local up = K.aliveOf(st.mine)
			removeZombies()
			TG.removeCorpses(st.c, st.range + 10)
			r.fightAt, r.fightRadius = nil, nil
			r.holdSweep = false
			TG.keepAlive(p)
			local kills = "?"
			if st.kills0 then
				local okK, k1 = K.tryOnce("zombie kills", function() return p:getZombieKills() end)
				if okK then kills = tostring(k1 - st.kills0) end
			end
			st.result = string.format("%d spawned %d tiles out, %s, %d shots fired of %d tries (OnWeaponSwing), %d hits (%.0f%%, mean damage %s, mean distance %s, farthest %.1f tiles), %s killed by you, %d put down by script at arm's length (at most %d), %d still standing (removed); %d reloads and %d jams cleared by script; %s; %s; hits taken %d%s",
				st.spawned, st.range, st.weapon, st.shots, st.attempts, st.hits, st.shots > 0 and 100 * st.hits / st.shots or 0,
				st.hits > 0 and string.format("%.2f", st.dmg / st.hits) or "-", st.hits > 0 and string.format("%.1f tiles", st.hitDist / st.hits) or "-", st.farHit,
				kills, st.thinned or 0, K.GUN_CROWD, up, st.reloads, st.unjams,
				st.clearedAt and string.format("cleared in %.1f s", st.clearedAt / 1000) or "not cleared",
				st.guarding and string.format("can't-die mode gave way (%s)", st.guarding) or string.format("can't-die mode held (%d heals)", st.heals or 0),
				(r.hitsTaken or 0) - (st.hits0 or 0),
				(#st.skillSet > 0 and ("; skills " .. table.concat(st.skillSet, " ")) or "") ..
				(st.fireFails and ("; ATTACK INPUT FAILED: " .. st.fireFails) or "") ..
				string.format("; aim by %s%s, aiming delay at the trigger %s%s", st.aim,
					st.aim == "mouse" and string.format(" (mouse on the target %d ticks, %s %d)", st.mouseSet, st.mouseErr and ("FAILED: " .. st.mouseErr .. ",") or "off it", st.mouseMiss) or "",
					st.delayN > 0 and string.format("%.1f mean", st.delaySum / st.delayN) or "not read",
					st.waitedOut > 0 and string.format(", %d shots fired after %.1f s without it settling", st.waitedOut, K.GUN_AIM_WAIT_MS / 1000) or "") ..
				(st.ranged and "" or "; NOT A RANGED WEAPON"))
			return true
		end
		return false
	end,
}
