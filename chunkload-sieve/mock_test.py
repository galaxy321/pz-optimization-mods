import lupa, random, sys, os
HERE=os.path.dirname(os.path.abspath(__file__))
SIEVE=HERE+'/ChunkLoadSieve/42/media/lua/shared/!!!_ChunkLoadSieve.lua'
PROF=HERE+'/../lua-event-profiler/LuaEventProfiler/42/media/lua/shared/!!!LuaEventProfiler.lua'
MOCK=r'''
local function newEvent()
  local e = {list={}}
  e.Add = function(fn) table.insert(e.list, fn) end
  e.Remove = function(fn) for i=#e.list,1,-1 do if e.list[i]==fn then table.remove(e.list,i) end end end
  e.trigger = function(...) for _,f in ipairs(e.list) do local ok,err=pcall(f,...) end end
  return e
end
Events = setmetatable({}, {__index=function(t,k) local e=newEvent(); rawset(t,k,e); return e end})
for _,n in ipairs({"LoadGridsquare","OnGameStart","OnGameBoot","OnTick"}) do local _=Events[n] end
getFilenameOfClosure = function(f) return (debug.getinfo(f,"S").source:gsub("^@","")) end
local clock=0
getTimestampMs = function() return clock end
advance = function(ms) clock = clock + ms end
getSpecificPlayer=function() return nil end
getAverageFPS=function() return 30 end
getFileWriter=function() return {writeln=function() end, close=function() end} end
LGEP = {GHOST_SPRITE="LGEP_ghost"}
TFC={Registered={}}
function GetTFCSystemData() return TFC end
for i=1,30 do TFC.Registered[(i*37).."-"..(i*11).."-0"]={} end
function isServer() return false end
DAMN={Spawns={byLocation={}}}
for i=1,20 do DAMN.Spawns.byLocation[(i*41).."_"..(i*7)]={} end
function list(t) return {size=function() return #t end, get=function(_,i) return t[i+1] end} end
SPR={}
function obj(o) return {
  getSprite=function() if o.name==nil then return nil end local sp=SPR[o.name]; if not sp then sp={getName=function() return o.name end}; SPR[o.name]=sp end return sp end,
  hasModData=function() return o.md==true end,
  getContainerCount=function() return o.cc or 0 end } end
function square(s)
  local objs={} for _,o in ipairs(s.objs) do objs[#objs+1]=obj(o) end
  return { spec=s,
    getGenerator=function() return s.gen and {} or nil end,
    getWorldObjects=function() return list(s.items or {}) end,
    getSpecialObjects=function() local t={} for _,v in ipairs(s.special or {}) do t[#t+1]=v end if s.gen then t[#t+1]=1 end return list(t) end,
    getX=function() return s.x end, getY=function() return s.y end, getZ=function() return 0 end,
    getVehicleContainer=function() return s.veh and {} or nil end,
    getRoom=function() return s.room and {} or nil end,
    getFloor=function() if not s.floor then return nil end return {
       getAttachedAnimSprite=function() return s.floor.att and list(s.floor.att) or nil end,
       hasModData=function() return s.floor.md==true end } end,
    getObjects=function() return list(objs) end }
end
'''
# "effect" predicates mirror when each original handler can do anything
MODS = {
 "mods/OnanGenSet/42/media/lua/server/OnanGenSet/OnanServer.lua": "s.gen or anyName(s,{onan_genset_01_0=1,onan_genset_01_3=1})",
 "mods/OnanGenSet/42/media/lua/client/OnanGenSet/OnanSound.lua": "s.gen",
 "mods/GasPumpIndicator/42/media/lua/client/GasPumpIndicator.lua": "anyName(s,{location_shop_gas2go_01_13=1,location_shop_fossoil_01_12=1})",
 "mods/LGExtendedPlumbing/42.20/media/lua/client/LGExtendedPlumbing/LGEPClient.lua": "anyObj(s,function(o) return o.name==nil or o.name=='LGEP_ghost' or o.md end)",
 "mods/LGExtendedElectricity/42.20/media/lua/server/LGExtendedElectricity/LGEEGrid.lua": "s.gen or anyObj(s,function(o) return o.md end)",
 "mods/PZTheMutants/42.21/media/lua/server/PZTheMutants/MutantTypes/Puker/PZM_Puker_Decals.lua": "anyObj(s,function(o) return o.md end)",
 "mods/Vanilla Foods Expanded/42.18/media/lua/server/vfx_agingmanager.lua": "(s.items and #s.items>0) or anyObj(s,function(o) return (o.cc or 0)>0 end)",
 "mods/Vanilla Foods Expanded/42.18/media/lua/server/vfx_storydistribution.lua": "anyObj(s,function(o) return (o.cc or 0)>0 end)",
 "mods/Vanilla Foods Expanded/42.18/media/lua/client/vfx_birthday_world.lua": "s.items and #s.items>0",
 "mods/QoLCompendium/42/media/lua/server/qolc_reasonable_alarms.lua": "(s.special and #s.special>0) or s.veh",
 "mods/Take A Bath And Shower New/42.20/media/lua/server/TubFluidContainer/TABAS_STubFluidContainerSystem.lua": "TFC.Registered[s.x..'-'..s.y..'-0']~=nil",
 "mods/damnlib/42.20/media/lua/server/DAMN_Spawns.lua": "DAMN.Spawns.byLocation[s.x..'_'..s.y]~=nil",
 "mods/FittedBarricades/42/media/lua/client/FittedBarricades/FB_Client.lua": "(s.special and #s.special>0) or s.gen",
 "mods/FittedBarricades/42/media/lua/server/FittedBarricades/FB_Build.lua": "isServer()",
 "mods/FittedSheets/42/media/lua/server/FittedSheets/FT_Server.lua": "(s.special and #s.special>0) or s.gen",
 "mods/RCStructureFramework/42/media/lua/shared/RCStructureFramework/RoofPieces.lua": "(s.special and #s.special>0) or s.gen",
 "mods/RCStructureFramework/42/media/lua/shared/RCStructureFramework/SpritePropertyPatcher.lua": "(s.special and #s.special>0) or s.gen",
 "mods/RCStructureFramework/42/media/lua/shared/RCStructureFramework/RoomLighting.lua": "s.room",
 "mods/RCStructureFramework/42/media/lua/shared/RCStructureFramework/TemplateStamp.lua": "anyObj(s,function(o) return o.md end)",
 "mods/SomeOther/42/media/lua/client/Other.lua": "true",
}
HELP=r'''
function anyName(s,set) for _,o in ipairs(s.objs) do if o.name and set[o.name] then return true end end return false end
function anyObj(s,f) for _,o in ipairs(s.objs) do if f(o) then return true end end return false end
'''
def run(order, seed):
    L=lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK); L.execute(HELP)
    for f in order:
        L.execute(L.eval('load')(open(f).read(), '@'+f) and "") if False else L.eval('function(c,n) local f=assert(load(c,"@"..n)); f() end')(open(f).read(), "C:/Users/x/Zomboid/mods/X/42/media/lua/shared/"+f.split('/')[-1])
    L.execute("results={}; called={}; should={}")
    for path,pred in MODS.items():
        code=f'''local name=...; Events.LoadGridsquare.Add(function(sq) local s=sq.spec; called[name]=(called[name] or 0)+1
           if {pred} then should[name]=(should[name] or 0)+1 end end)'''
        L.eval('function(c,n,p) local f=assert(load(c,"@"..p)); f(n) end')(code, path.split('/')[-1], "C:/Steam/108600/1/"+path)
    # an erroring captured handler must not stop others
    L.eval('function(c,p) assert(load(c,"@"..p))() end')('Events.LoadGridsquare.Add(function() error("boom") end)', "C:/x/mods/OnanGenSet/42/media/lua/client/OnanGenSet/OnanSound.lua")
    L.execute('for _,f in ipairs(Events.OnGameStart.list) do f() end; for i=1,30 do for _,f in ipairs(Events.OnTick.list) do f() end end')
    rnd=random.Random(seed)
    names=[None,"floors_01","onan_genset_01_0","location_shop_gas2go_01_13","LGEP_ghost","walls_01"]
    sqs=[]
    for i in range(20000):
        objs=[]
        for _ in range(rnd.choice([0,1,1,2,2,3,5])):
            objs.append({"name":rnd.choices(names,[1,60,1,1,1,40])[0],"md":rnd.random()<0.03,"cc":1 if rnd.random()<0.05 else 0})
        x=rnd.randint(1,1200); y=rnd.randint(1,400)
        if rnd.random()<0.01: k=rnd.randint(1,30); x,y=k*37,k*11
        elif rnd.random()<0.01: k=rnd.randint(1,20); x,y=k*41,k*7
        s={"x":x,"y":y,"objs":objs,"gen":rnd.random()<0.002,"items":[1] if rnd.random()<0.03 else [],"special":[1] if rnd.random()<0.05 else [],"veh":rnd.random()<0.005,"room":rnd.random()<0.3,
           "floor":({"att":[1] if rnd.random()<0.01 else [], "md":rnd.random()<0.01} if rnd.random()<0.9 else None)}
        sqs.append(s)
    pyconv=L.eval('function(t) return t end')
    L.execute("function mk(s) return square(s) end")
    tbl=lambda o: L.table_from({k:(tbl(v) if isinstance(v,(dict,list)) else v) for k,v in (o.items() if isinstance(o,dict) else enumerate(o,1))})
    trig=L.eval('function(sq) Events.LoadGridsquare.trigger(sq) end')
    mk=L.eval('mk')
    # first-index lists for ipairs
    def conv(s):
        d=dict(s); d["objs"]=L.table(*[L.table_from(o) for o in s["objs"]]); d["items"]=L.table(*s["items"]); d["special"]=L.table(*s["special"])
        if s["floor"]: d["floor"]=L.table_from({"att":L.table(*s["floor"]["att"]),"md":s["floor"]["md"]})
        return L.table_from(d)
    for s in sqs: trig(mk(conv(s)))
    called=dict(L.globals().called); should=dict(L.globals().should)
    nreg=len(L.eval('Events.LoadGridsquare.list'))
    ok=True
    for n in sorted(called.keys()|should.keys()):
        c=called.get(n,0); sh=should.get(n,0)
        # each handler predicate == gate, so a handler must be called exactly when it should act (superset check: called>=should)
        flag = "OK" if c>=sh else "MISSED"
        if c<sh: ok=False
        print(f"  {n:38s} called {c:6d} would act {sh:6d} {flag}")
    print("  event listeners:",nreg)
    # Remove test
    return ok
