#!/usr/bin/env python3
"""Mock test for Lua Event Profiler 2: runs the real Lua file under lupa against fake Events,
a fake clock in which handlers, print and file writes take time, and fake mod files."""
import os
import sys
import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
NEW = os.path.join(HERE, "LuaEventProfiler2/42/media/lua/shared/!!!LuaEventProfiler2.lua")
OLD = os.path.join(HERE, "LuaEventProfiler/42/media/lua/shared/!!!LuaEventProfiler.lua")

HARNESS = r"""
next = nil            -- Kahlua has no next()
clock = 0             -- ms, fractional; getTimestampMs floors it like the real 1 ms timer
function getTimestampMs() return math.floor(clock) end
function advance(ms) clock = clock + ms end
printed = {}
printCost = 0.5       -- a console line costs this many ms
function print(s) printed[#printed + 1] = { t = clock, s = tostring(s) }; advance(printCost) end
files = {}
function getFileWriter(name, create, append)
  local f = { lines = {}, closed = false }
  files[name] = f
  return { writeln = function(self, l) f.lines[#f.lines + 1] = l; advance(0.2) end,
           close = function(self) f.closed = true end }
end
pathOf = setmetatable({}, { __mode = "k" })
function getFilenameOfClosure(fn) return pathOf[fn] end
function getSpecificPlayer() return nil end
function getAverageFPS() return 60 end

local function newEvent()
  local e = { list = {} }
  e.Add = function(fn) e.list[#e.list + 1] = fn end
  e.Remove = function(fn)
    for i = #e.list, 1, -1 do if e.list[i] == fn then table.remove(e.list, i) end end
  end
  return e
end
Events = {}
for _, n in ipairs({ "OnGameBoot", "OnGameStart", "OnTick", "OnPlayerUpdate", "LoadGridsquare" }) do
  Events[n] = newEvent()
end
function fire(name, ...)
  local l = Events[name].list
  for i = 1, #l do l[i](...) end
end

-- A handler defined in a fake mod file that costs ms(callNumber) each call.
function modHandler(mod, file, cost)
  local n = 0
  local fn = function() n = n + 1; advance(cost(n)) end
  pathOf[fn] = "C:/Users/x/Zomboid/mods/" .. mod .. "/42/media/lua/client/" .. file
  return fn
end
"""


def fresh(load_old=False, no_coroutine=False):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(HARNESS)
    if no_coroutine:
        lua.execute("coroutine = nil")
    if load_old:
        lua.execute(open(OLD, encoding="utf-8").read())
    lua.execute(open(NEW, encoding="utf-8").read())
    return lua


fails = 0


def check(cond, msg):
    global fails
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        fails += 1


def lines(lua, start=1):
    p = lua.globals().printed
    return [p[i].s for i in range(start, len(p) + 1)]


SETUP = r"""
-- An expensive handler (2 ms a call), a cheap frequent one (1 ms every 40th call, so 25 us
-- average), and one with a rare 12 ms call.
heavy = modHandler("HeavyMod", "Heavy.lua", function(n) return 2 end)
cheap = modHandler("CheapMod", "Cheap.lua", function(n) return (n % 40 == 0) and 1 or 0 end)
spiky = modHandler("SpikyMod", "Spiky.lua", function(n) return (n == 300) and 12 or 0 end)
gone = modHandler("GoneMod", "Gone.lua", function(n) return 5 end)
Events.OnTick.Add(heavy)
for i = 1, 10 do Events.OnPlayerUpdate.Add(cheap) end   -- ten registrations, same function
Events.OnTick.Add(spiky)
Events.OnTick.Add(gone)
Events.OnTick.Remove(gone)
fire("OnGameBoot")
fire("OnGameStart")
tickWork = {}   -- ms of clock spent per tick outside the fake handlers' own cost
function runTicks(n, frameMs)
  for i = 1, n do
    local t0 = clock
    fire("OnTick")
    fire("OnPlayerUpdate")
    tickWork[#tickWork + 1] = clock - t0
    advance(frameMs or 16)
  end
end
"""


