# Notes for Claude (or anyone) continuing this work

These are unofficial performance patch mods for Project Zomboid Build 42. They were built by profiling one heavily modded singleplayer save and patching the worst Lua costs. Read `README.md` first for what each mod does and the measured numbers.

## Ground rules
- **Never edit another mod's files.** Every patch works from its own mod. It catches the target's event handler as it registers, or wraps a global function after it loads. If the target mod changes in a way the patch doesn't recognise, the patch must stand down and leave the original behaviour in place, with a console line saying so.
- **Keep the target's behaviour.** Call the original handler or function rather than reimplementing it. Only change *when* or *how often* it runs, or skip it on inputs where reading its source shows it does nothing.
- **One flag per part.** Each patched behaviour has an `ENABLE_...` or similar flag at the top of the Lua file, so a user can turn a single part off.
- **Don't change or disable the user's mods without asking.** Suggest a settings change or a patch, and let them decide.
- **Log clearly.** Print one `[ModName] active (version) ...` line at start, and a `caught ...` line for each handler taken, so a user can confirm it in `console.txt`.

## How the patches work
- **Catching handlers.** Wrap `Events.X.Add` (and `Remove`) from a file in `media/lua/shared/`. Name the file so it sorts before the mods it patches: Zomboid loads Lua files in name order within each folder (shared, then client, then server), so `!!!_Name.lua` loads first. Identify the caller with `getFilenameOfClosure(fn)` and match the file path suffix.
- **Profiler compatibility.** `!!!LuaEventProfiler.lua` sorts before the patches and wraps handlers too. Use `LuaEventProfiler.originalOf(fn)` (when it exists) to get the real function before calling `getFilenameOfClosure`.
- **Caches keyed by sprite.** Sprites are shared objects, so a table keyed by the sprite object caches "what kind of thing is this" for every copy of it. See `classify` in Chunk Load Sieve.
- **Time slicing.** Turn one big pass into a queue processed a fixed number per `OnTick` (Hitch Fix: 200 casings or 20 plants per tick). Snapshot the list first. Re-check each object is still valid before using it, for example `system:getLuaObjectAt(x, y, z) == obj` for global object systems. If a new pass starts while one is still running, finish the old one first.
- **Kahlua is slow at Java calls.** Any call into a Java object (`getSquare`, `getObjects`, `getSprite`) costs much more than plain Lua. Hoist them out of loops and cache what you can.
- **Chunk Load Sieve 1.2 has a `ChunkLoadSieve.watch(test, onSquare)` hook.** Other patches use it to learn about objects as squares load, without adding their own `LoadGridsquare` handler. Hitch Fix uses it to find Tuna racks.

## Testing
Each patch has a `mock_test.py` that runs the real Lua file under [lupa](https://pypi.org/project/lupa/) against fake `Events`, squares and objects. The fakes stand in for the target mods and register the way the real files do.

```
python3 -m pip install lupa
python3 chunkload-sieve/mock_test.py   # ends with "ALL OK"
python3 hitch-fix/mock_test.py         # ends with "ALL PASS"
python3 ui-throttle/mock_test.py       # prints rebuild counts
```

A mock only proves the logic. The real check is in game: install the mod, load a save and look in `%USERPROFILE%\Zomboid\console.txt` for its `active` line and any errors.

## Measuring
1. Install `lua-event-profiler/LuaEventProfiler` and enable it.
2. Play the scenario you care about (walking, driving, waiting through a few in-game 10-minute marks).
3. Read `%USERPROFILE%\Zomboid\Lua\LuaEventProfiler.txt` and `console.txt`. They list ms per second by mod and by handler, single calls over 8 ms, and frame gaps over 100 ms.
4. Turn the profiler off afterwards. It costs about 5 to 9 ms/s, plus a hitch every 30 s when it writes its report.

Report numbers as ms/s of main-thread Lua time, and say what was measured and what is only expected.

## Where mod sources are
- Workshop mods: `C:\Program Files (x86)\Steam\steamapps\workshop\content\108600\<workshop id>\mods\<ModName>\`.
- Build 42 mods can have versioned folders (`42`, `42.19`, `42.20`, `common`). The game uses the highest folder not above its own version, so check which one is live before reading the code.
- Local mods: `%USERPROFILE%\Zomboid\mods\<ModName>\`.
- Vanilla Lua: `...\steamapps\common\ProjectZomboid\media\lua\`.

## Open leads
These are the remaining Lua costs from the last profile, with what's known so far:
- **Hitch Fix "after" numbers** are not profiled yet. One profiler run past a few in-game 10-minute marks would confirm the hitch is gone. Then update the Hitch Fix row in `README.md`.
- **CHStatusHUD render:** about 12 ms/s (0.83 ms per frame), from drawing 18 rows. Best handled through its settings (fewer rows) or a lower `uiRenderFPS`.
- **CleanUI** `ISInventoryPage:update` (about 8 ms/s left) and `prerender` (about 8 ms/s, with 8 to 30 ms spikes). Looked at and left alone: the rest is work vanilla's own inventory page also does every update (`controlsUI:arrange()`, container highlights), and the spikes are `ISInventoryPage.dirtyUI()` rebuilding after an inventory change, which has to happen. The only small win left is caching NeatUI's `NeatTool.truncateText` results for the window titles; its source wasn't read yet.
- **NVFramework** `OnPlayerUpdate`: about 4.7 ms/s, from `NV.CheckNVState` every 30 updates (about 1.8 ms each). Hitch Fix 1.1 caches `NV.Shared.IsNVTaggedItem` per item type, which is where the time goes. Not yet profiled in game.
- **damnlib** `OnPlayerUpdate` (in-vehicle armour): about 7 ms/s.
- **Exact Minute Clock** render: about 5.8 ms/s. The UI Throttle watch-check throttle made no measurable difference.
- **Immersive Snow:** about 15 ms/s in total. It already has a low-end mode and quiet-weather gating, so settings are the better fix.
- **FittedBarricades, FittedSheets and damnlib `LoadGridsquare`:** about 1.5 to 2 µs per square each. They could join Chunk Load Sieve once their handlers are read.

## Repo conventions
- One folder per mod: the mod folder itself (`ModName/42/...`, `ModName/common/`), a `README.md` and a `mock_test.py`.
- Bump `modversion` in `mod.info` and the version in the `active` log line together.
- Keep paths in docs generic (`%USERPROFILE%`), not tied to one person's machine.
