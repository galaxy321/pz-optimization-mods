-- Test Ground 1.13.0: standing, walking, turning, waiting, Walk To cases, weather, looting.
require "TestGround/Core"
local TG = TestGroundInternal
if TG.loaded.Idle then return end
TG.loaded.Idle = true
local S = TG.S
local K, LEG_TIMEOUT_MS, Steps, T, busy, clearClimate = TG.K, TG.LEG_TIMEOUT_MS, TG.Steps, TG.T, TG.busy, TG.clearClimate
local floor, near, out, setClimate, squareLoaded, stateName = TG.floor, TG.near, TG.out, TG.setClimate, TG.squareLoaded, TG.stateName
local teleport, try, walkTo = TG.teleport, TG.try, TG.walkTo
Steps.walk = {
	begin = function(r, st)
		st.laps = math.max(1, floor(st.a or 1))
		st.lap, st.index = 1, 0
		st.legs, st.legsOk = 0, 0
		if #r.plan.route < 2 then st.skip = "needs at least 2 route points" end
	end,
	tick = function(r, st, t)
		local p = r.p
		if st.legStart and busy(p) then
			if t - st.legStart > LEG_TIMEOUT_MS then
				ISTimedActionQueue.clear(p)
				T.trace(string.format("leg %d timeout at %.1f,%.1f,%d", st.index, p:getX(), p:getY(), floor(p:getZ())))
				st.legStart = nil
			end
			return false
		end
		if st.legStart then
			local pt = r.plan.route[st.index]
			local ok = near(p, pt, 1.5)
			if ok then st.legsOk = st.legsOk + 1 end
			T.trace(string.format("leg %d %s in %.1f s at %.1f,%.1f,%d", st.index, ok and "arrived" or "stopped short",
				(t - st.legStart) / 1000, p:getX(), p:getY(), floor(p:getZ())))
			st.legStart = nil
		end
		st.index = st.index + 1
		if st.index > #r.plan.route then
			st.lap = st.lap + 1
			st.index = 1
			if st.lap > st.laps then
				st.result = string.format("%d of %d legs arrived", st.legsOk, st.legs)
				return true
			end
		end
		local pt = r.plan.route[st.index]
		local ok, why = walkTo(p, pt.x, pt.y, pt.z, "vanilla")
		st.legs = st.legs + 1
		if ok then st.legStart = t else T.trace("leg " .. st.index .. " not started: " .. tostring(why)) end
		return false
	end,
}

Steps.stream = {
	begin = function(r, st)
		st.seconds = st.a or 60
		st.speed = st.b or 15        -- tiles (metres) per second; 15 is about 54 km/h
		st.seg, st.dir, st.pos = 1, 1, 0
		st.tiles = 0
		if #r.plan.road < 2 then st.skip = "needs at least 2 road points"; return end
		r.p:setGhostMode(true)   -- zombies ignore you while you sweep past
		local p0 = r.plan.road[1]
		teleport(r.p, p0.x, p0.y, p0.z)
		st.x, st.y = p0.x + 0.5, p0.y + 0.5
	end,
	tick = function(r, st, t, dt)
		local road = r.plan.road
		local move = st.speed * math.min(dt, 100) / 1000
		st.tiles = st.tiles + move
		while move > 0 do
			local a = road[st.seg]
			local b = road[st.seg + st.dir]
			if not b then
				st.dir = -st.dir
				b = road[st.seg + st.dir]
			end
			local bx, by = b.x + 0.5, b.y + 0.5
			local dx, dy = bx - st.x, by - st.y
			local d = math.sqrt(dx * dx + dy * dy)
			if d <= move then
				st.x, st.y = bx, by
				st.seg = st.seg + st.dir
				move = move - d
			else
				st.x, st.y = st.x + dx / d * move, st.y + dy / d * move
				move = 0
			end
		end
		pcall(function()
			r.p:getForwardDirection():set(1, 0)
			r.p:teleportTo(st.x, st.y, road[1].z or 0)
		end)
		if t - st.t0 >= st.seconds * 1000 then
			pcall(function() r.p:setGhostMode(r.wasGhost) end)
			st.result = string.format("%.0f tiles at %.0f tiles/s", st.tiles, st.speed)
			return true
		end
		return false
	end,
}

