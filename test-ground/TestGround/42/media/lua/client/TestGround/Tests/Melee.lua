-- Test Ground 1.13.0: melee fighting: the scripted fight and the real fight.
require "TestGround/Core"
local TG = TestGroundInternal
if TG.loaded.Melee then return end
TG.loaded.Melee = true
local S = TG.S
local K, Steps, T, floor, isDead, isGod = TG.K, TG.Steps, TG.T, TG.floor, TG.isDead, TG.isGod
local near, now, playerHealth, removeZombies, say, spawnZombies = TG.near, TG.now, TG.playerHealth, TG.removeZombies, TG.say, TG.spawnZombies
local teleport, try, zombiesList = TG.teleport, TG.try, TG.zombiesList
local FIGHT_ABORT_MS = 15000   -- a fight that has put nothing down by then is stopped
local FIGHT_LURE_MS = 3000     -- how often zombies that aren't at arm's length are sent at you
-- Guarded fights, for when god mode can't be turned on (outside debug mode the cheat isn't reachable
-- from Lua): any zombie that gets this close is put down that tick, well outside its attack range,
-- and the first sign of a wound ends the fight, removes every zombie and heals the player.
local GUARD_KILL2 = 2.2 * 2.2

local function wounds(p)
	local w = { health = playerHealth(p) }
	pcall(function()
		local bd = p:getBodyDamage()
		w.scratched, w.bitten, w.bleeding = bd:getNumPartsScratched(), bd:getNumPartsBitten(), bd:getNumPartsBleeding()
		w.infected = bd:IsInfected()
	end)
	return w
end

-- What got worse since w0, in words, or nil.
local function newWound(w0, w)
	if w.health and w0.health and w.health < w0.health - 0.01 then return string.format("health %.2f", w.health) end
	for _, k in ipairs({ "scratched", "bitten", "bleeding" }) do
		if w[k] and w0[k] and w[k] > w0[k] then return w[k] .. " parts " .. k end
	end
	if w.infected and not w0.infected then return "infected" end
	return nil
end

local function healPlayer(p)
	return try("heal player", function()
		local bd = p:getBodyDamage()
		bd:RestoreToFullHealth()
		pcall(function() bd:setInfected(false) end)
		pcall(function() bd:setInfectionTime(-1) end)
	end)
end
local function lure(p, list, skip)
	K.tryOnce("addSound", function() getWorldSoundManager():addSound(p, floor(p:getX()), floor(p:getY()), floor(p:getZ()), 30, 30) end)
	for _, z in ipairs(list) do
		if z ~= skip then K.tryOnce("zombie pathToCharacter", function() z:pathToCharacter(p) end) end
	end
end

