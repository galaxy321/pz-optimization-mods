"""Mock test for Test Ground: runs the real Lua (with Lua Event Profiler 1.4) against a fake world.

python3 -m pip install lupa
python3 test-ground/mock_test.py      # ends with "ALL OK"
"""
import os
import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TG = os.path.join(HERE, 'TestGround/42/media/lua/client/TestGround.lua')
TGB = os.path.join(HERE, 'TestGroundBridge/42/media/lua/client/TestGroundBridge.lua')
LEP = os.path.join(ROOT, 'lua-event-profiler/LuaEventProfiler/42/media/lua/shared/!!!LuaEventProfiler.lua')

try:
    from lupa import lua51 as lupa_rt
except ImportError:
    lupa_rt = lupa
import os
DEBUG_WEAK = False
L = lupa_rt.LuaRuntime(unpack_returned_tuples=True)

L.execute(r'''
next = nil   -- Kahlua has no next()
math.random, math.randomseed = nil, nil   -- nor math.random (1.12.8/1.12.9 knock-down traces): ZombRand
local zr = 12345
function ZombRand(a, b) zr = (zr * 1103515245 + 12345) % 2147483648; if b then return a + zr % (b - a) end return zr % a end
clock = 100000
function getTimestampMs() return clock end
paused = false
function isGamePaused() return paused end
FILES = {}
function getFileWriter(name, create, append)
  if not append or not FILES[name] then FILES[name] = FILES[name] and append and FILES[name] or {} end
  if not append then FILES[name] = {} end
  local t = FILES[name]
  return { writeln = function(_, l) t[#t+1] = l end, close = function() end }
end
function getFileReader(name, create)
  local t = FILES[name]
  if not t then return nil end
  local i = 0
  return { readLine = function() i = i + 1; return t[i] end, close = function() end }
end
MODFILES = {}
function getModFileReader(mod, path, create)
  local t = MODFILES[mod .. "/" .. path]
  if not t then return nil end
  local i = 0
  return { readLine = function() i = i + 1; return t[i] end, close = function() end }
end
function getFilenameOfClosure(fn) return FILENAMES and FILENAMES[fn] or "C:/Zomboid/mods/TestGround/42/media/lua/client/TestGround.lua" end
function getAverageFPS() return 60 end
DEBUGMODE = true
-- every error a pcall catches prints a stack trace in game, so the mock counts them by message
PCALL_FAILS = {}
local rawpcall = pcall
function pcall(f, ...)
  local r = { rawpcall(f, ...) }
  if not r[1] then
    local m = tostring(r[2]):gsub("^%[string \"<python>\"%]:%d+: ", "")
    PCALL_FAILS[m] = (PCALL_FAILS[m] or 0) + 1
  end
  return unpack(r)
end
function isDebugEnabled() return DEBUGMODE end
ZOOMS = {0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0}
ZTARGET = 1.0
ZSCROLLS = 0
function getCore() return {
  getZoom = function(_, i) return ZTARGET end,
  getMaxZoom = function() return ZOOMS[#ZOOMS] end,
  getNextZoom = function(_, i, d)
    for k, v in ipairs(ZOOMS) do if v == ZTARGET then
      local n = ZOOMS[k + (d > 0 and 1 or -1)]; return n or ZTARGET end end
    return 1 end,
  doZoomScroll = function(self, i, d) ZSCROLLS = ZSCROLLS + 1; ZTARGET = self:getNextZoom(i, d) end,
} end

Events = {}
for _, n in ipairs({"OnGameBoot","OnGameStart","OnTick","OnRenderTick","OnFillWorldObjectContextMenu","OnWeaponSwing","OnWeaponHitCharacter"}) do
  local e = { l = {} }
  e.Add = function(f) table.insert(e.l, f) end
  e.Remove = function(f) for i, g in ipairs(e.l) do if g == f then table.remove(e.l, i) return end end end
  Events[n] = e
end
function fire(n, ...) local copy = {} for i, f in ipairs(Events[n].l) do copy[i] = f end for _, f in ipairs(copy) do f(...) end end

local function list(t) return { size = function() return #t end, get = function(_, i) return t[i + 1] end } end

-- World
SQ = {}
UNLOADED = {}
FLAGS, PROPS, OBJS, ROOFS, BLOCKSQ, BUILD, ROOMS, VEHSQ = {}, {}, {}, {}, {}, {}, {}, {}
IsoFlagType = { TallHoppableW = "TallHoppableW", TallHoppableN = "TallHoppableN", HoppableW = "HoppableW", HoppableN = "HoppableN" }
function getSq(x, y, z)
  x, y, z = math.floor(x), math.floor(y), math.floor(z or 0)
  local k = x .. "," .. y .. "," .. z
  if UNLOADED[k] then return nil end
  if FARHIDE and y >= 250 then return nil end   -- a far road that hasn't loaded yet
  if not SQ[k] then
    local street = (y == 60 and x >= 30 and x <= 80) or (MAPST and y >= 300 and y <= 307 and x >= 1000 and x <= 1700) or (MAPST2 and x >= 1697 and x <= 1704 and y >= 300 and y <= 1000) or (MAPDIV and x >= 5000 and x <= 5700 and ((y >= 5400 and y <= 5406) or (y >= 5409 and y <= 5415)))
    if MAPWORKS and not street and y >= 40300 and y <= 40307 and x >= 1000 and x <= 1700 then street = true end
    -- 1.13.14: a street whose centre is 2 tiles off the map's line before a 20 deg bend and 9 tiles off after it
    if MAPOFF and not street then
      local cx, cy = x + 0.5, y + 0.5 - 20000
      if cy >= 300 and cy <= 308 and cx >= 1000 and cx <= 1712 then street = true
      else
        local sn, cs = math.sin(math.rad(20)), math.cos(math.rad(20))
        local d = -(cx - 1700) * sn + (cy - 302) * cs
        local a = (cx - 1700) * cs + (cy - 302) * sn
        street = d >= 5 and d <= 13 and a >= -10 and a <= 640
      end
    end
    local floorName = street and "blends_street_01_16" or "floors_exterior_natural_01_0"
    local flags = FLAGS[k] or {}
    local props = PROPS[k] or {}
    local objs = OBJS[k] or {}
    local hasFloor = (z == 0) or ROOFS[k]
    SQ[k] = { getDeadBodys = function() return list(BODIES[k] or {}) end, getX = function() return x end, getY = function() return y end, getZ = function() return z end,
      getFloor = function() if not hasFloor then return nil end return { getSprite = function() return { getName = function() return floorName end } end } end,
      isFree = function() return not BLOCKSQ[k] end,
      getVehicleContainer = function() if type(VEHSQ[k]) == "table" then return VEHSQ[k] end return VEHSQ[k] and {} or nil end,
      has = function(_, f) return flags[f] == true end,   -- B42: has(), not Is()
      getRoom = function() return ROOMS[k] end,
      getProperties = function() return { has = function(_, n) return props[n] == true end } end,
      getSpecialObjects = function() return list(objs) end,
      getObjects = function() return list(objs) end,
      getBuilding = function() return BUILD[k] end,
    }
  end
  return SQ[k]
end
ZOMBIES = {}
BODIES, NBODIES = {}, 0
function createRandomDeadBody(sq, blood)
  local k = sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()
  BODIES[k] = BODIES[k] or {}
  local md = {}
  local b = { getModData = function() return md end, hasModData = function() for _ in pairs(md) do return true end return false end }
  b.removeFromWorld = function()
    for i, o in ipairs(BODIES[k]) do if o == b then table.remove(BODIES[k], i); NBODIES = NBODIES - 1; break end end
  end
  b.removeFromSquare = function() end
  table.insert(BODIES[k], b)
  NBODIES = NBODIES + 1
  return b
end
function instanceof(o, c) return (c == "IsoZombie" and o.isZombie == true) or (c == "IsoDoor" and o.isDoor == true) or (c == "IsoTree" and o.isTree == true) end
local function door(north, locked, open)
  return { isDoor = true, getNorth = function() return north end, IsOpen = function() return open end,
    isLocked = function() return locked end, isBarricaded = function() return false end }
end
-- features for the survey
FLAGS["58,50,0"] = { TallHoppableW = true }
FLAGS["40,40,0"] = { TallHoppableN = true }
FLAGS["62,44,0"] = { HoppableW = true }
OBJS["45,45,0"] = { door(true, true, false) }
OBJS["46,56,0"] = { door(false, false, false) }
OBJS["47,57,0"] = { door(false, false, true) }   -- open: ignored
PROPS["40,55,0"] = { ladderN = true }
ROOFS["40,55,1"] = true
local cell = {
  getGridSquare = function(_, x, y, z) return getSq(x, y, z) end,
  getObjectListForLua = function() return list(ZOMBIES) end,
  getZombieList = function() return list(ZOMBIES) end,
}
function getCell() return cell end
function newZombie(x, y)
  local z = { isZombie = true, x = x or 0, y = y or 0, health = 1 }
  z.removeFromWorld = function() for i, o in ipairs(ZOMBIES) do if o == z then table.remove(ZOMBIES, i) return end end end
  z.removeFromSquare = function() end
  z.getX = function() return z.x end
  z.getY = function() return z.y end
  z.isDead = function() return z.health <= 0 end
  z.isProne = function() return z.prone == true end
  z.knockDown = function() z.prone = true; KNOCKS = (KNOCKS or 0) + 1 end
  z.setHealth = function(_, h) if NOKILL then return end z.health = h; z.deadTicks = 0 end
  table.insert(ZOMBIES, z)
end
spawned = 0
function addZombiesInOutfit(x, y, z, n) for i = 1, n do newZombie(x + 0.5, y + 0.5) end spawned = spawned + n end
-- zombies walk at you (0.05 tile a tick); a put-down one turns into a corpse 30 ticks later
function stepZombies()
  for i = #ZOMBIES, 1, -1 do
    local z = ZOMBIES[i]
    if z.health <= 0 then
      z.deadTicks = z.deadTicks + 1
      if z.deadTicks > 30 then table.remove(ZOMBIES, i) end
    elseif not FREEZE then
      local dx, dy = P.x - z.x, P.y - z.y
      local d = math.sqrt(dx*dx + dy*dy)
      if d > 0.8 then z.x, z.y = z.x + dx / d * 0.05, z.y + dy / d * 0.05
      elseif not P.god then P.scratched = (P.scratched or 0) + 1 end   -- in reach and no god mode: it scratches
    end
  end
end

-- Containers: a list of items; the loot step moves some out to the player and back.
function newContainer(n)
  local c = { items = {} }
  for i = 1, n do c.items[i] = { name = "item" .. i } end
  c.getItems = function() return list(c.items) end
  return c
end
function moveItem(item, from, to)
  for i, it in ipairs(from.items) do if it == item then table.remove(from.items, i); table.insert(to.items, item); return true end end
  return false
end
INV = newContainer(0)
INV.AddItem = function(self, id)
  if BBP_ITEMS and id ~= "Base.BaseballBat" and id ~= "Mod.Sword" then
    ITEMID = (ITEMID or 0) + 1; local it = { id = id, n = ITEMID }; it.getID = function() return it.n end
    table.insert(self.items, it); return it end
  if id == "Base.Pistol" then
    local g = { id = id, cond = 10, ranged = true, ammo = 0, clip = false, chambered = false }
    g.getDisplayName = function() return "M9 Pistol" end
    g.isTwoHandWeapon = function() return false end
    g.isRanged = function() return true end
    g.getSubCategory = function() return "Firearm" end
    g.getMaxRange = function() return 15 end
    g.getCondition = function() return g.cond end
    g.getConditionMax = function() return 10 end
    g.getMaxAmmo = function() return 15 end
    g.getCurrentAmmoCount = function() return g.ammo end
    g.setCurrentAmmoCount = function(_, n) g.ammo = n end
    g.isContainsClip = function() return g.clip end
    g.setContainsClip = function(_, v) g.clip = v end
    g.haveChamber = function() return true end
    g.isRoundChambered = function() return g.chambered end
    g.setRoundChambered = function(_, v) g.chambered = v end
    g.isJammed = function() return false end
    table.insert(self.items, g); return g end
  if id ~= "Base.BaseballBat" and id ~= "Mod.Sword" then return nil end
  local w = { id = id, cond = 15 }
  w.getDisplayName = function() return id == "Base.BaseballBat" and "Baseball Bat" or "Sword" end
  w.isTwoHandWeapon = function() return true end
  w.getSubCategory = function() return id == "Base.BaseballBat" and "Blunt" or "LongBlade" end
  w.getMaxRange = function() return 1.25 end
  w.getCondition = function() return w.cond end
  w.getConditionMax = function() return 15 end
  table.insert(self.items, w); return w end
INV.Remove = function(self, w) for i, it in ipairs(self.items) do if it == w then table.remove(self.items, i); return end end end
Perks = { Strength = "Strength", Axe = "Axe", FromString = function(n) if n == "Axe" or n == "Strength" or n == "Blunt" then return n end return nil end }
BUILD["45,65,0"], BUILD["46,65,0"], BUILD["30,30,0"] = "B1", "B1", "B2"
for x = 44, 47 do for y = 64, 66 do ROOMS[x .. ",64,0"] = "R1"; ROOMS[x .. "," .. y .. ",0"] = "R1" end end
-- B1's way in is the unlocked door at 46,56; B3 is nearer but its only door (45,45) is locked
BUILD["46,56,0"] = "B1"
BUILD["45,45,0"], BUILD["50,53,0"] = "B3", "B3"
OBJS["50,53,0"] = { { getContainer = function() return newContainer(4) end } }
-- trees on both verges of the street (y = 60), 3 tiles out on each side, x 50..70
for x = 50, 70 do OBJS[x .. ",57,0"] = { { isTree = true } }; OBJS[x .. ",63,0"] = { { isTree = true } } end

CRATE1, CRATE2 = newContainer(5), newContainer(2)
OBJS["45,65,0"] = { { getContainer = function() return CRATE1 end } }
OBJS["46,65,0"] = { { getContainer = function() return CRATE2 end } }
OBJS["30,30,0"] = { { getContainer = function() return newContainer(1) end } }

local function stateObj(name) return setmetatable({}, { __tostring = function() return "zombie.ai.states." .. name .. "@1a2b" end }) end
P = { x = 50.5, y = 50.5, z = 0, ghost = false, inv = false, state = "IdleState", teleports = 0 }
local fwd = { set = function(_, dx, dy) P.fdx, P.fdy = dx, dy; P.turns = (P.turns or 0) + 1 end }
player = {
  getX = function() return P.x end, getY = function() return P.y end, getZ = function() return P.z end,
  teleportTo = function(_, x, y, z) P.x, P.y, P.z = x, y, z; P.teleports = P.teleports + 1 end,
  getForwardDirection = function() return fwd end,
  isGhostMode = function() return P.ghost end, setGhostMode = function(_, v) P.ghost = v end,
  isInvincible = function() return P.inv end, setInvincible = function(_, v) P.inv = v end,
  -- like a game without -debug: setGodMod only works when the role has the capability
  isGodMod = function() return P.god == true end,
  setGodMod = function(_, v) if ROLE.caps.ToggleGodModHimself then P.god = v else P.god = false end end,
  getRole = function() return ROLE end,
  getCheats = function() return CHEATS end,
  getHealth = function() return P.health or 1 end,
  getBodyDamage = function() return BD end,
  isDead = function() return false end, getVehicle = function() return P.vehicle end,
  getCurrentState = function() return stateObj(P.state) end,
  getPlayerNum = function() return 0 end,
  getCurrentSquare = function() return getSq(P.x, P.y, P.z) end,
  getInventory = function() return INV end,
  -- a swing: every other one drops the nearest zombie within 1.5 tiles
  pressedAttack = function() PRESSED = (PRESSED or 0) + 1 end,
  setIsAiming = function(_, v) P.aiming = v end,
  isAttackStarted = function() return P.attackStarted == true end,
  setAttackStarted = function(_, v) P.attackStarted = v end,
  isPerformingAttackAnimation = function() return false end,
  getZombieKills = function() return KILLS or 0 end,
  isDeathDragDown = function() return P.dragDown == true end,
  setDeathDragDown = function(_, v) P.dragDown = v end,
  getHitReaction = function() return P.hitReaction or "" end,
  setHitReaction = function(_, v) P.hitReaction = v end,
  setBlockMovement = function(_, v) P.block = v end,
  setX = function(_, v) P.x = v end, setY = function(_, v) P.y = v end,
  getMeleeDelay = function() return 0 end, getRecoilDelay = function() return 0 end,
  isWeaponReady = function() return true end,
  isDoShove = function() return false end, isAimAtFloor = function() return false end,
  clearHandToHandAttack = function() P.attackStarted = false end,
  AttemptAttack = function()
    if not P.aiming or not P.block then return end
    local gun = P.primary and P.primary.ranged
    if gun then
      if P.primary.ammo <= 0 or not P.primary.chambered then return end
      P.primary.ammo = P.primary.ammo - 1
      GUNSHOTS = (GUNSHOTS or 0) + 1
    end
    SWINGS = (SWINGS or 0) + 1
    if Events.OnWeaponSwing then fire("OnWeaponSwing", player, P.primary) end
    if SWINGS % 2 == 0 then
      local best, bd = nil, gun and 15 or 1.5
      for _, z in ipairs(ZOMBIES) do
        local d = math.sqrt((z.x - P.x) ^ 2 + (z.y - P.y) ^ 2)
        if z.health > 0 and d < bd then best, bd = z, d end
      end
      if best then
        if Events.OnWeaponHitCharacter then fire("OnWeaponHitCharacter", player, best, P.primary, 1.5) end
        best:setHealth(0); KILLS = (KILLS or 0) + 1; if P.primary then P.primary.cond = P.primary.cond - 1 end end
    end
  end,
  getPrimaryHandItem = function() return P.primary end,
  setPrimaryHandItem = function(_, w) P.primary = w end,
  getSecondaryHandItem = function() return P.secondary end,
  setSecondaryHandItem = function(_, w) P.secondary = w end,
  getPerkLevel = function(_, pk) return (PERKS or {})[pk] or 5 end,
  setPerkLevelDebug = function(_, pk, l) PERKS = PERKS or {}; PERKS[pk] = l end,
  isOnFloor = function() return P.down == true end, isKnockedDown = function() return false end,
  getStats = function() return { reset = function() end,
    getNumVisibleZombies = function() local n = 0; for _, z in ipairs(ZOMBIES) do if math.abs(z.x - P.x) < 20 and math.abs(z.y - P.y) < 20 then n = n + 1 end end return n end } end,
  setRunning = function(_, v) P.running = v end, setPathfindRunning = function() end,
}
CharacterStat = { ENDURANCE = 1, PANIC = 2, FATIGUE = 3, PAIN = 4, STRESS = 5 }
-- the map's zombie intensity: a hot spot round 150,90
SANDBOX = { ["ZombieLore.ZombiesDragDown"] = true, ["ZombieLore.ZombiesCrawlersDragDown"] = true }
function getSandboxOptions() return { getOptionByName = function(_, n)
  if SANDBOX[n] == nil then return nil end
  return { getValue = function() return SANDBOX[n] end, setValue = function(_, v) SANDBOX[n] = v; if n == "ZombieLore.ZombiesDragDown" and v == false then DRAGOFF = (DRAGOFF or 0) + 1 end end } end } end
-- forest zones: FOREST[x .. "," .. y] or a FORESTBOX {x1,y1,x2,y2}
FOREST = {}
local function zl(t) return { size = function() return #t end, get = function(_, i) return t[i + 1] end } end
function getWorld() return { getMetaGrid = function() return {
  getZonesAt = function(_, x, y, z)
    for _, b in ipairs(FOREST) do if x >= b[1] and x <= b[3] and y >= b[2] and y <= b[4] then return zl({ { getType = function() return "DeepForest" end } }) end end
    return zl({ { getType = function() return "Nav" end } }) end,
  getChunkDataFromTile = function(_, x, y)
  local d = math.sqrt((x - 150) ^ 2 + (y - 90) ^ 2)
  return { getZombieIntensity = function() return math.max(0, 1 - d / 120) end } end } end } end
function getSpecificPlayer(n) return player end
Capability = { ToggleGodModHimself = "ToggleGodModHimself", ToggleInvincibleHimself = "ToggleInvincibleHimself" }
ROLE = { caps = {}, locked = false }
ROLE.hasCapability = function(_, c) return ROLE.caps[c] == true end
ROLE.addCapability = function(_, c) if ROLE.locked then return false end ROLE.caps[c] = true; return true end
ROLE.removeCapability = function(_, c) ROLE.caps[c] = nil; return true end
BD = {
  getNumPartsScratched = function() return P.scratched or 0 end,
  getNumPartsBitten = function() return 0 end, getNumPartsBleeding = function() return 0 end,
  IsInfected = function() return false end,
  RestoreToFullHealth = function() P.scratched = 0; HEALED = (HEALED or 0) + 1 end,
  setInfected = function() end, setInfectionTime = function() end,
}
FREEZE = false
CheatType = { GOD_MODE = "GOD_MODE" }
CHEATS_BROKEN = false
CHEAT_THROWS = 0
CHEATS = { set = function(_, t, v) if CHEATS_BROKEN then CHEAT_THROWS = CHEAT_THROWS + 1; error("no such method") end if t == "GOD_MODE" then P.god = v end end,
  isSet = function(_, t) if CHEATS_BROKEN then CHEAT_THROWS = CHEAT_THROWS + 1; error("no such method") end return t == "GOD_MODE" and P.god == true end }

-- Timed actions: a walk moves 0.1 tile per tick; targets in BLOCKED make it give up after 1 s.
BLOCKED = {}
CLIMB = {}
QUEUE = {}
ISWalkToTimedAction = {}
function ISWalkToTimedAction:new(p, sq) return { sq = sq, ticks = 0 } end
ISTimedActionQueue = {
  add = function(a) table.insert(QUEUE, a) end,
  clear = function(p) QUEUE = {} end,
  isPlayerDoingAction = function(p) return #QUEUE > 0 end,
}
luautils = { walkAdj = function(p, sq) ISTimedActionQueue.add(ISWalkToTimedAction:new(p, getSq(sq:getX() + 1, sq:getY(), sq:getZ()))); return true end }
TRANSFERS = 0
ISInventoryTransferUtil = { newInventoryTransferAction = function(p, item, from, to) return { transfer = true, item = item, from = from, to = to, ticks = 0 } end }
function stepWalk()
  local a = QUEUE[1]
  if not a then P.state = "IdleState" return end
  a.ticks = a.ticks + 1
  if a.transfer then
    if a.ticks >= 20 then
      if moveItem(a.item, a.from, a.to) then TRANSFERS = TRANSFERS + 1 end
      table.remove(QUEUE, 1)
    end
    return
  end
  local k = a.sq:getX() .. "," .. a.sq:getY() .. "," .. a.sq:getZ()
  if BLOCKED[k] and a.ticks > 60 then table.remove(QUEUE, 1) P.state = "IdleState" return end
  P.state = (CLIMB[k] and a.ticks % 50 < 10) and "ClimbOverWallState" or "PathFindState2"
  local tx, ty = a.sq:getX() + 0.5, a.sq:getY() + 0.5
  local dx, dy = tx - P.x, ty - P.y
  local d = math.sqrt(dx*dx + dy*dy)
  if d < 0.15 then P.x, P.y, P.z = tx, ty, a.sq:getZ(); table.remove(QUEUE, 1) P.state = "IdleState" return end
  if BLOCKED[k] then return end
  P.x, P.y = P.x + dx / d * 0.1, P.y + dy / d * 0.1
end

-- A fake car for drivefast. It spawns facing the wrong way (and 8 degrees off), its physics
-- forward vector maps to the map as (-z, x), and getAngleY turns the other way from the map, so
-- the step has to work all three out. Cruise control accelerates at 6 tiles/s^2, brakes at 8.
IsoDirections = { N = "N", S = "S", E = "E", W = "W" }
local DIRANG = { E = 0, S = math.pi / 2, W = math.pi, N = -math.pi / 2 }
NOCAR = false
CARS_REMOVED, ALIGN_CALLS, CAR = 0, 0, nil
function getScriptManager() return { getVehicle = function(_, n) if NOCAR then return nil end return n == "Base.SportsCar" and {} or nil end } end
function triggerEvent() end
Vector3f = { new = function() local v = { _x = 0, _z = 0 }; v.x = function() return v._x end; v.z = function() return v._z end; return v end }
function addVehicleDebug(name, dir, skin, sq)
  local c = { px = sq:getX() + 0.5, py = sq:getY() + 0.5, speed = 0, reg = false, regSpeed = 0, brakeT = -100000, engine = false }
  c.yaw = -math.deg(DIRANG[dir] + math.pi + math.rad(8))
  local function head() return -math.rad(c.yaw) end
  c.getX = function() return c.px end
  c.getY = function() return c.py end
  c.getForwardVector = function(_, v) local h = head(); v._x = math.sin(h); v._z = -math.cos(h); return v end
  c.getAngleX = function() return 0 end
  c.getAngleZ = function() return 0 end
  c.getAngleY = function() return c.yaw end
  c.setAngles = function(_, x, y, z)
    if MIRROR and c.speed > 3 then y = 2 * c.yaw - y end   -- MIRROR: a car going faster than 3 tiles/s turns the other way
    if math.abs(y - c.yaw) >= 1 then c.yaw = y end; ALIGN_CALLS = ALIGN_CALLS + 1 end   -- like the game: under a degree is ignored
  c.getZ = function() return 0 end
  c.hr, c.torq = 0, 0   -- turn rate (map heading, rad/s) and the torque pushed this tick
  c.applyImpulseGeneric = function(_, x, y, z, dx, dy, dz, m)
    local d = math.sqrt(dx * dx + dy * dy)
    if d == 0 then return end
    c.torq = c.torq + ((x - c.px) * dy - (y - c.py) * dx) / d * m
    TORQUE_CALLS = (TORQUE_CALLS or 0) + 1
  end
  c.getMaxSpeed = function() return 150 end
  c.repair = function() end
  c.cheatHotwire = function() end
  c.getPartById = function(_, id) return { setContainerContentAmount = function(_, a) c.fuel = a end, getContainerCapacity = function() return 50 end, getInventoryItem = function() return nil end } end
  c.enter = function(_, seat, p) P.vehicle = c end
  c.exit = function(_, p) P.vehicle = nil end
  c.setCharacterPosition = function() end
  c.playPassengerAnim = function() end
  c.tryStartEngine = function() c.engine = true end
  c.engineDoRunning = function() c.engine = true end
  c.isEngineRunning = function() return c.engine end
  c.setRegulator = function(_, v) c.reg = v end
  c.setRegulatorSpeed = function(_, v) c.regSpeed = v end
  c.setForceBrake = function() c.brakeT = clock end
  c.getCurrentSpeedKmHour = function() return c.speed * 3.6 end
  c.permanentlyRemove = function() c.removed = true; CARS_REMOVED = CARS_REMOVED + 1; if CAR == c then CAR = nil end end
  CAR = c
  return c
end
function addVehicle() return nil end
function stepCar(dt)
  local c = CAR
  if not c then return end
  if CARWALL and c.px >= CARWALL and (not CARWALL_END or c.px <= CARWALL_END) and math.cos(-math.rad(c.yaw)) > 0 then c.speed = 0 end
  if clock - c.brakeT < 1000 then
    c.reg = false
    c.speed = math.max(0, c.speed - 8 * dt)
  elseif c.engine and c.reg and c.speed * 3.6 < c.regSpeed then
    c.speed = c.speed + 6 * dt
  else
    c.speed = math.max(0, c.speed - 0.5 * dt)
  end
  if CARDRIFT and c.speed > 1 then c.yaw = c.yaw + CARDRIFT * dt end   -- no car runs perfectly straight
  -- torque turns the car; the tyres damp the turn harder the faster it goes (TQSCALE: how strong a push is)
  c.hr = c.hr + (c.torq * (TQSCALE or 0.02) - c.hr * (2 + c.speed * 0.2)) * dt
  c.torq = 0
  c.yaw = c.yaw - math.deg(c.hr * dt)
  if BARRIER and c.speed > 0 then   -- 1.13.14: road works the car can't drive through
    local hh = -math.rad(c.yaw)
    for _, k in ipairs({ -0.9, 0, 0.9 }) do
      local fx, fy = c.px + math.cos(hh) * 1.5 - math.sin(hh) * k, c.py + math.sin(hh) * 1.5 + math.cos(hh) * k
      if BARRIER[math.floor(fx) .. "," .. math.floor(fy)] then c.speed = 0; BARRIERHIT = (BARRIERHIT or 0) + 1 end
    end
  end
  if WRECKAT and c.speed > 0 then
    local w = VEHSQ[WRECKAT]
    if type(w) == "table" and not w.gone and math.abs(c.px - w.x) < 2 and math.abs(c.py - w.y) < (WRECKW or 4) then c.speed = 0; WRECKHIT = (WRECKHIT or 0) + 1 end
  end
  local h = -math.rad(c.yaw)
  c.px, c.py = c.px + math.cos(h) * c.speed * dt, c.py + math.sin(h) * c.speed * dt
  if c.speed > (MAXV or 0) then MAXV = c.speed end
  if P.vehicle == c then P.x, P.y = c.px, c.py end
end

minutes = 0
gameSpeed = 1
GTMOD = {}
local gt = { getModData = function() return GTMOD end, setTimeOfDay = function(_, h) timeOfDay = h end, setMultiplier = function(_, m) mult = m; if m > (maxMult or 1) then maxMult = m end end, getMinutesStamp = function() return minutes end }
function getGameTime() return gt end
function setGameSpeed(s) gameSpeed = s end
function getGameSpeed() return gameSpeed end

CLIM = {}
local function cf(name)
  local f = { name = name, admin = false, value = nil }
  f.getName = function() return name end
  f.setEnableAdmin = function(_, v) f.admin = v end
  f.setAdminValue = function(_, v) f.value = v end
  return f
end
local floats = { cf("DAYLIGHT_STRENGTH"), cf("PRECIPITATION_INTENSITY"), cf("FOG_INTENSITY"), cf("CLOUD_INTENSITY"), cf("WIND_INTENSITY") }
for _, f in ipairs(floats) do CLIM[f.name] = f end
local climate = { getFloatMax = function() return #floats end, getClimateFloat = function(_, i) return floats[i + 1] end }
function getClimateManager() return climate end
function getActivatedMods() return list({ "TestGround", "LuaEventProfiler", "HitchFix" }) end

-- A fake mod handler, so the profiler has something to report per step.
function slowHandler() clock = clock + 0 end
''')