Steps.idle = {
	begin = function(r, st) st.seconds = st.a or 30 end,
	tick = function(r, st, t) return t - st.t0 >= st.seconds * 1000 end,
}

local TURNS = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }
Steps.turn = {
	begin = function(r, st) st.seconds = st.a or 30; st.turns = 0; st.next = 0 end,
	tick = function(r, st, t)
		if t - st.t0 >= st.next then
			st.turns = st.turns + 1
			local d = TURNS[(st.turns % 4) + 1]
			pcall(function() r.p:getForwardDirection():set(d[1], d[2]) end)
			st.next = st.next + 500
		end
		if t - st.t0 >= st.seconds * 1000 then
			st.result = st.turns .. " turns"
			return true
		end
		return false
	end,
}

-- look S [facing|mouse] (or a name with either in it): 1.13.19 (the user: with Project Viewpoint you turn your head and change where
-- you look; does looking around at will cause trouble, in isometric and in third and first person?).
-- For S seconds (30 by default) the view is swept two full circles: "facing" turns the character a
-- step a tick, "mouse" moves the cursor round the screen in a figure eight (left-right twice, up-down
-- four times) the way a hand on the mouse would. The result says how far the facing and the look
-- angle really turned, so a way that doesn't move the view shows as 0. Frames are measured as for
-- any step; the plan's viewpoint line picks the view.
local function angDiff(a, b)
	local d = (a - b) % 360
	if d > 180 then d = d - 360 end
	return d
end
Steps.look = {
	begin = function(r, st)
		st.seconds = st.a or 30
		st.how = "facing"
		for i = 2, #(st.args or {}) do
			local w = string.lower(tostring(st.args[i]))
			-- the way is any word with mouse or facing in it, so the step's name can say it (look 30 look_mouse)
			if string.find(w, "mouse", 1, true) then st.how = "mouse" elseif string.find(w, "facing", 1, true) then st.how = "facing" end
		end
		if st.how == "mouse" and not (Mouse and Mouse.setXY) then st.skip = "Mouse.setXY isn't reachable from Lua"; return end
		st.turned, st.looked, st.moves = 0, 0, 0
		pcall(function() st.face0 = r.p:getDirectionAngle() end)
		st.phi0 = math.rad(st.face0 or 0)
		-- 1.13.20 (review of 1.13.19): facing and the mouse go back however the step ends
		if not r.cleanup then
			r.cleanup = function()
				pcall(function() if st.face0 and r.p.setDirectionAngle then r.p:setDirectionAngle(st.face0) end end)
				if st.mx0 then pcall(function() Mouse.setXY(st.mx0, st.my0) end) end
			end
		end
		pcall(function() st.look0 = math.deg(r.p:getLookAngleRadians()) end)
		st.lastFace, st.lastLook = st.face0, st.look0
		if st.how == "mouse" then
			pcall(function() st.mx0, st.my0 = Mouse.getX(), Mouse.getY() end)
			pcall(function() st.w, st.h = getCore():getScreenWidth(), getCore():getScreenHeight() end)
			st.w, st.h = st.w or 1280, st.h or 720
		end
	end,
	tick = function(r, st, t)
		local p = r.p
		local f = math.min(1, (t - st.t0) / (st.seconds * 1000))
		local phi = (st.phi0 or 0) + f * 4 * math.pi   -- two full circles, from where the character faces
		if st.how == "facing" then
			pcall(function()
				local deg = math.deg(phi) % 360
				if p.setDirectionAngle then p:setDirectionAngle(deg) end
				p:getForwardDirection():set(math.cos(phi), math.sin(phi))
			end)
		else
			pcall(function()
				Mouse.setXY(floor(st.w / 2 + st.w * 0.4 * math.sin(phi)), floor(st.h / 2 + st.h * 0.35 * math.sin(2 * phi)))
				st.moves = st.moves + 1
			end)
		end
		pcall(function()
			local a = p:getDirectionAngle()
			if st.lastFace then st.turned = st.turned + math.abs(angDiff(a, st.lastFace)) end
			st.lastFace = a
		end)
		pcall(function()
			local a = math.deg(p:getLookAngleRadians())
			if st.lastLook then st.looked = st.looked + math.abs(angDiff(a, st.lastLook)) end
			st.lastLook = a
		end)
		if f >= 1 then
			if st.how == "mouse" and st.mx0 then pcall(function() Mouse.setXY(st.mx0, st.my0) end) end
			pcall(function() if st.face0 and r.p.setDirectionAngle then r.p:setDirectionAngle(st.face0) end end)
			st.result = string.format("looked round by %s for %d s: facing turned %.0f deg, look angle turned %.0f deg%s (in the %s view)",
				st.how, st.seconds, st.turned, st.looked, st.how == "mouse" and string.format(", %d cursor moves", st.moves) or "",
				tostring(K.viewNow and K.viewApi and K.viewApi() and K.viewNow() or "isometric"))
			T.trace("look: " .. st.result)
			return true
		end
		return false
	end,
}

