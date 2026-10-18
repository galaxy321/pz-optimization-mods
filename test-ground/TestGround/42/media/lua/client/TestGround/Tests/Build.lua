-- Test Ground 1.13.0: building with Better Building Plus, and visiting the built room.
require "TestGround/Core"
local TG = TestGroundInternal
if TG.loaded.Build then return end
TG.loaded.Build = true
local S = TG.S
local K, Steps, T, floor, now, player = TG.K, TG.Steps, TG.T, TG.floor, TG.now, TG.player
local readLines, teleport = TG.readLines, TG.teleport
function K.bbp()
	local okC, commands = pcall(require, "BetterBuildingPlus/networking/commands")
	local okP, presets = pcall(require, "RCStructureFramework/Presets")
	if not (okP and type(presets) == "table") then
		local okF, fw = pcall(require, "RCStructureFramework")
		presets = okF and type(fw) == "table" and fw.Presets or nil
	end
	if okC and type(commands) == "table" and presets and presets.jsonEncode then return commands, presets end
	return nil, nil
end
-- The room's pieces: walls on the four edges, a door frame and door in the middle of the south
-- wall, a floor on every tile. BBP's own sprites for level-1 wood (StructureDefinition.lua).
function K.bbpPlan(x0, y0, z, w, h)
	local cells, walls = {}, {}
	for x = x0, x0 + w - 1 do for y = y0, y0 + h - 1 do cells[#cells + 1] = { x = x, y = y, z = z, spriteName = K.BBP_FLOOR } end end
	local doorX = x0 + floor(w / 2)
	for x = x0, x0 + w - 1 do
		walls[#walls + 1] = { x = x, y = y0, z = z, north = true, slotKind = "wall", spriteName = K.BBP_WALL_N }
		if x == doorX then
			walls[#walls + 1] = { x = x, y = y0 + h, z = z, north = true, slotKind = "doorframe", spriteName = K.BBP_FRAME_N }
			walls[#walls + 1] = { x = x, y = y0 + h, z = z, north = true, slotKind = "door", spriteName = K.BBP_DOOR_N }
		else
			walls[#walls + 1] = { x = x, y = y0 + h, z = z, north = true, slotKind = "wall", spriteName = K.BBP_WALL_N }
		end
	end
	for y = y0, y0 + h - 1 do
		walls[#walls + 1] = { x = x0, y = y, z = z, north = false, slotKind = "wall", spriteName = K.BBP_WALL_W }
		walls[#walls + 1] = { x = x0 + w, y = y, z = z, north = false, slotKind = "wall", spriteName = K.BBP_WALL_W }
	end
	local nWalls = 2 * w + 2 * h - 1
	local need = { ["Base.Plank"] = nWalls * 2 + 4 + 4 + w * h, ["Base.Nails"] = nWalls * 4 + 4 + 4 + w * h,
		["Base.Hinge"] = 2, ["Base.Doorknob"] = 1, ["Base.Hammer"] = 1 }
	return { structureId = "BetterBuildingPlus_FreeForm", variant = "default", x = x0, y = y0, z = z,
		rects = { { x = x0, y = y0, z = z, w = w, h = h, kind = "room" } }, cells = cells, walls = walls, stairs = {} },
		need, #cells + #walls
end
-- 1.12.5: any structure from a file, one piece per line, coordinates relative to the site's
-- north-west corner (x east, y south, z floor):
--   woodwork = 6              # skill for the build (default 3; BBP's wood stairs need 6)
--   floor 0,0,0 4x3           # floor tiles over an area (or one tile without WxH)
--   walls 0,0,0 4x3 door=south   # the walls round an area, a door frame and door in the middle of one side
--   wall 1,0,0 north          # one wall on the north (or west) edge of a tile
--   doorframe 2,3,0 north     # a door frame; "door 2,3,0 north" hangs a door in it
--   stairs 3,1,0 north        # wood stairs from this tile (BBP's own trio of sprites)
-- Sprites are BBP's level-1 wood pieces; materials come from BBP's own recipes (PlanMaterials).
K.BBP_STAIRS = { north = { "carpentry_02_96", "carpentry_02_97", "carpentry_02_98" }, west = { "carpentry_02_88", "carpentry_02_89", "carpentry_02_90" } }
function K.structParse(lines)
	local d = { pieces = {}, woodwork = 3, errors = {} }
	for n, raw in ipairs(lines) do
		local line = string.gsub(string.gsub(raw, "#.*$", ""), "^%s*(.-)%s*$", "%1")
		if line ~= "" then
			local key, val = string.match(line, "^(%w+)%s*=%s*(.-)$")
			if key then
				if string.lower(key) == "woodwork" then d.woodwork = tonumber(val) or d.woodwork end
			else
				local kind, x, y, z, rest = string.match(line, "^(%a+)%s+(%-?%d+),(%-?%d+),(%-?%d+)%s*(.*)$")
				if not kind then
					d.errors[#d.errors + 1] = "line " .. n .. ": " .. line
				else
					kind = string.lower(kind)
					local w, h = string.match(rest, "(%d+)x(%d+)")
					local pc = { kind = kind, x = tonumber(x), y = tonumber(y), z = tonumber(z), w = tonumber(w) or 1, h = tonumber(h) or 1,
						dir = string.match(string.lower(rest), "^(%a+)") , door = string.match(string.lower(rest), "door=(%a+)") }
					if pc.dir and string.match(pc.dir, "^%d") then pc.dir = nil end
					local known = { floor = 1, walls = 1, wall = 1, doorframe = 1, door = 1, stairs = 1 }
					if known[kind] then d.pieces[#d.pieces + 1] = pc else d.errors[#d.errors + 1] = "line " .. n .. ": unknown piece " .. kind end
				end
			end
		end
	end
	return d
end
-- The BBP plan for a parsed structure at world x0,y0,z0, its materials, piece count and footprint.
function K.structPlan(d, x0, y0, z0)
	local cells, walls, stairs = {}, {}, {}
	local maxX, maxY, maxZ = 0, 0, 0
	local function wall(x, y, z, north, slot, sprite)
		walls[#walls + 1] = { x = x0 + x, y = y0 + y, z = z0 + z, north = north, slotKind = slot, spriteName = sprite }
	end
	local function edge(x, y, z, north, slot)
		if slot == "door" then
			wall(x, y, z, north, "doorframe", K.BBP_FRAME_N); wall(x, y, z, north, "door", K.BBP_DOOR_N)
		else
			wall(x, y, z, north, "wall", north and K.BBP_WALL_N or K.BBP_WALL_W)
		end
	end
	for _, pc in ipairs(d.pieces) do
		maxX, maxY, maxZ = math.max(maxX, pc.x + pc.w), math.max(maxY, pc.y + pc.h), math.max(maxZ, pc.z)
		if pc.kind == "floor" then
			for x = pc.x, pc.x + pc.w - 1 do for y = pc.y, pc.y + pc.h - 1 do
				cells[#cells + 1] = { x = x0 + x, y = y0 + y, z = z0 + pc.z, spriteName = K.BBP_FLOOR }
			end end
		elseif pc.kind == "walls" then
			local mx, my = pc.x + floor(pc.w / 2), pc.y + floor(pc.h / 2)
			for x = pc.x, pc.x + pc.w - 1 do
				edge(x, pc.y, pc.z, true, (pc.door == "north" and x == mx) and "door" or "wall")
				edge(x, pc.y + pc.h, pc.z, true, (pc.door == "south" and x == mx) and "door" or "wall")
			end
			for y = pc.y, pc.y + pc.h - 1 do
				edge(pc.x, y, pc.z, false, (pc.door == "west" and y == my) and "door" or "wall")
				edge(pc.x + pc.w, y, pc.z, false, (pc.door == "east" and y == my) and "door" or "wall")
			end
		elseif pc.kind == "wall" then
			edge(pc.x, pc.y, pc.z, pc.dir ~= "west", "wall")
		elseif pc.kind == "doorframe" then
			wall(pc.x, pc.y, pc.z, pc.dir ~= "west", "doorframe", K.BBP_FRAME_N)
		elseif pc.kind == "door" then
			wall(pc.x, pc.y, pc.z, pc.dir ~= "west", "door", K.BBP_DOOR_N)
		elseif pc.kind == "stairs" then
			local north = pc.dir ~= "west"
			local tr = north and K.BBP_STAIRS.north or K.BBP_STAIRS.west
			stairs[#stairs + 1] = { x = x0 + pc.x, y = y0 + pc.y, z = z0 + pc.z, north = north, bottomSprite = tr[1], middleSprite = tr[2], topSprite = tr[3] }
			if north then maxY = math.max(maxY, pc.y + 1) else maxX = math.max(maxX, pc.x + 1) end
		end
	end
	local plan = { structureId = K.BBP_STRUCTURE, variant = "default", x = x0, y = y0, z = z0,
		rects = {}, cells = cells, walls = walls, stairs = stairs }
	return plan, #cells + #walls + #stairs, maxX, maxY, maxZ
end
-- What a plan needs, from BBP's own recipes; tools kept are given once. Falls back to nil.
K.TAG_ITEMS = { ["base:hammer"] = "Base.Hammer", ["base:saw"] = "Base.Saw", ["base:screwdriver"] = "Base.Screwdriver" }
function K.bbpNeed(plan)
	local okM, PM = pcall(require, "BetterBuildingPlus/PlanMaterials")
	if not (okM and type(PM) == "table" and PM.forPlan) then return nil, "PlanMaterials not found" end
	local okL, list = pcall(PM.forPlan, plan)
	if not okL or type(list) ~= "table" then return nil, "PlanMaterials failed: " .. tostring(list) end
	local need, missing = {}, {}
	for _, l in ipairs(list) do
		local id = l.fullType or K.TAG_ITEMS[tostring(l.tag)]
		if id then need[id] = (need[id] or 0) + (l.keep and 1 or (l.count or 1))
		else missing[#missing + 1] = tostring(l.tag) end
	end
	return need, #missing > 0 and ("no item for " .. table.concat(missing, ", ")) or nil
end

-- A site is clear when every tile of the room and a 1-tile ring is loaded, outside buildings, with
-- no tree, vehicle or solid object.
function K.siteClear(x0, y0, z, w, h)
	local cell = getCell()
	for x = x0 - 1, x0 + w do
		for y = y0 - 1, y0 + h do
			local sq = cell:getGridSquare(x, y, z)
			if not sq then return false end
			local bad = false
			pcall(function()
				if sq:getBuilding() or sq:getRoom() then bad = true end
				if sq:getVehicleContainer() then bad = true end
				if TG.hasTree(sq) then bad = true end
				if sq:isSolid() or sq:isSolidTrans() then bad = true end
				-- BBP refuses water at ground level (Validators.notOnWater)
				if z == 0 and sq:getProperties():has(IsoFlagType.water) then bad = true end
			end)
			if bad then return false end
		end
	end
	return true
end
function K.findSite(cx, cy, z, w, h)
	for rad = 3, 30, 3 do
		for _, d in ipairs({ { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }) do
			local x0, y0 = cx + d[1] * rad, cy + d[2] * rad
			if K.siteClear(x0, y0, z, w, h) then return x0, y0 end
		end
	end
	return nil
end
-- Afterwards the room is taken down again and BBP's record cancelled, so the next run builds it
-- again instead of finding it standing. RCStructureFramework tags every object it places (walls,
-- the corner posts it adds, the door open or shut, floors) with modData.RCStructureFramework.
-- structureId; its own removeObject puts back the ground a floor buried (a plain remove leaves a
-- hole). The room RCSF registers once the walls stand is removed too, or it comes back on reload
-- and the next site check sees a building.
K.BBP_STRUCTURE = "BetterBuildingPlus_FreeForm"
function K.bbpTearDown(site)
	if not site then return 0 end
	pcall(function() if BBPAutonomousBuilder then BBPAutonomousBuilder.stop() end end)
	local okF, RCSF = pcall(require, "RCStructureFramework")
	local PH = okF and type(RCSF) == "table" and RCSF.PlacementHelpers or nil
	local n, cell = 0, getCell()
	for z = site.z, site.zmax or site.z do
	for x = site.x - 1, site.x + site.w + 1 do
		for y = site.y - 1, site.y + site.h + 1 do
			local sq = cell:getGridSquare(x, y, z)
			if sq then
				pcall(function()
					local objs = sq:getObjects()
					for i = objs:size() - 1, 0, -1 do
						local o = objs:get(i)
						local tag = o:hasModData() and o:getModData()["RCStructureFramework"] or nil
						if type(tag) == "table" and tag.structureId == K.BBP_STRUCTURE then
							if PH and PH.removeObject then PH.removeObject(o) else sq:transmitRemoveItemFromSquare(o) end
							n = n + 1
						end
					end
				end)
			end
		end
	end
	end
	if site.recordId then
		local commands = K.bbp()
		if commands then pcall(function() commands.CancelConstruction:send(player(), { recordId = site.recordId }) end) end
	end
	if okF and type(RCSF) == "table" then
		pcall(function() RCSF.RoomPersistence.removeRoomsWithin(site.x, site.y, site.x + site.w - 1, site.y + site.h - 1) end)
	end
	return n
end
-- Objects RCStructureFramework placed for BBP on a site (and a 1-tile ring).
function K.bbpCount(site)
	local n, cell = 0, getCell()
	for z = site.z, site.zmax or site.z do
	for x = site.x - 1, site.x + site.w + 1 do
		for y = site.y - 1, site.y + site.h + 1 do
			local sq = cell:getGridSquare(x, y, z)
			if sq then
				pcall(function()
					local objs = sq:getObjects()
					for i = 0, objs:size() - 1 do
						local o = objs:get(i)
						local tag = o:hasModData() and o:getModData()["RCStructureFramework"] or nil
						if type(tag) == "table" and tag.structureId == K.BBP_STRUCTURE then n = n + 1 end
					end
				end)
			end
		end
	end
	end
	return n
end
-- 1.12.6: what is really standing at the site after the build, per floor: tagged objects, and how
-- many of them are stair pieces (the proof that a stair and an upper floor got built)
function K.bbpCountByFloor(site)
	local stairSet = {}
	for _, l in pairs(K.BBP_STAIRS) do for _, n in ipairs(l) do stairSet[n] = true end end
	local per, stairs, cell = {}, 0, getCell()
	for z = site.z, site.zmax or site.z do
		local n = 0
		for x = site.x - 1, site.x + site.w + 1 do
			for y = site.y - 1, site.y + site.h + 1 do
				local sq = cell:getGridSquare(x, y, z)
				if sq then
					pcall(function()
						local objs = sq:getObjects()
						for i = 0, objs:size() - 1 do
							local o = objs:get(i)
							local tag = o:hasModData() and o:getModData()["RCStructureFramework"] or nil
							if type(tag) == "table" and tag.structureId == K.BBP_STRUCTURE then
								n = n + 1
								local sp = o:getSprite()
								if sp and stairSet[sp:getName()] then stairs = stairs + 1 end
							end
						end
					end)
				end
			end
		end
		per[#per + 1] = string.format("floor %d: %d", z - site.z, n)
	end
	return table.concat(per, ", "), stairs
end
function K.buildLabel(st)
	if st.file then return string.format("structure %s (%dx%d%s)", st.file, st.w, st.h, (st.site and (st.site.zmax or 0) > st.site.z) and ", 2+ floors" or "") end
	return string.format("%dx%d wooden room", st.w, st.h)
end
K.BBP_BENIGN = { ["Build already in progress"] = true, ["Build already queued"] = true, ["Too soon; cooldown active"] = true }
function K.bbpEvent(name, fn)
	if Events[name] and Events[name].Add then Events[name].Add(fn); return fn end
	return nil
end
function K.bbpUnhook(st)
	for name, fn in pairs(st.hooks or {}) do pcall(function() Events[name].Remove(fn) end) end
	st.hooks = {}
end
Steps.build = {
	begin = function(r, st)
		local commands, presets = K.bbp()
		if not commands then st.skip = "Better Building Plus (and RCStructureFramework) not loaded"; return end
		local fileArg = st.args[2] and not tonumber(st.args[2]) and string.match(st.text or "", "^%S+%s+(%S+)")
		if fileArg then
			-- build <file> [seconds]: a structure from a file in Zomboid/Lua ("mod:<name>" ships in the mod)
			local lines = string.sub(fileArg, 1, 4) == "mod:" and K.readModFile("media/TestGround/" .. string.sub(fileArg, 5) .. ".txt") or readLines(fileArg)
			if not lines or #lines == 0 then st.skip = "no structure file " .. fileArg; return end
			st.struct = K.structParse(lines)
			if #st.struct.errors > 0 then st.skip = "structure file " .. fileArg .. ": " .. table.concat(st.struct.errors, "; "); return end
			if #st.struct.pieces == 0 then st.skip = "structure file " .. fileArg .. " has no pieces"; return end
			st.file = fileArg
			local _, _, mx, my = K.structPlan(st.struct, 0, 0, 0)
			st.w, st.h = math.max(1, mx), math.max(1, my)
			st.seconds = tonumber(st.args[3]) or 600
		else
			st.w, st.h = math.max(2, floor(st.a or 3)), math.max(2, floor(st.b or 3))
			st.seconds = tonumber(st.args[4]) or 300
		end
		local p = r.p
		local z = 0
		local x0, y0
		if r.plan.buildsite then
			x0, y0, z = r.plan.buildsite.x, r.plan.buildsite.y, r.plan.buildsite.z or 0
			local dx, dy = p:getX() - x0, p:getY() - y0
			if dx * dx + dy * dy > 46 * 46 then st.skip = "buildsite more than 46 tiles away (BBP refuses a plan over 48 tiles from the player)"; return end
			if not K.siteClear(x0, y0, z, st.w, st.h) then st.skip = "buildsite " .. x0 .. "," .. y0 .. " isn't clear (building, tree, car or wall)"; return end
		else
			x0, y0 = K.findSite(floor(p:getX()), floor(p:getY()), z, st.w, st.h)
			if not x0 then st.skip = "no clear " .. st.w .. "x" .. st.h .. " spot within 30 tiles"; return end
		end
		local plan, need, pieces
		if st.struct then
			local mz
			plan, pieces, _, _, mz = K.structPlan(st.struct, x0, y0, z)
			local why
			need, why = K.bbpNeed(plan)
			if not need then st.skip = "materials: " .. tostring(why); return end
			st.needNote = why
			st.site = { x = x0, y = y0, z = z, w = st.w, h = st.h, zmax = z + mz }
		else
			plan, need, pieces = K.bbpPlan(x0, y0, z, st.w, st.h)
			st.site = { x = x0, y = y0, z = z, w = st.w, h = st.h }
		end
		st.planKinds = string.format("%d floor tiles, %d walls, %d stairs", #(plan.cells or {}), #(plan.walls or {}), #(plan.stairs or {}))
		st.total = pieces
		-- buildspeed (1.12.4): real = BBP's builder at game speed 1, the only mode whose build timings
		-- and frames mean anything; fast (default) = the same builder at game speed x20; instant = build
		-- cheat on, BBP places the whole plan at once (no builder, no materials used). Use fast or
		-- instant when the structure is only the setting for the steps after it.
		st.mode = r.plan.buildspeed or "fast"
		K.INSTANT_WAIT_MS, K.INSTANT_STEADY_MS = K.INSTANT_WAIT_MS or 15000, K.INSTANT_STEADY_MS or 2000
		if st.mode == "instant" then
			local okC = K.tryOnce("build cheat", function() p:setBuildCheat(true) end)
			if not okC then st.mode = "fast"; st.modeNote = "instant refused (build cheat), so fast" end
		else
			pcall(function() p:setBuildCheat(false) end)
		end
		if st.mode == "fast" then
			K.tryOnce("game speed", function() T.setSpeed(3) end)
		end
		local o = K.stepOpts(st)
		local hasWood = false
		for _, sk in ipairs(o.skills) do if string.lower(sk.name) == "woodwork" then hasWood = true end end
		if not hasWood then o.skills[#o.skills + 1] = { name = "Woodwork", level = st.struct and st.struct.woodwork or 3 } end
		st.skillSet = K.setSkills(r, o.skills)
		st.given = {}
		local inv = p:getInventory()
		for id, n in pairs(need) do
			local ok = pcall(function() for _ = 1, n do local it = inv:AddItem(id); st.given[#st.given + 1] = it end end)
			if not ok then st.skip = "could not give " .. id; return end
		end
		local okB, bp = pcall(function() return inv:AddItem("BetterBuildingPlus.EmptyBlueprint") end)
		if not okB or not bp then st.skip = "no BetterBuildingPlus.EmptyBlueprint item"; return end
		st.given[#st.given + 1] = bp
		st.need = need
		-- events: claim, piece built or failed, builder done or stopped
		st.claimAt, st.actAt, st.doneAt, st.pieceTimes, st.actTimes, st.fails = {}, {}, {}, {}, {}, {}
		st.hooks = {}
		st.hooks.OnBeginConstructionSucceeded = K.bbpEvent("OnBeginConstructionSucceeded", function(_, _, recordId) st.recordId = recordId; st.site.recordId = recordId end)
		st.hooks.OnBeginConstructionFailed = K.bbpEvent("OnBeginConstructionFailed", function(_, _, err) st.beginErr = tostring(err) end)
		st.hooks.OnBBPPieceClaimed = K.bbpEvent("OnBBPPieceClaimed", function(a)
			if type(a) == "table" and a.status == "granted" and a.pieceIndex and (not st.recordId or a.recordId == st.recordId) then
				st.claimAt[a.pieceIndex] = st.claimAt[a.pieceIndex] or now()
			end
		end)
		-- every piece result, success or not (OnBuildPieceFailed misses some failures and also fires
		-- for retries the builder shrugs off)
		st.hooks.OnBBPBuildPieceResult = K.bbpEvent("OnBBPBuildPieceResult", function(a)
			if type(a) ~= "table" or (st.recordId and a.recordId ~= st.recordId) then return end
			local idx = a.pieceIndex
			if a.success then
				local t = now()
				st.doneAt[idx] = t
				if st.claimAt[idx] then st.pieceTimes[#st.pieceTimes + 1] = t - st.claimAt[idx] end
				if st.actAt[idx] then st.actTimes[#st.actTimes + 1] = t - st.actAt[idx] end
				st.built = (st.built or 0) + 1
			elseif not K.BBP_BENIGN[a.error] then
				st.fails[#st.fails + 1] = tostring(idx) .. ": " .. tostring(a.error)
			end
		end)
		local okJ, json = pcall(function() return presets.jsonEncode(plan) end)
		if not okJ then st.skip = "could not encode the plan: " .. tostring(json); K.bbpUnhook(st); return end
		local okS, err = pcall(function()
			if commands.sendPlan then commands.sendPlan(commands.BeginConstruction, p, { blueprintItemId = bp:getID(), planJson = json })
			else commands.BeginConstruction:send(p, { blueprintItemId = bp:getID(), planJson = json }) end
		end)
		-- 1.13.11 (showcase trial: instant placed 0 objects): the build cheat stays on until the tick
		-- has seen the plan placed; BeginConstruction is a command handled after this call returns
		if not okS and st.mode == "instant" then pcall(function() p:setBuildCheat(false) end) end
		if not okS then st.skip = "BeginConstruction failed: " .. tostring(err); K.bbpUnhook(st); if st.mode == "fast" then T.setSpeed(r.speed or 1) end; return end
		r.buildSite = st.site   -- from here the run takes it down at the end, built or not
		r.buildGiven = st.given
		T.trace(string.format("build: %s at %d,%d (%d pieces: %s), BBP construction %s", K.buildLabel(st), x0, y0, pieces, st.planKinds, tostring(st.recordId or st.beginErr or "pending")))
	end,
	tick = function(r, st, t)
		local el = t - st.t0
		if st.mode == "instant" then
			-- 1.13.11: wait for the pieces (1.13.9 counted on the first tick, before BBP had placed any):
			-- done when the count holds for K.INSTANT_STEADY_MS with something placed, or all are, or
			-- after K.INSTANT_WAIT_MS
			local n = K.bbpCount(st.site)
			if n ~= st.instN then st.instN, st.instT = n, t end
			local steady = n > 0 and t - (st.instT or t) >= K.INSTANT_STEADY_MS
			if not (steady or (st.total and n >= st.total) or el >= K.INSTANT_WAIT_MS or st.beginErr) then return false end
			K.bbpUnhook(st)
			pcall(function() r.p:setBuildCheat(false) end)
			st.result = string.format("%s at %d,%d by Better Building Plus, build speed instant (build cheat): %d objects placed of %s pieces in %.1f s%s%s; frames here are not a build measurement",
				K.buildLabel(st), st.site.x, st.site.y, n, tostring(st.total or "?"), el / 1000,
				n == 0 and " (NOTHING PLACED: BBP did not build with the build cheat; use buildspeed = fast)" or "",
				st.beginErr and (", error: " .. st.beginErr) or "")
			return true
		end
		-- the build action itself: from when BBP's BuildPieceAction heads the queue
		pcall(function()
			local q = ISTimedActionQueue.getTimedActionQueue(r.p).queue
			local a = q and q[1]
			if a and a.Type == "BuildPieceAction" and a.pieceIndex and not st.actAt[a.pieceIndex] then st.actAt[a.pieceIndex] = t end
		end)
		local state, built, total = "?", st.built or 0, st.total
		pcall(function()
			local B = BBPAutonomousBuilder
			if B then
				state = tostring(B.getState())
				local b, n = B.getProgress()
				if b then built = b end
				if n and n > 0 then total = n end
			end
		end)
		st.state = state
		if state == "building" or state == "refilling" then st.ran = true end
		if t >= (st.nextNote or 0) then
			st.nextNote = t + 10000
			T.trace(string.format("build: %s, %d of %d pieces", state, built, total))
		end
		-- idle after building: the builder stopped itself (it stops on movement, aiming, Esc or death)
		local over = st.beginErr or state == "done" or state == "error" or (st.ran and state == "idle") or built >= total or el >= st.seconds * 1000
		if not over then return false end
		pcall(function() if BBPAutonomousBuilder and state ~= "done" then BBPAutonomousBuilder.stop() end end)
		local err = st.beginErr
		pcall(function() if not err and BBPAutonomousBuilder and state == "error" then err = tostring(BBPAutonomousBuilder.getError()) end end)
		K.bbpUnhook(st)
		if st.mode == "fast" then K.tryOnce("game speed", function() T.setSpeed(r.speed or 1) end) end
		local function stat(list)
			if #list == 0 then return "none" end
			local sum, mx = 0, 0
			for _, v in ipairs(list) do sum = sum + v; if v > mx then mx = v end end
			return string.format("mean %.1f s, max %.1f s", sum / #list / 1000, mx / 1000)
		end
		st.result = string.format("%s at %d,%d by Better Building Plus, build speed " .. st.mode ..
			(st.mode == "fast" and " (game speed x20, times are real seconds, frames not a measurement)" or "") .. (st.modeNote and (" [" .. st.modeNote .. "]") or "") ..
			": %d of %d pieces built in %.0f s (builder %s%s); per piece claim to built %s, build action %s; %d failed%s; skills %s",
			K.buildLabel(st), st.site.x, st.site.y, built, total, el / 1000, (st.ran and state == "idle") and "stopped itself" or state, err and (", error: " .. err) or "",
			stat(st.pieceTimes), stat(st.actTimes), #st.fails, #st.fails > 0 and (" (" .. table.concat(st.fails, "; ", 1, math.min(3, #st.fails)) .. ")") or "",
			table.concat(st.skillSet, " "))
		local okF, per, nst = pcall(K.bbpCountByFloor, st.site)
		st.result = st.result .. string.format("; asked for %s; standing after: %s", st.planKinds or "?", okF and string.format("%s tagged objects, %d stair pieces", per, nst) or "not counted")
		return true
	end,
}
Steps.visit = {
	begin = function(r, st)
		st.seconds = st.a or 20
		local s = r.buildSite
		if not s then st.skip = "nothing built in this run (a build step first)"; return end
		teleport(r.p, s.x + floor(s.w / 2), s.y + floor(s.h / 2), s.z)
	end,
	tick = function(r, st, t) return t - st.t0 >= st.seconds * 1000 end,
}


