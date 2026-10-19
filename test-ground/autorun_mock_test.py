"""Mock test for Test Ground Autorun: fake main menu, fake game, fake Test Ground.

python3 test-ground/autorun_mock_test.py      # ends with "ALL OK"
"""
import os
from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, 'TestGroundAutorun/42/media/lua/client/TestGroundAutorun.lua'), encoding='utf-8').read()

BENCH_SRC = None
ok = True
def check(cond, msg):
    global ok
    print(('ok   ' if cond else 'FAIL ') + msg)
    ok = ok and bool(cond)

PRELUDE = r'''
next = nil
clock = 1792140000000
function getTimestampMs() return clock end
paused = false
function isGamePaused() return paused end
FILES = FILES or {}
function getFileWriter(name, create, append)
  if not append then FILES[name] = {} end
  FILES[name] = FILES[name] or {}
  local t = FILES[name]
  return { writeln = function(_, l) t[#t+1] = l end, close = function() end }
end
function getFileReader(name)
  local t = FILES[name]
  if not t then return nil end
  local i = 0
  return { readLine = function() i = i + 1; return t[i] end, close = function() end }
end
Events = {}
for _, n in ipairs({"OnMainMenuEnter","OnGameStart","OnTick","OnFETick","OnRenderTick","OnInitWorld","OnResetLua"}) do
  local e = { l = {} }
  e.Add = function(f) table.insert(e.l, f) end
  e.Remove = function(f) for i, g in ipairs(e.l) do if g == f then table.remove(e.l, i) return end end end
  Events[n] = e
end
function fire(n, ...) local c = {} for i, f in ipairs(Events[n].l) do c[i] = f end for _, f in ipairs(c) do f(...) end end
LOADS = {}
MainScreen = { instance = {}, continueLatestSave = function(mode, save) table.insert(LOADS, mode .. "/" .. save) end }
WORLD = "Lumberjack - Copy - PerfTest"
function getWorld() return { getWorld = function() return WORLD end } end
QUIT = 0
function getCore() return { quitToDesktop = function() QUIT = QUIT + 1 end, getOptionPauseOnFocusloss = function() return true end } end
function setGameSpeed() end
UIManager = { getSpeedControls = function() return { SetCurrentGameSpeed = function(_, n) if n > 0 then paused = false; UNPAUSED = (UNPAUSED or 0) + 1 end end } end }
'''

def fresh(files=None):
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    L.execute('FILES = {}')
    if files:
        for k, v in files.items():
            L.execute('FILES[%r] = {}' % k)
            for l in v:
                L.execute('table.insert(FILES[%r], %r)' % (k, l))
    L.execute(PRELUDE)
    L.execute(SRC)
    return L

def ticks(L, n, step=100):
    # the main menu only gets OnFETick, the game only OnTick (as in PZ)
    L.execute('for i = 1, %d do clock = clock + %d; fire(INGAME and "OnTick" or "OnFETick") end' % (n, step))

def lines(L, name):
    t = L.eval('FILES[%r]' % name)
    return [t[i] for i in range(1, len(t) + 1)] if t else []

FLAG = ['save = Lumberjack - Copy - PerfTest', 'mode = Sandbox', 'plan = baseline   # comment', 'delay = 5', 'quit = 1']

# 1. No flag: nothing at all.
L = fresh()
L.execute('fire("OnMainMenuEnter")')
ticks(L, 100)
check(L.eval('#LOADS') == 0 and L.eval('#Events.OnTick.l') == 0 and L.eval('#Events.OnFETick.l') == 0, 'no flag: no load, no tick handler')
L.execute('INGAME = true; fire("OnGameStart")')
check(L.eval('#Events.OnTick.l') == 0, 'no flag: nothing in game')

# 2. Empty flag file: nothing.
L = fresh({'TestGround_autorun.txt': []})
L.execute('fire("OnMainMenuEnter")'); ticks(L, 100)
check(L.eval('#LOADS') == 0, 'empty flag: no load')

# 3. Menu loads the save once, after a short delay; a second menu entry (Lua reset) doesn't load again.
L = fresh({'TestGround_autorun.txt': FLAG})
L.execute('fire("OnMainMenuEnter")')
ticks(L, 10)
check(L.eval('#LOADS') == 0, 'menu: waits before loading')
ticks(L, 30)
check(L.eval('#LOADS') == 1 and L.eval('LOADS[1]') == 'Sandbox/Lumberjack - Copy - PerfTest', 'menu: loads the named save')
state = lines(L, 'TestGround_autorun_state.txt')
L2 = fresh({'TestGround_autorun.txt': FLAG, 'TestGround_autorun_state.txt': state})
L2.execute('clock = clock + 20000; fire("OnMainMenuEnter")'); ticks(L2, 40)
check(L2.eval('#LOADS') == 0, 'menu after the Lua reset: no second load')
L3 = fresh({'TestGround_autorun.txt': FLAG, 'TestGround_autorun_state.txt': state})
L3.execute('clock = clock + 400000; fire("OnMainMenuEnter")'); ticks(L3, 40)
check(L3.eval('#LOADS') == 1, 'stale load note (minutes old) is ignored')

