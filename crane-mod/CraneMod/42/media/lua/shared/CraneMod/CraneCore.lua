-- Crane mod core: layout, state, path checks, raise/lower, build callbacks.
-- Runs on both sides. World changes happen in timed action complete(),
-- which runs on the server in multiplayer and locally in singleplayer.

CraneMod = CraneMod or {}
local C = CraneMod

C.KEY = "CraneMod"
-- Our own tile names (media/cranemod.tiles), drawn with vanilla images. B42 lets
-- each tile appear in only one build script slot, so each facing has its own copy.
C.WINCH_SPRITES = {
    cranemod_winch_e_53 = true, cranemod_winch_w_53 = true,
    cranemod_winch_s_52 = true, cranemod_winch_n_52 = true,
}
C.LANDING_SPRITE = "cranemod_column_e_48"
C.BOX_SPRITE = "cranemod_box_19"
C.HOOK_SPRITE = "cranemod_hook_57"
-- Per facing: the chain under the jib (box down or hook only), the hanging box
-- (box up) and the extra chain wound on the drum (box up, an overlay on the winch).
function C.chainSprite(L) return "cranemod_chain_" .. C.faceLetter(L) .. "_0" end
function C.hangingSprite(L) return "cranemod_hang_" .. C.faceLetter(L) .. "_0" end
function C.drumSprite(L) return "cranemod_drum_" .. C.faceLetter(L) .. "_0" end
C.CRANK_ANIM = "UseHandPress"
-- Sound looped while cranking; nil means silent. Pick one with Debug: Test Sound.
C.CRANK_SOUND = "VehicleTowAttach"
-- Sound looped while dismantling: the welding torch, as when building.
C.DISMANTLE_SOUND = "BlowTorch"
C.DEBUG_SOUNDS = {
    "VehicleWindowHandleOpen", "VehicleWindowHandleClose", "SharpenBladeGrindstone",
    "GarageDoorOpen", "MetalGateOpen", "VehicleTowAttach", "CrateMetalOpen",
    "CraftMetalSawing", "Dismantle", "BlowTorch",
}
C.DEBUG_ANIMS = { "UseGrindingStone", "UseStoneQuern", "UseHandPress", "UseSpinningWheel", "Loot", "Build", "disassemble", "Welding" }
C.DIRS = { E = { 1, 0 }, W = { -1, 0 }, S = { 0, 1 }, N = { 0, -1 } }

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

function C.sandbox(name, default)
    local t = SandboxVars and SandboxVars.Crane
    local v = t and t[name]
    if v == nil then return default end
    return v
end

function C.capacity()
    return C.sandbox("BoxCapacity", 100)
end

function C.hasSkill(character, which)
    if not character then return false end
    if which == "winch" then
        return character:getPerkLevel(Perks.MetalWelding) >= C.sandbox("WinchWeldingLevel", 3)
    end
    return character:getPerkLevel(Perks.Woodwork) >= C.sandbox("BoxWoodworkLevel", 3)
end

-- Crane data lives in the object's modData under one key.
function C.data(obj)
    if not obj or not obj.getModData then return nil end
    if obj.hasModData and not obj:hasModData() then return nil end
    local md = obj:getModData()
    return md and md[C.KEY] or nil
end

function C.setData(obj, t)
    obj:getModData()[C.KEY] = t
end

function C.square(x, y, z)
    return getCell():getGridSquare(x, y, z)
end

function C.findRole(sq, role)
    if not sq then return nil end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local d = C.data(o)
        if d and d.role == role then return o, d end
    end
    return nil
end

local flagCache = {}
local function flag(name)
    if flagCache[name] == nil then
        local ok, f = pcall(function() return IsoFlagType[name] end)
        flagCache[name] = (ok and f) or false
    end
    return flagCache[name] or nil
end

local function propsHas(props, name)
    local f = flag(name)
    if not f or not props then return false end
    return props:has(f)
end

local function isSolidObject(obj)
    local spr = obj:getSprite()
    local props = spr and spr:getProperties()
    if not props then return false end
    return propsHas(props, "solid") or propsHas(props, "solidtrans")
end

