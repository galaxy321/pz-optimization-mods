-- Test Ground 1.13.0: driving: the walk-speed drive, the tree road and the real-car fast drive.
require "TestGround/Core"
local TG = TestGroundInternal
if TG.loaded.Drive then return end
TG.loaded.Drive = true
local S = TG.S
local K, Steps, T, areaLoaded, floor, newFrames = TG.K, TG.Steps, TG.T, TG.areaLoaded, TG.floor, TG.newFrames
local now, out, say, teleport = TG.now, TG.out, TG.say, TG.teleport
Steps.drive = {
	begin = function(r, st)
		st.seconds = st.a or 60
		st.speed = st.b or 20        -- tiles per second; 20 is about 72 km/h
		local sign = (st.args and tonumber(st.args[4]) == -1) and -1 or 1
		local d = r.plan.drive or { x = 1, y = 0 }
		local len = math.sqrt(d.x * d.x + d.y * d.y)
		if len == 0 then d, len = { x = 1, y = 0 }, 1 end
		st.dx, st.dy = d.x / len * sign, d.y / len * sign
		st.x, st.y = r.p:getX(), r.p:getY()
		local home = r.plan.start or r.home
		st.hx, st.hy, st.z = home.x + 0.5, home.y + 0.5, home.z or 0
		st.out, st.tiles, st.far = true, 0, 0
		r.p:setGhostMode(true)
	end,
	tick = function(r, st, t, dt)
		local move = st.speed * math.min(dt, 100) / 1000
		st.tiles = st.tiles + move
		local fx, fy = st.dx, st.dy
		local arrived = false
		if st.out then
			st.x, st.y = st.x + st.dx * move, st.y + st.dy * move
			if t - st.t0 >= st.seconds * 500 then
				st.out = false
				st.far = st.tiles
				T.trace(string.format("drive turned back at %.0f,%.0f after %.0f tiles", st.x, st.y, st.tiles))
			end
		else
			local dx, dy = st.hx - st.x, st.hy - st.y
			local d = math.sqrt(dx * dx + dy * dy)
			if d <= move then
				st.x, st.y = st.hx, st.hy
				arrived = true
			else
				fx, fy = dx / d, dy / d
				st.x, st.y = st.x + fx * move, st.y + fy * move
			end
		end
		pcall(function()
			r.p:getForwardDirection():set(fx, fy)
			r.p:teleportTo(st.x, st.y, st.z)
		end)
		if arrived or t - st.t0 >= st.seconds * 3000 then
			pcall(function() r.p:setGhostMode(r.wasGhost) end)
			st.result = string.format("%.0f tiles at %.0f tiles/s, %.0f out%s", st.tiles, st.speed, st.far,
				arrived and ", back at the start" or ", time limit before getting back")
			return true
		end
		return false
	end,
}

-- treeroad S [speed]: the tree-lined road the survey found (treeroad = x,y,z twice). Glides from
-- where you are to one end at driving speed, then back and forth along it until S seconds have
-- passed, in ghost mode. Same speed as the drive steps, so its frames compare with theirs.
Steps.treeroad = {
	begin = function(r, st)
		st.seconds = st.a or 40
		st.speed = st.b or 20
		local pts = r.plan.treeroad
		if #pts < 2 then st.skip = "no tree-lined road in the plan (treeroad = x,y,z twice)"; return end
		st.ends = { { x = pts[1].x + 0.5, y = pts[1].y + 0.5 }, { x = pts[2].x + 0.5, y = pts[2].y + 0.5 } }
		st.z = pts[1].z or 0
		st.x, st.y = r.p:getX(), r.p:getY()
		st.target, st.tiles, st.passes = 1, 0, 0
		r.p:setGhostMode(true)
		-- 1.10.0: a road from the map can be kilometres away; gliding there ate the whole step
		-- (0 passes). Far away: teleport to its first end, wait for it to load, and start the
		-- clock and the frame stats from there.
		local e = st.ends[1]
		if math.sqrt((e.x - st.x) ^ 2 + (e.y - st.y) ^ 2) > 60 then
			teleport(r.p, floor(e.x), floor(e.y), st.z)
			st.x, st.y, st.loadingSince = e.x, e.y, now()
			st.waiting = "the tree road to load"
			st.target, st.passes = 2, 1   -- already at the first end: no approach leg to discount
		end
	end,
	tick = function(r, st, t, dt)
		if st.loadingSince then
			if areaLoaded(floor(st.x), floor(st.y), st.z, 30) or t - st.loadingSince >= K.TREE_LOAD_MS then
				st.loadNote = string.format("teleported to the tree road, %s after %.1f s", areaLoaded(floor(st.x), floor(st.y), st.z, 30) and "loaded" or "NOT fully loaded", (t - st.loadingSince) / 1000)
				T.trace("treeroad: " .. st.loadNote)
				st.loadingSince, st.waiting = nil, nil
				-- 1.13.10 (review of 18 Oct): the Lua profiler window restarts too, not only the time and frames
				K.restartMeasure(st, t)
			end
			return false
		end
		local move = st.speed * math.min(dt, 100) / 1000
		st.tiles = st.tiles + move
		local fx, fy = 1, 0
		while move > 0 do
			local e = st.ends[st.target]
			local dx, dy = e.x - st.x, e.y - st.y
			local d = math.sqrt(dx * dx + dy * dy)
			if d > 0 then fx, fy = dx / d, dy / d end
			if d <= move then
				st.x, st.y = e.x, e.y
				move = move - d
				st.target = 3 - st.target
				st.passes = st.passes + 1
				if d == 0 and move > 0 then move = math.max(0, move - 0.001) end
			else
				st.x, st.y = st.x + fx * move, st.y + fy * move
				move = 0
			end
		end
		pcall(function()
			r.p:getForwardDirection():set(fx, fy)
			r.p:teleportTo(st.x, st.y, st.z)
		end)
		if t - st.t0 >= st.seconds * 1000 then
			pcall(function() r.p:setGhostMode(r.wasGhost) end)
			st.result = string.format("%.0f tiles at %.0f tiles/s, %d passes of the tree road%s", st.tiles, st.speed, math.max(0, st.passes - 1),
				st.loadNote and (" (" .. st.loadNote .. "; frames counted from there)") or "")
			return true
		end
		return false
	end,
}

