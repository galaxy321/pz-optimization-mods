# UI Throttle

A patch mod for the UI costs left after Chunk Load Sieve. It doesn't modify any other mod's files.

## What it changes
1. **Loot window while moving.** The loot window (vanilla, and [CleanUI](https://steamcommunity.com/sharedfiles/filedetails/?id=3437629766)'s version of it) rebuilds its list of nearby containers instantly every time you step onto a new square or turn. That's 2 to 4 times a second while walking, and constantly while driving. Each rebuild also makes [The Shortcut](https://steamcommunity.com/sharedfiles/filedetails/?id=3470659758) redo its item scan, and [Better Sorting](https://steamcommunity.com/sharedfiles/filedetails/?id=2313387159) and other listeners run too. With CleanUI one rebuild measured 12 to 16 ms, which is the stutter you feel. The patch first checks what the window would list around you: floor items, containers, corpses, vehicles, and whether a wall is in the way. It only skips the rebuild when none of that changed. When anything lootable changes, it still rebuilds instantly, as vanilla does, so there's no lag. Inside a vehicle the window only lists the containers your seat can reach in that vehicle, so driving never needs a rebuild there. Switching seats still rebuilds, so the glove box appears or disappears as in vanilla (fixed in 1.0.1). Clicks, transfers and other reasons to refresh are untouched.
2. **[Exact Minute Clock](https://steamcommunity.com/sharedfiles/filedetails/?id=3778884296).** On every frame, it walks your worn items, and sometimes your whole inventory, to find your watch. The patch makes it check 5 times a second instead (`CLOCK_MS = 200`). The clock still draws every frame. The only effect is that putting on or taking off a watch can show up to 0.2 s late.
3. **[Take A Bath And Shower](https://steamcommunity.com/sharedfiles/filedetails/?id=3592172476) grime moodle** (1.1, moved here from Hitch Fix 1.2). It sets the body grime moodle on every player update, about 5 ms/s, although the moodle has four levels and grime changes over in-game hours. The patch runs the same function at most every 250 ms per player (`MOODLE_MS`), and Moodle Framework keeps the value in between. This part is in `shared/!!!_UIThrottle.lua`, because it has to catch the handler as that mod registers it. Expected, not yet profiled: about 0.2 ms/s.

Each part has a switch at the top of its file: `ENABLE_LOOT_WINDOW` and `ENABLE_CLOCK` in `client/UIThrottle.lua`, `ENABLE_TABAS_MOODLE` in `shared/!!!_UIThrottle.lua`.

## Version history
- 1.1.4: two fixes from a code review of 1.1.3. No `missed` line when `ENABLE_TABAS_MOODLE` is switched off. And the line no longer suggests moving UI Throttle in the mod list: the handler is matched only in Take A Bath And Shower's `client/` folder, which always loads after UI Throttle's `shared/` file, so a miss means the mod changed.
- 1.1.3: if Take A Bath And Shower is on but its grime moodle handler wasn't caught, the console says so at game start, with what to do. Build 42 loads all shared files before all client files, each in mod list order, so a target in another mod's `client/` folder is always caught; a miss means the mod changed.
- 1.1.2: two fixes from a code review. Walking beside a parked vehicle now rebuilds the loot window on every step, as vanilla does, because which of the vehicle's containers you can reach depends on where you stand next to it; 1.1.1 could skip those steps while the same car squares stayed in reach. And a window class whose `update` calls its parent's (both patched) is only judged once, so the inner call can't hide a move. CleanUI 42.19 doesn't do this (its vanilla-style and clean classes are separate and swapped in as `ISInventoryPage`), so with CleanUI nothing changes there. Checked against the game's own `ISInventoryPage:refreshBackpacks` (42.21): same 3x3 squares, the same `canReachTo` wall check, floor items, corpses, object containers and vehicles. It also hides animal corpses and, in multiplayer only, safehouse loot, which can only make 1.1.2 rebuild more often than needed, never less.
- 1.1.1: fixes 1.1, which called `next()`, a function the game's Lua doesn't have. Every other mod's `OnPlayerUpdate` handler failed to register, and the files registering them (Combat Text, Gunworks and others) stopped loading at that line. Don't use 1.1.
- 1.1: Take A Bath And Shower's grime moodle throttle moved here from Hitch Fix.

## Mock test
- Walking 30 squares down an empty street past one crate: 3 rebuilds instead of 30. One was at the start, one when the crate came into reach and one when it left.
- Turning next to the crate still rebuilt the window, as in vanilla.
- Driving 100 squares: 1 rebuild getting in and 1 getting out.
- Switching seats in a parked car: it rebuilds.
- The clock's watch check ran 50 times instead of 600.
- The grime moodle was set 4 times in a second of player updates instead of 100, with its own timer per player, and the profiler still reports it under Take A Bath And Shower.

Not yet tested in the real game.

## Install
Copy `UIThrottle` to `%USERPROFILE%\Zomboid\mods\` and enable "UI Throttle (performance patch)". Its position in the load order doesn't matter. `console.txt` shows `[UIThrottle] caught client/TABAS_BodyGrime.lua` (if you use that mod), then `[UIThrottle] active (1.1.4)` and `[UIThrottle] loot window skips rebuilds when nothing nearby changed` once you load a save.

## Settings worth changing (no patch needed)
- **[CHStatusHUD](https://steamcommunity.com/sharedfiles/filedetails/?id=3776182375):** it costs about 830 µs per frame, from drawing 18 rows of icon, bar and text. Your text size of 33 is a native font size on your PC (console: "drawn untouched"), so changing it won't help. Turning off stats you don't need to watch cuts the cost row by row.
- **[Immersive Snow](https://steamcommunity.com/sharedfiles/filedetails/?id=3810071828):** tire tracks cost about 125 µs per frame to draw. In Mod Options, lowering "MaxTireTracks" (default 4000; the mod's own lighter preset uses 1200) and turning off "BloodyTireTracks" cuts that.
- **UI render rate:** your options.ini has `uiRenderFPS=60`. Every mod's UI drawing (CHStatusHUD, Exact Minute Clock, The Shortcut and the rest) runs at this rate, so a lower UI frame rate in the game's display options cuts all of them at once. The world still renders at full FPS. Only the panels update less often.

## CleanUI
CleanUI replaces the whole inventory UI. Its biggest measured cost was `ISInventoryPage:update`, at about 1.5 ms per call. That is the same loot-window rebuild on every square described above, but heavier, because CleanUI's rebuild does more. This patch covers CleanUI's version too, so CleanUI should stutter much less when walking or driving if you turn it back on. Its per-frame drawing, about 15 ms/s for the inventory panes, isn't changed: that would mean rewriting CleanUI itself.