-- Ladders stand out into their square, so a box there would overlap one and
-- get in the way of climbing.
local function isLadder(obj)
    local spr = obj:getSprite()
    local props = spr and spr:getProperties()
    if not props then return false end
    return props:has("ladderN") or props:has("ladderS") or props:has("ladderE") or props:has("ladderW")
end

-- ---------------------------------------------------------------------------
-- Layout. The winch holds dx/dy: the landing is winch + dir, the rope column
-- is landing + dir (air tile on the winch floor, box tile one floor down).
-- ---------------------------------------------------------------------------

function C.layout(winch)
    local d = C.data(winch)
    if not d or d.role ~= "winch" or not d.dx then return nil end
    local sq = winch:getSquare()
    if not sq then return nil end
    local L = { winch = winch, x = sq:getX(), y = sq:getY(), z = sq:getZ(), dx = d.dx, dy = d.dy }
    L.lx, L.ly = L.x + d.dx, L.y + d.dy
    L.ax, L.ay = L.lx + d.dx, L.ly + d.dy
    L.bz = L.z - 1
    return L
end

function C.faceLetter(L)
    if L.dx == 1 then return "e" end
    if L.dx == -1 then return "w" end
    if L.dy == 1 then return "s" end
    return "n"
end

-- Find the winch from any crane object (winch, landing, hook, box, hanging box).
function C.winchFrom(obj)
    local d = C.data(obj)
    if not d then return nil end
    if d.role == "winch" then return obj end
    local sq = obj:getSquare()
    if not sq then return nil end
    if d.role == "landing" then
        if not d.dx then return nil end
        return (C.findRole(C.square(sq:getX() - d.dx, sq:getY() - d.dy, sq:getZ()), "winch"))
    end
    if d.wx then
        return (C.findRole(C.square(d.wx, d.wy, d.wz), "winch"))
    end
    return nil
end

-- Fills in the squares and parts and returns "up", "down" or "none".
function C.state(L)
    L.landingSq = C.square(L.lx, L.ly, L.z)
    L.airSq = C.square(L.ax, L.ay, L.z)
    L.groundSq = C.square(L.ax, L.ay, L.bz)
    L.landing = C.findRole(L.landingSq, "landing")
    L.hanging = C.findRole(L.airSq, "hanging")
    L.chain = C.findRole(L.airSq, "chain")
    L.box = C.findRole(L.groundSq, "box")
    L.hook = C.findRole(L.groundSq, "hook")
    if L.hanging then return "up" end
    if L.box then return "down" end
    return "none"
end

function C.loadWeight(L, state)
    local obj
    if state == "up" then obj = L.landing else obj = L.box end
    local c = obj and obj:getContainer()
    if not c then return 0 end
    return c:getCapacityWeight()
end

function C.crankTime(L, state)
    local w = C.loadWeight(L, state)
    return math.floor(C.sandbox("CrankBaseTime", 100) + C.sandbox("CrankTimePerWeight", 3) * w)
end

-- ---------------------------------------------------------------------------
-- Path checks
-- ---------------------------------------------------------------------------

-- The edge the rope crosses between the landing and the air tile.
function C.edgeFor(lx, ly, dx, dy)
    if dx == 1 then return lx + 1, ly, false end
    if dx == -1 then return lx, ly, false end
    if dy == 1 then return lx, ly + 1, true end
    return lx, ly, true
end

function C.edgeBlocked(esq, north)
    if not esq then return false end
    local p = esq:getProperties()
    local s = north and "N" or "W"
    if propsHas(p, "Wall" .. s) or propsHas(p, "WallNW") or propsHas(p, "DoorWall" .. s) or propsHas(p, "TallHoppable" .. s) then
        return true
    end
    local win = esq:getWindow(north and GridSquareEdgeFacingDirection.NORTH_SOUTH or GridSquareEdgeFacingDirection.EAST_WEST)
    if win then
        if win:isBarricaded() then return true end
        local smashed = win.isSmashed and win:isSmashed()
        if not (win:IsOpen() or smashed) then return true end
    end
    return false
end

-- Pre-existing roof tiles (roofs_* sheets) don't block the rope: the rope
-- passes through a porch or eave roof under a balcony.
function C.isRoof(o)
    local spr = o and o.getSprite and o:getSprite()
    local name = spr and spr:getName()
    return name ~= nil and string.find(string.lower(name), "^roofs?_") ~= nil
