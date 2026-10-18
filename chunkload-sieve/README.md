# Chunk Load Sieve

A patch mod for driving FPS in Project Zomboid Build 42. It doesn't modify any other mod's files.

## What it does
Several mods run a Lua function on every square of every chunk that loads (`Events.LoadGridsquare`), which happens thousands of times a second while driving. Most of them only care about squares with one kind of object.

This patch catches those functions when they register and keeps them off the event. One shared function then looks at each square once. It calls each caught function only when the square has what that function needs:

| Mod file | Called only when the square has |
|---|---|
| OnanGenSet/OnanServer.lua ([Onan GenSet](https://steamcommunity.com/sharedfiles/filedetails/?id=3812222734)) | a generator, or an Onan engine-half sprite |
| OnanGenSet/OnanSound.lua | a generator |
| GasPumpIndicator.lua ([Gas Pump Indicator](https://steamcommunity.com/sharedfiles/filedetails/?id=3755993986)) | a gas pump sprite |
| LGExtendedPlumbing/LGEPClient.lua ([LG Extended Plumbing](https://steamcommunity.com/sharedfiles/filedetails/?id=3779561845)) | an object with mod data, or the LGEP ghost sprite |
| LGExtendedElectricity/LGEEGrid.lua ([LG Extended Electricity](https://steamcommunity.com/sharedfiles/filedetails/?id=3779562002)) | a generator, or an object with mod data |
| LGExtendedElectricity/LGEEAgree.lua | a generator (only registers in multiplayer) |
| PZM_Puker_Decals.lua ([PZ The Mutants](https://steamcommunity.com/sharedfiles/filedetails/?id=3796669056)) | an object with mod data (puke always saves its expiry there) |
| vfx_agingmanager.lua ([Vanilla Foods Expanded](https://steamcommunity.com/sharedfiles/filedetails/?id=3577903007)) | ground items or a container |
| vfx_storydistribution.lua (VFE) | a container |
| vfx_birthday_world.lua / vfx_birthday.lua (VFE) | ground items |
| qolc_reasonable_alarms.lua ([QoL Compendium](https://steamcommunity.com/sharedfiles/filedetails/?id=3781012462)) | doors or windows (special objects), or a vehicle |
| TABAS_STubFluidContainerSystem.lua ([Take A Bath And Shower](https://steamcommunity.com/sharedfiles/filedetails/?id=3592172476)) | a square in its tub registry |
| server/DAMN_Spawns.lua ([damnlib](https://steamcommunity.com/sharedfiles/filedetails/?id=3171167894)) | one of damnlib's forced vehicle spawn points (added in 1.3) |
| FittedBarricades/FB_Client.lua ([Fitted Barricades](https://steamcommunity.com/sharedfiles/filedetails/?id=3795414660)) | special objects (doors, windows), its own first check (1.3) |
| FittedBarricades/FB_Build.lua (Fitted Barricades) | never in singleplayer: it only works on a server (1.3) |
| FittedSheets/FT_Server.lua ([Fitted Sheets](https://steamcommunity.com/sharedfiles/filedetails/?id=3794207681)) | special objects (windows, curtains), its own first check (1.3) |
| RCStructureFramework/RoofPieces.lua (RC Structure Framework) | special objects, the only ones it repairs (1.7) |
| RCStructureFramework/SpritePropertyPatcher.lua (RC Structure Framework) | special objects, its own first check (1.7) |
| RCStructureFramework/RoomLighting.lua (RC Structure Framework) | a square inside a room; it only wires light switches in its own rooms (1.7) |
| RCStructureFramework/TemplateStamp.lua (RC Structure Framework) | an object with mod data, where it keeps its preview tag (1.7) |

Each condition comes from reading that mod's handler. One exception: Mutants puke that somehow has no saved expiry is no longer given one when its chunk loads. It is the minimum the handler needs before it does anything, so skipping a square changes nothing for that mod.

The patch leaves every other event alone, apart from the LG Extended Electricity and LG Extended Plumbing parts below.

## LG Extended Electricity (1.4)
[LG Extended Electricity](https://steamcommunity.com/sharedfiles/filedetails/?id=3779562002) keeps a list of every generator it has seen and re-works its powered buildings in passes. Two things make it busy while you drive:

- **Every generator it sees gets filed**, including ones lying in a field that nobody has plugged in. Each new one makes it forget its plans for the whole grid and start its current pass again. 1.4 skips filing a generator that isn't plugged in, isn't running, isn't a solar mod's battery bank and carries no mod data. Such a generator can't power anything. Plugging it in or starting it files it at that moment (the mod's own hook on those actions). One thing changes: you can't wire a relay to an unplugged generator that was only seen while loading; plug it in first. (`ENABLE_LGEE_DORMANT`)
- **Every chunk that loads, and every object removed anywhere, asks for a new pass.** 1.4 drops that request when the place is far from every generator and relay the mod knows: more than its longest range plus `LGEE_MARGIN` (200 tiles), measured in 128-tile cells. The rest of those handlers still runs, and a request that gives a reason or is urgent always goes through. The mod's own pass every 25 seconds, and the hourly one, still happen. (`ENABLE_LGEE_FAR`)

Nothing is dropped while LGEE is switched off in its options, or if its generator list or relay store can't be read. The 2-minute stats line also counts unplugged generators skipped and far requests dropped.

**1.5 trims the saved list** as the save loads, before LGEE reads it (`ENABLE_LGEE_PRUNE`). Without it the list keeps every generator the mod ever saw. Entries that were off, not wired to a building, not tripped, not plumbed and not a solar bank are removed, and the console says how many. The saved list doesn't record whether a generator was connected, so a connected generator that was switched off is removed too. Nothing visible changes for it: it powers nothing while off, and LGEE adds it back as soon as its area loads or it is started. Until then you can't wire a relay to it from far away.

## LG Extended Plumbing (1.6)
This was the separate LGEP Chunk Load Patch mod, now part of the sieve. **If you have that mod, turn it off.** While it is on it keeps doing the job, and the sieve leaves the plumbing scan to it and says so in the console.

[LG Extended Plumbing](https://steamcommunity.com/sharedfiles/filedetails/?id=3779561845)'s server file (`LGEPPlumbing.lua`) scans every square of every chunk as it loads, about 20 µs a square by the mod's own estimate. The sieve holds that handler and changes two things:

- **Spread over time.** Each chunk is queued when it has loaded, and its squares are fed to the original handler for at most 2 ms per tick (`LGEP_BUDGET_MS`), 8 chunk levels at most.
- **Only near plumbing.** Nothing in the plumbing mod does anything until a player plumbs a barrel in, so only chunks near a mirror, a plumbed barrel or a pipe are read (`LGEP_LAZY`). A chunk skipped this way is read in full if something nearby is plumbed while it is still loaded.

Plumbing a barrel in or out is recorded in a small list saved with the world. It keeps the old mod's key, so nothing is lost when you switch. A barrel plumbed before either was installed, somewhere no mirror or pipe covers, is picked up the next time it is unplumbed and plumbed again. `ENABLE_LGEP_QUEUE = false` turns the whole part off. The 2-minute stats line counts chunk levels read and chunks skipped. Background: [docs/LGEP.md](docs/LGEP.md) (why, and what was not done) and [docs/LGEP-walkthrough.md](docs/LGEP-walkthrough.md) (the code).

## Trees and bushes (1.8)
When chunks load, the game's vegetation pass removes and replaces trees, bushes and grass, and each removal raises `OnObjectAboutToBeRemoved`. Seven handlers from three mods are skipped where, by their own code, they can't do anything:

| Handler | Skipped for | Why |
|---|---|---|
| LGEPPlumbing.lua:6012 | trees and bushes | acts only on its ghosts, water sources (IsoThumpable), fed fixtures and waterPiped fixtures |
| LGEPClient.lua:1062 | everything outside a multiplayer client | only sends when `isClient() and not isServer()` |
| LGEEGrid.lua:11645 | trees and bushes | marks the square's power draw dirty and asks for a sweep; vegetation draws nothing and is no generator or fuel holder |
| LGEEAgree.lua:182 | everything outside a multiplayer client | returns at once there |
| TABAS_STubFluidContainerSystem.lua:337 | trees and bushes | bathtub sprites only |
| TABAS_ShowerFx.lua:549 | trees and bushes | shower or bath sprites only |
| TABAS_TubEdge.lua:589 | trees and bushes with no solid, solidtrans or wall flag | it also reacts to anything solid or a wall next to a tub, so solid vegetation still reaches it |

"Trees and bushes" means an `IsoTree`, or an object whose sprite has the game's `vegitation` flag (cached per sprite). The console says `removals: caught <file>` for each, and the 2-minute stats add `removals: <file> skipped N, ran M`. Full mode only (`ENABLE_REMOVAL_GATE` at the top of the Lua file).

## Census, modes and timing (1.7)
**Census.** When the game starts, the console lists every handler on `LoadGridsquare`, `LoadChunk`, `ReuseGridsquare` and `OnObjectAboutToBeRemoved`, one line each: `[ChunkLoadSieve] census <event> <caught|queued|held|passed> <file>`. `passed` means the sieve left it on the event as it was. A summary line follows (`[ChunkLoadSieve] census: LoadGridsquare (5 passed, 20 caught); LoadChunk (...)`), and a handler added later prints a `census (late)` line.

**Modes.** For comparing runs. Put one word on the first line of `%USERPROFILE%\Zomboid\Lua\ChunkLoadSieve_mode.txt` (or change `MODE` at the top of the Lua file), then start the game:
- `full` (default, or no file): the sieve as described above.
- `machinery`: one handler calls every `LoadGridsquare` handler on every square. No rules, no LG Extended Electricity or Plumbing parts, and no `watch()`, so Hitch Fix finds racks by rescanning, as it does without the sieve.
- `measure`: nothing is caught or changed; the sieve only lists and times. This stands in for "no sieve".

**Timing.** In every mode, every 2 minutes:
`[ChunkLoadSieve] timing mode=<mode> window 120 s: LoadGridsquare Lua <ms> ms over <n> squares = <ms/s>, <us/square>; LGEP queue <ms> = <ms/s>; since start <ms> ms over <n> squares (<us/square>)`.
It times everything between a listener added first and one kept last on `LoadGridsquare`, so it covers each mod's handler and the game's call into each one, the same way in all three modes. The clock counts whole milliseconds, which averages out over thousands of squares. In `full` mode, LG Extended Plumbing's scan runs from the tick queue instead, so add the `LGEP queue` figure when comparing. Turn the Lua Event Profiler off for these runs: it wraps each handler, which costs more with more handlers on the event and so favours the sieve.

Since 1.8 a second line, `[ChunkLoadSieve] timing LoadChunk mode=<mode> window 120 s: <ms> ms over <n> chunks = <ms/s>, <us/chunk>`, times every `LoadChunk` handler the same way.

**Rules from other files.** `ChunkLoadSieve.rule("Folder/File.lua", { "special" })` adds a rule; a handler already on the event is taken off it and caught. Facts are those listed above `RULES` in the Lua file, plus `room` (the square is in a room).

**Dev build.** `build-dev.sh` makes `dev/ChunkLoadSieveDev`: the same mod with id `ChunkLoadSieveDev` and Lua file `!!!_ChunkLoadSieve-Dev.lua`, for testing a new version while the Workshop Chunk Load Sieve is installed (both share the id `ChunkLoadSieve`, so a local copy of the same id loses to the Workshop one). Only one copy can run: whichever file loads first is active, and the console says so (`active (1.8, mode full, ChunkLoadSieveDev)`, or `... NOT ACTIVE: Chunk Load Sieve 1.6 or older ... loaded first`). Turning the Workshop copy off for test runs is the sure way.

## Install
Copy the `ChunkLoadSieve` folder to `%USERPROFILE%\Zomboid\mods\`, then enable "Chunk Load Sieve" in the Mods menu. Put it above the mods named under "Mod order" below.

**Mod order.** Put Chunk Load Sieve above LG Extended Electricity, RC Structure Framework and Vanilla Foods Expanded in the mod list. Build 42 loads every mod's `shared` Lua files in mod-list order, and those mods have handlers in their `shared` folders, so the sieve only catches them if it loads first. Handlers in `client` and `server` folders are caught wherever the sieve sits. If one is missed, the console says so at start: `[ChunkLoadSieve] missed LGExtendedElectricity/LGEEAgree.lua: move Chunk Load Sieve above LG Extended Electricity in the mod list`.

To check it is working, look in `console.txt` for `[ChunkLoadSieve] active (1.8, mode full), N handlers captured: ...`. Every 2 minutes it also prints how many squares loaded and how many times each caught handler was actually called.

To turn it off, disable the mod. Alternatively, set `ENABLED = false` at the top of `!!!_ChunkLoadSieve.lua`.

## Testing so far
I tested it against a mock of the game's event system with 20,000 random squares:
- Every caught handler was called on every square where its condition holds.
- Unrelated handlers still got every square.
- A handler that throws an error doesn't stop the others.
- It works with the Lua Event Profiler loaded before or after it.

The mock checks the mechanism, not my reading of each mod, and it hasn't been run in the real game yet.

If a mod update renames one of these files, that handler simply isn't caught and runs as normal.

## Version history
- 1.8: object-removal handlers of LG Extended Plumbing, LG Extended Electricity and Take A Bath And Shower skipped for trees and bushes (and the two multiplayer-client-only ones outside a client). LoadChunk timing. Review fixes: Take A Bath And Shower and damnlib handlers get every square until their lists are first read after the game has started (before that they may not be loaded yet, so tubs near where you load in were missed); rule files match whole file names only; set-up also runs on a dedicated server (OnServerStarted); a handler a mod adds and removes over and over is printed and announced once; a mode file other than `full` is called out at start; a handler in another mod's `shared` folder that was missed because of mod order is named at start. Mock-tested only.
- 1.7: handler census, `machinery` and `measure` modes with the same timing line in every mode, `ChunkLoadSieve.rule()`, and rules for RC Structure Framework's four handlers. Mock-tested only.
- 1.6: the LGEP Chunk Load Patch mod's plumbing scan queue is folded in. Not yet measured in game.
- 1.0: first test drive. All 11 handlers were caught, but the shared check cost 43 microseconds a square. The old handlers together cost about 55 by the profiler's count, which counts profiler overhead 11 times, so the real saving was small.
- 1.5: LG Extended Electricity's saved generator list is trimmed of old, unused entries on load.
- 1.4: LG Extended Electricity: unplugged generators aren't filed, and far chunks and removals don't ask for a new pass. Not yet measured in game.
- 1.1: rewritten for Kahlua's slow calls. Sprite names are cached per sprite, and a square with nothing of interest runs no handler loop. TABAS now only gets squares in its tub registry, and Mutants only gets squares with mod data.
