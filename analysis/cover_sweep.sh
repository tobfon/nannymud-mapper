#!/usr/bin/env bash
# CORPUS LINE COVERAGE, one union per knob spec.  Run from area/map_helper/client.
#
#   analysis/cover_sweep.sh base "-"                  # the default-configuration union
#   analysis/cover_sweep.sh faceFit_on "faceFit=true" # what that knob's branch adds
#
# Writes analysis/cov/<tag>.cov (the union over the corpus) and analysis/cov/<tag>/<area>.cov (the
# per-area sets, kept because "which area is the only one that reaches this line" is the question
# right after "is this line dead").
#
# ⚠ NOT AN A/B HARNESS. `census.sh` runs every spec in ONE process because the LuaJIT hash seed
# would otherwise dominate a layout comparison; this runs one process per (area, spec) on purpose.
# See the header of analysis/cover_impl.lua.
#
# AREAS=...  overrides the corpus (default: the census corpus, world_live last -- it is the slow one)
set -u
cd "$(dirname "$0")/.."
AREAS=${AREAS:-"lyr titleist rand dannoc_on gore_bug world_block soulfly kadagar mael_live nib_live leowon dunstan world_live"}

tag=${1:?usage: cover_sweep.sh <tag> [knobspec]}
spec=${2:--}

out="analysis/cov/$tag"
mkdir -p "$out"
for a in $AREAS; do
  [ -f "analysis/$a.txt" ] || continue
  luajit analysis/cover.lua "$out/$a.cov" "analysis/$a.txt" "$spec" >/dev/null 2>&1 \
    || echo "  !! $tag/$a FAILED" >&2
done

# union: plain sort -u over the `layout N` / `core N` lines of every area
cat "$out"/*.cov 2>/dev/null | grep -E '^[a-z]+ [0-9]+$' | sort -u -k1,1 -k2,2n > "analysis/cov/$tag.cov"
printf '%-24s %s  (layout %s, core %s)\n' "$tag" "$spec" \
  "$(grep -c '^layout' "analysis/cov/$tag.cov")" "$(grep -c '^core' "analysis/cov/$tag.cov")"
