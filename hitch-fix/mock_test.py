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
local function itemCleanUp() ORIGINAL_AMMO_RAN = (ORIGINAL_AMMO_RAN or 0) + 1 end
Events.EveryTenMinutes.Add(itemCleanUp)
''')
GUN = modfile('Tuna_GunRacks/client/Tuna_WeaponRack.lua', r'''
local tick = 0
Events.OnTick.Add(function() tick = tick + 1; GUN_TICKS = (GUN_TICKS or 0) + 1 end)
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

def run(with_sieve):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    if with_sieve: L.execute(f'dofile([[{SIEVE}]])')
    L.execute(f'dofile([[{FIX}]])')
    for p in (AMMO, GUN, ER, OTHER, FARM):
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

print()
print('ALL PASS' if not failures else f'{len(failures)} FAILED: {failures}')
