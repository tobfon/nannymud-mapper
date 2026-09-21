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
| `window.lua` | `mapwin`: the map as a small resizable window inside the session |
| `export.lua` | `mapexport`: one map as an A4 SVG made for paper |

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

**The captured command.** The link captures every command as the parser ran it
(asked for by `maplink seq auto` in the handshake) and the server sends it as the
`!MAP` line's `dir` for the player's own moves and party follows. A non-compass
`dir` is therefore a replayable command and `onRoom` records it as the edge
command (the same store `maprecordmove` writes, first-writer wins), which is what
makes `climb mountain` replayable without recording it by hand. The server never
sends room prose there any more; a move it cannot name arrives as `dir=none`.

**Recorded exits outlive the rooms.** The command store is map-level, keyed by
permanent ids, so a GUI delete of rooms leaves it intact while Mudlet's special
exits die with the rooms; re-exploring then showed a glyph for an exit the map
could not route (2026-09-05). `onRoom` calls `smap_restore` when it creates a
room: every recorded edge touching it whose other end exists is put back. An
explicit `mapdelroom` clears the record, so that stays deleted. Mudlet has no
reliable event for a GUI delete, which is why this hangs off re-creation. To make
the explicit form as easy as the GUI one, `mapdelroom sel` deletes the mapper
selection through `delete_room`, and the same action is added to the mapper's
right-click menu as "Delete rooms (mapper)" via `addMapEvent`; Mudlet's own
entry cannot be removed, so it sits beside it.

**Walking from the map.** Double-clicking a room makes Mudlet run `getPath` from
the player's room and call the global `doSpeedWalk()` with the result in
`speedWalkDir`/`speedWalkPath`; ours hands those to `walk_steps`, so recorded
commands replay where a bare direction would fail. "Walk here (mapper)" in the
right-click menu does the same for a single selected room through `gotoRoom`.

**Server merge hints (`mha=`, `mh=`).** The server may suggest the canvas a room
is drawn on: `mha` for every room of its server area, `mh` for that room alone.
⛔ **A hint is data, never an action.** `onRoom` only STORES it (`elro.hintArea`,
one entry per server area, in map userdata; `mh` in room userdata) and the
canvas is always computed by `elro.resolve_area(sarea, mh)` from the hint plus
the player's say. If arrival APPLIED a hint, re-walking a room would undo an
unmerge, and the client would have to remember unmerged rooms one by one. As it
is, the player's say is per server area (`elro.hintIgnore`, and the global
`elro.hintsOff`), so rooms explored after an unmerge follow it and nothing can
merge them back. Precedence: steal > fold > the player's own merge > server
hint > server area. `resolve_area` is the ONE definition that `onRoom` and
`recompute_areas` both call; two that disagree flip a room's tab on every entry.
An unmerged area is **pinned** to its own tab (`hint_pinned`, forced-keep in
`recompute_areas`, exempt from the gate in `onRoom`): without the pin `area_min`
folds a half-explored one straight back into the area it was entered from,
which looks exactly like the unmerge failing. The server is the authority on
its own suggestion, so a line without the field clears what was stored.
`mapmerges` lists both kinds, `mapunmerge <area>` undoes either, `maphints
[on|off [area]]` is the way back. `analysis/test_hints.lua` walks the scenarios.