# 3b. 1.4.3: the game's save check dialog after the load ("map not found") ends the job at once
L = fresh({'TestGround_autorun.txt': FLAG})
L.execute('MainScreen.continueLatestSave = function(mode, save) table.insert(LOADS, mode .. "/" .. save); MainScreen.instance.checkSavefileModal = { text = "<H1> Error loading savefile <LINE> map not found: Project RV Interior" } end')
L.execute('fire("OnMainMenuEnter")'); ticks(L, 45)
done = lines(L, 'TestGround_autorun_done.txt')
check(L.eval('#LOADS') == 1 and 'result = load failed' in done and any('save check dialog' in l and 'map not found: Project RV Interior' in l for l in done) and lines(L, 'TestGround_autorun.txt') == [],
      'save check dialog after the load: done file says load failed with the dialog text, flag cleared (%s)' % done)
# and after a Lua reset (the dialog comes up in the new Lua state, where the load was already asked for)
L2 = fresh({'TestGround_autorun.txt': FLAG, 'TestGround_autorun_state.txt': state})
L2.execute('clock = clock + 20000; fire("OnMainMenuEnter")'); ticks(L2, 40)
L2.execute('MainScreen.instance.checkSavefileModal = { text = "Error loading savefile" }'); ticks(L2, 3)
done2 = lines(L2, 'TestGround_autorun_done.txt')
check(L2.eval('#LOADS') == 0 and any('save check dialog: Error loading savefile' in l for l in done2), 'save check dialog after a Lua reset: also caught (%s)' % done2)
L.execute('MainScreen.instance.checkSavefileModal = nil; MainScreen.continueLatestSave = function(mode, save) table.insert(LOADS, mode .. "/" .. save) end')
# 4. In game, wrong save: nothing.
L = fresh({'TestGround_autorun.txt': FLAG})
L.execute('INGAME = true; WORLD = "Lumberjack"; fire("OnGameStart")')
check(L.eval('#Events.OnTick.l') == 0 and lines(L, 'TestGround_autorun.txt') == FLAG, 'other save: does nothing, flag kept')

# 5. In game, right save: consumes flag, waits, runs, writes done, quits.
STUB = r'''
CMDS = {}
TestGround = { start = function() return true end, loadPlan = function() return {} end }
TestGround.spots = { westpoint = { name = "West Point, South St", x = 11501, y = 6949, z = 0 } }
TestGround.defaultSpot = "westpoint"
TestGround.command = function(c) table.insert(CMDS, c); return { string.find(c, "^baseline") and "surveying for the baseline" or "started baseline" } end
TestGround.onFinish = function(last) BRIDGE_SAW = last.report end
'''
WPBASE = ['label = baseline', 'start = westpoint          # West Point, South St (11501,6949,0)']
L = fresh({'TestGround_autorun.txt': FLAG})
L.execute(STUB)
L.execute('INGAME = true; fire("OnGameStart")')
check(lines(L, 'TestGround_autorun.txt') == [], 'game: flag emptied (one run per flag)')
ticks(L, 40)
check(L.eval('#CMDS') == 0, 'game: waits for the delay')
L.execute('paused = true'); ticks(L, 100); L.execute('paused = false')
check(L.eval('#CMDS') == 0, 'game: paused time does not count')
L.execute('paused = true; for i = 1, 30 do clock = clock + 100; fire("OnRenderTick") end')
check(L.eval('paused') is True, 'game: a short pause is left alone')
L.execute('for i = 1, 40 do clock = clock + 100; fire("OnRenderTick") end')
check(L.eval('paused') is False and L.eval('UNPAUSED') == 1, 'game: paused 5 s+ before the run, so it unpauses (OnRenderTick)')
ticks(L, 20)
check(L.eval('CMDS[1]') == 'baseline westpoint', 'game: no baseline plan yet, so it surveys at the fixed start (bridge "baseline westpoint")')
L.execute('paused = true; for i = 1, 70 do clock = clock + 100; fire("OnRenderTick") end')
check(L.eval('paused') is False and L.eval('UNPAUSED') == 2, 'game: paused 5 s+ during the run (after the survey), so it unpauses again')
L.execute('TestGround.onFinish({ report = "R.txt", trace = "T.txt", perf = "P.csv", spikes = "S.csv" })')
done = lines(L, 'TestGround_autorun_done.txt')
print('\n'.join(done))
check(done[:2] == ['result = done', 'report = R.txt'] and 'perf = P.csv' in done and 'save = Lumberjack - Copy - PerfTest' in done and 'unpaused = 2' in done and 'focusloss = true' in done, 'done marker written')
check(L.eval('BRIDGE_SAW') == 'R.txt', 'Test Ground own onFinish still called')
ticks(L, 30)
check(L.eval('QUIT') == 0, 'quit waits a moment')
ticks(L, 30)
check(L.eval('QUIT') == 1, 'quits to desktop')