L.execute(open(LEP, encoding='utf-8').read())
# 1.13.0: the mod is split into TestGround/*.lua files that the entry file require()s
TGDIR = os.path.dirname(TG)
def tg_sources():
    srcs = {}
    for root, _, fs in os.walk(os.path.join(TGDIR, 'TestGround')):
        for f in fs:
            if f.endswith('.lua'):
                full = os.path.join(root, f)
                srcs[os.path.relpath(full, TGDIR)[:-4].replace(os.sep, '/')] = open(full, encoding='utf-8').read()
    return srcs
TG_ALL = open(TG, encoding='utf-8').read() + ''.join(tg_sources().values())
_v = [__import__('re').search(r'local VERSION = "([\d.]+)"', t) for t in (open(TG, encoding='utf-8').read(), tg_sources()['TestGround/Core'])]
L.globals().MODSRC = L.table_from(tg_sources())
L.execute(r'''
MODLOADED = {}
local reqBase = require
function require(name)
  if MODSRC[name] then
    if not MODLOADED[name] then MODLOADED[name] = true; assert(loadstring(MODSRC[name], "@" .. name .. ".lua"))() end
    return true
  end
  if string.find(name, "^ISUI/") then return true end
  if reqBase then return reqBase(name) end
  error("module '" .. tostring(name) .. "' not found")
end
UIFont = UIFont or { Medium = "m", Small = "s" }
ISPanel = { derive = function(self, n) local c = {}; c.__index = c; setmetatable(c, { __index = self }); c.Type = n; _G[n] = c; return c end,
  new = function(self, x, y, w, h) local o = setmetatable({ x = x, y = y, width = w, height = h, children = {}, vis = true }, self); return o end,
  initialise = function() end, instantiate = function() end, addChild = function(self, c) table.insert(self.children, c) end,
  addToUIManager = function(self) ENDSCREENS = (ENDSCREENS or 0) + 1; LASTEND = self end, bringToTop = function() end,
  setVisible = function(self, v) self.vis = v end, removeFromUIManager = function() end, prerender = function() end,
  drawText = function(self, t) self.drawn = (self.drawn or "") .. t .. "\n" end }
ISButton = ISPanel:derive("ISButton")
ISButton.new = function(self, x, y, w, h, title) return setmetatable({ title = title, vis = true }, ISButton) end
ISButton.setTitle = function(self, t) self.title = t end
''')
L.execute(open(TG, encoding='utf-8').read())
L.execute(open(TGB, encoding='utf-8').read())
L.execute(r'''
FILENAMES = {}
FILENAMES[slowHandler] = "C:/Zomboid/mods/SlowMod/42/media/lua/client/Slow.lua"
Events.OnTick.Add(slowHandler)
''')

ok = True
def check(cond, msg):
    global ok
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        ok = False

# Game start writes the template and parses it.
L.execute('fire("OnGameStart")')
files = L.eval('FILES')
check(files['TestGround_plan.txt'] is not None, 'plan template written on first start')
tmpl = [files['TestGround_plan.txt'][i] for i in range(1, len(files['TestGround_plan.txt']) + 1)]
plan = L.eval('TestGround.parsePlan')(L.table_from(tmpl))
check(len(plan.errors) == 0, 'template parses without errors')
check(len(plan.steps) == 1 and plan.steps[1].kind == 'idle', 'template has one idle step')

# Parser checks.
bad = L.eval('TestGround.parsePlan')(L.table_from(['step = fly 3', 'foo = 1', 'walkto = x | 1,2', 'route = a,b']))
check(len(bad.errors) == 4, 'bad lines are reported, not thrown (%d errors)' % len(bad.errors))

# Recording through the context menu appends to the plan.
L.execute(r'''
captured = {}
ISContextMenu = { getNew = function(_, parent)
  local m = { opts = {} }
  m.addOption = function(self, name, a, fn) self.opts[name] = fn; return {} end
  return m
end }
ctx = { addOption = function() return {} end, addSubMenu = function(_, o, sub) captured = sub end }
local sq = getSq(60, 52, 0)
fire("OnFillWorldObjectContextMenu", 0, ctx, { { getSquare = function() return sq end } }, false)
captured.opts["Add route point: here"]()
captured.opts["Add Walk To case: me to here"]()
''')
plantxt = L.eval('FILES["TestGround_plan.txt"]')
lines = [plantxt[i] for i in range(1, len(plantxt) + 1)]
check(lines[-2] == 'route = 60,52,0', 'menu records a route point')
check(lines[-1] == 'walkto = case | 50,50,0 | 60,52,0 | any', 'menu records a Walk To case from you to the square')

# A full plan.
PLAN = '''
label = mock
settle = 2
repeat = 2
start = 50,50,0
time = 12
weather = rain
zombies = none
god = 1
step = walk 1
step = stream 5 15
step = idle 3
step = turn 3
step = wait 4 3
step = walkto
route = 50,50,0
route = 55,50,0
route = 55,54,0
road = 50,50,0
road = 90,50,0
walkto = open | 50,50,0 | 56,50,0 | arrive
walkto = locked | 50,50,0 | 52,58,0 | fail
walkto = wall | 50,50,0 | 50,56,0 | arrive
walkto = wrongexpect | 50,50,0 | 52,58,0 | arrive
'''
L.execute('TestGround.trusted = true')
L.execute('FILES["TestGround_plan.txt"] = {}')
for l in PLAN.strip().split('\n'):
    L.execute('table.insert(FILES["TestGround_plan.txt"], %r)' % l)
L.execute(r'''
BLOCKED["52,58,0"] = true
CLIMB["50,56,0"] = true
for i = 1, 5 do newZombie() end
P.x, P.y = 70.5, 70.5   -- home, away from the start
started = TestGround.start()
''')
check(L.eval('started') is True, 'run starts')
HAS_WINDOW = L.eval('LuaEventProfiler.takeWindow') is not None
print('profiler in the repo has takeWindow (1.4+):', HAS_WINDOW)
check(not HAS_WINDOW or L.eval('LuaEventProfiler.quiet') is True, 'profiler goes quiet during the run')
check(L.eval('#ZOMBIES') == 0, 'zombies = none clears zombies')
check(L.eval('CLIM.PRECIPITATION_INTENSITY.admin') is True, 'weather override set')
check(L.eval('timeOfDay') == 12, 'time of day set')
check(L.eval('P.inv') is True, 'invincible on during the run')
check(L.eval('P.god') is True and L.eval('ROLE.caps.ToggleGodModHimself') is None, 'god mode on during the run, via getCheats():set (no role change needed)')

L.execute(r'''
ticks = 0
local maxSpeedSeen = 1
while TestGround.isRunning() and ticks < 200000 do
  ticks = ticks + 1
  clock = clock + ((ticks % 500 == 0) and 150 or 16)
  if ticks % 200 == 0 then minutes = minutes + gameSpeed end
  if ticks % 1000 == 0 then newZombie() end
  if gameSpeed > maxSpeedSeen then maxSpeedSeen = gameSpeed end
  stepWalk()
  fire("OnTick")
end
maxSpeed = maxSpeedSeen
''')
check(L.eval('TestGround.isRunning()') is False, 'run finishes (%d ticks)' % L.eval('ticks'))
check(L.eval('maxSpeed') == 3, 'wait step raised game speed to 3')
check(L.eval('gameSpeed') == 1 and L.eval('mult') == 1 and L.eval('maxMult') == 20, 'game speed x20 during wait, back to 1 after')
check(L.eval('CLIM.PRECIPITATION_INTENSITY.admin') is False, 'weather override cleared')
check(L.eval('P.inv') is False and L.eval('P.ghost') is False, 'invincible and ghost mode restored')
check(L.eval('P.god') is False, 'god mode off again after the run')
check(abs(L.eval('P.x') - 70.5) < 0.01 and abs(L.eval('P.y') - 70.5) < 0.01, 'player returned home')
check(not HAS_WINDOW or L.eval('LuaEventProfiler.quiet') is False, 'profiler back to normal')

files = L.eval('FILES')
names = [k for k in files.keys() if str(k).startswith('TestGround_mock_')]
AUX = ('_trace.txt', '_perf.txt', '_spikes.txt', '_marks.txt')
report_name = [n for n in names if n.endswith('.txt') and not n.endswith(AUX)]
trace_name = [n for n in names if n.endswith('_trace.txt')]
check(len(report_name) == 1 and len(trace_name) == 1 and len(names) == 4, 'report, trace, perf and spikes written: %s' % names)
rep = files[report_name[0]]
rep = [rep[i] for i in range(1, len(rep) + 1)]
tr = files[trace_name[0]]
tr = [tr[i] for i in range(1, len(tr) + 1)]
text = '\n'.join(rep)
print('\n--- report ---')
print(text)
print('--- trace (first 12 and last 12 lines) ---')
print('\n'.join(tr[:12]))
print('...')
print('\n'.join(tr[-12:]))
print('---')

check(text.count('== pass ') == 12, '12 step sections (6 steps x 2 passes)')
check('mods: HitchFix;LuaEventProfiler;TestGround' in text, 'active mods listed')
check('3 of 3 legs arrived' in text, 'walk step: all legs arrived')
check(not HAS_WINDOW or ('Lua in handlers' in text and '[SlowMod]' in text), 'profiler numbers per step, by mod')
check('1 hitches (100 ms+)' in text and 'worst 150 ms' in text, 'frame stats count the injected hitches')
check('walkto open: arrive' in text and 'walkto locked: fail' in text, 'walkto outcomes recorded')
check('ClimbOverWallState' in text, 'walkto records the states seen (wall climb)')
check('walkto wrongexpect: fail' in text and 'EXPECTED ARRIVE' in text, 'unexpected outcome is flagged')
check('3 of 4 cases as expected' in text, 'walkto step summary')
check(any('in-game minutes passed at speed 3' in l for l in rep), 'wait step reports in-game minutes')
check(any('tiles at 15 tiles/s' in l for l in rep), 'stream step reports distance')
check(L.eval('P.turns') >= 6, 'turn step turned the player')
check(any(l.split()[1] == 'pos' for l in tr if len(l.split()) > 1), 'trace has position samples')
check(any('waiting ' in l and 'with no movement at' in l and 'stands still by design' in l for l in tr), 'stall watchdog names what a still step waits for')
check(any('waiting ' in l and 'with no movement at' in l for l in tr) and any('moving again after' in l for l in tr), 'stall watchdog says when the player moves again')
check(not any('bookkeeping took' in l for l in tr), 'no slow step bookkeeping in a normal run')

# 1.5.4: the frame summary is a running histogram, same percentiles as sorting every gap, and cheap at any length.
import random, time as _time
random.seed(7)
gaps = [random.choice([16, 16, 17, 16, 33, 16, 17, 50, 16]) + random.random() for _ in range(3000)] + [150.2, 420.0]
fs = L.eval('TestGround.frameSummary')(L.table_from(gaps), 60)
def pct(srt, q):
    import math
    return int(math.floor(srt[max(1, math.ceil(len(srt) * q)) - 1] + 0.5))
srt = sorted(gaps)
check((fs.p50, fs.p95, fs.p99, fs.worst) == (pct(srt, .5), pct(srt, .95), pct(srt, .99), 420), 'histogram percentiles match a full sort: %s' % [fs.p50, fs.p95, fs.p99, fs.worst])
L.execute('BIGFR = nil')
t0 = _time.time()
L.execute('''
local fr = TestGround.newFrames()
for i = 1, 40000 do TestGround.addGap(fr, (i % 7 == 0) and 33.4 or 16.6) end
BIGFR = TestGround.frameSummary(fr, 660)
''')
check(L.eval('BIGFR.frames') == 40000 and L.eval('BIGFR.p99') == 33, 'summary of a 40k-frame step (the 11 min walk) works')

# Notes from other mods only land during a run.
L.execute('TestGround.note("x", 1)')
check(True, 'note outside a run is a no-op')

# Bridge: commands in TestGround_cmd.txt, results in TestGround_out.txt.
def bridge(*cmds):
    L.execute('FILES["TestGround_cmd.txt"] = {}')
    for c in cmds:
        L.execute('table.insert(FILES["TestGround_cmd.txt"], %r)' % c)
    L.execute('clock = clock + 1100; fire("OnTick")')

def out_lines():
    o = L.eval('FILES["TestGround_out.txt"]')
    return [o[i] for i in range(1, len(o) + 1)] if o else []

L.execute('FILES["TestGround_alt.txt"] = {"label = alt", "settle = 1", "step = idle 2"}')
bridge('status', 'lua 1 + 2', 'lua nosuch.call()', 'run TestGround_alt.txt')
o = out_lines()
check('idle' in o, 'bridge status says idle')
check('ok: 3' in o, 'bridge lua returns a value')
check(any(l.startswith('error:') for l in o), 'bridge lua error is caught')
check('started alt' in o, 'bridge starts a run from another plan file')
check(L.eval('#FILES["TestGround_cmd.txt"]') == 0, 'command file emptied')
bridge('status')
check(any(l.startswith('running alt') for l in out_lines()), 'bridge status while running')
L.execute('''
local n = 0
while TestGround.isRunning() and n < 10000 do n = n + 1; clock = clock + 16; stepWalk(); fire("OnTick") end
''')
check(any(l.startswith('=== done TestGround_alt_') for l in out_lines()), 'bridge announces the finished report')
bridge('run nosuch.txt')
check('no such plan: nosuch.txt' in out_lines(), 'missing plan file reported')

# Survey: builds a plan and a site list from the area, then the plan runs.
L.execute('P.x, P.y, P.z = 50.5, 50.5, 0; FILES["TestGround_out.txt"] = {}')
bridge('survey 30 run here')
L.execute('''
local n = 0
while n < 100 and not (FILES["TestGround_survey.txt"]) do n = n + 1; clock = clock + 16; fire("OnTick") end
''')
sv = L.eval('FILES["TestGround_survey.txt"]')
check(sv is not None, 'survey wrote TestGround_survey.txt')
svl = [sv[i] for i in range(1, len(sv) + 1)] if sv else []
site = L.eval('FILES["TestGround_site.txt"]')
sitel = [site[i] for i in range(1, len(site) + 1)] if site else []
print('--- survey plan ---'); print('\n'.join(svl)); print('--- site ---'); print('\n'.join(sitel)); print('---')
check(sum(1 for l in svl if l.startswith('route = ')) == 4, 'survey: 4 route points')
check('road = 30,60,0' in svl and 'road = 80,60,0' in svl, 'survey: road = the street run ends')
check(any(l.startswith('walkto = tallwall1 | 56,50,0 | 59,50,0') for l in svl), 'survey: tall wall W case crosses the edge')
check(any(l.startswith('walkto = tallwall2 | 40,38,0 | 40,41,0') for l in svl), 'survey: tall wall N case crosses the edge')
check(any(l.startswith('walkto = fence1') for l in svl), 'survey: low fence case')
check(any(l.startswith('walkto = lockeddoor1 | 45,43,0 | 45,46,0') for l in svl), 'survey: locked door case')
check(any(l.startswith('walkto = door1 | 44,56,0 | 47,56,0') for l in svl), 'survey: unlocked closed door case, open door ignored')
check(any(l.startswith('walkto = ladder1') and l.endswith('| walktoplus') and '40,55,1' in l for l in svl), 'survey: ladder case to the floor above via Walk To Plus')
check('door 45,45,0 N locked' in sitel and 'ladder 40,55,0' in sitel and 'street 30,60,0 80,60,0 51' in sitel, 'site list has every feature')
check(any('started survey run' in l for l in out_lines()), 'survey run started through the bridge')
L.execute('''
local n = 0
while TestGround.isRunning() and n < 200000 do n = n + 1; clock = clock + 16; stepWalk(); fire("OnTick") end
''')
check(any(l.startswith('=== done TestGround_survey_') for l in out_lines()), 'survey run finished')

