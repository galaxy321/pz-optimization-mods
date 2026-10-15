# LG Extended Plumbing: chunk-load patch

## Does the proposed fix hold up?

The diagnosis is right: `notice()` in `server/LGExtendedPlumbing/LGEPPlumbing.lua` runs on every square of every chunk, from `Events.LoadGridsquare` (line ~655). The mod's own comments measure it at roughly 20 microseconds per square, which is a lot of main-thread time when you are driving and dozens of chunks arrive per second.

Two of the patch's assumptions do not hold, though.

**1. "No squares ever get modified" is not quite true.** Most of `notice()` only fills in-memory lists (barrels, fixtures, mirrors). But for every `IsoThumpable` it calls `EP.repairOrphanedCollector` (LGEPCore.lua ~3775), which re-attaches components to rain barrels that the engine stripped during an unload (`GameEntityFactory.AddComponent`). That is a real change to a world object, and it is aimed specifically at chunks that are loading *again*.

**2. The "once per session" cache breaks things.** This is the part that makes the patch fast, and it is also the part that is wrong for this mod:
- When a chunk unloads, the mod deliberately forgets the mirrors on it (`settleMirrorSquare`, ~line 2675: "forget the address and pick it up again from LoadGridsquare") and prunes fixtures (`flattenLoaded`, ~line 4354).
- With the cache, a chunk you drive away from and come back to is never read again. Its taps and mirrors drop out of the system until someone right-clicks them, and gutted barrels are never repaired.

**Smaller problems in the code itself:**
- **Chunk ID formula:** `(wx + 32768) * 65535 + wy + 32768` multiplies by 65535 instead of 65536, so two different chunks can share an ID. It only happens at extreme coordinates, so it is harmless in practice, but it is a typo.
- **Hardcoded 64:** correct for Build 42 (8x8 chunks), but it relies on `getSquaresForLevel` returning a Java array that Kahlua indexes from 1. The mod's own LGEPPipes.lua uses `chunk:getGridSquare(lx, ly, z)`, which is safer.
- **Dedupe check only on the lowest level:** if the lowest level has no square at index 1, the "seen" check is skipped for the whole chunk.
- **`notice` is a `local` function**, so a separate file cannot call it. `EP` is fine (it is the global `LGEP`). The original handler is also an anonymous function, so it cannot be removed with `Events.LoadGridsquare.Remove`. The poster almost certainly edited the workshop file directly, which breaks on every mod update.
- **"LoadChunk happens after data is streamed to clients"** is not something I could confirm. The mod author's own note (LGEPPipes.lua ~285) says LoadChunk fires at the end of `IsoChunk.doLoadGridsquare`, after every square is in, in the same call. Moving the work from one event to the other does not by itself save time; the cache does.

## What the patch mod does instead

It keeps all of the original's work, but takes it out of the chunk-loading path:
1. In `shared/`, it wraps `Events.LoadGridsquare.Add` and catches the plumbing mod's handler when it registers, so the handler is never attached to the per-square event.
2. On `LoadChunk`, it queues the chunk's coordinates.
3. On `OnTick`, it feeds queued squares to the original handler for at most 2 ms per tick (`BUDGET_MS`, at the top of the server file).

Every chunk is still read on every load, so mirrors, fixtures and barrel repairs behave exactly as before. The only difference is that filing happens a few ticks after a chunk arrives instead of during it, which the mod already tolerates (its maintenance loop is built around "notice eventually").

If an update to the original moves things around and the capture fails, the patch logs `did not find ... standing down` and the original behaves as if the patch were not installed.

## Version 1.2: scan only near plumbing

Nothing in the plumbing mod does anything until a player plumbs a barrel in from the context menu: a supply needs `EP.isIncluded` (LGEPCore ~1863), and a mirror is only made for a fixture with a supply. So each chunk is sorted:

- **Hot** (near a mirror, a plumbed barrel, or a pipe): every square goes through `notice()`, as before. "Near" means the whole map building plus one chunk around it, and the Reach distance too (player-built bases have no building).
- **Cold** (everywhere else): skipped entirely.

Where the addresses come from:
- **Mirrors:** the mod's own saved list of every mirror (`mirrors` in the `LGExtendedPlumbing` world data), so bases you have not visited this session are still known.
- **Plumbed barrels:** a list this patch saves with the world (`LGEPChunkLoadPatch` world data). The patch wraps `LGEP.setIncluded`, the function both the plumb and unplumb menu actions end in. After the original runs, it reads the barrel back: plumbed in means it is added, unplumbed (or a refused plumb) means it is removed. So unplugging and plugging a barrel always leaves it on the list.
- **Pipes:** the mod's saved pipe pieces.

There is no learning scan. A barrel plumbed before the patch was installed is still covered if a mirror or pipe is near it, which is the usual case because plumbing a building creates mirrors in it. If one is ever missed, unplumbing and plumbing it again puts it on the list.