# 5b. closeui = 1 closes the Character Info window and other windows, keeps inventory and chat.
UI = r'''
function mkclass(name, parent) local c = {}; c.__index = c; c.Type = name; if parent then setmetatable(c, parent) end; return c end
ISPanel = mkclass("ISPanel")
ISCollapsableWindow = mkclass("ISCollapsableWindow", ISPanel)
ISCollapsableWindow.close = function(self) self.vis = false end
local function win(class, vis) local o = setmetatable({ vis = vis }, class); o.getIsVisible = function(s) return s.vis end; return o end
local Info = mkclass("ISCharacterInfoWindow", ISCollapsableWindow)
local Craft = mkclass("ISCraftingUI", ISCollapsableWindow)
local Chat = mkclass("ISChat", ISCollapsableWindow)
local Inv = mkclass("ISInventoryPage", ISPanel)
INFO, CRAFT, CHAT, INV = win(Info, true), win(Craft, true), win(Chat, true), win(Inv, true)
HIDDEN = win(Craft, false)
function getPlayerInfoPanel() return INFO end
local function el(t) return { getTable = function() return t end, isVisible = function() return t.vis end } end
local els = { el(INFO), el(CRAFT), el(CHAT), el(INV), el(HIDDEN) }
UIManager.getUI = function() return { size = function() return #els end, get = function(_, i) return els[i + 1] end } end
'''
L = fresh({'TestGround_autorun.txt': FLAG + ['closeui = 1']})
L.execute(STUB); L.execute(UI); L.execute('INGAME = true; fire("OnGameStart")'); ticks(L, 70)
check(L.eval('INFO.vis') is False and L.eval('CRAFT.vis') is False, 'closeui: Character Info and other windows closed')
check(L.eval('CHAT.vis') is True and L.eval('INV.vis') is True, 'closeui: chat and inventory left open')
L.execute('TestGround.onFinish({ report = "R.txt" })')
check('closed_ui = ISCharacterInfoWindow, ISCraftingUI' in lines(L, 'TestGround_autorun_done.txt'), 'closeui: done file lists what was closed')
L = fresh({'TestGround_autorun.txt': FLAG})
L.execute(STUB); L.execute(UI); L.execute('INGAME = true; fire("OnGameStart")'); ticks(L, 70)
check(L.eval('INFO.vis') is True, 'closeui off by default: windows left alone')

# 6. Existing baseline plan is reused.
L = fresh({'TestGround_autorun.txt': FLAG, 'TestGround_baseline.txt': WPBASE})
L.execute(STUB); L.execute('INGAME = true; fire("OnGameStart")'); ticks(L, 70)
check(L.eval('CMDS[1]') == 'run TestGround_baseline.txt', 'existing baseline plan is reused')

# 6a. A baseline surveyed where the save loaded is surveyed again at the fixed start; "start = here" keeps it.
OLDBASE = ['label = baseline', 'start = 12090,6736,0']
L = fresh({'TestGround_autorun.txt': FLAG, 'TestGround_baseline.txt': OLDBASE})
L.execute(STUB); L.execute('INGAME = true; fire("OnGameStart")'); ticks(L, 70)
check(L.eval('CMDS[1]') == 'baseline westpoint', 'baseline from where the save loaded: surveyed again at the fixed start')
L = fresh({'TestGround_autorun.txt': FLAG + ['start = here'], 'TestGround_baseline.txt': OLDBASE})
L.execute(STUB); L.execute('INGAME = true; fire("OnGameStart")'); ticks(L, 70)
check(L.eval('CMDS[1]') == 'run TestGround_baseline.txt', 'start = here: the where-loaded baseline is reused')
L.execute('TestGround.onFinish({ report = "R.txt" })')
check('start = here' in (lines(L, 'TestGround_autorun_done.txt') or []), 'done file says which start')

# 6b. skip = phases: handed to Test Ground and listed in the done file.
F3 = FLAG[:-1] + ['skip = fight_small,fight_large', 'timeout = 10']
L = fresh({'TestGround_autorun.txt': F3, 'TestGround_baseline.txt': WPBASE})
L.execute(STUB); L.execute('TestGround.stop = function() end; INGAME = true; fire("OnGameStart")'); ticks(L, 200)
check(L.eval('TestGround.skip') == 'fight_small,fight_large' and 'skip = fight_small,fight_large' in (lines(L, 'TestGround_autorun_done.txt') or []), 'skip: passed to Test Ground and listed in the done file')

# 6b2. 1.4.5: viewpoint = third: handed to Test Ground and listed in the done file.
F3V = FLAG[:-1] + ['viewpoint = third', 'timeout = 10']
L = fresh({'TestGround_autorun.txt': F3V, 'TestGround_baseline.txt': WPBASE})
L.execute(STUB); L.execute('TestGround.stop = function() end; INGAME = true; fire("OnGameStart")'); ticks(L, 200)
check(L.eval('TestGround.viewpoint') == 'third' and 'viewpoint = third' in (lines(L, 'TestGround_autorun_done.txt') or []), 'viewpoint: passed to Test Ground and listed in the done file')

