-- Test Ground 1.13.0: report modules, and the pzopt detail marks.
-- A report module is a table with any of these, each called in a pcall:
--   stepStart(run, step)        a step begins (step.tag is its phase name, step.text its plan line)
--   stepEnd(run, step, add)     a step ended; add(line) puts a line in the report under that step
--   finish(run, add)            the run ended; add(line) puts a line at the end of the report
-- Register one with TestGround.addReportModule(name, module); the per-mod cost report plugs in here.
require "TestGround/Core"
local TG = TestGroundInternal
if TG.loaded.Report then return end
TG.loaded.Report = true
local K, T, floor, now, out, say, writeLines = TG.K, TG.T, TG.floor, TG.now, TG.out, TG.say, TG.writeLines

T.reportModules = T.reportModules or {}
function T.addReportModule(name, mod)
	if type(name) ~= "string" or type(mod) ~= "table" then say("addReportModule: needs a name and a table"); return false end
	for _, m in ipairs(T.reportModules) do
		if m.name == name then m.mod = mod; return true end
	end
	table.insert(T.reportModules, { name = name, mod = mod })
	return true
end
function K.reportCall(what, ...)
	for _, m in ipairs(T.reportModules) do
		local fn = m.mod[what]
		if type(fn) == "function" then
			local ok, err = pcall(fn, ...)
			if not ok and not m.failed then
				m.failed = true
				out(string.format("report module %s: %s failed (%s); its output may be missing", m.name, what, tostring(err)))
			end
		end
	end
end

-- detail = pzopt (plan key, or pzopt found and no detail key; detail = off stops it): a start and an end mark per step, on the console as
-- "[TestGround] mark start|end <run id> p<pass> s<step> <tag> <ms>" and in TestGround_<label>_<id>_marks.txt,
-- with getTimestampMs, so pzopt's Lua sampler output can be cut into the steps.
K.MARK_FILE = "_marks.txt"
-- Whether pzopt is in this game: its Lua (media/lua/client/pzopt/) sets PzoptOptionClasses, and with
-- it active MainScreen.prerender comes from a pzopt_*.lua file. Without a detail key in the plan the
-- marks are on when either is seen.
function K.pzoptFound()
	if PzoptOptionClasses ~= nil then return "PzoptOptionClasses is set" end
	local ok, fn = pcall(function() return getFilenameOfClosure(MainScreen.prerender) end)
	if ok and type(fn) == "string" and string.find(string.lower(fn), "pzopt_", 1, true) then return "MainScreen.prerender is from " .. fn end
	return nil
end
local function detailOn(r)
	if r.detailOn == nil then
		if r.plan.detail == "pzopt" then r.detailOn, r.detailWhy = true, "detail = pzopt in the plan"
		elseif r.plan.detail == "off" then r.detailOn = false
		else
			local why = K.pzoptFound()
			r.detailOn, r.detailWhy = why ~= nil, why and ("pzopt found: " .. why)
		end
	end
	return r.detailOn
end
local function mark(r, st, what)
	local line = string.format("%s %s p%d s%d %s %d", what, tostring(r.id), r.pass or 1, r.si or 0, tostring(st.tag), now())
	print("[TestGround] mark " .. line)
	r.marks = r.marks or {}
	table.insert(r.marks, line)
end
T.addReportModule("pzopt detail", {
	stepStart = function(r, st) if detailOn(r) then mark(r, st, "start") end end,
	stepEnd = function(r, st) if detailOn(r) then mark(r, st, "end") end end,
	finish = function(r, add)
		if not detailOn(r) then return end
		local name = "TestGround_" .. r.plan.label .. "_" .. tostring(r.id) .. K.MARK_FILE
		local ok = writeLines(name, r.marks or {}, false)
		add(string.format("detail: pzopt marks for %d steps in Zomboid/Lua/%s%s (%s; getTimestampMs, the epoch-ms clock of pzopt-lua.out, which counts per second: use the whole seconds inside each step; the same lines on the console as [TestGround] mark ...)",
			floor((#(r.marks or {})) / 2), name, ok and "" or " (NOT written)", tostring(r.detailWhy)))
	end,
})
