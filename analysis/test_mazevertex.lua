-- PLAN-maze step 1: the folded maze as ONE vertex in the layout graph.
--
-- ⭐ THE CLAIM: area_adjacency currently DROPS a boundary room's exit into a folded
-- maze (the destination is out of area), so the doors point nowhere and the rooms
-- around them are never tied to each other. Substituting a synthetic vertex turns
-- each door into a real compass edge, and the solver then places the vertex --
-- which is what makes the drawn stubs truthful rather than merely plausible.
--
-- The corpus cannot cover this: dumps carry rooms, exits and coordinates only, no
-- fold data. So the fixtures are built here.
--   cd .../map_helper/client && luajit analysis/test_mazevertex.lua
dofile("analysis/engine_load.lua")

local fails, checks = 0, 0
local function ok(cond, what)
  checks = checks + 1
  if not cond then fails = fails + 1 ; print("  FAIL  " .. what) end
end

local AA = elro.area_adjacency

-- An area of `plain` rooms in a row, plus a folded maze cluster reached by the
-- doors given as {room, dir}. Returns the area id.
local function fixture(doors, mazeRooms)
  reset_map() ; elro.cs_reset()
  local aid = addAreaName("testarea")
  local seen = {}
  for _, d in ipairs(doors) do
    if not seen[d[1]] then addRoom(d[1]) ; setRoomArea(d[1], aid) ; seen[d[1]] = true end
  end
  local maid = addAreaName("maze-900")
  for _, m in ipairs(mazeRooms or { 900, 901 }) do
    addRoom(m) ; setRoomArea(m, maid) ; setRoomUserData(m, "fold", "maze-900")
  end
  for _, d in ipairs(doors) do setExit(d[1], (mazeRooms or { 900 })[1], d[2]) end
  elro.cs_reset()
  return aid
end