# 6c. The survivor guide window that opens over a loaded save is closed, the way Esc closes it.
GUIDE = r'''
Keyboard = { KEY_ESCAPE = 1 }
SurvivalGuide = { instance = { vis = true, escOnly = ESC_ONLY } }
SurvivalGuide.instance.getIsVisible = function(s) return s.vis end
SurvivalGuide.instance.setVisible = function(s, v) if s.escOnly then error("no") end s.vis = v end
SurvivalGuide.instance.onKeyRelease = function(s, k) if k == Keyboard.KEY_ESCAPE then s.vis = false end end
'''
L = fresh({'TestGround_autorun.txt': FLAG, 'TestGround_baseline.txt': WPBASE})
L.execute(STUB); L.execute(GUIDE); L.execute('INGAME = true; fire("OnGameStart"); clock = clock + 16; fire("OnRenderTick")')
check(L.eval('SurvivalGuide.instance.vis') is False, 'survivor guide: closed on the first frame after load')
ticks(L, 80); L.execute('TestGround.onFinish({ report = "R.txt" })')
check('survival_guide = closed' in (lines(L, 'TestGround_autorun_done.txt') or []), 'survivor guide: the done file says it was closed')
L = fresh({'TestGround_autorun.txt': FLAG})
L.execute(STUB); L.execute('ESC_ONLY = true'); L.execute(GUIDE); L.execute('INGAME = true; fire("OnGameStart"); clock = clock + 16; fire("OnRenderTick")')
check(L.eval('SurvivalGuide.instance.vis') is False, 'survivor guide: falls back to its own Esc handler')

# 7. Timeout: run never finishes.
F2 = FLAG[:-1] + ['quit = 0', 'timeout = 10']
L = fresh({'TestGround_autorun.txt': F2})
L.execute(STUB); L.execute('STOPPED = nil; TestGround.stop = function(w) STOPPED = w end; INGAME = true; fire("OnGameStart")')
ticks(L, 200)
done = lines(L, 'TestGround_autorun_done.txt')
check(done and done[0] == 'result = timeout' and L.eval('STOPPED') == 'autorun timeout', 'timeout writes the marker and stops the run')
check(L.eval('QUIT') == 0, 'quit = 0 stays in game')

# 8. No Test Ground in the save.
L = fresh({'TestGround_autorun.txt': FLAG})
L.execute('INGAME = true; fire("OnGameStart")'); ticks(L, 80)
done = lines(L, 'TestGround_autorun_done.txt')
check(done and done[0] == 'result = no run', 'no Test Ground: marker says no run')