Steps.wait = {
	begin = function(r, st)
		st.seconds = st.a or 120
		st.speed = math.max(1, math.min(3, floor(st.b or 1)))
		st.minute0 = getGameTime():getMinutesStamp()
		if st.speed > 1 then try("game speed", function() T.setSpeed(st.speed) end) end
	end,
	tick = function(r, st, t)
		if t - st.t0 >= st.seconds * 1000 then
			if st.speed > 1 then try("game speed", function() T.setSpeed(S.run and S.run.speed or 1) end) end
			local minutes = 0
			pcall(function() minutes = getGameTime():getMinutesStamp() - st.minute0 end)
			st.result = string.format("%d in-game minutes passed at speed %d", minutes, st.speed)
			return true
		end
		return false
	end,
}

Steps.walkto = {
	begin = function(r, st)
		st.i = 0
		st.phase = "next"
		st.pass, st.failed = 0, 0
		if #r.plan.cases == 0 then st.skip = "no walkto cases in the plan" end
	end,
	tick = function(r, st, t, dt)
		local p = r.p
		local c = r.plan.cases[st.i]
		if st.phase == "next" then
			st.i = st.i + 1
			c = r.plan.cases[st.i]
			if not c then
				st.result = string.format("%d of %d cases as expected", st.pass, #r.plan.cases)
				return true
			end
			ISTimedActionQueue.clear(p)
			teleport(p, c.from.x, c.from.y, c.from.z)
			st.phase, st.tPhase = "settle", t
		elseif st.phase == "settle" then
			if t - st.tPhase >= 2000 and squareLoaded(c.to.x, c.to.y, c.to.z) then
				local ok, why = walkTo(p, c.to.x, c.to.y, c.to.z, c.via)
				st.walked, st.states, st.lastState, st.lastX, st.lastY = 0, {}, nil, p:getX(), p:getY()
				st.maxZ = floor(p:getZ())
				if not ok then
					st.why = why
					st.phase, st.tPhase = "done", t
				else
					T.trace("walkto " .. c.name .. " start (" .. c.via .. ")")
					st.phase, st.tPhase = "walking", t
				end
			elseif t - st.tPhase > 15000 then
				st.why = "target square never loaded"
				st.phase, st.tPhase = "done", t
			end
		elseif st.phase == "walking" then
			local x, y = p:getX(), p:getY()
			local dx, dy = x - st.lastX, y - st.lastY
			st.walked = st.walked + math.sqrt(dx * dx + dy * dy)
			st.lastX, st.lastY = x, y
			if floor(p:getZ()) > st.maxZ then st.maxZ = floor(p:getZ()) end
			local s = stateName(p)
			if s ~= st.lastState then
				st.lastState = s
				if not st.states[s] then
					st.states[s] = true
					table.insert(st.states, s)
				end
			end
			-- Give a just-queued action a moment to start before reading "not busy" as finished.
			if (t - st.tPhase > 500 and not busy(p)) or t - st.tPhase > LEG_TIMEOUT_MS then
				if busy(p) then ISTimedActionQueue.clear(p); st.why = "timeout" end
				st.phase = "done"
			end
		end
		if st.phase == "done" then
			local arrived = near(p, c.to, 1.5)
			local outcome = arrived and "arrive" or "fail"
			local asExpected = c.expect == "any" or c.expect == outcome
			if asExpected then st.pass = st.pass + 1 else st.failed = st.failed + 1 end
			local line = string.format("walkto %s: %s%s, %.1f s, walked %.1f tiles, top floor %d, states %s -> %s",
				c.name, outcome, st.why and (" (" .. st.why .. ")") or "", (t - (st.tPhase or t)) / 1000,
				st.walked or 0, st.maxZ or 0, table.concat(st.states or {}, ","),
				asExpected and "as expected" or ("EXPECTED " .. string.upper(c.expect)))
			T.trace(line)
			out("  " .. line)
			st.why = nil
			st.phase = "next"
		end
		return false
	end,
}

-- drive S [speed] [-1]: fast travel. Out along the plan's drive direction (drive = x,y, default
-- east; -1 reverses it) for half of S, then straight back to the start, in ghost mode. There is
-- no vehicle: chunks load at driving speed, but vehicle physics and vehicle Lua don't run.