print("knob OFF -- the hole stays a hole")
elro.mazeVertex = false
local aid = fixture({ { 1, "north" }, { 2, "west" } })
local rooms, adj = AA(aid)
ok(#rooms == 2, "only the real rooms are in the graph (" .. #rooms .. ")")
ok(next(adj[1]) == nil, "the door into the maze is DROPPED -- today's behaviour, the bug")

print("knob ON -- one vertex, real edges")
elro.mazeVertex = true
elro.cs_reset()
rooms, adj = AA(aid)
ok(#rooms == 3, "the vertex joins the room list (" .. #rooms .. ")")
local vid
for _, r in ipairs(rooms) do if elro.is_maze_vertex(r) then vid = r end end
ok(vid ~= nil, "and it is recognisable as a vertex")
ok(vid >= elro.MAZE_VBASE, "ids sit ABOVE every real room id, so sorting is unshifted")
ok(adj[1].north == vid, "room 1's north door is now an EDGE to the vertex")
ok(adj[2].west == vid, "room 2's west door too")
ok(adj[vid].south == 1, "the vertex carries the reverse of room 1's door")
ok(adj[vid].east == 2, "...and of room 2's")

-- sorting must not be disturbed: the vertex sorts last, real rooms keep their order
local sorted = {}
for i, r in ipairs(rooms) do sorted[i] = r end
table.sort(sorted)
ok(sorted[#sorted] == vid, "the vertex sorts LAST among the area's rooms")

print("one cluster, one vertex")
-- three doors from three rooms all reach the SAME cluster: still one vertex
aid = fixture({ { 1, "north" }, { 2, "west" }, { 3, "southeast" } })
rooms, adj = AA(aid)
local n = 0
for _, r in ipairs(rooms) do if elro.is_maze_vertex(r) then n = n + 1 end end
ok(n == 1, "three doors into one maze produce ONE vertex, not three (" .. n .. ")")

print("the block is SIZED, and capped")
-- ⛔ elro.mazeCells is 1 unless raised, because the block does not pay for itself:
-- on leowon and lyr it buys the fourth door either by making four real edges lie
-- (chained) or by scattering the cells 15x10 apart so the maze reads as two
-- (unchained). See the note at the cap in canvas.lua.
aid = fixture({ { 1, "west" }, { 2, "west" } })
rooms, adj = AA(aid)
local ncap = 0
for _, r in ipairs(rooms) do if elro.is_maze_vertex(r) then ncap = ncap + 1 end end
ok(ncap == 2, "two rooms sharing a direction get a cell each (" .. ncap .. ")")

print("two rooms entering the same way -- the block")
elro.mazeCells = 3
-- ⭐ THIS USED TO BE A COLLISION AND IS NOW THE POINT. Two rooms both entering
-- going west are both EAST of the maze, so with one cell only one of them could
-- have its door satisfied -- the second would sit behind the first and its spoke
-- would cross rooms. leowon and lyr each lost exactly one door to that. The block
-- gives them a cell each, spread perpendicular to the shared direction.
aid = fixture({ { 1, "west" }, { 2, "west" } })
rooms, adj = AA(aid)
local cells = {}
for _, r in ipairs(rooms) do if elro.is_maze_vertex(r) then cells[#cells + 1] = r end end
table.sort(cells)
ok(#cells == 2, "two rooms sharing a direction -> TWO cells (" .. #cells .. ")")
ok(adj[1].west ~= adj[2].west, "and their doors reach DIFFERENT cells")
ok(adj[1].west == cells[1] or adj[1].west == cells[2], "both of them real cells of the block")
-- each cell can now hold a clean reverse, where one cell could hold only one
local revs = 0
for _, c in ipairs(cells) do for _ in pairs(adj[c]) do revs = revs + 1 end end
ok(revs >= 3, "each cell carries its own reverse, plus the edge joining them (" .. revs .. ")")

-- the cells are ONE place, not two scattered points: a real compass edge joins them
local joined = false
for _, c in ipairs(cells) do
  for _, d in ipairs({ "north", "south", "east", "west" }) do
    if adj[c][d] and elro.is_maze_vertex(adj[c][d]) then joined = true end
  end
end
ok(joined, "a compass edge joins the cells, so the solver keeps them together")
-- west is horizontal, so the cells stack VERTICALLY: the rooms east of the maze
-- need to be in different rows, not different columns
local vert = false
for _, c in ipairs(cells) do
  if adj[c].north and elro.is_maze_vertex(adj[c].north) then vert = true end
end
ok(vert, "and they stack perpendicular to the shared direction")

print("one room facing it several ways -- mishra's shape")
-- one room, three doors: the maze has to BE in three places, so three cells
aid = fixture({ { 1, "east" }, { 1, "north" }, { 1, "south" } })
rooms, adj = AA(aid)
cells = {}
for _, r in ipairs(rooms) do if elro.is_maze_vertex(r) then cells[#cells + 1] = r end end
ok(#cells == 3, "three doors on one room -> THREE cells (" .. #cells .. ")")
local seen = {}
for _, d in ipairs({ "east", "north", "south" }) do
  ok(elro.is_maze_vertex(adj[1][d] or 0), d .. " reaches a cell")
  ok(not seen[adj[1][d]], "...a DIFFERENT one from the others")
  seen[adj[1][d]] = true
end

elro.mazeCells = nil

print("determinism")
-- the same map must produce the same ids and the same reverse edges every time
aid = fixture({ { 1, "north" }, { 2, "west" }, { 3, "north" } })
local idsA, revA = {}, {}
for pass = 1, 2 do
  elro.cs_reset()
  local rr, aa = AA(aid)
  local acc = {}
  for _, r in ipairs(rr) do if elro.is_maze_vertex(r) then acc[#acc + 1] = r end end
  table.sort(acc)
  local rv = {}
  for _, d in ipairs({ "north", "east", "south", "west" }) do
    rv[#rv + 1] = d .. "=" .. tostring(aa[acc[1]] and aa[acc[1]][d])
  end
  if pass == 1 then idsA, revA = table.concat(acc, ","), table.concat(rv, " ")
  else
    ok(idsA == table.concat(acc, ","), "vertex ids are stable across runs")
    ok(revA == table.concat(rv, " "), "so are the reverse edges the collisions decided")
  end
end

print("non-maze folds are untouched")
-- a manual (non-maze) submap fold must NOT get a vertex: it is a real submap of
-- real rooms, not an untruthful cluster standing in for one.
reset_map() ; elro.cs_reset()
aid = addAreaName("testarea")
addRoom(1) ; setRoomArea(1, aid)
local said = addAreaName("submap-7-north")
addRoom(900) ; setRoomArea(900, said) ; setRoomUserData(900, "fold", "submap-7-north")
setExit(1, 900, "north")
elro.cs_reset()
rooms, adj = AA(aid)
ok(#rooms == 1, "an ordinary submap fold produces no vertex")
ok(next(adj[1]) == nil, "...and its exit stays dropped, exactly as before")

print("through the REAL layout")
-- ⭐⭐ THE CLAIM OF THE WHOLE PLAN: the solver PLACES the vertex, so the doors are
-- truthful because the geometry was solved for them. Anything less than a real
-- layout cannot show this -- area_adjacency alone only proves the edges exist.
elro.mazeVertex = true
reset_map() ; elro.cs_reset()
aid = addAreaName("t")
for i = 1, 2 do addRoom(i) ; setRoomArea(i, aid) end
setExit(1, 2, "east") ; setExit(2, 1, "west")
local maid = addAreaName("maze-900")
addRoom(900) ; setRoomArea(900, maid) ; setRoomUserData(900, "fold", "maze-900")
-- north of room 1 AND northwest of room 2 is satisfiable, at room 1 + (0,1)
setExit(1, 900, "north") ; setExit(2, 900, "northwest")
elro.cs_reset()
elro._mazePos = nil
local laid = pcall(elro.layout_one, aid)
ok(laid, "a layout carrying a maze vertex runs to completion")
local vx, vy
for _, p in pairs(elro._mazePos or {}) do vx, vy = p[1], p[2] end
ok(vx ~= nil, "the vertex's solved position is stashed, not written as room coordinates")
if vx then
  local x1, y1 = getRoomCoordinates(1)
  local x2, y2 = getRoomCoordinates(2)
  ok(vx - x1 == 0 and vy - y1 > 0, "room 1's NORTH door points at the vertex, truthfully")
  ok(vx - x2 < 0 and vy - y2 > 0 and (x2 - vx) == (vy - y2),
     "room 2's NORTHWEST door does too -- both satisfied at once, which is the point")
end
-- ⛔ AND THE ID CEILING, which the first cut got wrong. The engine packs a room
-- PAIR as `r * 1000003 + x` in eqw's edge index (K.eid's 2^26 is the OTHER, larger
-- packing). A vertex id over that modulus decodes to a different room and the
-- layout died in `mirror` on a room that was never placed.
ok(elro.MAZE_VBASE < elro.MAZE_VMAX, "the id floor is below the packing ceiling")
local anyv
for v in pairs(elro._mazePos or {}) do anyv = v end
ok(anyv and anyv < 1000003, "a vertex id stays inside `r * 1000003 + x` (" .. tostring(anyv) .. ")")
ok(anyv and anyv < 2 ^ 26, "...and inside K.eid's 2^26 as well")

print("the SPOKE render (step 3)")
-- ⭐ Every door of one cluster ends at the SAME point, so the map says "these are
-- the same maze, and it is here" -- and says it truthfully, because the solver
-- placed that point. Three points per spoke, always: the middle one is half a cell
-- along the door's REAL direction, so the departure is a fact even when the rest is
-- routing. A satisfied door makes that midpoint collinear and the kink vanishes,
-- which is how "truthful" reads on screen without a second line style.
local LINES = {}
local realACL, realGCL = addCustomLine, getCustomLines
_G.addCustomLine = function(r, pts, d, style, col) LINES[#LINES + 1] =
  { r = r, pts = pts, d = d, style = style, col = col } end
_G.getCustomLines = function() return {} end

local function collinear(p)          -- does the midpoint lie on a->c?
  if #p < 3 then return nil end
  local ax, ay, bx, by, cx, cy = p[1][1], p[1][2], p[2][1], p[2][2], p[3][1], p[3][2]
  return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax) == 0
end
-- ⚠ style alone is NOT enough to pick out a spoke: draw_residual dashes too (and
-- files its lines under short direction keys, so elro.delta does not even know
-- them). The maze colour is what identifies ours.
local MCOL = (elro.classColours and elro.classColours.maze) or { 150, 40, 200 }
local function spokes()
  local out = {}
  for _, L in ipairs(LINES) do
    if L.style == "dash line" and L.col[1] == MCOL[1] and L.col[2] == MCOL[2] then
      out[#out + 1] = L
    end
  end
  return out
end

-- satisfiable: north from room 1, northwest from room 2
local function render_fixture(doors)
  reset_map() ; elro.cs_reset() ; LINES = {}
  local a = addAreaName("t")
  for i = 1, 2 do addRoom(i) ; setRoomArea(i, a) end
  setExit(1, 2, "east") ; setExit(2, 1, "west")
  local m = addAreaName("maze-900")
  addRoom(900) ; setRoomArea(900, m) ; setRoomUserData(900, "fold", "maze-900")
  for _, d in ipairs(doors) do setExit(d[1], 900, d[2]) end
  elro.cs_reset() ; elro._mazePos = nil
  elro.layout_one(a)
  return a
end

elro.mazeVertex = true
render_fixture({ { 1, "north" }, { 2, "northwest" } })
local sp = spokes()
ok(#sp == 2, "one dashed spoke per door (" .. #sp .. ")")
local endx, endy = sp[1] and sp[1].pts[3][1], sp[1] and sp[1].pts[3][2]
local same = true
for _, L in ipairs(sp) do
  if L.pts[3][1] ~= endx or L.pts[3][2] ~= endy then same = false end
  ok(#L.pts == 3, "each spoke departs, then routes (" .. #L.pts .. " points)")
  ok(collinear(L.pts), "a satisfied door draws STRAIGHT -- no kink to explain")
end
ok(same, "every spoke of one cluster ends at the SAME point -- the maze is one place")
local mc = MCOL
ok(sp[1] and sp[1].col[1] == mc[1], "drawn in the maze colour")

-- ⛔ EVERY DOOR DRAWS, dogleg and all. Two earlier cuts gated this -- on
-- truthfulness, then on distance -- and both stopped leowon showing rooms that
-- really do connect to its maze. Drawing is an overlay: a bent spoke that crosses
-- something costs nothing and still shows the connection. The BASE LAYOUT is what
-- must not be paid for, and that is guarded in the solve by the veto.
render_fixture({ { 1, "east" }, { 1, "north" }, { 1, "south" } })
sp = spokes()
ok(#sp == 3, "all three doors draw, including the ones the solver could not satisfy (" .. #sp .. ")")
local straight, kinked = 0, 0
for _, L in ipairs(sp) do
  if collinear(L.pts) then straight = straight + 1 else kinked = kinked + 1 end
  local del = elro.delta[L.d]
  local dx, dy = L.pts[2][1] - L.pts[1][1], L.pts[2][2] - L.pts[1][2]
  ok(dx * ((del[1] == 0) and 1 or del[1]) >= 0 and dy * ((del[2] == 0) and 1 or del[2]) >= 0,
     L.d .. " departs in its OWN direction, satisfied or not")
end
ok(straight >= 1, "the satisfied door draws straight (" .. straight .. ")")
ok(kinked >= 1, "and an unsatisfied one is visibly kinked rather than hidden (" .. kinked .. ")")

-- knob off: back to the half stub, exactly as before
elro.mazeVertex = false
render_fixture({ { 1, "north" }, { 2, "northwest" } })
ok(#spokes() == 0, "knob OFF draws no spokes at all")
local half = 0
for _, L in ipairs(LINES) do if L.style == "solid line" and #L.pts == 2 then half = half + 1 end end
ok(half >= 1, "...and the old half-length stub is back (" .. half .. ")")

_G.addCustomLine, _G.getCustomLines = realACL, realGCL
elro.mazeVertex = false
print("")
if fails == 0 then print("PASS  " .. checks .. "/" .. checks .. " checks passed")
else print("FAIL  " .. fails .. "/" .. checks .. " checks failed") ; os.exit(1) end