# 9. newsave: a fresh vanilla save, made with only the Test Ground mods, then its mod list set to `mods`.
NS = r"""
function mkmods(list) local o = { m = {} }
  for _, x in ipairs(list or {}) do o.m[#o.m+1] = x end
  o.getMods = function(self) local m = self.m; return { size = function() return #m end, get = function(_, i) return m[i+1] end } end
  o.clear = function(self) self.m = {} end
  o.setModActive = function(self, id, on) if on then for _, x in ipairs(self.m) do if x == id then return end end; self.m[#self.m+1] = id end end
  o.copyFrom = function(self, other) self.m = {}; for _, x in ipairs(other.m) do self.m[#self.m+1] = x end end
  o.removeMod = function(self, id) for i, x in ipairs(self.m) do if x == id then table.remove(self.m, i); return end end end
  return o end
AM = { default = mkmods({"\\TestGround","\\TestGroundBridge","\\TestGroundAutorun","\\BetterBuildingPlus"}), currentGame = mkmods({}) }
ActiveMods = { getById = function(id) return AM[id] end,
  requiresResetLua = function(am) local d = AM.default.m; if #am.m ~= #d then return true end; for i = 1, #d do if am.m[i] ~= d[i] then return true end end; return false end }
INSTALLED = { ["\\TestGround"]=1, ["\\TestGroundBridge"]=1, ["\\TestGroundAutorun"]=1, ["\\BetterBuildingPlus"]=1, ["\\ModA"]=1 }
function getModInfoByID(id) return INSTALLED[id] and {} or nil end
SAVES = SAVES or {}
function getFileSeparator() return "/" end
function checkSaveFolderExists(f) return SAVES[f] ~= nil end
function manipulateSavefile(f, what) if what == "WriteModsDotTxt" then SAVES[f] = SAVES[f] or {}; SAVES[f].mods = mkmods(AM.currentGame.m) end end
function getSaveInfo(f) local s = SAVES[f]; if not s then return {} end; return { activeMods = s.mods, playerAlive = s.player } end
function sanitizeWorldName(n) return (string.gsub(n, "[/\\\\:]", "")) end
WS = { luaPos = {} }
function getWorld() return {
  getWorld = function() return WORLD end, setWorld = function(_, n) WS.world = n end, setGameMode = function(_, m) WS.mode = m end,
  setMap = function(_, m) WS.map = m end, setPreset = function(_, p) WS.preset = p end,
  setLuaPosX = function(_, v) WS.luaPos.x = v end, setLuaPosY = function(_, v) WS.luaPos.y = v end, setLuaPosZ = function(_, v) WS.luaPos.z = v end } end
RESETS = {}
QUIT = 0; QUITMENU = 0
function getCore() return { quitToDesktop = function() QUIT = QUIT + 1 end, quit = function() QUITMENU = QUITMENU + 1 end,
  getOptionPauseOnFocusloss = function() return false end, setSelectedMap = function() end,
  ResetLua = function(_, which, why) table.insert(RESETS, which .. ":" .. why) end } end
SANDBOX_RESET = 0
MainScreen.instance = { setDefaultSandboxVars = function() SANDBOX_RESET = SANDBOX_RESET + 1 end,
  charCreationProfession = { resetBuild = function() PROF = "unemployed" end },
  charCreationMain = { randomGenericOutfit = function() DRESSED = true end } }
MapSpawnSelect = { instance = { getSpawnRegions = function() return { { name = "Muldraugh, KY" }, { name = "West Point, KY" } } end, saveGenParams = function() SEEDED = true end } }
function setSpawnRegion(n) REGION = n end
CREATED = nil
function createWorld(n) CREATED = n; SAVES["Sandbox/" .. n] = { mods = mkmods(AM.currentGame.m) } end
GameWindow = { doRenderEvent = function() end }
LoadingQueueState = { new = function() return {} end }
function forceChangeState() LOADING = true end
function getSandboxOptions() error("no sandbox in mock") end
TestGround = { spots = { westpoint = { x = 11501, y = 6949, z = 0 } } }
"""
NSFLAG = ['newsave = Vanilla Base', 'delay = 5', 'quit = 1']
L = fresh({'TestGround_autorun.txt': NSFLAG})
L.execute(NS)
L.execute('fire("OnMainMenuEnter")'); ticks(L, 40)
check(L.eval('RESETS[1]') == 'currentGame:TestGroundNewsave' and L.eval('CREATED') is None, 'newsave: menu runs another mod, so Lua is reloaded with just the Test Ground mods first')
check(list(L.eval('AM.currentGame.m').values()) == ['\\TestGround', '\\TestGroundBridge', '\\TestGroundAutorun'], 'newsave: made with only the Test Ground mods (BBP left out)')
state = lines(L, 'TestGround_autorun_state.txt')
# after the reload: a new Lua state, same files and Java-side mods
L2 = fresh({'TestGround_autorun.txt': NSFLAG, 'TestGround_autorun_state.txt': state})
L2.execute(NS); L2.execute('AM.currentGame.m = {"\\\\TestGround","\\\\TestGroundBridge","\\\\TestGroundAutorun"}')
L2.execute('fire("OnResetLua", "TestGroundNewsave")'); ticks(L2, 40)
check(L2.eval('CREATED') == 'Vanilla Base' and L2.eval('WS.mode') == 'Sandbox' and L2.eval('WS.map') == 'DEFAULT' and L2.eval('REGION') == 'West Point, KY', 'newsave: world created (Sandbox, default map, West Point region)')
check(L2.eval('SANDBOX_RESET') == 1 and L2.eval('PROF') == 'unemployed' and L2.eval('DRESSED') is True and L2.eval('LOADING') is True, 'newsave: default sandbox, default character, loading started')
L2.execute('fire("OnInitWorld")')
check(L2.eval('WS.luaPos.x') == 11501 and L2.eval('WS.luaPos.y') == 6949, 'newsave: spawn moved to the fixed West Point start')
# in game
L2.execute('INGAME = true; WORLD = "Vanilla Base"; fire("OnGameStart")')
check(lines(L2, 'TestGround_autorun.txt') == NSFLAG, 'newsave in game: flag kept for the menu step')
L2.execute('getPlayer = function() return { getX = function() return 11501.5 end, getY = function() return 6949.2 end, getZ = function() return 0 end, getDescriptor = function() return { getForename = function() return "Kate" end, getSurname = function() return "Smith" end, getCharacterProfession = function() return "base:unemployed" end } end } end')
ticks(L2, 70)
check(L2.eval('QUITMENU') == 1, 'newsave in game: saves and goes back to the main menu')
state = lines(L2, 'TestGround_autorun_state.txt')
check(state[0].startswith('newsave-saved ') and 'spawn = 11501,6949,0' in state, 'newsave in game: state notes the save and where the player is')
# back at the menu (Lua reset to the default mods)
L3 = fresh({'TestGround_autorun.txt': NSFLAG, 'TestGround_autorun_state.txt': state})
L3.execute(NS); L3.execute('SAVES["Sandbox/Vanilla Base"] = { mods = mkmods({"\\\\TestGround"}), player = true }')
L3.execute('fire("OnMainMenuEnter")'); ticks(L3, 40)
done = lines(L3, 'TestGround_autorun_done.txt')
print('\n'.join(done))
check(done[0] == 'result = newsave created' and any(l.startswith('mods = none (vanilla') for l in done) and 'player_saved = true' in done and 'spawn = 11501,6949,0' in done, 'newsave: done file, save now has no mods (vanilla)')
check(L3.eval('#SAVES["Sandbox/Vanilla Base"].mods.m') == 0 and L3.eval('#AM.currentGame.m') == 4, 'newsave: mods.txt empty, currentGame put back to the menu list')
check(lines(L3, 'TestGround_autorun.txt') == [] and L3.eval('QUIT') == 1 and L3.eval('#LOADS') == 0, 'newsave: flag cleared, quits')

