#!/usr/bin/env bash
# CORPUS CENSUS: run every dump under N knob specs and print the census lines side by side, with
# each spec labelled A/B/C/... so the table is readable when the specs are long (a leave-one-out
# sweep over seven knobs makes every spec ~90 characters, and the raw output is unreadable).
#
# ⛔ ONE PROCESS PER AREA, NEVER ONE PER SPEC -- LuaJIT randomises string hashing per process, so two
# invocations differ by hash seed as well as by knobs and an A/B across them is void (see
# [[reference_luajit_hash_seed]]).  test_dump_layout runs every spec inside one process, which is
# exactly why the specs are handed to it together.
#
#   analysis/census.sh "-" "eqBridgeVeto=true"
#   K="classTight=true,seamMagAll=true" ; analysis/census.sh "$K" "$K,sgNoGrow=false"
#
# AREAS=...  overrides the corpus list (default: the whole corpus, world_live last -- it is 12s).
set -u
cd "$(dirname "$0")/.."
AREAS=${AREAS:-"lyr titleist rand dannoc_on gore_bug world_block soulfly kadagar mael_live nib_live leowon dunstan world_live"}

echo "SPECS:"
i=0
for spec in "$@"; do
  printf '  %s = %s\n' "$(printf "\\$(printf '%03o' $((65+i)))")" "$spec"
  i=$((i+1))
done
echo

for a in $AREAS; do
  [ -f "analysis/$a.txt" ] || { echo "== $a  (no dump)"; continue; }
  echo "== $a"
  luajit analysis/test_dump_layout.lua "analysis/$a.txt" "$@" 2>&1 \
    | grep -E "^[^ ].*collide=|room\(s\) differ" \
    | awk -v specs="$*" '
      BEGIN { n = split(specs, S, / /) }   # note: only used for the label fallback
      { print }' \
    | python3 -c '
import sys, re
specs = sys.argv[1:]
lab = {s: chr(65+i) for i, s in enumerate(specs)}
for ln in sys.stdin:
    ln = ln.rstrip("\n")
    m = re.match(r"^\[(.*)\] vs \[(.*)\]: (.*)$", ln)
    if m:
        print("   %s vs %s: %s" % (lab.get(m.group(1), "?"), lab.get(m.group(2), "?"), m.group(3)))
        continue
    # census line: "<spec><padding><time>s  collide=..."
    m = re.match(r"^(\S*)\s+([\d.]+s\s+collide=.*)$", ln)
    if m:
        body = re.sub(r"\s+\| bloat.*", "", m.group(2))
        print("   %s  %s" % (lab.get(m.group(1), "?"), body))
' "$@"
done
