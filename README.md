# PZ optimization mods (Project Zomboid B42)

These are small, unofficial patch mods for Project Zomboid Build 42. They cut the Lua cost and the frame hitches caused by other mods. None of them edit another mod's files. Each one catches the handlers it patches when they register, or wraps a function at load. Every part can be switched off with a flag at the top of its Lua file.

| Folder | Mod | What it does |
|---|---|---|
| `chunkload-sieve` | Chunk Load Sieve | Replaces many mods' per-square `LoadGridsquare` handlers with one shared pass. Each handler only runs on squares holding what it looks for. Driving chunk-load Lua went from about 170 to about 30 ms/s. |
| `ui-throttle` | UI Throttle | The loot window skips rebuilds when nothing nearby changed, and keeps vanilla's instant updates when something did. It also throttles Exact Minute Clock's watch check. |
| `hitch-fix` | Hitch Fix | Spreads AmmoMaker's casing clean-up and vanilla farming's plant checks over several ticks. It also holds back the Tuna rack scans while no rack is near. |
| `lgep-chunk-load-patch` | LG Extended Plumbing Chunk Load Patch | Cuts the lag LG Extended Plumbing causes while chunks load, which is most noticeable when driving. It also lives in its own repo, [pz-lgep-chunk-load-patch](https://github.com/galaxy321/pz-lgep-chunk-load-patch). |
| `lua-event-profiler` | Lua Event Profiler | A diagnostic mod. It times every Lua event handler and UI method by mod, and prints a report every 30 s. Turn it off when you aren't measuring, because the report itself causes a hitch. |

Install a mod by copying its inner folder (for example `ChunkLoadSieve`) to `%USERPROFILE%\Zomboid\mods\`, then enable it in the Mods menu. Each folder's README has the details.

The `mock_test.py` scripts run the patches against stand-ins for the real mod files, using `lupa` (`pip install lupa`).
