# UI Throttle

A patch mod for the UI costs left after Chunk Load Sieve. It doesn't modify any other mod's files.

## What it changes
1. **Loot window while moving.** The loot window (vanilla, and CleanUI's version of it) rebuilds its list of nearby containers instantly every time you step onto a new square or turn. That's 2 to 4 times a second while walking, and constantly while driving. Each rebuild also makes The Shortcut redo its item scan, and Better Sorting and other listeners run too. With CleanUI one rebuild measured 12 to 16 ms, which is the stutter you feel. The patch first checks what the window would list around you: floor items, containers, corpses, vehicles, and whether a wall is in the way. It only skips the rebuild when none of that changed. When anything lootable changes, it still rebuilds instantly, as vanilla does, so there's no lag. Inside a vehicle the window only lists that vehicle's own containers, so moving never needs a rebuild there. Clicks, transfers and other reasons to refresh are untouched.
2. **Exact Minute Clock.** On every frame, it walks your worn items, and sometimes your whole inventory, to find your watch. The patch makes it check 5 times a second instead (`CLOCK_MS = 200`). The clock still draws every frame. The only effect is that putting on or taking off a watch can show up to 0.2 s late.

## Mock test
- Walking 30 squares down an empty street past one crate: 3 rebuilds instead of 30. One was at the start, one when the crate came into reach and one when it left.
- Turning next to the crate still rebuilt the window, as in vanilla.
- Driving 100 squares: 1 rebuild getting in and 1 getting out.
- The clock's watch check ran 50 times instead of 600.

Not yet tested in the real game.

## Install
Copy `UIThrottle` to `%USERPROFILE%\Zomboid\mods\` and enable "UI Throttle (performance patch)". Its position in the load order doesn't matter. `console.txt` shows `[UIThrottle] loot window skips rebuilds when nothing nearby changed` once you load a save.

## Settings worth changing (no patch needed)
- **CHStatusHUD:** it costs about 830 µs per frame, from drawing 18 rows of icon, bar and text. Your text size of 33 is a native font size on your PC (console: "drawn untouched"), so changing it won't help. Turning off stats you don't need to watch cuts the cost row by row.
- **Immersive Snow:** tire tracks cost about 125 µs per frame to draw. In Mod Options, lowering "MaxTireTracks" (default 4000; the mod's own lighter preset uses 1200) and turning off "BloodyTireTracks" cuts that.
- **UI render rate:** your options.ini has `uiRenderFPS=60`. Every mod's UI drawing (CHStatusHUD, Exact Minute Clock, The Shortcut and the rest) runs at this rate, so a lower UI frame rate in the game's display options cuts all of them at once. The world still renders at full FPS. Only the panels update less often.

## CleanUI
CleanUI replaces the whole inventory UI. Its biggest measured cost was `ISInventoryPage:update`, at about 1.5 ms per call. That is the same loot-window rebuild on every square described above, but heavier, because CleanUI's rebuild does more. This patch covers CleanUI's version too, so CleanUI should stutter much less when walking or driving if you turn it back on. Its per-frame drawing, about 15 ms/s for the inventory panes, isn't changed: that would mean rewriting CleanUI itself.
