--
-- LG Extended Plumbing - Chunk Load Patch: the server half.
--
-- The original runs notice() on every square inside LoadGridsquare, which fires while the
-- chunk is being loaded on the main thread.  This changes two things:
--
-- 1. WHEN.  Each chunk is noted on LoadChunk (raised once its squares are all in) and its
--    squares are handed to the original handler a few at a time on OnTick, under a budget.
--
-- 2. WHERE.  Nothing in this mod does anything until a player plumbs a barrel in from the
--    context menu: a supply needs EP.isIncluded (LGEPCore, EP.eligible), and a mirror is only
--    made for a fixture that has a supply.  So only chunks near plumbing are read at all:
--
--      HOT   near a mirror, a plumbed barrel or a pipe: every square goes through notice(),
--            exactly as the original does.
--      COLD  everywhere else: skipped.
--
--    Mirrors come from the mod's own saved list of every mirror address.  Plumbed barrels
--    come from a list this patch saves with the world, kept by wrapping LGEP.setIncluded -
--    the one function the plumb and unplumb menu actions end in.  There is no learning scan:
--    a barrel plumbed before this patch was installed, in a place no mirror or pipe covers,
--    is picked up the next time somebody unplumbs and plumbs it again.
--
-- WHAT IS DELIBERATELY NOT DONE: remembering chunks "once per session".  The original mod
-- forgets mirrors and fixtures whose chunk has unloaded and relies on the next load to file
-- them again, and notice() also repairs barrels the engine gutted on unload.
--
-- Squares are looked up again by coordinates when their turn comes, never kept as objects:
-- a square that has been recycled (ReuseGridsquare) is reused at a different place.
--

-- The original file returns early on a multiplayer client, so there is nothing to do there.
if isClient() then return end

-- Read lazily: this file may load before or after LGEPPlumbing.lua, and the capture
-- happens whenever that one runs.  Either way it is done before the first chunk loads.
local function capturedHandler() return LGEP_CLP and LGEP_CLP.captured end

-- Milliseconds of work allowed per tick.  Lower is smoother, higher catches up faster.
local BUDGET_MS = 2
-- Hard cap per tick as well, in case the clock is coarse.  One chunk level is 64 squares.
local MAX_LEVELS_PER_TICK = 8
-- Set to false to scan every chunk fully (the 1.0 behaviour).
local LAZY = true
-- How often the hot-chunk index is rebuilt from the mod's own records.
local INDEX_EVERY_MS = 5000
-- The global ModData key this patch saves its list of plumbed barrels under.
local STORE = "LGEPChunkLoadPatch"

local CHUNK = 8

local function log(msg) print("[LGEPChunkLoadPatch] " .. msg) end

local function nowMs()
	if getTimestampMs then return getTimestampMs() end
	return 0
end

local function chunkKey(cx, cy) return cx * 65536 + cy end

--------------------------------------------------------------------------------
-- which chunks are hot
--------------------------------------------------------------------------------

local hot = {}            -- chunk key -> true
local indexBuiltAt = nil
local addressMemo = {}    -- address -> list of chunk keys it heats

local lazyBroken = false  -- the index could not be built: read everything in full
local plumbed = nil       -- saved: "x,y,z" -> true for every barrel plumbed in

local function lazyOn()
	return LAZY and not lazyBroken
end

