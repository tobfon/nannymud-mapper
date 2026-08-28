# ElrohirMapper client — design

The Mudlet side of the `!MAP` mapper: it receives room announcements from the server, keeps
Mudlet's room database as the graph store, and computes every area's coordinates itself. The
server side and the wire protocol are described in [../DESIGN.md](../DESIGN.md); this document
covers only what lives under `client/`.

## 1. Files and load order

Everything is plain Lua under `lua/`, loaded by the bootstrap script in `map_helper.xml` (the only
code that lives in the package itself). The bootstrap resolves the source directory and `dofile`s
the modules listed in `lua/modules.lua`, in order; `mapreload` re-reads that list, so adding a
module never needs a package reinstall. Offline harnesses loop over the same list.

| module | role |
|---|---|
| `geom.lua` | pure (x,y) primitives: orientation, edge raster, strict segment crossing |
| `keys.lua` | the string formats naming an edge, a crossing, a room-on-edge incidence |
| `core.lua` | the driver: `!MAP` feed (`onRoom`), the c-space snapshot, regionalisation, the relayout loop and background coroutine, the write gate, aliases, glyphs, terrain, mazes |
| `tune.lua` | `TUNE`, the engine's numeric constants |
| `canvas.lua` | area adjacency, the flood layout (fallback), composition of an area from its components, orphans, the defect scanner, the write path |
| `audit.lua` | exit provenance and the constraint audit: which exits are trustworthy, which get demoted |
| `topo.lua` | topology: biconnected blocks, face tracing, the outer face, face fit, and the two crossing provers |
| `levers.lua` | the lever engine: enumerating and ranking the moves that resolve one conflict |
| `eqw.lua` | closure equations: the field solve, diagonal equations, make-room, loop closure, ring tightening |
| `eqlevers.lua` | lever generators built on the equations: chord, equation plates (1D/2D), ring dilation, the seam walk |
| `place.lua` | `place_room`: put one room down and resolve what it breaks |
| `walk.lua` | `walk_branches`: the room-by-room walk that drives placement; `layout_eqw`, the live entry |
| `render.lua` | overlays (demoted, residual, stubs), the `mapstep` replay, diagnostic commands |
| `vert.lua` | up/down exits: classification, docking floors, bridge pistons, drawing |

Every module binds what it needs from earlier ones into file-scope locals at load
(`elro.g`, `elro.k`, `elro.exits`, `elro.clk`, `elro.TUNE`, `elro.area_adjacency`) and fails
loudly if loaded out of order. All cross-module calls go through the `elro` table at run time.

`eqw`, `eqlevers` and `place` hold functions that were nested closures of `walk_branches`. They
take the walk's context table `W` as their first argument: a shim inside `walk_branches` copies
the captured locals into `W` at every call and the function binds them back to locals at its top.
This is exact because none of those functions writes a captured variable (verified from bytecode
when they were extracted); it costs a few dozen table stores per call.

## 2. The pipeline, end to end

```
server !MAP line
  -> core.onRoom            create/enrich rooms + exits in Mudlet; invalidate the snapshot; markDirty
  -> core.relayout          (idle-debounced, or urgent on an overlap) per dirty area:
       core.recompute_areas   fold small server areas into "world"; honour steals/merges/mazes
       core.layout_one        maze or huge area -> canvas.layout_area (flood)
                              otherwise        -> walk.layout_eqw
            canvas.compose_spqr(_adj)   per connected component:
                 audit.demotion_set / walk.walk_adj    the shadow graph the equations may trust
                 canvas.core_classify                  2-core + inward/outward pendant trees
                 topo.facefit                          face sizes and shared-edge topology
                 topo.blocks_adj                       artery / block classification
                 topo.wire_cross, topo.topo_cross      provably unavoidable crossings -> seed choice
                 walk.walk_branches                    place every room (see 3)
                 canvas.slide_pendants                 anything the walk left over
              vert.vert_assemble                       dock up/down-linked components
              shelf pack + canvas.place_orphans
       canvas.write_compose   write_begin gate, setRoomCoordinates, overlays, terrain repaint
  -> core.relayout_done     re-run if the graph moved meanwhile (level-triggered, spin-guarded)
```

### The c-space snapshot (core)

