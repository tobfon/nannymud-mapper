#!/bin/sh
# ⛔⛔⛔ THE CHECK THAT WOULD HAVE CAUGHT IT.
#
# The canary and the 31-dump census both run at DEFAULTS, where `stepDebug` is off -- and the whole
# mapstep/plate-gen trace is BUILT ONLY UNDER stepDebug. So a broken `string.format` in a trace line
# is invisible to every check we had: 31 dumps clean, canary identical, test_noyield passing, and
# the user's background relayout dies with `bad argument #6 to 'format' (number expected, got
# string)`. Measured after the fact -- a plain run of rand prints its census happily, the same run
# with `stepDebug=true` aborts.
#
# ⇒ A DIAGNOSTIC PATH THAT ONLY THE USER CAN EXECUTE IS ONE THAT ONLY THE USER CAN BREAK.
# Run this after touching ANY trace/diagnostic string, alongside canary.sh.
#
#   usage: sh analysis/trace_smoke.sh
#
# Two layers, because the trace has two failure surfaces:
#   1. BUILD side -- the format runs during the walk, under stepDebug. A bad arg list aborts the run.
#   2. RENDER side -- TRACECHECK=1 then re-renders every captured frame through the real
#      `elro.dump_step`, which is otherwise reachable only from the in-game alias.
# `timeGuillo` is on as well: several trace lines only exist when it is.
cd "$(dirname "$0")/.." || exit 1
FAIL=0
for f in rand lyr kadagar soulfly titleist mael_live world_block; do
  out=$(TRACECHECK=1 luajit analysis/test_dump_layout.lua "analysis/$f.txt" \
        "stepDebug=true,timeGuillo=true" 2>&1)
  if echo "$out" | grep -q "TRACE ERROR"; then
    printf '  FAIL   %-12s render-side\n' "$f" ; echo "$out" | grep "TRACE ERROR" | head -3
    FAIL=$((FAIL + 1))
  elif ! echo "$out" | grep -q "^TRACECHECK: rendered"; then
    printf '  FAIL   %-12s the walk itself aborted (build-side format error?)\n' "$f"
    echo "$out" | grep -E "layout\.lua:[0-9]+:" | head -2
    FAIL=$((FAIL + 1))
  else
    printf '  ok     %-12s %s\n' "$f" "$(echo "$out" | grep '^TRACECHECK: rendered')"
  fi
done
if [ "$FAIL" -eq 0 ]; then echo "" ; echo "trace smoke: all clean."
else echo "" ; echo "$FAIL AREA(S) FAILED -- do not ship; the in-game trace is broken." ; exit 1 ; fi
