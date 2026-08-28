#!/bin/sh
# Deterministic mapper regression canary.
#
# These five corpora were verified (3 reps each, 2026-08-12) to produce a BYTE-IDENTICAL
# census across separate luajit processes under the user's working knob set. That makes
# them a valid identity check for a pure-deletion refactor -- unlike world_live and
# nib_live, which diverge run to run (LuaJIT per-process string-hash seed) and must be
# A/B'd in-process via knobs only.
#
#   usage: canary.sh <outfile>
OUT=$(cd "$(dirname "$0")" && pwd)
cd "$(dirname "$0")/.." || exit 1
# ⭐⭐⭐⭐ BASELINE RE-CUT 2026-08-14 (4th) -- SIX DEFAULT FLIPS, the user's in-game set:
#   `pistonFirst` OFF, `eqUnvShearFree` OFF, `sgNoGrow` ON, `mrSeeds` ON, `classTight` ON,
#   `seamMagAll` ON, `seamSizeRank` ON.  (`sfAll` was already off and stays off.)
# ⭐ Verified: bare defaults are BYTE-IDENTICAL to that set spelled out explicitly, on all 13
# corpus areas -- which is the only check that says the defaults were wired the way they read.
#   lyr       cross 2   roe 0  skew 0   len 165  hole 27   <- unchanged
#   titleist  cross 2   roe 0  skew 0   len 103  hole 10   <- unchanged
#   rand      cross 6   roe 0  skew 11  len 146  hole 24   <- MOVED: cross 5->6, skew 10->11,
#                                                             len 144->146, hole 14->24, all of
#                                                             it `pistonFirst=false` (measured).
#   dannoc_on cross 104 roe 1  skew 55  len 665  hole 72   <- unchanged
#   gore_bug  cross 0   roe 1  skew 0   len 23   hole 0    <- unchanged
# ⚠ rand's regression is REAL and was accepted deliberately: the user's in-game map is much better
# with pistonFirst off (world 518, the 3x3 box, world 1445's step 316), and the offline world
# trajectory is not theirs.  Do not "fix" rand by putting pistonFirst back.
#
# ⭐⭐ BASELINE RE-CUT 2026-08-13 (2nd), when dragTight / seam2d / seamEq / boxRank became
# defaults ON, dragTightFree OFF, and the class-shift tier was RETIRED (the knob was still
# `classLevers=false` then; the generator itself was DELETED 2026-08-14, canary-identical
# + eqUnverified). Reading a drift against the OLD numbers as a regression is the trap this
# header exists to close -- the census below IS the new baseline:
#   lyr       cross 2  roe 0  skew 0   len 165  hole 27   <- hole 30 -> 27 (dragTight)
#   titleist  cross 2  roe 0  skew 0   len 103  hole 10   <- unchanged
#   rand      cross 5  roe 0  skew 10  len 144  hole 13->14  <- RE-CUT 2026-08-14, diagPiston
#   dannoc_on cross 104 roe 1 skew 55  len 665  hole 72   <- unchanged
#   gore_bug  cross 0  roe 1  skew 0   len 23   hole 0    <- unchanged
# ⭐ RE-CUT 2026-08-14 (3rd): `diagPiston` defaulted ON (the square diagonal extension) and
# `plateTwin` became unconditional. ONLY rand moves: `room-on-edge 1 -> 0` -- a defect class
# above crossings -- bought with len 139 -> 144 and box 22x29 -> 23x30. lyr/titleist/dannoc/gore
# are untouched. Off-canary: leowon len 138 -> 129 (the bug this was built for), mael_live
# len 265 -> 274 / hole 24 -> 32 with no defect change.
# ⭐ THE CLASS TIER'S RETIREMENT IS BYTE-IDENTICAL HERE -- that is what made it shippable.
# ⭐ RUNS AT DEFAULTS -- no pinned knob set. That is the point: a default change is
# ⚠ A DEFAULT CHANGE IS INVISIBLE TO A BASELINE THAT PINS THE KNOB -- that is how the
# faceShared default nearly shipped broken. Running bare is what keeps this honest.
# ⭐⭐⭐⭐ BASELINE RE-CUT 2026-08-15 (5th) -- `eq2dShear` (see core.lua). The 2D generator was
# RIGID-ONLY: `local rg = true` at its head, and its void fallback chain varied enclosed-component
# absorption and never `rigidDiag` -- so a 2D plate that had to shear a settled 45 could not be built
# on ANY path. It now falls back to a shearing build where all three rigid ones void, which is
# strictly additive (it runs only where the generator emitted nothing at all).
# ⚠ ONLY rand MOVES, and it moves the RIGHT WAY -- same defect census, less of everything else:
#   rand      cross 6  roe 0  skew 11 -> 7   len 146 -> 141   hole 24 -> 16   box 22x29 -> 24x28
# The other four areas and the remaining 26 corpus dumps are byte-identical, and rand is the area
# whose two un-squarable walls this file's history is about ([[project_eq_2d_shift]]).
#   lyr       cross 2   roe 0  skew 0   len 165  hole 27   <- unchanged
#   titleist  cross 2   roe 0  skew 0   len 103  hole 10   <- unchanged
#   rand      cross 6   roe 0  skew 7   len 141  hole 16   <- MOVED, improved
#   dannoc_on cross 104 roe 1  skew 55  len 665  hole 72   <- unchanged
#   gore_bug  cross 0   roe 1  skew 0   len 23   hole 0    <- unchanged
# ⭐ 2026-08-16: `eq2dUnionBound` DEFAULTED **OFF** (it had never been read at its use site, so every
# earlier A/B of it was vacuous).  BASELINE UNCHANGED -- all five areas byte-identical; titleist's
# only difference is 2 rooms moving in POSITION, with the census the same.  Off-canary, world_live
# moves 670 rooms (len 951->961, hole 1149->1265) and the other 11 corpus areas are identical.
# ⚠ Recorded here because this file runs BARE: a default flip is exactly what it exists to catch,
# and "no change" is only meaningful if someone wrote down that it was checked.
# ⭐ 2026-08-16: `eq2dProbeCap` DEFAULTED **ON** at 120 rooms -- a per-build room budget for the 2D
# generator's `complete` probes, which abort mid-flood instead of finishing a plate nothing will
# pick.  BASELINE UNCHANGED -- all five areas byte-identical, and off-canary all 13 corpus areas are
# 0 rooms different (at 120 AND at 48).  It is a PERF change and identity is the pass condition: in
# game the two expensive probes on world step 642 went 39ms -> 14ms with the same pick.
# ⭐⭐⭐ 2026-08-16: `enclPlaced` DEFAULTED **ON** -- the enclosed-component sweep's three floods run
# over the PLACED graph only.  They were traversing the unplaced remainder of the walk: 42.9% of the
# anchor flood's 1.23M visits and 51.5% of the comp sweep's 1.14M, in the two phases holding 68% of
# `eqw_forced_shift`.  BASELINE UNCHANGED -- all five areas byte-identical, all 13 corpus areas 0
# rooms different, world_live -11.5% (7.17s -> 6.44s, A/B/A/B in one process).
# ⭐⭐⭐ 2026-08-16: `seamAccum` DEFAULTED **ON** -- the seam walk accumulates its seeds across hops
# instead of rebuilding from `{start} U bind_k` and discarding the previous hop's.  BASELINE
# UNCHANGED -- all five areas byte-identical, and 11 of the other 12 corpus areas too.  world_live
# is the one that moves and it moves the RIGHT WAY: 501 rooms, `len 961->956, hole 1265->1218,
# box 79x94->79x93`, defect census identical.  Cost is a wash.
# ⚠ A QUALITY change on a bare run, which is exactly what this file exists to catch -- recorded
# because "the canary did not move" is only meaningful if someone wrote down that it was checked.
# ⭐⭐⭐⭐ BASELINE RE-CUT 2026-08-16 (6th) -- `closeCarry` (see core.lua). A TIGHTEN reclaims ONE cell
# per pass, so a 12-cell edge ran `eq_phase` twelve times, each re-deriving both sides + their rigid
# variants and carrying EVERY one to completion.  The winning plate is now carried across the unit
# passes and only re-searched when it stops working (97% hit rate: 89 hit / 3 miss on world_live).
# ⛔⛔ THE FIRST RE-CUT WHERE A CANARY AREA MOVES THE **WRONG** WAY, and it is recorded as a debt:
#   rand      cross 6  roe 0  skew 7   len 141 -> 143   hole 16 -> 18    <- WORSE (6 rooms)
#   lyr / titleist / dannoc_on / gore_bug                                <- byte-identical
# Taken because the trade is lopsided and the defect census is unchanged on both sides:
#   world_live  len 956 -> 941, hole 1218 -> 1013 (-17%), 675 rooms, and the walk is 5% faster
# The other 11 corpus areas are byte-identical.
# ⚠ THE OPEN QUESTION, IF rand EVER NEEDS EXPLAINING: per-pass re-ranking let successive cells be
# reclaimed from ALTERNATING sides, which scatters the slack -- that churn is why carrying IMPROVES
# world_live so much.  rand is the 45-degree area, so its 2 cells may be a real interaction with the
# square-wall rules rather than noise.  `elro.closeCarry = false` restores the old behaviour.
# ⭐⭐⭐⭐ BASELINE RE-CUT 2026-08-18 (7th) -- the 08-17 mega-session (two-phase pendant repair, the
# seam-walk family, chord climb, `reClearMirror` DEFAULT ON) moved lyr and rand and nobody re-cut
# this file; the 2026-08-18 perf pass then verified itself as 0 rooms differ x13 at EVERY step
# (poison-loop break, dtProof, reIdxBatch, eqClsMemo, closeRigidSkip, enclVoidProof, the drag-watch
# strip), so what follows is the 08-17 layout, not the perf pass's:
#   lyr       cross 2   roe 0  skew 0   len 164  hole 27   <- len 165 -> 164 (08-17)
#   titleist  cross 2   roe 0  skew 0   len 103  hole 10   <- unchanged
#   rand      cross 7   roe 0  skew 9   len 148  hole 16   <- cross 6->7 skew 7->9 len 143->148
#                                                             (reClearMirror; recorded in core.lua)
#   dannoc_on cross 104 roe 1  skew 40  len 665  hole 72   <- skew 55 -> 40 (08-17)
#   gore_bug  cross 0   roe 1  skew 0   len 23   hole 0    <- unchanged
# ⭐⭐⭐⭐ BASELINE RE-CUT 2026-08-18 (8th) -- `diagLenGuard` + `cascadeNoJunction`, the two
# changes that finally let rand's rhombus DILATE UNIFORMLY around its castle (see
# [[project_eq_2d_shift]]).  ONLY rand moves; the other four here, the remaining 8 corpus dumps and
# world_live are all 0 rooms different, and world_live costs nothing (6.43/6.40s, 6.50/6.59s
# A/B/A/B in one process).
#   lyr       cross 2   roe 0  skew 0   len 164  hole 27   <- unchanged
#   titleist  cross 2   roe 0  skew 0   len 103  hole 10   <- unchanged
#   rand      cross 6   roe 0  skew 3   len 148  hole 24   <- cross 7->6, skew 9->3, hole 16->24
#   dannoc_on cross 104 roe 1  skew 40  len 665  hole 72   <- unchanged
#   gore_bug  cross 0   roe 1  skew 0   len 23   hole 0    <- unchanged
# ⭐⭐⭐ rand's RHOMBUS IS 4/4 WALLS SQUARE AND SO IS ITS CASTLE'S FIT: 5283(12,14) 5276(17,19)
# 5301(7,19) 5307(12,24), a radius-5 diamond holding the 3x3 castle and the 9-room column that runs
# through it.  The 3 remaining skewed walls are `5272:5278` and `5277:5278` -- the two DIAGONALS
# BETWEEN THE TWO COLUMNS, which is exactly the set the user's hand-built target shears too, and
# `hole 24` matches that target's 24 cell-for-cell.  The engine's own count_defects is IDENTICAL to
# the baseline AND to the target: 0 collisions, 2 lies, 0 room-on-edge, 4 crossings (the castle's
# own internal X's).  ⚠ `hole 16 -> 24` is not a regression -- the rhombus is bigger because it now
# has to be to hold the castle squarely, and it is the SAME size as the target's.
# ⭐ `dragLeaf` (same session) then took `len 149 -> 148`: ONE room (rand 5314, a leaf the dilation
# had been leaving behind), and all 12 other corpus areas 0 rooms different.
# BASELINE RE-CUT 2026-08-17 -- the OUTER-FACE CONFLICT session. Four new defaults:
#   `topoPlane`      genus is a SPHERE test; two faces both turning -360 in ONE 2-core component
#                    force a crossing even at genus 0. Fires on gurk and nowhere else in the corpus.
#   `topoOuterSeed`  when that conflict exists, root the walk on core_classify's outer face instead
#                    of on a room of the crossing quartet (the quartet root stays right at genus > 0
#                    -- maelstorm). 0 rooms differ on all 14 corpus areas including world_live.
#   `dragBlockTie` + `dragBlockAxial`  a tightness-drag plateau tie inside ONE all-axial biconnected
#                    block DRAGS: no cut through such a block is better than any other, so the block
#                    moves whole. gurk `eq:7276:w1` 41 rooms / 9 boundary edges -> 79 / 1.
# gurk itself is the witness and is NOT in this list -- it is NOT process-stable, so A/B it in ONE
# process only. It goes `lie 2 cross 0 len 208` -> `lie 0 cross 2 len 214`, matching the census of
# the user's two hand-built solutions exactly.
# ONLY lyr MOVES, and the user accepted it in game ("I'll check lyr.. it looks fine"):
#   lyr       hole 27 -> 29   <- `dragBlockTie`; len 164 and the defect census are UNCHANGED
# titleist / rand / dannoc_on / gore_bug / edoras are byte-identical. Off-canary, world_block moves
# 4 rooms and world_live 3, both with an IDENTICAL census.
#   lyr       cross 2   roe 0  skew 0   len 164  hole 29   <- MOVED, accepted
#   titleist  cross 2   roe 0  skew 0   len 103  hole 10   <- unchanged
#   rand      cross 6   roe 0  skew 3   len 148  hole 24   <- unchanged
#   dannoc_on cross 104 roe 1  skew 40  len 665  hole 72   <- unchanged
#   gore_bug  cross 0   roe 1  skew 0   len 23   hole 0    <- unchanged
#   edoras    cross 0   roe 0  skew 0   len 133  hole 6    <- unchanged
# ⭐⭐⭐⭐ BASELINE RE-CUT 2026-08-19 (9th) -- `vertPack` AND `vertNoCrossInFace` DEFAULT **ON**
# (the user's call in game after a day of live testing: *"honestly this is working out MUCH MUCH
# better than I thought in general"*).  Up/down exits are no longer invisible to the layout: a
# component joined to another by a vertical link is DOCKED onto it at a canonical non-compass offset
# instead of being shelf-packed on its own.  See [[project_vertical_exits]].
# ⚠⚠ THIS FILE RUNS BARE, SO THE CORPUS DUMPS DO CARRY VERTICALS -- and that surprised me once
# already.  `elro.dump_file` writes from getRoomExits, not from `adj`, so world_live has 64 vertical
# darts and rand has 2.  The long-standing note that "no offline corpus can size this" was FALSE.
# ONLY rand MOVES, and it moves the RIGHT way -- same defect census, same len, same hole, a much
# tighter box, because its one forest link now docks instead of opening a second shelf:
#   lyr       cross 2   roe 0  skew 0   len 164  hole 29   <- unchanged
#   titleist  cross 2   roe 0  skew 0   len 103  hole 10   <- unchanged (its dump has NO verticals)
#   rand      cross 6   roe 0  skew 3   len 148  hole 24   <- MOVED: box 26x28 -> 20x28, fill .13->.16
#   dannoc_on cross 104 roe 1  skew 40  len 665  hole 72   <- unchanged (its one link DECLINES)
#   gore_bug  cross 0   roe 1  skew 0   len 23   hole 0    <- unchanged
#   edoras    cross 0   roe 0  skew 0   len 133 hole 6     <- unchanged
#   cathbad   cross 0   roe 0  skew 0   len 76   hole 3    <- unchanged
# Off-canary, and every one of them defect-census-IDENTICAL with the box shrinking:
#   world_live  box 82x89 -> 82x79, hole 1128 -> 1118, 59 components packed as 27 groups
#   soulfly     56x44 -> 57x26      mael_live 45x16 -> 32x16      kadagar 49x66 -> 42x66
#   world_block / nib_live / leowon / dunstan / lyr / titleist / dannoc_on: 0 rooms differ
# ⚠ `vertOverRoom` stays OFF -- the user tried it and it is the lever for one stuck area, not a
# default: *"it gets too cluttered"*.  `TUNE.vertScaleCap` stayed 6 here -- but see 2026-08-28
# below, where the user flipped it to 1.
# ⭐⭐⭐⭐ 2026-08-19: `vertPiston` AND `vertMakeRoom` DEFAULT **ON** -- the user's call after both
# tiers did real work on the live map: *"vertPiston can be on by default and so can vertMakeRoom.
# Both did real work."*  The two bridge-piston triggers: one closes a near-miss vertical AFTER the
# dock, the other frees a cell in the mass BEFORE one.  `TUNE.vertRoomWork` stays 40 (the user:
# *"I don't think you need to change the vertRoomWork default"*), which is what keeps a piston a
# MINOR adjustment -- soulfly's 79-room x 5-cell shove is refused by it.
# ⚠ BASELINE UNCHANGED -- all seven areas here are BYTE-IDENTICAL, and recorded because this file
# runs bare and "the canary did not move" is only meaningful if someone wrote down that it was
# checked.  Off-canary exactly two areas move, both defect-census-IDENTICAL and both a make-room
# rescue of a dock that used to decline:
#   mael_live   box 32x16 -> 28x16, hole 21 unchanged, len 258 -> 259   (bridge 4202-4203 west +1)
#   world_live  69 rooms, hole 1118 -> 1117, box 82x79 -> 84x80         (bridge 5243-5247 north +1)
#   lyr / titleist / rand / dannoc_on / gore_bug / world_block / soulfly / kadagar / nib_live /
#   leowon / dunstan: 0 rooms differ.  Cost ~3% on world_live (A/B/A/B in one process).
# ⛔⛔ AND THE FLIP BROKE ONE FIXTURE, which is the trap this file exists to catch, met from the
# test side: `test_vertpack`'s rung-2 renderer case is a hand-built NEAR MISS, so the piston landed
# it and it drew STRAIGHT instead of bent.  Both legs are now pinned there, and the second leg is
# real coverage -- the same scene at defaults must draw straight.
# BASELINE RE-CUT 2026-08-20 (10th) -- THE RING DILATION SHIPS ON. Five defaults flip together
# (user's call, for live testing): `ringDilate`, `ringUniform` (both folded 2026-08-27), `reClearRide`, `ringDummyArc`,
# `fsDragLeaf`.  `compactNoShear` also became a default this session but is measured INERT here.
# See [[plan_family_shearfree]] for the whole mechanism; the short version is that a bounded face
# with 45-degree walls can now be GROWN without shearing it, which no generator could do before.
# ONLY TWO AREAS MOVE:
#   dagoth    skew-diag 6 -> 2   len 176 -> 178  hole 6 -> 11   <- THE POINT. The lens
#             8769-8766-8791-8788-8785-8782-8781-8778-8775-8772 comes out UNIFORM 2/2/2/2 with all
#             four diagonals square, which is the pre-registered MINLEN target reached with no hand
#             input. The remaining 2 skews and all 4 room-on-edge are the separate 8818-8821 problem.
#   rand      cross 6 -> 7  len 148 -> 146  hole 24 -> 60  box 20x28 -> 20x26
#             cross IS NOT A REGRESSION: 0 REAL crossings before and after -- rand's total is 4
#             quad-X + lie-slants, and the +1 is a third lie-slant. `XDUMP=1` proves it, and see
#             [[reference_crossing_census]] before reading any `cross` delta again.
#             The real cost is `hole`, and it is `fsDragLeaf`'s: it swaps rand's three bad
#             extensions for three OTHER ones (`EXT=1`: `5255:5256` and `5273:5277` out,
#             `5261:5263` and `5327:5335` in, and `5273:5274` goes 5 -> 7).
#             ACCEPTED KNOWINGLY AND TEMPORARILY -- the user is looking at fixing `fsDragLeaf` next.
# lyr / titleist / dannoc_on / gore_bug / edoras / cathbad_lie are BYTE-IDENTICAL.
# Off-canary, only nib_live moves -- `skew-diag 6 -> 4, len 148 -> 151, hole 17 -> 20` (32 rooms),
# which the user accepted in game: *"nib trades a bit of hole and len for a more symmetric layout,
# it's fine"*.  dunstan / leowon / kadagar / soulfly / mael_live / world_block / world_live: 0 rooms
# differ.  world_live costs ~20%.
# WARN TWO NEW DIAGNOSTICS, both env-gated and both deliberately OUTSIDE the census string so this
# file stays a stable text diff: `XDUMP=1` (crossings split REAL / quad-X / demoted / lie-slant) and
# `EXT=1` (every stretched edge, listed -- `len` is a total and hides WHICH edges grew).
# BASELINE RE-CUT 2026-08-21 (11th) -- THE RING RE-SOLVE (`closeSquarify` / `closeSqAtClose` /
# `closeSqRider`) AND THE WALL SPLIT (`ringWallSplit`), all DEFAULT ON.
#   dagoth    skew-diag 2 -> 0   len 178 -> 181   hole 11 -> 12   (115 rooms)
#   lyr / titleist / rand / dannoc_on / gore_bug / edoras / cathbad_lie: BYTE-IDENTICAL
# Off-canary only nib_live moves: `skew-diag 4 -> 2`, `len 154 -> 152` (the wall split squared
# `1881:1889`, the wall this file's siblings list as out of reach). world_live 0 rooms differ.
# THE MOVE: a dilation's increment is `+1 on every cut edge`, and sum-zero then forces an axial wall
# to grow by TWICE the diagonal growth -- so a dilation CANNOT CHANGE A WALL'S PARITY. dagoth's
# triangle closes with an odd base (the piston pushes 8809 off the cell the crossing needs, which is
# right) and its square solutions are at base 2 and 4, so no increment and no TIGHTEN can reach one.
# `squarify_sets` RE-SOLVES the ring instead: walls as unknowns, `sum L_w * D_w = 0`, enumerated by
# increasing total, and the ordinary guard refuses the ones that park a room on the crossing.
# ⚠ `fsDragPend` STAYS OFF. It drags rand's two remaining stubs tight (5 pendant stretches -> 3, 1
# excess cell) and pays `room-on-edge 0 -> 1`, `skew 3 -> 4`, `hole 60 -> 64` -- and it makes dagoth's
# skew-0 HASH-SEED DEPENDENT (0/0/2/0/2 over five runs, against 0/0/0/0/0 with it off).
# ⚠ `garric.txt` joined the dumps 2026-08-21 as a PERF PROBE ONLY -- it is process-unstable by a
# wide margin (skew 92/71/81 over three runs of ONE spec) and must NOT be added here.
# BASELINE RE-CUT 2026-08-24 (12th) -- THE CLOSURE SET SHIPS. Thirteen knobs became defaults on the
# user's call after a live regression run (*"works on maelstorm, lever is gone... can't see any
# regression anywhere"*), and TWELVE of them were FOLDED with the flip -- knob and off-branch both
# gone, the behaviour unconditional. `fieldClosure` is the only survivor and is now DEFAULT **ON**,
# kept deliberately and temporarily as the way back to the old builder.
#   ringTightenExtreme  fieldRoomEdgeMirror  tightenExtremeSeeds  fieldRoomEdge  eqRigidGate
#   eqRigid  seamSubsetSep  eqRigidWalk  closeAssertEq  deferPendingClose  xboundTruthOnly   FOLDED
#   fieldClosure  KEPT, default ON      eqSf  KEPT, default now FOLLOWS THE PATH (elro.sf_enabled)
# ⭐⭐⭐ THE PASS CONDITION WAS THE ONE THIS FILE'S HEADER HAS ALWAYS NAMED: bare defaults must be
# BYTE-IDENTICAL to that thirteen-knob set spelled out explicitly. Verified on EIGHTEEN corpus areas
# (the eight here plus soulfly, nib_live, world_block, mael_live, kadagar, leowon, dunstan, gurk,
# mael, world_live), each first checked to be process-stable under that set by running it twice in
# separate processes. Checked TWICE -- after the default flip, and again after the fold -- so a
# break would have been attributable to one or the other.
# ⚠ THE CENSUS BELOW THEREFORE MOVES, and it is the new baseline, not a regression:
#   lyr       cross 2   roe 0  skew 0   len 164  hole 30   <- hole 29 -> 30
#   titleist  cross 2   roe 0  skew 0   len 103  hole 10   <- unchanged
#   rand      cross 7   roe 0  skew 3   len 142  hole 27   <- cross 6->7, len 148->142, hole 58->27
#   dannoc_on cross 104 roe 1  skew 40  len 665  hole 72   <- unchanged
#   gore_bug  cross 0   roe 1  skew 0   len 23   hole 0    <- unchanged
#   edoras / cathbad_lie / dagoth                          <- unchanged
# ⚠ `fieldClosure = false` IS NOT A TIME MACHINE. The folded work included general bug fixes that
# correctly apply to BOTH paths (user: *"some of them are probably correctly also affecting the old
# path -- we did some general bug fixes"*), so the old path is the old BUILDER with today's rules.
# Against the pre-flip old path: rand `cross 7->6 len 146->142 hole 58->28` (better), world_block
# `hole 632->698`, world_live `len 946->958 hole 1121->1198`, the other 15 identical.
# BASELINE RE-CUT 2026-08-25 (13th) -- `eqWalkLazy` DEFAULT **ON** (the user's call: *"let's flip
# eqWalkLazy then"*), after the 2026-08-25 perf pass shipped four identity-clean commits ahead of it.
# THE MOVE: defer every `:t`/`:sf` seam walk until the probe loops are done, then walk only the bases
# TIED at the best score -- scored SHEAR-BLIND, because under the live shear-first ranking a base
# ranks badly for exactly the shear its own `:t` removes (rank 1 in 3 of 35 picks; shear-blind, 35 of
# 35). See the knob in core.lua for the whole verdict.
# ⭐⭐⭐ THE PASS CONDITION THIS FILE'S HEADER HAS ALWAYS NAMED WAS CHECKED FIRST: bare defaults are
# 0 ROOMS DIFFERENT from `eqWalkLazy=true` spelled out explicitly, on all 16 corpus areas, in ONE
# process. That is the only check that says the default was wired the way it reads.
# ⚠ EXACTLY ONE LINE HERE MOVES, and it moves the WRONG way -- recorded as the price, not hidden:
#   dannoc_on  len 665 -> 667  hole 72 -> 76   <- WORSE (9 rooms); the DEFECT CENSUS IS UNCHANGED
#   lyr        2 rooms move and its census line does NOT -- user: *"on lyr it is just irrelevant
#              slack moving"*
#   titleist / rand / gore_bug / edoras / cathbad_lie / dagoth: BYTE-IDENTICAL
# ⭐ THE REASON IT SHIPS ANYWAY: the DEFECT CENSUS -- collide / lie / cross / room-on-edge / skew --
# is IDENTICAL on ALL SIXTEEN corpus areas, and that is the ranked quality measure. 13 of the 16 are
# 0 rooms different outright. Off-canary, world_live moves 200 rooms and moves the RIGHT way on two
# of three: `len 948 -> 951` but `hole 1027 -> 1022` and `box 78x83 -> 78x82`. User, in game: *"on
# world it is a bit more unclear, mostly also chords/slack moving around"*.
#   world_block / soulfly / kadagar / mael_live / nib_live / leowon / dunstan: 0 rooms differ.
# ⭐⭐⭐ AND `world_new` -- THE USER'S ACTUAL LIVE WORLD -- COMES OUT BETTER ON EVERY NUMBER, which is
# the strongest single reading available offline: same defect census (lie 7, cross 6, roe 0, skew 0),
# `len 1312 -> 1311`, `hole 1087 -> 1063`, `box 90x106 -> 86x106` (NARROWER), 190 rooms, 8.18 -> 6.79s.
# Only FOUR of the nineteen corpus dumps move at all: dannoc_on (9), lyr (2), world_live (227),
# world_new (206). The other fifteen are 0 rooms different.
# ⭐⭐ AND THE COST IT BUYS: `t:WALK 1127 -> 333ms` (98 bases walked, 167 HELD), `place_room TOTAL
# 4281 -> 3229ms`, corpus sum 11.57 -> 10.04s (-13%). The escalation re-ask (`_eqWalkAll`) fires 14
# times on world_live and `LEGAL`/`PICKED` are 85 both ways -- the safety net is exercised, not
# theoretical, and no conflict went unresolved.
# ⛔ IT IS A HEURISTIC, NOT A BOUND. A variant does not inherit its base's score in general (17 of
# 329 pairs differ, 9 score BETTER), so a worse-scoring base CAN hide a better variant. The corpus
# says only that one has never been the PICK -- and now also that the defect census never moves.
#   lyr       cross 2   roe 0  skew 0   len 164  hole 30   <- unchanged
#   titleist  cross 2   roe 0  skew 0   len 103  hole 10   <- unchanged
#   rand      cross 7   roe 0  skew 3   len 142  hole 27   <- unchanged
#   dannoc_on cross 104 roe 1  skew 40  len 667  hole 76   <- MOVED, and it is the price above
#   gore_bug  cross 0   roe 1  skew 0   len 23   hole 0    <- unchanged
#   edoras / cathbad_lie / dagoth                          <- unchanged
# ⭐ The four perf commits that precede it (`e1c4ab2` `5eb71af` `a24796e` `d18921b`) and the
# `ringLeaveBehind` knob (`f65a50c`) are ALL byte-identical here and 0 rooms different on 19 dumps --
# they are pure duplicate-work removal, so this file did not move for any of them.
# ⭐ 2026-08-28: TUNE.vertScaleCap 6 -> 1, the user's call -- a dock now takes the canonical
# 1:2/2:1 offset or DECLINES, instead of stepping out along the ray for a longer connector.
# BASELINE UNCHANGED: all eight canary areas byte-identical. Off-canary nine areas move and
# every one keeps its EXACT defect census (collide/lie/cross/roe/skew and len all unchanged);
# what changes is the box, because a declined dock is shelf-packed instead:
#   brom 58x50 -> 58x49 hole 93 -> 87 (tighter)   titleist_now 33x23 -> 42x18   sel: box same
#   mael_live 28x16 -> 33x16   maelstorm_new 28x25 -> 33x25   nib 40x22 -> 46x22
#   titleist_full 33x18 -> 42x18   world_live 79x82 -> 79x86   world_new 90x105 -> 90x126
# It is a READABILITY call, not a census one -- the census cannot see connector length.
# ⛔ Six test_vertpack fixtures asserted the step-out and so encoded the OLD default; they now
# pin `TUNE.vertScaleCap = 6` themselves. A fixture that needs a non-default knob must SAY so.

