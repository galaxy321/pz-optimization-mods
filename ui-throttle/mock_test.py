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
    s.getVehicleContainer=function() return nil end
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
L.execute('for _,f in ipairs(Events.OnGameStart.l) do f() end')
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
print("ALL OK")
