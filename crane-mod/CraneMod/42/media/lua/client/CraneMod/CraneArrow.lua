-- While placing a crane winch, draw a construction arrow on the floor under the
-- jib (the column tile), pointing to the side the hook and rope will hang.
require "CraneMod/CraneCore"

local C = CraneMod
local arrows = {}

local function arrowSprite(letter)
    if not arrows[letter] then
        local sprite = IsoSprite.new()
        sprite:LoadSingleTexture("media/textures/CraneMod_Arrow_" .. letter .. ".png")
        arrows[letter] = sprite
    end
    return arrows[letter]
end

-- Offset of the column tile within the face, or nil when this is not a winch.
local function columnOffset(face)
    for xx = 0, face:getWidth() - 1 do
        for yy = 0, face:getHeight() - 1 do
            local info = face:getTileInfo(xx, yy, 0)
            local name = info and info:getSpriteName()
            if name and string.find(name, "cranemod_column_", 1, true) == 1 then
                return xx, yy
            end
        end
    end
    return nil
end

local function hookRender()
    if not ISBuildIsoEntity or ISBuildIsoEntity.craneArrowHooked then return end
    ISBuildIsoEntity.craneArrowHooked = true
    local orig = ISBuildIsoEntity.render
    function ISBuildIsoEntity:render(x, y, z, square)
        orig(self, x, y, z, square)
        local ok, err = pcall(function()
            local face = self:getFace()
            if not face then return end
            local cx, cy = columnOffset(face)
            if not cx then return end
            local _, letter = C.faceDir(face:getFaceName())
            if not C.DIRS[letter] then return end
            arrowSprite(letter):RenderGhostTileColor(x + cx, y + cy, z, 1.0, 1.0, 1.0, 0.9)
        end)
        if not ok and not self.craneArrowError then
            self.craneArrowError = true
            print("[CraneMod] arrow error: " .. tostring(err))
        end
    end
end

Events.OnGameStart.Add(hookRender)

-- Crane builds play their recipe's sound (the welding torch) themselves, the
-- same way the metal barricade action does, because the build action's own
-- sound loop stays silent for them.
local function isCraneBuild(action)
    local name = action.item and tostring(action.item.name or "")
    return name and string.find(name, "CraneMod_", 1, true) ~= nil
end

local function recipeSound(name)
    local recipe = getScriptManager():getCraftRecipe(name)
    local action = recipe and recipe:getTimedActionScript()
    return action and action:getSound()
end

local function stopCraneSound(action)
    if action.craneSound and action.craneSound ~= 0 and action.character:getEmitter():isPlaying(action.craneSound) then
        action.character:getEmitter():stopSound(action.craneSound)
    end
    action.craneSound = nil
end

local function hookBuildSound()
    if not ISBuildAction then return end
    local origStart, origUpdate = ISBuildAction.start, ISBuildAction.update
    local origStop, origPerform = ISBuildAction.stop, ISBuildAction.perform

    function ISBuildAction:start()
        if isCraneBuild(self) then
            self.craneSoundName = self.item.craftingBank or recipeSound(tostring(self.item.name))
            self.item.craftingBank = nil
        end
        return origStart(self)
    end

    function ISBuildAction:update()
        if self.craneSoundName then
            local emitter = self.character:getEmitter()
            local now = getTimestampMs()
            local waited = not self.craneSoundStarted or now - self.craneSoundStarted >= 1000
            if waited and (not self.craneSound or self.craneSound == 0 or not emitter:isPlaying(self.craneSound)) then
                self.craneSound = emitter:playSound(self.craneSoundName)
                self.craneSoundStarted = now
                local radius = 20 * self.character:getWeldingSoundMod()
                addSound(self.character, self.character:getX(), self.character:getY(), self.character:getZ(), radius, radius)
            end
        end
        return origUpdate(self)
    end

    function ISBuildAction:stop()
        stopCraneSound(self)
        return origStop(self)
    end

    function ISBuildAction:perform()
        stopCraneSound(self)
        return origPerform(self)
    end
end

Events.OnGameStart.Add(hookBuildSound)
