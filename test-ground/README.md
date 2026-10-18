# Test Ground

A dev tool, not a patch. It runs a fixed test plan in a singleplayer save, so a patch can be measured and checked the same way every time instead of replaying a scenario by hand. It follows the approach of PZ Optimization's own test harness (a fixed scene, scripted movement, a log to compare runs), written in Lua and much smaller.

## What a run does

1. Teleports you to the plan's start (waiting until it has loaded) and sets the scene: time of day, weather (clear, rain or fog), zombies (none, kept, or a fixed number placed in a ring), and god mode.
2. Waits `settle` seconds for the world around you to load.
3. Runs the steps in order, `repeat` times:

| Step | What it does | Good for |
|---|---|---|
| `walk N` | Walks the `route` points N times with vanilla Walk To actions, so the path search runs | on-foot cost, loot window, Walk To Plus |
| `stream S [speed]` | Moves you along the `road` points for S seconds at driving speed (15 tiles/s by default), in ghost mode. There is no vehicle, but chunks load the way they do while driving | `LoadGridsquare` and `LoadChunk` cost (Chunk Load Sieve) |
| `idle S` | Stands still | HUD, `OnTick` and `OnPlayerUpdate` baseline |
| `turn S` | Turns on the spot every half second | loot window rebuilds (UI Throttle) |
| `wait S [speed]` | Stands still at game speed 1 to 3 (x1, x5, x20) | 10-minute timers (Hitch Fix) |
| `walkto` | Each Walk To case: teleport to its start, walk to its target, record the outcome | wall, door and ladder behaviour |
| `drive S [speed] [-1]` | Fast travel (20 tiles/s by default) out along `drive = x,y` for half of S, then back to the start, in ghost mode | driving-speed chunk loading |
| `fight N S` | Back at the start, spawns N zombies in a ring; they come at you (god mode) and are put down one at a time; leftovers removed after S seconds | zombie AI and crowd cost |
| `loot` | Walks next to each `loot = x,y,z` container, lets the loot window fill it, moves up to 3 items out and back | loot window, container fill |
| `treeroad S [speed]` | Back and forth at driving speed along the two `treeroad = x,y,z` points (the survey picks the street with the most trees on both verges) | tree rendering and sway while driving |
| `drivefast S [kmh]` | A real car along a street from the game's own street map (`shared/TestGroundRoads.lua`, made from `streets.xml`). The survey takes up to 3,600 tiles of one street, bends included (the Dixie Highway from West Point), and gives it time to match; with no long street in reach it takes the longest straight piece, then the longest straight street it can see. The console says which source won and why. The car drives at top speed, brakes and rolls round corners, gets a fresh car if it gets stuck or drifts off the centre, and turns back at the end while there's time; it glides only as a last resort | vehicle physics, engine sound and chunk loading at real car speed |
| `realfight N S` | N zombies in the fight ring, and you swing yourself through the attack input, with whatever is in your hands (bare hands shove). Nothing is put down by script | real melee contact and hit reactions |
| `stress N S [D]` | N zombies (500) spawned in a ring D to D+15 tiles out (20), 25 a tick so there's no single spawn burst, lured to you for S seconds; then every zombie and body within 45 tiles is removed. The report gives how many were alive and seen at once | zombie AI, rendering and crowd cost at scale |
| `weather W` | Sets `clear`, `rain`, `fog` or `keep` for the steps after it. Takes no time; the run's end clears it | fog and rain cost (the baseline repeats the first drive in fog) |
| `natural S [stand\|run] [R]` | The game's own zombies at the plan's `zone = x,y,z`: a noise every 4 s draws the ones nearby; you stand, or run round a ring of radius R (25). Guarded. Nothing is spawned | natural spawns and AI as players meet them |

Any word after the numbers in a step line is its phase tag (`fight 6 30 fight_small`). The tag goes in the perf files and to Lua Event Profiler 2's `mark()`. **`baseline`** (bridge) or **Go to West Point, survey and run baseline** (menu) surveys the fixed test start and runs the baseline scenario. See `perf/test-run.md`.

**The fixed test start.** `start = westpoint` in a plan is South St in West Point (11501,6949) on the vanilla map, the same in every save, so a modded save and a fresh unmodded save run from the same streets. It was picked from the game's map files: a residential street with 23 houses within 60 tiles, Main St (1,223 tiles straight) 49 tiles north, and the Dixie Highway 300 tiles away for the long drive. The survey goes there first unless told `here` (`baseline here`, or **Survey here and run baseline**), which runs where the save loaded.

**"Can't die" mode.** Outside debug mode god mode can't be turned on from Lua, so `realfight`, `stress` and `natural` restore health and clear wounds, infection, tiredness and panic every tick instead. Zombies can grab and knock you down but not kill you; if a hit still gets through between ticks, the step switches to putting down zombies within 2.2 tiles and says so. Launching the game with `-debug` makes real god mode work for `fight`.

**The natural zone.** The survey also reads the map's zombie intensity (the numbers the game spawns by) within 160 tiles, and writes `TestGround_natural.txt`, a plan for the densest 40x40 tiles with the game's own zombies kept (`run TestGround_natural.txt`).

**Zoom.** Runs zoom all the way out and keep it there, so you see as much as possible. Zooming out draws more of the world, so frame times aren't comparable with runs before 1.8.0.

4. Puts you back where you were and clears its weather, speed, ghost and god changes.

Each step is measured on its own: frames, fps, mean, p50, p95 and p99 frame time, the worst frame, and frames over 33 ms and over 100 ms. With Lua Event Profiler 1.4 enabled, it also records that step's Lua cost by mod and by handler. During a run the profiler's 30-second report is switched off, so its own hitch doesn't land inside a step.