def main_test():
    print("== Lua Event Profiler 2: wrapping, amortized report, sampling ==")
    lua = fresh()
    g = lua.globals()
    lua.execute(SETUP)
    P = g.LuaEventProfiler
    check(P.version == "2.5", "version 2.5 is the running profiler")
    check(lua.eval("#Events.OnTick.list") == 3, "OnTick has our tick, heavy and spiky (gone was removed)")
    check(lua.eval("LuaEventProfiler.originalOf[Events.OnTick.list[2]] == heavy"),
          "originalOf maps the wrapper back to the handler")
    check(any("active (2.5)" in s for s in lines(lua)), "prints an active line")

    # Window 1: 30 s at 16 ms frames (heavy handler adds 2 ms per tick).
    mark = len(g.printed) + 1
    lua.execute("runTicks(1700)")
    out = lines(lua, mark)
    check(any("spike 12 ms [SpikyMod]" in s for s in out), "spike line is queued and printed")
    heads = [s for s in out if "] last " in s]
    check(len(heads) == 1, "one report in the first window")
    import re as _re
    m = _re.search(r"fps (\d+) over the window", heads[0]) if heads else None
    check(m is not None and 50 <= int(m.group(1)) <= 70, "header gives the window's own frame rate (%s)" % (m.group(1) if m else "none"))
    check(any("[HeavyMod]" in s for s in out) and any("[CheapMod]" in s for s in out),
          "report lists both mods")
    check(not any("GoneMod" in s for s in out), "removed handler is gone")
    f = g.files["LuaEventProfiler.txt"]
    check(f is not None and f.closed and len(f.lines) > 10, "report file written and closed")
    cats = [s for s in out if "worst:" in s]
    check(any("-- by category, this window --" in s for s in out), "report has a by-category list")
    check(any(" tick " in s and "HeavyMod" in s and "SpikyMod" in s for s in cats),
          "tick category names its worst mods: " + str([c for c in cats if " tick " in c][:1]))
    check(any("player update" in s and "CheapMod" in s for s in cats), "player update category names CheapMod")
    flines = [f.lines[i] for i in range(1, len(f.lines) + 1)]
    check(any("-- by category, whole session --" in l for l in flines)
          and any("-- by event, whole session --" in l for l in flines), "file has session category and event lists")
    check(any("OnPlayerUpdate" in l and "worst: CheapMod" in l for l in flines), "event list names OnPlayerUpdate's worst mod")

    # How was the report work spread? Ticks that did report work, from the report's own count
    # in the next header, and the worst tick overall apart from the 12 ms spike.
    work = sorted(float(x) for x in g.tickWork.values())
    check(work[-2] <= 2.5 + 3, "worst tick apart from the spike: %.1f ms (handlers 2.5 ms + about 2 ms budget)" % work[-2])

    # Window 2: the cheap handler should now be sampled.
    mark = len(g.printed) + 1
    lua.execute("runTicks(1900)")
    out = lines(lua, mark)
    cheap_lines = [s for s in out if "[CheapMod]" in s and "Cheap.lua" in s]
    check(any("~OnPlayerUpdate" in s for s in cheap_lines), "cheap handler is marked as sampled (~)")
    heavy_lines = [s for s in out if "[HeavyMod]" in s and "Heavy.lua" in s]
    check(heavy_lines and "~" not in heavy_lines[0], "heavy handler is not sampled")
    # The report after window 2 shows window 2 timed on samples: true cost 25 us/call.
    lua.execute("runTicks(1900)")
    out = lines(lua, mark)
    cheap_lines = [s for s in out if "[CheapMod]" in s and "Cheap.lua" in s]
    us = float(cheap_lines[-1].split("calls")[1].split("us/call")[0])
    check(15 <= us <= 35, "sampled estimate %.1f us/call is close to the true 25" % us)
    heads = [s for s in out if "] last " in s]
    check(any("last report took" in s for s in heads), "header reports the previous report's cost")
    took = heads[-1].split("last report took ")[1]
    ticks = int(took.split(" over ")[1].split(" ticks")[0])
    most = int(took.split("at most ")[1].split(" ms")[0])
    check(ticks >= 4 and most <= 2, "report spread over %d ticks, at most %d ms in one" % (ticks, most))

    # Hitch: a 250 ms gap between ticks.
    mark = len(g.printed) + 1
    lua.execute("runTicks(1); advance(250); runTicks(5)")
    check(any("hitch" in s and "between ticks" in s for s in lines(lua, mark)), "hitch line printed")

    # mark(label) ends the window early and tags the next report.
    mark = len(g.printed) + 1
    lua.execute('LuaEventProfiler.mark("drive"); runTicks(2); LuaEventProfiler.mark("walk"); runTicks(300)')
    out = lines(lua, mark)
    check(any("phase drive" in s for s in out), "report for a marked window carries its phase")

    # quiet stops the 30 s report; takeWindow returns a window's lines without printing.
    mark = len(g.printed) + 1
    lua.execute("LuaEventProfiler.takeWindow(); LuaEventProfiler.quiet = true; runTicks(2500)")
    check(not any("] last " in s for s in lines(lua, mark)), "quiet: no automatic report")
    got = lua.eval("LuaEventProfiler.takeWindow(40)")
    got = [got[i] for i in range(1, len(got) + 1)]
    check(got and "Lua in handlers:" in got[0], "takeWindow returns lines: " + (got[0] if got else "none"))
    check(any("[HeavyMod]" in l for l in got) and not any("] last " in s for s in lines(lua, mark)),
          "takeWindow lists the heavy mod and prints nothing")
    cl = [l for l in got if "Cheap.lua" in l]
    us = float(cl[0].split("calls")[1].split("us/call")[0]) if cl else -1
    check(15 <= us <= 35, "sampled cheap handler (1 ms every 40th call) reads %.1f us/call, true 25" % us)
    lua.execute("LuaEventProfiler.quiet = false")

    # report() writes out now, in one go.
    mark = len(g.printed) + 1
    lua.execute("runTicks(100); LuaEventProfiler.report()")
    check(any("] last " in s for s in lines(lua, mark)), "report() prints at once")


