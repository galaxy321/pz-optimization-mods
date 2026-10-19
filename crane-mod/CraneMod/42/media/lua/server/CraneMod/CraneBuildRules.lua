-- Build placement rules: nothing else may be built on a crane's rope tile or
-- box tile, and the crane parts need the sandbox skill levels.
require "CraneMod/CraneCore"
require "BuildingObjects/ISBuildIsoEntity"

local function entityKind(build)
    local name = tostring(build.name or "")
    if string.find(name, "CraneMod_Box", 1, true) then return "box" end
    if string.find(name, "CraneMod_Winch", 1, true) then return "winch" end
    return nil
end

local origIsValidPerSquare = ISBuildIsoEntity.isValidPerSquare
function ISBuildIsoEntity:isValidPerSquare(square, tileInfo, ...)
    local kind = entityKind(self)
    if kind ~= "box" and square and CraneMod.isReserved(square) then
        if kind == "winch" then CraneMod.why("square is part of a crane") end
        return false
    end
    if kind and self.character and not self.character:isBuildCheat() and not CraneMod.hasSkill(self.character, kind) then
        if kind == "winch" then CraneMod.why("Metalworking level too low") end
        return false
    end
    -- The box goes on the hook's square, where the game's own check refuses
    -- it (the hook tile blocks placement), so the box only needs its own rule:
    -- a crane hook on this square.
    if kind == "box" and square then
        return CraneMod.Build.OnIsValidBox({ square = square }) == true
    end
    return origIsValidPerSquare(self, square, tileInfo, ...)
end
