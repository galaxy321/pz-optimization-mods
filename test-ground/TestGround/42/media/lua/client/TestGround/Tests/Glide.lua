-- Test Ground 1.13.0: fast floating: the pass-by glide and the corpse drive.
require "TestGround/Core"
local TG = TestGroundInternal
if TG.loaded.Glide then return end
TG.loaded.Glide = true
local S = TG.S
local K, Steps, T, floor, now, teleport = TG.K, TG.Steps, TG.T, TG.floor, TG.now, TG.teleport
Steps.passby = {
	begin = function(r, st)
		local s = r.buildSite
		if not s then st.skip = "nothing built in this run (a build step first)"; return end
		local y = s.y + s.h + 3
		r.plan.treeroad = { { x = s.x - 30, y = y, z = s.z }, { x = s.x + s.w + 30, y = y, z = s.z } }
		st.passby = true
		Steps.treeroad.begin(r, st)
	end,
	tick = function(r, st, t, dt)
		local done = Steps.treeroad.tick(r, st, t, dt)
		if done and st.result then st.result = string.gsub(st.result, "passes of the tree road", "passes by the built room") end
		return done
	end,
}

-- 1.12.7: corpses N [phase] lays N zombie corpses in every 8x8 chunk along the first corpselen tiles
-- (default 1000) of the plan's fastroad, up to corpseband tiles (default 12) either side of it, off
-- the street itself so the car isn't blocked. It glides along in ghost mode, laying them as the
-- chunks load, then leaves; a drivefast right after it drives back through chunks that now load
-- with the corpses in them (the streaming, decay, loot and clean-up mods that hook corpses all
-- get to work). "corpses clear [phase]" glides the stretch again and takes every corpse Test
-- Ground laid (any run's) back off the map. The corpses come from the game's createRandomDeadBody
-- (dressed, bloodied, loot filled as for a real one) and carry modData.TestGroundCorpse.
K.CORPSE_LEN, K.CORPSE_BAND, K.CORPSE_CHUNK = 1000, 12, 8
K.CORPSE_TICK_MS = 6         -- work per tick, laying or clearing
K.CORPSE_AHEAD = 30          -- chunks this far ahead of the glide are worked on
K.CORPSE_GLIDE = 15          -- tiles/s, when nothing near is waiting
K.CORPSE_TAG = "TestGroundCorpse"
function K.corpseChunks(st, len, band)
	local seen, list, c = {}, {}, K.CORPSE_CHUNK
	for s0 = 0, len, c / 2 do
		for off = -band, band, c / 2 do
			local x, y = TG.pointAt(st, s0, off)
			local cx, cy = floor(x / c), floor(y / c)
			local key = cx .. "," .. cy
			if not seen[key] then
				seen[key] = true
				list[#list + 1] = { cx = cx, cy = cy, s = s0, i = 0 }
			end
		end
	end
	return list
end
-- the same squares every run: a small LCG seeded by the chunk
function K.chunkOrder(cx, cy)
	local n, order = K.CORPSE_CHUNK * K.CORPSE_CHUNK, {}
	for i = 1, n do order[i] = i - 1 end
	local seed = (cx * 73856093 + cy * 19349663) % 2147483647
	for i = n, 2, -1 do
		seed = (seed * 1103515245 + 12345) % 2147483648
		local j = seed % i + 1
		order[i], order[j] = order[j], order[i]
	end
	return order
end
function K.corpseSquareOk(sq)
	if not sq or TG.isStreetSq(sq) then return false end
	local ok, free = pcall(function() return sq:isFree(false) and sq:getFloor() ~= nil end)
	return ok and free == true
end
function K.layCorpse(sq, tag)
	local ok, b = K.tryOnce("lay corpse", function() return createRandomDeadBody(sq, 5) end)
	if not ok or not b then return false end
	K.tryOnce("tag corpse", function() b:getModData()[K.CORPSE_TAG] = tag end)
	return true
end
function K.clearCorpses(sq)
	local n = 0
	local ok, list = pcall(function() return sq:getDeadBodys() end)
	if not ok or not list then return 0 end
	for i = list:size() - 1, 0, -1 do
		local b = list:get(i)
		local okT, tagged = pcall(function() return b:hasModData() and b:getModData()[K.CORPSE_TAG] ~= nil end)
		if okT and tagged then
			if K.tryOnce("remove corpse", function() b:removeFromWorld(); b:removeFromSquare() end) then n = n + 1 end
		end
	end
	return n
end
Steps.corpses = {
	begin = function(r, st)
		st.clear = st.args[2] == "clear"
		st.per = st.clear and 0 or math.max(1, math.min(64, floor(st.a or 30)))
		local pts = r.plan.fastroad
		if #pts < 2 then st.skip = "no road in the plan (fastroad = x,y,z, two or more)"; return end
		local path = {}
		for _, q in ipairs(pts) do path[#path + 1] = { x = q.x + 0.5, y = q.y + 0.5 } end
		TG.buildPath(st, path)
		st.z = pts[1].z or 0
		st.len = math.min(st.total, r.plan.corpselen or K.CORPSE_LEN)
		st.band = r.plan.corpseband or K.CORPSE_BAND
		st.chunks = K.corpseChunks(st, st.len, st.band)
		st.next, st.gs, st.laid, st.cleared, st.missed, st.full = 1, 0, 0, 0, 0, 0
		st.workMs, st.ctag = 0, tostring(r.id)
		-- 1.13.2: what's laid is known to the run, so a stop before "corpses clear" takes it back off
		if not st.clear then r.corpseOut = { chunks = st.chunks, z = st.z, laid = 0 } end
		pcall(function() r.p:setGhostMode(true) end)
		local x, y = TG.pointAt(st, 0, 0)
		teleport(r.p, floor(x), floor(y), st.z)
		T.trace(string.format("corpses: %s %d chunks along %.0f tiles of %s, %d tiles either side", st.clear and "clearing" or ("laying " .. st.per .. " a chunk in"),
			#st.chunks, st.len, r.plan.fastname or "the road", st.band))
	end,
	tick = function(r, st, t, dt)
		local c, cell = K.CORPSE_CHUNK, getCell()
		local t0 = now()
		-- work through the chunks near the glide, in order along the road
		local k = st.next
		while k <= #st.chunks and st.chunks[k].s <= st.gs + K.CORPSE_AHEAD and now() - t0 < K.CORPSE_TICK_MS do
			local ch = st.chunks[k]
			local x0, y0 = ch.cx * c, ch.cy * c
			if not cell:getGridSquare(x0, y0, st.z) or not cell:getGridSquare(x0 + c - 1, y0 + c - 1, st.z) then
				-- not loaded yet: wait while it's ahead, give up on it once well behind
				if ch.s < st.gs - K.CORPSE_AHEAD then st.missed = st.missed + 1; ch.i = -1; st.next = k + 1 end
				break
			end
			if st.clear then
				for dx = 0, c - 1 do for dy = 0, c - 1 do
					st.cleared = st.cleared + K.clearCorpses(cell:getGridSquare(x0 + dx, y0 + dy, st.z))
				end end
				ch.i = -1
			else
				ch.order = ch.order or K.chunkOrder(ch.cx, ch.cy)
				ch.n = ch.n or 0
				while ch.n < st.per and ch.i < #ch.order and now() - t0 < K.CORPSE_TICK_MS do
					ch.i = ch.i + 1
					local o = ch.order[ch.i]
					local sq = cell:getGridSquare(x0 + o % c, y0 + floor(o / c), st.z)
					if K.corpseSquareOk(sq) and K.layCorpse(sq, st.ctag) then
						ch.n = ch.n + 1; st.laid = st.laid + 1
						if r.corpseOut then r.corpseOut.laid = r.corpseOut.laid + 1 end
					end
				end
				if ch.n >= st.per or ch.i >= #ch.order then
					if ch.n >= st.per then st.full = st.full + 1 end
					ch.i = -1
				else
					break   -- out of time this tick, same chunk next tick
				end
			end
			if K.broken["lay corpse"] then st.skip = "the game's createRandomDeadBody failed: " .. K.broken["lay corpse"]; return true end
			k = k + 1
			st.next = k
		end
		st.workMs = st.workMs + (now() - t0)
		-- glide on while nothing near is waiting
		local waiting = st.next <= #st.chunks and st.chunks[st.next].s <= st.gs + 8
		if not waiting and st.gs < st.len then
			st.gs = math.min(st.len, st.gs + K.CORPSE_GLIDE * math.min(dt, 100) / 1000)
			local x, y = TG.pointAt(st, st.gs, 0)
			pcall(function() r.p:teleportTo(x, y, st.z) end)
		end
		local over = (st.next > #st.chunks and st.gs >= st.len) or t - st.t0 >= K.CORPSE_MAX_S * 1000
		if not over then return false end
		pcall(function() r.p:setGhostMode(r.wasGhost) end)
		local home = r.plan.start or r.home
		if home then teleport(r.p, home.x, home.y, home.z) end
		local el = (t - st.t0) / 1000
		if st.clear then
			r.corpseOut = nil
			st.result = string.format("corpses cleared along %.0f tiles of %s: %d taken off in %d chunks (%d chunks never loaded) in %.0f s, %.1f s of it removing",
				st.len, r.plan.fastname or "the road", st.cleared, #st.chunks - st.missed, st.missed, el, st.workMs / 1000)
		else
			st.result = string.format("corpses laid along %.0f tiles of %s, %d tiles either side: %d corpses in %d chunks (%d chunks got all %d, %d never loaded) in %.0f s, %.1f s of it laying (%.1f ms a corpse); frames here are the laying, not a drive%s",
				st.len, r.plan.fastname or "the road", st.band, st.laid, #st.chunks - st.missed, st.full, st.per, st.missed, el, st.workMs / 1000,
				st.laid > 0 and st.workMs / st.laid or 0, st.next <= #st.chunks and ", STOPPED at the time limit" or "")
		end
		return true
	end,
}
K.CORPSE_MAX_S = 600

-- 1.12.11, "station x,y,z [tag]" or "station spawn [type=Module.Name] [tag]": a crafting station's
-- using-player, for the Entity Loop Fix check. The game's UsingPlayerUpdateSystem clears an entity's
-- using player once the player is more than 10 tiles away; the patch replaces that per-frame loop. The
-- step opens the station's entity window (or calls setUsingPlayer when there's no window to open),
-- closes it, moves K.STATION_AWAY tiles off and waits K.STATION_WAIT_S seconds (wait=N), reading
-- getUsingPlayer every second. A station it puts down itself (spawn; a drying rack type if the game
-- has one, else the first entity type with a craft bench) is taken off again at the end.
K.STATION_AWAY, K.STATION_WAIT_S = 14, 70
K.STATION_SPRITE = "carpentry_01_16"


