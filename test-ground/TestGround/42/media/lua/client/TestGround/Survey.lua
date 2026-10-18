-- Test Ground 1.13.0: the survey, map roads and the tree-road scan.
require "TestGround/Core"
local TG = TestGroundInternal
if TG.loaded.Survey then return end
TG.loaded.Survey = true
local S = TG.S
local K, PLAN_FILE, T, VERSION, areaLoaded, floor = TG.K, TG.PLAN_FILE, TG.T, TG.VERSION, TG.areaLoaded, TG.floor
local now, out, player, readLines, say, spotKeys = TG.now, TG.out, TG.player, TG.readLines, TG.say, TG.spotKeys
local stateName, teleport, writeLines = TG.stateName, TG.teleport, TG.writeLines
function T.addFinder(name, square, finish)
	table.insert(T.finders, { name = name, square = square, finish = finish, state = {} })
end
local SURVEY_RADIUS = 40
local TREE_RADIUS = 80        -- how far the survey looks for a tree-lined road (loaded squares only)
local TREE_RUN_MIN = 16       -- shortest straight stretch of road to consider
local TREE_BAND = { 2, 8 }    -- verge band, in tiles out from the road row, on each side
local FAST_RUN_MIN = 40       -- shortest straight road for the real-car drive
local FAST_GAP = 2            -- non-street tiles a straight road may have in a row (cracks, junk)
local SURVEY_ROWS_PER_TICK = 6

S.survey = nil

local function flag(name)
	local ok, f = pcall(function() return IsoFlagType[name] end)
	if ok then return f end
	return nil
end

-- B42 squares answer flags with has() (vanilla: sq:has(IsoFlagType.solid)); B41 used Is().
-- If the call fails once, flag checks are off for the rest of the survey: in debug mode every
-- caught error prints a stack trace, and this runs four times per square.
S.flagsBroken = false
local function sqIs(sq, f)
	if not f or S.flagsBroken then return false end
	local ok, v = pcall(function() return sq:has(f) end)
	if not ok then
		S.flagsBroken = true
		say("square flag check failed, skipping walls and fences in this survey: " .. tostring(v))
		return false
	end
	return v == true
end

local function hasProp(props, name)
	local ok, v = pcall(function() return props:has(name) end)
	return ok and v == true
end

local function freeAt(x, y, z)
	local ok, v = pcall(function()
		local sq = getCell():getGridSquare(x, y, z)
		return sq ~= nil and sq:getFloor() ~= nil and sq:isFree(false)
	end)
	return ok and v == true
end

K.flag, K.sqIs = flag, sqIs   -- for the drive's obstacle check, defined further up
local function hasTree(sq)
	local objs = sq:getObjects()
	for i = 0, objs:size() - 1 do
		if instanceof(objs:get(i), "IsoTree") then return true end
	end
	return false
end
K.hasTree = hasTree

-- Rows run over the tree band (TREE_RADIUS); everything but streets and trees is only looked for
-- within the survey radius, so the main plan is the same as before.
local function surveyRow(sv, y)
	local cell = getCell()
	local z = sv.z
	local innerRow = math.abs(y - sv.cy) <= sv.r
	for x = sv.cx - sv.rr, sv.cx + sv.rr do
		local sq = cell:getGridSquare(x, y, z)
		if sq then
			local fl = sq:getFloor()
			local street = false
			if fl then
				local sp = fl:getSprite()
				local name = sp and sp:getName()
				street = name ~= nil and string.find(name, "^blends_street") ~= nil
			end
			sv.street[x .. "," .. y] = street or nil
			if not street then
				local okt, tree = pcall(hasTree, sq)
				if okt and tree then sv.trees[x .. "," .. y] = true; sv.treeCount = sv.treeCount + 1 end
			end
			if innerRow and math.abs(x - sv.cx) <= sv.r then
			if sqIs(sq, sv.fTallW) then table.insert(sv.tall, { x = x, y = y, w = true }) end
			if sqIs(sq, sv.fTallN) then table.insert(sv.tall, { x = x, y = y, w = false }) end
			if sqIs(sq, sv.fHopW) then table.insert(sv.low, { x = x, y = y, w = true }) end
			if sqIs(sq, sv.fHopN) then table.insert(sv.low, { x = x, y = y, w = false }) end
			local props = sq:getProperties()
			if props and (hasProp(props, "ladderN") or hasProp(props, "ladderS") or hasProp(props, "ladderE") or hasProp(props, "ladderW")) then
				table.insert(sv.ladders, { x = x, y = y })
			end
			for _, ext in ipairs(T.finders) do pcall(ext.square, ext.state, sq, x, y, z) end
			local okb, b = pcall(function() return sq:getBuilding() end)
			if okb and b then
				local objs = sq:getObjects()
				for i = 0, objs:size() - 1 do
					local o = objs:get(i)
					if not instanceof(o, "IsoDeadBody") then
						local okc, c = pcall(function() return o:getContainer() end)
						if okc and c then
							table.insert(sv.containers, { x = x, y = y, b = tostring(b) })
							break
						end
					end
				end
			end
			if sq:getSpecialObjects():size() > 0 then
				local objs = sq:getObjects()
				for i = 0, objs:size() - 1 do
					local o = objs:get(i)
					if instanceof(o, "IsoDoor") then
						local okd, d = pcall(function()
							return { x = x, y = y, w = not o:getNorth(), open = o:IsOpen(),
								locked = o:isLocked(), barricaded = o:isBarricaded() }
						end)
						if okd and d and not d.open then table.insert(sv.doors, d) end
						if okd and d and (d.open or not (d.locked or d.barricaded)) then
							-- a door you can walk through: mark the building on either side as enterable
							local bx, by = d.w and x - 1 or x, d.w and y or y - 1
							for _, s2 in ipairs({ sq, cell:getGridSquare(bx, by, z) }) do
								local okb2, b2 = pcall(function() return s2:getBuilding() end)
								if okb2 and b2 then sv.enterable[tostring(b2)] = true end
							end
						end
					end
				end
			end
			end
		end
	end
end

local function dist2(a, cx, cy) return (a.x - cx) * (a.x - cx) + (a.y - cy) * (a.y - cy) end

local function nearestFirst(list, cx, cy)
	table.sort(list, function(a, b) return dist2(a, cx, cy) < dist2(b, cx, cy) end)
	return list
end

-- An edge on square (x,y): west edge (w) lies between x-1 and x, north edge between y-1 and y.
local function edgeCase(e, z, name)
	local sx, sy, tx, ty
	if e.w then sx, sy, tx, ty = e.x - 2, e.y, e.x + 1, e.y
	else sx, sy, tx, ty = e.x, e.y - 2, e.x, e.y + 1 end
	if freeAt(sx, sy, z) and freeAt(tx, ty, z) then
		return string.format("walkto = %s | %d,%d,%d | %d,%d,%d | any", name, sx, sy, z, tx, ty, z)
	end
	-- the other way round
	if e.w then sx, tx = e.x + 1, e.x - 2 else sy, ty = e.y + 1, e.y - 2 end
	if freeAt(sx, sy, z) and freeAt(tx, ty, z) then
		return string.format("walkto = %s | %d,%d,%d | %d,%d,%d | any", name, sx, sy, z, tx, ty, z)
	end
	return nil
end

local function nearestFree(x, y, z, reach)
	for r = 0, reach do
		for dy = -r, r do
			for dx = -r, r do
				if (math.abs(dx) == r or math.abs(dy) == r) and freeAt(x + dx, y + dy, z) then return x + dx, y + dy end
			end
		end
	end
	return nil
end