end

-- The air tile must have no floor and nothing solid (our hanging box and
-- roof tiles excepted).
function C.airBlocked(air)
    if not air then return false end
    local floor = air:getFloor()
    if floor and not C.isRoof(floor) then return true end
    if not floor and propsHas(air:getProperties(), "solidfloor") then return true end
    local objs = air:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if o ~= floor and not C.data(o) and not C.isRoof(o) and isSolidObject(o) then return true end
    end
    return false
end

-- The ground tile must exist, have a floor and nothing solid or a ladder (hook/box
-- excepted). allowLadder lets a box that already sits there be raised away.
function C.groundBlocked(ground, allowLadder)
    if not ground or not ground:getFloor() then return true end
    if ground:isVehicleIntersecting() then return true end
    local floor = ground:getFloor()
    local objs = ground:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if o ~= floor and not C.data(o) and (isSolidObject(o) or (not allowLadder and isLadder(o))) then return true end
    end
    return false
end

function C.pathClear(L)
    local ex, ey, north = C.edgeFor(L.lx, L.ly, L.dx, L.dy)
    if C.edgeBlocked(C.square(ex, ey, L.z), north) then return false end
    if C.airBlocked(L.airSq or C.square(L.ax, L.ay, L.z)) then return false end
    if C.groundBlocked(L.groundSq or C.square(L.ax, L.ay, L.bz), L.box ~= nil) then return false end
    return true
end

-- True when a square is a crane's rope tile or box tile, so nothing else may be built there.
function C.isReserved(sq)
    if not sq then return false end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    for _, d in pairs(C.DIRS) do
        for lz = z, z + 1 do
            local l, ld = C.findRole(C.square(x - d[1], y - d[2], lz), "landing")
            if l and ld.dx == d[1] and ld.dy == d[2] then return true end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Object factories
-- ---------------------------------------------------------------------------

local function transmitNew(obj)
    if isServer() then obj:transmitCompleteItemToClients() end
end

local function syncModData(obj)
    if isServer() or isClient() then obj:transmitModData() end
end

function C.ensureContainer(obj, sq)
    local c = obj:getContainer()
    if not c and instanceof(obj, "IsoThumpable") then
        obj:setIsContainer(true)
        c = obj:getContainer()
    end
    if not c then
        c = ItemContainer.new("crate", sq, obj)
        obj:setContainer(c)
    end
    c:setType("crate")
    c:setCapacity(C.capacity())
    c:setExplored(true)
    return c
end

local function newThumpable(sq, sprite)
    local t = IsoThumpable.new(getCell(), sq, sprite, false, {})
    t:setIsDismantable(false)
    t:setCanBarricade(false)
    t:setIsHoppable(false)
    return t
end

local function newLanding(L, withContainer)
    local old = L.landing and L.landing:getSprite()
    local sprite = (old and old:getName()) or C.LANDING_SPRITE
    local t = newThumpable(L.landingSq, sprite)
    t:setCanPassThrough(true)
    t:setIsThumpable(false)
    t:setBlockAllTheSquare(false)
    C.setData(t, { role = "landing", dx = L.dx, dy = L.dy })
    if withContainer then C.ensureContainer(t, L.landingSq) end
    return t
end

local function removeContainer(obj)
    if obj.removeAllContainers then
        obj:removeAllContainers()
    else
        obj:setContainer(nil)
    end
end

local function syncContainers(obj)
    if isServer() and obj.sendObjectChange then
        obj:sendObjectChange("containers")
    end
end

local function newBox(L, health, maxHealth)
    local t = newThumpable(L.groundSq, C.BOX_SPRITE)
    t:setCanPassThrough(false)
    t:setIsThumpable(true)
    t:setBlockAllTheSquare(true)
    t:setMaxHealth(maxHealth or 200)
    t:setHealth(health or t:getMaxHealth())
    t:setBreakSound("BreakObject")
    C.setData(t, { role = "box", wx = L.x, wy = L.y, wz = L.z })
    C.ensureContainer(t, L.groundSq)
    t:setExplored(true)
    return t
