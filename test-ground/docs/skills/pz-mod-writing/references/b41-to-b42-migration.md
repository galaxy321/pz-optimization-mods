# Build 41 to Build 42 migration appendix

Draft. Tags: **[seen]** confirmed in this project's mods, game files or runs; **[likely]** from general knowledge of the B42 change, not checked here; **[unverified]** a guess to confirm against vanilla before relying on it. Rule for all of them: **grep the game's own `media/` (Lua and scripts) for the thing you are porting and copy vanilla's B42 usage.** Do not port from memory.

## Procedure (do in this order)
0. **Before anything else, fetch the game's own `media/scripts` and `media/lua`** (install folder `...\steamapps\common\ProjectZomboid\media\`) into the working area. Without them, item names, recipe keys and vanilla UI hooks cannot be verified; if they are not available, say so and treat every [likely] below as [unverified].
1. Read the whole B41 mod once; list every item/recipe/entity script, every Lua file's events and Java calls, translations, sandbox options and tiles.
2. Make the B42 skeleton (below) and get the mod to **load with no console errors** before touching behaviour.
3. Run it: enable it in a bench save, load, then read `Zomboid\console.txt` from the top. Fix the first error, reload, repeat. Errors cascade: only the first one is trustworthy.
4. Use Test Ground only after it loads (`pz-test-ground`): a plan with `idle 30` proves it survives; add steps for the mod's features. Keep `TestGround_*_trace.txt` for what happened.
5. Port feature by feature, smallest first. Log one `[Mod] active (version)` line.
6. Give the human a list of everything tagged [unverified] that you could not test in game.

## Folder and mod.info
- B41: `Contents/mods/<Mod>/media/...` plus `mod.info` at the mod root. B42: `common/` (present, may be empty) and a versioned `42/` folder containing `mod.info` and `media/`. [seen]
- The game loads the highest versioned folder not above its own version (`42`, `42.19`...); put B41 files in a folder named `41` only if you want one package for both. [seen]
- `mod.info`: `name`, `id`, `description`, `modversion`, `versionMin=42.0.0`, `require=\OtherModId` (backslash before the id). `tiledef=<name> <number>` for custom tiles. [seen]
- Wrap-up: `poster`, `icon` filenames in `mod.info`; Workshop folder has `preview.png` 256x256. [seen in release notes]

## Scripts: items, recipes, entities
- Item scripts keep the `module Base { item Name { ... } }` shape. [likely] Check the property names of your item type against a similar vanilla B42 item: some were renamed or moved into components (fluid containers, food and tags). [unverified for each]
- **Recipes:** B41 `recipe Name { Ingredient, Result:, Time:, ... }` is replaced by `craftRecipe Name { time = , category = , inputs { item 1 [Base.X] ... }, outputs { item 1 Base.Y } }`. [likely] Learn the exact keys from a vanilla `scripts/recipes/*.txt` file.
- **Recipe Lua hooks** (`OnCreate`, `OnTest`, `OnGiveXP`) have new signatures with craft-recipe data objects instead of `items, result, player`. [likely] Copy a vanilla `recipecode.lua` function.
- **Entities:** buildable things are `entity Name { component UiConfig {...} component SpriteConfig {... face E { layer { row = sprite1 sprite2 } } } component CraftRecipe {...} }`. [seen, see CraneMod_entities.txt] A sprite may appear only once across all faces ("Tile duplicate" stops every save from loading). [seen] Build-menu placement uses `OnIsValid`/`OnCreate` Lua functions named in the script. [seen]
- B41 `ISBuildMenu`/`ISBuildingObject` build code usually has to be replaced by an entity script. [likely]

## Lua and Java API changes
- `sq:Is(flag)` removed: `sq:has(IsoFlagType.x)`; properties via `props:has("Name")`. [seen]
- Character stats moved to `CharacterStat`: `getStats():reset(CharacterStat.ENDURANCE)` (and `PANIC`, `FATIGUE`) instead of per-stat getters/setters. [seen] Check any `getStats():getX()` or `setX()` call. [likely]
- `player:getCheats()` is not indexable from Lua and `setGodMod` needs a role capability; don't port god-mode code. [seen]
- `OnTick` does not fire at the main menu or while paused (`OnFETick`, `OnRenderTick`). [seen]
- Java methods renamed or removed between builds are the largest risk. **Never call a method you have not found in B42 vanilla Lua or a working B42 mod.** [rule]
- Moodles, traits, professions, skills (perks) and food/poison/illness handling were reworked in B42. [likely] Port with vanilla B42 code as the template. [unverified in detail]
- Animals, fluids, foraging and new map object systems are B42-only additions: a B41 mod can't use them as-is. [likely]
- UI classes (`ISPanel`, `ISCollapsableWindow`, `ISInventoryPage`, context-menu and timed-action classes) exist in B42 but some constructors, fields and button handlers changed. Compare against the B42 file of the same name under `media/lua/client/ISUI/`. [unverified per class]
- Timed actions: base class `ISBaseTimedAction` remains; `perform`/`stop` order and `isValid` usage are as vanilla B42 shows. Copy a vanilla action. [likely]

## Translations
- B41 `Translate/EN/ContextMenu_EN.txt` Lua tables become JSON files under `media/lua/shared/Translate/EN/` (`ContextMenu.json`, `Sandbox.json`, `Tooltip.json`, `IG_UI.json`, `Recipes.json`, ...): `{ "Key": "Text" }`. [seen] Whether old `.txt` still loads in your build: [unverified], test.
- Sandbox options: `media/sandbox-options.txt` still used. [seen]

## Multiplayer
Check what runs where: `server/` code and `MapObjects` hooks do not run on an MP client. B42 also changed how some object state syncs. [unverified] State "singleplayer tested only" in the README unless you tested MP.

## Load order caution
Two project notes disagree on whether mod-list order matters for `shared/` file load order (CLAUDE.md says mod-list order, then file name; an older note says file name only). Don't rely on either: hook at `OnGameStart`, or test. [conflict, unverified]

## Known limits of a model porting from memory
Expect to stall on: recipe/craftRecipe keys, renamed Java methods, changed UI signatures, vehicle scripts and anything custom in the animation or sound systems. A mod with custom recipes or vehicles needs a human check in game. Write down what was guessed.
