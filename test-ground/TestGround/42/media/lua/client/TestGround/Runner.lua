-- Test Ground 1.13.0: the runner: scene, steps, per-step perf and spikes, the report, the tick.
require "TestGround/Core"
local TG = TestGroundInternal
if TG.loaded.Runner then return end
TG.loaded.Runner = true
local S = TG.S
local K, Steps, T, VERSION, activeMods, areaLoaded = TG.K, TG.Steps, TG.T, TG.VERSION, TG.activeMods, TG.areaLoaded
local busy, clearClimate, countZombies, floor, frameTick, godCall = TG.busy, TG.clearClimate, TG.countZombies, TG.floor, TG.frameTick, TG.godCall
local isGod, makeGod, newFrames, now, out, player = TG.isGod, TG.makeGod, TG.newFrames, TG.now, TG.out, TG.player
local playerHealth, removeZombies, say, setClimate, spawnZombies, split = TG.playerHealth, TG.removeZombies, TG.say, TG.setClimate, TG.spawnZombies, TG.split
local stateName, teleport, try, unGod, writeLines = TG.stateName, TG.teleport, TG.try, TG.unGod, TG.writeLines
local function profiler()
	local P = LuaEventProfiler
	if P and P.takeWindow then return P end
	return nil
end

local function setZombies(r)
	local plan, p = r.plan, r.p
	if plan.zombies == "none" then
		r.zombiesRemoved = removeZombies()
	elseif type(plan.zombies) == "number" and plan.zombies > 0 then
		removeZombies()
		spawnZombies(plan.start or { x = floor(p:getX()), y = floor(p:getY()), z = floor(p:getZ()) }, plan.zombies)
	end
end

-- Drag-down (1.9.4): when enough zombies hit at once, the game sets the player's hit reaction to
-- "EndDeath" and kills them outright next update, whatever their health (BodyDamage.
-- AddRandomDamageFromZombie, IsoPlayer.updateDeathDragDown); only god mode skips it. So healing
-- can't save a crowded fight: the run turns the sandbox's ZombiesDragDown off (restored at the end)
-- and clears a pending drag-down every tick.
K.DRAG_OPTS = { "ZombieLore.ZombiesDragDown", "ZombieLore.ZombiesCrawlersDragDown" }
function K.dragDown(r, off)
	for _, name in ipairs(K.DRAG_OPTS) do
		K.tryOnce("sandbox " .. name, function()
			local o = getSandboxOptions():getOptionByName(name)
			if not o then return end
			if off then
				r.dragWas = r.dragWas or {}
				r.dragWas[name] = o:getValue()
				o:setValue(false)
				say(string.format("%s was %s, off for the run (reads back %s)", name, tostring(r.dragWas[name]), tostring(o:getValue())))
			elseif r.dragWas and r.dragWas[name] ~= nil then
				o:setValue(r.dragWas[name])
				say(string.format("%s put back to %s", name, tostring(o:getValue())))
			end
		end)
	end
end
-- Down: on the floor, knocked down, or in a hit reaction (the 1.9.1 death came after 3 s of hit
-- reactions, which neither isOnFloor nor isKnockedDown reports).
local function downOf(p) return p:isOnFloor() or p:isKnockedDown() end
function K.isDown(p)
	local ok, down = K.tryOnce("knocked-down check", downOf, p)
	if ok and down then return true end
	local s = stateName(p)
	return s ~= nil and string.find(s, "HitReaction") ~= nil
end
-- 1.13.0: the per-tick calls take the player as an argument instead of building a closure each tick
local function dragDownOf(p) return p:isDeathDragDown() end
local function dragDownClear(p)
	p:setDeathDragDown(false)
	if p:getHitReaction() == "EndDeath" then p:setHitReaction("") end
end
function K.noDragDeath(p)
	local ok, dd = K.tryOnce("drag-down check", dragDownOf, p)
	if ok and dd then
		K.tryOnce("drag-down clear", dragDownClear, p)
		return true
	end
	return false
end

local function setScene(r)
	local plan, p = r.plan, r.p
	K.dragDown(r, true)
	if plan.start then teleport(p, plan.start.x, plan.start.y, plan.start.z) end
	if plan.time then try("time of day", function() getGameTime():setTimeOfDay(plan.time) end) end
	if plan.weather == "clear" then
		setClimate("rain", 0); setClimate("fog", 0); setClimate("cloud", 0); setClimate("wind", 0)
	elseif plan.weather == "rain" then
		setClimate("rain", 0.8); setClimate("cloud", 1); setClimate("fog", 0)
	elseif plan.weather == "fog" then
		setClimate("fog", 1); setClimate("rain", 0)
	end
	-- a start that isn't loaded yet: the zombies are set once it is (the settle waits for it)
	if plan.start and not areaLoaded(plan.start.x, plan.start.y, plan.start.z) then
		r.loadingSince = now()
		T.trace(string.format("start %d,%d,%d not loaded yet, waiting", plan.start.x, plan.start.y, plan.start.z))
	else
		setZombies(r)
	end
	if plan.god then
		r.godHow = makeGod(r)
		say("god mode " .. (r.godHow or "COULD NOT be turned on: fights run guarded (zombies put down before they reach you)"))
		T.trace("god mode " .. (r.godHow or "COULD NOT be turned on"))
	end
end

