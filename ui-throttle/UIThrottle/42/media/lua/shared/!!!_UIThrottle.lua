--
-- UI Throttle (performance patch), the part that has to load early.
--
-- 3. Take A Bath And Shower sets its body grime moodle on every player update (client/
--    TABAS_BodyGrime.lua, moodleUpdate). The moodle has four levels, set from a grime value that
--    moves over in-game hours, and Moodle Framework keeps the value it was given. Here the same
--    function runs at most every MOODLE_MS per player. (This was part 5 of Hitch Fix 1.2.)
--
-- The handler is caught as it registers, by file name, so this file is in shared/ (loaded before
-- every client/ file) and its name sorts after "!!!LuaEventProfiler.lua".
--

if UIThrottleEarly then return end
UIThrottleEarly = {}

local ENABLE_TABAS_MOODLE = true
local MOODLE_MS = 250   -- the grime moodle is set at most this often per player

local TABAS_FILE = "client/TABAS_BodyGrime.lua"

local function fileOf(fn)
	local P = LuaEventProfiler
	local orig = P and P.originalOf and P.originalOf[fn]
	local ok, name = pcall(getFilenameOfClosure, orig or fn)
	if ok and name then return (string.gsub(tostring(name), "\\", "/")) end
	return nil
end

local function throttled(fn)
	local lastAt = {}
	return function(player, ...)
		local key = player and player.getIndex and player:getIndex() or 0
		local now = getTimestampMs()
		local last = lastAt[key]
		if last and now - last < MOODLE_MS and now >= last then return end
		lastAt[key] = now
		return fn(player, ...)
	end
end

local ev = Events and Events.OnPlayerUpdate
if ENABLE_TABAS_MOODLE and type(ev) == "table" and type(ev.Add) == "function" then
	local realAdd, realRemove = ev.Add, ev.Remove
	local wrapperOf = {}
	local caught = false   -- one handler only; Kahlua has no next()
	ev.Add = function(fn)
		if type(fn) == "function" and not caught then
			local path = fileOf(fn)
			if path and #path >= #TABAS_FILE and string.sub(path, -#TABAS_FILE) == TABAS_FILE then
				local w = throttled(fn)
				wrapperOf[fn] = w
				caught = true
				local P = LuaEventProfiler
				if P and P.sourceOf then P.sourceOf[w] = fn end
				print("[UIThrottle] caught " .. TABAS_FILE .. " (grime moodle at most every " .. MOODLE_MS .. " ms)")
				UIThrottleEarly.tabas = true
				return realAdd(w)
			end
		end
		return realAdd(fn)
	end
	if type(realRemove) == "function" then
		ev.Remove = function(fn)
			local w = wrapperOf[fn]
			if w then wrapperOf[fn] = nil; caught = false return realRemove(w) end
			return realRemove(fn)
		end
	end
end