K='-'
out="${1:-$OUT/canary_out.txt}"
: > "$out"
# ⭐ `edoras` JOINED 2026-08-17 and it earned its place the hard way: 85 rooms, and the ONLY
# corpus area that reaches the part-lock site in eqw_forced_shift_1's separation pass. The
# 19bb431 session shipped `dragPartial` measured as "byte-identical on all 8 A/B corpora" --
# true, and it meant only that no corpus area exercised it. edoras did, and it cost lie 2 -> 4
# (a diagonal boundary edge flattened) for len -1 / hole -3. An area that is identical under
# every knob teaches nothing; keep this one because it is the one that disagrees.
# ⭐ `cathbad` JOINED 2026-08-18, same reason as edoras and the same recipe. It is the only
# corpus area whose CASCADE PAIR flips a diagonal's sign: 1796 hangs SE off 1771 and 1800 hangs NE
# off 1772, 1771/1772 sit 2 apart in one column, so both leaves want ONE cell -- and only at gap
# exactly 2. The pair moved a leaf across its parent's row instead of stretching the free column
# edge, and `1771 -southeast-> 1796` drew NORTHEAST. Every other corpus area is 0-rooms-different
# under `cascLie`, i.e. none of them reaches the site -- which is precisely why this one is here.
# ⭐ `dagoth` JOINED 2026-08-19 with the `growMult` / `crossDomShare` / `crossNoFarSide` flip, and
# for the third time for the same reason: all three are 0-rooms-different on 19 corpus dumps, i.e.
# NOTHING ELSE REACHES THE SITE. It is the only area whose one bounded face is a TRIANGLE with two
# DIAGONAL walls -- dirs E/NW/SW, which admits no opposite pair and no zero-sum triple, so the ring
# growth had no move at all and the face priced NOT MEASURABLE. 203 rooms, `lie 5 -> 1` for one
# extra crossing, verified process-stable over 3 separate luajit runs before being added here.
for f in lyr titleist rand dannoc_on gore_bug edoras cathbad_lie dagoth; do
  printf '%-12s %s\n' "$f" \
    "$(luajit analysis/test_dump_layout.lua "analysis/$f.txt" "$K" 2>&1 | tail -1 | sed 's/^[^ ]*  *[0-9.]*s  *//')" \
    >> "$out"
done
cat "$out"
