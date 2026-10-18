import re
import lupa, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
FIX = HERE + '/HitchFix/42/media/lua/shared/!!!_HitchFix.lua'
SIEVE = HERE + '/../chunkload-sieve/ChunkLoadSieve/42/media/lua/shared/!!!_ChunkLoadSieve.lua'
TMP = HERE + '/mocktmp'

def modfile(rel, code):
    p = os.path.join(TMP, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'w').write(code)
    return p

# stand-ins for the real mods, registering the way the real files do
AMMO = modfile('ammomaker/server/ammomaker_itemCleanUp.lua', r'''
function ammoMakerItemCleanUpAddModData(itemType, x, y, z)
  local t = ModData.getOrCreate("droppedCasings")
  table.insert(t, itemType .. ";" .. x .. ";" .. y .. ";" .. z .. ";" .. getWorld():getWorldAgeDays())
end
function AMMO_FN() ORIGINAL_AMMO_RAN = (ORIGINAL_AMMO_RAN or 0) + 1 end
Events.EveryTenMinutes.Add(AMMO_FN)
''')
GUN = modfile('Tuna_GunRacks/client/Tuna_WeaponRack.lua', r'''
local tick = 0
GUN_FN = function() tick = tick + 1; GUN_TICKS = (GUN_TICKS or 0) + 1 end
Events.OnTick.Add(GUN_FN)
''')
ER = modfile('Tuna_EquipmentRacks/client/Tuna_ER_Render.lua', r'''
Events.OnTick.Add(function() ER_TICKS = (ER_TICKS or 0) + 1 end)
''')
OTHER = modfile('Other/client/other.lua', r'''
Events.OnTick.Add(function() OTHER_TICKS = (OTHER_TICKS or 0) + 1 end)
Events.EveryTenMinutes.Add(function() OTHER_TEN = (OTHER_TEN or 0) + 1 end)
''')
FARM = modfile('server/Farming/SFarmingSystem.lua', r'''
SFarmingSystem = {}
SFarmingSystem.__index = SFarmingSystem
function SFarmingSystem:checkPlant()
  for i=1,self:getLuaObjectCount() do
    if not self:getLuaObjectByIndex(i) then break end
    self:checkPlant2(self:getLuaObjectByIndex(i))
  end
  local i = self:getLuaObjectCount()
  while i > 0 do
    if not self:getLuaObjectByIndex(i) then break end
    self:plowFadeCheck(self:getLuaObjectByIndex(i))
    i = i - 1
  end
end
function SFarmingSystem:checkPlant2(o) o.checks = (o.checks or 0) + 1; LOG[#LOG+1] = "c" .. o.id end
function SFarmingSystem:plowFadeCheck(o)
  o.plows = (o.plows or 0) + 1; LOG[#LOG+1] = "p" .. o.id
  if o.removeOnPlow then self:remove(o) end
end
function SFarmingSystem:getLuaObjectCount() return #self.objs end
function SFarmingSystem:getLuaObjectByIndex(i) return self.objs[i] end
function SFarmingSystem:getLuaObjectAt(x,y,z) for _,o in ipairs(self.objs) do if o.x==x and o.y==y and o.z==z then return o end end return nil end
function SFarmingSystem:remove(o) for i=#self.objs,1,-1 do if self.objs[i]==o then table.remove(self.objs,i) end end end
''')
NVF = modfile('NVFramework/common/media/lua/shared/nvframework_shared.lua', r'''
NV = NV or {}; NV.Shared = NV.Shared or {}
local REG = {}
NV_ORIG_CALLS = 0
function NV.Shared.IsNVTaggedItem(item)
  NV_ORIG_CALLS = NV_ORIG_CALLS + 1
  if not item or not item.getType then return false end
  return REG[item:getFullType()] == true or string.find(item:getType(), "NVG", 1, true) ~= nil
end
function NV.Shared.RegisterNightVisionItem(ft) REG[ft] = true; return true end
function NV.Shared.ClearScriptNightVisionCache() return true end
NV_SAVED_REGISTER = NV.Shared.RegisterNightVisionItem   -- a copy kept by some other mod
function NV.GetWornNVItem(player)
  local worn = player:getWornItems()
  for i = 0, worn:size() - 1 do
    local item = worn:get(i)
    if NV.Shared.IsNVTaggedItem(item) then return item end
  end
  return nil
end
''')

