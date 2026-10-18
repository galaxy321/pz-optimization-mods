--
-- Lua Event Profiler (diagnostic).
--
-- Every Events.<Name>.Add made after this file loads gets a wrapper that adds the time the
-- handler took to a counter for the file that defined the handler. At game start it also
-- wraps render/prerender of every Lua UI class whose code lives in a mod, so mod HUDs show
-- up too. Every REPORT_SECONDS it prints the most expensive handlers and mods.
--
-- The file name starts with "!!!" so it sorts before other mods' shared files and is in
-- place before they register handlers. Handlers registered before it (vanilla shared files)
-- are not timed.
--
-- Timing uses getTimestampMs(), which only has millisecond steps. One call is usually
-- "0 ms" or "1 ms", but over thousands of calls the sum averages out to the real cost.
--

if LuaEventProfiler then return end
LuaEventProfiler = {}
local P = LuaEventProfiler
P.originalOf = setmetatable({}, { __mode = "k" })  -- timed wrapper -> handler, for other patches
-- Another patch that registers its own wrapper around a mod's handler sets sourceOf[wrapper] = handler,
-- so the time is still reported under the mod that wrote the handler.
P.sourceOf = setmetatable({}, { __mode = "k" })

local REPORT_SECONDS = 30
local TOP = 20
local SPIKE_MS = 8       -- log any single handler call at least this long
local HITCH_MS = 100     -- log any gap between ticks at least this long

-- Per-frame bookkeeping for hitch reports.
local frameLua = 0
local frameWorst, frameWorstMs = nil, 0
local lastTick = nil
local spikeCount = 0

local now = getTimestampMs
local stats = {}       -- key -> { label, mod, ms, calls }
local wrappedOf = {}   -- event name -> { [original fn] = wrapped fn }
local windowStart = now()
local sessionStart = windowStart
local totals = {}      -- key -> { label, mod, ms, calls } over the whole session

local function fileOf(fn)
	local ok, name = pcall(getFilenameOfClosure, P.sourceOf[fn] or fn)
	if ok and name then return tostring(name) end
	return nil
end

local function modOf(path)
	if not path then return "?" end
	local m = string.match(path, "[/\\]mods[/\\]([^/\\]+)")
	if m then return m end
	return "vanilla"
end

local function shortPath(path)
	if not path then return "?" end
	local a, b = string.match(path, "([^/\\]+)[/\\]([^/\\]+)$")
	if a then return a .. "/" .. b end
	return path
end

local function counter(key, label, mod)
	local s = stats[key]
	if not s then
		s = { label = label, mod = mod, ms = 0, calls = 0 }
		stats[key] = s
	end
	return s
end

local function timed(fn, key, label, mod)
	return function(...)
		local s = stats[key] or counter(key, label, mod)
		local t0 = now()
		local a, b, c, d = fn(...)
		local dt = now() - t0
		s.ms = s.ms + dt
		s.calls = s.calls + 1
		if dt > 0 then
			frameLua = frameLua + dt
			if dt > frameWorstMs then frameWorst, frameWorstMs = s, dt end
			if dt > (s.max or 0) then s.max = dt end
			if dt >= SPIKE_MS and spikeCount < 200 then
				spikeCount = spikeCount + 1
				print(string.format("[LuaEventProfiler] spike %d ms [%s] %s", dt, s.mod, s.label))
			end
		end
		return a, b, c, d
	end
end

local function wrapEvent(eventName, event)
	if type(event) ~= "table" or event.__lepWrapped then return end
	local add, remove = event.Add, event.Remove
	if type(add) ~= "function" then return end
	local map = {}
	wrappedOf[eventName] = map
	event.Add = function(fn)
		if type(fn) ~= "function" then return add(fn) end
		local path = fileOf(fn)
		local mod = modOf(path)
		local label = eventName .. "  " .. shortPath(path)
		local key = eventName .. "|" .. tostring(path) .. "|" .. tostring(fn)
		local w = timed(fn, key, label, mod)
		map[fn] = w
		P.originalOf[w] = fn
		return add(w)
	end
	if type(remove) == "function" then
		event.Remove = function(fn)
			local w = map[fn]
			if w then
				map[fn] = nil
				return remove(w)
			end
			return remove(fn)
		end
	end
	event.__lepWrapped = true
end

local function wrapAllEvents()
	if not Events then return end
	for name, event in pairs(Events) do
		pcall(wrapEvent, name, event)
	end
end

