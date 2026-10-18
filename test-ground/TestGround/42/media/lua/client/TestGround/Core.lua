-- Test Ground 1.13.0: shared helpers: plan parsing, teleport, squares, zombies, god mode, weather, frames, trace.
--
-- Test Ground (dev tool).
--
-- Runs a fixed test plan in a singleplayer save so a patch can be measured and checked the
-- same way every time, instead of replaying a scenario by hand. The plan lives in
-- Zomboid/Lua/TestGround_plan.txt (a commented template is written there the first time).
--
-- A run: teleport to the plan's start, set the scene (time of day, weather, zombies, god mode),
-- wait for the world to settle, then do each step in order:
--   walk N    walk the route points N times with vanilla Walk To actions (the path search runs)
--   stream S  move along the road points at driving speed for S seconds, so chunks load the way
--             they do while driving (ghost mode, no vehicle)
--   idle S    stand still
--   turn S    turn on the spot every half second (the loot window rebuild case)
--   look S [facing|mouse]  look round two full circles (1.13.19; for Project Viewpoint views)
--   wait S X  stand still at game speed X (1 to 3), so 10-minute marks and other timers pass
--   walkto    every Walk To case: teleport to its start, walk to its target, record the outcome
--   drive S X fast travel (X tiles/s) out along the plan's drive direction for half of S, then
--             straight back to the start (ghost mode, no vehicle)
--   fight N S spawn N zombies around the start and fight them for S seconds (god mode on, checked
--             every step; skipped if it can't be turned on, stopped if nothing is put down)
--   loot      walk to each loot container, let the loot window fill it, move a few items out and back
--   treeroad S X  glide back and forth on the tree-lined road the survey found
--   drivefast S [kmh]  a real car along the street route the survey took from the map, at top speed
--   realfight N S   N zombies, and you swing yourself through the attack input ("can't die" mode)
--   stress N S [D]  N zombies (500) spawned D+ tiles out, 25 a tick, crowd round you for S seconds
--   weather W       clear, rain, fog or keep, for the steps after it
--   natural S [stand|run]  the game's own zombies at the plan's zone (TestGround_natural.txt)
-- "Can't die" mode: outside debug mode god mode can't be turned on from Lua, so health, wounds,
-- infection, tiredness and panic are restored every tick instead.
-- The start: "start = westpoint" is a fixed test start on the vanilla map, the same in every save;
-- the survey ("baseline" on the bridge) goes there first unless told "here".
-- Every step gets frame-time numbers (fps, p50/p95/p99 frame, hitches) and, when Lua Event
-- Profiler 1.4 is enabled, its Lua cost by mod and by handler for that step only.
--
-- Output, in Zomboid/Lua/:
--   TestGround_<label>_<id>.txt        the report, one section per step
--   TestGround_<label>_<id>_trace.txt  the behaviour log: positions, states, Walk To outcomes,
--                                      notes from other mods (TestGround.note)
--   TestGround_<label>_<id>_perf.txt   CSV, one row per second: step, position, fps, frame times, zombies
--   TestGround_<label>_<id>_spikes.txt CSV, every frame of 50 ms or more, with step, position and state
--                                      (.txt because the game refuses Lua writes to .csv files)
--   TestGround_*_latest.*              copies of the last run's files under fixed names
-- compare.py in the repo diffs two runs.
--
-- Start a run from the right-click menu (Test Ground > Run plan) or with autostart in the plan.
-- The same menu records the start, route points, road points and Walk To cases into the plan.
--
-- It changes the save it runs in (time passes, zombies are removed, weather overrides), so use
-- a copy of the save. At the end it puts you back where you were and clears its overrides.
--

if TestGround then return end
TestGround = {}
TestGroundInternal = { loaded = { Core = true }, S = {} }
local TG = TestGroundInternal
local S = TG.S
local T = TestGround

local VERSION = "1.13.22"
local PLAN_FILE = "TestGround_plan.txt"

local ENABLE_MENU = true
local ENABLE_AUTOSTART = true

local function say(s) print("[TestGround] " .. s) end

local now = getTimestampMs
local floor = math.floor
local K = {}   -- constants added since 1.7 (Kahlua allows 200 locals in the main chunk)

-- In game, an error caught by pcall still prints a stack trace to the console and counts as an
-- error on screen. So a call that can fail every tick is made through tryOnce: after the first
-- failure that kind of call is switched off for the rest of the session, with one line saying so.
K.broken = {}
function K.tryOnce(key, fn, ...)
	if K.broken[key] then return false, "switched off" end
	local ok, a, b, c = pcall(fn, ...)
	if not ok then
		K.broken[key] = tostring(a)
		print("[TestGround] " .. key .. " failed (" .. K.broken[key] .. "); not trying again this session")
		if TestGround.trace then pcall(TestGround.trace, key .. " failed; not trying again this session") end
	end
	return ok, a, b, c
end

-- Fixed test starts: the same place in every save, so a run in a modded save and one in a fresh
-- unmodded save start from the same streets. "start = westpoint" in a plan; "start = here" (or no
-- start line) runs where the save loaded. The survey ("baseline" on the bridge) goes to
-- K.DEFAULT_SPOT first unless told "here".
-- westpoint: South St, West Point, on the vanilla map. Picked from the game's own map files
-- (streets.xml, worldmap.xml): a residential street with 23 houses within 60 tiles and only one
-- non-house building, Main St (a straight 1,223 tiles) 49 tiles north for the plain drive, the
-- Dixie Highway (12,700 tiles with its bends) 300 tiles away for the long fast drive, and away
-- from the busier town centre on Main St.
T.spots = {
	westpoint = { name = "West Point, South St", x = 11501, y = 6949, z = 0 },
}
K.DEFAULT_SPOT = "westpoint"
T.defaultSpot = K.DEFAULT_SPOT
local function spotKeys()
	local k = {}
	for name in pairs(T.spots) do k[#k + 1] = name end
	table.sort(k)
	return k
end

K.SPOT_LOAD_MS = 30000     -- a fixed start gets this long to load after the teleport
K.SPOT_LOAD_EDGE = 30      -- loaded when squares this far out on each side exist

-- Plan -----------------------------------------------------------------------------------

local TEMPLATE = {
	"# Test Ground plan. Lines are 'key = value'; '#' starts a comment.",
	"# Right-click in game > Test Ground records start, route, road and walkto lines into this file.",
	"label = baseline          # names the report files; change it per run (e.g. sieve-on, sieve-off)",
	"settle = 10               # seconds to wait after setting the scene, before measuring",
	"repeat = 1                # run the step list this many times (3 gives a feel for the spread)",
	"autostart = 0             # 1 = start the plan this many seconds after loading (see autostart_delay)",
	"autostart_delay = 20",
	"return = 1                # 1 = put you back where you were when the run ends",
	"# popups = keep           # leave other mods' first-load notice windows open (default: they are hidden during the settle)",
	"# endscreen = 30          # 1.13.20: the end-of-run screen, with a countdown to closing the game (seconds, a Pause button); 0 = no countdown, off = no screen; unattended Autorun runs show none unless this is set",
	"",
	"# Scene. Leave a line out (or 'keep') to leave that part as it is.",
	"# start = 10582,9370,0    # where the run begins (x,y,z)",
	"time = keep               # hour of day, e.g. 12",
	"weather = keep            # clear | rain | fog | keep",
	"zombies = keep            # none (removed now and every 2 s) | keep | a number to spawn around the start",
	"god = 1                   # 1 = invincible during the run",
	"",
	"# Steps, in order. walk N | stream SECONDS [TILES_PER_S] | idle SECONDS | turn SECONDS | look SECONDS [facing|mouse] | wait SECONDS [SPEED] | walkto",
	"#   drive SECONDS [TILES_PER_S] [-1] | fight ZOMBIES SECONDS | loot",
	"step = idle 30",
	"",
	"# route = x,y,z           # walk route points (walk step)",
	"# road = x,y              # road points (stream step), driven back and forth",
	"# walkto = name | sx,sy,sz | tx,ty,tz | expect [| via]   expect: arrive | fail | any; via: vanilla | walktoplus",
	"# loot = x,y,z            # a container square (loot step)",
	"# drive = 1,0             # direction of the drive step (x,y); -1 as the step's third number reverses it",
}

local function trim(s) return (string.gsub(s, "^%s*(.-)%s*$", "%1")) end

local function split(s, sep)
	local out = {}
	local start = 1
	while true do
		local i = string.find(s, sep, start, true)
		if not i then
			out[#out + 1] = trim(string.sub(s, start))
			return out
		end
		out[#out + 1] = trim(string.sub(s, start, i - 1))
		start = i + #sep
	end
end

local function numbers(s)
	local out = {}
	for _, part in ipairs(split(s, ",")) do
		local v = tonumber(part)
		if v == nil then return nil end
		out[#out + 1] = v
	end
	return out
end

local function point(s)
	local n = numbers(s)
	if not n or #n < 2 then return nil end
	return { x = n[1], y = n[2], z = n[3] or 0 }
end

function T.parsePlan(lines)
	local plan = {
		label = "run", settle = 10, rep = 1, autostart = 0, autostartDelay = 20, ret = true, banner = true,
		time = nil, weather = nil, zombies = nil, god = true,
		steps = {}, route = {}, road = {}, cases = {}, loot = {}, treeroad = {}, fastroad = {}, skip = {}, errors = {}, extra = {},
	}
	for n, raw in ipairs(lines) do
		local line = raw
		local hash = string.find(line, "#", 1, true)
		if hash then line = string.sub(line, 1, hash - 1) end
		line = trim(line)
		if line ~= "" then
			local eq = string.find(line, "=", 1, true)
			if not eq then
				table.insert(plan.errors, "line " .. n .. ": no '='")
			else
				local key = string.lower(trim(string.sub(line, 1, eq - 1)))
				local val = trim(string.sub(line, eq + 1))
				local lval = string.lower(val)
				if key == "label" then plan.label = string.gsub(val, "[^%w%-_%.]", "_")
				elseif key == "settle" then plan.settle = tonumber(val) or plan.settle
				elseif key == "repeat" then plan.rep = math.max(1, floor(tonumber(val) or 1))
				elseif key == "autostart" then plan.autostart = tonumber(val) or 0
				elseif key == "autostart_delay" then plan.autostartDelay = tonumber(val) or 20
				elseif key == "return" then plan.ret = val ~= "0"
				elseif key == "start" then
					local sp = T.spots[lval]
					if sp then
						plan.start, plan.startName = { x = sp.x, y = sp.y, z = sp.z }, sp.name
					elseif lval == "here" or lval == "loaded" then
						plan.start = nil
					else
						plan.start = point(val)
					end
				elseif key == "zone" then plan.zone = point(val)
				elseif key == "obstacles" then plan.obstacles = lval == "avoid" and "avoid" or "clear"
				elseif key == "buildspeed" then plan.buildspeed = (lval == "real" or lval == "instant") and lval or "fast"
				elseif key == "detail" then
					-- 1.13.0: detail = pzopt|off: per-step start/end marks for pzopt's samplers (see
					-- Report.lua); left out, they're on when pzopt is found
					plan.detail = (lval == "pzopt" or lval == "on") and "pzopt" or ((lval == "off" or lval == "0") and "off" or nil)
				elseif key == "screenshot" then
					-- screenshot = N [kind ...]: a screenshot every N seconds of each step (or only of
					-- the step kinds listed), to Zomboid/Screenshots; 0 or off: none
					local w = {}
					for x in string.gmatch(lval, "%S+") do w[#w + 1] = x end
					-- "on" = every 5 s: each shot is a ~300 ms hitch in game (1.12.6: 239 of 271 hitches at 1 a second)
					local every = (w[1] == "on" or w[1] == "yes") and K.SHOT_DEFAULT_S or tonumber(w[1])
					if every and every > 0 then
						plan.screenshot = { every = math.max(0.2, every) }
						if #w > 1 then
							plan.screenshot.kinds = {}
							for i = 2, #w do plan.screenshot.kinds[w[i]] = true end
						end
					else
						plan.screenshot = nil
					end
				elseif key == "drivetune" then plan.drivetune = K.TUNES and K.TUNES[val] and val or nil
				elseif key == "steer" then plan.steer = (lval == "pursuit" or lval == "nudge") and lval or "torque"
				elseif key == "gamespeed" then plan.gamespeed = math.max(1, math.min(3, floor(tonumber(val) or 1)))
				elseif key == "measure" then plan.measure = val ~= "0"
				elseif key == "banner" then plan.banner = val ~= "0"
				elseif key == "driveview" then plan.driveview = val ~= "0"
				elseif key == "film" then
					-- 1.13.11: film = <fps> <width> (e.g. 30 1280): Test Ground Capture 1.0.2+ writes the
					-- game's own frames as JPEGs to Zomboid/Lua/film/<label>_<run id>/ for the showcase film
					local fw = {}
					for w in string.gmatch(val, "%S+") do fw[#fw + 1] = tonumber(w) end
					-- (1.13.12: a third number caps it in minutes, default 20, at most 120)
					if fw[1] and fw[1] > 0 then plan.film = { fps = math.max(1, math.min(60, floor(fw[1]))), width = math.max(320, math.min(3840, floor(fw[2] or 1280))),
						minutes = math.max(1, math.min(120, fw[3] or 20)),
						-- (1.13.15: a fourth, the JPEG quality, 0.5 to 0.95; Capture 1.0.4+)
						quality = fw[4] and math.max(0.5, math.min(0.95, fw[4])) or nil }
					else plan.film = nil end
				elseif key == "popups" then
					-- 1.13.19: popups = keep leaves other mods' first-load pop-ups open (closed by default)
					plan.popups = lval == "keep" and "keep" or nil
				elseif key == "endscreen" then
					-- 1.13.20: seconds to the closing countdown on the end-of-run screen; off = no screen
					if lval == "off" then plan.endscreen = false else plan.endscreen = math.max(0, math.min(3600, floor(tonumber(lval) or 30))) end
				elseif key == "ui" then
					-- 1.13.15 (showcase trial 2: the saved Info and Status windows covered every frame):
					-- ui = hide hides the open game windows for the run and shows them again after
					plan.ui = lval == "hide" and "hide" or nil
				elseif key == "capture" then
					-- 1.13.7: capture = auto|back|world|both|game, how screenshots are taken when Test Ground
					-- Capture (ZombieBuddy) is installed; "game" = the game's own takeScreenshot
					plan.capture = (lval == "back" or lval == "world" or lval == "both" or lval == "game") and lval or "auto"
				elseif key == "viewpoint" then plan.viewpoint = (lval == "first" or lval == "third" or lval == "isometric") and lval or nil
				elseif key == "corners" then plan.corners = lval == "stop" and "stop" or nil
				elseif key == "time" then plan.time = lval ~= "keep" and tonumber(val) or nil
				elseif key == "weather" then plan.weather = lval ~= "keep" and lval or nil
				elseif key == "zombies" then
					if lval == "none" then plan.zombies = "none"
					elseif tonumber(val) then plan.zombies = floor(tonumber(val))
					else plan.zombies = nil end
				elseif key == "god" then plan.god = val ~= "0"
				elseif key == "weapon" then plan.weapon = val
				elseif key == "buildsite" then plan.buildsite = point(val)
				elseif key == "crowd" then plan.crowd = math.max(1, floor(tonumber(val) or 2))
				elseif key == "skip" then
					for _, w in ipairs(split(val, ",")) do
						w = string.lower((string.gsub(w, "^%s*(.-)%s*$", "%1")))
						if w ~= "" then plan.skip[#plan.skip + 1] = w end
					end
				elseif key == "route" then
					local p = point(val)
					if p then table.insert(plan.route, p) else table.insert(plan.errors, "line " .. n .. ": bad route point") end
				elseif key == "road" then
					local p = point(val)
					if p then table.insert(plan.road, p) else table.insert(plan.errors, "line " .. n .. ": bad road point") end
				elseif key == "treeroad" then
					local p = point(val)
					if p then table.insert(plan.treeroad, p) else table.insert(plan.errors, "line " .. n .. ": bad treeroad point") end
				elseif key == "fastwidth" then plan.fastwidth = tonumber(val)
				elseif key == "corpselen" then plan.corpselen = tonumber(val)
				elseif key == "glidespeed" then plan.glidespeed = tonumber(val)
				elseif key == "corpseband" then plan.corpseband = tonumber(val)
				elseif key == "fastname" then plan.fastname = val
				elseif key == "fastroad" then
					local p = point(val)
					if p then table.insert(plan.fastroad, p) else table.insert(plan.errors, "line " .. n .. ": bad fastroad point") end
				elseif key == "loot" then
					local p = point(val)
					if p then table.insert(plan.loot, p) else table.insert(plan.errors, "line " .. n .. ": bad loot point") end
				elseif key == "drive" then
					local d = numbers(val)
					if d and #d >= 2 then plan.drive = { x = d[1], y = d[2] } else table.insert(plan.errors, "line " .. n .. ": drive needs x,y") end
				elseif key == "walkto" then
					local f = split(val, "|")
					local s, t = point(f[2] or ""), point(f[3] or "")
					if s and t then
						table.insert(plan.cases, { name = f[1] ~= "" and f[1] or ("case" .. (#plan.cases + 1)), from = s, to = t,
							expect = string.lower(f[4] or "any"), via = string.lower(f[5] or "vanilla") })
					else
						table.insert(plan.errors, "line " .. n .. ": walkto needs name | sx,sy,sz | tx,ty,tz")
					end
				elseif key == "step" or key == "test" then
					-- 1.13.0: "test = <group> <step ...>" is the same as "step = <step ...>", with the
					-- step's group named first (K.GROUPS); the old step lines keep working
					local parts = split(lval, " ")
					if key == "test" then
						local g = table.remove(parts, 1)
						local st0 = parts[1]
						if not K.GROUPS[g] then table.insert(plan.errors, "line " .. n .. ": unknown test group '" .. tostring(g) .. "'"); parts = {}
						elseif st0 and K.groupOf(st0) ~= g then table.insert(plan.errors, "line " .. n .. ": '" .. tostring(st0) .. "' isn't in the " .. g .. " group"); parts = {}
						else val = string.match(val, "^%S+%s+(.*)$") or "" end
					end
					local kind = parts[1]
					local a, b = tonumber(parts[2]), tonumber(parts[3])
					if T.Steps[kind] then
						table.insert(plan.steps, { kind = kind, a = a, b = b, args = parts, text = val })
					elseif kind then
						table.insert(plan.errors, "line " .. n .. ": unknown step '" .. tostring(kind) .. "'")
					end
				elseif string.find(key, "%.") then
					-- "<mod>.<key> = value": data for a mod's own steps, e.g. crane.winch = x,y,z
					plan.extra[key] = plan.extra[key] or {}
					table.insert(plan.extra[key], val)
				else
					table.insert(plan.errors, "line " .. n .. ": unknown key '" .. key .. "'")
				end
			end
		end
	end
	return plan
end

local function readLines(name)
	local lines = {}
	local ok = pcall(function()
		local r = getFileReader(name, false)
		if not r then return end
		local line = r:readLine()
		while line do
			lines[#lines + 1] = line
			line = r:readLine()
		end
		r:close()
	end)
	if not ok then return nil end
	return lines
end

local function writeLines(name, lines, append)
	return pcall(function()
		local w = getFileWriter(name, true, append == true)
		for _, l in ipairs(lines) do w:writeln(l) end
		w:close()
	end)
end

-- Plans shipped in the mod (media/TestGround/<name>.txt): "mod:baseline", "mod:natural".
function K.readModFile(path)
	local lines = {}
	local ok = pcall(function()
		local r = getModFileReader("TestGround", path, false)
		if not r then return end
		local line = r:readLine()
		while line do
			lines[#lines + 1] = line
			line = r:readLine()
		end
		r:close()
	end)
	return ok and #lines > 0 and lines or nil
end
K.FIXED_BASELINE = "mod:baseline"

function T.loadPlan(name)
	if name and string.sub(name, 1, 4) == "mod:" then
		local path = "media/TestGround/" .. string.sub(name, 5) .. ".txt"
		local lines = K.readModFile(path)
		if not lines then say("plan not found in the mod: " .. path); return nil end
		local plan = T.parsePlan(lines)
		for _, e in ipairs(plan.errors) do say(name .. ": " .. e) end
		return plan
	end
	if name and name ~= PLAN_FILE then
		local lines = readLines(name)
		if not lines or #lines == 0 then say("plan file not found: Zomboid/Lua/" .. name); return nil end
		local plan = T.parsePlan(lines)
		for _, e in ipairs(plan.errors) do say(name .. ": " .. e) end
		return plan
	end
	local lines = readLines(PLAN_FILE)
	if not lines or #lines == 0 then
		writeLines(PLAN_FILE, TEMPLATE, false)
		say("wrote a plan template to Zomboid/Lua/" .. PLAN_FILE)
		lines = TEMPLATE
	end
	local plan = T.parsePlan(lines)
	for _, e in ipairs(plan.errors) do say("plan: " .. e) end
	return plan
end

-- World helpers (every call into the game is guarded: a failed call is logged, never thrown) --

local function player() return getSpecificPlayer(0) end

local function try(what, fn)
	local ok, err = pcall(fn)
	if not ok then say(what .. " failed: " .. tostring(err)) end
	return ok
end

-- Same pairs as vanilla's SpeedControlsHandler (speed 2 = x5, speed 3 = x20).
local MULTIPLIER = { 1, 5, 20 }
function T.setSpeed(speed)
	setGameSpeed(speed)
	getGameTime():setMultiplier(MULTIPLIER[speed] or 1)
end

-- 1.13.0: the name is worked out once per state object (it was a tostring and two string.match every
-- call, and the busiest harness function in pzopt's sampler while standing still)
local stateCache = { obj = nil, name = "?" }
local function currentState(p) return p:getCurrentState() end
local function stateName(p)
	local ok, o = pcall(currentState, p)
	if not ok or o == nil then return "?" end
	if o == stateCache.obj then return stateCache.name end
	local s = tostring(o)
	local name = string.match(s, "([%w_]+)@") or string.match(s, "([%w_]+)$") or s
	stateCache.obj, stateCache.name = o, name
	return name
end

local function teleport(p, x, y, z)
	return try("teleport", function() p:teleportTo(x + 0.5, y + 0.5, z or 0) end)
end

-- After a teleport the squares around stream in over a few seconds.
local function areaLoaded(x, y, z, edge)
	local ok, res = pcall(function()
		local c = getCell()
		if not c then return false end
		edge = edge or K.SPOT_LOAD_EDGE
		for _, d in ipairs({ { 0, 0 }, { edge, 0 }, { -edge, 0 }, { 0, edge }, { 0, -edge } }) do
			if not c:getGridSquare(x + d[1], y + d[2], z or 0) then return false end
		end
		return true
	end)
	return ok and res
end
T.areaLoaded = areaLoaded

-- God mode. setInvincible doesn't stop zombie damage (nothing in the damage code reads it); god
-- mode does: isGodMod() reads the player's cheats, getCheats():isSet(CheatType.GOD_MODE). In a
-- game started without -debug, setGodMod only works when the player's role has the
-- ToggleGodModHimself capability, and the default roles are read-only, so 1.5.1 and 1.5.2 could
-- not turn it on. The cheats object itself (PlayerCheats, marked UsedFromLua) has no such check,
-- so set the cheat directly first (the way pzopt's harness does), then fall back to setGodMod,
-- then to adding the capability to the role. Whatever worked is logged.
local GOD_CAPS = { "ToggleGodModHimself", "ToggleInvincibleHimself" }

-- Outside debug mode these calls throw, and the engine prints a stack trace (and counts an error on
-- screen) even when the call is pcall'd. So the first throw switches them all off for the rest of
-- the game session: one attempt, logged once, and the fights run guarded.
S.godBroken, S.godErr = false, nil
-- Outside debug mode every god-mode call throws, so they aren't made at all there (1.7.1 still
-- printed a few stack traces: one per Lua reload). Launch with -debug for real god mode.
local function debugOn()
	if type(isDebugEnabled) == "function" then
		local ok, v = pcall(isDebugEnabled)
		return ok and v == true
	end
	if type(getDebug) == "function" then
		local ok, v = pcall(getDebug)
		return ok and v == true
	end
	return false
end
S.godProbed = false
local function godCall(fn)
	if not S.godProbed then
		S.godProbed = true
		if not debugOn() then
			S.godBroken, S.godErr = true, "not in debug mode; launch with -debug for god mode"
			print("[TestGround] god mode: " .. S.godErr .. "; fights run guarded, realfight and stress use can't-die mode")
		end
	end
	if S.godBroken then return false, "skipped" end
	local ok, v = pcall(fn)
	if not ok then
		S.godBroken, S.godErr = true, tostring(v)
		T.trace("god mode: the game refused (" .. S.godErr .. "); not trying again this session")
	end
	return ok, v
end
function T.godBroken() return S.godBroken, S.godErr end
function T.resetGodProbe() S.godBroken, S.godErr, S.godProbed = false, nil, false end   -- for tests

local function isGod(p)
	if S.godBroken then return false end
	local ok, g = godCall(function() return p:isGodMod() end)
	if ok and g == true then return true end
	local ok2, c = godCall(function() return p:getCheats():isSet(CheatType.GOD_MODE) end)
	return ok2 and c == true
end

local function cheatsSay(p)
	if S.godBroken then return "god mode calls switched off after the game refused one" end
	local ok, c = godCall(function() return p:getCheats():isSet(CheatType.GOD_MODE) end)
	local ok2, g = godCall(function() return p:isGodMod() end)
	return string.format("getCheats GOD_MODE %s, isGodMod %s", ok and tostring(c) or "unreadable", ok2 and tostring(g) or "unreadable")
end

local function makeGod(r)
	local p = r.p
	if S.godBroken then return nil end
	godCall(function() p:setInvincible(true) end)
	local okC, errC = godCall(function() p:getCheats():set(CheatType.GOD_MODE, true) end)
	if isGod(p) then r.godPath = "cheats"; return "on via getCheats():set(GOD_MODE) (" .. cheatsSay(p) .. ")" end
	if S.godBroken then return nil end
	godCall(function() p:setGodMod(true) end)
	if isGod(p) then r.godPath = "setGodMod"; return "on via setGodMod (" .. cheatsSay(p) .. ")" end
	if S.godBroken then return nil end
	godCall(function()
		local role = p:getRole()
		if not role then
			role = Role.new("testground")
			p:setRole(role)
		end
		for _, name in ipairs(GOD_CAPS) do
			local cap = Capability[name]
			if cap and not role:hasCapability(cap) and role:addCapability(cap) then
				r.addedCaps = r.addedCaps or {}
				table.insert(r.addedCaps, { role = role, cap = cap })
			end
		end
	end)
	godCall(function() p:setGodMod(true) end)
	if isGod(p) then r.godPath = "role"; return "on via a role capability (" .. cheatsSay(p) .. ")" end
	T.trace("god mode: every path failed (" .. cheatsSay(p) .. ")")
	return nil
end

local function unGod(r)
	local p = r.p
	if not r.godPath then return end   -- nothing was turned on, so nothing to undo (and no calls that throw)
	if r.godPath == "cheats" then godCall(function() p:getCheats():set(CheatType.GOD_MODE, r.wasGod == true) end) end
	godCall(function() p:setGodMod(r.wasGod == true) end)
	godCall(function() p:setInvincible(r.wasInvincible) end)
	for _, a in ipairs(r.addedCaps or {}) do pcall(function() a.role:removeCapability(a.cap) end) end
	r.addedCaps = nil
end

local function playerHealth(p)
	local ok, h = pcall(function() return p:getHealth() end)
	return ok and h or nil
end

local function squareLoaded(x, y, z)
	local ok, sq = pcall(function() return getCell():getGridSquare(x, y, z or 0) end)
	return ok and sq ~= nil
end

local function removeZombies()
	local n = 0
	pcall(function()
		local list = getCell():getObjectListForLua()
		for i = list:size(), 1, -1 do
			local o = list:get(i - 1)
			if instanceof(o, "IsoZombie") then
				o:removeFromWorld()
				o:removeFromSquare()
				n = n + 1
			end
		end
	end)
	return n
end

local function countZombies()
	local ok, n = pcall(function() return getCell():getZombieList():size() end)
	return ok and n or -1
end

local function zombiesList()
	local out = {}
	pcall(function()
		local list = getCell():getObjectListForLua()
		for i = 0, list:size() - 1 do
			local o = list:get(i)
			if instanceof(o, "IsoZombie") then out[#out + 1] = o end
		end
	end)
	return out
end

local function isDead(z)
	local ok, d = pcall(function() return z:isDead() end)
	return ok and d == true
end

local function spawnZombies(center, count)
	if S.run then S.run.spawnedZombies = true end
	-- Fixed ring around the start, so every run gets the same layout.
	for i = 1, count do
		local angle = (i / count) * 2 * math.pi
		local r = 8 + (i % 3) * 3
		local x = floor(center.x + math.cos(angle) * r)
		local y = floor(center.y + math.sin(angle) * r)
		try("spawn zombie", function()
			addZombiesInOutfit(x, y, center.z, 1, nil, 50, false, false, false, false, false, false, 1, false, 0, false, false)
		end)
	end
end

local CLIMATE = { rain = "PRECIPITATION_INTENSITY", fog = "FOG_INTENSITY", cloud = "CLOUD_INTENSITY", wind = "WIND_INTENSITY" }

local function climateFloat(name)
	local ok, v = pcall(function()
		local c = getClimateManager()
		for i = 0, c:getFloatMax() - 1 do
			local f = c:getClimateFloat(i)
			if tostring(f:getName()) == name then return f end
		end
	end)
	return ok and v or nil
end

local function setClimate(key, value)
	local f = climateFloat(CLIMATE[key])
	if not f then say("weather: no climate value " .. CLIMATE[key]); return end
	try("weather " .. key, function()
		f:setEnableAdmin(true)
		f:setAdminValue(value)
	end)
end

local function clearClimate()
	for key, _ in pairs(CLIMATE) do
		local f = climateFloat(CLIMATE[key])
		if f then pcall(function() f:setEnableAdmin(false) end) end
	end
end

local function activeMods()
	local out = {}
	pcall(function()
		local list = getActivatedMods()
		for i = 0, list:size() - 1 do out[#out + 1] = tostring(list:get(i)) end
	end)
	table.sort(out)
	return out
end

-- Run state --------------------------------------------------------------------------------

S.run = nil          -- the run in progress
T.noteBuffer = nil       -- trace lines from other mods, only collected during a run

-- Other mods (or your own probes) can add a line to the behaviour log of the current run.
-- Costs nothing when no run is going.
function T.note(tag, ...)
	if not S.run then return end
	local parts = { tostring(tag) }
	for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
	T.trace("note " .. table.concat(parts, " "))
end

function T.isRunning() return S.run ~= nil end

function T.trace(line)
	if not S.run then return end
	local t = (now() - S.run.t0) / 1000
	S.run.trace[#S.run.trace + 1] = string.format("%8.2f %s", t, line)
end

local function out(line)
	S.run.report[#S.run.report + 1] = line
end

-- 1.9.3: the trace is appended to its file as it grows (every heartbeat and step end), so a run that
-- is killed (a timeout, a crash) still leaves its trace; the end of the run writes it whole again.
function K.flushTrace(r)
	if not r or not r.trace then return end
	local from = (r.traceFlushed or 0) + 1
	if from > #r.trace then return end
	local chunk = {}
	for i = from, #r.trace do chunk[#chunk + 1] = r.trace[i] end
	writeLines("TestGround_" .. r.plan.label .. "_" .. r.id .. "_trace.txt", chunk, from > 1)
	r.traceFlushed = #r.trace
end

-- Frame stats ------------------------------------------------------------------------------

-- Frame times are kept as a histogram of whole milliseconds, updated per frame, so the summary
-- at the end of a step costs one pass over 0..worst ms. Up to 1.5.3 every frame time was kept
-- and sorted at the end; a 180 s walk at 190 fps is 34,000 numbers, and Kahlua's sort of those
-- held the game for about 9 s right after the walk's last leg.
local function newFrames()
	return { hist = {}, n = 0, total = 0, over33 = 0, over100 = 0, worst = 0, start = now(), last = nil, paused = 0 }
end

local function addGap(fr, g)
	local k = floor(g + 0.5)
	fr.hist[k] = (fr.hist[k] or 0) + 1
	fr.n = fr.n + 1
	fr.total = fr.total + g
	if g > 33 then fr.over33 = fr.over33 + 1 end
	if g >= 100 then fr.over100 = fr.over100 + 1 end
	if k > fr.worst then fr.worst = k end
end

local function frameTick(fr, t)
	if fr.last then addGap(fr, t - fr.last) end
	fr.last = t
end

-- 1.13.20 (the user: real names for the tests): what a step's name tag is called in the report, on the
-- end screen and in the status lines. The tag stays the id (reports, compare.py, skip lists use it).
K.DISPLAY_NAMES = {
	walk = "Walk a short route", loot = "Loot a container", car_loot = "Loot a car's trunk",
	glide_south = "Glide south in a car", glide_north = "Glide north in a car", glide_fog = "Glide south in fog",
	glide_trees = "Glide down a tree-lined road", setup_corpses = "Lay corpses along the road",
	cleanup_corpses = "Clear the corpses", drive_corpses = "Drive through the corpses",
	drive_fast = "Fast drive on Dixie Highway", drive_human = "Human-speed drive on Dixie Highway",
	drive_view = "Fast drive with the drive view", drive_old = "Fast drive (1.13.9 tuning)",
	fight_small = "Melee fight, small group", fight_large = "Melee fight, large crowd", fight_swing = "Melee fight with a real swing",
	gear_still = "Stand still with gear", knows = "Goggles on, standing", stress_500 = "Zombie stress, 500 zombies",
	zone_run = "Run through a zombie zone", zone_stand = "Stand in a zombie zone",
	look_still = "Stand still (look-round baseline)", look_facing = "Look round by turning", look_mouse = "Look round with the mouse",
	look_after = "Stand still after looking round", clear = "Weather: clear", fog = "Weather: fog",
}
function T.displayName(tag)
	tag = tostring(tag or "")
	if K.DISPLAY_NAMES[tag] then return K.DISPLAY_NAMES[tag] end
	local s = string.gsub(tag, "_", " ")
	return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

-- T.frameSummary(frames, seconds): frames is a step's frame record, or (as before 1.5.4) a plain
-- list of frame times in ms.
function T.frameSummary(fr, seconds)
	if fr.hist == nil then
		local list = fr
		fr = newFrames()
		for _, g in ipairs(list) do addGap(fr, g) end
	end
	local n = fr.n
	local want = { 0.50, 0.95, 0.99 }
	local got = {}
	if n > 0 then
		local cum, wi = 0, 1
		for k = 0, fr.worst do
			local c = fr.hist[k]
			if c then
				cum = cum + c
				while wi <= #want and cum >= math.max(1, math.ceil(n * want[wi])) do
					got[wi] = k
					wi = wi + 1
				end
				if wi > #want then break end
			end
		end
	end
	return {
		frames = n, seconds = seconds,
		fps = seconds > 0 and n / seconds or 0,
		mean = n > 0 and fr.total / n or 0,
		p50 = got[1] or 0, p95 = got[2] or 0, p99 = got[3] or 0, worst = fr.worst,
		over33 = fr.over33, over100 = fr.over100,
	}
end

T.newFrames, T.addGap = newFrames, addGap   -- for tests

-- Steps ------------------------------------------------------------------------------------
-- Each step is { begin(run, step), tick(run, step, t, dtMs) -> true when done }.

local Steps = {}
T.Steps = Steps

-- Other mods (or a mod's test file) can add step kinds, used in a plan as "step = <kind> args".
-- impl = { begin = function(run, step), tick = function(run, step, t, dtMs) -> true when done }.
-- step.a and step.b are the first two numbers after the kind, step.args every word; set
-- step.result to a short summary, or step.skip to a reason. run.p is the player, run.plan the
-- plan, TestGround.trace(line) adds to the behaviour log.
-- 1.13.0: the test groups, one Lua file each under TestGround/Tests/. A mod's own step goes in
-- the group addStep names (default "other").
K.GROUPS = {
	idle = { "idle", "walk", "stream", "turn", "look", "wait", "walkto", "weather", "loot" },
	glide = { "passby", "corpses" },
	drive = { "drive", "treeroad", "drivefast" },
	zombies = { "stress", "natural" },
	melee = { "fight", "realfight" },
	build = { "build", "visit" },
	station = { "station" },
	other = {},
}
function K.groupOf(kind)
	for g, kinds in pairs(K.GROUPS) do
		for _, k in ipairs(kinds) do if k == kind then return g end end
	end
	return Steps[kind] and "other" or nil
end
function T.addStep(kind, impl, group)
	if type(kind) ~= "string" or type(impl) ~= "table" or type(impl.begin) ~= "function" or type(impl.tick) ~= "function" then
		say("addStep: needs a name and { begin = fn, tick = fn }")
		return false
	end
	Steps[string.lower(kind)] = impl
	if group and group ~= "other" then
		K.GROUPS[group] = K.GROUPS[group] or {}
		table.insert(K.GROUPS[group], string.lower(kind))
	end
	say("step kind added: " .. string.lower(kind))
	return true
end

local function walkTo(p, x, y, z, via)
	local sq = getCell():getGridSquare(x, y, z or 0)
	if not sq then return false, "target square not loaded" end
	if via == "walktoplus" and WalkToPlus and WalkToPlus.walkTo then
		WalkToPlus.walkTo(p, sq)
		return true
	end
	ISTimedActionQueue.clear(p)
	ISTimedActionQueue.add(ISWalkToTimedAction:new(p, sq))
	return true
end

local function busy(p)
	local ok, b = pcall(function() return ISTimedActionQueue.isPlayerDoingAction(p) end)
	if ok and b then return true end
	-- Walk To Plus keeps a ladder route of several legs in WalkToPlus.routes[playerNum].
	local routes = WalkToPlus and WalkToPlus.routes
	if type(routes) == "table" then
		local ok2, r = pcall(function() return routes[p:getPlayerNum()] end)
		if ok2 and r then return true end
	end
	return false
end

local function near(p, pt, tol)
	local dx, dy = p:getX() - (pt.x + 0.5), p:getY() - (pt.y + 0.5)
	return dx * dx + dy * dy <= tol * tol and floor(p:getZ()) == (pt.z or 0)
end

local LEG_TIMEOUT_MS = 60000

TG.CLIMATE, TG.ENABLE_AUTOSTART, TG.ENABLE_MENU, TG.GOD_CAPS, TG.K, TG.LEG_TIMEOUT_MS = CLIMATE, ENABLE_AUTOSTART, ENABLE_MENU, GOD_CAPS, K, LEG_TIMEOUT_MS
TG.MULTIPLIER, TG.PLAN_FILE, TG.Steps, TG.T, TG.TEMPLATE, TG.VERSION = MULTIPLIER, PLAN_FILE, Steps, T, TEMPLATE, VERSION
TG.activeMods, TG.addGap, TG.areaLoaded, TG.busy, TG.cheatsSay, TG.clearClimate = activeMods, addGap, areaLoaded, busy, cheatsSay, clearClimate
TG.climateFloat, TG.countZombies, TG.debugOn, TG.floor, TG.frameTick, TG.godCall = climateFloat, countZombies, debugOn, floor, frameTick, godCall
TG.isDead, TG.isGod, TG.makeGod, TG.near, TG.newFrames, TG.now = isDead, isGod, makeGod, near, newFrames, now
TG.numbers, TG.out, TG.player, TG.playerHealth, TG.point, TG.readLines = numbers, out, player, playerHealth, point, readLines
TG.removeZombies, TG.say, TG.setClimate, TG.spawnZombies, TG.split, TG.spotKeys = removeZombies, say, setClimate, spawnZombies, split, spotKeys
TG.squareLoaded, TG.stateName, TG.teleport, TG.trim, TG.try, TG.unGod = squareLoaded, stateName, teleport, trim, try, unGod
TG.walkTo, TG.writeLines, TG.zombiesList = walkTo, writeLines, zombiesList