TIYL = modfile('ThisIsYourLife/42/media/lua/client/ThisIsYourLife/TIYLSurvivorJournal.lua', r'''
TIYL_RUNS = {0, 0, 0}
Events.OnTick.Add(function() TIYL_RUNS[1] = TIYL_RUNS[1] + 1 end) -- retryJournalItemRequest
Events.OnTick.Add(function() TIYL_RUNS[2] = TIYL_RUNS[2] + 1 end) -- retryJournalAdoption
Events.OnTick.Add(function() TIYL_RUNS[3] = TIYL_RUNS[3] + 1 end) -- markGameClockSettled
''')
BBP = modfile('BetterBuildingPlus/42/media/lua/server/BetterBuildingPlus/networking/server.lua', r'''
BBP_RUNS = 0
Events.OnClientCommand.Add(function() end)
Events.OnTick.Add(function() BBP_RUNS = BBP_RUNS + 1 end)
''')
LGEE = modfile('LGExtendedElectricity/42.20/media/lua/server/LGExtendedElectricity/LGEEGrid.lua', r'''
LGEE = LGEE or {}
LGEE_SWEEPS = 0
LGEE.perf = {}
local EE, marks, relays = LGEE, {}, 0
function EE.getOption(name) return OPTIONS_SEEN and false or false end
function EE.markStart(name) if EE.getOption("Debug") then marks[name] = getTimestampMs() end end
function EE.markEnd(name)
  if not EE.getOption("Debug") or not marks[name] then return end
  local row = EE.perf[name] or { calls = 0, total = 0, worst = 0 }
  EE.perf[name] = row
  row.calls, row.total = row.calls + 1, row.total + (getTimestampMs() - marks[name])
end
function EE.relayCount() return relays end
function EE.sweepPending() return LGEE_SWEEPS < 4 end
function LGEE.rebuild(budget, rotating)
  LGEE_SWEEPS = LGEE_SWEEPS + 1
  LGEE_LAST_BUDGET = budget
  if LGEE_SWEEPS <= 4 then
    EE.markStart("  .walk"); advanceClock(30); EE.markEnd("  .walk")
    advanceClock(10)   -- unmarked: engine figures
    EE.markStart("  .setRelays"); advanceClock(300); relays = relays + 100; EE.markEnd("  .setRelays")
  end
  return "built"
end
Events.OnTick.Add(function()
  LGEE_RESULT = LGEE.rebuild(400, false)
  if LGEE_SWEEPS == 2 then advanceClock(50) end  -- the rest of the handler, slow once
end)
''')
# An LGEE stand-in whose walk asks for the same player structures on every lap (300 ms each).
LGEE3 = modfile('LGExtendedElectricity3/42.20/media/lua/server/LGExtendedElectricity/LGEEGrid.lua', r'''
LGEE = LGEE or {}
LGEE.perf = {}
local EE = LGEE
function EE.getOption(name) return false end
function EE.relayCount() return 0 end
ASKED, SEEN, LAPS = 0, {}, 0
function EE.visitPlayerStructures(gx, gy, gz, radius, radiusSquared, vertical, visit)
  ASKED = ASKED + 1
  advanceClock(300)
  visit(gx, gy, gz); visit(gx + 1, gy, gz); visit(gx, gy + 1, gz)
  return 1, 3
end
function LGEE.rebuild(budget)
  LAPS = LAPS + 1
  local got = {}
  local w, e = EE.visitPlayerStructures(10, 10, 0, 20, 400, 1, function(x, y, z) got[#got + 1] = x .. "," .. y .. "," .. z end)
  SEEN[LAPS] = table.concat(got, ";") .. "|" .. tostring(w) .. "," .. tostring(e)
  return "built"
end
Events.OnTick.Add(function() LGEE.rebuild(100) end)
''')
# An LGEE stand-in whose walk stage calls a few LGEE functions (one of them 300 ms) and does
# 20 ms of its own local work.
LGEE4 = modfile('LGExtendedElectricity4/42.20/media/lua/server/LGExtendedElectricity/LGEEGrid.lua', r'''
LGEE = LGEE or {}
LGEE.perf = {}
local EE, marks = LGEE, {}
function EE.getOption(name) return false end
function EE.markStart(name) if EE.getOption("Debug") then marks[name] = getTimestampMs() end end
function EE.markEnd(name)
  if not EE.getOption("Debug") or not marks[name] then return end
  local row = EE.perf[name] or { calls = 0, total = 0, worst = 0 }
  EE.perf[name] = row
  row.calls, row.total = row.calls + 1, row.total + (getTimestampMs() - marks[name])
end
function EE.relayCount() return 5 end
local SQC = 0
function EE.squareId(x, y, z) SQC = SQC + 1; if SQC % 7 == 0 then advanceClock(1) end; return x .. "," .. y .. "," .. z end
function EE.planCover(entry) advanceClock(5); return entry end
function EE.discRegistrations(x, y, z) advanceClock(290); for i = 1, 70 do EE.squareId(i, 0, 0) end; return { 1, 2 } end
function EE.advanceRelayDiff(diff, purse) advanceClock(2); return true end
LAPS4 = 0
function LGEE.rebuild(budget)
  LAPS4 = LAPS4 + 1
  if LAPS4 > 2 then return "built" end
  EE.markStart("  .walk")
  for i = 1, 3 do EE.planCover(i) end
  advanceClock(20)                       -- the walk's own local code
  REGS = EE.discRegistrations(1, 2, 0)
  SQC = 0
  for i = 1, 1000 do EE.squareId(i, 1, 0) end
  EE.advanceRelayDiff({}, {})
  EE.markEnd("  .walk")
  return "built"
end
Events.OnTick.Add(function() LGEE.rebuild(100) end)
''')
# An LGEE stand-in whose machine circle is covered the slow way (340 ms) on every lap; the answer
# depends on which squares canHost refuses (generator squares, from a local registry).
LGEE5 = modfile('LGExtendedElectricity5/42.20/media/lua/server/LGExtendedElectricity/LGEEGrid.lua', r'''
LGEE = LGEE or {}
LGEE.perf = {}
local EE = LGEE
function EE.getOption(name) return false end
function EE.relayCount() return 0 end
EE.CHUNK = 8
function EE.relayKey(r) return r.x .. "," .. r.y .. "," .. r.z end
function EE.chunkKey(x, y) return math.floor(x / 8) .. ":" .. math.floor(y / 8) end
GENS = { ["0,0,0"] = true }
local function canHost(x, y, z) return GENS[x .. "," .. y .. "," .. z] == nil end
COVERS = 0
function EE.discRegistrations(cx, cy, z, r, engine, canHostFn, out)
  out = out or {}
  COVERS = COVERS + 1
  if r > engine then advanceClock(340) end
  for x = cx - r, cx + r, engine do
    for y = cy - r, cy + r, engine do
      if canHostFn(x, y, z) then out[#out + 1] = { x = x, y = y, z = z, kx = math.floor(x / 8), ky = math.floor(y / 8) } end
    end
  end
  for i = 1, #out do out[i].key = EE.relayKey(out[i]); out[i].chunkKey = EE.chunkKey(out[i].kx * 8, out[i].ky * 8) end
  return out
end
function LGEE.rebuild(budget)
  LAST = EE.discRegistrations(0, 0, 0, 20, 4, canHost)
  LAST_N = #LAST
  LAST[1].down = 99   -- LGEE marks its registrations after getting them
  return "built"
end
Events.OnTick.Add(function() LGEE.rebuild(100) end)
canHostForTest = canHost
''')
TIYL4 = modfile('ThisIsYourLife4/42/media/lua/client/ThisIsYourLife/TIYLSurvivorJournal.lua', r'''
TIYL_RUNS = {0, 0, 0, 0}
for i = 1, 4 do Events.OnTick.Add(function() TIYL_RUNS[i] = TIYL_RUNS[i] + 1 end) end
''')