# --- LG Extended Electricity (1.4) -------------------------------------------------------------
LGEE_GRID = r'''
LGEE = LGEE or {}
local EE = LGEE
EE.KEY_FUEL = "LGEEFuel"; EE.CHUNK = 8
local generators, wires = {}, {}
FILED, EPOCH, SWEEPS, URGENT, DIRTY, REMOVED = {}, 0, 0, 0, 0, 0
OPTIONS = { Enabled = true }
function EE.getOption(k) return OPTIONS[k] end
function EE.isConnected(g) return g.connected == true end
function EE.isForeignGenerator(g) return g.foreign == true end
function EE.radius() return 20 end
function EE.cordRadius() return 2 end
function EE.eachKnownGenerator(visit) for k, p in pairs(generators) do visit(k, { x = p.x, y = p.y, z = p.z }) end end
function EE.wireStoreForTest() return wires end
function EE.chunkCoords(c) return math.floor(c.x / 8), math.floor(c.y / 8) end
function EE.requestSweep(reason, urgent) SWEEPS = SWEEPS + 1; if urgent then URGENT = URGENT + 1 end end
ADD_WIRE = function(x, y) wires[x .. "," .. y] = { x = x, y = y, z = 0 } end
ADD_GEN = function(x, y) generators[x .. "," .. y .. ",0"] = { x = x, y = y, z = 0 } end
Events.LoadGridsquare.Add(function(square)
  local x, y = square:getX(), square:getY()
  if square:getGenerator() then
    local k = x .. "," .. y .. ",0"
    if not generators[k] then generators[k] = { x = x, y = y, z = 0 }; EPOCH = EPOCH + 1 end
    FILED[k] = true
  end
end)
Events.LoadChunk.Add(function(chunk)
  DIRTY = DIRTY + 1
  if chunk.reason then EE.requestSweep("a returning generator", true) end
  if chunk.boom then error("boom") end
  EE.requestSweep()
end)
Events.OnObjectAboutToBeRemoved.Add(function(object)
  REMOVED = REMOVED + 1
  EE.requestSweep()
end)
'''
LGEE_MOCK = r'''
function gsq(x, y, gen, objs)
  local o = {}
  if gen then
    gen.isActivated = function() return gen.on == true end
    gen.hasModData = function() return gen.md ~= nil end
    gen.getModData = function() return gen.md end
    o[#o + 1] = gen
  end
  for _, b in ipairs(objs or {}) do
    o[#o + 1] = { hasModData = function() return b.md ~= nil end, getModData = function() return b.md end,
                  getSprite = function() return nil end, getContainerCount = function() return 0 end }
  end
  if gen then gen.getSprite = function() return nil end; gen.getContainerCount = function() return 0 end end
  return { getGenerator = function() return gen end, getX = function() return x end, getY = function() return y end,
    getZ = function() return 0 end, getObjects = function() return list(o) end,
    getSpecialObjects = function() return list(gen and { gen } or {}) end,
    getVehicleContainer = function() return nil end, getWorldObjects = function() return list({}) end }
end
function chunk(x, y, t) t = t or {}; t.x = x; t.y = y; return t end
function obj(x, y) return { getSquare = function() return { getX = function() return x end, getY = function() return y end } end } end
'''
def lgee(with_prof):
    L=lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK); L.execute(LGEE_MOCK)
    for _,n in []: pass
    L.execute('for _,n in ipairs({"LoadChunk","OnObjectAboutToBeRemoved"}) do local _=Events[n] end')
    load=L.eval('function(c,n) local f=assert(load(c,"@"..n)); f() end')
    if with_prof: load(open(PROF).read(), "C:/Users/x/Zomboid/mods/LuaEventProfiler/42/media/lua/shared/!!!LuaEventProfiler.lua")
    load(open(SIEVE).read(), "C:/Users/x/Zomboid/mods/ChunkLoadSieve/42/media/lua/shared/!!!_ChunkLoadSieve.lua")
    load(LGEE_GRID, "C:/Steam/108600/3779562002/mods/LGExtendedElectricity/42.20/media/lua/server/LGExtendedElectricity/LGEEGrid.lua")
    ok=True
    def check(name, cond):
        nonlocal ok
        print(("  PASS " if cond else "  FAIL ")+name)
        if not cond: ok=False
    G=L.globals()
    L.execute('ADD_GEN(1000, 1000); ADD_WIRE(5000, 5000)')
    L.execute('for _,f in ipairs(Events.OnGameStart.list) do f() end')
    sq=L.eval('function(...) Events.LoadGridsquare.trigger(gsq(...)) end')
    filed=lambda x,y: bool(L.eval(f'FILED["{x},{y},0"] == true'))
    # dormant generators
    L.execute('Events.LoadGridsquare.trigger(gsq(10,10,{}))')
    check("unplugged world generator not filed", not filed(10,10))
    e0=G.EPOCH
    L.execute('Events.LoadGridsquare.trigger(gsq(11,10,{connected=true}))')
    check("plugged-in generator filed", filed(11,10) and G.EPOCH==e0+1)
    L.execute('Events.LoadGridsquare.trigger(gsq(12,10,{on=true}))')
    check("running generator filed", filed(12,10))
    L.execute('Events.LoadGridsquare.trigger(gsq(13,10,{foreign=true}))')
    check("solar bank filed", filed(13,10))
    L.execute('Events.LoadGridsquare.trigger(gsq(14,10,{md={PSR=1}}))')
    check("generator with mod data filed", filed(14,10))
    L.execute('Events.LoadGridsquare.trigger(gsq(15,10,{md={}}))')
    check("generator with empty mod data not filed", not filed(15,10))
    L.execute('Events.LoadGridsquare.trigger(gsq(16,10,{},{{md={LGEEFuel=true}}}))')
    check("unplugged generator beside a fuel barrel: handler runs", filed(16,10))
    L.execute('Events.LoadGridsquare.trigger(gsq(17,10,{},{{md={other=1}}}))')
    check("unplugged generator beside other mod data: not filed", not filed(17,10))
    # far sweep requests
    L.execute('REAL = LGEE.requestSweep')
    putBack=lambda: bool(L.eval('LGEE.requestSweep == REAL'))
    trig=lambda ev,arg: L.execute(f'Events.{ev}.trigger({arg})')
    s0,d0=G.SWEEPS,G.DIRTY
    trig("LoadChunk","chunk(1100,1100)")
    check("chunk near a generator asks for a sweep", G.SWEEPS==s0+1 and G.DIRTY==d0+1)
    s0,d0=G.SWEEPS,G.DIRTY
    trig("LoadChunk","chunk(3000,3000)")
    check("far chunk: rest of handler runs, bare sweep dropped", G.SWEEPS==s0 and G.DIRTY==d0+1)
    check("requestSweep put back", putBack())
    s0,u0=G.SWEEPS,G.URGENT
    trig("LoadChunk","chunk(3000,3000,{reason=true})")
    check("far chunk: urgent request with a reason goes through", G.SWEEPS==s0+1 and G.URGENT==u0+1)
    s0=G.SWEEPS
    trig("LoadChunk","chunk(5100,5150)")
    check("chunk near a relay asks for a sweep", G.SWEEPS==s0+1)
    s0=G.SWEEPS
    trig("LoadChunk","chunk(1000+20+200-8,1000-20-200+8)")
    check("chunk just inside reach + margin asks", G.SWEEPS==s0+1)
    s0=G.SWEEPS
    trig("LoadChunk","chunk(1000+20+200+3*128+8,1000)")
    check("chunk past reach + margin + three cells is far", G.SWEEPS==s0)
    trig("LoadChunk","chunk(3000,3000,{boom=true})")
    check("error in handler: requestSweep still put back", putBack())
    s0,r0=G.SWEEPS,G.REMOVED
    trig("OnObjectAboutToBeRemoved","obj(3000,3000)")
    check("far removal: handler runs, sweep dropped", G.SWEEPS==s0 and G.REMOVED==r0+1)
    trig("OnObjectAboutToBeRemoved","obj(1005,1005)")
    check("near removal asks for a sweep", G.SWEEPS==s0+1)
    L.execute('ADD_GEN(3000, 3000); for i=1,700 do for _,f in ipairs(Events.OnTick.list) do f() end end')
    s0=G.SWEEPS
    trig("LoadChunk","chunk(3010,3010)")
    check("new generator picked up on refresh", G.SWEEPS==s0+1)
    L.execute('OPTIONS.Enabled=false; ChunkLoadSieve.refreshNear()')
    s0=G.SWEEPS
    trig("LoadChunk","chunk(9000,9000)")
    check("LGEE switched off: nothing dropped", G.SWEEPS==s0+1)
    L.execute('OPTIONS.Enabled=true; LGEE.wireStoreForTest=nil; ChunkLoadSieve.refreshNear()')
    s0=G.SWEEPS
    trig("LoadChunk","chunk(9000,9000)")
    check("wire store unreadable: stands down", G.SWEEPS==s0+1)
    if with_prof:
        w=L.eval('Events.LoadChunk.list[2]')  # [1] is the sieve's own timing stamp (1.8)
        inner=L.eval('LuaEventProfiler.originalOf')[w]
        src=L.eval('LuaEventProfiler.sourceOf')[inner]
        check("profiler reports LGEE's own file", src is not None and 'LGEEGrid.lua' in L.eval('getFilenameOfClosure')(src))
    return ok

