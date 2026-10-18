# Load Fix

A Java patch, to be shipped as a ZombieBuddy Java mod, that makes the game's folder walks faster on boot, on every Lua reload (mod-list change, Load with a different list, quitting to the menu) and on save load. It does not change any game or mod file. Version 0.1.1 turns on part 1 only (the Lua listing). Part 2 is in the jar but off until the exact-match check passes on the PC.

## Why

Measured on the PC with `perf/tools/WalkBench.java` (see `perf/loading/loading-time.md`, "WalkBench result"):
- `LuaManager.searchFolders` calls `getCanonicalFile()` on the parent folder for every entry, about 0.6 ms each time. That is about 6.7 s of each full Lua load.
- `ZomboidFileSystem.searchFolders` asks `isDirectory()` of every entry, 53-74 us each. An NIO walk gets the same answer from the folder listing for 4-11 us.

## What it changes

`src/loadfix/FastWalk.java`:
1. `luaSearchFolders`: the same walk as `LuaManager.searchFolders`, with the canonical parent worked out once per folder. It's the same call on the same folder, so it gives the same strings.
2. `zfsSearchFolders`: the same walk as `ZomboidFileSystem.searchFolders`, using `Files.walkFileTree` (following links, as `File` does). It gives the same paths in the same order, with the same `\` to `/` and `./` clean-up, the same `media/maps/` folder entries, and the same once-per-entry hook (the game yields and polls the keyboard there). Two cases differ, both where the game would fail: an unreadable folder is added as a path instead of crashing, and a folder loop is skipped instead of recursing forever.

`src/loadfix/Original.java` is the game's two methods, written out from the jar's bytecode, used only for checking.

## Checking it

`build/loadfix-verify.jar` (`loadfix.Verify`) runs both versions on real folders and prints `ALL IDENTICAL` or the first differing path, with timings. It only lists folders.
- In the container: identical on `test/make_tree.sh` (nested and empty folders, `media/maps/`, upper-case `.LUA`, spaces and dots in names, folder and file links, a broken link) and on the vanilla Lua copy.
- On the PC: queued (Workshop folder, game `media`, `Zomboid\mods`); result goes to `verify-pc.txt`.

## Install

- Copy the `LoadFix` folder to `%USERPROFILE%\Zomboid\mods\`, so you get `Zomboid\mods\LoadFix\42\mod.info` and `...\42\media\java\loadfix.jar`.
- Enable "Load Fix (faster folder scans)" in the save's mod list and in the menu list, keeping both lists the same. It needs ZombieBuddy, which is already installed. Load order doesn't matter.
- **Signing:** the jar is unsigned. ZombieBuddy allows unsigned mods by default, but its default policy (`prompt`) shows a dialog on the first launch asking whether to load a new jar. Someone has to approve it once at the PC. After every rebuild of the jar it asks again, because approval is per jar file. The jar's SHA-256 is printed in the README section below, to check against the dialog.
- Rollback: disable the mod, or delete the folder.

## Check it is working

The console shows `[LoadFix] active (0.1.1): Lua listing on, file listing off` while mods load. Then, after each full Lua load, `[LoadFix] Lua listing: N walks, N ms, 0 fell back; file listing: 0 walks, ...`. Compare the Lua time with the game's: about 6.7 s per full load without the mod (game-thread samples). A non-zero "fell back" count means the game's own walk ran for that folder; the first such case prints its reason.

To turn part 2 on for a test, add `-Dloadfix.files=true` to the game's JVM options. `-Dloadfix.lua=false` turns part 1 off.

## Build

`src/pzmod/loadfix/{FastWalk,Patches,Main}.java`, compiled with `--release 21` against `projectzomboid.jar` and `ZombieBuddy.jar`, into `LoadFix/42/media/java/loadfix.jar`. `test/run.sh <ZombieBuddy.jar>` builds against stand-in game classes and checks that the patched walks fill the game's lists exactly as the game's walks do. It also checks that a failing walk adds nothing and hands over to the game's own walk, and that the flags work. The last run printed ALL OK.

0.1.1 jar SHA-256: `cb6f0495404248ed78fa0e3844ad77f222ee1126cb817afc22b7e96e0b611216`

0.2.0 jar SHA-256: `ee39798e64e9410b2e0aef1c48ff2cf9d4d1fae7ae37466192df3d55f27565e9`. It turns on the NIO Lua listing and part 2 (the file listing). The PC check printed ALL IDENTICAL. In the game the Lua listing took 1.3 s instead of 3.5 s, but the file listing never ran (`file listing: 0 walks`).

0.2.1 jar SHA-256: `26f1757346bc6328b0daa49321beb3495f2b17e72464eaa574de825a4981dc74` (in `next/LoadFix`). It fixes that: ZombieBuddy 2.3.4 reads an unannotated advice parameter's position as the game argument's position (PatchEngine.java, signature-aware matcher), so `enter(@Patch.This Object self, File dir)` asked for a second argument that `ZomboidFileSystem.searchFolders(File)` doesn't have, and the advice was applied to nothing, with no error. `dir` is now `@Patch.Argument(0)`. `test/src/AdviceMatchCheck.java`, run by `test/run.sh` when the game jar is passed, follows ZombieBuddy's matching against the real game classes and fails on 0.2.0's jar. The rest of the code is the same as 0.2.0 (compared with javap). The boot's first walk of the game's own folders runs before any mod jar loads, so part 2 can only speed up the per-mod walks at boot (two per mod, inside `loadMods`) and all of them on a Lua reload.

0.1.0 crashed at boot: the advice copied into `LuaManager.LoadDirBase` called a package-private `Patches.report()` (`IllegalAccessError`). In 0.1.1, everything advice calls is public, each advice body catches every error and lets the game's own code run, and `test/check_advice_access.sh` (run by `test/run.sh`) fails the build if an advice body touches anything non-public. The check flags the 0.1.0 jar.

## Still to do

- Part 2 on by default, once the PC's exact-match check passes and an A/B load is clean.

## 0.3.0 (installed on the PC; source of truth: `next-0.3.0/LoadFix`)

Jar SHA-256 `98af27059512c1841c020e070c6252d5659cd4d004e6e72a6345b4e96dece0cd`. Check tool `build/loadfix-verify-0.3.0.jar`, SHA-256 `f33f5f406a989174c571395726d32306609283db7bc8161854ccf12663a76fef`. It adds a fourth comparison, `game`.

- **Part 3, new:** `ZomboidFileSystem.walkGameAndModFilesInternal` sits behind `resolveAllFiles` and `resolveAllDirectories`. pzopt's Lua precompile lists through it at boot, which took 3.1 s on the boot thread. The game lists each folder with `listFiles()`, then asks `isDirectory()` of every entry, and the visitor asks `isFile()`. Here each folder is listed once with NIO, and the visitor gets `KnownFile` objects that already carry both answers. The entries, their order, the path strings and the visitor calls are all the same. A link, a junction, or a folder NIO can't list is listed with `listFiles()`, as the game does. This walk can't start over after an error, because the visitor has already been called. So it has no catch-all, and an error from the visitor reaches the game as it would from the game's own walk. `-Dloadfix.gamewalk=false` turns it off.
- **Part 2, changed:** the file listing no longer walks with FOLLOW_LINKS. Following links made NIO ask the file system about every entry again, which is likely why 0.2.1's file listing still took 1.8-2.0 s over 446 walks. Links and junctions are now handed to the game's own logic at the point the game would reach them.
- **Console line:** it now ends with `game+mod file walks: N, M ms, K folders listed the game's way`.
- **Tests:** `test/run.sh` prints ALL OK, ADVICE ACCESS OK and ADVICE MATCH OK. The test compares the visitor's view (path, folder, isFile, isDirectory) for recursive and flat walks, over plain folders, linked folders, a missing folder and a file. It also checks that a visitor error reaches the caller after the same visits.