# 9a. A name the game's folder rules change (here ":" dropped) is made under the game's name, not refused;
# spaces are fine.
L = fresh({'TestGround_autorun.txt': ['newsave = Vanilla: Base', 'save = Vanilla: Base', 'plan = fight']})
L.execute(NS); L.execute('AM.currentGame.m = {"\\\\TestGround","\\\\TestGroundBridge","\\\\TestGroundAutorun"}; RESETS = {}')
L.execute('ActiveMods.requiresResetLua = function() return false end')
L.execute('fire("OnMainMenuEnter")'); ticks(L, 40)
check(L.eval('CREATED') == 'Vanilla Base' and L.eval('TestGroundAutorun.readFlag().save') == 'Vanilla Base', 'newsave: the name is cleaned the game way (Vanilla: Base -> Vanilla Base), spaces kept, save = follows it')

# 9b. An existing save is never overwritten; a mod that isn't installed fails cleanly.
L = fresh({'TestGround_autorun.txt': NSFLAG})
L.execute(NS); L.execute('SAVES["Sandbox/Vanilla Base"] = { mods = mkmods({}) }')
L.execute('fire("OnMainMenuEnter")'); ticks(L, 40)
check(lines(L, 'TestGround_newsave_done.txt')[0] == 'result = newsave failed' and L.eval('CREATED') is None and L.eval('#RESETS') == 0, 'newsave: existing save refused')
L = fresh({'TestGround_autorun.txt': NSFLAG + ['mods = ModA, Missing']})
L.execute(NS); L.execute('fire("OnMainMenuEnter")'); ticks(L, 40)
check('error = not installed: Missing' in lines(L, 'TestGround_autorun_done.txt'), 'newsave: missing mod named in the done file')

# 9c. newsave then a run: mods = ModA, then load it with the Test Ground mods added.
F = ['newsave = Base2', 'mods = ModA', 'save = Base2', 'addmods = TestGround,TestGroundBridge,TestGroundAutorun', 'plan = fight', 'quit = 1']
st = ['newsave-saved %d Base2' % 1792140000000, 'spawn = 1,2,0', 'player = x']
L = fresh({'TestGround_autorun.txt': F, 'TestGround_autorun_state.txt': st})
L.execute(NS); L.execute('SAVES["Sandbox/Base2"] = { mods = mkmods({}), player = true }')
L.execute('fire("OnMainMenuEnter")'); ticks(L, 40)
check(lines(L, 'TestGround_newsave_done.txt')[0] == 'result = newsave created' and 'mods = \\ModA' in lines(L, 'TestGround_newsave_done.txt'), 'newsave + run: newsave result in its own file')
check(list(L.eval('SAVES["Sandbox/Base2"].mods.m').values()) == ['\\ModA', '\\TestGround', '\\TestGroundBridge', '\\TestGroundAutorun'], 'newsave + run: addmods added the Test Ground mods to the save')
check(L.eval('LOADS[1]') == 'Sandbox/Base2' and not any(l.startswith('newsave') for l in lines(L, 'TestGround_autorun.txt')), 'newsave + run: loads it, newsave lines dropped from the flag')

# 9d. 1.4.4: addmods' changes are taken off the save's mod list the next time the menu shows
L = fresh({'TestGround_autorun.txt': ['save = Lumber', 'addmods = TestGround,TestGroundAutorun', 'plan = fight']})
L.execute(NS); L.execute('SAVES["Sandbox/Lumber"] = { mods = mkmods({"\\\\ModA", "\\\\TestGround"}), player = true }')
L.execute('fire("OnMainMenuEnter")'); ticks(L, 40)
m1 = list(L.eval('SAVES["Sandbox/Lumber"].mods.m').values())
bk = lines(L, 'TestGround_autorun_mods.txt')
# the next game start: a fresh Lua state at the menu, the flag already used, the load long ago
L2 = fresh({'TestGround_autorun_mods.txt': bk, 'TestGround_autorun.txt': []})
L2.execute(NS); L2.execute('SAVES["Sandbox/Lumber"] = { mods = mkmods(%s), player = true }' % ('{' + ','.join(repr(x) for x in m1) + '}'))
L2.execute('fire("OnMainMenuEnter")'); ticks(L2, 40)
m2 = list(L2.eval('SAVES["Sandbox/Lumber"].mods.m').values())
check(m1 == ['\\ModA', '\\TestGround', '\\TestGroundAutorun'] and bk == ['mode = Sandbox', 'save = Lumber', 'added = \\TestGroundAutorun'] and m2 == ['\\ModA', '\\TestGround'] and lines(L2, 'TestGround_autorun_mods.txt') == [],
      'addmods: only the mods it turned on are noted, and taken off the save\'s list again at the next menu (%s -> %s, %s)' % (m1, m2, bk))

