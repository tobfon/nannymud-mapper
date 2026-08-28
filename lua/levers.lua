-- Lever engine: stitch, stretch energy, candidate scoring/ranking, lever core.
-- Split out of layout.lua; see lua/modules.lua for the load order.

elro = elro or {}
local G = elro.g or error("levers.lua: lua/geom.lua must be loaded first (see elro.modules)")
local ori = G.ori
local seg = G.seg
local seg_hits = G.seg_hits
local K = elro.k or error("levers.lua: lua/keys.lua must be loaded first (see elro.modules)")
local ekey = K.edge
local eid = K.eid
local each_exit = elro.exits or error("levers.lua: lua/core.lua must be loaded first")
local CLK = elro.clk or error("levers.lua: lua/core.lua must be loaded first")
local TUNE = elro.TUNE or error("levers.lua: lua/tune.lua must be loaded first")

-- STAGE 4 (loop-cut + stitch): shift the two cut endpoints so a->b renders truthfully,
-- driven by an incremental deviation cost through _lever_core. Residual -> portal.
function elro.stitch_one(coord, adj, a, b, del)
  if not (coord[a] and coord[b] and del) then return false end
  local dx0, dy0 = del[1], del[2]
  local parmin = dx0 * dx0 + dy0 * dy0
  -- deviation cost from the truthful del RAY (not the del point, which would tie an
  -- off-axis cell with a colinear one). Primary: perpendicular offset; wrong side
  -- penalised hard; excess length past adjacency a light cost.
  local function costAt(pa, pb)
    local ox, oy = pb[1] - pa[1], pb[2] - pa[2]
    local perp = ox * dy0 - oy * dx0
    local par = ox * dx0 + oy * dy0
    local c = perp * perp * 1000
    if par < parmin then c = c + (parmin - par) * (parmin - par) * 1000
    else c = c + (par - parmin) end
    return c
  end
  local function truthful()
    local ox, oy = coord[b][1] - coord[a][1], coord[b][2] - coord[a][2]
    return (ox * dy0 - oy * dx0) == 0 and (ox * dx0 + oy * dy0) >= parmin
  end
  if truthful() then return true end

  -- defect-check inputs (room membership + edge identities constant; only positions move).
  -- Use the CUT adj so the open a-b gap is not itself counted as a crossing.
  local placed, pedges, seenPE = {}, {}, {}
  for r in pairs(coord) do placed[r] = true end
  elro._bfGen = (elro._bfGen or 0) + 1
  for r in pairs(coord) do
    for d, v in each_exit(adj[r]) do
      local de = elro.delta[d]
      if coord[v] and de and (de[1] ~= 0 or de[2] ~= 0) then
        local ek = ekey(r, v)
        if not seenPE[ek] then seenPE[ek] = true ; pedges[#pedges + 1] = { u = r, v = v } end
      end
    end
  end
  local base = elro.count_defects(coord, placed, pedges)
  local o0x, o0y = coord[b][1] - coord[a][1], coord[b][2] - coord[a][2]
  -- mark the start of this cut's stitch so mapstep has a clear phase boundary even if
  -- no pull is applied (the per-pull snaps below carry the incremental lever moves).
  elro.step_snap(coord, string.format("stitch BEGIN %d-%d off=(%d,%d) del=(%d,%d)",
    a, b, o0x, o0y, dx0, dy0), b, a)

  -- shift applicator matching the walk's cand_shift: guillotine cuts carry a per-room
  -- `deltas` table (a half-plane moves), other levers a flat set*dx*dist.
  local function cshift(c, r)
    if c.deltas then local e = c.deltas[r] ; if e then return e[1], e[2] end ; return 0, 0 end
    if c.set and c.set[r] then return (c.dx or 0) * (c.dist or 0), (c.dy or 0) * (c.dist or 0) end
    return 0, 0
  end
  -- Toolbox unblock: when both arm tips are pinned, try the walk's guillotine/chord-slack
  -- closures tentatively; keep a move only if it lowers the cost and adds no defect.
  local function try_unblock()
    local T = elro._stitchTools
    if not (T and T.qbl) then return false end
    local cur = costAt(coord[a], coord[b])
    -- Rigid blocks + nearest-rigid anchor BFS: query_block_levers' own guardrail,
    -- pre-checked cheaply before paying for its detectors. Spatial-only adjacency
    -- (drop up/down), matching how qbl builds its blocks.
    local roomsL, radj = {}, {}
    for r in pairs(placed) do roomsL[#roomsL + 1] = r end
    table.sort(roomsL)   -- pairs order is per-process; blocks_adj' block order decides bid below
    for _, r in ipairs(roomsL) do
      radj[r] = {}
      for d, v in each_exit(adj[r]) do
        local de = elro.delta[d]
        if placed[v] and de and (de[1] ~= 0 or de[2] ~= 0) then radj[r][d] = v end
      end
    end
    local blkOf, blockId, anchor, q, qh, bid = {}, {}, {}, {}, 1, 0
    for _, comp in ipairs(elro.blocks_adj(roomsL, radj)) do
      if #comp > 1 then
        bid = bid + 1
        local mnx, mny, mxx, mxy, rep = math.huge, math.huge, -math.huge, -math.huge
        local BS, bl = {}, {}
        for _, e in ipairs(comp) do BS[e[1]] = true ; BS[e[2]] = true end
        for rr in pairs(BS) do bl[#bl + 1] = rr end
        -- sorted, not pairs order: `rep` takes the first room, and the seed order decides
        -- anchor[] for any room equidistant between two blocks (first writer wins in the BFS).
        table.sort(bl)
        for _, rr in ipairs(bl) do
          rep = rep or rr
          blockId[rr] = bid ; anchor[rr] = rr ; q[#q + 1] = rr   -- rigid seeds for the anchor BFS
          local p = coord[rr]
          if p[1] < mnx then mnx = p[1] end ; if p[1] > mxx then mxx = p[1] end
          if p[2] < mny then mny = p[2] end ; if p[2] > mxy then mxy = p[2] end
        end
        local cap = math.max(mxx - mnx, mxy - mny) + 3
        for _, rr in ipairs(bl) do blkOf[rr] = blkOf[rr] or { rep = rep, cap = cap, set = BS } end
      end
    end
    -- anchor[r] = nearest rigid room (the block r's branch hangs off), BFS outward from rigid set.
    while qh <= #q do
      local u = q[qh] ; qh = qh + 1
      for d, v in each_exit(adj[u]) do
        local de = elro.delta[d]
        if placed[v] and anchor[v] == nil and de and (de[1] ~= 0 or de[2] ~= 0) then
          anchor[v] = anchor[u] ; q[#q + 1] = v
        end
      end
    end
    -- the pinning block of an endpoint e = a block it (or a placed neighbour) belongs to.
    local function pinBlock(e)
      if blkOf[e] then return blkOf[e], e end
      for d, v in each_exit(adj[e]) do
        local de = elro.delta[d]
        if blkOf[v] and de and (de[1] ~= 0 or de[2] ~= 0) then return blkOf[v], v end
      end
    end
    -- cap = extent of whichever rigid block the tips are pinned to (a big block needs a big gap).
    local cap = 8
    for _, e in ipairs({ a, b }) do local blk = pinBlock(e) ; if blk and blk.cap > cap then cap = blk.cap end end
    local gg = {}
    -- guillotine only when the guardrail says a cut EXISTS: a,b must hang off
    -- different anchor rooms of the same block
    local aA, aB = anchor[a], anchor[b]
    if aA and aB and aA ~= aB and blockId[aA] and blockId[aA] == blockId[aB] then
      for _, pr in ipairs({ { a, b }, { b, a } }) do
        for _, c in ipairs(T.qbl(pr[1], pr[2], { [pr[1]] = true }, cap, nil) or {}) do gg[#gg + 1] = c end
      end
    end
    -- CHORD slack: slide each tip along its pinning block's wall using existing slack (fired
    -- correctly on the shared-anchor case where the guillotine cannot cut).
    for _, e in ipairs({ b, a }) do
      local _, blkRoom = pinBlock(e)
      if blkRoom then for _, c in ipairs(T.qcl(e, blkRoom, e, nil, { [e] = true }) or {}) do gg[#gg + 1] = c end end
    end
    for _, c in ipairs(gg) do
      local saved = {}
      for r in pairs(c.set) do saved[r] = coord[r] end
      for r in pairs(c.set) do local dx, dy = cshift(c, r) ; coord[r] = { coord[r][1] + dx, coord[r][2] + dy } end
      if elro.count_defects(coord, placed, pedges) <= base and costAt(coord[a], coord[b]) < cur then
        if elro.debug then
          cecho(string.format("\n<green>[loopcut] UNBLOCK %s (%d-%d) cost %.0f->%.0f<reset>",
            tostring(c.kind), a, b, cur, costAt(coord[a], coord[b])))
        end
        elro.step_snap(coord, string.format("stitch UNBLOCK %s (%d-%d)", tostring(c.kind), a, b), b)
        return true
      end
      for r in pairs(c.set) do coord[r] = saved[r] end   -- revert: no gain / adds defect
    end
    return false
  end

  local budget = elro.stitch_budget or 40
  while budget > 0 and not truthful() do
    budget = budget - 1
    local cur = costAt(coord[a], coord[b])
    -- conflict = "this move does not reduce the deviation"; _lever_core drives it false,
    -- i.e. emits levers (far-side piston moves along a bridge axis) that LOWER the cost.
    local function conflict(ov)
      local pa = (ov and ov[a]) or coord[a]
      local pb = (ov and ov[b]) or coord[b]
      return costAt(pa, pb) >= cur
    end
    local cands = elro._lever_core(coord, adj, a, b, {}, conflict, nil)
    local order = {}
    for _, c in ipairs(cands) do if c.intoEmpty then order[#order + 1] = c end end
    table.sort(order, function(x, y)
      local xr = (x.kind == "re-angle") and 1 or 0
      local yr = (y.kind == "re-angle") and 1 or 0
      if xr ~= yr then return xr < yr end          -- piston before re-angle
      if x.cost ~= y.cost then return x.cost < y.cost end
      -- fewest-rooms tiebreak MUST use the whole moved-set count (roomsFull), not
      -- c.rooms: the live-walk's window makes c.rooms a local count that under-counts
      -- far-side movers and flips this tiebreak toward the wrong side.
      return (x.roomsFull or x.rooms or 0) < (y.roomsFull or y.rooms or 0)
    end)
    local applied = false
    for _, pick in ipairs(order) do
      for r in pairs(pick.set) do
        coord[r] = { coord[r][1] + pick.dx * pick.dist, coord[r][2] + pick.dy * pick.dist }
      end
      if elro.count_defects(coord, placed, pedges) <= base
         and costAt(coord[a], coord[b]) < cur then
        applied = true
        elro.step_snap(coord, string.format("stitch %s for %d-%d (%dr dist %d)",
          pick.kind, a, b, pick.rooms or 0, pick.dist), b)
        break
      end
      for r in pairs(pick.set) do                  -- revert: collides or no gain
        coord[r] = { coord[r][1] - pick.dx * pick.dist, coord[r][2] - pick.dy * pick.dist }
      end
    end
    if not applied then
      -- pistons stalled: try the guillotine / chord-slack toolbox before conceding to a portal.
      if elro.stitchUnblock ~= false and try_unblock() then applied = true else break end
    end
  end

  if elro.debug then
    cecho(string.format(
      "\n<cyan>[loopcut] stitch %d-%d del=(%d,%d) off0=(%d,%d) off=(%d,%d) truthful=%s<reset>",
      a, b, dx0, dy0, o0x, o0y, coord[b][1] - coord[a][1], coord[b][2] - coord[a][2],
      tostring(truthful())))
  end
  return truthful()
end

-- Trunk-vs-leaf classifier for the skeleton view. classify_spine does a FULL leaf-
-- peel (keeps only the 2-core), which dissolves acyclic roads entirely -- so a long
-- thoroughfare with branches hanging off both sides shows as all-pendant. Here we peel
-- leaf chains but STOP at junctions (a non-rigid room with >=3 neighbours, or one that
-- touches a rigid block). What survives is the trunk: junctions + the chains between
-- them = the artery as a human reads it. Returns (artery set, pendant set); rigid rooms
-- are in neither. Kept separate from classify_spine so the composer is unaffected.
function elro.classify_artery(rooms, adj, rigidId)
  local nb = {}
  for _, r in ipairs(rooms) do
    nb[r] = {}
    local seen = {}
    for _, v in each_exit(adj[r]) do
      if v ~= r and not seen[v] then seen[v] = true ; nb[r][#nb[r] + 1] = v end
    end
  end
  -- degree counts ALL neighbours (rigid included). Rigid rooms never peel and act as
  -- anchors, so a through-road between two blocks survives; a leaf off a block (deg 1)
  -- peels away as a pendant. The only addition over classify_spine: junctions (branch
  -- points, deg>=3) also never peel, so a branched trunk is kept as artery.
  local deg = {}
  for _, r in ipairs(rooms) do deg[r] = #nb[r] end
  local junction = {}
  for _, r in ipairs(rooms) do
    if not rigidId[r] and deg[r] >= 3 then junction[r] = true end
  end
  local pendant, q, qh = {}, {}, 1
  for _, r in ipairs(rooms) do
    if not rigidId[r] and not junction[r] and deg[r] <= 1 then q[#q + 1] = r end
  end
  while qh <= #q do
    local r = q[qh] ; qh = qh + 1
    if not pendant[r] and not junction[r] and not rigidId[r] then
      pendant[r] = true
      for _, v in ipairs(nb[r]) do
        if not rigidId[v] and not pendant[v] and not junction[v] then
          deg[v] = deg[v] - 1
          if deg[v] <= 1 then q[#q + 1] = v end
        end
      end
    end
  end
  local artery = {}
  for _, r in ipairs(rooms) do
    if not rigidId[r] and not pendant[r] then artery[r] = true end
  end
  return artery, pendant
end


-- structural-class -> highlight colour (shared by mapclassify and the mapstep repaint)
elro.classColours = {
  main    = { 255, 200,   0 },   -- gold: biggest block (the anchor)
  block   = {   0, 200, 200 },   -- cyan: other blocks
  artery  = { 255,  90,   0 },   -- orange: connecting roads
  inward  = { 255, 105, 180 },   -- pink: inward pendants
  outward = { 120, 120, 140 },   -- grey: outward pendants
  cut     = { 190,  90, 230 },   -- purple: the endpoints of each cut (stitch points)
  maze    = { 150,  40, 200 },   -- violet: rooms folded into a maze submap (untruthful exits)
  -- LINE colour, not a room highlight: corridors for edges the equations demoted.
  -- Loud on purpose, and clear of the other line colours in use.
  demoted = { 255,  60, 220 },   -- magenta: demoted edges (see draw_demoted)
  -- Magenta = the engine DISBELIEVED the exit (fix the area source); red = it
  -- believed it and placement failed anyway (a mapper bug). Keep them separate.
  residual = { 255,  60,  60 },   -- red: kept but drawn off-axis (see draw_residual)
  -- Room-on-edge is the one defect class repairable at draw time: the exit is
  -- truthful, only ambiguous in the picture.
  occluded = { 255, 210,   0 },   -- yellow: truthful, but a room sits ON it
  -- Teal, clear of every other line colour. Not an accusation: a vertical is a
  -- different KIND of edge, no compass direction; both its angles are one category.
  vertical = {   0, 210, 190 },   -- teal: up/down links (see draw_vertical)
}


-- LEVER PICKER. _lever_core enumerates and ranks the levers that resolve a conflict between
-- anchorA and anchorB: move the far side of a Tarjan bridge as a PISTON (along the bridge
-- axis) or, for a diagonal bridge, a RE-ANGLE (steepen, never flatten). conflict(ov) is true
-- while the conflict persists under a coord override; cost = smallest clearing extension.
-- A lever that only relocates the conflict within MAXD is CASCADE. Pure read of coord.
-- Returns a sorted list { kind, ek, dx, dy, dist, rooms, cost, intoEmpty, set }.
-- branchSet (optional): a bridge straddling the branch/mesh boundary is the articulation;
-- moving its far side slides the branch out as a unit (artic).
-- _stretch_energy: spring energy k*((Lf-Lc)/nat)^2 on every edge a pull stretches; a rigid
-- co-move costs 0. `shearOnly` returns only the shear. `pre` (r -> {dx,dy}) is a displacement
-- already applied to coord, subtracted so a two-lever pair measures as one composite move:
-- stretch is a cost (per pull), shear is a state (before vs final only).
function elro._stretch_energy(coord, adj, pulls, shearOnly, pre)
  local k = TUNE.springK
  local function fp(r)
    local p = coord[r] ; if not p then return nil end
    local x, y = p[1], p[2]
    -- A graded candidate carries dx = dy = 0 with the real move in `deltas`, so fp must
    -- apply deltas or the pull is invisible and its stretch/shear read as 0.
    for _, pl in ipairs(pulls) do
      if pl.set[r] then
        local d = pl.deltas and pl.deltas[r]
        if d then x = x + d[1] ; y = y + d[2]
        else x = x + pl.dx * pl.dist ; y = y + pl.dy * pl.dist end
      end
    end
    return x, y
  end
  local function bp(r)                       -- the BEFORE position: coord minus what `pre` applied
    local p = coord[r]
    local d = pre and pre[r]
    if not d then return p[1], p[2] end
    return p[1] - d[1], p[2] - d[2]
  end
  local moved = {}
  for _, pl in ipairs(pulls) do for r in pairs(pl.set) do moved[r] = true end end
  if pre then for r in pairs(pre) do moved[r] = true end end
  local E, shear, seen = 0, 0, {}
  -- stepDebug-gated collector: which edges the shear counter actually fired on (see below)
  local shEdges = elro.stepDebug and {} or nil
  local DL = 0                  -- signed change in drawn edge length (see below)
  -- Orient the delta to the key: `ek` is canonical (low:high) but cx,cy are measured
  -- from whichever endpoint the traversal reached first; make the printed delta run
  -- low->high, or its sign depends on iteration order.
  local function shLabel(sign, ek, r, w, cx, cy, ax, ay)
    local g = (r < w) and -1 or 1                 -- key runs low->high; make the delta run that way
    return string.format("%s%s(%d,%d->%d,%d)", sign, ek, g * cx, g * cy, g * ax, g * ay)
  end
  for r in pairs(moved) do
    local pr = coord[r]
    local fx, fy = fp(r)
    if pr and fx then
      for d, w in each_exit(adj[r]) do
        local de = elro.delta[d]
        if coord[w] and de and (de[1] ~= 0 or de[2] ~= 0) then
          -- The dedup key is an integer (eid); the printed diagnostics build ekey's
          -- "a:b" string lazily, which is what _shWatch is keyed by.
          local ek = eid(r, w)
          if not seen[ek] then
            seen[ek] = true
            local wx, wy = fp(w)
            local brx, bry = bp(r) ; local bwx, bwy = bp(w)
            local cx, cy = brx - bwx, bry - bwy
            local ax, ay = fx - wx, fy - wy
            local isDiag = (de[1] ~= 0 and de[2] ~= 0)
            -- Dlen: signed Chebyshev change in drawn length. The energy only sees
            -- stretch (`ext > 0` discards shortening), so this is the squash signal.
            local _cL = (math.abs(cx) > math.abs(cy)) and math.abs(cx) or math.abs(cy)
            local _aL = (math.abs(ax) > math.abs(ay)) and math.abs(ax) or math.abs(ay)
            DL = DL + (_aL - _cL)
            local ext = 0
            if not shearOnly then
              ext = math.sqrt(ax * ax + ay * ay) - math.sqrt(cx * cx + cy * cy)
            end
            if ext > 0 then
              local nat = math.sqrt(de[1] * de[1] + de[2] * de[2])
              -- Dividing by `nat` converts the extension to grid steps;
              -- TUNE.diagStretchMult is the extra surcharge for a stretched diagonal
              -- (1 = none).
              local e = k * (ext / nat) * (ext / nat)
              if isDiag then e = e * TUNE.diagStretchMult end
              E = E + e
            end
            -- SHEAR (second return, never folded into E): signed count of diagonals tipped
            -- off 45 (+1 tipped, -1 restored, 0 for bending a bent edge further), only while
            -- the edge is truthful before and after.
            -- OPEN: a grid-X quad family is charged per edge, opposite to the gridXSkip gate.
            if elro._shWatch and isDiag and elro._shWatch[ekey(r, w)] then
              print(string.format("  [shw] %s de=%d,%d before=%d,%d after=%d,%d gate=%s wasSq=%s isSq=%s",
                ekey(r, w), de[1], de[2], cx, cy, ax, ay,
                tostring(cx * de[1] < 0 and cy * de[2] < 0 and ax * de[1] < 0 and ay * de[2] < 0),
                tostring(math.abs(cx) == math.abs(cy)), tostring(math.abs(ax) == math.abs(ay))))
            end
            if isDiag and cx * de[1] < 0 and cy * de[2] < 0 and ax * de[1] < 0 and ay * de[2] < 0 then
              local wasSq = (math.abs(cx) == math.abs(cy))
              local isSq  = (math.abs(ax) == math.abs(ay))
              if wasSq and not isSq then shear = shear + 1
                -- record which edge (stepDebug-gated: allocates per candidate).
                if shEdges then
                  shEdges[#shEdges + 1] = shLabel("+", ekey(r, w), r, w, cx, cy, ax, ay)
                end
              elseif isSq and not wasSq then shear = shear - 1
                if shEdges then
                  shEdges[#shEdges + 1] = shLabel("-", ekey(r, w), r, w, cx, cy, ax, ay)
                end
              end
            end
          end
        end
      end
    end
  end
  return E, shear, shEdges, DL
end
-- optional spring-energy timing (lua elro.timeGuillo = true). Installed once, right
-- after the definition, so re-sourcing can never nest it.
do
  local core = elro._stretch_energy
  elro._stretch_energy = function(...)
    if not elro.timeGuillo then return core(...) end
    local t = CLK() ; elro._strN = (elro._strN or 0) + 1
    -- pass the third (shear-edge list) and fourth (Dlen) returns through: the wrapper
    -- must not swallow diagnostics exactly when timing is switched on.
    local a, b, c, d = core(...) ; elro._strT = (elro._strT or 0) + (CLK() - t) ; return a, b, c, d
  end
end

-- is the segment u->w rendered as a 45-degree wall? (both components non-zero). Deliberately reads
-- the RENDERED geometry, not the exit direction: a diagonal exit currently drawn flat is a lie for
-- the closure to repair, not a wall to preserve.
function elro.diag_edge(coord, u, w)
  local a, b = coord[u], coord[w]
  if not (a and b) then return false end
  return (a[1] ~= b[1]) and (a[2] ~= b[2])
end
local _fbIdx, _fbFor

function elro._score_cands(coord, adj, subject, anchorA, anchorB, cands)
  -- ROOMS = disturbance. TUNE.leverRoomsRadius (Chebyshev; 0 = whole canvas) windows
  -- `rooms` to moved rooms near the collision point; c.roomsFull keeps the whole count.
  local RR = TUNE.leverRoomsRadius
  local cc0 = coord[subject] or coord[anchorA] or coord[anchorB]   -- collision centre (pre-pull)
  -- c.boxArea = the bounding box this move would leave (`elro.boxRank`). For a W x H
  -- box a column costs H and a row costs W, so "grow the long axis" is just "minimise
  -- the resulting area". Monotone approximation: new = old union (moved, shifted);
  -- ignores that vacating an extreme could shrink the box. O(|moved|) per candidate.
  local bx0, by0, bx1, by1
  if elro.boxRank ~= false then
    for _, p in pairs(coord) do
      if not bx0 then bx0, by0, bx1, by1 = p[1], p[2], p[1], p[2]
      else
        if p[1] < bx0 then bx0 = p[1] elseif p[1] > bx1 then bx1 = p[1] end
        if p[2] < by0 then by0 = p[2] elseif p[2] > by1 then by1 = p[2] end
      end
    end
  end
  local function box_area(c)
    if not (elro.boxRank ~= false and bx0 and c.set) then return nil end
    local x0, y0, x1, y1 = bx0, by0, bx1, by1
    for r in pairs(c.set) do
      local p = coord[r]
      if p then
        local d = c.deltas and c.deltas[r]
        local nx = p[1] + (d and d[1] or c.dx or 0)
        local ny = p[2] + (d and d[2] or c.dy or 0)
        if nx < x0 then x0 = nx elseif nx > x1 then x1 = nx end
        if ny < y0 then y0 = ny elseif ny > y1 then y1 = ny end
      end
    end
    return (x1 - x0 + 1) * (y1 - y0 + 1)
  end
  -- junction_score overwrites c.score afterwards; here: c.roomsFull, the windowed c.rooms,
  -- and a rooms+dist fallback. Shear is priced for every candidate carrying a set: any plate
  -- can tip a settled 45, not just a diag-eq one.
  for _, c in ipairs(cands) do
    c.boxArea = box_area(c)
    c.roomsFull = c.rooms
    if RR > 0 and cc0 then
      local cnt = 0
      for r in pairs(c.set) do
        local p = coord[r]
        if p and math.max(math.abs(p[1] - cc0[1]), math.abs(p[2] - cc0[2])) <= RR then cnt = cnt + 1 end
      end
      c.rooms = cnt
    end
    c.score = (c.rooms or 0) + (c.dist or 0)
    -- measured here too so _pref_key works when junction_score returns nil (no junction)
    if TUNE.diagSkewCap ~= 0 and c.set then
      local _, sh = elro._stretch_energy(coord, adj,
        { { set = c.set, dx = c.dx or 0, dy = c.dy or 0, dist = c.dist or 0, deltas = c.deltas } },
        true)
      c.shear = sh
    end
  end
  return cands
end

-- The one place the 45-degree preference is priced; shared by single-lever ranking and the
-- two-lever adoption test so both tiers see it. `score` = move cost, `shear` = the state term.
function elro._pref_key(score, shear)
  local s = shear or 0
  -- Only the penalty applies: negative shear (a candidate squaring a diagonal back up) is
  -- clamped, since a credit can drag an unrelated cosmetic win to the top of the list.
  if s < 0 then s = 0 end
  return (score or 0) + TUNE.diagSkewCap * s
end

function elro._rank_cands(cands)
  -- The score is the repel-field energy; ties fall through a fixed key chain (dist, seam, box,
  -- rooms, edge key). Preferences are added to the sort KEY only, never to `c.score`, so S1 and
  -- the cascade prune keep their scale. Any comparator must pick its keys once for the whole
  -- sort: table.sort needs a strict weak ordering.
  -- `elro.forceLever` (debugging): candidates whose `ek` is listed rank above everything, and
  -- override the pick-loop guards.
  local FL = elro.forceLever
  if FL then
    -- `true` = every ranking; a room id = only while that room is being placed (see place_room)
    for _, c in ipairs(cands) do
      local f = c.ek and FL[c.ek]
      c._forced = (f ~= nil and f ~= false and (f == true or f == elro._placingV)) or false
    end
  end
  local _ekHit = false          -- set when the comparator fell through to the label key
  local cmp
  cmp = function(a, b)
    if FL and a._forced ~= b._forced then return a._forced end
    if a.intoEmpty ~= b.intoEmpty then return a.intoEmpty end
    -- re-angle last: it steepens a diagonal exit into a rendered-angle lie (structural, not a weight)
    local ar, br = (a.kind == "re-angle"), (b.kind == "re-angle")
    if ar ~= br then return br end
    -- Shear rides on the score as an upper bound (TUNE.diagSkewCap), not a price; 0 turns it off.
    local ak = elro._pref_key(a.score, a.shear)
    local bk = elro._pref_key(b.score, b.shear)
    if ak ~= bk then return ak < bk end
    if a.score ~= b.score then return a.score < b.score end
    -- guillotine vs guillotine only: fewer rooms displaced globally (rigid motion is invisible
    -- to stretch and to the windowed `rooms`). Never lets a guillotine lose to a bridge.
    if a.kind == "guillotine" and b.kind == "guillotine" and a.roomsFull and b.roomsFull
       and a.roomsFull ~= b.roomsFull then return a.roomsFull < b.roomsFull end
    if (a.dist or 0) ~= (b.dist or 0) then return (a.dist or 0) < (b.dist or 0) end
    -- seamTight = min face tightness over the edges a class shift stretches; slack goes where
    -- that is largest, so DESCENDING. Only compared when both sides have one: nil means the
    -- outer face absorbs it for free, which is not "seam 0".
    if a.seamTight and b.seamTight
       and a.seamTight ~= b.seamTight then return a.seamTight > b.seamTight end
    -- seamGrow = cells the seam injects; both sides or neither, as above.
    if a.seamGrow and b.seamGrow
       and a.seamGrow ~= b.seamGrow then return a.seamGrow < b.seamGrow end
    -- then the smaller resulting bounding box (see box_area in _score_cands)
    if a.boxArea and b.boxArea and a.boxArea ~= b.boxArea then return a.boxArea < b.boxArea end
    if (a.rooms or 0) ~= (b.rooms or 0) then return (a.rooms or 0) < (b.rooms or 0) end
    -- Room count is deliberately not a damage measure beyond this (remote rigid motion is free).
    -- Pistons along one arm tie on everything above: prefer the bridge nearest a conflict
    -- anchor (the smallest pull that separates). Structural, so a label rename cannot move it.
    local ah, bh = a.hops or math.huge, b.hops or math.huge
    if ah ~= bh then return ah < bh end
    -- path midpoint (equidistant from both ends): the one nearer the path's source anchor
    ah, bh = a.hopsA or math.huge, b.hopsA or math.huge
    if ah ~= bh then return ah < bh end
    -- Last key: the legacy label (see _ek_ord), memoised since it is a string rebuild.
    a._ekOrd = a._ekOrd or (elro._ek_ord and elro._ek_ord(a.ek)) or a.ek
    b._ekOrd = b._ekOrd or (elro._ek_ord and elro._ek_ord(b.ek)) or b.ek
    _ekHit = true
    return tostring(a._ekOrd) < tostring(b._ekOrd)
  end
  table.sort(cands, cmp)
  -- label-tie census: did the TOP TWO tie all the way down to the label?
  -- Recorded on the list and COUNTED at the pick (place.lua): a list is sorted more than once
  -- per placement, so counting here overstates label-decided picks.
  cands._ekTie = nil
  if elro.timeGuillo and #cands >= 2 then
    _ekHit = false ; cmp(cands[1], cands[2])
    if _ekHit then
      local L = elro._ekTopList or {} ; elro._ekTopList = L
      do
        -- twin/mirror/other census: per-room displacement of the top two
        local A, B = cands[1], cands[2]
        local function mv(c, r)
          local d = c.deltas and c.deltas[r]
          if d then return d[1], d[2] end
          return (c.dx or 0) * (c.dist or 0), (c.dy or 0) * (c.dist or 0)
        end
        local cls = "other"
        if A.set and B.set then
          local same, twin, mirror = true, true, true
          for r in pairs(A.set) do
            if not B.set[r] then same = false ; break end
            local ax, ay = mv(A, r) ; local bx, by = mv(B, r)
            if ax ~= bx or ay ~= by then twin = false end
            if ax ~= -bx or ay ~= -by then mirror = false end
          end
          if same then for r in pairs(B.set) do if not A.set[r] then same = false ; break end end end
          if same then cls = twin and "twin" or (mirror and "mirror" or "sameset")
          else
            -- disjoint sets moved in opposite directions: the same relative move (complement plates)
            local disj = true
            for r in pairs(A.set) do if B.set[r] then disj = false ; break end end
            if disj and (A.dx or 0) == -(B.dx or 0) and (A.dy or 0) == -(B.dy or 0) and (A.dist or 0) == (B.dist or 0)
               and not A.deltas and not B.deltas then cls = "disjoint-opposite" end
          end
        end
        cands._ekTie = { cls = cls, ek = tostring(A.ek) .. " vs " .. tostring(B.ek) .. " hops=" .. tostring(A.hops) .. "/" .. tostring(B.hops) .. " hopsA=" .. tostring(A.hopsA) .. "/" .. tostring(B.hopsA) }
      end
      if #L < 10 then
        local A, B = cands[1], cands[2]
        local nA, nB, both = 0, 0, 0
        for r in pairs(A.set or {}) do nA = nA + 1 ; if B.set and B.set[r] then both = both + 1 end end
        for _ in pairs(B.set or {}) do nB = nB + 1 end
        L[#L + 1] = string.format(
          "%s vs %s [kind %s/%s sc=%s d=%s r=%s/%s box=%s/%s seam=%s/%s shear=%s/%s dxy=(%s,%s)/(%s,%s) shared=%d of sets %d/%d dLen=%s/%s]",
          tostring(A.ek), tostring(B.ek), tostring(A.kind), tostring(B.kind),
          tostring(A.score), tostring(A.dist), tostring(A.rooms), tostring(B.rooms),
          tostring(A.boxArea), tostring(B.boxArea),
          A.seamFree and "free" or tostring(A.seamTight), B.seamFree and "free" or tostring(B.seamTight),
          tostring(A.shear), tostring(B.shear),
          tostring(A.dx), tostring(A.dy), tostring(B.dx), tostring(B.dy), both, nA, nB,
          tostring(A.dLen), tostring(B.dLen))
      end
    end
  end
  return cands
end

function elro._lever_core(coord, adj, anchorA, anchorB, edgesInvolved, conflict, branchSet, subject)
  local function key(x, y) return x .. ":" .. y end
  -- participants = the only rooms the `conflict` predicate reads: the anchors plus the
  -- endpoints of every edge in edgesInvolved. eval's per-distance feasibility test moves these
  -- and nothing else.
  local participants = {}
  local function addPart(r) if r ~= nil then participants[r] = true end end
  addPart(anchorA) ; addPart(anchorB)
  for _, e in ipairs(edgesInvolved or {}) do addPart(e.u) ; addPart(e.v) end
  -- timing regions (elro.timeGuillo): SETUP, FARSIDE, EVAL
  local _lc0 = elro.timeGuillo and CLK()
  local rooms, radj = {}, {}
  for r in pairs(coord) do rooms[#rooms + 1] = r end
  for _, r in ipairs(rooms) do
    radj[r] = {}
    for d, v in each_exit(adj[r]) do if coord[v] then radj[r][d] = v end end
  end
  local isBridge = {}
  for _, comp in ipairs(elro.blocks_adj(rooms, radj)) do
    if #comp == 1 then isBridge[ekey(comp[1][1], comp[1][2])] = true end
  end
  local function farside(a, b)
    local _t = _lc0 and CLK()
    local set, q, qh, n = { [a] = true }, { a }, 1, 1
    while qh <= #q do
      local u = q[qh] ; qh = qh + 1
      for _, v in each_exit(radj[u]) do
        if not set[v] and not ((u == a and v == b) or (u == b and v == a)) then
          set[v] = true ; n = n + 1 ; q[#q + 1] = v
        end
      end
    end
    if _t then elro._lcFarT = (elro._lcFarT or 0) + (CLK() - _t)
      elro._lcFarN = (elro._lcFarN or 0) + 1 end
    return set, n
  end
  -- Stationary index, built once per call; the moving `set` is excluded at lookup time (occ_hit).
  -- cellRooms[cell] = rooms there; cellEdges[cell] = {u,v} pairs whose raster passes through it.
  -- Numeric cell key (private to this function; injective while |y| < 500000).
  local function ck(x, y) return x * 1000003 + y end
  -- work-unit counters for eval's edge phase: raster cells visited, edge_over_room calls,
  -- bucket entries examined
  local lcRas, lcEorC, lcEorS = 0, 0, 0
  -- cellPts: interior lattice points of IRREGULAR edges (neither axial nor 45), which `seg`
  -- rasters endpoint-only. Enumerated as a + i*(dx/g, dy/g), i = 1..g-1, g = gcd. This keeps a
  -- moved room landing on a stationary edge at the same precision as edge_over_room's test.
  local cellRooms, cellEdges, cellPts = {}, {}, {}
  for _, r in ipairs(rooms) do
    local p = coord[r]
    if p then local k = ck(p[1], p[2])
      local l = cellRooms[k] ; if l then l[#l + 1] = r else cellRooms[k] = { r } end
    end
  end
  -- dedup by canonical pair, never by `r < w`: radj is DIRECTED (a one-way "out" exit appears
  -- in one neighbour list only), and an `r < w` test would silently drop such edges.
  local seenE = {}
  for _, r in ipairs(rooms) do
    local p = coord[r]
    if p then
      for _, w in each_exit(radj[r]) do
        local eKey = eid(r, w)
        if not seenE[eKey] then
          seenE[eKey] = true
          local q = coord[w]
          if q then
            seg(p[1], p[2], q[1], q[2], function(x, y)
              local k = ck(x, y)
              local l = cellEdges[k] ; if l then l[#l + 1] = { r, w } else cellEdges[k] = { { r, w } } end
            end)
            local dx, dy = q[1] - p[1], q[2] - p[2]
            local adx, ady = (dx < 0) and -dx or dx, (dy < 0) and -dy or dy
            if adx ~= 0 and ady ~= 0 and adx ~= ady then   -- irregular: seg gave us the endpoints only
              local g, h = adx, ady                        -- gcd
              while h ~= 0 do g, h = h, g % h end
              if g > 1 then
                local ux, uy = dx / g, dy / g
                local pr = { r, w }
                for i = 1, g - 1 do
                  local k = ck(p[1] + ux * i, p[2] + uy * i)
                  local l = cellPts[k] ; if l then l[#l + 1] = pr else cellPts[k] = { pr } end
                end
              end
            end
          end
        end
      end
    end
  end
  if _lc0 then elro._lcSetT = (elro._lcSetT or 0) + (CLK() - _lc0)
    elro._lcSetN = (elro._lcSetN or 0) + 1 end
  local MAXD, cands = 12, {}
  -- edge_over_room: any room collinear on the INTERIOR of segment (ax,ay)-(bx,by), excluding the
  -- endpoints sa,sb, each room at its post-move position; a room rigid under a wholly-moved edge
  -- (efull) is skipped. Must match the pick-loop detector roomedge_moved exactly (bbox + ori==0 +
  -- endpoint exclusion + efull skip). Bucket index over BASE coords; moved rooms are found by
  -- shifting the query window by -(ddx,ddy), so no per-distance rebuild.
  local RB = elro.crossBucket or 4
  local rfloor = math.floor
  local roomBk = {}
  for _, r in ipairs(rooms) do
    local p = coord[r]
    if p then local k = rfloor(p[1] / RB) * 1000003 + rfloor(p[2] / RB)
      local l = roomBk[k] ; if l then l[#l + 1] = r else roomBk[k] = { r } end
    end
  end
  local function edge_over_room(ax, ay, bx, by, sa, sb, set, ov, efull, ddx, ddy)
    lcEorC = lcEorC + 1
    local lox = (ax < bx) and ax or bx ; local hix = (ax > bx) and ax or bx
    local loy = (ay < by) and ay or by ; local hiy = (ay > by) and ay or by
    -- wantMoved selects the population; the window is the bbox, shifted back for moved rooms
    local function scan(wlox, whix, wloy, whiy, wantMoved)
      for bi = rfloor(wlox / RB), rfloor(whix / RB) do
        for bj = rfloor(wloy / RB), rfloor(whiy / RB) do
          local l = roomBk[bi * 1000003 + bj]
          if l then
            lcEorS = lcEorS + #l
            for i = 1, #l do
              local r = l[i]
              if r ~= sa and r ~= sb then
                local inSet = set[r] and true or false
                if inSet == wantMoved and not (efull and inSet) then
                  local c = coord[r]
                  if c then
                    local px, py = c[1], c[2]
                    if wantMoved then px = px + ddx ; py = py + ddy end
                    if px >= lox and px <= hix and py >= loy and py <= hiy
                       and ori(ax, ay, bx, by, px, py) == 0
                       and not (px == ax and py == ay) and not (px == bx and py == by) then
                      return true
                    end
                  end
                end
              end
            end
          end
        end
      end
      return false
    end
    if scan(lox, hix, loy, hiy, false) then return true end     -- stationary rooms, at base coords
    if efull then return false end                              -- edge wholly moved: movers are rigid
    return scan(lox - ddx, hix - ddx, loy - ddy, hiy - ddy, true)
  end
  local curHops, curHopsA
  local function eval(kind, ek, set, n, vx, vy, artic)
    if vx == 0 and vy == 0 then return end
    -- A bridge is not swept here: it is recorded and query_eq_levers builds it as a field plate
    -- with the whole far side seeded and the near end pinned (start = far, anchor = near). The
    -- distance sweep below serves the re-angles only.
    if kind == "piston" then
      local B = elro._bridgeSpecs
      if not B or B.A ~= anchorA or B.B ~= anchorB then
        B = { A = anchorA, B = anchorB } ; elro._bridgeSpecs = B
      end
      B[#B + 1] = { ek = ek, set = set, n = n, vx = vx, vy = vy, artic = artic, hops = curHops, hopsA = curHopsA }
      return
    end
    local _te = _lc0 and CLK()
    local _teK = _te and collectgarbage("count")
    -- phase timers/counters (conflict probe, ov+occ build, edge loop), kept in locals and
    -- flushed once in evDone so the innermost loop carries no global increments
    local tCo, tOv, tEd, nD, nC, nSet, nEdg = 0, 0, 0, 0, 0, 0, 0
    local failOcc, failEdge = 0, 0
    -- `fc` = the firstClear distance, passed in because firstClear is declared below this closure.
    local function evDone(outcome, fc)
      if _te then elro._lcEvK = (elro._lcEvK or 0) + (collectgarbage("count") - _teK)
        elro._lcEvT = (elro._lcEvT or 0) + (CLK() - _te)
        elro._lcEvN = (elro._lcEvN or 0) + 1
        elro._evCoT = (elro._evCoT or 0) + tCo ; elro._evOvT = (elro._evOvT or 0) + tOv
        elro._evEdT = (elro._evEdT or 0) + tEd
        elro._evDN = (elro._evDN or 0) + nD ; elro._evCN = (elro._evCN or 0) + nC
        elro._evSetN = (elro._evSetN or 0) + nSet ; elro._evEdgN = (elro._evEdgN or 0) + nEdg
        elro._evFO = (elro._evFO or 0) + failOcc ; elro._evFE = (elro._evFE or 0) + failEdge
        local o = outcome or "none"
        elro._evOut = elro._evOut or {}
        elro._evOut[o] = (elro._evOut[o] or 0) + 1
        -- distances probed after firstClear by a call that never found a clean one
        if o == "cascade" and fc then elro._evWaste = (elro._evWaste or 0) + (nD - fc) end
      end
    end
    -- stationary occupancy: a cell is occupied iff a room not in `set` sits there, or an edge
    -- with both endpoints outside `set` rasters through it
    local function occ_hit(x, y)
      local k = x * 1000003 + y            -- inlined ck(), hottest lookup in the engine
      local rl = cellRooms[k]
      if rl then for i = 1, #rl do if not set[rl[i]] then return true end end end
      local el = cellEdges[k]
      if el then for i = 1, #el do local e = el[i]
        if not set[e[1]] and not set[e[2]] then return true end
      end end
      return false
    end
    -- moved-room variant: also consults cellPts, so room-on-edge is judged at edge_over_room's
    -- precision. occ_hit itself stays raster-only because its caller (segCb) tests crossings.
    local function occ_hit_room(x, y)
      local k = x * 1000003 + y
      local rl = cellRooms[k]
      if rl then for i = 1, #rl do if not set[rl[i]] then return true end end end
      local el = cellEdges[k]
      if el then for i = 1, #el do local e = el[i]
        if not set[e[1]] and not set[e[2]] then return true end
      end end
      local pl = cellPts[k]
      if pl then for i = 1, #pl do local e = pl[i]
        -- an edge with an endpoint in `set` is not stationary; pair_bad tests those
        if not set[e[1]] and not set[e[2]] then
          elro._lcPtHit = (elro._lcPtHit or 0) + 1
          return true
        end
      end end
      return false
    end
    -- one reusable seg callback per eval (per-pair state lives in upvalues). `cbOwn` selects the
    -- population: stationary edges (occ_hit) or the moved side's own edges for the stretched-edge
    -- pass. Rooms are deliberately not consulted in the own-side pass; edge_over_room covers them.
    local cbPx, cbPy, cbQx, cbQy, cbHit, cbOwn
    local cbR, cbW                       -- the moved edge's rooms, for the licence test below
    -- a stationary edge in a swept cell is not an obstruction when crossing it is licensed
    -- (same rule as pull_makes_crossing)
    local function lic_edge_ok(x, y)
      if not (cbR and cbW) then return false end
      local k = x * 1000003 + y
      local rl = cellRooms[k]
      if rl then for i = 1, #rl do if not set[rl[i]] then return false end end end
      local el = cellEdges[k]
      if el then for i = 1, #el do local e = el[i]
        if not set[e[1]] and not set[e[2]] then
          local a1, b1, a2, b2 = cbR, cbW, e[1], e[2]
          local lp = elro._licPair
          if not (lp and lp(a1, b1, a2, b2)) then return false end
        end
      end end
      elro._lcLic = (elro._lcLic or 0) + 1
      return true
    end
    local function segCb(x, y)
      lcRas = lcRas + 1
      if (x == cbPx and y == cbPy) or (x == cbQx and y == cbQy) then return end
      if cbOwn then
        local el = cellEdges[x * 1000003 + y]
        if el then for i = 1, #el do local e = el[i]
          if set[e[1]] and set[e[2]] then cbHit = true ; return end
        end end
      elseif occ_hit(x, y) and not lic_edge_ok(x, y) then cbHit = true end
    end
    -- ovP holds only the moved participants (all `conflict` reads); the full `ov` is built only
    -- once a distance clears the conflict.
    local movedParts = {}
    for r in pairs(participants) do if set[r] then movedParts[#movedParts + 1] = r end end
    local ovP, ov, firstClear = {}, {}, nil
    -- fail-fast memo: the room / edge pair that failed at the previous distance is re-tested
    -- first. Safe because only the boolean `clean` is ever read, never which blocker.
    local sx, sy = 0, 0
    local badRoom, badU, badW
    local function pair_bad(r, w)
      local p = ov[r] ; local q = set[w] and ov[w] or coord[w]
      if not (p and q) then return false end
      nEdg = nEdg + 1
      -- (1) raster vs occ2: a moved edge crossing a stationary EDGE cell
      cbPx, cbPy, cbQx, cbQy, cbHit, cbOwn = p[1], p[2], q[1], q[2], false, false
      cbR, cbW = r, w
      seg(cbPx, cbPy, cbQx, cbQy, segCb)
      if cbHit then return true end
      -- (1b) a STRETCHED edge (one endpoint in `set`) also sweeps the moved side's own geometry;
      -- tested by shifting the segment by -(sx,sy) against the base index
      if not set[w] then
        cbPx, cbPy, cbQx, cbQy, cbOwn = p[1] - sx, p[2] - sy, q[1] - sx, q[2] - sy, true
        seg(cbPx, cbPy, cbQx, cbQy, segCb)
        if cbHit then elro._lcOwnHit = (elro._lcOwnHit or 0) + 1 ; return true end
      end
      -- (2) collinearity vs rooms at post-move positions (including rooms that moved with the set)
      return edge_over_room(p[1], p[2], q[1], q[2], r, w, set, ov, set[w], sx, sy) and true or false
    end
    local _p0, whyD, fcWhy
    for d = 1, MAXD do
      if _te then nD = nD + 1 ; _p0 = CLK() end
      for i = 1, #movedParts do
        local r = movedParts[i] ; local p = coord[r] ; ovP[r] = { p[1] + vx * d, p[2] + vy * d }
      end
      whyD = nil                        -- what made THIS distance unclean; see `cascWhy` below
      local feasible = not conflict(ovP)
      if _te then tCo = tCo + (CLK() - _p0) end
      if feasible then
        if _te then nC = nC + 1 ; _p0 = CLK() end
        -- fused build + occupancy check; ov tables are written in place and reused across
        -- distances. An early break leaves ov partly stale, which is safe: ov is read only when
        -- `clean` survived, i.e. the loop ran to completion.
        local clean = true
        sx, sy = vx * d, vy * d
        if badRoom and set[badRoom] then
          local p = coord[badRoom]
          if p and occ_hit_room(p[1] + sx, p[2] + sy) then clean = false
            whyD = "occ@" .. tostring(badRoom) end
        end
        if clean then
          for r in pairs(set) do
            local p = coord[r] ; local x, y = p[1] + sx, p[2] + sy
            local t = ov[r] ; if t then t[1] = x ; t[2] = y else ov[r] = { x, y } end
            nSet = nSet + 1
            if occ_hit_room(x, y) then clean = false ; badRoom = r
              whyD = "occ@" .. tostring(r) ; break end
          end
        end
        if not clean then failOcc = failOcc + 1 end
        if _te then tOv = tOv + (CLK() - _p0) ; _p0 = CLK() end
        -- edge-over-room rejection: the moved set's incident edges must not lie across a
        -- stationary room (else pushing a leaf past its blocker is a swap, not a solution).
        -- `ov` is complete here because the build loop ran to completion.
        if clean and badU and set[badU] and badW and pair_bad(badU, badW) then clean = false
          whyD = "edge@" .. tostring(badU) .. "-" .. tostring(badW) end
        if clean then
          for r in pairs(set) do
            for _, w in each_exit(radj[r]) do
              if pair_bad(r, w) then clean = false ; badU, badW = r, w
                whyD = "edge@" .. tostring(r) .. "-" .. tostring(w) end
              if not clean then break end
            end
            if not clean then break end
          end
        end
        if not clean then failEdge = failEdge + 1 end   -- includes the occ failures
        if _te then tEd = tEd + (CLK() - _p0) end
        if clean then
          -- lag of the clean distance behind firstClear, bucketed
          if _te then
            local lag = d - (firstClear or d)
            elro._evLag = elro._evLag or {}
            local b = (lag >= 5) and "5+" or tostring(lag)
            elro._evLag[b] = (elro._evLag[b] or 0) + 1
            if lag > (elro._evLagMax or 0) then elro._evLagMax = lag end
          end
          cands[#cands + 1] = { kind = kind, ek = ek, dx = vx, dy = vy, dist = d,
            rooms = n, cost = d, intoEmpty = true, set = set, artic = artic, hops = curHops, hopsA = curHopsA }
          evDone("clean")
          return
        elseif not firstClear then firstClear = d ; fcWhy = whyD end
      end
    end
    -- a piston that clears the conflict but is not clean is emitted with intoEmpty = false;
    -- cascWhy names the blocker (`occ@<room>` or `edge@<u>-<w>`) for the trace
    if firstClear then
      cands[#cands + 1] = { kind = kind, ek = ek, dx = vx, dy = vy, dist = firstClear,
        rooms = n, cost = firstClear, intoEmpty = false, set = set, artic = artic,
        cascWhy = fcWhy, hops = curHops, hopsA = curHopsA }
    end
    evDone(firstClear and "cascade" or "none", firstClear)
  end
  -- a candidate bridge: try BOTH sides (each side extends AWAY from its anchor)
  local seen_ek = {}
  local function consider_bridge(a, b, hops, hopsA)
    local ek = ekey(a, b)
    curHops, curHopsA = hops, hopsA
    if elro.probeSeam and elro._brWatch and (elro._brWatch[a] or elro._brWatch[b]) then
      print(string.format("[bridge?] anchors=%s/%s edge %s-%s  isBridge=%s seen=%s",
        tostring(anchorA), tostring(anchorB), tostring(a), tostring(b),
        tostring(isBridge[ek] and true or false), tostring(seen_ek[ek] and true or false)))
    end
    if not isBridge[ek] or seen_ek[ek] then return end
    seen_ek[ek] = true
    local sA, nA = farside(a, b)
    local sB, nB = farside(b, a)
    -- partition census: do sA and sB cover every placed room? (precondition for the one-side dedup)
    if elro.timeGuillo then
      elro._brN = (elro._brN or 0) + 1
      if nA + nB == #rooms then elro._brPart = (elro._brPart or 0) + 1
      else
        elro._brSplit = (elro._brSplit or 0) + 1
        local miss = #rooms - (nA + nB)
        if miss > (elro._brMissMax or 0) then elro._brMissMax = miss end
        if nA + nB > #rooms then elro._brOverlap = (elro._brOverlap or 0) + 1 end
      end
    end
    -- articulation = this bridge straddles the branch/mesh boundary; sliding the branch-side
    -- far set moves the whole branch out as a unit (the pack_branches isAttach equivalent).
    local straddle = branchSet and ((branchSet[a] and not branchSet[b])
                                 or (branchSet[b] and not branchSet[a]))
    local function try_side(set, n, mover, anchor)
      -- only the side whose moved set is the BRANCH counts as the articulation slide (moving
      -- the mesh side would shove settled geometry, not slide the branch out)
      local artic = straddle and branchSet[mover] or false
      local pa, pm = coord[anchor], coord[mover]
      local ax = (pm[1] > pa[1]) and 1 or (pm[1] < pa[1] and -1 or 0)
      local ay = (pm[2] > pa[2]) and 1 or (pm[2] < pa[2] and -1 or 0)
      if ax ~= 0 and ay ~= 0 then         -- diagonal: STEEPEN away from anchor (no flatten)
        -- the two re-angles are different moves and must carry distinct labels (a shared `ek`
        -- makes the last tie-break arbitrary and un-nameable by maplever)
        eval("re-angle", ek .. ":" .. ((ax > 0) and "e" or "w"), set, n, ax, 0, artic)
        eval("re-angle", ek .. ":" .. ((ay > 0) and "n" or "s"), set, n, 0, ay, artic)
        -- the diagonal extension keeps the wall at 45; it is a piston, not a re-angle, since it
        -- creates no rendered-angle lie
        do
          eval("piston", ek .. ":" .. ((ay > 0) and "n" or "s") .. ((ax > 0) and "e" or "w"),
               set, n, ax, ay, artic)
        end
      else                                -- orthogonal: extend away from anchor
        eval("piston", ek, set, n, ax, ay, artic)
      end
    end
    -- One side per bridge: moving sA by +d is moving sB by -d, translated. Keep the articulation
    -- side when straddling (artic is a ranking signal), else the smaller side, ties by room id.
    -- Only valid when sA and sB partition the placed rooms; otherwise both sides must be kept.
    if (nA + nB) ~= #rooms then
      try_side(sA, nA, a, b) ; try_side(sB, nB, b, a)
    else
      local keepA
      if straddle then keepA = branchSet[a] and true or false
      elseif nA ~= nB then keepA = nA < nB
      else keepA = tostring(a) < tostring(b) end
      if keepA then try_side(sA, nA, a, b) else try_side(sB, nB, b, a) end
      if elro.timeGuillo then elro._brOne = (elro._brOne or 0) + 1 end
    end
  end
  for _, e in ipairs(edgesInvolved or {}) do consider_bridge(e.u, e.v, 0, 0) end
  -- Walk bridges on all anchor-pair paths (anchorA/anchorB to each involved endpoint): a single
  -- BFS path may detour around the separating bridge. Note that placing the room that closes a
  -- loop removes every piston on that loop (isBridge turns false), so a missing piston is
  -- usually lost one conflict earlier.
  local function walk_path(src, dst)
    local par2, q2, qh2 = { [src] = src }, { src }, 1
    local dep = { [src] = 0 }
    while qh2 <= #q2 do
      local u = q2[qh2] ; qh2 = qh2 + 1
      if u == dst then break end
      for _, v in each_exit(radj[u]) do
        if par2[v] == nil then par2[v] = u ; dep[v] = dep[u] + 1 ; q2[#q2 + 1] = v end
      end
    end
    if par2[dst] ~= nil then
      -- hops = the bridge's distance from the NEARER path end: the ranking's last structural
      -- key prefers the smallest pull that separates the anchors (see _rank_cands)
      local cur, dd = dst, dep[dst]
      while cur ~= src do
        local pp = par2[cur]
        consider_bridge(cur, pp, math.min(dep[pp], dd - dep[cur]), dep[pp])
        cur = pp
      end
    end
  end
  walk_path(anchorA, anchorB)
  for _, e in ipairs(edgesInvolved or {}) do
    walk_path(anchorA, e.u) ; walk_path(anchorA, e.v)
    walk_path(anchorB, e.u) ; walk_path(anchorB, e.v)
  end
  -- score via the shared helpers so an injected guillotine proxy competes on identical terms;
  -- the real move score is applied afterwards by junction_score in the caller
  elro._score_cands(coord, adj, subject, anchorA, anchorB, cands)
  if _lc0 then   -- flush the edge-phase shape counters
    elro._evRasN = (elro._evRasN or 0) + lcRas
    elro._evEorC = (elro._evEorC or 0) + lcEorC ; elro._evEorS = (elro._evEorS or 0) + lcEorS
  end
  return elro._rank_cands(cands)
end

-- crossing of two edges e1,e2 (each { u, v })
function elro.cheapest_lever(coord, adj, e1, e2, branchSet, subject)
  elro.bg_tick("lever-cross")
  local function still_cross(ov)
    if e1.u == e2.u or e1.u == e2.v or e1.v == e2.u or e1.v == e2.v then return false end
    local function p(r) return (ov and ov[r]) or coord[r] end
    local a, b, c, d = p(e1.u), p(e1.v), p(e2.u), p(e2.v)
    local d1 = ori(c[1], c[2], d[1], d[2], a[1], a[2]) ; local d2 = ori(c[1], c[2], d[1], d[2], b[1], b[2])
    local d3 = ori(a[1], a[2], b[1], b[2], c[1], c[2]) ; local d4 = ori(a[1], a[2], b[1], b[2], d[1], d[2])
    if not (((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0))) then return false end
    -- OPEN: first_crossing exempts a truthful grid-X (two 45 diagonals), but this feasibility
    -- test does not -- `isD` is defined and never called, so a move that restores a square
    -- grid-X can never read as feasible.
    local function isD(p1, p2)
      local dx, dy = p2[1] - p1[1], p2[2] - p1[2]
      return dx ~= 0 and (dx == dy or dx == -dy)
    end
    return true
  end
  return elro._lever_core(coord, adj, e1.u, e2.u, { e1, e2 }, still_cross, branchSet, subject)
end

-- room R sitting ON an edge e ({ u, v }) -- on e's raster, excluding e's endpoints. Candidate
-- bridges include R's own attach bridge (path R..e.u), usually the cheapest fix.
function elro.cheapest_lever_roomedge(coord, adj, R, e, branchSet, subject)
  elro.bg_tick("lever-roomedge")
  -- the endpoint guard is load-bearing: seg_hits tests a stretched diagonal's endpoints, and
  -- removing the guard would widen room-on-edge for every such edge
  local function on_edge(ov)
    local function p(r) return (ov and ov[r]) or coord[r] end
    if R == e.u or R == e.v then return false end
    local a, b, pr = p(e.u), p(e.v), p(R)
    if (pr[1] == a[1] and pr[2] == a[2]) or (pr[1] == b[1] and pr[2] == b[2]) then return false end
    return seg_hits(a[1], a[2], b[1], b[2], pr[1], pr[2])
  end
  return elro._lever_core(coord, adj, R, e.u, { e }, on_edge, branchSet, subject)
end

-- two rooms A,B sharing the same cell (room-on-room overlap). No edge to re-angle; the
-- candidate bridges are those on the path A..B (move one side off the shared cell).
function elro.cheapest_lever_overlap(coord, adj, A, B, branchSet, subject)
  elro.bg_tick("lever-overlap")
  local function same_cell(ov)
    if A == B then return false end
    local function p(r) return (ov and ov[r]) or coord[r] end
    local a, b = p(A), p(B)
    return a[1] == b[1] and a[2] == b[2]
  end
  return elro._lever_core(coord, adj, A, B, {}, same_cell, branchSet, subject)
end