local function longestStreetRun(sv)
	local best = nil
	local function consider(ax, ay, bx, by, len)
		if len >= 12 and (not best or len > best.len) then best = { ax = ax, ay = ay, bx = bx, by = by, len = len } end
	end
	for y = sv.cy - sv.r, sv.cy + sv.r do
		local runStart, len = nil, 0
		for x = sv.cx - sv.r, sv.cx + sv.r + 1 do
			if sv.street[x .. "," .. y] then
				if not runStart then runStart = x end
				len = len + 1
			else
				if runStart then consider(runStart, y, x - 1, y, len) end
				runStart, len = nil, 0
			end
		end
	end
	for x = sv.cx - sv.r, sv.cx + sv.r do
		local runStart, len = nil, 0
		for y = sv.cy - sv.r, sv.cy + sv.r + 1 do
			if sv.street[x .. "," .. y] then
				if not runStart then runStart = y end
				len = len + 1
			else
				if runStart then consider(x, runStart, x, y - 1, len) end
				runStart, len = nil, 0
			end
		end
	end
	return best
end

-- The straight street stretch with the most trees on both verges: for every straight run of street
-- tiles (rows and columns, TREE_RUN_MIN or longer) within TREE_RADIUS, count trees in the band
-- TREE_BAND tiles out on each side. Score = trees on the thinner side per road tile, so a road
-- with trees on one side only scores 0.
local function treeRoad(sv)
	local best = nil
	local lo, hi = TREE_BAND[1], TREE_BAND[2]
	local function score(ax, ay, len, horizontal)
		local left, right = 0, 0
		for i = 0, len - 1 do
			local x, y = horizontal and ax + i or ax, horizontal and ay or ay + i
			for d = lo, hi do
				if horizontal then
					if sv.trees[x .. "," .. (y - d)] then left = left + 1 end
					if sv.trees[x .. "," .. (y + d)] then right = right + 1 end
				else
					if sv.trees[(x - d) .. "," .. y] then left = left + 1 end
					if sv.trees[(x + d) .. "," .. y] then right = right + 1 end
				end
			end
		end
		local s = math.min(left, right) / len
		if s > 0 and (not best or s > best.score) then
			best = { ax = ax, ay = ay, bx = horizontal and ax + len - 1 or ax, by = horizontal and ay or ay + len - 1,
				len = len, left = left, right = right, score = s }
		end
	end
	local r = sv.rr
	for y = sv.cy - r, sv.cy + r do
		local start, len = nil, 0
		for x = sv.cx - r, sv.cx + r + 1 do
			if sv.street[x .. "," .. y] then
				start = start or x
				len = len + 1
			else
				if start and len >= TREE_RUN_MIN then score(start, y, len, true) end
				start, len = nil, 0
			end
		end
	end
	for x = sv.cx - r, sv.cx + r do
		local start, len = nil, 0
		for y = sv.cy - r, sv.cy + r + 1 do
			if sv.street[x .. "," .. y] then
				start = start or y
				len = len + 1
			else
				if start and len >= TREE_RUN_MIN then score(x, start, len, false) end
				start, len = nil, 0
			end
		end
	end
	return best
end

-- The longest straight, clear stretch of street within TREE_RADIUS, for the real-car drive: rows and
-- columns, gaps of up to FAST_GAP non-street tiles allowed, moved to the middle of the street's
-- width, then cut at anything the car would hit (a blocked square or a parked vehicle on the line
-- or one tile either side of it). 1.5.0 skipped that last part, and the car hit something
-- 10 tiles in.
local function clearAt(x, y, z)
	if not freeAt(x, y, z) then return false end
	local sq = getCell():getGridSquare(x, y, z)
	if not sq then return false end
	local ok, v = pcall(function() return sq:getVehicleContainer() end)
	return not (ok and v)
end