# 10. 1.4.6: loads = 2: after the run, back to the main menu, load the same save again, idle, quit
L = fresh({'TestGround_autorun.txt': FLAG + ['loads = 2', 'reloadplan = idle']})
L.execute(STUB)
L.execute('QUITMENU = 0; local old = getCore; function getCore() local c = old(); c.quit = function() QUITMENU = QUITMENU + 1 end; return c end')
L.execute('INGAME = true; fire("OnGameStart")'); ticks(L, 70)
L.execute('TestGround.onFinish({ report = "R1.txt", trace = "T.txt", perf = "P.csv", spikes = "S.csv" })')
fl = lines(L, 'TestGround_autorun.txt')
d1 = lines(L, 'TestGround_autorun_done_load1.txt')
ticks(L, 60)
check(L.eval('QUITMENU') == 1 and L.eval('QUIT') == 0 and lines(L, 'TestGround_autorun_done.txt') == [] and 'load = 1 of 2' in d1
      and 'loadn = 2' in fl and 'plan = idle' in fl and 'load_1 = result = done' in fl and not any(l.startswith('plan = baseline') for l in fl),
      'loads = 2: after load 1 the flag is written back for load 2 and it quits to the main menu, not the desktop (%s)' % fl)
# the main menu again (the same Lua state is fine here), then the second load
L.execute('INGAME = false; LOADS = {}; fire("OnMainMenuEnter")'); ticks(L, 40)
check(L.eval('LOADS[1]') == 'Sandbox/Lumberjack - Copy - PerfTest', 'loads = 2: the main menu loads the same save again')
L.execute('CMDS = {}; INGAME = true; fire("OnGameStart")'); ticks(L, 70)
done = lines(L, 'TestGround_autorun_done.txt')
ticks(L, 60)
check(done and done[0] == 'result = idle' and 'load = 2 of 2' in done and 'load_1 = result = done' in done and L.eval('#CMDS') == 0 and L.eval('QUIT') == 1 and lines(L, 'TestGround_autorun.txt') == [],
      'loads = 2: load 2 idles (no run), the done file has both loads, then it quits to desktop (%s)' % done)

# 10b. 1.4.7: the quit to the main menu never happens: the final done file still comes, after 30 s
L = fresh({'TestGround_autorun.txt': FLAG + ['loads = 2', 'reloadplan = idle']})
L.execute(STUB)
L.execute('local old = getCore; function getCore() local c = old(); c.quit = function() end; return c end')
L.execute('INGAME = true; fire("OnGameStart")'); ticks(L, 70)
L.execute('TestGround.onFinish({ report = "R1.txt", trace = "T.txt", perf = "P.csv", spikes = "S.csv" })')
ticks(L, 360)
done = lines(L, 'TestGround_autorun_done.txt')
ticks(L, 60)
check(done and done[0] == 'result = load failed' and any('still in game 30 s after asking to quit' in l for l in done) and lines(L, 'TestGround_autorun.txt') == [] and L.eval('QUIT') == 1,
      'loads = 2: a quit to the menu that never happens ends with the done file and a quit to desktop (%s)' % done)

