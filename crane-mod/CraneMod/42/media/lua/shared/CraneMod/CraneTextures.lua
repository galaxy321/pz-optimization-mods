-- The cranemod_* tiles (see cranemod.tiles) have no texture of their own name,
-- so each sprite is pointed at the mod's own image in media/textures, both in
-- the world and in the build ghost.

CraneTextures = {}

local T = "media/textures/CraneMod_"
local TEXTURES = {
    cranemod_winch_e_53 = T .. "Winch_E.png", cranemod_winch_w_53 = T .. "Winch_W.png",
    cranemod_winch_s_52 = T .. "Winch_S.png", cranemod_winch_n_52 = T .. "Winch_N.png",
    cranemod_column_e_48 = T .. "Column_E.png", cranemod_column_w_48 = T .. "Column_W.png",
    cranemod_column_s_48 = T .. "Column_S.png", cranemod_column_n_48 = T .. "Column_N.png",
    cranemod_box_19 = T .. "Box.png",
    cranemod_boxhang_19 = "camping_01_19",
    cranemod_hook_57 = T .. "Hook.png",
}
for _, f in ipairs({ "e", "w", "s", "n" }) do
    local F = string.upper(f)
    TEXTURES["cranemod_chain_" .. f .. "_0"] = T .. "Chain_" .. F .. ".png"
    TEXTURES["cranemod_hang_" .. f .. "_0"] = T .. "Hang_" .. F .. ".png"
    TEXTURES["cranemod_drum_" .. f .. "_0"] = T .. "Drum_" .. F .. ".png"
end

-- The texture a cranemod sprite draws with, or nil for other names.
function CraneTextures.textureFor(name)
    if type(name) ~= "string" then return nil end
    return TEXTURES[name]
end

local fixed = false
local function fixWorldSprites()
    if fixed or isServer() then return end
    fixed = true
    for name, texture in pairs(TEXTURES) do
        local sprite = getSprite(name)
        if sprite then
            sprite:LoadSingleTexture(texture)
        else
            print("[CraneMod] missing sprite " .. tostring(name))
        end
    end
end

local hooked = false
local function hookGhost()
    if hooked or not ISBuildIsoEntity then return end
    hooked = true
    local orig = ISBuildIsoEntity.cacheSprites
    function ISBuildIsoEntity:cacheSprites(face)
        orig(self, face)
        if not self.spriteCache then return end
        for name, _ in pairs(self.spriteCache) do
            local texture = CraneTextures.textureFor(name)
            if texture then
                local sprite = IsoSprite.new()
                sprite:LoadSingleTexture(texture)
                self.spriteCache[name] = sprite
            end
        end
    end
end

Events.OnGameStart.Add(function()
    fixWorldSprites()
    hookGhost()
end)
