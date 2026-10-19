-- Temporary diagnostics: print how the game files the crane build entries,
-- next to the SMB_steps ladders for comparison.
local function try(obj, method)
    local ok, v = pcall(function() return obj[method](obj) end)
    if ok then return tostring(v) end
    return "?"
end

local function describe(tag, recipe)
    local name = try(recipe, "getName")
    if string.find(name, "Crane", 1, true) or string.find(name, "SMB_steps", 1, true) then
        print("[CraneMod] " .. tag .. " " .. name
            .. " category=" .. try(recipe, "getCategory")
            .. " tags=" .. try(recipe, "getTags")
            .. " module=" .. try(recipe, "getModule"))
    end
end

local function dumpList(tag, list)
    if not list then
        print("[CraneMod] " .. tag .. " list is nil")
        return
    end
    print("[CraneMod] " .. tag .. " size=" .. tostring(list:size()))
    for i = 0, list:size() - 1 do
        describe(tag, list:get(i))
    end
end

local function hookBuildPanel()
    if not ISBuildPanel or ISBuildPanel.craneDiagHooked then return end
    ISBuildPanel.craneDiagHooked = true
    local dumped = false
    local origRefresh = ISBuildPanel.refreshList
    function ISBuildPanel:refreshList()
        origRefresh(self)
        if dumped then return end
        dumped = true
        local ok, err = pcall(function()
            dumpList("buildable", self.logic:getAllBuildableRecipes())
            local cats = self.logic:getCategoryList()
            if cats then
                local names = {}
                for i = 0, cats:size() - 1 do
                    names[#names + 1] = tostring(cats:get(i))
                end
                print("[CraneMod] categories: " .. table.concat(names, ", "))
            end
        end)
        if not ok then print("[CraneMod] diag error: " .. tostring(err)) end
    end
end

local function startupDump()
    local ok, err = pcall(function()
        local sm = ScriptManager.instance
        for _, n in ipairs({"CraneMod_Winch", "CraneMod_Box", "SMB_steps_WoodLadder", "SMB_steps_SteelLadder"}) do
            local r = sm:getCraftRecipe(n)
            if r then
                describe("script", r)
            else
                print("[CraneMod] script " .. n .. " = nil")
            end
        end
    end)
    if not ok then print("[CraneMod] diag error: " .. tostring(err)) end
    hookBuildPanel()
end
Events.OnGameStart.Add(startupDump)