Steps.weather = {
	begin = function(r, st)
		local w = string.lower(tostring(st.args[2] or "clear"))
		st.weather = w
		if w == "keep" then clearClimate()
		elseif w == "clear" then setClimate("rain", 0); setClimate("fog", 0); setClimate("cloud", 0); setClimate("wind", 0)
		elseif w == "rain" then setClimate("rain", 0.8); setClimate("cloud", 1); setClimate("fog", 0)
		elseif w == "fog" then setClimate("fog", 1); setClimate("rain", 0)
		else st.skip = "unknown weather " .. w .. " (clear, rain, fog or keep)"; return end
		T.trace("weather now " .. w)
	end,
	tick = function(r, st)
		st.result = st.result or ("weather now " .. tostring(st.weather))
		return true
	end,
}

-- stress N S [D]: N zombies (500 by default) are spawned in a ring D to D+15 tiles out (20 by
-- default), 25 a tick so there's no single spawn burst, and lured to you every few seconds; you
-- stand there for S seconds in ghost mode while they crowd round. Then every zombie and
-- every body within 45 tiles is removed. The report gives how many were alive and seen at the peak.
K.STRESS_BATCH = 25

local LOOT_ITEMS = 3
local LOOT_TIMEOUT_MS = 30000

local function containerOn(sq)
	local objs = sq:getObjects()
	for i = 0, objs:size() - 1 do
		local o = objs:get(i)
		if not instanceof(o, "IsoDeadBody") then
			local c = o:getContainer()
			if c then return c end
		end
	end
	return nil
end

-- A free square next to the container, in the same room, to stand on when it can't be walked to.
local NEIGHBOURS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }
local function besideContainer(sq)
	local room = nil
	pcall(function() room = sq:getRoom() end)
	local cell = getCell()
	for _, d in ipairs(NEIGHBOURS) do
		local n = cell:getGridSquare(sq:getX() + d[1], sq:getY() + d[2], sq:getZ())
		if n then
			local ok, good = pcall(function()
				return n:getFloor() ~= nil and n:isFree(false) and (room == nil or n:getRoom() == room)
			end)
			if ok and good then return n end
		end
	end
	return nil
end

local function transferAction(p, item, from, to)
	if ISInventoryTransferUtil and ISInventoryTransferUtil.newInventoryTransferAction then
		return ISInventoryTransferUtil.newInventoryTransferAction(p, item, from, to)
	end
	return ISInventoryTransferAction:new(p, item, from, to)
end

-- 1.13.2: items the loot step took out and hasn't put back yet (a timeout, a stop) go straight
-- back into their container. Returns how many.
function K.lootBack(r)
	local lo = r.lootOut
	r.lootOut = nil
	if not lo then return 0 end
	local n = 0
	pcall(function()
		local inv = r.p:getInventory()
		for _, item in ipairs(lo.items) do
			if inv:contains(item) then
				inv:Remove(item)
				lo.c:AddItem(item)
				n = n + 1
			end
		end
	end)
	return n
end