The solver never reads Mudlet's room database directly. `cs_room` materialises a room's exits,
area and user data once and caches it; `onRoom` invalidates exactly the rooms it writes and bumps
the area's version. This is what makes the background coroutine correct: a solve reads a private,
self-consistent copy while the player keeps walking. `bg_write_ok` decides at the write boundary
whether the input was consistent; a stale-but-consistent layout is committed and the area left
dirty for the queued rebuild.

### Background relayout (core)

The solve runs in a coroutine driven by a `tempTimer`: it computes for `bgSlice` ms, yields at
`bg_tick` sites inside the engine's loops, and Mudlet gets its event loop back. Mudlet is stock
Lua 5.1, which cannot yield across a C boundary: no `pcall`, metamethod or C function may sit
between the resume and a tick. `elro._noYield` marks the windows where a `pcall` is unavoidable
(the provers), turning ticks inside them into no-ops. Diagnostic timers read `elro.clk`, which
subtracts the driver's idle time so a bracket that straddled a yield is not charged the frame gap.

### Regionalisation (core)

A server area keeps its own Mudlet tab only if its largest internally connected cluster has at
least `area_min` rooms; otherwise its rooms fold into "world" (or "world 2", the overflow area).
Manual overrides: `mapsteal` (per-room adopt), `mapmerge` (area redirect), branch folds, and maze
submaps (clusters of untruthful exits detected from mutation counters). All are persisted in map
user data and honoured identically by `recompute_areas` and `onRoom`, so a room never flips tabs.

## 3. The walk (walk.lua, place.lua)

`walk_branches` lays out one component onto a live canvas, one room at a time, in a fixed order:

- PASS 0: inward pendants and nested blocks off the settled core, while the exterior is empty.
- PASS 1: the artery skeleton — the 2-core, block by block. Inside a block, rooms are released
  in face-onion waves (outer ring first) after the crossing wave (rooms of a proven crossing).
- PASS 1.5: artery islands walled off by pendant tails.
- PASS 2: pendant kids, walking back along the placed artery.

Each room goes through `place_room(u, kid, root)`:

1. Seat it one step off its parent along the exit; constrained placement locks its row/column to
   already-placed neighbours; `eqw_make_room` opens an interval if none is feasible; a proven
   forced crossing is realised at its site.
2. If the cell conflicts (overlap, crossing, edge over a room, room on an edge), resolve with the
   cheapest clean lever: re-angles from `levers._lever_core`, chord slides (cuts through the field), equation
   plates (`eqlevers`), ring dilation. Candidates are scored on spring energy with the 45-degree
   preference as a sort key, junction-first when the conflict is two branches diverging.
3. Escalate: deeper equation caps, 2D completion, and finally a deliberate least-severe defect
   (a crossing over a room-on-edge over a collision). A plate refused for the incidence it
   creates derives its own separation — a unit shift on the other axis, built on the post-plate
   geometry — and the two are composed into one graded candidate ranked like any other; a
   composed candidate is never re-derived (seed for the collision, closure, one separation).
4. Close loops: every back-edge to an already-placed room is made truthful by
   `eqw_close_core_1`, then the ring it closed is tightened; a pre-solved face is snapped into
   its container (`try_chunk`).

Placement is deterministic by construction: neighbours are iterated in `dir_order`, every set
that is walked is sorted first, and ties fall to room id. `pairs()` order is never allowed to pick
a winner because LuaJIT seeds string hashing per process.

## 4. The equations (eqw.lua, eqlevers.lua)

The engine's model is a constraint system, not a physics simulation. A compass exit asserts, per
axis, an equality (an east exit says "same row") or an ordering ("strictly further east");
diagonals assert only orderings. Rooms tied by equalities form row/column classes.

- `eqw_field_shift` is the plate builder: given a seed map (room -> displacement) it relaxes the
  whole system once — equalities from the classes, inequalities from minimum lengths and accepted
  crossing bounds, squareness of settled 45s — and returns the set of rooms that must travel and
  by how much. Nothing moves unless a constraint forces it (least solution above the current
  geometry, Bellman-Ford over the ordering graph; running out of rounds means infeasible, never a
  truncated answer).
