-- Canvas handling: area adjacency, flood layout, composition, orphans, defect counting.
-- Split out of layout.lua; see lua/modules.lua for the load order.

elro = elro or {}
local G = elro.g or error("canvas.lua: lua/geom.lua must be loaded first (see elro.modules)")
local ori = G.ori
local seg = G.seg
local K = elro.k or error("canvas.lua: lua/keys.lua must be loaded first (see elro.modules)")
local ekey = K.edge
local each_exit = elro.exits or error("canvas.lua: lua/core.lua must be loaded first")
local CLK = elro.clk or error("canvas.lua: lua/core.lua must be loaded first")
local TUNE = elro.TUNE or error("canvas.lua: lua/tune.lua must be loaded first")

-- ---- maze vertices (PLAN-maze.md step 1) -----------------------------------
-- A folded maze is a HOLE in the parent canvas: the loop below drops a boundary
-- room's exit into it because the destination is out of area, so those doors point
-- nowhere and the rooms around them are never tied to each other at all. The fix
-- is to put ONE vertex on the canvas per cluster and let the solver place it, so a
-- door becomes a real compass edge and the geometry is SOLVED for it.
--
-- ⚠ THE VERTEX IS NOT A MUDLET ROOM and never becomes one. It exists only in the
-- rooms/adj pair the engine consumes; write_canvas stashes its solved position
-- rather than writing coordinates. So no exit is ever added, getPath cannot route
-- through it -- correct, since the maze's exits shuffle and any route through it
-- would be a lie you could walk into -- and elro.cs is left alone, which also
-- keeps two areas' vertices out of each other's cache.
if elro.mazeVertex == nil then elro.mazeVertex = false end   -- scaffolding: folds out at step 5

-- ⛔ THE ID HAS A CEILING AS WELL AS A FLOOR, and only the floor is obvious.
--   floor: ABOVE every real room id, never below. Callers table.sort the room list
--     in place, so a negative id would sort FIRST and shift every downstream
--     tie-break and seed order, and determinism is load-bearing here.
--   ceiling: BELOW 1000003. The engine packs a room PAIR into one number in two
--     different ways -- `K.eid` is `a * 2^26 + b` and says so, but eqw's edge index
--     and untruthful-edge sets use `r * 1000003 + x`, which is documented nowhere.
--     An id over that modulus decodes to a different room: the first cut used 2^24,
--     cleared K.eid, blew the other one, and crashed in `mirror` on a room that was
--     never placed. A vertex must be small enough that BOTH encodings stay exact.
-- The areaID term keeps a cluster's vertex distinct on each canvas it has doors on.
elro.MAZE_VBASE = elro.MAZE_VBASE or 900000
elro.MAZE_VMAX  = elro.MAZE_VMAX  or 1000003   -- the tighter of the two packings
local MAZE_PER_AREA = 64
local function maze_vid(areaID, i) return elro.MAZE_VBASE + areaID * MAZE_PER_AREA + i end
function elro.is_maze_vertex(id) return type(id) == "number" and id >= elro.MAZE_VBASE end

-- Which canvas a vertex belongs to, straight back out of its id. Used to drop an
-- area's stale positions when it is re-solved: ids are reused deterministically, so
-- a position left over from a previous fold set would be silently believed.
function elro.maze_vertex_area(id)
  return math.floor((id - elro.MAZE_VBASE) / MAZE_PER_AREA)
end

-- Forget everything the last solve of this area published.
local function maze_forget(areaID)
  if elro._mazeDoor then elro._mazeDoor[areaID] = nil end
  if elro._mazePos then
    for vid in pairs(elro._mazePos) do
      if elro.maze_vertex_area(vid) == areaID then elro._mazePos[vid] = nil end
    end
  end
end

-- Fixed order, because the reverse edges below are first-writer-wins and `pairs`
-- over a dir table is not deterministic.
local DIRS8 = { "north", "northeast", "east", "southeast",
                "south", "southwest", "west", "northwest" }

-- ⛔ THE MAZE VERTEX MAY MOVE THE LAYOUT; IT MAY NOT DEFECT IT. Moving rooms is
-- the point -- leowon comes out ten columns narrower for it. What is not allowed
-- is a collision or a room-on-edge that the area does not have without the vertex:
-- an unsatisfiable door is still a live constraint, so the solver can drag a room
-- toward a cell it cannot reach and land it on someone else's edge while still
-- failing the door. lyr does exactly that with 2533 on the 2524-2525 edge.
--
-- Proving the vertex CAUSED a defect needs both layouts, and a vetoed area is
-- re-solved without it on the very next relayout -- so the comparison is made
-- ACROSS those two solves and costs no extra work:
--
--   solve with it     -> defects > 0 ?  veto, and remember the count
--   solve without it  -> fewer defects ?  the vertex was to blame, veto stands
--                        no better     ?  it was not, lift the veto and stop
--                                          re-testing so the area cannot oscillate
--
-- Crossings are deliberately not counted: they are the least severe of the three
-- and the expensive one to compute here. Collisions and room-on-edge are what the
-- vertex actually produces, and both are ranked above a crossing anyway.
elro._mazeVeto = elro._mazeVeto or {}     -- aid -> true: skip the vertex here
elro._mazeSeen = elro._mazeSeen or {}     -- aid -> { withV = n, settled = bool }

function elro.maze_veto_clear(aid)
  if aid then elro._mazeVeto[aid] = nil ; elro._mazeSeen[aid] = nil
  else elro._mazeVeto = {} ; elro._mazeSeen = {} end
end

-- Collisions and rooms-on-edge among the REAL rooms of an area, off live
-- coordinates. The vertex is not a room and is not counted.
--
-- ⛔ WALKS EACH EDGE'S CELLS, never every room per edge. The first cut tested
-- every room against every edge, which is O(rooms^2 x edges) -- fine for an
-- 18-room fixture and ruinous on a 393-room area, and this runs after every solve.
-- elro.g.seg is the same rasteriser guess_inconsistent uses, so the answer agrees
-- with the scanner cell for cell.
--
-- ⚠ Rooms with no coordinates are SKIPPED rather than counted at (0,0). Treating
-- unplaced rooms as colocated invents a pile of collisions at the origin and
-- vetoed gore_bug -- an area the vertex takes from 18x5 to 6x8 with every door
-- satisfied and nothing on an edge.
function elro.maze_defect_count(aid)
  local rooms = elro.cs_area_rooms(aid)
  local at, coll = {}, 0
  for _, r in ipairs(rooms) do
    if roomExists(r) then
      local x, y = getRoomCoordinates(r)
      if x then
        local k = x * 1000003 + y
        if at[k] then coll = coll + 1 else at[k] = r end
      end
    end
  end
  local roe = 0
  local seg = elro.g and elro.g.seg
  if seg then
    for _, u in ipairs(rooms) do
      if roomExists(u) then
        local ax, ay = getRoomCoordinates(u)
        if ax then
          for d, v in pairs(elro.cs_exits(u)) do
            local de = elro.delta[d]
            -- ⛔ THIS CANVAS ONLY. A cross-area exit -- a maze door above all --
            -- ends at a room laid out in a DIFFERENT frame, so its coordinates say
            -- nothing here and the segment drawn between them is fiction. Counting
            -- those invents defects, and a false veto is exactly what stops a maze
            -- vertex being used where it would have helped.
            if de and (de[1] ~= 0 or de[2] ~= 0) and v ~= u and u < v
               and roomExists(v) and getRoomArea(v) == aid then
              local bx, by = getRoomCoordinates(v)
              if bx then
                -- ⛔ THE RASTER IS A SUPERSET: seg walks the cells a DIAGONAL
                -- passes through, not the ones its centre line crosses, so every
                -- hit is confirmed with the exact test before it counts. Without
                -- that, gore_bug -- which is nearly all diagonals -- reported two
                -- rooms-on-edge it does not have and vetoed a vertex that takes
                -- the area from 18x5 to 6x8 with every door satisfied.
                local ex, ey = bx - ax, by - ay
                seg(ax, ay, bx, by, function(cx, cy)
                  local o = at[cx * 1000003 + cy]
                  if o and o ~= u and o ~= v then
                    local tx, ty = cx - ax, cy - ay
                    if ex * ty - ey * tx == 0                      -- on the line
                       and tx * ex + ty * ey > 0                   -- past u
                       and tx * tx + ty * ty < ex * ex + ey * ey   -- before v
                    then roe = roe + 1 end
                  end
                end)
              end
            end
          end
        end
      end
    end
  end
  return coll, roe
end

-- Called after each solve of `aid`. Runs the state machine above.
function elro.maze_check_veto(aid)
  local seen = elro._mazeSeen[aid]
  if seen and seen.settled then return false end
  local coll, roe = elro.maze_defect_count(aid)
  local n = coll + roe
  if elro._mazeVeto[aid] then
    -- this was the WITHOUT-vertex solve: did dropping it actually help?
    local withV = seen and seen.withV or math.huge
    if n < withV then
      elro._mazeSeen[aid] = { settled = true }        -- the vertex was to blame
      elro.tr(string.format("maze: veto CONFIRMED on area %s -- %d defect(s) with the vertex, %d without",
              tostring(aid), withV, n))
    else
      elro._mazeVeto[aid] = nil                        -- it was not; let it back in
      elro._mazeSeen[aid] = { settled = true }
      elro.tr(string.format("maze: veto LIFTED on area %s -- %d defect(s) either way, so the vertex is not the cause",
              tostring(aid), n))
    end
    return false
  end
  if n > 0 and (elro._mazeDoor or {})[aid] then
    -- a defect AND a vertex here: suspect it, and find out next relayout
    elro._mazeVeto[aid] = true
    elro._mazeSeen[aid] = { withV = n }
    elro.tr(string.format("maze: vertex SUSPECTED on area %s -- %d defect(s); next relayout solves without it",
            tostring(aid), n))
    return true
  end
  if (elro._mazeDoor or {})[aid] then
    elro._mazeSeen[aid] = { settled = true }           -- clean with the vertex: done
  end
  return false
end