# Mod-defined steps and plan data.
L.execute('''
seen = {}
TestGround.addStep("probe", {
  begin = function(r, st) seen.arg = st.a; seen.data = r.plan.extra["probe.spot"] and r.plan.extra["probe.spot"][1] end,
  tick = function(r, st, t) st.result = "probed"; return t - st.t0 > 500 end,
})
FILES["TestGround_probe.txt"] = { "label = probe", "settle = 1", "probe.spot = 1,2,0", "step = probe 7" }
''')
bridge('run TestGround_probe.txt')
L.execute('''
local n = 0
while TestGround.isRunning() and n < 10000 do n = n + 1; clock = clock + 16; fire("OnTick") end
''')
check(L.eval('seen.arg') == 7 and L.eval('seen.data') == '1,2,0', 'mod step gets its number and plan data')
check(any(l.startswith('=== done TestGround_probe_') for l in out_lines()), 'mod step run finished')


# Baseline scenario: survey writes TestGround_baseline.txt, the bridge runs it.
L.execute('MARKS = {}; LuaEventProfiler.mark = function(l) table.insert(MARKS, l) end')
L.execute('P.x, P.y, P.z = 50.5, 50.5, 0; FILES["TestGround_out.txt"] = {}; FILES["TestGround_baseline.txt"] = nil; ZOMBIES = {}; for i = 1, 3 do newZombie(60, 60) end')
L.execute('BLOCKED["47,65,0"] = true; BLOCKSQ["75,60,0"] = true; VEHSQ["33,61,0"] = true')
bridge('baseline 30 here')
L.execute('''
local n = 0
while n < 100 and not (FILES["TestGround_baseline.txt"]) do n = n + 1; clock = clock + 16; fire("OnTick") end
''')
bl = L.eval('FILES["TestGround_baseline.txt"]')
bll = [bl[i] for i in range(1, len(bl) + 1)] if bl else []
print('--- baseline plan ---'); print('\n'.join(bll)); print('---')
check('loot = 45,65,0' in bll and 'loot = 46,65,0' in bll and 'loot = 30,30,0' not in bll and 'loot = 50,53,0' not in bll, 'baseline: loot from the nearest building with a usable door (not the nearer locked one)')
check('drive = 1.000,0.000' in bll, 'baseline: drive along the street')
check([l for l in bll if l.startswith('step = ')] == ['step = walk 2 walk', 'step = loot loot', 'step = drive 60 20 glide_south',
      'step = drive 40 20 -1 glide_north', 'step = weather fog', 'step = drive 60 20 glide_fog', 'step = weather clear', 'step = treeroad 40 20 glide_trees',
      'step = drivefast 90 120 drive_fast', 'step = corpses 30 setup_corpses', 'step = drivefast 45 120 drive_corpses', 'step = corpses clear cleanup_corpses',
      'step = fight 6 30 fight_small', 'step = fight 40 60 fight_large', 'step = realfight 6 30 fight_swing', 'step = stress 500 60 stress_500'],
      'baseline: the phases in the 1.13.7 order (on foot, glides with the fog twin, car, fights, stress last)')
check('fastroad = 34,60,0' in bll and 'fastroad = 74,60,0' in bll, 'baseline: straight road for the real car, cut at the blocked square (75) and the parked car beside the line (33)')
check('treeroad = 30,60,0' in bll and 'treeroad = 80,60,0' in bll, 'baseline: tree-lined road found (the street with trees both sides)')
check(any('started baseline run' in l for l in out_lines()), 'baseline run started through the bridge')
L.execute('''
local n = 0
maxZ, sweptDuringFight = 0, false
while TestGround.isRunning() and n < 400000 do
  n = n + 1
  clock = clock + ((n % 700 == 0) and 120 or 16)
  if #ZOMBIES > maxZ then maxZ = #ZOMBIES end
  stepWalk(); stepZombies(); stepCar(((n % 700 == 0) and 120 or 16) / 1000); fire("OnTick")
end
blTicks = n
''')
check(L.eval('TestGround.isRunning()') is False, 'baseline run finishes (%d ticks)' % L.eval('blTicks'))
o = out_lines()
done = [l for l in o if l.startswith('=== done TestGround_baseline_')]
check(len(done) == 1 and '_perf.txt' in done[0] and '_spikes.txt' in done[0], 'done line names the perf and spikes files')
files = L.eval('FILES')
rname = [k for k in files.keys() if str(k).startswith('TestGround_baseline_') and str(k).endswith('.txt') and not str(k).endswith(AUX)][0]
rep_l = [files[rname][i] for i in range(1, len(files[rname]) + 1)]
btext = '\n'.join(rep_l)
trn = rname[:-4] + '_trace.txt'
btr = [files[trn][i] for i in range(1, len(files[trn]) + 1)]
import re as _re
print('--- baseline report (steps) ---'); print('\n'.join(l for l in rep_l if l.startswith('== '))); print('---')
print('\n'.join(l for l in btr if ' loot ' in l or 'drive turned' in l or 'fight:' in l or ('drivefast' in l and ' tiles to go' not in l)))
check(btext.count('== pass ') == 16 and 'SKIPPED' not in btext, 'baseline: sixteen steps, none skipped')
check('500 of 500 spawned' in btext and 'up to 500 alive' in btext and "can't-die mode held" in btext and '500 removed' in btext, 'stress: 500 spawned in batches, can\'t-die mode held, all removed')
check(_re.search(r'fight_swing \(30 s\), 6 spawned, [1-9]\d* swings \(Base\.BaseballBat \(Baseball Bat\) via AttemptAttack, ', btext) is not None and _re.search(r'[1-9]\d* killed by you', btext) is not None and 'ATTACK INPUT FAILED' not in btext, 'real fight: aimed swings through AttemptAttack, zombies killed by the player')
check(L.eval('DRAGOFF or 0') >= 1 and L.eval('SANDBOX["ZombieLore.ZombiesDragDown"]') is True, 'drag-down: off during the run, restored after')
print([l for l in btext.split('\n') if 'fight_real' in l][:2])
check('weather fog (0 s), weather now fog' in btext and 'weather clear (0 s), weather now clear' in btext, 'weather steps switch fog on and off')
check('passes of the tree road' in btext, 'baseline: drive_trees went back and forth on the tree road')
check(btext.count('back at the start') == 3, 'baseline: all three drives end back at the start')
check('6 spawned' in btext and '40 spawned' in btext, 'baseline: fights spawn 6 and 40 zombies')
check(L.eval('maxZ') >= 40, 'baseline: the large fight had 40 zombies at once (max %d)' % L.eval('maxZ'))
pd = [int(m.group(1)) for m in _re.finditer(r'(\d+) put down', btext)]
check(len(pd) == 2 and all(n > 0 for n in pd), 'baseline: zombies put down in both fights %s' % pd)
check('2 of 2 containers reached (1 by teleport), 7 items seen, 5 moved out and back' in btext, 'baseline: loot step reached both containers, one by teleport')
check(L.eval('#CRATE1.items') == 5 and L.eval('#CRATE2.items') == 2 and L.eval('#INV.items') == 0, 'baseline: loot put back')
check(L.eval('TRANSFERS') == 10, 'baseline: 10 transfers (5 out, 5 back)')
perf = files['TestGround_perf_latest.txt']; perf = [perf[i] for i in range(1, len(perf) + 1)]
spk = files['TestGround_spikes_latest.txt']; spk = [spk[i] for i in range(1, len(spk) + 1)]
check(perf[0].startswith('run_s,pass,step,phase') and len(perf) > 100, 'perf csv: header and one row a second (%d rows)' % (len(perf) - 1))
phases = []
for l in perf[1:]:
    ph = l.split(',')[3]
    if not phases or phases[-1] != ph: phases.append(ph)
check(phases == ['walk', 'loot', 'glide_south', 'glide_north', 'glide_fog', 'glide_trees', 'drive_fast', 'setup_corpses', 'drive_corpses', 'cleanup_corpses', 'fight_small', 'fight_large', 'fight_swing', 'stress_500'], 'perf csv: rows tagged by phase in order %s' % phases)
check(len(spk) > 5 and all(',120,' in l for l in spk[1:]), 'spikes csv: the injected 120 ms frames, nothing else (%d)' % (len(spk) - 1))
print('marks', list(L.eval('MARKS').values()))
print('MARKS', list(L.eval('MARKS').values())[:16])
check(list(L.eval('MARKS').values())[:14] == ['walk', 'loot', 'glide_south', 'glide_north', 'fog', 'glide_fog', 'clear', 'glide_trees', 'drive_fast', 'setup_corpses', 'drive_corpses', 'cleanup_corpses', 'fight_small', 'fight_large'], 'profiler mark() called per phase')
check(files['TestGround_report_latest.txt'] is not None, 'latest report copy written')
check("FALLBACK glide (leg 1 ended (end of road) at only" in btext and 'too short to reach 60' in btext and L.eval('P.vehicle') is None, 'drive_fast on the 41-tile mock street: too short for 60 km/h, so it glides and says why')
check(L.eval('#ZOMBIES') == 0, 'baseline: no zombies left after the run')
check(abs(L.eval('P.x') - 50.5) < 0.01 and L.eval('P.ghost') is False, 'baseline: back home, ghost mode off')
L.execute('LuaEventProfiler.mark = nil')
print('--- perf csv (first 4 rows) ---'); print('\n'.join(perf[:4])); print('--- spikes (first 3) ---'); print('\n'.join(spk[:3])); print('---')

# 1.5.1: a fight that puts nothing down is stopped; with no god mode, fights are skipped.
L.execute('FREEZE = true; ZOMBIES = {}; P.x, P.y = 50.5, 50.5; FILES["TestGround_out.txt"] = {}')
L.execute('FILES["TestGround_fz.txt"] = {"label = fz", "settle = 1", "start = 50,50,0", "zombies = none", "step = fight 6 30 fight_small"}')
bridge('run TestGround_fz.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; stepWalk(); stepZombies(); fire("OnTick") end
fzTicks = n
""")
files = L.eval('FILES')
def report_of(prefix):
    ks = [str(k) for k in files.keys() if str(k).startswith(prefix) and str(k).endswith('.txt') and not str(k).endswith(AUX)]
    k = max(ks, key=lambda n: (len(n), n))   # the newest report (names end in a growing number)
    return '\n'.join(files[k][i] for i in range(1, len(files[k]) + 1))
fz = report_of('TestGround_fz_')
print([l for l in fz.split('\n') if l.startswith('== ')])
check('ABORTED after 15 s: none put down, none came within reach' in fz and L.eval('#ZOMBIES') == 0, 'fight with nothing in reach is aborted at 15 s and its zombies removed')
L.execute('FREEZE = false; ROLE.locked = true; CHEATS_BROKEN = true; FILES["TestGround_out.txt"] = {}')
L.execute('FILES["TestGround_ng.txt"] = {"label = ng", "settle = 1", "start = 50,50,0", "zombies = none", "step = fight 6 30 fight_small"}')
SPAWNED_BEFORE_NG = L.eval('spawned')
bridge('run TestGround_ng.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; stepWalk(); stepZombies(); fire("OnTick") end
""")
files = L.eval('FILES')
ng = report_of('TestGround_ng_')
check('god COULD NOT be turned on' in ng and 'guarded (no god mode; ' in ng and 'ABORTED' not in ng and L.eval('spawned') > SPAWNED_BEFORE_NG and L.eval('P.scratched or 0') == 0, 'no god mode: header says so and the fight runs guarded, player never touched: %s' % [l for l in ng.split('\n') if l.startswith('== ')])
def ng_run(hook=''):
    L.execute('FILES["TestGround_out.txt"] = {}')
    bridge('run TestGround_ng.txt')
    L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; stepWalk(); stepZombies(); %s fire("OnTick") end
""" % hook)
    fl = L.eval('FILES')
    ks = sorted([k for k in fl.keys() if str(k).startswith('TestGround_ng_') and str(k).endswith('.txt') and not str(k).endswith(AUX)], key=lambda k: int(__import__('re').search(r'_(\d+)\.txt$', k).group(1)))
    return '\n'.join(fl[ks[-1]][i] for i in range(1, len(fl[ks[-1]]) + 1))
# guarded, but put-down silently does nothing: stopped before anything reaches the player
L.execute('NOKILL = true; HEALED = 0; P.scratched = 0')
rt = ng_run()
L.execute('NOKILL = false')
check('guarded, ABORTED after' in rt and 'is still up, so a guarded fight isn' in rt and L.eval('P.scratched') == 0 and L.eval('#ZOMBIES') == 0, 'guarded fight: a put-down that does not take stops it before any contact: %s' % [l for l in rt.split('\n') if 'ABORTED' in l])
# guarded, and the player gets hurt anyway: zombies removed, player healed
rt = ng_run('if n == 150 then P.scratched = 1 end;')
check('guarded, ABORTED after' in rt and 'player hurt (1 parts scratched), zombies removed, player healed' in rt and L.eval('HEALED') >= 1 and L.eval('P.scratched') == 0 and L.eval('#ZOMBIES') == 0, 'guarded fight: a wound stops it, removes zombies, heals: %s' % [l for l in rt.split('\n') if 'ABORTED' in l])
L.execute('ROLE.locked = false')
# 1.7.1: once a god-mode call throws (each throw prints a stack trace and counts an error on screen),
# none is made again this session, even with a role that would allow it
rt = ng_run()
check('guarded (no god mode; ' in rt and L.eval('CHEAT_THROWS') == 1 and L.eval('ROLE.caps.ToggleGodModHimself') is None, 'god mode: one refused call per session, then no more tries (%d throws over 4 runs)' % L.eval('CHEAT_THROWS'))
L.execute('CHEATS_BROKEN = false; TestGround.resetGodProbe()')
# 1.8.1: outside debug mode no god-mode call is made at all (each throw prints a stack trace in game)
L.execute('DEBUGMODE = false; CHEATS_BROKEN = true; CHEAT_THROWS = 0; TestGround.resetGodProbe()')
rt = ng_run()
check('guarded (no god mode; ' in rt and L.eval('CHEAT_THROWS') == 0, 'not in debug mode: no god-mode call made, fights guarded (%d throws)' % L.eval('CHEAT_THROWS'))
L.execute('DEBUGMODE = true; CHEATS_BROKEN = false; TestGround.resetGodProbe()')

# 1.5.5: skip phases by name (Autorun's flag sets TestGround.skip; a plan can say "skip =" too).
L.execute('FILES["TestGround_sk.txt"] = {"label = sk", "settle = 1", "start = 50,50,0", "zombies = none", "step = idle 3 still", "step = fight 6 30 fight_small", "step = fight 12 30 fight_large"}')
L.execute('TestGround.skip = "fight_small, Fight_Large"')
SPAWNED_BEFORE_SK = L.eval('spawned')
bridge('run TestGround_sk.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; stepWalk(); stepZombies(); fire("OnTick") end
""")
L.execute('TestGround.skip = nil')
files = L.eval('FILES')
sk = report_of('TestGround_sk_')
check(sk.count('== pass ') == 1 and 'plan step 2: fight 6 30 fight_small SKIPPED: skipped by flag' in sk and 'plan step 3: fight 12 30 fight_large SKIPPED: skipped by flag' in sk and L.eval('spawned') == SPAWNED_BEFORE_SK, 'skip flag leaves out both fights and says so, nothing spawned: %s' % [l for l in sk.split('\n') if 'SKIPPED' in l or l.startswith('== ')])
L.execute('FILES["TestGround_sk.txt"] = {"label = sk2", "settle = 1", "skip = fight", "step = fight 6 30 fight_small"}')
r = bridge('run TestGround_sk.txt')
check(not L.eval('TestGround.isRunning()'), 'plan "skip = fight" (a kind) with only fights: no run starts')
# 1.13.8: an old step name in a skip flag means the renamed step
L.execute('FILES["TestGround_sk3.txt"] = {"label = sk3", "settle = 1", "start = 50,50,0", "zombies = none", "step = idle 3 still", "step = fight 6 30 fight_swing"}')
L.execute('TestGround.skip = "fight_real"')
bridge('run TestGround_sk3.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; stepWalk(); stepZombies(); fire("OnTick") end
""")
L.execute('TestGround.skip = nil')
files = L.eval('FILES')
sk3 = report_of('TestGround_sk3_')
check('fight 6 30 fight_swing SKIPPED: skipped by flag' in sk3 and 'old step names taken as the new ones: fight_real (now fight_swing)' in sk3, 'skip flag: an old step name skips the renamed step and the report says so')
# 1.13.9: a skip name that matches no step is reported, not dropped silently
L.execute('FILES["TestGround_sk4.txt"] = {"label = sk4", "settle = 1", "start = 50,50,0", "zombies = none", "step = idle 3 still"}')
L.execute('TestGround.skip = "nosuchstep"')
bridge('run TestGround_sk4.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; stepWalk(); stepZombies(); fire("OnTick") end
""")
L.execute('TestGround.skip = nil')
files = L.eval('FILES')
sk4 = report_of('TestGround_sk4_')
check('skip: NO STEP MATCHES nosuchstep' in sk4, 'skip flag: a name that matches nothing is reported: %s' % [l for l in sk4.split('\n') if 'skip' in l])

# drive_fast on a long road: the real (fake) car passes 60 km/h, lines up every leg, no fallback.
L.execute('CAR = nil; P.vehicle = nil; CARS_REMOVED = 0; ALIGN_CALLS = 0; MAXV = 0; FILES["TestGround_out.txt"] = {}')
L.execute('FILES["TestGround_long.txt"] = {"label = long", "settle = 1", "start = 50,50,0", "step = drivefast 90 drive_fast", "fastroad = 30,90,0", "fastroad = 230,90,0"}')
bridge('run TestGround_long.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
""")
files = L.eval('FILES')
def rep_and_trace(prefix):
    ks = [str(k) for k in files.keys() if str(k).startswith(prefix) and str(k).endswith('.txt') and not str(k).endswith(AUX)]
    k = max(ks, key=lambda n: (len(n), n))   # the newest report (names end in a growing number)
    t = k[:-4] + '_trace.txt'
    return '\n'.join(files[k][i] for i in range(1, len(files[k]) + 1)), [files[t][i] for i in range(1, len(files[t]) + 1)]
btext, btr = rep_and_trace('TestGround_long_')
print([l for l in btext.split('\n') if l.startswith('== ')])
mlegs = _re.search(r'real car Base\.SportsCar, (\d+) legs, (\d+) tiles, peak ([\d.]+) tiles/s', btext)
check(mlegs is not None and 'FALLBACK' not in btext, 'drive_fast: drove the real (fake) car, no fallback')
check(mlegs is not None and int(mlegs.group(1)) >= 3 and float(mlegs.group(3)) > 10, 'drive_fast: 3+ legs, peak over 10 tiles/s %s' % (mlegs and mlegs.groups(),))
check('COULD NOT LINE UP' not in btext and L.eval('ALIGN_CALLS') > 0, 'drive_fast: lined up with setAngles (%d calls)' % L.eval('ALIGN_CALLS'))
check(any('forward map 7' in l for l in btr), 'drive_fast: worked out the forward-vector mapping from the creep')
offs = [float(m.group(1)) for m in _re.finditer(r'off by ([\d.]+) deg', '\n'.join(btr))]
check(len(offs) >= 3 and max(offs) < 2.0, 'drive_fast: every leg lined up within 2 degrees %s' % offs)
lat = _re.search(r"up to ([\d.]+) tiles off the street's centre", btext)
check(lat is not None and float(lat.group(1)) < 1.5, 'drive_fast: stayed on the road line (%s)' % (lat and lat.group(1)))
uturns = _re.search(r'(\d+) turned back', btext)
check(uturns is not None and int(uturns.group(1)) >= 1 and L.eval('CARS_REMOVED') == int(uturns.group(1)) + 1 and L.eval('P.vehicle') is None, 'drive_fast: a fresh car facing back at each end of the road (%s), all removed, out of the car' % (uturns and uturns.group(1)))
check(L.eval('MAXV') * 3.6 <= 150 + 1, 'drive_fast: cruise held at or under the car top speed')
check(L.eval('MAXV') * 3.6 >= 60, 'drive_fast: the car passed 60 km/h (%.0f)' % (L.eval('MAXV') * 3.6))
traces = [l for l in btr if 'to the next stop' in l]
gaps = [float(traces[i+1].split()[0]) - float(traces[i].split()[0]) for i in range(len(traces) - 1)]
check(len(traces) > 5 and min(gaps) > 0.4, 'drive_fast: one progress line every half second, no repeats')

# drive_fast into something on the road: the car stops dead, the step says so and glides instead.
L.execute('CAR = nil; P.vehicle = nil; CARWALL = 60; FILES["TestGround_out.txt"] = {}')
bridge('run TestGround_long.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
CARWALL = nil
""")
files = L.eval('FILES')
ks = sorted([k for k in files.keys() if str(k).startswith('TestGround_long_') and str(k).endswith('.txt') and not str(k).endswith(AUX)], key=lambda k: int(_re.search(r'_(\d+)\.txt$', k).group(1)))
ctext = '\n'.join(files[ks[-1]][i] for i in range(1, len(files[ks[-1]]) + 1))
print([l for l in ctext.split('\n') if l.startswith('== ')])
check('FALLBACK glide (car stuck at' in ctext and 'after 3 fresh cars in a row' in ctext and 'blocked by something on the road' in ctext and L.eval('P.vehicle') is None, 'drive_fast: a car that stays stuck gets 3 fresh cars, then the glide, and says where')
_tr = list(files[ks[-1][:-4] + '_trace.txt'].values())
_sk = [int(m.group(1)) for l in _tr for m in [_re.search(r'a fresh car (\d+) tiles further on', l)] if m]
check(_sk[:3] == [15, 30, 60], 'drive_fast: each fresh car is in the trace, further on each time (%s)' % _sk)
check(any(('drivefast: stuck' in l and 'in front of the car:' in l) for l in _tr), 'drive_fast: a stuck car says what is in front of it')
# one thing in the way: a fresh car past it, and the drive goes on without a glide
L.execute('CAR = nil; P.vehicle = nil; CARWALL = 60; CARWALL_END = 63; FILES["TestGround_out.txt"] = {}')
bridge('run TestGround_long.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
CARWALL = nil; CARWALL_END = nil
""")
files = L.eval('FILES')
ks = sorted([k for k in files.keys() if str(k).startswith('TestGround_long_') and str(k).endswith('.txt') and not str(k).endswith(AUX)], key=lambda k: int(_re.search(r'_(\d+)\.txt$', k).group(1)))
ctext = '\n'.join(files[ks[-1]][i] for i in range(1, len(files[ks[-1]]) + 1))
print([l for l in ctext.split('\n') if l.startswith('== ')])
check('FALLBACK' not in ctext and _re.search(r'([1-9]\d*) fresh cars after getting stuck', ctext) is not None, 'drive_fast: one obstacle, a fresh car past it each time, no glide')

# drive_fast falls back to a glide at top speed when there is no car to spawn.
L.execute('NOCAR = true; CAR = nil; P.vehicle = nil; FILES["TestGround_out.txt"] = {}')
L.execute('FILES["TestGround_fast.txt"] = {"label = fast", "settle = 1", "start = 50,50,0", "step = drivefast 10 drive_fast", "fastroad = 30,60,0", "fastroad = 80,60,0"}')
bridge('run TestGround_fast.txt')
L.execute('''
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
''')
files = L.eval('FILES')
fname = [k for k in files.keys() if str(k).startswith('TestGround_fast_') and str(k).endswith('.txt') and not str(k).endswith(AUX)][0]
ftext = '\n'.join(files[fname][i] for i in range(1, len(files[fname]) + 1))
check('FALLBACK glide (could not spawn a car' in ftext and 'at 33 tiles/s' in ftext, 'drive_fast: no car -> glide at about 120 km/h, and says why')
check(L.eval('P.ghost') is False and L.eval('P.vehicle') is None, 'drive_fast fallback: ghost mode off afterwards')
L.execute('NOCAR = false')

# Stopping a run mid-drive gets you out of the car and removes it.
L.execute('CARS_REMOVED = 0; FILES["TestGround_out.txt"] = {}')
bridge('run TestGround_fast.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 400 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
inCarMid = P.vehicle ~= nil
TestGround.stop("test stop")
""")
check(L.eval('inCarMid') is True and L.eval('P.vehicle') is None and L.eval('CARS_REMOVED') == 1, 'drive_fast: a stopped run leaves the car and removes it')