print("sieve only"); a=run([SIEVE],1)
print("profiler then sieve"); b=run([PROF,SIEVE],2)
print("sieve then profiler"); c=run([SIEVE,PROF],3)
def prune():
    L=lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute('''
      LGEE = { MODDATA_KEY = "LGExtendedElectricity", isAuthority = function() return true end,
               getOption = function(k) return true end }
      local store = { registry = { generators = {
        a = { x=1, y=1, z=0, running=false, extended=false, tripped=false, bank=false },
        b = { x=2, y=1, z=0, running=true,  extended=false, tripped=false, bank=false },
        c = { x=3, y=1, z=0, running=false, extended=true,  tripped=false, bank=false },
        d = { x=4, y=1, z=0, running=false, extended=false, tripped=false, bank=true },
        e = { x=5, y=1, z=0, running=false, extended=false, tripped=false, bank=false, lineShare=0.5 },
        f = { x=6, y=1, z=0, running=false, extended=false, tripped=false, bank=false, seenHour=12 },
        g = { x=7, y=1, z=0, running=false, extended=false, tripped=true,  bank=false, tripGroup="k" },
      }, relays = { 1, 2, 3 } } }
      ModData = { getOrCreate = function(k) assert(k == "LGExtendedElectricity"); return store end }
      STORE = store
    ''')
    load=L.eval('function(c,n) local f=assert(load(c,"@"..n)); f() end')
    load(open(SIEVE).read(), "C:/Users/x/Zomboid/mods/ChunkLoadSieve/42/media/lua/shared/!!!_ChunkLoadSieve.lua")
    # LGEE registers its own reader after the sieve, the way server/ files load after shared/
    L.execute('Events.OnInitGlobalModData.Add(function() SEEN = {} for k in pairs(STORE.registry.generators) do SEEN[k] = true end end)')
    L.execute('Events.OnInitGlobalModData.trigger()')
    seen=set(L.eval('SEEN').keys())
    ok = seen=={"b","c","d","e","g"} and L.eval('#STORE.registry.relays')==3
    print(("  PASS" if ok else "  FAIL")+" saved list trimmed before LGEE reads it:", sorted(seen))
    return ok


