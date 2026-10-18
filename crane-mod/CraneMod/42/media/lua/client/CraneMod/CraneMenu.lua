-- Right-click menu on crane parts, plus the loot panel highlight on the hanging box.
require "CraneMod/CraneCore"
require "TimedActions/CraneCrankAction"
require "TimedActions/CraneDismantleAction"

local C = CraneMod

local function addTooltip(option, text)
    local tooltip = ISWorldObjectContextMenu.addToolTip()
    tooltip.description = text
    option.toolTip = tooltip
end

local function disabled(context, label, why)
    local option = context:addOption(label, nil, nil)
    option.notAvailable = true
    if why then addTooltip(option, why) end
    return option
end

local function say(player, text)
    if HaloTextHelper and HaloTextHelper.addBadText then
        HaloTextHelper.addBadText(player, text)
    else
        player:Say(text)
    end
end

local function queueCrank(player, winch, mode, anim, sound)
    if luautils.walkAdj(player, winch:getSquare(), true) then
        ISTimedActionQueue.add(CraneCrankAction:new(player, winch, mode, anim, sound))
    end
end

local function onCrank(worldobjects, player, winch, mode)
    local L = C.layout(winch)
    if not L then return end
    C.state(L)
    if not C.pathClear(L) then
        say(player, getText("IGUI_Crane_Blocked"))
        return
    end
    queueCrank(player, winch, mode)
end

local function onRestoreHook(worldobjects, player, winch)
    queueCrank(player, winch, "hook")
end

local function onTestAnim(worldobjects, player, winch, anim)
    queueCrank(player, winch, "test", anim)
end

local function onTestSound(worldobjects, player, winch, sound)
    queueCrank(player, winch, "test", nil, sound)
end

local function onDismantle(worldobjects, player, winch)
    if luautils.walkAdj(player, winch:getSquare(), true) then
        ISTimedActionQueue.add(CraneDismantleAction:new(player, winch))
    end
end

-- Find a crane winch among the clicked objects or anything on their squares.
local function findWinch(worldobjects)
    local seen = {}
    for _, obj in ipairs(worldobjects) do
        local w = C.winchFrom(obj)
        if w then return w end
        local sq = obj.getSquare and obj:getSquare()
        if sq and not seen[sq] then
            seen[sq] = true
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                w = C.winchFrom(objs:get(i))
                if w then return w end
            end
        end
    end
    return nil
end

local function onFillMenu(playerNum, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    local winch = findWinch(worldobjects)
    if not winch then return end
    local L = C.layout(winch)
    if not L then return end
    local state = C.state(L)
    local upstairs = math.floor(player:getZ()) == L.z

    if state == "down" or state == "up" then
        local label = getText(state == "down" and "ContextMenu_Crane_Raise" or "ContextMenu_Crane_Lower")
        if not upstairs then
            disabled(context, label, getText("ContextMenu_Crane_Upstairs"))
        elseif not C.pathClear(L) then
            disabled(context, label, getText("IGUI_Crane_Blocked"))
        else
            local option = context:addOption(label, worldobjects, onCrank, player, winch, state == "down" and "raise" or "lower")
            local w = C.loadWeight(L, state)
            addTooltip(option, getText("ContextMenu_Crane_LoadTooltip", string.format("%.1f", w)))
        end
    elseif L.hook then
        disabled(context, getText("ContextMenu_Crane_NoBox"), getText("ContextMenu_Crane_NoBoxTooltip"))
    else
        context:addOption(getText("ContextMenu_Crane_RestoreHook"), worldobjects, onRestoreHook, player, winch)
    end

    local canDismantle, why = C.canDismantle(L)
    if canDismantle then
        context:addOption(getText("ContextMenu_Crane_Dismantle"), worldobjects, onDismantle, player, winch)
    else
        disabled(context, getText("ContextMenu_Crane_Dismantle"),
            getText(why == "up" and "ContextMenu_Crane_DismantleUp" or "ContextMenu_Crane_DismantleNotEmpty"))
    end

    if isDebugEnabled() then
        local parent = context:addOption(getText("ContextMenu_Crane_DebugAnim"), nil, nil)
        local sub = ISContextMenu:getNew(context)
        context:addSubMenu(parent, sub)
        for _, anim in ipairs(C.DEBUG_ANIMS) do
            sub:addOption(anim, worldobjects, onTestAnim, player, winch, anim)
        end
        local soundParent = context:addOption(getText("ContextMenu_Crane_DebugSound"), nil, nil)
        local soundSub = ISContextMenu:getNew(context)
        context:addSubMenu(soundParent, soundSub)
        for _, sound in ipairs(C.DEBUG_SOUNDS) do
            soundSub:addOption(sound, worldobjects, onTestSound, player, winch, sound)
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillMenu)

-- ---------------------------------------------------------------------------
-- Loot panel highlight: when the landing's container is selected, light up
-- the hanging box instead of the landing column.
-- ---------------------------------------------------------------------------

local function hangingFor(landing)
    local d = C.data(landing)
    if not d or d.role ~= "landing" or not d.dx then return nil end
    local sq = landing:getSquare()
    if not sq then return nil end
    return (C.findRole(C.square(sq:getX() + d.dx, sq:getY() + d.dy, sq:getZ()), "hanging"))
end

local origUpdateHighlight = ISInventoryPage.updateContainerHighlight
function ISInventoryPage:updateContainerHighlight()
    origUpdateHighlight(self)
    local target = nil
    if not self.isCollapsed then
        local parent = self:getContainerParent(self.inventory)
        target = parent and hangingFor(parent)
        if target then
            parent:setHighlighted(self.player, false, false)
            parent:setOutlineHighlight(self.player, false)
        end
    end
    local prev = self.craneHighlighted
    if prev and prev ~= target then
        prev:setHighlighted(self.player, false, false)
    end
    if target then
        target:setHighlighted(self.player, true, false)
        target:setHighlightColor(self.player, getCore():getObjectHighlitedColor())
    end
    self.craneHighlighted = target
end

-- The Proximity Inventory mod highlights every nearby container's object each
-- frame from its own ISInventoryPage.update wrapper. Wrap update at game start,
-- after every mod has loaded, so this runs after it and moves the landing's
-- highlight onto the hanging box.
local function hookProximityHighlight()
    local origUpdate = ISInventoryPage.update
    function ISInventoryPage:update()
        origUpdate(self)
        local prev = self.craneProxHighlighted or {}
        local now = {}
        if not self.isCollapsed and self.inventory and self.inventory:getType() == "proxInv" and self.backpacks then
            for i = 1, #self.backpacks do
                local parent = self.backpacks[i].inventory and self.backpacks[i].inventory:getParent()
                local target = parent and hangingFor(parent)
                if target and parent:isHighlighted(self.player) then
                    parent:setHighlighted(self.player, false, false)
                    target:setHighlighted(self.player, true, false)
                    target:setHighlightColor(self.player, getCore():getObjectHighlitedColor())
                    now[target] = true
                end
            end
        end
        for obj in pairs(prev) do
            if not now[obj] and obj ~= self.craneHighlighted then
                obj:setHighlighted(self.player, false, false)
            end
        end
        self.craneProxHighlighted = now
    end
end

Events.OnGameStart.Add(hookProximityHighlight)
