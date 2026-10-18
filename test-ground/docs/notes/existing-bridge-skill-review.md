# Review of `release/skill/pz-test-ground` (Bridge item)

Read against the 1.13.16 build. The skill is good and I didn't rewrite it. Changes I'd make before upload:

1. **Step list is incomplete.** "Choosing steps" omits `corpses` (setup and clean-up, not play), `weather`, and `mod:*` steps (`mod:drive`, `mod:look` in 1.13.18/19). Add them, with the note that setup steps shouldn't be read as game performance.
2. **Baseline duration says ~15 minutes**; the suite is now 16 steps and about 19 minutes (Autorun waits of ~1120 s in the 17 Oct runs). Say "15–20 minutes".
3. **No mention of the first-run confirmation dialog beyond one line**, but the Bridge can't click it; also say it appears in a fresh save each time a bench copy is made.
4. **Naming:** when the real-names build lands, tell the agent reports will show display names and keep the old ids as the key (compare.py and plan `skip` still use ids). *(Pending.)*
5. **Add a pointer to `pz-read-test-report`** instead of the current "Reading a report" section, so the logic isn't kept in two places. If the report skill ships only in Test Ground and the Bridge skill is installed alone, keep the short section.
6. Confirm `obstacles = clear` wording matches the final shipped default (release README lists it as open).

Not in scope: mod code, release package.