-- ⭐ HOW BIG THE BLOCK MUST BE, from two independent lower bounds -- the same pair
-- mapmazefit reports, and for the same reasons:
--   1. the most doors on any ONE room: it needs the maze in that many places;
--   2. the most ROOMS sharing one door direction. Every room entering going south
--      sits in the block's column; one can be adjacent, a second would have to sit
--      BEHIND the first and its spoke would cross rooms, so that door gets dropped.
--      leowon and lyr each lost exactly one door to this while the maze was a
--      single cell.
-- The block is a straight run of cells laid out PERPENDICULAR to the direction
-- that forced it -- which is the shape leowon had before its maze was folded: two
-- maze rooms side by side, one boundary room north of each.
local function block_shape(doors)
  local per, byDir = {}, {}
  for _, d in ipairs(doors) do
    per[d.room] = (per[d.room] or 0) + 1
    byDir[d.dir] = byDir[d.dir] or {}
    byDir[d.dir][d.room] = true
  end
  local n = 1
  for _, c in pairs(per) do if c > n then n = c end end
  local dn, dd = 1, nil
  for _, dir in ipairs(DIRS8) do          -- fixed order: ties must not follow `pairs`
    local set = byDir[dir]
    if set then
      local c = 0 ; for _ in pairs(set) do c = c + 1 end
      if c > dn then dn, dd = c, dir end
    end
  end
  if dn > n then n = dn end
  local axis = "x"                        -- rooms north of it need cells side by side
  if dd then
    local u = elro.delta[dd]
    if u and u[1] ~= 0 and u[2] == 0 then axis = "y" end   -- rooms west of it: stacked
  end
  -- ⭐ COUNT IS A LOWER BOUND, NOT THE SIZE. Two rooms entering going south need
  -- two cells only if they are side by side; leowon's sit at x=44 and x=42, so the
  -- block has to SPAN them -- three cells -- or one of the two doors still cannot
  -- reach. Sized from where the sharing rooms currently sit, which is the same seed
  -- assign_slots orders them by: it picks a size, and if the first layout guesses
  -- wrong the next one reads the positions the doors themselves produced.
  if dd and dn > 1 then
    local lo, hi
    for _, d in ipairs(doors) do
      if d.dir == dd then
        local x, y = getRoomCoordinates(d.room)
        if x then
          local v = (axis == "x") and x or y
          if not lo or v < lo then lo = v end
          if not hi or v > hi then hi = v end
        end
      end
    end
    if lo and hi then
      local span = hi - lo + 1
      if span > n then n = span end
    end
  end
  return n, axis, dd
end