-- drivefast S [kmh]: a real car along the road in the plan (fastroad = x,y,z, two or more points:
-- a straight road the survey saw, or a whole street from the game's map with its corners).
-- Spawns a fast vanilla car at the start with a full tank, puts you in the driver's seat, starts
-- the engine and lets the car's own cruise control hold the accelerator (vanilla CarController
-- gives gas while the regulator is on and the car is below the regulator speed), set to the car's
-- top speed. Lua has no steering input, so the car is kept on the street by turning it a whole
-- degree at a time (vehicle:setAngles) towards the street's centre a little way ahead; a short
-- creep at the start finds how the car's forward vector maps to the map. It brakes
-- (vehicle:setForceBrake) before real corners and turns there at a standstill. At the end of the
-- road, if time is left, a fresh car is put down facing back (turning a car round in place can
-- wedge it against trees or fences). Other vehicles on the road ahead are taken off the map.
-- If the car gets stuck, a fresh car goes down 15 tiles further on (up to K.FAST_RESPAWNS times).
-- Only when all that fails (no car, engine won't run, stuck again and again) does it say why and
-- glide you along the same road at the car's top speed, so the phase still loads chunks at speed.
local FAST_CARS = { "Base.SportsCar", "Base.CarLuxury", "Base.ModernCar", "Base.ModernCar02", "Base.CarNormal" }
local FAST_INSET = 4            -- tiles kept clear of each end of the road
local FAST_DECEL = 6            -- tiles/s per second assumed when deciding where to brake (cautious)
local FAST_MIN_KMH = 60         -- leg 1 must reach this (dashboard) within FAST_MIN_MS, or it's a glide
local FAST_MIN_MS = 20000      -- 1.12.8: was 10 s; drive_corpses missed it at 55 km/h (69 fps, 220 mods)
local FAST_STUCK_MS = 2500      -- under 0.8 tiles/s this long with the cruise control on = blocked
local FAST_MARGIN = 6           -- extra tiles of braking room
local FAST_LATERAL_MAX = 5      -- (up to 1.12.9) tiles off the centre before the leg was cut short
local FAST_ALIGN_TOL = 2        -- degrees
local FAST_GLIDE_DEFAULT = 33   -- tiles/s (about 120 km/h) when the fallback glide has no car to copy
local FAST_LOAD_MS = 30000      -- a far road end gets this long to load after the teleport
local FAST_STEER_MS = 300       -- how often the moving car is turned back towards the road ahead
local FAST_CLEAR_AHEAD = 90     -- tiles ahead of the car kept free of other vehicles (wrecks, parked cars)
local FAST_TOP_SHARE = 0.95     -- a leg that reaches this share of the car's top speed counts as top speed
K.FAST_CORNER_DEG = 40      -- a bend sharper than this is a corner: brake, turn at a standstill
K.FAST_BEND_DEG = 8         -- 1.9.0: a bend from this up to FAST_CORNER_DEG is taken on the move, slowed down
K.FAST_PURSUIT_S = 1.2      -- pure pursuit: aim at the street's centre this many seconds ahead
K.FAST_PURSUIT_MIN, K.FAST_PURSUIT_MAX = 15, 45   -- tiles, the aim point's distance limits
-- 1.13.10 (the user on tonight's runs: the steering overcorrects, getting going again from a low
-- speed is hard, look further; the goal is a good average speed with few fresh cars). Run 2b's start
-- (drive view run 2b, 18-28 s): steering back from 2.4 tiles at 40 km/h with the aim 10 tiles on
-- swung the heading to -13 and -16 deg off the road (the built-up share -134 of a -141 push), and
-- each steer-back braked in 1 s bursts down to 14 km/h. Now the aim is further on (1.2 s, 15 to 45
-- tiles; was 0.9 s, 10 to 40), a steer-back keeps K.RECOVER_LOOK of it (was the 10-tile minimum),
-- the built-up share bleeds off K.TQ_I_OPPOSE times faster while it pushes against the error, and a
-- steer-back only slows the car (to K.RECOVER_SHARE of the cruise) until it is past halfway to the
-- hard limit or off the street, where the old K.FAST_RECOVER_KMH and brake stay; it brakes only past
-- K.RECOVER_BRAKE_OVER of its speed. Corners driven through keep the old 10-tile aim.
K.FAST_ROLL_LOOK = 10
K.RECOVER_LOOK = 0.7
K.TQ_I_OPPOSE = 5
K.RECOVER_SHARE = 0.75
K.RECOVER_BRAKE_OVER = 1.35
K.RECOVER_CENTRE_MS = 1500
K.AHEAD_S, K.AHEAD_MAX = 0.3, 10
-- plan "drivetune = 1.13.9" drives with the 1.13.9 numbers, to compare the two in one build
K.TUNES = { ["1.13.9"] = { FAST_PURSUIT_S = 0.9, FAST_PURSUIT_MIN = 10, FAST_PURSUIT_MAX = 40, RECOVER_LOOK = 0,
	TQ_I_OPPOSE = 1, RECOVER_SHARE = 0, RECOVER_BRAKE_OVER = 1.2, RECOVER_CENTRE_MS = math.huge, AHEAD_S = 0, TQ_SPIN_OLD = true, REANCHOR = false,
	FAST_ROLL_KMH = 45, SOLID_SKIP = false, SPAWN_LOAD_WAITS = 0, LOOK_OLD = true,
	BEND_OFF = false, CORNER_NO_RAISE = false, ALIGN_CLEAR = false, SOLID_DODGE = false,
	REANCHOR_RAMP_MS = 0, RECOVER_GAIN_MIN = 0.125, ALIGN_STREET = false } }   -- 1.13.12: every later change has its old value here
K.SOLID_SKIP = true
K.LOOK_OLD = false
-- 1.13.14 (1.13.11 mod:drive: 4 + 4 fresh cars): see K.offAt, K.blocker, the align phase and the torque raise
K.BEND_OFF, K.CORNER_NO_RAISE, K.ALIGN_CLEAR, K.SOLID_DODGE = true, true, true, true
K.BEND_OFF_AT, K.BEND_OFF_MAX = 15, 8
K.SOLID_DODGE_FROM, K.SOLID_DODGE_TO, K.SOLID_DODGE_S, K.DODGE_KMH = 6, 40, 2.5, 50
K.DODGE_IDLE_MS = 900
-- 1.13.17 (1.13.14 mod:drive): see the re-anchor, the spin halving and the align phase
K.REANCHOR_RAMP_MS, K.RECOVER_GAIN_MIN, K.ALIGN_STREET = 1500, 0.25, true
K.REANCHOR = true
K.SPAWN_LOAD_WAITS = 3
K.REANCHOR_BEND, K.REANCHOR_AFTER, K.REANCHOR_W, K.REANCHOR_MAX = 25, 12, 0.6, 10
function K.tune(st, name)
	local t = st.tune
	if t and t[name] ~= nil then return t[name] end
	return K[name]
end
K.FAST_TURN_MAX = 0.6       -- radians per second the car may be turned at most
K.FAST_RESPAWNS = 4         -- fresh cars in a row (no 50 tiles of progress between) before falling back to a glide
K.FAST_RESPAWN_SKIP = 15    -- tiles further on for the fresh car
K.FAST_UTURN_MIN_S = 25     -- seconds that must be left to go back the other way at the end
K.FAST_CORNER_KMH = 20      -- a car that stopped short of a corner rolls up to it at this speed
K.FAST_CORNER_NEAR = 6      -- tiles from the corner that count as "at the corner"
-- 1.12.10: the 1.12.8 baseline left the street at bends and on the diagonal of Dixie Highway (all 7
-- "stuck" lines: trees, bushes and light poles off the street) with the old 5-tile drift limit. Now a
-- car drifting past the soft limit (or onto squares that aren't street) slows to
-- K.FAST_RECOVER_KMH and aims K.FAST_PURSUIT_MIN tiles ahead until it's back within a tile; the leg
-- is cut short at the hard limit, about half the street's width. Bends get the aim point
-- shortened to K.FAST_BEND_LOOK of the usual distance, and slower speeds (see nextBend).
K.FAST_SOFT_MIN, K.FAST_HARD_MIN = 1.5, 2.5
K.FAST_RECOVER_KMH = 40
K.FAST_BEND_LOOK = 0.6
-- 1.13.2, from the user's own Dixie Highway drive (manual-drive-1016/DRIVING-PROPOSALS.md):
-- wreck jams: 2 or more vehicles found in the next K.JAM_AHEAD tiles (or 1 within K.JAM_NEAR) cap
-- the cruise at K.JAM_KMH, braked to like a bend, until K.JAM_PAST tiles past the last one; the user
-- crawled both jams at 18 to 29 km/h, the 1.12.10 car went in at cruise and lost 2 cars there.
K.JAM_KMH, K.JAM_AHEAD, K.JAM_NEAR, K.JAM_PAST = 25, 60, 30, 20
-- corners from K.FAST_CORNER_DEG up to K.FAST_ROLL_DEG are driven through at K.FAST_ROLL_KMH
-- (K.FAST_ROLL_SHARP_KMH from 55 deg), unless the street there is much wider (a junction);
-- sharper ones still stop and turn. Plan "corners = stop" keeps the old stop at 40 deg.
K.FAST_ROLL_DEG, K.FAST_ROLL_KMH, K.FAST_ROLL_SHARP_KMH = 70, 38, 30   -- 1.13.11: 38 (was 45; 1.13.10 spun off at the 46 deg one at 10681,8764 in both drives)
K.FAST_ROLL_TURN = 1.0      -- radians per second the car may turn near a corner it rolls through
-- off the street or stuck: up to K.INPLACE_TRIES tries on the same car (stop, line up towards the
-- centre K.INPLACE_AIM tiles on, go on slowly) within K.INPLACE_SPAN tiles before a fresh car
K.INPLACE_TRIES, K.INPLACE_SPAN, K.INPLACE_AIM = 2, 30, 8
K.LINEUP_TOL = 3            -- degrees: a leg starts only this well lined up (two more tries)
K.LINEUP_AIM = 6            -- tiles on: where a leg's start points the car
K.LEG_GRACE = 40            -- tiles at a leg's start before the cut is the plain hard limit
K.SLOW_TURN_TPS = 12        -- below this speed the wanted turn rate is scaled down
-- 1.13.4 (the user: "the to-middle condition is too loose, use a percentage"): the limits are shares
-- of the street's half-width, not tiles. Steering back starts past K.LAT_SOFT of it, the car counts as
-- back on the centre under K.LAT_BACK, and the leg is cut past K.LAT_HARD. On the 7-wide street of
-- the all-on run (allon-1017-1854) that is 1.2 / 0.5 / 2.8 tiles, where 1.13.2 had 1.5 / 1.0 / 3.0.
K.LAT_SOFT, K.LAT_BACK, K.LAT_HARD = 0.35, 0.15, 0.8
K.LAT_SOFT_MIN, K.LAT_BACK_MIN, K.LAT_HARD_MIN = 0.75, 0.4, 1.5
-- 1.13.5: from the width of the street run the car holds (one carriageway of a divided road), not
-- the plan's whole-road width: drive view run 1 had 80% of the 14-wide Dixie Highway's half-width
-- (5.6 tiles) as the cut, off the 7-wide carriageway on one side and over the median on the other.
function K.laneWidth(st) return st.laneW or st.width end
function K.latLimits(width)
	local hw = (width or 8) / 2
	return math.max(K.LAT_SOFT_MIN, K.LAT_SOFT * hw), math.max(K.LAT_HARD_MIN, K.LAT_HARD * hw), math.max(K.LAT_BACK_MIN, K.LAT_BACK * hw)
end
-- 1.13.4: the torque steering aims along the road plus at most K.APPROACH_DEG towards the centre.
-- In allon-1017-1854 the aim point 10 tiles ahead of a car 2.8 tiles off asked for 34 deg/s at
-- 39 km/h; the car crossed the centre at 7 deg and spun at 50 km/h (gain halved, then a 45 deg slide
-- off the street and the glide fallback).
K.APPROACH_DEG = 10

local function atan2(y, x)
	if math.atan2 then return math.atan2(y, x) end
	if x > 0 then return math.atan(y / x) end
	if x < 0 then return math.atan(y / x) + (y >= 0 and math.pi or -math.pi) end
	return y > 0 and math.pi / 2 or (y < 0 and -math.pi / 2 or 0)
end

local function wrapAngle(a)
	while a > math.pi do a = a - 2 * math.pi end
	while a < -math.pi do a = a + 2 * math.pi end
	return a
end

-- The road as a path: points st.pts, arc length st.cum, corners st.stops (arc lengths, the end last).
-- Positions on it are (s, perp): s along the path, perp tiles to the side (positive = direction turned 90 deg).
local function buildPath(st, pts)
	st.pts, st.cum = pts, { 0 }
	for i = 2, #pts do
		local dx, dy = pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y
		st.cum[i] = st.cum[i - 1] + math.sqrt(dx * dx + dy * dy)
	end
	st.total = st.cum[#pts]
	st.stops, st.bends = {}, {}
	for i = 2, #pts - 1 do
		local a1 = atan2(pts[i].y - pts[i - 1].y, pts[i].x - pts[i - 1].x)
		local a2 = atan2(pts[i + 1].y - pts[i].y, pts[i + 1].x - pts[i].x)
		local deg = math.abs(wrapAngle(a2 - a1)) * 180 / math.pi
		local roll = st.rollDeg or K.FAST_ROLL_DEG
		if deg >= K.FAST_CORNER_DEG and deg < roll then
			st.bends[#st.bends + 1] = { s = st.cum[i], deg = deg, roll = true }
		elseif deg >= K.FAST_CORNER_DEG then st.stops[#st.stops + 1] = st.cum[i]
		elseif deg >= K.FAST_BEND_DEG then st.bends[#st.bends + 1] = { s = st.cum[i], deg = deg } end
	end
	st.stops[#st.stops + 1] = st.total
	st.seg = 1
end

local function reversePath(st)
	local rev = {}
	for i = #st.pts, 1, -1 do rev[#rev + 1] = st.pts[i] end
	buildPath(st, rev)
	st.jamS, st.jamUntil, st.jamFrom, st.inJam = nil, nil, nil, nil
end

local function segAt(st, s)
	local n = #st.pts
	for i = 1, n - 2 do
		if s < st.cum[i + 1] then return i end
	end
	return n - 1
end

local function segDir(st, i)
	local a, b = st.pts[i], st.pts[i + 1]
	local dx, dy = b.x - a.x, b.y - a.y
	local d = math.sqrt(dx * dx + dy * dy)
	if d == 0 then return 1, 0 end
	return dx / d, dy / d
end

local function pointAt(st, s, perp)
	local i = segAt(st, s)
	local ux, uy = segDir(st, i)
	local t = s - st.cum[i]
	local p = st.pts[i]
	return p.x + ux * t - uy * (perp or 0), p.y + uy * t + ux * (perp or 0)
end

-- Where (x, y) is on the path: s, perp and the segment, looked for near the last known segment.
local function project(st, x, y)
	local best, bs, bp, bi = nil, 0, 0, st.seg or 1
	local n = #st.pts
	for i = math.max(1, (st.seg or 1) - 1), math.min(n - 1, (st.seg or 1) + 2) do
		local ux, uy = segDir(st, i)
		local p = st.pts[i]
		local len = st.cum[i + 1] - st.cum[i]
		local t = (x - p.x) * ux + (y - p.y) * uy
		local perp = -(x - p.x) * uy + (y - p.y) * ux
		local over = math.max(0, -t, t - len)
		local cost = math.abs(perp) + over * 2
		if not best or cost < best then
			best, bs, bp, bi = cost, st.cum[i] + math.max(-2, math.min(len + 2, t)), perp, i
		end
	end
	return bs, bp, bi
end

-- The next corner (or the end) after s that the car hasn't already stopped for.
local function nextStop(st, s)
	for _, c in ipairs(st.stops) do
		if c > s + 0.5 and (not st.passedStop or c > st.passedStop + 0.5) then return c end
	end
	return st.total
end

-- The next bend taken on the move (at or after s, before the next stop), and its speed in tiles/s:
-- 70 km/h for a gentle one, down to 40 km/h near FAST_CORNER_DEG (1.12.10; was 80 to 45).
local function nextBend(st, s, stopS)
	for _, b in ipairs(st.bends or {}) do
		if b.s > s - 6 and b.s < stopS and not b.stop then
			local kmh = b.deg < 18 and 70 or (b.deg < 28 and 50 or 40)
			if b.roll then kmh = b.deg < 55 and K.tune(st, "FAST_ROLL_KMH") or K.FAST_ROLL_SHARP_KMH end
			return b, kmh / 3.6
		end
	end
	return nil
end

local function isStreetSq(sq)
	if not sq then return false end
	local ok, yes = pcall(function()
		local fl = sq:getFloor()
		local sp = fl and fl:getSprite()
		local name = sp and sp:getName()
		return name ~= nil and string.find(name, "^blends_street") ~= nil
	end)
	return ok and yes
end

-- Where the street really is across the path at s: the street tiles in one run around st.off,
-- as (centre perp, width), or nil when that row isn't loaded or has no street.
local function streetCentre(st, s)
	local cell = getCell()
	local base = floor(st.off + 0.5)
	local function street(k)
		local x, y = pointAt(st, s, k)
		local sq = cell:getGridSquare(floor(x), floor(y), st.z)
		if not sq then return nil end
		return isStreetSq(sq)
	end
	if street(base) == nil then return nil end
	local seed = nil
	for d = 0, 6 do
		if street(base + d) then seed = base + d; break end
		if street(base - d) then seed = base - d; break end
	end
	if not seed then return nil end
	local lo, hi = seed, seed
	while hi - seed < 16 and street(hi + 1) do hi = hi + 1 end
	while seed - lo < 16 and street(lo - 1) do lo = lo - 1 end
	-- 1.12.10: the middle of the two edge tiles' centres (the same as (lo + hi) / 2 on a straight
	-- street, as the path runs through tile centres; closer on a diagonal one)
	local bx, by = pointAt(st, s, 0)
	local ux, uy = segDir(st, segAt(st, s))
	local function perpOf(k)
		local x, y = pointAt(st, s, k)
		return -(floor(x) + 0.5 - bx) * uy + (floor(y) + 0.5 - by) * ux
	end
	return (perpOf(lo) + perpOf(hi)) / 2, hi - lo + 1
end

-- 1.13.5: every street run across the path at s within R tiles of the line, as {lo, hi, c, w} in perp
-- (left to right). Drive view run 1 showed the Dixie Highway as two 7-wide runs with an unpaved
-- median row between its yellow lines; streetCentre found only the run nearest the line.
function K.streetRuns(st, s, R)
	local cell = getCell()
	local bx, by = pointAt(st, s, 0)
	local ux, uy = segDir(st, segAt(st, s))
	local runs, cur = {}, nil
	for k = -R, R do
		local x, y = pointAt(st, s, k)
		local sq = cell:getGridSquare(floor(x), floor(y), st.z)
		if sq and isStreetSq(sq) then
			local p = -(floor(x) + 0.5 - bx) * uy + (floor(y) + 0.5 - by) * ux
			if cur then cur.hi, cur.w = p, cur.w + 1 else cur = { lo = p, hi = p, w = 1 }; runs[#runs + 1] = cur end
		else
			cur = nil
		end
	end
	for _, r in ipairs(runs) do r.c = (r.lo + r.hi) / 2 end
	return runs
end

-- A divided road (two runs of 3+ tiles with at most K.MEDIAN_MAX tiles between them): the right-hand
-- carriageway's centre and width, and the median's width; nil on an undivided street.
K.MEDIAN_MAX = 4
function K.pickCarriageway(st, s)
	local R = floor((st.width or 8) / 2) + 4
	local runs = {}
	for _, r in ipairs(K.streetRuns(st, s, R)) do if r.w >= 3 then runs[#runs + 1] = r end end
	if #runs < 2 then return nil end
	local a, b = runs[#runs - 1], runs[#runs]
	local gap = b.lo - a.hi - 1
	if gap > K.MEDIAN_MAX then return nil end
	return b.c, b.w, math.max(0, floor(gap + 0.5))
end

-- Other vehicles on the road ahead (wrecks, parked cars) are taken off the map before the car gets
-- there: a few rows a tick, up to FAST_CLEAR_AHEAD tiles ahead, as far as the world has loaded.
local function clearAhead(st, s)
	if not st.clearTo or st.clearTo < s - 10 then st.clearTo = s - 8 end
	local target = math.min(st.total, s + FAST_CLEAR_AHEAD)
	local half = floor((st.width or 8) / 2) + 2
	local cell = getCell()
	local rows = 0
	while rows < 6 and st.clearTo < target do
		local a = st.clearTo + 1
		local cx, cy = pointAt(st, a, st.off)
		if not cell:getGridSquare(floor(cx), floor(cy), st.z) then break end
		for k = -half, half do
			local x, y = pointAt(st, a, st.off + k)
			-- squares ahead of a fast car are often not loaded yet; a caught error still prints a
			-- stack trace in game, so check before calling
			local sq = cell:getGridSquare(floor(x), floor(y), st.z)
			local ok, v = false, nil
			if sq then ok, v = pcall(function() return sq:getVehicleContainer() end) end
			if ok and v and v ~= st.car and not st.removed[v] and K.keepCar(st, v, x, y) then
				st.removed[v] = true
				K.jamNote(st, a)
			elseif ok and v and v ~= st.car and not st.removed[v] then
				st.removed[v] = true
				K.jamNote(st, a)
				local name = "a vehicle"
				pcall(function() name = v:getScript():getName() end)
				if not pcall(function() v:permanentlyRemove() end) then pcall(function() v:removeFromWorld() end) end
				st.wrecks = st.wrecks + 1
				T.trace(string.format("drivefast: took %s off the road at %d,%d", tostring(name), floor(x), floor(y)))
			end
		end
		st.clearTo = a
		rows = rows + 1
	end
end

-- 1.13.2 (review): a car a player has been in, hotwired or left the keys in is likely the user's
-- own: it stays (noted for the jam cap; the car slows for it, and may knock it). Wrecks and the
-- map's parked cars have none of that.
function K.keepCar(st, v, x, y)
	local ok, mine = pcall(function()
		return v:isPreviouslyEntered() or v:isHotwired() or v:isKeysInIgnition()
	end)
	if not (ok and mine) then return false end
	st.kept = st.kept or {}
	if not st.kept[v] then
		st.kept[v] = true
		st.keptCars = (st.keptCars or 0) + 1
		local name = "a vehicle"
		pcall(function() name = v:getScript():getName() end)
		T.trace(string.format("drivefast: left %s at %d,%d on the road (a player has been in it, hotwired it or left its keys)", tostring(name), floor(x), floor(y)))
	end
	return true
end

-- 1.13.2: the vehicles found on the road ahead (cleared or not), by arc length, for the jam cap
function K.jamNote(st, a)
	st.jamS = st.jamS or {}
	local n = #st.jamS
	for i = n, math.max(1, n - 15), -1 do
		if math.abs(st.jamS[i] - a) < 0.5 then return end
	end
	st.jamS[n + 1] = a
	if n + 1 > 64 then table.remove(st.jamS, 1) end
end
-- Is the car at s in (or coming up to) a jam? Returns the arc length the cap starts at (the first
-- vehicle ahead, or s when already in it), or nil.
function K.jamAhead(st, s)
	local n, first, last = 0, nil, nil
	for _, a in ipairs(st.jamS or {}) do
		if a > s and a <= s + K.JAM_AHEAD then
			n = n + 1
			if not first or a < first then first = a end
			if not last or a > last then last = a end
		end
	end
	if first and (n >= 2 or first - s <= K.JAM_NEAR) then
		local untilS = last + K.JAM_PAST
		if not st.jamUntil or untilS > st.jamUntil then st.jamUntil = untilS end
		if not st.inJam then st.jamFrom = first end
	end
	if st.jamUntil and s < st.jamUntil then
		if st.jamFrom and s < st.jamFrom then return st.jamFrom end
		return s
	end
	st.jamUntil, st.jamFrom = nil, nil
	return nil
end
-- 1.13.2: the same car is tried again (lined up towards the centre a little way on) before a fresh
-- car; true when this one gets another try.
function K.inPlaceTry(st, s, why, perp)
	if not st.ipS or s > st.ipS + K.INPLACE_SPAN then st.ipS, st.ipN = s, 0 end
	if st.ipN >= K.INPLACE_TRIES then return false end
	-- well past the edge (a slide while braking): a fresh car is quicker
	local off = perp and math.abs(perp - st.off)
	local _, hard = K.latLimits(K.laneWidth(st))
	if off and off > hard + 1 then return false end
	st.ipLat = off
	st.ipN = st.ipN + 1
	st.inPlaceTries = (st.inPlaceTries or 0) + 1
	st.ipPending = s
	st.alignTo = K.INPLACE_AIM
	local x, y = 0, 0
	pcall(function() x, y = st.car:getX(), st.car:getY() end)
	T.trace(string.format("drivefast: %s at %.0f,%.0f (%.0f tiles along, %.1f off the centre); trying the same car again (%d of %d here)", why, x, y, s, perp and math.abs(perp - st.off) or -1, st.ipN, K.INPLACE_TRIES))
	return true
end

-- 1.13.2: one line per drive step for the step tables, so frame and hitch numbers can be read
-- against how the drive went (a car that keeps crashing streams chunks twice: 1.13.1's E1 run)
-- 1.13.10 (the user: a good average speed with as few fresh cars as possible). 1.13.11 (review of
-- 1.13.10: the leg loop alone left out stops off the street, same-car tries and fresh-car setup, so a
-- tuning that crashes more wasn't penalised): the average is the car's tiles over the whole time from
-- the first car to the end of the drive (or the fallback), everything in between included; the speed
-- in the leg loop and while moving over 3 tiles/s are kept beside it to show where the time went
function K.driveLine(st)
	local tiles = st.carTiles or st.tiles or 0
	local whole = st.firstCarT and ((st.carEndT or now()) - st.firstCarT) / 1000 or 0
	return string.format("drive: left the street %d times, %d steered back from the edge, %d legs cut short, %d fresh cars, %d tries on the same car, %d knocks, %d wreck jams, %.0f tiles in the car, %s; average %.0f km/h from the first car to the end (%.0f s, fresh cars, tries and stops included), %.0f km/h in the legs (%.0f s), %.0f km/h while moving; tuning %s",
		st.offStreetN or 0, st.steerBacks or 0, st.cut or 0, st.respawns or 0, st.inPlaceTries or 0, st.tqKnocks or 0, st.jams or 0,
		tiles, st.fallback and ("FALLBACK glide of " .. string.format("%.0f", st.tiles or 0) .. " tiles") or "no fallback",
		whole > 0 and tiles / whole * 3.6 or 0, whole,
		(st.carSec or 0) > 0 and tiles / st.carSec * 3.6 or 0, st.carSec or 0,
		(st.moveSec or 0) > 0 and st.moveTiles / st.moveSec * 3.6 or 0,
		st.tune and ("1.13.9 (plan drivetune)") or "1.13.19")
end

function K.driveCounts(st)
	return (st.steerBacks and string.format(", %d times steered back from the edge", st.steerBacks) or "") ..
		((st.reanchors or 0) > 0 and string.format(", centre found again %d times (off the street on it)", st.reanchors) or "") ..
		((st.bendOffs or 0) > 0 and string.format(", centre taken from past the bend at %d bends", st.bendOffs) or "") ..
		((st.dodges or 0) > 0 and string.format(", %d times round something solid", st.dodges) or "") ..
		((st.solidSkips or 0) > 0 and string.format(", %d fresh cars past something solid in front", st.solidSkips) or "") ..
		(st.lateWrecks and string.format(", %d late-loaded vehicles cleared, %d removed again", st.lateWrecks, st.stillThere or 0) or "") ..
		((st.tqKnocks or st.tqSpins) and string.format(", %d knocks, %d spins", st.tqKnocks or 0, st.tqSpins or 0) or "") ..
		K.jamCounts(st)
end
function K.jamCounts(st)
	return ((st.keptCars or 0) > 0 and string.format(", %d cars left on the road as a player's own", st.keptCars) or "") ..
		((st.jams or 0) > 0 and string.format(", %d wreck jams crawled at %d km/h (%.0f s, %.0f tiles)", st.jams, K.JAM_KMH, st.jamT or 0, st.jamTiles or 0) or "") ..
		((st.inPlaceTries or 0) > 0 and string.format(", %d tries on the same car (%d recovered in place)", st.inPlaceTries, st.inPlaceOk or 0) or "") ..
		((st.rollsTaken or 0) > 0 and string.format(", %d corners driven through", st.rollsTaken) or "") ..
		((st.rollJunctions or 0) > 0 and string.format(", %d corners at a junction stopped for", st.rollJunctions) or "")
end

-- 1.12.7: vehicles stream in after their chunk's squares, so a row clearAhead already passed can
-- get a wreck a moment later (1.12.6 drive check: the car ran into a jam of wrecks on Dixie Highway
-- and kept leaving the street). Every K.RECHECK_MS the rows K.RECHECK_FROM..K.RECHECK_TO tiles
-- ahead of the car are looked at again; a vehicle that was "removed" but is still there gets
-- removeFromWorld as well, and a trace line.
K.RECHECK_MS, K.RECHECK_FROM, K.RECHECK_TO = 500, 3, 45
K.buildPath = buildPath   -- for the mock tests
function K.recheckAhead(st, s, t, keep)
	if t < (st.recheckT or 0) then return end
	st.recheckT = t + K.RECHECK_MS
	local half = floor((st.width or 8) / 2) + 2
	local cell = getCell()
	for a = floor(s) + K.RECHECK_FROM, math.min(st.total, floor(s) + K.RECHECK_TO) do
		for k = -half, half do
			local x, y = pointAt(st, a, st.off + k)
			local sq = cell:getGridSquare(floor(x), floor(y), st.z)
			local ok, v = false, nil
			if sq then ok, v = pcall(function() return sq:getVehicleContainer() end) end
			if ok and v and v ~= st.car and (keep or (not st.removed[v] and K.keepCar(st, v, x, y)) or st.kept and st.kept[v]) then
				-- obstacles = avoid: only noted, for the jam cap
				K.jamNote(st, a)
			elseif ok and v and v ~= st.car then
				K.jamNote(st, a)
				local again = st.removed[v]
				st.removed[v] = true
				local name = "a vehicle"
				pcall(function() name = v:getScript():getName() end)
				if again then
					pcall(function() v:removeFromWorld() end)
					st.stillThere = (st.stillThere or 0) + 1
				else
					if not pcall(function() v:permanentlyRemove() end) then pcall(function() v:removeFromWorld() end) end
					st.wrecks = st.wrecks + 1
					st.lateWrecks = (st.lateWrecks or 0) + 1
				end
				T.trace(string.format("drivefast: %s %s at %d,%d, %d tiles ahead", again and "removed again (still there)" or "late-loaded, took", tostring(name), floor(x), floor(y), a - floor(s)))
			end
		end
	end
end

-- The eight ways the physics forward vector (x, z) can map onto the map's (x, y).
local FWD_MAPS = {
	function(x, z) return x, z end, function(x, z) return x, -z end,
	function(x, z) return -x, z end, function(x, z) return -x, -z end,
	function(x, z) return z, x end, function(x, z) return z, -x end,
	function(x, z) return -z, x end, function(x, z) return -z, -x end,
}

local function carForward(v)
	local ok, fx, fz = pcall(function()
		local vec = Vector3f.new()
		v:getForwardVector(vec)
		return vec:x(), vec:z()
	end)
	if ok then return fx, fz end
	return nil
end

local function carHeading(st)
	if not st.fmap then return nil end
	local fx, fz = carForward(st.car)
	if not fx then return nil end
	local x, y = FWD_MAPS[st.fmap](fx, fz)
	return atan2(y, x)
end

-- 1.12.8: what is on the squares just in front of a stuck car (vehicles, and objects other than
-- the floor), for the trace
function K.whatsAhead(st, v)
	local h = carHeading(st)
	if not h then return "heading unknown" end
	local seen, out, cell = {}, {}, getCell()
	for d = 1, 4 do
		for side = -1, 1 do
			local x = v:getX() + math.cos(h) * (d + 1) - math.sin(h) * side
			local y = v:getY() + math.sin(h) * (d + 1) + math.cos(h) * side
			local sq = cell:getGridSquare(floor(x), floor(y), st.z)
			if sq then
				pcall(function()
					local car = sq:getVehicleContainer()
					if car and car ~= v and not seen[car] then
						seen[car] = true
						local n = "vehicle"
						pcall(function() n = car:getScript():getName() end)
						out[#out + 1] = n .. " at " .. floor(x) .. "," .. floor(y)
					end
					local objs = sq:getObjects()
					for i = 0, objs:size() - 1 do
						local o = objs:get(i)
						local sp = o:getSprite()
						local name = sp and sp:getName() or tostring(o:getObjectName())
						if o ~= sq:getFloor() and name and not seen[name] then
							seen[name] = true
							out[#out + 1] = name .. " at " .. floor(x) .. "," .. floor(y)
						end
					end
				end)
				if not isStreetSq(sq) and not seen["offstreet" .. d] then
					seen["offstreet" .. d] = true
					out[#out + 1] = string.format("off the street %d tiles ahead", d + 1)
				end
			end
			if #out >= 8 then break end
		end
	end
	return #out > 0 and table.concat(out, "; ") or "nothing found"
end

local function axisDir(dx, dy)
	if math.abs(dx) >= math.abs(dy) then return dx >= 0 and IsoDirections.E or IsoDirections.W end
	return dy >= 0 and IsoDirections.S or IsoDirections.N
end

local function spawnFastCar(sq, dx, dy)
	local sm = getScriptManager()
	for _, name in ipairs(FAST_CARS) do
		local okS, script = pcall(function() return sm:getVehicle(name) end)
		if okS and script then
			local ok, v = pcall(function() return addVehicleDebug(name, axisDir(dx, dy), nil, sq) end)
			if not (ok and v) then
				ok, v = pcall(function() return addVehicle(name, sq:getX(), sq:getY(), sq:getZ()) end)
			end
			if ok and v then return v, name end
		end
	end
	return nil
end

local function readyCar(v)
	pcall(function() v:repair() end)
	pcall(function()
		local g = v:getPartById("GasTank")
		if g then g:setContainerContentAmount(g:getContainerCapacity()) end
	end)
	pcall(function()
		local b = v:getPartById("Battery")
		local it = b and b:getInventoryItem()
		if it then
			if not pcall(function() it:setCurrentUsesFloat(1) end) then it:setUsedDelta(1) end
		end
	end)
	pcall(function() v:cheatHotwire(true, false) end)
end

-- Out of the car, car gone. Also run by finish() if the run stops mid-drive.
local function fastCleanup(r, st)
	local v, p = st.car, r.p
	if not v then return end
	st.car = nil
	pcall(function() v:setRegulator(false) end)
	pcall(function()
		if p:getVehicle() == v then
			v:exit(p)
			v:setCharacterPosition(p, 0, "outside")
			triggerEvent("OnExitVehicle", p)
		end
	end)
	if not pcall(function() v:permanentlyRemove() end) then pcall(function() v:removeFromWorld() end) end
	T.trace("drivefast: car removed")
end

-- Along the path and back at st.speed tiles/s, in ghost mode (the fallback).
local function glideTick(r, st, dt)
	local move = st.speed * math.min(dt, 100) / 1000
	st.tiles = st.tiles + move
	st.gs = st.gs + st.gdir * move
	if st.gs >= st.total then st.gs = 2 * st.total - st.gs; st.gdir = -1; st.passes = st.passes + 1 end
	if st.gs <= 0 then st.gs = -st.gs; st.gdir = 1; st.passes = st.passes + 1 end
	local x, y = pointAt(st, st.gs, st.off)
	local ux, uy = segDir(st, segAt(st, st.gs))
	pcall(function()
		r.p:getForwardDirection():set(ux * st.gdir, uy * st.gdir)
		r.p:teleportTo(x, y, st.z)
	end)
end

-- 1.13.8/1.13.9 (review of 18 Oct): after a wait for a far road the step's time, frames and Lua
-- profiler window start again, so none of them carries the loading
function K.restartMeasure(st, t)
	st.t0 = t
	st.frames = newFrames()
	local P = TG.profiler and TG.profiler()
	if P then pcall(P.takeWindow) end
end

local function fastFallback(r, st, why)
	if st.firstCarT and not st.carEndT then st.carEndT = now() end
	fastCleanup(r, st)
	st.carTiles = st.tiles or 0
	st.fallback = why
	st.mode = "glide"
	-- 1.12.8: always the same glide speed, so glides in different steps compare (1.12.7: drive_fast
	-- glided at 56 tiles/s, drive_corpses at 28, copying whichever car had spawned)
	st.speed = r.plan.glidespeed or FAST_GLIDE_DEFAULT
	st.gs = math.max(0, math.min(st.total or 0, st.s or 0))
	st.gdir = 1
	st.tiles, st.passes = 0, 0
	pcall(function() r.p:setGhostMode(true) end)
	T.trace("drivefast: FALLBACK to a glide at " .. string.format("%.0f", st.speed) .. " tiles/s: " .. why)
	say("drivefast fallback: " .. why)
end

local function fastPhase(st, t, name)
	st.phase, st.tPhase = name, t
	st.alignN, st.alignWait, st.lastErr = 0, 0, nil
end

-- The car's measured speed over the map, tiles/s, from its position every 250 ms or so.
local function fastMeasure(st, t)
	local v = st.car
	local x, y = v:getX(), v:getY()
	if not st.mx then st.mx, st.my, st.mt = x, y, t; return end
	local el = t - st.mt
	if el >= 250 then
		local dx, dy = x - st.mx, y - st.my
		st.tps = math.sqrt(dx * dx + dy * dy) * 1000 / el
		st.mx, st.my, st.mt = x, y, t
		if st.tps > st.peakTps and st.phase == "leg" then st.peakTps = st.tps end
	end
	local okK, kmh = pcall(function() return v:getCurrentSpeedKmHour() end)
	if okK and kmh and st.phase == "leg" and math.abs(kmh) > st.peakKmh then st.peakKmh = math.abs(kmh) end
end

-- Turn the stopped car until it points at angle want (radians on the map). One correction every
-- third tick, so the physics transform has caught up before it's read again; if a correction made
-- things worse, the sign between getAngleY and the map is the other way round.
-- 1.11.1: which way setAngles' Y turns the heading is measured once per car: +2 degrees, read the
-- heading, put it back. Up to 1.11.0 the sign was only learnt when lining up needed several nudges;
-- a car that was already lined up kept the default, and if that was wrong the pursuit steered away
-- from the street (the "drifted 7 tiles at 18 km/h" in every 1.9.x run).
local function probeSign(st)
	if st.signCar == st.car then return true end
	local v = st.car
	local h0 = carHeading(st)
	if not h0 then return false end
	if not st.probeH0 then
		st.probeH0 = h0
		pcall(function() v:setAngles(v:getAngleX(), v:getAngleY() + 2, v:getAngleZ()) end)
		return false
	end
	local dh = wrapAngle(h0 - st.probeH0)
	pcall(function() v:setAngles(v:getAngleX(), v:getAngleY() - 2, v:getAngleZ()) end)
	st.probeH0 = nil
	if math.abs(dh) < 0.005 then
		st.probeTries = (st.probeTries or 0) + 1
		if st.probeTries < 5 then return false end
		T.trace("drivefast: steering sign probe saw no turn; keeping " .. st.alignSign)
	else
		st.alignSign = dh > 0 and 1 or -1
		st.signKnown = true
		T.trace(string.format("drivefast: steering sign %+d (+2 deg of angle Y turned the heading %+.1f deg)", st.alignSign, dh * 180 / math.pi))
	end
	st.signCar, st.probeTries = st.car, 0
	return false   -- the heading read this tick still had the +2 in it
end

local function fastAlign(st, want)
	local h = carHeading(st)
	if not h then return true end
	if not probeSign(st) then return false end
	local err = wrapAngle(want - h)
	if math.abs(err) * 180 / math.pi < FAST_ALIGN_TOL then return true end
	st.alignWait = st.alignWait - 1
	if st.alignWait > 0 then return false end
	st.alignN = st.alignN + 1
	if st.alignN > 30 then st.alignFailed = (st.alignFailed or 0) + 1; return true end
	-- flip only when the probe couldn't measure the sign (1.12.2: the flip undid a measured sign)
	if not st.signKnown and st.lastErr and math.abs(err) > math.abs(st.lastErr) - 0.01 then st.alignSign = -st.alignSign end
	st.lastErr = err
	local deg = err * 180 / math.pi
	if math.abs(deg) < 1.5 then deg = deg < 0 and -1.5 or 1.5 end
	local v = st.car
	pcall(function() v:setAngles(v:getAngleX(), v:getAngleY() + st.alignSign * deg, v:getAngleZ()) end)
	st.alignWait = 3
	return false
end

-- A turn of `deg` degrees (positive = heading angle up) through setAngles, remembered so the next
-- check can see which way the heading really went.
function K.steerBy(st, v, h, deg)
	st.moveSign = st.moveSign or st.alignSign
	pcall(function() v:setAngles(v:getAngleX(), v:getAngleY() + st.moveSign * deg, v:getAngleZ()) end)
	st.steers = st.steers + 1
	st.lastSteer = { h = h, deg = deg }
	-- 1.12.6: what each teleport does to the speed, for the first few of them
	if (st.tpNotes or 0) < 6 and not st.tpAt then st.tpAt, st.tpBefore = now(), st.tps end
end
-- 1.12.6, steer = torque (the default): turn the moving car with a pair of equal and opposite sideways
-- pushes at its front and back (vehicle:applyImpulseGeneric). They add up to a pure turn and no
-- sideways shove, go through the physics like a bump from a hit object does, and never teleport
-- the car the way setAngles does (every setAngles is a Bullet.teleportVehicle; with it every 300 ms
-- the 1.12.3 car's speed went 0.7 -> 4.7 -> 0.7 tiles/s). The push is a feedback loop on the turn
-- rate: wanted rate (pure pursuit) minus the rate read from the heading, plus a slowly built-up
-- share for what the tyres hold back. Its scale in the engine is unknown, so it adapts: a push at
-- its cap that hardly turns the car doubles the cap (and the gain) every 0.2 s; a spinning car
-- halves the gain; a cap past K.TQ_CEIL that still does nothing hands the car back to the nudges.
K.TQ_ARM = 1.5        -- tiles from the car's centre to each push
K.TQ_GAIN0 = 0.5      -- push per degree/s of turn-rate error, to start with
K.TQ_KI = 60          -- how fast the built-up share grows, per second
K.TQ_MAX0 = 400       -- the largest push, to start with
K.TQ_CEIL = 6400      -- past this the push does nothing here (1.13.4: was 1e6; real cars turn at pushes of 150 to 300,
                      -- and with the tighter 1.13.4 limits a dead push must hand over before the leg is cut)
K.TQ_SPIN = 45        -- degrees/s: the car is spinning
-- 1.13.2: the 1.12.10 drive_fast halved the gain 4 times in the wreck jams (0.5 to 0.031) and kept
-- it there, so the car hardly steered for the rest of the run. Now it never goes under K.TQ_GAIN_MIN
-- and grows back by K.TQ_REGROW every K.TQ_REGROW_MS without a spin, up to where it was.
K.TQ_GAIN_MIN = 0.125
-- 1.13.5: run 1's leg 1 spin came from the built-up share (-210 of a -214 push at 38 km/h, the car
-- already turning 18 deg/s the right way). It now stays under K.TQ_I_SHARE of the cap, bleeds off
-- at K.TQ_I_LEAK per second, and stops building while the push is at the cap; the direct part is
-- K.TQ_P times stronger. A spinning car gets a push against the spin (at most the built-up limit)
-- instead of none.
K.TQ_I_SHARE, K.TQ_I_LEAK, K.TQ_P = 0.5, 1.0, 3
K.TQ_REGROW, K.TQ_REGROW_MS = 1.25, 5000
function K.torqueSteer(st, v, h, wantDeg, t, dt)
	local sec = math.min(dt, 100) / 1000
	if sec <= 0 then return end
	if st.tqH and st.tqCar == v and t - (st.tqT or 0) <= 250 then
		local w = wrapAngle(h - st.tqH) * 180 / math.pi / sec
		st.tqW = (st.tqW or w) * 0.6 + w * 0.4
	else
		st.tqW, st.tqI, st.tqSat = 0, 0, nil
	end
	st.tqH, st.tqCar, st.tqT = h, v, t
	st.tqGain = st.tqGain or K.TQ_GAIN0
	st.tqMax = st.tqMax or K.TQ_MAX0
	local w = st.tqW
	-- 1.13.11 (1.13.10 drive_fast at 10679,8761): a corner driven through may ask for up to
	-- K.FAST_ROLL_TURN (57 deg/s), past K.TQ_SPIN, so the turn it asked for was taken for a spin:
	-- gain halved and a push against the turn, and the car went off the outside of the corner.
	-- Now it is a spin past 1.5 times the wanted rate plus 20 deg/s (at least K.TQ_SPIN), or the wrong way past K.TQ_SPIN.
	local spinning = math.abs(w) > math.max(K.TQ_SPIN, 1.5 * math.abs(wantDeg) + 20) or (math.abs(w) > K.TQ_SPIN and w * wantDeg <= 0)
	if K.tune(st, "TQ_SPIN_OLD") then spinning = math.abs(w) > K.TQ_SPIN end
	if spinning then
		st.tqI = 0
		local lim = (st.tqMax or K.TQ_MAX0) * K.TQ_I_SHARE
		st.tqCounter = math.max(-lim, math.min(lim, st.tqGain * K.TQ_P * (wantDeg - w)))
		K.tqPush(st, v, h, st.tqCounter)
		-- 1.12.7: a spin with only a small push is a knock (a wreck, a kerb), not the steering: the
		-- 1.12.6 drive check halved the gain 4 times for knocks at pushes of 12 to 44 (cap 400)
		if math.abs(st.tqM or 0) < 0.3 * (st.tqMax or K.TQ_MAX0) then
			if t >= (st.tqKnockT or 0) then
				st.tqKnockT = t + 1000
				st.tqKnocks = (st.tqKnocks or 0) + 1
				T.trace(string.format("drivefast: the car spun (%.0f deg/s) at a small push (%.0f): knocked by something, gain kept", w, st.tqM or 0))
			end
			return
		end
		if t >= (st.tqSpinT or 0) then
			st.tqSpinT = t + 1000
			st.tqGainTop = math.max(st.tqGainTop or 0, st.tqGain)
			-- 1.13.17 (1.13.14 drive_fast: halved to 0.125 three times steering back at 10606,8829, and too weak
			-- to hold the car after): not under K.RECOVER_GAIN_MIN while steering back
			-- 1.13.18 (review of 1.13.17): the floor never raises a gain already under it
			st.tqGain = math.min(st.tqGain, math.max(st.recover and K.tune(st, "RECOVER_GAIN_MIN") or K.TQ_GAIN_MIN, st.tqGain * 0.5))
			st.tqRegrowT = t + K.TQ_REGROW_MS
			st.tqSpins = (st.tqSpins or 0) + 1
			T.trace(string.format("drivefast: torque steering spun the car (%.0f deg/s); gain halved to %.3g", w, st.tqGain))
		end
		return
	end
	if st.tqGainTop and t >= (st.tqRegrowT or 0) then
		st.tqRegrowT = t + K.TQ_REGROW_MS
		st.tqGain = math.min(st.tqGainTop, st.tqGain * K.TQ_REGROW)
		if st.tqGain >= st.tqGainTop then st.tqGainTop = nil end
	end
	st.tqCounter = nil
	local e = wantDeg - w
	local cap = st.tqMax
	local iCap = cap * K.TQ_I_SHARE
	local leak = K.TQ_I_LEAK
	if (st.tqI or 0) * e < 0 then leak = leak * K.tune(st, "TQ_I_OPPOSE") end   -- 1.13.10: pushing past the turn wanted
	local I = (st.tqI or 0) * math.max(0, 1 - leak * sec)
	local raw = st.tqGain * K.TQ_P * e + I
	if math.abs(raw) < cap or raw * e < 0 then I = I + e * sec * K.TQ_KI * st.tqGain end
	st.tqI = math.max(-iCap, math.min(iCap, I))
	local m = math.max(-cap, math.min(cap, st.tqGain * K.TQ_P * e + st.tqI))
	-- at the cap while the car turns less than half as fast as wanted: the push is too weak here
	-- (1.13.5: or the built-up share at its limit, now under the cap)
	if (math.abs(m) >= cap * 0.99 or math.abs(st.tqI) >= iCap * 0.99) and math.abs(wantDeg) > 1 and w * wantDeg < 0.5 * wantDeg * wantDeg then
		st.tqSat = st.tqSat or t
		-- 1.13.14 (1.13.11 drive_fast at 10674,8762: raised to 800 at the 46 deg corner, spun 0.25 s later
		-- and left the street): not in a corner driven through, where the turn takes a moment to build
		if st.nearRoll and K.tune(st, "CORNER_NO_RAISE") then st.tqSat = t end
		if t - st.tqSat > 120 then   -- 1.13.4: was 200; the tighter limits leave less time
			st.tqSat = t
			if st.tqMax >= K.TQ_CEIL then
				st.steerMode = "nudge"
				T.trace(string.format("drivefast: torque steering turned the car only %.1f deg/s (wanted %.1f) at a push of %.0f; steering with setAngles nudges from here", w, wantDeg, m))
				return
			end
			st.tqMax, st.tqGain = st.tqMax * 2, st.tqGain * 2
			if st.tqGainTop then st.tqGainTop = st.tqGainTop * 2 end
			st.tqRaised = (st.tqRaised or 0) + 1
			if st.tqRaised <= 3 or st.tqRaised % 5 == 0 then
				T.trace(string.format("drivefast: torque steering too weak (%.1f deg/s, wanted %.1f); push cap raised to %.0f, gain %.3g", w, wantDeg, st.tqMax, st.tqGain))
			end
		end
	else
		st.tqSat = nil
	end
	st.tqM = m
	st.tqPeak = math.max(st.tqPeak or 0, math.abs(m))
	K.tqPush(st, v, h, m)
end

-- The pair of pushes for a turn push m (positive turns the heading angle up).
function K.tqPush(st, v, h, m)
	if math.abs(m) < 0.01 then return end
	local fx, fy = math.cos(h), math.sin(h)
	local sg = m > 0 and 1 or -1
	local nx, ny = -fy * sg, fx * sg   -- pushing the front this way turns the heading angle up when m > 0
	local x, y, z = v:getX(), v:getY(), v:getZ()
	local a = K.TQ_ARM
	pcall(function()
		v:applyImpulseGeneric(x + fx * a, y + fy * a, z, nx, ny, 0, math.abs(m))
		v:applyImpulseGeneric(x - fx * a, y - fy * a, z, -nx, -ny, 0, math.abs(m))
	end)
	st.tqTicks = (st.tqTicks or 0) + 1
end

-- 1.12.2: the sign is checked on the move too, and kept apart from the lining-up sign (measured on a
-- stopped or slow car, which may turn the other way). A turn whose heading change goes the other way
-- three times more often than the right way flips the moving sign; it carries over to fresh cars.
function K.steerCheck(st, h)
	local ls = st.lastSteer
	if not ls then return end
	st.lastSteer = nil
	local dh = wrapAngle(h - ls.h) * 180 / math.pi
	if math.abs(dh) < 0.3 then return end
	if (dh > 0) == (ls.deg > 0) then st.signRight = (st.signRight or 0) + 1 else st.signWrong = (st.signWrong or 0) + 1 end
	if (st.signWrong or 0) >= 3 and st.signWrong > 2 * (st.signRight or 0) then
		st.moveSign = -(st.moveSign or st.alignSign)
		T.trace(string.format("drivefast: steering on the move went the wrong way %d times (%d right); moving sign flipped to %+d (lining-up sign %+d)", st.signWrong, st.signRight or 0, st.moveSign, st.alignSign))
		st.signWrong, st.signRight = 0, 0
	end
end

-- The pure-pursuit turn rate (radians/s) for aim angle a at `look` tiles, capped; 1.13.2 scales it
-- down below K.SLOW_TURN_TPS (a hard correction at a crawl cost leg 1 its speed in 1.12.10) and
-- allows K.FAST_ROLL_TURN near a corner driven through.
function K.wantedRate(tps, a, look, roll)
	local rate = 2 * tps * math.sin(a) / look
	if tps < K.SLOW_TURN_TPS then rate = rate * math.max(0, tps) / K.SLOW_TURN_TPS end
	local cap = roll and K.FAST_ROLL_TURN or K.FAST_TURN_MAX
	return math.max(-cap, math.min(cap, rate))
end

local function startLeg(st, t)
	fastPhase(st, t, "leg")
	st.legs = st.legs + 1
	st.legPeak, st.movedT, st.gasT0 = 0, nil, nil
	st.legLat0, st.legS0 = nil, nil
end

-- obstacles = avoid (1.9.1): the other vehicles stay where they are and the car steers round them,
-- the way a real driver (or a real autopilot) has to; the default "clear" takes them off the map.
-- The game's own obstacle graph (PolygonalMap2) isn't reachable from Lua, so this looks at squares:
-- along the next 12 to 60 tiles, each lane offset across the street is tried as a corridor about
-- as wide as the car (the offset and a tile either side), and one with no vehicle, solid object or
-- tree in it is taken, the one nearest the current line first. None clear: stop short of it.
K.DODGE_FROM, K.DODGE_TO = 12, 60
local function blockedSq(sq, car)
	if not sq then return false end
	local ok, v = pcall(function() return sq:getVehicleContainer() end)
	if ok and v and v ~= car then return true end
	if K.sqIs and (K.sqIs(sq, K.flag("solid")) or K.sqIs(sq, K.flag("solidtrans"))) then return true end
	local okT, tree = false, false
	if K.hasTree then okT, tree = pcall(K.hasTree, sq) end
	return okT and tree == true
end
-- 1.13.14 (1.13.11 mod:drive: road works at 10587,9449-9543 (construction_01_8, damaged_objects_01_27)
-- and light poles at the edge (lighting_outdoor_01_16) stopped the car 9 times and took 4 fresh cars;
-- the solid probe didn't see them): these sprites count as in the way as well
K.BLOCK_PREFIX = { "construction_", "damaged_objects_", "lighting_outdoor_" }
function K.blocker(sq, car)
	if not sq then return false end
	if blockedSq(sq, car) then return true end
	local hit = false
	pcall(function()
		local objs = sq:getObjects()
		for i = 0, objs:size() - 1 do
			local sp = objs:get(i):getSprite()
			local n = sp and sp:getName()
			if n then for _, pre in ipairs(K.BLOCK_PREFIX) do if string.sub(n, 1, #pre) == pre then hit = true; return end end end
		end
	end)
	return hit
end
-- the followed centre at a (past the next bend once its own centre is read: K.BEND_OFF)
function K.offAt(st, a)
	if st.offNextS and st.offNext and a > st.offNextS then return st.offNext end
	return st.off
end
-- 1.13.14: in "obstacles = clear" (the default: cars ahead are taken away) solid things on the road are
-- steered round too, within the carriageway held: the nearest offset with a car-wide lane clear of
-- them from K.SOLID_DODGE_FROM to K.SOLID_DODGE_TO tiles on. Nothing clear: the centre, as before.
function K.solidDodge(st, s, car)
	local cell = getCell()
	local half = math.max(1, floor((K.laneWidth(st) or 8) / 2) - 1)
	local cur = st.dodge or 0
	local order = { 0 }
	for d = 1, half do order[#order + 1] = d; order[#order + 1] = -d end   -- 1.13.15: the right (positive) side first
	if cur ~= 0 then table.insert(order, 1, cur) end
	-- held until a few tiles past the last thing in the way on the centre (inside K.SOLID_DODGE_FROM
	-- the scan no longer sees it, and the car would turn back into it)
	local lastBlock
	local function clear(o, from)
		local ok = true
		for a = from, math.min(st.total, s + math.max(K.SOLID_DODGE_TO, (st.tps or 0) * K.SOLID_DODGE_S)), 2 do
			for k = -1, 1 do
				local x, y = pointAt(st, a, K.offAt(st, a) + o + k)
				local sq = cell:getGridSquare(floor(x), floor(y), st.z)
				-- 1.13.15 (review of 1.13.14): a lane round it must be street, not pavement or a verge
				if o ~= 0 and sq and not isStreetSq(sq) then return false end
				if K.blocker(sq, car) then
					if o ~= 0 then return false end
					ok, lastBlock = false, a
					break
				end
			end
		end
		return ok
	end
	if cur ~= 0 and s < (st.dodgeHold or -1) and clear(cur, s + 1) then return cur end
	if clear(0, s + K.SOLID_DODGE_FROM) then st.dodgeHold = nil; return 0 end
	for _, o in ipairs(order) do
		if o ~= 0 and clear(o, s + 1) then st.dodgeHold = (lastBlock or s) + 4; return o end
	end
	st.dodgeHold = nil
	return 0
end
function K.dodge(st, s, car)
	local cell = getCell()
	local half = floor((st.width or 8) / 2) - 1
	local cur = st.dodge or 0
	local order = { cur }
	for d = 1, 2 * half do
		for _, sgn in ipairs({ -1, 1 }) do
			local o = cur + sgn * d
			if math.abs(o) <= half then order[#order + 1] = o end
		end
	end
	local firstBlock = nil
	local function clear(o)
		for a = s + K.DODGE_FROM, math.min(st.total, s + K.DODGE_TO), 2 do
			for k = -1, 1 do
				local x, y = pointAt(st, a, st.off + o + k)
				if blockedSq(cell:getGridSquare(floor(x), floor(y), st.z), car) then
					if o == 0 and not firstBlock then firstBlock = a end
					return false
				end
			end
		end
		return true
	end
	for _, o in ipairs(order) do
		if clear(o) then
			st.dodgeBlockS = nil
			if o == 0 then return 0, "road clear" end
			return o, "something on the road ahead"
		end
	end
	st.dodgeBlockS = firstBlock or (s + K.DODGE_FROM)
	return cur, "no way round"
end

Steps.drivefast = {
	begin = function(r, st)
		st.seconds = st.a or 90
		st.kmh = st.b
		st.tiles, st.passes, st.legs, st.peakTps, st.peakKmh, st.tps, st.maxLateral0 = 0, 0, 0, 0, 0, 0, 0
		st.alignSign = 1
		st.off, st.steers, st.wrecks, st.removed, st.topLegs = 0, 0, 0, {}, 0
		st.respawns, st.uturns, st.corners, st.stuckRun = 0, 0, 0, 0
		st.tune = r.plan.drivetune and K.TUNES[r.plan.drivetune] or nil
		st.carSec, st.moveSec, st.moveTiles = 0, 0, 0
		local pts = r.plan.fastroad
		if #pts < 2 then st.skip = "no road in the plan (fastroad = x,y,z, two or more)"; return end
		local path = {}
		for _, p in ipairs(pts) do path[#path + 1] = { x = p.x + 0.5, y = p.y + 0.5 } end
		if r.plan.corners == "stop" then st.rollDeg = K.FAST_CORNER_DEG end
		buildPath(st, path)
		st.z = pts[1].z or 0
		st.roadLen, st.width, st.roadName = st.total, r.plan.fastwidth, r.plan.fastname
		st.s = FAST_INSET
		if st.total < FAST_INSET * 2 + 10 then fastFallback(r, st, "road too short (" .. floor(st.total) .. " tiles)"); return end
		local sx, sy = pointAt(st, FAST_INSET, 0)
		sx, sy = floor(sx), floor(sy)
		pcall(function() r.p:setGhostMode(false) end)
		teleport(r.p, sx, sy, st.z)
		if not getCell():getGridSquare(sx, sy, st.z) then
			-- a road far from the start (picked from the map): wait for the world to load there
			st.mode, st.loadT0, st.loadX, st.loadY = "load", st.t0 or now(), sx, sy
			T.trace(string.format("drivefast: waiting for the road at %d,%d to load", sx, sy))
			return
		end
		Steps.drivefast.spawn(r, st, FAST_INSET)
	end,
	-- A car on the path at s0, pointing along it. Any car already out is taken away first.
	spawn = function(r, st, s0)
		st.firstCarT = st.firstCarT or now()   -- 1.13.11: the average speed's clock starts at the first car
		if st.car then fastCleanup(r, st) end
		st.passedStop, st.recover, st.offStreet, st.offAhead = nil, nil, nil, nil
		st.ipS, st.ipN, st.ipPending, st.alignTo, st.lineupTries = nil, nil, nil, nil, nil
		st.offNextS, st.offNext, st.offTryT, st.offRamp = nil, nil, nil, nil
		if r.plan.obstacles ~= "avoid" then st.dodge = nil end
		st.seg = segAt(st, s0)
		-- line up with the street as it really is (the map's centre lines can be a tile or two off)
		local okC, c, w = pcall(streetCentre, st, s0)
		local okP, pc, pw, gap = pcall(K.pickCarriageway, st, s0)
		st.dividedRight = okP and pc ~= nil   -- 1.13.12: re-anchoring keeps to this side then
		if okP and pc then
			st.off, st.laneW = pc, pw
			st.width = st.width or pw
			T.trace(string.format("drivefast: divided street at %.0f tiles: %d-wide carriageways either side of a %d-tile median; holding the right-hand one, centre %.1f tiles off the line", s0, pw, gap, pc))
		elseif okC and c and (not st.width or w <= st.width + 3) then
			st.off, st.laneW = c, w
			st.width = st.width or w
			T.trace(string.format("drivefast: street at %.0f tiles is %d wide, centre %.1f tiles off the line", s0, w, c))
		end
		local sx, sy = pointAt(st, s0, st.off)
		sx, sy = floor(sx), floor(sy)
		st.clearTo = nil
		pcall(clearAhead, st, s0)
		teleport(r.p, sx, sy, st.z)
		local sq = getCell():getGridSquare(sx, sy, st.z)
		if not sq then
			-- 1.13.11 (1.13.10 baseline drive_fast: "road not loaded at 11607,8746" right after the
			-- teleport for a fresh car): wait for it like the first road, up to K.SPAWN_LOAD_WAITS times
			if (st.spawnWaits or 0) < K.tune(st, "SPAWN_LOAD_WAITS") then
				st.spawnWaits = (st.spawnWaits or 0) + 1
				st.mode, st.loadT0, st.loadX, st.loadY, st.loadS, st.loadedT = "load", now(), sx, sy, s0, nil
				T.trace(string.format("drivefast: the fresh car's square %d,%d isn't loaded yet; waiting for it", sx, sy))
				return
			end
			fastFallback(r, st, "road not loaded at " .. sx .. "," .. sy); return
		end
		local ux, uy = segDir(st, st.seg)
		local v, name = spawnFastCar(sq, ux, uy)
		if not v then fastFallback(r, st, "could not spawn a car (" .. table.concat(FAST_CARS, ", ") .. ")"); return end
		st.car, st.carName = v, name
		st.s, st.mx = s0, nil
		r.cleanup = function() fastCleanup(r, st) end
		readyCar(v)
		local okM, maxS = pcall(function() return v:getMaxSpeed() end)
		st.maxKmh = okM and maxS or nil
		if st.maxKmh and st.maxKmh > 0 then st.topTps = st.maxKmh / 3.6 end
		st.kmh = st.b or st.maxKmh or 120
		-- 1.12.6: no cruise above what the car can do (120 on a 110 km/h car)
		if st.maxKmh and st.maxKmh > 0 and st.kmh > st.maxKmh then st.kmh = st.maxKmh end
		st.mode = "car"
		st.forcedEngine = nil
		fastPhase(st, now(), "enter")
		T.trace(string.format("drivefast: spawned %s at %d,%d (%.0f of %.0f tiles), top speed %s km/h, cruise set to %s",
			name, sx, sy, s0, st.total, tostring(st.maxKmh), tostring(st.kmh)))
	end,
	tick = function(r, st, t, dt)
		local el = t - st.t0
		if st.mode == "load" then
			st.waiting = "the far road end to load"
			local sq = getCell():getGridSquare(st.loadX, st.loadY, st.z)
			if sq then
				st.loadedT = st.loadedT or t
				if t - st.loadedT >= 1000 then   -- a moment more for the squares around it
					st.waiting = nil
					st.mode = nil
					if st.loadS then   -- 1.13.11: a fresh car's square mid-drive; the step's numbers go on
						local s0 = st.loadS
						st.loadS = nil
						T.trace(string.format("drivefast: the fresh car's square loaded after %.1f s", (t - st.loadT0) / 1000))
						Steps.drivefast.spawn(r, st, s0)
						return false
					end
					st.loadMs = t - st.loadT0
					-- 1.13.8 (review of 18 Oct): the step's time and frames start here, as the tree road's
					-- do, so neither the drive's time nor its fps carries the wait (1.13.7 only added the time)
					K.restartMeasure(st, t)
					T.trace(string.format("drivefast: road loaded after %.1f s; the step's time, frames and Lua profile start now", st.loadMs / 1000))
					Steps.drivefast.spawn(r, st, FAST_INSET)
				end
			elseif t - st.loadT0 > FAST_LOAD_MS then
				st.waiting = nil
				if not st.loadS then K.restartMeasure(st, t) end   -- 1.13.9: the glide's numbers don't carry the wait either
				fastFallback(r, st, string.format("the road at %d,%d was still not loaded %d s after the teleport", st.loadX, st.loadY, FAST_LOAD_MS / 1000))
			end
			return false
		end
		if st.mode == "glide" then
			glideTick(r, st, dt)
			if el >= st.seconds * 1000 then
				pcall(function() r.p:setGhostMode(r.wasGhost) end)
				local home = r.plan.start or r.home
				teleport(r.p, home.x, home.y, home.z)
				st.extraLines = { K.driveLine(st) }
				st.result = string.format("FALLBACK glide (%s): %.0f tiles at %.0f tiles/s, %d passes%s", st.fallback,
					st.tiles, st.speed, st.passes,
					st.legs > 0 and string.format("; before that the car did %d legs, peak %.0f km/h, %d fresh cars", st.legs, st.peakKmh, st.respawns) or "") .. K.driveCounts(st)
				return true
			end
			return false
		end
		local v, p = st.car, r.p
		if not v then fastFallback(r, st, "car gone"); return false end
		local okM = pcall(fastMeasure, st, t)
		if not okM then fastFallback(r, st, "car position unreadable"); return false end
		local inPhase = t - st.tPhase

		if st.phase == "enter" then
			if inPhase < 1000 then return false end   -- give the new car a moment in the physics world
			pcall(function()
				v:enter(0, p)
				v:setCharacterPosition(p, 0, "inside")
				v:playPassengerAnim(0, "idle")
				triggerEvent("OnEnterVehicle", p)
			end)
			local okV, inCar = pcall(function() return p:getVehicle() == v end)
			if not (okV and inCar) then fastFallback(r, st, "could not get into the driver's seat"); return false end
			pcall(function() v:tryStartEngine(true) end)
			fastPhase(st, t, "engine")
			return false
		end

		if st.phase == "engine" then
			local okE, running = pcall(function() return v:isEngineRunning() end)
			if okE and running then
				T.trace(string.format("drivefast: engine running after %.1f s", inPhase / 1000))
				if st.fmap then
					fastPhase(st, t, "align")   -- a fresh car of the same kind: the forward map is known
				else
					fastPhase(st, t, "creep")
					st.cx, st.cy = v:getX(), v:getY()
					pcall(function() v:setRegulatorSpeed(10); v:setRegulator(true) end)
				end
				return false
			end
			if inPhase > 2000 and not st.forcedEngine then
				st.forcedEngine = true
				pcall(function() v:engineDoRunning() end)
				T.trace("drivefast: engine forced on (engineDoRunning)")
			elseif inPhase > 3000 and inPhase % 1000 < 20 then
				pcall(function() v:tryStartEngine(true) end)
			end
			if inPhase > 8000 then fastFallback(r, st, "engine would not run") end
			return false
		end

		if st.phase == "creep" then
			-- a few tiles at walking pace, to learn which way the car's forward vector points on the map
			local dx, dy = v:getX() - st.cx, v:getY() - st.cy
			local d = math.sqrt(dx * dx + dy * dy)
			if d >= 2.5 then
				pcall(function() v:setRegulator(false) end)
				local fx, fz = carForward(v)
				if fx then
					local best, bdot = nil, 0.8
					for i, m in ipairs(FWD_MAPS) do
						local mx, my = m(fx, fz)
						local dot = (mx * dx + my * dy) / d
						if dot > bdot then best, bdot = i, dot end
					end
					st.fmap = best
				end
				local ux, uy = segDir(st, st.seg)
				T.trace(string.format("drivefast: creep moved %.1f tiles heading %.0f deg (road %.0f deg), forward map %s",
					d, atan2(dy, dx) * 180 / math.pi, atan2(uy, ux) * 180 / math.pi, tostring(st.fmap)))
				if not st.fmap then T.trace("drivefast: forward vector doesn't match the motion, no lining up") end
				fastPhase(st, t, "stop")
				st.after = "align"
			elseif inPhase > 8000 then
				fastFallback(r, st, string.format("car moved only %.1f tiles in 8 s at cruise 10 km/h", d))
			end
			return false
		end

		if st.phase == "stop" then
			pcall(function() v:setRegulator(false); v:setForceBrake() end)
			if st.tps < 0.3 and inPhase > 600 or inPhase > 15000 then
				if st.after == "done" or el >= (st.seconds - 4) * 1000 then
					return Steps.drivefast.finishCar(r, st)
				end
				if st.after == "recentre" then
					-- off the street: 1.13.2 tries this car again first (lined up towards the centre),
					-- then a fresh car on its centre a little further on
					local s = project(st, v:getX(), v:getY())
					if K.inPlaceTry(st, s, "off the street", select(2, project(st, v:getX(), v:getY()))) then
						fastPhase(st, t, "align")
						return false
					end
					if st.stuckRun < K.FAST_RESPAWNS and s + 3 < st.total - FAST_INSET - 10 then
						st.respawns, st.stuckRun = st.respawns + 1, st.stuckRun + 1
						st.respawnS = s + 3
						T.trace(string.format("drivefast: off the street at %.0f,%.0f; a fresh car on the centre (%d in a row, up to %d)",
							v:getX(), v:getY(), st.stuckRun, K.FAST_RESPAWNS))
						Steps.drivefast.spawn(r, st, s + 3)
						return false
					end
					fastFallback(r, st, string.format("kept leaving the street (%d fresh cars in a row)", st.stuckRun))
					return false
				end
				if st.after == "corner" then
					local s = project(st, v:getX(), v:getY())
					if st.cornerS - s > K.FAST_CORNER_NEAR then
						-- braking from top speed stops well short: roll up to the corner slowly first
						st.slow = true
						fastPhase(st, t, "leg")
						st.movedT, st.gasT0 = nil, nil
						return false
					end
					st.passedStop, st.slow = st.cornerS, nil
					fastPhase(st, t, "align")
					return false
				end
				if st.after == "uturn" then
					-- end of the road: a fresh car facing back, rather than turning this one round in place
					reversePath(st)
					st.uturns = st.uturns + 1
					st.stuckRun, st.respawnS = 0, nil
					T.trace("drivefast: end of the road, a fresh car facing back")
					Steps.drivefast.spawn(r, st, FAST_INSET)
					return false
				end
				fastPhase(st, t, "align")
			end
			return false
		end

		if st.phase == "align" then
			pcall(function() v:setForceBrake() end)
			local s = project(st, v:getX(), v:getY())
			-- 1.13.5: along the road K.LINEUP_AIM tiles on, not the segment here: run 1's second car stood
			-- on a 51 deg bend, lined up with the old segment and left the street turning. (1.13.6: along
			-- it, not at its centre: run 2's car stood 2.2 tiles off after the creep, pointed 20 deg in
			-- and swung across the 6-wide carriageway.)
			local s1 = math.min(st.total - 0.5, math.max(s, st.passedStop or s) + K.LINEUP_AIM)
			local ux, uy = segDir(st, segAt(st, s1))
			local want = atan2(uy, ux)
			if st.alignTo then
				-- a try on the same car: point at the centre a little way on, not along the road
				local s0 = math.max(s, st.passedStop or s)
				local cx, cy = pointAt(st, math.min(st.total, s0 + st.alignTo), K.offAt(st, s0 + st.alignTo) + (st.dodge or 0))
				-- 1.13.14 (1.13.11 drive_fast at 11542,8756: three tries into the same light pole): the
				-- first aim whose line from the car is clear of anything in the way, a car's width wide
				if K.tune(st, "ALIGN_CLEAR") and not st.alignPicked then
					st.alignPicked = true
					local cell = getCell()
					local function lineClear(tx, ty)
						local dx, dy = tx - v:getX(), ty - v:getY()
						local len = math.sqrt(dx * dx + dy * dy)
						if len < 1 then return true end
						local nx, ny = -dy / len, dx / len
						for d = 1, len, 1 do
							for k = -1, 1 do
								local x = v:getX() + dx / len * d + nx * k
								local y = v:getY() + dy / len * d + ny * k
								local sq = cell:getGridSquare(floor(x), floor(y), st.z)
								if K.blocker(sq, v) then return false end
								-- 1.13.17 (1.13.14 drive_human at 10601,9689: two tries straight on into the verge):
								-- the line's middle must stay on the street
								if k == 0 and d >= 2 and K.tune(st, "ALIGN_STREET") and sq and not isStreetSq(sq) then return false end
							end
						end
						return true
					end
					if not lineClear(cx, cy) then
						local found = false
						for _, o in ipairs({ 0, 1, -1, 2, -2 }) do
							for _, a in ipairs({ st.alignTo, 5, 12 }) do
								local tx, ty = pointAt(st, math.min(st.total, s0 + a), K.offAt(st, s0 + a) + (st.dodge or 0) + o)
								if lineClear(tx, ty) then
									cx, cy, found = tx, ty, true
									T.trace(string.format("drivefast: the line to the centre %d tiles on is blocked; aiming %d tiles on, %+d off the centre", st.alignTo, a, o))
									break
								end
							end
							if found then break end
						end
						st.alignAim = found and { cx, cy } or nil
					end
				end
				if st.alignAim then cx, cy = st.alignAim[1], st.alignAim[2] end
				want = atan2(cy - v:getY(), cx - v:getX())
			end
			if fastAlign(st, want) or inPhase > 12000 then
				local h = carHeading(st)
				local off = h and math.abs(wrapAngle(want - h)) * 180 / math.pi
				-- 1.13.2: 1.12.10's leg 1 started 11 deg off and lost speed to the correction at 24 km/h
				if off and off > K.LINEUP_TOL and (st.lineupTries or 0) < 2 and inPhase <= 12000 then
					st.lineupTries = (st.lineupTries or 0) + 1
					st.alignN, st.alignWait = 0, 0
					T.trace(string.format("drivefast: still %.1f deg off after lining up; again (%d)", off, st.lineupTries))
					return false
				end
				T.trace(string.format("drivefast: lined up for leg %d, %s", st.legs + 1,
					off and string.format("off by %.1f deg", off) or "heading unknown"))
				st.lineupTries = nil
				local again = st.alignTo
				st.alignTo, st.alignPicked, st.alignAim = nil, nil, nil
				startLeg(st, t)
				if again then st.recover = true end
			end
			return false
		end

		if st.phase == "leg" then
			local s, perp, seg = project(st, v:getX(), v:getY())
			st.s, st.seg = s, seg
			if st.respawnS and s > st.respawnS + 50 then st.stuckRun, st.respawnS = 0, nil end
			if st.ipPending and s > st.ipPending + K.INPLACE_SPAN then
				st.inPlaceOk, st.ipPending = (st.inPlaceOk or 0) + 1, nil
				T.trace(string.format("drivefast: recovered in place (%.0f tiles on)", K.INPLACE_SPAN))
			end
			local jamAt = K.jamAhead(st, s)
			local jamNow = jamAt ~= nil and jamAt <= s + 0.5
			if jamNow and not st.inJam then
				st.inJam = true
				st.jams = (st.jams or 0) + 1
				T.trace(string.format("drivefast: wreck jam at %.0f,%.0f; crawling at %d km/h to %.0f tiles", v:getX(), v:getY(), K.JAM_KMH, st.jamUntil or s))
			elseif not jamNow and st.inJam then
				st.inJam = nil
				T.trace(string.format("drivefast: out of the jam at %.0f,%.0f", v:getX(), v:getY()))
			end
			if st.inJam then
				local sec = math.min(dt, 100) / 1000
				st.jamT, st.jamTiles = (st.jamT or 0) + sec, (st.jamTiles or 0) + st.tps * sec
			end
			local stopS = nextStop(st, s)
			local remaining = stopS - s
			if r.plan.obstacles ~= "avoid" then pcall(clearAhead, st, s); pcall(K.recheckAhead, st, s, t)
			else pcall(K.recheckAhead, st, s, t, true) end
			local pMin, pMax = K.tune(st, "FAST_PURSUIT_MIN"), K.tune(st, "FAST_PURSUIT_MAX")
			local look = math.min(math.max(pMin, math.min(pMax, st.tps * K.tune(st, "FAST_PURSUIT_S"))), math.max(4, remaining - 2))
			if st.offRamp then
				local f = math.min(1, (t - st.offRamp.t0) / K.tune(st, "REANCHOR_RAMP_MS"))
				st.off = st.offRamp.from + (st.offRamp.to - st.offRamp.from) * f
				if f >= 1 then
					st.offRamp = nil
					-- 1.13.19 (review of 1.13.18): the leg's grace starts again where the ease-in ends, so a
					-- long jump at speed isn't cut before the car has followed it
					st.legLat0, st.legS0 = math.abs(perp - st.off), s
				end
			end
			local lateral = math.abs(perp - st.off)
			local soft, hard, back = K.latLimits(K.laneWidth(st))
			if st.width and t >= (st.nextOnStreet or 0) then
				st.nextOnStreet = t + FAST_STEER_MS
				local okS, on = pcall(function() return isStreetSq(getCell():getGridSquare(floor(v:getX()), floor(v:getY()), st.z)) end)
				local wasOff = st.offStreet
				st.offStreet = okS and on == false
				-- 1.13.11 (1.13.10 drive_fast and drive_human on the diagonal from 10681,8764: "stuck off the
				-- street, 0.3 off the centre" 7 times, the followed centre walked 5 to 10 tiles off the
				-- street): off the street while on the followed centre means the centre is wrong; take the
				-- street run nearest it across the path, at most once a second
				-- (not within K.REANCHOR_BEND tiles of a bend, where the row across the path can cut the
				-- street's other leg; only a run at least K.REANCHOR_W of the lane wide, K.REANCHOR_MAX away)
				-- (1.13.12, review of 1.13.11: nor just past one, and on a divided road never onto the
				-- other carriageway, left of the line)
				local bR = nextBend(st, s, stopS)
				local segS = st.cum[segAt(st, s)] or 0
				local nearBend = (bR and bR.s - s < K.REANCHOR_BEND) or (segAt(st, s) > 1 and s - segS < K.REANCHOR_AFTER)
				-- (1.13.17, 1.13.14 drive_fast at 10606,8829, 32 tiles before the diagonal's last bend: the centre
				-- past the bend was already read, a re-anchor still jumped 5.2 tiles at 81 km/h, three spins and a
				-- fresh car followed: none while the centre past the next bend is waiting, and a jump is eased in
				-- over K.REANCHOR_RAMP_MS)
				if st.offStreet and lateral < back and K.tune(st, "REANCHOR") and t >= (st.reanchorT or 0) and not nearBend
					and not (st.offNextS and K.tune(st, "BEND_OFF")) then
					st.reanchorT = t + 1000
					local okR, runs = pcall(K.streetRuns, st, s + 2, floor((st.width or 8) / 2) + 8)
					local best, bd = nil, 1e9
					local minW = math.max(4, K.REANCHOR_W * (K.laneWidth(st) or 8))
					-- 1.13.13 (review of 1.13.12): divided or not is read here, where the car is, not kept from the spawn
					local okD, dc = pcall(K.pickCarriageway, st, s + 2)
					st.dividedRight = okD and dc ~= nil
					for _, rn in ipairs(okR and runs or {}) do
						if rn.w >= minW and not (st.dividedRight and rn.c < 0) and math.abs(rn.c - st.off) < bd then best, bd = rn, math.abs(rn.c - st.off) end
					end
					if best and bd >= 1 and bd <= K.REANCHOR_MAX then
						T.trace(string.format("drivefast: off the street on the followed centre at %.0f,%.0f; centre moved %.1f -> %.1f tiles off the line (the street run there is %d wide)",
							v:getX(), v:getY(), st.off, best.c, best.w))
						if K.tune(st, "REANCHOR_RAMP_MS") > 0 and math.abs(best.c - st.off) > 1.5 then
							st.offRamp = { from = st.off, to = best.c, t0 = t }
						else
							st.off = best.c
						end
						st.laneW = best.w
						st.reanchors = (st.reanchors or 0) + 1
						lateral = math.abs(perp - st.off)
						-- 1.13.18 (review of 1.13.17): measured against where the centre is going, not where the
						-- ease-in starts, so the centre easing across does not read as the car drifting
						st.legLat0, st.legS0 = math.abs(perp - best.c), s   -- the leg's grace again: the car is where it was, the line moved
					end
				end
				if st.offStreet and not wasOff then st.offStreetN = (st.offStreetN or 0) + 1 end
				-- and 3 tiles ahead along the heading, so the drift is caught before the wheels leave the street
				-- (1.13.10: K.AHEAD_S seconds ahead at speed, up to K.AHEAD_MAX tiles; 3 tiles at 120 km/h
				-- was a tenth of a second)
				local hA = carHeading(st)
				local ahead = math.max(3, math.min(K.AHEAD_MAX, st.tps * K.tune(st, "AHEAD_S")))
				if not st.offStreet and hA and remaining > 10 then
					local okA, onA = pcall(function()
						return isStreetSq(getCell():getGridSquare(floor(v:getX() + math.cos(hA) * ahead), floor(v:getY() + math.sin(hA) * ahead), st.z))
					end)
					st.offAhead = okA and onA == false
				else
					st.offAhead = nil
				end
			end
			-- a swerve round something on the road is meant: the limits widen by its size
			local latAim = lateral
			if (st.dodge or 0) ~= 0 then
				local dg = math.abs(st.dodge)
				soft, hard = soft + dg, hard + dg
			end
			st.recLat, st.recSoft, st.recHard, st.recBack = latAim, soft, hard, back
			if inPhase >= 1100 then
				if not st.recover and (latAim > soft or ((st.offStreet or st.offAhead) and latAim > back)) then
					st.recover = true
					st.steerBacks = (st.steerBacks or 0) + 1
					T.trace(string.format("drivefast: drifting %.1f tiles off the centre at %.0f,%.0f%s at %.0f km/h; steering back (slower: to %d km/h past %.1f tiles or off the street%s)",
						latAim, v:getX(), v:getY(), st.offStreet and " (off the street)" or (st.offAhead and " (heading off the street)" or ""), st.tps * 3.6, K.FAST_RECOVER_KMH, (soft + hard) / 2,
						K.tune(st, "RECOVER_SHARE") > 0 and string.format(", else to %.0f%% of the cruise", 100 * K.tune(st, "RECOVER_SHARE")) or ""))
				elseif st.recover and latAim < back and not st.offStreet then
					st.recover, st.recCentreT = nil, nil
					T.trace(string.format("drivefast: back on the centre at %.0f,%.0f", v:getX(), v:getY()))
				elseif st.recover and latAim < back then
					-- 1.13.10: on the centre line where the squares aren't marked street (a bridge, a bend
					-- the map's street squares don't cover): 1.13.9 stayed at 40 km/h for the rest of the
					-- leg (the mock's bend: 40 s); on the centre for K.RECOVER_CENTRE_MS ends it too
					st.recCentreT = st.recCentreT or t
					if t - st.recCentreT >= K.tune(st, "RECOVER_CENTRE_MS") then
						st.recover, st.recCentreT = nil, nil
						st.recUnmarked = (st.recUnmarked or 0) + 1
						T.trace(string.format("drivefast: back on the centre at %.0f,%.0f (the squares here aren't marked street)", v:getX(), v:getY()))
					end
				elseif st.recover then
					st.recCentreT = nil
				end
			end
			local bAhead = nextBend(st, s, stopS)
			if bAhead and bAhead.roll and not bAhead.checked and bAhead.s - s < 60 then
				-- a corner to drive through: a junction (the street there much wider) is still a stop
				local okJ, cJ, wJ = pcall(streetCentre, st, bAhead.s)
				if okJ and cJ then
					bAhead.checked = true
					if st.width and wJ > st.width + 6 then
						bAhead.stop = true
						table.insert(st.stops, bAhead.s)
						table.sort(st.stops)
						st.rollJunctions = (st.rollJunctions or 0) + 1
						T.trace(string.format("drivefast: the %.0f deg corner at %.0f tiles is a junction (%d wide); stopping for it", bAhead.deg, bAhead.s, wJ))
						stopS = nextStop(st, s)
						remaining = stopS - s
						bAhead = nextBend(st, s, stopS)
					end
				end
			end
			local nearRoll = bAhead and bAhead.roll and bAhead.s - s < look + 6
			if K.tune(st, "LOOK_OLD") then   -- 1.13.13 (review of 1.13.12): drive_old exactly as 1.13.9 had it
				if st.recover then look = math.min(look, pMin)
				elseif nearRoll then look = pMin
				elseif bAhead and bAhead.s - s < look + 6 and look > pMin then look = math.max(pMin, look * K.FAST_BEND_LOOK) end
			elseif nearRoll then look = math.min(look, K.FAST_ROLL_LOOK)
			elseif st.recover then look = math.min(look, math.max(pMin, look * K.tune(st, "RECOVER_LOOK")))
			elseif bAhead and bAhead.s - s < look + 6 and look > pMin then
				look = math.max(pMin, look * K.FAST_BEND_LOOK)
			end
			st.nearRoll = nearRoll
			-- 1.13.14 (1.13.11 mod:drive, 3 of the 8 fresh cars, on the diagonal from 10681,8764 to
			-- 10592,8858): the followed centre is an offset from the map's line, and the offset can change
			-- at a bend (5.0 tiles before the diagonal, 10.7 on it, 5.0 after it). The old one carried
			-- past the bend aimed the car off the street. Now the centre past the next bend is read
			-- K.BEND_OFF_AT tiles past it (once loaded), the aim takes it past the bend, and the car takes
			-- it at the bend.
			if K.tune(st, "BEND_OFF") then
				if bAhead and bAhead.s > s and bAhead.s - s < look + 15 and st.offNextS ~= bAhead.s and t >= (st.offTryT or 0) then
					st.offTryT = t + FAST_STEER_MS
					local sN = math.min(st.total - 1, bAhead.s + K.BEND_OFF_AT)
					-- 1.13.15 (review of 1.13.14): with another bend within K.BEND_OFF_AT, read short of it
					local b2 = nextBend(st, bAhead.s + 7, st.total)
					if b2 and b2.s - 3 < sN then sN = math.max(bAhead.s + 4, b2.s - 3) end
					local val, how
					local okP, pc = pcall(K.pickCarriageway, st, sN)
					if okP and pc then val, how = pc, "a divided street"
					else
						local okC, c, w = pcall(streetCentre, st, sN)
						if okC and c and w >= 3 and w <= (st.width or w) + 3 then val, how = c, string.format("%d wide", w) end
					end
					-- 1.13.19 (review of 1.13.18): against where an ease-in is going, not its middle
					if val and math.abs(val - (st.offRamp and st.offRamp.to or st.off)) <= K.BEND_OFF_MAX then
						st.offNextS, st.offNext = bAhead.s, val
						if math.abs(val - st.off) >= 1 then
							T.trace(string.format("drivefast: past the bend at %.0f tiles the centre is %.1f tiles off the line (%.1f before it; %s)", bAhead.s, val, st.off, how))
						end
					end
				end
				if st.offNextS and s >= st.offNextS then
					-- 1.13.18 (review of 1.13.17): a running ease-in would overwrite the bend's centre
					st.offRamp = nil
					if st.offNext and math.abs(st.offNext - st.off) >= 0.5 then
						st.off = st.offNext
						st.bendOffs = (st.bendOffs or 0) + 1
						lateral = math.abs(perp - st.off)
						st.legLat0, st.legS0 = lateral, s   -- the line moved, not the car
					end
					st.offNextS, st.offNext = nil, nil
				end
			end
			if t >= (st.nextSteer or 0) and inPhase >= 1100 then
				-- where the street really is a little way ahead (streets.xml centre lines can be a tile
				-- or two off); a row much wider than the street is a junction or a car park: ignore it
				st.nextSteer = t + FAST_STEER_MS
				local okC, c, w = pcall(streetCentre, st, s + look)
				if not (st.offNextS and s + look > st.offNextS) and okC and c and w >= 3 and w <= (st.width or w) + 3 and math.abs(c - st.off) <= 2 then
					st.off = st.off * 0.7 + c * 0.3
					st.laneW = st.laneW and (st.laneW * 0.7 + w * 0.3) or w
				end
				if r.plan.obstacles == "avoid" then
					local okD, dodge, why = pcall(K.dodge, st, s, v)
					if okD then
						if dodge ~= (st.dodge or 0) then
							T.trace(string.format("drivefast: %s, steering %+d tiles off the centre at %.0f,%.0f", why, dodge, v:getX(), v:getY()))
							if dodge ~= 0 then st.dodges = (st.dodges or 0) + 1 end
						end
						st.dodge = dodge
						st.blockedAhead = (why == "no way round") and (st.blockedAhead or s) or nil
					end
				elseif K.tune(st, "SOLID_DODGE") and t >= (st.dodgeScanT or 0) then
					-- 1.13.15 (review of 1.13.14: 3 to 6 ms/s cruising): every K.DODGE_IDLE_MS while the road is clear
					local okD, dodge = pcall(K.solidDodge, st, s, v)
					st.dodgeScanT = (okD and dodge == 0 and not st.dodgeHold) and (t + K.DODGE_IDLE_MS) or 0
					if okD and dodge ~= (st.dodge or 0) then
						T.trace(string.format("drivefast: %s, steering %+d tiles off the centre at %.0f,%.0f", dodge ~= 0 and "something solid on the road ahead" or "road clear", dodge, v:getX(), v:getY()))
						if dodge ~= 0 then st.dodges = (st.dodges or 0) + 1 end
						st.dodge = dodge
					end
				end
			end
			if st.tpAt and t - st.tpAt >= 300 then
				st.tpNotes = (st.tpNotes or 0) + 1
				T.trace(string.format("drivefast: setAngles turn at %.1f tiles/s, %.1f tiles/s 0.3 s later", st.tpBefore or 0, st.tps))
				st.tpAt = nil
			end
			local mode = st.steerMode or r.plan.steer or "torque"
			if inPhase >= 1100 and st.tps > 3 and mode == "torque" then
				local h = carHeading(st)
				if h then
					local px, py = pointAt(st, s + look, K.offAt(st, s + look) + (st.dodge or 0))
					local aimDir = atan2(py - v:getY(), px - v:getX())
					local rx, ry = segDir(st, segAt(st, s + look))
					local roadDir = atan2(ry, rx)
					local lim = (nearRoll and 45 or K.APPROACH_DEG) * math.pi / 180
					local want = roadDir + math.max(-lim, math.min(lim, wrapAngle(aimDir - roadDir)))
					local a = wrapAngle(want - h)
					local rate = K.wantedRate(st.tps, a, look, nearRoll)
					K.torqueSteer(st, v, h, rate * 180 / math.pi, t, dt)
					if r.plan.driveview then
						K.driveView(st, v, s, look, { h = h, road = roadDir, aimDir = aimDir, want = want, rate = rate, px = px, py = py,
							lat = perp - st.off, soft = soft, hard = hard, back = back })
					end
				end
			elseif inPhase >= 1100 and st.tps > 3 then
				local h = carHeading(st)
				if h then K.steerCheck(st, h) end
				if h and mode == "pursuit" then
					-- 1.9.0, pure pursuit: aim at the centre line `look` tiles ahead; the turn rate that puts
					-- the car on an arc through that point is 2 v sin(a) / look. setAngles ignores changes
					-- under a degree, so the turn is added up and applied a whole degree at a time.
					local px, py = pointAt(st, s + look, K.offAt(st, s + look) + (st.dodge or 0))
					local a = wrapAngle(atan2(py - v:getY(), px - v:getX()) - h)
					local rate = 2 * st.tps * math.sin(a) / look
					rate = math.max(-K.FAST_TURN_MAX, math.min(K.FAST_TURN_MAX, rate))
					st.turnAcc = (st.turnAcc or 0) + rate * math.min(dt, 100) / 1000 * 180 / math.pi
					if math.abs(st.turnAcc) >= 1 then
						local deg = st.turnAcc >= 0 and floor(st.turnAcc) or -floor(-st.turnAcc)
						st.turnAcc = st.turnAcc - deg
						K.steerBy(st, v, h, deg)
					end
				elseif h and t >= (st.nextNudge or 0) then
					-- default (1.12.3), 1.8.0's steering: every 300 ms at most 2 whole degrees towards the centre
					-- line 20+ tiles ahead. Every setAngles is a Bullet.teleportVehicle (BaseVehicle.
					-- setWorldTransform); pursuit called it several times a second and the 1.11.1 car never
					-- got past 4 tiles/s with cruise at 120, while 1.8.0 (this steering) reached 123 km/h.
					st.nextNudge = t + FAST_STEER_MS
					local la = math.min(math.max(20, st.tps * 1.2), math.max(4, remaining - 2))
					local px, py = pointAt(st, s + la, K.offAt(st, s + la) + (st.dodge or 0))
					local err = wrapAngle(atan2(py - v:getY(), px - v:getX()) - h) * 180 / math.pi
					if math.abs(err) >= 1 then
						K.steerBy(st, v, h, math.max(-2, math.min(2, err >= 0 and floor(err + 0.5) or -floor(-err + 0.5))))
					end
				end
			end
			-- 1.13.8 (review of 18 Oct): the drive view after torque steering hands over to nudges or pursuit
			if r.plan.driveview and mode ~= "torque" and inPhase >= 1100 and st.tps > 3 then
				local h = carHeading(st)
				if h then
					local px, py = pointAt(st, s + look, K.offAt(st, s + look) + (st.dodge or 0))
					local rx, ry = segDir(st, segAt(st, s + look))
					local aimDir = atan2(py - v:getY(), px - v:getX())
					K.driveView(st, v, s, look, { h = h, road = atan2(ry, rx), aimDir = aimDir, want = aimDir, rate = 0, px = px, py = py,
						lat = perp - st.off, soft = soft, hard = hard, back = back, mode = mode })
				end
			end
			if t >= (st.nextLegNote or 0) and inPhase >= 1100 then
				st.nextLegNote = t + 1000
				local h = carHeading(st)
				local ux, uy = segDir(st, seg)
				T.trace(string.format("drivefast: steer %s, %.0f km/h, %.1f off the centre, heading %s off the road, %s",
					mode, st.tps * 3.6, perp - st.off,
					h and string.format("%+.1f deg", wrapAngle(h - atan2(uy, ux)) * 180 / math.pi) or "?",
					mode == "torque" and string.format("turning %+.1f deg/s, push %+.0f (built-up %+.0f, gain %.3g)", st.tqW or 0, st.tqM or 0, st.tqI or 0, st.tqGain or K.TQ_GAIN0)
						or string.format("sign %+d (%d right, %d wrong)", st.moveSign or st.alignSign, st.signRight or 0, st.signWrong or 0)))
			end
			-- 1.12.10: which side the car keeps to (positive perp is the car's right; the user saw it drift left)
			if inPhase >= 1100 and st.tps > 3 then
				local sd = (perp - st.off) * math.min(dt, 100) / 1000
				st.sideSum, st.sideT = (st.sideSum or 0) + sd, (st.sideT or 0) + math.min(dt, 100) / 1000
				if perp - st.off < -1 then st.leftT = (st.leftT or 0) + math.min(dt, 100) / 1000 end
				if perp - st.off > 1 then st.rightT = (st.rightT or 0) + math.min(dt, 100) / 1000 end
			end
			if lateral > st.maxLateral0 then st.maxLateral0 = lateral end
			st.tiles = st.tiles + st.tps * math.min(dt, 100) / 1000
			-- 1.13.10: the time in the car, for the average speed (stops, steer-backs and jams count)
			st.carSec = (st.carSec or 0) + math.min(dt, 100) / 1000
			if st.tps > 3 then st.moveSec, st.moveTiles = (st.moveSec or 0) + math.min(dt, 100) / 1000, (st.moveTiles or 0) + st.tps * math.min(dt, 100) / 1000 end
			-- setForceBrake holds the brake for 1 s and a braking car drops its cruise control, so wait
			-- that out, then keep the cruise control on (cheap, and nothing else turns it back on)
			if inPhase >= 1100 then
				if st.tps > st.legPeak then st.legPeak = st.tps end
				local kmh = st.slow and K.FAST_CORNER_KMH or st.kmh
				if st.recover then
					local share = K.tune(st, "RECOVER_SHARE")
					local far = share <= 0 or (st.offStreet and (st.recLat or 0) > (st.recBack or 0)) or (st.recLat or 0) > ((st.recSoft or 0) + (st.recHard or 0)) / 2
					local cap = far and K.FAST_RECOVER_KMH or math.max(K.FAST_RECOVER_KMH, (kmh or K.FAST_RECOVER_KMH) * share)
					kmh = math.min(kmh or 999, cap)
					if st.tps * 3.6 > cap * K.tune(st, "RECOVER_BRAKE_OVER") and t >= (st.bendBrakeT or 0) then
						st.bendBrakeT = t + 1100
						pcall(function() v:setForceBrake() end)
					end
				end
				-- 1.13.14: going round something on the road: K.DODGE_KMH until on the line round it
				if st.dodgeHold and (st.dodge or 0) ~= 0 and math.abs(perp - st.off - st.dodge) > 1 then
					kmh = math.min(kmh or 999, K.DODGE_KMH)
					if st.tps * 3.6 > K.DODGE_KMH * 1.35 and t >= (st.bendBrakeT or 0) then
						st.bendBrakeT = t + 1100
						pcall(function() v:setForceBrake() end)
					end
				end
				-- a bend taken on the move: slow to its speed in time (brake in 1 s bursts), back up after
				local b, vb = nextBend(st, s, stopS)
				if b and not st.slow then
					local need = (st.tps * st.tps - vb * vb) / (2 * FAST_DECEL) + 8
					if b.s - s <= need then
						kmh = math.min(kmh or 999, vb * 3.6)
						if st.tps > vb * 1.1 and t >= (st.bendBrakeT or 0) then
							st.bendBrakeT = t + 1100
							pcall(function() v:setForceBrake() end)
						end
						if st.bendAt ~= b then
							st.bendAt = b
							if b.roll then st.rollsTaken = (st.rollsTaken or 0) + 1 else st.bendsTaken = (st.bendsTaken or 0) + 1 end
						end
					end
				end
				if jamAt and not st.slow then
					local vj = K.JAM_KMH / 3.6
					local need = (st.tps * st.tps - vj * vj) / (2 * FAST_DECEL) + 8
					if jamAt - s <= need then
						kmh = math.min(kmh or 999, K.JAM_KMH)
						if st.tps > vj * 1.15 and t >= (st.bendBrakeT or 0) then
							st.bendBrakeT = t + 1100
							pcall(function() v:setForceBrake() end)
						end
					end
				end
				if t >= (st.bendBrakeT or 0) then
					pcall(function() v:setRegulatorSpeed(kmh); v:setRegulator(true) end)
				end
				st.gasT0 = st.gasT0 or t
				if st.tps >= 0.8 or not st.movedT then st.movedT = st.tps >= 0.8 and t or (st.movedT or t) end
			end
			local function where() return string.format("%.0f,%.0f", v:getX(), v:getY()) end
			local fast = math.max(st.peakKmh, st.peakTps * 3.6) >= FAST_MIN_KMH
			if inPhase >= 1100 and t - st.movedT > FAST_STUCK_MS then
				-- stuck: a fresh car further on, a few times, before giving up on the car
				local at = where()
				local hS = carHeading(st)
				local uxS, uyS = segDir(st, seg)
				T.trace(string.format("drivefast: stuck%s, %.1f off the centre (street %s wide, its centre %.1f off the line), heading %s off the road; in front of the car: %s",
					st.offStreet and " off the street" or "", lateral, tostring(st.width), st.off,
					hS and string.format("%+.0f deg", wrapAngle(hS - atan2(uyS, uxS)) * 180 / math.pi) or "?", K.whatsAhead(st, v)))
				-- 1.12.8: each fresh car in a row goes further on (15, 30, 60, 120 tiles), so one long
				-- blockage (1.12.7: stuck at 10618,8836 three times 15 tiles apart) is got past.
				-- 1.12.10: a car stuck off the street ran off the road, nothing blocks it: the fresh
				-- car goes on the centre just 3 tiles on
				-- 1.13.11 (1.13.10 drive_human at 10587,9541: three tries against road works): a car on
				-- the street with something solid right in front goes straight to a fresh car further on
				local solidAhead = false
				if not st.offStreet and hS and lateral < back and K.tune(st, "SOLID_SKIP") then   -- 1.13.12: on the centre, not a kerb at the edge
					for d = 1, 3 do
						-- 1.13.14: a car's width, and K.blocker (1.13.11 drive_human: road works at the front corner weren't seen)
						for k = (K.tune(st, "SOLID_DODGE") and -1 or 0), (K.tune(st, "SOLID_DODGE") and 1 or 0) do
							local okB, b = pcall(function()
								local x, y = v:getX() + math.cos(hS) * d - math.sin(hS) * k, v:getY() + math.sin(hS) * d + math.cos(hS) * k
								local sq = getCell():getGridSquare(floor(x), floor(y), st.z)
								return K.tune(st, "SOLID_DODGE") and K.blocker(sq, v) or blockedSq(sq, v)
							end)
							if okB and b then solidAhead = true; break end
						end
						if solidAhead then break end
					end
				end
				-- 1.13.14: with something solid in front the try aims clear of it (the align phase), so it gets one
				if (not solidAhead or K.tune(st, "ALIGN_CLEAR")) and K.inPlaceTry(st, s, solidAhead and "stuck, something solid in front" or "stuck", perp) then
					st.recover = nil
					pcall(function() v:setRegulator(false) end)
					fastPhase(st, t, "align")
					return false
				end
				local skip = (st.offStreet or lateral > soft) and not solidAhead and 3 or K.FAST_RESPAWN_SKIP * 2 ^ st.stuckRun
				if st.stuckRun < K.FAST_RESPAWNS and s + skip < st.total - FAST_INSET - 10 then
					if solidAhead then st.solidSkips = (st.solidSkips or 0) + 1 end   -- 1.13.15: fresh cars only, not tries
					st.respawns, st.stuckRun = st.respawns + 1, st.stuckRun + 1
					st.respawnS = s + skip
					st.recover = nil
					T.trace(string.format("drivefast: car stuck at %s on leg %d; a fresh car %d tiles further on (%d in a row, up to %d)",
						at, st.legs, skip, st.stuckRun, K.FAST_RESPAWNS))
					Steps.drivefast.spawn(r, st, s + skip)
					return false
				end
				fastFallback(r, st, string.format("car stuck at %s on leg %d after %d fresh cars in a row (peak %.0f km/h): blocked by something on the road",
					at, st.legs, st.stuckRun, st.peakKmh)); return false
			end
			if st.legs == 1 and not fast and not st.slow and st.gasT0 and t - st.gasT0 > FAST_MIN_MS then
				fastFallback(r, st, string.format("car reached only %.0f km/h in %d s (needs %d)", st.peakKmh, FAST_MIN_MS / 1000, FAST_MIN_KMH)); return false
			end
			if st.blockedAhead and st.dodgeBlockS then
				-- blocked right across the street: stop short of it like at a road end
				remaining = math.min(remaining, st.dodgeBlockS - s - 6)
			end
			local brakeAt = st.tps * st.tps / (2 * FAST_DECEL) + (st.slow and 2 or FAST_MARGIN)
			local latMax = hard
			-- 1.13.6: a leg that starts off the centre (after the creep, or a fresh car) gets K.LEG_GRACE
			-- tiles to come back before the cut counts from where it started
			if not st.legLat0 then st.legLat0, st.legS0 = lateral, s end
			if s < st.legS0 + K.LEG_GRACE then latMax = math.max(hard, st.legLat0 + 1) end
			local why = nil
			if remaining <= brakeAt then why = (stopS >= st.total - 0.5) and "end of road" or "corner"
			elseif st.ipLat and lateral <= latMax then st.ipLat = nil
			elseif lateral > latMax and not (st.ipLat and lateral < st.ipLat + 1) then why = string.format("drifted %.1f tiles off the street's centre", lateral)
			elseif el >= (st.seconds - 4) * 1000 then why = "time up" end
			-- (1.13.6: not for a drift: run 2 glided the whole drive after leg 1 drifted at 41 km/h)
			if why and st.legs == 1 and not fast and why ~= "corner" and not why:find("^drifted") and not st.slow then
				fastFallback(r, st, string.format("leg 1 ended (%s) at only %.0f km/h; the road is too short to reach %d", why, st.peakKmh, FAST_MIN_KMH))
				return false
			end
			if t >= (st.nextTrace or 0) then
				st.nextTrace = t + 500
				T.trace(string.format("drivefast: leg %d %.1f tiles/s, %.0f of %.0f tiles, %.0f to the next stop, %.1f off the centre",
					st.legs, st.tps, s, st.total, remaining, lateral))
			end
			if why then
				T.trace(string.format("drivefast: leg %d braking (%s) at %.1f tiles/s", st.legs, why, st.tps))
				if not st.slow and st.maxKmh and st.legPeak * 3.6 >= st.maxKmh * FAST_TOP_SHARE then st.topLegs = st.topLegs + 1 end
				if why == "corner" then
					if not st.slow then st.corners = st.corners + 1 end
					st.cornerS = stopS
					st.after = "corner"
				elseif why == "end of road" then
					st.passes = st.passes + 1
					st.after = (el < (st.seconds - K.FAST_UTURN_MIN_S) * 1000) and "uturn" or "done"
				elseif why == "time up" then
					st.after = "done"
				else
					st.cut = (st.cut or 0) + 1
					st.after = "recentre"
				end
				fastPhase(st, t, "stop")
			end
			return false
		end
		if el >= st.seconds * 3000 then return Steps.drivefast.finishCar(r, st) end
		return false
	end,
	finishCar = function(r, st)
		local name = st.carName or "car"
		st.extraLines = { K.driveLine(st) }
		fastCleanup(r, st)
		r.cleanup = nil
		local home = r.plan.start or r.home
		teleport(r.p, home.x, home.y, home.z)
		st.result = string.format("%sreal car %s, %d legs, %.0f tiles, peak %.1f tiles/s (%.0f km/h at 1 tile = 1 m), dashboard peak %.0f km/h, cruise %s km/h, %s, %d corners, %d turned back, %d fresh cars after getting stuck%s%s%s",
			st.roadName and string.format("%s (%.0f-tile road from the map%s), ", st.roadName, st.roadLen,
				st.loadMs and string.format(", loaded in %.1f s", st.loadMs / 1000) or "") or "",
			name, st.legs, st.tiles, st.peakTps, st.peakTps * 3.6, st.peakKmh, tostring(st.kmh),
			(st.maxKmh and st.maxKmh > 0) and string.format("top speed %s (%d of %d legs at %d%%+ of %.0f km/h), %d steering nudges, %d vehicles cleared off the road",
				(st.topLegs > 0) and "REACHED" or "not reached", st.topLegs, st.legs, FAST_TOP_SHARE * 100, st.maxKmh, st.steers, st.wrecks) or
				string.format("%d steering nudges, %d vehicles cleared off the road", st.steers, st.wrecks),
			st.corners, st.uturns, st.respawns,
			string.format(", %d bends taken on the move", st.bendsTaken or 0) ..
			((r.plan.obstacles == "avoid" or (st.dodges or 0) > 0) and string.format(", obstacles avoided by steering (%d swerves)", st.dodges or 0) or "") .. (st.cut and string.format(", %d legs cut short", st.cut) or "") ..
				(st.steerBacks and string.format(", %d times steered back from the edge", st.steerBacks) or ""),
			string.format(", up to %.1f tiles off the street's centre", st.maxLateral0) ..
				((st.sideT or 0) > 0 and string.format(" (on average %.2f tiles to its %s; over a tile left %.0f s, right %.0f s)",
					math.abs(st.sideSum / st.sideT), st.sideSum < 0 and "left" or "right", st.leftT or 0, st.rightT or 0) or "") ..
				(st.lateWrecks and string.format(", %d late-loaded vehicles cleared, %d removed again", st.lateWrecks, st.stillThere or 0) or "") ..
				K.jamCounts(st) ..
				(st.tqTicks and string.format(", torque steering on %d ticks (peak push %.0f, cap %.0f, gain %.3g, %d spins, %d knocks)%s", st.tqTicks, st.tqPeak or 0, st.tqMax or K.TQ_MAX0, st.tqGain or K.TQ_GAIN0, st.tqSpins or 0, st.tqKnocks or 0, st.steerMode == "nudge" and ", HANDED BACK TO NUDGES" or "") or ""),
			st.alignFailed and ", COULD NOT LINE UP " .. st.alignFailed .. " times" or "")
		return true
	end,
}

-- fight N S: back at the start, N zombies are spawned in a fixed ring (8 to 14 tiles out) and
-- come at you. You stand your ground in god mode; every so often the nearest zombie within 2.5
-- tiles is put down (health 0), paced so all N could go down in about 70% of S. After S seconds
-- the ones still standing are removed. The world's own zombies are kept away during the step.
local FIGHT_REACH2 = 2.5 * 2.5

TG.FAST_ALIGN_TOL, TG.FAST_CARS, TG.FAST_CLEAR_AHEAD, TG.FAST_DECEL, TG.FAST_GLIDE_DEFAULT, TG.FAST_INSET = FAST_ALIGN_TOL, FAST_CARS, FAST_CLEAR_AHEAD, FAST_DECEL, FAST_GLIDE_DEFAULT, FAST_INSET
TG.FAST_LATERAL_MAX, TG.FAST_LOAD_MS, TG.FAST_MARGIN, TG.FAST_MIN_KMH, TG.FAST_MIN_MS, TG.FAST_STEER_MS = FAST_LATERAL_MAX, FAST_LOAD_MS, FAST_MARGIN, FAST_MIN_KMH, FAST_MIN_MS, FAST_STEER_MS
TG.FAST_STUCK_MS, TG.FAST_TOP_SHARE, TG.FIGHT_REACH2, TG.FWD_MAPS, TG.atan2, TG.axisDir = FAST_STUCK_MS, FAST_TOP_SHARE, FIGHT_REACH2, FWD_MAPS, atan2, axisDir
TG.blockedSq, TG.buildPath, TG.carForward, TG.carHeading, TG.clearAhead, TG.fastAlign = blockedSq, buildPath, carForward, carHeading, clearAhead, fastAlign
TG.fastCleanup, TG.fastFallback, TG.fastMeasure, TG.fastPhase, TG.glideTick, TG.isStreetSq = fastCleanup, fastFallback, fastMeasure, fastPhase, glideTick, isStreetSq
TG.nextBend, TG.nextStop, TG.pointAt, TG.probeSign, TG.project, TG.readyCar = nextBend, nextStop, pointAt, probeSign, project, readyCar
TG.reversePath, TG.segAt, TG.segDir, TG.spawnFastCar, TG.startLeg, TG.streetCentre = reversePath, segAt, segDir, spawnFastCar, startLeg, streetCentre
TG.wrapAngle = wrapAngle

-- 1.13.4: the drive view (plan "driveview = 1"): what the steering sees, drawn over the game for
-- screenshots. Street squares round the car (green), the centre line (yellow), the soft and hard
-- limits either side (amber, red), the aim point (magenta), the car's heading (cyan) and the road's
-- direction (white) as dotted rays from the car, and a text panel with the numbers. The street
-- squares are looked up every K.DV_TILES_MS; the rest is from the steering's last tick.
-- 1.13.8 (the user: the squares should reach further at speed, where turning is harder): the street
-- squares are looked up along the path from K.DV_BACK tiles behind to the aim point (which is 0.9 s
-- ahead, so it grows with speed) and K.DV_SIDE tiles past the street either side, every K.DV_TILES_MS
-- (1.13.4: within 9 tiles of the car every 500 ms, so at 120 km/h they lagged 15 tiles behind)
K.DV_BACK, K.DV_SIDE, K.DV_TILES_MS = 6, 3, 200
function K.driveView(st, v, s, look, d)
	local t = now()
	d.x, d.y, d.z, d.s, d.look, d.t = v:getX(), v:getY(), st.z or 0, s, look, t
	d.kmh, d.push, d.turn, d.gain, d.width, d.recover = st.tps * 3.6, st.tqCounter or st.tqM or 0, st.tqW or 0, st.tqGain or K.TQ_GAIN0, K.laneWidth(st), st.recover
	d.roadW, d.counter = st.width, st.tqCounter
	local old = st.dv
	if old and old.tiles and t - (old.tilesT or 0) < K.DV_TILES_MS then
		d.tiles, d.tilesT = old.tiles, old.tilesT
	else
		local tiles, seen = {}, {}
		local cell = getCell()
		local hw = (st.width or 8) / 2 + K.DV_SIDE
		for k = -K.DV_BACK, look + 2 do
			for c = -hw, hw do
				local ok, x, y = pcall(pointAt, st, s + k, c)
				if ok then
					local tx, ty = floor(x), floor(y)
					local key = tx * 100000 + ty
					if not seen[key] then
						seen[key] = true
						local okS, on = pcall(function() return isStreetSq(cell:getGridSquare(tx, ty, d.z)) end)
						if okS and on then tiles[#tiles + 1] = { tx + 0.5, ty + 0.5 } end
					end
				end
			end
		end
		d.tiles, d.tilesT = tiles, t
	end
	-- the centre line and the limits, from a little behind the car to the aim point
	local lines = { centre = {}, softL = {}, softR = {}, hardL = {}, hardR = {} }
	for k = -K.DV_BACK, look, 1.5 do
		local function at(off) local ok, x, y = pcall(pointAt, st, s + k, off); if ok then return { x, y } end end
		local c = st.off + (st.dodge or 0)
		lines.centre[#lines.centre + 1] = at(c)
		lines.softL[#lines.softL + 1], lines.softR[#lines.softR + 1] = at(c - d.soft), at(c + d.soft)
		lines.hardL[#lines.hardL + 1], lines.hardR[#lines.hardR + 1] = at(c - d.hard), at(c + d.hard)
	end
	d.lines = lines
	st.dv = d
end

local function deg(a) return (a * 180 / math.pi) % 360 end
function K.drawDriveView()
	local r = TG.S.run
	if not r or not r.plan.driveview or r.phase ~= "step" then return end
	local st = r.steps and r.steps[r.si]
	local d = st and st.kind == "drivefast" and st.dv
	if not d or now() - d.t > 1500 then return end
	local R = getRenderer()
	-- 1.13.7: also to Test Ground Capture while it wants it (its world shots have no game UI)
	local cap = K.captureWantsOverlay and K.captureWantsOverlay()
	if cap then pcall(function() TGCapture.beginOverlay() end) end
	local function rect(x, y, w, h, cr, cg, cb, ca)
		R:renderRect(x, y, w, h, cr, cg, cb, ca)
		if cap then pcall(function() TGCapture.rect(x, y, w, h, cr, cg, cb, ca) end) end
	end
	local function scr(x, y) return isoToScreenX(0, x, y, d.z), isoToScreenY(0, x, y, d.z) end
	local function dot(x, y, sz, cr, cg, cb, ca)
		local sx, sy = scr(x, y)
		rect(floor(sx - sz / 2), floor(sy - sz / 2), sz, sz, cr, cg, cb, ca)
	end
	pcall(function()
		for _, p in ipairs(d.tiles or {}) do dot(p[1], p[2], 6, 0.2, 0.9, 0.2, 0.55) end
		local L = d.lines or {}
		for _, p in ipairs(L.hardL or {}) do dot(p[1], p[2], 5, 1, 0.15, 0.15, 0.9) end
		for _, p in ipairs(L.hardR or {}) do dot(p[1], p[2], 5, 1, 0.15, 0.15, 0.9) end
		for _, p in ipairs(L.softL or {}) do dot(p[1], p[2], 5, 1, 0.7, 0.1, 0.9) end
		for _, p in ipairs(L.softR or {}) do dot(p[1], p[2], 5, 1, 0.7, 0.1, 0.9) end
		for _, p in ipairs(L.centre or {}) do dot(p[1], p[2], 6, 1, 1, 0.1, 1) end
		for k = 1, 12 do
			dot(d.x + math.cos(d.road) * k, d.y + math.sin(d.road) * k, 4, 1, 1, 1, 0.9)
			dot(d.x + math.cos(d.h) * k, d.y + math.sin(d.h) * k, 5, 0.1, 0.9, 1, 1)
			dot(d.x + math.cos(d.want) * k * 0.8, d.y + math.sin(d.want) * k * 0.8, 4, 1, 0.3, 1, 0.8)
		end
		dot(d.px, d.py, 12, 1, 0.2, 1, 1)
	end)
	local hw = (d.width or 8) / 2
	local side = d.lat >= 0 and "right" or "left"
	local lines = {
		string.format("DRIVE VIEW  %s  %.0f km/h  %.0f of %.0f tiles  aim %.0f tiles ahead%s%s", tostring(st.tag), d.kmh, d.s, st.total or 0, d.look or 0,
			d.mode and ("  steering: " .. d.mode) or "", d.recover and "  STEERING BACK" or ""),
		string.format("road direction %.1f deg   car heading %.1f deg   heading off the road %+.1f deg", deg(d.road), deg(d.h), wrapAngle(d.h - d.road) * 180 / math.pi),
		-- (1.13.9: after the hand-over to nudges the torque numbers are stale, so they aren't shown)
		d.mode and string.format("aim %+.1f deg from the road   steering by %s: setAngles turns of a degree or two, no push",
			wrapAngle(d.aimDir - d.road) * 180 / math.pi, d.mode == "nudge" and "nudges" or d.mode) or
		string.format("aim %+.1f deg from the road (limit %d)   wanted turn %+.1f deg/s   turning %+.1f deg/s   push %+.0f%s (gain %.3g)",
			wrapAngle(d.want - d.road) * 180 / math.pi, K.APPROACH_DEG, d.rate * 180 / math.pi, d.turn, d.push, d.counter and " against a spin" or "", d.gain),
		string.format("off the centre %.1f tiles to the %s = %.0f%% of the half-width %.1f%s   back under %.0f%%, steer back past %.0f%%, cut past %.0f%%",
			math.abs(d.lat), side, 100 * math.abs(d.lat) / hw, hw, (d.roadW and d.width and d.width < d.roadW - 2) and string.format(" (one carriageway of %d)", d.roadW) or "",
			100 * d.back / hw, 100 * d.soft / hw, 100 * d.hard / hw),
		"green street squares, yellow centre, amber soft limit, red hard limit, magenta aim, cyan car heading, white road direction",
	}
	pcall(function()
		local tm = getTextManager()
		local fh = tm:getFontHeight(UIFont.Medium)
		local x, y = 20, floor(getCore():getScreenHeight() * 0.62)
		rect(x - 8, y - 6, floor(getCore():getScreenWidth() * 0.62), fh * #lines + 12, 0, 0, 0, 0.6)
		for i, l in ipairs(lines) do
			tm:DrawString(UIFont.Medium, x, y + (i - 1) * fh, l, 1, 1, 1, 1)
			if cap then pcall(function() TGCapture.text(x, y + (i - 1) * fh, l, 1, 1, 1) end) end
		end
	end)
	if cap then pcall(function() TGCapture.endOverlay() end) end
end