Steps.fight = {
	begin = function(r, st)
		st.count = math.max(1, floor(st.a or 6))
		st.seconds = st.b or 30
		st.guarded = not isGod(r.p)
		if st.guarded then T.trace("fight: god mode is off, so this fight is guarded") end
		r.holdSweep = true
		removeZombies()
		pcall(function() r.p:setGhostMode(false) end)
		local home = r.plan.start
		if home and not near(r.p, home, 3) then
			teleport(r.p, home.x, home.y, home.z)
			T.trace("fight: back to the start")
		end
		local c = { x = floor(r.p:getX()), y = floor(r.p:getY()), z = floor(r.p:getZ()) }
		spawnZombies(c, st.count)
		r.fightAt = c
		st.spawned = #zombiesList()
		st.killEvery = math.max(300, st.seconds * 700 / st.count)
		st.nextKill = 2000      -- they need a moment to reach you
		st.killed, st.maxNear = 0, 0
		st.nextLure = 500
		st.health0 = playerHealth(r.p)
		st.wounds0 = wounds(r.p)
		st.guardKills = 0
	end,
	tick = function(r, st, t)
		local el = t - st.t0
		local function abort(why)
			local standing = 0
			for _, z in ipairs(zombiesList()) do if not isDead(z) then standing = standing + 1 end end
			removeZombies()
			r.holdSweep = false
			st.result = string.format("%sABORTED after %.0f s: %s; %d spawned, %d put down, up to %d at arm's length, %d still standing (removed)",
				st.guarded and "guarded, " or "", el / 1000, why, st.spawned, st.killed, st.maxNear, standing)
			T.trace("fight aborted: " .. why)
			say("fight aborted: " .. why)
			return true
		end
		if st.guarded then
			local hurt = newWound(st.wounds0, wounds(r.p))
			if hurt then
				removeZombies()
				local healed = healPlayer(r.p)
				return abort("player hurt (" .. hurt .. "), zombies removed, " .. (healed and "player healed" or "HEALING FAILED"))
			end
			local px, py = r.p:getX(), r.p:getY()
			for _, z in ipairs(zombiesList()) do
				if not isDead(z) then
					local dx, dy = z:getX() - px, z:getY() - py
					if dx * dx + dy * dy < GUARD_KILL2 then
						st.downed = st.downed or {}
						local at = st.downed[z]
						if at then
							if t - at > 300 then
								removeZombies()
								return abort("a zombie put down 0.3 s ago is still up, so a guarded fight isn't safe; zombies removed")
							end
						elseif try("put down zombie", function() z:setHealth(0) end) then
							st.downed[z] = t
							st.killed, st.guardKills = st.killed + 1, st.guardKills + 1
							if st.maxNear < 1 then st.maxNear = 1 end
						else
							removeZombies()
							return abort("putting zombies down fails, so a guarded fight isn't safe; zombies removed")
						end
					end
				end
			end
		else
			if not isGod(r.p) then return abort("god mode went off") end
			local h = playerHealth(r.p)
			if h and st.health0 and h < st.health0 - 0.2 then return abort(string.format("player hurt (health %.2f)", h)) end
		end
		if el >= st.nextLure then
			st.nextLure = el + FIGHT_LURE_MS
			lure(r.p, zombiesList())
		end
		if el >= st.nextKill then
			local px, py = r.p:getX(), r.p:getY()
			local best, bd, nearN = nil, TG.FIGHT_REACH2, 0
			for _, z in ipairs(zombiesList()) do
				if not isDead(z) then
					local dx, dy = z:getX() - px, z:getY() - py
					local d = dx * dx + dy * dy
					if d < TG.FIGHT_REACH2 then nearN = nearN + 1 end
					if d < bd then best, bd = z, d end
				end
			end
			if nearN > st.maxNear then st.maxNear = nearN end
			if best and not st.cannotKill then
				pcall(function()
					local dx, dy = best:getX() - px, best:getY() - py
					local d = math.sqrt(dx * dx + dy * dy)
					if d > 0 then r.p:getForwardDirection():set(dx / d, dy / d) end
				end)
				if try("put down zombie", function() best:setHealth(0) end) then
					st.killed = st.killed + 1
				else
					st.cannotKill = true   -- don't repeat a failing call every second
				end
				st.nextKill = el + st.killEvery
			else
				st.nextKill = el + 250
			end
		end
		if st.killed == 0 and el >= math.min(FIGHT_ABORT_MS, st.seconds * 500) then
			local px, py = r.p:getX(), r.p:getY()
			local nearest = nil
			for _, z in ipairs(zombiesList()) do
				local dx, dy = z:getX() - px, z:getY() - py
				local d = math.sqrt(dx * dx + dy * dy)
				if not nearest or d < nearest then nearest = d end
			end
			return abort(st.cannotKill and "putting zombies down fails" or
				string.format("none put down, none came within reach (nearest %.1f tiles)", nearest or -1))
		end
		if el >= st.seconds * 1000 then
			local standing = 0
			for _, z in ipairs(zombiesList()) do if not isDead(z) then standing = standing + 1 end end
			removeZombies()
			r.holdSweep = false
			st.result = string.format("%s%d spawned, %d put down, up to %d at arm's length, %d still standing (removed)%s",
				st.guarded and string.format("guarded (no god mode; %d put down as they came within 2.2 tiles), ", st.guardKills) or "",
				st.spawned, st.killed, st.maxNear, standing, st.cannotKill and ", PUT DOWN FAILED" or "")
			return true
		end
		return false
	end,
}

-- "Can't die" mode, for steps where zombies really reach you and god mode isn't available (outside
-- debug mode the cheat can't be turned on from Lua): every tick health is restored and wounds,
-- infection, tiredness and panic are cleared, so zombies can grab you and knock you down but not
-- kill you. If a hit still takes health below K.KEEPALIVE_FLOOR between ticks, the step switches to
-- guarded put-downs for the rest of it and says so.
K.KEEPALIVE_FLOOR = 0.5
local function keepAlive(p)
	local ok = K.tryOnce("RestoreToFullHealth", function() p:getBodyDamage():RestoreToFullHealth() end)
	if ok then
		local bd = p:getBodyDamage()
		K.tryOnce("setInfected", function() bd:setInfected(false) end)
		K.tryOnce("setInfectionTime", function() bd:setInfectionTime(-1) end)
	end
	if K.stats == nil then
		-- looked up once: an exposed class indexed with a missing name throws
		K.stats = false
		if CharacterStat then
			local ok, list = K.tryOnce("CharacterStat", function()
				return { CharacterStat.ENDURANCE, CharacterStat.PANIC, CharacterStat.FATIGUE, CharacterStat.PAIN, CharacterStat.STRESS }
			end)
			if ok then K.stats = list end
		end
	end
	if K.stats then
		K.tryOnce("stats reset", function()
			local s = p:getStats()
			for _, k in ipairs(K.stats) do s:reset(k) end
		end)
	end
	return ok
end
T.keepAlive = keepAlive

-- Puts down every live zombie within GUARD_KILL2 of the player; returns how many.
local function guardRing(p)
	local n = 0
	local px, py = p:getX(), p:getY()
	for _, z in ipairs(zombiesList()) do
		if not isDead(z) then
			local dx, dy = z:getX() - px, z:getY() - py
			if dx * dx + dy * dy < GUARD_KILL2 and try("put down zombie", function() z:setHealth(0) end) then n = n + 1 end
		end
	end
	return n
end

-- Dead bodies within radius of a point are taken away (after a stress step, hundreds of corpses
-- would weigh on every later step).
local function removeCorpses(c, radius)
	local n = 0
	local cell = getCell()
	for y = c.y - radius, c.y + radius do
		for x = c.x - radius, c.x + radius do
			local sq = cell:getGridSquare(x, y, c.z or 0)
			if sq then
				K.tryOnce("remove bodies", function()
					local list = sq:getDeadBodys()
					for i = list:size() - 1, 0, -1 do
						sq:removeCorpse(list:get(i), false)
						n = n + 1
					end
				end)
			end
		end
	end
	return n
