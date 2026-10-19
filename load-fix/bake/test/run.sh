#!/bin/sh
# Builds the built-in (pzopt-style) Load Fix on the stand-in game classes and checks it gives
# the same results as the plain stand-ins, that every part ran, and that a changed game jar
# turns it off. With the real game jar as third argument, also bakes that and verifies the
# bytecode.   sh run.sh <ZombieBuddy.jar> <asm jars dir> [projectzomboid.jar]
set -e
HERE=$(cd "$(dirname "$0")" && pwd); LF="$HERE/../.."; ZB=$(realpath "$1"); ASM=$(realpath "$2")
ASMCP="$ASM/asm.jar:$ASM/asm-tree.jar:$ASM/asm-analysis.jar"
W=/tmp/lfbake.$$; mkdir -p "$W"; trap 'rm -rf "$W"' EXIT
javac -d "$W/stubs" $(find "$LF/test/stubs" -name '*.java')
javac -cp "$W/stubs:$ZB" -d "$W/mod" "$LF"/src/pzmod/loadfix/*.java
javac -cp "$W/stubs:$W/mod:$ZB" -d "$W/bake" "$HERE"/../src/pzmod/loadfix/bake/*.java
javac -cp "$W/stubs:$W/mod:$ZB" -d "$W/test" "$LF/test/src/ZBIntegrationTest.java" "$LF/test/src/TestAgent.java" "$HERE/BakedTest.java"
javac -cp "$ASMCP" -d "$W/vb" "$HERE/VerifyBaked.java"
mkdir -p "$W/jar"; jar cf "$W/jar/projectzomboid.jar" -C "$W/stubs" .
java -Dnet.bytebuddy.experimental=true -cp "$ZB:$W/mod:$W/bake" pzmod.loadfix.bake.Baker "$W/jar/projectzomboid.jar" "$W/baked"
java -cp "$ASMCP:$W/vb" VerifyBaked "$W/jar/projectzomboid.jar" "$W/mod" "$W/baked"
sh "$LF/test/make_tree.sh" "$W/tree"
# plain: the stand-ins from the jar; baked: the baked copies ahead of the jar, as in the game folder.
(cd "$W/tree/game" && java -cp "$W/jar/projectzomboid.jar:$W/mod:$ZB:$W/test" BakedTest "$W/tree" plain) > "$W/plain.txt"
(cd "$W/tree/game" && java -cp "$W/baked:$W/jar/projectzomboid.jar:$W/mod:$ZB:$W/test" BakedTest "$W/tree" baked) > "$W/baked.txt"
grep '^RESULT' "$W/plain.txt" > "$W/p"; grep '^RESULT' "$W/baked.txt" > "$W/b"
if cmp -s "$W/p" "$W/b"; then echo "ok   baked results identical to the game's ($(wc -l < "$W/p") checks)"; else echo "FAIL baked results differ"; diff "$W/p" "$W/b" | head; exit 1; fi
grep '^\[LoadFix\]' "$W/baked.txt"
grep -q 'built into the game.s classes, checked against projectzomboid.jar' "$W/baked.txt" && echo "ok   start line and jar check"
grep -q 'BAKED RUN OK' "$W/baked.txt" && echo "ok   reload set no folder"
line=$(grep '\[LoadFix\] Lua listing' "$W/baked.txt" | head -1)
echo "$line" | grep -qE 'Lua listing: [1-9][0-9]* walks.*file listing: [1-9][0-9]* walks.*game\+mod file walks: [1-9].*relative paths: [1-9][0-9]* from the listing.*init: [1-9].*folders: [0-9]+ from the cache.* [1-9][0-9]* kept from the mod list' \
  && echo "ok   every part ran" || { echo "FAIL not every part ran: $line"; exit 1; }
# A different game jar: the jar check must turn everything off, and results stay the game's.
mkdir -p "$W/jar2/x"; (cd "$W/jar2/x" && jar xf "$W/jar/projectzomboid.jar" && printf '\0' >> zombie/ZomboidFileSystem.class && jar cf "$W/jar2/projectzomboid.jar" .)
(cd "$W/tree/game" && java -cp "$W/baked:$W/jar2/projectzomboid.jar:$W/mod:$ZB:$W/test" BakedTest "$W/tree" baked) > "$W/off.txt" 2>&1 || true
grep -q '\[LoadFix\] OFF: zombie/ZomboidFileSystem.class in projectzomboid.jar has changed' "$W/off.txt" && echo "ok   changed game jar turns it off" || { echo "FAIL jar check"; cat "$W/off.txt" | head; exit 1; }
grep "\[LoadFix\] Lua listing" "$W/off.txt"; grep "\[LoadFix\] Lua listing" "$W/off.txt" | grep -q 'Lua listing: 0 walks.*file listing: 0 walks.*init: 0' && echo "ok   nothing patched ran" || { echo "FAIL parts ran while off"; exit 1; }
grep '^RESULT' "$W/off.txt" | grep -v '^RESULT reload=\|^RESULT boot=' > "$W/o"; grep -v '^RESULT reload=\|^RESULT boot=' "$W/p" > "$W/p2"
cmp -s "$W/p2" "$W/o" && echo "ok   results while off identical" || { echo "FAIL results while off differ"; exit 1; }
if [ -n "$3" ]; then
  java -Dnet.bytebuddy.experimental=true -cp "$ZB:$W/mod:$W/bake" pzmod.loadfix.bake.Baker "$(realpath "$3")" "$W/real"
  java -cp "$ASMCP:$W/vb" VerifyBaked "$(realpath "$3")" "$W/mod" "$W/real"
fi
echo "BAKE TESTS OK"