dump = os.environ.get('TG_DUMP')
if dump:
    for name in (report_name[0], trace_name[0]):
        with open(os.path.join(dump, name), 'w') as fh:
            fh.write('\n'.join([files[name][i] for i in range(1, len(files[name]) + 1)]) + '\n')

# 1.7.0: the real-car drive on a long road from the game's map.
ROADS = os.path.join(HERE, 'TestGround/42/media/lua/shared/TestGroundRoads.lua')
L.execute(open(ROADS, encoding='utf-8').read())
mr = L.eval('TestGround.mapRoad(12090, 6736)')
check(mr is not None and mr.name == 'Main St' and (mr.ax, mr.ay, mr.bx, mr.by, mr.len) == (12114, 6900, 10891, 6900, 1223), 'map roads: near the Lumberjack start the pick is Main St, 1223 tiles, starting at its near end')
check(L.eval('TestGround.mapRoad(50, 50)') is None, 'map roads: nothing picked when every road is over 3000 tiles away')
L.execute('TestGround.mapRoads = { { "Mock Road", 8, 1000, 302, 1700, 302 } }')
mr2 = L.eval('TestGround.mapRoad(900, 250)')
check(mr2 is not None and mr2.name == 'Mock Road' and mr2.ax == 1000, 'map roads: a custom list can be used (TestGround.mapRoads)')
# the drive: the road is 950 tiles from the start and only loads after the teleport, the map's line
# is 1.5 tiles off the real street, the car drifts, and a wreck sits on the road
L.execute("""CAR = nil; P.vehicle = nil; MAXV = 0; MAPST = true; FARHIDE = true; CARDRIFT = 0.8
WRECKAT = "1400,304,0"
VEHSQ[WRECKAT] = { x = 1400.5, y = 304.5, getScript = function() return { getName = function() return "CarWreck" end } end }
VEHSQ[WRECKAT].permanentlyRemove = function() VEHSQ[WRECKAT].gone = true; VEHSQ[WRECKAT] = nil end
FILES["TestGround_out.txt"] = {}
FILES["TestGround_map.txt"] = {"label = map", "settle = 1", "start = 50,50,0", "step = drivefast 120 drive_fast", "fastname = Mock Road", "fastwidth = 8", "fastroad = 1000,302,0", "fastroad = 1700,302,0"}""")
bridge('run TestGround_map.txt')
L.execute("""
local n = 0
maxLat = 0
while TestGround.isRunning() and n < 40000 do
  n = n + 1; clock = clock + 16
  if n == 150 then FARHIDE = false end
  stepWalk(); stepCar(0.016); fire("OnTick")
  if CAR and P.vehicle == CAR and CAR.speed > 20 then maxLat = math.max(maxLat, math.abs(CAR.py - 304)) end
end
CARDRIFT = nil; MAPST = false; WRECKAT = nil
""")
files = L.eval('FILES')
mtext, mtr = rep_and_trace('TestGround_map_')
print([l for l in mtext.split('\n') if l.startswith('== ')])
check('Mock Road (700-tile road from the map, loaded in' in mtext and 'FALLBACK' not in mtext, 'map road: the far road loads after the teleport and the real car drives it')
check('top speed REACHED' in mtext and L.eval('MAXV') * 3.6 >= 140, 'map road: the car reaches its top speed (%.0f km/h)' % (L.eval('MAXV') * 3.6))
check('1 vehicles cleared off the road' in mtext and any('took CarWreck off the road at 1400,304' in l for l in mtr), 'map road: the wreck on the road is taken off before the car gets there')
check(any('centre 1.5 tiles off the line' in l for l in mtr), 'map road: lines up with the real street, not the map line')
mst = _re.search(r'(\d+) steering nudges', mtext)
check(mst is not None and (int(mst.group(1)) > 0 or 'torque steering on' in mtext) and L.eval('maxLat') < 3.0, 'map road: steering keeps the drifting car on the street (%s nudges, up to %.1f tiles off)' % (mst and mst.group(1), L.eval('maxLat')))
check(any('waiting ' in l and 'the far road end to load' in l for l in mtr), 'map road: the stall line names the road loading')
# the survey writes the map road into the baseline plan, with the longer step
L.execute('P.x, P.y, P.z = 50.5, 50.5, 0; FILES["TestGround_baseline.txt"] = nil; TestGround.mapRoutes = {}; TestGround.mapRoads = { { "Mock Road", 8, 1000, 302, 1700, 302 } }')
bridge('baseline 30 here')
L.execute("""
local n = 0
while n < 100 and not (FILES["TestGround_baseline.txt"]) do n = n + 1; clock = clock + 16; fire("OnTick") end
TestGround.stop("test stop")
TestGround.mapRoads = nil
""")
bl2 = L.eval('FILES["TestGround_baseline.txt"]')
bl2 = [bl2[i] for i in range(1, len(bl2) + 1)] if bl2 else []
check('fastname = Mock Road' in bl2 and 'fastwidth = 8' in bl2 and 'fastroad = 1000,302,0' in bl2 and 'fastroad = 1700,302,0' in bl2 and 'step = drivefast 120 120 drive_fast' in bl2, 'survey: a road from the map goes into the baseline plan, with a 120 s drive')

# 1.8.0: a whole street from the map, with corners, for 5 to 10 times the ground.
L.execute(open(ROADS, encoding='utf-8').read())
L.execute('TestGround.mapRoutes = nil; TestGround.mapRoads = nil')
rt0 = L.eval('TestGround.mapRoute(12090, 6736)')
check(rt0 is not None and rt0.name == 'Dixie Highway (Route 31W)' and rt0.len == 3600 and rt0.dist < 400, 'map route: near the Lumberjack start it is Dixie Highway, 3600 tiles (%s, %s tiles, %s away, %s corners)' % (rt0 and rt0.name, rt0 and rt0.len, rt0 and rt0.dist, rt0 and rt0.corners))
# drive a mock route: 700 tiles east, a right-angle corner, 600 tiles south; the map line is off by 1.5
L.execute("""CAR = nil; P.vehicle = nil; MAXV = 0; MAPST = true; MAPST2 = true; FARHIDE = false; CARDRIFT = 0.5; CARS_REMOVED = 0
FILES["TestGround_out.txt"] = {}
FILES["TestGround_route.txt"] = {"label = route", "settle = 1", "start = 50,50,0", "step = drivefast 150 drive_fast", "fastname = Mock Route", "fastwidth = 8", "fastroad = 1000,302,0", "fastroad = 1700,302,0", "fastroad = 1700,900,0"}""")
bridge('run TestGround_route.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 40000 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
CARDRIFT = nil; MAPST = false; MAPST2 = false
""")
files = L.eval('FILES')
rtext, rtr = rep_and_trace('TestGround_route_')
print([l for l in rtext.split('\n') if l.startswith('== ')])
mt = _re.search(r'(\d+) legs, (\d+) tiles', rtext)
check('FALLBACK' not in rtext and _re.search(r'[1-9]\d* corners', rtext) is not None and mt is not None and int(mt.group(2)) >= 1200, 'map route: drives round the corner and on down the second street (%s tiles)' % (mt and mt.group(2)))
check('top speed REACHED' in rtext, 'map route: top speed on the long pieces')
check(any('braking (corner)' in l for l in rtr) and any('braking (end of road)' in l for l in rtr), 'map route: brakes for the corner and for the end')
# the survey writes the route, with time for it
L.execute('P.x, P.y, P.z = 50.5, 50.5, 0; FILES["TestGround_baseline.txt"] = nil; TestGround.mapRoutes = { { "Mock Route", 8, { 1000, 302, 1700, 302, 1700, 2302 } } }')
bridge('baseline 30 here')
L.execute("""
local n = 0
while n < 100 and not (FILES["TestGround_baseline.txt"]) do n = n + 1; clock = clock + 16; fire("OnTick") end
TestGround.stop("test stop")
TestGround.mapRoutes = nil
""")
bl3 = L.eval('FILES["TestGround_baseline.txt"]')
bl3 = [bl3[i] for i in range(1, len(bl3) + 1)] if bl3 else []
fr3 = [l for l in bl3 if l.startswith('fastroad = ')]
st3 = [l for l in bl3 if l.startswith('step = drivefast')]
check('fastname = Mock Route' in bl3 and len(fr3) >= 3 and st3 and int(st3[0].split()[3]) > 120, 'survey: a whole street from the map goes into the plan with its corners and time for it (%s, %s)' % (fr3, st3))

# 1.8.0: zoomed out to the maximum during a run, and again after something zooms back in
L.execute('ZTARGET = 1.0; FILES["TestGround_zm.txt"] = {"label = zm", "settle = 1", "start = 50,50,0", "zombies = none", "step = idle 8 still"}')
bridge('run TestGround_zm.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; if n == 300 then ZTARGET = 0.75 end; fire("OnTick") end
""")
files = L.eval('FILES')
zt, ztr = rep_and_trace('TestGround_zm_')
check('zoom: 1.00 at the start, kept at the maximum 2.00' in zt and L.eval('ZTARGET') == 2.0 and any('back out to 2.00' in l for l in ztr), 'zoom: out to the maximum, and back out after a zoom in')

# 1.8.0: the fixed test start. The survey goes there, waits for it to load, and the plan names it.
L.execute('TestGround.spots.mock = { name = "Mock Spot", x = 50, y = 50, z = 0 }; P.x, P.y, P.z = 10.5, 10.5, 0; FILES["TestGround_baseline.txt"] = nil; FILES["TestGround_out.txt"] = {}')
L.execute('UNLOADED["50,50,0"] = true')
bridge('baseline 30 mock')
L.execute("""
local n = 0
while n < 200 do n = n + 1; clock = clock + 16; fire("OnTick") end
""")
check(L.eval('FILES["TestGround_baseline.txt"]') is None and abs(L.eval('P.x') - 50.5) < 0.01, 'fixed start: teleported there, survey waits while it is not loaded')
L.execute("""
UNLOADED["50,50,0"] = nil
local n = 0
while n < 400 and not FILES["TestGround_baseline.txt"] do n = n + 1; clock = clock + 16; fire("OnTick") end
""")
bl4 = L.eval('FILES["TestGround_baseline.txt"]')
bl4 = [bl4[i] for i in range(1, len(bl4) + 1)] if bl4 else []
outl = out_lines()
check(any(l.startswith('start = mock ') and 'Mock Spot' in l for l in bl4) and any('survey done at Mock Spot (Mock Spot loaded after' in l for l in outl), 'fixed start: plan says "start = mock", summary says where (%s)' % [l for l in bl4 if l.startswith('start')])
L.execute('TestGround.stop("test stop")')
# a run whose start isn't loaded waits for it, and counts the settle from there
L.execute('P.x, P.y = 10.5, 10.5; UNLOADED["50,50,0"] = true; FILES["TestGround_sp.txt"] = {"label = sp", "settle = 1", "start = mock", "zombies = none", "step = idle 3 still"}')
bridge('run TestGround_sp.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; if n == 300 then UNLOADED["50,50,0"] = nil end; fire("OnTick") end
""")
files = L.eval('FILES')
spt = report_of('TestGround_sp_')
check('start 50,50,0 (Mock Spot, fixed test start)' in spt and 'start loaded after 4.' in spt, 'run at a fixed start: header names it, waits for it to load: %s' % [l for l in spt.split('\n') if l.startswith('start')])
L.execute('TestGround.spots.mock = nil')

# 1.8.0: the natural zombie zone. The survey wrote it from the map's intensity (hot spot at 150,90).
nat = L.eval('FILES["TestGround_natural.txt"]')
natl = [nat[i] for i in range(1, len(nat) + 1)] if nat else []
zl = [l for l in natl if l.startswith('zone = ')]
zx, zy = (int(v) for v in zl[0].split('=')[1].strip().split(',')[:2]) if zl else (0, 0)
check(zl and abs(zx - 150) <= 24 and abs(zy - 90) <= 24 and 'zombies = keep' in natl and 'step = natural 90 run zone_run' in natl, 'natural zone: the densest spot on the map near the start, zombies kept (%s)' % zl)
L.execute('ZOMBIES = {}; for i = 1, 12 do newZombie(%d + 30 + (i %% 4) * 2, %d + math.floor(i / 4) * 2) end; FILES["TestGround_out.txt"] = {}; P.x, P.y = 50.5, 50.5; HEALED = 0' % (zx, zy))
bridge('run TestGround_natural.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 40000 do n = n + 1; clock = clock + 16; stepWalk(); stepZombies(); fire("OnTick") end
""")
files = L.eval('FILES')
nt = report_of('TestGround_natural_')
print([l for l in nt.split('\n') if l.startswith('== ')])
check('zone_stand (60 s), stood at' in nt and 'zone_run (90 s), ran ' in nt and 'zombie intensity there 0.' in nt and _re.search(r'up to (1[0-2]|[1-9]) zombies within 40 tiles', nt) is not None, 'natural zone: stood, then ran the ring, with the intensity and the zombies around')
check(L.eval('spawned') == L.eval('spawned') and 'put down as they came within 2.2 tiles' in nt and L.eval('P.scratched or 0') == 0, 'natural zone: guarded, player unhurt')

# 1.8.2: "can't die" for the whole run. Knocked down with zombies on you during any step: they're put down.
L.execute('ZOMBIES = {}; FILES["TestGround_dn.txt"] = {"label = dn", "settle = 1", "start = 50,50,0", "god = 0", "step = idle 6 still"}; P.x, P.y = 50.5, 50.5; P.down = true; P.scratched = 0')
bridge('run TestGround_dn.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; if n == 200 then for i = 1, 3 do newZombie(51 + i * 0.3, 50.5) end end; stepZombies(); fire("OnTick") end
P.down = false
""")
files = L.eval('FILES')
dt, dtr = rep_and_trace('TestGround_dn_')
check(any('zombies within 2.2 tiles put down (you were down)' in l for l in dtr) and all(z.health <= 0 for z in L.eval('ZOMBIES').values()), 'can\'t die: knocked down with zombies on you, they are put down (any step)')

# 1.8.3: the tree-lined road here is weak (0.4), so the survey visits rural roads from the map and
# takes the first with real trees, then comes back.
L.execute("""
for x = 190, 360 do OBJS[x .. ",296,0"] = { { isTree = true } }; OBJS[x .. ",304,0"] = { { isTree = true } } end
TestGround.mapTreeRoads = { { "Mock Field Road", 6, 120, 200, 270, 200 }, { "Mock Wood Road", 6, 200, 300, 350, 300 } }
FOREST = { { 190, 290, 360, 310 } }
P.x, P.y, P.z = 50.5, 50.5, 0; P.ghost = false; FILES["TestGround_baseline.txt"] = nil; FILES["TestGround_out.txt"] = {}
TestGround.K.TREE_GOOD = 0.5   -- the local mock road scores 0.4
""")
bridge('baseline 30 here')
L.execute("""
local n = 0
while n < 3000 and not FILES["TestGround_baseline.txt"] do n = n + 1; clock = clock + 16; fire("OnTick") end
TestGround.stop("test stop")
TestGround.mapTreeRoads = nil
""")
bl5 = L.eval('FILES["TestGround_baseline.txt"]')
bl5 = [bl5[i] for i in range(1, len(bl5) + 1)] if bl5 else []
outl = out_lines()
check('treeroad = 200,300,0' in bl5 and 'treeroad = 350,300,0' in bl5 and abs(L.eval('P.x') - 50.5) < 0.01 and L.eval('P.ghost') is False, 'tree road: weak here, so the wooded road from the map is visited, counted and used; back at the start, ghost off (%s)' % [l for l in bl5 if l.startswith('treeroad')])
print([l for l in outl if 'tree' in l][:3])

# 1.9.0: a 20-degree bend is taken on the move (slowed, steered by pure pursuit), not stopped at.
L.execute('CAR = nil; P.vehicle = nil; P.x, P.y = 50.5, 50.5; MAXV = 0; FILES["TestGround_out.txt"] = {}; CARDRIFT = 3')
bx, by = 1700 + int(600 * __import__('math').cos(__import__('math').radians(20))), 302 + int(600 * __import__('math').sin(__import__('math').radians(20)))
L.execute('FILES["TestGround_bend.txt"] = {"label = bend", "settle = 1", "start = 50,50,0", "step = drivefast 90 drive_fast", "steer = pursuit", "fastname = Mock Bend", "fastwidth = 8", "fastroad = 1000,302,0", "fastroad = 1700,302,0", "fastroad = %d,%d,0"}' % (bx, by))
bridge('run TestGround_bend.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 40000 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
CARDRIFT = nil
""")
files = L.eval('FILES')
bt, btr2 = rep_and_trace('TestGround_bend_')
print([l for l in bt.split('\n') if l.startswith('== ')])
ml = _re.search(r'up to ([\d.]+) tiles off', bt)
check('FALLBACK' not in bt and '0 corners' in bt and _re.search(r'[1-9]\d* bends taken on the move', bt) is not None and 'top speed REACHED' in bt and ml and float(ml.group(1)) < 3, 'bend: taken on the move at speed, pure pursuit keeps the car within 3 tiles of the centre (%s)' % (ml and ml.group(1)))
check(_re.search(r'^drive: left the street \d+ times, \d+ steered back from the edge, \d+ legs cut short, \d+ fresh cars, \d+ tries on the same car, \d+ knocks, \d+ wreck jams, \d+ tiles in the car, no fallback; average [1-9]\d* km/h from the first car to the end \(\d+ s, fresh cars, tries and stops included\), [1-9]\d* km/h in the legs \(\d+ s\), [1-9]\d* km/h while moving; tuning 1\.13\.19$', bt, _re.M) is not None, 'drive line: each drive step says how often it left the street, how many fresh cars it took and its average speed: %s' % [l for l in bt.split('\n') if l.startswith('drive:')])


