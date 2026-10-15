--
-- UI Throttle (performance patch).
--
-- 1. Loot window while moving. ISInventoryPage:update (vanilla, and CleanUI's copy of it) calls
--    refreshBackpacks() whenever the player's square or facing changed since the last frame, so
--    the loot window rebuilt its whole list of nearby containers on every square crossed, and
--    every OnRefreshInventoryWindowContainers listener (The Shortcut, Better Sorting, ...) ran
--    with it. With CleanUI one rebuild measured 12-16 ms: a visible hitch per square. This still
--    rebuilds at once, as vanilla does, whenever anything the window would list has changed, but
--    skips the rebuild when the move changed nothing: an empty street on foot, or any move inside
--    the same vehicle. Every other reason to refresh is untouched.
--
-- 2. Exact Minute Clock. Its updateState() walks every worn item (and, without a worn clock, the
--    whole inventory) on every rendered frame to find the watch. This runs it at most every
--    CLOCK_MS; the clock still draws every frame from the last result.
--

if UIThrottle then return end
UIThrottle = {}

local CLOCK_MS = 200

local now = getTimestampMs

-- What the loot window would list around a player on foot, as a flat list of Java objects: for
-- each of the 3x3 squares refreshBackpacks looks at, every item on the floor, every corpse or
-- object container, the vehicle parked there, and whether the square can be reached. Empty
-- squares add nothing, so walking down an empty street gives the same (empty) list every step.
local function footSignature(p, out)
	local n = 0
	local cell = getCell()
	local cur = p:getCurrentSquare()
	local x, y, z = p:getX(), p:getY(), p:getZ()
	for dy = -1, 1 do
		for dx = -1, 1 do
			local gs = cell:getGridSquare(x + dx, y + dy, z)
			if gs then
				local start = n
				local wobs = gs:getWorldObjects()
				for i = 0, wobs:size() - 1 do
					n = n + 1; out[n] = wobs:get(i):getItem() or false
				end
				local sobs = gs:getStaticMovingObjects()
				for i = 0, sobs:size() - 1 do
					local c = sobs:get(i):getContainer()
					if c then n = n + 1; out[n] = c end
				end
				local obs = gs:getObjects()
				for i = 0, obs:size() - 1 do
					local o = obs:get(i)
					for c = 0, o:getContainerCount() - 1 do
						n = n + 1; out[n] = o:getContainerByIndex(c)
					end
				end
				local v = gs:getVehicleContainer()
				if v then n = n + 1; out[n] = v end
				if n > start then
					-- Something lootable here: which square it is, and whether a wall is in the way.
					n = n + 1; out[n] = gs
					n = n + 1; out[n] = (gs == cur) or (cur ~= nil and cur:canReachTo(gs)) or false
				end
			end
		end
	end
	if n > 0 then
		-- Facing picks which nearby container is selected, as in vanilla, so it only matters
		-- when there is something nearby.
		n = n + 1; out[n] = p:getDir()
	end
	for i = n + 1, #out do out[i] = nil end
	return n
end

local function sameList(a, b, n)
	if #b ~= n then return false end
	for i = 1, n do
		if a[i] ~= b[i] then return false end
	end
	return true
end

local function throttleLootRefresh(cls, label)
	if type(cls) ~= "table" or rawget(cls, "__uiThrottled") then return false end
	local orig = rawget(cls, "update")
	if type(orig) ~= "function" then return false end

	cls.update = function(self, ...)
		if not self.onCharacter then
			local p = getSpecificPlayer(self.player)
			if p then
				local sq, dir = p:getCurrentSquare(), p:getDir()
				if self.lastDir ~= dir or self.lastSquare ~= sq then
					local vehicle = p:getVehicle()
					local skip = false
					if vehicle then
						-- In a vehicle the loot window lists that vehicle's own containers, which
						-- moving does not change.
						skip = (self.__uitVehicle == vehicle)
						self.__uitSig = nil
					elseif self.__uitVehicle == nil then
						local new = self.__uitNew or {}
						local n = footSignature(p, new)
						local old = self.__uitSig
						skip = old ~= nil and sameList(new, old, n)
						self.__uitSig, self.__uitNew = new, old
					else
						self.__uitSig = nil
					end
					self.__uitVehicle = vehicle or nil
					if skip then
						-- Nothing to loot changed: hide the move from the original.
						self.lastDir, self.lastSquare = dir, sq
					end
				end
			end
		end
		return orig(self, ...)
	end
	cls.__uiThrottled = true
	print("[UIThrottle] loot window skips rebuilds when nothing nearby changed (" .. label .. ")")
	return true
end

local function throttleClock()
	local C = ExactMinuteClock
	if type(C) ~= "table" or rawget(C, "__uiThrottled") then return end
	local orig = rawget(C, "updateState")
	if type(orig) ~= "function" then return end
	C.updateState = function(self, ...)
		local t = now()
		local last = self.__uitAt
		if last and t >= last and t - last < CLOCK_MS then return end
		self.__uitAt = t
		return orig(self, ...)
	end
	C.__uiThrottled = true
	print("[UIThrottle] Exact Minute Clock watch check throttled")
end

local function install()
	throttleLootRefresh(ISInventoryPage, "ISInventoryPage")
	throttleLootRefresh(CleanUI_Vanilla_ISInventoryPage, "CleanUI_Vanilla_ISInventoryPage")
	throttleClock()
end

Events.OnGameStart.Add(install)

-- CleanUI can load its other inventory class later, when its UI mode is switched; pick it up then.
local ticks = 0
Events.OnTick.Add(function()
	ticks = ticks + 1
	if ticks % 600 == 0 then install() end
end)