MOCK = r'''
local function newEvent()
  local e = {list={}}
  e.Add = function(fn) table.insert(e.list, fn) end
  e.Remove = function(fn) for i=#e.list,1,-1 do if e.list[i]==fn then table.remove(e.list,i) end end end
  e.trigger = function(...) for _,f in ipairs(e.list) do f(...) end end
  return e
end
Events = setmetatable({}, {__index=function(t,k) local e=newEvent(); rawset(t,k,e); return e end})
for _,n in ipairs({"LoadGridsquare","OnGameStart","OnTick","EveryTenMinutes","OnObjectAdded","OnServerStarted"}) do local _=Events[n] end
getFilenameOfClosure = function(f) return (debug.getinfo(f,"S").source:gsub("^@","")) end
local clock = 0
getTimestampMs = function() return clock end
function advanceClock(ms) clock = clock + ms end
FILES = FILES or {}
function getFileWriter(name, create, append)
  local buf = {}
  return { write = function(_, s) buf[#buf + 1] = s end, close = function() FILES[name] = table.concat(buf) end }
end
function getFileReader(name, create)
  local text = FILES[name]
  if not text then return nil end
  local lines = {}
  for l in string.gmatch(text, "([^\n]*)\n") do lines[#lines + 1] = l end
  local i = 0
  return { readLine = function() i = i + 1; return lines[i] end, close = function() end }
end
LOG = {}
isServer = function() return false end
isClient = function() return false end
function jlist(t) return {size=function() return #t end, get=function(_,i) return t[i+1] end} end
-- world
SQ = {}
function sqAt(x,y,z) return SQ[x..","..y..","..z] end
SPR = {}
function sprite(name, props)
  local s = SPR[name]; if s then return s end
  s = {name=name, getName=function(self) return name end,
       getProperties=function(self) return {has=function(_,k) return props ~= nil and props[k] ~= nil end} end}
  SPR[name] = s; return s
end
function makeSquare(x,y,z)
  local sq = {x=x,y=y,z=z, objs={}, wos={}}
  sq.getX=function() return x end; sq.getY=function() return y end; sq.getZ=function() return z end
  sq.getObjects=function() return jlist(sq.objs) end
  sq.getWorldObjects=function() return jlist(sq.wos) end
  sq.getSpecialObjects=function() return jlist({}) end
  sq.getGenerator=function() return nil end
  sq.getVehicleContainer=function() return nil end
  sq.transmitRemoveItemFromSquare=function(_, wo) end
  SQ[x..","..y..","..z] = sq
  return sq
end
function addObj(sq, sprName, props)
  local o = {sq=sq}
  o.getSprite=function() return sprName and sprite(sprName, props) or nil end
  o.hasModData=function() return false end
  o.getContainerCount=function() return 0 end
  o.getSquare=function() return sq end
  table.insert(sq.objs, o); return o
end
function item(ft)
  local t = ft:match("%.(.*)$")
  return {getFullType=function() return ft end, getType=function() return t end}
end
function addCasing(sq, typ)
  local wo = {}
  wo.getItem=function() return {getType=function() return typ end} end
  wo.removeFromWorld=function() end
  wo.removeFromSquare=function() for i=#sq.wos,1,-1 do if sq.wos[i]==wo then table.remove(sq.wos,i) end end end
  table.insert(sq.wos, wo); return wo
end
WORLD_DAYS = 10
local cell = {getGridSquare=function(_,x,y,z) return sqAt(x,y,z) end}
getCell = function() return cell end
getWorld = function() return {getGameMode=function() return "Sandbox" end, getWorldAgeDays=function() return WORLD_DAYS end, getCell=function() return cell end} end
SandboxVars = {ammomakerOptions={DroppedCasingsLifetime=24}}
MD = {}
ModData = {get=function(k) return MD[k] end, getOrCreate=function(k) MD[k]=MD[k] or {}; return MD[k] end, add=function(k,t) MD[k]=t; MD_ADDS=(MD_ADDS or 0)+1 end}
PX, PY, PZ = 0.5, 0.5, 0
getSpecificPlayer = function() return {getX=function() return PX end, getY=function() return PY end, getZ=function() return PZ end} end
'''

failures = []
def check(name, cond):
    print(('PASS ' if cond else 'FAIL ') + name)
    if not cond: failures.append(name)

# Part 10 (the structure-walk memory) is off by default from 1.10; its tests run on a copy with it on.
FIX_RC = modfile('HitchFix_rc.lua', open(FIX).read().replace(
    'local ENABLE_LGEE_REGION_CACHE = false', 'local ENABLE_LGEE_REGION_CACHE = true', 1))