# 1.12.2: the steering sign can't be read on a stopped car and is the other way on a moving one:
# the check on the move must flip it, or the car drives off the street (the 1.9 to 1.11 drift).
L.execute('CAR = nil; P.vehicle = nil; P.x, P.y = 50.5, 50.5; MAXV = 0; FILES["TestGround_out.txt"] = {}; CARDRIFT = 3; MIRROR = true')
L.execute('FILES["TestGround_bend2.txt"] = {"label = bend2", "settle = 1", "start = 50,50,0", "step = drivefast 90 drive_fast", "steer = pursuit", "fastname = Mock Bend", "fastwidth = 8", "fastroad = 1000,302,0", "fastroad = 1700,302,0", "fastroad = %d,%d,0"}' % (bx, by))
bridge('run TestGround_bend2.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 40000 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
CARDRIFT = nil; MIRROR = nil
""")
bt2, btr3 = rep_and_trace('TestGround_bend2_')
ml = _re.search(r'up to ([\d.]+) tiles off', bt2)
btr3 = '\n'.join(btr3) if isinstance(btr3, list) else btr3
print([l for l in btr3.split('\n') if 'sign' in l][:5]); print(str(bt2)[:1500])
check('sign flipped' in btr3 and 'FALLBACK' not in bt2 and ml and float(ml.group(1)) < 5, 'steering sign wrong on the move: flipped by the check while driving, car stays on the street (%s)' % (ml and ml.group(1)))

# 1.13.10: the same bend with this build's steering numbers and with plan "drivetune = 1.13.9"
AB = {}
for tune in ('1.13.10', '1.13.9'):
    L.execute('CAR = nil; P.vehicle = nil; P.x, P.y = 50.5, 50.5; MAXV = 0; FILES = {}; CARDRIFT = 3; TQSCALE = 0.02')
    extra = ', "drivetune = 1.13.9"' if tune == '1.13.9' else ''
    L.execute('FILES["TestGround_ab.txt"] = {"label = ab", "settle = 1", "start = 50,50,0", "step = drivefast 90 drive_fast", "fastname = Mock Bend", "fastwidth = 8", "fastroad = 1000,302,0", "fastroad = 1700,302,0", "fastroad = %d,%d,0"%s}' % (bx, by, extra))
    bridge('run TestGround_ab.txt')
    L.execute("""
local n = 0
while TestGround.isRunning() and n < 40000 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
CARDRIFT = nil; TQSCALE = nil
""")
    files = L.eval('FILES')
    abt, _ = rep_and_trace('TestGround_ab_')
    dl = [l for l in abt.split('\n') if l.startswith('drive:')]
    mo = _re.search(r'up to ([\d.]+) tiles off', abt)
    AB[tune] = (dl[0] if dl else '', mo and mo.group(1))
    print('A/B', tune, 'max off', AB[tune][1], AB[tune][0])
_dl = open(os.path.join(HERE, 'TestGround/42/media/TestGround/drive_old.txt'), encoding='utf-8').read().split('\n')
L.execute('DOLD = {}')
for _l in _dl: L.execute('table.insert(DOLD, %r)' % _l)
L.execute('local pl = TestGround.parsePlan(DOLD); DOLD_T, DOLD_E, DOLD_N = pl.drivetune, #pl.errors, #pl.steps')
check(L.eval('DOLD_T') == '1.13.9' and L.eval('DOLD_E') == 0 and L.eval('DOLD_N') == 2, 'mod:drive_old: the drive check with drivetune = 1.13.9, no plan errors')
L.execute('local pl = TestGround.parsePlan({"label = pt", "step = build mod:shell2 300 setup_shell", "step = drive 60 20 glide_south"}); PT1 = TestGroundInternal.phaseOf(pl.steps[1]); PT2 = TestGroundInternal.phaseOf(pl.steps[2])')
check(L.eval('PT1') == 'setup_shell' and L.eval('PT2') == 'glide_south', 'phase tag: a plan reference (mod:shell2) is not the step name (%s, %s)' % (L.eval('PT1'), L.eval('PT2')))
check(AB['1.13.9'][0].endswith('tuning 1.13.9 (plan drivetune)') and AB['1.13.10'][0].endswith('tuning 1.13.19') and 'FALLBACK' not in AB['1.13.10'][0] + AB['1.13.9'][0],
      'drivetune: a plan can drive with the 1.13.9 steering numbers, and the drive line says which ran')

# 1.13.14 (1.13.11 mod:drive on the diagonal from 10681,8764): the centre past a bend is read there
# and taken at the bend, so a street whose offset from the map's line changes at the bend is followed
OFFB = {}
for tune in ('1.13.14', '1.13.9'):
    L.execute('CAR = nil; P.vehicle = nil; P.x, P.y = 50.5, 50.5; MAXV = 0; FILES = {}; CARDRIFT = 1; TQSCALE = 0.02; MAPOFF = true')
    extra = ', "drivetune = 1.13.9"' if tune == '1.13.9' else ''
    L.execute('FILES["TestGround_offb.txt"] = {"label = offb", "settle = 1", "start = 50,50,0", "step = drivefast 60 drive_fast", "fastname = Mock Offset", "fastwidth = 8", "fastroad = 1000,20302,0", "fastroad = 1700,20302,0", "fastroad = %d,%d,0"%s}' % (bx, by + 20000, extra))
    bridge('run TestGround_offb.txt')
    L.execute("""
local n = 0
while TestGround.isRunning() and n < 40000 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
CARDRIFT = nil; TQSCALE = nil; MAPOFF = nil
""")
    files = L.eval('FILES')
    obt, obtr = rep_and_trace('TestGround_offb_')
    dl = [l for l in obt.split('\n') if l.startswith('drive:')]
    OFFB[tune] = (dl[0] if dl else '', '\n'.join(obtr))
    print('OFFB', tune, OFFB[tune][0]); print([l for l in obtr if 'bend' in l or 'centre moved' in l][:6])
def _left(l):
    m = _re.search(r'left the street (\d+) times', l); return int(m.group(1)) if m else 99
def _fresh(l):
    m = _re.search(r'(\d+) fresh cars', l); return int(m.group(1)) if m else 99
check(_re.search(r'past the bend at \d+ tiles the centre is (8|9|10)\.\d tiles off the line \((1|2|3)\.\d before it', OFFB['1.13.14'][1]) is not None
      and _left(OFFB['1.13.14'][0]) == 0 and _fresh(OFFB['1.13.14'][0]) == 0 and (_left(OFFB['1.13.9'][0]) > 0 or _fresh(OFFB['1.13.9'][0]) > 0),
      'bend offset (1.13.14): the centre past the bend is read and taken there; no fresh car and never off the street, where 1.13.9 left it (%s | %s)' % (OFFB['1.13.14'][0][:120], OFFB['1.13.9'][0][:120]))

# 1.13.14 (1.13.11 drive_human at 10587,9449-9543: road works, 3 fresh cars): construction sprites on the
# centre are steered round within the carriageway
RW = {}
for tune in ('1.13.14', '1.13.9'):
    L.execute("""CAR = nil; P.vehicle = nil; P.x, P.y = 50.5, 50.5; MAXV = 0; FILES = {}; CARDRIFT = 1; TQSCALE = 0.02; MAPWORKS = true; BARRIERHIT = 0
BARRIER = {}
local function sp(n) return { getSprite = function() return { getName = function() return n end } end, getObjectName = function() return n end } end
for _, x in ipairs({ 1300, 1301, 1500, 1501 }) do for y = 40303, 40305 do BARRIER[x .. "," .. y] = true; OBJS[x .. "," .. y .. ",0"] = { sp("construction_01_8") } end end""")
    extra = ', "drivetune = 1.13.9"' if tune == '1.13.9' else ''
    L.execute('FILES["TestGround_rw.txt"] = {"label = rw", "settle = 1", "start = 50,50,0", "step = drivefast 45 drive_fast", "fastname = Mock Works", "fastwidth = 8", "fastroad = 1000,40302,0", "fastroad = 1700,40302,0"%s}' % extra)
    bridge('run TestGround_rw.txt')
    L.execute("""
local n = 0
while TestGround.isRunning() and n < 40000 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
CARDRIFT = nil; TQSCALE = nil; MAPWORKS = nil; BARRIER = nil
for _, x in ipairs({ 1300, 1301, 1500, 1501 }) do for y = 40303, 40305 do OBJS[x .. "," .. y .. ",0"] = nil end end""")
    files = L.eval('FILES')
    rwt, rwtr = rep_and_trace('TestGround_rw_')
    dl = [l for l in rwt.split('\n') if l.startswith('drive:')]
    RW[tune] = (dl[0] if dl else '', '\n'.join(rwtr), L.eval('BARRIERHIT'))
    print('RW', tune, RW[tune][2], RW[tune][0][:200]); print([l for l in rwtr if 'solid' in l or 'stuck' in l][:6])
def _tries(l):
    m = _re.search(r'(\d+) tries on the same car', l); return int(m.group(1)) if m else 99
check('something solid on the road ahead, steering' in RW['1.13.14'][1] and RW['1.13.14'][2] == 0 and _fresh(RW['1.13.14'][0]) == 0 and _tries(RW['1.13.14'][0]) == 0
      and (_fresh(RW['1.13.9'][0]) + _tries(RW['1.13.9'][0]) > 0),
      'road works (1.13.14): steered round within the carriageway, never hit, no tries or fresh cars, where 1.13.9 got stuck (%s | %s)' % (RW['1.13.14'][0][:150], RW['1.13.9'][0][:150]))

# 1.12.6: torque steering (the default) on the bend, with a push 30x weaker than the default mock,
# 30x stronger, and one that does nothing (it must hand the car back to the nudges)
for scale, label in ((0.02 / 30, 'weak'), (0.6, 'strong'), (0, 'none')):
    L.execute('CAR = nil; P.vehicle = nil; P.x, P.y = 50.5, 50.5; MAXV = 0; FILES = {}; CARDRIFT = 3; TQSCALE = %r' % scale)
    L.execute('FILES["TestGround_bendt.txt"] = {"label = bendt", "settle = 1", "start = 50,50,0", "step = drivefast 90 drive_fast", "fastname = Mock Bend", "fastwidth = 8", "fastroad = 1000,302,0", "fastroad = 1700,302,0", "fastroad = %d,%d,0"}' % (bx, by))
    bridge('run TestGround_bendt.txt')
    L.execute("""
local n = 0
while TestGround.isRunning() and n < 40000 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
CARDRIFT = nil; TQSCALE = nil
""")
    files = L.eval('FILES')
    btt, btrt = rep_and_trace('TestGround_bendt_')
    mlt = _re.search(r'up to ([\d.]+) tiles off', btt)
    mtq = _re.search(r'torque steering on [^"\n]*', btt)
    print(label, mtq and mtq.group(0), mlt and mlt.group(1), _re.findall(r'\d+ times steered back[^,]*|\d+ fresh cars after getting stuck|\d+ legs cut short', btt))
    if label == 'weak' and DEBUG_WEAK:
        print('\n'.join(l for l in btrt if 'drifting' in l or 'braking' in l or 'stuck' in l or 'street at' in l or 'off the centre,' in l)[:6000])
    if label == 'weak':
        # 1.12.10: a car drifting towards the edge of a bend is slowed and steered back, not left to hit the verge
        _bt = '\n'.join(btrt) if isinstance(btrt, list) else str(btrt)
        check('times steered back from the edge' in btt and 'steering back (slower: to 40 km/h past' in _bt and 'back on the centre' in _bt and mlt and float(mlt.group(1)) < 4,
              'bend, weak push: drifting car slowed and steered back to the centre; legs cut short at half the width (%s)' % (mlt and mlt.group(1)))
    if label == 'none':
        # 1.13.4: the hard limit is now 80% of the half-width (3.2 tiles here, was 3.5), so this mock car,
        # pushed sideways 3 tiles/s with a dead push, is cut on leg 1 after the hand-over; the hand-over
        # itself must still happen before the cut
        _nt = '\n'.join(btrt)
        _ho = _re.search(r'^ *([\d.]+) drivefast: torque steering turned the car only.*nudges from here', _nt, _re.M)
        _cut = _re.search(r'^ *([\d.]+) drivefast: (FALLBACK|.*legs? cut)', _nt, _re.M)
        check(_ho is not None and (_cut is None or float(_ho.group(1)) < float(_cut.group(1))), 'torque steering: a push that does nothing hands the car to the nudges before the leg is cut (%s, cut %s)' % (_ho and _ho.group(1), _cut and _cut.group(1)))
    else:
        check(mtq and 'HANDED BACK' not in btt and 'FALLBACK' not in btt and mlt and float(mlt.group(1)) < 6, 'torque steering, %s push: car stays on the street (%s; %s)' % (label, mlt and mlt.group(1), mtq and mtq.group(0)))


# 1.12.3: the fight keeps a standing zombie in the weapon's band (steps back when too close) and
# attacks a downed one from its head.
L.execute("""
local K = TestGround.K
ZOMBIES = {}; FREEZE = true; P.x, P.y = 300.5, 300.5; P.attackStarted = false; SWINGS = 0
newZombie(300.9, 300.5)
local r = { p = player }
local st = { swings = 0, backoffs = 0 }
st.lo, st.hi = 0.91, 1.15
for i = 1, 4 do K.holdAim(r.p, st) end
K.fightMove(r, st)
FT_SHOVE, FT_BACK0 = st.closeShoves or 0, st.backoffs
for i = 1, 20 do K.holdAim(r.p, st); K.fightMove(r, st) end
FT_BACK, FT_DIST, FT_SW = st.backoffs, math.abs(P.x - 300.9), st.swings
ZOMBIES = {}
newZombie(303.5, 300.5); local z = ZOMBIES[1]
z.prone = true
z.getForwardDirection = function() return { getX = function() return 1 end, getY = function() return 0 end } end
z.isOnBack = function() return true end
for i = 1, 80 do K.holdAim(r.p, st); K.fightMove(r, st) end
FT_HX, FT_FLOOR, FT_SW2 = P.x, st.floorTargets or 0, st.swings
-- a floor hit at 0.1 x the standing mean is the legs: the next swings go from the other end
st.standHits, st.standDmg = 4, 8
z.health = 100; SWINGS = 0; K.fightMove(r, st); K.floorHit(st, st.floorZ, 0.2)
for i = 1, 80 do K.holdAim(r.p, st); K.fightMove(r, st) end
FT_HX2, FT_NO = P.x, st.headNo
K.floorHit(st, st.floorZ, 6)
FT_YES = st.headYes
ZOMBIES = {}; FREEZE = nil
""")
check(L.eval('FT_SHOVE') == 1 and L.eval('FT_BACK0') == 0, 'fight: a zombie 0.4 tiles away is shoved off first (%d shoves, %d step-backs)' % (L.eval('FT_SHOVE'), L.eval('FT_BACK0')))
check(L.eval('FT_BACK') >= 1 and 0.9 <= L.eval('FT_DIST') <= 1.2 and L.eval('FT_SW') >= 1, 'fight: still too close after the shove: the player steps back into the bat band (%.2f tiles), then swings' % L.eval('FT_DIST'))
check(L.eval('FT_FLOOR') == 1 and abs(L.eval('FT_HX') - 302.75) < 0.1 and L.eval('FT_SW2') > L.eval('FT_SW'), "fight: a downed zombie is attacked standing on its head (on its back: head behind its facing, %.2f)" % L.eval('FT_HX'))
check(L.eval('FT_NO') == 1 and abs(L.eval('FT_HX2') - 304.25) < 0.1 and L.eval('FT_YES') == 1, "fight: a floor hit that does leg damage moves the player to the other end (%.2f, %s legs, %s head); 3x damage counts as the head" % (L.eval('FT_HX2'), L.eval('FT_NO'), L.eval('FT_YES')))

# 1.12.6: screenshot = N [kinds]: through the game's takeScreenshot(name), only in the listed steps
L.execute('SHOTS = {}; function takeScreenshot(n) table.insert(SHOTS, n) end')
L.execute('FILES["TestGround_shot.txt"] = {"label = shot", "settle = 1", "start = 50,50,0", "zombies = none", "screenshot = 1 idle", "step = idle 4 still", "step = walk 3 walkpart"}; P.x, P.y = 50.5, 50.5')
bridge('run TestGround_shot.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; stepWalk(); fire("OnTick") end
""")
files = L.eval('FILES')
shtext, _ = rep_and_trace('TestGround_shot_')
shots = list(L.eval('SHOTS').values())
check(3 <= len(shots) <= 4 and all('_still_' in n and n.endswith('.png') for n in shots) and 'screenshots: %d in Zomboid/Screenshots' % len(shots) in shtext, 'screenshot = 1 idle: one a second in the idle step only (%s)' % shots[:2])
L.execute('takeScreenshot = nil')

# 1.12.7: corpses along the fast road, then cleared again
L.execute('MAPST = true; NBODIES = 0; BODIES = {}')
L.execute('FILES["TestGround_corpse.txt"] = {"label = corpse", "settle = 1", "start = 50,50,0", "zombies = none", "corpselen = 200", "corpseband = 12", "step = corpses 3 corpse_lay", "step = idle 1 between", "step = corpses clear corpse_clear", "fastname = Mock Road", "fastroad = 1000,303,0", "fastroad = 1700,303,0"}; P.x, P.y = 50.5, 50.5')
bridge('run TestGround_corpse.txt')
L.execute("""
local n = 0
CORPSE_PEAK = 0
while TestGround.isRunning() and n < 60000 do n = n + 1; clock = clock + 16; fire("OnTick"); if NBODIES > CORPSE_PEAK then CORPSE_PEAK = NBODIES end end
""")
files = L.eval('FILES')
ctext, _ = rep_and_trace('TestGround_corpse_')
cl = [l for l in ctext.split('\n') if l.startswith('== ')]
print(cl)
mlaid = _re.search(r': (\d+) corpses in (\d+) chunks \((\d+) chunks got all 3', ctext)
mclr = _re.search(r'(\d+) taken off', ctext)
peak = L.eval('CORPSE_PEAK')
check(mlaid and int(mlaid.group(1)) == peak and int(mlaid.group(3)) >= int(mlaid.group(2)) - 2 and peak >= 3 * 60, 'corpses: 3 a chunk laid along 200 tiles of the road, off the street (%s, peak %d on the map)' % (mlaid and mlaid.groups(), peak))
onstreet = L.eval('(function() local n = 0 for k, l in pairs(BODIES) do local y = tonumber(k:match(",(%d+),")) if #l > 0 and y >= 300 and y <= 307 then n = n + 1 end end return n end)()')
check(onstreet == 0, 'corpses: none on the street itself (%d street squares with one)' % onstreet)
check(mclr and int(mclr.group(1)) == peak and L.eval('NBODIES') == 0, 'corpses clear: every corpse laid is taken off again (%s of %d, %d left)' % (mclr and mclr.group(1), peak, L.eval('NBODIES')))
check('corpse_lay' in ctext and 'corpse_clear' in ctext, 'corpses: step names are the phases, not "clear"')
L.execute('MAPST = nil')

# 1.12.7: a wreck that streams in after its row was cleared is caught by the second look
L.execute("""
local K = TestGround.K
local st = { removed = {}, wrecks = 0, width = 8, off = 0, z = 0, car = {} }
K.buildPath(st, { { x = 1000.5, y = 303.5 }, { x = 1700.5, y = 303.5 } })
LATE = { getScript = function() return { getName = function() return "CarWreck" end } end }
LATE.permanentlyRemove = function() LATE.gone = true; VEHSQ["1030,305,0"] = nil end
VEHSQ["1030,305,0"] = LATE
K.recheckAhead(st, 10, 1e9)
LATE_GONE, LATE_N = LATE.gone == true, st.lateWrecks or 0
""")
check(_v[0] and _v[1] and _v[0].group(1) == _v[1].group(1), 'split: the entry file and Core carry the same VERSION (%s)' % [v and v.group(1) for v in _v])
check(L.eval('LATE_GONE') and L.eval('LATE_N') == 1, 'drive: a wreck loaded after its row was cleared is taken off by the second look ahead')

# 1.12.11: the station step: put down a drying rack, open, close, move away, wait
L.execute(r'''
local function list(t) return { size = function() return #t end, get = function(_, i) return t[i + 1] end } end
ComponentType = { CraftBench = "CraftBench", DryingLogic = "DryingLogic", DryingCraftLogic = "DryingCraftLogic", FurnaceLogic = "FurnaceLogic" }
local function scr(name, comps) return { getFullName = function() return name end, containsComponent = function(_, c) return comps[c] == true end } end
STATION_SCRIPTS = { scr("Base.Workbench", { CraftBench = true }), scr("Base.DryingRackHide", { CraftBench = true }) }
local oldSM = getScriptManager
function getScriptManager()
  local sm = oldSM()
  sm.getAllGameEntities = function() return list(STATION_SCRIPTS) end
  sm.getGameEntityScript = function(_, n) for _, s in ipairs(STATION_SCRIPTS) do if s:getFullName() == n then return s end end return nil end
  return sm
end
STATIONS = {}
IsoThumpable = { new = function(cell, sq, sprite, n, t)
  local md = {}
  local o = { sq = sq, getModData = function() return md end }
  o.hasComponent = function(_, c) return o.script ~= nil and o.script:containsComponent(c) end
  o.isValidEngineEntity = function() return o.inWorld == true end
  o.getUsingPlayer = function() return o.user end
  o.setUsingPlayer = function(_, pl) o.user = pl end
  o.getEntityScript = function() return o.script end
  return o
end }
GameEntityFactory = { CreateIsoObjectEntity = function(o, s, b) o.script = s end }
local mt = getSq(0, 0, 0)
function stationSquare(sq)
  sq.AddSpecialObject = function(_, o) o.inWorld = true; STATIONS[#STATIONS + 1] = o end
  sq.transmitRemoveItemFromSquare = function(_, o) o.inWorld = false; for i, x in ipairs(STATIONS) do if x == o then table.remove(STATIONS, i) end end end
end
-- the game's UsingPlayerUpdateSystem: clear the user once they're more than 10 tiles off
function usingPlayerSystem()
  if NO_ENTITY_LOOP then return end
  for _, o in ipairs(STATIONS) do
    if o.user and (math.abs(P.x - o.sq:getX()) > 10 or math.abs(P.y - o.sq:getY()) > 10) then o.user = nil end
  end
end
''')
L.execute('stationSquare(getSq(52, 50, 0)); FILES = {}; P.x, P.y = 50.5, 50.5')
L.execute('FILES["TestGround_station.txt"] = {"label = station", "settle = 1", "start = 50,50,0", "zombies = none", "step = station spawn wait=20 station_rack"}')
bridge('run TestGround_station.txt')
L.execute('local n = 0 while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; usingPlayerSystem(); fire("OnTick") end')
files = L.eval('FILES')
stx, sttr = rep_and_trace('TestGround_station_')
sl = [l for l in stx.split('\n') if l.startswith('== ')]
print(sl); print([l for l in sttr if 'station:' in l])
check(sl and 'Base.DryingRackHide at 52,50,0' in sl[0] and 'using player set after opening (via setUsingPlayer)' in sl[0] and 'cleared after' in sl[0] and L.eval('#STATIONS') == 0 and 'station_rack' in stx,
      'station: a drying rack put down, its using player set, cleared after moving away, rack taken off (%s)' % (sl and sl[0]))
# with the game's loop gone and nothing in its place, the report must say it stayed set
L.execute('NO_ENTITY_LOOP = true; stationSquare(getSq(52, 50, 0)); FILES = {}; P.x, P.y = 50.5, 50.5')
L.execute('FILES["TestGround_station2.txt"] = {"label = station2", "settle = 1", "start = 50,50,0", "zombies = none", "step = station spawn type=Base.Workbench wait=5 station_wb"}')
bridge('run TestGround_station2.txt')
L.execute('local n = 0 while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; usingPlayerSystem(); fire("OnTick") end; NO_ENTITY_LOOP = nil')
files = L.eval('FILES')
stx2, _ = rep_and_trace('TestGround_station2_')
sl2 = [l for l in stx2.split('\n') if l.startswith('== ')]
check(sl2 and 'Base.Workbench' in sl2[0] and 'STILL SET after 5 s' in sl2[0], 'station: type=, and a using player nothing clears is reported STILL SET (%s)' % (sl2 and sl2[0]))

# gamespeed: only with measure = 0 and no profiler; the report says the numbers aren't measurements
L.execute('FILES["TestGround_gs.txt"] = {"label = gs", "settle = 1", "start = 50,50,0", "zombies = none", "gamespeed = 3", "measure = 0", "step = idle 2 still"}; P.x, P.y = 50.5, 50.5')
def gs_run():
    bridge('run TestGround_gs.txt')
    L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; fire("OnTick") end
