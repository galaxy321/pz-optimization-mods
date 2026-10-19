#!/bin/sh
# Builds Load Fix against the stand-in game classes and ZombieBuddy's jar, then runs
# PatchesTest on a generated awkward folder tree.   sh run.sh <ZombieBuddy.jar> [projectzomboid.jar]
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ZB=$(realpath "$1")
W=/tmp/lftest.$$; mkdir -p "$W"; trap 'rm -rf "$W"' EXIT
javac -d "$W/stubs" $(find "$HERE/stubs" -name '*.java')
javac -cp "$W/stubs:$ZB" -d "$W/mod" "$HERE"/../src/pzmod/loadfix/*.java
javac -cp "$W/stubs:$W/mod" -d "$W/test" "$HERE/src/PatchesTest.java"
sh "$HERE/make_tree.sh" "$W/tree"
java -cp "$W/stubs:$W/mod:$W/test:$ZB" PatchesTest "$W/tree" "$W/tree/mod A" "$W/tree/missing"
sh "$HERE/check_advice_access.sh" "$W/mod"
# With the game jar as a second argument, also check ZombieBuddy would apply every advice.
if [ -n "$2" ]; then
  javac -cp "$ZB:$W/mod" -d "$W/chk" "$HERE/src/AdviceMatchCheck.java"
  java -Dnet.bytebuddy.experimental=true -cp "$ZB:$W/mod:$W/stubs:$W/chk" AdviceMatchCheck "$(realpath "$2")"
fi
# The patches applied by ZombieBuddy's own engine to the stand-in classes.
javac -cp "$W/stubs:$W/mod:$ZB" -d "$W/zbt" "$HERE/src/ZBIntegrationTest.java" "$HERE/src/TestAgent.java"
printf 'Premain-Class: TestAgent\nCan-Retransform-Classes: true\nCan-Redefine-Classes: true\n' > "$W/agent.mf"
jar cfm "$W/agent.jar" "$W/agent.mf" -C "$W/zbt" TestAgent.class
(cd "$W/tree/game" && java -javaagent:"$W/agent.jar" -cp "$W/stubs:$W/mod:$ZB:$W/zbt" ZBIntegrationTest "$W/tree")
