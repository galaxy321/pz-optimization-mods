---
name: pz-read-test-report
description: Use when the user has one or two Test Ground reports (TestGround_*_<id>.txt, _perf, _spikes, _trace) for Project Zomboid Build 42 and wants to know whether a mod, patch or setting made the game faster, smoother or different.
---

# Reading Test Ground reports

Draft, ships with Test Ground. Needs only the report files; no Bridge, no live game.

## Files (all in `Zomboid/Lua/`)
- `TestGround_<label>_<id>.txt`: the report. Header (plan, scene, `profiler:`, full `mods:` list), then one section per step with frames, fps, mean, p50/p95/p99, worst frame, frames over 33 and 100 ms, and with Lua Event Profiler the Lua cost by mod and handler.
- `_perf.txt`: one row per second (phase, position, fps, mean, worst, zombies). `_spikes.txt`: every frame of 50 ms or more with phase and player state. `_trace.txt`: positions, walk legs, Walk To outcomes, notes from mods.
- `*_latest.*`: copies of the last run. Prefer the id-named files when comparing.

## Procedure
1. **Check the runs are comparable before reading any number.** Same plan and `settle`; same `start`; same step list (the step table in each report); `mods:` lists differ only by what the user changed; same Test Ground version in the first line. Say what differs.
2. **Compare per step, not overall.** A total or "worst step" is dominated by setup steps (`corpse_lay`, `corpse_clear`), which measure Test Ground laying and lifting corpses, not the game.
3. **Pick the right metric.**
   - Feel: median fps and p50.
   - Stutter: p99, worst frame and hitches (frames over 100 ms). A stutter fix shows in hitches and worst, often not in fps.
   - Lua cost: needs `profiler:` not `off`. It covers event handlers, mod UI render/update and vehicle scripts only; engine time is not in it. Test Ground's own handlers show as `TestGround`: compare, don't subtract.
4. **Use repeats.** With one run per variant say so and call differences under ~5% noise. With 3 runs compare medians and give the spread. Real examples from the project: the same suite varies run to run by several fps and by tens of hitches in driving steps.
5. **Special steps.**
   - `drive`, `stream`, `treeroad` glide in ghost mode: chunk loading only. `drivefast` is a real car; a result starting `FALLBACK` glided instead, so don't compare it with real-car runs.
   - A `walkto` `fail` is not a bug by itself: compare with the run without the mod and with what the mod promises.
   - Fog and clear steps are only comparable when they cover the same ground for the same time.
6. **Find the cause.** Use `_spikes.txt` to see which phase and state the worst frames fell in, and the profiler's top mods for that step. `compare.py A.txt B.txt` prints the largest per-mod moves, mods present in only one run and changed Walk To outcomes.

## Report back with
Plan label, step, run count and the numbers (A vs B, difference, spread). Mark anything not measured as "expected". End with one sentence a non-expert can act on, and list what could not be concluded.

## Don't
- Don't average across steps or across different step lists.
- Don't call an fps change real from a single run.
- Don't compare runs from different saves or different start points.