# --- LG Extended Plumbing queue (1.6) ----------------------------------------------------------
LGEP_PLUMBING = r"""
if isClient() then return end
LGEP = LGEP or {}
local EP = LGEP
EP.PIPE_STORE = "LGEPPipes"
EP.floorPipes, EP.wallPipes = {}, {}
function EP.eachCollector(fn) end
NOTICED = {}
Events.LoadGridsquare.Add(function(square)
  local k = square:getX() .. "," .. square:getY() .. "," .. square:getZ()
  NOTICED[k] = (NOTICED[k] or 0) + 1
end)
function EP.forgetColumns() end
INCLUDED = {}
function EP.sourceAt(x, y, z) return { k = x .. "," .. y .. "," .. z } end
function EP.isIncluded(src) return INCLUDED[src.k] == true end
function EP.setIncluded(x, y, z, on) if not REFUSE then INCLUDED[x .. "," .. y .. "," .. z] = on or nil end end
"""
LGEP_MOCK = r"""
function isClient() return false end
MD = {}
ModData = { getOrCreate = function(k) MD[k] = MD[k] or {}; return MD[k] end }
LOADED = {}   -- chunk key "cx,cy" -> true
local function sqObj(x, y, z) return { getX=function() return x end, getY=function() return y end, getZ=function() return z end } end
function getCell() return { getGridSquare = function(_, x, y, z)
  if z < 0 or z > 2 then return nil end
  if LOADED[math.floor(x/8) .. "," .. math.floor(y/8)] then return sqObj(x, y, z) end
  return nil end } end
function chunkAt(x0, y0, hi)
  LOADED[math.floor(x0/8) .. "," .. math.floor(y0/8)] = true
  return { getMinLevel=function() return 0 end, getMaxLevel=function() return hi or 0 end,
    getGridSquare=function(_, lx, ly, z) return sqObj(x0 + lx, y0 + ly, z) end }
end
function noticedIn(x0, y0)
  local n = 0
  for dx=0,7 do for dy=0,7 do for z=0,2 do if NOTICED[(x0+dx)..","..(y0+dy)..","..z] then n = n + 1 end end end end
  return n
end
function ticks(n) for i=1,n do Events.OnTick.trigger() end end
"""
def lgep(with_prof):
    L=lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK); L.execute(LGEP_MOCK)
    L.execute('for _,n in ipairs({"LoadChunk","OnObjectAboutToBeRemoved","OnInitGlobalModData"}) do local _=Events[n] end')
    load=L.eval('function(c,n) local f=assert(load(c,"@"..n)); f() end')
    if with_prof: load(open(PROF).read(), "C:/Users/x/Zomboid/mods/LuaEventProfiler/42/media/lua/shared/!!!LuaEventProfiler.lua")
    load(open(SIEVE).read(), "C:/Users/x/Zomboid/mods/ChunkLoadSieve/42/media/lua/shared/!!!_ChunkLoadSieve.lua")
    load(LGEP_PLUMBING, "C:/Steam/108600/3779561845/mods/LGExtendedPlumbing/42.20/media/lua/server/LGExtendedPlumbing/LGEPPlumbing.lua")
    ok=True
    def check(name, cond):
        nonlocal ok
        print(("  PASS " if cond else "  FAIL ")+name)
        if not cond: ok=False
    G=L.globals()
    L.execute('MD.LGEPPipes = { mirrors = { ["100,100,0"] = true } }')
    L.execute('Events.OnInitGlobalModData.trigger(); for _,f in ipairs(Events.OnGameStart.list) do f() end')
    L.execute('Events.LoadGridsquare.trigger({getX=function() return 100 end,getY=function() return 100 end,getZ=function() return 0 end, getSpecialObjects=function() return list({}) end, getObjects=function() return list({}) end, getWorldObjects=function() return list({}) end, getVehicleContainer=function() return nil end})')
    check("handler not run during the square load", L.eval('next(NOTICED)') is None)
    L.execute('Events.LoadChunk.trigger(chunkAt(96, 96, 2))')
    check("nothing read during the chunk load", L.eval('next(NOTICED)') is None)
    L.execute('ticks(1)')
    check("hot chunk: first tick reads at most 8 levels", L.eval('noticedIn(96,96)') <= 8*64)
    L.execute('ticks(5)')
    check("chunk next to a mirror read in full (3 levels)", L.eval('noticedIn(96,96)') == 3*64)
    L.execute('Events.LoadChunk.trigger(chunkAt(2000, 2000)); ticks(5)')
    check("chunk away from plumbing skipped", L.eval('noticedIn(2000,2000)') == 0)
    L.execute('REFUSE = true; LGEP.setIncluded(2001, 2001, 0, true); REFUSE = nil; ticks(5)')
    check("refused plumb not listed", L.eval('next(MD.LGEPChunkLoadPatch.plumbed)') is None and L.eval('noticedIn(2000,2000)') == 0)
    L.execute('LGEP.setIncluded(2001, 2001, 0, true); ticks(5)')
    check("plumbing a barrel saves it", L.eval('MD.LGEPChunkLoadPatch.plumbed["2001,2001,0"]') == True)
    check("its still-loaded chunk is then read in full", L.eval('noticedIn(2000,2000)') == 64)
    L.execute('Events.LoadChunk.trigger(chunkAt(2016, 2000)); ticks(5)')
    check("chunk two over from the barrel (within Reach) read", L.eval('noticedIn(2016,2000)') == 64)
    L.execute('LGEP.setIncluded(2001, 2001, 0, false); ticks(1)')
    check("unplumbing removes it", L.eval('MD.LGEPChunkLoadPatch.plumbed["2001,2001,0"]') is None)
    L.execute('LGEP.floorPipes[1] = { x = 5000, y = 5000 }; advance(6000); ticks(1); Events.LoadChunk.trigger(chunkAt(5000, 5000)); ticks(3)')
    check("chunk with a pipe read", L.eval('noticedIn(5000,5000)') == 64)
    L.execute('for i=0,39 do Events.LoadChunk.trigger(chunkAt(96 + 8*(i%5), 96 + 8*math.floor(i/5))) end')
    L.execute('BEFORE = 0; for k,v in pairs(NOTICED) do BEFORE = BEFORE + v end; ticks(1); AFTER = 0; for k,v in pairs(NOTICED) do AFTER = AFTER + v end')
    check("one tick reads at most 8 chunk levels", G.AFTER - G.BEFORE <= 8*64)
    L.execute('Events.OnInitGlobalModData.trigger()')
    check("plumbing wrapped once after a second init", L.eval('LGEP.setIncludedWrappedByCLP') == True)
    return ok

