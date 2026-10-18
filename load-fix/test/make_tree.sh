#!/bin/sh
# Builds a small folder tree with the awkward cases: nested folders, empty folder,
# media/maps/ folders, upper-case .LUA, non-Lua files, a folder link, a file link,
# a broken link, and names with spaces and dots.
set -e
R="$1"; rm -rf "$R"; mkdir -p "$R"
cd "$R"
mkdir -p "mod A/media/lua/shared/sub dir" "mod A/media/lua/client" "mod A/media/maps/Muldraugh, KY" "mod A/empty" "mod B/42/media/lua/server/..dots"
echo x > "mod A/media/lua/shared/a.lua"; echo x > "mod A/media/lua/shared/B.LUA"
echo x > "mod A/media/lua/shared/sub dir/c.lua"; echo x > "mod A/media/lua/shared/readme.txt"
echo x > "mod A/media/lua/client/z.lua"; echo x > "mod A/media/maps/Muldraugh, KY/map.info"
echo x > "mod B/42/media/lua/server/..dots/d.lua"; echo x > "mod B/mod.info"
for i in $(seq 1 50); do echo x > "mod B/42/media/lua/server/f$i.lua"; done
ln -s "../mod A/media/lua/shared" "mod B/linked"
ln -s "../mod B/mod.info" "mod A/info-link"
ln -s "/nonexistent/target" "mod A/broken-link"
mkdir -p "mod C/media/lua/shared/real"
echo x > "mod C/media/lua/shared/real/r.lua"
ln -s "real" "mod C/media/lua/shared/dirlink"
ln -s "real/r.lua" "mod C/media/lua/shared/filelink.lua"
ln -s "../../../../mod A/media/lua" "mod C/media/lua/shared/outside"
# All lower case, for the relative-path check on a case-sensitive file system.
mkdir -p "lower/media/maps/town/sub" "lower/media/lua/shared"
echo x > "lower/media/maps/town/map.info"; echo x > "lower/media/maps/town/sub/0_0.lotpack"; echo x > "lower/media/lua/shared/l.lua"
# A stand-in game folder (lower case) for ZomboidFileSystem.init in ZBIntegrationTest.
mkdir -p "game/media/lua/shared" "game/media/maps/muldraugh, ky" "game/media/scripts" "game/media/anims"
echo x > "game/media/lua/shared/x.lua"; echo x > "game/media/maps/muldraugh, ky/0_0.lotheader"; echo x > "game/media/scripts/items.txt"