-- Chunks covering a box of tiles, grown by `margin` chunks.
local function boxChunks(list, minX, minY, maxX, maxY, margin)
	for cx = math.floor(minX / CHUNK) - margin, math.floor(maxX / CHUNK) + margin do
		for cy = math.floor(minY / CHUNK) - margin, math.floor(maxY / CHUNK) + margin do
			list[#list + 1] = chunkKey(cx, cy)
		end
	end
end

-- The map building at a point, as a box, or nil.  EP.mapBuildingAt answers from the map's
-- building index when the square is not loaded, so this works for a mirror far away.
local function buildingBox(x, y, z)
	local EP = LGEP
	if not (EP and EP.mapBuildingAt and EP.buildingBounds) then return nil end
	local ok, b = pcall(function()
		local def = EP.mapBuildingAt(x, y, z)
		return def and EP.buildingBounds(def) or nil
	end)
	if ok and b and b.minX then return b end
	return nil
end

local function reachChunks()
	local EP = LGEP
	local reach = 12
	if EP and EP.getOption then
		local ok, r = pcall(EP.getOption, "Reach")
		if ok and type(r) == "number" then reach = r end
	end
	return math.ceil(reach / CHUNK)
end

-- An address heats its own building, and the ground within `margin` chunks of it (a
-- player-built structure has no building, and its scope is decided by Reach).
local function heatAround(memoKey, x, y, z, margin)
	local list = addressMemo[memoKey]
	if not list then
		list = {}
		boxChunks(list, x, y, x, y, margin)
		local b = buildingBox(x, y, z)
		if b then boxChunks(list, b.minX, b.minY, b.maxX, b.maxY, 1) end
		addressMemo[memoKey] = list
	end
	for i = 1, #list do hot[list[i]] = true end
end

local function parseKey(key)
	if type(key) ~= "string" then return nil end
	local x, y, z = string.match(key, "^(-?%d+),(-?%d+),(-?%d+)$")
	if not x then return nil end
	return tonumber(x), tonumber(y), tonumber(z)
end

local function rebuildIndex()
	local EP = LGEP
	hot = {}
	if not EP then return end
	local margin = reachChunks()

	-- Every mirror this save has, loaded or not: the mod keeps the list for its uninstall.
	if ModData and ModData.getOrCreate and EP.PIPE_STORE then
		local store = ModData.getOrCreate(EP.PIPE_STORE)
		if store and type(store.mirrors) == "table" then
			for key in pairs(store.mirrors) do
				local x, y, z = parseKey(key)
				if x then heatAround(key, x, y, z, margin) end
			end
		end
	end

	-- Every barrel (or dispenser) a player has plumbed in since this patch was installed.
	if plumbed then
		for key in pairs(plumbed) do
			local x, y, z = parseKey(key)
			if x then heatAround("p:" .. key, x, y, z, margin) end
		end
	end

	-- Every pipe piece, and the chunks either side of it.
	local function pipes(rows)
		if type(rows) ~= "table" then return end
		for _, row in pairs(rows) do
			if row.x and row.y then
				local list = {}
				boxChunks(list, row.x, row.y, row.x, row.y, 1)
				for i = 1, #list do hot[list[i]] = true end
			end
		end
	end
	pipes(EP.floorPipes)
	pipes(EP.wallPipes)
end

--------------------------------------------------------------------------------
-- the queue
--------------------------------------------------------------------------------

-- Chunk levels still to read: {x, y = first square, z = level, key, last}.
local queue, head, tail = {}, 1, 0
-- Chunks currently waiting, so a chunk that loads twice before we reach it is read once.
local pending = {}
-- Chunks skipped as cold, so they can be read in full if they turn hot while loaded:
-- key -> {x, y, lo, hi}.
local readCold = {}

local function enqueueLevels(key, x0, y0, lo, hi)
	pending[key] = true
	for z = lo, hi do
		tail = tail + 1
		queue[tail] = { x = x0, y = y0, z = z, key = key, last = (z == hi) }
	end
end

local function enqueue(chunk)
	if not chunk or not chunk.getGridSquare then return end
	local lo, hi = 0, 0
	if chunk.getMinLevel and chunk.getMaxLevel then lo, hi = chunk:getMinLevel(), chunk:getMaxLevel() end

	-- The chunk's world position, from any square it holds (Kahlua exposes methods, not
	-- fields, so chunk.wx is not readable).
	local x0, y0
	for z = lo, hi do
		for lx = 0, CHUNK - 1 do
			for ly = 0, CHUNK - 1 do
				local square = chunk:getGridSquare(lx, ly, z)
				if square then
					x0 = math.floor(square:getX() / CHUNK) * CHUNK
					y0 = math.floor(square:getY() / CHUNK) * CHUNK
					break
				end
			end
			if x0 then break end
		end
		if x0 then break end
	end
	if not x0 then return end

	local key = chunkKey(math.floor(x0 / CHUNK), math.floor(y0 / CHUNK))
	if pending[key] then return end

	if lazyOn() and not hot[key] then
		-- Cold: not read now, but remembered while loaded in case it turns hot.
		readCold[key] = { x = x0, y = y0, lo = lo, hi = hi }
		return
	end
	readCold[key] = nil
	enqueueLevels(key, x0, y0, lo, hi)
end