# the retired LGEP Chunk Load Patch 1.2 capture file, as users may still have it enabled
OLD_LGEP_CAPTURE = r"""
--
-- LG Extended Plumbing - Chunk Load Patch: the capture half.
--
-- WHY THIS LIVES IN shared/.  LGEPPlumbing.lua registers its per-square handler with an
-- anonymous function, so there is nothing to pass to Events.LoadGridsquare.Remove later.
-- The only way to stop it running per square, without editing that file, is to be standing
-- at the door when it calls Add.  shared/ is loaded before server/ in every mode, whatever
-- the mod order, so a wrapper installed here is always in place first.
--
-- HOW WE RECOGNISE THE RIGHT HANDLER.  A Lua file runs top to bottom without interruption.
-- LGEPPlumbing.lua defines LGEP.eachCollector (line ~385), then adds its LoadGridsquare
-- handler (line ~655), then defines LGEP.forgetColumns (line ~1165).  So the one
-- LoadGridsquare.Add that happens while eachCollector exists and forgetColumns does not is
-- that file's.  If an update to the original moves those around, nothing is captured, the
-- handler is registered normally, and the server half logs that it is standing down.
--

LGEP_CLP = LGEP_CLP or {}

local CLP = LGEP_CLP

if CLP.wrapped then return end

local function looksLikePlumbingHandler()
	local EP = LGEP
	return CLP.captured == nil
		and EP ~= nil
		and EP.eachCollector ~= nil
		and EP.forgetColumns == nil
end

local ok, err = pcall(function()
	local event = Events and Events.LoadGridsquare
	if not event or not event.Add then return end

	local originalAdd = event.Add
	event.Add = function(fn)
		if looksLikePlumbingHandler() then
			-- Held, not registered.  The server half calls it from a tick budget instead.
			CLP.captured = fn
			return
		end
		return originalAdd(fn)
	end

	-- If the server half stands down it hands the handler back through this.
	CLP.registerNormally = function(fn) return originalAdd(fn) end
	CLP.wrapped = true
end)

if not ok then
	print("[LGEPChunkLoadPatch] could not wrap Events.LoadGridsquare.Add: " .. tostring(err))
end
"""
def lgep_old_mod_on():
    L=lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK); L.execute(LGEP_MOCK)
    L.execute('for _,n in ipairs({"LoadChunk","OnObjectAboutToBeRemoved","OnInitGlobalModData"}) do local _=Events[n] end')
    load=L.eval('function(c,n) local f=assert(load(c,"@"..n)); f() end')
    load(open(SIEVE).read(), "C:/Users/x/Zomboid/mods/ChunkLoadSieve/42/media/lua/shared/!!!_ChunkLoadSieve.lua")
    load(OLD_LGEP_CAPTURE, "C:/x/mods/LGEPChunkLoadPatch/42/media/lua/shared/LGEPChunkLoadPatch/LGEPChunkLoadPatch_Capture.lua")
    load(LGEP_PLUMBING, "C:/Steam/108600/3779561845/mods/LGExtendedPlumbing/42.20/media/lua/server/LGExtendedPlumbing/LGEPPlumbing.lua")
    L.execute('for _,f in ipairs(Events.OnGameStart.list) do f() end')
    # Only the sieve's two LoadChunk timing stamps (1.8); a queue would make it three.
    ok = L.eval('LGEP_CLP.captured ~= nil and #Events.LoadChunk.list == 2')
    print(("  PASS" if ok else "  FAIL")+" old mod still on: it keeps the handler, the sieve does not queue it too")
    return ok