local function fastRoad(sv)
	local runs = {}
	local r, z = sv.rr, sv.z
	local function street(x, y) return sv.street[x .. "," .. y] end
	for _, horizontal in ipairs({ true, false }) do
		for a = -r, r do
			local start, last, gap = nil, nil, 0
			for b = -r, r + FAST_GAP + 1 do
				local x, y = horizontal and sv.cx + b or sv.cx + a, horizontal and sv.cy + a or sv.cy + b
				if street(x, y) then
					start, last, gap = start or b, b, 0
				elseif start then
					gap = gap + 1
					if gap > FAST_GAP or b > r then
						if last - start + 1 >= FAST_RUN_MIN then
							runs[#runs + 1] = { a = a, from = start, to = last, len = last - start + 1, horizontal = horizontal }
						end
						start, last, gap = nil, nil, 0
					end
				end
			end
		end
	end
	table.sort(runs, function(p, q) return p.len > q.len end)
	local best = nil
	for _, rn in ipairs(runs) do
		if best and rn.len <= best.len then break end
		-- centre across the street at the middle of the rn
		local mid = floor((rn.from + rn.to) / 2)
		local function at(off)
			local a = rn.a + off
			if rn.horizontal then return street(sv.cx + mid, sv.cy + a) end
			return street(sv.cx + a, sv.cy + mid)
		end
		local lo, hi = 0, 0
		while lo < 6 and at(-(lo + 1)) do lo = lo + 1 end
		while hi < 6 and at(hi + 1) do hi = hi + 1 end
		local a = rn.a + floor((hi - lo) / 2)
		-- longest clear piece along that line
		local function clear(b)
			for off = -1, 1 do
				local x, y
				if rn.horizontal then x, y = sv.cx + b, sv.cy + a + off else x, y = sv.cx + a + off, sv.cy + b end
				if not clearAt(x, y, z) then return false end
			end
			return true
		end
		local s0, blocked = nil, 0
		for b = rn.from, rn.to + 1 do
			if b <= rn.to and clear(b) then
				s0 = s0 or b
			else
				if b <= rn.to then blocked = blocked + 1 end
				if s0 and b - s0 >= FAST_RUN_MIN and (not best or b - s0 > best.len) then
					best = { from = s0, to = b - 1, len = b - s0, horizontal = rn.horizontal, a = a,
						width = lo + hi + 1, cut = rn.len - (b - s0) }
				end
				s0 = nil
			end
		end
	end
	if not best then return nil end
	if best.horizontal then
		best.ax, best.ay, best.bx, best.by = sv.cx + best.from, sv.cy + best.a, sv.cx + best.to, sv.cy + best.a
	else
		best.ax, best.ay, best.bx, best.by = sv.cx + best.a, sv.cy + best.from, sv.cx + best.a, sv.cy + best.to
	end
	return best
end

-- A long straight street from the vanilla map near (cx, cy), for the real-car drive: the
-- TestGroundRoads list (shared/TestGroundRoads.lua, made from the game's streets.xml). The car needs
-- about 100 tiles to reach top speed and 100 to brake from it, so longer is better: score = distance
-- to the nearer end minus half the length (capped at 1500), within MAP_ROAD_RANGE. The nearer end
-- becomes end A, where the car starts.
local MAP_ROAD_RANGE = 3000
local MAP_ROAD_MIN = 500
-- Whether the street data (shared/TestGroundRoads.lua) is there: ok, and a line for the console.
-- The shared file should already have run; if it hasn't, it's asked for once more by name.
function T.mapData()
	if type(TestGroundRoutes) ~= "table" and type(TestGroundRoads) ~= "table" and not T.mapRequired then
		T.mapRequired = true
		local ok, err = pcall(function() require "TestGroundRoads" end)
		if not ok then T.mapRequireErr = string.match(tostring(err), "^[^\n]*") end
	end
	local routes = T.mapRoutes or TestGroundRoutes
	local roads = T.mapRoads or TestGroundRoads
	if type(routes) ~= "table" and type(roads) ~= "table" then
		return false, "shared/TestGroundRoads.lua did not load" .. (T.mapRequireErr and (": " .. T.mapRequireErr) or "; is it in mods/TestGround/42/media/lua/shared?")
	end
	return true, string.format("%d whole streets and %d straight pieces loaded", type(routes) == "table" and #routes or 0, type(roads) == "table" and #roads or 0)
end

function T.mapRoad(cx, cy)
	local list = T.mapRoads or TestGroundRoads
	if type(list) ~= "table" then return nil end
	local best, bestScore = nil, nil
	for _, rd in ipairs(list) do
		local name, w, x1, y1, x2, y2 = rd[1], rd[2], rd[3], rd[4], rd[5], rd[6]
		local len = math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1))
		local d1 = math.sqrt((x1 - cx) * (x1 - cx) + (y1 - cy) * (y1 - cy))
		local d2 = math.sqrt((x2 - cx) * (x2 - cx) + (y2 - cy) * (y2 - cy))
		local d = math.min(d1, d2)
		if len >= MAP_ROAD_MIN and d <= MAP_ROAD_RANGE then
			local score = d - 0.5 * math.min(len, 1500)
			if not bestScore or score < bestScore then
				bestScore = score
				if d2 < d1 then x1, y1, x2, y2 = x2, y2, x1, y1 end
				best = { name = name, width = w, ax = x1, ay = y1, bx = x2, by = y2, len = floor(len + 0.5), dist = floor(d + 0.5) }
			end
		end
	end
	return best
end

-- A whole street from the vanilla map for the real-car drive, several thousand tiles with its
-- corners (TestGroundRoutes in shared/TestGroundRoads.lua). It starts at the street's point nearest
-- (cx, cy), within MAP_ROAD_RANGE, and runs whichever way has more street, up to `want` tiles.
-- Returns { name, width, pts = { {x, y}, ... }, len, dist, corners } or nil.
K.ROUTE_WANT = 3600         -- tiles: 5 to 10 times the old straight-road drive (about 430 tiles)
K.ROUTE_MIN = 1500
K.ROUTE_CORNER_DEG = 12
function T.mapRoute(cx, cy, want)
	want = want or K.ROUTE_WANT
	local list = T.mapRoutes or TestGroundRoutes
	if type(list) ~= "table" then return nil end
	local best = nil
	for _, rt in ipairs(list) do
		local name, w, flat = rt[1], rt[2], rt[3]
		local pts = {}
		for i = 1, #flat - 1, 2 do pts[#pts + 1] = { x = flat[i], y = flat[i + 1] } end
		-- nearest point on the street
		local bd, bi, bx, by = nil, nil, nil, nil
		for i = 1, #pts - 1 do
			local a, b = pts[i], pts[i + 1]
			local dx, dy = b.x - a.x, b.y - a.y
			local l2 = dx * dx + dy * dy
			local t = l2 > 0 and math.max(0, math.min(1, ((cx - a.x) * dx + (cy - a.y) * dy) / l2)) or 0
			local px, py = a.x + dx * t, a.y + dy * t
			local d = math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))
			if not bd or d < bd then bd, bi, bx, by = d, i, px, py end
		end
		if bd and bd <= MAP_ROAD_RANGE then
			-- walk both ways from there, up to `want` tiles
			local function walk(stepDir)
				local out = { { x = floor(bx + 0.5), y = floor(by + 0.5) } }
				local len = 0
				local i = stepDir > 0 and bi + 1 or bi
				local px, py = bx, by
				while i >= 1 and i <= #pts and len < want do
					local q = pts[i]
					local d = math.sqrt((q.x - px) * (q.x - px) + (q.y - py) * (q.y - py))
					if len + d > want then
						local f = (want - len) / d
						q = { x = px + (q.x - px) * f, y = py + (q.y - py) * f }
						d = want - len
					end
					if d >= 1 then
						out[#out + 1] = { x = floor(q.x + 0.5), y = floor(q.y + 0.5) }
						len = len + d
						px, py = q.x, q.y
					end
					i = i + stepDir
				end
				return out, len
			end
			local fwd, lf = walk(1)
			local back, lb = walk(-1)
			local path, len = fwd, lf
			if lb > lf then path, len = back, lb end
			if len >= K.ROUTE_MIN then
				local score = bd - 0.5 * math.min(len, want)
				if not best or score < best.score then
					local corners = 0
					for k = 2, #path - 1 do
						local a1 = math.atan2 and math.atan2(path[k].y - path[k - 1].y, path[k].x - path[k - 1].x) or 0
						local a2 = math.atan2 and math.atan2(path[k + 1].y - path[k].y, path[k + 1].x - path[k].x) or 0
						local da = a2 - a1
						while da > math.pi do da = da - 2 * math.pi end
						while da < -math.pi do da = da + 2 * math.pi end
						if math.abs(da) * 180 / math.pi >= K.ROUTE_CORNER_DEG then corners = corners + 1 end
					end
					best = { name = name, width = w, pts = path, len = floor(len + 0.5), dist = floor(bd + 0.5),
						corners = corners, score = score }
				end
			end
		end
	end
	return best
end

-- Seconds for the drive: the route at about 22 tiles/s, 6 s per corner, 30 s to load and get going.
local function routeSeconds(len, corners)
	return math.max(90, math.min(400, floor(len / 22 + 6 * (corners or 0) + 30)))
end

-- Zombie intensity from the map (the same numbers the game spawns by), 0 when it can't be read.
K.NATURAL_FILE = "TestGround_natural.txt"
K.NATURAL_RANGE = 160
K.NATURAL_STEP = 8
K.NATURAL_WINDOW = 40
local function intensityAt(x, y)
	local ok, v = pcall(function() return getWorld():getMetaGrid():getChunkDataFromTile(x, y):getZombieIntensity() end)
	return ok and tonumber(v) or nil
end
T.intensityAt = intensityAt

function T.naturalZone(cx, cy)
	local n = floor(K.NATURAL_RANGE / K.NATURAL_STEP)
	local grid, any = {}, false
	for j = -n, n do
		grid[j] = {}
		for i = -n, n do
			local v = intensityAt(cx + i * K.NATURAL_STEP, cy + j * K.NATURAL_STEP)
			if v then any = true end
			grid[j][i] = v or 0
		end
	end
	if not any then return nil end
	local w = floor(K.NATURAL_WINDOW / K.NATURAL_STEP)
	local best = nil
	for j = -n, n - w + 1 do
		for i = -n, n - w + 1 do
			local sum = 0
			for b = 0, w - 1 do for a = 0, w - 1 do sum = sum + grid[j + b][i + a] end end
			local avg = sum / (w * w)
			if not best or avg > best.score then
				best = { score = avg, x = cx + floor((i + (w - 1) / 2) * K.NATURAL_STEP), y = cy + floor((j + (w - 1) / 2) * K.NATURAL_STEP) }
			end
		end
	end
	best.here = grid[0][0]
	return best
end

local function startLine(sv)
	local here = sv.cx .. "," .. sv.cy .. "," .. sv.z
	if not sv.spot then return "start = " .. here end
	return "start = " .. sv.spot .. "          # " .. sv.spotName .. " (" .. here .. "), the fixed test start; 'here' runs where the save loaded"
end

local function surveyFinish(sv)
	local z, cx, cy = sv.z, sv.cx, sv.cy
	local lines = {
		"# Test Ground plan written by the survey around " .. cx .. "," .. cy .. "," .. z .. ". Edit freely.",
		"label = survey",
		"settle = 10",
		"repeat = 1",
		"autostart = 0",
		"return = 1",
		startLine(sv),
		"time = 12",
		"weather = clear",
		"zombies = none",
		"god = 1",
		"",
	}
	local found = {}
	-- route: a loop at about half the radius
	local h = floor(sv.r / 2)
	local route = {}
	for _, c in ipairs({ { -h, -h }, { h, -h }, { h, h }, { -h, h } }) do
		local x, y = nearestFree(cx + c[1], cy + c[2], z, 6)
		if x then route[#route + 1] = string.format("route = %d,%d,%d", x, y, z) end
	end
	-- road
	local road = longestStreetRun(sv)
	local roadLines = {}
	if road then
		roadLines = { string.format("road = %d,%d,%d", road.ax, road.ay, z), string.format("road = %d,%d,%d", road.bx, road.by, z) }
		found[#found + 1] = "a " .. road.len .. "-tile street"
	end
	-- walkto cases
	local cases = {}
	local ox, oy = nearestFree(cx + 6, cy, z, 3)
	if ox then cases[#cases + 1] = string.format("walkto = open | %d,%d,%d | %d,%d,%d | any", cx, cy, z, ox, oy, z) end
	local function addEdges(list, name, max)
		local n = 0
		for _, e in ipairs(nearestFirst(list, cx, cy)) do
			if n >= max then break end
			local line = edgeCase(e, z, name .. (n + 1))
			if line then cases[#cases + 1] = line; n = n + 1 end
		end
		return n
	end
	local nTall = addEdges(sv.tall, "tallwall", 2)
	local nLow = addEdges(sv.low, "fence", 1)
	local bad, good = {}, {}
	for _, d in ipairs(sv.doors) do
		if d.locked or d.barricaded then bad[#bad + 1] = d else good[#good + 1] = d end
	end
	local nBad = addEdges(bad, "lockeddoor", 2)
	local nGood = addEdges(good, "door", 1)
	local nLadder = 0
	for _, l in ipairs(nearestFirst(sv.ladders, cx, cy)) do
		if nLadder >= 2 then break end
		local ax, ay = nearestFree(l.x + 3, l.y, z, 3)
		local okTop, top = pcall(function()
			local sq = getCell():getGridSquare(l.x, l.y, z + 1)
			return sq ~= nil and sq:getFloor() ~= nil
		end)
		if ax and okTop and top then
			nLadder = nLadder + 1
			cases[#cases + 1] = string.format("walkto = ladder%d | %d,%d,%d | %d,%d,%d | any | walktoplus", nLadder, ax, ay, z, l.x, l.y, z + 1)
		end
	end
	found[#found + 1] = string.format("%d tall wall, %d fence, %d locked door, %d door, %d ladder cases", nTall, nLow, nBad, nGood, nLadder)

	if #route >= 2 then lines[#lines + 1] = "step = walk 2" end
	lines[#lines + 1] = "step = stream 60"
	lines[#lines + 1] = "step = idle 30"
	lines[#lines + 1] = "step = turn 20"
	lines[#lines + 1] = "step = wait 60 3"
	if #cases > 0 then lines[#lines + 1] = "step = walkto" end
	lines[#lines + 1] = ""
	for _, l in ipairs(route) do lines[#lines + 1] = l end
	if #roadLines == 0 then
		-- no street in range: sweep the route loop instead
		for _, l in ipairs(route) do roadLines[#roadLines + 1] = (string.gsub(l, "^route", "road")) end
		found[#found + 1] = "no street, the stream step sweeps the walk loop"
	end
	for _, l in ipairs(roadLines) do lines[#lines + 1] = l end
	for _, l in ipairs(cases) do lines[#lines + 1] = l end

	-- Everything found, for writing other plans from (one line per feature, nearest first).
	local site = { "# Test Ground site survey around " .. cx .. "," .. cy .. "," .. z .. ", radius " .. sv.r,
		string.format("center %d,%d,%d", cx, cy, z) }
	local function list(kind, items, fmt)
		for i, e in ipairs(nearestFirst(items, cx, cy)) do
			if i > 60 then break end
			site[#site + 1] = kind .. " " .. fmt(e)
		end
	end
	local function edge(e) return string.format("%d,%d,%d %s", e.x, e.y, z, e.w and "W" or "N") end
	list("tallwall", sv.tall, edge)
	list("fence", sv.low, edge)
	list("door", sv.doors, function(e)
		return edge(e) .. (e.locked and " locked" or "") .. (e.barricaded and " barricaded" or "")
	end)
	list("ladder", sv.ladders, function(e) return string.format("%d,%d,%d", e.x, e.y, z) end)
	if road then site[#site + 1] = string.format("street %d,%d,%d %d,%d,%d %d", road.ax, road.ay, z, road.bx, road.by, z, road.len) end
	for _, ext in ipairs(T.finders) do
		local okf, extra = pcall(ext.finish, ext.state, cx, cy, z)
		if okf and type(extra) == "table" then for _, l in ipairs(extra) do site[#site + 1] = ext.name .. " " .. l end end
	end
	list("container", sv.containers, function(e) return string.format("%d,%d,%d", e.x, e.y, z) end)
	local tr = sv.treePick or treeRoad(sv)
	if sv.treeTried then
		site[#site + 1] = "treeroad candidates from the map: " .. table.concat(sv.treeTried, ", ")
		say("tree-lined road: " .. (sv.treePick and string.format("%s from the map won (%.2f trees per tile each side)", sv.treePick.name, sv.treePick.score)
			or "no map candidate beat the local one") .. "; tried " .. table.concat(sv.treeTried, ", "))
	end
	if tr and tr.map then
		site[#site + 1] = string.format("treeroad %d,%d,0 %d,%d,0 %d tiles, %s from the map, %.2f trees per tile each side",
			tr.ax, tr.ay, tr.bx, tr.by, tr.len, tr.name, tr.score)
		found[#found + 1] = string.format("%s from the map as the tree-lined road (%.2f trees per tile on each side)", tr.name, tr.score)
	elseif tr then
		site[#site + 1] = string.format("treeroad %d,%d,%d %d,%d,%d %d tiles, %d trees one side, %d the other, %.1f per tile",
			tr.ax, tr.ay, z, tr.bx, tr.by, z, tr.len, tr.left, tr.right, tr.score)
		found[#found + 1] = string.format("a %d-tile tree-lined road (%.1f trees per tile on each side)", tr.len, tr.score)
	else
		found[#found + 1] = "no tree-lined road within " .. sv.rr .. " tiles (" .. sv.treeCount .. " trees seen)"
	end
	local mapOk, mapWhy = T.mapData()
	local fr = T.mapRoute(cx, cy)
	local routeSource
	if fr then
		routeSource = string.format("map route %s won (%d tiles, %d tiles from the start)", fr.name, fr.len, fr.dist)
		fr.map = true
		fr.seconds = routeSeconds(fr.len, fr.corners)
		site[#site + 1] = string.format("fastroute %s, %d tiles from %d,%d to %d,%d, %d points, %d corners, street %d wide, %d tiles from the start",
			fr.name, fr.len, fr.pts[1].x, fr.pts[1].y, fr.pts[#fr.pts].x, fr.pts[#fr.pts].y, #fr.pts, fr.corners, fr.width, fr.dist)
		found[#found + 1] = string.format("%s from the map (%d tiles, %d corners) for the real-car drive", fr.name, fr.len, fr.corners)
	else
		fr = T.mapRoad(cx, cy)
		if fr then
			routeSource = string.format("no map route of %d+ tiles within %d tiles, so the map's straight %s won (%d tiles)", K.ROUTE_MIN, MAP_ROAD_RANGE, fr.name, fr.len)
			fr.map = true
			fr.pts = { { x = fr.ax, y = fr.ay }, { x = fr.bx, y = fr.by } }
			fr.seconds = 120
			site[#site + 1] = string.format("fastroad %d,%d,0 %d,%d,0 %d tiles, street %d wide, %s from the map, nearer end %d tiles away",
				fr.ax, fr.ay, fr.bx, fr.by, fr.len, fr.width, fr.name, fr.dist)
			found[#found + 1] = string.format("%s from the map (%d tiles straight) for the real-car drive", fr.name, fr.len)
		else
			fr = fastRoad(sv)
			routeSource = (mapOk and string.format("nothing usable on the map within %d tiles", MAP_ROAD_RANGE) or ("map data NOT loaded (" .. mapWhy .. ")")) ..
				", so the local survey's " .. (fr and (fr.len .. "-tile road") or "(no road either)") .. " is used"
		end
	end
	say("drive_fast road: " .. routeSource)
	site[#site + 1] = "fastsource " .. routeSource
	if fr and fr.map then
		-- already said
	elseif fr then
		site[#site + 1] = string.format("fastroad %d,%d,%d %d,%d,%d %d tiles, street %d wide", fr.ax, fr.ay, z, fr.bx, fr.by, z, fr.len, fr.width)
		found[#found + 1] = string.format("a %d-tile straight road for the real-car drive", fr.len)
	else
		found[#found + 1] = "no straight road of " .. FAST_RUN_MIN .. "+ tiles within " .. sv.rr .. " tiles (no real-car drive)"
	end
	writeLines(TG.SITE_FILE, site, false)

	-- The baseline scenario: drive, walk, small fight, loot one building, large fight, drive back.
	local loot = {}
	local sorted = nearestFirst(sv.containers, cx, cy)
	if #sorted > 0 then
		-- the nearest building with a door you can walk through (a barricaded house can't be looted
		-- on foot); if none has one, the nearest building, and the loot step teleports in
		local first = sorted[1]
		for _, c in ipairs(sorted) do
			if sv.enterable[c.b] then first = c; break end
		end
		found[#found + 1] = sv.enterable[first.b] and "loot building has a usable door" or "no loot building with a usable door"
		local inBuilding = {}
		for _, c in ipairs(sorted) do if c.b == first.b then inBuilding[#inBuilding + 1] = c end end
		for i, c in ipairs(nearestFirst(inBuilding, first.x, first.y)) do
			if i > TG.BASELINE_CONTAINERS then break end
			loot[#loot + 1] = string.format("loot = %d,%d,%d", c.x, c.y, z)
		end
	end
	local dx, dy = 1, 0
	if road then
		dx, dy = road.bx - road.ax, road.by - road.ay
		local len = math.sqrt(dx * dx + dy * dy)
		dx, dy = dx / len, dy / len
	end
	local base = {
		"# Baseline scenario written by the survey around " .. cx .. "," .. cy .. "," .. z .. ". Edit freely.",
		"label = baseline",
		"settle = 30",
		"repeat = 1",
		"autostart = 0",
		"return = 1",
		startLine(sv),
		"time = 12",
		"weather = clear",
		"zombies = none",
		"god = 1",
		"",
		-- 1.13.7: the order and names of the step name review (see media/TestGround/baseline.txt)
		"step = walk 2 walk",
		"step = loot loot",
		"step = drive 60 20 glide_south",
		"step = drive 40 20 -1 glide_north",
		"step = weather fog",
		"step = drive 60 20 glide_fog",
		"step = weather clear",
		"step = treeroad 40 20 glide_trees",
		-- the cruise speed is written out (120 km/h), so it doesn't follow whichever car spawns
		(fr and fr.map) and ("step = drivefast " .. fr.seconds .. " 120 drive_fast") or "step = drivefast 90 120 drive_fast",
		"# corpses in every chunk along the first 1000 tiles of the fast road, a drive back through them",
		"# as the chunks load again, then every corpse taken back off",
		"step = corpses 30 setup_corpses",
		"step = drivefast 45 120 drive_corpses",
		"step = corpses clear cleanup_corpses",
		"step = fight 6 30 fight_small",
		"step = fight 40 60 fight_large",
		"step = realfight 6 30 fight_swing",
		"step = stress 500 60 stress_500",
		"",
		string.format("drive = %.3f,%.3f", dx, dy),
	}
	for _, l in ipairs(route) do base[#base + 1] = l end
	for _, l in ipairs(loot) do base[#base + 1] = l end
	if tr then
		base[#base + 1] = string.format("treeroad = %d,%d,%d", tr.ax, tr.ay, z)
		base[#base + 1] = string.format("treeroad = %d,%d,%d", tr.bx, tr.by, z)
	end
	if fr and fr.map then
		base[#base + 1] = "fastname = " .. fr.name
		base[#base + 1] = "fastwidth = " .. fr.width
		for _, p in ipairs(fr.pts) do base[#base + 1] = string.format("fastroad = %d,%d,0", p.x, p.y) end
	elseif fr then
		base[#base + 1] = string.format("fastroad = %d,%d,%d", fr.ax, fr.ay, z)
		base[#base + 1] = string.format("fastroad = %d,%d,%d", fr.bx, fr.by, z)
	end
	writeLines(TG.BASELINE_FILE, base, false)
	found[#found + 1] = #loot .. " loot containers in one building"

	-- The natural zombie zone: the densest 40x40 tiles by the map's zombie intensity near here.
	local zone = T.naturalZone(cx, cy)
	say(zone and string.format("zombie intensity: %.2f at the start %d,%d; the densest 40x40 tiles within %d tiles is %.2f at %d,%d",
		zone.here or -1, cx, cy, K.NATURAL_RANGE, zone.score, zone.x, zone.y) or "zombie intensity: not readable")
	if zone then
		local nat = {
			"# Natural zombie zone written by the survey: the densest " .. K.NATURAL_WINDOW .. "x" .. K.NATURAL_WINDOW .. " tiles by the map's zombie",
			"# intensity within " .. K.NATURAL_RANGE .. " tiles of " .. cx .. "," .. cy .. " (" .. string.format("%.2f there, %.2f round here", zone.score, zone.here or -1) .. ").",
			"# The game's own zombies are kept; nothing is spawned. Edit freely.",
			"label = natural",
			"settle = 10",
			"repeat = 1",
			"autostart = 0",
			"return = 1",
			string.format("start = %d,%d,0", zone.x, zone.y),
			string.format("zone = %d,%d,0", zone.x, zone.y),
			"time = 12",
			"weather = clear",
			"zombies = keep",
			"god = 0",
			"",
			"step = natural 60 stand zone_stand",
			"step = natural 90 run zone_run",
		}
		writeLines(K.NATURAL_FILE, nat, false)
		found[#found + 1] = string.format("a natural zombie zone at %d,%d (intensity %.2f, %.2f at the start) in %s", zone.x, zone.y, zone.score, zone.here or -1, K.NATURAL_FILE)
	else
		found[#found + 1] = "no zombie intensity readable, so no natural zone"
	end

	local ok = writeLines(TG.SURVEY_FILE, lines, false)
	local summary = "survey done" .. (sv.spot and (" at " .. sv.spotName .. " (" .. tostring(sv.loadNote) .. ")") or " where the save loaded") .. ": " .. #route .. " route points, " .. table.concat(found, ", ") ..
		(ok and (", written to Zomboid/Lua/" .. TG.SURVEY_FILE) or ", could NOT write the plan")
	say(summary)
	if sv.onDone then
		S.pendingHome = sv.home
		pcall(sv.onDone, ok, summary)
		S.pendingHome = nil
	end
end

-- Starts a survey around player 0, or at a fixed start (spotKey, a key of T.spots: the player is
-- teleported there and the survey waits for it to load). onDone(ok, summary) is called when it's written.
function T.survey(radius, onDone, spotKey)
	if K.mpBlocked() then say("singleplayer only; not run"); return false end
	if S.survey or S.run then return false end
	local p = player()
	if not p then return false end
	local sp = spotKey and T.spots[spotKey]
	if spotKey and not sp then return false end
	local cx, cy, cz = floor(p:getX()), floor(p:getY()), floor(p:getZ())
	-- 1.13.2 (review): where the player really was, so the run the survey starts goes back there
	-- ("return = 1"), not to the fixed start it teleported to
	local home = { x = cx, y = cy, z = cz }
	if sp then
		cx, cy, cz = sp.x, sp.y, sp.z
		teleport(p, cx, cy, cz)
	end
	S.survey = {
		home = home,
		spot = sp and spotKey, spotName = sp and sp.name, loadingSince = sp and now() or nil,
		cx = cx, cy = cy, z = cz, r = radius or SURVEY_RADIUS,
		street = {}, tall = {}, low = {}, doors = {}, ladders = {}, containers = {}, enterable = {},
		trees = {}, treeCount = 0,
		fTallW = flag("TallHoppableW"), fTallN = flag("TallHoppableN"),
		fHopW = flag("HoppableW"), fHopN = flag("HoppableN"),
		onDone = onDone,
	}
	S.survey.rr = math.max(S.survey.r, TREE_RADIUS)
	S.survey.y = S.survey.cy - S.survey.rr
	S.flagsBroken = false
	for _, ext in ipairs(T.finders) do ext.state = {} end
	say("surveying " .. (2 * S.survey.r + 1) .. "x" .. (2 * S.survey.r + 1) .. " squares around " .. S.survey.cx .. "," .. S.survey.cy .. "," .. S.survey.z ..
		(sp and (" (" .. sp.name .. ", the fixed test start)") or ""))
	return true
end

-- A tree-lined road with real trees (1.8.3). streets.xml has no trees, so the survey's own search
-- only sees what's within 80 tiles, and at West Point that's 0.0 trees per tile. When the local
-- best is under K.TREE_GOOD, the nearest rural pieces from TestGroundTreeRoads (no building within
-- 40 tiles on the map, so most likely woods) are visited one by one: teleport to the middle, wait
-- for it to load, count trees 2 to 8 tiles out on each side along the middle 80 tiles. The first
-- with K.TREE_GOOD or more wins; otherwise the best seen. Then back to the start to finish.
K.TREE_GOOD = 0.3   -- 1.10.0: 0.5 was more than any road in a 25-road scan had (best 0.35)
K.TREE_TRIES = 4
K.TREE_RANGE = 2500
K.TREE_LOAD_MS = 15000

local function treeCount(ax, ay, bx, by, z, lo, hi)
	local cell = getCell()
	local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
	if len < 1 then return 0, 0 end
	local ux, uy = (bx - ax) / len, (by - ay) / len
	local nx, ny = -uy, ux
	local mid = len / 2
	local left, right, n = 0, 0, 0
	for s = math.max(0, mid - 40), math.min(len, mid + 40) do
		local cx, cy = ax + ux * s, ay + uy * s
		n = n + 1
		for d = lo or TREE_BAND[1], hi or TREE_BAND[2] do
			for side = -1, 1, 2 do
				local sq = cell:getGridSquare(floor(cx + nx * d * side), floor(cy + ny * d * side), z)
				if sq then
					local ok, yes = pcall(hasTree, sq)
					if ok and yes then
						if side < 0 then left = left + 1 else right = right + 1 end
					end
				end
			end
		end
	end
	return math.min(left, right) / math.max(1, n), n
end
T.treeCount = treeCount
T.K = K   -- for the mock tests

-- 1.9.3: the map's zones (loaded for the whole map, no teleport needed) say where the woods are:
-- share of verge points 3 and 6 tiles out, every 10 tiles along the piece, in a zone whose type
-- has "Forest" in it (Forest, DeepForest, ...); the thinner side counts. Candidates are tried
-- most wooded first, and "treescan" writes the real counts to TREE_FILE for later surveys.
K.TREE_FILE = "TestGround_treeroads.txt"
K.TREE_SCAN_N = 400   -- all of them: a visit takes about 1.5 s
function K.isForest(x, y)
	local ok, yes = pcall(function()
		local zs = getWorld():getMetaGrid():getZonesAt(x, y, 0)
		if not zs then return false end
		for i = 0, zs:size() - 1 do
			local ty = zs:get(i):getType()
			if ty and string.find(tostring(ty), "Forest") then return true end
		end
		return false
	end)
	return ok and yes
end
function K.forestScore(rd)
	local ax, ay, bx, by = rd[3], rd[4], rd[5], rd[6]
	local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
	if len < 1 then return 0 end
	local ux, uy = (bx - ax) / len, (by - ay) / len
	local nx, ny = -uy, ux
	local l, r, n = 0, 0, 0
	for s = 0, len, 10 do
		local cx, cy = ax + ux * s, ay + uy * s
		for _, d in ipairs({ 3, 6 }) do
			n = n + 1
			if K.isForest(floor(cx - nx * d), floor(cy - ny * d)) then l = l + 1 end
			if K.isForest(floor(cx + nx * d), floor(cy + ny * d)) then r = r + 1 end
		end
	end
	return math.min(l, r) / math.max(1, n)
end
-- Candidates from the map list within range (nil: any distance), most wooded first, then nearest.
function K.treeCands(cx, cy, range)
	local list = T.mapTreeRoads or TestGroundTreeRoads
	if type(list) ~= "table" then return {} end
	local cands = {}
	for _, rd in ipairs(list) do
		local mx, my = (rd[3] + rd[5]) / 2, (rd[4] + rd[6]) / 2
		local d = math.sqrt((mx - cx) ^ 2 + (my - cy) ^ 2)
		if not range or d <= range then cands[#cands + 1] = { rd = rd, d = d, forest = K.forestScore(rd) } end
	end
	table.sort(cands, function(a, b)
		if a.forest ~= b.forest then return a.forest > b.forest end
		return a.d < b.d
	end)
	return cands
end
-- TREE_FILE lines: name | x1,y1,x2,y2 | trees per tile (thinner side) | forest share
function K.knownTreeRoads()
	local lines = readLines(K.TREE_FILE)
	local out = {}
	if (not lines or #lines == 0) and type(TestGroundTreeRoadsScanned) == "table" then
		for _, e in ipairs(TestGroundTreeRoadsScanned) do
			out[#out + 1] = { name = e[1], ax = e[2], ay = e[3], bx = e[4], by = e[5], score = e[6] }
		end
		return out
	end
	for _, l in ipairs(lines or {}) do
		local name, ax, ay, bx, by, sc = string.match(l, "^([^#|][^|]-)%s*|%s*(%d+),(%d+),(%d+),(%d+)%s*|%s*([%d.]+)")
		if name then out[#out + 1] = { name = name, ax = tonumber(ax), ay = tonumber(ay), bx = tonumber(bx), by = tonumber(by), score = tonumber(sc) } end
	end
	return out
end

function K.startTreeHunt(sv)
	local okL, local0 = pcall(treeRoad, sv)
	sv.localTree = okL and local0 or nil
	if sv.localTree and sv.localTree.score >= K.TREE_GOOD then return false end
	-- a scanned road from TREE_FILE: no visits needed
	local best
	for _, k in ipairs(K.knownTreeRoads()) do
		if not best or k.score > best.score then best = k end
	end
	if best and best.score >= K.TREE_GOOD and (not sv.localTree or best.score > sv.localTree.score) then
		best.len = floor(math.sqrt((best.bx - best.ax) ^ 2 + (best.by - best.ay) ^ 2) + 0.5)
		best.map, best.left, best.right = true, 0, 0
		sv.treePick = best
		sv.treeTried = { "from " .. ((readLines(K.TREE_FILE) or {})[1] and K.TREE_FILE or "the scanned list in TestGroundRoads.lua") }
		return false
	end
	local cands = K.treeCands(sv.cx, sv.cy, K.TREE_RANGE)
	if #cands == 0 then return false end
	local p = player()
	local okG, g0 = pcall(function() return p:isGhostMode() end)
	sv.treeHunt = { cands = cands, i = 0, tried = {}, ghost0 = okG and g0 or false, max = K.TREE_TRIES }
	say(string.format("tree-lined road here is weak (%s), checking %d rural roads from the map",
		sv.localTree and string.format("%.2f trees per tile each side", sv.localTree.score) or "none found", math.min(K.TREE_TRIES, #cands)) ..
		string.format(", most wooded first (forest zones %.0f%% for the first)", cands[1].forest * 100))
	return true
end

-- One tick of the hunt; true when it's over (and the player is back and loaded at the start).
function K.treeHuntTick(sv)
	local h = sv.treeHunt
	local p = player()
	local t = now()
	if h.back then
		if areaLoaded(sv.cx, sv.cy, sv.z, sv.r) or t - h.back >= K.TREE_LOAD_MS then return true end
		return false
	end
	if h.cur then
		local rd = h.cur.rd
		local mx, my = floor((rd[3] + rd[5]) / 2), floor((rd[4] + rd[6]) / 2)
		if not (areaLoaded(mx, my, 0, 30) or t - h.since >= K.TREE_LOAD_MS) then return false end
		if t - h.since < 1500 then return false end
		local score = treeCount(rd[3], rd[4], rd[5], rd[6], 0)
		h.tried[#h.tried + 1] = string.format("%s %.2f", rd[1], score)
		if h.results then
			local wide = treeCount(rd[3], rd[4], rd[5], rd[6], 0, 2, 20)
			h.results[#h.results + 1] = { rd = rd, score = score, forest = h.cur.forest or 0, wide = wide,
				loaded = areaLoaded(mx, my, 0, 30) }
		end
		say(string.format("tree road candidate %s %d,%d-%d,%d: %.2f trees per tile each side (forest zones %.0f%%)", rd[1], rd[3], rd[4], rd[5], rd[6], score, (h.cur.forest or 0) * 100))
		if not h.best or score > h.best.score then
			h.best = { ax = rd[3], ay = rd[4], bx = rd[5], by = rd[6], len = floor(math.sqrt((rd[5] - rd[3]) ^ 2 + (rd[6] - rd[4]) ^ 2) + 0.5),
				score = score, name = rd[1], map = true, left = 0, right = 0 }
		end
		h.cur = nil
		if score >= K.TREE_GOOD and not h.all then h.i = #h.cands end
	end
	h.i = h.i + 1
	if h.i > math.min(h.max or K.TREE_TRIES, #h.cands) then
		if h.best and (not sv.localTree or h.best.score > sv.localTree.score) then sv.treePick = h.best end
		sv.treeTried = h.tried
		if p then
			teleport(p, sv.cx, sv.cy, sv.z)
			pcall(function() p:setGhostMode(h.ghost0) end)
		end
		h.back = t
		return false
	end
	h.cur = h.cands[h.i]
	h.since = t
	local rd = h.cur.rd
	if p then
		pcall(function() p:setGhostMode(true) end)
		teleport(p, floor((rd[3] + rd[5]) / 2), floor((rd[4] + rd[6]) / 2), 0)
	end
	return false
end

local function onSurveyTick()
	local sv = S.survey
	if not sv then return end
	if sv.loadingSince then
		-- teleported to a fixed start: wait for the squares to stream in, then 2 s more
		local t = now()
		if not sv.readyAt then
			local loaded = areaLoaded(sv.cx, sv.cy, sv.z, sv.r)
			if loaded or t - sv.loadingSince >= K.SPOT_LOAD_MS then
				sv.readyAt = t + 2000
				sv.loadNote = string.format("%s %s after %.1f s", sv.spotName, loaded and "loaded" or "still NOT fully loaded", (t - sv.loadingSince) / 1000)
				say(sv.loadNote)
			end
			return
		end
		if t < sv.readyAt then return end
		sv.loadingSince = nil
	end
	if sv.treeHunt then
		if not K.treeHuntTick(sv) then return end
		sv.treeHunt = nil
	end
	for _ = 1, SURVEY_ROWS_PER_TICK do
		if sv.y > sv.cy + sv.rr and not sv.treeHuntDone then
			-- the rows are done; if the tree-lined road here is weak, go and look at rural roads from
			-- the map first (each is teleported to, loaded and counted), then come back and finish
			sv.treeHuntDone = true
			if K.startTreeHunt(sv) then return end
		end
		if sv.y > sv.cy + sv.rr then
			S.survey = nil
			local ok, err = pcall(surveyFinish, sv)
			if not ok then
				say("survey failed: " .. tostring(err))
				if sv.onDone then pcall(sv.onDone, false, "survey failed: " .. tostring(err)) end
			end
			return
		end
		local ok, err = pcall(surveyRow, sv, sv.y)
		if not ok then say("survey row " .. sv.y .. " failed: " .. tostring(err)) end
		sv.y = sv.y + 1
	end
end

-- "treescan [N]": a one-off job. Visits the N most wooded rural roads on the whole map (by forest
-- zones), counts the real trees on each and writes TREE_FILE, best first; later surveys take the
-- best road from it with no visits. Ends back where it started.
S.treeScan = nil
function T.treeScan(n)
	if K.mpBlocked() then return false, "singleplayer only" end
	if S.run or S.survey or S.treeScan then return false, "busy (a survey, run or scan is going)" end
	local p = player()
	if not p then return false, "no player" end
	local cands = K.treeCands(p:getX(), p:getY(), nil)
	if #cands == 0 then return false, "no rural road list (TestGroundTreeRoads)" end
	local okG, g0 = pcall(function() return p:isGhostMode() end)
	local sv = { cx = floor(p:getX()), cy = floor(p:getY()), z = floor(p:getZ()), r = 30, t0 = now() }
	sv.treeHunt = { cands = cands, i = 0, tried = {}, results = {}, ghost0 = okG and g0 or false,
		max = math.min(n or K.TREE_SCAN_N, #cands), all = true }
	S.treeScan = sv
	say(string.format("tree scan: visiting the %d most wooded of %d rural roads", sv.treeHunt.max, #cands))
	return true
end
function K.treeScanTick()
	local sv = S.treeScan
	if not sv then return end
	if not K.treeHuntTick(sv) then return end
	S.treeScan = nil
	local res = sv.treeHunt.results
	table.sort(res, function(a, b) return a.score > b.score end)
	local lines = { "# Test Ground tree road scan " .. VERSION .. ": name | x1,y1,x2,y2 | trees per tile on the thinner side (2 to 8 tiles out, middle 80 tiles) | share of verge in forest zones | trees per tile 2 to 20 tiles out (thinner side)",
		"# made by the treescan command; surveys take the best line scoring " .. K.TREE_GOOD .. " or more" }
	for _, e in ipairs(res) do
		local rd = e.rd
		lines[#lines + 1] = string.format("%s | %d,%d,%d,%d | %.2f | %.2f | %.2f%s", rd[1], rd[3], rd[4], rd[5], rd[6], e.score, e.forest, e.wide or 0,
			e.loaded and "" or " | NOT LOADED")
	end
	writeLines(K.TREE_FILE, lines)
	local top = res[1]
	local msg = string.format("tree scan done in %.0f s: %d roads, best %s", (now() - sv.t0) / 1000, #res,
		top and string.format("%s %.2f trees per tile each side", top.rd[1], top.score) or "none")
	say(msg)
	if K.bridgeOut then K.bridgeOut({ "=== " .. msg .. " (" .. K.TREE_FILE .. ")" }) end
	if T.onScanDone then pcall(T.onScanDone, K.TREE_FILE, msg) end
end

-- Context menu: run, stop, record ----------------------------------------------------------

local function appendPlan(line)
	local ok = writeLines(PLAN_FILE, { line }, true)
	say((ok and "added to plan: " or "could not write plan: ") .. line)
	pcall(function()
		local p = player()
		if p and HaloTextHelper and HaloTextHelper.addGoodText then HaloTextHelper.addGoodText(p, "Test Ground: " .. line) end
	end)
end

local function sqText(sq) return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() end
local function meText(p) return floor(p:getX()) .. "," .. floor(p:getY()) .. "," .. floor(p:getZ()) end

local function onFillMenu(playerNum, context, worldobjects, test)
	if test or playerNum ~= 0 then return end
	if K.mpBlocked() then return end
	local p = getSpecificPlayer(playerNum)
	if not p then return end
	local sq = nil
	for _, o in ipairs(worldobjects or {}) do
		if o and o.getSquare and o:getSquare() then sq = o:getSquare(); break end
	end
	sq = sq or p:getCurrentSquare()
	local opt = context:addOption("Test Ground", nil, nil)
	local sub = ISContextMenu:getNew(context)
	context:addSubMenu(opt, sub)
	if S.run then
		sub:addOption("Stop run", nil, function() T.stop() end)
		return
	end
	sub:addOption("Run the fixed baseline (West Point)", nil, function() K.withConfirm(function() T.start(T.loadPlan(K.FIXED_BASELINE)) end) end)
	sub:addOption("Run plan", nil, function() K.withConfirm(function() T.start() end) end)
	sub:addOption("Survey here and run", nil, function() K.withConfirm(function()
		T.survey(nil, function(ok) if ok then T.start(T.loadPlan(TG.SURVEY_FILE)) end end)
	end) end)
	sub:addOption("Survey here and run baseline", nil, function() K.withConfirm(function()
		T.survey(nil, function(ok) if ok then T.start(T.loadPlan(TG.BASELINE_FILE)) end end)
	end) end)
	for _, key in ipairs(spotKeys()) do
		sub:addOption("Go to " .. T.spots[key].name .. ", survey and run baseline", nil, function() K.withConfirm(function()
			T.survey(nil, function(ok) if ok then T.start(T.loadPlan(TG.BASELINE_FILE)) end end, key) end)
		end)
	end
	sub:addOption("Set start: here", nil, function() appendPlan("start = " .. sqText(sq)) end)
	sub:addOption("Add route point: here", nil, function() appendPlan("route = " .. sqText(sq)) end)
	sub:addOption("Add road point: here", nil, function() appendPlan("road = " .. sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()) end)
	sub:addOption("Add Walk To case: me to here", nil, function()
		appendPlan("walkto = case | " .. meText(p) .. " | " .. sqText(sq) .. " | any")
	end)
end


-- Commands -----------------------------------------------------------------------------------
-- TestGround.command(line) runs one command and returns its reply lines; results that come later
-- (a survey or run ending) are appended to Zomboid/Lua/TestGround_out.txt. Test Ground itself reads
-- no command file and runs no Lua from files: the separate Test Ground Bridge mod (1.11.0) does
-- that, for tools and agents that drive the game from outside. Commands:
--   run [planfile]   start a run (default TestGround_plan.txt; any file in Zomboid/Lua/)
--   survey [radius] [run] [here|<start>]  go to the fixed test start (westpoint unless "here"),
--                          build TestGround_survey.txt from the area around it, then run it
--   baseline         run the fixed baseline shipped in the mod (media/TestGround/baseline.txt)
--   baseline survey|here|<start> [radius]  survey there, write TestGround_baseline.txt and run it
--   stop             stop the run (the report so far is written)
--   status           running or idle, current step, position, fps, last report
--   (lua <code> is in the separate Test Ground Bridge mod, with the command file itself)
-- When a run ends, "=== done <report> <trace>" is appended, so a script can wait for it.

local OUT = "TestGround_out.txt"

local function bridgeOut(lines)
	writeLines(OUT, lines, true)
end
K.bridgeOut = bridgeOut
T.bridgeOut = bridgeOut   -- the Test Ground Bridge mod writes its replies through this
T.VERSION = VERSION
T.FIXED = true   -- has the fixed baseline in the mod (1.11.0)

local function status()
	local p = player()
	local lines = {}
	if S.run then
		local st = S.run.steps[S.run.si]
		lines[#lines + 1] = string.format("running %s: %s, pass %d step %d of %d%s", S.run.plan.label, S.run.phase, S.run.pass,
			S.run.si, #S.run.steps, st and (" (" .. st.text .. ")") or "")
	else
		lines[#lines + 1] = "idle"
	end
	if p then
		lines[#lines + 1] = string.format("player %.1f,%.1f,%d %s", p:getX(), p:getY(), floor(p:getZ()), stateName(p))
	end
	pcall(function() lines[#lines + 1] = "fps " .. tostring(getAverageFPS()) end)
	if T.last then lines[#lines + 1] = "last report " .. T.last.report .. (T.last.stopped and (" (stopped: " .. T.last.stopped .. ")") or "") end
	return lines
end

-- "here" (or "loaded"): where the save loaded; a T.spots key; nothing: K.DEFAULT_SPOT
local function whereFrom(rest)
	for w in string.gmatch(string.lower(rest or ""), "%a+") do
		if w == "here" or w == "loaded" then return nil end
		if T.spots[w] then return w end
		if w ~= "run" and w ~= "survey" then return nil, "no such start: " .. w .. " (here, or one of: " .. table.concat(spotKeys(), ", ") .. ")" end
	end
	return K.DEFAULT_SPOT
end

-- Better Building Plus (1.12.0) ---------------------------------------------------------------
-- build W H [S]: a W x H wooden room with a floor and a door, built by BBP's own code: the player
-- gets the tools and materials, a plan goes to BBP's BeginConstruction (the same command its
-- placement preview sends after the click), and BBP's autonomous builder walks to each piece and
-- runs its BuildPieceAction. Times each piece (claim to built, and the build action alone), counts
-- failures, and stops after S seconds (default 300). Needs BBP (and its RCStructureFramework).
-- visit S: stand in the middle of the room built by the last build step for S seconds.
-- passby S [speed]: glide back and forth along a 60-tile line past that room (as the drive steps do).
-- Plan keys: buildsite = x,y,z (default: a clear spot near the start); per step Woodwork=N etc.
K.BBP_WALL_N, K.BBP_WALL_W = "walls_exterior_wooden_01_45", "walls_exterior_wooden_01_44"
K.BBP_FRAME_N, K.BBP_DOOR_N = "walls_exterior_wooden_01_55", "carpentry_01_49"
K.BBP_FLOOR = "carpentry_02_58"

TG.FAST_GAP, TG.FAST_RUN_MIN, TG.MAP_ROAD_MIN, TG.MAP_ROAD_RANGE, TG.OUT, TG.SURVEY_RADIUS = FAST_GAP, FAST_RUN_MIN, MAP_ROAD_MIN, MAP_ROAD_RANGE, OUT, SURVEY_RADIUS
TG.SURVEY_ROWS_PER_TICK, TG.TREE_BAND, TG.TREE_RADIUS, TG.TREE_RUN_MIN, TG.appendPlan, TG.bridgeOut = SURVEY_ROWS_PER_TICK, TREE_BAND, TREE_RADIUS, TREE_RUN_MIN, appendPlan, bridgeOut
TG.clearAt, TG.dist2, TG.edgeCase, TG.fastRoad, TG.flag, TG.freeAt = clearAt, dist2, edgeCase, fastRoad, flag, freeAt
TG.hasProp, TG.hasTree, TG.intensityAt, TG.longestStreetRun, TG.meText, TG.nearestFirst = hasProp, hasTree, intensityAt, longestStreetRun, meText, nearestFirst
TG.nearestFree, TG.onFillMenu, TG.onSurveyTick, TG.routeSeconds, TG.sqIs, TG.sqText = nearestFree, onFillMenu, onSurveyTick, routeSeconds, sqIs, sqText
TG.startLine, TG.status, TG.surveyFinish, TG.surveyRow, TG.treeCount, TG.treeRoad = startLine, status, surveyFinish, surveyRow, treeCount, treeRoad
TG.whereFrom = whereFrom
