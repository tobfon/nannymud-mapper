#!/usr/bin/env bash
# THE KNOB SWEEP: line coverage of the whole corpus under every knob's flipped value, so that
# "this line never runs" can be sharpened into "this line never runs, under ANY knob setting we
# ship".  Run from area/map_helper/client.
#
#   analysis/cover_knobs.sh              # base + probes + one tag per knob flip
#   JOBS=4 analysis/cover_knobs.sh       # fewer parallel luajits
#   TAGS="base faceFit_on" analysis/cover_knobs.sh
#
# Output: analysis/cov/<tag>.cov (union over the corpus) + analysis/cov/<tag>/<area>.cov.
# Read it with analysis/cover_report.lua (dead lines) and analysis/cover_delta.lua (per knob).
#
# ⚠ THE SPEC LIST IS GENERATED, NOT WRITTEN DOWN (analysis/cover_specs.lua): the flip of a knob is
# the OPPOSITE OF ITS DEFAULT, the default lives in the read site, and a hand-maintained list of 65
# of those goes stale the first time someone changes `~= false` to a bare truthy test.
#
# ⚠ `probes` MATTERS AS MUCH AS ANY KNOB. Diagnostics are ~850 lines of layout.lua on lyr alone, and
# with them off the "uncovered" list is topped by `tg_report`, `dump_caps`, `render_step` and
# friends -- live code that is simply not on the offline path. Covering them is what makes the rest
# of the list readable. (`stepRanked` and `walkWatchdog` are NUMBERS, not flags: `stepRanked=true`
# reaches `#ranked < (elro.stepRanked or 40)` and compares a number with a boolean.)
#
# ⛔⛔ DO NOT EDIT lua/layout.lua, lua/core.lua OR THIS SCRIPT WHILE A SWEEP IS RUNNING. Twenty-five
# minutes of runs are silently voided two different ways, and neither one errors:
#   1. A `.cov` file is a set of LINE NUMBERS. Inserting eight comment lines into layout.lua halfway
#      through shifts every later tag's numbers relative to the earlier ones, so `cover_delta.lua`
#      subtracts two different coordinate systems and reports EXCL counts that mean nothing.
#   2. `sh` re-reads its script by BYTE OFFSET as it executes. Rewriting this file mid-run moved the
#      rest of it under the running shell and it died on `syntax error near unexpected token )` --
#      inside the union loop, i.e. after all 1365 runs had finished and before a single `.cov` was
#      assembled. (2026-08-21, the knob review; the whole sweep was thrown away.)
# ⇒ start the sweep, then keep your hands off the tree until it prints its table.
set -u
cd "$(dirname "$0")/.."
AREAS=${AREAS:-"lyr titleist rand dannoc_on gore_bug world_block soulfly kadagar mael_live nib_live leowon dunstan world_live"}
JOBS=${JOBS:-10}

PROBES="detWho=true,timeGuillo=true,stepTime=true,probeDiag=true,probeDiagStart=true"
PROBES="$PROBES,probeFaceFit=true,probeMove=true,probeChunkFace=true,repelDump=true"
PROBES="$PROBES,plateCompare=true,drawSprings=true,probeOrder=true,mrSeedCensus=true"
PROBES="$PROBES,probeClose=true,probeSeam=true,stepDebug=true"
# ⚠ crossCost / probePend arrived here 2026-08-21 when they moved out of elro.KNOBS. This string is
# HAND-WRITTEN while the knob tags are generated, so anything leaving KNOBS silently loses its flip
# and its branch reads as uncovered in all 105 configurations -- PRUNE.md rule 2 by the front door.
PROBES="$PROBES,crossCost=true,probePend=true"

luajit analysis/cover_specs.lua > analysis/cov_specs.txt || exit 1
{ grep -v '^#' analysis/cov_specs.txt
  printf 'probes\t%s\n' "$PROBES"
  printf 'detIdx_off\tdetIdx=false\n'
} > analysis/cov_specs.all

# one job per (tag, area); the tags are what we parallelise over, not the areas, so a tag's union is
# never assembled from a half-finished directory
rm -rf analysis/cov ; mkdir -p analysis/cov
while IFS=$'\t' read -r tag spec; do
  [ -n "${TAGS:-}" ] && ! printf '%s\n' ${TAGS} | grep -qx "$tag" && continue
  printf '%s\t%s\n' "$tag" "$spec"
done < analysis/cov_specs.all | tee analysis/cov/_tags.txt | \
while IFS=$'\t' read -r tag spec; do
  for a in $AREAS; do
    [ -f "analysis/$a.txt" ] && printf '%s\t%s\t%s\n' "$tag" "$a" "$spec"
  done
done > analysis/cov/_jobs.txt

echo "$(wc -l < analysis/cov/_tags.txt) tag(s) x $(echo $AREAS | wc -w) area(s) = $(wc -l < analysis/cov/_jobs.txt) run(s), $JOBS at a time"
xargs -P "$JOBS" -I{} -d'\n' sh -c '
  IFS="	" read -r tag a spec <<EOF
{}
EOF
  mkdir -p "analysis/cov/$tag"
  luajit analysis/cover.lua "analysis/cov/$tag/$a.cov" "analysis/$a.txt" "$spec" >/dev/null 2>&1 \
    || echo "  !! $tag / $a FAILED" >&2
' < analysis/cov/_jobs.txt

while IFS=$'\t' read -r tag spec; do
  cat "analysis/cov/$tag"/*.cov 2>/dev/null | grep -E '^[a-z]+ [0-9]+$' | sort -u -k1,1 -k2,2n \
    > "analysis/cov/$tag.cov"
  printf '%-24s %-28s layout %5s  core %4s\n' "$tag" "$spec" \
    "$(grep -c '^layout' "analysis/cov/$tag.cov")" "$(grep -c '^core' "analysis/cov/$tag.cov")"
done < analysis/cov/_tags.txt