def run(with_sieve, tiyl=None, fix=None):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    if with_sieve: L.execute(f'dofile([[{SIEVE}]])')
    L.execute(f'dofile([[{fix or FIX}]])')
    for p in (NVF, AMMO, GUN, ER, OTHER, FARM, tiyl or TIYL, BBP):
        L.execute(f'dofile([[{p}]])')
    return L

for with_sieve in (True, False):
    print(f'--- with Chunk Load Sieve: {with_sieve}')
    L = run(with_sieve)
    g = L.globals()
    # world: a rack at (40,40,0), casings at (5,5,0)
    L.execute('''
      for x=-60,60,1 do for y=-60,60,4 do makeSquare(x,y,0) end end
      for x=-12,12 do for y=-12,12 do if not sqAt(x,y,0) then makeSquare(x,y,0) end end end
      for x=30,50 do for y=30,50 do if not sqAt(x,y,0) then makeSquare(x,y,0) end end end
      RACKSQ = sqAt(40,40,0); addObj(RACKSQ, "tuna_weaponrack_01_3")
      ERSQ = sqAt(-40,-40,0) or makeSquare(-40,-40,0); addObj(ERSQ, "tuna_equipmentrack_01_7", {TunaERPiece="armory"})
      for _, sq in pairs(SQ) do Events.LoadGridsquare.trigger(sq) end
    ''')
    # casings: 6 entries, old enough; picked-up one, unloaded one, young one
    L.execute('''
      local A = sqAt(5,5,0); addCasing(A, "Casing9mm"); addCasing(A, "Casing9mm"); addCasing(A, "Pebble")
      local B = sqAt(6,5,0); addCasing(B, "Pebble")       -- its casing was picked up
      WORLD_DAYS = 5
      ammoMakerItemCleanUpAddModData("ammomaker.Casing9mm", 5,5,0)
      ammoMakerItemCleanUpAddModData("ammomaker.Casing9mm", 5,5,0)
      ammoMakerItemCleanUpAddModData("ammomaker.Casing9mm", 6,5,0)
      ammoMakerItemCleanUpAddModData("ammomaker.Casing9mm", 999,999,0)   -- not loaded
      ammoMakerItemCleanUpAddModData("ammomaker.Casing9mm", 7,5,0)       -- loaded, empty square
      WORLD_DAYS = 9.99
      ammoMakerItemCleanUpAddModData("ammomaker.Casing9mm", 5,5,0)       -- young
      WORLD_DAYS = 10
      sqAt(7,5,0)
    ''')
    L.execute('Events.OnGameStart.trigger()')
    check('original AmmoMaker handler not attached', L.eval('ORIGINAL_AMMO_RAN') is None)
    L.execute('Events.EveryTenMinutes.trigger()')
    check('other mods\' EveryTenMinutes still attached', L.eval('OTHER_TEN') == 1)
    check('nothing done in the frame itself', L.eval('#sqAt(5,5,0).wos') == 3)
    L.execute('Events.OnTick.trigger()')
    check('two old casings at (5,5) removed, pebble kept', L.eval('#sqAt(5,5,0).wos') == 1 and L.eval('sqAt(5,5,0).wos[1].getItem().getType()') == 'Pebble')
    left = sorted(L.eval('(function() local r={} for k,v in pairs(MD.droppedCasings) do r[#r+1]=v end return table.concat(r,"|") end)()').split('|'))
    check('kept: the unloaded one and the young one only', left == sorted(['ammomaker.Casing9mm;999;999;0;5', 'ammomaker.Casing9mm;5;5;0;9.99']))
    check('pebble on (6,5) untouched', L.eval('#sqAt(6,5,0).wos') == 1)
    n_ten = L.eval('#Events.EveryTenMinutes.list')
    L.execute('Events.EveryTenMinutes.Remove(AMMO_FN)')
    check('AmmoMaker removing its clean-up removes the sliced one too (1.13)', L.eval('#Events.EveryTenMinutes.list') == n_ten - 1)
    L.execute('Events.EveryTenMinutes.Add(AMMO_FN)')
    check('re-added, one sliced clean-up again, not two, and the original still not attached', L.eval('#Events.EveryTenMinutes.list') == n_ten and L.eval('ORIGINAL_AMMO_RAN') is None)

    # farming
    L.execute('''
      FS = setmetatable({objs={}}, SFarmingSystem)
      for i=1,50 do FS.objs[i] = {id=i, x=i, y=0, z=0} end
      FS.objs[10].removeOnPlow = true
      LOG = {}
    ''')
    check('farming patched', L.eval('SFarmingSystem.__hitchFix') == True)
    L.execute('FS:checkPlant()')
    check('no plant checked in the frame itself', L.eval('#LOG') == 0)
    L.execute('Events.OnTick.trigger()')
    n1 = L.eval('#LOG')
    check('one tick checks a slice (20)', n1 == 20)
    for _ in range(10): L.execute('Events.OnTick.trigger()')
    check('every plant checked once, then plow-checked once', L.eval('(function() for _,o in ipairs(FS.objs) do if o.checks~=1 or o.plows~=1 then return false end end return true end)()'))
    check('plant removed during the plow pass is gone', L.eval('#FS.objs') == 49)
    # order: all checks before plows, plows last-first, like vanilla
    order = list(L.eval('table.concat(LOG, " ")').split())
    check('all checkPlant2 before plowFadeCheck', order.index('p50') > order.index('c50') and all(x.startswith('c') for x in order[:50]))
    check('plowFadeCheck runs last plant first', order[50] == 'p50')
    # back-to-back passes (sleeping): second call finishes the first
    L.execute('LOG = {}; for _,o in ipairs(FS.objs) do o.checks=0; o.plows=0 end; FS:checkPlant(); Events.OnTick.trigger(); FS:checkPlant()')
    check('a pass still running is finished before the next starts', L.eval('(function() for _,o in ipairs(FS.objs) do if o.checks~=1 or o.plows~=1 then return false end end return true end)()'))
    for _ in range(10): L.execute('Events.OnTick.trigger()')
    check('then the second pass completes', L.eval('(function() for _,o in ipairs(FS.objs) do if o.checks~=2 or o.plows~=2 then return false end end return true end)()'))

    # racks: player at origin, no rack within 9
    L.execute('GUN_TICKS=0; ER_TICKS=0; OTHER_TICKS=0; PX,PY=0.5,0.5')
    for _ in range(100): L.execute('Events.OnTick.trigger()')
    check('other OnTick handlers run every tick', L.eval('OTHER_TICKS') == 100)
    g_far = L.eval('GUN_TICKS')
    check('rack handlers held back far from racks (only the startup tail ran)', g_far <= 31 and L.eval('ER_TICKS') <= 31)
    if with_sieve:
        L.execute('GUN_TICKS=0; PX,PY=35.5,35.5')
        for _ in range(60): L.execute('Events.OnTick.trigger()')
        check('gun rack handler runs every tick near a rack found at chunk load', L.eval('GUN_TICKS') == 60)
        L.execute('GUN_TICKS=0; PX,PY=0.5,0.5')
        for _ in range(60): L.execute('Events.OnTick.trigger()')
        check('one sweep (31 ticks) after walking away, then stops', L.eval('GUN_TICKS') == 31)
        L.execute('ER_TICKS=0; PX,PY=-33.5,-33.5')
        for _ in range(10): L.execute('Events.OnTick.trigger()')
        check('equipment rack found by its TunaERPiece property', L.eval('ER_TICKS') == 10)
    # a rack placed near the player afterwards
    L.execute('PX,PY=20.5,20.5; GUN_TICKS=0; local o = addObj(sqAt(22,22,0) or makeSquare(22,22,0), "tuna_weaponrack_01_5"); Events.OnObjectAdded.trigger(o)')
    for _ in range(5): L.execute('Events.OnTick.trigger()')
    check('a newly placed rack is noticed at once', L.eval('GUN_TICKS') == 5)
    # rack placed with no event (rescan path)
    L.execute('PX,PY=-20.5,20.5; GUN_TICKS=0; addObj(sqAt(-22,22,0) or makeSquare(-22,22,0), "tuna_weaponrack_01_6")')
    for _ in range(700): L.execute('Events.OnTick.trigger()')
    check('a rack with no event is found by the rescan', L.eval('GUN_TICKS') > 31)
    # Tuna taking its handler off the event, then putting it back (1.13)
    L.execute('GUN_TICKS=0; Events.OnTick.Remove(GUN_FN)')
    for _ in range(5): L.execute('Events.OnTick.trigger()')
    check('a rack handler the mod removed is no longer called', L.eval('GUN_TICKS') == 0)
    L.execute('Events.OnTick.Add(GUN_FN)')
    for _ in range(5): L.execute('Events.OnTick.trigger()')
    check('re-added, it runs once per tick, not twice', L.eval('GUN_TICKS') == 5)
    check('and it is not on the event itself', L.eval('(function() for _,f in ipairs(Events.OnTick.list) do if f == GUN_FN then return true end end return false end)()') == False)

    # night vision: 20 worn items, no goggles, checked 100 times
    L.execute('''
      WORN = {}
      for i=1,20 do WORN[i] = item("Base.Shirt" .. i) end
      NVP = {getWornItems=function() return jlist(WORN) end}
      NV_ORIG_CALLS = 0
      for i=1,100 do NV_FOUND = NV.GetWornNVItem(NVP) end
    ''')
    check('night vision: no goggles found among ordinary clothes', L.eval('NV_FOUND') is None)
    check('night vision: each item type looked up once (20, not 2000)', L.eval('NV_ORIG_CALLS') == 20)
    L.execute('WORN[21] = item("Base.Hat_NVG_ON"); NV_FOUND = NV.GetWornNVItem(NVP)')
    check('night vision: goggles put on are found', L.eval('NV_FOUND and NV_FOUND.getType()') == 'Hat_NVG_ON')
    L.execute('WORN[21] = item("Mod.Monocle"); NV.Shared.RegisterNightVisionItem("Mod.Monocle"); NV_FOUND = NV.GetWornNVItem(NVP)')
    check('night vision: a type registered later is found (answers forgotten)', L.eval('NV_FOUND and NV_FOUND.getType()') == 'Monocle')
    check('night vision: nil item is not goggles', L.eval('NV.Shared.IsNVTaggedItem(nil)') == False)
    # a type registered through a copy saved before the wrap: found once the answers are forgotten (1.13)
    L.execute('WORN[21] = item("Mod.Scope"); NV_FOUND = NV.GetWornNVItem(NVP); NV_SAVED_REGISTER("Mod.Scope"); NV_FOUND = NV.GetWornNVItem(NVP)')
    check('night vision: a copy-registered type is not seen at once (remembered false)', L.eval('NV_FOUND') is None)
    L.execute('advanceClock(5000); Events.OnTick.trigger(); NV_FOUND = NV.GetWornNVItem(NVP)')
    check('night vision: still remembered 5 s later', L.eval('NV_FOUND') is None)
    L.execute('advanceClock(5001); Events.OnTick.trigger(); NV_ORIG_CALLS = 0; NV_FOUND = NV.GetWornNVItem(NVP)')
    check('night vision: found after the 10 s forget', L.eval('NV_FOUND and NV_FOUND.getType()') == 'Scope')
    L.execute('NV_ORIG_CALLS = 0; for i=1,100 do NV.GetWornNVItem(NVP) end')
    check('night vision: then remembered again (no lookups for 100 checks)', L.eval('NV_ORIG_CALLS') == 0)

    # This Is Your Life: 200 ticks 10 ms apart = 2 s
    L.execute('''
      for _, f in ipairs(Events.OnGameStart.list) do f() end
      advanceClock(5000); TIYL_RUNS = {0, 0, 0}; BBP_RUNS = 0
      for i=1,200 do Events.OnTick.trigger(); advanceClock(10) end
    ''')
    runs = list(L.eval('TIYL_RUNS').values())
    check('better building plus: scaffold tick runs 8 times in 2 s, not 200', L.eval('BBP_RUNS') == 8)
    check('journal: adoption check runs twice in 2 s, not 200', runs[1] == 2)
    check('journal: the other two handlers still run every tick', runs[0] == 200 and runs[2] == 200)

