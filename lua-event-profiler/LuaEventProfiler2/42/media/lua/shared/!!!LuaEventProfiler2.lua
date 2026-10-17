--
-- Lua Event Profiler 2 (diagnostic, low overhead).
--
-- Same job and same report lines as Lua Event Profiler 1.3: every Events.<Name>.Add made after
-- this file loads gets a wrapper that adds the time the handler took to a counter for the file
-- that defined it, and at game start mod UI render/prerender/update methods and vehicle script
-- functions are wrapped too. Every REPORT_SECONDS it reports the most expensive mods and handlers.
--
-- What is different, and why:
--
-- 1. The report no longer runs in one frame. Version 1 sorted every counter, built and printed
--    about 35 lines and rewrote a file in the tick the window ended, which showed up as a
--    140-290 ms hitch every 30 s. Here the window end only flips which half of each counter the
--    wrappers write to (one assignment). A coroutine then folds, ranks, formats, prints and writes
--    the report a slice at a time, at most REPORT_BUDGET_MS of work per tick. Spike and hitch
--    lines are queued and printed a few per tick the same way.
--
-- 2. Cheap, frequent handlers are timed on a sample of calls. Each timing is two calls into Java
--    (getTimestampMs), which is most of the profiler's own cost. A handler that has averaged under
--    SAMPLE_BELOW_US per call over at least SAMPLE_MIN_CALLS calls is then timed on one call in
--    SAMPLE_EVERY on average, at random; its other calls are counted but not timed, and its ms are scaled up by
--    calls / timed calls. Sampled handlers are marked "~" in the report. A sampled handler can
--    still miss a rare slow call, so its "max" is a lower bound.
--
-- 3. (2.1) The wrapper reads no table fields. Its counters are upvalues of the wrapper itself.
--    pzopt's retained UI logs every table read made during a UI draw (pzopt.UiDeps), and in a run
--    with 2.0 the main thread spent 22% of its samples in UI draw against 7.6% with no profiler
--    (version 1: 15% to 22% on the older scenario), with UiDeps$Log.addKey alone going from 0% to
--    3.4%. That, not the report or the sampling, is what made 2.0 cost more than version 1.
--
-- 4. (2.1) Vehicle script functions (about 6000) are wrapped without looking up their files; a
--    function's file is looked up the first time it shows up in a report or a spike line. The
--    lookups were most of a 4.7 s freeze at game start in version 1 and 2.0.
--
-- 5. (2.2) Costs by category. Each timed function gets a category when it is wrapped (tick,
--    player update, render events, chunk load, game clock, UI draw, UI update, vehicle scripts
--    and so on; see categoryOf), and the report adds a "by category" list: each category's
--    ms/s and the mods that cost most in it. The file also gets the same list for the whole
--    session and a "by event" list (each event name, its ms/s and its worst mods). The wrapper is
--    unchanged; the grouping is done by the report, a slice at a time.
--
-- 6. (2.4) LuaEventProfiler.snapshot() hands the whole-session totals to other mods (Mod Cost
--    Report turns them into a Markdown table).
--
-- 7. (2.5) Self time. A timed call no longer includes the time of timed calls made inside it (a
--    mod UI class calling its parent's render, an event fired from inside a handler), so nothing
--    is counted twice and per-mod sums add up. Untimed code a handler runs, including another
--    mod's plain functions, still counts for the handler that called it.
--    Adding the same function twice reuses one wrapper, so Events.X.Remove(fn) removes exactly
--    what it would without the profiler, and re-adding a function doesn't grow the records.
--    modOf takes the last "mods" folder in a path and treats the game's media folder as vanilla;
--    a handler's "sampled" mark stays once set.
--
-- Not threaded: Project Zomboid runs all mod Lua on the main thread, and Lua has no way to start
-- another one. Printing and the file write are still main-thread Java calls; they are only spread
-- out so no single frame pays for all of them.
--
-- Only one profiler runs. If Lua Event Profiler (version 1) is also enabled it loads first
-- ("!!!LuaEventProfiler.lua" sorts before this file) and this one stands down with a console line.
--
-- LuaEventProfiler.mark(label) ends the current window at the next tick and tags the next report
-- with the label, so a scripted test run can line reports up with its phases.
--

if LuaEventProfiler then
	print("[LuaEventProfiler2] another Lua Event Profiler is already running ("
		.. tostring(LuaEventProfiler.version or "1.x") .. "); this one stands down. Enable only one.")
	return
end
LuaEventProfiler = {}
local P = LuaEventProfiler
P.version = "2.5"
P.originalOf = setmetatable({}, { __mode = "k" })  -- timed wrapper -> handler, for other patches
-- Another patch that registers its own wrapper around a mod's handler sets sourceOf[wrapper] = handler,
-- so the time is still reported under the mod that wrote the handler.
P.sourceOf = setmetatable({}, { __mode = "k" })

local REPORT_SECONDS = 30
local TOP = 20
local CAT_MODS = 3          -- mods named per category and per event
local SESSION_EVENTS = 25   -- events listed in the file's whole-session "by event" list
local SPIKE_MS = 8          -- log any single handler call at least this long
local HITCH_MS = 100        -- log any gap between ticks at least this long

local ENABLE_SAMPLING = true
local SAMPLE_EVERY = 8      -- time one call in this many for a cheap handler
local SAMPLE_BELOW_US = 50  -- "cheap": average per timed call below this
local SAMPLE_MIN_CALLS = 2000 -- and called at least this often in a window (about every tick)

local ENABLE_AMORTIZED_REPORT = true
local REPORT_BUDGET_MS = 1  -- report work per tick (getTimestampMs has 1 ms steps, so 1-2 ms)
local REPORT_MAX_STEPS = 50 -- and at most this many slices per tick
local RECORDS_PER_STEP = 20
local LINES_PER_STEP = 3
local WRITE_LINES_PER_STEP = 5
local QUEUED_LINES_PER_TICK = 2

local now = getTimestampMs

-- Each counter has two halves. The wrappers add to half `gen`; the window end flips gen, and the
-- report then reads the other half and clears it: record.collect(g) returns ms, calls, timed, max.
-- The counters are upvalues of each wrapper, not table fields. pzopt's retained UI logs every
-- table read made inside a UI draw as a dependency (pzopt.UiDeps), so table reads in a wrapper
-- around a render method cost far more than the reads themselves: 2.0, which kept them in
-- tables, doubled the main thread's UI draw time.
local gen = 1
local records = {}     -- list of { key, label, mod, collect, setSampled, sampled }; keys can repeat

local frameLua = 0
local childMs = 0      -- ms of timed calls made inside the current timed call (for self time)
local frameWorst, frameWorstMs = nil, 0
local lastTick = nil
local spikeCount = 0
local queue, qHead, qTail = {}, 1, 0

local function enqueue(line)
	qTail = qTail + 1
	queue[qTail] = line
end

local function fileOf(fn)
	local ok, name = pcall(getFilenameOfClosure, P.sourceOf[fn] or fn)
	if ok and name then return tostring(name) end
	return nil
end

local function modOf(path)
	if not path then return "?" end
	if string.find(path, "ProjectZomboid[/\\]media[/\\]") then return "vanilla" end
	local last = nil
	for m in string.gmatch(path, "[/\\]mods[/\\]([^/\\]+)") do last = m end
	return last or "vanilla"
end

local function shortPath(path)
	if not path then return "?" end
	local a, b = string.match(path, "([^/\\]+)[/\\]([^/\\]+)$")
	if a then return a .. "/" .. b end
	return path
end

-- Category of an event, by name. Checked in order; the first match wins.
local CATEGORY_RULES = {
	{ "render events", { "Render", "Draw", "^OnPostUI", "^OnPreUI" } },
	{ "tick", { "^OnTick", "^OnFETick" } },
	{ "player update", { "^OnPlayerUpdate", "^OnPlayerMove", "^OnCharacter", "^OnPlayer" } },
	{ "zombies", { "Zombie" } },
	{ "game clock", { "^Every", "^OnDawn", "^OnDusk", "Season" } },
	{ "chunk load", { "Gridsquare", "Chunk", "MapZones", "OnNewWithSprite", "OnLoadWithSprite" } },
	{ "world objects", { "Object", "Tile", "Container", "Thumpable", "Generator", "Fire" } },
	{ "vehicle events", { "Vehicle" } },
	{ "combat", { "Weapon", "Hit", "Attack", "Damage", "Death", "Dead" } },
	{ "items and inventory", { "Clothing", "Equip", "Inventory", "Item", "Refresh", "Fill", "Craft" } },
	{ "input", { "Key", "Mouse", "Joypad", "Gamepad", "Controller", "Press" } },
	{ "weather", { "Weather", "Climate", "Rain", "Snow", "Thunder" } },
	{ "network", { "Command", "Client", "Server", "Connect", "Network" } },
	{ "loading", { "^OnGameBoot", "^OnGameStart", "^OnLoad", "^OnInit", "^OnCreate", "^OnSave", "^OnPostSave",
		"^OnPreMap", "^OnPostMap", "Distribution", "^OnMainMenu", "^OnNewGame" } },
}
local catCache = {}
local function categoryOf(eventName)
	local c = catCache[eventName]
	if c then return c end
	c = "other events"
	for i = 1, #CATEGORY_RULES do
		local rule = CATEGORY_RULES[i]
		for j = 1, #rule[2] do
			if string.find(eventName, rule[2][j]) then c = rule[1] break end
		end
		if c ~= "other events" then break end
	end
	catCache[eventName] = c
	return c
end
P.categoryOf = categoryOf

-- Sampled handlers are timed after a random 1 to 2 * SAMPLE_EVERY - 1 calls (SAMPLE_EVERY on
-- average), not on every SAMPLE_EVERY-th call, so a handler that does its work every N calls
-- can't line up with the samples. Park-Miller, which stays exact in Kahlua's doubles.
local seed = 12345
local function nextSkip()
	seed = (seed * 16807) % 2147483647
	return 1 + seed % (2 * SAMPLE_EVERY - 1)
end

-- A record made with mod == nil names its file only when it is first reported (lazy): finding a
-- function's file is a Java call, and doing it for each of the ~6000 vehicle script functions at
-- game start was most of a 4.7 s freeze in versions 1 and 2.0. Most of them are never called.
local function resolve(r)
	if r.mod == nil then
		local path = fileOf(r.fn)
		r.mod = modOf(path)
		r.label = r.label .. "  " .. shortPath(path)
		r.fn = nil
	end
	return r
end

local function timed(fn, key, label, mod, cat, event)
	local ms1, calls1, timed1, max1 = 0, 0, 0, 0
	local ms2, calls2, timed2, max2 = 0, 0, 0, 0
	local sampled, skip = false, 1
	local r = { key = key, label = label, mod = mod, sampled = false, cat = cat, event = event }
	if mod == nil then r.fn = fn end
	records[#records + 1] = r
	r.collect = function(g)
		if g == 1 then
			local a, b, c, d = ms1, calls1, timed1, max1
			ms1, calls1, timed1, max1 = 0, 0, 0, 0
			return a, b, c, d
		end
		local a, b, c, d = ms2, calls2, timed2, max2
		ms2, calls2, timed2, max2 = 0, 0, 0, 0
		return a, b, c, d
	end
	r.setSampled = function(on)
		sampled = on
		r.sampled = on
	end

	-- Only reached when a call took at least 1 ms, so its table work stays off the common path.
	local function spent(dt)
		frameLua = frameLua + dt
		if dt > frameWorstMs then frameWorst, frameWorstMs = r, dt end
		if dt >= SPIKE_MS and spikeCount < 200 then
			spikeCount = spikeCount + 1
			resolve(r)
			enqueue(string.format("[LuaEventProfiler] spike %d ms [%s] %s", dt, r.mod, r.label))
		end
	end

	return function(...)
		if sampled then
			local k = skip - 1
			if k > 0 then
				skip = k
				if gen == 1 then calls1 = calls1 + 1 else calls2 = calls2 + 1 end
				return fn(...)
			end
			skip = nextSkip()
		end
		local outer = childMs
		childMs = 0
		local t0 = now()
		local a, b, c, d = fn(...)
		local total = now() - t0
		local dt = total - childMs   -- self time: leave out timed calls made inside this one
		if dt < 0 then dt = 0 end
		childMs = outer + total
		if gen == 1 then
			calls1, timed1, ms1 = calls1 + 1, timed1 + 1, ms1 + dt
			if dt > max1 then max1 = dt end
		else
			calls2, timed2, ms2 = calls2 + 1, timed2 + 1, ms2 + dt
			if dt > max2 then max2 = dt end
		end
		if dt > 0 then spent(dt) end
		return a, b, c, d
	end
end

local function wrapEvent(eventName, event)
	if type(event) ~= "table" or event.__lepWrapped then return end
	local add, remove = event.Add, event.Remove
	if type(add) ~= "function" then return end
	local map = setmetatable({}, { __mode = "k" })  -- handler -> its one wrapper
	event.Add = function(fn)
		if type(fn) ~= "function" then return add(fn) end
		local w0 = map[fn]
		if w0 then return add(w0) end   -- same wrapper again: the game sees the same function twice
		local path = fileOf(fn)
		local mod = modOf(path)
		local label = eventName .. "  " .. shortPath(path)
		local key = eventName .. "|" .. tostring(path) .. "|" .. tostring(fn)
		local w = timed(fn, key, label, mod, categoryOf(eventName), eventName)
		map[fn] = w
		P.originalOf[w] = fn
		return add(w)
	end
	if type(remove) == "function" then
		event.Remove = function(fn)
			local w = map[fn]
			if w then return remove(w) end  -- the wrapper is kept: fn may still be added more than once
			return remove(fn)
		end
	end
	event.__lepWrapped = true
end

-- For tests and late-created events: wrap one event by name.
function P.rewrap(name)
	if Events and Events[name] then pcall(wrapEvent, name, Events[name]) end
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
					if mod ~= "vanilla" and mod ~= "?" and mod ~= "LuaEventProfiler" and mod ~= "LuaEventProfiler2" then
						local key = "UI|" .. name .. "." .. method
						cls[method] = timed(fn, key, "UI " .. name .. ":" .. method .. "  " .. shortPath(path), mod,
							method == "update" and "UI update" or "UI draw", "UI " .. method)
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
			-- file and mod are looked up when the function is first reported (see resolve)
			local key = "VEH|" .. prefix .. "." .. fname
			tbl[fname] = timed(fn, key, prefix .. "." .. fname, nil, "vehicle scripts", "vehicle " .. prefix)
			n = n + 1
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

-- Report -------------------------------------------------------------------------------------

local totals = {}      -- key -> { label, mod, ms, calls, max, sampled } over the whole session
local sessionStart = now()
local windowStart = sessionStart
local windowTicks = 0  -- ticks in this window; the window's own frame rate (getAverageFPS is only the last moment)
local foldedTicks = 0  -- ticks in the windows already folded into totals (for snapshot)
local windowLabel, pendingLabel, markPending = nil, nil, false
local job = nil        -- the running report coroutine, or nil
-- What the last report cost, printed in the next report's header.
local lastJob = nil    -- { ms, ticks, maxTick }
local curJob = nil

local function fmt(s, seconds)
	local perSec = seconds > 0 and s.ms / seconds or 0
	local perCall = s.calls > 0 and (s.ms * 1000) / s.calls or 0
	return string.format("%8.1f ms/s %9d calls %8.1f us/call max %4d ms  [%s] %s%s", perSec, s.calls, perCall,
		s.max or 0, s.mod, s.sampled and "~" or "", s.label)
end

-- Keeps list as the n largest by ms, largest first, without sorting everything.
local function offer(list, n, s)
	local len = #list
	if len >= n and s.ms <= list[len].ms then return end
	local i = (len < n) and len + 1 or len
	while i > 1 and list[i - 1].ms < s.ms do
		list[i] = list[i - 1]
		i = i - 1
	end
	list[i] = s
end

local function noYield() end

-- Groups (a category or an event name): name -> { label, ms, mods = { mod -> ms } }.
local function addGroup(groups, name, mod, ms)
	local gr = groups[name]
	if not gr then
		gr = { label = name, ms = 0, mods = {} }
		groups[name] = gr
	end
	gr.ms = gr.ms + ms
	gr.mods[mod] = (gr.mods[mod] or 0) + ms
end

-- The n most expensive groups, largest first, each with its CAT_MODS most expensive mods.
local function rankGroups(groups, n)
	local list = {}
	for _, gr in pairs(groups) do
		if gr.ms > 0 then
			offer(list, n, gr)
			local worst = {}
			for mod, ms in pairs(gr.mods) do offer(worst, CAT_MODS, { mod = mod, ms = ms }) end
			gr.worst = worst
		end
	end
	return list
end

local function fmtGroup(gr, seconds)
	local parts = {}
	for i = 1, #gr.worst do
		local w = gr.worst[i]
		local perSec = seconds > 0 and w.ms / seconds or 0
		if perSec >= 0.05 or i == 1 then parts[#parts + 1] = string.format("%s %.1f", w.mod, perSec) end
	end
	return string.format("%8.1f ms/s  %-20s worst: %s", seconds > 0 and gr.ms / seconds or 0, gr.label,
		table.concat(parts, ", "))
end

-- Builds one window's report from half g of every record. Calls yield between slices.
-- Reads and clears half g of every record and folds it into the session totals. Returns the
-- nTop most expensive handlers, the nMods most expensive mods, and the total ms.
local function foldHalf(g, nTop, nMods, yield)
	local count = #records
	local byKey, keyList = {}, {}
	local total = 0
	for i = 1, count do
		local r = records[i]
		local hMs, hCalls, hTimed, hMax = r.collect(g)
		if hCalls > 0 then
			resolve(r)
			local ms = hMs
			if hTimed > 0 and hTimed < hCalls then ms = ms * hCalls / hTimed end
			total = total + ms
			-- one line per key: a handler registered several times is one handler
			local s = byKey[r.key]
			if not s then
				s = { key = r.key, label = r.label, mod = r.mod, ms = 0, calls = 0, max = 0, sampled = false,
					timedMs = 0, timed = 0, recs = {}, cat = r.cat or "other events", event = r.event or "?" }
				byKey[r.key] = s
				keyList[#keyList + 1] = s
			end
			s.ms = s.ms + ms
			s.calls = s.calls + hCalls
			if hMax > s.max then s.max = hMax end
			if r.sampled then s.sampled = true end
			s.timedMs = s.timedMs + hMs
			s.timed = s.timed + hTimed
			s.recs[#s.recs + 1] = r
		end
		if i % RECORDS_PER_STEP == 0 then yield() end
	end
	yield()
	local top, mods, modList = {}, {}, {}
	local cats = {}
	for i = 1, #keyList do
		local s = keyList[i]
		offer(top, nTop, s)
		addGroup(cats, s.cat, s.mod, s.ms)
		local m = mods[s.mod]
		if not m then
			m = { label = s.mod, mod = s.mod, ms = 0, calls = 0, max = 0 }
			mods[s.mod] = m
			modList[#modList + 1] = m
		end
		m.ms = m.ms + s.ms
		m.calls = m.calls + s.calls
		if s.max > m.max then m.max = s.max end
		local t = totals[s.key]
		if not t then
			t = { label = s.label, mod = s.mod, ms = 0, calls = 0, max = 0, cat = s.cat, event = s.event }
			totals[s.key] = t
		end
		t.ms = t.ms + s.ms
		t.calls = t.calls + s.calls
		t.sampled = t.sampled or s.sampled
		if s.max > t.max then t.max = s.max end
		-- Decide sampling for the next window from what was timed in this one, per handler.
		if ENABLE_SAMPLING and s.timed >= 100 then
			local on = s.calls >= SAMPLE_MIN_CALLS and (s.timedMs * 1000) / s.timed < SAMPLE_BELOW_US
			for j = 1, #s.recs do s.recs[j].setSampled(on) end
		end
		if i % RECORDS_PER_STEP == 0 then yield() end
	end
	yield()
	local topMods = {}
	for i = 1, #modList do offer(topMods, nMods, modList[i]) end
	return top, topMods, total, rankGroups(cats, 100)
end

local function buildReport(g, seconds, header, yield)
	local sessionSeconds = (now() - sessionStart) / 1000
	-- 1. Read and clear this window's half; fold it into the session totals.
	local top, topMods, _, topCats = foldHalf(g, TOP, 10, yield)
	yield()

	-- 2. Format and print the window, a few lines per slice.
	local lines = { header }
	lines[#lines + 1] = "[LuaEventProfiler] -- by mod, this window --"
	for i = 1, #topMods do lines[#lines + 1] = "[LuaEventProfiler] " .. fmt(topMods[i], seconds) end
	lines[#lines + 1] = "[LuaEventProfiler] -- by category, this window --"
	for i = 1, #topCats do lines[#lines + 1] = "[LuaEventProfiler] " .. fmtGroup(topCats[i], seconds) end
	lines[#lines + 1] = "[LuaEventProfiler] -- by handler, this window --"
	for i = 1, #top do lines[#lines + 1] = "[LuaEventProfiler] " .. fmt(top[i], seconds) end
	yield()
	for i = 1, #lines do
		print(lines[i])
		if i % LINES_PER_STEP == 0 then yield() end
	end

	-- 3. Session totals, ranked a slice at a time.
	local stop, sMods, sModList = {}, {}, {}
	local sCats, sEvents = {}, {}
	local n = 0
	for _, t in pairs(totals) do
		offer(stop, 40, t)
		addGroup(sCats, t.cat or "other events", t.mod, t.ms)
		addGroup(sEvents, t.event or "?", t.mod, t.ms)
		local m = sMods[t.mod]
		if not m then
			m = { label = t.mod, mod = t.mod, ms = 0, calls = 0, max = 0 }
			sMods[t.mod] = m
			sModList[#sModList + 1] = m
		end
		m.ms = m.ms + t.ms
		m.calls = m.calls + t.calls
		if t.max > m.max then m.max = t.max end
		n = n + 1
		if n % RECORDS_PER_STEP == 0 then yield() end
	end
	local stopMods = {}
	for i = 1, #sModList do offer(stopMods, 15, sModList[i]) end
	yield()
	local stopCats = rankGroups(sCats, 100)
	yield()
	local stopEvents = rankGroups(sEvents, SESSION_EVENTS)
	yield()

	-- 4. The file in Zomboid/Lua/: its lines are formatted, then written a few per slice.
	local out = {}
	for i = 1, #lines do out[#out + 1] = lines[i] end
	out[#out + 1] = string.format("[LuaEventProfiler] -- by mod, whole session (%.0f s) --", sessionSeconds)
	for i = 1, #stopMods do out[#out + 1] = "[LuaEventProfiler] " .. fmt(stopMods[i], sessionSeconds) end
	out[#out + 1] = "[LuaEventProfiler] -- by category, whole session --"
	for i = 1, #stopCats do out[#out + 1] = "[LuaEventProfiler] " .. fmtGroup(stopCats[i], sessionSeconds) end
	yield()
	out[#out + 1] = "[LuaEventProfiler] -- by event, whole session --"
	for i = 1, #stopEvents do out[#out + 1] = "[LuaEventProfiler] " .. fmtGroup(stopEvents[i], sessionSeconds) end
	yield()
	out[#out + 1] = "[LuaEventProfiler] -- by handler, whole session --"
	for i = 1, #stop do
		out[#out + 1] = "[LuaEventProfiler] " .. fmt(stop[i], sessionSeconds)
		if i % LINES_PER_STEP == 0 then yield() end
	end
	local w = getFileWriter("LuaEventProfiler.txt", true, false)
	local ok, err = true, nil
	local i = 1
	while ok and i <= #out do
		local last = math.min(#out, i + WRITE_LINES_PER_STEP - 1)
		ok, err = pcall(function()
			for k = i, last do w:writeln(out[k]) end
		end)
		i = last + 1
		yield()
	end
	pcall(function() w:close() end)
	if not ok then print("[LuaEventProfiler] could not write LuaEventProfiler.txt: " .. tostring(err)) end
end

local function header(seconds, label, ticks)
	local player = getSpecificPlayer and getSpecificPlayer(0)
	local driving = player and player.getVehicle and player:getVehicle() ~= nil
	local extra = ""
	if label then extra = extra .. ", phase " .. label end
	local fpsText = tostring(getAverageFPS and getAverageFPS() or "?")
	if ticks and seconds > 0 then
		fpsText = string.format("%.0f over the window, %s at the end", ticks / seconds, fpsText)
	end
	local s = string.format("[LuaEventProfiler] last %.0f s (%s, fps %s%s)", seconds,
		driving and "in a vehicle" or "on foot", fpsText, extra)
	if lastJob then
		s = s .. string.format("; last report took %d ms over %d ticks, at most %d ms in one tick",
			lastJob.ms, lastJob.ticks, lastJob.maxTick)
	end
	return s
end

local function finishJob()
	lastJob = curJob
	job, curJob = nil, nil
end

-- Runs report slices for up to REPORT_BUDGET_MS. With all = true, runs the job to the end.
local function runJob(all)
	if not job then return end
	local t0 = now()
	local steps = 0
	repeat
		local ok, err = coroutine.resume(job)
		steps = steps + 1
		if not ok then
			print("[LuaEventProfiler] report failed: " .. tostring(err))
			job = nil
		elseif coroutine.status(job) == "dead" then
			job = nil
		end
	until not job or (not all and (now() - t0 >= REPORT_BUDGET_MS or steps >= REPORT_MAX_STEPS))
	local spent = now() - t0
	curJob.ms = curJob.ms + spent
	curJob.ticks = curJob.ticks + 1
	if spent > curJob.maxTick then curJob.maxTick = spent end
	if not job then finishJob() end
end

local function endWindow(t)
	-- A report still running from the last window is finished first, so halves never mix.
	if job then runJob(true) end
	local seconds = (t - windowStart) / 1000
	local ticks = windowTicks
	windowTicks = 0
	foldedTicks = foldedTicks + ticks
	local g = gen
	gen = 3 - gen
	windowStart = t
	local label = windowLabel
	windowLabel = pendingLabel
	pendingLabel, markPending = nil, false
	spikeCount = 0
	if seconds <= 0 then return end
	local head = header(seconds, label, ticks)
	curJob = { ms = 0, ticks = 0, maxTick = 0 }
	if ENABLE_AMORTIZED_REPORT and coroutine then
		job = coroutine.create(function() buildReport(g, seconds, head, coroutine.yield) end)
		runJob(false)
	else
		local t0 = now()
		local ok, err = pcall(buildReport, g, seconds, head, noYield)
		if not ok then print("[LuaEventProfiler] report failed: " .. tostring(err)) end
		local spent = now() - t0
		curJob.ms, curJob.ticks, curJob.maxTick = spent, 1, spent
		finishJob()
	end
end

local function tick()
	local t = now()
	if lastTick then
		local gap = t - lastTick
		if gap >= HITCH_MS then
			enqueue(string.format("[LuaEventProfiler] hitch %d ms between ticks; Lua in that frame %d ms%s", gap, frameLua,
				frameWorst and string.format(", worst [%s] %s %d ms", resolve(frameWorst).mod, frameWorst.label, frameWorstMs) or ""))
		end
	end
	lastTick = t
	windowTicks = windowTicks + 1
	frameLua, frameWorst, frameWorstMs = 0, nil, 0
	if markPending or (not P.quiet and t - windowStart >= REPORT_SECONDS * 1000) then
		endWindow(t)
	elseif job then
		runJob(false)
	end
	local n = 0
	while qHead <= qTail and n < QUEUED_LINES_PER_TICK do
		print(queue[qHead])
		queue[qHead] = nil
		qHead = qHead + 1
		n = n + 1
	end
end

-- Ends the current window at the next tick; the report after that is tagged with label.
function P.mark(label)
	pendingLabel = label and tostring(label) or nil
	markPending = true
end

-- Same as Lua Event Profiler 1.4, for Test Ground and other benches. P.quiet = true stops the
-- 30 s report, so it doesn't land inside a measured step. P.takeWindow(seconds) folds the current
-- window into the session totals, resets it, and returns the window's report lines (top mods,
-- top handlers) without printing them. It runs in one go: call it between measured steps.
P.quiet = false
function P.takeWindow(seconds)
	if job then runJob(true) end
	local t = now()
	seconds = seconds or (t - windowStart) / 1000
	local g = gen
	gen = 3 - gen
	windowStart = t
	foldedTicks = foldedTicks + windowTicks
	windowTicks = 0
	windowLabel, pendingLabel, markPending = pendingLabel, nil, false
	spikeCount = 0
	local top, topMods, total, topCats = foldHalf(g, 30, 15, noYield)
	local lines = {}
	if seconds > 0 then
		lines[#lines + 1] = string.format("[LuaEventProfiler] Lua in handlers: %.1f ms/s", total / seconds)
		lines[#lines + 1] = "[LuaEventProfiler] -- by mod --"
		for i = 1, #topMods do lines[#lines + 1] = "[LuaEventProfiler] " .. fmt(topMods[i], seconds) end
		lines[#lines + 1] = "[LuaEventProfiler] -- by category --"
		for i = 1, #topCats do lines[#lines + 1] = "[LuaEventProfiler] " .. fmtGroup(topCats[i], seconds) end
		lines[#lines + 1] = "[LuaEventProfiler] -- by handler --"
		for i = 1, #top do lines[#lines + 1] = "[LuaEventProfiler] " .. fmt(top[i], seconds) end
	end
	return lines
end

-- (2.4) The whole-session totals, one row per handler, as of the last window folded in (call
-- report() first to fold the current one). Returns rows, seconds covered, ticks in them, and the
-- getTimestampMs() values where the covered span starts and ends.
-- Each row: { mod, cat, event, label, ms, calls, max, sampled }; ms are already scaled up for
-- sampled handlers. Rows are copies, so the caller may keep or change them.
function P.snapshot()
	if job then runJob(true) end
	local rows = {}
	for _, t in pairs(totals) do
		rows[#rows + 1] = { mod = t.mod, cat = t.cat or "other events", event = t.event or "?", label = t.label,
			ms = t.ms, calls = t.calls, max = t.max, sampled = t.sampled and true or false }
	end
	return rows, (windowStart - sessionStart) / 1000, foldedTicks, sessionStart, windowStart
end

-- Writes the current window out now, all in one go (for a test script's last step).
function P.report()
	endWindow(now())
	if job then runJob(true) end
end

wrapAllEvents()
print("[LuaEventProfiler] wrapping Events.*.Add (version " .. P.version .. ")")

-- Our own hooks go through the wrapped Add too; they are tagged as LuaEventProfiler2 and cost
-- next to nothing, so they are left in the list as a baseline.
Events.OnGameBoot.Add(wrapAllEvents)
Events.OnGameStart.Add(function()
	wrapAllEvents()
	wrapUIClasses()
	pcall(wrapVehicleFunctions)
	-- Start the session clean: drop what loading the save cost.
	for i = 1, #records do
		local r = records[i]
		r.collect(1)
		r.collect(2)
	end
	job, curJob, lastJob = nil, nil, nil
	totals = {}
	windowStart = now()
	windowTicks = 0
	foldedTicks = 0
	sessionStart = windowStart
	print("[LuaEventProfiler] active (" .. P.version .. "), report every " .. REPORT_SECONDS .. " s"
		.. (ENABLE_AMORTIZED_REPORT and coroutine and ", spread over ticks" or ", in one tick")
		.. (ENABLE_SAMPLING and (", cheap handlers sampled 1 in " .. SAMPLE_EVERY) or ""))
end)
Events.OnTick.Add(tick)