-- 1.13.2 (review): a run stopped or timed out mid-step left its zombies, a fight's corpses, the
-- laid corpses and loot taken out in the save. Returns a line for the report, or nil.
function K.leftovers(r)
	local said = {}
	local back = K.lootBack and K.lootBack(r) or 0
	if back > 0 then said[#said + 1] = back .. " loot items put back" end
	if r.spawnedZombies then
		local n = removeZombies()
		r.spawnedZombies = nil
		if n > 0 then said[#said + 1] = n .. " zombies removed" end
	end
	if r.fightAt then
		local n = TG.removeCorpses(r.fightAt, r.fightRadius or 20)
		r.fightAt, r.fightRadius = nil, nil
		if n and n > 0 then said[#said + 1] = n .. " corpses from the fight removed" end
	end
	if r.corpseOut then
		local co, c, cell, n = r.corpseOut, K.CORPSE_CHUNK, getCell(), 0
		r.corpseOut = nil
		for _, ch in ipairs(co.chunks) do
			local x0, y0 = ch.cx * c, ch.cy * c
			for dx = 0, c - 1 do for dy = 0, c - 1 do
				local sq = cell:getGridSquare(x0 + dx, y0 + dy, co.z)
				if sq then n = n + K.clearCorpses(sq) end
			end end
		end
		said[#said + 1] = string.format("%d of the %d laid corpses removed%s", n, co.laid, n < co.laid and " (the rest are on chunks not loaded now: a run with \"corpses clear\" takes them off)" or "")
	end
	return #said > 0 and ("cleaned up at the end of the run: " .. table.concat(said, ", ")) or nil
end

local function restore(r)
	local p = r.p
	pcall(K.showUi, r)   -- 1.13.16 (review of 1.13.15): first, so nothing that fails below leaves windows hidden
	if r.plan.viewpoint and K.viewApi() and K.viewNow() ~= "isometric" then
		-- 1.13.13: one cycle a frame (asks in one frame are one), so it finishes after the run
		K.viewBack = { want = "isometric", log = print }
		T.trace("viewpoint: going back to isometric after the run, " .. tostring(K.viewNow()) .. " now")
	end
	pcall(function() T.setSpeed(1) end)
	K.dragDown(r, false)
	K.releaseAim(p)
	K.unarm(r)
	local okL, left = pcall(K.leftovers, r)
	if okL and left then out(left); T.trace(left) elseif not okL then T.trace("clean-up after the run failed: " .. tostring(left)) end
	if r.buildSite then
		local n = K.bbpTearDown(r.buildSite)
		local left = 0
		pcall(function()
			local inv = r.p:getInventory()
			for _, it in ipairs(r.buildGiven or {}) do if inv:contains(it) then inv:Remove(it); left = left + 1 end end
		end)
		say("build site taken down (" .. n .. " objects), " .. left .. " unused materials taken back")
		r.buildSite, r.buildGiven = nil, nil
	end
	K.resetSkills(r)
	clearClimate()
	ISTimedActionQueue.clear(p)
	pcall(function() p:setGhostMode(r.wasGhost) end)
	if r.plan.god then unGod(r) end
	if r.plan.ret then teleport(p, r.home.x, r.home.y, r.home.z) end
	local P = profiler()
	if P then P.quiet = false end
end

-- 1.13.3: viewpoint = first | third | isometric switches Project Viewpoint (Workshop 3809306528) to
-- that view before the settle, and back to isometric at the end. Its Lua API (Viewpoint.View, from
-- its Java part) has cycle() and next() (the view cycle() goes to), no getter; how the run cycles
-- is under K.viewStep (1.13.13). Without the
-- mod the plan line is reported and ignored. With a Viewpoint view on, the run doesn't zoom out.
function K.viewApi()
	local v = Viewpoint and Viewpoint.View
	if type(v) == "table" and type(v.cycle) == "function" and type(v.next) == "function" then return v end
	return nil
end
function K.viewNames(v)
	local names = {}
	pcall(function() for k, x in pairs(v) do names[#names + 1] = tostring(k) .. (type(x) == "function" and "()" or "") end end)
	table.sort(names)
	return table.concat(names, " ")
end
-- 1.13.13 (PC, Viewpoint check: "COULD NOT reach the third view in 3 cycles"; read from Viewpoint
-- 0.1.6.1's classes): cycle() only asks, and the ask is taken on the next rendered frame (two asks in
-- one frame are one); an ask while its first-run setup is due opens the setup and is dropped. next()
-- is read from the state, so it tells the view on now: next() "first" = isometric, "isometric" =
-- third, "third" = first. Third person is Viewpoint's saved setting camera.thirdPersonOnFoot, which
-- going from first to third turns on: with it on, isometric goes straight to third and first can't
-- be reached by cycling. So: ask, and wait for next() to change; an ask not taken in
-- K.VIEW_ASK_MS is asked again (harmless while one is pending); all in K.VIEW_BUDGET_MS. A view seen
-- again without the one wanted means a loop that doesn't hold it.
K.VIEW_ASK_MS, K.VIEW_BUDGET_MS, K.VIEW_TRIES = 2000, 30000, 4
K.VIEW_NOW = { first = "isometric", isometric = "third", third = "first" }
function K.viewNow()
	local v = K.viewApi()
	if not v then return nil end
	local ok, nx = pcall(v.next)
	return ok and K.VIEW_NOW[nx] or nil, nx
end
-- One step of job (a table: want, and the step's own state) at time t; returns "done", "busy" or
-- nil with job.why (no Viewpoint, or it gave up). job.log(line) traces.
function K.viewStep(job, t)
	local v = K.viewApi()
	if not v then job.why = "Project Viewpoint isn't loaded"; return nil end
	local cur, nx = K.viewNow()
	if not cur then job.why = "Viewpoint.View.next() said " .. tostring(nx); return nil end
	job.t0 = job.t0 or t
	job.cycles, job.asks = job.cycles or 0, job.asks or 0
	if not job.seen then
		job.seen = { [cur] = true }
		job.log("viewpoint: Viewpoint.View has " .. K.viewNames(v) .. "; " .. cur .. " now, " .. job.want .. " wanted")
	end
	if job.askedAt and cur ~= job.before then
		job.cycles = job.cycles + 1
		job.log(string.format("viewpoint: %s now, %d ms after the ask (%d ask%s)", cur, t - job.askedAt, job.asks, job.asks == 1 and "" or "s"))
		job.askedAt = nil
		if cur ~= job.want and job.seen[cur] then
			job.why = "cycling goes " .. table.concat(job.order, " -> ") .. " -> " .. cur .. " and never to " .. job.want
				.. (job.want == "first" and " (Viewpoint's camera.thirdPersonOnFoot is on: it goes to third person instead)" or "")
			return nil
		end
		job.seen[cur] = true
	end
	if cur == job.want then return "done" end
	if t - job.t0 > K.VIEW_BUDGET_MS then job.why = string.format("no %s view in %d s (%d asks, %d taken)", job.want, math.floor(K.VIEW_BUDGET_MS / 1000), job.asks, job.cycles); return nil end
	if job.cycles >= K.VIEW_TRIES then job.why = string.format("%d cycles and no %s view", job.cycles, job.want); return nil end
	if job.askedAt and t - job.askedAt < K.VIEW_ASK_MS then return "busy" end
	if not job.askedAt then job.before = cur; job.order = job.order or {}; job.order[#job.order + 1] = cur end
	if not pcall(v.cycle) then job.why = "Viewpoint.View.cycle() failed"; return nil end
	job.asks = job.asks + 1
	job.askedAt = t
	return "busy"
end
-- after the run: back to isometric on the render tick (the run is over, so it goes to the console)
function K.viewBackTick()
	local job = K.viewBack
	if not job then return end
	local s = K.viewStep(job, now())
	if s == "busy" then return end
	K.viewBack = nil
	print("[TestGround] viewpoint: back to isometric " .. (s == "done" and "done" or ("FAILED: " .. tostring(job.why))))
end
function K.viewing(r)
	return r.plan.viewpoint and r.plan.viewpoint ~= "isometric" and r.viewAt == r.plan.viewpoint
end

-- Zoomed all the way out for the whole run (the user watches runs, and wants to see as much as
-- possible). Core:doZoomScroll steps one zoom level towards getNextZoom; it's checked every
-- K.ZOOM_CHECK_MS, so anything that zooms back in (a car's auto zoom, a key) is undone quickly.
-- Note: zooming out draws more of the world, so frame times aren't comparable with runs before 1.8.0.
K.ZOOM_CHECK_MS = 500
local function zoomOut(r)
	if K.viewing(r) then return nil end
	local c = getCore()
	local ok, z, mx = K.tryOnce("zoom", function() return c:getZoom(0), c:getMaxZoom() end)
	if not (ok and z and mx) then return nil end
	if z >= mx - 0.01 then return z, mx, true end
	local okN, n1, n2 = K.tryOnce("zoom", function() return c:getNextZoom(0, 1), c:getNextZoom(0, -1) end)
	local del = 1
	if okN and n1 and n2 and n2 > n1 then del = -1 end
	if K.tryOnce("zoom", function() c:doZoomScroll(0, del) end) then r.zoomSteps = (r.zoomSteps or 0) + 1 end
	return z, mx, false
end

local function header(r)
	out("Test Ground " .. VERSION .. " report: " .. r.plan.label .. " (" .. r.id .. ")")
	out("plan: " .. #r.plan.steps .. " steps x " .. r.plan.rep .. ", settle " .. r.plan.settle .. " s, start " ..
		(r.plan.start and (r.plan.start.x .. "," .. r.plan.start.y .. "," .. r.plan.start.z ..
		(r.plan.startName and (" (" .. r.plan.startName .. ", fixed test start)") or "")) or "where the save loaded"))
	out("scene: time " .. tostring(r.plan.time or "keep") .. ", weather " .. tostring(r.plan.weather or "keep") ..
		", zombies " .. tostring(r.plan.zombies or "keep") .. ", god " .. (r.plan.god and (r.godHow or "COULD NOT be turned on") or "off"))
	local P2 = LuaEventProfiler and not profiler() and type(LuaEventProfiler.mark) == "function"
	out("profiler: " .. (profiler() and "on (Lua Event Profiler 1.4, per step below)" or
		(P2 and "Lua Event Profiler 2 (its own reports, tagged with each step's phase)" or "off (frame times only)")))
	local sp = r.plan.start
	local zi = sp and T.intensityAt and T.intensityAt(sp.x, sp.y)
	if zi then out(string.format("zombie intensity at the start: %.2f (the map's own spawn density, 0 to 1)", zi)) end
	if r.speed then out("game speed: x" .. r.speed .. " (fast-forward for trying behaviour; frame numbers below are NOT measurements)")
	elseif r.speedRefused then out("game speed: 1 (gamespeed asked for, but " .. r.speedRefused .. ")") end
	out("zoom: " .. ((r.plan.viewpoint and r.plan.viewpoint ~= "isometric" and K.viewApi()) and "left alone (a Project Viewpoint view is asked for)" or r.zoom0 and string.format("%.2f at the start, kept at the maximum %.2f during the run", r.zoom0, r.zoomMax or 0) or "unreadable, left as it was"))
	if r.plan.viewpoint then
		out("viewpoint: " .. r.plan.viewpoint .. (K.viewApi() and " asked for (Project Viewpoint is loaded; switched during the settle, reported there)" or " asked for, but Project Viewpoint isn't loaded (Viewpoint.View missing): the run stays isometric"))
	end
	out("mods: " .. table.concat(activeMods(), ";"))
	out("")
end

-- Per-second samples and slow frames, for the perf and spikes files. Kept in memory and written
-- when the run ends, so the logging itself doesn't add file writes inside a step.
local SPIKE_MS = 50
local PERF_HEAD = "run_s,pass,step,phase,step_text,x,y,z,frames,fps,mean_ms,worst_ms,over33,over100,zombies"
local SPIKE_HEAD = "run_s,pass,step,phase,step_text,ms,x,y,z,state,zombies"

local function perfFlush(r, t)
	local b = r.sec
	r.sec = nil
	if not b or b.n == 0 then return end
	local p, st = r.p, b.st
	local secs = (t - b.t0) / 1000
	r.perf[#r.perf + 1] = string.format("%.1f,%d,%d,%s,%s,%.1f,%.1f,%d,%d,%.1f,%.1f,%d,%d,%d,%d",
		(t - r.t0) / 1000, st.pass, b.si, b.tag, st.text, p:getX(), p:getY(), floor(p:getZ()),
		b.n, secs > 0 and b.n / secs or 0, b.sum / b.n, b.worst, b.o33, b.o100, countZombies())
end

local function perfFrame(r, st, t, gap)
	local b = r.sec
	-- 1.13.10 (review of 18 Oct): while a step waits for a far road to load (st.waiting), its rows
	-- go under "<phase>_load", so the drive's own rows don't carry the wait
	local tag = st.waiting and (st.tag .. "_load") or st.tag
	if not b or b.st ~= st or b.tag ~= tag then
		if b then perfFlush(r, t) end
		b = { st = st, si = r.si, tag = tag, t0 = t - gap, n = 0, sum = 0, worst = 0, o33 = 0, o100 = 0 }
		r.sec = b
	end
	b.n = b.n + 1
	b.sum = b.sum + gap
	if gap > b.worst then b.worst = gap end
	if gap > 33 then b.o33 = b.o33 + 1 end
	if gap >= 100 then b.o100 = b.o100 + 1 end
	if gap >= SPIKE_MS then
		local p = r.p
		r.spikes[#r.spikes + 1] = string.format("%.2f,%d,%d,%s,%s,%d,%.1f,%.1f,%d,%s,%d", (t - r.t0) / 1000, st.pass, r.si,
			tag, st.text, gap, p:getX(), p:getY(), floor(p:getZ()), stateName(p), countZombies())
	end
	if t - b.t0 >= 1000 then perfFlush(r, t) end
end

-- A step's phase tag: the first word after the kind that isn't a number ("fight 6 30 fight_small"),
-- else the kind. It goes in the perf and spikes files and to Lua Event Profiler 2's mark().
local function phaseOf(st)
	for i = 2, #(st.args or {}) do
		local w = st.args[i]
		-- 1.13.11 (showcase trial: "build mod:shell2 300 setup_shell" was tagged mod:shell2, and the
		-- colon broke a file name): a plan or file reference (":" "/" "\\" or ".txt") isn't the name
		if not tonumber(w) and not string.find(w, "=", 1, true) and not string.find(w, "[:/\\]") and not string.find(string.lower(w), "%.txt$")
			and not (st.kind == "corpses" and w == "clear" and i == 2)
			and not (st.kind == "station" and i == 2 and (w == "spawn" or string.find(w, ",", 1, true))) then return w end
	end
	return st.kind
end

local SLOW_BOOKKEEPING_MS = 50   -- step start/end work longer than this gets a trace line

local function beginStep(r, t)
	local st = r.steps[r.si]
	local w0 = now()
	st.t0 = t
	st.frames = newFrames()
	st.tag = phaseOf(st)
	K.filmCall("filmTag", st.tag)
	-- 1.13.8 (review of 18 Oct): no drive view overlay left over from an earlier step in a capture
	if K.captureOn("auto") then pcall(function() TGCapture.beginOverlay(); TGCapture.endOverlay() end) end
	K.reportCall("stepStart", r, st)
	if r.plan.god and not S.godBroken and not isGod(r.p) then
		-- something turned it off since the last step (or it never took): try again, and say so
		r.godHow = makeGod(r)
		T.trace("god mode was off at step " .. r.si .. ", " .. (r.godHow and ("turned back " .. r.godHow) or "COULD NOT turn it on"))
	end
	if LuaEventProfiler and type(LuaEventProfiler.mark) == "function" then
		pcall(LuaEventProfiler.mark, st.tag)
	end
	r.holdSweep = false   -- a step that ended early can't leave the sweep off
	if r.plan.zombies == "none" then
		-- nothing left over from an earlier step (or wandered in) when a step starts
		local n = removeZombies()
		if n > 0 then T.trace(string.format("step %d.%d: %d zombies removed at the start", r.pass, r.si, n)) end
	end
	local ok, err = pcall(Steps[st.kind].begin, r, st)
	if not ok then st.skip = "error: " .. tostring(err); say("step error: " .. tostring(err)) end
	local P = profiler()
	if P then P.takeWindow() end   -- drop whatever ran before this step
	T.trace(string.format("step %d.%d %s begin", r.pass, r.si, st.text))
	local ms = now() - w0
	if ms > SLOW_BOOKKEEPING_MS then T.trace(string.format("step %d.%d start bookkeeping took %d ms", r.pass, r.si, ms)) end
end

local function endStep(r, t)
	local st = r.steps[r.si]
	local w0 = now()
	perfFlush(r, t)
	local seconds = (t - st.t0) / 1000
	local f = T.frameSummary(st.frames, seconds)
	local pausedS = (st.frames.paused or 0) / 1000
	out(string.format("== pass %d step %d: %s (%.0f s)%s%s", r.pass, r.si, st.text, seconds,
		st.skip and (" SKIPPED: " .. st.skip) or (st.result and (", " .. st.result) or ""),
		pausedS >= 0.5 and string.format(" [game paused %.0f s, left out of the frames and the step's time]", pausedS) or ""))
	out("name: " .. T.displayName(st.tag or phaseOf(st)))
	r.summary = r.summary or {}
	r.summary[#r.summary + 1] = { name = T.displayName(st.tag or phaseOf(st)), pass = r.pass, f = f, result = st.skip and ("skipped: " .. st.skip) or st.result, skipped = st.skip ~= nil }
	-- (1.13.8, review of 18 Oct: a step with screenshots says its numbers include them)
	out(string.format("frames: %d, %.1f fps, mean %.1f ms, p50 %d, p95 %d, p99 %d, worst %d ms, %d over 33 ms, %d hitches (100 ms+)%s",
		f.frames, f.fps, f.mean, f.p50, f.p95, f.p99, f.worst, f.over33, f.over100,
		(st.screenshots or 0) > 0 and string.format("; NOT A MEASUREMENT: %d screenshots in this step, the fps and hitches include them", st.screenshots) or
		(r.filming and "; NOT A MEASUREMENT: filmed (Test Ground Capture film mode), the fps and hitches include it" or "")))
	if r.filming then
		local okF, fl = K.filmCall("filmTake")
		out("film: " .. (okF and tostring(fl) or ("no numbers (" .. tostring(fl) .. ")")))
		K.filmCall("filmTag", "gap")
	end
	for _, l in ipairs(st.extraLines or {}) do out(l) end
	local P = profiler()
	if P then
		local lines = P.takeWindow(seconds)
		for _, l in ipairs(lines) do out(l) end
	end
	K.reportCall("stepEnd", r, st, out)
	out("")
	T.trace(string.format("step %d.%d %s end: %s", r.pass, r.si, st.text, st.skip or st.result or "done"))
	say(string.format("pass %d step %d %s: %.1f fps, p99 %d ms, %d hitches", r.pass, r.si, T.displayName(st.tag or phaseOf(st)), f.fps, f.p99, f.over100))

	local ms = now() - w0
	if ms > SLOW_BOOKKEEPING_MS then T.trace(string.format("step %d.%d end bookkeeping took %d ms (summary of %d frames)", r.pass, r.si, ms, f.frames)) end
	K.flushTrace(r)
end

-- The run in a few numbers (1.13.20): for the end of the report and the end screen. The save is named
-- both ways: the one the user chose (T.sourceSave, set by Autorun's Benchmark Save) and the one the run
-- really happened in (a throwaway copy of it).
function K.runSummary(r, why)
	local sum = { rows = {}, label = r.plan.label, stopped = why }
	pcall(function() sum.copy = getCurrentSaveName() end)
	sum.save = (type(T.sourceSave) == "string" and T.sourceSave ~= "") and T.sourceSave or sum.copy
	sum.copyOf = sum.save ~= sum.copy
	local secs, frames, over33, over100, worst, p99 = 0, 0, 0, 0, 0, 0
	local tmean = 0
	for _, e in ipairs(r.summary or {}) do
		if not e.skipped and e.f and e.f.frames > 0 then
			secs, frames = secs + e.f.seconds, frames + e.f.frames
			over33, over100 = over33 + e.f.over33, over100 + e.f.over100
			worst, p99 = math.max(worst, e.f.worst), math.max(p99, e.f.p99)
			tmean = tmean + e.f.mean * e.f.frames
		end
		sum.rows[#sum.rows + 1] = e
	end
	sum.seconds, sum.frames, sum.worst, sum.p99, sum.over33, sum.over100 = secs, frames, worst, p99, over33, over100
	sum.fps = secs > 0 and frames / secs or 0
	sum.mean = frames > 0 and tmean / frames or 0
	pcall(function() sum.mem = math.floor((collectgarbage("count") or 0) / 1024) end)
	sum.version = tostring(T.VERSION or "")
	local L = {}
	L[#L + 1] = "run summary:"
	L[#L + 1] = string.format("save tested: %s%s", tostring(sum.save), sum.copyOf and string.format(" (this run happened in the throwaway copy %s)", tostring(sum.copy)) or "")
	L[#L + 1] = string.format("plan %s, %d steps measured, %.0f s, %d frames: %.1f fps, mean %.1f ms, worst step p99 %d ms, worst frame %d ms, %d over 33 ms, %d hitches (100 ms+)%s",
		tostring(sum.label), #sum.rows, secs, frames, sum.fps, sum.mean, p99, worst, over33, over100, why and (", stopped: " .. tostring(why)) or "")
	sum.lines = L
	return sum
end

local function finish(r, why)
	if r.cleanup then pcall(r.cleanup); r.cleanup = nil end   -- e.g. out of the drivefast car
	restore(r)
	if LuaEventProfiler and type(LuaEventProfiler.report) == "function" then
		pcall(LuaEventProfiler.report)   -- Lua Event Profiler 2: write out the last phase's window
	end
	if why then out("run stopped: " .. why) end
	if r.filming then
		local okT, tot = K.filmCall("filmTotal")
		K.filmCall("filmStop")
		r.filming = nil
		out("film: run total " .. (okT and tostring(tot) or "?") .. "; frames in Zomboid/Lua/film/" .. tostring(r.filmDir) .. "/ (frames.txt lists them by step)")
	elseif r.plan.film then
		out("film: NOT FILMED (" .. tostring(r.filmWhy) .. ")")
	end
	if r.plan.screenshot then
		out(K.broken.screenshot and ("screenshots: FAILED (" .. K.broken.screenshot .. ")") or
			string.format("screenshots: %d in Zomboid/Screenshots, named TestGround_%s_%s_p<pass>_s<step>_<step name>_<n>.png (every %.1f s%s; each is a ~300 ms hitch, so this run's fps and hitch counts are not measurements), %s",
				r.shots or 0, r.plan.label, tostring(r.id), r.plan.screenshot.every, (r.shots or 0) >= K.SHOT_MAX and ", STOPPED at " .. K.SHOT_MAX or "",
				K.captureOn(r.plan.capture or "auto") and ("taken by Test Ground Capture, capture = " .. (r.plan.capture or "auto") .. " (" .. tostring(select(2, pcall(function() return TGCapture.status() end))) .. ")")
					or ("taken by the game's own screenshot (needs the window on screen)" .. (K.capBroken and ("; Test Ground Capture failed: " .. K.capBroken) or ""))))
	end
	if (r.pausedBeats or 0) > 0 then
		out(string.format("game paused during the run: about %d s (seen at %d heartbeats; a window out of focus with focusloss on pauses it)", r.pausedBeats * 10, r.pausedBeats))
	end
	K.reportCall("finish", r, out)
	local okS, sum = pcall(K.runSummary, r, why)
	if not okS then   -- 1.13.21 (review of 1.13.20): a failed summary never loses the report
		T.trace("run summary failed: " .. tostring(sum))
		sum = { lines = { "run summary: unavailable (" .. tostring(sum) .. ")" }, rows = {}, label = r.plan.label }
	end
	for _, l in ipairs(sum.lines) do out(l) end
	T.trace("run end" .. (why and (": " .. why) or ""))
	local base = "TestGround_" .. r.plan.label .. "_" .. r.id
	local ok1 = writeLines(base .. ".txt", r.report, false)
	local ok2 = writeLines(base .. "_trace.txt", r.trace, false)
	table.insert(r.perf, 1, PERF_HEAD)
	table.insert(r.spikes, 1, SPIKE_HEAD)
	local function save(name, lines)
		local ok, err = writeLines(name, lines, false)
		if not ok then say("could not write Zomboid/Lua/" .. name .. ": " .. tostring(err)) end
	end
	save(base .. "_perf.txt", r.perf)
	save(base .. "_spikes.txt", r.spikes)
	-- the same files under fixed names, so another tool can always read the last run
	save("TestGround_report_latest.txt", r.report)
	save("TestGround_perf_latest.txt", r.perf)
	save("TestGround_spikes_latest.txt", r.spikes)
	T.last = { report = base .. ".txt", trace = base .. "_trace.txt", perf = base .. "_perf.txt",
		spikes = base .. "_spikes.txt", stopped = why }
	if T.onFinish then pcall(T.onFinish, T.last) end
	if T.endScreen then pcall(T.endScreen, sum, r.plan) end
	say("run finished" .. (why and (" (" .. why .. ")") or "") .. ", report " ..
		(ok1 and ("Zomboid/Lua/" .. base .. ".txt") or "NOT written") .. (ok2 and ", trace written" or ", trace NOT written"))
	S.run = nil
end

-- Release safety (1.10.0) ---------------------------------------------------------------------
-- Singleplayer only: in multiplayer a run would teleport, spawn and remove things on a server.
function K.mpBlocked()
	local mp = false
	pcall(function() mp = isClient() or isServer() end)
	return mp
end
-- A run changes the save it runs in (teleports, spawns and removes zombies, corpses and cars, sets the
-- weather and time). Before the first run in a save, the player confirms once; the answer is kept in
-- the save's mod data. Autorun (which works on a copy of the save) sets T.trusted and skips the ask.
K.CONFIRM_TEXT = "Test Ground changes this save: it teleports you, spawns and removes zombies, " ..
	"corpses and cars, and sets the weather and time. The fast drive deletes every car on its road " ..
	"(up to 3,600 tiles) except ones a player has been in, hotwired or left keys in. " ..
	"Use a copy of your save for tests. Run it in this save?"
function K.confirmed()
	if T.trusted then return true end
	local ok, yes = pcall(function() return getGameTime():getModData().TestGroundConfirmed == true end)
	return ok and yes
end
function K.withConfirm(fn)
	if K.confirmed() then fn(); return true end
	if K.asking then return false end
	K.asking = true
	local ok = pcall(function()
		local w, h = 380, 170
		local x, y = 200, 200
		pcall(function() x, y = (getCore():getScreenWidth() - w) / 2, (getCore():getScreenHeight() - h) / 2 end)
		local d = ISModalDialog:new(x, y, w, h, K.CONFIRM_TEXT, true, nil, function(_, button)
			K.asking = false
			if button.internal == "YES" then
				pcall(function() getGameTime():getModData().TestGroundConfirmed = true end)
				fn()
			else
				say("not run: not confirmed for this save")
			end
		end)
		d:initialise()
		d:addToUIManager()
	end)
	if not ok then K.asking = false; say("could not ask to confirm; not run") end
	return false
end

function T.start(plan)
	if K.mpBlocked() then say("singleplayer only; not run"); return false end
	if S.run then say("a run is already going"); return false end
	local p = player()
	if not p then say("no player"); return false end
	if p:getVehicle() then say("get out of the vehicle first"); return false end
	plan = plan or T.loadPlan()
	if not plan then return false end
	if #plan.steps == 0 then say("the plan has no steps"); return false end
	-- 1.13.3: TestGround.viewpoint (Autorun sets it from its flag file) when the plan has no viewpoint line
	if not plan.viewpoint and type(T.viewpoint) == "string" then
		local v = string.lower(T.viewpoint)
		if v == "first" or v == "third" or v == "isometric" then plan.viewpoint = v end
	end
	-- Phases to leave out: the plan's "skip =" lines plus TestGround.skip (Autorun sets it from its flag
	-- file). A name matches a step's phase tag or its kind, so "fight" leaves out every fight.
	local skipSet, skipped = {}, {}
	-- 1.13.7 renamed the baseline's steps; a skip naming an old one means the new one (review of 18 Oct:
	-- an old name was ignored and the step ran). "drive" stays the step kind.
	local OLD_NAMES = { drive_back = "glide_north", drive_trees = "glide_trees", drive_fog = "glide_fog",
		corpse_lay = "setup_corpses", corpse_clear = "cleanup_corpses", fight_real = "fight_swing" }
	for _, w in ipairs(plan.skip or {}) do skipSet[w] = true end
	if type(T.skip) == "string" then
		for _, w in ipairs(split(T.skip, ",")) do
			w = string.lower((string.gsub(w, "^%s*(.-)%s*$", "%1")))
			if w ~= "" then skipSet[w] = true end
		end
	elseif type(T.skip) == "table" then
		for _, w in ipairs(T.skip) do skipSet[string.lower(tostring(w))] = true end
	end
	local renamedSkips = {}
	for old, new in pairs(OLD_NAMES) do
		if skipSet[old] and not skipSet[new] then skipSet[new] = true; renamedSkips[#renamedSkips + 1] = old .. " (now " .. new .. ")" end
	end
	table.sort(renamedSkips)
	local t = now()
	K.viewBack = nil   -- 1.13.14 (review of 1.13.13): a restore still going from the last run would fight this one
	S.run = {
		plan = plan, p = p, t0 = t, id = string.format("%d", floor(t / 1000)),
		report = {}, trace = {}, perf = {}, spikes = {},
		home = S.pendingHome or { x = floor(p:getX()), y = floor(p:getY()), z = floor(p:getZ()) },
		wasGhost = p:isGhostMode(), wasInvincible = (not S.godBroken) and select(2, godCall(function() return p:isInvincible() end)) == true, wasGod = isGod(p),
		phase = "settle", phaseT = t, pass = 1, si = 0, steps = {},
		lastZombieSweep = t,
	}
	for i = 1, plan.rep do
		for si, s in ipairs(plan.steps) do
			local st = { kind = s.kind, a = s.a, b = s.b, args = s.args, text = s.text, pass = i }
			local tag = string.lower(phaseOf(st))
			if skipSet[tag] or skipSet[string.lower(s.kind)] then
				if i == 1 then skipped[#skipped + 1] = { si = si, text = s.text } end
			else
				S.run.steps[#S.run.steps + 1] = st
			end
		end
	end
	-- 1.13.9 (review of 18 Oct): a skip name that matches no step's name or kind is reported, not ignored
	local unmatchedSkips = {}
	do
		local known = {}
		for _, s in ipairs(plan.steps) do
			known[string.lower(s.kind)] = true
			known[string.lower(phaseOf({ kind = s.kind, a = s.a, b = s.b, args = s.args, text = s.text }))] = true
		end
		for w in pairs(skipSet) do
			local renamedTo = OLD_NAMES[w]
			if not known[w] and not (renamedTo and known[renamedTo]) then unmatchedSkips[#unmatchedSkips + 1] = w end
		end
		table.sort(unmatchedSkips)
	end
	if #S.run.steps == 0 then
		S.run = nil
		say("every step is skipped by flag; nothing to run")
		return false
	end
	local P = profiler()
	if P then P.quiet = true end   -- no 30 s report hitch in the middle of a step
	setScene(S.run)
	-- gamespeed = 2 or 3 fast-forwards the whole run, for trying behaviour quickly; frame numbers are
	-- meaningless then, so it needs "measure = 0" and no Lua Event Profiler, and the report says so
	if (plan.gamespeed or 1) > 1 then
		if plan.measure == false and not profiler() and not (LuaEventProfiler and LuaEventProfiler.mark) then
			S.run.speed = plan.gamespeed
			try("game speed", function() T.setSpeed(S.run.speed) end)
		else
			S.run.speedRefused = plan.measure ~= false and "the run measures frames (add measure = 0)" or "a profiler is on"
		end
	end
	K.tryOnce("zoom", function() S.run.zoom0, S.run.zoomMax = getCore():getZoom(0), getCore():getMaxZoom() end)
	zoomOut(S.run)
	header(S.run)
	for _, k in ipairs(skipped) do
		out(string.format("== plan step %d: %s SKIPPED: skipped by flag", k.si, k.text))
		T.trace(string.format("plan step %d %s skipped by flag", k.si, k.text))
	end
	if #renamedSkips > 0 then out("skip: old step names taken as the new ones: " .. table.concat(renamedSkips, ", ")) end
	if #unmatchedSkips > 0 then
		out("skip: NO STEP MATCHES " .. table.concat(unmatchedSkips, ", ") .. " (nothing left out for them)")
		T.trace("skip: no step matches " .. table.concat(unmatchedSkips, ", "))
	end
	if #skipped > 0 or #renamedSkips > 0 or #unmatchedSkips > 0 then out("") end
	T.trace("run begin " .. plan.label)
	K.hideUi(S.run)
	out(plan.popups == "keep" and "popups: left alone (popups = keep)" or "popups: other mods' notice windows are hidden during the settle (popups = keep leaves them); each one is listed here")
	K.filmBegin(S.run)
	say("run started: " .. plan.label .. ", " .. #S.run.steps .. " steps, settling " .. plan.settle .. " s")
	return true
end

function T.stop(why)
	if S.run then finish(S.run, why or "stopped by hand") end
end

local SAMPLE_MS = 500
local STALL_MS = 2000      -- a step that hasn't moved the player for this long gets a trace line
local STALL_TILES = 0.2

-- What the step is waiting on while the player stands still, in words for the trace.
local function waitingFor(r, st, p)
	if st.waiting then return st.waiting end
	local k = st.kind
	if k == "idle" or k == "wait" or k == "turn" or k == "look" then return "nothing, " .. k .. " stands still by design" end
	if k == "fight" then return "zombies to come within reach (" .. countZombies() .. " loaded)" end
	local what
	local okV, v = pcall(function() return p:getVehicle() end)
	if okV and v then
		local kmh = 0
		pcall(function() kmh = v:getCurrentSpeedKmHour() end)
		what = string.format("the car (%.0f km/h)", kmh)
	elseif busy(p) then
		local okA, a = pcall(function()
			local q = ISTimedActionQueue.getTimedActionQueue(p)
			local cur = q and q.queue and q.queue[1]
			return cur and (cur.Type or "a timed action") or nil
		end)
		what = "timed action " .. tostring(okA and a or "(type unknown)")
	else
		what = "no timed action running"
	end
	return what .. (st.phase and (", " .. k .. " phase " .. tostring(st.phase)) or (", " .. k))
end

-- Called every measured tick: one line when the player has stood still past STALL_MS, one when it moves again.
local function stallWatch(r, st, p, t)
	local x, y = p:getX(), p:getY()
	local w = st.still
	if not w then st.still = { x = x, y = y, t = t }; return end
	local dx, dy = x - w.x, y - w.y
	if dx * dx + dy * dy > STALL_TILES * STALL_TILES then
		if w.said then
			T.trace(string.format("moving again after %.1f s still", (t - w.t) / 1000))
		end
		st.still = { x = x, y = y, t = t }
		return
	end
	if not w.said and t - w.t > STALL_MS then
		w.said = true
		T.trace(string.format("waiting %.1f s with no movement at %.1f,%.1f: %s", (t - w.t) / 1000, x, y, waitingFor(r, st, p)))
	end
end

-- "Can't die" for the whole run (1.8.2): the 1.8.0 check lost its player at the start between
-- steps. Every tick, unless god mode is really on or a guarded fight is watching for wounds itself:
-- health back to full, and if you're down (knocked down or on the floor, where zombies can kill
-- outright) or the game's own zombies are about between steps, any zombie within 2.2 tiles is put down.
-- 1.13.0: pzopt's Lua sampler had the harness at 8% of the game's Lua while standing still (EC1),
-- most of it here: god check, heal, stats reset and the knocked-down check (a state name built from
-- tostring) every tick. Now the drag-down check (which must catch the kill) runs every tick and the
-- rest every K.PROTECT_MS.
K.PROTECT_MS = 200
local function protect(r, p, t)
	if t >= (r.nextProtect or 0) then
		r.nextProtect = t + K.PROTECT_MS
		r.godNow = isGod(p)
		r.protectDue = true
	end
	if r.godNow then return end
	if K.noDragDeath(p) then
		r.dragSaves = (r.dragSaves or 0) + 1
		T.trace("drag-down cleared (the game was about to kill you under a pile of zombies)")
	end
	if not r.protectDue then return end
	r.protectDue = nil
	local st = r.phase == "step" and r.steps[r.si] or nil
	if st and st.kind == "fight" then return end
	-- a hit shows as health under full before the heal below (the step's own check came after it)
	local h = playerHealth(p)
	if h and h < 0.999 then r.hitsTaken = (r.hitsTaken or 0) + 1 end
	TG.keepAlive(p)
	local down = K.isDown(p)
	if down or (r.plan.zone and not st) then
		local n = TG.guardRing(p)
		if n > 0 then
			r.rescues = (r.rescues or 0) + n
			if st then st.rescues = (st.rescues or 0) + n end
			T.trace(string.format("%d zombies within 2.2 tiles put down (%s)", n, down and "you were down" or "between steps"))
		end
	end
end

-- Heartbeat: OnRenderTick fires even while the game is paused (OnTick doesn't), so every 10 s of a
-- run it traces the phase, whether the game is paused and how many game ticks ran, which tells a
-- paused game from a stuck step.
K.hb = { ticks = 0 }
-- 1.13.12 (review of 1.13.11): Test Ground Capture 1.0.3 stops a film that hears nothing for 10 s
-- (a run that never finishes: a quit to the menu, a Lua error), so it is told every second. 1.13.13
-- (review of 1.13.12): from here, the render tick, so a pause of 10 s or more doesn't stop the film
-- (OnTick doesn't fire while paused). A false answer means Capture has stopped it: said once.
function K.filmAliveTick(r, t)
	if not r.filming or t < (r.filmAliveT or 0) then return end
	r.filmAliveT = t + 1000
	local ok, alive = K.filmCall("filmAlive")
	if ok and alive == false and not r.filmLost then
		r.filmLost = true
		local okS, why = K.filmCall("filmStatus")
		T.trace("film: Test Ground Capture stopped the film: " .. tostring(okS and why or "no status"))
	end
end
function K.heartbeat()
	K.viewBackTick()
	local r = S.run
	if not r then K.hb.next = nil; return end
	local t = now()
	K.filmAliveTick(r, t)
	K.filmRetryTick(r, t)
	if not K.hb.next then K.hb.next, K.hb.ticks = t + 10000, 0; return end
	if t < K.hb.next then return end
	K.hb.next = t + 10000
	local paused, spd = false, "?"
	pcall(function() paused = isGamePaused() end)
	if paused then r.pausedBeats = (r.pausedBeats or 0) + 1 end
	pcall(function() spd = tostring(getGameSpeed()) end)
	local st = r.steps and r.steps[r.si]
	T.trace(string.format("heartbeat: %s%s, paused %s, game speed %s, %d game ticks in 10 s%s", r.phase,
		st and (" step " .. r.si .. " " .. tostring(st.tag or st.kind)) or "", tostring(paused), spd, K.hb.ticks,
		r.loadingSince and ", waiting for the start to load" or ""))
	K.hb.ticks = 0
	K.flushTrace(r)
end

-- 1.12.6: in-game screenshots (the plan's "screenshot = N [kinds]"), through the game's own
-- takeScreenshot(name) (Core.TakeFullScreenshot: glReadPixels of the window's FRONT buffer, written
-- as a PNG to Zomboid/Screenshots on the render thread). That is what is on the screen, so a covered
-- or minimised window gives an empty picture (drive view run 2: 45 blank shots). 1.13.7: with Test
-- Ground Capture (a ZombieBuddy submod, global TGCapture) the shot is its back-buffer or world read
-- instead (plan "capture = auto|back|world|both|game"); the game's own is the fallback.
-- Each one costs a frame, so the step's fps includes them.
K.SHOT_MAX = 400
-- 1.13.11: the plan's "film = <fps> <width>" through Test Ground Capture 1.0.2's film mode. Every
-- call is guarded: without the submod (or an older one) the run goes on and the report says why.
function K.filmCall(name, a, b, c)
	if not (TGCapture and TGCapture[name]) then return false, "Test Ground Capture 1.0.2+ is not installed" end
	local f = TGCapture[name]
	-- the exposed Java methods take exactly their own arguments
	return pcall(function()
		if c ~= nil then return f(a, b, c) elseif b ~= nil then return f(a, b) elseif a ~= nil then return f(a) end
		return f()
	end)
end
-- 1.13.15 (showcase trial 2: the saved Info and Status windows covered the view in every frame): plan
-- "ui = hide" hides every open game window (a UI element with a title bar, or a type named ...Window)
-- for the run and shows the same ones again at the end; it never closes them, so the layout is kept.
function K.hideUi(r)
	if r.plan.ui ~= "hide" then return end
	r.uiHidden = {}
	local types = {}
	pcall(function()
		local list = UIManager.getUI()
		for i = 0, list:size() - 1 do
			local el = list:get(i)
			local tbl = el and el:getTable()
			if tbl and el:isVisible() then
				local ty = tostring(tbl.Type or "")
				if (tbl.titlebarbkg ~= nil or string.find(ty, "Window", 1, true)) and not string.find(ty, "TestGround", 1, true) then
					r.uiHidden[#r.uiHidden + 1] = el
					types[#types + 1] = ty ~= "" and ty or "?"
				end
			end
		end
	end)
	for _, el in ipairs(r.uiHidden) do pcall(function() el:setVisible(false) end) end
	local line = string.format("ui: %d game window%s hidden for the run%s", #r.uiHidden, #r.uiHidden == 1 and "" or "s",
		#types > 0 and (" (" .. table.concat(types, ", ") .. ")") or "")
	out(line); T.trace(line)
end
-- 1.13.19 (the user: Radio Trader and other mods show a pop-up the first time a save loads), reworked
-- 1.13.20 (review of 1.13.19): during the settle, a window is shut only if its class name says it is a
-- notice (Welcome, Popup, News, Changelog, Splash, Notice, Bulletin, Update, Intro, Modal) AND the class
-- itself, not a method a mod patched onto a vanilla class, was written in a mod's Lua file (its own new,
-- createChildren, render or close). Never the game's own windows or ones a player keeps open, and not
-- a mod's panels that stay (they carry no notice name). It is hidden, or closed by the class's own
-- close when the mod wrote one; never removed from the UI manager, so a mod showing it again works.
-- The mod stays on and is measured. popups = keep turns it off.
K.POPUP_WORDS = { "Welcome", "Popup", "PopUp", "News", "Changelog", "ChangeLog", "Splash", "Notice", "Bulletin", "Update", "Intro", "Modal" }
K.POPUP_KEEP = { ISInventoryPage = true, ISChat = true, ISEquippedItem = true, ISCharacterInfoWindow = true, ISUserPanelUI = true,
	ISPlayerStatsUI = true, ISPlayerDataObject = true, ISHealthPanel = true, ISCraftingUI = true, MainScreen = true }
K.POPUP_OWN = { "new", "createChildren", "render", "prerender", "close", "initialise" }
K.POPUP_SCAN_MS = 500
function K.popupOrigin(cls)
	if type(cls) ~= "table" or not getFilenameOfClosure then return nil end
	for _, k in ipairs(K.POPUP_OWN) do
		local f = rawget(cls, k)
		if type(f) == "function" then
			local ok, fn = pcall(getFilenameOfClosure, f)
			if ok and fn then return tostring(fn), k end
		end
	end
	return nil
end
function K.fromMod(fn)
	if not fn then return false end
	local l = string.lower((string.gsub(fn, "\\", "/")))
	if string.find(l, "testground", 1, true) then return false end
	-- a mod's file lives under .../mods/<id>/ or the Workshop folder (content/108600/<item>/mods/<id>/)
	return string.find(l, "/mods/", 1, true) ~= nil or string.find(l, "/108600/", 1, true) ~= nil
end
function K.popupTick(r, t)
	if r.plan.popups == "keep" or r.phase ~= "settle" or t < (r.popupNext or 0) then return end
	r.popupNext = t + K.POPUP_SCAN_MS
	r.popupSeen = r.popupSeen or {}
	local shut = {}
	pcall(function()
		local list = UIManager.getUI()
		for i = list:size() - 1, 0, -1 do
			local el = list:get(i)
			local tbl = el and el:getTable()
			if tbl and el:isVisible() and not r.popupSeen[tbl] then
				local ty = tostring(tbl.Type or "")
				local named = false
				for _, w in ipairs(K.POPUP_WORDS) do if string.find(ty, w, 1, true) then named = true end end
				if named and not K.POPUP_KEEP[ty] and not string.find(ty, "TestGround", 1, true) then
					r.popupSeen[tbl] = true
					local cls = getmetatable(tbl)
					local fn, how = K.popupOrigin(cls)
					-- 1.13.21 (review of 1.13.20): only a class a mod wrote; a vanilla dialog (even one the game is
					-- waiting on, or a mod opened with the vanilla class) is left alone
					if K.fromMod(fn) then
						shut[#shut + 1] = { el = el, tbl = tbl, cls = cls, ty = ty ~= "" and ty or "?", fn = fn }
					end
				end
			end
		end
	end)
	for _, w in ipairs(shut) do
		local how = "hidden"
		local own = w.cls and rawget(w.cls, "close")
		local ownMod = false
		if type(own) == "function" and getFilenameOfClosure then
			local okF, fn = pcall(getFilenameOfClosure, own)
			ownMod = okF and K.fromMod(fn)
		end
		local ok = pcall(function()
			if ownMod then how = "the mod's own close"; w.tbl:close() else w.el:setVisible(false) end
		end)
		if ok and w.el:isVisible() then pcall(function() w.el:setVisible(false) end); how = how .. ", then hidden" end
		r.popups = (r.popups or 0) + 1
		local short = string.match(w.fn, "mods[/\\]([^/\\]+)") or w.fn
		local line = string.format("popups: shut %s from %s, %.1f s into the run (%s)%s", w.ty, short, (t - r.t0) / 1000, how, ok and "" or " FAILED")
		out(line); T.trace(line)
	end
end
function K.showUi(r)
	for _, el in ipairs(r.uiHidden or {}) do pcall(function() el:setVisible(true) end) end
	r.uiHidden = nil
end

function K.filmBegin(r)
	local f = r.plan.film
	if not f then return end
	r.filmDir = string.gsub(r.plan.label .. "_" .. tostring(r.id), "[^%w%._%-]", "_")
	if TGCapture and TGCapture.filmMaxMinutes then K.filmCall("filmMaxMinutes", f.minutes or 20) end
	if f.quality and TGCapture and TGCapture.filmQuality then K.filmCall("filmQuality", f.quality) end
	local ok, res = K.filmCall("filmStart", r.filmDir, f.fps, f.width)
	if ok and res ~= false then
		r.filming = true
		K.filmCall("filmTag", "settle")
		local okS, stt = K.filmCall("filmStatus")
		T.trace(string.format("film: %d fps at %d wide to Zomboid/Lua/film/%s/ (%s)", f.fps, f.width, r.filmDir, okS and tostring(stt) or "?"))
	else
		r.filmWhy = ok and "filmStart refused" or tostring(res)
		-- 1.13.16: Capture 1.0.5 refuses while the last run's film is still stopping (at most a few
		-- seconds, on its own threads): asked again every 500 ms for up to K.FILM_RETRY_MS
		local okS, stt = K.filmCall("filmStatus")
		if ok and okS and stt then r.filmWhy = "filmStart refused: " .. tostring(stt) end   -- 1.13.17: with Capture's reason
		if ok and okS and string.find(tostring(stt), "still stopping", 1, true) and not r.filmRetryUntil then
			r.filmRetryUntil, r.filmRetryT = now() + K.FILM_RETRY_MS, now() + 500
			T.trace("film: the last film is still stopping; trying again")
			return
		end
		T.trace("film: not filming: " .. r.filmWhy)
	end
end
K.FILM_RETRY_MS = 5000
function K.filmRetryTick(r, t)
	if not r.filmRetryUntil or r.filming or t < (r.filmRetryT or 0) then return end
	r.filmRetryT = t + 500
	local f = r.plan.film
	local ok, res = K.filmCall("filmStart", r.filmDir, f.fps, f.width)
	if ok and res ~= false then
		r.filming, r.filmRetryUntil, r.filmWhy = true, nil, nil
		K.filmCall("filmTag", r.phase == "step" and r.steps[r.si] and r.steps[r.si].tag or "settle")
		T.trace("film: started on a later try")
	elseif t >= r.filmRetryUntil then
		r.filmRetryUntil = nil
		T.trace("film: not filming: " .. tostring(r.filmWhy))
	end
end

function K.captureOn(mode)
	return mode ~= "game" and not K.capBroken and TGCapture ~= nil and type(TGCapture) ~= "nil"
end
-- the drive view overlay goes to the capture too (a world shot has no game UI on it)
function K.captureWantsOverlay()
	if not K.captureOn("auto") then return false end
	local ok, w = pcall(function() return TGCapture.wantsOverlay() end)
	return ok and w == true
end
K.SHOT_DEFAULT_S = 5
function K.screenshotTick(r, st, t)
	local sh = r.plan.screenshot
	if not sh or K.broken.screenshot then return end
	if sh.kinds and not sh.kinds[st.kind] and not sh.kinds[string.lower(st.tag or "")] then return end
	if (r.shots or 0) >= K.SHOT_MAX then return end
	st.shotNext = st.shotNext or (t + 1000)
	if t < st.shotNext then return end
	st.shotNext = t + sh.every * 1000
	st.shotN = (st.shotN or 0) + 1
	local name = string.format("TestGround_%s_%s_p%d_s%02d_%s_%03d.png", r.plan.label, tostring(r.id), r.pass or 1, r.si or 0, st.tag or st.kind, st.shotN)
	name = string.gsub(name, "[^%w_%.%-]", "_")
	local ok
	local mode = r.plan.capture or "auto"
	if K.captureOn(mode) then
		local okC, taken = pcall(function() return TGCapture.request(name, mode) end)
		if not okC then
			K.capBroken = tostring(taken)
			T.trace("screenshot: Test Ground Capture failed (" .. K.capBroken .. "); the game's own screenshots from here")
		elseif not taken then
			T.trace("screenshot " .. name .. " skipped: the last capture isn't finished")
			return
		else
			ok = true
			local okL, lr = pcall(function() return TGCapture.lastResult() end)
			if okL and lr and lr ~= r.capLast then r.capLast = lr; T.trace("capture: " .. tostring(lr)) end
		end
	end
	if not ok then ok = K.tryOnce("screenshot", function() takeScreenshot(name) end) end
	if ok then
		-- 1.13.10 (review of 18 Oct): st.screenshots, as a gunfight counts its fired shots in st.shots
		r.shots, st.screenshots = (r.shots or 0) + 1, (st.screenshots or 0) + 1
		T.trace("screenshot " .. name)
	end
end

-- 1.13.2: what's running, in large text at the top centre of the screen for the whole run (the
-- user watches runs). Plan "banner = 0" turns it off. Two DrawStringCentre calls a frame.
K.BANNER_Y = 0.1
function K.bannerText(r, t)
	if r.phase == "settle" then return "Test Ground: " .. r.plan.label, r.loadingSince and "waiting for the start to load" or "settling" end
	local st = r.steps[r.si]
	if not st then return nil end
	if r.phase == "gap" then return "Test Ground: " .. r.plan.label, "next: " .. st.text end
	local sub = string.format("step %d of %d%s, %d s", r.si, #r.steps, r.plan.rep > 1 and (", pass " .. st.pass) or "", floor((t - st.t0) / 1000))
	return string.format("TEST: %s (%s)", st.tag or st.kind, K.groupOf(st.kind) or st.kind), sub .. "   " .. st.text
end
function K.drawBanner()
	local r = S.run
	if not r or r.plan.banner == false then return end
	pcall(function()
		local big, small = K.bannerText(r, now())
		if not big then return end
		local c, tm = getCore(), getTextManager()
		local x, y = c:getScreenWidth() / 2, c:getScreenHeight() * K.BANNER_Y
		tm:DrawStringCentre(UIFont.Large, x + 2, y + 2, big, 0, 0, 0, 0.85)
		tm:DrawStringCentre(UIFont.Large, x, y, big, 1, 0.9, 0.3, 1)
		if small then
			local dy = tm:getFontHeight(UIFont.Large) + 4
			tm:DrawStringCentre(UIFont.Medium, x + 1, y + dy + 1, small, 0, 0, 0, 0.85)
			tm:DrawStringCentre(UIFont.Medium, x, y + dy, small, 1, 1, 1, 1)
		end
	end)
end

local function onTick()
	if not S.run then return end
	local r = S.run
	K.hb.ticks = K.hb.ticks + 1
	local t = now()
	local okP, paused = pcall(isGamePaused)
	if okP and paused then
		-- 1.13.2: a pause isn't a frame: the step's frame clock stops here and starts again on the
		-- first tick after it (up to 1.13.1 the whole pause was one long frame in worst/p99/hitches)
		local st = r.phase == "step" and r.steps[r.si]
		if st and st.frames then
			st.frames.pauseFrom = st.frames.pauseFrom or t
			st.frames.last = nil
		end
		r.lastT = t
		return
	end
	local dt = r.lastT and (t - r.lastT) or 0
	r.lastT = t
	local p = r.p
	if not p or p:isDead() then finish(r, "player gone"); return end

	if t >= (r.nextZoom or 0) then
		r.nextZoom = t + K.ZOOM_CHECK_MS
		local z, mx, at = zoomOut(r)
		if at and not r.zoomedAt then
			r.zoomedAt = t
			T.trace(string.format("zoomed out to the maximum (%.2f)", mx))
		elseif z and not at and r.zoomedAt and t - (r.zoomSaid or 0) > 10000 then
			r.zoomSaid = t
			T.trace(string.format("zoom was %.2f, back out to %.2f", z, mx))
		end
	end

	if r.plan.zombies == "none" and not r.holdSweep and t - r.lastZombieSweep >= 2000 then
		r.lastZombieSweep = t
		removeZombies()
	end

	protect(r, p, t)
	K.popupTick(r, t)

	if r.phase == "settle" then
		if r.loadingSince then
			local st0 = r.plan.start
			local loaded = areaLoaded(st0.x, st0.y, st0.z)
			if loaded or t - r.loadingSince >= K.SPOT_LOAD_MS then
				local waited = (t - r.loadingSince) / 1000
				r.loadWait = string.format("%s after %.1f s", loaded and "loaded" or "still NOT loaded", waited)
				T.trace("start " .. r.loadWait)
				out("start " .. r.loadWait .. " (the settle counts from there)")
				out("")
				r.loadingSince = nil
				r.phaseT = t        -- the settle time counts from here
				pcall(setZombies, r)
			end
			return
		end
		if r.plan.viewpoint and not r.viewDone then
			r.viewJob = r.viewJob or { want = r.plan.viewpoint, log = T.trace }
			local s = K.viewStep(r.viewJob, t)
			if s == "busy" then return end
			r.viewDone = true
			local j = r.viewJob
			if s == "done" then r.viewAt = r.plan.viewpoint end
			local line = s == "done" and string.format("viewpoint: %s view on after %d cycle%s of Viewpoint.View in %.1f s (the settle counts from here)", r.plan.viewpoint, j.cycles, j.cycles == 1 and "" or "s", (t - (j.t0 or t)) / 1000)
				or (K.viewApi() and string.format("viewpoint: COULD NOT reach the %s view (%s); left as it is", r.plan.viewpoint, tostring(j.why))) or nil
			if line then out(line); out(""); T.trace(line) end
			r.phaseT = t
			return
		end
		if t - r.phaseT >= r.plan.settle * 1000 then
			r.si = 1
			r.pass = r.steps[1].pass
			r.phase = "step"
			beginStep(r, t)
		end
		return
	end

	if r.phase == "gap" then
		-- Short unmeasured gap between steps so one step's tail doesn't land in the next.
		if t - r.phaseT >= 2000 then
			r.phase = "step"
			beginStep(r, t)
		end
		return
	end

	local st = r.steps[r.si]
	if st.frames.pauseFrom then
		-- the step's own clock skips the pause too, so it still runs its full length
		local ms = t - st.frames.pauseFrom
		st.frames.paused = st.frames.paused + ms
		st.t0 = st.t0 + ms
		st.frames.pauseFrom = nil
	end
	local gap = st.frames.last and (t - st.frames.last) or nil
	frameTick(st.frames, t)
	if gap then perfFrame(r, st, t, gap) end
	pcall(stallWatch, r, st, p, t)
	K.screenshotTick(r, st, t)
	if t - (r.lastSample or 0) >= SAMPLE_MS then
		r.lastSample = t
		T.trace(string.format("pos %.1f,%.1f,%d %s z%d", p:getX(), p:getY(), floor(p:getZ()), stateName(p), countZombies()))
	end
	local done = st.skip ~= nil
	if not done then
		local ok, res = pcall(Steps[st.kind].tick, r, st, t, dt)
		if not ok then
			st.skip = "error: " .. tostring(res)
			say("step error: " .. tostring(res))
			done = true
		else
			done = res
		end
	end
	if done then
		endStep(r, t)
		r.si = r.si + 1
		if r.si > #r.steps then
			finish(r, nil)
			return
		end
		r.pass = r.steps[r.si].pass
		r.phase, r.phaseT = "gap", t
	end
end


-- Survey -----------------------------------------------------------------------------------
-- Builds a plan from the area around you, so nothing has to be marked by hand. It scans the
-- squares within RADIUS on your floor, a few rows per tick, and picks:
--   route    four free squares on a loop around you (walk step)
--   road     the ends of the longest straight run of street tiles (stream step)
--   walkto   one open walk (control), up to 2 tall-wall crossings, 1 low fence, up to 2 locked
--            or barricaded closed doors and 1 unlocked closed door, each from 2 tiles on one
--            side to 1 tile past the other; and up to 2 ladders, walked to the floor above with
--            Walk To Plus. Expectations are "any": the outcome is recorded, not judged.
-- The plan is written to Zomboid/Lua/TestGround_survey.txt (your own plan file is left alone),
-- and every feature found (up to 60 of each, nearest first) to TestGround_site.txt, so plans for
-- other tests can be written from it.

local SURVEY_FILE = "TestGround_survey.txt"
local SITE_FILE = "TestGround_site.txt"
local BASELINE_FILE = "TestGround_baseline.txt"
local BASELINE_CONTAINERS = 6

-- Other mods can look for their own things during a survey: finder.square(state, sq, x, y, z)
-- per scanned square, finder.finish(state, cx, cy, z) -> lines for TestGround_site.txt.
T.finders = {}

TG.BASELINE_CONTAINERS, TG.BASELINE_FILE, TG.PERF_HEAD, TG.SAMPLE_MS, TG.SITE_FILE, TG.SLOW_BOOKKEEPING_MS = BASELINE_CONTAINERS, BASELINE_FILE, PERF_HEAD, SAMPLE_MS, SITE_FILE, SLOW_BOOKKEEPING_MS
TG.SPIKE_HEAD, TG.SPIKE_MS, TG.STALL_MS, TG.STALL_TILES, TG.SURVEY_FILE, TG.beginStep = SPIKE_HEAD, SPIKE_MS, STALL_MS, STALL_TILES, SURVEY_FILE, beginStep
TG.endStep, TG.finish, TG.header, TG.onTick, TG.perfFlush, TG.perfFrame = endStep, finish, header, onTick, perfFlush, perfFrame
TG.phaseOf, TG.profiler, TG.protect, TG.restore, TG.setScene, TG.setZombies = phaseOf, profiler, protect, restore, setScene, setZombies
TG.stallWatch, TG.waitingFor, TG.zoomOut = stallWatch, waitingFor, zoomOut