BENCH_SRC = open(os.path.join(HERE, 'TestGroundAutorun/42/media/lua/client/TestGroundBenchmark.lua'), encoding='utf-8').read()
# 11. 1.5.0: Benchmark Save: the window copies the chosen save, writes the flag, loads the copy; the copy goes at the next menu
BENCH = open(os.path.join(HERE, 'TestGroundAutorun/42/media/lua/client/TestGroundBenchmark.lua'), encoding='utf-8').read()
L = fresh()
L.execute(r'''
package.loaded["TestGroundAutorun"] = true
function require() return true end
UIFont = { Small = 1, Medium = 2 }
function getTimestamp() return 777 end
function getFileSeparator() return "/" end
ISPanel = { derive = function(self, n) local c = {}; c.__index = c; setmetatable(c, { __index = self }); _G[n] = c; return c end,
  new = function(self, x, y, w, h) return setmetatable({ x = x, y = y, width = w, height = h, children = {} }, self) end,
  initialise = function() end, instantiate = function(self) if self.createChildren then self:createChildren() end end, addChild = function(self, c) table.insert(self.children, c) end,
  addToUIManager = function() end, bringToTop = function() end, setVisible = function() end, removeFromUIManager = function() end, prerender = function() end }
ISScrollingListBox = ISPanel:derive("ISScrollingListBox")
ISScrollingListBox.instantiate = function() end
ISScrollingListBox.new = function(self, x, y, w, h) return setmetatable({ items = {}, children = {} }, ISScrollingListBox) end
ISScrollingListBox.addItem = function(self, t, item) table.insert(self.items, { text = t, item = item }) end
ISButton = ISPanel:derive("ISButton")
ISButton.instantiate = function() end
ISButton.setEnable = function(self, v) self.enabled = v end
ISButton.new = function(self, x, y, w, h, title, target, fn) return setmetatable({ title = title, target = target, fn = fn }, ISButton) end
function getCore() return { getScreenWidth = function() return 1920 end, getScreenHeight = function() return 1080 end, quitToDesktop = function() end } end
local function jf(mode, name, t) return { getName = function() return name end, lastModified = function() return t end, getParentFile = function() return { getName = function() return mode end } end } end
function getFullSaveDirectoryTable()
  local l = { jf("Sandbox", "Lumberjack", 5), jf("Sandbox", "Old", 1), jf("Sandbox", "TG Benchmark Old 1", 9), jf("Weird", "Other", 3) }
  return setmetatable({}, { __index = function(_, k) return nil end })  -- ipairs finds nothing: filled below
end
BIGLIST = { jf("Sandbox", "Lumberjack", 5), jf("Sandbox", "Old", 1), jf("Sandbox", "TG Benchmark Old 1", 9), jf("Weird", "Other", 3) }
function getFullSaveDirectoryTable() return BIGLIST end
COPIES = {}
COPYSTATE = "copying 1 of 9 MB"
TGCapture = { copySaveStart = function(mode, src, dst) table.insert(COPIES, mode .. "/" .. src .. " -> " .. dst); return "" end,
  copySaveStatus = function() return COPYSTATE end }
MainScreen.instance.addChild = function(self, c) self.kids = (self.kids or 0) + 1 end
DELETED = {}
function deleteSave(p) table.insert(DELETED, p) end
''')
L.execute(BENCH_SRC)
L.execute('TestGroundAutorun.writeSaveMods = function(folder, fn) return true, { "TestGround" } end')
L.execute('fire("OnMainMenuEnter")')
btn = L.eval('MainScreen.instance.testGroundBenchBtn ~= nil')
L.execute('MainScreen.instance.testGroundBenchBtn.fn()')
L.execute('W = TestGroundAutorun.benchWindow; W.list.selected = 2; W:onStart()')
mid = lines(L, 'TestGround_autorun.txt')
L.execute('clock = clock + 400; W:prerender()')
mid_note = L.eval('W.note')
L.execute('COPYSTATE = "done"; clock = clock + 400; W:prerender()')
fl = lines(L, 'TestGround_autorun.txt')
rec = lines(L, 'TestGround_benchcopy.txt')
names = L.eval('W.list.items[1].text .. "|" .. W.list.items[2].text .. "|" .. W.list.items[3].text .. "|" .. #W.list.items')
ticks(L, 20, 100)
check(mid == [] and 'copying 1 of 9 MB' in mid_note and btn and names == 'New vanilla save|Lumberjack   (Sandbox)|Old   (Sandbox)|3' and L.eval('COPIES[1]') == 'Sandbox/Lumberjack -> TG Benchmark Lumberjack 777'
      and 'save = TG Benchmark Lumberjack 777' in fl and 'origin = Lumberjack' in fl and 'quit = 0' in fl and 'endscreen = 1' in fl and 'name = TG Benchmark Lumberjack 777' in rec
      and L.eval('LOADS[1]') == 'Sandbox/TG Benchmark Lumberjack 777',
      'Benchmark Save: menu button, the list (newest first, no old copies), the copy made, the flag written, the copy loaded (%s | %s | %s)' % (names, fl, L.eval('COPIES[1]')))
# in game the run knows the chosen save; back at the menu the copy is deleted, once
L.execute(STUB)
L.execute('WORLD = "TG Benchmark Lumberjack 777"')
L.execute('INGAME = true; LOADS = {}; fire("OnGameStart")'); ticks(L, 260)
src = L.eval('TestGround.sourceSave')
L.execute('INGAME = false; TestGround.onFinish({ report = "R1.txt", trace = "T.txt", perf = "P.csv", spikes = "S.csv" }); fire("OnMainMenuEnter")')
check(src == 'Lumberjack' and L.eval('#DELETED') == 1 and L.eval('DELETED[1]') == 'Sandbox/TG Benchmark Lumberjack 777' and lines(L, 'TestGround_benchcopy.txt') == [],
      'Benchmark Save: the run is told the chosen save (%s), and the next main menu deletes the copy once (%s)' % (src, L.eval('DELETED[1]')))
# a record naming a save that is not a Benchmark copy is never deleted
L.execute('FILES["TestGround_benchcopy.txt"] = { "mode = Sandbox", "name = Lumberjack", "origin = x" }; DELETED = {}; fire("OnMainMenuEnter")')
check(L.eval('#DELETED') == 0, 'Benchmark Save: a record that names a normal save deletes nothing')

print('ALL OK' if ok else 'SOME FAILED')
