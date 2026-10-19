---
name: pz-mod-writing
description: Use when writing, structuring or debugging a Project Zomboid Build 42 mod (Lua): folder layout, mod.info, events, load order, patching another mod safely, and the common traps.
---

# Writing a Project Zomboid Build 42 mod

Draft, for the developer add-on. Pairs with `pz-mod-performance` (making a mod cheap) and `pz-test-ground` / `pz-mod-test-step` (testing it).

## Read first, write second
- Vanilla Lua is the documentation: `<install>\media\lua\` (client, server, shared). Find a vanilla feature close to yours and copy its pattern, e.g. `server/Map/MapObjects/MOBarricade.lua`.
- Other mods' source is in `steamapps\workshop\content\108600\<id>\mods\<Mod>\`. Check which versioned folder is live first (`42`, `42.19`, `42.20`, `common`): the game uses the highest not above its own version.
- Don't call a game method you haven't seen used in vanilla or the target mod. A wrong name is a runtime error, and in `-debug` even a caught one can stop the game.

## Layout
```
<Mod>/
  common/                      (can be empty; B42 wants it)
  42/mod.info                  name, id, description, versionMin, require=\OtherModId
  42/media/lua/{client,server,shared}/...
  42/media/scripts/*.txt       items, recipes, entities, sandbox
  42/media/lua/shared/Translate/EN/*.json
```
- `client` runs on the player's machine, `server` on the host (and in singleplayer), `shared` on both. Load order: all vanilla and mod `shared`, then `client`, then `server`, each in mod-list order; within one mod, by file name. A prefix like `!!!_Name.lua` orders files only inside one mod.
- Put every constant in one table (`local K = {}`): a Kahlua file may have at most 200 locals.

## Events
| Need | Use | Not |
|---|---|---|
| Something changed | `OnObjectAdded`, `OnContainerUpdate`, `OnClothingUpdated` | polling in `OnTick` |
| Find objects by sprite | `MapObjects.OnLoadWithSprite(sprite, fn, prio)` (+ `OnNewWithSprite`); filtered in Java | `Events.LoadGridsquare` (Lua call for every square that loads) |
| Main menu code | `OnFETick` | `OnTick` (doesn't fire at the menu or while paused; `OnRenderTick` does) |
| Once the world is ready | `OnGameStart`, `OnNewGame` | top-level code (other mods aren't loaded yet) |

## Patching another mod or vanilla
1. **Never edit their files.** Wrap their global function after it loads (do it at `OnGameStart`; it doesn't depend on mod order), or catch their handler as it registers by wrapping `Events.X.Add` from a `shared` file.
2. Call the original; change only when or how often it runs. Keep its behaviour.
3. If the target changed shape (a handler count, a function missing), **stand down** and log one line saying so.
4. One `ENABLE_...` flag per patched part; one `[Mod] active (version) ...` console line at start.
5. Identify a caller with `getFilenameOfClosure(fn)`; if Lua Event Profiler is on, get the real function with `LuaEventProfiler.originalOf(fn)` first.
6. Don't change or disable the player's other mods; suggest it.

## Kahlua / B42 traps
- No `next()` (call fails with "tried to call nil", and inside an `Events.X.Add` wrapper it breaks every other mod's registration). Use `for _ in pairs(t) do ... end`.
- Java calls (`getSquare`, `getObjects`, `getSprite`) are far slower than Lua: hoist them out of loops.
- `sq:Is(flag)` is gone: `sq:has(IsoFlagType.x)`; properties `props:has("name")`.
- `getGridSquare` returns nil for unloaded squares: check before use. `pcall` catches an error but the game still logs and counts it, so avoid errors instead of catching them.
- Lua can read and write only inside `Zomboid\Lua\`, and refuses `.csv` (write `.txt`).
- More found-the-hard-way items: `b42-lua-gotchas.md` in the Bridge skill.

## Multiplayer awareness
State your mod's single-player/server assumptions in the README. `server/` code and `MapObjects` hooks don't run on a multiplayer client.

## Porting a Build 41 mod
Read `references/b41-to-b42-migration.md` first: it has the procedure (skeleton, load with no console errors, then features), the known renames, and which statements are verified. Never port from memory; copy vanilla B42 usage.

## Check list before release
1. `console.txt` has the `active` line and no errors after loading a save with the mod on and off.
2. Bump `modversion` and the log line's version together.
3. A mock test of the logic (lupa with fake `Events`) for anything that wraps other code, then a real in-game check: a mock only proves the logic.
4. Measure it (see `pz-mod-performance`), including with it disabled.
5. README: what it does, flags, what it was measured at (and what is only expected).