**Exits that leave the map.** The server maps only the areas its administrators
have opened, and a move into anything else used to send nothing, so such an exit
stayed a stub for ever: indistinguishable from one not yet walked, and counted
toward `stubHaloMin`, which let a town full of closed doors engage the halo and
hide its real frontier. The server now sends `!MAP id=0|from=<id>|dir=<dir>` for
such a move. `onOff` records the direction
in the room's `xoff` userdata and **links the exit to the placeholder room**
(`elro.OFF_ROOM`, in the "off the map" area, see below). That makes it an
ordinary cross-area exit: Mudlet drops the stub because an exit exists,
`stub_area_count` stops counting it, and `draw_area_stubs` draws the blue border
half-line, all by paths that already worked. The first cut drew a custom line on
a direction that had NO exit; in Mudlet that draws nothing and the stub stays
(seen live, the user's diagnosis). The layout never sees the link, since
`area_adjacency` drops exits that leave the area. `onRoom` unlinks the
placeholder BEFORE it writes a real edge through that direction, or the write
would read as a destination that changed and count a maze mutation. Compass exits only: nothing
else can be stubbed or drawn. A real arrival through the exit (the area was
opened) clears the mark in `onRoom`. The player has to try the exit once; an
untried exit into a closed area is still an honest stub.

**An exit into the DARK stays a stub, on purpose** (decided 2026-09-19, seen
live). A closed area is finished: there is nothing there for this map to learn,
so its exit becomes a border. A dark room is not: come back with a light and it
maps like any other, so the stub's "unexplored" is simply true. It also falls out
of the protocol rather than needing a rule, since the dark sends the bare marker,
which names no exit.

Precedence, in one rule: **a real edge always wins.** A marker for a direction
the room already has an exit in records nothing (an area mapped and later closed
keeps its edges; the map does not forget what it knows). A mark on a direction
that later gains an edge is stale and `stub_apply` drops it, which covers an
opened area whose edge is learned from the far side. The dark needs no rule: a
blind move sends the bare form, which has no room and no direction, so it can
neither mark an exit nor be mistaken for one, and the lit room's ordinary line
writes the real edge later. `onOff` runs its two halves, the record and the view
change, under separate `pcall`s and prints an error from either: Mudlet abandons
a trigger script at its first error, and when the record sat behind the view
change a live test swapped the canvas and left the stubs unmarked, silently.
`mapoff [id]` prints what a room has recorded, its stubs and its custom lines.

**Off the map, the view leaves too.** The player marker used to stay on the
last mapped room, which reads as "you are here" and is wrong. Mudlet cannot show
no player room, so the same marker moves the view to one placeholder room
(`elro.OFF_ROOM` 899999, below `MAZE_VBASE` and above any real id) in a canvas of
its own, "off the map", with a label saying so. `adopt` pins it to its own tab
and `via` = `VIA_NONE` keeps a one-room area from being folded into `world`.
`elro.view_room()` is what `recenter` and `view_assert` follow, so a background
relayout finishing while the player is away cannot snap the view back.
`elro.current` is deliberately NOT cleared: it anchors the stub halo, and nil
there makes `stub_halo_update` resync every stub on the map at each step off it.
Any `onRoom` ends the excursion. The server also sends the bare form
`!MAP id=0|from=0` for a login or teleport into unmapped space, so a session that
starts there does not show the player where the last one ended.

The markers are NOT gated on the client's version. They briefly were (sent only
after an ack reporting 1.1.0, to spare 1.0.0 clients a raw line), and that made
a feature depend on state kept in two places: the link forgets the client at
every login while the client remembered having said hello for the whole Mudlet
session, so a relog silently switched the markers off. 1.0.0 had no users, so
the gate went. The ack itself is still re-sent after a reload or a reconnect,
and by `mapack`, because the version notice and `maplink`'s status use it.

**The command fence** is the fallback for a wire without `dir=` (an admin
decision, `WIRE_DIR` in the server daemon): the link then prints `!MAPSEQ <n>
<command>` before every parsed command. `core.onSeq` keeps only the latest fence,
with the room the client was in when it arrived, and `onRoom` takes it once per
arrival when `dir` is missing: it labels the move only if its `from` is that room
and the fence is younger than `fenceWindow` ms, so a stale fence can never label a
vehicle. The trigger regex treats `dir=` as optional for this. The wire order is
fence, room description, `!MAP`; the fence lines are gagged unless `elro.fenceShow`
is set. The trigger accepts a prompt (`> `) in front of the fence: the prompt has
no trailing newline, and in a queued speedwalk the local command echo that would
normally break the line is long gone, so the fence arrives glued to it. The server side and its driver lessons are in `../DESIGN.md`.

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

### When a relayout is urgent (core, `guess_inconsistent`)

Every graph change queues a relayout after `autoIdle`; urgency only skips that wait. It is
urgent when the unit-step guess lands on a room, and when the step shows the drawing is wrong:
an edge that lies, an edge running over a third room, or the new room landing on somebody
else's edge. The edge a new room is PLACED on is truthful by construction, so it is skipped.

A room created by `onRoom` has no other edge, because exits are recorded only when walked.
So live, a loop closes when the player WALKS between two rooms that are both already placed,
and the closing edge is the walked one. Passing it as `skip` meant the closure was the one
edge never judged, and a lying closure sat on screen for the whole debounce, or for as long
as the player kept moving. For a walk between placed rooms only that edge is judged, from its
source (the forward exit always exists; the reverse may not be advertised). The rest of the
room's edges and the on-edge scan are left out: nothing moved, and re-reporting a lie the
solver chose to keep would make every new edge at that room urgent.