- `eqw_diag_shift` is the four-family generalisation for diagonal walls.
- `eqw_close_core_1` closes a loop: the closure offset is known exactly and the classes say which
  rooms travel with each end, so the cut is calculated, not searched; the cheaper valid side wins.
  A tighten (edge already truthful but slack) seeds the ring's extremes, and a pin escalation moves
  both ends out when the plate would drag something into a conflict.
- `seam_walk` (eqlevers.lua) is the one `:t` construction: from a built base plate it walks the cut
  family outward while the plate grows, keeping the cut with the fewest sheared walls, then the
  loosest tightest face. The generator, the loop closure and the ring tighten all call it.
- The `query_*_levers` generators turn these into ranked candidates for `place_room`, each carrying
  a label (`eq:638:e1`, `chord:...`) that is both the trace name and the final sort key.

## 5. Trust: provenance and demotion (audit.lua)

Not every exit is equally true. A reciprocal pair walked both ways is corroborated; a one-way
exit is a single assertion (often a builder typo) and an `onRoom`-fabricated reverse never counts
as corroboration. `constraint_audit` admits hard edges first and rejects any soft edge the
accepted set refutes; `demotion_set` is what the walk actually drops from the equations (fan-in
extras, conflict extras, refuted soft edges, and trap sinks — rooms more than eight others claim
to be adjacent to, which are teleports by pigeonhole). Demoted edges still exist in the graph and
are drawn as magenta corridors; a room whose every edge was demoted is an orphan, placed from its
demoted exit as a hint only.

## 6. Topology (topo.lua)

- `blocks_adj`: biconnected components (Tarjan); bridges are single-edge blocks.
- `faces`: traces the rotation system (the compass exits ARE the embedding); `pick_outer_face`
  uses signed turning, with largest area as the fallback.
- `facefit`: how big must each face be before anything is placed — the minimum edge lengths a
  ring needs to hold what it encloses, plus shared-edge topology (`faceUse`) consumed by the
  closure ranking.
- `wire_cross` / `topo_cross`: prove from the exits alone that two wires (row/column classes) must
  meet. What is proved is an unavoidable incidence; a crossing is the least severe reading, so
  proven pairs license a crossing at one site and seed the walk at that structure.

## 7. Vertical exits (vert.lua)

up/down exits never enter the planar graph. Components joined by them are docked at a canonical
non-compass offset (a 1:2 or 2:1 ratio, so the geometry alone marks a vertical), chosen by a
spanning forest over (components, vertical links): the first link joining two components is
honoured, later ones are drawn only. A bridge piston may stretch one Tarjan bridge after docking
so a near-miss link draws straight; it is gated on no defect kind getting worse.

## 8. Drawing (render.lua, canvas.write_compose)

`write_compose` is the only path that writes coordinates. It normalises to the origin, writes
every room, then the overlays in a fixed order: blue cross-area stubs, magenta demoted corridors,
teal honoured verticals, red residual lies (edges the engine kept but drew off-axis), and last the
terrain repaint, which loses the highlight slot to occluded/maze marks. `drawn_direction_ok` is
the one definition of "this drawing tells the truth about this exit", shared by every overlay.

`mapstep` replays a relayout frame by frame from the snapshots `step_snap` records under
`stepDebug`; each frame carries the closure trace and the lever options that were ranked, in the
same colours as the collision dump.

## 9. Contracts that are easy to break

- **Key text is a layout contract.** `keys.lua`'s formats are index keys, trace labels and the
  final tie-break in `_rank_cands`. Changing a key's text changes layouts; A/B it as one.
- **Determinism.** Iterate exits with `elro.exits`, sort every set before walking it, never let
  `pairs()` choose. The corpus check below is only meaningful because of this.
- **Two crossing predicates on purpose.** `geom.seg_cross_strict` rejects a collinear touch; the
  walk's test counts it and handles it via proper/touch. Do not unify them.
- **Edge raster.** A stretched (non-45) diagonal rasters to its two endpoints only; callers depend
  on that for what counts as room-on-edge.
- **No pcall on the background path** (section 2). `analysis/test_bgcs.lua` enforces it.
- **Clocks.** Diagnostics use `elro.clk`; wall-clock budgets that keep the client responsive use
  raw `os.clock()`.
