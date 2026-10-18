-- Test Ground: the entry file. Since 1.13.0 the code is split by test group under TestGround/
-- (TestGround/Core, Runner, Survey and Tests/*); this file loads them in order and holds the
-- menu, the bridge commands and the event hooks.
local VERSION = "1.13.22"   -- the same as in TestGround/Core.lua (the release build reads it here)
require "TestGround/Core"
require "TestGround/Tests/Idle"
require "TestGround/Tests/Drive"
require "TestGround/Tests/Melee"
require "TestGround/Tests/Gun"
require "TestGround/Tests/Gear"
require "TestGround/Tests/Zombies"
require "TestGround/Tests/Glide"
require "TestGround/Tests/Build"
require "TestGround/Tests/Station"
require "TestGround/Report"
require "TestGround/Runner"
require "TestGround/EndScreen"
require "TestGround/Survey"
local TG = TestGroundInternal
if TG.loaded.Main then return end
TG.loaded.Main = true
local S = TG.S
local ENABLE_AUTOSTART, ENABLE_MENU, K, T, VERSION, now = TG.ENABLE_AUTOSTART, TG.ENABLE_MENU, TG.K, TG.T, TG.VERSION, TG.now
local readLines, say, writeLines = TG.readLines, TG.say, TG.writeLines
local function command(line)
	T.commandStart = true   -- 1.13.21: a run started by a command (Bridge, Autorun) shows its end screen with no closing countdown
	local cmd, rest = string.match(line, "^(%S+)%s*(.-)%s*$")
	cmd = cmd and string.lower(cmd)
	if cmd and K.CHANGES[cmd] then
		if K.mpBlocked() then return { "singleplayer only; not run" } end
		if not K.confirmed() then
			K.withConfirm(function() T.command(line) end)
			return { "waiting for the confirmation in game (a run changes this save)" }
		end
	end
	if cmd == "run" then
		local plan = T.loadPlan(rest ~= "" and rest or nil)
		if not plan then return { "no such plan: " .. rest } end
		return { T.start(plan) and ("started " .. plan.label) or "not started (see console.txt)" }
	elseif cmd == "survey" then
		local radius = tonumber(string.match(rest, "^(%d+)"))
		local andRun = string.find(rest, "run", 1, true) ~= nil
		local spot, bad = TG.whereFrom(rest)
		if bad then return { bad } end
		local started = T.survey(radius, function(ok, summary)
			TG.bridgeOut({ "=== " .. summary })
			if ok and andRun then
				local plan = T.loadPlan(TG.SURVEY_FILE)
				TG.bridgeOut({ plan and T.start(plan) and "=== started survey run" or "=== survey run not started" })
			end
		end, spot)
		return { started and "surveying" or "busy (a survey or run is going)" }
	elseif cmd == "baseline" and rest == "" then
		-- the fixed baseline shipped in the mod: the same test for every player, no survey
		local plan = T.loadPlan(K.FIXED_BASELINE)
		if not plan then return { "no fixed baseline in the mod (media/TestGround/baseline.txt)" } end
		return { T.start(plan) and ("started " .. plan.label .. " (fixed, from the mod)") or "not started (see console.txt)" }
	elseif cmd == "baseline" then
		-- "baseline survey|here|<start>|<radius>": survey there, write TestGround_baseline.txt and run it
		local radius = tonumber(string.match(rest, "^(%d+)"))
		local spot, bad = TG.whereFrom(rest)
		if bad then return { bad } end
		local started = T.survey(radius, function(ok, summary)
			TG.bridgeOut({ "=== " .. summary })
			local plan = ok and T.loadPlan(TG.BASELINE_FILE)
			TG.bridgeOut({ plan and T.start(plan) and "=== started baseline run" or "=== baseline run not started" })
		end, spot)
		return { started and "surveying for the baseline" or "busy (a survey or run is going)" }
	elseif cmd == "fight" then
		-- the real-fight plan alone (TestGround_fight.txt, written with defaults if missing)
		if not readLines(K.FIGHT_FILE) or #readLines(K.FIGHT_FILE) == 0 then writeLines(K.FIGHT_FILE, K.FIGHT_PLAN) end
		local plan = T.loadPlan(K.FIGHT_FILE)
		if not plan then return { "no fight plan" } end
		return { T.start(plan) and ("started " .. plan.label) or "not started (see console.txt)" }
	elseif cmd == "build" then
		if not readLines(K.BUILD_FILE) or #readLines(K.BUILD_FILE) == 0 then writeLines(K.BUILD_FILE, K.BUILD_PLAN) end
		local plan = T.loadPlan(K.BUILD_FILE)
		if not plan then return { "no build plan" } end
		return { T.start(plan) and ("started " .. plan.label) or "not started (see console.txt)" }
	elseif cmd == "treescan" then
		local ok, why = T.treeScan(tonumber(string.match(rest, "^(%d+)")))
		return { ok and "scanning tree roads" or ("not started: " .. tostring(why)) }
	elseif cmd == "stop" then
		if not S.run then return { "no run going" } end
		T.stop("stopped through the bridge")
		return { "stopped" }
	elseif cmd == "status" then
		return TG.status()
	end
	return { "unknown command: " .. tostring(line) }
end

T.onFinish = function(last)
	TG.bridgeOut({ "=== done " .. last.report .. " " .. last.trace .. " " .. last.perf .. " " .. last.spikes ..
		(last.stopped and (" (" .. last.stopped .. ")") or "") })
end

T.command = command

-- Autostart --------------------------------------------------------------------------------

S.autostartAt = nil
local function onAutostartTick()
	if not S.autostartAt or now() < S.autostartAt then return end
	S.autostartAt = nil
	Events.OnTick.Remove(onAutostartTick)
	T.commandStart = true   -- 1.13.22: an unattended start gets no closing countdown
	T.start()
end

local function onGameStart()
	local mapOk, mapWhy = T.mapData()
	say("map data for the fast drive: " .. mapWhy)
	local plan = T.loadPlan()
	say("active (" .. VERSION .. "), plan '" .. plan.label .. "': " .. #plan.steps .. " steps, " .. #plan.route ..
		" route points, " .. #plan.road .. " road points, " .. #plan.cases .. " walkto cases" ..
		(LuaEventProfiler and LuaEventProfiler.takeWindow and ", profiler 1.4+ found" or ", no profiler 1.4+ (frame times only)"))
	if ENABLE_AUTOSTART and plan.autostart == 1 then
		S.autostartAt = now() + plan.autostartDelay * 1000
		Events.OnTick.Add(onAutostartTick)
		say("autostart in " .. plan.autostartDelay .. " s")
	end
end

Events.OnGameStart.Add(onGameStart)
Events.OnTick.Add(TG.onTick)
Events.OnRenderTick.Add(K.heartbeat)
if Events.OnPostUIDraw then Events.OnPostUIDraw.Add(K.drawBanner); Events.OnPostUIDraw.Add(K.drawDriveView) end
Events.OnTick.Add(TG.onSurveyTick)
Events.OnTick.Add(K.treeScanTick)
if ENABLE_MENU then Events.OnFillWorldObjectContextMenu.Add(TG.onFillMenu) end

TG.command, TG.onAutostartTick, TG.onGameStart = command, onAutostartTick, onGameStart
