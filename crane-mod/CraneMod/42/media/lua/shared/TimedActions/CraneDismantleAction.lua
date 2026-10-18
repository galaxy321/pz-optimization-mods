require "TimedActions/ISBaseTimedAction"
require "TimedActions/CraneCrankAction"

-- Takes the whole crane apart. Only allowed with the box down and empty (or no box).
CraneDismantleAction = ISBaseTimedAction:derive("CraneDismantleAction")

function CraneDismantleAction:isValid()
    if not self.winch or self.winch:getObjectIndex() == -1 then return false end
    local L = CraneMod.layout(self.winch)
    return L ~= nil and (CraneMod.canDismantle(L))
end

function CraneDismantleAction:waitToStart()
    self.character:faceThisObject(self.winch)
    return self.character:shouldBeTurning()
end

-- Same sound loop as cranking: restart the sound when it ends, at most once a second.
CraneDismantleAction.updateSound = CraneCrankAction.updateSound
CraneDismantleAction.stopSound = CraneCrankAction.stopSound

function CraneDismantleAction:update()
    self.character:faceThisObject(self.winch)
    self.character:setMetabolicTarget(Metabolics.UsingTools)
    self:updateSound()
end

function CraneDismantleAction:start()
    self:setActionAnim("disassemble")
    self:updateSound()
end

function CraneDismantleAction:stop()
    self:stopSound()
    ISBaseTimedAction.stop(self)
end

function CraneDismantleAction:perform()
    self:stopSound()
    ISBaseTimedAction.perform(self)
end

function CraneDismantleAction:complete()
    local L = CraneMod.layout(self.winch)
    if L then CraneMod.doDismantle(L) end
    return true
end

function CraneDismantleAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 300
end

function CraneDismantleAction:new(character, winch)
    local o = ISBaseTimedAction.new(self, character)
    o.winch = winch
    o.soundName = CraneMod.DISMANTLE_SOUND
    o.maxTime = o:getDuration()
    o.caloriesModifier = 2
    return o
end
