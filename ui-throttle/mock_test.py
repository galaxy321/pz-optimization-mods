import os
import lupa
L=lupa.LuaRuntime()
L.execute(r'''
local clock=0
function getTimestampMs() return clock end
function advance(ms) clock=clock+ms end
Events={OnGameStart={l={}},OnTick={l={}}}
for _,e in pairs(Events) do e.Add=function(f) table.insert(e.l,f) end end
local function list(t) return {size=function() return #t end, get=function(_,i) return t[i+1] end} end
-- world: squares keyed "x,y"; some have a crate
crates={}
vehicles={}
SQ={}
local function sqAt(x,y)
  local k=x..","..y
  if not SQ[k] then
    local s={}
    s.getWorldObjects=function() return list({}) end
    s.getStaticMovingObjects=function() return list({}) end
    s.getObjects=function()
      local c=crates[k]
      if c then return list({{getContainerCount=function() return 1 end, getContainerByIndex=function() return c end}}) end
      return list({})
    end
    s.getVehicleContainer=function() return vehicles[k] end
    s.canReachTo=function() return true end
    SQ[k]=s
  end
  return SQ[k]
end
function getCell() return {getGridSquare=function(_,x,y,z) return sqAt(math.floor(x),math.floor(y)) end} end
P={x=10,y=10,dir="E",veh=nil}
local player={getVehicle=function() return P.veh end, getCurrentSquare=function() return sqAt(P.x,P.y) end,
  getDir=function() return P.dir end, getX=function() return P.x+0.5 end, getY=function() return P.y+0.5 end, getZ=function() return 0 end}
function getSpecificPlayer() return player end
refreshes=0
ISInventoryPage={}
function ISInventoryPage.update(self)
  if not self.onCharacter then
    if self.lastDir ~= P.dir then self.lastDir=P.dir; refreshes=refreshes+1
    elseif self.lastSquare ~= player:getCurrentSquare() then self.lastSquare=player:getCurrentSquare(); refreshes=refreshes+1 end
  end
end
ExactMinuteClock={}; clockRuns=0
function ExactMinuteClock.updateState(self) clockRuns=clockRuns+1 end
''')
L.execute(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'UIThrottle/42/media/lua/client/UIThrottle.lua')).read())
L.execute(r"""
PRINTED={}; __rp=print; print=function(s) PRINTED[#PRINTED+1]=tostring(s) end
MODS={"\\TakeABathAndShowerNew"}
getActivatedMods=function() return {contains=function(_,id) for _,x in ipairs(MODS) do if x==id then return true end end return false end} end
""")
L.execute('for _,f in ipairs(Events.OnGameStart.l) do f() end')
_m=[s for s in L.eval('PRINTED').values() if 'missed' in s]
assert len(_m)==1 and 'most likely changed' in _m[0] and 'mod list' not in _m[0], _m
print("PASS 1.1.4: grime moodle handler missed while the mod is on is named: " + _m[0][:60] + "...")
L.execute('PRINTED={}; UIThrottleEarly={tabas=true}')
L.execute('for _,f in ipairs(Events.OnGameStart.l) do f() end')
L.execute('PRINTED2=PRINTED; UIThrottleEarly=nil; MODS={}; PRINTED={}')
L.execute('for _,f in ipairs(Events.OnGameStart.l) do f() end')
_n=[s for s in list(L.eval('PRINTED2').values())+list(L.eval('PRINTED').values()) if 'missed' in s]
assert not _n, _n
print("PASS 1.1.3: no missed line when caught, or when the mod is off")
L.execute('MODS={"TakeABathAndShowerNew"}; UIThrottleEarly={tabasOn=false}; PRINTED={}')
L.execute('for _,f in ipairs(Events.OnGameStart.l) do f() end')
_o=[s for s in L.eval('PRINTED').values() if 'missed' in s]
assert not _o, _o
print("PASS 1.1.4: no missed line when the moodle part is switched off")
L.execute('print=__rp')
L.execute(r'''
page={player=0,onCharacter=false}
crates["25,11"]={name="crate"}   -- one crate next to the path at x=25
log={}
local function step() advance(16.7); ISInventoryPage.update(page) end
for x=11,40 do P.x=x; step(); step(); log[#log+1]=refreshes end
walkRefreshes=refreshes
-- turning in place on the empty street
P.dir="N"; step(); turnEmpty=refreshes
-- turn while next to the crate
P.x=24; step(); P.dir="E"; step(); turnNearCrate=refreshes
-- driving: enter a vehicle, cross 100 squares, exit
refreshes=0; P.veh={getSeat=function() return 0 end}
for x=41,140 do P.x=x; step() end
P.veh=nil; P.x=141; step()
driveRefreshes=refreshes
-- switching seats in a parked car: the reachable containers change, so it must rebuild
refreshes=0; P.seat=0; P.veh={getSeat=function() return P.seat end}
step(); P.dir="S"; step()
P.seat=1; P.x=P.x+1; step()
seatRefreshes=refreshes
P.veh=nil; P.seat=nil
for f=1,600 do advance(16.7); ExactMinuteClock.updateState({}) end
''')
g=L.globals()
print("walk 30 squares on an empty street with one crate beside it: rebuilds", g.walkRefreshes, "per step:", list(g.log.values()))
print("turn in place on empty street: total now", g.turnEmpty, "| step next to crate then turn there:", g.turnNearCrate)
print("drive 100 squares then get out: rebuilds", g.driveRefreshes)
print("get in a parked car, turn, switch seat: rebuilds", g.seatRefreshes)
assert g.driveRefreshes == 2 and g.seatRefreshes == 2, "vehicle rebuild counts changed"
assert g.walkRefreshes == 3, "walk rebuild count changed"

