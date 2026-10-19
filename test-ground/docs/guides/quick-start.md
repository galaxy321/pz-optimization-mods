# Test Ground quick start

*Audience: players. Ships with: Test Ground. Draft.*

Test Ground plays the same scripted session in your save every time (walk, loot, fight, drive, a 500-zombie crowd) and writes how smooth the game was. Run it with one mod list, change the list, run it again, compare.

## Before you start
1. **Use a copy of your save.** A run passes game time, spawns and removes zombies, may remove parked cars on the fast-drive road, and moves items out of containers and back. Copy the save folder under `Zomboid\Saves\<mode>\` and load the copy. *(Pending: the "Benchmark Save" menu button will make a throwaway copy for you.)*
2. Enable **Test Ground** in the save's mod list. Optional: **Lua Event Profiler** (adds Lua cost per mod to the report).
3. Keep the game in front and unpaused. If "pause on focus loss" is on, switching windows pauses the run's clock.

## Run the standard test
1. Load the copy and stand anywhere safe.
2. Right-click in the world > **Test Ground** > **Go to West Point, survey and run baseline**. The first time, confirm the dialog (it warns that cars on the fast-drive road are removed).
3. Wait. The baseline takes about 15–20 minutes. You are teleported to a fixed street in West Point (the same in every save, so a modded save and a vanilla save are comparable) and back at the end.
4. The report appears in `Zomboid\Lua\`: `TestGround_baseline_<id>.txt`, plus `_perf.txt` (one row per second), `_spikes.txt` (every frame of 50 ms or more) and `_trace.txt` (what the player and zombies did).

## Compare two setups
- One variant per game load: change the mod list, restart the game, load a fresh copy of the same save, run again.
- Run each variant 2–3 times and compare **medians**. One run is an anecdote.
- Read the two reports with the `pz-read-test-report` skill, or run `compare.py A.txt B.txt` (in Test Ground Bridge's `tools/`).

## Your own plan
`Zomboid\Lua\TestGround_plan.txt` is created on first load, with comments. Right-click > Test Ground records start, route and road points where you stand. Full key list and step kinds: `README.md` and the skill's `references/plan-format.md`.

## Limits
Singleplayer only. `drive`, `stream` and `treeroad` glide in ghost mode (chunk loading is real, vehicle physics is not); `drivefast` uses a real car. Timings vary a little between runs because walking is real game walking.
