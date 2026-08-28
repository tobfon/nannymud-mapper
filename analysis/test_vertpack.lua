-- Offline coverage for the VERTICAL-AWARE COMPONENT PACK (elro.vertPack) --
-- elro.vert_assemble and the ray search behind it.
--
--   luajit analysis/test_vertpack.lua
--
-- ⭐ WHY THIS DRIVES vert_assemble DIRECTLY rather than a whole relayout. The pack is
-- the LAST thing compose_spqr_adj does: every component arrives already laid out in its
-- own local coordinates, and all the pack decides is where each one is PUT. That makes
-- it a pure function of (comps, local coords, adj, component-of-room) -- so the fixtures
-- below hand it hand-built geometry and assert the answer exactly, instead of laying out
-- a map and hoping the interesting case survives to the end.
--
-- ⚠⚠ AND THE CORPUS DUMPS DO EXERCISE THIS -- which corrects the note that used to sit
-- here and in layout.lua. `analysis/*.txt` are written by elro.dump_file from
-- getRoomExits, NOT from `adj`, so they carry their up/down exits: world_live has 64
-- vertical darts and 33 forest links, soulfly 12, mael_live 9, kadagar 4. Those runs are
-- the SIZE check (`vertPack=true` vs `-` in one process); this file is the BEHAVIOUR
-- check, and it exists because no dump happens to contain a three-staircase ring or a
-- component boxed in tightly enough to force a decline.
--
-- The properties asserted, and each is load-bearing somewhere in the design:
--   * a docked child sits at EXACTLY one of the four canonical offsets, scaled
--   * UP = +y ALWAYS, and `down` is the exact negation -- so which way the link was
--     walked never changes the picture
--   * NO CANDIDATE IS A MULTIPLE OF 45 DEGREES, which is what makes a vertical
--     unmistakable for a compass exit without relying on colour
--   * a TREE places every edge exactly (a shaft five deep is still exact at the top)
--   * a SHAFT is ONE STRAIGHT LADDER: every dock carries its parent's ray, so `up up up
--     up` is collinear instead of zigzagging (and the carry holds the RAY, not the
--     scale -- an obstructed rung steps out along the same line)
--   * the STEEP ratio (1:2) outranks the shallow one AND outranks compaction
--   * an over-determined CYCLE link is never honoured
--   * a blocked dock DECLINES, and a declined component is left EXACTLY where it was
--     -- the monotonicity the whole feature rests on
--   * no honoured dock puts two rooms in one cell, and no room of the docked floor is
--     left TOUCHING a room of the mass it has no exit to (the cathbad case)
--   * the RENDERER's three rungs: a straight centre-to-centre line for an honoured link,
--     the single-bend shape for one the packer declined but whose run is clear, and
--     NOTHING -- not even a claimed direction slot -- when the run is blocked
--   * the BRIDGE PISTON (`elro.vertPiston`, case 19): stretching ONE bridge lands a
--     near-miss link and CARRIES every component docked beyond it; a bridge is never
--     sheared, never shrunk past adjacency, and never a vertical; a correction with no
--     bridge along its axis is refused without a trial; and the defect gate reverts a
--     piston that would collide. ⚠ This is the ONLY coverage the piston has -- the
--     corpus dumps exercise its refusals and cannot exercise an acceptance.

package.path = "analysis/?.lua;" .. package.path
dofile("analysis/engine_load.lua")

local fail, ntest = 0, 0
local function ok(cond, what)
  ntest = ntest + 1
  if not cond then fail = fail + 1 ; print("  FAIL: " .. what) end
end
local function eq(got, want, what)
  ntest = ntest + 1
  if got ~= want then
    fail = fail + 1
    print(string.format("  FAIL: %s -- got %s want %s", what, tostring(got), tostring(want)))
  end
end

-- ---- fixture helpers ------------------------------------------------------
local AID
local function room(id) addRoom(id) ; setRoomArea(id, AID) end
local function link(a, b, d) setExit(a, b, d) ; setExit(b, a, elro.reverse[d]) end
local function stair(a, b) setExit(a, b, "up") ; setExit(b, a, "down") end

-- Build a scenario: `specs` is a list of components, each { rooms = {id...},
-- at = { [id] = {x,y} } }. Returns everything vert_assemble wants.
local function scene(specs)
  local comps, lcs, adj, compOf = {}, {}, {}, {}
  for ci, s in ipairs(specs) do
    comps[ci] = s.rooms ; lcs[ci] = {}
    for _, r in ipairs(s.rooms) do
      compOf[r] = ci
      lcs[ci][r] = { s.at[r][1], s.at[r][2] }
      adj[r] = {}
    end
  end
  -- the compass adjacency, read straight off the fake Mudlet map so the fixture cannot
  -- drift from the exits the classifier sees
  for r in pairs(compOf) do
    for dn, dest in pairs(getRoomExits(r) or {}) do
      local d = elro.norm(dn)
      local de = elro.delta[d]
      if de and (de[1] ~= 0 or de[2] ~= 0) and compOf[dest] then adj[r][d] = dest end
    end
  end
  return comps, lcs, adj, compOf
end

-- the offset an honoured link ended up using, in group coordinates
local function offset(G, lo, hi)
  return G.coord[hi][1] - G.coord[lo][1], G.coord[hi][2] - G.coord[lo][2]
end
local CANON = { ["2:1"] = true, ["-2:1"] = true, ["1:2"] = true, ["-1:2"] = true }
-- is (dx,dy) k*(one of the four canonical offsets), for some k >= 1?
-- ⚠ SIGN-AGNOSTIC, and it has to be: `down` is the exact NEGATION of `up`, so a downward
-- link legitimately reads (+2,-1). Normalising to +y first tests the ANGLE, which is what
-- "canonical" means; the semantic y sign is a separate assertion at each call site, and
-- keeping the two apart is the point. (A first version only knew the +y forms and failed
-- the one downward link in the dannoc fixture -- the helper was wrong, not the engine.)
local function canonical(dx, dy)
  if dy < 0 then dx, dy = -dx, -dy end
  for k = 1, 20 do
    if dx % k == 0 and dy % k == 0 and CANON[(dx / k) .. ":" .. (dy / k)] then return k end
  end
  return nil
end
local function no_overlap(G, what)
  local seen = {}
  for r, p in pairs(G.coord) do
    local key = p[1] .. ":" .. p[2]
    ok(not seen[key], what .. ": " .. tostring(r) .. " and " .. tostring(seen[key])
       .. " both at " .. key)
    seen[key] = r
  end
end

-- ---- 1. ONE STAIR, TWO COMPONENTS -- the exactly-satisfiable case ---------
-- The whole argument for the forest rule: a translation has two free parameters and
-- ONE vertical link pins both, so this must land on a canonical offset, every time.
do
  reset_map() ; AID = addAreaName("one")
  room(1) ; room(2) ; link(1, 2, "east")
  room(10) ; room(11) ; link(10, 11, "east")
  stair(1, 10)                                   -- 1 up-> 10, so 10 is the UPPER floor
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = { 1, 2 },   at = { [1] = { 0, 0 }, [2] = { 1, 0 } } },
    { rooms = { 10, 11 }, at = { [10] = { 0, 0 }, [11] = { 1, 0 } } },
  })
  local groups, links = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(#groups, 1, "one stair folds two components into ONE group")
  local G = groups[1]
  local dx, dy = offset(G, 1, 10)
  ok(canonical(dx, dy), string.format("the dock is a canonical offset (got %d,%d)", dx, dy))
  eq(dy > 0, true, "UP = +y: the upper floor is drawn higher on screen")
  ok(dx ~= 0 and dy ~= 0 and math.abs(dx) ~= math.abs(dy),
     "the offset is not a multiple of 45 degrees -- unmistakable for a compass exit")
  eq(canonical(dx, dy), 1, "an unobstructed dock takes scale 1")
  no_overlap(G, "one stair")
  eq(elro._vertStats.honoured, 1, "stats: one honoured")
  eq(elro._vertStats.declined, 0, "stats: none declined")
  local nf = 0
  for _, p in ipairs(links) do if p.cls == "forest" then nf = nf + 1 ; eq(p.honoured, true, "the forest link is marked honoured") end end
  eq(nf, 1, "exactly one forest link")
end

-- ---- 2. DOWN = -UP, and it does not matter which way the link was walked --
-- ⭐ THE SELF-CONSISTENCY THE WHOLE OFFSET SCHEME RESTS ON. `A up-> B` puts B at
-- A+(2,1); reading the same link as `B down-> A` puts A at B-(2,1). Same answer.
-- Two scenes that differ ONLY in which dart the classifier meets first must agree.
local function walked(first_up)
  reset_map() ; AID = addAreaName("dir")
  room(1) ; room(2) ; link(1, 2, "east")
  room(10) ; room(11) ; link(10, 11, "east")
  if first_up then setExit(1, 10, "up") else setExit(10, 1, "down") end
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = { 1, 2 },   at = { [1] = { 0, 0 }, [2] = { 1, 0 } } },
    { rooms = { 10, 11 }, at = { [10] = { 0, 0 }, [11] = { 1, 0 } } },
  })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  local dx, dy = offset(groups[1], 1, 10)
  return dx, dy
end
do
  local ax, ay = walked(true)
  local bx, by = walked(false)
  eq(ax .. "," .. ay, bx .. "," .. by,
     "`1 up-> 10` and `10 down-> 1` place the floors identically")
  eq(ay > 0, true, "...and the upper floor is above in both readings")
end

-- ---- 3. THE UPPER FLOOR IS THE CHILD, OR THE PARENT ----------------------
-- The child can hold EITHER end of the link. If it holds the lower end the offset is
-- the exact negation -- the y sign is a fact about the STAIR, never about which
-- component happened to be placed first.
do
  reset_map() ; AID = addAreaName("down")
  room(1) ; room(2) ; room(3) ; link(1, 2, "east") ; link(2, 3, "east")
  room(10) ; room(11) ; link(10, 11, "east")
  stair(10, 1)                                   -- 10 up-> 1, so 1 is the UPPER floor
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    -- component 1 is the LARGER, so it roots the tree and 10/11 docks onto it
    { rooms = { 1, 2, 3 }, at = { [1] = { 0, 0 }, [2] = { 1, 0 }, [3] = { 2, 0 } } },
    { rooms = { 10, 11 },  at = { [10] = { 0, 0 }, [11] = { 1, 0 } } },
  })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(#groups, 1, "the stair still folds both components")
  local dx, dy = offset(groups[1], 10, 1)
  ok(canonical(dx, dy), string.format("canonical offset (got %d,%d)", dx, dy))
  eq(dy > 0, true, "room 1 is the upper floor, so it is drawn ABOVE 10 -- child or not")
end

-- ---- 4. THE THREE-STAIRCASE RING -- forest 2, cycle 1 --------------------
-- ⭐ THE LOAD-BEARING CASE for the spanning forest over "is it the only link between
-- these two floors": each of the three IS the only link of its own pair, so the naive
-- test honours all three and over-determines the translation.
do
  reset_map() ; AID = addAreaName("ring")
  for _, b in ipairs({ 0, 10, 20 }) do
    room(b + 1) ; room(b + 2) ; link(b + 1, b + 2, "east")
  end
  stair(1, 11) ; stair(11, 21) ; stair(21, 1)
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = { 1, 2 },   at = { [1] = { 0, 0 }, [2] = { 1, 0 } } },
    { rooms = { 11, 12 }, at = { [11] = { 0, 0 }, [12] = { 1, 0 } } },
    { rooms = { 21, 22 }, at = { [21] = { 0, 0 }, [22] = { 1, 0 } } },
  })
  local groups, links = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(#groups, 1, "three floors, three staircases -> one group")
  eq(elro._vertStats.honoured, 2, "exactly TWO of the three staircases are honoured")
  local nh = 0
  for _, p in ipairs(links) do if p.honoured then nh = nh + 1 end end
  eq(nh, 2, "...and the third is never marked honoured (it is the cycle)")
  no_overlap(groups[1], "ring")
end

-- ---- 5. A SHAFT: A CHAIN OF FIVE, EVERY EDGE EXACT -----------------------
-- ⭐⭐ THE TREE ARGUMENT, stated properly: in a TREE every edge is satisfiable
-- SIMULTANEOUSLY, because each newly-placed component satisfies its single edge to the
-- already-placed part exactly. Errors do not accumulate down a shaft -- only
-- collisions do. world has two real shafts this deep (6657..6661, 6763..6767).
do
  reset_map() ; AID = addAreaName("shaft")
  for f = 0, 4 do
    room(100 + f * 10) ; room(101 + f * 10) ; link(100 + f * 10, 101 + f * 10, "east")
    if f > 0 then stair(90 + f * 10, 100 + f * 10) end   -- floor f-1 up-> floor f
  end
  elro.cs_reset()
  local specs = {}
  for f = 0, 4 do
    specs[f + 1] = { rooms = { 100 + f * 10, 101 + f * 10 },
                     at = { [100 + f * 10] = { 0, 0 }, [101 + f * 10] = { 1, 0 } } }
  end
  local comps, lcs, adj, compOf = scene(specs)
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(#groups, 1, "a five-deep shaft is ONE group")
  eq(elro._vertStats.honoured, 4, "every one of the four links is honoured")
  local G = groups[1]
  local lasty, step
  for f = 1, 4 do
    local dx, dy = offset(G, 90 + f * 10, 100 + f * 10)
    ok(canonical(dx, dy), string.format("shaft step %d is canonical (%d,%d)", f, dx, dy))
    eq(dy > 0, true, "shaft step " .. f .. " climbs in y")
    -- ⭐⭐⭐ ONE STRAIGHT LADDER, NOT A ZIGZAG (the user's steer). Every step of a shaft
    -- takes the SAME offset, so the whole stack is collinear and reads as one staircase.
    -- Before the carry each dock picked its own ray on compaction alone and world's
    -- 6657..6661 came out (2,1), (-2,1), (1,2) -- nothing was looking at the run's SHAPE.
    if step then
      eq(dx .. "," .. dy, step, "shaft step " .. f .. " repeats the ladder's offset")
    end
    step = dx .. "," .. dy
  end
  -- THREE, not four: the first rung's parent IS the tree root, and a root has no
  -- incoming line to continue.
  -- ⭐ AND THIS FIXTURE REALLY DOES SEPARATE THE TWO -- I assumed at first it could not,
  -- on the theory that a clean field gives the free search no reason to switch rays.
  -- It has one: COMPACTION ACTIVELY PREFERS ALTERNATING. Five same-ray steps drift
  -- (5,10) and extend the bbox 5x10, a mixed run drifts (7,8) and extends it 7x8 -- so
  -- the old tie-break was not merely indifferent to the zigzag, it was CHOOSING it.
  -- With the carry off, floors 2, 3 and 4 all leave the line below.
  eq(elro._vertStats.carried, 3, "...and three of the four docks CONTINUED the ray")
  -- collinear as a geometric fact, not merely as equal steps
  local x0, y0 = G.coord[100][1], G.coord[100][2]
  local ex, ey = G.coord[110][1] - x0, G.coord[110][2] - y0
  for f = 2, 4 do
    local cx, cy = G.coord[100 + f * 10][1] - x0, G.coord[100 + f * 10][2] - y0
    eq(cx * ey - cy * ex, 0, "floor " .. f .. " sits ON the ladder's line")
  end
  -- ⭐ AND IT ALWAYS CLIMBS: reading the floors bottom-to-top off the picture is the
  -- whole point of refusing to flip the y sign.
  for f = 0, 4 do
    local y = G.coord[100 + f * 10][2]
    if lasty then ok(y > lasty, "floor " .. f .. " is drawn above floor " .. (f - 1)) end
    lasty = y
  end
  no_overlap(G, "shaft")
end

-- ---- 5b. THE CARRY SURVIVES AN OBSTRUCTION -- same RAY, bigger step ------
-- ⭐⭐ The ladder is held by the RAY, not by the scale. A corridor of the mass runs
-- through the cell where the second rung would land at scale 1, so that rung steps OUT
-- along the SAME ray instead of switching to another one: floors 0, 1 and 2 stay
-- collinear and only the spacing is uneven. That is the whole reason the carry is two
-- tiers (`ladder` then `collinear`) rather than one.
-- ⚠ The obstruction has to be an EDGE, not a room: a room ON the ray blocks every
-- scale beyond it too (the run's own lattice points), so the ray would be dead and the
-- free search would legitimately take over. Test 6 is that case.
-- Pins the cap: this fixture is about the ray search BEING ABLE to step out, so it must
-- not inherit the default (which is 1, i.e. no stepping out at all).
do
  local capWas = elro.TUNE.vertScaleCap ; elro.TUNE.vertScaleCap = 6
  reset_map() ; AID = addAreaName("carry")
  local mass, at = {}, {}
  local id = 0
  local function put(x, y) id = id + 1 ; room(id) ; mass[#mass + 1] = id ; at[id] = { x, y } ; return id end
  local row = {}
  for x = -6, 6 do row[x] = put(x, 0) end
  for x = -6, 5 do link(row[x], row[x + 1], "east") end
  local col = { row[0] }
  for y = 1, 3 do col[#col + 1] = put(0, y) end
  local top = put(0, 4)
  col[#col + 1] = top
  for i = 1, #col - 1 do link(col[i], col[i + 1], "north") end
  -- ⭐ A STRETCHED EDGE, four cells long, whose raster covers (1,4) (2,4) (3,4). Its
  -- far end is a room; the cells in between are not, which is exactly the distinction
  -- the fit test draws between a COLLISION and ROOM-ON-EDGE.
  local far = put(4, 4)
  link(top, far, "east")
  local S = row[0]                                  -- the shaft's foot, at (0,0)
  local A, B = 9001, 9002
  room(A) ; room(B)
  stair(S, A) ; stair(A, B)
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = mass, at = at },
    { rooms = { A }, at = { [A] = { 0, 0 } } },
    { rooms = { B }, at = { [B] = { 0, 0 } } },
  })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(#groups, 1, "the two-rung shaft docks into the mass")
  eq(elro._vertStats.honoured, 2, "both rungs honoured")
  local ax, ay = offset(groups[1], S, A)
  local bx, by = offset(groups[1], A, B)
  eq(ax .. "," .. ay, "1,2", "rung 1 takes the steep ray at scale 1")
  ok(canonical(bx, by), string.format("rung 2 is canonical (%d,%d)", bx, by))
  ok(bx * 2 == by, string.format("rung 2 stays on the SAME ray -- 1:2 (got %d,%d)", bx, by))
  ok(by > ay, "...at a bigger scale, because scale 1 was on the corridor")
  eq(elro._vertStats.carried, 1, "the stats record it as a carried dock")
  -- and the three floors are still collinear, which is the property the carry exists for
  eq(ax * by - ay * bx, 0, "foot, rung 1 and rung 2 are collinear")
  elro.TUNE.vertScaleCap = capWas
end

-- ---- 6. NO ROOM -> DECLINE, AND THE DECLINED COMPONENT DOES NOT MOVE -----
-- ⭐⭐⭐ THE MONOTONICITY TEST. A declined link must leave its component EXACTLY where it
-- was, shelf-packed as today -- that is what makes every honoured link a strict
-- improvement and every declined one a no-change, and it is the property that kept the
-- "expand the grid, inset the floor" tier parked.
-- The parent here is a solid 40x40 block, so every candidate cell out to the scale cap
-- is occupied whichever of the four rays the search takes.
do
  reset_map() ; AID = addAreaName("full")
  local wall, at, byxy = {}, {}, {}
  local id = 0
  for x = -10, 10 do
    for y = -10, 10 do
      id = id + 1 ; room(id) ; wall[#wall + 1] = id ; at[id] = { x, y }
      byxy[x .. ":" .. y] = id
    end
  end
  -- a connected slab, so it is genuinely one compass component
  for _, r in ipairs(wall) do
    local p = at[r]
    local e, n = byxy[(p[1] + 1) .. ":" .. p[2]], byxy[p[1] .. ":" .. (p[2] + 1)]
    if e then link(r, e, "east") end
    if n then link(r, n, "north") end
  end
  local mid = byxy["0:0"]                      -- deep inside the slab, every ray blocked
  room(9001) ; room(9002) ; link(9001, 9002, "east")
  stair(mid, 9001)
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = wall, at = at },
    { rooms = { 9001, 9002 }, at = { [9001] = { 0, 0 }, [9002] = { 1, 0 } } },
  })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(#groups, 2, "a link with nowhere to land DECLINES -- two groups, not one")
  eq(elro._vertStats.honoured, 0, "nothing honoured")
  eq(elro._vertStats.declined, 1, "one declined")
  -- ⛔ THE DECLINED COMPONENT IS UNTOUCHED. Its group is its own local coordinates,
  -- verbatim, so the shelf pack downstream puts it exactly where it goes today.
  eq(groups[2].coord[9001][1] .. "," .. groups[2].coord[9001][2], "0,0",
     "the declined component keeps its own local coordinates")
  eq(groups[2].coord[9002][1] .. "," .. groups[2].coord[9002][2], "1,0",
     "...all of them")
end

-- ---- 7. SQUEEZED, NOT BLOCKED -> the ray SEARCH finds a longer step ------
-- ⭐⭐ THE ANGLE IS THE INVARIANT AND THE MAGNITUDE IS FREE. This is the difference
-- between a search and a yes/no gate: scale 1 does not fit on any of the four rays, so
-- the dock STEPS OUT along the same ray instead of giving up.
-- ⚠ AND NOTE WHAT TEST 6 ABOVE ALREADY PROVED, because it constrains this fixture: a
-- stair room in the MIDDLE of a mass can never escape at ANY scale. The run's own
-- interior lattice points are gu + k*offset*j, so a ray that is blocked at scale 1 by a
-- ROOM is blocked at every scale beyond it too -- stepping out does not step over.
-- Reaching scale 2 therefore requires the near cells to be free and the CHILD'S OWN
-- FOOTPRINT to be what does not fit, which is what this fixture builds: the stair room
-- sits on the top edge of a 3-row band and the child is a column hanging DOWNWARD off
-- its own stair room, so close in it lands inside the band and far out it clears.
-- Pins the cap for the same reason as 5b: the default is 1, which declines instead.
do
  local capWas = elro.TUNE.vertScaleCap ; elro.TUNE.vertScaleCap = 6
  reset_map() ; AID = addAreaName("squeeze")
  local band, at, byxy = {}, {}, {}
  local id = 0
  for x = -10, 10 do
    for y = -2, 0 do
      id = id + 1 ; room(id) ; band[#band + 1] = id ; at[id] = { x, y }
      byxy[x .. ":" .. y] = id
    end
  end
  for _, r in ipairs(band) do
    local p = at[r]
    local e, n = byxy[(p[1] + 1) .. ":" .. p[2]], byxy[p[1] .. ":" .. (p[2] + 1)]
    if e then link(r, e, "east") end
    if n then link(r, n, "north") end
  end
  local top = byxy["0:0"]                       -- on the band's top edge: the rays are clear
  local col = { 9001, 9002, 9003, 9004 }        -- ...but the child hangs down into it
  local cat = {}
  for i, r in ipairs(col) do
    room(r) ; cat[r] = { 0, -(i - 1) }
    if i > 1 then link(col[i - 1], r, "south") end
  end
  stair(top, 9001)
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = band, at = at },
    { rooms = col,  at = cat },
  })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(#groups, 1, "the ray search steps out instead of declining")
  local dx, dy = offset(groups[1], top, 9001)
  local k = canonical(dx, dy)
  ok(k, string.format("the longer step is STILL canonical (%d,%d)", dx, dy))
  eq(k, 2, "...and it took exactly scale 2 -- one step out, not a scramble")
  eq(dy > 0, true, "and it still climbs")
  no_overlap(groups[1], "squeeze")
  elro.TUNE.vertScaleCap = capWas
end

-- ---- 8. NO VERTICALS -> NO PLAN, so the shelf pack is untouched ----------
-- ⛔ THE IDENTITY GUARANTEE. vert_assemble returns nil when nothing joins two
-- components, and compose_spqr_adj then shelf-packs one group per component -- the same
-- arithmetic, in the same order, as before this feature existed. The canary rests on it.
do
  reset_map() ; AID = addAreaName("flat")
  room(1) ; room(2) ; link(1, 2, "east")
  room(10) ; room(11) ; link(10, 11, "east")
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = { 1, 2 },   at = { [1] = { 0, 0 }, [2] = { 1, 0 } } },
    { rooms = { 10, 11 }, at = { [10] = { 0, 0 }, [11] = { 1, 0 } } },
  })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(groups, nil, "no vertical link at all -> no plan, the shelf pack is untouched")
end

-- ---- 9. REDUNDANT LINKS MOVE NOTHING ------------------------------------
-- A stair beside a corridor: both ends are already in one component, so there is no
-- translation to solve and nothing to place. It is drawn (rung 2), never packed.
do
  reset_map() ; AID = addAreaName("redundant")
  room(1) ; room(2) ; room(3) ; link(1, 2, "east") ; link(2, 3, "east")
  stair(1, 3)
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = { 1, 2, 3 }, at = { [1] = { 0, 0 }, [2] = { 1, 0 }, [3] = { 2, 0 } } },
  })
  local groups, links = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(groups, nil, "a redundant stair asks for no placement change")
  eq(#links, 1, "...but it is still classified and published for the renderer")
  eq(links[1].cls, "redundant", "...as redundant")
end

-- ---- 10. DETERMINISM -----------------------------------------------------
-- ⚠ elro.cs_room iterates rec.ex with pairs(), and both the forest/cycle split AND the
-- dock order ride on it. Re-running from a cold c-space must reproduce identical
-- geometry, not merely an identical link count. See [[reference_luajit_hash_seed]].
do
  local function build_ring()
    reset_map() ; AID = addAreaName("det")
    for _, b in ipairs({ 0, 10, 20, 30 }) do
      room(b + 1) ; room(b + 2) ; link(b + 1, b + 2, "east")
    end
    stair(1, 11) ; stair(11, 21) ; stair(21, 31) ; stair(31, 1) ; stair(1, 21)
    elro.cs_reset()
    return scene({
      { rooms = { 1, 2 },   at = { [1] = { 0, 0 }, [2] = { 1, 0 } } },
      { rooms = { 11, 12 }, at = { [11] = { 0, 0 }, [12] = { 1, 0 } } },
      { rooms = { 21, 22 }, at = { [21] = { 0, 0 }, [22] = { 1, 0 } } },
      { rooms = { 31, 32 }, at = { [31] = { 0, 0 }, [32] = { 1, 0 } } },
    })
  end
  local sig
  for pass = 1, 5 do
    local groups = elro.vert_assemble(build_ring())
    local ids = {}
    for r in pairs(groups[1].coord) do ids[#ids + 1] = r end
    table.sort(ids)
    local parts = {}
    for _, r in ipairs(ids) do
      parts[#parts + 1] = r .. "@" .. groups[1].coord[r][1] .. "," .. groups[1].coord[r][2]
    end
    local s = table.concat(parts, " ")
    if pass == 1 then sig = s else eq(s, sig, "pass " .. pass .. ": identical geometry") end
    eq(#groups, 1, "pass " .. pass .. ": four floors, one group")
    eq(elro._vertStats.honoured, 3, "pass " .. pass .. ": a spanning forest of 4 nodes has 3 edges")
  end
end

-- ---- 11. THE PACK MUTATES NO GRAPH STATE --------------------------------
-- ⛔ graph-vs-canvas: the packer may move rooms on the canvas, and it may NEVER touch an
-- exit. Verticals are carried in a side table read only by the packer and the renderer,
-- and `adj` never learns they exist.
do
  reset_map() ; AID = addAreaName("pure")
  room(1) ; room(2) ; link(1, 2, "east")
  room(10) ; room(11) ; link(10, 11, "east")
  stair(1, 10)
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = { 1, 2 },   at = { [1] = { 0, 0 }, [2] = { 1, 0 } } },
    { rooms = { 10, 11 }, at = { [10] = { 0, 0 }, [11] = { 1, 0 } } },
  })
  local before = {}
  for id in pairs(getRooms()) do
    local ex = {}
    for d, v in pairs(getRoomExits(id)) do ex[#ex + 1] = d .. "=" .. v end
    table.sort(ex) ; before[id] = table.concat(ex, ",")
  end
  elro.vert_assemble(comps, lcs, adj, compOf)
  for id, sig in pairs(before) do
    local ex = {}
    for d, v in pairs(getRoomExits(id)) do ex[#ex + 1] = d .. "=" .. v end
    table.sort(ex)
    eq(table.concat(ex, ","), sig, "room " .. id .. ": exits untouched")
  end
  for r, nb in pairs(adj) do
    for d in pairs(nb) do
      local de = elro.delta[d]
      ok(de and (de[1] ~= 0 or de[2] ~= 0), "adj stays PLANAR: " .. r .. " has no " .. d)
    end
  end
end

-- ---- 12. STEEP BEATS SHALLOW, AND IT BEATS COMPACTION -------------------
-- ⭐⭐ The user's call: *"I also want to prefer (+2n,+1e/w) over (+1n,+2e/w) I think,
-- since it looks more vertical"*. Both ratios stay legal, but 1:2 (63.43 degrees) is the
-- one that reads as a staircase; 2:1 (26.57) reads as a corridor wandering off sideways.
-- So the ratio is ranked ABOVE the bounding box, not merely used to break its ties -- and
-- this fixture is built so the two disagree: the mass is a WIDE row, so the shallow ray
-- keeps the box the same height while the steep one makes it taller. Steep wins anyway.
-- ⭐ Note the two agree on SEPARATION here, which is the ordinary case: real floors are
-- wider than they are tall, so the steeper ray is also the one that gets clear of the
-- mass faster. Test 13 is the fixture where they genuinely conflict.
do
  reset_map() ; AID = addAreaName("steep")
  local row, at, byx = {}, {}, {}
  local id = 0
  for x = -8, 8 do id = id + 1 ; room(id) ; row[#row + 1] = id ; at[id] = { x, 0 } ; byx[x] = id end
  for x = -8, 7 do link(byx[x], byx[x + 1], "east") end
  room(9001) ; stair(byx[0], 9001)                 -- up from the middle of the row
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = row, at = at },
    { rooms = { 9001 }, at = { [9001] = { 0, 0 } } },
  })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  local dx, dy = offset(groups[1], byx[0], 9001)
  eq(math.abs(dy), 2, "the steep ratio is taken: 2 up")
  eq(math.abs(dx), 1, "...and 1 across")
  eq(dy > 0, true, "up is still up")
  ok(not (math.abs(dx) == 2 and math.abs(dy) == 1),
     "the shallow ray lost even though it kept the box shorter")
end

-- ---- 13. ...BUT SEPARATION BEATS STEEP -----------------------------------
-- ⚠⚠ THE ONE PLACE THE TWO USER PREFERENCES CONFLICT, and the ordering is a deliberate
-- choice recorded here rather than an accident: SEPARATION IS RANKED FIRST. The mass is a
-- bare vertical column, so the steep ray runs straight up alongside it and leaves the
-- docked room touching three of its rooms with no exit to any of them, while the shallow
-- ray stands two cells clear. Unexplained adjacency is a legibility DEFECT; the ratio is
-- a cosmetic preference, and it still decides every dock where nothing is touching.
-- ⭐ To flip this, swap the first two elements of the ranking key in `vert_ray` -- they
-- are a plain lexicographic list precisely so the priority can be read and changed in one
-- place. Nothing else in the pack depends on the order.
do
  reset_map() ; AID = addAreaName("conflict")
  local col, at = {}, {}
  local id = 0
  for y = 0, 9 do id = id + 1 ; room(id) ; col[#col + 1] = id ; at[id] = { 0, y } end
  for i = 1, #col - 1 do link(col[i], col[i + 1], "north") end
  room(9001) ; stair(col[1], 9001)
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = col, at = at },
    { rooms = { 9001 }, at = { [9001] = { 0, 0 } } },
  })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  local dx, dy = offset(groups[1], col[1], 9001)
  ok(canonical(dx, dy), string.format("still canonical (%d,%d)", dx, dy))
  eq(math.abs(dx), 2, "against a bare wall the SHALLOW ray wins -- it stands clear")
  eq(dy > 0, true, "...and up is still up")
  -- the point of the whole thing: no room of the upper floor touches one of the lower
  local G = groups[1]
  for _, r in ipairs(col) do
    local p, q = G.coord[r], G.coord[9001]
    ok(math.max(math.abs(p[1] - q[1]), math.abs(p[2] - q[2])) > 1,
       "room " .. r .. " does not touch the docked floor")
  end
end

-- ---- 14. THE cathbad REGRESSION -- the user's own selection ---------------
-- ⭐⭐⭐ THE CASE THAT BOUGHT THE SEPARATION TERM, copied room-for-room out of the user's
-- `mapdumpsel`: *"1760:1761 picked (2s,1w), but (2s,1e) would better shift the geometry
-- away from each other"*. Compaction chose WEST because A spans x 3..9 and the west
-- placement keeps the union 7 wide against the east one's 9 -- and paid for it with 1761
-- directly south of 1759 and 1763 directly south of 1760, neither pair connected.
-- ⚠ NOT reachable from any dump: cathbad_lie.txt is a different selection and carries
-- neither room. Hand-built for that reason, like the rest of this file.
do
  reset_map() ; AID = addAreaName("cathbad")
  local A = { [321] = { 6, 24 }, [1310] = { 6, 23 }, [1311] = { 6, 22 }, [1312] = { 6, 21 },
              [1749] = { 5, 21 }, [1750] = { 7, 21 }, [1751] = { 6, 20 }, [1752] = { 6, 19 },
              [1753] = { 6, 18 }, [1754] = { 5, 17 }, [1755] = { 4, 18 }, [1756] = { 3, 19 },
              [1757] = { 3, 18 }, [1758] = { 7, 17 }, [1759] = { 8, 20 }, [1760] = { 9, 21 } }
  local B = { [1761] = { 0, 0 }, [1762] = { 1, 0 }, [1763] = { 1, 1 }, [1764] = { 2, 0 } }
  local ar, br = {}, {}
  for r in pairs(A) do ar[#ar + 1] = r end ; table.sort(ar)
  for r in pairs(B) do br[#br + 1] = r end ; table.sort(br)
  for _, r in ipairs(ar) do room(r) end
  for _, r in ipairs(br) do room(r) end
  link(321, 1310, "south") ; link(1310, 1311, "south") ; link(1311, 1312, "south")
  link(1312, 1751, "south") ; link(1312, 1749, "west") ; link(1312, 1750, "east")
  link(1751, 1752, "south") ; link(1752, 1753, "south")
  link(1753, 1754, "southwest") ; link(1753, 1758, "southeast")
  link(1754, 1755, "northwest") ; link(1755, 1756, "northwest") ; link(1755, 1757, "west")
  link(1750, 1759, "southeast") ; link(1759, 1760, "northeast")
  link(1761, 1762, "east") ; link(1762, 1763, "north") ; link(1762, 1764, "east")
  link(1763, 1764, "southeast")
  setExit(1760, 1761, "down") ; setExit(1761, 1760, "up")
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = ar, at = A },
    { rooms = br, at = B },
  })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(#groups, 1, "the upper cluster docks onto the mass")
  local G = groups[1]
  local dx, dy = offset(G, 1760, 1761)
  eq(dy, -2, "1761 is the LOWER floor, so it is drawn two below 1760")
  eq(dx, 1, "...and EAST, clear of the mass -- not WEST into the notch beside 1759")
  -- the property that actually matters, stated without naming a direction
  local touch = 0
  for _, a in ipairs(ar) do
    for _, b in ipairs(br) do
      local p, q = G.coord[a], G.coord[b]
      if math.max(math.abs(p[1] - q[1]), math.abs(p[2] - q[2])) <= 1 then touch = touch + 1 end
    end
  end
  eq(touch, 0, "no room of the upper floor touches a room of the lower one")
  no_overlap(G, "cathbad")
end

-- ---- 15. THE RENDERER -- the three rungs, as actual polylines ------------
-- ⭐ The drawing had NO offline coverage: `addCustomLine` is a no-op stub, so every check
-- above stopped at the coordinates. Overriding the stub with a recorder tests the real
-- geometry -- and it is the half the user reads, since `mapvert`'s counts only say how
-- many lines of each kind were drawn, never what they looked like.
-- ⚠ `elro.draw_vertical` reads LIVE coordinates (it serves both the map renderer and
-- `mapstep`, which re-lays each frame near the origin), so the group's answer has to be
-- written to the fake map first.
local drawn
local realAdd = addCustomLine
function addCustomLine(r, pts, dir, style, col)
  drawn[#drawn + 1] = { r = r, pts = pts, dir = dir, style = style, col = col }
end

local function render(groups)
  drawn = {}
  for _, G in ipairs(groups or {}) do
    for r, p in pairs(G.coord) do setRoomCoordinates(r, p[1], p[2]) end
  end
  local coord = {}
  for _, G in ipairs(groups or {}) do for r in pairs(G.coord) do coord[r] = true end end
  local sunk = {}
  local a, b, c = elro.draw_vertical(coord, function(u, d) sunk[#sunk + 1] = u .. ":" .. d end)
  return a, b, c, sunk
end

-- RUNG 1: an honoured link is a STRAIGHT centre-to-centre line. We control the geometry,
-- so it is already at a provably non-compass angle and needs no bend.
do
  reset_map() ; AID = addAreaName("draw1")
  room(1) ; room(2) ; link(1, 2, "east")
  room(10) ; room(11) ; link(10, 11, "east")
  stair(1, 10)
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = { 1, 2 },   at = { [1] = { 0, 0 }, [2] = { 1, 0 } } },
    { rooms = { 10, 11 }, at = { [10] = { 0, 0 }, [11] = { 1, 0 } } },
  })
  local groups, links = elro.vert_assemble(comps, lcs, adj, compOf)
  elro._vertLinks = links
  local nS, nB, nQ, sunk = render(groups)
  eq(nS, 1, "one straight line for the honoured link")
  eq(nB, 0, "nothing bent")
  eq(nQ, 0, "nothing silent")
  eq(#drawn, 1, "exactly one custom line")
  eq(#drawn[1].pts, 2, "...with two points -- centre to centre, no bend")
  eq(drawn[1].style, "dash line", "...dashed, because a vertical is never a plane adjacency")
  -- ⚠ the SHORT key. Mudlet files custom lines under "u"/"d", and a long key leaves its
  -- own marker drawn beside ours. See elro.shorten.
  ok(drawn[1].dir == "u" or drawn[1].dir == "d",
     "...filed under the SHORT direction key (got " .. tostring(drawn[1].dir) .. ")")
  eq(#sunk, 1, "the sink saw the line, so mapstep can clear it")
  -- the line runs between the two rooms, and at a non-compass angle
  local x1, y1 = drawn[1].pts[1][1], drawn[1].pts[1][2]
  local x2, y2 = drawn[1].pts[2][1], drawn[1].pts[2][2]
  local dx, dy = x2 - x1, y2 - y1
  ok(dx ~= 0 and dy ~= 0 and math.abs(dx) ~= math.abs(dy),
     string.format("the drawn line is not on a compass ray (%d,%d)", dx, dy))
end

-- RUNG 2 and RUNG 3: a link the packer could NOT honour. Its geometry is not ours, so a
-- straight line could land at 45 or 90 degrees and lie -- it gets the single-bend shape,
-- and only when the run is clear. A blocked run gets NOTHING, and must not claim the
-- direction's line slot: Mudlet's own marker is the fallback and taking the slot to draw
-- something we just judged unreadable would be strictly worse.
-- ⛔⛔ AND THIS FIXTURE HAD TO PIN THE PISTON KNOBS THE DAY THEY DEFAULTED ON, which is
-- the trap this file has now met twice (test 17d was the first). The scene is a
-- hand-built NEAR MISS -- that is what makes it a rung-2 case -- so `vertPiston` lands it
-- and the renderer draws a straight line instead of the bend this test exists to check.
-- The failure was loud, but only because the assertions were specific; a fixture asserting
-- something weaker would have gone on "passing" while testing nothing.
-- ⭐ BOTH LEGS, and the second one is real coverage rather than bookkeeping: the same
-- scene AT DEFAULTS must now draw STRAIGHT, because the piston has made the geometry ours.
local function draw2_scene()
  reset_map() ; AID = addAreaName("draw2")
  -- a redundant stair: both ends in ONE component, so no placement change is possible
  -- and the renderer is all there is. 1 and 3 are three apart with 2 NOT between them,
  -- so the run is clear.
  room(1) ; room(2) ; room(3)
  link(1, 2, "north") ; link(2, 3, "east")
  stair(1, 3)
  elro.cs_reset()
  return scene({
    { rooms = { 1, 2, 3 }, at = { [1] = { 0, 0 }, [2] = { 0, 1 }, [3] = { 1, 1 } } },
  })
end
do
  elro.vertPiston = false ; elro.vertMakeRoom = false
  local comps, lcs, adj, compOf = draw2_scene()
  local _, links = elro.vert_assemble(comps, lcs, adj, compOf)
  elro._vertLinks = links
  eq(links[1].cls, "redundant", "the stair beside the corridor is redundant")
  eq(links[1].honoured, nil, "...and is never honoured -- nothing to place")
  local nS, nB, nQ = render({ { coord = lcs[1] } })
  eq(nS, 0, "no straight line -- the geometry is not ours")
  eq(nB, 1, "one BENT line, because the run is clear")
  eq(#drawn[1].pts, 3, "...three points: centre, stub, far centre")
  eq(drawn[1].style, "dot line", "...dotted, distinct from an honoured link")
  -- ⛔ THE STUB CARRIES THE SEMANTICS: `up` leaves along +y, always, whatever direction
  -- the far room actually lies in. That is the one invariant the visual language rests on.
  local sy = drawn[1].pts[2][2] - drawn[1].pts[1][2]
  eq(links[1].dir == "up" and sy > 0 or links[1].dir == "down" and sy < 0, true,
     "the stub leaves along the TRUE vertical sense (" .. links[1].dir .. ")")
  local sx = drawn[1].pts[2][1] - drawn[1].pts[1][1]
  ok(math.abs(math.abs(sx) - math.abs(sy)) > 1e-9 and sx ~= 0 and sy ~= 0,
     "...and the stub is not on a compass ray either")
  elro.vertPiston = nil ; elro.vertMakeRoom = nil
end

-- ...and the other leg: AT DEFAULTS the piston lands this very link, so the renderer's
-- rung 1 applies instead. Same scene, same renderer, opposite answer -- which is what
-- "the piston made the geometry ours" means in the one place the player can see it.
do
  local comps, lcs, adj, compOf = draw2_scene()
  local groups, links = elro.vert_assemble(comps, lcs, adj, compOf)
  elro._vertLinks = links
  local dx, dy = offset(groups and groups[1] or { coord = lcs[1] }, 1, 3)
  eq(dx .. "," .. dy, "1,2", "at defaults the piston lands the redundant stair")
  local nS, nB = render({ groups and groups[1] or { coord = lcs[1] } })
  eq(nS, 1, "...so the renderer draws it STRAIGHT")
  eq(nB, 0, "...and not bent")
  eq(drawn[1].style, "dash line", "...dashed, the honoured/realised style")
end

do
  -- RUNG 3: a room sits dead on the run -> draw nothing, claim nothing.
  reset_map() ; AID = addAreaName("draw3")
  room(1) ; room(2) ; room(3)
  link(1, 2, "east") ; link(2, 3, "east")
  stair(1, 3)
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = { 1, 2, 3 }, at = { [1] = { 0, 0 }, [2] = { 1, 0 }, [3] = { 2, 0 } } },
  })
  local _, links = elro.vert_assemble(comps, lcs, adj, compOf)
  elro._vertLinks = links
  local nS, nB, nQ, sunk = render({ { coord = lcs[1] } })
  eq(nS + nB, 0, "room 2 sits on the run -> nothing is drawn")
  eq(nQ, 1, "...and it is counted as left to Mudlet's marker")
  eq(#drawn, 0, "no custom line at all")
  eq(#sunk, 0, "...so nothing to clear, and the direction slot is UNCLAIMED")
end


-- ---- 16. A LINK THE PACKER NEVER PLACED, THAT LANDED RIGHT ANYWAY --------
-- ⭐⭐⭐ The user: *"lift the loop restriction to some extent, by picking one exit first to
-- decide the placement and once placement is decided, see if the other exit can be drawn
-- with the same angle, if so, do it"*.  A link is drawn STRAIGHT exactly when its REALISED
-- geometry satisfies the same predicate the packer would have imposed had it placed it --
-- canonical offset, within the scale cap, right y sign, no room centre on the run.
-- ⚠⚠ AND THIS FILE IS THE ONLY PLACE IT IS TESTED, because the corpus cannot reach it: all
-- 14 dumps together hold exactly ONE cycle link (world_live) and ZERO redundant ones.
-- `mapvert all` counts 13 cycles world-wide, 4 of them in titleist -- whose dump carries no
-- vertical exits at all.  The offline zero is a fact about the corpus, not about the rule.
local function drawn_kind()
  if #drawn == 0 then return "none" end
  return (#drawn[1].pts == 2) and "straight" or "bend"
end

-- (a) THE CYCLE LINK, which is the case the user asked for: two staircases between the
-- same two floors.  The forest link pins the translation; the second stair then lands one
-- canonical offset apart all by itself, and gets a straight line -- two parallel teal
-- ladders, which is what a building with two staircases should look like.
do
  reset_map() ; AID = addAreaName("cyc")
  room(1) ; room(2) ; link(1, 2, "east")
  room(10) ; room(11) ; link(10, 11, "east")
  stair(1, 10) ; stair(2, 11)
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = { 1, 2 },   at = { [1] = { 0, 0 }, [2] = { 1, 0 } } },
    { rooms = { 10, 11 }, at = { [10] = { 0, 0 }, [11] = { 1, 0 } } },
  })
  local groups, links = elro.vert_assemble(comps, lcs, adj, compOf)
  elro._vertLinks = links
  local nf, ncy = 0, 0
  for _, p in ipairs(links) do
    if p.cls == "forest" then nf = nf + 1 elseif p.cls == "cycle" then ncy = ncy + 1 end
  end
  eq(nf, 1, "one staircase is the forest link")
  eq(ncy, 1, "...and the second is a CYCLE -- over-determined, never placed")
  drawn = {}
  for _, G in ipairs(groups) do
    for r, q in pairs(G.coord) do setRoomCoordinates(r, q[1], q[2]) end
  end
  local coord = {}
  for _, G in ipairs(groups) do for r in pairs(G.coord) do coord[r] = true end end
  local nS, nB, _, nR = elro.draw_vertical(coord)
  eq(nS, 2, "BOTH staircases are drawn straight")
  eq(nR, 1, "...and exactly one of them was never placed by the packer")
  eq(nB, 0, "nothing had to bend")
  eq(#drawn, 2, "two custom lines")
  for i = 1, 2 do eq(#drawn[i].pts, 2, "line " .. i .. " is straight (two points)") end
  -- the two ladders are PARALLEL, which is the whole visual point
  local function vec(L) return L.pts[2][1] - L.pts[1][1], L.pts[2][2] - L.pts[1][2] end
  local ux, uy = vec(drawn[1])
  local vx, vy = vec(drawn[2])
  eq(ux * vy - uy * vx, 0, "the two staircases are drawn PARALLEL")
  -- ⛔ and the packer still moved nothing for the second one
  eq(elro._vertStats.honoured, 1, "only ONE link was ever honoured for placement")
end

-- (b) THE FOUR REFUSALS. Each is the placement test read back, and each must fall through
-- to the bend (or to nothing) rather than getting a straight line it has not earned.
-- One component per case, so every link is `redundant` -- no packer would move it, which
-- makes these pure tests of the drawing rule.
local function redundant_case(name, at, from, to, dir, links_expect)
  reset_map() ; AID = addAreaName(name)
  local rooms = {}
  for r in pairs(at) do rooms[#rooms + 1] = r end
  table.sort(rooms)
  for _, r in ipairs(rooms) do room(r) end
  -- a compass spine so the whole thing is ONE component; direction names are not asserted
  for i = 1, #rooms - 1 do link(rooms[i], rooms[i + 1], "east") end
  setExit(from, to, dir) ; setExit(to, from, elro.reverse[dir])
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({ { rooms = rooms, at = at } })
  local _, links = elro.vert_assemble(comps, lcs, adj, compOf)
  elro._vertLinks = links
  eq(links[1].cls, "redundant", name .. ": the stair is redundant (one component)")
  drawn = {}
  for r, q in pairs(lcs[1]) do setRoomCoordinates(r, q[1], q[2]) end
  local coord = {} ; for r in pairs(lcs[1]) do coord[r] = true end
  local nS, nB, nQ, nR = elro.draw_vertical(coord)
  return nS, nB, nQ, nR
end

-- ⛔ THE Y SIGN IS NOT COSMETIC. A straight line at the right ANGLE and the wrong SIGN is
-- worse than a bend: it reads as a properly placed vertical while lying about which end is
-- the higher floor -- the one invariant the whole visual language rests on.
do
  local nS, nB = redundant_case("ysign", { [1] = { 0, 0 }, [2] = { 1, 2 } }, 1, 2, "down")
  eq(nS, 0, "canonical offset but 2 is drawn ABOVE 1 while the stair goes DOWN -> not straight")
  eq(nB, 1, "...it bends instead")
  eq(drawn_kind(), "bend", "...three points")
end
do
  -- the same two rooms, the same offset, the stair walked the other way: now it is honest
  local nS, nB, _, nR = redundant_case("ysign_ok", { [1] = { 0, 0 }, [2] = { 1, 2 } }, 1, 2, "up")
  eq(nS, 1, "the SAME geometry with the stair going UP is drawn straight")
  eq(nB, 0, "...and does not bend")
  eq(nR, 1, "...counted as a link that landed right without being placed")
end

-- a 45-degree offset is a COMPASS ray: drawing it straight would be indistinguishable
-- from a northeast exit, which is exactly what the canonical offsets exist to avoid
do
  local nS, nB = redundant_case("diag", { [1] = { 0, 0 }, [2] = { 2, 2 } }, 1, 2, "up")
  eq(nS, 0, "a 45-degree offset is never drawn straight -- it would read as northeast")
  eq(nB, 1, "...it bends")
end

-- canonical, right sign, but FAR: the same scale cap a placement would have obeyed, or a
-- "canonical" line runs clean across the map and reads as a corridor
do
  local nS, nB, nQ, nR = redundant_case("far", { [1] = { 0, 0 }, [2] = { 7, 14 } }, 1, 2, "up")
  eq(nS, 0, "canonical but beyond the scale cap -> not straight")
  eq(nR, 0, "...and not counted as landing right")
  eq(nB + nQ, 1, "...it falls through to the bend/silent path like any other stray link")
end

-- canonical and near, but a room sits dead on the run. `elro.room_on_segment` is the exact
-- test and it is the same one vert_fit enumerates when it PLACES a link.
do
  local nS = redundant_case("onrun",
    { [1] = { 0, 0 }, [2] = { 1, 2 }, [3] = { 2, 4 } }, 1, 3, "up")
  eq(nS, 0, "room 2 sits exactly on the 1->3 run -> not straight")
end

-- ...and the generalisation the user did not ask for but which follows from the same rule:
-- a REDUNDANT stair (both ends in one component, so no packer would ever move it) that
-- happens to land canonically gets the straight line too.
do
  local nS, nB, nQ, nR = redundant_case("redu", { [1] = { 0, 0 }, [2] = { 2, 1 } }, 1, 2, "up")
  eq(nS, 1, "a redundant stair that landed canonically is drawn straight")
  eq(nR, 1, "...and counted as never-placed")
  eq(drawn_kind(), "straight", "...as two points")
end

-- ---- 17. THE TWO KNOBS ---------------------------------------------------
-- ⚠ Both are read at MORE THAN ONE SITE and the sites must agree, which is the only thing
-- that can really go wrong with them -- so each is asserted through the behaviour of a
-- fixture from earlier in this file rather than by reading the value back.

-- `TUNE.vertScaleCap` -- how far out the ray search may step. The squeeze fixture needs
-- scale 2 (its child hangs down into a band at scale 1), so capping the search at 1 must
-- turn it from a dock into a decline, and the component must be left exactly where it was.
do
  reset_map() ; AID = addAreaName("knob_scale")
  local band, at, byxy = {}, {}, {}
  local id = 0
  for x = -10, 10 do
    for y = -2, 0 do
      id = id + 1 ; room(id) ; band[#band + 1] = id ; at[id] = { x, y }
      byxy[x .. ":" .. y] = id
    end
  end
  for _, r in ipairs(band) do
    local q = at[r]
    local e, n = byxy[(q[1] + 1) .. ":" .. q[2]], byxy[q[1] .. ":" .. (q[2] + 1)]
    if e then link(r, e, "east") end
    if n then link(r, n, "north") end
  end
  local top = byxy["0:0"]
  local col = { 9001, 9002, 9003, 9004 }
  local cat = {}
  for i, r in ipairs(col) do
    room(r) ; cat[r] = { 0, -(i - 1) }
    if i > 1 then link(col[i - 1], r, "south") end
  end
  stair(top, 9001)
  elro.cs_reset()
  local function run()
    local comps, lcs, adj, compOf = scene({
      { rooms = band, at = at }, { rooms = col, at = cat },
    })
    return elro.vert_assemble(comps, lcs, adj, compOf), lcs
  end
  -- ⚠ `elro.vertScale` WAS A KNOB LAYERED ON `TUNE.vertScaleCap` and went in the 2026-08-21 knob
  -- review -- one number, one name. The cap itself is still reachable (`elro.TUNE` is published as a
  -- measurement handle at layout.lua:220), so this fixture keeps its coverage; it just sets the
  -- constant instead of an override on top of it.
  local capWas = elro.TUNE.vertScaleCap
  elro.TUNE.vertScaleCap = 1
  local g1 = run()
  eq(#g1, 2, "vertScaleCap=1: the dock that needed scale 2 DECLINES")
  eq(elro._vertStats.honoured, 0, "...nothing honoured")
  elro.TUNE.vertScaleCap = 6                -- explicit, not `capWas`: the default IS 1 now,
  local g2 = run()                          -- which would make this half of the contrast vacuous
  eq(#g2, 1, "...and at cap 6 the same fixture docks again")
  eq(elro._vertStats.honoured, 1, "...honoured")
  elro.TUNE.vertScaleCap = capWas
end

-- `elro.vertOverRoom` -- let the CONNECTOR cross rooms, and nothing else. A solid slab with
-- the stair room at its centre declines by default because THE CONNECTOR'S RUN crosses room
-- after room, and a ray blocked at scale 1 by a room is blocked at every scale beyond it.
-- The knob drops exactly that refusal: the far floor lands outside the slab and the teal
-- line runs over the rooms in between.
local function slab(half)
  local wall, at, byxy = {}, {}, {}
  local id = 0
  for x = -half, half do
    for y = -half, half do
      id = id + 1 ; room(id) ; wall[#wall + 1] = id ; at[id] = { x, y }
      byxy[x .. ":" .. y] = id
    end
  end
  for _, r in ipairs(wall) do
    local q = at[r]
    local e, n = byxy[(q[1] + 1) .. ":" .. q[2]], byxy[q[1] .. ":" .. (q[2] + 1)]
    if e then link(r, e, "east") end
    if n then link(r, n, "north") end
  end
  room(9001) ; stair(byxy["0:0"], 9001)
  elro.cs_reset()
  return scene({ { rooms = wall, at = at }, { rooms = { 9001 }, at = { [9001] = { 0, 0 } } } })
end

-- Pins the cap at 6: clearing a 21-wide slab needs the far floor to step OUT to scale 6
-- (offset 6:12), which the default cap of 1 forbids outright -- the knob would then be
-- testing nothing, since both halves would decline.
do
  reset_map() ; AID = addAreaName("knob_roe")
  local capWas = elro.TUNE.vertScaleCap ; elro.TUNE.vertScaleCap = 6
  local comps, lcs, adj, compOf = slab(10)
  local g1 = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(#g1, 2, "the run crosses the slab, so the dock DECLINES")
  elro.vertOverRoom = true
  local g2 = elro.vert_assemble(comps, lcs, adj, compOf)
  elro.vertOverRoom = nil
  eq(#g2, 1, "vertOverRoom: the same dock is accepted -- the far floor clears the slab")
  eq(elro._vertStats.honoured, 1, "...one honoured")
  -- ...and it is still a canonical offset. The knob relaxes WHAT MAY BE CROSSED, never
  -- the angle -- a vertical that is not provably non-compass would be a different feature.
  local dx, dy = offset(g2[1], (function()
    for r, q in pairs(lcs[1]) do if q[1] == 0 and q[2] == 0 then return r end end
  end)(), 9001)
  ok(canonical(dx, dy), string.format("...at a canonical offset still (%d,%d)", dx, dy))
  elro.TUNE.vertScaleCap = capWas
end

do
  -- ⛔ A COLLISION IS NEVER RELAXED. Widen the slab past the scale cap`s reach and every
  -- candidate lands on a ROOM rather than merely running over one, so the knob cannot help.
  reset_map() ; AID = addAreaName("knob_roe_collide")
  local comps, lcs, adj, compOf = slab(15)
  elro.vertOverRoom = true
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  elro.vertOverRoom = nil
  eq(#groups, 2, "vertROE does NOT relax a collision -- the wider slab still declines")
  eq(elro._vertStats.declined, 1, "...one decline")
end

do
  local capWas = elro.TUNE.vertScaleCap ; elro.TUNE.vertScaleCap = 6  -- fixture needs the step-out; default is 1
  -- ...and the knob's SECOND read site, `vert_realised`: a link nobody placed, at a
  -- canonical offset, with a room sitting dead on its run. Default refuses it the straight
  -- line; vertROE grants it, so the two sites stay in step. ⚠ If they ever drifted, the
  -- map would refuse to PLACE geometry it was willing to DRAW.
  local nS = redundant_case("roe_draw",
    { [1] = { 0, 0 }, [2] = { 1, 2 }, [3] = { 2, 4 } }, 1, 3, "up")
  eq(nS, 0, "default: a room on the run means no straight line")
  elro.vertOverRoom = true
  local nS2 = redundant_case("roe_draw2",
    { [1] = { 0, 0 }, [2] = { 1, 2 }, [3] = { 2, 4 } }, 1, 3, "up")
  elro.vertOverRoom = nil
  eq(nS2, 1, "vertOverRoom: the same link IS drawn straight, over the room in between")
  elro.TUNE.vertScaleCap = capWas
end

do
  local capWas = elro.TUNE.vertScaleCap ; elro.TUNE.vertScaleCap = 6  -- fixture needs the step-out; default is 1
  -- ⛔⛔ THE NARROWING, and it is the whole point of the knob's name. It shipped first as
  -- `vertROE`, relaxing ALL THREE room-on-edge refusals; the user cut it down the same day:
  -- *"But ROE is too accepting. It should accept ONLY the vert edges cutting through rooms.
  -- The placement of the actual rooms is NOT allowed to land on real edges."*
  -- This is the carry fixture from case 5b, whose second rung is pushed out to scale 2 by a
  -- stretched CORRIDOR sitting where scale 1 would land. Under the old knob that rung
  -- dropped back to scale 1, ON the corridor. Under this one it must NOT: a room of the
  -- arriving floor on a mass edge stays refused however the knob is set.
  reset_map() ; AID = addAreaName("narrow")
  local mass, at, byxy = {}, {}, {}
  local id = 0
  local function put(x, y) id = id + 1 ; room(id) ; mass[#mass + 1] = id ; at[id] = { x, y }
    byxy[x .. ":" .. y] = id ; return id end
  local row = {}
  for x = -6, 6 do row[x] = put(x, 0) end
  for x = -6, 5 do link(row[x], row[x + 1], "east") end
  local colr = { row[0] }
  for y = 1, 3 do colr[#colr + 1] = put(0, y) end
  local top = put(0, 4) ; colr[#colr + 1] = top
  for i = 1, #colr - 1 do link(colr[i], colr[i + 1], "north") end
  link(top, put(4, 4), "east")     -- the stretched edge, rastering (1,4) (2,4) (3,4)
  local S = row[0]
  local A, B = 9001, 9002
  room(A) ; room(B) ; stair(S, A) ; stair(A, B)
  elro.cs_reset()
  local function run()
    local comps, lcs, adj, compOf = scene({
      { rooms = mass, at = at },
      { rooms = { A }, at = { [A] = { 0, 0 } } },
      { rooms = { B }, at = { [B] = { 0, 0 } } },
    })
    return elro.vert_assemble(comps, lcs, adj, compOf)
  end
  local g1 = run()
  local b1 = { offset(g1[1], A, B) }
  elro.vertOverRoom = true
  local g2 = run()
  local b2 = { offset(g2[1], A, B) }
  elro.vertOverRoom = nil
  eq(b1[1] .. "," .. b1[2], "2,4", "default: the corridor pushes rung 2 out to scale 2")
  eq(b2[1] .. "," .. b2[2], b1[1] .. "," .. b1[2],
     "vertOverRoom leaves it there -- a room may still NOT land on a real edge")
  elro.TUNE.vertScaleCap = capWas
end

-- ---- 17b. THE dannoc FAN-OUT -- the user's own selection -----------------
-- ⭐⭐⭐ FOUR SEPARATE TWO-RUNG TOWERS off one floor, plus a downward link. In the LIVE map
-- all nine connectors came out on the same ray (+1,+2). The user:
-- *"Do all these verticals really need to have northeast pointing? It looks cluttered...
-- for an actual shaft I think it is desirable, but these are not true shafts?"* -- and that
-- is the exact distinction: WITHIN a tower the carry makes sameness deliberate, BETWEEN
-- independent towers nothing was asking the question, so all four tied on every ranking
-- term and fell through to the index, which is ray 1 every time.
-- ⚠ Hand-built from `mapdumpsel`, like the cathbad case: dannoc_on.txt carries ONE vertical
-- link, so the corpus cannot reach this shape at all.
-- ⛔⛔ AND THIS FIXTURE DOES **NOT** REPRODUCE THE CLUTTER -- checked, with the fan-out term
-- disabled it produces the same spread. What it pins is the STRUCTURE: canonical offsets,
-- towers internally consistent, and not everything on one ray. Case 17c is the fan-out test.
-- ⭐ THE REASON IS THE FINDING: the selection is 42 rooms, so its bounding box is small
-- enough that the four candidates give DIFFERENT boxes and compaction separates them on its
-- own. The live group is far bigger, the box does not move whichever ray is taken, every
-- term ties, and the INDEX decides -- which is ray 1, every time. Reproducing a tie-break
-- bug needs a fixture where the earlier terms actually tie.
do
  local capWas = elro.TUNE.vertScaleCap ; elro.TUNE.vertScaleCap = 6  -- fixture needs the step-out; default is 1
  reset_map() ; AID = addAreaName("dannoc_towers")
  local M = { [8659] = {16,35}, [8660] = {15,36}, [8661] = {15,35}, [8662] = {15,34},
              [8663] = {15,33}, [8664] = {15,32}, [8665] = {15,31}, [8666] = {16,31},
              [8667] = {17,31}, [8668] = {18,31}, [8669] = {19,31}, [8670] = {20,31},
              [8671] = {20,32}, [8672] = {20,33}, [8673] = {20,34}, [8674] = {20,35},
              [8675] = {20,36}, [8676] = {19,36}, [8677] = {18,36}, [8678] = {17,36},
              [8679] = {16,36}, [8680] = {16,32}, [8681] = {17,32}, [8689] = {19,32},
              [8690] = {18,32}, [8694] = {19,35}, [8695] = {18,35}, [8701] = {17,35} }
  local mr = {} ; for r in pairs(M) do mr[#mr + 1] = r end ; table.sort(mr)
  for _, r in ipairs(mr) do room(r) end
  link(8659, 8701, "east") ; link(8659, 8660, "northwest") ; link(8660, 8679, "east")
  link(8660, 8661, "south") ; link(8661, 8662, "south") ; link(8662, 8663, "south")
  link(8663, 8664, "south") ; link(8664, 8665, "south") ; link(8665, 8680, "northeast")
  link(8665, 8666, "east") ; link(8666, 8667, "east") ; link(8667, 8668, "east")
  link(8668, 8669, "east") ; link(8669, 8670, "east") ; link(8670, 8689, "northwest")
  link(8670, 8671, "north") ; link(8671, 8672, "north") ; link(8672, 8673, "north")
  link(8673, 8674, "north") ; link(8674, 8675, "north") ; link(8675, 8694, "southwest")
  link(8675, 8676, "west") ; link(8676, 8677, "west") ; link(8677, 8678, "west")
  link(8678, 8679, "west") ; link(8680, 8681, "east") ; link(8689, 8690, "west")
  link(8694, 8695, "west")
  -- the landings and their single-room top floors
  local specs = { { rooms = mr, at = M } }
  local function pair(a, b, d, at)          -- a two-room landing, its own component
    room(a) ; room(b) ; link(a, b, d)
    specs[#specs + 1] = { rooms = { a, b }, at = at }
  end
  local function solo(a)
    room(a) ; specs[#specs + 1] = { rooms = { a }, at = { [a] = { 0, 0 } } }
  end
  pair(8682, 8683, "north", { [8682] = { 0, 0 }, [8683] = { 0, 1 } })
  pair(8691, 8692, "north", { [8691] = { 0, 0 }, [8692] = { 0, 1 } })
  pair(8696, 8697, "south", { [8696] = { 0, 0 }, [8697] = { 0, -1 } })
  pair(8702, 8703, "south", { [8702] = { 0, 0 }, [8703] = { 0, -1 } })
  pair(8699, 8700, "south", { [8699] = { 0, 0 }, [8700] = { 0, -1 } })
  solo(8684) ; solo(8693) ; solo(8698) ; solo(8704)
  stair(8681, 8682) ; stair(8683, 8684)          -- tower 1
  stair(8690, 8691) ; stair(8692, 8693)          -- tower 2
  stair(8695, 8696) ; stair(8697, 8698)          -- tower 3
  stair(8701, 8702) ; stair(8703, 8704)          -- tower 4
  setExit(8694, 8699, "down") ; setExit(8699, 8694, "up")   -- ...and one going down
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene(specs)
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(#groups, 1, "the whole cluster assembles into one group")
  eq(elro._vertStats.honoured, 9, "all nine links are honoured")
  local G = groups[1]
  -- THE FEET: five independent docks, each the first rung of its own tower
  local feet = { { 8681, 8682 }, { 8690, 8691 }, { 8695, 8696 }, { 8701, 8702 },
                 { 8694, 8699 } }
  local rays = {}
  for _, f in ipairs(feet) do
    local dx, dy = offset(G, f[1], f[2])
    ok(canonical(dx, dy), string.format("%d->%d is canonical (%d,%d)", f[1], f[2], dx, dy))
    local k = math.min(math.abs(dx), math.abs(dy))
    -- UNSIGNED ray: two connectors look parallel whichever way they are walked
    local rx, ry = dx / k, dy / k
    if ry < 0 then rx, ry = -rx, -ry end
    rays[rx .. ":" .. ry] = (rays[rx .. ":" .. ry] or 0) + 1
  end
  local ndistinct = 0
  for _ in pairs(rays) do ndistinct = ndistinct + 1 end
  ok(ndistinct >= 2, "the independent towers do NOT all take one ray (got "
     .. ndistinct .. " distinct)")
  ok((rays["1:2"] or 0) < 5, "...specifically, not all five on (+1,+2) as before")
  -- ⭐ ...WHILE EACH TOWER IS STILL INTERNALLY CONSISTENT. That is the carry, and the fan-out
  -- must not have disturbed it: rung 2 repeats rung 1's ray in every tower.
  local rungs = { { 8681, 8682, 8683, 8684 }, { 8690, 8691, 8692, 8693 },
                  { 8695, 8696, 8697, 8698 }, { 8701, 8702, 8703, 8704 } }
  for _, t in ipairs(rungs) do
    local ax, ay = offset(G, t[1], t[2])
    local bx, by = offset(G, t[3], t[4])
    eq(ax * by - ay * bx, 0, "tower " .. t[1] .. ": both rungs on ONE line")
    ok(ax * bx + ay * by > 0, "...and climbing the same way")
  end
  elro.TUNE.vertScaleCap = capWas
end

-- ---- 17c. THE FAN-OUT, on a fixture where everything else TIES ----------
-- ⭐⭐⭐ THE MECHANISM, isolated. A long bar with four stair rooms on it: every child lands
-- clear of the mass (contacts 0 on both steep rays), and the mass is wide enough that the
-- bounding box is identical whichever of them is taken. So contacts tie, steep ties, area
-- and perimeter tie -- and before the fan-out term the INDEX decided, giving four parallel
-- connectors. That is the shape of the user's dannoc complaint, reduced to its cause.
-- ⚠ The towers here are single rooms on purpose: no carry, so every dock is an independent
-- choice and the term under test is the only thing that can separate them.
do
  reset_map() ; AID = addAreaName("fanout")
  local bar, at, byx = {}, {}, {}
  local id = 0
  for x = -20, 20 do
    id = id + 1 ; room(id) ; bar[#bar + 1] = id ; at[id] = { x, 0 } ; byx[x] = id
  end
  for x = -20, 19 do link(byx[x], byx[x + 1], "east") end
  local feet, specs = { -12, -4, 4, 12 }, { { rooms = bar, at = at } }
  for i, x in ipairs(feet) do
    local up = 9000 + i
    room(up) ; stair(byx[x], up)
    specs[#specs + 1] = { rooms = { up }, at = { [up] = { 0, 0 } } }
  end
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene(specs)
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(#groups, 1, "all four towers dock")
  eq(elro._vertStats.honoured, 4, "...all four honoured")
  eq(elro._vertStats.carried, 0, "...and NONE of them is a carry -- four free choices")
  local G, rays, ndistinct = groups[1], {}, 0
  for i, x in ipairs(feet) do
    local dx, dy = offset(G, byx[x], 9000 + i)
    ok(canonical(dx, dy), string.format("tower %d canonical (%d,%d)", i, dx, dy))
    eq(dy > 0, true, "tower " .. i .. " climbs")
    eq(math.abs(dy), 2, "tower " .. i .. " keeps the STEEP ratio -- fan-out ranks below it")
    local k = math.min(math.abs(dx), math.abs(dy))
    rays[(dx / k) .. ":" .. (dy / k)] = true
  end
  for _ in pairs(rays) do ndistinct = ndistinct + 1 end
  ok(ndistinct >= 2, "the four independent towers FAN OUT (got " .. ndistinct
     .. " distinct rays, index alone would give 1)")
end

-- ---- 17d. CROSSINGS ARE FINE OUTSIDE, NOT INSIDE A FACE ------------------
-- ⭐⭐⭐ The user's rule: *"It's ok to accept a crossing for the vertical if it is placed
-- outside the main grid. But if it is placed inside a face, then crossings are not ok in my
-- opinion."*  A sealed 9x9 ring of rooms with a stair room hanging below the middle of its
-- south wall: at scale 1 the steep candidates land in the ring's INTERIOR and the connector
-- cuts the wall to get there. That is the case the rule exists to refuse.
-- ⚠ "Inside" is a flood over free cells, so a 1-cell-thick wall seals it even against an
-- 8-connected flood -- every border cell is a room.
local function ring_scene()
  reset_map() ; AID = addAreaName("ring" .. tostring(elro.vertNoCrossInFace))
  local wall, at, byxy = {}, {}, {}
  local id = 0
  local function put(x, y) id = id + 1 ; room(id) ; wall[#wall + 1] = id ; at[id] = { x, y }
    byxy[x .. ":" .. y] = id ; return id end
  for x = 0, 8 do put(x, 0) ; put(x, 8) end
  for y = 1, 7 do put(0, y) ; put(8, y) end
  local S = put(4, -1)                       -- the stair room, OUTSIDE the ring
  for _, r in ipairs(wall) do
    local q = at[r]
    local e, n = byxy[(q[1] + 1) .. ":" .. q[2]], byxy[q[1] .. ":" .. (q[2] + 1)]
    if e then link(r, e, "east") end
    if n then link(r, n, "north") end
  end
  room(9001) ; stair(S, 9001)
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = wall, at = at }, { rooms = { 9001 }, at = { [9001] = { 0, 0 } } },
  })
  return elro.vert_assemble(comps, lcs, adj, compOf), S
end
-- ⚠ "docked inside the face" is TWO conditions, and testing only the coordinate would be a
-- false positive: a DECLINED child becomes its own group and keeps its own local (0,0),
-- which reads as inside the ring by coordinate alone. It has to be in the wall's group too.
local function docked_inside(groups)
  if #groups ~= 1 then return false end
  local q = groups[1].coord[9001]
  return q ~= nil and q[1] > 0 and q[1] < 8 and q[2] > 0 and q[2] < 8
end
do
  -- ⚠ BOTH LEGS ARE PINNED EXPLICITLY. The rule became the DEFAULT on 2026-08-19, so the
  -- "off" leg has to say `= false` -- a fixture that relied on the old default silently
  -- became a test of nothing the moment the default flipped, and this one did.
  elro.vertNoCrossInFace = false
  local g1 = ring_scene()
  elro.vertNoCrossInFace = nil
  eq(#g1, 1, "rule OFF: the floor docks")
  ok(docked_inside(g1), "...INSIDE the ring, with the connector cutting the wall")
  local g2 = ring_scene()            -- default: the rule is ON
  ok(not docked_inside(g2),
     "rule ON (the default): it does NOT land inside the face any more")
  if #g2 == 1 then
    local S
    for r, c in pairs(g2[1].coord) do if c[1] == 4 and c[2] == -1 then S = r end end
    local dx, dy = offset(g2[1], S, 9001)
    ok(canonical(dx, dy), string.format("...and wherever it went is canonical (%d,%d)", dx, dy))
  end
end

do
  -- ⚠ AND THE RULE MUST BE SILENT WHERE THERE IS NOTHING TO JUDGE. A plain bar with a
  -- stair off it: the connector crosses nothing, so the knob may not change the answer.
  local function bar_scene()
    reset_map() ; AID = addAreaName("bar" .. tostring(elro.vertNoCrossInFace))
    local bar, at, byx = {}, {}, {}
    local id = 0
    for x = -8, 8 do id = id + 1 ; room(id) ; bar[#bar + 1] = id ; at[id] = { x, 0 } ; byx[x] = id end
    for x = -8, 7 do link(byx[x], byx[x + 1], "east") end
    room(9001) ; stair(byx[0], 9001)
    elro.cs_reset()
    local comps, lcs, adj, compOf = scene({
      { rooms = bar, at = at }, { rooms = { 9001 }, at = { [9001] = { 0, 0 } } },
    })
    return elro.vert_assemble(comps, lcs, adj, compOf), byx[0]
  end
  elro.vertNoCrossInFace = false
  local g1, s1 = bar_scene()
  elro.vertNoCrossInFace = nil
  local a1 = { offset(g1[1], s1, 9001) }
  local g2, s2 = bar_scene()         -- default: the rule is ON
  local a2 = { offset(g2[1], s2, 9001) }
  eq(a2[1] .. "," .. a2[2], a1[1] .. "," .. a1[2],
     "no crossing to judge -> the rule changes nothing")
end

-- ---- 19. THE BRIDGE PISTON (elro.vertPiston) -----------------------------
-- ⭐⭐⭐ THE ONE TIER ALLOWED TO MOVE ROOMS THE WALK ALREADY PLACED, so it is also the
-- one that has to prove it cannot make an area worse. Every case below pins BOTH legs
-- of the knob explicitly -- ⛔ test 17d's "off" leg was the bare default, and flipping
-- that default turned the whole A/B into a test of nothing.
--
-- ⚠⚠ AND THIS IS ALL THE COVERAGE THERE IS, BECAUSE THE CORPUS IS INERT. Across all 14
-- dumps exactly TWO undrawn links sit within `TUNE.vertPistonL1` of legal, and both are
-- refused for the right reasons -- world_live `5248 down 5249` would collide whichever
-- way it is pushed, titleist `1349 down 1660` needs an x correction and every bridge
-- separating its ends runs diagonally or is already at minimum length. So the corpus
-- proves the REFUSALS and cannot prove the acceptance; these fixtures have to.
--
-- THE SHARED SCENE, hand-built so every bridge and every offset is known by hand:
--
--        6---4              1 up-> 6 is REDUNDANT (both ends in one component) and comes
--            |              out at offset (0,+2) -- one cell short of the canonical
--            3              (+1,+2). The only correction is (+-1, 0), and the only
--            |              bridge on the path between 1 and 6 that runs along x is
--        1---2              `1-2` east. Stretching it one cell east slides {2,3,4,6}
--                           (and everything docked to them) and the link lands exactly.
-- 100/101 is a second component docked onto room 3 by a FOREST link -- it is there for
-- two reasons: `vert_assemble` returns early with no forest link at all, and room 3 is
-- on the MOVING side, so the fixture also asserts the piston carried a docked subtree.
local function piston_scene(extra)
  reset_map() ; AID = addAreaName("piston" .. tostring(extra and extra.tag or ""))
  local rooms1 = { 1, 2, 3, 4, 6 }
  local at1 = { [1] = { 0, 0 }, [2] = { 1, 0 }, [3] = { 1, 1 }, [4] = { 1, 2 }, [6] = { 0, 2 } }
  for _, r in ipairs(rooms1) do room(r) end
  link(1, 2, "east") ; link(2, 3, "north") ; link(3, 4, "north") ; link(4, 6, "west")
  room(100) ; room(101) ; link(100, 101, "east")
  stair(1, 6)                                    -- REDUNDANT: both ends in component 1
  stair(3, 100)                                  -- FOREST: docks 100/101 onto room 3
  if extra and extra.build then extra.build(rooms1, at1) end
  elro.cs_reset()
  return scene({
    { rooms = rooms1, at = at1 },
    { rooms = { 100, 101 }, at = { [100] = { 0, 0 }, [101] = { 1, 0 } } },
  })
end

-- 19a. IT APPLIES, AND IT CARRIES.
do
  elro.vertPiston = true
  local comps, lcs, adj, compOf = piston_scene({ tag = "a" })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  eq(#groups, 1, "piston: the forest link still folds both components into one group")
  local G = groups[1]
  local dx, dy = offset(G, 1, 6)
  eq(dx .. "," .. dy, "1,2", "piston: the near-miss link is now at the canonical (+1,+2)")
  eq(canonical(dx, dy), 1, "piston: ...and `canonical` agrees, at scale 1")
  eq(dy > 0, true, "piston: UP is still +y -- the correction may not flip the sense")
  eq(elro._vertStats.pistApp, 1, "piston: stats say exactly one was applied")
  no_overlap(G, "piston applied")
  -- the bridge STRETCHED, it did not shear: 1-2 is still a pure east edge
  local bx, by = offset(G, 1, 2)
  eq(by, 0, "piston: the stretched bridge 1-2 is still horizontal (no shear)")
  eq(bx, 2, "piston: ...and it grew from 1 cell to 2")
  -- ⭐ THE CARRY. 100 is docked onto room 3, which is on the moving side, so it had to
  -- move with it or the pack would have silently broken a promise it had already made.
  local hx, hy = offset(G, 3, 100)
  ok(canonical(hx, hy), string.format(
     "piston: the honoured link 3->100 is STILL exact (%d,%d)", hx, hy))
  local ex, ey = offset(G, 100, 101)
  eq(ex .. "," .. ey, "1,0", "piston: ...and the docked component moved RIGID")
end

-- 19b. THE KNOB IS OFF BY DEFAULT, and the same scene must then be untouched.
-- ⛔ BOTH LEGS PINNED. `vertPiston = false` here, `= true` above: the bare default is
-- not a leg of an A/B, because a default flip would make both legs assert one thing.
do
  elro.vertPiston = false
  local comps, lcs, adj, compOf = piston_scene({ tag = "b" })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  local dx, dy = offset(groups[1], 1, 6)
  eq(dx .. "," .. dy, "0,2", "piston OFF: the near-miss link is left exactly as it landed")
  eq(canonical(dx, dy), nil, "piston OFF: ...i.e. still not canonical, still drawn bent")
  local bx = offset(groups[1], 1, 2)
  eq(bx, 1, "piston OFF: the bridge is untouched")
  eq(elro._vertStats.pistApp, 0, "piston OFF: nothing tried, nothing applied")
end

-- 19c. THE GATE: A COLLISION IS NEVER WORTH A CONNECTOR.
-- The same scene with a static room parked exactly where room 2 would land. It hangs
-- off room 1 by a path that never touches the bridge, so it stays put while the moving
-- side slides into it -- and `count_defects` says collisions 0 -> 1.
-- ⚠⚠ AND THE FIXTURE HAD TO CLOSE BOTH ESCAPES, WHICH IS THE LESSON IN IT. The first
-- version blocked the east bridge only, and the piston quietly went out the other side:
-- `4 -west-> 6` is also an x-axis bridge on the path, and LENGTHENING it puts 6 at
-- (-1,+2), which is just as canonical. It applied, the assertion failed, and the engine
-- was right -- ⭐ A GATE FIXTURE HAS TO BLOCK EVERY VIABLE PISTON, not the one the
-- author had in mind, or it tests the search order instead of the gate.
do
  elro.vertPiston = true
  local comps, lcs, adj, compOf = piston_scene({ tag = "c", build = function(rooms1, at1)
    -- east escape: 11 parks where room 2 would land
    room(7) ; room(8) ; room(9) ; room(11)
    link(1, 7, "south") ; link(7, 8, "east") ; link(8, 9, "east") ; link(9, 11, "north")
    at1[7] = { 0, -1 } ; at1[8] = { 1, -1 } ; at1[9] = { 2, -1 } ; at1[11] = { 2, 0 }
    -- west escape: 14 parks where room 6 would land
    room(12) ; room(13) ; room(14)
    link(1, 12, "west") ; link(12, 13, "north") ; link(13, 14, "north")
    at1[12] = { -1, 0 } ; at1[13] = { -1, 1 } ; at1[14] = { -1, 2 }
    for _, r in ipairs({ 7, 8, 9, 11, 12, 13, 14 }) do rooms1[#rooms1 + 1] = r end
  end })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  local dx, dy = offset(groups[1], 1, 6)
  eq(dx .. "," .. dy, "0,2", "piston gate: a piston that would collide is REVERTED")
  eq(offset(groups[1], 1, 2), 1, "piston gate: ...and the bridge is put back")
  ok((elro._vertStats.pistTry or 0) > 0, "piston gate: it really was tried")
  eq(elro._vertStats.pistApp, 0, "piston gate: ...and not applied")
  no_overlap(groups[1], "piston gate")
end

-- 19d. THE AXIS RULE -- the constraint that shapes the whole search, and the one the
-- corpus is a witness for: BOTH titleist near-misses need an x correction while every
-- bridge separating their ends runs diagonally. Here the path from 1 to 6 is pure
-- north/south, so a (+-1, 0) correction has no axis to ride and nothing is even tried.
do
  elro.vertPiston = true
  reset_map() ; AID = addAreaName("piston-axis")
  local rooms1 = { 1, 5, 6 }
  for _, r in ipairs(rooms1) do room(r) end
  link(1, 5, "north") ; link(5, 6, "north")
  room(100) ; room(101) ; link(100, 101, "east")
  stair(1, 6) ; stair(5, 100)
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = rooms1, at = { [1] = { 0, 0 }, [5] = { 0, 1 }, [6] = { 0, 2 } } },
    { rooms = { 100, 101 }, at = { [100] = { 0, 0 }, [101] = { 1, 0 } } },
  })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  local dx, dy = offset(groups[1], 1, 6)
  eq(dx .. "," .. dy, "0,2", "axis rule: an x correction over a north/south path is refused")
  eq(elro._vertStats.pistTry, 0, "axis rule: ...and it is refused WITHOUT a trial")
  eq(elro._vertStats.pistApp, 0, "axis rule: nothing applied")
end

-- 19e. OUT OF RANGE -- the other half of the corpus finding. A link 14 cells from legal
-- is not a "minor layout adjustment" and must not be chased; the pass reports the
-- distance and does nothing. `TUNE.vertPistonL1` is where that line is drawn.
do
  elro.vertPiston = true
  reset_map() ; AID = addAreaName("piston-far")
  local rooms1, at1 = {}, {}
  for i = 0, 9 do
    local id = 200 + i ; room(id) ; rooms1[#rooms1 + 1] = id ; at1[id] = { i, 0 }
    if i > 0 then link(200 + i - 1, id, "east") end
  end
  room(100) ; room(101) ; link(100, 101, "east")
  stair(200, 209)                                -- REDUNDANT, offset (+9,0): nowhere near
  stair(205, 100)                                -- FOREST, so the assembly runs at all
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = rooms1, at = at1 },
    { rooms = { 100, 101 }, at = { [100] = { 0, 0 }, [101] = { 1, 0 } } },
  })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  local dx, dy = offset(groups[1], 200, 209)
  eq(dx .. "," .. dy, "9,0", "out of range: a link 8 cells from legal is left alone")
  eq(elro._vertStats.pistTry, 0, "out of range: nothing is tried")
end

-- 19f. A LONGER BRIDGE MAY BE SHORTENED, but never past adjacency -- the mirror of 19a,
-- and the case that decides titleist. `1 -east-> 2` is FIVE cells long here and the link
-- needs one cell back; pulling it in lands `1 up-> 4` on (+4,+2) = 2 x (+2,+1). The very
-- same test at length ONE is what refuses titleist's only east bridge, so this fixture and
-- that refusal are the two sides of `m + t >= 1`.
-- ⚠ THE PATH FROM 1 TO 4 CARRIES NO OTHER x-AXIS BRIDGE. 19c is the fixture that learned
-- why that matters: leave a second one open and the piston takes it, and the assertion
-- ends up describing the search order rather than the rule.
do
  local capWas = elro.TUNE.vertScaleCap ; elro.TUNE.vertScaleCap = 6  -- fixture asserts scale 2; default is 1
  elro.vertPiston = true
  reset_map() ; AID = addAreaName("piston-shrink")
  local rooms1 = { 1, 2, 3, 4 }
  local at1 = { [1] = { 0, 0 }, [2] = { 5, 0 }, [3] = { 5, 1 }, [4] = { 5, 2 } }
  for _, r in ipairs(rooms1) do room(r) end
  link(1, 2, "east") ; link(2, 3, "north") ; link(3, 4, "north")
  room(100) ; room(101) ; link(100, 101, "east")
  stair(1, 4)                                    -- REDUNDANT, offset (+5,+2)
  stair(100, 1)                                  -- FOREST, and it hangs off the STATIC side
  elro.cs_reset()
  local comps, lcs, adj, compOf = scene({
    { rooms = rooms1, at = at1 },
    { rooms = { 100, 101 }, at = { [100] = { 0, 0 }, [101] = { 1, 0 } } },
  })
  local groups = elro.vert_assemble(comps, lcs, adj, compOf)
  local dx, dy = offset(groups[1], 1, 4)
  eq(dx .. "," .. dy, "4,2", "shrink: the 5-cell bridge was pulled in to land the link")
  eq(canonical(dx, dy), 2, "shrink: ...at scale 2, and the run's one interior cell is clear")
  eq(offset(groups[1], 1, 2), 4, "shrink: the bridge is 4 cells, still truthfully east")
  eq(elro._vertStats.pistApp, 1, "shrink: one piston applied")
  elro.TUNE.vertScaleCap = capWas
end

-- 19g. NO FOREST LINK AT ALL -- the case the assembly used to return `nil` for, and
-- the one a piston fits best. A `redundant` stair has both ends inside ONE compass
-- component, so no packer can ever help it: the two rooms are already in one rigid
-- body, which is exactly the body a bridge cuts in two.
-- ⚠ AND THE `nil` CONTRACT SURVIVES. With the knob off (or with nothing moved) the
-- branch still returns `nil`, which is what tells compose_spqr_adj to shelf-pack bare
-- components the way it did before any of this existed.
do
  local function lone_scene(tag)
    reset_map() ; AID = addAreaName("piston-lone" .. tag)
    local rooms1 = { 1, 2, 3, 4, 6 }
    local at1 = { [1] = { 0, 0 }, [2] = { 1, 0 }, [3] = { 1, 1 }, [4] = { 1, 2 }, [6] = { 0, 2 } }
    for _, r in ipairs(rooms1) do room(r) end
    link(1, 2, "east") ; link(2, 3, "north") ; link(3, 4, "north") ; link(4, 6, "west")
    stair(1, 6)
    elro.cs_reset()
    return scene({ { rooms = rooms1, at = at1 } })
  end
  elro.vertPiston = false
  local g0 = elro.vert_assemble(lone_scene("off"))
  eq(g0, nil, "no forest link + piston OFF: still the plain `nil` contract")
  elro.vertPiston = true
  local g1 = elro.vert_assemble(lone_scene("on"))
  ok(g1 ~= nil, "no forest link + piston ON: the pass runs and hands back groups")
  if g1 then
    local dx, dy = offset(g1[1], 1, 6)
    eq(dx .. "," .. dy, "1,2", "no forest link: the redundant stair is landed anyway")
  end
end

-- 19h. A ONE-WAY BRIDGE IS STILL A BRIDGE. Tarjan runs on the undirected graph, so a
-- corridor walked in one direction only becomes a bridge like any other -- but its
-- compass direction is recorded at the FAR end. Reading it from the near end alone
-- would skip it as though it were a vertical, which is a false negative that looks
-- exactly like the axis rule working correctly. [[project_asymmetric_exits]].
do
  elro.vertPiston = true
  reset_map() ; AID = addAreaName("piston-oneway")
  local rooms1 = { 1, 2, 3, 4, 6 }
  local at1 = { [1] = { 0, 0 }, [2] = { 1, 0 }, [3] = { 1, 1 }, [4] = { 1, 2 }, [6] = { 0, 2 } }
  for _, r in ipairs(rooms1) do room(r) end
  setExit(2, 1, "west")                          -- ⚠ ONE WAY: nothing says 1 -east-> 2
  link(2, 3, "north") ; link(3, 4, "north") ; link(4, 6, "west")
  stair(1, 6)
  elro.cs_reset()
  local groups = elro.vert_assemble(scene({ { rooms = rooms1, at = at1 } }))
  ok(groups ~= nil, "one-way bridge: the piston still found something to do")
  if groups then
    local dx, dy = offset(groups[1], 1, 6)
    eq(dx .. "," .. dy, "1,2", "one-way bridge: stretched from the far end's direction")
    eq(offset(groups[1], 1, 2), 2, "one-way bridge: ...it really was 1-2 that grew")
  end
end

elro.vertPiston = nil

-- ---- 20. MAKE ROOM (elro.vertMakeRoom) ----------------------------------
-- ⭐⭐⭐ THE OTHER PISTON TRIGGER, and the one the user asked for first: *"use pistons on
-- the existing geometry that we dock to in order to make space for the placement if
-- there is no room"*. Where case 19 CLOSES A GAP at the end of the pass, this one FREES
-- A CELL before a dock -- it fires only where the packer is about to DECLINE.
--
-- ⭐ AND UNLIKE CASE 19, THE CORPUS EXERCISES BOTH PATHS OF THIS ONE, which is why these
-- fixtures can be few. Across the dumps it reverts 63 pistons (world_live 12, soulfly 40,
-- dannoc 7, kadagar 4) and rescues world_live's `5245 up 5251` -- so the gate and the
-- accept path are both real-data-tested. What the fixtures add is the geometry stated by
-- hand, so a failure says which rule broke.
--
-- THE SCENE, with `vertScale = 1` so the four scale-1 targets are the WHOLE search and
-- can each be blocked by one room:
--
--     30--31--32          bar B sits on (-1,2) (0,2) (1,2)
--         |
--  20-21-22-23-24         bar A sits on (-2,1) .. (2,1)
--         |
--         1               the stair room; 100 wants one of (+-1,+2) / (+-2,+1)
--
-- Every one of the four canonical offsets from room 1 is occupied, so the dock declines.
-- ⭐ THE PISTON THAT WORKS IS `22-31 north`: bar B is the smallest side holding the
-- blocker, and sliding it one cell up frees (1,2) while the stretched bridge only ever
-- covers (0,2), which bar B just vacated. Bar A never moves.
local function room_scene(tag)
  reset_map() ; AID = addAreaName("makeroom" .. tag)
  local rooms1, at1 = {}, {}
  local function put(id, x, y) room(id) ; rooms1[#rooms1 + 1] = id ; at1[id] = { x, y } end
  put(1, 0, 0)
  local barA = { 20, 21, 22, 23, 24 }
  for i, id in ipairs(barA) do put(id, i - 3, 1) end
  for i = 1, #barA - 1 do link(barA[i], barA[i + 1], "east") end
  local barB = { 30, 31, 32 }
  for i, id in ipairs(barB) do put(id, i - 2, 2) end
  for i = 1, #barB - 1 do link(barB[i], barB[i + 1], "east") end
  link(1, 22, "north") ; link(22, 31, "north")
  room(100) ; stair(1, 100)                      -- 100 is the UPPER floor
  elro.cs_reset()
  return scene({
    { rooms = rooms1, at = at1 },
    { rooms = { 100 }, at = { [100] = { 0, 0 } } },
  })
end

-- 20a. IT MAKES ROOM, AND THE DOCK THEN FITS.
do
  elro.TUNE.vertScaleCap = 1 ; elro.vertMakeRoom = true
  local groups = elro.vert_assemble(room_scene("a"))
  eq(#groups, 1, "make room: the rescued dock folds both components into ONE group")
  local G = groups[1]
  eq(elro._vertStats.declined, 0, "make room: the link is no longer declined")
  eq(elro._vertStats.honoured, 1, "make room: ...it is honoured")
  eq(elro._vertStats.roomApp, 1, "make room: ...by exactly one piston")
  local dx, dy = offset(G, 1, 100)
  eq(dx .. "," .. dy, "1,2", "make room: the floor docked on the freed cell")
  eq(canonical(dx, dy), 1, "make room: ...at scale 1, the nearest floor")
  -- the mass moved, and moved the way the rule says: bar B slid, bar A did not
  local bx, by = offset(G, 22, 31)
  eq(bx .. "," .. by, "0,2", "make room: the bridge 22-31 stretched from 1 cell to 2,"
     .. " and stayed vertical")
  local ex, ey = offset(G, 30, 32)
  eq(ex .. "," .. ey, "2,0", "make room: bar B moved RIGID -- a piston deforms nothing")
  eq(offset(G, 20, 24), 4, "make room: ...and bar A, on the near side, never moved")
  local ax, ay = offset(G, 1, 22)
  eq(ax .. "," .. ay, "0,1", "make room: the untouched bridge 1-22 is still one cell")
  no_overlap(G, "make room")
end

-- 20b. THE KNOB IS OFF BY DEFAULT, and the same scene must then decline exactly as it
-- always did -- the component shelf-packed on its own, the mass untouched.
-- ⛔ BOTH LEGS PINNED (`= false` here, `= true` above); the bare default is not a leg.
do
  elro.TUNE.vertScaleCap = 1 ; elro.vertMakeRoom = false
  local groups = elro.vert_assemble(room_scene("b"))
  eq(#groups, 2, "make room OFF: the dock declines and the component packs alone")
  eq(elro._vertStats.declined, 1, "make room OFF: ...recorded as a decline")
  eq(elro._vertStats.roomApp, 0, "make room OFF: nothing applied")
  local ox, oy = offset(groups[1], 22, 31)
  eq(ox .. "," .. oy, "0,1", "make room OFF: the mass is untouched")
end

-- 20c. A RIGID MASS IS NEVER TOUCHED. The blockers here form a closed ring with the
-- stair room on it -- one biconnected block, no bridge anywhere -- so there is no side
-- to slide and the pass must not invent one. This is the guardrail that keeps the tier
-- honest: a piston is legal because a BRIDGE cancels out of the closure sum, and no
-- other cut has that property.
do
  elro.TUNE.vertScaleCap = 1 ; elro.vertMakeRoom = true
  reset_map() ; AID = addAreaName("makeroom-rigid")
  -- a 12-room rectangle ring through (0,0), covering all four canonical offsets
  local cyc = { { 1, 0, 0 }, { 41, 1, 0 }, { 42, 2, 0 }, { 43, 2, 1 }, { 44, 2, 2 },
                { 45, 1, 2 }, { 46, 0, 2 }, { 47, -1, 2 }, { 48, -2, 2 }, { 49, -2, 1 },
                { 50, -2, 0 }, { 51, -1, 0 } }
  local rooms1, at1 = {}, {}
  for _, c in ipairs(cyc) do
    room(c[1]) ; rooms1[#rooms1 + 1] = c[1] ; at1[c[1]] = { c[2], c[3] }
  end
  for i = 1, #cyc do
    local a, b = cyc[i], cyc[(i % #cyc) + 1]
    local d
    if b[2] > a[2] then d = "east" elseif b[2] < a[2] then d = "west"
    elseif b[3] > a[3] then d = "north" else d = "south" end
    link(a[1], b[1], d)
  end
  room(100) ; stair(1, 100)
  elro.cs_reset()
  local groups = elro.vert_assemble(scene({
    { rooms = rooms1, at = at1 },
    { rooms = { 100 }, at = { [100] = { 0, 0 } } },
  }))
  eq(elro._vertStats.declined, 1, "rigid mass: the dock still declines")
  eq(elro._vertStats.roomTry, 0, "rigid mass: ...and NOT ONE piston was tried")
  eq(offset(groups[1], 1, 41), 1, "rigid mass: the ring is exactly where it was")
end

-- 20d. "MINOR" IS PRICED, AND THE DEFECT GATE CANNOT PRICE IT. Stretching a bridge adds
-- no defect -- that is the theorem the whole tier rests on -- so a piston that shoves
-- half an area five cells sideways passes the defect gate with an IDENTICAL census and
-- simply INFLATES the map. soulfly is the witness: 79 rooms x 5 cells, `hole 43 -> 93`.
-- `vertRoomWork` is the term that says how minor is minor, in rooms-moved x cells-moved.
-- Here the winning piston moves bar B (3 rooms) one cell, so it costs 3; price it at 2
-- and the dock must go back to declining rather than quietly costing more.
-- ⚠ `vertScale` and `vertRoomWork` became TUNE constants in the 2026-08-21 knob review, so this
-- fixture sets them through `elro.TUNE` (published at layout.lua:220 as a measurement handle).
-- `vertMakeRoom` is still a knob -- it is one of three the vertical renderer's fixtures need in
-- order to construct an OFF scene at all, which is why it survived the fold.
-- ⛔ SAVED OUTSIDE THE `do`, because the restore below is outside it too. Clearing a knob with `nil`
-- restored its default for free; a TUNE constant has no such fallback, so a saved value that fell
-- out of scope would set the cap to nil and every later fixture would inherit it.
local capWas, workWas = elro.TUNE.vertScaleCap, elro.TUNE.vertRoomWork
do
  elro.TUNE.vertScaleCap = 1 ; elro.vertMakeRoom = true ; elro.TUNE.vertRoomWork = 2
  local groups = elro.vert_assemble(room_scene("d"))
  eq(elro._vertStats.declined, 1, "work cap: a piston that costs more than the cap is refused")
  eq(elro._vertStats.roomApp, 0, "work cap: ...nothing applied")
  local ox, oy = offset(groups[1], 22, 31)
  eq(ox .. "," .. oy, "0,1", "work cap: the mass is untouched")
  -- ⚠ AND THE PRICE IS CHECKED BEFORE THE TRIAL, not after -- an over-large piston
  -- must cost nothing at all to refuse, because the trial is the dear part (a whole
  -- occupancy rebuild plus a fresh ray search). At a cap of zero NOTHING is affordable,
  -- so a single trial here would mean the check had moved behind the work.
  elro.TUNE.vertRoomWork = 0
  elro.vert_assemble(room_scene("d0"))
  eq(elro._vertStats.roomTry, 0, "work cap: priced BEFORE the trial, so a refusal is free")
  elro.TUNE.vertRoomWork = workWas
end

elro.TUNE.vertScaleCap = capWas ; elro.vertMakeRoom = nil ; elro.TUNE.vertRoomWork = workWas

-- ---- 18. THE DEFAULT PATH -- vertPack OFF, nothing to draw ---------------
-- ⛔⛔ THE HOLE THIS FILE HAD. Every case above sets `elro._vertLinks` first, so the
-- early-out in draw_vertical -- the branch that runs on EVERY relayout with the knob off --
-- was the one path nothing here executed. It shipped returning three values where the real
-- return had grown to four, and `draw_vertical_map` formats all four into a trace string
-- that string.format builds BEFORE elro.tr can decide it is not tracing. Every relayout
-- died. The canary caught it; this file should have.
-- ⭐ THE LESSON IS ABOUT ARITY, not about verticals: a multi-value return with an early-out
-- has two signatures to keep in step, and only one of them is exercised by the tests that
-- care about the feature.
do
  elro._vertLinks = nil
  local a, b, c, d = elro.draw_vertical({})
  eq(a, 0, "no links: straight count is 0, not nil")
  eq(b, 0, "...bent 0")
  eq(c, 0, "...silent 0")
  eq(d, 0, "...and the FOURTH value is 0 too -- the early-out matches the real arity")
  local ok_, err = pcall(elro.draw_vertical_map, {})
  ok(ok_, "draw_vertical_map survives the default path (" .. tostring(err) .. ")")
end

-- the recorder installed for test 15 comes off here, after the last case that draws
addCustomLine = realAdd
elro._vertLinks = nil

print(string.format("test_vertpack: %d check(s), %d failure(s)", ntest, fail))
os.exit(fail == 0 and 0 or 1)
