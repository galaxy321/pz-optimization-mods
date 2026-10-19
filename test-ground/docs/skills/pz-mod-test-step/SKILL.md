---
name: pz-mod-test-step
description: Use when a Project Zomboid Build 42 mod author wants their own mod to have a Test Ground test step or survey finder, so the mod can be measured or checked the same way every run.
---

# Adding a Test Ground step to a mod

Draft, ships with Test Ground (the API belongs to the mod, not the Bridge). Reference for the full API is in the Test Ground README ("For other mods"); the working example is in the Bridge skill. This skill is the checklist.

## Where the code goes
A file that does nothing without Test Ground, in the mod under test: `42/media/lua/client/<Mod>/<Mod>Test.lua`, starting with `if not TestGround then return end`. Never make the mod require Test Ground.

## Pieces
- `TestGround.addStep(kind, { begin = function(run, step) ... end, tick = function(run, step, t, dtMs) ... return true when done end })`. A plan uses it as `step = <kind> <numbers> [tag]`. `step.a`, `step.b` are the first two numbers, `step.args` every word, `run.p` the player, `run.plan.extra["<mod>.<key>"]` the plan lines `<mod>.<key> = value`.
- `step.result = "..."` is the one-line summary in the report. `TestGround.note(tag, ...)` writes to the behaviour log so two runs can be diffed (a no-op outside a run).
- `TestGround.addFinder(name, squareFn, finishFn)` adds lines to `TestGround_site.txt` during a survey; plan-writing for the mod then starts from real spots.

## Rules that keep the test honest
1. A finder asks the mod's **own placement check** (the function the build menu calls). Never reimplement the rule.
2. Build fixtures with the mod's **own create functions** and the menu's arguments. Never place sprites by hand.
3. Build only when the site list has no usable spot; check first whether the fixture already exists so repeat runs don't stack copies; `note` what was built.
4. Make the step report what it checked (`result`), not just that it ran. A step that always passes measures nothing.
5. Guard every world call; a failure should log and let the run go on.
6. Read the Build 42 Lua gotchas (`b42-lua-gotchas.md` in the Bridge skill) before writing Lua.

## Verify
Run a plan containing only the new step in a bench copy of a save, twice. The second run must not leave extra fixtures. Check `TestGround_*_trace.txt` for the notes and the report for the result line.
