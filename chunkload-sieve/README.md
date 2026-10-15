# Chunk Load Sieve

A patch mod for driving FPS in Project Zomboid Build 42. It doesn't modify any other mod's files.

## What it does
Several mods run a Lua function on every square of every chunk that loads (`Events.LoadGridsquare`), which happens thousands of times a second while driving. Most of them only care about squares with one kind of object.

This patch catches those functions when they register and keeps them off the event. One shared function then looks at each square once. It calls each caught function only when the square has what that function needs:

| Mod file | Called only when the square has |
|---|---|
| OnanGenSet/OnanServer.lua | a generator, or an Onan engine-half sprite |
| OnanGenSet/OnanSound.lua | a generator |
| GasPumpIndicator.lua | a gas pump sprite |
| LGExtendedPlumbing/LGEPClient.lua | an object with mod data, or the LGEP ghost sprite |
| LGExtendedElectricity/LGEEGrid.lua | a generator, or an object with mod data |
| LGExtendedElectricity/LGEEAgree.lua | a generator (only registers in multiplayer) |
| PZM_Puker_Decals.lua (PZ The Mutants) | an object with mod data (puke always saves its expiry there) |
| vfx_agingmanager.lua (VFE) | ground items or a container |
| vfx_storydistribution.lua (VFE) | a container |
| vfx_birthday_world.lua / vfx_birthday.lua (VFE) | ground items |
| qolc_reasonable_alarms.lua (QoL Compendium) | doors or windows (special objects), or a vehicle |
| TABAS_STubFluidContainerSystem.lua | a square in its tub registry |

Each condition comes from reading that mod's handler. One exception: Mutants puke that somehow has no saved expiry is no longer given one when its chunk loads. It is the minimum the handler needs before it does anything, so skipping a square changes nothing for that mod.

The patch leaves these alone: DAMN_Spawns, FittedBarricades, FittedSheets (their source wasn't available), every other event, and LoadChunk.

## Install
Copy the `ChunkLoadSieve` folder to `%USERPROFILE%\Zomboid\mods\`, then enable "Chunk Load Sieve" in the Mods menu. Load order doesn't matter: the file name sorts it ahead of the mods it patches.

To check it is working, look in `console.txt` for `[ChunkLoadSieve] active, N handlers captured: ...`. Every 2 minutes it also prints how many squares loaded and how many times each caught handler was actually called.

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
- 1.0: first test drive. All 11 handlers were caught, but the shared check cost 43 microseconds a square. The old handlers together cost about 55 by the profiler's count, which counts profiler overhead 11 times, so the real saving was small.
- 1.1: rewritten for Kahlua's slow calls. Sprite names are cached per sprite, and a square with nothing of interest runs no handler loop. TABAS now only gets squares in its tub registry, and Mutants only gets squares with mod data.