""")
    fl = L.eval('FILES')
    ks = sorted([k for k in fl.keys() if str(k).startswith('TestGround_gs_') and str(k).endswith('.txt') and not str(k).endswith(AUX)], key=lambda k: int(_re.search(r'_(\d+)\.txt$', k).group(1)))
    return '\n'.join(fl[ks[-1]][i] for i in range(1, len(fl[ks[-1]]) + 1))
g1 = gs_run()
L.execute('SAVED_PROF = LuaEventProfiler; LuaEventProfiler = nil; maxMult = 1')
g2 = gs_run()
L.execute('LuaEventProfiler = SAVED_PROF')
check('game speed: 1 (gamespeed asked for, but a profiler is on)' in g1 and 'game speed: x3 (fast-forward' in g2 and L.eval('maxMult') == 20 and L.eval('mult') == 1, 'gamespeed: refused with a profiler on, x3 without, back to 1 after')

# 1.9.1: obstacles = avoid. The wreck stays; the car steers round it within the street.
L.execute("""CAR = nil; P.vehicle = nil; P.x, P.y = 50.5, 50.5; MAXV = 0; MAPST = true; WRECKW = 2; WRECKHIT = 0
WRECKAT = "1400,304,0"
local w = { x = 1400.5, y = 304.5, getScript = function() return { getName = function() return "CarWreck" end } end }
w.permanentlyRemove = function() w.gone = true end
for x = 1399, 1402 do for y = 303, 305 do VEHSQ[x .. "," .. y .. ",0"] = w end end
FILES["TestGround_out.txt"] = {}
FILES["TestGround_av.txt"] = {"label = av", "settle = 1", "start = 50,50,0", "obstacles = avoid", "step = drivefast 60 120 drive_fast", "fastname = Mock Road", "fastwidth = 8", "fastroad = 1000,302,0", "fastroad = 1700,302,0"}""")
bridge('run TestGround_av.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 40000 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
""")
files = L.eval('FILES')
avt, avtr = rep_and_trace('TestGround_av_')
print([l for l in avt.split('\n') if l.startswith('== ')])
print([l for l in avtr if 'steering' in l and 'off the centre at' in l][:3])
check('obstacles avoided by steering' in avt and L.eval('WRECKHIT') == 0 and not L.eval('VEHSQ["1400,304,0"].gone') and 'FALLBACK' not in avt and any('something on the road ahead' in l for l in avtr), 'obstacles = avoid: the wreck stays, the car swerves round it without touching it')
L.execute('for x = 1399, 1402 do for y = 303, 305 do VEHSQ[x .. "," .. y .. ",0"] = nil end end; WRECKAT = nil; WRECKW = nil; MAPST = false')

# 1.9.2: heartbeat on OnRenderTick tells a paused game from a stuck step
L.execute('FILES["TestGround_hb.txt"] = {"label = hb", "settle = 1", "start = 50,50,0", "zombies = none", "step = idle 2 still"}; P.x, P.y = 50.5, 50.5')
bridge('run TestGround_hb.txt')
L.execute("""
for i = 1, 50 do clock = clock + 16; fire("OnRenderTick"); fire("OnTick") end
paused = true
for i = 1, 1500 do clock = clock + 16; fire("OnRenderTick") end
paused = false
""")
fl = L.eval('FILES')
mid = [k for k in fl.keys() if str(k).startswith('TestGround_hb_') and str(k).endswith('_trace.txt')]
check(L.eval('TestGround.isRunning()') and len(mid) == 1 and any('heartbeat' in fl[mid[0]][i] for i in range(1, len(fl[mid[0]]) + 1)), 'trace: written as the run goes (a killed run still leaves it)')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; fire("OnRenderTick"); fire("OnTick") end
""")
files = L.eval('FILES')
hbt, hbtr = rep_and_trace('TestGround_hb_')
check(len([l for l in hbtr if 'run begin' in l]) == 1 and any('run end' in l for l in hbtr), 'trace: the final write is whole, not doubled')
hbs = [l for l in hbtr if 'heartbeat' in l]
print(hbs[:3])
check(any('heartbeat: settle, paused true' in l and ' 0 game ticks' in l for l in hbs), 'heartbeat: a paused settle shows as paused, with 0 game ticks')

# 1.9.3: forest zones order the candidates; treescan writes the real counts; surveys read the file
outl = out_lines()
L.execute("""
TestGround.mapTreeRoads = { { "Mock Field Road", 6, 120, 200, 270, 200 }, { "Mock Wood Road", 6, 200, 300, 350, 300 } }
FOREST = { { 190, 290, 360, 310 } }
P.x, P.y, P.z = 50.5, 50.5, 0; P.ghost = false; FILES["TestGround_treeroads.txt"] = nil; FILES["TestGround_out.txt"] = {}; TestGround.K.TREE_GOOD = 0.5
""")
bridge('treescan 5')
L.execute("""
local n = 0
while n < 5000 and not FILES["TestGround_treeroads.txt"] do n = n + 1; clock = clock + 16; fire("OnTick") end
for i = 1, 200 do clock = clock + 16; fire("OnTick") end
""")
tf = L.eval('FILES["TestGround_treeroads.txt"]')
tf = [tf[i] for i in range(1, len(tf) + 1)] if tf else []
print(tf)
data = [l for l in tf if not l.startswith('#')]
check(len(data) == 2 and data[0].startswith('Mock Wood Road | 200,300,350,300 | ') and float(data[0].split('|')[2]) >= 0.5 and float(data[0].split('|')[3]) > 0.9 and float(data[1].split('|')[3]) == 0, 'treescan: both roads visited, the wooded one first with its tree count and forest share')
check(abs(L.eval('P.x') - 50.5) < 0.01 and L.eval('P.ghost') is False and any('tree scan done' in l for l in out_lines()), 'treescan: back where it started, ghost off, bridge told')
L.execute("""
OBJS_SAVE = {}
for x = 190, 360 do OBJS_SAVE[x] = { OBJS[x .. ",296,0"], OBJS[x .. ",304,0"] }; OBJS[x .. ",296,0"] = nil; OBJS[x .. ",304,0"] = nil end
P.x, P.y = 50.5, 50.5; FILES["TestGround_baseline.txt"] = nil; FILES["TestGround_out.txt"] = {}
TELEPORTS0 = TELEPORTS or 0
""")
bridge('baseline 30 here')
L.execute("""
local n = 0
while n < 3000 and not FILES["TestGround_baseline.txt"] do n = n + 1; clock = clock + 16; fire("OnTick") end
TestGround.stop("test stop")
for x = 190, 360 do OBJS[x .. ",296,0"], OBJS[x .. ",304,0"] = OBJS_SAVE[x][1], OBJS_SAVE[x][2] end
TestGround.mapTreeRoads = nil; FOREST = {}; FILES["TestGround_treeroads.txt"] = nil; TestGround.K.TREE_GOOD = 0.3
""")
bl6 = L.eval('FILES["TestGround_baseline.txt"]')
bl6 = [bl6[i] for i in range(1, len(bl6) + 1)] if bl6 else []
check('treeroad = 200,300,0' in bl6 and 'treeroad = 350,300,0' in bl6, 'survey: takes the tree road from TestGround_treeroads.txt (trees gone here, so it did not count them again) %s' % [l for l in bl6 if l.startswith('treeroad')])

# 1.9.4: the fight plan alone; a pending drag-down is cleared; hit reactions count as down
L.execute('FILES["TestGround_fight.txt"] = nil; FILES["TestGround_out.txt"] = {}; P.x, P.y = 50.5, 50.5; P.god = false; ROLE.caps = {}; ROLE.locked = true')
# 1.13.10: the gun aims with the mouse and waits for the aiming delay
L.execute('''
MX, MY, AIMD, AIMREADS = 0, 0, 4, 0
isoToScreenX = isoToScreenX or function(pn, x, y, z) return (x - y) * 32 end
isoToScreenY = isoToScreenY or function(pn, x, y, z) return (x + y) * 16 - z * 48 end
function setMouseXY(x, y) MX, MY = x, y end
function getMouseX() return MX end
function getMouseY() return MY end

function player.getAimingDelay() AIMREADS = AIMREADS + 1; if AIMREADS % 12 == 0 then AIMD = 4 else AIMD = math.max(0, AIMD - 1) end; return AIMD end
''')
bridge('fight')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 30000 do n = n + 1; clock = clock + 16
  if n == 900 then P.dragDown = true; P.hitReaction = "EndDeath" end
  stepZombies(); fire("OnTick") end
""")
ff = L.eval('FILES["TestGround_fight.txt"]')
ff = [ff[i] for i in range(1, len(ff) + 1)] if ff else []
files = L.eval('FILES')
ft, ftr = rep_and_trace('TestGround_fight_')
fl3 = [l for l in ft.split('\n') if l.startswith('== ') and 'realfight' in l]
print(fl3)
check('step = realfight 12 40 fight_12' in ff and len(fl3) == 4 and all('hits taken' in l and 'guard fired' in l for l in fl3), 'fight plan: written with defaults, 3 then 6 then 12 then the floor fight, each with swings, kills, hits, downs and the guard')
check('knock-downs by script (every 6 s, via' in (fl3[-1] if fl3 else ''), 'fight_floor: the step reports its script knock-downs and the route')
gl = [l for l in ft.split('\n') if l.startswith('== ') and 'gunfight' in l]
print(gl)
check('step = gunfight 8 40 gun_pistol' in ff and len(gl) == 1 and _re.search(r'8 spawned 15 tiles out, Base\.Pistol \(M9 Pistol\), [1-9]\d* shots fired', gl[0]) is not None and _re.search(r'[1-9]\d* hits', gl[0]) and _re.search(r'[1-9]\d* reloads', gl[0]) and 'NOT A RANGED' not in gl[0] and 'FAILED' not in gl[0],
      'gun fight: in the fight plan, a loaded pistol fires through the attack input, hits at range, ammo topped up by script')
check(gl and _re.search(r'aim by mouse \(mouse on the target [1-9]\d* ticks, off it 0\), aiming delay at the trigger [0-9.]+ mean', gl[0]) is not None, 'gun fight: the mouse is put on the target and shots wait for the aiming delay')
L.execute("""
local K = TestGround.K
ZOMBIES = {}; FREEZE = true; P.x, P.y = 300.5, 300.5; SWINGS = 1
newZombie(301.5, 300.5)
local r = { p = player }
local st = { swings = 0, backoffs = 0, lo = 0.66, hi = 1.15 }
K.knockOne(r, st)
for i = 1, 40 do K.holdAim(r.p, st); K.knockVerify(st); K.fightMove(r, st) end
KO_N, KO_FLOOR = st.knocked or 0, st.floorTargets or 0
ZOMBIES = {}; FREEZE = nil
""")
check(L.eval('KO_N') == 1 and L.eval('KO_FLOOR') == 1, 'fight_floor: a zombie knocked down by script is attacked from its head end (%d knocked, %d floor targets)' % (L.eval('KO_N'), L.eval('KO_FLOOR')))

# 1.13.2: the game's knockDown floors the zombie only after its stagger, and the bat's next hit
# (hitConsequences) clears it; the knocked zombie must not be swung at or lured while it's watched
L.execute("""
local K = TestGround.K
ZOMBIES = {}; FREEZE = true; P.x, P.y = 300.5, 300.5; SWINGS = 1
newZombie(301.5, 300.5)
local z = ZOMBIES[#ZOMBIES]
z.knockDown = function() z.fallAt = clock + 1500 end
z.isProne = function() return z.fallAt ~= nil and clock >= z.fallAt end
local r = { p = player }
local st = { swings = 0, backoffs = 0, lo = 0.66, hi = 1.15 }
K.knockOne(r, st)
for i = 1, 60 do clock = clock + 16; K.holdAim(r.p, st); K.knockVerify(st); K.fightMove(r, st) end
KH_SWINGS = st.swings
for i = 1, 60 do clock = clock + 16; K.knockVerify(st) end
KH_DOWN, KH_MS = st.knockDown or 0, st.knockMs or 0
ZOMBIES = {}; FREEZE = nil
""")
check(L.eval('KH_SWINGS') == 0 and L.eval('KH_DOWN') == 1 and 1400 <= L.eval('KH_MS') <= 1700, 'fight_floor: a zombie being knocked down is left alone until it is on the floor, and the time it took is kept (%s swings, %s down, %s ms)' % (L.eval('KH_SWINGS'), L.eval('KH_DOWN'), L.eval('KH_MS')))
check(L.eval('P.dragDown') is False and any('drag-down cleared' in l for l in ftr), 'drag-down: a pending drag-down death is cleared')
check(any('of them put down by script to keep at most 2' in l for l in fl3), 'fight: crowd cap reported')
check('weapon condition 15/15 before' in fl3[0] and all('weapon condition' in l and 'strength 5, arms ok' in l for l in fl3) and L.eval('P.primary') is None and L.eval('#INV.items') == 0, 'fight: a real bat is held, its condition and the character\'s fitness reported, and it is taken away after')

# weapon/skill matrix: per-step weapon and skills, put back after
L.execute('FILES["TestGround_fm.txt"] = {"label = fm", "settle = 1", "start = 50,50,0", "zombies = none", "god = 0", "step = realfight 3 20 sword_axe5 weapon=Mod.Sword Axe=5 Strength=8", "step = realfight 3 20 bat_0 weapon=Base.BaseballBat Blunt=0"}; P.x, P.y = 50.5, 50.5; PERKS = {}')
bridge('run TestGround_fm.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 30000 do n = n + 1; clock = clock + 16; stepZombies(); fire("OnTick") end
""")
files = L.eval('FILES')
mt, mtr = rep_and_trace('TestGround_fm_')
ml = [l for l in mt.split('\n') if l.startswith('== ') and 'realfight' in l]
print(ml)
check(len(ml) == 2 and 'Mod.Sword (Sword)' in ml[0] and 'category LongBlade' in ml[0] and 'skills Axe=5 Strength=8' in ml[0] and 'Base.BaseballBat' in ml[1] and 'category Blunt' in ml[1] and 'skills Blunt=0' in ml[1] and 'cleared in' in ml[0], 'weapon matrix: each step its own weapon, category and skills, with time to clear')
check(L.eval('PERKS.Axe') == 5 and L.eval('PERKS.Strength') == 5 and L.eval('#INV.items') == 0 and ('sword_axe5' in mt), 'weapon matrix: skills put back, weapons taken away, tags kept')

# 1.10.0 release safety: lua only in -debug; first run per save asks; MP refused; bridge off unless enabled
L.execute('FILES["TestGround_out.txt"] = {}')
check(L.eval('TestGround.command("lua 1 + 2")[1]').startswith('unknown command') and 'TestGround_cmd.txt' not in TG_ALL, 'release: the core has no lua command and reads no command file')
bridge('lua 1 + 2')
check(any('ok: 3' in l for l in out_lines()), 'bridge mod: lua and the command file work when it is installed')
# 1.1.0 bridge: lua lines only with -debug or the save's sandbox option; logged either way
L.execute('DEBUGMODE = false; FILES["TestGround_out.txt"] = {}; FILES["TestGround_bridge_lua.txt"] = nil; SandboxVars = nil')
bridge('lua 40 + 2', 'status')
o = out_lines()
lg = L.eval('FILES["TestGround_bridge_lua.txt"]'); lg = [lg[i] for i in range(1, len(lg) + 1)] if lg else []
check(not any('ok: 42' in l for l in o) and any(l.startswith('refused:') for l in o) and any(l == 'idle' or l.startswith('running') for l in o) and any('refused: 40 + 2' in l for l in lg),
      'bridge 1.1.0: no -debug and no sandbox option: lua refused and logged, commands still work (%s)' % lg)
L.execute('SandboxVars = { TestGroundBridge = { AllowLua = true } }; FILES["TestGround_out.txt"] = {}')
bridge('lua 40 + 2')
lg = L.eval('FILES["TestGround_bridge_lua.txt"]'); lg = [lg[i] for i in range(1, len(lg) + 1)] if lg else []
check(any('ok: 42' in l for l in out_lines()) and any('run (the save' in l and '40 + 2' in l for l in lg), 'bridge 1.1.0: the sandbox option lets lua lines run, and the line is logged')
L.execute('SandboxVars = nil; DEBUGMODE = true')
L.execute('DEBUGMODE = true')
L.execute("""
TestGround.trusted = false; GTMOD = {}; DIALOGS = {}
ISModalDialog = { new = function(_, x, y, w, h, text, yes, tgt, onclick) local d = { text = text, onclick = onclick }
  d.initialise = function() end; d.addToUIManager = function() table.insert(DIALOGS, d) end; return d end }
getCore_orig = getCore
FILES["TestGround_fight.txt"] = nil; P.x, P.y = 50.5, 50.5
""")
bridge('fight')
check(any('waiting for the confirmation' in l for l in out_lines()) and L.eval('#DIALOGS') == 1 and not L.eval('TestGround.isRunning()'), 'release: first run in a save asks first, nothing runs yet')
L.execute('DIALOGS[1].onclick(nil, { internal = "YES" })')
check(L.eval('TestGround.isRunning()') is True and L.eval('GTMOD.TestGroundConfirmed') is True, 'release: yes runs it and is remembered in the save')
L.execute('TestGround.stop("test")')
bridge('fight')
check(L.eval('#DIALOGS') == 1 and L.eval('TestGround.isRunning()') is True, 'release: no second ask in the same save')
L.execute('TestGround.stop("test"); function isClient() return true end')
bridge('fight')
check(any('singleplayer only' in l for l in out_lines()) and not L.eval('TestGround.isRunning()'), 'release: refused in multiplayer')
L.execute('isClient = nil; TestGround.trusted = true')

# 1.10.0: a far tree road is teleported to, not glided to (that ate the whole step: 0 passes)
L.execute('FILES["TestGround_tr.txt"] = {"label = tr", "settle = 1", "start = 50,50,0", "zombies = none", "treeroad = 1200,300,0", "treeroad = 1350,300,0", "step = treeroad 20 20 drive_trees"}; P.x, P.y = 50.5, 50.5')
L.execute('UNLOADED["1200,300,0"] = true')   # 1.13.10: the far road takes a few seconds to load
bridge('run TestGround_tr.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 30000 do n = n + 1; clock = clock + 16; if n == 250 then UNLOADED["1200,300,0"] = nil end; fire("OnTick") end
UNLOADED["1200,300,0"] = nil
""")
files = L.eval('FILES')
trt, trtr = rep_and_trace('TestGround_tr_')
tl = [l for l in trt.split('\n') if 'drive_trees' in l and l.startswith('== ')]
print(tl)
m = _re.search(r'(\d+) passes of the tree road \(teleported to the tree road, loaded', tl[0] if tl else '')
check(m is not None and int(m.group(1)) >= 2 and '(20 s)' in tl[0], 'tree road far away: teleported there, loaded, then 2+ passes, and the wait is not in its time')
# 1.13.10: the wait for the far road is filed under drive_trees_load in the perf file, not drive_trees
trp = files['TestGround_perf_latest.txt']
trp = [trp[i] for i in range(1, len(trp) + 1)]
print('tree perf tags:', sorted(set(l.split(',')[3] for l in trp[1:] if l.count(',') > 4)))
check(any(',drive_trees_load,' in l for l in trp) and any(',drive_trees,' in l for l in trp), 'tree road far away: the load wait has its own perf rows (drive_trees_load)')

# 1.11.0: the fixed baseline shipped in the mod runs with no survey
for name in ('baseline', 'natural'):
    L.execute('MODFILES["TestGround/media/TestGround/%s.txt"] = {}' % name)
    for l in open(os.path.join(HERE, 'TestGround/42/media/TestGround/%s.txt' % name), encoding='utf-8').read().split('\n'):
        L.execute('table.insert(MODFILES["TestGround/media/TestGround/%s.txt"], %r)' % (name, l))
L.execute('FILES["TestGround_out.txt"] = {}; FILES["TestGround_baseline.txt"] = nil; P.x, P.y = 50.5, 50.5')
bridge('baseline')
fx = L.eval('TestGround.status and 1')
ol = out_lines()
check(any('started baseline (fixed, from the mod)' in l for l in ol) and L.eval('FILES["TestGround_baseline.txt"]') is None, 'fixed baseline: runs from the mod with no survey %s' % [l for l in ol if 'baseline' in l][:2])
L.execute('TestGround.stop("test")')
fp = L.eval('TestGround.loadPlan("mod:baseline")')
check(fp is not None and len(fp.steps) >= 12 and fp.treeroad[1].x == 12266 and fp.start.x == 11501, 'fixed baseline: parses, all steps, Tioga Road, West Point start')
check(L.eval('TestGround.loadPlan("mod:natural")') is not None, 'fixed natural plan parses')

# 1.12.0: Better Building Plus build step, against a fake BBP that builds a piece every 2 s
L.execute("""
for _, n in ipairs({"OnBeginConstructionSucceeded","OnBeginConstructionFailed","OnBBPPieceClaimed","OnBuildPieceSucceeded","OnBuildPieceFailed","OnBBPBuildPieceResult"}) do
  local e = { l = {} }
  e.Add = function(f) table.insert(e.l, f) end
  e.Remove = function(f) for i, g in ipairs(e.l) do if g == f then table.remove(e.l, i) return end end end
  Events[n] = e
end
BBP = { pieces = 0, built = 0, state = "idle", sent = nil, cancelled = 0 }
local function fireE(n, ...) local c = {} for i, f in ipairs(Events[n].l) do c[i] = f end for _, f in ipairs(c) do f(...) end end
BBP_COMMANDS = {
  BeginConstruction = { name = "BeginConstruction", send = function(self, p, args)
    BBP.sent = args; local plan = BBP_DECODED
    BBP.pieces = #plan.cells + #plan.walls + #(plan.stairs or {}); BBP.built = 0; BBP.state = "building"; BBP.next = clock + 2000
    fireE("OnBeginConstructionSucceeded", p, nil, 77) end },
  CancelConstruction = { send = function(self, p, args) BBP.cancelled = BBP.cancelled + 1 end },
}
BBP_COMMANDS.sendPlan = function(cmd, p, args) cmd:send(p, args) end
BBP_PRESETS = { jsonEncode = function(plan) BBP_DECODED = plan; return "{json}" end }
local req0 = require
function require(name)
  if name == "BetterBuildingPlus/networking/commands" then return BBP_COMMANDS end
  if name == "RCStructureFramework/Presets" then return BBP_PRESETS end
  if name == "BetterBuildingPlus/PlanMaterials" then return { forPlan = function(plan)
    local n = #plan.walls + #plan.cells + 13 * #(plan.stairs or {})
    return { { tag = "base:hammer", keep = true, count = 1 }, { fullType = "Base.Plank", keep = false, count = n }, { fullType = "Base.Nails", keep = false, count = n } } end } end
  return req0(name)
end
BBPAutonomousBuilder = { getState = function() return BBP.state end, getProgress = function() return BBP.built, BBP.pieces end,
  stop = function() BBP.state = "idle" end, getError = function() return nil end }
function bbpTick()
  if BBP.state == "building" and clock >= BBP.next then
    BBP.built = BBP.built + 1; BBP.next = clock + 2000
    fireE("OnBBPPieceClaimed", { status = "granted", pieceIndex = BBP.built, recordId = 77 })
    fireE("OnBBPBuildPieceResult", { recordId = 77, pieceIndex = BBP.built, success = false, error = "Build already queued" })
    fireE("OnBuildPieceSucceeded", P, 77, BBP.built)
    fireE("OnBBPBuildPieceResult", { recordId = 77, pieceIndex = BBP.built, success = true })
    if BBP.built >= BBP.pieces then BBP.state = "done" end
  end
end
FILES["TestGround_build.txt"] = nil; FILES["TestGround_out.txt"] = {}; P.x, P.y = 50.5, 50.5; INV.items = {}; BBP_ITEMS = true
""")
L.execute('FILES["TestGround_build.txt"] = {"label = build", "settle = 1", "start = 50,50,0", "zombies = none", "god = 0", "buildsite = 80,80,0", "buildspeed = real", "step = build 3 3 300 build_bbp Woodwork=1", "step = visit 5 build_inside", "step = passby 10 20 build_pass"}')
for x in range(78, 86):
    pass
