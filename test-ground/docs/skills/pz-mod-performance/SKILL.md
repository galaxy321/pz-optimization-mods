---
name: pz-mod-performance
description: Use when a Project Zomboid Build 42 mod or modlist is slow, stutters or loads slowly, and you need to find the cost, judge whether fixing it is worth it, and change it without changing behaviour.
---

# Finding and fixing Project Zomboid mod performance problems

Draft, for the developer add-on. Measure with Test Ground (see `pz-test-ground`, `pz-read-test-report`); this skill is the judgement around it.

## 1. Measure before touching anything
1. Run a Test Ground baseline in a bench copy of the save, 3 times if you can, with Lua Event Profiler on for a second set of runs (it costs about 5 to 9 ms/s and a hitch every 30 s, so don't use those runs for fps).
2. Separate **feel** (median fps) from **stutter** (p99, worst frame, hitches over 100 ms). They have different causes and different fixes.
3. Find out what bounds the frame. In this project's runs the game was main-thread bound (GPU about 12% busy, GC pauses under 20 ms) and Lua was roughly a third of a frame. Check yours before assuming Lua.

## 2. Read profiler numbers with suspicion
- Lua Event Profiler covers handlers, mod UI render/update and vehicle scripts. Engine time (chunk loading, rendering, animation) isn't in it.
- It files wrapped work under the wrapper's mod: a mod that wraps a vanilla render gets charged for vanilla's whole draw. Look at the code before blaming a mod (a "mod" at 58 ms/s was vanilla's open Character Info window).
- Per-handler ms/s overstates what a cut buys: halving about 150 ms/s of UI drawing gave no measurable fps change. Repeats of the same setup differ by up to ~5%, so smaller differences are noise. Confirm any fix with a before/after pair.
- Worth fixing: single calls over 8 ms, frame gaps over 100 ms, and anything that scales with squares loaded or objects in the world. Usually not worth it: steady costs under ~1 ms/s.

## 3. Where cost comes from, and the fix
| Symptom | Typical cause | Fix |
|---|---|---|
| Hitch while driving | Lua on every loaded square (`LoadGridsquare`, `LoadChunk`) | Move to `MapObjects.OnLoadWithSprite`; or gate on the cheapest fact first; or queue and process a fixed number per tick |
| Hitch every 10 in-game minutes, or right after load | One big pass over many objects | Time-slice: snapshot the list, process N per `OnTick`, re-check each object is still valid, finish the old pass before starting a new one |
| Steady ms/s in `OnTick` / `OnPlayerUpdate` | Work that rarely changes done every tick | Run on a timer (every 250 ms to 1 s), cache per item type or sprite, or switch to a change event |
| Steady ms/s in UI render | Rebuilding strings/lists each draw | Cache until the data changes; fewer rows; a lower `uiRenderFPS` is the user's setting to change, not yours |
| Big loot-window cost | Rebuild on every update | Skip the rebuild when nothing changed |
| First-time hitch (animals, animation sets) | Lazy load on first use | Preload at a quiet moment (a menu or load) |
| Kahlua stalls | Big-table work in Lua (`table.sort` of tens of thousands of entries) | Constant-cost bookkeeping (running histograms) |

Patterns: cache keyed by sprite or item type (shared objects, so one answer serves every copy); hoist Java calls out of loops; test cheap conditions first; poll on a timer when you can't use an event.

## 4. Make the change without changing behaviour
1. Wrap, don't edit (see `pz-mod-writing`). Call the original; change only **when** or **how often** it runs, or skip inputs where reading its source shows it does nothing.
2. Throttling can change feel or correctness (a handler that restores armour every update, an easing camera). If running less often could let something break or look different, leave it and say why.
3. Keep a flag to turn the change off, and log one line when it stands down.
4. Re-measure with the change on and off, same save, same plan, same repeats. Report the step, run count, both numbers and the spread. Say "expected" for anything not measured.

## 5. Report
One table: step, before, after, spread, runs. Then one plain sentence on what changed for a player, and a list of leads left alone and why.

## 6. Patterns that kept recurring in this project
- **Chunk-load handlers.** Many mods add a `LoadGridsquare` (or `LoadChunk`) handler that checks every square for something rare. Together they cost tens of ms/s while driving. Fix by reading each handler and gating it on a fact that makes it a no-op (generator, special object, vehicle, container, a specific sprite); never skip a handler whose effect you haven't read, since many must run before the square is drawn (roof repair, alarms, item ageing). A "universal" skip is not possible without reading the handler: its Lua-side effects aren't visible from outside.
- **Per-tick scans** (doors, squares, inventories) whose result changes rarely: run on a timer, or on the change event.
- **Lua UI drawing** (HUDs, clocks, inventory pages): many small draws add up. Prefer the mod's own settings (fewer rows, lower refresh) over wrapping its local functions.
- **First-use loads** such as an animal type's animation set (hundreds of ms walking every game and mod file): preload at a quiet moment.
- **Load-time sweeps** that run in one tick after a save loads: cap per tick, or split and delay.
Java-level patching is out of scope here; it is a separate, riskier skill (unsigned jar, can crash the game).