0.3.0 on the PC (with pzopt):
- **Check tool:** ALL IDENTICAL (`verify-pc-030.txt`).
- **Boot to menu:** 39.5 s, against 49.2-52.6 s without Load Fix.
- **Lua reload after a mod-list change:** 21.6 s, against 31.6 s without.
- **pzopt's Lua precompile listing:** 0.9 s, against 3.0-3.5 s.
- **Errors:** none, and nothing fell back. Full numbers are in `perf/loading/loading-time.md`.

## 0.4.0 (installed on the PC; `next-0.4.0/LoadFix`)

Jar SHA-256 `37ec6de6722589b458f8e2edc3aef5d0cc2f732868a9445d3819560ebdd778c0`. Check tool `build/loadfix-verify-0.4.0.jar`, SHA-256 `de6164eba0198f6c45498764fd46eabf361e606ed5a43b6d1ea3537581e7ca59`. The check tool adds a `rel` line for each folder.

- **Part 4, new:** this patches `ZomboidFileSystem.getRelativeFile(URI, String)`. In 0.3.0's mod-change reload it was the top cost, at 29% of game-thread samples. `loadMod` and `init` call it for every path the file listing found, and it builds a URI with `File.toURI()`, which asks the file system whether the path is a folder. Part 2's listing already knows that, so it keeps a folder-or-not map for the paths it adds. The patch computes the game's own result with that answer, using `KnownFile`, whose `getAbsoluteFile()` keeps the answer for `toURI()`.
- **What still goes to the game's method:** any path the last listing didn't add, a null base, and, on a case-sensitive file system, a path with capitals. The map is replaced by each listing and cleared at the end of each Lua load. `-Dloadfix.relpath=false` turns it off.
- **Matching:** the patch uses `strictMatch`. Without it, ZombieBuddy would also match the one-argument overloads, because the exit advice has only special parameters.
- **Tests:** `test/AdviceMatchCheck` now follows ZombieBuddy's class-level matching and requires exactly one matched method per patch. A new `test/ZBIntegrationTest` applies the patches with ZombieBuddy's own PatchEngine to already-loaded stand-in classes. It checks that every patched method was really replaced and gives the same results as before patching. `test/run.sh` prints ALL OK, ADVICE ACCESS OK, ADVICE MATCH OK and ZB INTEGRATION OK.