# A rack beside the player at load, without Chunk Load Sieve: the first rescan runs at once, so
# the handler keeps running past the 31-tick startup tail (1.12 waited for tick 600). (1.13)
L = run(False)
L.execute('''
  for x=-12,12 do for y=-12,12 do makeSquare(x,y,0) end end
  addObj(sqAt(2,2,0), "tuna_weaponrack_01_3")
  PX,PY=0.5,0.5
  for _, f in ipairs(Events.OnGameStart.list) do f() end
  GUN_TICKS = 0
  for i=1,100 do Events.OnTick.trigger() end
''')
check('racks: a rack beside the player at load is found by the first rescan (100 of 100 ticks)', L.eval('GUN_TICKS') == 100)

L = run(False, TIYL4)
L.execute('''
  for _, f in ipairs(Events.OnGameStart.list) do f() end
  TIYL_RUNS = {0, 0, 0, 0}
  for i=1,50 do Events.OnTick.trigger(); advanceClock(10) end
''')
check('journal: a file with four tick handlers is left alone', list(L.eval('TIYL_RUNS').values()) == [50, 50, 50, 50])

# LG Extended Electricity probe: times the handler and its sweep, changes nothing, then unwraps.
L = run(False)
L.execute(f'dofile([[{LGEE}]])')
L.execute('''
  PRINTED = {}
  print = function(s) PRINTED[#PRINTED + 1] = tostring(s) end
  ORIG_REBUILD = LGEE.rebuild
  ORIG_OPTION = LGEE.getOption
  for _, f in ipairs(Events.OnGameStart.list) do f() end
  for i=1,10 do Events.OnTick.trigger(); advanceClock(16) end
''')
out = list(L.eval('PRINTED').values())
probe = [s for s in out if 'LGEE probe:' in s]
check('lgee probe: four slow ticks printed', len(probe) == 4)
check('lgee probe: sweep and budget named', probe and 'sweep 340 ms (budget 400), rest 0 ms' in probe[0])
check('lgee probe: the slow rest of the handler is told apart', len(probe) > 1 and 'sweep 340 ms (budget 400), rest 50 ms' in probe[1])
check('lgee stages: time per stage, outside them, relays and pending',
      probe and 'stages: walk 30, setRelays 300, publish 0, fuel line 0, broadcast 0, outside them 10 ms; relays 0 -> 100; another sweep pending: yes' in probe[0])