local function wrapUIClasses()
	local n = 0
	for name, cls in pairs(_G) do
		if type(cls) == "table" and type(name) == "string" and rawget(cls, "Type") ~= nil then
			for _, method in ipairs({ "prerender", "render", "update" }) do
				local fn = rawget(cls, method)
				if type(fn) == "function" then
					local path = fileOf(fn)
					local mod = modOf(path)
					if mod ~= "vanilla" and mod ~= "?" and mod ~= "LuaEventProfiler" then
						local key = "UI|" .. name .. "." .. method
						cls[method] = timed(fn, key, "UI " .. name .. ":" .. method .. "  " .. shortPath(path), mod)
						n = n + 1
					end
				end
			end
		end
	end
	print("[LuaEventProfiler] timing " .. n .. " UI render/update methods from mods")
end

-- Vehicle scripts name Lua functions as strings ("Vehicles.Update.Engine") and the engine looks
-- them up when it calls them, for every loaded vehicle part. Those calls are not events, so they
-- are wrapped here in place. Covers Vehicles.* and the same sub-table names on other globals
-- (mods such as damnlib keep their own Create/Init/Update tables).
local VEHICLE_SUBTABLES = { "Create", "Init", "Update", "Use", "ContainerAccess", "InstallComplete",
	"UninstallComplete", "InstallTest", "UninstallTest", "Test" }

local function wrapFunctionTable(prefix, tbl)
	local n = 0
	for fname, fn in pairs(tbl) do
		if type(fn) == "function" and type(fname) == "string" then
			local path = fileOf(fn)
			local mod = modOf(path)
			if mod ~= "LuaEventProfiler" then
				local key = "VEH|" .. prefix .. "." .. fname
				tbl[fname] = timed(fn, key, prefix .. "." .. fname .. "  " .. shortPath(path), mod)
				n = n + 1
			end
		end
	end
	return n
end

local wrappedTables = {}

local function wrapVehicleFunctions()
	local n = 0
	for gname, g in pairs(_G) do
		if type(g) == "table" and type(gname) == "string" and rawget(g, "Type") == nil and g ~= LuaEventProfiler then
			for _, sub in ipairs(VEHICLE_SUBTABLES) do
				local t = rawget(g, sub)
				if type(t) == "table" and not wrappedTables[t] then
					wrappedTables[t] = true
					n = n + wrapFunctionTable(gname .. "." .. sub, t)
				end
			end
		end
	end
	print("[LuaEventProfiler] timing " .. n .. " vehicle script functions")
end