bridge('build')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 60000 do n = n + 1; clock = clock + 16; bbpTick(); fire("OnTick") end
""")
files = L.eval('FILES')
bt2, btr2 = rep_and_trace('TestGround_build_')
bl = [l for l in bt2.split('\n') if l.startswith('== ')]
print(bl)
check(any('by Better Building Plus, build speed real: 22 of 22 pieces built' in l and 'builder done' in l and 'claim to built mean' in l for l in bl), 'build: BBP builds the 3x3 room (22 pieces) through BeginConstruction, timed per piece')
check(L.eval('BBP.sent.blueprintItemId') is not None and len(L.eval('BBP_DECODED.walls')) == 13 and L.eval('BBP.cancelled') == 1, 'build: plan sent with a blueprint id, 12 walls + frame + door, cancelled at the end')
# buildspeed fast (default): the same builder at x20; instant: build cheat, all placed at once
for mode, want in (('fast', 'build speed fast (game speed x20'), ('instant', 'build speed instant (build cheat)')):
    L.execute('FILES["TestGround_build.txt"] = {"label = build", "settle = 1", "start = 50,50,0", "zombies = none", "god = 0", "buildsite = 80,80,0"%s, "step = build 3 3 300 build_bbp"}; P.x, P.y = 50.5, 50.5; SPEEDS = {}; INV.items = {}' % ('' if mode == 'fast' else ', "buildspeed = instant"'))
    L.execute('player.setBuildCheat = function(_, v) P.cheat = v end; local sg = setGameSpeed; setGameSpeed = function(s) table.insert(SPEEDS, s); if sg then sg(s) end end')
    bridge('run TestGround_build.txt')
    L.execute("""
local n = 0
while TestGround.isRunning() and n < 60000 do n = n + 1; clock = clock + 16; bbpTick(); fire("OnTick") end
""")
    b3, _ = rep_and_trace('TestGround_build_')
    l3 = [l for l in b3.split('\n') if l.startswith('== ') and 'build_bbp' in l]
    sp = list(L.eval('SPEEDS').values())
    check(l3 and want in l3[-1] and (mode == 'instant' or (3 in sp and sp[-1] == 1)) and not L.eval('P.cheat'), 'build: buildspeed %s (%s; game speeds %s)' % (mode, l3 and l3[-1][:160], sp))
check(any('build_inside' in l and 'SKIPPED' not in l for l in bl) and any('passes by the built room' in l for l in bl), 'build: stand inside and glide past the room')

# 1.12.5: any structure from a file: two floors, walls with a door, stairs, Woodwork from the file
L.execute('FILES["crane_site.txt"] = {"# crane test shell", "woodwork = 6", "floor 0,0,0 4x3", "walls 0,0,0 4x3 door=south", "floor 0,0,1 4x3", "stairs 4,2,0 north"}')
L.execute('FILES["TestGround_build.txt"] = {"label = build", "settle = 1", "start = 50,50,0", "zombies = none", "god = 0", "buildsite = 80,80,0", "buildspeed = real", "step = build crane_site.txt 600 shell"}; P.x, P.y = 50.5, 50.5; INV.items = {}; PERKS = {}')
bridge('run TestGround_build.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 90000 do n = n + 1; clock = clock + 16; bbpTick(); fire("OnTick") end
""")
b4, _ = rep_and_trace('TestGround_build_')
l4 = [l for l in b4.split('\n') if l.startswith('== ') and 'shell' in l]
print(l4)
nW, nC, nS = len(L.eval('BBP_DECODED.walls')), len(L.eval('BBP_DECODED.cells')), len(L.eval('BBP_DECODED.stairs'))
check(l4 and 'structure crane_site.txt (5x3, 2+ floors)' in l4[0] and '40 of 40 pieces built' in l4[0] and 'Woodwork=6' in l4[0] and (nW, nC, nS) == (15, 24, 1) and L.eval('BBP_DECODED.stairs[1].bottomSprite') == 'carpentry_02_96', 'structure file: 2 floors, walls with a door, stairs; BBP builds all 40 pieces with Woodwork 6 (%s)' % ((nW, nC, nS),))
L.execute('for k in pairs(FILES) do if string.find(k, "^Zomboid/Lua/TestGround_build_") or string.find(k, "^TestGround_build_") then FILES[k] = nil end end')
L.execute('FILES["bad.txt"] = {"floor 0,0,0 2x2", "crane 1,1,0"}; FILES["TestGround_build.txt"] = {"label = build", "settle = 1", "start = 50,50,0", "zombies = none", "god = 0", "step = build bad.txt"}; P.x, P.y = 50.5, 50.5')
bridge('run TestGround_build.txt')
L.execute("local n = 0 while TestGround.isRunning() and n < 9000 do n = n + 1; clock = clock + 16; bbpTick(); fire('OnTick') end")
b5, _ = rep_and_trace('TestGround_build_')
print([l for l in b5.split('\n') if l.startswith('==')]); check('unknown piece crane' in b5, 'structure file: an unknown piece is named and the step skipped')
L.execute('require = nil; BBP_ITEMS = nil')

# 1.13.0: "test = <group> <step>" lines, the detail = pzopt marks, and a report module
L.execute('''
RM_SEEN = {}
TestGround.addReportModule("mock cost", {
  stepStart = function(r, st) RM_SEEN[#RM_SEEN + 1] = "start " .. st.tag end,
  stepEnd = function(r, st, add) add("mock cost: " .. st.tag); RM_SEEN[#RM_SEEN + 1] = "end " .. st.tag end,
  finish = function(r, add) add("mock cost: run done") end,
})
''')
L.execute('FILES = {}; P.x, P.y = 50.5, 50.5')
L.execute('FILES["TestGround_groups.txt"] = {"label = groups", "settle = 1", "start = 50,50,0", "zombies = none", "detail = pzopt", "test = idle idle 2 stand_still", "step = wait 2 1 old_style", "test = melee idle 2 wrong_group", "test = nosuch idle 2"}')
bridge('run TestGround_groups.txt')
L.execute('local n = 0 while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; fire("OnTick") end')
files = L.eval('FILES')
gtx, _ = rep_and_trace('TestGround_groups_')
gl = [l for l in gtx.split('\n') if l.startswith('== ')]
mk = [str(k) for k in files.keys() if str(k).endswith('_marks.txt') and 'groups' in str(k)]
marks = [files[mk[0]][i] for i in range(1, len(files[mk[0]]) + 1)] if mk else []
print(gl, marks[:4])
check(len(gl) == 2 and 'idle 2 stand_still' in gl[0] and 'wait 2 1 old_style' in gl[1], 'test lines: "test = idle idle 2 ..." runs the step, old "step =" lines still run (%s)' % gl)
_pe = L.eval('table.concat(TestGround.parsePlan({"test = melee idle 2 x", "test = nosuch idle 2", "test = drive drivefast 60 ok"}).errors, "|")')
check("isn't in the melee group" in _pe and "unknown test group 'nosuch'" in _pe and _pe.count('|') == 1, 'test lines: a step in the wrong group or an unknown group is a plan error')
check(len(marks) == 4 and marks[0].startswith('start ') and 'stand_still' in marks[0] and marks[1].startswith('end ') and 'pzopt marks for 2 steps' in gtx, 'detail = pzopt: a start and end mark per step in the marks file (%s)' % marks)
check(L.eval('#RM_SEEN') == 4 and 'mock cost: stand_still' in gtx and 'mock cost: run done' in gtx, 'report module: called at each step start and end and at the end of the run')
# no detail key: on when pzopt's Lua global is there, off otherwise
L.execute('PzoptOptionClasses = {}; FILES = {}; FILES["TestGround_pz.txt"] = {"label = pz", "settle = 1", "start = 50,50,0", "zombies = none", "step = idle 1 a"}')
bridge('run TestGround_pz.txt')
L.execute('local n = 0 while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; fire("OnTick") end')
L.execute('PzoptOptionClasses = nil; FILES["TestGround_nopz.txt"] = {"label = nopz", "settle = 1", "start = 50,50,0", "zombies = none", "step = idle 1 a"}')
bridge('run TestGround_nopz.txt')
L.execute('local n = 0 while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; fire("OnTick") end')
files = L.eval('FILES')
pz, _ = rep_and_trace('TestGround_pz_'); nopz, _ = rep_and_trace('TestGround_nopz_')
check('pzopt found: PzoptOptionClasses is set' in pz and 'pzopt marks' not in nopz, 'detail: on by itself when pzopt is found, off without it')

# 1.13.2: driving changes from the user's manual drive, the pause fix, the clean-up and the banner
L.execute("""
local K = TestGround.K
local st = {}
K.buildPath(st, { {x=0.5,y=0.5}, {x=100.5,y=0.5}, {x=100.5+70.7,y=0.5+70.7}, {x=100.5+70.7-80,y=0.5+70.7+20} })
RB_STOPS, RB_ROLL = #st.stops, (st.bends[1] and st.bends[1].roll) and 1 or 0
local st2 = { rollDeg = K.FAST_CORNER_DEG }
K.buildPath(st2, { {x=0.5,y=0.5}, {x=100.5,y=0.5}, {x=100.5+70.7,y=0.5+70.7} })
RB_STOPS2 = #st2.stops
local _, kmh = TestGroundInternal.nextBend(st, 50, 1e9)
RB_KMH = kmh * 3.6
local j = {}
K.jamNote(j, 100); K.jamNote(j, 105); K.jamNote(j, 105)
JA1 = K.jamAhead(j, 50); JA2 = K.jamAhead(j, 110); JA3 = K.jamAhead(j, 130)
local j2 = {}
K.jamNote(j2, 100)
JB1 = K.jamAhead(j2, 50); JB2 = K.jamAhead(j2, 75)
WR1 = K.wantedRate(6, 0.1, 10, false); WR2 = K.wantedRate(12, 0.1, 10, false); WR3 = K.wantedRate(30, 1.0, 10, true)
""")
check(L.eval('RB_STOPS') == 2 and L.eval('RB_ROLL') == 1 and L.eval('RB_STOPS2') == 2 and abs(L.eval('RB_KMH') - 38) < 0.01,
      'corners: 45 deg is driven through at 38 km/h (1.13.11), 80+ deg still stops, "corners = stop" stops at 40 (%s stops, roll %s, %s km/h)' % (L.eval('RB_STOPS'), L.eval('RB_ROLL'), L.eval('RB_KMH')))
check(L.eval('JA1') == 100 and L.eval('JA2') == 110 and L.eval('JA3') is None and L.eval('JB1') is None and L.eval('JB2') == 100,
      'wreck jam: 2 in the next 60 tiles (or 1 within 30) caps the speed from the first, until 20 tiles past the last (%s %s %s %s %s)' % (L.eval('JA1'), L.eval('JA2'), L.eval('JA3'), L.eval('JB1'), L.eval('JB2')))
check(abs(L.eval('WR1') * 4 - L.eval('WR2')) < 1e-6 and abs(L.eval('WR3') - 1.0) < 1e-6, 'steering: the turn rate is scaled down below 12 tiles/s, and a corner allows 1 rad/s')