-- Which cell each door attaches to. The rooms sharing the forcing direction spread
-- across the block in the order they CURRENTLY sit along the spread axis.
--
-- ⚠ THAT IS A SEED, NOT A MEASUREMENT -- the distinction that matters here, since
-- pricing anything off pre-solve positions was already wrong once in this plan.
-- It only picks an ORDER, and if the first layout guesses wrong the next relayout
-- reads the positions the doors themselves produced and unwinds it. A room with no
-- coordinates yet (leowon's 1738, whose only edge is the maze door) sorts last by
-- id rather than pretending to a position.
local function assign_slots(doors, n, axis, dd)
  local slot = {}
  for _, d in ipairs(doors) do
    slot[d.room] = slot[d.room] or {}
    slot[d.room][d.dir] = 1
  end
  if n < 2 then return slot end
  -- ⛔ NOT `or not dd`: a block can be forced by ONE room with several doors, in
  -- which case no direction is shared, dd is nil, and bailing here left all of its
  -- doors on cell 1 -- the exact case (mishra's) the extra cells exist for.
  if dd then
    local share, seen = {}, {}
    for _, d in ipairs(doors) do
      if d.dir == dd and not seen[d.room] then seen[d.room] = true ; share[#share + 1] = d.room end
    end
    table.sort(share, function(a, b)
      local ax, ay = getRoomCoordinates(a)
      local bx, by = getRoomCoordinates(b)
      local av = ax and ((axis == "x") and ax or ay) or nil
      local bv = bx and ((axis == "x") and bx or by) or nil
      if av and bv and av ~= bv then return av < bv end
      if (av == nil) ~= (bv == nil) then return bv == nil end
      return a < b
    end)
    -- ⭐ BY OFFSET, NOT BY RANK. The block spans the sharing rooms, so a room two
    -- cells along belongs in the third cell, not the second: leowon's 1738 and 1731
    -- sit at x=42 and x=44 across a 3-cell block, and ranking them 1st and 2nd put
    -- 1731 on the middle cell where its door could not reach it.
    local rep, lo = {}, nil
    for _, r in ipairs(share) do
      local x, y = getRoomCoordinates(r)
      if x then
        local v = (axis == "x") and x or y
        if not lo or v < lo then lo = v end
      end
    end
    -- ⚠ Offsets can COLLIDE -- two rooms at the same coordinate (or none yet, which
    -- reads the same) both want cell 1, leaving a cell unused and a door unserved.
    -- They still need one each, which is why the count is a separate bound; the
    -- later one takes the next free cell.
    local taken = {}
    for i, r in ipairs(share) do
      local x, y = getRoomCoordinates(r)
      local sl = i
      if x and lo then
        sl = ((axis == "x") and x or y) - lo + 1
      end
      if sl < 1 then sl = 1 end
      if sl > n then sl = n end
      while taken[sl] and sl < n do sl = sl + 1 end
      if taken[sl] then                       -- full to the right; search left
        local f = sl
        while f > 1 and taken[f] do f = f - 1 end
        if not taken[f] then sl = f end
      end
      taken[sl] = true
      slot[r][dd] = sl
      if x and rep[sl] == nil then rep[sl] = (axis == "x") and x or y end
    end
    -- ⭐ AND EVERY OTHER DOOR TAKES THE NEAREST CELL, not cell 1. leowon's 1733
    -- sits east of the block and enters going west, so it has to reach the EASTERN
    -- cell; defaulting it to the first one pointed it at the far side and turned a
    -- door that was truthful with a single cell into a bent one. The cells' seed
    -- positions are the sharing rooms that claimed them.
    for _, d in ipairs(doors) do
      if d.dir ~= dd then
        local x, y = getRoomCoordinates(d.room)
        local v = x and ((axis == "x") and x or y) or nil
        if v then
          local best, bestd
          for i = 1, n do
            local rv = rep[i]
            if rv then
              local gap = (v - rv < 0) and (rv - v) or (v - rv)
              if not bestd or gap < bestd then best, bestd = i, gap end
            end
          end
          if best then slot[d.room][d.dir] = best end
        end
      end
    end
  end
  -- A room facing the maze several ways needs a cell per door, so spread its own.
  -- ⛔ ONLY SUCH A ROOM. This used to run for every door room and rewrote each
  -- one's slot to the index of the door within that room -- which for a room with
  -- a SINGLE door is always 1, silently undoing the nearest-cell choice above.
  -- leowon's 1733 kept being sent to the far end of the block that way.
  for _, d in ipairs(doors) do
    local sl = slot[d.room]
    local ndoor = 0
    for _, dir in ipairs(DIRS8) do if sl[dir] then ndoor = ndoor + 1 end end
    if ndoor > 1 then
      local used, k = {}, 0
      for _, dir in ipairs(DIRS8) do
        if sl[dir] then
          k = k + 1
          local want = (dir == dd) and sl[dir] or ((k > n) and n or k)
          while used[want] and want < n do want = want + 1 end
          sl[dir] = want ; used[want] = true
        end
      end
    end
  end
  return slot
end

-- The cells this area needs, the maze-room -> fold lookup the substitution wants,
-- the block's own internal edges, and the per-door cell map. nil when there are no
-- maze doors here.
local function maze_vertices(areaID, rooms, cs_room, delta)
  maze_forget(areaID)                     -- this solve republishes; nothing carries over
  if elro._mazeVeto and elro._mazeVeto[areaID] then return nil end   -- cost a defect last time
  local destFold, byFold = {}, {}
  for _, r in ipairs(rooms) do
    -- the map has outgrown the id window: degrade to today's behaviour (the door
    -- is dropped) rather than hand the engine two rooms that pack to one key
    if r >= elro.MAZE_VBASE then return nil end
    local rec = cs_room(r)
    if rec then
      for d, dest in pairs(rec.ex) do
        local del = delta[d]
        if del and (del[1] ~= 0 or del[2] ~= 0) then
          if destFold[dest] == nil then
            local drec = cs_room(dest)
            destFold[dest] = (drec and elro.is_maze_area(drec.fold)) and drec.fold or false
          end
          local f = destFold[dest]
          if f then
            byFold[f] = byFold[f] or {}
            byFold[f][#byFold[f] + 1] = { room = r, dir = d }
          end
        end
      end
    end
  end
  local names = {}
  for f in pairs(byFold) do names[#names + 1] = f end
  if #names == 0 then return nil end
  table.sort(names)                       -- deterministic ids from a deterministic order

  local chain, door, used = {}, {}, 0
  for _, f in ipairs(names) do
    local doors = byFold[f]
    table.sort(doors, function(a, b)
      if a.room ~= b.room then return a.room < b.room end
      return a.dir < b.dir
    end)
    local n, axis, dd = block_shape(doors)
    -- ⛔ CAPPED AT ONE BY DEFAULT, because the block does not pay for itself. On
    -- leowon and lyr, measured with analysis/maze_ab.lua:
    --   1 cell            3/4 doors, no lies, maze reads as ONE place  <- shipped
    --   block, chained    4/4 doors, but FOUR real edges start lying
    --   block, unchained  4/4 doors, no lies, but the cells land 15x10 and 16x5
    --                     apart -- two scattered markers, not one maze
    -- The cause is geometric, not a bug: the two same-direction rooms end up far
    -- apart in the solved layout, so any maze satisfying both doors must span that
    -- distance. There is no compact arrangement. A kinked spoke saying "this door
    -- cannot be drawn truthfully" beats all three. Raise elro.mazeCells to
    -- experiment; the machinery is here and tested.
    local cap = elro.mazeCells or 4
    if n > cap then n = cap end
    if used + n >= MAZE_PER_AREA then return nil end
    if maze_vid(areaID, used + n) >= elro.MAZE_VMAX then return nil end
    local ids = {}
    for i = 1, n do used = used + 1 ; ids[i] = maze_vid(areaID, used) end
    -- the block itself: each cell joined to the next by a real compass edge, which
    -- is what holds them together as ONE place rather than n scattered points
    local step = (axis == "x") and "east" or "north"
    for i = 1, n - 1 do chain[#chain + 1] = { u = ids[i], v = ids[i + 1], d = step } end
    local slot = assign_slots(doors, n, axis, dd)
    for _, d in ipairs(doors) do
      door[d.room] = door[d.room] or {}
      door[d.room][d.dir] = ids[slot[d.room][d.dir] or 1]
    end
  end
  -- published for the renderer: it holds a DOOR and needs the cell that door
  -- attaches to, which is no longer one per cluster
  elro._mazeDoor = elro._mazeDoor or {}
  elro._mazeDoor[areaID] = door
  return door, destFold, chain
end

-- { room -> { dir -> destRoom } } for COMPASS exits within this area only.
-- Reads the c-space snapshot (elro.cs_room), not Mudlet: the returned adj is a private
-- copy, so the solver holds immutable input that onRoom cannot change underneath it.
-- keepLoops: only the constraint audit passes true (selfloops are real source bugs it
-- must report). Everyone else gets them stripped -- a selfloop can never be drawn
-- truthfully and carries no planarity information, and leftover selfloop darts corrupt
-- elro.faces nondeterministically, so stripping here is a determinism requirement.
local function area_adjacency(areaID, keepLoops)
  local rooms = elro.cs_area_rooms(areaID)
  local cs_room, delta = elro.cs_room, elro.delta   -- hot: once per room / per edge
  local inArea, adj = {}, {}
  for _, r in ipairs(rooms) do inArea[r] = true end
  local door, destFold, chain
  if elro.mazeVertex then door, destFold, chain = maze_vertices(areaID, rooms, cs_room, delta) end
  for _, r in ipairs(rooms) do
    local a = {}
    adj[r] = a
    local rec = cs_room(r)
    if rec then
      for d, dest in pairs(rec.ex) do
        local del = delta[d]
        if del and (del[1] ~= 0 or del[2] ~= 0) then
          local to = inArea[dest] and dest or nil
          -- the substitution: a door into a folded maze becomes an edge to that
          -- cluster's vertex instead of being dropped for being out of area
          -- each door goes to ITS cell of the block, not to one shared point
          if not to and door and destFold[dest] then
            local byDir = door[r]
            to = byDir and byDir[d] or nil
          end
          if to and (keepLoops or to ~= r) then a[d] = to end
        end
      end
    end
  end
  -- Copy the id list: callers table.sort it in place, and cs_area_rooms hands
  -- back the cached list itself.
  local out = {}
  for i = 1, #rooms do out[i] = rooms[i] end
  if door then
    local vids, seenV = {}, {}
    for _, byDir in pairs(door) do
      for _, id in pairs(byDir) do
        if not seenV[id] then seenV[id] = true ; vids[#vids + 1] = id ; adj[id] = {} end
      end
    end
    for _, e in ipairs(chain or {}) do
      for _, id in ipairs({ e.u, e.v }) do
        if not seenV[id] then seenV[id] = true ; vids[#vids + 1] = id ; adj[id] = {} end
      end
    end
    table.sort(vids)
    -- the block's internal edges, so the cells are one rigid place
    for _, e in ipairs(chain or {}) do
      adj[e.u][e.d] = e.v
      local rv = elro.reverse[e.d]
      if rv then adj[e.v][rv] = e.u end
    end
    -- Reverse edges, so the vertex is a two-way node like any room. Doors are
    -- taken in a fixed room/direction order because several doors can want the
    -- SAME reverse direction (three rooms east of the maze all ask for its west)
    -- and only one can have it -- first writer wins, deterministically. The
    -- others still constrain the vertex through their own forward edge.
    local sorted = {}
    for i = 1, #rooms do sorted[i] = rooms[i] end
    table.sort(sorted)
    for _, r in ipairs(sorted) do
      for _, d in ipairs(DIRS8) do
        local dest = adj[r][d]
        if dest and elro.is_maze_vertex(dest) then
          local rev = elro.reverse[d]
          if rev and adj[dest][rev] == nil then adj[dest][rev] = r end
        end
      end
    end
    for _, id in ipairs(vids) do out[#out + 1] = id end
  end
  return out, adj
end
elro.area_adjacency = area_adjacency

-- a placement canvas: coord/comp/occ + expand-on-collision place() + on_edge()
local function new_canvas(adj)
  local coord, comp, occ = {}, {}, {}
  local function key(c, x, y) return c .. ":" .. x .. ":" .. y end
  local function insert_axis(c, t, dir, ax)
    for r, cc in pairs(comp) do
      if cc == c then
        local p = coord[r]
        if (dir > 0 and p[ax] >= t) or (dir < 0 and p[ax] <= t) then
          occ[key(c, p[1], p[2])] = nil ; p[ax] = p[ax] + dir
        end
      end
    end
    for r, cc in pairs(comp) do
      if cc == c then local p = coord[r] ; occ[key(c, p[1], p[2])] = r end
    end
  end
  local function place(cx, cy, dx, dy, v, c)   -- expand-on-collision
    local tx, ty = cx + dx, cy + dy
    if occ[key(c, tx, ty)] then
      if dx ~= 0 then insert_axis(c, tx, dx > 0 and 1 or -1, 1)
      elseif dy ~= 0 then insert_axis(c, ty, dy > 0 and 1 or -1, 2)
      else return false end
    end
    coord[v] = {tx, ty} ; comp[v] = c ; occ[key(c, tx, ty)] = v
    return true
  end
  local function edge_between(c, ax, ay, bx, by)
    local a, b = occ[key(c, ax, ay)], occ[key(c, bx, by)]
    if not a or not b then return false end
    for _, dest in each_exit(adj[a]) do if dest == b then return true end end
    return false
  end
  local function on_edge(c, tx, ty)
    return edge_between(c, tx - 1, ty, tx + 1, ty)
        or edge_between(c, tx, ty - 1, tx, ty + 1)
  end
  return { coord = coord, comp = comp, occ = occ, key = key,
           place = place, on_edge = on_edge }
end

-- offset each component side-by-side and write coords to Mudlet. Spacing is now
-- baked into placement (skeleton at delta*s, non-core hugging at delta*1), so
-- this just normalizes to non-negative coords and offsets components.
local function write_canvas(cv, ncomp)
  -- Write boundary (see elro.write_begin): either this run's input is still current
  -- and the area's stale custom lines are cleared now, or the result is dropped with
  -- the canvas untouched. Nothing is ever half-written.
  if not elro.write_begin() then return end
  local members = {}
  for r, c in pairs(cv.comp) do
    members[c] = members[c] or {} ; members[c][#members[c] + 1] = r
  end
  local nwrote = 0
  local offx = 0
  for c = 1, ncomp do
    local mem = members[c]
    if mem then
      local minx, miny, maxx = math.huge, math.huge, -math.huge
      for _, r in ipairs(mem) do
        local p = cv.coord[r]
        if p[1] < minx then minx = p[1] end
        if p[1] > maxx then maxx = p[1] end
        if p[2] < miny then miny = p[2] end
      end
      for _, r in ipairs(mem) do
        local p = cv.coord[r]
        local x, y = p[1] - minx + offx, p[2] - miny
        if elro.is_maze_vertex(r) then
          -- No room to write to. Stash the position for the renderer instead --
          -- and stash it HERE, inside the per-component normalisation, or it
          -- would be in a different frame from every room around it.
          elro._mazePos = elro._mazePos or {}
          elro._mazePos[r] = { x, y }
        else
          setRoomCoordinates(r, x, y, 0)
          nwrote = nwrote + 1
        end
      end
      offx = offx + (maxx - minx) + 2
    end
  end
  elro.tr("    write_canvas wrote " .. nwrote .. " rooms")
end

-- plain flood (no scoring/overflow), used for the fragmented world-2 area
local function simple_flood(rooms, adj)
  local cv = new_canvas(adj)
  local ncomp = 0
  local seeds = {}
  for _, r in ipairs(rooms) do seeds[#seeds + 1] = r end
  table.sort(seeds, function(a, b) return a < b end)
  for _, s in ipairs(seeds) do
    if not cv.coord[s] then
      ncomp = ncomp + 1
      cv.coord[s] = {0, 0} ; cv.comp[s] = ncomp ; cv.occ[cv.key(ncomp, 0, 0)] = s
      local q, qh = {s}, 1
      while qh <= #q do
        elro.bg_tick("flood-w2")   -- world 2 can hold thousands of exiled rooms
        local u = q[qh] ; qh = qh + 1
        local p = cv.coord[u]
        for _, d in ipairs(elro.dir_order) do
          local v = adj[u][d]
          if v and not cv.coord[v] then
            local del = elro.delta[d]
            if cv.place(p[1], p[2], del[1], del[2], v, ncomp) then q[#q + 1] = v end
          end
        end
      end
    end
  end
  return cv, ncomp
end

local INF = 1e9

-- importance: peel leaves accumulating subtree size; 2-core scores INF, every
-- other room scores "rooms hanging off it" (how many vanish if it overflows).
local function score_rooms(rooms, adj)
  local deg, size, removed, peel = {}, {}, {}, {}
  for _, r in ipairs(rooms) do
    local n = 0 ; for _ in each_exit(adj[r]) do n = n + 1 end
    deg[r] = n ; size[r] = 0
  end
  local q, qt, qh = {}, 0, 1
  for _, r in ipairs(rooms) do if deg[r] <= 1 then qt = qt + 1 ; q[qt] = r end end
  while qh <= qt do
    local u = q[qh] ; qh = qh + 1
    if not removed[u] and deg[u] <= 1 then
      local w
      for _, d in ipairs(elro.dir_order) do
        local nb = adj[u][d]
        if nb and not removed[nb] then w = nb ; break end
      end
      removed[u] = true
      peel[#peel + 1] = { u, w }            -- w may be nil (last-peeled centre)
      if w then
        size[w] = size[w] + size[u] + 1
        deg[w] = deg[w] - 1
        if deg[w] <= 1 then qt = qt + 1 ; q[qt] = w end
      end
    end
  end
  local score = {}
  for _, r in ipairs(rooms) do score[r] = removed[r] and size[r] or INF end
  return score, peel, removed
end
-- deterministic two-phase layout: flood the 2-core, then attach non-core rooms
-- at their real peel-parent + exit direction. With allow_overflow (default), a
-- pure dead-end leaf that collides is exiled to world 2; with allow_overflow
-- false (mode "a") every room is kept in-area and collisions expand-place
-- instead -- truthful, no exile. Both paths share scoring + skeleton spacing.
function elro.layout_area(areaID, allow_overflow)
  if allow_overflow == nil then allow_overflow = true end
  local rooms, adj = area_adjacency(areaID)
  if #rooms == 0 then return end
  table.sort(rooms, function(a, b) return a < b end)        -- stable order
  local score, peel, removed = score_rooms(rooms, adj)

  local cv = new_canvas(adj)
  local coord, comp, occ, key = cv.coord, cv.comp, cv.occ, cv.key
  local overflow = {}
  local ncomp = 0
  -- binary spacing: the 2-core skeleton is placed delta*sp apart so loop edges
  -- have routing channels; everything peeled off (chains/leaves) hugs its parent
  -- at delta*1, tucked into those channels. sp=1 reproduces the old unit grid.
  local sp = elro.spacing or 1

  local function degree(r) local n = 0 ; for _ in each_exit(adj[r]) do n = n + 1 end ; return n end
  local function dir_uv(u, v)
    for _, d in ipairs(elro.dir_order) do if adj[u][d] == v then return d end end
  end

  -- phase 1: flood the 2-core (skeleton) with deterministic BFS + expand
  local core = {}
  for _, r in ipairs(rooms) do if not removed[r] then core[#core + 1] = r end end
  table.sort(core, function(a, b)
    local da, db = degree(a), degree(b)
    if da ~= db then return da > db end
    return a < b
  end)
  for _, s in ipairs(core) do
    if not coord[s] then
      ncomp = ncomp + 1
      coord[s] = {0, 0} ; comp[s] = ncomp ; occ[key(ncomp, 0, 0)] = s
      local cq, ch = {s}, 1
      while ch <= #cq do
        elro.bg_tick("flood-core") -- flood BFS: the whole engine for modes on/a/b
        local u = cq[ch] ; ch = ch + 1
        local p = coord[u]
        for _, d in ipairs(elro.dir_order) do
          local v = adj[u][d]
          if v and not removed[v] and not coord[v] then
            local del = elro.delta[d]
            if cv.place(p[1], p[2], del[1] * sp, del[2] * sp, v, ncomp) then cq[#cq + 1] = v end
          end
        end
      end
    end
  end

  -- phase 2: attach non-core rooms, core-side first (reverse peel order)
  for i = #peel, 1, -1 do
    elro.bg_tick("flood-peel")
    local u, w = peel[i][1], peel[i][2]
    if not coord[u] and not overflow[u] then
      if w and overflow[w] then
        overflow[u] = true                          -- parent overflowed: follow
      elseif w and coord[w] then
        local d = dir_uv(w, u)
        local del = d and elro.delta[d]
        local c = comp[w]
        if not del then
          overflow[u] = true                        -- no usable direction
        elseif score[u] > 0 then
          -- u has descendants (a chain link / bridge): overflowing it would
          -- orphan its whole subtree, so keep it connected and expand instead
          cv.place(coord[w][1], coord[w][2], del[1], del[2], u, c)
        else
          -- pure dead-end leaf (subtree size 0)
          local tx, ty = coord[w][1] + del[1], coord[w][2] + del[2]
          if occ[key(c, tx, ty)] or cv.on_edge(c, tx, ty) then
            if allow_overflow then
              overflow[u] = true            -- exile rather than disturb the map
            else
              cv.place(coord[w][1], coord[w][2], del[1], del[2], u, c)  -- keep it
            end
          else
            coord[u] = {tx, ty} ; comp[u] = c ; occ[key(c, tx, ty)] = u
          end
        end
      else
        ncomp = ncomp + 1                            -- tree centre / isolated: seed
        coord[u] = {0, 0} ; comp[u] = ncomp ; occ[key(ncomp, 0, 0)] = u
      end
    end
  end

  -- Write boundary hoisted above the whole commit: exiling overflow rooms to
  -- world 2 is a graph mutation, so a stale result must be dropped before it.
  -- write_begin is idempotent, so write_canvas's own call is a free re-check.
  if not elro.write_begin() then return end
  write_canvas(cv, ncomp)
  local w2 = elro.areaId("world 2")
  local exiled = false
  for r in pairs(overflow) do setRoomArea(r, w2) ; elro.cs_dirty(r, w2) ; exiled = true end
  if exiled then elro.cs_lists_dirty() end
  -- cross-area exit stubs (half-length arrows, maze-bound ones coloured): the compose
  -- path draws these in write_compose, but the flood path (mapengine flood, and every
  -- maze submap) skipped them -- draw them here too so boundary exits show + colour.
  elro.draw_area_stubs(coord)
end

-- the overflow area: fragmented by nature; just flood whatever landed here
function elro.layout_world2(areaID)
  local rooms, adj = area_adjacency(areaID)
  if #rooms == 0 then return end
  local cv, ncomp = simple_flood(rooms, adj)
  write_canvas(cv, ncomp)
end

-- Decompose a component into its 2-core plus classified pendant trees. The largest-area
-- face is the outer boundary; a pendant is INWARD if its attachment lies inside it.
function elro.core_classify(crooms, adj, space)
  space = space or 1
  local inset = {}
  for _, r in ipairs(crooms) do inset[r] = true end

  -- 2-core by leaf-peeling (axis edges only)
  local nb, deg = {}, {}
  for _, r in ipairs(crooms) do
    nb[r] = {}
    for d, v in each_exit(adj[r]) do
      local de = elro.delta[d]
      if inset[v] and de and (de[1] ~= 0 or de[2] ~= 0) then nb[r][#nb[r] + 1] = v end
    end
    deg[r] = #nb[r]
  end
  local peeled, pq, ph = {}, {}, 1
  for _, r in ipairs(crooms) do if deg[r] <= 1 then pq[#pq + 1] = r end end
  while ph <= #pq do
    elro.bg_tick("core-peel")
    local r = pq[ph] ; ph = ph + 1
    if not peeled[r] then
      peeled[r] = true
      for _, v in ipairs(nb[r]) do
        deg[v] = deg[v] - 1
        if deg[v] <= 1 and not peeled[v] then pq[#pq + 1] = v end
      end
    end
  end
  local S, nS = {}, 0
  for _, r in ipairs(crooms) do if not peeled[r] then S[r] = true ; nS = nS + 1 end end
  if nS == 0 then return { S = {}, nS = 0, inward = {}, trees = {} } end

  -- Decidable from the rotation system alone; the inward/outward split is discarded
  -- downstream, so Scoord stays nil and any future reader faults loudly.
  local faces = elro.faces(S, adj)
  elro.tr("  core_classify: faces=" .. #faces .. " -> outer/pip")
  local outerRooms = elro.pick_outer_face(faces, adj, true) or {}
  elro.tr("  core_classify: outer face by " .. (elro._outerPicked and "PICK (mapouter) (" or "ROTATION (") .. #outerRooms
    .. " rooms), no NS frame, no pip")
  local outerPoly = {}
  if Scoord then
    for _, r in ipairs(outerRooms) do if Scoord[r] then outerPoly[#outerPoly + 1] = Scoord[r] end end
  end
  local function pip(x, y)
    local inside, j = false, #outerPoly
    for i = 1, #outerPoly do
      local xi, yi = outerPoly[i][1], outerPoly[i][2]
      local xj, yj = outerPoly[j][1], outerPoly[j][2]
      if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi) then inside = not inside end
      j = i
    end
    return inside
  end

  -- Focal block = the biconnected block overlapping the outer face most. The rigid set is
  -- this block ALONE; nested inner blocks must not enter the piston solve.
  local outerSet = {}
  for _, r in ipairs(outerRooms) do outerSet[r] = true end
  elro.tr("  core_classify: outer=" .. #outerRooms .. " -> blocks_adj")
  local blocks = elro.blocks_adj(crooms, adj)
  elro.tr("  core_classify: blocks=" .. #blocks .. " -> focal + pendant trees")
  local Fset, nF, bestOv = {}, 0, -1
  for _, blk in ipairs(blocks) do
    local rs, n, ov = {}, 0, 0
    for _, e in ipairs(blk) do
      for i = 1, 2 do
        local nd = e[i]
        if not rs[nd] then rs[nd] = true ; n = n + 1 ; if outerSet[nd] then ov = ov + 1 end end
      end
    end
    if ov > bestOv then bestOv = ov ; Fset = rs ; nF = n end
  end

  -- everything in the component NOT in the focal block groups into pendant trees
  -- (acyclic tree pendants AND nested cyclic blocks). Classify each by attachment.
  local inward, trees, seen = {}, {}, {}
  for _, s in ipairs(crooms) do
    if not Fset[s] and not seen[s] then
      local comp, cq, ch = {}, { s }, 1 ; seen[s] = true
      while ch <= #cq do
        local u = cq[ch] ; ch = ch + 1 ; comp[#comp + 1] = u
        for _, v in each_exit(adj[u]) do
          if not Fset[v] and inset[v] and not seen[v] then seen[v] = true ; cq[#cq + 1] = v end
        end
      end
      local A, dir
      for _, b in ipairs(comp) do
        for d, v in each_exit(adj[b]) do
          local de = elro.delta[d]
          if Fset[v] and de and (de[1] ~= 0 or de[2] ~= 0) then A = v ; dir = d ; break end
        end
        if A then break end
      end
      local isIn = false
      -- no frame, so no pip: every tree reads OUTWARD (compose_spqr overwrites it anyway)
      if A and Scoord and Scoord[A] then
        -- dir is the pendant->core direction, so the pendant body sits at
        -- A - delta[dir]; sample TOWARD it (not past A) to test in/out.
        local de = elro.delta[dir]
        local px, py = Scoord[A][1] - de[1] * 0.5, Scoord[A][2] - de[2] * 0.5
        if py == math.floor(py) then py = py + 0.0001 end
        isIn = pip(px, py)
      end
      -- isBlock: the component contains a cycle (intra-comp edges >= rooms), i.e.
      -- a nested biconnected block, not an acyclic tree pendant.
      local cset, ce, eseen = {}, 0, {}
      for _, r in ipairs(comp) do cset[r] = true end
      for _, u in ipairs(comp) do
        for _, v in each_exit(adj[u]) do
          if cset[v] then
            local k = ekey(u, v)
            if not eseen[k] then eseen[k] = true ; ce = ce + 1 end
          end
        end
      end
      local isBlock = ce >= #comp
      if isIn then for _, r in ipairs(comp) do inward[r] = true end end
      trees[#trees + 1] = { rooms = comp, A = A, dir = dir, inward = isIn, n = #comp, isBlock = isBlock }
    end
  end
  elro.tr("  core_classify: DONE focal nF=" .. nF .. " trees=" .. #trees)
  return { S = Fset, nS = nF, Scoord = Scoord, outerRooms = outerRooms, inward = inward, trees = trees }
end

-- compose an area with SPQR-lite: per connected component, then bbox shelf-pack.
function elro.compose_spqr(areaID, space)
  local rooms, adj = area_adjacency(areaID)
  local a, b = elro.compose_spqr_adj(rooms, adj, space)
  -- stamp the vertical stats with the area they describe: a single global, and a
  -- relayout composes several canvases; vert_report compares the stamp
  if elro._vertStats then elro._vertStats.aid = areaID end
  return a, b
end

-- Classify each component's pendant trees, compose everything except the outward ones,
-- then slide those back on. Returns (coord, {}, adj). Offline safe.
function elro.orphans(areaID)
  areaID = areaID or (elro.current and getRoomArea(elro.current))
  if not areaID then return { error = "no current room; pass an area id" } end
  local rooms, adj = area_adjacency(areaID)
  local drop = elro.demotion_set(adj)
  -- the same shadow walk_branches builds: survivors only, then reverse-aware mirroring
  local sym = {}
  for r, nb in pairs(adj) do
    local t = {}
    for d, v in pairs(nb) do if not (drop[r] and drop[r][d]) then t[d] = v end end
    sym[r] = t
  end
  for u, nb in pairs(adj) do
    for d, v in pairs(nb) do
      if not (drop[u] and drop[u][d]) then
        local rev = elro.reverse[d]
        if rev and sym[v] then
          local back = false
          for _, x in pairs(sym[v]) do if x == u then back = true ; break end end
          if not back and sym[v][rev] == nil then sym[v][rev] = u end
        end
      end
    end
  end
  local out = {}
  for _, r in ipairs(rooms) do
    local n = 0 ; for _ in pairs(sym[r] or {}) do n = n + 1 end
    if n == 0 then
      local raw = 0 ; for _ in each_exit(adj[r]) do raw = raw + 1 end
      local x, y = getRoomCoordinates(r)
      out[#out + 1] = string.format("%d: %d raw compass edge(s), 0 survive demotion; at %s,%s",
                                    r, raw, tostring(x), tostring(y))
    end
  end
  if #out == 0 then out[1] = "no orphans in area " .. tostring(areaID) end
  return out
end

-- Orphans: a room whose every compass edge was demoted. Place it from its demoted exit
-- as a hint (no constraint); draw_residual marks the lie. Never refuse the last demotion.
function elro.place_orphans(rooms, adj, coord)
  local orphans = {}
  for _, r in ipairs(rooms) do
    if not coord[r] then orphans[#orphans + 1] = r end
  end
  if #orphans == 0 then return 0 end
  table.sort(orphans)                   -- deterministic: relayouts must not shuffle
  local occ = {}
  for r, p in pairs(coord) do occ[p[1] .. ":" .. p[2]] = r end
  -- who points AT me, so a room with only an inbound exit still gets an anchor
  local incoming = {}
  for u, nb in pairs(adj) do
    for d, v in pairs(nb) do
      local t = incoming[v] ; if not t then t = {} ; incoming[v] = t end
      t[#t + 1] = { u = u, d = d }
    end
  end
  for _, t in pairs(incoming) do             -- deterministic: pairs(adj) built these
    table.sort(t, function(a, b) if a.u ~= b.u then return a.u < b.u end return a.d < b.d end)
  end
  local placed = 0
  -- An orphan string is one object: lay the component out in its own coordinates, then find
  -- a free, not-walled-in translation; only then fall back to the per-room path.
  do
    local orphSet = {}
    for _, r in ipairs(orphans) do orphSet[r] = true end
    local minx, miny, maxx, maxy
    for _, p in pairs(coord) do
      if not minx or p[1] < minx then minx = p[1] end
      if not maxx or p[1] > maxx then maxx = p[1] end
      if not miny or p[2] < miny then miny = p[2] end
      if not maxy or p[2] > maxy then maxy = p[2] end
    end
    local comps, seenC = {}, {}
    for _, s in ipairs(orphans) do
      if not seenC[s] then
        local c, q, qh = { s }, { s }, 1 ; seenC[s] = true
        while qh <= #q do
          local u = q[qh] ; qh = qh + 1
          for _, d in ipairs(elro.dir_order) do
            local v = (adj[u] or {})[d]
            if v and orphSet[v] and not seenC[v] then seenC[v] = true ; q[#q + 1] = v ; c[#c + 1] = v end
          end
          for _, e in ipairs(incoming[u] or {}) do
            if orphSet[e.u] and not seenC[e.u] then
              seenC[e.u] = true ; q[#q + 1] = e.u ; c[#c + 1] = e.u
            end
          end
        end
        table.sort(c)
        if #c >= 2 then comps[#comps + 1] = c end
      end
    end
    table.sort(comps, function(a, b) return a[1] < b[1] end)
    for _, c in ipairs(comps) do
      -- 1. the component's own shape, from its own exits, at unit steps
      local pos, ok, occL = {}, true, {}
      pos[c[1]] = { 0, 0 } ; occL["0:0"] = c[1]
      local q, qh = { c[1] }, 1
      while qh <= #q do
        local u = q[qh] ; qh = qh + 1
        local pu = pos[u]
        local function put(v, x, y)
          if pos[v] then
            if pos[v][1] ~= x or pos[v][2] ~= y then ok = false end     -- inconsistent with itself
            return
          end
          local k = x .. ":" .. y
          if occL[k] then ok = false ; return end                      -- folds onto itself
          pos[v] = { x, y } ; occL[k] = v ; q[#q + 1] = v
        end
        for _, d in ipairs(elro.dir_order) do
          local v, de = (adj[u] or {})[d], elro.delta[d]
          if v and orphSet[v] and de and (de[1] ~= 0 or de[2] ~= 0) then
            put(v, pu[1] + de[1], pu[2] + de[2])
          end
        end
        for _, e in ipairs(incoming[u] or {}) do
          local de = elro.delta[e.d]
          if orphSet[e.u] and de and (de[1] ~= 0 or de[2] ~= 0) then
            put(e.u, pu[1] - de[1], pu[2] - de[2])       -- e.u -de-> u, so e.u sits one step back
          end
        end
      end
      for _, r in ipairs(c) do if not pos[r] then ok = false end end
      -- 2. where the placed geometry claims it should go -- inbound first, same rule as below
      local cands = {}
      if ok then
        for _, r in ipairs(c) do
          for _, d in ipairs(elro.dir_order) do
            local n, de = (adj[r] or {})[d], elro.delta[d]
            if n and coord[n] and de and (de[1] ~= 0 or de[2] ~= 0) and not orphSet[n] then
              cands[#cands + 1] = { n = n, d = d, inbound = false, r = r,
                                    tx = coord[n][1] - de[1] - pos[r][1],
                                    ty = coord[n][2] - de[2] - pos[r][2] }
            end
          end
          for _, e in ipairs(incoming[r] or {}) do
            local de = elro.delta[e.d]
            if coord[e.u] and de and (de[1] ~= 0 or de[2] ~= 0) and not orphSet[e.u] then
              cands[#cands + 1] = { n = e.u, d = e.d, inbound = true, r = r,
                                    tx = coord[e.u][1] + de[1] - pos[r][1],
                                    ty = coord[e.u][2] + de[2] - pos[r][2] }
            end
          end
        end
        table.sort(cands, function(a, b)
          if a.inbound ~= b.inbound then return a.inbound end
          if a.n ~= b.n then return a.n < b.n end
          if a.r ~= b.r then return a.r < b.r end
          return a.d < b.d
        end)
      end
      if ok and #cands > 0 then
        local function fits(tx, ty)
          for _, r in ipairs(c) do
            if occ[(pos[r][1] + tx) .. ":" .. (pos[r][2] + ty)] then return false end
          end
          return true
        end
        -- "not walled in": a cell that can reach past the occupied bounding box along
        -- a straight axis without crossing anything is outside the geometry
        local RAY = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
        local function open_air(tx, ty)
          for _, r in ipairs(c) do
            local x, y = pos[r][1] + tx, pos[r][2] + ty
            for _, dd in ipairs(RAY) do
              local cx, cy, clear = x, y, true
              while cx >= minx - 1 and cx <= maxx + 1 and cy >= miny - 1 and cy <= maxy + 1 do
                cx, cy = cx + dd[1], cy + dd[2]
                if occ[cx .. ":" .. cy] then clear = false ; break end
              end
              if clear then return true end
            end
          end
          return false
        end
        -- "outside" is a ladder: clear of the bbox beats open air beats merely free.
        -- Nearest-first from the claimed cell, so the demoted edges stay short.
        local function beyond(tx, ty)
          for _, r in ipairs(c) do
            local x, y = pos[r][1] + tx, pos[r][2] + ty
            if x >= minx and x <= maxx and y >= miny and y <= maxy then return false end
          end
          return true
        end
        -- within the first radius offering a legal spot, pick the least edge stretch,
        -- not the first found -- every claim is a demoted edge that will be drawn
        local function stretch(tx, ty)
          local s = 0
          for _, cd in ipairs(cands) do
            local dx = pos[cd.r][1] + tx - (pos[cd.r][1] + cd.tx)
            local dy = pos[cd.r][2] + ty - (pos[cd.r][2] + cd.ty)
            s = s + ((dx > 0 and dx or -dx) > (dy > 0 and dy or -dy)
                     and (dx > 0 and dx or -dx) or (dy > 0 and dy or -dy))
          end
          return s
        end
        local bx, by = cands[1].tx, cands[1].ty
        local tx, ty, air, loose
        for rad = 0, 60 do
          local bestS
          for dy = -rad, rad do
            for dx = -rad, rad do
              if math.max(math.abs(dx), math.abs(dy)) == rad then
                local ax, ay = bx + dx, by + dy
                if fits(ax, ay) then
                  if beyond(ax, ay) then
                    local s = stretch(ax, ay)
                    if not bestS or s < bestS then bestS, tx, ty = s, ax, ay end
                  else
                    if not air and open_air(ax, ay) then air = { ax, ay } end
                    if not loose then loose = { ax, ay } end
                  end
                end
              end
            end
          end
          if tx then break end
        end
        if not tx and air then tx, ty = air[1], air[2] end
        if not tx and loose then tx, ty = loose[1], loose[2] end
        if tx then
          for _, r in ipairs(c) do
            local x, y = pos[r][1] + tx, pos[r][2] + ty
            coord[r] = { x, y } ; occ[x .. ":" .. y] = r ; placed = placed + 1
          end
          elro.tr(string.format(
            "orphan string: %d rooms (%d..%d) had every edge to the map demoted -- placed as ONE"
            .. " piece in their own shape at %d,%d, anchored on %d%s",
            #c, c[1], c[#c], tx, ty, cands[1].n,
            beyond(tx, ty) and " (clear of the map)"
              or (open_air(tx, ty) and " (inside the span, but in open air)" or " (WALLED IN)")))
        end
      end
    end
  end
  local progress = true
  while progress do
    elro.bg_tick("orphans-place")    -- flag-driven; see the note on the blocks loop
    progress = false
    for _, r in ipairs(orphans) do
      if not coord[r] then
        -- candidate ideal cells, from BOTH directions of every exit that touches an
        -- already-placed room. `r -d-> n` says n sits at r+delta, so r wants n-delta;
        -- `n -d-> r` says r sits at n+delta.
        local cands, want = {}, nil
        for d, n in each_exit(adj[r]) do
          local de = elro.delta[d]
          if coord[n] and de and (de[1] ~= 0 or de[2] ~= 0) then
            cands[#cands + 1] = { x = coord[n][1] - de[1], y = coord[n][2] - de[2],
                                  n = n, d = d, inbound = false }
          end
        end
        for _, e in ipairs(incoming[r] or {}) do
          local de = elro.delta[e.d]
          if coord[e.u] and de and (de[1] ~= 0 or de[2] ~= 0) then
            cands[#cands + 1] = { x = coord[e.u][1] + de[1], y = coord[e.u][2] + de[2],
                                  n = e.u, d = e.d, inbound = true }
          end
        end
        if #cands > 0 then
          -- inbound claims outrank the orphan's own exit (another placed room's
          -- statement about where this one is). A free cell still wins over an
          -- occupied one regardless of direction.
          table.sort(cands, function(a, b)
            if a.inbound ~= b.inbound then return a.inbound end
            if a.n ~= b.n then return a.n < b.n end
            return a.d < b.d
          end)
          -- prefer the claim whose cell is actually free; only the genuinely
          -- impossible claim is left as a marked lie
          for _, c in ipairs(cands) do
            if not occ[c.x .. ":" .. c.y] then want = c ; break end
          end
          want = want or cands[1]
          -- nearest free cell, and nearest means to the ANCHOR, not the ideal (the
          -- ideal is nearly always taken); ties toward the ideal, so the orphan hugs
          -- the room it claims and the demoted edge stays short
          local ax, ay = coord[want.n][1], coord[want.n][2]
          local x, y = want.x, want.y
          if occ[x .. ":" .. y] then
            local best, bestKey
            for rad = 1, 40 do
              for dy = -rad, rad do
                for dx = -rad, rad do
                  if math.max(math.abs(dx), math.abs(dy)) == rad then
                    local cx, cy = want.x + dx, want.y + dy
                    if not occ[cx .. ":" .. cy] then
                      local da = math.max(math.abs(cx - ax), math.abs(cy - ay))
                      local di = math.max(math.abs(dx), math.abs(dy))
                      -- deterministic total order: anchor distance, then ideal
                      -- distance, then a fixed sweep so relayouts never differ
                      local key = da * 1e6 + di * 1e3 + (cy * 41 + cx) % 1000
                      if not bestKey or key < bestKey then bestKey, best = key, { cx, cy } end
                    end
                  end
                end
              end
              -- one ring past the first hit is enough: nothing further out can be
              -- closer to the anchor than something already found this ring
              if best and rad >= 2 then break end
            end
            if best then x, y = best[1], best[2] else x = nil end
          end
          if x then
            coord[r] = { x, y }
            occ[x .. ":" .. y] = r
            placed = placed + 1 ; progress = true
            elro.tr(string.format(
              "orphan: %d had every edge demoted -- placed at %d,%d from its %s exit to %d",
              r, x, y, want.d, want.n))
          end
        end
      end
    end
  end
  return placed
end


function elro.compose_spqr_adj(rooms, adj, space)
  space = space or 1
  if #rooms == 0 then return {}, {}, adj end
  elro._capLog = {}   -- pack_branches records here why each branch CAPed (mapcaps)
  elro._stepLog = {}  -- place_inward_pendants snapshots (mapstep), gated by elro.stepDebug
  -- the step-time toplist spans a whole relayout; reset at relayout enter, not here
  elro._stepTimeSeg = (elro._stepTimeSeg or 0) + 1
  elro._locCache = nil
  elro._stepCur = 0
  elro._stepPrevEnd = nil
  elro._stepKAcc, elro._stepNAcc = nil, nil
  elro._stepPrevIdle, elro._stepPrevKb = nil, nil
  elro._stepAcc = nil
  elro._guilloTracePending = nil
  elro._closeTracePending = nil
  elro._walkOrder = {} ; elro._walkPulls = {} ; elro._walkN = 0   -- frame-walk order/pulls (maporder)
  elro._repSeen = nil             -- pendant-repair once-per-edge memory, per relayout
  -- Connected components, reverse-aware: `adj` is directed, and a room reachable only by a
  -- one-way exit must not become its own component. This only ever merges components.
  -- Ticked per room / per popped node: this whole stretch sits between walk_adj's demotion
  -- trace and the first `classify` tick, and without these it was the longest un-yielding
  -- window in a relayout (165ms observed on a 4-map run).
  local incoming = {}
  for u, nb in pairs(adj) do
    elro.bg_tick("comp-incoming")
    for _, v in pairs(nb) do
      local t = incoming[v] ; if not t then t = {} ; incoming[v] = t end
      t[#t + 1] = u
    end
  end
  local comps, seen = {}, {}
  for _, s in ipairs(rooms) do
    if not seen[s] then
      local c, qq, qh = {}, { s }, 1 ; seen[s] = true
      while qh <= #qq do
        elro.bg_tick("comp-flood")
        local u = qq[qh] ; qh = qh + 1 ; c[#c + 1] = u
        for _, v in each_exit(adj[u]) do if not seen[v] then seen[v] = true ; qq[#qq + 1] = v end end
        for _, v in ipairs(incoming[u] or {}) do if not seen[v] then seen[v] = true ; qq[#qq + 1] = v end end
      end
      comps[#comps + 1] = c
    end
  end
  -- component of each room: the only input the vertical pack needs from here
  local compOf = {}
  for ci, c in ipairs(comps) do
    elro.bg_tick("comp-of")
    for _, r in ipairs(c) do compOf[r] = ci end
  end
  -- Classification solves the component's 2-core, so skip it for components too big to
  -- solve cheaply -- those fall through to pure compose (= the ns engine).
  local cap = elro.ns_cap or 1000

  -- Pre-pass: classify each component and compute its loop cuts once, so arteryAll is
  -- classified on the post-cut graph. perComp[i] = { adj, cc, picks }.
  -- Per-compose state is cleared here. `elro.minLen` is cleared only when this pre-pass
  -- owns it (`_minLenOwn`); a hand-asserted bound (MINLEN= harness) must survive.
  if elro._minLenOwn then elro.minLen = nil ; elro._minLenOwn = nil end
  elro._ffT = 0 ; elro.faceUse = nil
  elro.faceRings = nil     -- the rings behind faceUse, for `mapshared`
  elro._sqCalls = 0        -- closure squarify per-compose runaway guard (TUNE.sqCloseCap)
  elro._crossQuartets = nil
  elro._crossPairKeys = nil
  elro._faceChunks = nil
  local perComp = {}
  for ci, comp in ipairs(comps) do
    elro.bg_tick("classify")
    local info = { adj = adj }
    if #comp >= 4 and #comp <= cap then
      local cc = elro.core_classify(comp, adj, space)
      info.cc = cc
      elro.tr("compose_spqr_adj: classified, trees=" .. #(cc.trees or {}))
      if cc.nS and cc.nS > 0 then
      end
    end
    -- Shared-edge topology only (no sizing): `elro.faceUse` (edge -> bounded faces using it)
    -- feeds `eqw_shared_grow`'s lexicographic `sg` term in the closure pick key. Runs on the
    -- post-cut `walk_adj` shadow, the same graph the walk reads.
    if #comp >= 4 then
      local _, frep = elro.facefit(comp, elro.walk_adj(info.adj), true)
      if frep and frep.useN then
        local U = elro.faceUse or {} ; elro.faceUse = U
        for k, v in pairs(frep.useN) do if v > (U[k] or 0) then U[k] = v end end
      end
      -- the rings behind those counts, for `mapshared`
      if frep and frep.rings then
        local R = elro.faceRings or {} ; elro.faceRings = R
        for _, g in ipairs(frep.rings) do R[#R + 1] = g end
      end
    end
    -- the crossing-cost want-list needs the full facefit; measurement only, nothing else published
    if TUNE.crossCostTau > 0 and #comp >= 4 then
      elro.facefit(comp, elro.walk_adj(info.adj))
    end
    perComp[ci] = info
  end

  -- arteryAll on the post-cut graph; also capture the per-room class map for mapclassify.
  local adjPost = adj
  local arteryAll
  local arteryHints                -- { roomBlock } threaded to the live-LCA junction layer
  do
    local rigid, blockSets = {}, {}
    for _, b in ipairs(elro.blocks_adj(rooms, adjPost)) do
      if #b > 1 then
        local set, n = {}, 0
        for _, e in ipairs(b) do
          for i = 1, 2 do if not set[e[i]] then set[e[i]] = true ; n = n + 1 ; rigid[e[i]] = true end end
        end
        blockSets[#blockSets + 1] = { set = set, n = n }
      end
    end
    arteryAll = elro.classify_artery(rooms, adjPost, rigid)
    -- brand the 2-core rooms as artery so the skeleton pass lays the core first
    for r in pairs(rigid) do arteryAll[r] = true end
    -- `roomBlock` (room -> block id) lets the live-LCA trace treat each rigid block as one node
    do
      local roomBlock = {}
      for bi, b in ipairs(blockSets) do
        for r in pairs(b.set) do roomBlock[r] = bi end
      end
      arteryHints = { roomBlock = roomBlock }
    end
    -- class map: block/artery/outward base, biggest block -> main, inward overrides
    -- block, cut endpoints on top.
    local cm = {}
    for _, r in ipairs(rooms) do
      cm[r] = rigid[r] and "block" or (arteryAll[r] and "artery" or "outward")
    end
    local mainSet, mainN = nil, -1
    for _, b in ipairs(blockSets) do if b.n > mainN then mainN = b.n ; mainSet = b.set end end
    if mainSet then for r in pairs(mainSet) do if cm[r] == "block" then cm[r] = "main" end end end
    for _, info in ipairs(perComp) do
      if info.cc and info.cc.inward then
        for r in pairs(info.cc.inward) do if cm[r] then cm[r] = "inward" end end
      end
    end
    elro._classMap = cm
  end

  local gcoord = {}
  local lcs = {}    -- per-component local coordinates, shelf-packed after the loop
  local PAD = math.max(2, (elro.spacing or 1) * 2)
  local shelfX, shelfY, shelfH = 0, 0, 0
  elro._vertLinks = nil   -- the vertical side table for the renderer
  elro.tr("compose_spqr_adj: " .. #comps .. " component(s), cap=" .. cap)
  for ci, comp in ipairs(comps) do
    elro.bg_tick("component")
    local info = perComp[ci]
    local adj = info.adj
    local cc = info.cc
    -- per-component stitch toolbox; only this component's walk_branches may repopulate it
    elro._stitchTools = nil
    elro.tr("compose_spqr_adj: comp size=" .. #comp .. (#comp <= cap and " (classify)" or " (TOO BIG -> compose only)"))
    local unitRooms = {}
    local outward, inward = {}, {}
    if cc then
      for _, t in ipairs(cc.trees or {}) do
        if t.A and not t.inward then
          for _, r in ipairs(t.rooms) do if not unitRooms[r] then outward[r] = true end end
        elseif t.inward then
          for _, r in ipairs(t.rooms) do inward[r] = true end
        end
      end
    end
    -- Every component takes the "seed one room, walk everything else" path: every block room
    -- is placed by the branch walk and loops are closed by the place_room back-edge reconcile.
    inward = {}
    local seed
    -- Seed priority: contested outer face, then widest forced wire pair, then a topo crossing
    -- quartet, then lowest id. Stock Lua 5.1 cannot yield across pcall, so `elro._noYield`
    -- is raised around the provers.
    local inComp = {} ; for _, r in ipairs(comp) do inComp[r] = true end
    if cc and cc.outerRooms then
      elro._noYield = true
      local okT0, T0 = pcall(elro.topo_cross, adj)
      elro._noYield = nil
      if okT0 and T0 and ((T0.outerClaims or 0) > 1 or elro._outerPicked) then
        for _, r in ipairs(cc.outerRooms) do
          if inComp[r] and (not seed or r < seed) then seed = r end
        end
        if seed then
          elro._lastSeed = seed
          elro.tr(string.format("compose_spqr: seeding the walk on %d -- a room of the OUTER FACE"
            .. " (%s), so the boundary is laid before what it contains", seed,
            elro._outerPicked and "picked by mapouter"
              or string.format("genus 0 but %d face(s) claim it", T0.outerClaims)))
        end
      end
    end
    if not seed then
    elro._noYield = true
    local okW, Wc = pcall(elro.wire_cross, adj)
    elro._noYield = nil
    if okW and Wc then
      -- the pair spanning the most structure (|vm| + |hm|); tie-break on lowest S
      local bestSpan
      for _, p in ipairs(Wc.wires) do
        if p.S and inComp[p.S] then
          local span = #p.vm + #p.hm
          if not bestSpan or span > bestSpan or (span == bestSpan and p.S < seed) then
            bestSpan, seed = span, p.S
          end
        end
      end
      if seed then
        elro._lastSeed = seed
        elro.tr(string.format("compose_spqr: seeding the walk on %d -- the SOUTH end of the"
          .. " widest forced wire pair (%d rooms), so the walk climbs toward the crossing",
          seed, bestSpan))
      end
    end
    end
    -- only fall through to the topo quartet when the wire proof gave no root
    local ok, T = false, nil
    if not seed then
      elro._noYield = true
      ok, T = pcall(elro.topo_cross, adj)
      elro._noYield = nil
    end
    if ok and T then
      -- chain quartets first (the figure-eight case), then bridge quartets
      for _, wantChain in ipairs({ true, false }) do
        if not seed then
          for _, q in ipairs(T.quartet or {}) do
            if (q.chain == true) == wantChain then
              for i = 1, 4 do
                local r = q[i]
                if inComp[r] and (not seed or r < seed) then seed = r end
              end
            end
          end
        end
      end
      if seed then
        elro.tr(string.format("compose_spqr: seeding the walk on %d -- a room of the"
          .. " constructed crossing, so the 8 is laid outward from it", seed))
      end
    end
    if not seed then
      for _, r in ipairs(comp) do if not seed or r < seed then seed = r end end
    end
    if seed then
      for _, r in ipairs(comp) do
        if r ~= seed and not unitRooms[r] then outward[r] = true end
      end
      -- the seed must not carry an outward/inward tag or the walk gets no root
      outward[seed] = nil ; inward[seed] = nil
    end
    local composeRooms, cset = {}, {}
    for _, r in ipairs(comp) do
      if not unitRooms[r] and not outward[r] and not inward[r] then
        composeRooms[#composeRooms + 1] = r ; cset[r] = true
      end
    end
    -- The composed mesh is exactly the seed, at the origin. If more than one room ever lands
    -- here, the surplus is handed to the walk rather than stacked at the origin.
    local lc = {}
    if #composeRooms > 0 then lc[composeRooms[1]] = { 0, 0 } end
    for i = 2, #composeRooms do
      local r = composeRooms[i]
      cset[r] = nil ; outward[r] = true
      elro.tr("  compose_spqr: mesh room " .. r .. " beyond the seed -> handed to the walk")
    end
    elro.tr("  compose_spqr: mesh seeded (" .. #composeRooms .. " room(s))")
    elro.step_snap(lc, "mesh composed (" .. #composeRooms .. " rooms)")
    -- Outward and inward rooms are both walked room-by-room onto the live mesh; the walk's
    -- repel field and guillotine levers expand a containing face as needed.
    local walkAll = {}
    for r in pairs(outward) do walkAll[r] = true end
    for r in pairs(inward)  do walkAll[r] = true end
    if next(walkAll) then
      elro.tr("branch_walk: walkAll=" .. elro.tcount(walkAll) .. " -> outward_units")
      -- no rigid units: every room is walked individually
      local units, walkSet = {}, walkAll
      elro._faceChunks = info.faceChunks
      elro.tr("branch_walk: units=" .. #units .. " walkSet=" .. elro.tcount(walkSet) .. " -> walk_branches")
      local _, leftover = elro.walk_branches(lc, adj, walkSet, space, walkSet, units, arteryAll, arteryHints, inward)
      elro.tr("branch_walk: walk_branches DONE")
      if leftover and next(leftover) then
        elro.slide_pendants(lc, adj, leftover, space)
        elro.step_snap(lc, "walk leftovers slid (" .. elro.tcount(leftover) .. " rooms)")
      end
    end
    -- the shelf pack is deferred to the foot of this function: a docked pair must be packed as one bbox
    lcs[ci] = lc
    elro.tr("  compose_spqr: comp size=" .. #comp .. " DONE (laid out)")
  end

  -- Assemble, then shelf-pack. With no groups every component is its own group.
  local groups
  if elro.vertPack ~= false then     -- `~= false`: the knob defaults on
    local links
    groups, links = elro.vert_assemble(comps, lcs, adj, compOf)
    elro._vertLinks = links   -- read only by elro.draw_vertical; `adj` never sees these
  end
  if not groups then
    groups = {}
    for ci = 1, #comps do groups[ci] = { coord = lcs[ci] } end
  end
  for _, g in ipairs(groups) do
    -- bbox of the FULL group, then shelf-pack it
    local lc = g.coord
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, p in pairs(lc) do
      if p[1] < minx then minx = p[1] end ; if p[1] > maxx then maxx = p[1] end
      if p[2] < miny then miny = p[2] end ; if p[2] > maxy then maxy = p[2] end
    end
    local gw, gh = maxx - minx, maxy - miny
    if shelfX > 0 and shelfX + gw > 60 then
      shelfX = 0 ; shelfY = shelfY + shelfH + PAD ; shelfH = 0
    end
    local dx, dy = shelfX - minx, shelfY - miny
    for r, p in pairs(lc) do gcoord[r] = { p[1] + dx, p[2] + dy } end
    shelfX = shelfX + gw + 1 + PAD
    if gh > shelfH then shelfH = gh end
  end
  elro.step_snap(gcoord, string.format("compose: %d component(s) shelf-packed as %d group(s)",
    #comps, #groups))
  -- last: rooms demotion isolated, placed after shelf-packing so every cell is visible
  local norph = elro.place_orphans(rooms, adj, gcoord)
  if norph > 0 then
    elro.tr(string.format("compose: placed %d orphaned room(s) the walk could not reach", norph))
  end
  return gcoord, adj
end

-- Place rooms in `toPlace` by BFS from placed neighbours, sliding each along its entry
-- compass edge until it clears occupied cells. Occupancy is edge-aware. Mutates+returns coord.
function elro.slide_pendants(coord, adj, toPlace, space)
  local occ = {}
  local function key(x, y) return x .. ":" .. y end
  local function mark_cell(x, y) occ[key(x, y)] = true end
  local function mark_seg(x1, y1, x2, y2) return seg(x1, y1, x2, y2, mark_cell) end
  -- exact edge list: the raster marks only endpoints of a stretched non-45 diagonal
  local pedges = {}
  local function add_pedge(ax, ay, bx, by) pedges[#pedges + 1] = { ax, ay, bx, by } end
  local function on_pedge(x, y)
    for _, e in ipairs(pedges) do
      if ori(e[1], e[2], e[3], e[4], x, y) == 0
         and x >= math.min(e[1], e[3]) and x <= math.max(e[1], e[3])
         and y >= math.min(e[2], e[4]) and y <= math.max(e[2], e[4])
         and not (x == e[1] and y == e[2]) and not (x == e[3] and y == e[4]) then
        return true
      end
    end
    return false
  end
  -- reserve the already-composed structure (cells + edges among placed rooms)
  local q, qh, queued = {}, 1, {}
  for r, p in pairs(coord) do
    if not toPlace[r] then
      occ[key(p[1], p[2])] = true
      for _, v in each_exit(adj[r]) do
        if coord[v] and not toPlace[v] then
          mark_seg(p[1], p[2], coord[v][1], coord[v][2])
          add_pedge(p[1], p[2], coord[v][1], coord[v][2])
        end
      end
    end
  end
  for r in pairs(coord) do if not toPlace[r] then q[#q + 1] = r ; queued[r] = true end end
  -- BFS outward into the pendants, sliding along the entry direction
  while qh <= #q do
    elro.bg_tick("slide")
    local u = q[qh] ; qh = qh + 1
    for d, v in each_exit(adj[u]) do
      local del = elro.delta[d]
      if toPlace[v] and not coord[v] and del and (del[1] ~= 0 or del[2] ~= 0) then
        local cx, cy = coord[u][1] + del[1], coord[u][2] + del[2]
        local tries = 0
        while (occ[key(cx, cy)] or on_pedge(cx, cy)) and tries < 500 do
          cx = cx + del[1] ; cy = cy + del[2] ; tries = tries + 1
        end
        coord[v] = { cx, cy } ; occ[key(cx, cy)] = true
        mark_seg(cx, cy, coord[u][1], coord[u][2])
        add_pedge(cx, cy, coord[u][1], coord[u][2])
        if not queued[v] then queued[v] = true ; q[#q + 1] = v end
      end
    end
  end
  return coord
end


-- Shared defect scanner over a coordinate set. Returns cnt, nOv, nRoe, nX. The counts
-- are a contract every gate compares on; test_count_defects.lua checks them.
function elro.count_defects(coord, placed, pedges)
  elro.bg_tick("count-defects")
  local floor = math.floor
  local B = elro.crossBucket or 4
  local cnt = 0
  local nOv, nRoe, nX = 0, 0, 0
  -- cell census, numeric key: `cen[k]` is the first room in a cell, `cenX[k]` the rest.
  -- x * 1000003 + y assumes integer coordinates with |y| < 500000.
  local cen, cenX = {}, nil
  for rr in pairs(placed) do
    local p = coord[rr]
    if p then
      local k = p[1] * 1000003 + p[2]
      local f = cen[k]
      if f == nil then cen[k] = rr
      else
        cnt = cnt + 1 ; nOv = nOv + 1
        cenX = cenX or {}
        local x = cenX[k] ; if x then x[#x + 1] = rr else cenX[k] = { rr } end
      end
    end
  end
  -- endpoints + bbox into flat arrays, and the edge bucket index for the crossing test
  local n = #pedges
  local AX, AY, PX, PY = {}, {}, {}, {}
  local XLO, XHI, YLO, YHI = {}, {}, {}, {}
  local edgeIdx = {}
  for i = 1, n do
    local e = pedges[i] ; local a, b = coord[e.u], coord[e.v]
    if a and b then
      local ax, ay, bx, by = a[1], a[2], b[1], b[2]
      AX[i], AY[i], PX[i], PY[i] = ax, ay, bx, by
      local xlo = (ax < bx) and ax or bx ; local xhi = (ax > bx) and ax or bx
      local ylo = (ay < by) and ay or by ; local yhi = (ay > by) and ay or by
      XLO[i], XHI[i], YLO[i], YHI[i] = xlo, xhi, ylo, yhi
      for gx = floor(xlo / B), floor(xhi / B) do
        for gy = floor(ylo / B), floor(yhi / B) do
          local k = gx * 1000003 + gy
          local bk = edgeIdx[k] ; if bk then bk[#bk + 1] = i else edgeIdx[k] = { i } end
        end
      end
    end
  end
  -- room-on-edge by walking the segment's lattice points (gcd(|dx|,|dy|) + 1 of them)
  for i = 1, n do
    local ax = AX[i]
    if ax then
      local e = pedges[i] ; local u, v = e.u, e.v
      local ay, bx, by = AY[i], PX[i], PY[i]
      local dx, dy = bx - ax, by - ay
      local g                                  -- gcd(|dx|,|dy|); 0 only for a zero-length edge
      do local p, q = (dx < 0) and -dx or dx, (dy < 0) and -dy or dy
         while q ~= 0 do p, q = q, p % q end
         g = p
      end
      local sx, sy, steps
      if g == 0 then sx, sy, steps = 0, 0, 0 else sx, sy, steps = dx / g, dy / g, g end
      local px, py = ax, ay
      for _ = 0, steps do
        local k = px * 1000003 + py
        local f = cen[k]
        if f ~= nil then
          if f ~= u and f ~= v then cnt = cnt + 1 ; nRoe = nRoe + 1 end
          if cenX then
            local x = cenX[k]
            if x then for m = 1, #x do local rr = x[m]
              if rr ~= u and rr ~= v then cnt = cnt + 1 ; nRoe = nRoe + 1 end
            end end
          end
        end
        px, py = px + sx, py + sy
      end
    end
  end
  -- Edge-vs-nearby-edge crossing test (j > i dedup), bucketed by bbox. `seen` is stamped with i
  -- and reused; the closed-bbox overlap reject cannot hide a crossing; d3/d4 are only computed
  -- when d1/d2 already straddle.
  local seen = {}
  for i = 1, n do
    local ax = AX[i]
    if ax then
      local ay, bx, by = AY[i], PX[i], PY[i]
      local e1 = pedges[i] ; local u1, v1 = e1.u, e1.v
      local ixlo, ixhi, iylo, iyhi = XLO[i], XHI[i], YLO[i], YHI[i]
      local abx, aby = bx - ax, by - ay
      for gx = floor(ixlo / B), floor(ixhi / B) do
        for gy = floor(iylo / B), floor(iyhi / B) do
          local bk = edgeIdx[gx * 1000003 + gy]
          if bk then
            for m = 1, #bk do
              local j = bk[m]
              if j > i and seen[j] ~= i then
                seen[j] = i
                if XLO[j] <= ixhi and XHI[j] >= ixlo and YLO[j] <= iyhi and YHI[j] >= iylo then
                  local e2 = pedges[j]
                  if u1 ~= e2.u and u1 ~= e2.v and v1 ~= e2.u and v1 ~= e2.v then
                    local cx, cy = AX[j], AY[j]
                    local cdx, cdy = PX[j] - cx, PY[j] - cy
                    local d1 = cdx * (ay - cy) - cdy * (ax - cx)
                    local d2 = cdx * (by - cy) - cdy * (bx - cx)
                    if (d1 > 0) ~= (d2 > 0) then
                      local d3 = abx * (cy - ay) - aby * (cx - ax)
                      local d4 = abx * (PY[j] - ay) - aby * (PX[j] - ax)
                      if (d3 > 0) ~= (d4 > 0) then cnt = cnt + 1 ; nX = nX + 1 end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return cnt, nOv, nRoe, nX
end
-- Severity-ordered defect comparison: collision > room-on-edge ~ edge-on-room > crossing.
-- Lexicographic on the vector; returns true when A is strictly worse than B.
function elro.defects_worse(aOv, aRoe, aX, bOv, bRoe, bX)
  if aOv ~= bOv then return aOv > bOv end
  if aRoe ~= bRoe then return aRoe > bRoe end
  return aX > bX
end
-- Gate form of the comparison. `elro.sevGate` stays off by default: a strictly-non-worsening
-- greedy gate cannot pass through a temporarily worse state, so the stricter comparator makes
-- the descent more myopic. The real fix is to score candidates instead of accepting the first.
function elro.state_worse(aTot, aOv, aRoe, aX, bTot, bOv, bRoe, bX)
  if not elro.sevGate then return aTot > bTot end
  return elro.defects_worse(aOv, aRoe, aX, bOv, bRoe, bX)
end
-- Optional count_defects timing (elro.timeGuillo). Installed once, right after the definition,
-- so re-sourcing the file cannot nest wrappers.
do
  local core = elro.count_defects
  elro.count_defects = function(...)
    if not elro.timeGuillo then return core(...) end
    local t = CLK() ; elro._cdN = (elro._cdN or 0) + 1
    local a, b, c, d = core(...)
    elro._cdT = (elro._cdT or 0) + (CLK() - t)
    return a, b, c, d
  end
end

function elro.write_compose(coord)
  -- the write boundary; see elro.write_begin
  if not elro.write_begin() then return end
  local minx, miny = math.huge, math.huge
  for _, p in pairs(coord) do
    if p[1] < minx then minx = p[1] end
    if p[2] < miny then miny = p[2] end
  end
  -- A maze vertex has no room to write to: stash its solved position for the
  -- renderer, in the SAME normalised frame as the rooms around it. This is the
  -- eqw write path; write_canvas is the flood one and does the same.
  for r, p in pairs(coord) do
    if elro.is_maze_vertex(r) then
      elro._mazePos = elro._mazePos or {}
      elro._mazePos[r] = { p[1] - minx, p[2] - miny }
    else
      setRoomCoordinates(r, p[1] - minx, p[2] - miny, 0)
    end
  end
  elro.draw_area_stubs(coord)   -- blue cross-area stubs (coords now live)
  elro.draw_demoted(coord)      -- magenta corridors for edges the equations dropped
  elro.draw_vertical_map(coord) -- ...and teal ones for the up/down links the pack honoured
  elro.draw_residual(coord)     -- ...and red for the ones it kept and drew off-axis
  -- last: terrain loses the highlight arbitration to occluded / maze
  elro.terrain_repaint(coord)
end
