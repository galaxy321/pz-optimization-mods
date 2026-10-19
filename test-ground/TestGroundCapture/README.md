# Test Ground Capture 1.0.7

A ZombieBuddy submod of Test Ground. It takes Test Ground's screenshots (the plan's `screenshot = N`) without the game window having to be on screen.

## Why

The game's own screenshot copies the window's front buffer, which is what is on the screen. A covered or minimised window gives an empty picture. Drive view run 2 had the game minimised behind a full-screen app, and all 45 shots were blank.

## How it takes a shot

The plan key `capture` picks the way; it defaults to `auto`.

| capture | What it reads | Has the game UI | Works covered | Works minimised |
|---|---|---|---|---|
| `back` | The finished frame, from the back buffer just before the game shows it (a patch on `Display.swapBuffers`) | yes | expected yes (not yet tested on the PC) | **no**: a minimised window has no frame to read; the shot is skipped and the report says so |
| `world` | The game world from the offscreen buffer the game draws it into, scaled to the screen size, with the drive view overlay drawn on top by Java | no (only the drive view) | yes | only while the game keeps drawing the world when minimised; not yet tested. A shot whose world is identical to the last one is marked "world UNCHANGED" |
| `both` | Both, the world one named `..._world.png` | | | |
| `auto` | `back` while the window is on screen, `world` while it is minimised | | | |
| `game` | The game's own screenshot (needs the window on screen) | | | |

Without this mod, or if it fails, Test Ground uses the game's own screenshot. Each shot's result (size, share of non-black pixels, BLANK, minimised) goes in the trace as `capture: ...`, and the report's screenshots line has the totals.

## Film mode (1.0.2)

For the showcase film: frames the game itself draws, so only the game is in the film. Test Ground's plan key is `film = <fps> <width>`, for example `film = 30 1280`.

- **Source**: the back buffer just before `Display.swapBuffers`, as `capture = back`, so the banner and HUD are in it. Frames are taken at the fps wanted by wall clock; a game slower than that gives every frame. While the window is minimised there is nothing to read: the frame is skipped and counted.
- **No stall**: each frame is read into one of three pixel-buffer objects in turn, and the one read two frames earlier is mapped and copied into a pooled array. Two writer threads (1.0.4; `Film.WRITERS`, 1 to 4) take frames from one queue; each flips its frame, scales it to `width` (an even height kept to the aspect ratio, never wider than the window, a 2x2 average for 2560 to 1280) and writes the JPEG on its own, at quality 0.85 (`filmQuality`). Up to 8 frames wait in the queue, with a pool of writers + 8 + 1 arrays; when the writers are behind, the frame is dropped and counted, never waited for. (1.0.3 had one writer and 3 waiting, and on the PC at 30 fps, 1280 wide, it dropped 1538 frames of 6259.) If the PBOs fail, it goes on with a plain `glReadPixels` (which waits for the GPU) and `filmStatus` says so.
- **Output**: `Zomboid/Lua/film/<run id>/000001.jpg ...` (a second film with the same id goes in `<run id>_2`), and `frames.txt` in the same folder: a `#` header line, then one line per frame written, `<seq> <epoch ms when read> <tag> <file>`, in seq order. Since 1.0.4 seq is given when a frame is handed to the writers, so a frame dropped there (queue full) or that fails to write leaves a gap in seq and in the file names (`000009.jpg` missing, say); a frame dropped because no array was free gets no seq. The writers finish frames out of order, so each line waits in a small reorder buffer until the lines before it are in; a dropped frame is settled at once, so nothing waits for it. Take the files from `frames.txt`, not by counting; the timestamps keep the real timing for `showcase/encode-frames.ps1`. A tag is one word (white space becomes `_`).
- **Cost**: the render thread's part (the read, the map and the copy) is timed per frame. Steps' frame metrics while filming are not a measurement of the game alone.
- **With stills**: a still and a film frame on the same swap: the still is read first.