# a pause mid-step is no frame, and the step still runs its length
L.execute('FILES = {}; P.x, P.y = 50.5, 50.5')
L.execute('FILES["TestGround_pause.txt"] = {"label = pause", "settle = 1", "start = 50,50,0", "zombies = none", "step = idle 3 still"}')
bridge('run TestGround_pause.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do
  n = n + 1; clock = clock + 16
  if n == 200 then paused = true end
  if n == 700 then paused = false end
  fire("OnRenderTick"); fire("OnTick")
end
paused = false
""")
files = L.eval('FILES')
pt, _ = rep_and_trace('TestGround_pause_')
pl = [l for l in pt.split('\n') if l.startswith('== ') or l.startswith('frames:')]
print(pl)
mw = _re.search(r'worst (\d+) ms', pt)
check(any('[game paused 8 s, left out of the frames' in l for l in pl) and mw and int(mw.group(1)) < 100 and '(3 s)' in pt, 'pause: left out of the frame stats and the step time, and the step runs its full length (%s)' % pl)

# a run stopped mid-fight takes its zombies and the fight's corpses with it
L.execute('FILES = {}; P.x, P.y = 50.5, 50.5; ZOMBIES = {}')
L.execute('FILES["TestGround_stopf.txt"] = {"label = stopf", "settle = 1", "start = 50,50,0", "zombies = none", "step = realfight 6 30 f"}')
bridge('run TestGround_stopf.txt')
L.execute("""
FREEZE = true
local n = 0
while TestGround.isRunning() and n < 200 do n = n + 1; clock = clock + 16; fire("OnTick") end
STOPZ0 = #ZOMBIES
TestGround.stop("test stop")
STOPZ1 = #ZOMBIES
FREEZE = nil
""")
files = L.eval('FILES')
st_, _ = rep_and_trace('TestGround_stopf_')
check(L.eval('STOPZ0') > 0 and L.eval('STOPZ1') == 0 and 'cleaned up at the end of the run:' in st_ and 'zombies removed' in st_, 'stop mid-fight: the spawned zombies are removed and the report says so (%s -> %s)' % (L.eval('STOPZ0'), L.eval('STOPZ1')))

# the banner: what's running, in words
L.execute("""
local K = TestGround.K
local r = { phase = "step", si = 2, steps = { {kind="idle", text="idle 2 a", pass=1}, {kind="drivefast", text="drivefast 60 93 drive_human", tag="drive_human", pass=1, t0=0} }, plan = { label = "x", rep = 1 } }
BN1, BN2 = K.bannerText(r, 12500)
r.phase = "gap"; BN3, BN4 = K.bannerText(r, 0)
""")
check(L.eval('BN1') == 'TEST: drive_human (drive)' and 'step 2 of 2, 12 s' in L.eval('BN2') and L.eval('BN4') == 'next: drivefast 60 93 drive_human', 'banner: names the test, its group, the step number and the time (%s / %s)' % (L.eval('BN1'), L.eval('BN2')))

# 1.13.2: the shipped drive check plan parses, with both drives on the fixed baseline's road
L.globals().DRVLINES = L.table_from(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'TestGround/42/media/TestGround/drive.txt')).read().split('\n'))
L.execute("""
local pl = TestGround.parsePlan(DRVLINES)
DRV_N, DRV_ERR, DRV_ROAD = #pl.steps, #pl.errors, #pl.fastroad
""")
check(L.eval('DRV_N') == 2 and L.eval('DRV_ERR') == 0 and L.eval('DRV_ROAD') == 10, 'drive check plan: 2 drives (120 and 93 km/h) on the 10-point Dixie road, no errors')

# 1.13.2: the gear plan: goggles on and off, single steps beside a parked car
L.globals().GEARLINES = L.table_from(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'TestGround/42/media/TestGround/gear.txt')).read().split('\n'))
L.execute("""
local smOld = getScriptManager
function getScriptManager()
  local sm = smOld()
  sm.FindItem = function(_, id) return id == "Base.NightVisionGoggles" and {} or nil end
  return sm
end
local addOld = INV.AddItem
INV.AddItem = function(self, id)
  if id == "Base.NightVisionGoggles" then
    local g = { id = id }; g.getBodyLocation = function() return "Eyes" end
    table.insert(self.items, g); return g end
  return addOld(self, id)
end
WORNS, UNWORNS = 0, 0
player.setWornItem = function(_, loc, it) WORNS = WORNS + 1 end
player.removeWornItem = function(_, it) UNWORNS = UNWORNS + 1 end
FILES = {}; P.x, P.y = 50.5, 50.5; CAR = nil; P.vehicle = nil
local pl = GEARLINES
local out = {}
for i = 1, #pl do local l = pl[i]; if string.find(l, "^start") then l = "start = 50,50,0" end; if string.find(l, "^settle") then l = "settle = 1" end; out[#out + 1] = l end
FILES["TestGround_gear.txt"] = out
INV0 = #INV.items
""")
bridge('run TestGround_gear.txt')
L.execute('local n = 0 while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; fire("OnTick") end')
files = L.eval('FILES')
gr, _ = rep_and_trace('TestGround_gear_')
grl = [l for l in gr.split('\n') if l.startswith('== ')]
print(grl)
check(len(grl) == 3 and 'Base.NightVisionGoggles put on 5 times and taken off 5 times' in grl[1] and _re.search(r'Base.SportsCar parked beside you .*, 20 single steps along it over 7 squares', grl[2]) is not None and L.eval('#INV.items') == L.eval('INV0'),
      'gear plan: goggles worn and taken off every 3 s, single steps beside a parked car, goggles taken away after (%s)' % grl[1:])

# 1.13.3/1.13.13: viewpoint = third|first through Project Viewpoint's View.cycle()/next(), modelled on
# Viewpoint 0.1.6.1's classes: cycle() only asks, the ask is taken on the next rendered frame (two in one
# frame are one), an ask while the first-run setup is due is dropped, and third person is the saved
# setting camera.thirdPersonOnFoot (first -> third turns it on; with it on, isometric goes to third)
L.execute("""
VP = { enabled = false, third = false, onFoot = false, ask = false, block = 0, cycles = 0, on = true }
Viewpoint = { View = {
  next = function() if not VP.enabled then return "first" elseif VP.third then return "isometric" else return "third" end end,
  cycle = function() VP.ask = true end,
} }
Events.OnRenderTick.Add(function()
  if not VP.on then return end
  local a = VP.ask; VP.ask = false
  if a and VP.enabled and not VP.third then VP.onFoot = not VP.onFoot; VP.cycles = VP.cycles + 1
  elseif a then
    if VP.block > 0 then VP.block = VP.block - 1
    else if not VP.enabled then VP.third = false end; VP.enabled = not VP.enabled; VP.cycles = VP.cycles + 1 end
  end
  if VP.enabled then VP.third = VP.onFoot end
end)
function VPVIEW() if not VP.enabled then return "isometric" elseif VP.third then return "third" else return "first" end end
function VPRUN()
  local n = 0
  VMID = nil
  while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; fire("OnRenderTick"); fire("OnTick"); if TestGround.isRunning() and VMID == nil and VPVIEW() ~= "isometric" then VMID = VPVIEW() end end
  for i = 1, 300 do clock = clock + 16; fire("OnRenderTick") end
end
VP.block = 1
FILES = {}; P.x, P.y = 50.5, 50.5
FILES["TestGround_vp.txt"] = { "label = vp", "start = 50,50,0", "settle = 1", "viewpoint = third", "step = idle 2 still" }
""")
bridge('run TestGround_vp.txt')
L.execute("VPRUN()")
files = L.eval('FILES')
vr, vtr = rep_and_trace('TestGround_vp_')
vtr = '\n'.join(vtr)
check(L.eval('VPVIEW()') == 'isometric' and L.eval('VP.cycles') == 3 and 'viewpoint: third view on after 2 cycles of Viewpoint.View in' in vr and 'zoom: left alone' in vr
      and 'Viewpoint.View has cycle() next(); isometric now, third wanted' in vtr and 'ask (2 asks)' in vtr,
      'viewpoint = third (1.13.13): the setup drops the first ask, it is asked again; two cycles to third, one back to isometric after the run (%s, %s)' % (L.eval('VP.cycles'), [l for l in vr.split('\n') if 'viewpoint' in l]))
L.execute("VP.on = false; Viewpoint = nil")
bridge('run TestGround_vp.txt')
L.execute('local n = 0 while TestGround.isRunning() and n < 5000 do n = n + 1; clock = clock + 16; fire("OnTick") end')
files = L.eval('FILES')
vr2, _ = rep_and_trace('TestGround_vp_')
check("Project Viewpoint isn't loaded" in vr2 and '== pass 1 step 1' in vr2, 'viewpoint without the mod: said once, the run goes on isometric')

# 1.13.3: TestGround.viewpoint (from Autorun's flag) applies when the plan has no viewpoint line
L.execute("""
VP.on, VP.enabled, VP.third, VP.onFoot, VP.cycles, VP.block = true, false, false, false, 0, 0
Viewpoint = { View = {
  next = function() if not VP.enabled then return "first" elseif VP.third then return "isometric" else return "third" end end,
  cycle = function() VP.ask = true end } }
FILES["TestGround_vp2.txt"] = { "label = vp2", "start = 50,50,0", "settle = 1", "step = idle 2 still" }
TestGround.viewpoint = "first"
""")
bridge('run TestGround_vp2.txt')
L.execute('VPRUN()')
files = L.eval('FILES')
vr3, _ = rep_and_trace('TestGround_vp2_')
check('viewpoint: first view on after 1 cycle' in vr3 and L.eval('VMID') == 'first' and L.eval('VP.cycles') == 3 and L.eval('VPVIEW()') == 'isometric' and L.eval('VP.onFoot'),
      'viewpoint from the Autorun flag: first person in 1 cycle, then one cycle a frame through third back to isometric (%s cycles)' % L.eval('VP.cycles'))
# 1.13.13: with camera.thirdPersonOnFoot on (left by the run above), first person can't be reached: said so
bridge('run TestGround_vp2.txt')
L.execute('VPRUN(); TestGround.viewpoint = nil; Viewpoint = nil; VP.on = false')
files = L.eval('FILES')
vr4, _ = rep_and_trace('TestGround_vp2_')
check('COULD NOT reach the first view (cycling goes isometric -> third -> isometric and never to first' in vr4 and 'thirdPersonOnFoot is on' in vr4 and L.eval('VPVIEW()') == 'isometric',
      'viewpoint = first with third person on foot saved: says why it stays isometric (%s)' % [l for l in vr4.split('\n') if 'viewpoint' in l])

# 1.13.4: the lateral limits are shares of the half-width; the drive view draws without errors
L.execute("""
local K = TestGround.K
LS7, LH7, LB7 = K.latLimits(7)
LS20, LH20, LB20 = K.latLimits(20)
""")
check(abs(L.eval('LS7') - 1.225) < 0.01 and abs(L.eval('LH7') - 2.8) < 0.01 and abs(L.eval('LB7') - 0.525) < 0.01 and abs(L.eval('LH20') - 8) < 0.01,
      'lateral limits: 35%% / 80%% / 15%% of the half-width (7 wide: %.2f / %.2f / %.2f)' % (L.eval('LS7'), L.eval('LH7'), L.eval('LB7')))
L.globals().DVLINES = L.table_from(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'TestGround/42/media/TestGround/driveview.txt')).read().split('\n'))
L.execute("""
local pl = TestGround.parsePlan(DVLINES)
DV_N, DV_ERR, DV_ON, DV_SHOT = #pl.steps, #pl.errors, pl.driveview, pl.screenshot and pl.screenshot.every
RECTS, TEXTS = 0, {}
UIFont = UIFont or { Medium = 1, Large = 2, Small = 0 }
local coreOld = getCore
function getCore() local c = coreOld(); c.getScreenHeight = c.getScreenHeight or function() return 1080 end; c.getScreenWidth = c.getScreenWidth or function() return 1920 end; return c end
function getRenderer() return { renderRect = function(self, x, y, w, h, r, g, b, a) RECTS = RECTS + 1 end } end
function isoToScreenX(p, x, y, z) return (x - y) * 32 end
function isoToScreenY(p, x, y, z) return (x + y) * 16 end
local tmOld = getTextManager
function getTextManager() return { getFontHeight = function() return 18 end, DrawString = function(self, f, x, y, s) TEXTS[#TEXTS + 1] = s end,
  DrawStringCentre = function() end, MeasureStringX = function() return 100 end } end
FILES = {}; P.x, P.y = 50.5, 50.5; CAR = nil; P.vehicle = nil; CARDRIFT = 2
FILES["TestGround_dv.txt"] = {"label = dv", "settle = 1", "start = 50,50,0", "driveview = 1", "step = drivefast 30 120 drive_view", "fastname = Mock Road", "fastwidth = 8", "fastroad = 1000,302,0", "fastroad = 1700,302,0"}
""")
check(L.eval('DV_N') == 1 and L.eval('DV_ERR') == 0 and L.eval('DV_ON') == True and L.eval('DV_SHOT') == 2, 'drive view plan: 1 drive, the view on, a screenshot every 2 s')
bridge('run TestGround_dv.txt')
L.execute("""
local n = 0
DVDRAWN, DVAIM = 0, 0
while TestGround.isRunning() and n < 40000 do
  n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick")
  if n % 10 == 0 then
    local before = #TEXTS
    TestGround.K.drawDriveView()
    if #TEXTS > before then DVDRAWN = DVDRAWN + 1; DVLAST = TEXTS[#TEXTS - 2] end
    local st = TestGroundInternal.S.run and TestGroundInternal.S.run.steps[1]
    local d = st and st.dv
    if d then DVAIM = math.max(DVAIM, math.abs(TestGroundInternal.wrapAngle(d.want - d.road)) * 180 / math.pi) end
    if d and d.tiles and d.kmh > 60 then
      local fx, fy = math.cos(d.road), math.sin(d.road)
      for _, p in ipairs(d.tiles) do DVAHEAD = math.max(DVAHEAD or 0, (p[1] - d.x) * fx + (p[2] - d.y) * fy) end
    end
  end
end
CARDRIFT = nil
""")
print(L.eval('DVLAST'))
check(L.eval('DVDRAWN') > 50 and L.eval('RECTS') > 1000 and 'wanted turn' in (L.eval('DVLAST') or ''), 'drive view: drawn during the drive (%d frames, %d dots)' % (L.eval('DVDRAWN'), L.eval('RECTS')))
check((L.eval('DVAHEAD') or 0) > 20, 'drive view: street squares reach out to the aim point at speed (%.0f tiles ahead)' % (L.eval('DVAHEAD') or 0))
check(L.eval('DVAIM') <= 10.01, 'torque steering aims at most 10 deg off the road on a straight (max %.1f)' % L.eval('DVAIM'))

# 1.13.5: a divided road (two 7-wide carriageways, a 2-tile unpaved median on the map's line): the car
# holds the right-hand carriageway's centre, and the limits come from its 7 tiles, not the plan's 16
L.execute("""CAR = nil; P.vehicle = nil; MAXV = 0; MAPDIV = true; CARDRIFT = 0.3
FILES["TestGround_div.txt"] = {"label = div", "settle = 1", "start = 50,50,0", "step = drivefast 30 120 drive_div", "fastname = Mock Divided", "fastwidth = 16", "fastroad = 5000,5407,0", "fastroad = 5700,5407,0"}""")
bridge('run TestGround_div.txt')
L.execute("""
local n = 0
DIVY, DIVN, DIVW = 0, 0, nil
while TestGround.isRunning() and n < 30000 do
  n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick")
  if CAR and P.vehicle == CAR and CAR.speed > 20 then DIVY, DIVN = DIVY + CAR.py, DIVN + 1 end
  local st = TestGroundInternal.S.run and TestGroundInternal.S.run.steps[1]
  if st and st.laneW then DIVW = st.laneW end
end
CARDRIFT = nil; MAPDIV = false
""")
files = L.eval('FILES')
dtext, dtr = rep_and_trace('TestGround_div_')
dl = [l for l in dtr if 'divided street' in l]
print(dl[:1])
dy = L.eval('DIVY') / max(1, L.eval('DIVN'))
check(dl and 'holding the right-hand one, centre 5.0' in dl[0] and '2-tile median' in dl[0], 'divided road: the right-hand carriageway is held (%s)' % (dl[:1],))
check(L.eval('DIVN') > 100 and abs(dy - 5412.5) < 1.0, 'divided road: the car drives on the right-hand carriageway centre (mean y %.2f, centre 5412.5)' % dy)
check(L.eval('DIVW') is not None and abs(L.eval('DIVW') - 7) < 1, 'divided road: limits from the 7-wide carriageway (%s)' % L.eval('DIVW'))

# 1.13.7: with Test Ground Capture (global TGCapture) the shots go through it (mode from the plan), the
# drive view overlay is sent to it while it wants it, and the game's screenshot is the fallback
L.execute("""CAR = nil; P.vehicle = nil; MAXV = 0; MAPST = true; CARDRIFT = 0.3
SHOTS = {}; function takeScreenshot(n) table.insert(SHOTS, n) end
CAPREQ, CAPRECT, CAPTEXT, CAPEND, CAPFAIL = {}, 0, 0, 0, false
TGCapture = { request = function(n, m) if CAPFAIL then error("boom") end; table.insert(CAPREQ, m .. " " .. n); return true end,
  lastResult = function() return "x.png: world 1600x900, 80% lit" end, status = function() return "TestGroundCapture 1.0.0: swap patch active" end,
  wantsOverlay = function() return true end, beginOverlay = function() end, rect = function() CAPRECT = CAPRECT + 1 end,
  text = function() CAPTEXT = CAPTEXT + 1 end, endOverlay = function() CAPEND = CAPEND + 1 end }
FILES["TestGround_cap.txt"] = {"label = cap", "settle = 1", "start = 50,50,0", "driveview = 1", "screenshot = 2 drivefast", "capture = both", "step = drivefast 20 120 drive_cap", "fastname = Mock Road", "fastwidth = 8", "fastroad = 1000,302,0", "fastroad = 1700,302,0"}""")
bridge('run TestGround_cap.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 30000 do
  n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick")
  if n % 10 == 0 then TestGround.K.drawDriveView() end
end
""")
files = L.eval('FILES')
ctext, ctr = rep_and_trace('TestGround_cap_')
creq = list(L.eval('CAPREQ').values())
print(creq[:2], [l for l in ctext.split('\n') if l.startswith('screenshots:')])
check(len(creq) >= 5 and all(c.startswith('both TestGround_cap_') for c in creq) and len(L.eval('SHOTS')) == 0,
      'capture: shots go through Test Ground Capture with the plan mode (%d, game shots %d)' % (len(creq), len(L.eval('SHOTS'))))
check(L.eval('CAPRECT') > 100 and L.eval('CAPTEXT') > 10 and L.eval('CAPEND') > 10, 'capture: the drive view overlay is sent (%d rects, %d texts)' % (L.eval('CAPRECT'), L.eval('CAPTEXT')))
check('taken by Test Ground Capture, capture = both' in ctext and any('capture: x.png' in l for l in ctr), 'capture: the report and trace name it')
check('NOT A MEASUREMENT: ' in ctext and 'screenshots in this step' in ctext, 'capture: a step with screenshots says its fps includes them')
L.execute("""CAR = nil; P.vehicle = nil; MAXV = 0; CAPFAIL = true; SHOTS = {}
FILES["TestGround_cap2.txt"] = {"label = cap2", "settle = 1", "start = 50,50,0", "screenshot = 2 drivefast", "step = drivefast 12 120 drive_cap", "fastname = Mock Road", "fastwidth = 8", "fastroad = 1000,302,0", "fastroad = 1700,302,0"}""")
bridge('run TestGround_cap2.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 30000 do n = n + 1; clock = clock + 16; stepWalk(); stepCar(0.016); fire("OnTick") end
CARDRIFT = nil; MAPST = false; TGCapture = nil; takeScreenshot = nil
""")
files = L.eval('FILES')
c2text, c2tr = rep_and_trace('TestGround_cap2_')
check(len(L.eval('SHOTS')) >= 3 and 'Test Ground Capture failed' in c2text, 'capture: a failing capture falls back to the game screenshot (%d)' % len(L.eval('SHOTS')))
# 1.13.11: plan "film = 30 1280" films the run through Test Ground Capture 1.0.2's film mode
L.execute("""FILMLOG = {}
TGCapture = { filmStart = function(d, f, w) table.insert(FILMLOG, "start " .. d .. " " .. f .. " " .. w); return true end,
  filmTag = function(t) table.insert(FILMLOG, "tag " .. t) end, filmStop = function() table.insert(FILMLOG, "stop"); return true end,
  filmStatus = function() return "filming" end, filmTake = function() return "12 frames written, 0 dropped" end,
  filmTotal = function() return "24 frames written, 0 dropped" end, status = function() return "x" end, wantsOverlay = function() return false end }
FILES["TestGround_film.txt"] = {"label = film", "settle = 1", "start = 50,50,0", "zombies = none", "film = 30 1280", "step = idle 3 still_a", "step = idle 3 still_b"}""")
bridge('run TestGround_film.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; stepWalk(); stepZombies(); fire("OnTick") end
TGCapture = nil
""")
files = L.eval('FILES')
fmt_, _ = rep_and_trace('TestGround_film_')
flog = list(L.eval('FILMLOG').values())
print(flog)
check(flog[0].startswith('start film_') and flog[0].endswith(' 30 1280') and 'tag settle' in flog and 'tag still_a' in flog and 'tag gap' in flog and flog[-1] == 'stop'
      and fmt_.count('film: 12 frames written') == 2 and 'film: run total 24 frames written' in fmt_ and 'NOT A MEASUREMENT: filmed' in fmt_,
      'film: started with the plan rate and width, tagged per step (settle, steps, gap), per-step and total lines, stopped at the end')

# 1.13.13 (review of 1.13.12): filmAlive goes on through a 15 s pause (render tick only); a false answer is traced once
L.execute("""FILMLOG = {}; ALIVES = 0; ALIVE_OK = true
TGCapture = { filmStart = function(d, f, w) return true end, filmTag = function(t) end, filmStop = function() return true end,
  filmAlive = function() ALIVES = ALIVES + 1; return ALIVE_OK end,
  filmStatus = function() return "stopped: no word from Test Ground for 10 s" end, filmTake = function() return "1 frames" end,
  filmTotal = function() return "2 frames" end, status = function() return "x" end, wantsOverlay = function() return false end }
FILES["TestGround_filmp.txt"] = {"label = filmp", "settle = 1", "start = 50,50,0", "zombies = none", "film = 30 1280", "step = idle 30 still_a"}""")
bridge('run TestGround_filmp.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 300 do n = n + 1; clock = clock + 16; fire("OnRenderTick"); fire("OnTick") end
ALIVE0 = ALIVES; paused = true
for i = 1, 940 do clock = clock + 16; fire("OnRenderTick") end
ALIVE1 = ALIVES; paused = false; ALIVE_OK = false
local m = 0
while TestGround.isRunning() and m < 20000 do m = m + 1; clock = clock + 16; fire("OnRenderTick"); fire("OnTick") end
TGCapture = nil
""")
files = L.eval('FILES')
_, fptr = rep_and_trace('TestGround_filmp_')
check(L.eval('ALIVE1') - L.eval('ALIVE0') >= 13 and sum('Test Ground Capture stopped the film: stopped: no word' in l for l in fptr) == 1,
      'film (1.13.13): filmAlive every second through a 15 s pause, and a stopped film traced once (%s calls in the pause)' % (L.eval('ALIVE1') - L.eval('ALIVE0')))

# 1.13.16: a filmStart refused while the last film is still stopping (Capture 1.0.5) is tried again
L.execute("""FSTARTS = 0
TGCapture = { filmStart = function(d, f, w) FSTARTS = FSTARTS + 1; return FSTARTS >= 3 end, filmTag = function(t) end, filmStop = function() return true end,
  filmAlive = function() return true end,
  filmStatus = function() if FSTARTS < 3 then return "filmStart refused: film run_1 is still stopping (300 ms since its stop)" end return "filming" end,
  filmTake = function() return "1 frames" end, filmTotal = function() return "2 frames" end, status = function() return "x" end, wantsOverlay = function() return false end }
FILES["TestGround_filmr.txt"] = {"label = filmr", "settle = 3", "start = 50,50,0", "zombies = none", "film = 30 1280", "step = idle 2 still_a"}""")
bridge('run TestGround_filmr.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 20000 do n = n + 1; clock = clock + 16; fire("OnRenderTick"); fire("OnTick") end
TGCapture = nil""")
files = L.eval('FILES')
frt, frtr = rep_and_trace('TestGround_filmr_')
check(L.eval('FSTARTS') == 3 and any('film: started on a later try' in l for l in frtr) and 'film: run total' in frt,
      'film (1.13.16): refused while the last film is still stopping, started on a later try (%s starts)' % L.eval('FSTARTS'))

# 1.13.15: plan "ui = hide" hides the open game windows for the run and shows them again after
L.execute("""
local function el(tbl) local e = { vis = true, t = tbl }; e.getTable = function() return e.t end; e.isVisible = function() return e.vis end; e.setVisible = function(_, v) e.vis = v end; return e end
UIW1 = el({ Type = "ISCharacterInfoWindow", titlebarbkg = {} }); UIW2 = el({ Type = "ISInventoryPage", titlebarbkg = {} }); UIW3 = el({ Type = "TestGroundPanel", titlebarbkg = {} }); UIW4 = el({ Type = "ISButton" })
local ui = { UIW1, UIW2, UIW3, UIW4 }
UIManager = UIManager or {}
UIManager.getUI = function() return { size = function() return #ui end, get = function(_, i) return ui[i + 1] end } end
UIMID = nil
FILES["TestGround_uih.txt"] = {"label = uih", "settle = 1", "start = 50,50,0", "zombies = none", "ui = hide", "step = idle 2 still_a"}""")
bridge('run TestGround_uih.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 5000 do n = n + 1; clock = clock + 16; fire("OnRenderTick"); fire("OnTick"); if n == 50 then UIMID = (not UIW1.vis) and (not UIW2.vis) and UIW3.vis and UIW4.vis end end
UIManager.getUI = nil""")
files = L.eval('FILES')
uht, _ = rep_and_trace('TestGround_uih_')
check(L.eval('UIMID') == True and L.eval('UIW1.vis') and L.eval('UIW2.vis') and 'ui: 2 game windows hidden for the run (ISCharacterInfoWindow, ISInventoryPage)' in uht,
      'ui = hide (1.13.15): game windows hidden during the run (not Test Ground\'s, not buttons) and shown again after')

# 1.13.19: other mods' first-load pop-ups are closed with their own close for the first minute of a run
L.execute("""
local function el(tbl) local e = { vis = true, t = tbl }; e.getTable = function() return e.t end; e.isVisible = function() return e.vis end; e.setVisible = function(_, v) e.vis = v end; tbl.setVisible = function(_, v) e.vis = v end; tbl.removeFromUIManager = function() e.removed = true end; return e end
local RTClass = { createChildren = function() end }
RTClass.__index = RTClass
local VPClass = { render = function() end }
VPClass.__index = VPClass
local FNS = {}
FNS[RTClass.createChildren] = "C:/Program Files (x86)/Steam/steamapps/workshop/content/108600/123/mods/RadioTrader/42/media/lua/client/RT_Welcome.lua"
FNS[VPClass.render] = "C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid/media/lua/client/ISUI/ISCharacterInfoWindow.lua"
getFilenameOfClosure = function(f) return FNS[f] end
local rt = setmetatable({ Type = "RadioTraderWelcome", titlebarbkg = {} }, RTClass)
rt.close = function(self) POPC = (POPC or 0) + 1; self:setVisible(false) end
PUP1 = el(rt)
PUP2 = el(setmetatable({ Type = "ISCharacterInfoWindow", titlebarbkg = {} }, VPClass))
PUP3 = el({ Type = "ISModalRichText" })
PUP4 = el({ Type = "ISButton" })
local VClass = { render = function() end }; VClass.__index = VClass; FNS[VClass.render] = "C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid/media/lua/client/ISUI/ISWelcome.lua"
PUP5 = el(setmetatable({ Type = "VanillaWelcomeBox" }, VClass))
local ui = { PUP2, PUP4 }
UIManager = UIManager or {}
UIManager.getUI = function() return { size = function() return #ui end, get = function(_, i) return ui[i + 1] end } end
FILES["TestGround_pop.txt"] = {"label = pop", "settle = 3", "start = 50,50,0", "zombies = none", "step = idle 4 still_a"}""")
bridge('run TestGround_pop.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 5000 do n = n + 1; clock = clock + 16; fire("OnRenderTick"); fire("OnTick")
  if n == 60 then local l = UIManager.getUI(); local ui = {}; for i = 0, l:size() - 1 do ui[#ui + 1] = l:get(i) end; ui[#ui + 1] = PUP1; ui[#ui + 1] = PUP3; ui[#ui + 1] = PUP5; UIManager.getUI = function() return { size = function() return #ui end, get = function(_, i) return ui[i + 1] end } end end end
UIManager.getUI = nil; getFilenameOfClosure = nil""")
files = L.eval('FILES')
pot, _ = rep_and_trace('TestGround_pop_')
check(not L.eval('PUP1.vis') and L.eval('PUP2.vis') and L.eval('PUP4.vis') and L.eval('PUP3.vis') and L.eval('PUP5.vis')
      and 'popups: shut RadioTraderWelcome from RadioTrader' in pot and 'ISModalRichText' not in pot and 'VanillaWelcomeBox' not in pot,
      'popups (1.13.19): a mod\'s pop-up opened after load is closed with its own close, vanilla windows, dialogs and buttons stay (%s)' % [l for l in pot.split('\n') if 'popups' in l])

# 1.13.19: look S facing|mouse turns the view round and says how far it turned
L.execute("""
P.ang = 0
player.getDirectionAngle = function() return P.ang end
player.setDirectionAngle = function(_, a) P.ang = a end
player.getLookAngleRadians = function() return math.rad(P.ang) end
MOUSEN = 0
Mouse = { getX = function() return 100 end, getY = function() return 100 end, setXY = function(x, y) MOUSEN = MOUSEN + 1; MOUSEX = x end }
FILES["TestGround_lk.txt"] = {"label = lk", "settle = 1", "start = 50,50,0", "zombies = none", "step = look 6 look_facing", "step = look 4 look_mouse"}""")
bridge('run TestGround_lk.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 8000 do n = n + 1; clock = clock + 16; fire("OnRenderTick"); fire("OnTick") end
player.getDirectionAngle = nil; player.setDirectionAngle = nil; player.getLookAngleRadians = nil; Mouse = nil""")
files = L.eval('FILES')
lkt, _ = rep_and_trace('TestGround_lk_')
mt = _re.search(r'looked round by facing for 6 s: facing turned (\d+) deg', lkt)
check(mt and 680 <= int(mt.group(1)) <= 740 and 'looked round by mouse for 4 s: facing turned 0 deg, look angle turned 0 deg' in lkt and L.eval('MOUSEN') > 100 and L.eval('MOUSEX') == 100,
      'look (1.13.19): facing turns two full circles, mouse moves the cursor and puts it back, each says how far the view turned (%s)' % [l for l in lkt.split('\n') if 'looked' in l])

# 1.13.20: end-of-run screen with the save tested and a countdown; display names in the report
L.execute("""
ENDSCREENS = 0
getCurrentSaveName = function() return "TG Benchmark Lumberjack 1" end
TestGround.sourceSave = "Lumberjack"
FILES["TestGround_es.txt"] = {"label = es", "settle = 1", "start = 50,50,0", "zombies = none", "endscreen = 5", "step = walk 1 walk"}""")
bridge('run TestGround_es.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 8000 do n = n + 1; clock = clock + 16; fire("OnRenderTick"); fire("OnTick") end
LASTEND:render(); ES_OK = LASTEND.drawn
getCurrentSaveName = nil; TestGround.sourceSave = nil""")
files = L.eval('FILES')
est, _ = rep_and_trace('TestGround_es_')
drawn = str(L.eval('ES_OK'))
check(L.eval('ENDSCREENS') == 1 and 'Save tested: Lumberjack' in drawn and 'Walk a short route' in drawn and 'name: Walk a short route' in est
      and 'save tested: Lumberjack (this run happened in the throwaway copy TG Benchmark Lumberjack 1)' in est,
      'end screen (1.13.20): shown once with the save chosen and a display name per step; the report names the save and the copy (%s)' % drawn[:120].replace('\n', ' | '))

L.execute("""
TestGround.trusted = nil
FILES["TestGround_es2.txt"] = {"label = es2", "settle = 1", "start = 50,50,0", "zombies = none", "step = walk 1 walk"}""")
bridge('run TestGround_es2.txt')
L.execute("""
local n = 0
while TestGround.isRunning() and n < 8000 do n = n + 1; clock = clock + 16; fire("OnRenderTick"); fire("OnTick") end
ES2_LEFT = LASTEND.left; ES2_N = ENDSCREENS""")
check(L.eval('ES2_LEFT') is None, 'end screen (1.13.21): a run started by a command (Bridge) with no endscreen line gets no closing countdown (%s screens, left %s)' % (L.eval('ES2_N'), L.eval('ES2_LEFT')))

fails = L.eval('PCALL_FAILS')
fl = sorted(((int(fails[k]), str(k)) for k in fails.keys()), reverse=True)
print('--- caught errors (each is a stack trace in game) ---'); print('\n'.join('%6d  %s' % f for f in fl[:25])); print('---')
check(not any('getVehicleContainer' in m or 'getFloor' in m for _, m in fl), 'no caught errors from unloaded squares (clearAhead, street checks)')

print('ALL OK' if ok else 'SOME FAILED')