## Output (in `%USERPROFILE%\Zomboid\Lua\`)

- `TestGround_<label>_<id>.txt`: the report. A header lists the plan, the scene and the active mods, followed by one section per step.
- `TestGround_<label>_<id>_perf.txt` and `_spikes.txt` (CSV text; the game refuses Lua writes to .csv files): one row per second (phase, position, fps, mean and worst frame, zombies), and every frame of 50 ms or more. `TestGround_*_latest.*` hold the last run under fixed names.
- `TestGround_<label>_<id>_trace.txt`: the behaviour log. It has a position and state sample every half second, every walk leg (arrived or stopped short, and where), every Walk To outcome with the states seen (e.g. `ClimbOverWallState`), and notes from other mods.

Compare two runs:

```
python3 test-ground/compare.py TestGround_sieve-off_<id>.txt TestGround_sieve-on_<id>.txt
```

This prints the median fps, p99, hitches and Lua ms/s per step for both runs, and the mods whose cost moved most. It also lists mods that were on in only one run, Walk To cases whose outcome changed, and the first point where the behaviour logs differ.

## Survey: plans without marking anything

**Test Ground > Survey here and run** (or `survey [radius] [run]` through the bridge) scans the squares within 40 tiles of you, on your floor, a few rows per tick. It writes two files to `Zomboid\Lua\`:
- `TestGround_survey.txt`: a ready plan. It has a walking loop around you, the longest straight street in range for the driving step, and Walk To cases. The cases are one open walk, up to 2 tall walls, a low fence, up to 2 locked or barricaded doors, an unlocked closed door, and up to 2 ladders (walked with Walk To Plus). Each case goes from 2 tiles on one side to 1 tile past the other, and its outcome is recorded rather than judged (`expect = any`).
- `TestGround_site.txt`: every feature it found, up to 60 of each, nearest first. Plans for a specific mod are written from this.

Mods with their own tests can extend both:
- `TestGround.addStep(kind, { begin, tick })` adds a step kind, used as `step = <kind> ...`.
- Plan lines named `<mod>.<key> = value` reach the step as `run.plan.extra["<mod>.<key>"]`.
- `TestGround.addFinder(name, square, finish)` adds lines to the site list during a survey.

## The plan

`%USERPROFILE%\Zomboid\Lua\TestGround_plan.txt` is created, with comments, the first time a save loads with the mod on. Right-click in the world and open **Test Ground** to record lines into it:
- **Set start: here**
- **Add route point: here** (for `walk`)
- **Add road point: here** (for `stream`; pick points along a long road)
- **Add Walk To case: me to here**. Afterwards, change its name and `expect` (`arrive`, `fail` or `any`). Add `| walktoplus` to walk with Walk To Plus's ladder routing.

Then **Test Ground > Run plan**. Set `autostart = 1` to start the plan by itself `autostart_delay` seconds after the save loads.

Other plan files in `Zomboid\Lua\` can be run through the bridge (`run <file>`), so one save can hold several plans, for example a driving plan and a Walk To plan.

## Bridge

About once a second while the game is unpaused, the mod reads `Zomboid\Lua\TestGround_cmd.txt`, empties it, runs each line, and appends the results to `TestGround_out.txt`. This lets runs be started and checked from outside the game.

| Command | Result |
|---|---|
| `run [planfile]` | starts a run (default `TestGround_plan.txt`) |
| `stop` | stops it and writes the report so far |
| `status` | idle or running (step, pass), position, fps, last report |
| `survey [radius] [run] [here\|westpoint]` | goes to the fixed test start (unless `here`), surveys it, writes the survey plan, site list and natural-zone plan, and runs the survey plan with `run` |
| `baseline [radius] [here\|westpoint]` | the same survey, then runs the baseline scenario (`TestGround_baseline.txt`) |
| `lua <code>` | runs one line of Lua and prints the result |

When a run ends, `=== done <report> <trace>` is appended. Only call methods you know exist through `lua`: in debug mode an error, even a caught one, can stop the game in the debugger.

## For other mods

`TestGround.note(tag, ...)` adds a line to the current run's behaviour log, and does nothing when no run is going. A patch can use it to log what it did, for example how many plants a pass checked, so two runs can be diffed. `TestGround.isRunning()` and `TestGround.start(plan)` are also there.

## Use a copy of the save

A run changes the save it runs in: in-game time passes, zombies are removed or spawned, and you are teleported (you get put back afterwards). Make a bench copy of your save (copy its folder under `Zomboid\Saves\`) and run there. Measure each variant from the same starting save so the runs match.

## Before/after a patch

The patches read their `ENABLE_` flags when the game loads. So a before/after needs two loads: one with the patch on and one with it off (in the save's mod list), each with its own `label`. Then compare the two reports.

## Limits

- Singleplayer only (client Lua, local player 0).
- `stream` is not real driving. It loads chunks at driving speed, but vehicle physics and vehicle Lua (`Vehicles.Update.*`, in-vehicle `OnPlayerUpdate`) don't run. For those, measure by hand while driving.
- Walking is real game walking, so timings vary a little from run to run. Use `repeat = 3` and read the medians.
- The world calls it makes (teleport, climate overrides, `setTimeOfDay`, `setGameSpeed`, zombie removal and spawning) are each guarded. If one fails, it logs a `[TestGround] ... failed` line and the run goes on. It has passed a mock run, but not a real game yet.

## Install

Copy `TestGround` to `Zomboid\mods\` and enable it, along with Lua Event Profiler 1.4 if you want Lua costs. The console shows `[TestGround] active (1.5.0), plan '...': N steps, ...`.

## Test

`python3 test-ground/mock_test.py` (needs `lupa`) runs a full two-pass plan, the menu recorder and the bridge against a fake world. It ends with `ALL OK`.
