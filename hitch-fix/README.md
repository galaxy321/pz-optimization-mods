# Hitch Fix

A performance patch for galaxy321's Lumberjack save. It removes three periodic frame freezes and one steady cost. It does not edit any other mod's files. It catches the handlers as they register, by file name, the same way Chunk Load Sieve does.

| What | Before | After |
|---|---|---|
| [AmmoMaker](https://steamcommunity.com/sharedfiles/filedetails/?id=2788256295) casing clean-up (`server/ammomaker_itemCleanUp.lua`) | 24 to 37 ms in one frame every 10 in-game minutes. The list grows forever, because an entry whose casing was picked up is never removed. | 200 entries per tick. Each entry string is parsed once. Entries with nothing left to clean are dropped. |
| Vanilla farming `SFarmingSystem:checkPlant` | About 30 ms in one frame every 10 in-game minutes, on the same frame as AmmoMaker. | 20 plants per tick. The checks are unchanged and run in the same order. A pass still running is finished before the next one starts. |
| Tuna [gun racks](https://steamcommunity.com/sharedfiles/filedetails/?id=3784677588) and [equipment racks](https://steamcommunity.com/sharedfiles/filedetails/?id=3793403177) `OnTick` sweeps | About 11 ms/s, in 2 to 3 ms bursts twice a second, even with no rack near. | Their handlers run only within 9 squares of a known rack. Chunk Load Sieve 1.2 notes rack squares as chunks load. Racks are also picked up when one is placed (`OnObjectAdded`), and a slow rescan runs one row per tick. |
| [Night Vision Framework](https://steamcommunity.com/sharedfiles/filedetails/?id=3684087856) goggle check (`NV.Shared.IsNVTaggedItem`) | About 4.7 ms/s. Every 30 player updates it tests every worn item for being goggles, about 1.8 ms each time with a full outfit, even with no goggles. | The answer is remembered per item type, so a check is one lookup per worn item. It is forgotten whenever a mod registers a new goggle type. Expected, not yet profiled: close to 0 ms/s. (1.1) |

## Install

- Copy `HitchFix` to `Zomboid\mods\` and enable it.
- Update Chunk Load Sieve to 1.2, which adds `ChunkLoadSieve.watch`. Without 1.2, racks are found only by the rescan, which runs every 10 s.
- Load order does not matter. The file name `!!!_HitchFix.lua` sorts before the patched mods' files.

## Check it is working

The console shows:
- `[HitchFix] caught ...` for each handler it caught.
- `[HitchFix] active (1.1), caught: ...`, `[HitchFix] farming checks spread over ticks` and `[HitchFix] night vision goggle check remembered per item type` when the game starts.
- Every 10 real minutes, a line with the casing, farming, rack and night-vision item type counts.

## Turn parts off

Set `ENABLE_AMMO`, `ENABLE_FARMING`, `ENABLE_RACKS` or `ENABLE_NV` at the top of the Lua file to `false`.

## Test

Run `python3 mock_test.py` (needs `lupa`). It runs the patch against stand-ins for the real files, with and without Chunk Load Sieve.