check('lgee stages: the last slow tick says nothing is pending', len(probe) == 4 and 'pending: no' in probe[3])
check('lgee probe: handler still runs and sweep result passes through', L.eval('LGEE_SWEEPS') == 10 and L.eval('LGEE_RESULT') == 'built')
check('lgee probe: active line says 1.10 and lists LGEE and stage timing', any('active (1.13)' in s and 'LGEEGrid.lua' in s and 'LGEE stage timing' in s for s in out))
L.execute('for i=1,200 do Events.OnTick.trigger(); advanceClock(1000) end')
out = list(L.eval('PRINTED').values())
check('lgee probe: ends after its window and puts LGEE.rebuild back',
      any('LGEE probe done: 4 ticks' in s for s in out) and L.eval('LGEE.rebuild == ORIG_REBUILD'))
check('lgee stages: Debug answered as on only during the probe, then getOption put back',
      L.eval('LGEE.getOption == ORIG_OPTION') and L.eval('LGEE.getOption("Debug")') == False)

# LGEE structure walks: the same walk on later laps is answered from memory, forgotten when an
# object is added, and the original is put back after the minute.
L = run(False, fix=FIX_RC)
L.execute(f'dofile([[{LGEE3}]])')
L.execute('''
  PRINTED = {}
  print = function(s) PRINTED[#PRINTED + 1] = tostring(s) end
  ORIG_VPS = LGEE.visitPlayerStructures
  for _, f in ipairs(Events.OnGameStart.list) do f() end
  for i=1,4 do Events.OnTick.trigger(); advanceClock(16) end
''')
out = list(L.eval('PRINTED').values())
seen = list(L.eval('SEEN').values())
check('lgee walks: asked of the game once in four laps', L.eval('ASKED') == 1)
check('lgee walks: every lap got the same squares and counts', len(seen) == 4 and len(set(seen)) == 1 and seen[0] == '10,10,0;11,10,0;10,11,0|1,3')
probe = [s for s in out if 'LGEE probe:' in s]
check('lgee walks: only the first lap is slow, and its line says so', len(probe) == 1 and 'structure walks: 1 asked (300 ms), 0 from memory' in probe[0])
check('lgee walks: active line says 1.10 and lists it', any('active (1.13)' in s and 'LGEE structure walks' in s for s in out))
L.execute('Events.OnObjectAdded.trigger({}); Events.OnTick.trigger(); advanceClock(16)')
check('lgee walks: forgotten when an object is added', L.eval('ASKED') == 2)
L.execute('for i=1,70 do Events.OnTick.trigger(); advanceClock(1000) end')
out = list(L.eval('PRINTED').values())
check('lgee walks: put back after the minute, with a summary (answers kept at most 5 s, so asked again every 5 s)',
      L.eval('LGEE.visitPlayerStructures == ORIG_VPS')
      and any(re.search(r'LGEE structure walks done: ([89]|1\d|2[0-5]) asked of the game', s) for s in out))
