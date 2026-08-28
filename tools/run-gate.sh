#!/bin/sh
# Mapper client regression gate. Runs the assertion tests that are self-contained
# (no dump argument, meaningful exit code) plus the deterministic layout canary,
# and fails if any of them regress. Shared by tools/pre-commit and tools/pre-push.
#
#   usage: run-gate.sh [fast|full]
#
# fast (~4s) : the sub-second tests + canary.sh. This is what pre-commit runs.
# full (~27s): adds test_cd_layout and test_count_defects (~10s and ~13s). There is
#              no remote and so no pre-push hook; run this BY HAND before a risky
#              structural change, or flip the `sh "$gate" fast` line in tools/pre-commit
#              to `full` to pay it on every commit.
#
# WHAT IS NOT GATED, and why:
#   test_areamin / test_audit / test_bgcs / test_noyield exit non-zero on this tree
#   TODAY, before any of this. Gating on a red test blocks every commit, so they are
#   listed here rather than run. Fix one, move it into FAST/FULL below.
#   test_curl, test_currency, test_cycles, test_diageq, test_face_cost, test_facefit,
#   test_facefit_report, test_families, test_place take a <dump> argument and are
#   investigative tools, not pass/fail tests.
#   test_outer, test_topo, test_wire, test_shear need *_extract.lua cuts of the
#   deleted layout.lua and no longer run at all.
#
# Skips silently if luajit is not on PATH, so the repo still works elsewhere.

MODE="${1:-fast}"
cd "$(dirname "$0")/.." || exit 1

command -v luajit >/dev/null 2>&1 || exit 0

FAST="cross_rank relayout terrain near mazefit mazevertex stubs vert vertpack mapwipe onroom guesscheck shearall"
SLOW="cd_layout count_defects"

TESTS="$FAST"
[ "$MODE" = "full" ] && TESTS="$FAST $SLOW"

# The corpus dumps are real area topology and are not published, so a public clone
# has none. Everything that builds its own fixtures still runs; what needs a dump
# is skipped and said out loud, rather than failing and looking like a broken tree.
HAVE_DUMPS=0
for d in analysis/*.txt; do
  [ -f "$d" ] && { HAVE_DUMPS=1 ; break ; }
done
if [ "$HAVE_DUMPS" = "0" ]; then
  TESTS=$(echo "$TESTS" | sed 's/cd_layout//')
  echo "gate: no corpus dumps present -- skipping the layout canary and cd_layout."
fi

gfail=0

# Static checks: cheap, and catch a class of bug no test can see until it bites.
# check_collisions is the one that matters most -- two modules defining the same
# elro.* name is silent at load and only shows up as a wrong-arity call at runtime.
if command -v python >/dev/null 2>&1; then
  for chk in check_collisions check_help; do
    if ! python "analysis/$chk.py" >/tmp/gate_$chk.out 2>&1; then
      echo "gate: analysis/$chk.py FAILED" >&2
      sed 's/^/    /' "/tmp/gate_$chk.out" >&2
      gfail=1
    fi
  done
fi

for t in $TESTS; do
  if ! luajit "analysis/test_$t.lua" >/tmp/gate_$t.out 2>&1; then
    echo "gate: analysis/test_$t.lua FAILED" >&2
    tail -5 "/tmp/gate_$t.out" | sed 's/^/    /' >&2
    gfail=1
  fi
done

# The layout canary: 8 corpora verified byte-stable across processes. analysis/canary_out.txt
# is the committed baseline -- a diff here means a layout changed, which may be a fix or a
# regression, but must never be silent. Refresh it deliberately, in the commit that moves it.
if [ "$HAVE_DUMPS" = "0" ]; then
  :                              # no corpus to compare against; said above
elif ! sh analysis/canary.sh /tmp/gate_canary.txt >/dev/null 2>&1; then
  echo "gate: canary.sh did not run" >&2
  gfail=1
elif ! diff -u analysis/canary_out.txt /tmp/gate_canary.txt >/tmp/gate_canary.diff 2>&1; then
  echo "gate: layout canary MOVED (committed baseline vs this tree)" >&2
  sed -n '3,40p' /tmp/gate_canary.diff | sed 's/^/    /' >&2
  echo "    If this change is intended, refresh the baseline in this same commit:" >&2
  echo "      sh area/map_helper/client/analysis/canary.sh" >&2
  gfail=1
fi

exit $gfail
