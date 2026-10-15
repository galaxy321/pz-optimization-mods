# PZ optimization mods (Project Zomboid B42)

These are small, unofficial patch mods for Project Zomboid Build 42. They cut the Lua cost and the frame hitches caused by other mods. None of them edit another mod's files. Each one catches the handlers it patches when they register, or wraps a function at load. Every part can be switched off with a flag at the top of its Lua file.

| Folder | Mod | What it does |
|---|---|---|
| `chunkload-sieve` | Chunk Load Sieve | Replaces many mods' per-square `LoadGridsquare` handlers with one shared pass. Each handler only runs on squares holding what it looks for. Driving chunk-load Lua went from about 170 to about 30 ms/s. |
| `ui-throttle` | UI Throttle | The loot window skips rebuilds when nothing nearby changed, and keeps vanilla's instant updates when something did. It also throttles Exact Minute Clock's watch check. |
| `hitch-fix` | Hitch Fix | Spreads AmmoMaker's casing clean-up and vanilla farming's plant checks over several ticks. It also holds back the Tuna rack scans while no rack is near. |
| `lgep-chunk-load-patch` | LG Extended Plumbing Chunk Load Patch | Cuts the lag LG Extended Plumbing causes while chunks load, which is most noticeable when driving. It also lives in its own repo, [pz-lgep-chunk-load-patch](https://github.com/galaxy321/pz-lgep-chunk-load-patch). |
| `lua-event-profiler` | Lua Event Profiler | A diagnostic mod. It times every Lua event handler and UI method by mod, and prints a report every 30 s. Turn it off when you aren't measuring, because the report itself causes a hitch. |

## Measured savings

These numbers come from Lua Event Profiler runs on one heavily modded B42 save. They count Lua time only, in milliseconds of main-thread time per second of play (ms/s). Your numbers will depend on your mods and where you play.

| Mod | Before | After | Notes |
|---|---|---|---|
| Chunk Load Sieve | about 170 ms/s of chunk-load handlers while driving | about 30 ms/s | Covers about ten handlers from LG Extended Plumbing (client), LG Extended Electricity, OnanGenSet, Vanilla Foods Expanded, QoL Compendium, The Mutants and others. Each used to cost 20 to 35 ms/s. Now one shared pass costs about 9 µs per square. |
| UI Throttle | CleanUI loot window `update`: 29.6 ms/s (1.49 ms per call) | 8.3 ms/s (0.43 ms per call) | The 12 to 16 ms rebuild on every step or turn now only happens when something lootable nearby changed. The Exact Minute Clock part made no difference that could be measured. Its draw cost stayed at about 0.44 ms per frame. |
| Hitch Fix | 55 to 65 ms hitch every 10 in-game minutes (AmmoMaker 24 to 37 ms plus farming about 30 ms on the same frame); Tuna racks about 11 ms/s in 2 to 3 ms bursts | Expected: no single-frame hitch, and about 0 ms/s for the racks away from any rack | Not measured in game yet. The "before" figures are from the log that led to it. |
| LG Extended Plumbing Chunk Load Patch | about 20 µs per loading square for the server-side scan (the plumbing mod's own estimate) | Scans run in full only near plumbing, at most 2 ms per tick | Not profiled separately. It was installed before the profiler existed. |
| Lua Event Profiler | none | adds about 5 to 9 ms/s, plus a 140 to 290 ms hitch every 30 s when it writes its report | A diagnostic tool. Turn it off when you aren't measuring. |

Settings were changed alongside the patches on that save, so whole-game fps was not compared: the UI frame rate (`uiRenderFPS`) went from 60 to 15, and Immersive Snow's low-end mode was turned on.

Install a mod by copying its inner folder (for example `ChunkLoadSieve`) to `%USERPROFILE%\Zomboid\mods\`, then enable it in the Mods menu. Each folder's README has the details.

The `mock_test.py` scripts run the patches against stand-ins for the real mod files, using `lupa` (`pip install lupa`).
