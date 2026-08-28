-- Tuning constants (TUNE) shared by the layout modules.
-- Split out of layout.lua; see lua/modules.lua for the load order.

elro = elro or {}

-- Tuning constants, deliberately one table rather than file-scope locals: Lua 5.1
-- caps a chunk at 200 locals. Runtime knobs live in elro.KNOBS (core.lua).
local TUNE = {
  classShearWalk    = 16,      -- max rooms a class-shift may walk when checking shear-freedom
  eqwShiftCap       = 5000,     -- biggest equality class a forced shift may translate
  eqwPass1Slots     = 12,      -- pass-1 base-partition cache entries per (cls, _bfGen, placed)
                               -- generation. On overflow the generation is dropped whole: an LRU
                               -- would rank slots in pairs() order (per-process hash seed), and a
                               -- cache that follows the seed makes the layout follow it too.
  sqBendCap         = 1,       -- most cells a diagonal wall may be off 45 before a re-solve
                               -- declines it (see `squarify_sets`)
  sqRingCap         = 8,       -- most rooms in a ring a re-solve will take on
  sqHoldCap         = 6,       -- most normalisations (holds) tried per re-solved cut set
  sqPlateCap        = 48,      -- biggest plate a re-solve may build; a face re-solve that
                               -- moves half the canvas is not what the closure asked for
  sqCloseCap        = 64,      -- most closure squarify GENERATOR calls per relayout: a runaway
                               -- guard, not a budget
  sqWallCap         = 5,       -- most WALLS a `closeSquarify` re-solve will take on
  sqGrow            = 3,       -- how far above its minimum any one wall may be searched
  sqCap             = 6,       -- most re-solved candidates emitted per ring
  sqSplitCap        = 6,       -- most intra-wall splits per wall of one solution
  ringSplitMin      = 2,       -- least growth a WALL must have been given before its split is
                               -- enumerated (see `ringSplitCap`)
  ringSplitCap      = 8,       -- most cut sets one `addset` may emit once a WALL's growth is
                               -- split across its own edges (`elro.ringWallSplit`). A budget,
                               -- not a quality gate -- the all-ones member goes out first.
  ringSizeCap       = 24,      -- biggest RING (rooms on the cycle) the dilation generator will
                               -- look at; 0 = no bound
  eqGuilloCap       = 3,       -- magnitude cap for ordinary eq-plate generation (`eqGuilloDeep` is
                               -- the escalated one; they are not the same number)
  eqLazyCap         = 1,       -- magnitude cap for the LAZY eq generation in the pull2 tiers
  chordMaxPlans     = 8,       -- most plans one chord gap loop may emit
  classTightHops    = 8,       -- cap on the `:t` seam-walk reseed. Bounds work, not correctness;
                               -- do not tune it down as a perf measure (see `seamAccum`).
  closePinEscalate  = 4,       -- how far past the owed shift the closure will walk BOTH its
                               -- endpoints while the rooms it would otherwise drag into a conflict
                               -- are pinned (`pin_escalate`). Each step is one field solve;
                               -- 0 disables the pass.
  closeTightCap     = 64,      -- safety bound on passes, not a budget: a unit pass reclaims one cell
  tightenLenOk      = 0,       -- cells of TOTAL MAP LENGTH a tighten push may add. A rigid unit
                               -- translation's whole length cost is carried by the edges with
                               -- exactly one end in the plate, which is what the read site sums.
                               -- 0 = must not lengthen the map at all. This is the term
                               -- `ring_excess` cannot carry: it counts ring edges only, so slack
                               -- pushed onto an adjacent face is invisible to it.
  tightenSlackOk    = 1,       -- cells of ring slack a tighten push may inject (`tightenSeedScan`).
                               -- 0 = push must remove slack; 1 = slack-neutral is allowed too.
  tightenSeedCap    = 6,       -- most distinct classes `elro.tightenSeedScan` will offer per side.
                               -- A cost bound, not a quality gate: each extra seed is a field solve.
  springK           = 1,       -- spring constant for the stretch energy
  diagSkewCap       = 100,     -- cells of L1 one off-45 diagonal is worth. `= 0` disables the
                               -- preference entirely, which is why it is still read `~= 0`.
  demotedFork       = 0.9,     -- fork factor for a demoted-edge stub
  trapSpike         = 0.4,     -- spike factor for a trap sink
  crossCostTau      = 100,     -- planarity threshold; `= 0` turns the cost model off
  crossDomShare     = 0.9,     -- RULE 1 relents when ONE attachment carries this share of a
                               -- face's load. A count is not a cost. `= 0` restores the strict rule.
  fsPendCap         = 2000,      -- biggest pendant subtree `elro.fsDragPend` will drag along rather
                               -- than let its one connecting edge stretch; also bounds the walk.
  eq2dProbeCap      = 120,     -- room budget for a 2D completion probe, per build. Not a refusal:
                               -- if the whole seed sweep yields no completion and something was
                               -- aborted on the budget, the sweep re-runs uncapped.
  ringReseedCap     = 16,      -- builds a ring plate may spend on its `:sf` / `:t` / `:sf:t`
                               -- re-seeds, total, per normalisation. Each move tried is a full 2D
                               -- closure; a plate that needs no repair spends none of it. A tipped
                               -- wall offers up to four moves, so 16 fully explores four walls.
  ringDilateCap     = 120,     -- per-build room budget for a ring dilation's arc closures; aborts
                               -- mid-flood rather than finishing a map-scale plate nothing picks.
  eqwCascadeDepth   = 2,       -- how deep the closure cascade recurses
  chunkFaceMin      = 20,      -- smallest solved face worth placing as one chunk
  diagRoundCap      = 1000,    -- runaway guard on diagonal rounding
  eqGuilloDeep      = 8,       -- deep-magnitude cap for the escalated eq-plate generation
  chordMaxSteps     = 8,       -- max steps a chord plan may walk
  chordPlateCap     = 128,     -- plate budget for a cut build; no accepted cut plate across the corpus
                               -- exceeds 128 rooms, and the >128 builds were 40% of the generator's time
  repelRadius       = 2,       -- one-sided radius of the junction repel field
  repelMult         = 2,       -- weight of repel against stretch in the spring energy
  repelEdgeW        = 1,       -- weight of an EDGE in the repel field vs a room
  junctionWin       = 4,       -- window (cells) around a collision for the junction field
  leverRoomsRadius  = 4,       -- radius of the windowed `rooms` disturbance count
  diagSkew          = 5,       -- shear weight in the 45-degree preference
  diagStretchMult   = 2,       -- extra cost charged to stretching a diagonal
  nsEdgeRatio       = 2.0,     -- edges-per-room above which a mesh counts as dense
  topoRings         = 4,       -- rings the topo crossing prover examines
  topoFaceCap       = 40,      -- biggest face the topo prover will test
  topoBudget        = 200000,  -- work budget for the topo prover
  demotedBow        = 1.0,     -- bow depth when drawing a demoted edge
  eq2dCap           = 2,       -- magnitude cap for 2D equation shifts
  eq2dSeedCap       = 3,       -- seeds tried per 2D shift
  -- How far out along the vertical ray the dock search will step before declining.
  -- The angle is the invariant and the magnitude is free, so this is "how long a
  -- connector is still readable as one link".
  vertScaleCap      = 1,
  -- Length of the rung-2 stub, in cells. Longer than draw_demoted's: this one starts at
  -- the room centre and IS the whole statement of the exit's direction; under 0.5 the
  -- angle stops being readable at map zoom.
  vertStub          = 0.7,
  -- Free cells the enclosure flood may visit before giving up (see vert_enclosed). It
  -- FAILS OPEN, so this bounds the cost without being able to change a verdict from
  -- "outside" to "inside" -- only the other way, back to the pre-rule behaviour.
  vertFloodCap      = 3000,
  -- Biggest correction the bridge piston may chase, in L1 cells: the line between
  -- "minor layout adjustment" and the parked inset tier, not a search budget.
  vertPistonL1      = 2,
  -- Trial cap per group; bounds the pass.
  vertPistonTries   = 400,
  -- Much smaller cap for the make-room trigger: its trial must rebuild the group's
  -- occupancy raster and re-run the ray search, and is spent per decline.
  vertRoomTries     = 40,
  -- Cost cap for a make-room piston, as rooms-moved x cells-moved -- the only term that
  -- tells a minor adjustment from shoving half the area, because the defect gate cannot:
  -- stretching a bridge adds no defect by construction.
  vertRoomWork      = 40,
}
elro.TUNE = TUNE   -- measurement handle only: exposed so a harness can A/B in-process.