A new room that arrives with no edge at all (login, a teleport, `from=0`) gets no guess and
stays at `addRoom`'s (0,0), which is where a relayout normalises an area to, so it counts as a
collision, as a new room behind a special exit already did.

Not urgent, on purpose or not yet: a walked closure that only CROSSES another edge (often
forced, and the lowest severity), and a walked up/down between placed rooms (no compass
geometry to judge; `vertPack` decides it in the relayout). Urgency requested while a build is
in flight is not lost: `relayout_done` is level-triggered and rebuilds at once.

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

### Printing a map (export.lua)

`mapexport [area] [a4] [plain]` writes one map as an SVG into `<profile>/elro_export/`, which
any browser opens and prints. Mudlet's mapper has no print or image export, and a screenshot of a
dark, colour-coded screen is the wrong thing to put on paper, so the page is designed for
paper and is not a copy of the screen:

* White page, rooms as outlined boxes, thin dark connections. Terrain is a pale tint (the
  terrain colour let down 62% towards white), which costs little ink and is still a grey on a
  mono printer; `plain` leaves it out.
* Line STYLE carries what colour carries on screen, since colour does not survive a greyscale
  printer: dashed for a one-way exit, a dotted stub for an exit onto another map, a triangle
  for up or down.
* The second terrain's dot sits in a corner of the box, not the middle as on screen: the
  middle is where the room's number goes.
* The page is declared in millimetres as A4. Both orientations are tried and the one giving
  the bigger cell wins; a cell is capped at 11 mm so a small area is not blown up.
* Names never fit in a box, so rooms are numbered and listed under the map, with where an
  exit off the map leads. A small area (80 rooms or fewer) numbers every room; a larger one
  only the rooms worth finding on paper: healers, shops, transport, holy ground, typed exits
  and ways off the map. The list may take 40% of the page at most and says how many were
  left out; below a 3 mm box numbers are unreadable and are dropped, with a note.
* Numbers run as the page is read, top row first and left to right, not by room id: a
  number from the list is found by where it must be. Number 1 is the exception and is the
  door: the first room with an exit to the world map, else the first with any way off this
  map. A reader starts from where they walk in.
* One sheet. Tiling a large map over several is a later step; the command says so when the
  rooms come out under 2 mm. The footer says which rooms were numbered when not all were.
* A room takes 0.72 of its cell. At 0.56 the gaps were nearly as wide as the rooms and the
  map sprawled; the free cell went from 12 to 9.5 units so that the ROOM kept its size and
  only the gap halved. Half a cell is left clear all round the map, where the stubs end.
* **The default is not the sheet.** Bare `mapexport` is the same drawing with no paper to
  fit, for a screen or a wiki: a fixed 9.5 unit cell (38 pixels), an image as big as the map
  needs, every room numbered and the whole list under it, sized in pixels instead of
  millimetres. The one-sheet page is the `a4` option (file `<area>_a4.svg`). It began the
  other way round; the one-sheet rules (notable rooms only, a list capped at 40%) are paper's
  limits, read as arbitrary to the first person who tried it, and most exports are looked at,
  not printed.

It reads the map through the c-space snapshot and writes nothing back. `elro.exits` walks the
eight compass keys only, so up and down are read from the record directly.

### The map window (window.lua)

`mapwin` puts a `Geyser.Mapper` inside an `Adjustable.Container` over the top right of the text.
It is embedded (`createMapper`), so it belongs to one session and follows that session's console
under MultiView; `openMapWidget` would have made a dock or a free window instead. The container
supplies resizing, the lock styles and the save file.

