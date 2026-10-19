# Test Ground Autorun: hands-free runs

*Audience: the project owner / PC runner. Ships with: Autorun (dev only, not in the Workshop). Draft; source of truth is the header of `TestGroundAutorun.lua` (1.4.x) and `perf/test-run.md`.*

Autorun loads a save from the main menu, runs a Test Ground plan, writes a result file and quits to desktop. It does nothing unless `Zomboid\Lua\TestGround_autorun.txt` exists and names a save.

## One-time setup
- Enable Autorun in the **main menu** mod list (`Zomboid\mods\default.txt`; only main-menu mods run at the menu) and in the test save's mod list.
- pzopt's harness presses the loading screen's "click to start": write `Zomboid\Lua\pzopt-harness.txt` containing `mode=play` before each launch.

## Each run
1. Put a clean copy of the test save in place.
2. Write the flag file `Zomboid\Lua\TestGround_autorun.txt`:
```
save = Lumberjack - Copy - PerfTest
mode = Sandbox
plan = baseline
delay = 20
timeout = 900
quit = 1
```
3. Launch the game. Wait for `Zomboid\Lua\TestGround_autorun_done.txt` (`result = done | stopped: <why> | timeout | no run | load failed`, plus report/trace/perf/spikes names). The game quits 5 s later. Delete the done file before the next launch.

## Flag keys
| Key | Meaning |
|---|---|
| `save`, `mode` | Save name and its folder under `Saves` (default `Sandbox`) |
| `plan` | `baseline`, `fight`, `build`, `treescan`, `survey`, or a plan file name in `Zomboid\Lua\` |
| `delay`, `timeout` | In-game seconds before starting / before giving up |
| `quit` | 0 = stay in game after the run |
| `closeui` | 1 = close Character Info and other windows (not inventory, loot, chat) first; off by default so runs stay comparable |
| `skip` | Phases or step kinds to leave out (`skip = fight_small,fight_large`) |
| `viewpoint` | `first` or `third` (needs Test Ground 1.13.3+ and Project Viewpoint) |
| `start` | `westpoint` (default) or `here` |
| `loads` / `reloadplan` | Load the save N times in one session, quitting to the menu between (for second-world-load bugs) |
| `addmods` | Mods added to the save's list for this run; taken off again at the next menu |
| `newsave`, `mods`, `seed` | Make a new Sandbox save (never over an existing one), with the given mods; with `save` and `plan` also set it then runs it |

## What stalls a run
A popup at load (missing mods, world conversion question); Autorun missing from the main-menu mod list; pzopt not loaded or no harness file. The PC side sees no done file and must time out and kill the game.

## Before Steam updates the game
Run the Load Fix uninstaller (and pzopt's), then reinstall a matching build after the update. Set Steam to update the game only when launched. (Project rule, 18 Oct.)

## Rules for agents using Autorun
- State the expected duration and one expected number before a run.
- End every result note with `Not verified: ...` (what was inferred or not checked) or `Not verified: nothing`.

## Pending
"Benchmark Save" will add an in-game way to pick a save and run on a throwaway copy, overlapping step 1 above for interactive use; Autorun keeps its own copy step.