def old_vs_new():
    print("== version 1 on the same mock, for comparison ==")
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(HARNESS)
    lua.execute(open(OLD, encoding="utf-8").read())
    lua.execute(SETUP)
    lua.execute("runTicks(3800)")
    work = sorted(float(x) for x in lua.globals().tickWork.values())
    print("     version 1 worst tick apart from the spike: %.1f ms (its report, all in one tick)" % work[-3])


def old_first():
    print("== both profilers enabled ==")
    lua = fresh(load_old=True)
    check(lua.eval("LuaEventProfiler.version") is None, "version 1 keeps running")
    check(any("stands down" in s for s in lines(lua)), "version 2 says it stands down")


def no_coroutine():
    print("== no coroutine library: report in one tick ==")
    lua = fresh(no_coroutine=True)
    lua.execute(SETUP)
    mark = len(lua.globals().printed) + 1
    lua.execute("runTicks(1900)")
    out = lines(lua, mark)
    check(any("] last " in s for s in out) and any("[HeavyMod]" in s for s in out), "report still made")
    check(not any("report failed" in s for s in out), "no errors")


def vehicles():
    print("== vehicle script functions: wrapped at start, file looked up only when reported ==")
    lua = fresh()
    lua.execute(r"""
      Vehicles = { Update = {} }
      for i = 1, 300 do Vehicles.Update["Part" .. i] = modHandler("CarMod", "Car.lua", function(n) return 0 end) end
      Vehicles.Update.Engine = modHandler("CarMod", "Engine.lua", function(n) return 3 end)
      lookups = 0
      local real = getFilenameOfClosure
      getFilenameOfClosure = function(fn) lookups = lookups + 1; return real(fn) end
      fire("OnGameBoot"); fire("OnGameStart")
      startLookups = lookups
      for i = 1, 100 do Vehicles.Update.Engine(); fire("OnTick"); advance(16) end
      LuaEventProfiler.report()
    """)
    check(lua.eval("startLookups") < 5, "no file lookups for 301 vehicle functions at start (%d)" % lua.eval("startLookups"))
    out = lines(lua)
    check(any("[CarMod]" in s and "Vehicles.Update.Engine  client/Engine.lua" in s for s in out),
          "a called vehicle function is reported with its mod and file")
    check(lua.eval("lookups") - lua.eval("startLookups") <= 3, "only the called function's file was looked up")


def hot_path_has_no_table_reads():
    print("== the wrapper's own code reads no table fields (pzopt logs table reads inside UI draws) ==")
    import re
    src = open(NEW, encoding="utf-8").read()
    start = src.index("local function timed(")
    body = src[src.index("\treturn function(...)", start):]
    body = body[:body.index("\n\tend\nend\n")]
    code = "\n".join(l.split("--")[0] for l in body.splitlines())
    reads = re.findall(r"[A-Za-z_][A-Za-z0-9_]*\s*(?:\.|\[|:)[A-Za-z_]", code)
    check(not reads, "no field reads in the wrapper: %s" % (reads or "none"))


def categories():
    print("== event categories ==")
    lua = fresh()
    want = {"OnTick": "tick", "OnTickEvenPaused": "tick", "OnRenderTick": "render events", "OnPreUIDraw": "render events",
            "OnPlayerUpdate": "player update", "OnZombieUpdate": "zombies", "EveryTenMinutes": "game clock",
            "LoadGridsquare": "chunk load", "LoadChunk": "chunk load", "OnObjectAdded": "world objects",
            "OnContainerUpdate": "world objects", "OnEnterVehicle": "vehicle events", "OnWeaponHitCharacter": "combat",
            "OnClothingUpdated": "items and inventory", "OnKeyPressed": "input", "OnClientCommand": "network",
            "OnGameStart": "loading", "OnSomethingNew": "other events"}
    got = {k: lua.eval('LuaEventProfiler.categoryOf("%s")' % k) for k in want}
    bad = {k: v for k, v in got.items() if v != want[k]}
    check(not bad, "event names map to categories: %s" % (bad or "all as expected"))