end

local function newTile(sq, sprite, data)
    local o = IsoObject.new(getCell(), sq, getSprite(sprite))
    C.setData(o, data)
    return o
end

local function moveItems(src, dst)
    if not src or not dst then return end
    local items = src:getItems()
    local list = {}
    for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
    for _, it in ipairs(list) do
        src:DoRemoveItem(it)
        dst:AddItem(it)
    end
end

local function refreshUI()
    if not isServer() and ISInventoryPage and ISInventoryPage.dirtyUI then
        ISInventoryPage.dirtyUI()
    end
end

-- The rope tile on the winch floor is open air, so its square may not exist yet.
local function airSquare(L)
    if not L.airSq then
        local air = getCell():createNewGridSquare(L.ax, L.ay, L.z, true)
        air:EnsureSurroundNotNull()
        L.airSq = air
    end
    return L.airSq
end

-- The chain hanging from the jib down to the hook or box (not while the box is up).
local function placeChain(L)
    if L.chain or L.hanging then return end
    local air = airSquare(L)
    local chain = newTile(air, C.chainSprite(L), { role = "chain", wx = L.x, wy = L.y, wz = L.z })
    air:AddTileObject(chain)
    transmitNew(chain)
    L.chain = chain
end

local function removeChain(L)
    if L.chain then
        L.airSq:transmitRemoveItemFromSquare(L.chain)
        L.chain = nil
    end
end

-- Extra chain drawn on the winch drum while the box is up.
local function setDrum(L, up)
    local winch = L.winch
    if not winch.setOverlaySprite then return end
    winch:setOverlaySprite(up and C.drumSprite(L) or nil, isServer())
end

local function spriteName(obj)
    local spr = obj and obj:getSprite()
    return spr and spr:getName() or nil
end

local function setSprite(obj, name)
    obj:setSprite(getSprite(name))
    if isServer() then obj:transmitUpdatedSpriteToClients() end
end

-- Brings a crane built before the current art up to date: the new hook and
-- hanging-box sprites, the chain under the jib and the wound drum. Returns true
-- when anything changed.
function C.upgrade(L)
    C.state(L)
    local changed = false
    if L.hook and spriteName(L.hook) ~= C.HOOK_SPRITE then
        setSprite(L.hook, C.HOOK_SPRITE)
        changed = true
    end
    if L.hanging and spriteName(L.hanging) ~= C.hangingSprite(L) then
        setSprite(L.hanging, C.hangingSprite(L))
        setDrum(L, true)
        changed = true
    end
    if (L.hook or L.box) and not L.chain and not L.hanging then
        placeChain(L)
        changed = true
    end
    return changed
end

function C.placeHook(L)
    C.state(L)
    if L.hook or L.box or L.hanging then return false end
    if not L.groundSq then return false end
    local hook = newTile(L.groundSq, C.HOOK_SPRITE, { role = "hook", wx = L.x, wy = L.y, wz = L.z })
    L.groundSq:AddTileObject(hook)
    transmitNew(hook)
    placeChain(L)
    return true
end

-- ---------------------------------------------------------------------------
-- Raise / lower / dismantle (authoritative side)
-- ---------------------------------------------------------------------------

function C.doRaise(L)
    if not L or C.state(L) ~= "down" then return false, "state" end
    if not L.landing then return false, "state" end
    if not C.pathClear(L) then return false, "blocked" end

    local box = L.box
    local wd = C.data(L.winch)
    wd.boxHealth = box:getHealth()
    wd.boxMaxHealth = box:getMaxHealth()

    -- The landing gets a container that holds the items while the box is up.
    -- It is changed in place: the winch and landing are one built object, and
    -- removing the landing would remove the winch with it.
    C.ensureContainer(L.landing, L.landingSq)
    moveItems(box:getContainer(), L.landing:getContainer())
    syncContainers(L.landing)

    L.groundSq:transmitRemoveItemFromSquare(box)
    L.box = nil

    local air = airSquare(L)
    removeChain(L)
    local hanging = newTile(air, C.hangingSprite(L), { role = "hanging", wx = L.x, wy = L.y, wz = L.z })
    air:AddTileObject(hanging)
    transmitNew(hanging)
    setDrum(L, true)

    syncModData(L.winch)
    L.landingSq:RecalcAllWithNeighbours(true)
    L.groundSq:RecalcAllWithNeighbours(true)
    refreshUI()
    return true
