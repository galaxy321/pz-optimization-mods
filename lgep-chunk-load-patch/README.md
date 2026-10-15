# LG Extended Plumbing: Chunk Load Patch

An unofficial performance patch for [LG Extended Plumbing](https://steamcommunity.com/sharedfiles/filedetails/?id=3779561845) (Project Zomboid, Build 42). It cuts the lag the mod causes while chunks load, which is most noticeable when driving.

It is a separate mod that depends on the original. It does not edit or redistribute any of the original mod's files.

## What it does

The plumbing mod scans every square of every chunk as it loads, looking for barrels, sinks and its own "mirror" objects. On a server, that work happens while the chunk is loading, so a car outruns the map.

This patch changes two things:

- **Only near plumbing.** Nothing in the plumbing mod does anything until a player plumbs a barrel in, so the patch only scans chunks near a known mirror, a plumbed barrel or a pipe, and skips the rest.
- **Spread over time.** The scans it does run are queued and run for at most 2 ms per tick, instead of all at once while the chunk loads.

Plumbing a barrel in or out is recorded, and the area around it is scanned straight away. See [docs/GUIDE.md](docs/GUIDE.md) for the full reasoning and trade-offs, and [docs/WALKTHROUGH.md](docs/WALKTHROUGH.md) for a walk through the code.

## Requirements

- Project Zomboid Build 42.20 or later
- [LG Extended Plumbing](https://steamcommunity.com/sharedfiles/filedetails/?id=3779561845), enabled

## Installation

### Singleplayer, or hosting from your own game

1. Download this repository: **Code → Download ZIP** on GitHub, then unzip it. Or use `git clone`.
2. Copy the `LGEPChunkLoadPatch` folder into your Zomboid mods folder:
   - Windows: `%USERPROFILE%\Zomboid\mods\`
   - Linux / macOS: `~/Zomboid/mods/`

   You should end up with `...\Zomboid\mods\LGEPChunkLoadPatch\42\mod.info`.
3. Start the game, open **Mods**, and enable both **LG Extended Plumbing** and **LG Extended Plumbing - Chunk Load Patch**.
4. Load your save. A copy of the save is safest for the first run.

### Dedicated server

1. Copy the `LGEPChunkLoadPatch` folder into the `Zomboid/mods/` folder of the user account the server runs as.
2. In the server's `.ini`, add `LGEPChunkLoadPatch` to the `Mods=` line after `LGExtendedPlumbing`, written the same way as the other entries on that line.
3. Restart the server.

Players joining need the same mods as the server. Because this patch is not on the Workshop, each player has to install it the same way, in their own mods folder.

### Checking it works

Look in `Zomboid/console.txt` (or the server console) for:

```
[LGEPChunkLoadPatch] active: LG Extended Plumbing's square scan runs from a tick budget of 2 ms, in full only near plumbing.
```

If you see `did not find LG Extended Plumbing's LoadGridsquare handler; standing down` instead, the original mod has changed in a way the patch does not recognise. The patch then does nothing and the original behaves normally.

## Notes

- **Barrels plumbed before installing:** these are found through the mirrors and pipes near them. In the rare case one is missed, unplumb it and plumb it in again.
- **Turning lazy scanning off:** set `LAZY = false` at the top of `42/media/lua/server/LGEPChunkLoadPatch/LGEPChunkLoadPatch.lua` to scan every chunk (spread over ticks only).
- **Removing the patch:** disable it in the Mods menu. It only stores a small list of plumbed barrel locations in the world's save data, which the original mod ignores.
- **Testing:** the logic was tested against a mock of the game's event system, not inside the real game. Please report problems with your game version and the console log.

## Credits

All plumbing behaviour is the work of the author of LG Extended Plumbing. This patch only changes when and where that mod's own scanner runs.