def self_time_and_add_remove():
    print("== 2.5: self time, one wrapper per handler, modOf ==")
    lua = fresh()
    lua.execute(r"""
    -- ModA's OnTick costs 1 ms itself and fires LoadGridsquare inside, where ModB costs 2 ms.
    inner = modHandler("ModB", "B.lua", function(n) return 2 end)
    Events.LoadGridsquare.Add(inner)
    local own = modHandler("ModA", "A.lua", function(n) return 1 end)
    outerFn = function() own(); fire("LoadGridsquare") end
    pathOf[outerFn] = "C:/Users/x/Zomboid/mods/ModA/42/media/lua/client/A.lua"
    Events.OnTick.Add(outerFn)
    -- added twice, removed once: like the game without the profiler, one registration is left
    twice = modHandler("ModC", "C.lua", function(n) return 0 end)
    Events.OnPlayerUpdate.Add(twice); Events.OnPlayerUpdate.Add(twice)
    Events.OnPlayerUpdate.Remove(twice)
    fire("OnGameBoot"); fire("OnGameStart")
    for i = 1, 1000 do fire("OnTick"); fire("OnPlayerUpdate"); advance(16) end
    LuaEventProfiler.report()
    rows = LuaEventProfiler.snapshot()
    byMod = {}
    for _, r in ipairs(rows) do byMod[r.mod] = (byMod[r.mod] or 0) + r.ms end
    """)
    a, b = lua.eval("byMod.ModA"), lua.eval("byMod.ModB")
    check(abs(a - 1000) < 30 and abs(b - 2000) < 30,
          "nested timed call counted once: ModA %.0f ms (1 ms x 1000), ModB %.0f ms (2 ms x 1000)" % (a, b))
    # Whatever the game's Add/Remove do with duplicates, the profiler must give the same result as
    # the plain handler. Two event models: a list that removes every copy (the harness's), and one
    # that removes a single copy.
    for model in ("all", "one", "dedupe"):
        plain = lupa.LuaRuntime(unpack_returned_tuples=True)
        prof = fresh()
        for L in (plain, prof):
            if L is plain: L.execute(HARNESS)
            L.execute("""
            local function newEvent(model)
              local e = { list = {} }
              e.Add = function(fn)
                if model == "dedupe" then for i = 1, #e.list do if e.list[i] == fn then return end end end
                e.list[#e.list + 1] = fn
              end
              e.Remove = function(fn)
                for i = #e.list, 1, -1 do if e.list[i] == fn then table.remove(e.list, i); if model ~= "all" then return end end end
              end
              return e
            end
            Events.OnPlayerMove = newEvent("%s")
            x = function() end
            """ % model)
            if L is prof: L.execute("LuaEventProfiler.rewrap('OnPlayerMove')")
            L.execute("Events.OnPlayerMove.Add(x); Events.OnPlayerMove.Add(x); Events.OnPlayerMove.Remove(x)")
        n_plain, n_prof = plain.eval("#Events.OnPlayerMove.list"), prof.eval("#Events.OnPlayerMove.list")
        check(n_plain == n_prof, "Add twice + Remove once (event model: %s): %d left, as without the profiler (%d)" % (model, n_prof, n_plain))
        if n_prof:
            check(prof.eval("LuaEventProfiler.originalOf[Events.OnPlayerMove.list[1]] == x"), "  the one left is x's wrapper")
            prof.execute("Events.OnPlayerMove.Remove(x)")
            check(prof.eval("#Events.OnPlayerMove.list") == 0, "  a second Remove takes it out")
    lua.execute(r"""
    late = modHandler("ModD", "D.lua", function(n) return 0 end)
    pathOf[late] = "D:/mods/Steam/steamapps/common/ProjectZomboid/media/lua/client/X.lua"
    Events.OnTick.Add(late)
    late2 = modHandler("ModE", "E.lua", function(n) return 0 end)
    pathOf[late2] = "D:/mods/Steam/steamapps/workshop/content/108600/1/mods/RealMod/42/media/lua/client/E.lua"
    Events.OnTick.Add(late2)
    for i = 1, 10 do fire("OnTick") end
    LuaEventProfiler.report()
    mods = {}
    for _, r in ipairs(LuaEventProfiler.snapshot()) do mods[r.mod] = true end
    """)
    check(not lua.eval("mods.Steam") and lua.eval("mods.vanilla") and lua.eval("mods.RealMod"),
          "game files under a 'mods' install folder are vanilla; a Workshop mod is named by its own folder")


main_test()
categories()
self_time_and_add_remove()
hot_path_has_no_table_reads()
vehicles()
old_vs_new()
old_first()
no_coroutine()
print("ALL PASS" if fails == 0 else "%d FAILED" % fails)
sys.exit(1 if fails else 0)
