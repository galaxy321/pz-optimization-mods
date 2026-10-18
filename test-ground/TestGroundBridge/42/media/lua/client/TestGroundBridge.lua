--
-- Test Ground Bridge (dev tool).
--
-- Drives Test Ground from outside the game, for scripts and AI agents building test cases:
-- about once a second (while the game is unpaused) it reads Zomboid/Lua/TestGround_cmd.txt,
-- empties it, runs each line and appends the replies to Zomboid/Lua/TestGround_out.txt:
--   "=== #<n> <command>" and then the reply lines.
-- Lines are Test Ground commands (run, survey, baseline, fight, treescan, stop, status; see
-- TestGround.lua), plus:
--   lua <code>   run one line of Lua and print the result. Call only methods known to exist: in
--                debug mode an error, even a caught one, can stop the game in the debugger.
--
-- SECURITY (1.1.0): "lua" lines run only when the game was started with -debug, or when the save's
-- sandbox option "Test Ground Bridge: allow lua lines" (TestGroundBridge.AllowLua, off by default)
-- is on. Without either, any program that could write TestGround_cmd.txt could run Lua in the game
-- with a mod's full reach. Both live outside Zomboid/Lua, where nothing that writes the command file
-- can change them. The Test Ground commands (run, stop, status, ...) always work. Every lua line,
-- run or refused, goes to the console and to Zomboid/Lua/TestGround_bridge_lua.txt. Singleplayer only.

local VERSION = "1.1.0"
local CMD = "TestGround_cmd.txt"

TestGroundBridge = { VERSION = VERSION }
local B = TestGroundBridge

local function say(s) print("[TestGroundBridge] " .. s) end
local now = getTimestampMs

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

local function out(lines)
	if TestGround and TestGround.bridgeOut then TestGround.bridgeOut(lines) else writeLines("TestGround_out.txt", lines, true) end
end

local function mp()
	local m = false
	pcall(function() m = isClient() or isServer() end)
	return m
end

local LUA_LOG = "TestGround_bridge_lua.txt"
-- Why lua lines may run here, or nil when they may not
function B.luaAllowed()
	local dbg = false
	pcall(function() dbg = isDebugEnabled() == true end)
	if dbg then return "-debug" end
	local opt = false
	pcall(function() opt = SandboxVars.TestGroundBridge.AllowLua == true end)
	if opt then return "the save's sandbox option TestGroundBridge.AllowLua" end
	return nil
end
local function luaLog(what, code)
	local line = string.format("%s %s: %s", os.date and os.date("%Y-%m-%d %H:%M:%S") or tostring(now()), what, code)
	say("lua " .. what .. ": " .. code)
	writeLines(LUA_LOG, { line }, true)
end

-- One line: "lua <code>" here, anything else to Test Ground.
function B.run(line)
	local cmd, rest = string.match(line, "^(%S+)%s*(.-)%s*$")
	if cmd and string.lower(cmd) == "lua" then
		local why = B.luaAllowed()
		if not why then
			luaLog("refused", rest)
			return { "refused: lua lines run only with -debug or the save's sandbox option TestGroundBridge.AllowLua on (Test Ground commands still work)" }
		end
		luaLog("run (" .. why .. ")", rest)
		local f, err = loadstring("return " .. rest)
		if not f then f, err = loadstring(rest) end
		if not f then return { "compile error: " .. tostring(err) } end
		local ok, res = pcall(f)
		return { (ok and "ok: " or "error: ") .. tostring(res) }
	end
	if not (TestGround and TestGround.command) then return { "Test Ground is not loaded" } end
	return TestGround.command(line)
end

local seq = 0
local lastPoll = 0
local function poll()
	local t = now()
	if t - lastPoll < 1000 then return end
	lastPoll = t
	local cmds = readLines(CMD)
	if not cmds or #cmds == 0 then return end
	local real = {}
	for _, c in ipairs(cmds) do if string.find(c, "%S") then real[#real + 1] = c end end
	if #real == 0 then return end
	writeLines(CMD, {}, false)
	for _, c in ipairs(real) do
		seq = seq + 1
		local ok, res = pcall(B.run, c)
		local lines = { string.format("=== #%d %s", seq, c) }
		if ok then
			for _, l in ipairs(res or {}) do lines[#lines + 1] = l end
		else
			lines[#lines + 1] = "error: " .. tostring(res)
		end
		out(lines)
	end
end

Events.OnGameStart.Add(function()
	if mp() then say("multiplayer: off"); return end
	Events.OnTick.Add(poll)
	local tg = TestGround and TestGround.VERSION or "not loaded"
	local why = B.luaAllowed()
	out({ "=== bridge ready (" .. tg .. ", bridge " .. VERSION .. ", lua lines " .. (why and ("on: " .. why) or "off") .. ")" })
	say("reading Zomboid/Lua/" .. CMD .. " (Test Ground " .. tg .. ")")
end)