# --- 1.7: modes, census, timing, rule() ---------------------------------------------------------
def modes(mode):
    import re
    L=lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK); L.execute(HELP)
    L.execute('for _,n in ipairs({"LoadChunk","ReuseGridsquare","OnObjectAboutToBeRemoved","OnInitGlobalModData"}) do local _=Events[n] end')
    L.execute('LINES={}; print=function(s) LINES[#LINES+1]=tostring(s) end')
    if mode:
        L.globals().MODEFILE = mode + "\n"
        L.execute('getFileReader=function(n,c) assert(n=="ChunkLoadSieve_mode.txt" and c==false); local done=false; return {readLine=function() if done then return nil end done=true; return MODEFILE end, close=function() end} end')
    load=L.eval('function(c,n) local f=assert(load(c,"@"..n)); f() end')
    load(open(SIEVE).read(), "C:/Users/x/Zomboid/mods/ChunkLoadSieve/42/media/lua/shared/!!!_ChunkLoadSieve.lua")
    L.execute("called={}; should={}")
    for path,pred in MODS.items():
        code=("local name=...; Events.LoadGridsquare.Add(function(sq) local s=sq.spec; called[name]=(called[name] or 0)+1 "
              "if %s then should[name]=(should[name] or 0)+1 end end)" % pred)
        L.eval('function(c,n,p) local f=assert(load(c,"@"..p)); f(n) end')(code, path.split('/')[-1], "C:/Steam/108600/1/"+path)
    # a slow handler (1 ms a square) and a handler that a later rule() should catch
    load('Events.LoadGridsquare.Add(function() advance(1); called.Slow=(called.Slow or 0)+1 end)', "C:/x/mods/Slow/42/media/lua/client/Slow.lua")
    load('Events.LoadGridsquare.Add(function(sq) called.Late=(called.Late or 0)+1 end)', "C:/x/mods/Late/42/media/lua/client/Late/LateMod.lua")
    load('Events.LoadChunk.Add(function() end)', "C:/x/mods/Chunky/42/media/lua/server/Chunky.lua")
    L.execute('for _,f in ipairs(Events.OnGameStart.list) do f() end')
    results=[]
    def check(name, cond):
        results.append(bool(cond)); print(("  PASS " if cond else "  FAIL ")+name)
    m = mode or "full"
    check("mode is "+m, L.eval('ChunkLoadSieve.mode') == m)
    lines=lambda: list(L.eval('LINES').values())
    check("census lists the LoadChunk handler", any("census LoadChunk passed C:/x/mods/Chunky" in l for l in lines()))
    check("census summary printed", any(l.startswith("[ChunkLoadSieve] census: LoadGridsquare") for l in lines()))
    nl=len(L.eval('Events.LoadGridsquare.list'))
    if m=="machinery": check("3 listeners: first, all, last", nl==3)
    if m=="measure": check("every handler stays on the event, plus first and last", nl==len(MODS)+2+2)
    if m=="full": check("first, sieve, Other, Slow, Late, last", nl==6)
    check("watch() only in full mode", (L.eval('ChunkLoadSieve.watch') is not None) == (m=="full"))
    if m=="full":
        ok=L.eval('ChunkLoadSieve.rule("Late/LateMod.lua", {"room"})')
        check("rule() catches a handler already on the event", ok and len(L.eval('Events.LoadGridsquare.list'))==5)
        check("rule() refuses an unknown fact", not L.eval('ChunkLoadSieve.rule("X.lua", {"nope"})'))
    # a handler added after the game started must still be inside the timed span
    load('Events.LoadGridsquare.Add(function() advance(2) end)', "C:/x/mods/After/42/media/lua/client/After.lua")
    check("late addition printed", any("census (late) LoadGridsquare" in l for l in lines()))
    if mode and m!="full": check("mode file warning printed", any("NOT filtering" in l for l in lines()))
    rnd=random.Random(7)
    trig=L.eval('function(sq) Events.LoadGridsquare.trigger(sq) end'); mk=L.eval('square')
    N=3000; rooms=0
    for i in range(N):
        room = rnd.random()<0.3; rooms+=room
        trig(mk(L.table_from({"x":rnd.randint(1,900),"y":5,"objs":L.table(),"items":L.table(),"special":L.table(),"room":room})))
    called=dict(L.eval('called'))
    if m=="full":
        check("Late now runs only on squares with a room", called.get("Late")==rooms)
    else:
        check("every handler ran on every square", all(called.get(path.split('/')[-1])==N for path in MODS) and called.get("Late")==N)
    check("slow handler ran on every square", called.get("Slow")==N)
    load('Events.LoadChunk.Add(function() advance(5) end)', "C:/x/mods/SlowChunk/42/media/lua/server/SlowChunk.lua")
    L.execute('for i=1,100 do Events.LoadChunk.trigger({}) end')
    L.execute('advance(120000); for _,f in ipairs(Events.OnTick.list) do f() end')
    tc=[l for l in lines() if l.startswith("[ChunkLoadSieve] timing LoadChunk ")]
    check("LoadChunk timed, late handler included (%s)" % (tc[0][:90] if tc else None), len(tc)==1 and ": 500 ms over 100 chunks" in tc[0])
    t=[l for l in lines() if l.startswith("[ChunkLoadSieve] timing mode=")]
    check("timing line printed", len(t)==1)
    mt=re.search(r"LoadGridsquare Lua (\d+) ms over (\d+) squares", t[0]) if t else None
    check("timed every square, slow handlers included (%s)" % (mt.group(0) if mt else None),
          mt and int(mt.group(2))==N and int(mt.group(1))==3*N)
    if t: print("   ", t[0])
    return all(results)