* **The corner pin is ours.** The container's own attach reserves a console border, which keeps
  text out of the whole strip beside the map; the player wants text drawn underneath. And under
  MultiView `getMainWindowSize()` is the whole Mudlet window (measured 2560 against a 1280
  pane), so Geyser clamps and places against the wrong width and the box can be dragged out of
  the session. `anchor()` therefore keeps only the size the player chose, in pixels, and moves
  the box to `pane_width() - width, 0` after every drag (`AdjustableContainerRepositionFinish`)
  and every `sysWindowResizeEvent`. A second session opening beside this one raises no event
  (seen live: the box stayed put until the divider was moved), so while the window is up a one
  second timer compares the box's right edge with `pane_width()` and re-pins on a difference.
  The module restarts that timer at load when the window exists, because `elro` survives a
  reload or reinstall and the old timer chain does not. `pane_width()` is the one place that knows how to measure
  the session. Probed live with two sessions side by side: the one opened in MultiView read
  `getMainWindowSize()` 1278, its true pane, while the one that began in single view still read
  2560; both had 110 columns. So the main size is believed only when it lies within 6% above
  columns times `calcFontSize`, and then the edge is that size less the scrollbar. Otherwise
  the edge is columns times a cell width calibrated from the last believable reading (the
  smallest seen, since a partial column only ever inflates it), because `calcFontSize` says
  11.3 where the cell is 11.46 and that alone left an 18 pixel gap. `getMainConsoleWidth()`
  was tried and read 1111 in a 2545 pixel pane and in a 1280 one alike.

* **It opens by itself once.** A new player has no map on screen and does not know to ask for
  one, so with no save file the window opens at load (or a second after a mid-session install,
  which gets no `sysLoadEvent`) and says how to close it. After that the container's save file
  is the only record: the window comes back only if the file does not say hidden, so a player
  who closed it is not shown it again.
* **Mudlet's `generic_mapper` stays installed.** It answers `mapOpenEvent` by sending `look` and
  printing its quick-start three seconds later. Other scripts a player runs may depend on it, so
  it is not uninstalled, and its saved state is not touched. Its handlers are registered by name
  (`"map.eventHandler"`), which Mudlet resolves at each dispatch, so `quietly()` wraps that global
  for half a second around anything that raises the event and drops that one event. The restore
  is on a timer because it is not established that the event is delivered synchronously.
* **Left or right.** The right corner is the default because text runs from the left and a map
  there hides the start of every line; `mapwin left` exists for a player whose right corner
  is taken by another overlay. The side is not stored: a box saved with its left edge at the
  console's left edge is a left box when it is rebuilt.
* **OPEN: the neighbouring pane goes black (Mudlet 5.0.1, Windows, MultiView).** With a map
  window open in the FIRST session, alt-tabbing away and back blanks the second session's text
  until it is clicked; only lines that arrive afterwards are drawn. Never seen without a map
  window, and not caused by overlap (it happens with `mapwin left`). The last and best lead
  before the hunt was parked on 2026-09-20: it could not be produced with the window unlocked
  or locked by `mapwin lock` (style "full"), and appeared at once after locking from the
  container's RIGHT-CLICK menu (style "standard", whose inner area overhangs the box by a few
  pixels). Earlier observations that pointed elsewhere were made without knowing the lock
  state and should not be trusted. Not separated: the "standard" style against the use of the
  right-click menu itself (`lua elro.miniBox:lockContainer("standard")` with no menu, then
  "full" plus opening and dismissing the menu). The repaint happens in a session this code is
  not running in, so nothing here tries to repair it.
* **The banner.** Mudlet's "Short" map info (name / id (area)) fills a 380 pixel map, and
  neither its font nor its background can be set from Lua (the background is the preference
  behind `setMapInfoBgColor`, translucent by default, which is why rooms show through it). The
  module registers a "Room name" info and, on the first ever open and on `mapwin reset`, turns
  Short and Full off and that one on. Only then: the choice is the player's afterwards, in the
  map's right-click menu.
* **`createMapper` can refuse without an error.** Mudlet's binary carries "cannot create
  mapper. Do you already use a map window?" (and the reverse for the dock); the call returns
  nil and the message, nothing throws, and Geyser does not look, which would leave the frame
  with nothing in it. That was 1.2.0's black window on a tester's Mac (5.0.1): he used the
  docked Map, a bare `createMapper(0, 0, 300, 300)` printed that message, no error showed
  anywhere, and after a Mudlet restart the window worked. 1.2.0's `closeMapWidget` before
  building had not prevented it. The exact condition is still not known: on Windows 5.0.1 a
  session that had used the Map button got a working window. `can_embed()` asks with a
  zero-size `createMapper` before anything is built; on a refusal the automatic open does
  nothing and leaves the docked Map alone, and a typed `mapwin` prints Mudlet's reason and
  the restart that changes over.
 that are easy to break

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