0.4.0 on the PC (with pzopt):
- **Check tool:** ALL IDENTICAL (`verify-pc-040.txt`). Relative paths took 414 ms instead of 8,455 ms for 120,277 Workshop paths, and 107 ms instead of 2,474 ms for the game's media.
- **Boot to menu:** 37.0 s.
- **Lua reload after a mod-list change:** 17.2 s, against 32.4 s without Load Fix in the same pair.

## 0.5.0 (one boot on the PC; `next-0.5.0/LoadFix`)

Jar SHA-256 `04965ea83dcd065fa9b5b5459c4861cf98f915815bdb6fef59a30a04f944aa0b`. Check tool `build/loadfix-verify-0.5.0.jar`, SHA-256 `e01041aefacefd750bfb9c5c9fce8f2f44e65a58828d0458f8f5515f0eb6a2a5`. The check tool adds `kinds` (the listing's folder-or-not answers against asking the file system) and `luarel` (Lua files' relative paths).

- **Part 4, extended:** the Lua listing works out each Lua file's relative path without asking the file system. Every path it hands over is a file, because folders are walked into.
- **Part 5a, new:** `ZomboidFileSystem.init` was 17% of 0.4.0's reload samples, all in its own code. `ZfsInit` writes the method out from the bytecode. It calls the game's own `PZFolder.set`, `searchFolders` and `getRelativeFile` in the game's order, and changes one step: for each path the game-folder listing found, the trailing-separator decision uses the listing's folder-or-not answer instead of `isDirectory()`. Paths the listing didn't add are asked as the game does. If a private field is missing, the game's `init` runs. Once started, errors reach the game as they would from its own `init`. `-Dloadfix.init=false` turns it off. This helps on a Lua reload only, because at boot `init` runs before any mod jar loads.
- **Part 5b, new:** `PZFolder.set(File)` was 12% of the samples. It resolves the canonical path and makes two URIs, which means two "is it a folder?" calls, and ChooseGameInfo builds the same mod folders several times in one Lua load. Within one Lua load, a folder already set gets the game's earlier results again. The cache is cleared when `init` starts a Lua load and when `LoadDirBase` ends one. An error from the game's `set` is never cached. `-Dloadfix.foldercache=false` turns it off.
- **Console line:** it adds `init: N, K paths from the listing, M the game's way; folders: H from the cache, S set by the game`.
- **Tests:** `test/run.sh` prints ALL OK, ADVICE ACCESS OK, ADVICE MATCH OK (7 patches, one method each) and ZB INTEGRATION OK. The integration test now also runs a stand-in `init` (from the bytecode) on a stand-in game folder, before and after patching, and compares everything it leaves behind. It also checks that a folder set twice is set by the game once, and again after the cache is cleared.

