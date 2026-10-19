-- Stops vanilla pick up, scrap and dismantle on crane parts, and keeps
-- furniture from being placed on a crane's rope or box tile.
require "CraneMod/CraneCore"
require "Moveables/ISMoveableSpriteProps"

local function isCraneObject(obj)
    return obj ~= nil and CraneMod.data(obj) ~= nil
end

local function squareHasCraneSprite(sq, spriteName)
    if not sq then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if isCraneObject(o) then
            local spr = o:getSprite()
            if not spriteName or (spr and spr:getName() == spriteName) then return true end
        end
    end
    return false
end

local origFromObject = ISMoveableSpriteProps.fromObject
ISMoveableSpriteProps.fromObject = function(obj)
    local s = origFromObject(obj)
    if s and isCraneObject(obj) then
        s.isMoveable = false
        s.canScrap = false
    end
    return s
end

local origCanPickUp = ISMoveableSpriteProps.canPickUpMoveable
function ISMoveableSpriteProps:canPickUpMoveable(character, square, object)
    if object then
        if isCraneObject(object) then return false end
    elseif squareHasCraneSprite(square, self.spriteName) then
        return false
    end
    return origCanPickUp(self, character, square, object)
end

local origCanScrap = ISMoveableSpriteProps.canScrapObject
function ISMoveableSpriteProps:canScrapObject(character)
    local result, chance, perkName = origCanScrap(self, character)
    if result and isCraneObject(self.object) then
        result.canScrap = false
    end
    return result, chance, perkName
end

local origCanPlace = ISMoveableSpriteProps.canPlaceMoveable
function ISMoveableSpriteProps:canPlaceMoveable(character, square, item)
    if CraneMod.isReserved(square) then return false end
    return origCanPlace(self, character, square, item)
end