# --- 1.8: OnObjectAboutToBeRemoved gate for trees and bushes ---------------------------------------
REMOVAL_MOCK = r'''
IsoFlagType = { vegitation = "vegitation", solid = "solid", solidtrans = "solidtrans" }
function props(t) return { has = function(_, k) return t[k] == true end } end
SPRS = {}
function sprite(name, flags) local s = SPRS[name]; if not s then s = { getName = function() return name end, getProperties = function() return props(flags) end }; SPRS[name] = s end return s end
function instanceof(o, c) return o.cls == c or (c == "IsoObject") end
function robj(spec) return { cls = spec.cls, spec = spec,
   getSprite = function() return spec.name and sprite(spec.name, spec.flags) or nil end,
   getProperties = function() return props(spec.flags) end } end
'''
REMOVAL_MODS = {
  "LGExtendedPlumbing/42.20/media/lua/server/LGExtendedPlumbing/LGEPPlumbing.lua": "not s.veg",
  "LGExtendedPlumbing/42.20/media/lua/client/LGExtendedPlumbing/LGEPClient.lua": "NET and not s.veg",
  "LGExtendedElectricity/42.20/media/lua/server/LGExtendedElectricity/LGEEGrid.lua": "not s.veg",
  "LGExtendedElectricity/42.20/media/lua/shared/LGExtendedElectricity/LGEEAgree.lua": "NET and s.cls=='IsoGenerator'",
  "TakeABathAndShowerNew/42.20/media/lua/server/TubFluidContainer/TABAS_STubFluidContainerSystem.lua": "s.bath",
  "TakeABathAndShowerNew/42.20/media/lua/client/Bathing/TABAS_ShowerFx.lua": "s.bath or s.shower",
  "TakeABathAndShowerNew/42.20/media/lua/server/BuildingObjects/TABAS_TubEdge.lua": "s.bath or s.flags.solid or s.flags.solidtrans or s.flags.WallN or s.flags.WallW",
  "Other/42/media/lua/server/OtherRemoval.lua": "true",
}
def removal(net, with_prof):
    L=lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK); L.execute(REMOVAL_MOCK)
    L.execute('for _,n in ipairs({"LoadChunk","OnObjectAboutToBeRemoved","OnInitGlobalModData"}) do local _=Events[n] end')
    L.execute('LINES={}; print=function(s) LINES[#LINES+1]=tostring(s) end')
    L.globals().NET = net
    L.execute('isClient=function() return NET end; isServer=function() return false end')
    load=L.eval('function(c,n) local f=assert(load(c,"@"..n)); f() end')
    if with_prof: load(open(PROF).read(), "C:/x/mods/LuaEventProfiler/42/media/lua/shared/!!!LuaEventProfiler.lua")
    load(open(SIEVE).read(), "C:/Users/x/Zomboid/mods/ChunkLoadSieve/42/media/lua/shared/!!!_ChunkLoadSieve.lua")
    L.execute("called={}; should={}")
    for path,pred in REMOVAL_MODS.items():
        code=("local name=...; Events.OnObjectAboutToBeRemoved.Add(function(o) local s=o.spec; called[name]=(called[name] or 0)+1 "
              "if %s then should[name]=(should[name] or 0)+1 end end)" % pred)
        L.eval('function(c,n,p) local f=assert(load(c,"@"..p)); f(n) end')(code, path.split('/')[-1], "C:/Steam/108600/1/mods/"+path)
    L.execute('for _,f in ipairs(Events.OnGameStart.list) do f() end')
    rnd=random.Random(3)
    kinds=[("IsoTree","jumbo_tree_01",{"solidtrans":True},{}),
           ("IsoObject","vegetation_foliage_01_3",{"vegitation":True},{"veg":True}),
           ("IsoObject","e_newgrass_1_12",{"vegitation":True},{"veg":True}),
           ("IsoObject","vegetation_hedge_01",{"vegitation":True,"solid":True},{"veg":True}),
           ("IsoThumpable","carpentry_02_54",{},{}),
           ("IsoGenerator","appliances_misc_01_0",{},{}),
           ("IsoObject","fixtures_bathroom_01_24",{"solid":True},{"bath":True}),
           ("IsoObject","fixtures_bathroom_01_32",{},{"shower":True}),
           ("IsoObject","walls_exterior_house_01_0",{"WallN":True},{}),
           ("IsoObject",None,{},{})]
    trig=L.eval('function(o) Events.OnObjectAboutToBeRemoved.trigger(o) end'); mk=L.eval('robj')
    for i in range(5000):
        cls,name,flags,extra=rnd.choices(kinds,[30,30,20,3,3,2,2,2,3,1])[0]
        spec={"cls":cls,"flags":L.table_from(flags),"veg":cls=="IsoTree" or flags.get("vegitation",False)}
        if name: spec["name"]=name
        spec.update(extra)
        trig(mk(L.table_from(spec)))
    called=dict(L.eval('called')); should=dict(L.eval('should'))
    ok=True
    for n in sorted(called.keys()|should.keys()):
        c=called.get(n,0); sh=should.get(n,0)
        if c<sh: ok=False
        print(f"  {n:38s} called {c:5d} would act {sh:5d} {'OK' if c>=sh else 'MISSED'}")
    skipped = sum(1 for l in L.eval('LINES').values() if "removals: caught" in l)
    print(("  PASS" if skipped==7 else "  FAIL")+f" 7 removal handlers caught ({skipped})")
    tree_pass = called.get("LGEEGrid.lua",0) < 5000*0.5
    print(("  PASS" if tree_pass else "  FAIL")+" most vegetation removals skipped for LGEEGrid")
    return ok and skipped==7 and tree_pass
