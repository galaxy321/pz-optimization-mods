# Test Ground docs and skills: drafts for review (18 Oct 2026)

Drafts only. Nothing here is in the mod code or the release package. Status of the facts: written from the 1.13.16 release candidate, `README.md`, `perf/test-run.md` and the Autorun header. Three features asked for today (real test names, end-of-run stats screen with countdown, "Benchmark Save" menu button) are **not built yet**; where a draft touches them it says "pending" and gives the intended behaviour from the Mod test ground design note.

"Ships with" uses the packages in `release/README.md`: **Test Ground** (Lua mod, public), **Test Ground Bridge** (command-file bridge, public, requires Test Ground), **Autorun** (hands-free launcher, dev only, not shipped yet), **Capture** (Java jar, not shipped).

| # | Item | Kind | Audience | Ships with | Priority |
|---|---|---|---|---|---|
| 1 | [guides/quick-start.md](guides/quick-start.md) | Guide | Players measuring their mod list | Test Ground | High: the Steam page needs it |
| 2 | [skills/pz-read-test-report/](skills/pz-read-test-report/SKILL.md) | Skill | Anyone (or any agent) holding a report and asking "is this better or worse?" | Test Ground | High: needs no Bridge, no agent setup. Goes first for Steam visitors (confirmed by user, 18 Oct) |
| 3 | [skills/pz-mod-test-step/](skills/pz-mod-test-step/SKILL.md) | Skill | Mod authors adding a step or survey finder to their own mod | Test Ground (the API is the mod's) | Medium. Placement confirmed by user, 18 Oct |
| 4 | [guides/autorun-hands-free.md](guides/autorun-hands-free.md) | Guide | The project owner / PC runner | Autorun | Medium: only matters if Autorun ships |
| 5 | [skills/pz-autorun-benchmark/](skills/pz-autorun-benchmark/SKILL.md) | Skill | An agent queuing unattended runs (flag file, done file, game-update rule) | Autorun | Medium |
| 6 | [skills/pz-mod-writing/](skills/pz-mod-writing/SKILL.md) | Skill | Modders writing or patching a B42 mod | Developer add-on (Bridge item) | Added 18 Oct on request; has a B41 to B42 migration appendix (`references/`) |
| 7 | [skills/pz-mod-performance/](skills/pz-mod-performance/SKILL.md) | Skill | Modders and players finding and fixing slow mods | Developer add-on (Bridge item) | Added 18 Oct on request |
| 8 | [notes/existing-bridge-skill-review.md](notes/existing-bridge-skill-review.md) | Review notes | Reviewers | n/a | Needed before upload |

## Pending facts (Test Ground 1.13.20 in review, Autorun 1.5.0, Capture 1.0.6)
Per the coordinator: step display names; plan keys `popups` (closer on by default, `popups = keep` off) and `endscreen`; a `look` step / `mod:look`; Benchmark Save flow (copy named `TG Benchmark <save> <stamp>`, deleted at next main menu); Autorun flag keys `origin`, `endscreen`, `addmods`. Not yet written into the guides: add them when the build clears review.

## Judgement calls to confirm
1. **The existing `pz-test-ground` skill stays in the Bridge item** (an agent needs the Bridge to drive anything). I did not duplicate it. The report-reading part is duplicated on purpose in item 2 so players without an agent get it from the Test Ground item.
2. **Capture gets no new doc.** Its `README.md` is already a full reference; a skill would only repeat it. Add a one-paragraph "film and screenshots" pointer to item 1 if Capture ships.
3. **Autorun items stay out of the Workshop** while Autorun is dev-only (they name this PC's launcher and a `pzopt` harness). They live in the project until a "dev" item exists.
4. **Names:** the step tables in item 2 use today's ids (`drive_fast`, `glide_fog`...). When the real-names build lands, only the name column changes; ids stay.

## What I want reviewed
- Items 1 and 2: are they what you want a Steam visitor to see first? (Item 2 is the one I think matters most.)
- Whether item 3 belongs in the public Test Ground item or only in the Bridge skill.
- Item 8: the six fixes I think the Bridge skill needs before upload.