0.5.0 on the PC (with pzopt, job 95):
- **Check tool:** ALL IDENTICAL. Folder-or-not answers from the listing matched the file system for all 120,277 Workshop paths (7,318 ms asking, 27 ms from the listing) and 47,553 media paths. Lua relative paths matched for 6,982 Workshop and 1,443 media files.
- **One boot:** 42.8 s to the menu, including the approval dialog wait, so not comparable. No fallbacks or errors. Lua listing 898 walks in 867 ms, file listing 448 walks in 583 ms, pzopt's precompile listing 883 ms.
- **init and folder cache read 0 at boot, as expected:** `PZFolder.set` is only called from `init` and `PZModFolder.setWithCatch` (from the bytecode), and at boot `init` runs before the jar loads. Both only act on a Lua reload, and the reload run hung on the approval dialog (the approval wasn't saved to disk), so they are still unmeasured.
- **Relative paths at boot:** 45,117 from the listing, 57,661 the game's way, about the same split as 0.4.0's boot. 0.5.0 only looked up the most recent file listing, and who asks for the other paths isn't known yet.

## 0.5.1 (installed on the PC; `next-0.5.1/LoadFix`)

Jar SHA-256 `e9350f5599db125f6669416fe3fbf8d7f91f1a7d1afb13521121a212e43a3610`. The check tool is unchanged (`build/loadfix-verify-0.5.0.jar`), since FastWalk didn't change.

- **Part 4:** relative paths are looked up in every file listing since the Lua load began, not just the latest one. The map is cleared when `init` starts a Lua load and when `LoadDirBase` ends one.
- **Console:** the relative-paths line adds `N before any listing`, and below it Load Fix prints up to 12 paths that went the game's way, each with whether it was listed and the first four game frames that asked. That names the source of the 57,661.
- **Tests:** `test/run.sh` prints ALL OK, ADVICE ACCESS OK, ADVICE MATCH OK and ZB INTEGRATION OK. The integration test adds a case where paths from an earlier listing are answered after a second listing (0.5.0 sent them the game's way).

0.5.1 on the PC (with pzopt, `loadfix051-results.zip`):
- **Boot to menu:** 40.3 s in the clean run and 36.7 s in the reload run's boot, against 37.0 s for 0.4.0. 0.5.1 does nothing extra at boot, so the 40.3 is run-to-run spread.
- **Lua reload after a mod-list change:** 14.9 s (0.4.0: 17.2 s; without Load Fix in the same pair: 34.4 s). Whole save load 41.4 s (0.4.0: 50.3 s; without: 61.3 s).
- **init on the reload:** 47,553 paths from the listing, none asked; init fell from 181 samples (7.2 s) without Load Fix to 12 (0.5 s).
- **Relative paths on the reload:** 92,671 from the listing, 3,896 the game's way. The 12 sampled misses are mods' `common` or `42.0` folders that don't exist, which the game's listing adds as the folder itself.
- **Relative paths at boot:** 55,663 the game's way, because the game folder's listing at boot runs before the jar loads. In the samples, getRelativeFile is 25 samples (1.0 s) of the boot, through `getString` from clothing items, textures and Lua, so at most about 1 s is left there.
- **Folder cache: 0 hits, 3,326 sets.** ChooseGameInfo builds 10 folders for each of about 333 installed mods, once per Lua load, so a cache inside one load never hits. On the reload these sets were 57 samples (2.3 s).

## 0.5.2 (installed on the PC; `next-0.5.2/LoadFix`)

Jar SHA-256 `99f082966b19ff5424feac05087fe44520b9acabcad6d9f5238ad7b84045256c`. The check tool is unchanged (`build/loadfix-verify-0.5.0.jar`).

- **Part 5b, changed:** the folder cache now lasts across Lua loads. A new patch on `ChooseGameInfo.Reset`, which `Core.ResetLua` calls before the mods are read again, puts the folders of every mod the game is about to forget into the cache, including the boot's, which were set before the jar loaded. A cached folder is used only if the file system still gives the same folder-or-not answer, so a mod folder created or removed since is set by the game again. It costs one `isDirectory()` instead of a canonical-path lookup and two. Not covered: a folder whose canonical path changes while the game runs (a junction pointed elsewhere, or a folder renamed only in case). `-Dloadfix.foldercache=false` turns it off.
- **Console:** the folders part adds `C changed on disk, K kept from the mod list`.
- **Tests:** `test/run.sh` prints ALL OK, ADVICE ACCESS OK, ADVICE MATCH OK (8 patches, one method each) and ZB INTEGRATION OK. The integration test reads a stand-in mod before patching (the boot), then after `Reset` reads it again with no sets and the same fields, then creates the mod's version folder and checks the game sets that one folder again and gets the new answer.
- **Expected:** about 2 s off the reload (the 2.3 s of sets, less one check per folder). Nothing changes at boot.

0.5.2 on the PC (with pzopt, `approval-sitting-results.zip`): boot to menu 36.7 s clean, 35.9 s in the reload run. Lua reload 12.1 s (0.5.1: 14.9 s; without Load Fix in the same pair: 31.9 s). Whole save load 37.2 s (without: 58.7 s). After the reload: folders 3,310 from the cache, 16 set by the game, 0 changed on disk, 3,320 kept from the mod list. No errors or fallbacks.

## 0.6.0, built into the game's classes (installed on the PC; `next-0.6.0-builtin`)

**Result on the PC (18 Oct):** boot to menu took 30.9 and 30.4 s, against 36.7 and 35.9 s with 0.5.2. Reload and save load times were unchanged (12.4 s and 37.8 s). The installer ran under Windows PowerShell 5.1 with no errors. Details are in `perf/loading/loading-time.md`.

**For 0.6.1 (minor, from the review):**
- `-RestoreZombieBuddyMod` without the installed-files list can bring back 0.5.2 while the 13 files are still in the game folder.
- A user's own `mods\LoadFix` holding only `common\README.txt` would be taken for the marker.

This is the pzopt way of doing it. ZombieBuddy is not used for Load Fix. The same 8 patches are applied ahead of time to 4 of the game's classes (`zombie/Lua/LuaManager`, `zombie/ZomboidFileSystem`, `ZomboidFileSystem$PZFolder`, `zombie/gameStates/ChooseGameInfo`). The changed classes go in the game folder, which comes before `projectzomboid.jar` on the game's classpath (`"."`), next to pzopt's own classes. None of pzopt's 140 classes are among these 4.

- **How it's built:** `bake/` runs ByteBuddy (taken from ZombieBuddy.jar, build time only) over `projectzomboid.jar`. `bake/src/pzmod/loadfix/bake/Advices.java` mirrors each ZombieBuddy patch, and each one still calls the same `Patches` code. `Baker.java` matches each patch by exact signature and writes nothing unless every patch matches exactly one method. It also writes `pzmod/loadfix/baked.properties` with the sha256 of each original class.
- **Game update guard:** on first use, `Patches.bakedStart()` checks those hashes against the classes in the running `projectzomboid.jar`. If the game has been updated, every patch turns off and the console says `[LoadFix] OFF: ...`, telling you to run the uninstaller before playing. When the check passes it prints `[LoadFix] built into the game's classes, checked against projectzomboid.jar`. Note that after a game update the patched classes still replace the new ones, so the game may not start at all, or may silently run old game code, until they are removed. Turning the patches off doesn't fix that. **Rule: run the uninstaller before a Steam game update, and install a build made for the new version after.** Setting Steam to update the game only when it's launched keeps updates from arriving unnoticed. The user agreed to this rule on 18 Oct. The installer refuses a jar it wasn't built for for the same reason.
- **Boot:** in the ZombieBuddy version `init` ran before the jar loaded, so about 55k relative-path lookups at boot missed the cache (about 1 s). Built in, `init` is patched from the start, so boot should gain that back. This is expected, not measured.
- **Tests:** `bake/test/run.sh` bakes the test stubs, verifies the bytecode with ASM, runs the integration tests plain and baked and checks the results are identical, and checks that a corrupted jar turns everything off. Last run: BAKE TESTS OK. Baking the real jar: BAKE OK (4 classes), VERIFY OK (187 methods; 246 including the Load Fix classes).
- **Install:** `install-loadfix-builtin.ps1` checks the jar hash, refuses if pzopt lists any of the same files or if a file it would replace isn't ours, copies the 13 files listed in `loadfix-installed.txt` and checks each hash (Load Fix's own classes first, the game classes last, so a copy that fails halfway can't leave game classes calling missing ones), and only then moves the ZombieBuddy `Zomboid\mods\LoadFix` to `Zomboid\mods-disabled` (noting where in `loadfix-moved.txt`) and puts in a code-free `LoadFix` mod so saves that list it still load. ZombieBuddy itself stays installed for other Java mods.
- **Rollback:** `uninstall-loadfix-builtin.ps1 -RestoreZombieBuddyMod` deletes only files whose hash is still ours, removes folders left empty, and brings back the mod the installer moved, even after an install that failed before copying anything.
- **Not yet run:** both PowerShell scripts (this container has no PowerShell).