asked = L.eval('ASKED')
L.execute('Events.OnTick.trigger()')
check('lgee walks: after the minute every walk goes to the game again', L.eval('ASKED') == asked + 1)

# LGEE walk steps: the slow tick's line names the costly LGEE functions, the walk's own time and
# the order of calls; nested calls aren't counted twice; everything is put back after the probe.
L = run(False)
L.execute(f'dofile([[{LGEE4}]])')
L.execute('''
  PRINTED = {}
  print = function(s) PRINTED[#PRINTED + 1] = tostring(s) end
  ORIG4 = { LGEE.squareId, LGEE.planCover, LGEE.discRegistrations, LGEE.advanceRelayDiff, LGEE.markStart, LGEE.markEnd }
  for _, f in ipairs(Events.OnGameStart.list) do f() end
  HD = LGEE.discRegistrations   -- part 11's wrapper, over part 12's; part 11 must take its own off
  OUTSIDE = LGEE.squareId(1, 1, 1)   -- outside the walk: just calls through
  for i=1,4 do Events.OnTick.trigger(); advanceClock(16) end
''')
out = list(L.eval('PRINTED').values())
probe = [s for s in out if 'LGEE probe:' in s]
print('   ', probe[0] if probe else out)
check('lgee walk steps: two slow ticks, each with a walk-steps part', len(probe) == 2 and all('; walk steps (' in s for s in probe))
line = probe[0] if probe else ''
check('lgee walk steps: the 300 ms function is named first, nested calls inside it not counted on their own',
      re.search(r'walk steps \(4[78]\d ms\): discRegistrations 300 ms \(1 calls\)', line) is not None)
check('lgee walk steps: planCover 15 ms over 3 calls', 'planCover 15 ms (3 calls)' in line)
m = re.search(r'squareId about (\d+) ms \(1000 calls\)', line)
check('lgee walk steps: squareId sampled after 200 calls and scaled up (true 142 ms)', m is not None and 110 <= int(m.group(1)) <= 175)
m = re.search(r'in no LGEE function (\d+) ms', line)
check("lgee walk steps: the walk's own local time is told apart (20 ms)", m is not None and 0 <= int(m.group(1)) <= 55)
check('lgee walk steps: first and last calls in order',
      re.search(r'first-last call ms: planCover 0-15, discRegistrations 35-335, squareId 335-4\d\d, advanceRelayDiff 4\d\d-4\d\d', line) is not None)
check('lgee walk steps: results pass through', L.eval('REGS[2]') == 2 and L.eval('OUTSIDE') == '1,1,1')
check('lgee walk steps: active line lists it', any('active (1.13)' in s and 'LGEE walk steps (' in s for s in out))
L.execute('for i=1,200 do Events.OnTick.trigger(); advanceClock(1000) end')
check('lgee walk steps: every function put back after the probe',
      L.eval('LGEE.squareId == ORIG4[1] and LGEE.planCover == ORIG4[2] and LGEE.discRegistrations ~= HD and LGEE.advanceRelayDiff == ORIG4[4] and LGEE.markStart == ORIG4[5] and LGEE.markEnd == ORIG4[6]'))

# LGEE circle covers: the same slow cover is re-used while every canHost answer in reach is the
# same, worked out again when one changes, and never handed out as a shared table.
L = run(False)
L.execute(f'dofile([[{LGEE5}]])')
L.execute('''
  PRINTED = {}
  print = function(s) PRINTED[#PRINTED + 1] = tostring(s) end
  for _, f in ipairs(Events.OnGameStart.list) do f() end
  COVERS = 0   -- the start-up fingerprint call is not a lap
  for i=1,4 do Events.OnTick.trigger(); advanceClock(16) end
''')
out = list(L.eval('PRINTED').values())
probe = [s for s in out if 'LGEE probe:' in s]
print('   ', probe[0] if probe else out)
check('lgee circles: covered once in four laps', L.eval('COVERS') == 1)
check('lgee circles: the line says why it was worked out', probe and 'worked out because circle at 0,0,0,20,4: not seen before' in probe[0])
check('lgee circles: only the first lap is slow, and its line says so', len(probe) == 1 and 'circle covers: 1 worked out (340 ms), 0 re-used' in probe[0])
check('lgee circles: active line says 1.11 and lists it', any('active (1.13)' in s and 'LGEE circle covers re-used' in s for s in out))
n0 = L.eval('LAST_N')
L.execute('Z = LGEE.discRegistrations(0, 0, 0, 20, 4, canHostForTest)')
check('lgee circles: re-used answer is a fresh copy (the mark LGEE set on the last one is not in it)',
      n0 > 0 and L.eval('COVERS') == 1 and L.eval('#Z') == n0 and L.eval('Z[1].down') is None and L.eval('Z ~= LAST'))
L.execute('GENS["500,500,0"] = true; Events.OnTick.trigger(); advanceClock(16)')
check('lgee circles: a generator far away changes nothing', L.eval('COVERS') == 1 and L.eval('LAST_N') == n0)
L.execute('GENS["4,4,0"] = true; Events.OnTick.trigger(); advanceClock(16)')
check('lgee circles: a generator inside the circle means it is covered again, with that square left out',
      L.eval('COVERS') == 2 and L.eval('LAST_N') == n0 - 1)