end

-- One tick of "can't die": heal, and if a hit got through anyway, guard from then on.
local function cantDie(r, st)
	local h = playerHealth(r.p)
	if not st.guarding and h and h < K.KEEPALIVE_FLOOR then
		st.guarding = string.format("health fell to %.2f between heals", h)
		T.trace(st.kind .. ": " .. st.guarding .. ", zombies within 2.2 tiles are put down from now on")
	end
	if keepAlive(r.p) then st.heals = (st.heals or 0) + 1 elseif not st.healFailed then
		st.healFailed = true
		st.guarding = st.guarding or "healing failed"
	end
	if st.guarding then st.guardKills = (st.guardKills or 0) + guardRing(r.p) end
end

local function visibleZombies(p)
	local ok, n = K.tryOnce("visible zombie count", function() return p:getStats():getNumVisibleZombies() end)
	return ok and n or nil
end

local function aliveCount()
	local n = 0
	for _, z in ipairs(zombiesList()) do if not isDead(z) then n = n + 1 end end
	return n
end

-- weather W: from here on the weather is W (clear, rain, fog; keep = back to the save's own). Takes
-- no time; the steps after it are measured in that weather. The run's end clears it.

function K.stepOpts(st)
	local o = { skills = {} }
	for w in string.gmatch(st.text or "", "%S+") do   -- st.text keeps the case (item ids, perk names)
		local k, v = string.match(w, "^([%w_]+)=(%S+)$")
		if k then
			if string.lower(k) == "weapon" then o.weapon = v
			elseif string.lower(k) == "crowd" and tonumber(v) then o.crowd = math.max(1, floor(tonumber(v)))
			elseif string.lower(k) == "knockdown" and tonumber(v) then o.knockdown = math.max(1, tonumber(v))
			elseif tonumber(v) then o.skills[#o.skills + 1] = { name = k, level = math.max(0, math.min(10, floor(tonumber(v)))) } end
		end
	end
	return o
end
function K.perk(name)
	local ok, pk = pcall(function() return Perks.FromString(name) end)
	if ok and pk then return pk end
	ok, pk = pcall(function() return Perks[name] end)
	return ok and pk or nil
end
function K.setSkills(r, skills)
	local p, done = r.p, {}
	for _, sk in ipairs(skills) do
		local pk = K.perk(sk.name)
		local ok = false
		if pk then
			r.perkWas = r.perkWas or {}
			if r.perkWas[sk.name] == nil then pcall(function() r.perkWas[sk.name] = { pk = pk, level = p:getPerkLevel(pk) } end) end
			ok = pcall(function() p:setPerkLevelDebug(pk, sk.level) end)
		end
		done[#done + 1] = sk.name .. "=" .. sk.level .. (ok and "" or " (FAILED)")
	end
	return done
end
function K.resetSkills(r)
	for _, w in pairs(r.perkWas or {}) do pcall(function() r.p:setPerkLevelDebug(w.pk, w.level) end) end
	r.perkWas = nil
end
-- B42 HandWeapon has no getCategories (1.9.4 called it: a stack trace per fight); the sub-category
-- (Blunt, Axe, Spear, ...) is what the skill matrix needs.
function K.weaponCategory(w)
	local ok, cat = K.tryOnce("weapon sub-category", function() return w:getSubCategory() end)
	if ok and cat and cat ~= "" then return tostring(cat) end
	return "?"
end
function K.weaponReach(p, w)
	if not w then return 1.0 end
	local ok, r = K.tryOnce("weapon range", function() return w:getMaxRange(p) end)
	return (ok and tonumber(r) and r > 0.3) and r or 1.2
end
function K.armWeapon(r, st, id)
	local p = r.p
	id = id or r.plan.weapon or K.DEFAULT_WEAPON
	if string.lower(id) == "none" then
		K.tryOnce("unequip", function() p:setPrimaryHandItem(nil); p:setSecondaryHandItem(nil) end)
		r.weaponItem = nil
		return "bare hands"
	end
	if r.weaponItem and r.weaponId ~= id then K.unarm(r) end
	if not r.weaponItem then
		local ok, item = pcall(function() return p:getInventory():AddItem(id) end)
		if not ok or not item then return "bare hands (no item " .. id .. ")" end
		r.weaponItem, r.weaponId = item, id
	end
	local w = r.weaponItem
	K.tryOnce("equip", function()
		p:setPrimaryHandItem(w)
		local two = false
		pcall(function() two = w:isTwoHandWeapon() end)
		if two then p:setSecondaryHandItem(w) end
	end)
	return id
end
function K.weaponCondition(r)
	local w = r.weaponItem
	if not w then return nil end
	local ok, c, m = pcall(function() return w:getCondition(), w:getConditionMax() end)
	return ok and string.format("%d/%d", c, m) or nil
end
-- Can the character swing at all: strength, and no fractured arm or hand.
function K.fitness(p)
	local str = "?"
	K.tryOnce("strength level", function() str = tostring(p:getPerkLevel(Perks.Strength)) end)
	local broken = {}
	K.tryOnce("fracture check", function()
		local parts = p:getBodyDamage():getBodyParts()
		for i = 0, parts:size() - 1 do
			local bp = parts:get(i)
			local name = tostring(bp:getType())
			if (string.find(name, "Hand") or string.find(name, "Arm")) and bp:getFractureTime() > 0 then broken[#broken + 1] = name end
		end
	end)
	return "strength " .. str .. ", " .. (#broken > 0 and ("FRACTURED " .. table.concat(broken, " ")) or "arms ok")
end
function K.unarm(r)
	local w = r.weaponItem
	if not w then return end
	r.weaponItem = nil
	pcall(function()
		local p = r.p
		if p:getPrimaryHandItem() == w then p:setPrimaryHandItem(nil) end
		if p:getSecondaryHandItem() == w then p:setSecondaryHandItem(nil) end
		p:getInventory():Remove(w)
	end)
end

function K.aliveOf(list)
	local n = 0
	for _, z in ipairs(list or {}) do if not isDead(z) then n = n + 1 end end
	return n
end

-- 1.12.3, a swing as the game makes one (from the B42 bytecode):
--  * aim is held with setBlockMovement(true): otherwise the player's input step sets isAiming from the
--    real aim key every frame, so setIsAiming(true) from OnTick was gone before the animation saw it
--    (1.11.1: 13 to 21 swings, 1 to 4 frames in an attack animation, nothing hit);
--  * AttemptAttack once, only when no attack is marked started, not in an attack animation, melee and
--    recoil delays over and the weapon ready, after 3 ticks of aim;
--  * an attack marked started with no swing (OnWeaponSwing) for 0.5 s is cleared with
--    clearHandToHandAttack, or every later AttemptAttack does nothing.
-- The game decides shove or swing again when the swing starts: a standing zombie closer than the
-- weapon's MinRange gets a shove, so the fight keeps zombies in the working band first.
K.SWING_CHARGE = 1.0
K.AIM_TICKS = 3
K.SWING_STUCK_MS = 500
function K.holdAim(p, st)
	K.tryOnce("block movement", function() p:setBlockMovement(true) end)
	K.tryOnce("aim", function() p:setIsAiming(true) end)
	st.aimTicks = (st.aimTicks or 0) + 1
end
function K.releaseAim(p)
	K.tryOnce("aim", function() p:setIsAiming(false) end)
	K.tryOnce("block movement", function() p:setBlockMovement(false) end)
end
function K.readyToSwing(p, st)
	if (st.aimTicks or 0) < K.AIM_TICKS then return false end
	local t = now()
	local okS, started = K.tryOnce("attack started check", function() return p:isAttackStarted() end)
	local okP, anim = K.tryOnce("attack animation check", function() return p:isPerformingAttackAnimation() end)
	if okP and anim then st.anims = (st.anims or 0) + 1; return false end
	if okS and started then
		if st.attemptAt and t - st.attemptAt > K.SWING_STUCK_MS and (st.swungAt or 0) < st.attemptAt then
			local ok = K.tryOnce("clear hand to hand attack", function() p:clearHandToHandAttack() end)
			if not ok then K.tryOnce("attack started clear", function() p:setAttackStarted(false) end) end
			st.unstuck = (st.unstuck or 0) + 1
			st.attemptAt = nil
		end
		return false
	end
	local okM, md = K.tryOnce("melee delay", function() return p:getMeleeDelay() end)
	if okM and md and md > 0 then return false end
	local okR, rd = K.tryOnce("recoil delay", function() return p:getRecoilDelay() end)
	if okR and rd and rd > 0 then return false end
	local okW, ready = K.tryOnce("weapon ready", function() return p:isWeaponReady() end)
	if okW and ready == false then return false end
	return true
end
function K.swing(p, st)
	st.attemptAt = now()
	local ok, err = K.tryOnce("AttemptAttack", function() p:AttemptAttack(K.SWING_CHARGE) end)
	if ok then st.how = "AttemptAttack" end
	return ok, err
end
-- The weapon's working band: closer than MinRange is a shove, farther than MaxRange x RangeMod
-- misses. Distances are to the zombie's root; a lunging zombie's head is nearer, hence the margin.
-- 1.12.7, knockdown=N on a realfight step: every N s the nearest standing zombie within 2.5 tiles is
-- knocked to the floor (the game's own knockDown), so the floor attack gets tested; in the 1.12.6
-- fight_12 the bat put none down and the script's put-downs are kills, so it never ran.
function K.knockOne(r, st)
	local p = r.p
	local best, bd = nil, 2.5 * 2.5
	for _, z in ipairs(zombiesList()) do
		if not isDead(z) and not K.zProne(z) then
			local d = (z:getX() - p:getX()) ^ 2 + (z:getY() - p:getY()) ^ 2
			if d < bd then best, bd = z, d end
		end
	end
	if not best then return end
	-- Routes: knockDown, then setKnockedDown plus a stagger back. Whether the zombie really went
	-- down is read a second later, and the report names the route that worked. 1.12.10: the "tried
	-- to call nil" of 1.12.8 and 1.12.9 was math.random, which Kahlua doesn't have (ZombRand now);
	-- both methods are exposed.
	local routes = {
		{ "knockDown", function(z) z:knockDown(ZombRand(2) == 0) end },
		{ "setKnockedDown", function(z)
			z:setKnockedDown(true)
			if z.setFallOnFront then z:setFallOnFront(ZombRand(2) == 0) end
			if z.setStaggerBack then z:setStaggerBack(true) end
		end },
	}
	for _, rt in ipairs(routes) do
		local name, fn = rt[1], rt[2]
		local has = false
		pcall(function() has = best[name] ~= nil end)
		if has and not K.broken["knock down " .. name] then
			if K.tryOnce("knock down " .. name, function() fn(best) end) then
				st.knocked = (st.knocked or 0) + 1
				st.knockRoute = name
				-- 1.13.2: watched for K.KNOCK_WATCH_MS, and not swung at or lured meanwhile. In 1.12.10 none
				-- went down: the zombie knocked was the one at arm's length, and the bat's next hit runs
				-- IsoZombie.hitConsequences, which sets knockedDown to (critical hit or already on the
				-- floor), so it cleared the flag before the stagger reached the fall.
				st.knockCheck = { z = best, t0 = now(), until_ = now() + K.KNOCK_WATCH_MS }
				return
			end
		end
	end
	if not st.knockNone then
		st.knockNone = true
		T.trace("realfight: no knock-down route is callable from Lua here (knockDown, setKnockedDown)")
	end
end
K.KNOCK_WATCH_MS = 4000
function K.knockVerify(st)
	local c = st.knockCheck
	if not c then return end
	local t = now()
	if not c.state1 and t - c.t0 >= 1000 then c.state1 = TG.stateName(c.z) end
	if K.zProne(c.z) or isDead(c.z) then
		st.knockCheck = nil
		st.knockDown = (st.knockDown or 0) + 1
		st.knockMs = (st.knockMs or 0) + (t - c.t0)
		return
	end
	if t >= c.until_ then
		st.knockCheck = nil
		st.knockMissed = (st.knockMissed or 0) + 1
		if (st.knockMissed or 0) <= 3 then
			T.trace(string.format("realfight: knock-down didn't floor the zombie in %d s (state after 1 s: %s, now: %s)", K.KNOCK_WATCH_MS / 1000, c.state1 or "?", TG.stateName(c.z)))
		end
	end
end
-- the zombie being knocked down, while it's watched
function K.knockHeld(st)
	return st.knockCheck and st.knockCheck.z or nil
end
function K.weaponBand(p, w)
	if not w then return 0.3, 0.9 end
	local okN, mn = K.tryOnce("weapon min range", function() return w:getMinRange() end)
	local okX, mx = K.tryOnce("weapon max range", function() return w:getMaxRange(p) end)
	local okM, rm = K.tryOnce("weapon range mod", function() return w:getRangeMod(p) end)
	mn = (okN and tonumber(mn)) or 0.61
	mx = (okX and tonumber(mx) and mx > 0.3) and mx or 1.2
	if okM and tonumber(rm) and rm > 0 then mx = mx * rm end
	-- 1.12.7: the game shoves only under MinRange; 1.12.6 kept 0.3 tiles more and stepped back 257
	-- times in fight_12 (bat band 0.91 to 1.15), so the margin is now 0.05
	local lo, hi = mn + K.BAND_MARGIN, mx - 0.1
	if hi < lo + 0.1 then hi = lo + 0.1 end
	return lo, hi, mn, mx
end
-- A small step (not a teleport): the fight positions the player with these, as the player can't
-- walk without input.
K.STEP_TILES = 0.07
function K.stepToward(p, x, y, maxStep)
	local px, py = p:getX(), p:getY()
	local dx, dy = x - px, y - py
	local d = math.sqrt(dx * dx + dy * dy)
	if d < 0.01 then return 0 end
	local m = math.min(d, maxStep or K.STEP_TILES)
	local nx, ny = px + dx / d * m, py + dy / d * m
	local sq = getCell():getGridSquare(floor(nx), floor(ny), floor(p:getZ()))
	if not sq then return d end
	K.tryOnce("step", function() p:setX(nx); p:setY(ny) end)
	return d - m
end
function K.zProne(z)
	local ok, v = K.tryOnce("zombie prone", function() return z:isProne() end)
	if ok then return v == true end
	ok, v = K.tryOnce("zombie on floor", function() return z:isOnFloor() end)
	return ok and v == true
end
-- Where a prone zombie's head is: 0.75 tiles from its root along its facing, one way or the other
-- (B42 ragdolls, so it's checked with the game's own bone test once the player stands there).
K.HEAD_OFFSET = 0.75
function K.headCandidates(z)
	local fx, fy = 1, 0
	K.tryOnce("zombie facing", function() local f = z:getForwardDirection(); fx, fy = f:getX(), f:getY() end)
	local back = false
	K.tryOnce("zombie on back", function() back = z:isOnBack() == true end)
	local zx, zy = z:getX(), z:getY()
	local a = { x = zx + fx * K.HEAD_OFFSET, y = zy + fy * K.HEAD_OFFSET }
	local b = { x = zx - fx * K.HEAD_OFFSET, y = zy - fy * K.HEAD_OFFSET }
	if back then return { b, a } end
	return { a, b }
end
-- 1.12.6: which end of a downed zombie is its head, from the damage the hit does (the floor attack
-- hits where the player stands: head x3, spine x1, legs and feet x0.05). The game's own bone test
-- needs the zombie's AnimationPlayer, which Lua can't reach (1.12.3: "unavailable" every time).
-- A floor hit of at least K.HEAD_RATIO times the standing mean counts as the head; one under
-- K.FEET_RATIO times it is the legs, and the next swing goes to the other end.
K.HEAD_RATIO, K.FEET_RATIO = 2, 0.5
function K.floorHit(st, z, d)
	local ref = (st.standHits or 0) > 0 and st.standDmg / st.standHits or nil
	if z ~= st.floorZ or not ref or ref <= 0 then st.headUnknown = (st.headUnknown or 0) + 1; return end
	local ratio = d / ref
	if ratio >= K.HEAD_RATIO then
		st.headYes = (st.headYes or 0) + 1
	elseif ratio < K.FEET_RATIO then
		st.headNo = (st.headNo or 0) + 1
		if not st.headSwitched then
			st.headSwitched = true
			st.headTry = 3 - (st.headTry or 1)
			st.sideSwitches = (st.sideSwitches or 0) + 1
			T.trace(string.format("realfight: a floor hit did %.2f (%.2f x the standing mean): legs, not the head; moving to the other end", d, ratio))
		end
	else
		st.headMid = (st.headMid or 0) + 1
	end
end
-- Never more than K.CROWD_MAX zombies at arm's length: the rest are put down, so a real fight is
-- 1 or 2 on 1 and can't turn into a drag-down.
K.CROWD_MAX = 2
K.SHOVE_GAP_MS = 1200
K.BAND_MARGIN = 0.05
K.CROWD_REACH2 = 1.3 * 1.3
function K.crowdCap(p, max)
	max = max or K.CROWD_MAX
	local px, py = p:getX(), p:getY()
	local close = {}
	for _, z in ipairs(zombiesList()) do
		if not isDead(z) then
			local d = (z:getX() - px) ^ 2 + (z:getY() - py) ^ 2
			if d < K.CROWD_REACH2 then close[#close + 1] = { z = z, d = d } end
		end
	end
	if #close <= max then return 0 end
	table.sort(close, function(a, b) return a.d < b.d end)
	local n = 0
	for i = max + 1, #close do
		if try("put down zombie", function() close[i].z:setHealth(0) end) then n = n + 1 end
	end
	return n
end

-- The fight's own view of each swing: OnWeaponSwing (the swing really started: shove, or at the
-- floor) and OnWeaponHitCharacter (a hit, with its damage).
function K.fightHook(r, st)
	st.fhooks = {}
	local p = r.p
	local function add(name, fn)
		if Events[name] and Events[name].Add then Events[name].Add(fn); st.fhooks[name] = fn end
	end
	add("OnWeaponSwing", function(c)
		if c ~= p then return end
		st.real = st.real + 1
		st.swungAt = now()
		local okS, sh = pcall(function() return p:isDoShove() end)
		local okF, fl = pcall(function() return p:isAimAtFloor() end)
		if okS and sh then st.shoves = st.shoves + 1 end
		if okF and fl then st.floorSwings = st.floorSwings + 1 end
	end)
	add("OnWeaponHitCharacter", function(w, target, weapon, dmg)
		if w ~= p then return end
		local d = tonumber(dmg) or 0
		st.hitsLanded = st.hitsLanded + 1
		if target and K.zProne(target) then
			st.floorHits, st.floorDmg = (st.floorHits or 0) + 1, (st.floorDmg or 0) + d
			K.floorHit(st, target, d)
		else
			st.standHits, st.standDmg = (st.standHits or 0) + 1, (st.standDmg or 0) + d
		end
	end)
end
function K.fightUnhook(st)
	for name, fn in pairs(st.fhooks or {}) do pcall(function() Events[name].Remove(fn) end) end
	st.fhooks = {}
end
-- Each tick: a downed zombie (none standing near) is attacked from its head; a standing one is kept
-- in the weapon's working band (step back when too close, close in when too far) and swung at.
function K.fightMove(r, st)
	local p = r.p
	local px, py = p:getX(), p:getY()
	local stand, sd, prone, pd = nil, 1e9, nil, 1e9
	local held = K.knockHeld(st)
	for _, z in ipairs(zombiesList()) do
		if not isDead(z) and z ~= held then
			local dx, dy = z:getX() - px, z:getY() - py
			local d = math.sqrt(dx * dx + dy * dy)
			if K.zProne(z) then
				if d < pd then prone, pd = z, d end
			elseif d < sd then stand, sd = z, d end
		end
	end
	-- the game ignores downed zombies while a standing one that's after you is within 1.5 tiles
	if prone and (not stand or sd > 1.8) and pd < 8 then return K.floorAttack(r, st, prone) end
	st.floorZ = nil
	if not stand then return end
	K.tryOnce("face zombie", function() p:faceThisObject(stand) end)
	if sd < st.lo then
		-- 1.12.6: too close for the weapon. A zombie keeps walking in, so stepping back every time
		-- turned the 1.12.3 fight into a retreat (224 step-backs in fight_12). Shove it off first, as a
		-- player does (the game makes any swing this close a shove), and step back only while the
		-- next swing isn't ready or a shove went out in the last K.SHOVE_GAP_MS.
		if now() - (st.shoveAt or 0) > K.SHOVE_GAP_MS and K.readyToSwing(p, st) then
			st.shoveAt = now()
			st.closeShoves = (st.closeShoves or 0) + 1
			st.backing = false
			K.fightSwing(r, st)
			return
		end
		local d = math.max(sd, 0.01)
		K.stepToward(p, px + (px - stand:getX()) / d, py + (py - stand:getY()) / d)
		if not st.backing then st.backoffs = st.backoffs + 1 end
		st.backing = true
		return
	end
	st.backing = false
	if sd > st.hi then
		if sd < 3 then K.stepToward(p, stand:getX(), stand:getY(), 0.04) end
		return
	end
	if K.readyToSwing(p, st) then K.fightSwing(r, st) end
end
function K.fightSwing(r, st)
	local okA, err = K.swing(r.p, st)
	if okA then
		st.swings = st.swings + 1
	else
		st.swingFails = tostring(err)
		T.trace("realfight: the attack input fails: " .. st.swingFails)
	end
end
function K.floorAttack(r, st, z)
	local p = r.p
	if st.floorZ ~= z then
		st.floorZ, st.headTry, st.headCands, st.headChecked, st.headSwitched = z, 1, K.headCandidates(z), false, false
		st.floorTargets = (st.floorTargets or 0) + 1
	end
	local c = st.headCands[st.headTry]
	local left = K.stepToward(p, c.x, c.y)
	K.tryOnce("face zombie", function() p:faceThisObject(z) end)
	if left > 0.08 then return end
	if not st.headChecked then
		st.headChecked = true
		T.trace(string.format("realfight: standing at a downed zombie's head end at %.1f,%.1f (side %d; the hit's damage tells if it's the head)", c.x, c.y, st.headTry))
	end
	if K.readyToSwing(p, st) then K.fightSwing(r, st) end
end

-- realfight N S: like fight, but you swing yourself, with the plan's weapon (default a baseball
-- bat; "weapon = none" shoves bare-handed), through the attack input; nothing is put down by script. N zombies in the fight ring,
-- S seconds, "can't die" mode. The report counts swings and zombies down.
K.SWING_REACH2 = 1.4 * 1.4
K.SWING_EVERY_MS = 600
Steps.realfight = {
	begin = function(r, st)
		st.count = math.max(1, floor(st.a or 6))
		st.seconds = st.b or 30
		r.holdSweep = true
		removeZombies()
		pcall(function() r.p:setGhostMode(false) end)
		local home = r.plan.start
		if home and not near(r.p, home, 3) then teleport(r.p, home.x, home.y, home.z) end
		local c = { x = floor(r.p:getX()), y = floor(r.p:getY()), z = floor(r.p:getZ()) }
		st.c = c
		spawnZombies(c, st.count)
		r.fightAt = c
		-- the fight's own zombies; the game's zombies that wander in later aren't counted (1.9.4 said
		-- "125 still standing" at West Point)
		st.mine = {}
		for _, z in ipairs(zombiesList()) do st.mine[#st.mine + 1] = z end
		st.spawned = #st.mine
		st.swings, st.heals, st.guardKills, st.nextSwing, st.nextLure = 0, 0, 0, 0, 500
		local o = K.stepOpts(st)
		st.crowd = o.crowd or r.plan.crowd or K.CROWD_MAX
		st.knockEvery = o.knockdown
		st.weapon = K.armWeapon(r, st, o.weapon)
		st.category = r.weaponItem and K.weaponCategory(r.weaponItem) or "unarmed"
		st.skillSet = K.setSkills(r, o.skills)
		st.cond0 = K.weaponCondition(r)
		st.fit = K.fitness(r.p)
		st.drag0 = r.dragSaves or 0
		st.hits0 = r.hitsTaken or 0
		local okK, k0 = K.tryOnce("zombie kills", function() return r.p:getZombieKills() end)
		st.kills0 = okK and k0 or nil
		st.lo, st.hi, st.minR, st.maxR = K.weaponBand(r.p, r.weaponItem)
		st.real, st.shoves, st.floorSwings, st.hitsLanded, st.headHits, st.dmg, st.backoffs = 0, 0, 0, 0, 0, 0, 0
		st.headYes, st.headNo, st.headMid, st.headUnknown, st.sideSwitches = 0, 0, 0, 0, 0
		K.fightHook(r, st)
		pcall(function()
			local w = r.p:getPrimaryHandItem()
			if w then st.weapon = st.weapon .. " (" .. tostring(w:getDisplayName()) .. ")" end
		end)
	end,
	tick = function(r, st, t)
		local el = t - st.t0
		st.hits = (r.hitsTaken or 0) - (st.hits0 or 0)
		local down = K.isDown(r.p)
		if down and not st.wasDown then st.downs = (st.downs or 0) + 1 end
		st.wasDown = down
		cantDie(r, st)
		st.thinned = (st.thinned or 0) + K.crowdCap(r.p, st.crowd)
		if not st.clearedAt and el > 1000 and K.aliveOf(st.mine) == 0 then st.clearedAt = el end
		K.holdAim(r.p, st)
		if el >= st.nextLure then
			st.nextLure = el + FIGHT_LURE_MS
			lure(r.p, zombiesList(), K.knockHeld(st))
		end
		if st.knockEvery and el >= (st.nextKnock or 3000) then
			st.nextKnock = el + st.knockEvery * 1000
			K.knockOne(r, st)
		end
		K.knockVerify(st)
		if not st.swingFails then K.fightMove(r, st) end
		if el >= st.seconds * 1000 then
			K.releaseAim(r.p)
			K.fightUnhook(st)
			local up = K.aliveOf(st.mine)
			local down = math.max(0, st.spawned - up)   -- a zombie that's down soon leaves the list as a body
			removeZombies()
			removeCorpses(st.c, 20)
			r.fightAt = nil
			r.holdSweep = false
			keepAlive(r.p)
			local kills = "?"
			if st.kills0 then
				local okK, k1 = K.tryOnce("zombie kills", function() return r.p:getZombieKills() end)
				if okK then kills = tostring(k1 - st.kills0) end
			end
			local thin = st.thinned or 0
			local c1 = K.weaponCondition(r)
			st.extra = "; category " .. st.category .. (#st.skillSet > 0 and ("; skills " .. table.concat(st.skillSet, " ")) or "") ..
				(st.clearedAt and string.format("; cleared in %.1f s", st.clearedAt / 1000) or "; not cleared") ..
				(st.cond0 and string.format("; weapon condition %s before, %s after", st.cond0, c1 or "?") or "") ..
				"; " .. st.fit .. string.format("; hits taken %d, downed %d times, guard fired: %s", st.hits or 0, st.downs or 0,
				(st.guarding or (st.rescues or 0) > 0 or (r.dragSaves or 0) > (st.drag0 or 0)) and
					string.format("yes (%s%d put down while you were down, %d drag-downs cleared)", st.guarding and (st.guarding .. ", ") or "", st.rescues or 0, (r.dragSaves or 0) - (st.drag0 or 0)) or "no")
			local function mean(sum, n) return n and n > 0 and string.format("%.2f", sum / n) or "-" end
			st.extra = string.format("; %d swings started (OnWeaponSwing: %d shoves, %d at the floor), %d hits landed (mean damage %s standing over %d, %s downed over %d); weapon band %.2f to %.2f tiles (MinRange %.2f, reach %.2f), stepped back %d times, shoved off %d times when too close%s; %d downed zombies attacked from the head end (floor hits by damage: %d head, %d body, %d legs, %d unjudged; moved to the other end %d times)",
				st.real, st.shoves, st.floorSwings, st.hitsLanded, mean(st.standDmg, st.standHits), st.standHits or 0,
				mean(st.floorDmg, st.floorHits), st.floorHits or 0, st.lo, st.hi, st.minR or 0, st.maxR or 0, st.backoffs, st.closeShoves or 0, st.knockEvery and string.format(", %d knock-downs by script (every %g s, via %s; %d on the floor within %d s%s) for the floor attack", st.knocked or 0, st.knockEvery, st.knockRoute or "none", st.knockDown or 0, K.KNOCK_WATCH_MS / 1000, (st.knockDown or 0) > 0 and string.format(", after %.1f s on average", st.knockMs / st.knockDown / 1000) or "") or "",
				st.floorTargets or 0, st.headYes, st.headMid, st.headNo, st.headUnknown, st.sideSwitches) .. st.extra
			st.result = string.format("%d spawned, %d swings (%s via %s, %d frames in an attack animation, %d stuck attacks cleared), %s killed by you, %d down in all (%d of them put down by script to keep at most %d at arm's length), %d still standing (removed); %s%s",
				st.spawned, st.swings, st.weapon, st.how or "nothing", st.anims or 0, st.unstuck or 0, kills, down, thin, st.crowd, up,
				st.guarding and string.format("can't-die mode gave way (%s), %d put down after that", st.guarding, st.guardKills) or
					string.format("can't-die mode held (%d heals)", st.heals),
				st.swingFails and (", ATTACK INPUT FAILED: " .. st.swingFails) or "") ..
				(st.rescues and string.format(", %d put down while you were down", st.rescues) or "") .. (st.extra or "")
			return true
		end
		return false
	end,
}

-- natural S [stand|run] [R]: the game's own zombies, at the plan's zone (zone = x,y,z, picked by
-- the survey from the map's zombie density; "zombies = keep" in that plan). Every few seconds a
-- noise draws the ones nearby; you stand, or run round a ring of radius R (25) with Walk To,
-- guarded (zombies within 2.2 tiles are put down) and in "can't die" mode. Nothing is spawned.
K.NATURAL_NOISE = 40

TG.FIGHT_ABORT_MS, TG.FIGHT_LURE_MS, TG.GUARD_KILL2, TG.aliveCount, TG.cantDie, TG.guardRing = FIGHT_ABORT_MS, FIGHT_LURE_MS, GUARD_KILL2, aliveCount, cantDie, guardRing
TG.healPlayer, TG.keepAlive, TG.lure, TG.newWound, TG.removeCorpses, TG.visibleZombies = healPlayer, keepAlive, lure, newWound, removeCorpses, visibleZombies
TG.wounds = wounds
