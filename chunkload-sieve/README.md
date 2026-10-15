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

Each condition comes from reading that mod's handler. One exception: Mutants puke that somehow has no saved expiry is no longer given one when its chunk loads. It is the minimum the handler needs before it does anything, so skipping a square changes nothing for that mod.

The patch leaves these alone: DAMN_Spawns ([damnlib](https://steamcommunity.com/sharedfiles/filedetails/?id=3171167894)), [FittedBarricades](https://steamcommunity.com/sharedfiles/filedetails/?id=3795414660), [FittedSheets](https://steamcommunity.com/sharedfiles/filedetails/?id=3794207681) (their source wasn't available), every other event, and LoadChunk.

## Install
Copy the `ChunkLoadSieve` folder to `%USERPROFILE%\Zomboid\mods\`, then enable "Chunk Load Sieve" in the Mods menu. Load order doesn't matter: the file name sorts it ahead of the mods it patches.

To check it is working, look in `console.txt` for `[ChunkLoadSieve] active (1.2), N handlers captured: ...`. Every 2 minutes it also prints how many squares loaded and how many times each caught handler was actually called.

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
