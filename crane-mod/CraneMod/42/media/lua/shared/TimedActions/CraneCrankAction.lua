require "TimedActions/ISBaseTimedAction"

-- Cranks the winch. mode is "raise", "lower", "hook" (restore a missing hook)
-- or "test" (debug: plays an animation and sound and changes nothing).
CraneCrankAction = ISBaseTimedAction:derive("CraneCrankAction")

function CraneCrankAction:isValid()
    return self.winch ~= nil and self.winch:getObjectIndex() ~= -1
end

function CraneCrankAction:waitToStart()
    self.character:faceThisObject(self.winch)
    return self.character:shouldBeTurning()
end

-- The crank sound is restarted whenever it ends, so short sounds loop.
function CraneCrankAction:updateSound()
    if not self.soundName or isServer() then return end
    -- Wait a little between starts: a sound that is still starting can report
    -- itself as not playing, and restarting it every tick would stack copies.
    local now = getTimestampMs()
    if self.soundStarted and now - self.soundStarted < 1000 then return end
    local emitter = self.character:getEmitter()
    if not self.sound or self.sound == 0 or not emitter:isPlaying(self.sound) then
        self.sound = self.character:playSound(self.soundName)
        self.soundStarted = now
    end
end

function CraneCrankAction:stopSound()
    if self.sound and self.sound ~= 0 and self.character:getEmitter():isPlaying(self.sound) then
        self.character:stopOrTriggerSound(self.sound)
    end
    self.sound = nil
end

function CraneCrankAction:update()
    self.character:faceThisObject(self.winch)
    self.character:setMetabolicTarget(Metabolics.HeavyWork)
    self:updateSound()
end

function CraneCrankAction:start()
    self:setActionAnim(self.anim or CraneMod.CRANK_ANIM)
    self:updateSound()
end

function CraneCrankAction:stop()
    self:stopSound()
    ISBaseTimedAction.stop(self)
end

function CraneCrankAction:perform()
    self:stopSound()
    ISBaseTimedAction.perform(self)
end

function CraneCrankAction:complete()
    if self.mode == "test" then return true end
    local L = CraneMod.layout(self.winch)
    if not L then return false end
    if self.mode == "raise" then
        CraneMod.doRaise(L)
    elseif self.mode == "lower" then
        CraneMod.doLower(L)
    elseif self.mode == "hook" then
        CraneMod.placeHook(L)
    end
    return true
end

function CraneCrankAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    if self.mode == "test" then return 300 end
    if self.mode == "hook" then return 50 end
    local L = CraneMod.layout(self.winch)
    if not L then return 100 end
    return CraneMod.crankTime(L, CraneMod.state(L))
end

function CraneCrankAction:new(character, winch, mode, anim, soundName)
    local o = ISBaseTimedAction.new(self, character)
    o.winch = winch
    o.mode = mode
    o.anim = anim
    o.soundName = soundName or CraneMod.CRANK_SOUND
    o.maxTime = o:getDuration()
    return o
end