Steps.loot = {
	begin = function(r, st)
		st.i, st.phase = 0, "next"
		st.reached, st.moved, st.items, st.teleported = 0, 0, 0, 0
		if #r.plan.loot == 0 then st.skip = "no loot points in the plan"; return end
		pcall(function() r.p:setGhostMode(false) end)
	end,
	tick = function(r, st, t)
		local p = r.p
		if st.phase == "next" then
			st.i = st.i + 1
			local pt = r.plan.loot[st.i]
			if not pt then
				st.result = string.format("%d of %d containers reached (%d by teleport), %d items seen, %d moved out and back",
					st.reached, #r.plan.loot, st.teleported, st.items, st.moved)
				return true
			end
			st.pt = pt
			st.sq = getCell():getGridSquare(pt.x, pt.y, pt.z)
			if not st.sq then T.trace(string.format("loot %d %d,%d,%d: square not loaded", st.i, pt.x, pt.y, pt.z)); return false end
			local ok, res = pcall(function() return luautils.walkAdj(p, st.sq, false) end)
			if not ok or res == false then
				T.trace(string.format("loot %d %d,%d,%d: no way to walk next to it", st.i, pt.x, pt.y, pt.z))
			end
			st.phase, st.phaseT = "walk", t
			return false
		end
		if st.phase == "walk" then
			if busy(p) and t - st.phaseT < LOOT_TIMEOUT_MS then return false end
			ISTimedActionQueue.clear(p)
			local dx, dy = p:getX() - (st.pt.x + 0.5), p:getY() - (st.pt.y + 0.5)
			st.here = dx * dx + dy * dy <= 2.5 * 2.5 and floor(p:getZ()) == st.pt.z
			st.how = "reached"
			if not st.here then
				-- couldn't walk there (locked or barricaded building, blocked path): stand beside it
				local n = besideContainer(st.sq)
				if n and teleport(p, n:getX(), n:getY(), n:getZ()) then
					st.here, st.how = true, "teleported beside it"
					st.teleported = st.teleported + 1
				end
			end
			if st.here then st.reached = st.reached + 1 end
			st.walkS = (t - st.phaseT) / 1000
			st.phase, st.phaseT = "look", t
			return false
		end
		if st.phase == "look" then
			if t - st.phaseT < 1500 then return false end
			st.took = 0
			local ok, n = pcall(function()
				local c = containerOn(st.sq)
				if not c then return -1 end
				local items = c:getItems()
				local count = items:size()
				local inv = p:getInventory()
				local picked = {}
				for i = 0, math.min(count, LOOT_ITEMS) - 1 do picked[#picked + 1] = items:get(i) end
				for _, item in ipairs(picked) do ISTimedActionQueue.add(transferAction(p, item, c, inv)) end
				for _, item in ipairs(picked) do ISTimedActionQueue.add(transferAction(p, item, inv, c)) end
				st.took = #picked
				r.lootOut = { items = picked, c = c }
				return count
			end)
			if not ok then T.trace("loot " .. st.i .. ": " .. tostring(n)) end
			st.seen = ok and n or -1
			if st.seen > 0 then st.items = st.items + st.seen end
			st.phase, st.phaseT = "move", t
			return false
		end
		if st.phase == "move" then
			if busy(p) and t - st.phaseT < LOOT_TIMEOUT_MS then return false end
			ISTimedActionQueue.clear(p)
			if st.here then st.moved = st.moved + st.took end
			local back = K.lootBack(r)
			if back > 0 then T.trace(string.format("loot %d: %d items still in the inventory at the timeout, put straight back", st.i, back)) end
			T.trace(string.format("loot %d %d,%d,%d: %s in %.1f s, %s, moved %d out and back in %.1f s", st.i, st.pt.x, st.pt.y, st.pt.z,
				st.here and st.how or "NOT reached", st.walkS,
				st.seen < 0 and "no container" or (st.seen .. " items"), st.took, (t - st.phaseT) / 1000))
			st.phase = "next"
			return false
		end
		return false
	end,
}

-- Run control ------------------------------------------------------------------------------

TG.LOOT_ITEMS, TG.LOOT_TIMEOUT_MS, TG.NEIGHBOURS, TG.TURNS, TG.besideContainer, TG.containerOn = LOOT_ITEMS, LOOT_TIMEOUT_MS, NEIGHBOURS, TURNS, besideContainer, containerOn
TG.transferAction = transferAction
