#!/bin/sh
# Builds TestGroundCapture/42/media/java/tgcapture.jar from java/src.
#   GAME_CLASSES: projectzomboid.jar, or a folder of its classes
#   ZB_JAR:       ZombieBuddy.jar (workshop 3619862853, mods/ZombieBuddy/libs/)
# The game ships Java 25 class files. With a JDK 25+ javac, compile against projectzomboid.jar
# directly; with an older javac, point GAME_CLASSES at a copy whose class-file major version
# was lowered (compile-only, nothing from it is shipped). The jar is built with fixed file
# times, so the same source gives the same SHA-256. Signing (zbs-sign-mod.ps1) is done on the PC.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
javac --release 21 -nowarn -cp "$GAME_CLASSES:$ZB_JAR" -d "$OUT" "$HERE"/src/pzmod/tgcapture/*.java
mkdir -p "$HERE/../42/media/java"
(cd "$OUT" && find pzmod -exec touch -d "2026-10-18 00:00:00" {} + && jar --create --date=2026-10-18T00:00:00Z --file "$HERE/../42/media/java/tgcapture.jar" pzmod)
rm -rf "$OUT"
echo "built 42/media/java/tgcapture.jar"