When something is plumbed, the index is rebuilt right away, and any loaded chunk that was skipped and is now hot is read in full.

`LAZY = false` at the top of the server file turns all of this off and scans every chunk (1.0 behaviour).

**What you give up:** sinks in unplumbed buildings are not filed until the building gets plumbing (plumbing a barrel in scans its building through the mod's own path), and the mod's repair of broken *unplumbed* vanilla barrels only runs near plumbing.

## How Project Zomboid mods load (Build 42)

**Where mods live.** Workshop mods are downloaded to `steamapps\workshop\content\108600\<id>\mods\<ModName>\`. Local mods go in `C:\Users\<you>\Zomboid\mods\<ModName>\`. Both show up in the in-game Mods list.

**Folder layout.** In B42 each mod has a `common\` folder (files shared by all versions; it must exist, even if empty) and one or more version folders such as `42\` or `42.20\`. The game picks the highest version folder that is not newer than the game. Inside a version folder:
```
mod.info
media\lua\shared\   loaded first, everywhere, at game start
media\lua\client\   loaded on players' machines (a dedicated server only hashes these)
media\lua\server\   loaded when a world starts: on the server, in singleplayer,
                    and (surprisingly) on multiplayer clients too
media\sandbox-options.txt, media\scripts\, media\textures\ ...
```
That is why LGEPPlumbing.lua starts with `if isClient() then return end`.

**mod.info** is a plain key=value file. The important keys are `name`, `id` (unique), `require=\OtherModId` (dependency; the game will not enable yours without it), `versionMin`, and `description`.

**Events.** The engine announces things by event name, and mods subscribe with `Events.<Name>.Add(function ... end)`. Examples: `OnTick` (every frame/tick), `LoadGridsquare` (each square of a loading chunk), `LoadChunk` (once per chunk, after its squares), `OnGameStart`. `Events.<Name>.Remove(fn)` only works if you still hold the same function value.

**How one mod changes another.** There are three tools, from bluntest to most careful:
1. **File override.** If two mods ship a file at the same path under `media\lua\...`, the one loaded later in the mod order wins and the other is never run. This is simple but means copying the whole file (357 KB here), which then goes stale on every update.
2. **Replace globals.** Anything stored in a global table (like `LGEP.someFunction`) can be reassigned from your own file, as long as yours runs after theirs. `require "Folder/File"` forces a file to load before the rest of yours. Lua files in each folder load roughly in alphabetical path order, merged across mods, and `shared` always loads before `server`.
3. **Intercept registration.** `local` functions and anonymous handlers cannot be reached after the fact. The only hook is to wrap the API they call (here, `Events.LoadGridsquare.Add`) from a file that is guaranteed to run first, which is why the patch puts that piece in `shared\`.

## Installing and testing

The patch is at `%USERPROFILE%\Zomboid\mods\LGEPChunkLoadPatch\`. Enable it in the Mods menu next to LG Extended Plumbing. For a dedicated server, add `LGEPChunkLoadPatch` to the server's `Mods=` line after `LGExtendedPlumbing`. Because it is local, it has to be uploaded to the Workshop for other players or a hosted server to download it, and it should credit the original author.

To check it is working, look in `%USERPROFILE%\Zomboid\console.txt` (or the server console) for a line starting with `[LGEPChunkLoadPatch] active`. I tested the logic against a mock of the game's event system, not in the real game, so try it on a copy of a save first.

## The electricity mod (LG Extended Electricity, workshop 3779562002)

I read its chunk-loading code and did not build a patch, because the same technique does not fit it.

- **Its per-square work is far lighter.** `notice()` in `server/LGExtendedElectricity/LGEEGrid.lua` (~line 640) asks each square for a generator (`getGenerator()`, which only looks at the square's short "special objects" list), and walks the square's objects only when the Fuel Line option is on, with a cheap `hasModData()` check per object. The author already reads the options once per chunk instead of once per square. The plumbing mod, by comparison, runs several checks on every object of every square.
- **Its LoadChunk work has to happen in the same frame.** `EE.reconcileArrival` (LGEEGrid ~11450) settles a returning generator's fuel line before the engine bills it for the hours it was away. The relay re-registration in `EE.applyRelaysAround` (LGEECore ~3158) puts a fridge's power back before the game ages its food. The author documents player reports of rotten food and generators found switched off when either of these ran late. Deferring them to a tick queue would bring those bugs back.
- **The heavier work is already queued or self-limiting.** Relays for the surrounding block are queued and drained a slice per tick. The light-switch repair walk (`repairChunk`) switches itself off for the rest of the session after 300 clean chunks in a row.

If the electricity mod still seems slow during chunk loading, it needs measuring before any patch. Turn on the mod's **Debug** sandbox option. It then prints timing rows (for example "streamed squares" and "chunk load") to the console every so often, which would show whether it is really the cost.
