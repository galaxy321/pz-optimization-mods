#!/bin/sh
# ZombieBuddy copies each advice method's body into the game class it patches, so
# every class, method and field of this mod that an advice body touches must be
# public (0.1.0 crashed on a package-private Patches.report()). Lists those
# references from the compiled advice classes and checks each one is public.
#   sh check_advice_access.sh <folder with compiled pzmod/loadfix classes>
set -e
C="$1"; bad=0
for f in "$C"/pzmod/loadfix/Patches\$Patch_*.class; do
  cls=$(basename "$f" .class)
  javap -c -p -cp "$C" "pzmod.loadfix.$cls" 2>/dev/null \
    | grep -E 'invoke(static|virtual|special)|[gp]et(static|field)' \
    | grep -o '// [A-Za-z]* pzmod/loadfix/[^ ]*' | sort -u > /tmp/lf_refs.$$ || true
  while read -r _ kind ref; do
    owner=$(echo "$ref" | sed 's/\.[^.]*$//' | tr / .); member=$(echo "$ref" | sed 's/.*\.//; s/:.*//')
    sig=$(javap -p -cp "$C" "$owner" 2>/dev/null | grep -E "[ .]$member[(;]" | head -1)
    if javap -cp "$C" "$owner" 2>/dev/null | head -2 | grep -q "public class\|public final class" && echo "$sig" | grep -q "public"; then
      echo "ok   $cls -> $owner.$member"
    else
      echo "FAIL $cls -> $owner.$member is not public: $sig"; bad=1
    fi
  done < /tmp/lf_refs.$$
  rm -f /tmp/lf_refs.$$
done
[ $bad = 0 ] && echo "ADVICE ACCESS OK" || { echo "ADVICE ACCESS FAILED"; exit 1; }