-- After the index grows: a chunk that was skipped as cold and is still loaded is read in
-- full, so the fixtures in a building that has just been plumbed are not missed.
local function promoteCold()
	local cell = getCell()
	if not cell then return end
	local gone = nil
	for key, c in pairs(readCold) do
		if cell:getGridSquare(c.x, c.y, 0) == nil and cell:getGridSquare(c.x, c.y, c.lo) == nil then
			gone = gone or {}
			gone[#gone + 1] = key
		elseif hot[key] and not pending[key] then
			gone = gone or {}
			gone[#gone + 1] = key
			enqueueLevels(key, c.x, c.y, c.lo, c.hi)
		end
	end
	if gone then
		for i = 1, #gone do readCold[gone[i]] = nil end
	end
end

--------------------------------------------------------------------------------
-- reading a square
--------------------------------------------------------------------------------

local function readLevel(handler, cell, item)
	for dx = 0, CHUNK - 1 do
		for dy = 0, CHUNK - 1 do
			local square = cell:getGridSquare(item.x + dx, item.y + dy, item.z)
			-- nil means the chunk has gone again; its next load will queue it afresh.
			if square then
				handler(square)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- events
--------------------------------------------------------------------------------

local announced = false
local function announce(handler)
	if announced then return end
	announced = true
	if handler then
		log("active: LG Extended Plumbing's square scan runs from a tick budget of "
			.. BUDGET_MS .. " ms" .. (LAZY and ", in full only near plumbing." or "."))
	else
		log("did not find LG Extended Plumbing's LoadGridsquare handler; standing down, "
			.. "the original behaviour is unchanged.")
	end
end

local function refreshIndex(force)
	if not LAZY then return end
	local now = nowMs()
	if not force and indexBuiltAt and now - indexBuiltAt < INDEX_EVERY_MS then return end
	indexBuiltAt = now
	local ok, err = pcall(rebuildIndex)
	if not ok then
		log("ERROR building the plumbed-area index, reading everything in full: " .. tostring(err))
		lazyBroken = true
		return
	end
	pcall(promoteCold)
end

--- PLUMBING IN AND OUT, followed where it ends.
---
--- The menu sends a command and the server's handler calls EP.setIncluded through the LGEP
--- table (LGEPPlumbing ~3953), so replacing the table entry is enough.  The original runs
--- first and decides; the result is read back off the world afterwards, because the original
--- can refuse to plumb (EP.canPlumbHere) and only what actually happened goes on the list.
local function recordPlumbing(x, y, z, included)
	if not plumbed then return end
	local EP = LGEP
	local key = x .. "," .. y .. "," .. z
	local now = false
	if included then
		local source = EP.sourceAt and EP.sourceAt(x, y, z)
		if source and EP.isIncluded and EP.isIncluded(source) then
			now = true
		elseif EP.isFedPlumbed then
			local square = getCell():getGridSquare(x, y, z)
			now = square ~= nil and EP.isFedPlumbed(square) == true
		end
	end
	if now then plumbed[key] = true else plumbed[key] = nil end
	-- Rebuilt now rather than on the next lap, so the building turns hot straight away.
	indexBuiltAt = nil
end

local function wrapSetIncluded()
	local EP = LGEP
	if not EP or not EP.setIncluded or EP.setIncludedWrappedByCLP then return end
	local original = EP.setIncluded
	EP.setIncluded = function(x, y, z, included)
		local r1, r2 = original(x, y, z, included)
		local ok, err = pcall(recordPlumbing, x, y, z, included)
		if not ok then log("ERROR recording a plumb action: " .. tostring(err)) end
		return r1, r2
	end
	EP.setIncludedWrappedByCLP = true
end

Events.LoadChunk.Add(function(chunk)
	local handler = capturedHandler()
	announce(handler)
	if not handler then return end
	if not indexBuiltAt then refreshIndex(true) end
	local ok, err = pcall(enqueue, chunk)
	if not ok then log("ERROR queueing a chunk: " .. tostring(err)) end
end)

Events.OnTick.Add(function()
	local handler = capturedHandler()
	if not handler then return end
	refreshIndex(indexBuiltAt == nil)
	if head > tail then return end
	local cell = getCell()
	if not cell then return end

	local started = nowMs()
	local levels = 0
	while head <= tail and levels < MAX_LEVELS_PER_TICK do
		local item = queue[head]
		queue[head] = nil
		head = head + 1
		levels = levels + 1

		local ok, err = pcall(readLevel, handler, cell, item)
		if not ok then log("ERROR reading a chunk level: " .. tostring(err)) end
		if item.last then pending[item.key] = nil end

		if nowMs() - started >= BUDGET_MS then break end
	end

	if head > tail then
		-- Empty: start the indices again so they do not grow for the whole session.
		queue, head, tail = {}, 1, 0
	end
end)

-- A new world is a new map.
--
-- Also where the plumb/unplumb wrapper goes in.  Not at file load: this file may run before
-- LGEPPlumbing.lua (load order is by path, not by dependency), so EP.setIncluded may not
-- exist yet.  By this event every mod's files have run - LGEPPlumbing registers its own
-- handler for it - and no chunk has loaded and no player can have opened a menu.
Events.OnInitGlobalModData.Add(function()
	wrapSetIncluded()
	hot, addressMemo, readCold, indexBuiltAt = {}, {}, {}, nil
	plumbed = nil
	if ModData and ModData.getOrCreate then
		local store = ModData.getOrCreate(STORE)
		if type(store.plumbed) ~= "table" then store.plumbed = {} end
		plumbed = store.plumbed
	end
end)