local function sorted(tbl)
	local list = {}
	for _, s in pairs(tbl) do
		if s.calls > 0 then list[#list + 1] = s end
	end
	table.sort(list, function(x, y) return x.ms > y.ms end)
	return list
end

local function byMod(tbl)
	local mods = {}
	for _, s in pairs(tbl) do
		local m = mods[s.mod]
		if not m then
			m = { label = s.mod, mod = s.mod, ms = 0, calls = 0 }
			mods[s.mod] = m
		end
		m.ms = m.ms + s.ms
		m.calls = m.calls + s.calls
		if (s.max or 0) > (m.max or 0) then m.max = s.max end
	end
	return sorted(mods)
end

local function fmt(s, seconds)
	local perSec = seconds > 0 and s.ms / seconds or 0
	local perCall = s.calls > 0 and (s.ms * 1000) / s.calls or 0
	return string.format("%8.1f ms/s %9d calls %8.1f us/call max %4d ms  [%s] %s", perSec, s.calls, perCall, s.max or 0, s.mod, s.label)
end

local function report()
	local t = now()
	local seconds = (t - windowStart) / 1000
	if seconds <= 0 then return end
	local lines = {}
	local function out(line) lines[#lines + 1] = line end

	-- Fold this window into the session totals.
	for key, s in pairs(stats) do
		local tot = totals[key]
		if not tot then
			tot = { label = s.label, mod = s.mod, ms = 0, calls = 0 }
			totals[key] = tot
		end
		tot.ms = tot.ms + s.ms
		tot.calls = tot.calls + s.calls
		if (s.max or 0) > (tot.max or 0) then tot.max = s.max end
	end
	local player = getSpecificPlayer and getSpecificPlayer(0)
	local driving = player and player.getVehicle and player:getVehicle() ~= nil

	out(string.format("[LuaEventProfiler] last %.0f s (%s, fps %s)", seconds,
		driving and "in a vehicle" or "on foot",
		tostring(getAverageFPS and getAverageFPS() or "?")))
	out("[LuaEventProfiler] -- by mod, this window --")
	local mods = byMod(stats)
	for i = 1, math.min(10, #mods) do out("[LuaEventProfiler] " .. fmt(mods[i], seconds)) end
	out("[LuaEventProfiler] -- by handler, this window --")
	local list = sorted(stats)
	for i = 1, math.min(TOP, #list) do out("[LuaEventProfiler] " .. fmt(list[i], seconds)) end

	for _, line in ipairs(lines) do print(line) end

	-- Latest window plus session totals to a file in Zomboid/Lua/.
	local sessionSeconds = (t - sessionStart) / 1000
	local ok = pcall(function()
		local w = getFileWriter("LuaEventProfiler.txt", true, false)
		for _, line in ipairs(lines) do w:writeln(line) end
		w:writeln(string.format("[LuaEventProfiler] -- by mod, whole session (%.0f s) --", sessionSeconds))
		local smods = byMod(totals)
		for i = 1, math.min(15, #smods) do w:writeln("[LuaEventProfiler] " .. fmt(smods[i], sessionSeconds)) end
		w:writeln("[LuaEventProfiler] -- by handler, whole session --")
		local slist = sorted(totals)
		for i = 1, math.min(40, #slist) do w:writeln("[LuaEventProfiler] " .. fmt(slist[i], sessionSeconds)) end
		w:close()
	end)

	for _, s in pairs(stats) do
		s.ms = 0
		s.calls = 0
		s.max = 0
	end
	windowStart = t
end

local function tick()
	local t = now()
	if lastTick then
		local gap = t - lastTick
		if gap >= HITCH_MS then
			print(string.format("[LuaEventProfiler] hitch %d ms between ticks; Lua in that frame %d ms%s", gap, frameLua,
				frameWorst and string.format(", worst [%s] %s %d ms", frameWorst.mod, frameWorst.label, frameWorstMs) or ""))
		end
	end
	lastTick = t
	frameLua, frameWorst, frameWorstMs = 0, nil, 0
	if not P.quiet and t - windowStart >= REPORT_SECONDS * 1000 then
		spikeCount = 0
		report()
	end
end

wrapAllEvents()
print("[LuaEventProfiler] active (1.4.0), wrapping Events.*.Add")

-- Our own hooks go through the wrapped Add too; they are tagged as LuaEventProfiler and cost
-- next to nothing, so they are left in the list as a baseline.
Events.OnGameBoot.Add(wrapAllEvents)
Events.OnGameStart.Add(function()
	wrapAllEvents()
	wrapUIClasses()
	pcall(wrapVehicleFunctions)
	stats = {}
	totals = {}
	windowStart = now()
	sessionStart = windowStart
end)
Events.OnTick.Add(tick)

P.report = report

-- For Test Ground (and other benches): P.quiet = true stops the 30 s report, so its hitch doesn't
-- land inside a measured step. P.takeWindow(seconds) folds the current window into the session
-- totals, resets it, and returns the window's report lines (top mods, top handlers).
P.quiet = false
function P.takeWindow(seconds)
	local t = now()
	seconds = seconds or (t - windowStart) / 1000
	local lines = {}
	if seconds > 0 then
		local total = 0
		for _, s in pairs(stats) do total = total + s.ms end
		lines[#lines + 1] = string.format("[LuaEventProfiler] Lua in handlers: %.1f ms/s", total / seconds)
		lines[#lines + 1] = "[LuaEventProfiler] -- by mod --"
		local mods = byMod(stats)
		for i = 1, math.min(15, #mods) do lines[#lines + 1] = "[LuaEventProfiler] " .. fmt(mods[i], seconds) end
		lines[#lines + 1] = "[LuaEventProfiler] -- by handler --"
		local list = sorted(stats)
		for i = 1, math.min(30, #list) do lines[#lines + 1] = "[LuaEventProfiler] " .. fmt(list[i], seconds) end
	end
	for key, s in pairs(stats) do
		local tot = totals[key]
		if not tot then
			tot = { label = s.label, mod = s.mod, ms = 0, calls = 0 }
			totals[key] = tot
		end
		tot.ms = tot.ms + s.ms
		tot.calls = tot.calls + s.calls
		if (s.max or 0) > (tot.max or 0) then tot.max = s.max end
		s.ms, s.calls, s.max = 0, 0, 0
	end
	spikeCount = 0
	windowStart = t
	return lines
end
