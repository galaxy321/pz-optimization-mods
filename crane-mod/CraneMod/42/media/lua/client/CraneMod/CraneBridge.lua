-- Temporary debug bridge (single player, debug use). Every second it reads
-- Zomboid/Lua/cranemod_cmd.txt; each line is one command. Results are appended
-- to Zomboid/Lua/cranemod_out.txt. Commands:
--   dump [radius]   objects on the squares around the player (z-1 .. z+1)
--   lua <code>      run a line of Lua; the returned value is printed
require "CraneMod/CraneCore"

local C = CraneMod
local CMD, OUT = "cranemod_cmd.txt", "cranemod_out.txt"
local seq = 0

local function out(lines)
    local w = getFileWriter(OUT, true, true)
    if not w then return end
    for _, l in ipairs(lines) do w:write(tostring(l) .. "\n") end
    w:close()
end

local function spriteName(o)
    local s = o and o.getSprite and o:getSprite()
    return s and s:getName() or "-"
end

local function safe(f)
    local ok, v = pcall(f)
    if ok then return tostring(v) end
    return "?"
end

local function describeSquare(sq, lines)
    local objs = sq:getObjects()
    local floor = sq:getFloor()
    local head = string.format("  sq %d,%d,%d floor=%s solidfloor=%s free=%s",
        sq:getX(), sq:getY(), sq:getZ(), spriteName(floor),
        safe(function() return sq:getProperties():has("solidfloor") end),
        safe(function() return sq:isFree(false) end))
    lines[#lines + 1] = head
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local d = C.data(o)
        local role = ""
        if d then
            local parts = {}
            for k, v in pairs(d) do parts[#parts + 1] = k .. "=" .. tostring(v) end
            role = " crane{" .. table.concat(parts, ",") .. "}"
        end
        local cls = tostring(o):match("^([%w%.]+)") or "?"
        local kids = ""
        local ch = o.getChildSprites and o:getChildSprites()
        if ch and ch:size() > 0 then
            local names = {}
            for j = 0, ch:size() - 1 do
                local cs = ch:get(j)
                local p = cs and cs.getParentSprite and cs:getParentSprite()
                names[#names + 1] = p and p:getName() or "?"
            end
            kids = " overlays=" .. table.concat(names, ";")
        end
        lines[#lines + 1] = string.format("    [%d] %s %s%s%s", i, cls, spriteName(o), role, kids)
    end
end

local function dump(radius)
    local p = getPlayer()
    if not p then return { "no player" } end
    local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    local lines = {
        string.format("player %d,%d,%d MetalWelding=%d Woodwork=%d buildCheat=%s",
            px, py, pz, p:getPerkLevel(Perks.MetalWelding), p:getPerkLevel(Perks.Woodwork),
            tostring(ISBuildMenu and ISBuildMenu.cheat)),
    }
    for z = pz - 1, pz + 1 do
        for y = py - radius, py + radius do
            for x = px - radius, px + radius do
                local sq = getCell():getGridSquare(x, y, z)
                if sq and sq:getObjects():size() > 0 then describeSquare(sq, lines) end
            end
        end
    end
    return lines
end

local function run(line)
    local cmd, rest = line:match("^(%S+)%s*(.*)$")
    if cmd == "dump" then
        return dump(tonumber(rest) or 3)
    elseif cmd == "lua" then
        local f, err = loadstring("return " .. rest)
        if not f then f, err = loadstring(rest) end
        if not f then return { "compile error: " .. tostring(err) } end
        local ok, res = pcall(f)
        return { (ok and "ok: " or "error: ") .. tostring(res) }
    end
    return { "unknown command: " .. tostring(line) }
end

local ticks = 0
local function poll()
    ticks = ticks + 1
    if ticks < 60 then return end
    ticks = 0
    local r = getFileReader(CMD, false)
    if not r then return end
    local cmds = {}
    local line = r:readLine()
    while line do
        if line:match("%S") then cmds[#cmds + 1] = line end
        line = r:readLine()
    end
    r:close()
    if #cmds == 0 then return end
    local w = getFileWriter(CMD, true, false)
    if w then w:close() end
    for _, c in ipairs(cmds) do
        seq = seq + 1
        local ok, res = pcall(run, c)
        local lines = { string.format("=== #%d %s (%s)", seq, c, getTimestamp and tostring(getTimestamp()) or "") }
        if ok then
            for _, l in ipairs(res) do lines[#lines + 1] = l end
        else
            lines[#lines + 1] = "error: " .. tostring(res)
        end
        out(lines)
    end
end

Events.OnTick.Add(poll)
Events.OnGameStart.Add(function() out({ "=== bridge ready" }) end)
