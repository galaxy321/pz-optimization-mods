# PZ optimization mods (Project Zomboid B42)

These are small, unofficial patch mods for Project Zomboid Build 42. They cut the Lua cost and the frame hitches caused by other mods. None of them edit another mod's files. Each one catches the handlers it patches when they register, or wraps a function at load. Every part can be switched off with a flag at the top of its Lua file.

| Folder | Mod | What it does |
|---|---|---|
| `chunkload-sieve` | Chunk Load Sieve | Replaces many mods' per-square `LoadGridsquare` handlers with one shared pass. Each handler only runs on squares holding what it looks for. Driving chunk-load Lua went from about 170 to about 30 ms/s. |
| `ui-throttle` | UI Throttle | The loot window skips rebuilds when nothing nearby changed, and keeps vanilla's instant updates when something did. It also throttles [Exact Minute Clock](https://steamcommunity.com/sharedfiles/filedetails/?id=3778884296)'s watch check. |
| `hitch-fix` | Hitch Fix | Spreads [AmmoMaker](https://steamcommunity.com/sharedfiles/filedetails/?id=2788256295)'s casing clean-up and vanilla farming's plant checks over several ticks. It also holds back the Tuna rack scans ([gun racks](https://steamcommunity.com/sharedfiles/filedetails/?id=3784677588), [equipment racks](https://steamcommunity.com/sharedfiles/filedetails/?id=3793403177)) while no rack is near. |
| `lgep-chunk-load-patch` | LG Extended Plumbing Chunk Load Patch | Cuts the lag [LG Extended Plumbing](https://steamcommunity.com/sharedfiles/filedetails/?id=3779561845) causes while chunks load, which is most noticeable when driving. It also lives in its own repo, [pz-lgep-chunk-load-patch](https://github.com/galaxy321/pz-lgep-chunk-load-patch). |
| `lua-event-profiler` | Lua Event Profiler | A diagnostic mod. It times every Lua event handler and UI method by mod, and prints a report every 30 s. Turn it off when you aren't measuring, because the report itself causes a hitch. |

## Measured savings

These numbers come from Lua Event Profiler runs on one heavily modded B42 save. They count Lua time only, in milliseconds of main-thread time per second of play (ms/s). Your numbers will depend on your mods and where you play.

| Mod | Before | After | Notes |
|---|---|---|---|
| Chunk Load Sieve | about 170 ms/s of chunk-load handlers while driving | about 30 ms/s | Covers about ten handlers from LG Extended Plumbing (client), LG Extended Electricity, OnanGenSet, Vanilla Foods Expanded, QoL Compendium, The Mutants and others. Each used to cost 20 to 35 ms/s. Now one shared pass costs about 9 µs per square. |
| UI Throttle | [CleanUI](https://steamcommunity.com/sharedfiles/filedetails/?id=3437629766) loot window `update`: 29.6 ms/s (1.49 ms per call) | 8.3 ms/s (0.43 ms per call) | The 12 to 16 ms rebuild on every step or turn now only happens when something lootable nearby changed. The Exact Minute Clock part made no difference that could be measured. Its draw cost stayed at about 0.44 ms per frame. |
| Hitch Fix | 55 to 65 ms hitch every 10 in-game minutes (AmmoMaker 24 to 37 ms plus farming about 30 ms on the same frame); Tuna racks about 11 ms/s in 2 to 3 ms bursts | Expected: no single-frame hitch, and about 0 ms/s for the racks away from any rack | Ran cleanly in game for 12 ten-minute cycles (1,527 plants, 493 casing entries, 3 racks found). The hitch timing hasn't been profiled since, so the "after" figures are still expected values. |
| LG Extended Plumbing Chunk Load Patch | about 20 µs per loading square for the server-side scan (the plumbing mod's own estimate) | Scans run in full only near plumbing, at most 2 ms per tick | Not profiled separately. It was installed before the profiler existed. |
| Lua Event Profiler | none | adds about 5 to 9 ms/s, plus a 140 to 290 ms hitch every 30 s when it writes its report | A diagnostic tool. Turn it off when you aren't measuring. |

Game and mod settings changed during the same testing on that save, for example the UI frame rate (`uiRenderFPS`) went from 60 to 15, so whole-game fps is not compared here.

## Mods mentioned

These are the Steam Workshop pages for the mods the patches work with. None of them is required: each patch part only does something when its mod is installed.

| Mod | Patched by |
|---|---|
| [LG Extended Plumbing](https://steamcommunity.com/sharedfiles/filedetails/?id=3779561845) | Chunk Load Sieve, LG Extended Plumbing Chunk Load Patch |
| [LG Extended Electricity](https://steamcommunity.com/sharedfiles/filedetails/?id=3779562002) | Chunk Load Sieve |
| [Onan GenSet](https://steamcommunity.com/sharedfiles/filedetails/?id=3812222734) | Chunk Load Sieve |
| [Gas Pump Indicator](https://steamcommunity.com/sharedfiles/filedetails/?id=3755993986) | Chunk Load Sieve |
| [Vanilla Foods Expanded](https://steamcommunity.com/sharedfiles/filedetails/?id=3577903007) | Chunk Load Sieve |
| [QoL Compendium](https://steamcommunity.com/sharedfiles/filedetails/?id=3781012462) | Chunk Load Sieve |
| [PZ The Mutants](https://steamcommunity.com/sharedfiles/filedetails/?id=3796669056) | Chunk Load Sieve |
| [Take A Bath And Shower](https://steamcommunity.com/sharedfiles/filedetails/?id=3592172476) | Chunk Load Sieve |
| [CleanUI](https://steamcommunity.com/sharedfiles/filedetails/?id=3437629766) | UI Throttle |
| [Exact Minute Clock](https://steamcommunity.com/sharedfiles/filedetails/?id=3778884296) | UI Throttle |
| [AmmoMaker](https://steamcommunity.com/sharedfiles/filedetails/?id=2788256295) | Hitch Fix |
| [Tuna's Gun Racks](https://steamcommunity.com/sharedfiles/filedetails/?id=3784677588) | Hitch Fix |
| [Tuna's Equipment Racks](https://steamcommunity.com/sharedfiles/filedetails/?id=3793403177) | Hitch Fix |

Also mentioned in the notes, but not patched: [CHStatusHUD](https://steamcommunity.com/sharedfiles/filedetails/?id=3776182375), [Immersive Snow](https://steamcommunity.com/sharedfiles/filedetails/?id=3810071828), [The Shortcut](https://steamcommunity.com/sharedfiles/filedetails/?id=3470659758), [Better Sorting](https://steamcommunity.com/sharedfiles/filedetails/?id=2313387159), [Fitted Barricades](https://steamcommunity.com/sharedfiles/filedetails/?id=3795414660), [Fitted Sheets](https://steamcommunity.com/sharedfiles/filedetails/?id=3794207681), [damnlib](https://steamcommunity.com/sharedfiles/filedetails/?id=3171167894).

## Installation

These mods are tested in singleplayer on Build 42.20 and later. None of them is on the Steam Workshop, so you install them by hand.

1. **Download.** On GitHub, click **Code → Download ZIP** and unzip it. You can also use `git clone https://github.com/galaxy321/pz-optimization-mods`.
2. **Copy the mod folders.** Each patch folder in this repo holds one mod folder, the one with `42` and `common` inside. Copy that inner folder into your Zomboid mods folder:
   - Windows: `%USERPROFILE%\Zomboid\mods\` (for example `C:\Users\<you>\Zomboid\mods\`)
   - Linux / macOS: `~/Zomboid/mods/`

   | Repo folder | Copy this folder |
   |---|---|
   | `chunkload-sieve` | `ChunkLoadSieve` |
   | `ui-throttle` | `UIThrottle` |
   | `hitch-fix` | `HitchFix` |
   | `lgep-chunk-load-patch` | `LGEPChunkLoadPatch` (needs LG Extended Plumbing) |
   | `lua-event-profiler` | `LuaEventProfiler` (optional, only for measuring) |

   You should end up with paths like `Zomboid\mods\ChunkLoadSieve\42\mod.info`. Don't copy the repo folder itself.
3. **Enable.** Start the game, open **Mods**, and tick the ones you copied. Load order doesn't matter, because each one names its file so it loads before the mods it patches. For an existing save, also enable them in the save's own mod list when you load it.
4. **Check they're running.** Load the save, then open `Zomboid\console.txt` and look for these lines:
   - `[ChunkLoadSieve] active (1.2), N handlers captured: ...`
   - `[UIThrottle] loot window skips rebuilds when nothing nearby changed`
   - `[HitchFix] active (1.0), caught: ...`
   - `[LGEPChunkLoadPatch] active: ...`

   A patch whose target mod isn't installed simply catches nothing. It does no harm.

**Which ones to use.** Chunk Load Sieve and UI Throttle help almost any big modlist. Hitch Fix only does something if you use AmmoMaker, vanilla farming or Tuna's racks, and it works best alongside Chunk Load Sieve 1.2. Leave Lua Event Profiler off unless you are measuring, because its own report causes a hitch every 30 s.

**Updating.** Replace the folder with the new one. It is safe to do between play sessions. The plumbing patch keeps a small list of plumbed barrels in the save's mod data, and it carries over when you update.

**Uninstalling.** Untick the mod or delete its folder. Every patched mod goes back to its normal behaviour, since its files were never changed. Chunk Load Sieve (`ENABLED`) and Hitch Fix (`ENABLE_AMMO`, `ENABLE_FARMING`, `ENABLE_RACKS`) also have switches at the top of their Lua file, so you can turn off one part.

**Multiplayer.** This hasn't been tested. For a dedicated server, the mods have to be on the server and every client. Add their IDs (`ChunkLoadSieve;UIThrottle;HitchFix;LGEPChunkLoadPatch`) to the server's `Mods=` line. Because they are local mods, you would need to upload them to the Workshop yourself for other players to download, and credit the authors of the mods they patch.

The `mock_test.py` scripts run the patches against stand-ins for the real mod files, using `lupa` (`pip install lupa`).

## Contributing

`CLAUDE.md` explains how the patches work, how to test and measure them, and which costs are still worth looking at. It is written so that Claude Code, or a person, can pick the work up on their own machine.

## License

Public domain, under [The Unlicense](LICENSE). Use, copy, change, re-upload or include these in your own mods or modpacks, with or without credit. The mods they patch belong to their own authors and are not covered by this.