- **Knobs.** `elro.KNOBS` in core.lua is the whole settable surface, and it is deliberately small:
  a knob whose value was never measured is a constant in `TUNE` or nothing. A switch that exists
  only in a comment is deleted, not registered. Env vars (`RDWATCH`, `RDHALF`) are a harness
  channel `knob_audit.lua` cannot see: read them once into a file-scope local at load, never
  per candidate inside a ranking loop.

## 10. Verification (analysis/)

- `test_dump_layout.lua <dump> [knobspec]` lays out a dumped area offline under a fake Mudlet and
  prints a census (`collide lie cross room-on-edge skew-diag len hole`). `COORDS=<file>` writes
  every room's coordinates; `WRITE=<prefix>` writes a re-loadable dump.
- The 47 dumps under `analysis/*.txt` are process-stable in the current build: a refactor is
  verified by dumping coordinates before and after and requiring byte identity on all of them.
  A census comparison is weaker and can hide movement. Knob A/Bs must run inside one process
  (`test_dump_layout <dump> specA specB`) because of the per-process hash seed.
- `engine_load.lua` loads the real modules behind minimal stubs for unit harnesses
  (`test_vertpack`, `test_shear`, `test_audit`, `test_count_defects`, ...).
- `check_forward_refs.lua` catches a nested local called before its declaration — the failure
  mode of a file-scope local that silently becomes a global.
- `cover.lua` / `cover_report.lua` / `cover_show.lua`: line coverage over a corpus sweep, per
  module, for dead-code passes. `knob_audit.lua` / `knob_prose.lua` audit the knob registry.
- Comment-only or move-only edits are proved with a comment-blind token comparison of the source,
  since bytecode embeds line numbers.
- **Commands.** `map_helper.xml`'s aliases are one-liners that call an `elro.*` function; the help
  text lives in `core.lua`'s `HELP_BASIC` / `HELP_ADV` tables, not in the XML, so editing it needs
  no entity escaping. The three groups are by what a command TOUCHES — map data, appearance,
  diagnostics — and `maphelp advanced` carries the diagnostic and tuning half. A new alias belongs
  in one of those two tables; `analysis/check_help.py` compares alias regexes against help rows.
  `mapwipe` is scoped on `sarea` (the SERVER's area) rather than the canvas, because a tab holds
  folded, stolen and merged rooms from elsewhere, and it never acts without `confirm`
  (`analysis/test_mapwipe.lua`).
- `tools/run-gate.sh [fast|full]` is the automated tier. `fast` (~4s) runs the seven
  self-contained assertion tests plus `canary.sh` diffed against the committed
  `analysis/canary_out.txt`; `full` (~27s) adds `test_cd_layout` and `test_count_defects`.
  `tools/pre-commit` runs `fast` whenever `lua/` or `map_helper.xml` is staged (`SKIP_GATE=1`
  bypasses); `full` is manual, since there is no remote for a pre-push hook to fire on. The
  hooks are copies — re-run `tools/install-hooks.sh` after editing either.
  The gate is a tripwire, not coverage: it catches a `diagSkewCap` or `crossCostTau` change on
  the 8 canary areas but not, say, `repelRadius` or `eqwCascadeDepth`. The 47-dump `COORDS=`
  sweep above (~55s) remains the real identity proof for a structural refactor.
  Four tests are red on this tree and so are NOT gated — `test_areamin`, `test_audit`
  (gore_bug demote count 1 vs 0), `test_bgcs`, `test_noyield` (its own dumps error, and the
  error path then reports the violation). Fixing one means moving it into the gate's list.

## 11. Publishing

The public repo (`nannymud-mapper`, MIT) is the client only. It carries **no corpus dumps** —
those are real area topology — and no server LPC.

`tools/export-repo.sh <dir>` writes the publishable tree into a staging directory that keeps
its own git history, separate from this repo's. Re-run it whenever you publish and commit
there; each commit is a squash of what changed since the last export. It refuses if the
target resolves to this repo, and aborts if any `.txt` reaches the export.

The history must stay separate. The dumps and the LPC are in this repo's history, and
filtering them out after the fact is easy to get subtly wrong.

Everything that builds its own fixtures still runs in the export — 10 of the 11 gated tests.
`run-gate.sh` detects the absent corpus and skips the layout canary and `cd_layout` rather
than failing, so a clone gets a real suite instead of a red tree.

`tools/build-package.sh` produces the `.mpackage` and never included `analysis/` anyway.
