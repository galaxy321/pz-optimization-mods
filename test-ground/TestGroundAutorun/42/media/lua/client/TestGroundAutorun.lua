--
-- Test Ground Autorun (dev tool).
--
-- Hands-free test runs. Does nothing at all unless Zomboid/Lua/TestGround_autorun.txt exists and
-- names a save:
--   save = Lumberjack - Copy - PerfTest
--   mode = Sandbox           # the save's folder under Zomboid/Saves (default Sandbox)
--   plan = baseline          # baseline: the fixed baseline in the mod (start = westpoint, Test Ground 1.11+);
--                            # with another start, reuse TestGround_baseline.txt, survey only if it's missing
--                            # fight: the real-fight plan alone (TestGround_fight.txt), no survey
--                            # build: Better Building Plus builds a room (TestGround_build.txt)
--                            # treescan: visit the most wooded rural roads, write TestGround_treeroads.txt
--                            # survey: always survey a new baseline; or any plan file in Zomboid/Lua
--   delay = 20               # seconds in game before the run starts (the world settles)
--   timeout = 900            # seconds in game before giving up on a run that never finishes
--   quit = 1                 # 1 = quit to desktop when done
--   closeui = 0              # 1 = before the run, close the Character Info window and other open
--                            # windows (not the inventory, loot or chat windows); off by default
--   origin = My Save         # 1.5.0: the save the user chose; Test Ground names it in the report and on the end screen
--   endscreen = 1            # 1.5.0: show Test Ground's end screen (results and a closing countdown) after the run
--   (Benchmark Save, TestGroundBenchmark.lua: a main-menu button that copies a save, writes this flag for the copy
--   and deletes the copy at the next menu; needs Test Ground Capture 1.0.7 for the copy)
--   skip = fight_small,fight_large   # phases (or step kinds) Test Ground leaves out; the report says "skipped by flag"
--   viewpoint = first | third        # 1.4.5: Test Ground 1.13.3+ switches Project Viewpoint to that view for the run
--   start = westpoint        # where the run happens: Test Ground's fixed test start (the default), the
--                            # same in every save; "here" runs where the save loaded. A baseline
--                            # surveyed for another start is surveyed again.
--   loads = 2                # 1.4.6: load the save this many times in one game session: after each run
--                            # but the last, quit to the main menu (getCore():quit(), which saves) and load
--                            # it again (a mod's second-world-load bug, e.g. Animal Preload 0.2.1)
--   reloadplan = idle        # the plan for the loads after the first: idle (wait `delay` s, no run) or
--                            # any plan name as for plan; default the same plan
--   addmods = ModA,ModB      # before loading, add these mods to the save's own mod list (mods.txt);
--                            # 1.4.4: the next time the main menu shows, the ones it added are taken
--                            # off that list again (TestGround_autorun_mods.txt says which)
--
-- A fresh save instead of (or before) a run:
--   newsave = Vanilla Base   # make a new Sandbox save with this name (never over an existing one):
--                            # default sandbox settings, a default unemployed character, spawned at
--                            # Test Ground's fixed start (start = here: the game's own West Point spawn)
--   mods = ModA,ModB         # the new save's mod list; leave it out for a vanilla save
--   seed = 12345             # optional world seed
-- The save is made with only the Test Ground mods (Autorun has to run in it to save it) plus `mods`.
-- Once in game it saves and goes back to the main menu, where the save's mod list is set to exactly
-- `mods`. With `save = <the same name>` and a plan also in the flag, it then loads it and runs the
-- plan (add the Test Ground mods with addmods); otherwise it writes the done file and quits.
-- TestGround_newsave_done.txt always gets the new save's result.
--
-- Main menu: a few seconds after the menu shows (counted on OnFETick: OnTick doesn't run at the menu), loads that save the way Load > Play does
-- (MainScreen.continueLatestSave). In game: only in that save, it empties the flag file (one run
-- per flag), waits `delay`, starts the plan through Test Ground, and when the run ends writes
-- Zomboid/Lua/TestGround_autorun_done.txt (result and file names) and quits. The game sits paused
-- after loading and OnTick doesn't run while paused, so OnRenderTick unpauses it after 5 s.
--
-- The loading screen's "click to start" is pressed by pzopt's harness when
-- Zomboid/Lua/pzopt-harness.txt says mode=play; Lua can't press it.
--
-- Enable this mod in the main menu's mod list (so it runs at the menu) and in the test save's mod
-- list (so it runs in game). The game reloads Lua with the save's mods while loading, so the menu
-- part notes in TestGround_autorun_state.txt that it already asked for a load.
--

if TestGroundAutorun then return end
TestGroundAutorun = {}
local A = TestGroundAutorun

local VERSION = "1.5.1"
local FLAG = "TestGround_autorun.txt"
local DONE = "TestGround_autorun_done.txt"
local STATE = "TestGround_autorun_state.txt"
local NEWSAVE_DONE = "TestGround_newsave_done.txt"
local MODS_BACKUP = "TestGround_autorun_mods.txt"
local NEWSAVE_MODE = "Sandbox"
local MENU_DELAY_MS = 3000
local LOAD_GUARD_MS = 180000   -- a load asked for this recently is still in progress

local function say(s) print("[TestGroundAutorun] " .. s) end
local now = getTimestampMs

local function trim(s) return (string.gsub(s, "^%s*(.-)%s*$", "%1")) end

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
	return ok and lines or {}
end

local function writeLines(name, lines)
	return pcall(function()
		local w = getFileWriter(name, true, false)
		for _, l in ipairs(lines) do w:writeln(l) end
		w:close()
	end)
end

-- The flag file as a table, or nil when there is none (missing, empty, or no save named).
function A.readFlag()
	local f = { mode = "Sandbox", plan = "baseline", delay = 20, timeout = 900, quit = true, closeui = false }
	for _, raw in ipairs(readLines(FLAG)) do
		local line = raw
		local hash = string.find(line, "#", 1, true)
		if hash then line = string.sub(line, 1, hash - 1) end
		local eq = string.find(line, "=", 1, true)
		if eq then
			local key = string.lower(trim(string.sub(line, 1, eq - 1)))
			local val = trim(string.sub(line, eq + 1))
			if key == "save" then f.save = val
			elseif key == "mode" then f.mode = val
			elseif key == "plan" then f.plan = val
			elseif key == "delay" then f.delay = tonumber(val) or f.delay
			elseif key == "timeout" then f.timeout = tonumber(val) or f.timeout
			elseif key == "quit" then f.quit = val ~= "0"
			elseif key == "closeui" then f.closeui = val == "1"
			elseif key == "skip" then f.skip = val   -- phase names to leave out, comma separated
			elseif key == "viewpoint" then f.viewpoint = val
			elseif key == "start" then f.start = string.lower(val)
			elseif key == "addmods" then f.addmods = val
			elseif key == "origin" then f.origin = val          -- 1.5.0: the save the user chose (the run is in a copy of it)
			elseif key == "endscreen" then f.endscreen = val ~= "0"   -- 1.5.0: show Test Ground's end screen though the run is unattended
			elseif key == "newsave" then f.newsave = val
			elseif key == "mods" then f.mods = val
			elseif key == "seed" then f.seed = val
			elseif key == "loads" then f.loads = math.max(1, math.min(5, math.floor(tonumber(val) or 1)))
			elseif key == "loadn" then f.loadn = math.max(1, math.floor(tonumber(val) or 1))
			elseif key == "reloadplan" then f.reloadplan = val
			elseif string.match(key, "^load_%d+$") then f.prev = f.prev or {}; f.prev[#f.prev + 1] = key .. " = " .. val
			end
		end
	end
	if f.save == "" then f.save = nil end
	if f.newsave == "" then f.newsave = nil end
	if f.newsave and sanitizeWorldName then
		-- the folder name the game would use for this save name (New Game does the same); the save
		-- is made under that name, and a "save =" naming it the same way follows it
		local ok, clean = pcall(sanitizeWorldName, f.newsave)
		clean = ok and clean and tostring(clean) or f.newsave
		if clean ~= f.newsave and clean ~= "" then
			if f.save == f.newsave then f.save = clean end
			f.newsaveAsked, f.newsave = f.newsave, clean
		end
	end
	if not f.save and not f.newsave then return nil end
	return f
end

-- The state file: "<kind> <time ms> <save name>" on line 1, "key = value" lines after it.
function A.readState()
	local l = readLines(STATE)
	local s = {}
	if l[1] then
		local kind, ts, rest = string.match(l[1], "^(%S+)%s+(%d+)%s*(.*)$")
		s.kind, s.t, s.name = kind, tonumber(ts), rest
		s.recent = s.t ~= nil and now() - s.t < LOAD_GUARD_MS
	end
	for i = 2, #l do
		local k, v = string.match(l[i], "^(%w+)%s*=%s*(.*)$")
		if k then s[k] = v end
	end
	return s
end

local function stamp() return string.format("%d", now()) end

local function split(s)
	local out = {}
	for part in string.gmatch(s or "", "[^,;]+") do
		part = trim(part)
		if part ~= "" then out[#out + 1] = part end
	end
	return out
end

-- Mod ids in an ActiveMods list.
local function modList(am)
	local out = {}
	pcall(function()
		local m = am:getMods()
		for i = 0, m:size() - 1 do out[#out + 1] = tostring(m:get(i)) end
	end)
	return out
end

-- The id as the game spells it ("ModA" or "\ModA"), or nil when no such mod is installed.
function A.modId(id)
	for _, cand in ipairs({ id, "\\" .. id, (string.gsub(id, "^\\", "")) }) do
		local ok, info = pcall(getModInfoByID, cand)
		if ok and info then return cand end
	end
	return nil
end

-- Turns the ids on in an ActiveMods list; returns the ones that aren't installed.
function A.addMods(am, ids)
	local missing = {}
	for _, id in ipairs(ids) do
		local real = A.modId(id)
		if real then am:setModActive(real, true) else missing[#missing + 1] = id end
	end
	return missing
end

-- Writes a save's mods.txt the way Load > Mods does: the list goes in "currentGame", which is put
-- back to the main menu's list afterwards. fill(currentGame) builds the list.
function A.writeSaveMods(folder, fill)
	local cur, def = ActiveMods.getById("currentGame"), ActiveMods.getById("default")
	local missing = fill(cur)
	if #missing > 0 then
		cur:copyFrom(def)
		return false, "not installed: " .. table.concat(missing, ", ")
	end
	local ok, err = pcall(manipulateSavefile, folder, "WriteModsDotTxt")
	cur:copyFrom(def)
	if not ok then return false, tostring(err) end
	local info = getSaveInfo(folder) or {}
	return true, modList(info.activeMods)
end

-- 1.4.4 (review): addmods changed the save's mods.txt for good. Now the ids it turned on are kept in
-- MODS_BACKUP, and the next time the main menu shows (before any new flag is acted on) they're taken
-- off that save's list again. Returns a line for the console, or nil when there was nothing to do.
function A.restoreMods()
	local b = {}
	for _, raw in ipairs(readLines(MODS_BACKUP)) do
		local k, v = string.match(raw, "^(%w+)%s*=%s*(.*)$")
		if k then b[k] = trim(v) end
	end
	if not b.save or b.save == "" then return nil end
	local folder = (b.mode or "Sandbox") .. getFileSeparator() .. b.save
	local added = split(b.added)
	local ok, res = A.writeSaveMods(folder, function(cur)
		local info = getSaveInfo(folder) or {}
		cur:copyFrom(info.activeMods or ActiveMods.getById("default"))
		for _, id in ipairs(added) do
			local real = A.modId(id) or id
			pcall(function() cur:removeMod(real) end)
		end
		return {}
	end)
	writeLines(MODS_BACKUP, {})
	if not ok then return "could not put " .. b.save .. "'s mod list back: " .. tostring(res) end
	return "put " .. b.save .. "'s mod list back (took off " .. (#added > 0 and table.concat(added, ", ") or "nothing") .. ")"
end

-- Main menu ----------------------------------------------------------------------------------

local menuAt = nil

local function loadRequestedRecently()
	local st = A.readState()
	return st.kind == "loading" and st.recent
end

local function onMenuTick()
	if not menuAt or now() < menuAt then return end
	menuAt = nil
	Events.OnTick.Remove(onMenuTick)
	Events.OnFETick.Remove(onMenuTick)
	local f = A.readFlag()
	if not f then return end
	if f.newsave then A.menuNewsave(f) else A.menuLoad(f) end
end

-- 1.4.3: the game's own save check can stop a load with a dialog at the main menu ("Error loading
-- savefile", a map or mod the save needs that isn't on, a world-version conversion). Nothing
-- answers it on an unattended run, so for A.MODAL_WATCH_S after asking for a load the menu is
-- watched for MainScreen.instance.checkSavefileModal; when it shows, the done file says so at once.
A.MODAL_WATCH_S = 60
local modalUntil, modalSave = nil, nil
local function modalText(m)
	local t = "?"
	pcall(function() t = tostring(m.text or m.description or "?") end)
	t = string.gsub(t, "<[^>]*>", " ")
	t = string.gsub(t, "%s+", " ")
	t = string.gsub(t, "^ ", "")
	return t
end
local function onModalWatch()
	if not modalUntil then return end
	if now() > modalUntil then
		modalUntil = nil
		Events.OnFETick.Remove(onModalWatch)
		return
	end
	local m = nil
	pcall(function() m = MainScreen.instance.checkSavefileModal end)
	if not m then return end
	modalUntil = nil
	Events.OnFETick.Remove(onModalWatch)
	local text = modalText(m)
	say("load stopped by the game's save check dialog: " .. text)
	writeLines(DONE, { "result = load failed", "error = save check dialog: " .. text, "save = " .. tostring(modalSave) })
	writeLines(STATE, {})
	writeLines(FLAG, {})
end
function A.watchModal(save)
	modalSave = save
	if not modalUntil then Events.OnFETick.Add(onModalWatch) end
	modalUntil = now() + A.MODAL_WATCH_S * 1000
end

function A.menuLoad(f)
	if loadRequestedRecently() then
		say("a load was already asked for; waiting for it")
		A.watchModal(f.save)   -- after a Lua reset the dialog shows up in this Lua state
		return
	end
	if not (MainScreen and MainScreen.instance and MainScreen.continueLatestSave) then
		say("main menu not ready, cannot load " .. f.save)
		return
	end
	if f.addmods then
		local folder = f.mode .. getFileSeparator() .. f.save
		local added = {}
		local ok, res = A.writeSaveMods(folder, function(cur)
			local info = getSaveInfo(folder) or {}
			cur:copyFrom(info.activeMods or ActiveMods.getById("default"))
			local before = {}
			for _, id in ipairs(modList(cur)) do before[id] = true end
			local missing = A.addMods(cur, split(f.addmods))
			for _, id in ipairs(modList(cur)) do if not before[id] then added[#added + 1] = id end end
			return missing
		end)
		if ok and #added > 0 then
			writeLines(MODS_BACKUP, { "mode = " .. f.mode, "save = " .. f.save, "added = " .. table.concat(added, ",") })
		end
		if not ok then
			say("addmods failed: " .. tostring(res))
			writeLines(DONE, { "result = load failed", "error = addmods: " .. tostring(res), "save = " .. f.save })
			writeLines(FLAG, {})
			return
		end
		say("the save's mod list is now: " .. (#res > 0 and table.concat(res, ", ") or "none"))
	end
	writeLines(STATE, { "loading " .. stamp() .. " " .. f.save })
	say("loading " .. f.mode .. "/" .. f.save)
	local ok, err = pcall(MainScreen.continueLatestSave, f.mode, f.save)
	if not ok then
		say("load failed: " .. tostring(err))
		writeLines(DONE, { "result = load failed", "error = " .. tostring(err), "save = " .. f.save })
		writeLines(STATE, {})
	else
		A.watchModal(f.save)
	end
end

-- New save -----------------------------------------------------------------------------------

function A.saveFolder(name) return NEWSAVE_MODE .. getFileSeparator() .. name end

local function newsaveFailed(f, err)
	say("newsave failed: " .. err)
	local lines = { "result = newsave failed", "error = " .. err, "newsave = " .. f.newsave }
	writeLines(NEWSAVE_DONE, lines)
	writeLines(DONE, lines)
	writeLines(FLAG, {})
	writeLines(STATE, {})
end

-- West Point if the map has it, else the first spawn region (as the game's default spawn does).
function A.pickRegion()
	local regions = {}
	pcall(function() regions = MapSpawnSelect.instance:getSpawnRegions() or {} end)
	for _, r in ipairs(regions) do
		if string.find(string.lower(tostring(r.name)), "west point", 1, true) then return r end
	end
	return regions[1]
end

-- The game's own new-game path (New Game > Sandbox > spawn > character > Play) without the screens.
function A.menuNewsave(f)
	local st = A.readState()
	local name = f.newsave
	if st.kind == "newsave-saved" and st.name == name then return A.finishNewsave(f, st) end
	if st.kind == "newsave" and st.name == name and st.recent then say("the new save is being made; waiting"); return end
	local ms = MainScreen and MainScreen.instance
	if not (ms and MapSpawnSelect and MapSpawnSelect.instance and createWorld) then
		return newsaveFailed(f, "main menu not ready")
	end
	if string.sub(name, 1, 1) == "." or string.sub(name, -1) == "." then
		return newsaveFailed(f, "a save name can't start or end with a dot")
	end
	local okE, exists = pcall(checkSaveFolderExists, A.saveFolder(name))
	if okE and exists then
		return newsaveFailed(f, "a save named " .. name .. " already exists (newsave never overwrites)")
	end
	-- the mods it's made with: the Test Ground mods from the menu's list, plus the flag's mods
	local cur = ActiveMods.getById("currentGame")
	cur:clear()
	for _, id in ipairs(modList(ActiveMods.getById("default"))) do
		if string.find(string.lower(id), "testground", 1, true) then cur:setModActive(id, true) end
	end
	local missing = A.addMods(cur, split(f.mods))
	if #missing > 0 then
		cur:copyFrom(ActiveMods.getById("default"))
		return newsaveFailed(f, "not installed: " .. table.concat(missing, ", "))
	end
	if st.kind ~= "newsave-reset" and ActiveMods.requiresResetLua(cur) then
		-- the menu runs other mods: reload Lua with just these first (the game's NewGameMods step)
		writeLines(STATE, { "newsave-reset " .. stamp() .. " " .. name })
		say("reloading Lua with the new save's mods: " .. table.concat(modList(cur), ", "))
		getCore():ResetLua("currentGame", "TestGroundNewsave")
		return
	end
	A.createNewsave(f, name, ms)
end

function A.createNewsave(f, name, ms)
	getWorld():setGameMode(NEWSAVE_MODE)
	ms:setDefaultSandboxVars()
	pcall(function()
		-- as the Sandbox screen's Play does: water and power shut-off days rolled from the defaults
		local o = getSandboxOptions()
		o:set("WaterShutModifier", o:randomWaterShut(o:getOptionByName("WaterShut"):getValue()))
		o:set("ElecShutModifier", o:randomElectricityShut(o:getOptionByName("ElecShut"):getValue()))
		o:toLua()
	end)
	pcall(function() getWorld():setPreset("Apocalypse") end)
	getWorld():setMap("DEFAULT")
	ms.createWorld = true
	local region = A.pickRegion()
	if not region then return newsaveFailed(f, "the map has no spawn regions") end
	MapSpawnSelect.instance.selectedRegion = region
	setSpawnRegion(region.name)
	pcall(function() getCore():setSelectedMap(tostring(region.name)) end)
	getWorld():setWorld(name)
	if f.seed then
		pcall(function() WorldGenParams.INSTANCE:setSeedString(f.seed) end)
	else
		pcall(function() MapSpawnSelect.instance:saveGenParams() end)
	end
	-- default character: the first profession (unemployed) with its clothes
	pcall(function() ms.charCreationProfession:resetBuild() end)
	pcall(function() ms.charCreationMain:randomGenericOutfit() end)
	local start = f.start or "westpoint"
	local spot = TestGround and TestGround.spots and TestGround.spots[start]
	A.spawnAt = spot
	writeLines(STATE, { "newsave " .. stamp() .. " " .. name })
	say("making " .. NEWSAVE_MODE .. "/" .. name .. " in " .. tostring(region.name) ..
		(spot and (" at " .. spot.x .. "," .. spot.y .. "," .. spot.z) or " at the game's spawn") ..
		" with mods: " .. (#modList(ActiveMods.getById("currentGame")) > 0 and table.concat(modList(ActiveMods.getById("currentGame")), ", ") or "none"))
	createWorld(name)
	GameWindow.doRenderEvent(false)
	forceChangeState(LoadingQueueState.new())
end

-- Runs after the game's own OnInitWorld (CharacterCreationProfession.initWorld picks a random spawn
-- point in the region); moves the spawn to the fixed start.
function A.onInitWorld()
	local s = A.spawnAt
	if not s then return end
	A.spawnAt = nil
	pcall(function()
		getWorld():setLuaPosX(s.x)
		getWorld():setLuaPosY(s.y)
		getWorld():setLuaPosZ(s.z or 0)
	end)
	say("new save: spawn set to " .. s.x .. "," .. s.y .. "," .. (s.z or 0))
end

-- In the new game, after the delay: note where the player is, then save and go back to the menu.
function A.saveNewsave(job)
	local spawn, who = "?", "?"
	pcall(function()
		local p = getPlayer()
		spawn = math.floor(p:getX()) .. "," .. math.floor(p:getY()) .. "," .. math.floor(p:getZ())
	end)
	pcall(function()
		local d = getPlayer():getDescriptor()
		who = tostring(d:getForename()) .. " " .. tostring(d:getSurname()) .. " (" .. tostring(d:getCharacterProfession()) .. ")"
	end)
	writeLines(STATE, { "newsave-saved " .. stamp() .. " " .. job.newsave, "spawn = " .. spawn, "player = " .. who })
	job.ended = true
	say("new save " .. job.newsave .. " is in game (player at " .. spawn .. "); saving and going back to the main menu")
	pcall(function() setGameSpeed(1) end)
	local ok, err = pcall(function() getCore():quit() end)
	if not ok then
		newsaveFailed(job.flag, "could not save and quit: " .. tostring(err))
	end
end

-- Back at the menu: set the save's mod list to the flag's, write the result, then run or quit.
function A.finishNewsave(f, st)
	local name = f.newsave
	local folder = A.saveFolder(name)
	local ok, res = A.writeSaveMods(folder, function(cur)
		cur:clear()
		return A.addMods(cur, split(f.mods))
	end)
	local info = {}
	pcall(function() info = getSaveInfo(folder) or {} end)
	local lines = { ok and "result = newsave created" or "result = newsave made, mod list not set" }
	if not ok then lines[#lines + 1] = "error = " .. tostring(res) end
	lines[#lines + 1] = "newsave = " .. name
	if f.newsaveAsked then lines[#lines + 1] = "asked_name = " .. f.newsaveAsked .. " (the game's folder name for it is " .. name .. ")" end
	lines[#lines + 1] = "mode = " .. NEWSAVE_MODE
	-- 1.4.2: the save is made with the Test Ground mods loaded (they drive the creation); its list is
	-- then set to exactly `mods`, so "none" means a vanilla save that runs add the test mods back to
	if ok then lines[#lines + 1] = "mods = " .. (#res > 0 and table.concat(res, ",") or "none (vanilla: the Test Ground mods it was made with are off its list; a run adds them back with addmods)") end
	lines[#lines + 1] = "spawn = " .. tostring(st.spawn)
	lines[#lines + 1] = "player = " .. tostring(st.player)
	lines[#lines + 1] = "player_saved = " .. tostring(info.playerAlive)
	lines[#lines + 1] = "time_ms = " .. stamp()
	writeLines(NEWSAVE_DONE, lines)
	writeLines(STATE, {})
	say("done: " .. lines[1] .. " (" .. name .. ")")
	if f.save and ok then
		-- the rest of the flag is a run: drop the newsave lines and go on to the load
		local rest = {}
		for _, raw in ipairs(readLines(FLAG)) do
			local k = string.lower(trim(string.match(raw, "^([^=#]*)=") or ""))
			if k ~= "newsave" and k ~= "mods" and k ~= "seed" then rest[#rest + 1] = raw end
		end
		writeLines(FLAG, rest)
		local nf = A.readFlag()
		if nf then return A.menuLoad(nf) end
		return
	end
	writeLines(DONE, lines)
	writeLines(FLAG, {})
	if f.quit then
		say("quitting to desktop")
		pcall(function() getCore():quitToDesktop() end)
	end
end

-- Benchmark Save (1.5.0, TestGroundBenchmark.lua) ---------------------------------------------
-- The window makes a throwaway copy of a save (or a new vanilla save), writes the flag file for it and
-- calls A.kick(). The copy's name is recorded in BENCH_FILE; the next time the main menu shows, it is
-- deleted, but only a save whose name starts with "TG Benchmark " and that the record names.
local BENCH_FILE = "TestGround_benchcopy.txt"
A.BENCH_PREFIX = "TG Benchmark "
A.BENCH_MODES = { Sandbox = true, Apocalypse = true, Survivor = true, Builder = true, Beginner = true, Survival = true }
function A.recordBench(mode, name, origin) writeLines(BENCH_FILE, { "mode = " .. mode, "name = " .. name, "origin = " .. origin }) end
function A.cleanBench()
	local rec = {}
	for _, l in ipairs(readLines(BENCH_FILE)) do
		local k, v = string.match(l, "^(%w+)%s*=%s*(.-)%s*$")
		if k then rec[k] = v end
	end
	if not rec.name or rec.name == "" then return end
	-- a run that is still to load this copy keeps it
	local f = A.readFlag()
	if f and f.save == rec.name then return end
	-- 1.5.1 (review of 1.5.0): the record must look like one this mod wrote: a game mode, the prefix, a
	-- time stamp at the end, an origin, and no path characters
	local safe = A.BENCH_MODES[rec.mode or ""] and string.sub(rec.name, 1, #A.BENCH_PREFIX) == A.BENCH_PREFIX
		and string.match(rec.name, " %d+$") ~= nil and (rec.origin or "") ~= ""
		and not string.find(rec.name, "[/\\:*?\"<>|]") and not string.find(rec.name, "..", 1, true)
	if not safe then
		say("benchmark record ignored: " .. tostring(rec.name) .. " is not a Benchmark Save copy")
		writeLines(BENCH_FILE, {})
		return
	end
	local path = rec.mode .. getFileSeparator() .. rec.name
	local exists = true
	pcall(function() exists = checkSaveFolderExists(path) end)
	if exists then pcall(deleteSave, path) end
	local still = false
	pcall(function() still = checkSaveFolderExists(path) end)
	if still then
		say("could not delete the benchmark copy " .. rec.name .. "; the record stays for the next menu")
		return
	end
	say(exists and ("deleted the benchmark copy " .. rec.name .. " (of " .. tostring(rec.origin) .. ")") or ("the benchmark copy " .. rec.name .. " was already gone"))
	writeLines(BENCH_FILE, {})
end
-- load the save the flag file names, as at the menu
function A.writeFlagLines(lines) writeLines(FLAG, lines) end
function A.kick()
	if not A.readFlag() then say("kick: no flag"); return end
	if menuAt then return end
	menuAt = now() + 500
	Events.OnFETick.Add(onMenuTick)
end

local function onMainMenuEnter()
	-- before anything else (with or without a new flag), and not while a load it asked for is
	-- still going through the Lua reset
	if not loadRequestedRecently() then
		local okR, msg = pcall(A.restoreMods)
		if not okR then say("restoring a save's mod list failed: " .. tostring(msg)) elseif msg then say(msg) end
	end
	if not loadRequestedRecently() then pcall(A.cleanBench) end
	if not A.readFlag() then return end
	if menuAt then return end
	menuAt = now() + MENU_DELAY_MS
	-- OnTick doesn't run at the main menu; OnFETick (front-end tick) does.
	Events.OnFETick.Add(onMenuTick)
	say("flag found at the main menu; loading in " .. MENU_DELAY_MS .. " ms")
end

-- In game ------------------------------------------------------------------------------------

local job = nil   -- { flag, startAt, deadline, started, quitAt }

-- Whether TestGround_baseline.txt exists and was surveyed for this start ("here" or a fixed start's key).
function A.baselineFor(start)
	local lines = readLines("TestGround_baseline.txt")
	if #lines == 0 then return false end
	local have = nil
	for _, l in ipairs(lines) do
		local v = string.match(l, "^%s*start%s*=%s*([^%s#]+)")
		if v then have = string.lower(v) end
	end
	local spots = (TestGround and TestGround.spots) or {}
	if start == "here" or start == "loaded" then return have == nil or spots[have] == nil end
	return have == start
end

A.MENU_FAIL_MS = 30000
local finishJob
-- The next load can't happen: no more loads, the flag cleared, the final done file with this.
function A.reloadFailed(why)
	job.flag.loads = job.flag.loadn or 1
	job.ended = nil
	writeLines(FLAG, {})
	finishJob({ "result = load failed", "error = " .. why })
end

finishJob = function(lines)
	if not job or job.ended then return end
	job.ended = true
	if job.closed then lines[#lines + 1] = "closed_ui = " .. (#job.closed > 0 and table.concat(job.closed, ", ") or "nothing") end
	lines[#lines + 1] = "survival_guide = " .. (job.guide or "not open")
	if job.flag.skip and job.flag.skip ~= "" then lines[#lines + 1] = "skip = " .. job.flag.skip end
	if job.flag.viewpoint then lines[#lines + 1] = "viewpoint = " .. job.flag.viewpoint end
	if job.flag.addmods then lines[#lines + 1] = "addmods = " .. job.flag.addmods end
	lines[#lines + 1] = "start = " .. tostring(job.start or "?")
	lines[#lines + 1] = "unpaused = " .. (job.unpauses or 0)
	lines[#lines + 1] = "focusloss = " .. tostring(job.focusloss)
	lines[#lines + 1] = "save = " .. job.flag.save
	local loads, n = job.flag.loads or 1, job.flag.loadn or 1
	if loads > 1 then
		lines[#lines + 1] = string.format("load = %d of %d", n, loads)
		for _, l in ipairs(job.flag.prev or {}) do lines[#lines + 1] = l end
	end
	lines[#lines + 1] = "time_ms = " .. string.format("%d", now())
	if n < loads then
		-- 1.4.6: the flag back for the next load (this one's result noted in it), then to the main menu
		local keep = {}
		for _, raw in ipairs(job.flagLines or {}) do
			local k = string.lower(trim(string.match(raw, "^([^=#]*)=") or ""))
			if k ~= "loadn" and not string.match(k, "^load_%d+$") and not (k == "plan" and job.flag.reloadplan) then keep[#keep + 1] = raw end
		end
		for _, l in ipairs(job.flag.prev or {}) do keep[#keep + 1] = l end
		keep[#keep + 1] = string.format("load_%d = %s", n, lines[1])
		keep[#keep + 1] = "loadn = " .. (n + 1)
		if job.flag.reloadplan then keep[#keep + 1] = "plan = " .. job.flag.reloadplan end
		writeLines(FLAG, keep)
		writeLines(string.format("TestGround_autorun_done_load%d.txt", n), lines)
		say(string.format("done with load %d of %d: %s; back to the main menu to load it again", n, loads, lines[1]))
		job.menuAt = now() + 5000
		return
	end
	writeLines(DONE, lines)
	say("done: " .. lines[1])
	if job.flag.quit then job.quitAt = now() + 5000 end
end

-- Windows a save can load with open (Character Info costs a few % of every frame). The Character
-- Info window is closed the vanilla way (getPlayerInfoPanel(0):close()); then every other open
-- top-level window derived from ISCollapsableWindow, except the ones a player always has.
local KEEP_UI = { ISInventoryPage = true, ISChat = true }

local function derivesFrom(tbl, class)
	local m = getmetatable(tbl)
	local n = 0
	while m and n < 20 do
		if m == class then return true end
		m = getmetatable(m)
		n = n + 1
	end
	return false
end

function A.closeUI()
	local closed = {}
	pcall(function()
		local info = getPlayerInfoPanel(0)
		if info and info:getIsVisible() then
			info:close()
			closed[#closed + 1] = info.Type or "ISCharacterInfoWindow"
		end
	end)
	local ok, err = pcall(function()
		if not ISCollapsableWindow then return end
		local list = UIManager.getUI()
		local open = {}
		for i = 0, list:size() - 1 do
			local el = list:get(i)
			local tbl = el:getTable()
			if tbl and el:isVisible() and tbl.Type and not KEEP_UI[tbl.Type] and derivesFrom(tbl, ISCollapsableWindow) then
				open[#open + 1] = tbl
			end
		end
		for _, tbl in ipairs(open) do
			tbl:close()
			closed[#closed + 1] = tbl.Type
		end
	end)
	if not ok then say("closeui: window sweep failed: " .. tostring(err)) end
	say("closeui: closed " .. (#closed > 0 and table.concat(closed, ", ") or "nothing"))
	return closed
end

-- The survivor guide window (vanilla SurvivalGuide.lua) opens over a freshly loaded save and is
-- drawn every UI frame. Close it the way Esc does (SurvivalGuide:onKeyRelease sets it invisible);
-- the player's "show the survival guide" option is left alone, so it still opens for normal play.
function A.closeGuide()
	local g = SurvivalGuide and SurvivalGuide.instance
	if not g then return nil end
	local okV, vis = pcall(function() return g:getIsVisible() end)
	if okV and not vis then return nil end
	pcall(function() g:setVisible(false) end)
	okV, vis = pcall(function() return g:getIsVisible() end)
	if okV and vis then
		-- fallback: the panel's own Esc handler
		pcall(function() g:onKeyRelease(Keyboard.KEY_ESCAPE) end)
		okV, vis = pcall(function() return g:getIsVisible() end)
	end
	if okV and vis then return "still open" end
	return "closed"
end

local function guideCheck()
	if not job or job.guide == "closed" then return end
	local res = A.closeGuide()
	if res then
		job.guide = res
		say("survivor guide window " .. res)
	end
end

local function startRun()
	local T = TestGround
	if not (T and T.start and T.loadPlan and T.command) then
		finishJob({ "result = no run", "error = Test Ground is not loaded in this save" })
		return
	end
	local prev = T.onFinish
	T.onFinish = function(last)
		if prev then pcall(prev, last) end
		finishJob({ "result = " .. (last.stopped and ("stopped: " .. tostring(last.stopped)) or "done"),
			"report = " .. tostring(last.report), "trace = " .. tostring(last.trace),
			"perf = " .. tostring(last.perf), "spikes = " .. tostring(last.spikes) })
	end
	-- this save is a test copy named in the flag: no per-save confirmation
	T.trusted = true
	if job.flag.closeui then job.closed = A.closeUI() end
	guideCheck()
	local plan = job.flag.plan
	if plan == "idle" then   -- 1.4.6: a load that only needs to come up (loads = N, reloadplan = idle)
		finishJob({ "result = idle", "error = none (plan idle: the save loaded and ran " .. job.flag.delay .. " s, no Test Ground run)" })
		return
	end
	T.viewpoint = job.flag.viewpoint   -- Test Ground 1.13.3+: a Project Viewpoint view for the run (the plan's own line wins)
	T.sourceSave = job.flag.origin   -- 1.5.0: Test Ground names this save in the report and on the end screen
	T.wantEndScreen = job.flag.endscreen
	T.skip = job.flag.skip   -- Test Ground leaves these phases out and says "skipped by flag" in the report
	local res
	local start = job.flag.start or T.defaultSpot or "here"
	job.start = start
	if plan == "baseline" and start == "westpoint" and T.FIXED then
		-- Test Ground 1.11+: the fixed baseline shipped in the mod, the same for every player
		res = T.command("baseline")
	elseif plan == "survey" or (plan == "baseline" and not A.baselineFor(start)) then
		res = T.command("baseline " .. start)
	elseif plan == "baseline" then
		res = T.command("run TestGround_baseline.txt")
	elseif plan == "fight" then
		res = T.command("fight")
	elseif plan == "build" then
		res = T.command("build")
	elseif plan == "treescan" then
		T.onScanDone = function(file, msg)
			T.onScanDone = nil
			finishJob({ "result = done", "report = " .. tostring(file), "scan = " .. tostring(msg) })
		end
		res = T.command("treescan")
	else
		res = T.command("run " .. plan)
	end
	say("plan " .. plan .. ": " .. table.concat(res or {}, "; "))
	local first = res and res[1] or ""
	if not (string.find(first, "^started") or string.find(first, "^surveying") or string.find(first, "^scanning")) then
		finishJob({ "result = no run", "error = " .. first })
	end
end

local function onGameTick()
	if not job then return end
	local t = now()
	if job.menuAt then
		if t >= job.menuAt then
			job.menuAt = nil
			say("quitting to the main menu (load " .. (job.flag.loadn or 1) .. " of " .. (job.flag.loads or 1) .. ")")
			pcall(function() setGameSpeed(1) end)
			local ok, err = pcall(function() getCore():quit() end)
			if not ok then
				A.reloadFailed("could not quit to the main menu for the next load: " .. tostring(err))
			else
				-- 1.4.7 (review of 1.4.6): still in game A.MENU_FAIL_MS later means the quit didn't
				-- happen; without this the last done file was never written and the PC waited for ever
				job.menuFailAt = t + A.MENU_FAIL_MS
			end
		end
		return
	end
	if job.menuFailAt then
		if t >= job.menuFailAt then
			job.menuFailAt = nil
			A.reloadFailed(string.format("still in game %d s after asking to quit to the main menu", A.MENU_FAIL_MS / 1000))
		end
		return
	end
	if job.quitAt then
		if t >= job.quitAt then
			job.quitAt = nil
			Events.OnTick.Remove(onGameTick)
			say("quitting to desktop")
			pcall(function() setGameSpeed(1) end)
			pcall(function() getCore():quitToDesktop() end)
		end
		return
	end
	if job.ended then return end
	local paused = false
	pcall(function() paused = isGamePaused() end)
	if paused then
		-- don't let a pause eat the delay or the timeout
		if job.lastT then
			local d = t - job.lastT
			job.startAt = job.startAt + d
			job.deadline = job.deadline + d
		end
		job.lastT = t
		return
	end
	job.lastT = t
	if not job.started then
		if t >= job.startAt then
			job.started = true
			if job.newsave then A.saveNewsave(job) else startRun() end
		end
		return
	end
	if t >= job.deadline then
		pcall(function() if TestGround and TestGround.stop then TestGround.stop("autorun timeout") end end)
		finishJob({ "result = timeout", "error = no finished run within " .. job.flag.timeout .. " s" })
	end
end

-- OnTick doesn't fire while the game is paused, and an unattended run has nobody to unpause it.
-- OnRenderTick still fires: if the game sits paused for 5 s at any point until the job ends
-- (before the run, or after the survey's teleports), unpause it.
local pausedSince = nil
local function onPauseCheck()
	guideCheck()
	if not job or (job.ended and not job.quitAt and not job.menuAt and not job.menuFailAt) then   -- the quit also needs OnTick
		Events.OnRenderTick.Remove(onPauseCheck)
		return
	end
	local paused = false
	pcall(function() paused = isGamePaused() end)
	if not paused then pausedSince = nil; return end
	local t = now()
	pausedSince = pausedSince or t
	if t - pausedSince > 5000 then
		pausedSince = nil
		job.unpauses = (job.unpauses or 0) + 1
		local ok, err = pcall(function() UIManager.getSpeedControls():SetCurrentGameSpeed(1) end)
		say("game was paused " .. (job.started and "during the run" or "before the run") .. "; unpausing (" ..
			(ok and "ok" or tostring(err)) .. ", " .. job.unpauses .. " so far)")
	end
end

local function onGameStart()
	local st = A.readState()
	writeLines(STATE, {})
	local f = A.readFlag()
	if not f then return end
	local world = nil
	pcall(function() world = getWorld():getWorld() end)
	if f.newsave then
		if st.kind == "newsave" and st.name == f.newsave and tostring(world) == f.newsave then
			writeLines(STATE, { "newsave " .. stamp() .. " " .. f.newsave })
			local t = now()
			local wait = math.min(f.delay, 30)
			job = { flag = f, newsave = f.newsave, startAt = t + wait * 1000, deadline = t + (wait + 600) * 1000 }
			Events.OnTick.Add(onGameTick)
			Events.OnRenderTick.Add(onPauseCheck)
			say("active (" .. VERSION .. "): new save " .. f.newsave .. " loaded; saving it in " .. wait .. " s")
		else
			say("flag asks for a new save (" .. f.newsave .. ") but this game is " .. tostring(world) .. "; not running")
		end
		return
	end
	if tostring(world) ~= f.save then
		say("flag names " .. f.save .. " but this save is " .. tostring(world) .. "; not running")
		return
	end
	local flagLines = readLines(FLAG)
	writeLines(FLAG, {})   -- one run per flag
	local t = now()
	job = { flag = f, flagLines = flagLines, startAt = t + f.delay * 1000, deadline = t + (f.delay + f.timeout) * 1000 }
	Events.OnTick.Add(onGameTick)
	Events.OnRenderTick.Add(onPauseCheck)
	say("active (" .. VERSION .. "): " .. f.plan .. " in " .. f.delay .. " s, then " ..
		(((f.loadn or 1) < (f.loads or 1)) and string.format("back to the main menu for load %d of %d", (f.loadn or 1) + 1, f.loads) or (f.quit and "quit" or "stay")))
	-- options.ini focusloss=true pauses the game whenever the window loses focus (an unattended run's
	-- usual stall); say which it is, so a stall is explained in one line
	local okF, fl = pcall(function() return getCore():getOptionPauseOnFocusloss() end)
	job.focusloss = okF and tostring(fl) or "unknown"
	say("pause on focus loss (options.ini focusloss): " .. job.focusloss ..
		(job.focusloss == "true" and "; the game will pause when its window isn't in front, and the run unpauses it after 5 s each time" or ""))
end

Events.OnMainMenuEnter.Add(onMainMenuEnter)
Events.OnGameStart.Add(onGameStart)
if Events.OnInitWorld then Events.OnInitWorld.Add(A.onInitWorld) end
-- after newsave's Lua reload the menu may not be entered again; pick the flag up from here too
if Events.OnResetLua then
	Events.OnResetLua.Add(function(reason) if reason == "TestGroundNewsave" then onMainMenuEnter() end end)
end