# --- 1.1.2: a subclass whose update calls the wrapped parent's -----------------------------------
# The review's case: if both classes are wrapped and the outer one calls the inner, the inner
# sees the signature the outer just saved and hides every move. CleanUI 42.19 doesn't do this
# (its two classes are separate and swapped as the global), but another inventory mod could.
L.execute(r'''
SubPage={}
setmetatable(SubPage,{__index=ISInventoryPage})
function SubPage.update(self) ISInventoryPage.update(self) end
throttleSub = UIThrottle._throttle and UIThrottle._throttle(SubPage, "SubPage")
crates={}; crates["25,11"]={name="crate"}
sub=setmetatable({player=0,onCharacter=false},{__index=SubPage})
refreshes=0; P.veh=nil; P.dir="E"; P.x=10
local function sstep() advance(16.7); SubPage.update(sub) end
for x=11,40 do P.x=x; sstep() end
subWalk=refreshes
refreshes=0; P.seat=0; P.veh={getSeat=function() return P.seat end}
P.x=41; sstep(); P.x=42; sstep(); P.veh=nil; P.x=43; sstep()
subDrive=refreshes
''')
print("subclass calling the wrapped parent: walk past crate rebuilds", g.subWalk, "| get in, drive 1, get out:", g.subDrive)
assert g.throttleSub, "subclass not wrapped"
assert g.subWalk == 3 and g.subDrive == 2, "nested update hid moves from the loot window"

# --- 1.1.2: walking beside a parked car rebuilds every step --------------------------------------
# vanilla lists a vehicle's parts by vehicle:canAccessContainer(part, player), which depends on
# where you stand, so a step along a car must rebuild even when the same car squares are in reach.
L.execute(r'''
crates={}; vehicles={}
vehicles["60,11"]={name="car"}
refreshes=0; P.veh=nil; P.dir="E"; P.x=55; ISInventoryPage.update(page)
local function step() advance(16.7); ISInventoryPage.update(page) end
for x=56,58 do P.x=x; step() end
before=refreshes
for x=59,61 do P.x=x; step() end
besideCar=refreshes-before
''')
print("three steps with the same parked car square in reach: rebuilds", g.besideCar)
assert g.besideCar == 3, "steps beside a car were skipped"

