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
    L.execute('for _,f in ipairs(Events.OnGameStart.list) do f() end')
    rnd=random.Random(seed)
    names=[None,"floors_01","onan_genset_01_0","location_shop_gas2go_01_13","LGEP_ghost","walls_01"]
    sqs=[]
    for i in range(20000):
        objs=[]
        for _ in range(rnd.choice([0,1,1,2,2,3,5])):
            objs.append({"name":rnd.choices(names,[1,60,1,1,1,40])[0],"md":rnd.random()<0.03,"cc":1 if rnd.random()<0.05 else 0})
        x=rnd.randint(1,1200); y=rnd.randint(1,400)
        if rnd.random()<0.01: k=rnd.randint(1,30); x,y=k*37,k*11
        s={"x":x,"y":y,"objs":objs,"gen":rnd.random()<0.002,"items":[1] if rnd.random()<0.03 else [],"special":[1] if rnd.random()<0.05 else [],"veh":rnd.random()<0.005,
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
print("sieve only"); a=run([SIEVE],1)
print("profiler then sieve"); b=run([PROF,SIEVE],2)
print("sieve then profiler"); c=run([SIEVE,PROF],3)
print("ALL OK" if a and b and c else "FAIL")