out = list(L.eval('PRINTED').values())
check('lgee circles: and the line names the square that changed', any('changed (4,4=false new)' in s for s in out))
L.execute('GENS["4,4,0"] = nil; Events.OnTick.trigger(); advanceClock(16)')
check('lgee circles: back to the first answers, the first cover is re-used (both kept)', L.eval('COVERS') == 2 and L.eval('LAST_N') == n0)
L.execute('GENS["4,4,0"] = true')
L.execute('Events.OnTick.trigger()')
check('lgee circles: and that new answer is re-used after', L.eval('COVERS') == 2)
L.execute('X = LGEE.discRegistrations(0, 0, 0, 4, 4, canHostForTest); Y = LGEE.discRegistrations(0, 0, 0, 20, 4, canHostForTest, {})')
check('lgee circles: radius at the engine radius, or an out list, always calls the original', L.eval('COVERS') == 4)
L.execute('for i=1,200 do Events.OnTick.trigger(); advanceClock(1000) end')
out = list(L.eval('PRINTED').values())
check('lgee circles: a summary after the probe window, with why', any(re.search(r'LGEE circle covers so far: 2 worked out \(680 ms; 1 not seen before, 1 with changed answers\), \d+ re-used', s) for s in out)
      and any('worked out because circle at 0,0,0,20,4: 1 changed' in s for s in out))
saved = L.eval('FILES["HitchFix_LGEE_circles.txt"]')
check('lgee circles: answers written to disk once things settle', saved is not None and saved.startswith('HitchFixCircles 1 ') and saved.count('\nC|') == 2)

# The next session finds both answers on disk and works nothing out.
L2 = run(False)
L2.execute(f'dofile([[{LGEE5}]])')
L2.globals().FILES = L2.table_from({'HitchFix_LGEE_circles.txt': saved})
L2.execute('''
  PRINTED = {}
  print = function(s) PRINTED[#PRINTED + 1] = tostring(s) end
  for _, f in ipairs(Events.OnGameStart.list) do f() end
  COVERS = 0
  for i=1,3 do Events.OnTick.trigger(); advanceClock(16) end
  GENS["4,4,0"] = true
  for i=1,3 do Events.OnTick.trigger(); advanceClock(16) end
''')
out = list(L2.eval('PRINTED').values())
check('lgee circles: next session, both answers come from the file, nothing worked out', L2.eval('COVERS') == 0)
check('lgee circles: next session, the active line counts them', any('active (1.13)' in s and 'LGEE circle covers re-used (2 from file)' in s for s in out))
check('lgee circles: answers from the file are the same registrations, keys rebuilt', L2.eval('LAST_N') == n0 - 1 and L2.eval('LAST[2].key') == L2.eval('LAST[2].x .. "," .. LAST[2].y .. "," .. LAST[2].z'))
saved2 = saved.replace('HitchFixCircles 1 ', 'HitchFixCircles 1 X', 1)
L3 = run(False)
L3.execute(f'dofile([[{LGEE5}]])')
L3.globals().FILES = L3.table_from({'HitchFix_LGEE_circles.txt': saved2})
L3.execute('''
  PRINTED = {}
  print = function(s) PRINTED[#PRINTED + 1] = tostring(s) end
  for _, f in ipairs(Events.OnGameStart.list) do f() end
  COVERS = 0
  Events.OnTick.trigger()
''')
check('lgee circles: a file from different cover code is not used', L3.eval('COVERS') == 1 and any('another LGEE version' in s for s in L3.eval('PRINTED').values()))

# Character screen probe: counts who draws ISCharacterScreen:render, changes nothing, then unwraps.
L = run(False)
L.execute('''
  PRINTED = {}
  print = function(s) PRINTED[#PRINTED + 1] = tostring(s) end
  CS_DRAWS = 0
  ISCharacterScreen = { Type = "ISCharacterScreen" }
  function ISCharacterScreen.render(self) CS_DRAWS = CS_DRAWS + 1 end
  ORIG_CS = ISCharacterScreen.render
  local function panel(t, vis) return { Type = t, isVisible = function() return vis end,
    isReallyVisible = function() return vis end, getAbsoluteX = function() return 0 end,
    getAbsoluteY = function() return 0 end, getWidth = function() return 400 end,
    getHeight = function() return 600 end, parent = { Type = "ISCharacterInfoWindow", isVisible = function() return vis end } } end
  HIDDEN = panel("ISCharacterScreen", false)
  OTHER = panel("SomeModPanel", true)
  for _, f in ipairs(Events.OnGameStart.list) do f() end
  for i=1,700 do
    Events.OnTick.trigger()
    ISCharacterScreen.render(HIDDEN)
    if i % 2 == 0 then ISCharacterScreen.render(OTHER) end
    advanceClock(16)
  end
''')
out = list(L.eval('PRINTED').values())
check('charscreen probe: counts draws in 10 s', any('character screen probe:' in s and 'draws in 10 s' in s for s in out))
check('charscreen probe: names the hidden panel', any('ISCharacterScreen visible=false reallyVisible=false' in s and 'parent ISCharacterInfoWindow (visible=false)' in s for s in out))
check('charscreen probe: names a second caller', any('SomeModPanel visible=true' in s for s in out))
check('charscreen probe: every draw still reaches the original', L.eval('CS_DRAWS') == 1050)
L.execute('for i=1,200 do Events.OnTick.trigger(); advanceClock(1000) end')
out = list(L.eval('PRINTED').values())
check('charscreen probe: ends and puts the original back', any('character screen probe done' in s for s in out) and L.eval('ISCharacterScreen.render == ORIG_CS'))

print()
print('ALL PASS' if not failures else f'{len(failures)} FAILED: {failures}')
