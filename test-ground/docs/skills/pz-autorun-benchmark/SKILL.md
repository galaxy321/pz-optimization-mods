---
name: pz-autorun-benchmark
description: Use when queuing an unattended Project Zomboid Test Ground run on the PC through Test Ground Autorun (flag file, done file, bench-save copy), or when judging whether such a run finished and can be trusted.
---

# Queuing an Autorun benchmark

Draft, ships with Autorun (dev). Full flag-key list: `guides/autorun-hands-free.md`.

## Before queuing
1. **Review gate:** only a build that cleared Change review goes on the PC queue.
2. **Game update rule:** if Steam may have updated Project Zomboid, run the Load Fix (and pzopt) uninstallers first and reinstall a matching build afterwards.
3. State the job in a few lines: folders to install from, plan, flag keys, what counts as pass. One variant per game load; use a different `label` per variant.

## Job recipe
1. Copy a clean bench save over the test save (never the real save).
2. Install the mod folders (whole `42` folders; check the console for the map-data line).
3. Write `pzopt-harness.txt` (`mode=play`) and the flag file (`save`, `plan`, `delay`, `timeout`; `quit = 1`).
4. Launch, wait for `TestGround_autorun_done.txt`; on no file by `timeout` + margin, kill the game and report "timed out".
5. Collect the report, trace, perf and spikes files named in the done file; delete the done file; restore the user's mod lists and settings.

## Pass / fail
Pass = `result = done`, every step in the report has frame stats, and the versions seen in the console match what was installed. `stopped:`, `timeout`, `no run`, `load failed`, a missing step or a Lua error in `console.txt` are failures: report the line, don't average over them.

## Before each run
State the expected duration and one expected number (for example "about 19 minutes; drive_fast near 100 fps") before launching, so a surprise is visible afterwards.

## Report
Results and blockers only: the done result, report file names, per-step fps/p99/hitches for the steps asked about, and anything that makes the run non-comparable (popup, different mod list, skipped phases).

End every result note with a line `Not verified: ...` naming what was inferred or not checked, or `Not verified: nothing`.