| Lua (`TGCapture.`) | Returns |
|---|---|
| `filmStart(runId, fps, width)` | `true`, or `false` if a film is running, the last one is still stopping (1.0.5), or its folder can't be made (`filmStatus` says why). fps 1 to 60, width 320 to 3840 |
| `filmTag(tag)` | nothing. The tag of the frames from now on: a step's tag, `gap` between steps; it is `settle` at the start |
| `copySaveStart(mode, src, dst)` / `copySaveStatus()` | 1.0.7, for Benchmark Save: copies `Saves/<mode>/<src>` to `Saves/<mode>/<dst>` on its own thread. Start returns `""` or why not (a name that isn't a plain folder name, a mode that isn't a game mode, no such save, the copy's folder exists, a copy already running). Status says `idle`, `copying N of M MB`, `done` or `failed: why`. Refused over 20 GB or without the save's size plus 512 MB free; links are left out; a failed copy removes the folder it made. Lua can't reach the game's own copy (`IngameState.copyWorld`). Never touches the original |
| `filmStop()` | `true` if a film was running. Since 1.0.5 it returns at once (see **Stopping** below); `frames.txt` is complete when `filmStatus` no longer says `stopping` |
| `filmStatus()` | one line: `running`, `stopping`, or once stopped the reason (`stopped by filmStop`, ...); the quality; frames written and queued; the writers and their ms per frame; the read path; the folder |
| `filmTake()` | the counts since the last take, then resets them: `film: 812 frames written, 14 dropped (writer behind), 3 skipped (window minimised), capture 1.4 ms per frame on the render thread (worst 6.0)`, then `; by tag written/dropped/skipped: ...` when there was more than one tag. Frames are counted when written, so a step's last few frames can fall in the next take |
| `filmTotal()` | the same for the whole film, then `; stopped: ...` with the reason once it has stopped |
| `filmAlive()` | `true` while a film runs. Test Ground's heartbeat, about once a second while the run goes on (1.0.3) |
| `filmMaxMinutes(minutes)` | the cap kept: 1 to 120 minutes, 20 by default. It applies to the film running and later ones (1.0.3) |
| `filmQuality(q)` | the JPEG quality kept: 0.5 to 0.95, 0.85 by default. It applies from the next `filmStart`, not to a film running (1.0.4) |

**A film stops itself (1.0.3)**, the same as `filmStop`, so a run that doesn't end normally (a quit to the main menu, a Lua error) can't keep filling the disk. The reason is in `filmStatus` and at the end of `filmTotal`:

| When | Reason |
|---|---|
| no `filmAlive` or `filmTag` for 10 s | `stopped: no word from Test Ground for 10 s` |
| the game is out of the world (its state isn't `IngameState`) for 2 s | `stopped: the game left the world (quit to the main menu?)` |
| the film reaches the cap | `stopped: reached the cap of 20 minutes` |
| under 2 GB free under the film folder (checked every 100 frames written, by whichever writer wrote the 100th) | `stopped: 1.4 GB free under the film folder, under 2 GB` |
| `filmStop()` | `stopped by filmStop` |

**Stopping (1.0.5).** `filmStop()` only marks the stop and returns at once: Lua calls it on the game thread, and 1.0.4's wait there for the render thread froze the game about 1 s and lost the last frames in the PBOs. The render thread, at its next frame, empties the PBOs into the writers and ends the film; the writers write what is queued and close `frames.txt` on their own threads (at most 3 s, `Film.DRAIN_MS`, then what is left is dropped and counted). If no frame is drawn within 2 s of the stop (`Film.PICKUP_MS`; the game quit, say), a watchdog thread ends the film without the frames still in the PBOs. A stop the film makes itself (the table above) works the same way, from the render thread.

- While that goes on, `filmStatus` says `film <id> stopping: ...`; then `film <id> stopped by filmStop: ...` (or the film's own reason), ending `film <id> stopped by filmStop, frames.txt complete`, plus `(no render frame came within 2000 ms of the stop, so the frames still in the PBOs were lost)` when the watchdog ended it.
- `filmStart` while the last film is still stopping returns `false` at once (it never waits on the game thread) and `filmStatus` ends `filmStart refused: film <id> is still stopping (N ms since its stop; try again when filmStatus no longer says stopping)`. A stop takes well under 6 s; a film still stopping 10 s after its stop (`Film.ABANDON_MS`) is left to its threads and no longer refuses a new film.
- `filmTotal` and `filmTake` keep giving the stopped film's counts until the next `filmStart`.
- Each pooled frame array goes back to the pool exactly once, whether its frame is written, fails to write, is dropped or is left at the stop (1.0.4 gave it back twice when a JPEG failed to write).

At 1280x720 a frame is about 100 KB, so 30 fps is about 180 MB a minute on disk; the PC encodes and deletes the frames afterwards.

## Install

Needs Test Ground 1.13.7 or later and ZombieBuddy. The jar must be signed with the user's ZombieBuddy key on the PC (`zbs-sign-mod.ps1`), or allowed once in ZombieBuddy's prompt.

## Build and test

- `java/build.sh` builds `42/media/java/tgcapture.jar` reproducibly (see its header for `GAME_CLASSES` and `ZB_JAR`).
- `java/test/Smoke.java` checks the picture side outside the game: rows flipped, scaled, overlay drawn, a blank frame seen as blank, and a PNG written.
- Test Ground's `mock_test.py` checks the Lua side: shots go through `TGCapture` with the plan's mode, the overlay is sent, and a failure falls back to the game's screenshot.
- `java/test/FilmTest.java` checks the film side the same way: sizes, the scaler and its flip, the JPEG, the writer's pool and queue with drops counted, `frames.txt`, and the stats lines; the heartbeat, out-of-world, cap and disk stops on a made-up clock; and (1.0.4) two writers giving `frames.txt` in seq order with gaps for dropped and failed frames, `filmQuality`'s clamp, and `filmStop` draining both writers; (1.0.5) `filmStop` returning at once, `stopping` until a made-up render frame or the watchdog ends the film, `filmStart` refused meanwhile, `filmTotal` after the stop, and the pool after a failed JPEG write (every array back once). Run: `java -cp tgcapture.jar:. FilmTest <new, empty out dir>`.
- The OpenGL reads can only be checked in the game.
