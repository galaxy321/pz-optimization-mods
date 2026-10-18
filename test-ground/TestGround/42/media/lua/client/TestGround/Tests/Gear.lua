-- Test Ground 1.13.2: gear and car loot: goggles on and off, and the loot window beside a parked car.
require "TestGround/Core"
require "TestGround/Tests/Drive"
local TG = TestGroundInternal
if TG.loaded.Gear then return end
TG.loaded.Gear = true
local K, Steps, T, floor = TG.K, TG.Steps, TG.T, TG.floor
local near, teleport, try = TG.near, TG.teleport, TG.try
table.insert(K.GROUPS.idle, "goggles")
table.insert(K.GROUPS.idle, "carloot")

-- goggles S [every] [item=Module.Name]: night-vision goggles are put on and taken off every
-- `every` seconds (default 3) for S seconds, the way the Wear menu does it (setWornItem, then
-- OnClothingUpdated), so whatever checks worn items for night vision (Night Vision Framework's
-- IsNVTaggedItem, Hitch Fix's cache of it) runs on each change. The item is the plan's, or the
-- first of K.GOGGLES that exists, or one Night Vision Framework has registered. Taken away after.
K.GOGGLES = { "Base.Glasses_NightVision", "Base.NightVisionGoggles", "Base.NVG_PNV-10T_DOWN", "Base.NVG_GPNVG-18_DOWN", "Base.NVG_ANPVS-14_DOWN" }
function K.findItemType(list)
	local sm = getScriptManager()
	for _, id in ipairs(list) do
		local ok, it = pcall(function() return sm:FindItem(id) end)
		if ok and it then return id end
	end
	return nil
end
function K.goggleType(want)
	if want then return K.findItemType({ want }) end
	local id = K.findItemType(K.GOGGLES)
	if id then return id end
	local reg = {}
	pcall(function() for ft in pairs(NV.Shared.REGISTERED_NIGHT_VISION_ITEMS) do reg[#reg + 1] = ft end end)
	table.sort(reg)
	return K.findItemType(reg)
end
local function wear(p, item, on)
	local ok = pcall(function()
		if on then p:setWornItem(item:getBodyLocation(), item) else p:removeWornItem(item) end
	end)
	pcall(function() triggerEvent("OnClothingUpdated", p) end)
	return ok
end
Steps.goggles = {
	begin = function(r, st)
		st.seconds = st.a or 30
		st.every = math.max(0.5, st.b or 3)
		local want = nil
		for w in string.gmatch(st.text or "", "%S+") do
			local k, v = string.match(w, "^([%w_]+)=(%S+)$")
			if k and string.lower(k) == "item" then want = v end
		end
		local id = K.goggleType(want)
		if not id then st.skip = "no night-vision goggles item found (" .. (want or table.concat(K.GOGGLES, ", ")) .. "; item=<id> names one)"; return end
		local ok, item = pcall(function() return r.p:getInventory():AddItem(id) end)
		if not ok or not item then st.skip = "could not add " .. id; return end
		st.id, st.item, st.ons, st.offs, st.fails, st.on = id, item, 0, 0, 0, false
		st.next = 1000
		r.cleanup = function() wear(r.p, item, false); pcall(function() r.p:getInventory():Remove(item) end) end
	end,
	tick = function(r, st, t)
		local el = t - st.t0
		if el >= st.next then
			st.next = el + st.every * 1000
			st.on = not st.on
			if wear(r.p, st.item, st.on) then
				if st.on then st.ons = st.ons + 1 else st.offs = st.offs + 1 end
			else
				st.fails = st.fails + 1
			end
		end
		if el < st.seconds * 1000 then return false end
		if r.cleanup then pcall(r.cleanup); r.cleanup = nil end
		local nv = NV and NV.Shared and NV.Shared.IsNVTaggedItem and "Night Vision Framework is loaded" or "no Night Vision Framework"
		st.result = string.format("%s put on %d times and taken off %d times (every %g s)%s; %s",
			st.id, st.ons, st.offs, st.every, st.fails > 0 and string.format(", %d FAILED", st.fails) or "", nv)
		return true
	end,
}

-- carloot S [N]: a car (the first of the fast drive's cars there is) is parked 2 tiles east of the
-- start, and you take a single step (one tile) along it every 1.5 s, back and forth over N squares
-- (default 6), so the loot window lists its containers again at each step. The car is removed after.
K.CARLOOT_STEP_MS = 1500
Steps.carloot = {
	begin = function(r, st)
		st.seconds = st.a or 30
		st.span = math.max(2, floor(st.b or 6))
		local home = r.plan.start or r.home
		if home and not near(r.p, home, 3) then teleport(r.p, home.x, home.y, home.z) end
		local x, y, z = floor(r.p:getX()), floor(r.p:getY()), floor(r.p:getZ())
		local sq = getCell():getGridSquare(x + 2, y, z)
		if not sq then st.skip = "the square beside the start isn't loaded"; return end
		local v, name = TG.spawnFastCar(sq, 0, 1)
		if not v then st.skip = "could not park a car"; return end
		st.car, st.name, st.x0, st.y0, st.z = v, name, x, y - floor(st.span / 2), z
		st.containers = 0
		pcall(function()
			for i = 0, v:getPartCount() - 1 do
				if v:getPartByIndex(i):getItemContainer() then st.containers = st.containers + 1 end
			end
		end)
		st.i, st.dir, st.steps, st.next = 0, 1, 0, 1000
		teleport(r.p, st.x0, st.y0, z)
		r.cleanup = function()
			if not pcall(function() v:permanentlyRemove() end) then pcall(function() v:removeFromWorld() end) end
		end
	end,
	tick = function(r, st, t)
		local el = t - st.t0
		if el >= st.next then
			st.next = el + K.CARLOOT_STEP_MS
			if st.i + st.dir < 0 or st.i + st.dir > st.span then st.dir = -st.dir end
			st.i = st.i + st.dir
			pcall(function()
				r.p:setX(st.x0 + 0.5); r.p:setY(st.y0 + st.i + 0.5)
				r.p:getForwardDirection():set(1, 0)
			end)
			st.steps = st.steps + 1
		end
		if el < st.seconds * 1000 then return false end
		if r.cleanup then pcall(r.cleanup); r.cleanup = nil end
		st.result = string.format("%s parked beside you (%d parts with a container), %d single steps along it over %d squares", tostring(st.name), st.containers, st.steps, st.span + 1)
		return true
	end,
}