end

function C.doLower(L)
    if not L or C.state(L) ~= "up" then return false, "state" end
    if not L.landing then return false, "state" end
    if not C.pathClear(L) then return false, "blocked" end

    local wd = C.data(L.winch)
    local box = newBox(L, wd.boxHealth, wd.boxMaxHealth)
    moveItems(L.landing:getContainer(), box:getContainer())

    removeContainer(L.landing)
    syncContainers(L.landing)
    L.airSq:transmitRemoveItemFromSquare(L.hanging)
    L.hanging = nil
    placeChain(L)
    setDrum(L, false)

    L.groundSq:AddSpecialObject(box)
    transmitNew(box)

    L.landingSq:RecalcAllWithNeighbours(true)
    L.groundSq:RecalcAllWithNeighbours(true)
    refreshUI()
    return true
end

function C.canDismantle(L)
    local state = C.state(L)
    if state == "up" then return false, "up" end
    if L.box and L.box:getContainer() and not L.box:getContainer():isEmpty() then return false, "notEmpty" end
    return true
end

function C.doDismantle(L)
    if not L then return false end
    local ok = C.canDismantle(L)
    if not ok then return false end
    local sq = L.winch:getSquare()
    local drops = { "Base.HeavyChain_Hook", "Base.MetalPipe", "Base.MetalPipe", "Base.SheetMetal" }
    if L.box then
        drops[#drops + 1] = "Base.Plank"
        drops[#drops + 1] = "Base.Plank"
        drops[#drops + 1] = "Base.Rope"
        L.groundSq:transmitRemoveItemFromSquare(L.box)
    end
    if L.hook then L.groundSq:transmitRemoveItemFromSquare(L.hook) end
    removeChain(L)
    if L.landing then L.landingSq:transmitRemoveItemFromSquare(L.landing) end
    sq:transmitRemoveItemFromSquare(L.winch)
    for _, t in ipairs(drops) do
        sq:AddWorldInventoryItem(t, ZombRandFloat(0.2, 0.8), ZombRandFloat(0.2, 0.8), 0)
    end
    refreshUI()
    return true
end

-- ---------------------------------------------------------------------------
-- Build callbacks (named in the entity script)
-- ---------------------------------------------------------------------------

C.Build = C.Build or {}

-- Link a freshly built winch tile with its landing tile, whichever comes second.
local function tryLink(obj)
    local d = C.data(obj)
    local sq = obj:getSquare()
    local want = (d.role == "winch") and "landing" or "winch"
    for _, dir in pairs(C.DIRS) do
        local n = C.square(sq:getX() + dir[1], sq:getY() + dir[2], sq:getZ())
        local other, od = C.findRole(n, want)
        if other and not od.dx then
            local winch, landing = obj, other
            if d.role == "landing" then winch, landing = other, obj end
            local wsq, lsq = winch:getSquare(), landing:getSquare()
            local dx, dy = lsq:getX() - wsq:getX(), lsq:getY() - wsq:getY()
            C.data(winch).dx, C.data(winch).dy = dx, dy
            C.data(landing).dx, C.data(landing).dy = dx, dy
            syncModData(other)
            local L = C.layout(winch)
            if L then C.placeHook(L) end
            return true
        end
    end
    return false
end

function C.Build.OnCreateWinch(params)
    local obj = params.thumpable
    local spr = obj:getSprite()
    local name = spr and spr:getName()
    if C.WINCH_SPRITES[name] then
        C.setData(obj, { role = "winch" })
    else
        C.setData(obj, { role = "landing" })
        obj:setCanPassThrough(true)
        obj:setIsThumpable(false)
    end
    obj:setIsDismantable(false)
    tryLink(obj)
    -- Returning nothing lets the build code transmit this object.
end

-- Temporary: log why the winch ghost is red, once per change of reason.
local lastWhy = nil
function C.why(reason, extra)
    local msg = tostring(reason) .. (extra and (" " .. tostring(extra)) or "")
    if msg ~= lastWhy then
        lastWhy = msg
        print("[CraneMod] winch placement: " .. msg)
    end
end

-- The build menu's face name may come as "E", "e" or a longer name ending in
-- the letter, so only the last letter is used.
function C.faceDir(facing)
    local letter = string.upper(string.sub(tostring(facing), -1))
    return C.DIRS[letter], letter
end

function C.Build.OnIsValidWinch(params)
    local sq = params.square
    local name = params.tileInfo and params.tileInfo:getSpriteName()
    if C.isReserved(sq) then C.why("reserved square") return false end
    -- The game's own check lets multi-tile parts hang over open air, so both
    -- the winch and the column tile need a floor here.
    if not sq:getFloor() then C.why("no floor under the winch or column", params.facing) return false end
    if C.WINCH_SPRITES[name] then return true end

    -- Landing tile: the rope must have a clear drop to the floor below.
    local d = C.faceDir(params.facing)
    if not d then C.why("unknown facing", params.facing) return false end
    local z = sq:getZ()
    if z < 1 then C.why("not on an upper floor") return false end
    local lx, ly = sq:getX(), sq:getY()
    local ax, ay = lx + d[1], ly + d[2]
    local ex, ey, north = C.edgeFor(lx, ly, d[1], d[2])
    if C.edgeBlocked(C.square(ex, ey, z), north) then C.why("wall or closed window at the edge", params.facing) return false end
    local air = C.square(ax, ay, z)
    if C.airBlocked(air) or C.isReserved(air) then C.why("floor or object where the rope hangs", params.facing) return false end
    local ground = C.square(ax, ay, z - 1)
    if C.groundBlocked(ground) or C.isReserved(ground) then C.why("ground below blocked or missing", params.facing) return false end
    C.why("ok", params.facing)
    return true
end

function C.Build.OnIsValidBox(params)
    if not C.findRole(params.square, "hook") then return false end
    if C.groundBlocked(params.square) then return false end
    params.testCollisions = false
    return true
end

function C.Build.OnCreateBox(params)
    local box = params.thumpable
    local sq = box:getSquare()
    local hook, hd = C.findRole(sq, "hook")
    local data = { role = "box" }
    if hd then data.wx, data.wy, data.wz = hd.wx, hd.wy, hd.wz end
    C.setData(box, data)
    box:setIsDismantable(false)
    C.ensureContainer(box, sq)
    if hook then sq:transmitRemoveItemFromSquare(hook) end
end

-- OnAddToMenu tests (named in the entity script). Both parts always show in the
-- build menu. The sandbox skill levels are enforced by the placement wrapper
-- (server/CraneMod/CraneBuildRules.lua), so the ghost stays red below the level.
function CraneMod_WinchMenuTest(param)
    return true
end

function CraneMod_BoxMenuTest(param)
    return true
end

-- ---------------------------------------------------------------------------
-- Older cranes are brought up to date when their hook or box square loads. The
-- winch may sit in a chunk that is not loaded yet, so each crane is retried for
-- a while before it is dropped. Runs where the world is authoritative.
-- ---------------------------------------------------------------------------

local pendingUpgrades = {}
local UPGRADE_TRIES = 600   -- ticks

local function onLoadSquare(sq)
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local d = C.data(objs:get(i))
        if d and (d.role == "hook" or d.role == "hanging") and d.wx then
            pendingUpgrades[d.wx .. "," .. d.wy .. "," .. d.wz] = { d.wx, d.wy, d.wz, UPGRADE_TRIES }
        end
    end
end

local function processUpgrades()
    for key, p in pairs(pendingUpgrades) do
        local winch = C.findRole(C.square(p[1], p[2], p[3]), "winch")
        local L = winch and C.layout(winch)
        if L and C.state(L) and L.landing then
            C.upgrade(L)
            pendingUpgrades[key] = nil
        else
            p[4] = p[4] - 1
            if p[4] <= 0 then pendingUpgrades[key] = nil end
        end
    end
end

if not isClient() and Events and Events.LoadGridsquare and Events.OnTick then
    Events.LoadGridsquare.Add(onLoadSquare)
    Events.OnTick.Add(processUpgrades)
end