print("LGEE, sieve only"); d=lgee(False)
print("LGEE, profiler then sieve"); e=lgee(True)
print("LGEE saved list"); f=prune()
print("LGEP queue, sieve only"); g=lgep(False)
print("LGEP queue, profiler then sieve"); h=lgep(True)
print("LGEP, old mod still on"); i=lgep_old_mod_on()
print("1.7 full"); j=modes(None)
print("1.7 machinery"); k=modes("machinery")
print("1.7 measure"); l=modes("measure")
print("1.8 removals, singleplayer"); m=removal(False, False)
print("1.8 removals, MP client, profiler"); n=removal(True, True)
# --- 1.8 review fixes ------------------------------------------------------------------------------
def review18(dedicated):
    L=lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK); L.execute(HELP)
    L.execute('for _,n in ipairs({"LoadChunk","ReuseGridsquare","OnObjectAboutToBeRemoved","OnServerStarted"}) do local _=Events[n] end')
    L.execute('LINES={}; print=function(s) LINES[#LINES+1]=tostring(s) end')
    load=L.eval('function(c,n) local f=assert(load(c,"@"..n)); f() end')
    load(open(SIEVE).read(), "C:/Users/x/Zomboid/mods/ChunkLoadSieve/42/media/lua/shared/!!!_ChunkLoadSieve.lua")
    L.execute("called={}")
    for name in ["mods/Take A Bath And Shower New/42.20/media/lua/server/TubFluidContainer/TABAS_STubFluidContainerSystem.lua",
                 "mods/damnlib/42.20/media/lua/server/DAMN_Spawns.lua",
                 "mods/Fake/42/media/lua/client/XGasPumpIndicator.lua"]:
        load('local n=...; Events.LoadGridsquare.Add(function() called["%s"]=(called["%s"] or 0)+1 end)' % (name.split('/')[-1], name.split('/')[-1]), "C:/Steam/108600/1/"+name)
    L.execute('WATCHED=0; ChunkLoadSieve.watch(function(spr, name) return name=="crate_01" end, function() WATCHED=WATCHED+1 end)')
    results=[]
    def check(name, cond):
        results.append(bool(cond)); print(("  PASS " if cond else "  FAIL ")+name)
    lines=lambda: list(L.eval('LINES').values())
    trig=L.eval('function(sq) Events.LoadGridsquare.trigger(sq) end'); mk=L.eval('square')
    def sq(x, objs=None):
        return mk(L.table_from({"x":x,"y":5,"objs":objs or L.table(),"items":L.table(),"special":L.table()}))
    # Squares loaded before the start (no tub or spawn point at x=3): the tub and spawn handlers must run anyway.
    for i in range(10): trig(sq(3))
    called=dict(L.eval('called'))
    check("before the start, TABAS ran on every square", called.get("TABAS_STubFluidContainerSystem.lua")==10)
    check("before the start, damnlib ran on every square", called.get("DAMN_Spawns.lua")==10)
    check("XGasPumpIndicator.lua is not caught by the GasPumpIndicator.lua rule", called.get("XGasPumpIndicator.lua")==10
          and not any("captured" in l and "GasPump" in l for l in lines()))
    if dedicated:
        L.execute('for _,f in ipairs(Events.OnServerStarted.list) do f() end')
    L.execute('for _,f in ipairs(Events.OnGameStart.list) do f() end' if not dedicated else 'local _=0')
    L.execute('for _,f in ipairs(Events.OnServerStarted.list) do f() end; for _,f in ipairs(Events.OnGameStart.list) do f() end' if not dedicated else 'local _=0')
    act=[l for l in lines() if l.startswith("[ChunkLoadSieve] active")]
    check("set up once (%d active lines)" % len(act), len(act)==1)
    for i in range(5): trig(sq(3))
    called=dict(L.eval('called'))
    check("after the start but before the first refresh, still every square", called.get("TABAS_STubFluidContainerSystem.lua")==15
          and called.get("DAMN_Spawns.lua")==15)
    L.execute('for i=1,30 do for _,f in ipairs(Events.OnTick.list) do f() end end')
    for i in range(10): trig(sq(3))
    called=dict(L.eval('called'))
    check("after the first refresh, TABAS gated again", called.get("TABAS_STubFluidContainerSystem.lua")==15)
    check("after the first refresh, damnlib gated again", called.get("DAMN_Spawns.lua")==15)
    # A caught handler removed and added again during play is announced once.
    load('RCF=function() end; Events.LoadGridsquare.Add(RCF)', "C:/x/mods/RCStructureFramework/42/media/lua/shared/RCStructureFramework/RoomLighting.lua")
    L.execute('for i=1,3 do Events.LoadGridsquare.Remove(RCF); Events.LoadGridsquare.Add(RCF) end')
    n=sum(1 for l in lines() if l.startswith("[ChunkLoadSieve] captured") and "RoomLighting" in l)
    check("re-added handler announced once (%d)" % n, n==1)
    # A handler toggled on and off during play is printed once.
    load('local f=function() end; for i=1,3 do Events.LoadGridsquare.Add(f); Events.LoadGridsquare.Remove(f) end; Events.LoadChunk.Add(f); Events.LoadChunk.Remove(f); Events.LoadChunk.Add(f)',
         "C:/x/mods/Toggle/42/media/lua/server/Toggle.lua")
    late=[l for l in lines() if "census (late)" in l]
    check("toggled handlers printed once per event (%d)" % len(late), len(late)==3)
    # Watch: a square in one stats window, the next window's first square must still be seen.
    crate=L.table(L.table_from({"name":"crate_01"}))
    trig(sq(9, crate))
    L.execute('advance(120000); for _,f in ipairs(Events.OnTick.list) do f() end; advance(120000); for _,f in ipairs(Events.OnTick.list) do f() end')
    trig(sq(9, crate))
    check("watch sees the first square of a new stats window (%d)" % L.eval('WATCHED'), L.eval('WATCHED')==2)
    check("timing line printed", any(l.startswith("[ChunkLoadSieve] timing mode=full") for l in lines()))
    return all(results)
print("1.8 review fixes, client"); o=review18(False)
print("1.8 review fixes, dedicated server"); p=review18(True)
# --- 1.8: shared-folder targets missed because of mod order ---------------------------------------
def missed(server=False):
    L=lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK); L.execute(HELP)
    L.execute('for _,n in ipairs({"LoadChunk","ReuseGridsquare","OnObjectAboutToBeRemoved"}) do local _=Events[n] end')
    L.execute('LINES={}; print=function(s) LINES[#LINES+1]=tostring(s) end')
    L.execute('getActivatedMods=function() return list({"\\\\LGExtendedElectricity","RCStructureFramework","ChunkLoadSieve"%s}) end' % (',"VanillaFoodsExpanded"' if server else ''))
    if server: L.execute('isServer=function() return true end; isClient=function() return false end')
    load=L.eval('function(c,n) local f=assert(load(c,"@"..n)); f() end')
    # LGEEAgree loaded before the sieve (mod above it in the list): its handlers are never seen
    load('Events.LoadGridsquare.Add(function() end); Events.OnObjectAboutToBeRemoved.Add(function() end)',
         "C:/Steam/108600/1/mods/LGExtendedElectricity/42.20/media/lua/shared/LGExtendedElectricity/LGEEAgree.lua")
    load(open(SIEVE).read(), "C:/Users/x/Zomboid/mods/ChunkLoadSieve/42/media/lua/shared/!!!_ChunkLoadSieve.lua")
    for f in (["RoofPieces","SpritePropertyPatcher"] if server else ["RoofPieces","SpritePropertyPatcher","RoomLighting","TemplateStamp"]):
        load('Events.LoadGridsquare.Add(function() end)', "C:/Steam/108600/2/mods/RCStructureFramework/42/media/lua/shared/RCStructureFramework/%s.lua" % f)
    L.execute('for _,f in ipairs(Events.OnGameStart.list) do f() end')
    m=[l for l in L.eval('LINES').values() if "] missed " in l]
    if server:
        ok = len(m)==2 and any("LGEEAgree" in l for l in m) and any("vfx_birthday.lua: move Chunk Load Sieve above Vanilla Foods Expanded" in l for l in m)
        print(("  PASS" if ok else "  FAIL")+" dedicated server: RoomLighting and TemplateStamp not reported (%s)" % m)
        return ok
    ok = len(m)==1 and not any("vfx_birthday" in l for l in m) and "LGEEAgree.lua: move Chunk Load Sieve above LG Extended Electricity" in m[0]
    print(("  PASS" if ok else "  FAIL")+" missed shared target reported once (%s)" % m)
    return ok
print("1.8 missed shared targets"); q=missed() and missed(True)
print("ALL OK" if a and b and c and d and e and f and g and h and i and j and k and l and m and n and o and p and q else "FAIL")
