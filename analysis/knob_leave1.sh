#!/usr/bin/env bash
# LEAVE-ONE-OUT: what is each feature knob actually WORTH on the corpus, today?
#
#   analysis/knob_leave1.sh                    # every flippable knob, whole corpus
#   analysis/knob_leave1.sh > analysis/leave1.txt
#   TAGS="faceFit_on ringDilate_off" analysis/knob_leave1.sh
#   AREAS="rand dagoth" analysis/knob_leave1.sh
#
# WHY IT EXISTS (2026-08-21, the knob review): the registry says what each flag was worth on the day
# it shipped. That is not the same question as what it is worth NOW, after three weeks of other
# changes -- and "retire the flag, keep the behaviour" is only safe to decide from the second one.
# User: *"we should do them in batches, A/B test so we know what we are talking about and make
# informed decisions except for the most obvious cases."*
#
# ⛔ ONE PROCESS PER AREA, EVERY SPEC INSIDE IT. LuaJIT randomises string hashing per process, so a
# flip measured in its own invocation is confounded with a hash seed -- see
# [[reference_luajit_hash_seed]]. `test_dump_layout` takes all the specs at once and diffs each
# against the base laid out in the SAME process, which is the only identity check this engine
# accepts. That is also why this is slow: N+1 full relayouts per area, not N+1 processes.
#
# ⛔⛔ DO NOT EDIT lua/layout.lua OR lua/core.lua WHILE THIS RUNS. Each area is a fresh luajit that
# loads the engine at start, so an edit halfway through means the later areas measured different
# code from the earlier ones -- and nothing in the output says so. Same rule as `cover_knobs.sh`.
#
# READING IT. `rooms` is the honest headline: 0 means this flag changes nothing on that area today.
# A flag that is 0 everywhere is either load-bearing-and-unreachable-when-off (fold it) or inert
# (fold it) -- the census cannot tell those apart, and neither can this tool. What it CAN say is
# which flags still move something, and those are the ones worth an argument.
set -u
cd "$(dirname "$0")/.."

# ⛔⛔ A FLAG WHOSE WITNESS AREA IS MISSING READS AS INERT, AND THAT IS AN ARGUMENT TO DELETE IT.
# The 13-area corpus the other harnesses use is tuned for regression, not for coverage of the knob
# set, and on it `topoPlane` and `topoOuterSeed` both move ZERO rooms -- while on `gurk`, which their
# own registry entries name as the only area that fires them, turning them off costs `lie 0 -> 2` and
# `cross 2 -> 6`. Same for `eqPiston` (67 rooms on gurk, silent elsewhere). So this list is DELIBERATELY
# wider than the regression corpus: every dump that is somebody's witness belongs here.
#   gurk        topoPlane / topoOuterSeed / dragBlockTie -- the outer-face conflict
#   cathbad_lie the cascade lie gate
#   mael_edge   the maelstorm loop cases (eq2dUnionBound names maelstorm 6913)
#   garric      process-stable since f4bb490, and the messiest census in the set
#   edoras      small, lie-carrying
# ⚠ The cost is linear in areas AND specs: 82 x 21 full relayouts, and world_live is ~7s of each.
AREAS=${AREAS:-"lyr titleist rand dannoc_on gore_bug world_block soulfly kadagar mael_live nib_live leowon dunstan dagoth gurk cathbad_lie mael_edge mael garric edoras world_live"}

luajit analysis/cover_specs.lua > analysis/cov_specs.txt || exit 1
# the NUMERIC knobs print as a `#` comment, not as a spec, so they are already excluded -- a cap has
# no branch to flip and `springK=false` would multiply a boolean
SPECS=$(grep -v '^#' analysis/cov_specs.txt | grep -v '^base' | cut -f2)
if [ -n "${TAGS:-}" ]; then
  SPECS=$(grep -v '^#' analysis/cov_specs.txt | awk -v want="$TAGS" '
    BEGIN { n = split(want, W, / /); for (i = 1; i <= n; i++) K[W[i]] = 1 }
    K[$1] { print $2 }' FS='\t')
fi
NSPEC=$(printf '%s\n' "$SPECS" | grep -c .)
echo "# $NSPEC spec(s) x $(echo $AREAS | wc -w) area(s), one process per area"
echo

for a in $AREAS; do
  [ -f "analysis/$a.txt" ] || { echo "== $a  (no dump)"; continue; }
  # shellcheck disable=SC2086
  luajit analysis/test_dump_layout.lua "analysis/$a.txt" "-" $SPECS 2>&1 \
    | python3 -c '
import sys, re
area, want = sys.argv[1], int(sys.argv[2])
base, cens, rooms, err = None, {}, {}, []
# ⛔⛔ KEEP len AND hole. The first version cut the census at the first `|`, i.e. at the defect counts,
# and that is precisely the wrong place: several knobs exist to BUY a defect in order to SAVE length.
# `attachLicensed`, `guardLicensed` and `crossCostBox` all deliberately accept a crossing so the map
# does not grow a super-long edge (the user, 2026-08-21: *"they are THERE to force crossings to make
# the map understandable and not have super long edges"*). Judged on defects alone such a knob can
# only ever score "better when flipped" -- the tool would recommend deleting exactly the rules whose
# whole purpose it cannot see. Same blindness made the `tie-only` bucket meaningless: identical
# defects, and `vertPack` moving 665 rooms with `hole 1128 -> 1112` invisible.
def trim(c):
    if not c: return "?"
    m = re.search(r"(collide=.*?skew-diag=\d+).*?(len=\d+ hole=\d+ box=\S+)", c)
    return (m.group(1) + "  " + m.group(2)) if m else c.split("  |")[0].strip()
for ln in sys.stdin:
    ln = ln.rstrip("\n")
    m = re.match(r"^(\S+)\s+[\d.]+s\s+(collide=.*)$", ln)
    if m:
        spec, c = m.group(1), m.group(2)
        if base is None: base = c
        cens[spec] = c
        continue
    m = re.match(r"^\[(.*)\] vs \[(.*)\]: (\d+) room\(s\) differ$", ln)
    if m:
        rooms[m.group(1)] = int(m.group(3)); continue
    if re.search(r"(luajit(\.exe)?:|attempt to|stack traceback)", ln): err.append(ln.strip())
print("== %s   base: %s" % (area, trim(base)))
# ⛔ COUNT THE ANSWERS, DO NOT ASSUME THEM. Every spec shares ONE luajit process (it has to -- see the
# hash-seed note above), so ONE bad spec aborts the run and takes the other 86 answers with it. The
# first version just printed the diffs it had, and an aborted area came out as "every flip: 0 rooms
# differ" -- MISSING DATA WEARING THE COSTUME OF A CLEAN RESULT, on rand, where two of those flips
# move 78 and 65 rooms. A harness that cannot tell "measured, no effect" from "never measured" is
# worse than none: it is evidence for retiring a flag that was never tested.
if len(rooms) != want:
    print("   ⛔ ABORTED after %d of %d spec(s) -- THIS AREA IS NOT MEASURED, do not read it as 0"
          % (len(rooms), want))
    for e in err[:3]: print("      " + e)
    if not err: print("      (no error line captured; re-run this area alone)")
elif not any(rooms.values()):
    print("   all %d flips measured: 0 rooms differ on every one" % want)
if rooms:
    for s, n in sorted([t for t in rooms.items() if t[1]], key=lambda t: -t[1]):
        d = "SAME census" if cens.get(s) == base else trim(cens[s])
        print("   %-26s %5d rooms   %s" % (s, n, d))
' "$a" "$NSPEC"
done