# --- Take A Bath And Shower grime moodle (1.1) ---------------------------------------------------
HERE=os.path.dirname(os.path.abspath(__file__))
EARLY=HERE+'/UIThrottle/42/media/lua/shared/!!!_UIThrottle.lua'
PROF=HERE+'/../lua-event-profiler/LuaEventProfiler/42/media/lua/shared/!!!LuaEventProfiler.lua'
TABAS=r"""
MOODLE_SETS = 0
local function moodleUpdate(player) MOODLE_SETS = MOODLE_SETS + 1; LAST_MOODLE_PLAYER = player end
Events.OnPlayerUpdate.Add(moodleUpdate)
Events.OnPlayerUpdate.Add(function() OTHER_RUNS = (OTHER_RUNS or 0) + 1 end)
"""
def moodle(with_prof):
    M=lupa.LuaRuntime()
    M.execute(r"""
      local clock=0
      function getTimestampMs() return clock end
      function advance(ms) clock=clock+ms end
      getFilenameOfClosure = function(f) return (debug.getinfo(f,"S").source:gsub("^@","")) end
      getSpecificPlayer=function() return nil end
      getAverageFPS=function() return 30 end
      getFileWriter=function() return {writeln=function() end, close=function() end} end
      local function newEvent()
        local e = {list={}}
        e.Add = function(fn) table.insert(e.list, fn) end
        e.Remove = function(fn) for i=#e.list,1,-1 do if e.list[i]==fn then table.remove(e.list,i) end end end
        e.trigger = function(...) for _,f in ipairs(e.list) do f(...) end end
        return e
      end
      Events = setmetatable({}, {__index=function(t,k) local e=newEvent(); rawset(t,k,e); return e end})
      local _ = Events.OnPlayerUpdate, Events.OnGameStart, Events.OnTick
      next = nil   -- Kahlua (the game's Lua) has no next(); 1.1 called it and broke every OnPlayerUpdate.Add
    """)
    load=M.eval('function(c,n) local f=assert(load(c,"@"..n)); f() end')
    if with_prof: load(open(PROF).read(), "C:/x/mods/LuaEventProfiler/42/media/lua/shared/!!!LuaEventProfiler.lua")
    load(open(EARLY).read(), "C:/x/mods/UIThrottle/42/media/lua/shared/!!!_UIThrottle.lua")
    load(TABAS, "C:/Steam/108600/3592172476/mods/Take A Bath And Shower New/42.20/media/lua/client/TABAS_BodyGrime.lua")
    M.execute(r"""
      P0 = {getIndex=function() return 0 end}
      P1 = {getIndex=function() return 1 end}
      for i=1,100 do Events.OnPlayerUpdate.trigger(P0); advance(10) end
      SETS0 = MOODLE_SETS
      MOODLE_SETS = 0; Events.OnPlayerUpdate.trigger(P1); SETS1 = MOODLE_SETS
    """)
    g=M.globals()
    ok = g.SETS0 == 4 and g.SETS1 == 1 and M.eval('LAST_MOODLE_PLAYER == P1') and g.OTHER_RUNS == 101
    print(("  PASS" if ok else "  FAIL") + f" grime moodle set {g.SETS0} times in 1 s (was 100), second player {g.SETS1}, other handler ran {g.OTHER_RUNS} of 101")
    if with_prof:
        w=M.eval('Events.OnPlayerUpdate.list[1]')
        inner=M.eval('LuaEventProfiler.originalOf')[w]
        src=M.eval('LuaEventProfiler.sourceOf')[inner]
        p = src is not None and 'TABAS_BodyGrime.lua' in M.eval('getFilenameOfClosure')(src)
        print(("  PASS" if p else "  FAIL") + " profiler reports TABAS's own file")
        ok = ok and p
    return ok
print("grime moodle"); m1=moodle(False)
print("grime moodle, profiler first"); m2=moodle(True)
assert m1 and m2, "grime moodle checks failed"
print("ALL OK")
