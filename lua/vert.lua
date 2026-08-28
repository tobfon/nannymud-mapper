-- Vertical exits (up/down): classification, packing, bridge pistons, census and drawing.
-- Split out of layout.lua; loaded after it (reads elro.TUNE and elro.area_adjacency).

elro = elro or {}
local G = elro.g or error("vert.lua: lua/geom.lua must be loaded first (see elro.modules)")
local seg, seg_cross_strict = G.seg, G.seg_cross_strict
local K = elro.k or error("vert.lua: lua/keys.lua must be loaded first (see elro.modules)")
local ekey = K.edge
local each_exit = elro.exits or error("vert.lua: lua/core.lua must be loaded first")
local TUNE = elro.TUNE or error("vert.lua: lua/layout.lua must be loaded first")
local area_adjacency = elro.area_adjacency or error("vert.lua: lua/layout.lua must be loaded first")

-- ---- VERTICAL EXITS: classify, pack, draw (elro.vertPack) ----
-- up/down exits never enter `adj`; they live in a side table read by the packer and
-- renderer. Placement is translation-only, so a spanning forest over (components,
-- vertical links) decides which links are honoured.

-- Canonical offsets at atan(1/2)/atan(2): never a multiple of 45 degrees, so the
-- geometry alone marks a vertical. The angle is the invariant, the scale is free (a
-- ray search steps outward). The x sign is free; the y sign is semantic: up = +y,
-- never flipped to find room. Indices 1-2 are the steep pair and 3-4 the shallow one;
-- `vert_ray` tests `oi <= 2`, so do not reorder without changing that test.
local VERT_OFF = { { 1, 2 }, { -1, 2 }, { 2, 1 }, { -2, 1 } }

-- One function because the packer and `vert_realised` must agree on the scale range.
local function vert_cap() return TUNE.vertScaleCap end

-- Which end of a folded link is the upper floor. `p.dir` is the direction of the
-- first dart and `p.from` the room it leaves; nothing downstream needs walk direction.
local function vert_high(p)
  local to = (p.a == p.from) and p.b or p.a
  return (p.dir == "up") and to or p.from
end

-- Shared classifier for the `mapvert` report and the packer; they must agree.
--   redundant -- both ends in the same component; draw-only.
--   forest    -- joins two components, first to do so. Honourable.
--   cycle     -- joins two already-linked components. Over-determined, draw-only.
--   cross     -- far end on another canvas.
function elro.vert_classify(rooms, comp, inScope)
  -- every vertical dart leaving a room of this scope (the far end may be outside)
  local darts = {}
  for _, r in ipairs(rooms) do
    local rec = elro.cs_room(r)
    if rec then
      for d, dest in pairs(rec.ex) do
        local del = elro.delta[d]
        if del and del[1] == 0 and del[2] == 0 and (del[3] or 0) ~= 0
           and dest and dest ~= r and roomExists(dest) then
          darts[#darts + 1] = { u = r, v = dest, d = d }
        end
      end
    end
  end
  -- pairs() order is per-process and the forest/cycle split is order-dependent: sort.
  table.sort(darts, function(x, y)
    if x.u ~= y.u then return x.u < y.u end
    if x.v ~= y.v then return x.v < y.v end
    return (elro.dirNum[x.d] or 0) < (elro.dirNum[y.d] or 0)
  end)

  -- fold the darts into UNDIRECTED links
  local P, links = {}, {}
  for _, e in ipairs(darts) do
    local lo, hi = e.u, e.v
    if lo > hi then lo, hi = hi, lo end
    local k = ekey(lo, hi)
    local p = P[k]
    if not p then
      p = { a = lo, b = hi, key = k, darts = {} }
      P[k] = p ; links[#links + 1] = p
    end
    p.darts[#p.darts + 1] = e
  end

  for _, p in ipairs(links) do
    local f = p.darts[1]
    p.from, p.dir = f.u, f.d
    local rev
    for i = 2, #p.darts do
      local e = p.darts[i]
      if e.u == f.v and e.d == elro.reverse[f.d] then rev = e end
    end
    -- a cross-area link's reverse lives in a room outside the scan; ask it directly
    if not rev then
      local frec = elro.cs_room(f.v)
      local rd = elro.reverse[f.d]
      if frec and rd and frec.ex[rd] == f.u then rev = { u = f.v, v = f.u, d = rd } end
    end
    -- an assumed (onRoom-fabricated) reverse is not corroboration; reported, not filtered
    local af = (elro.cs_room(f.u) or {}).asm
    local ar = rev and (elro.cs_room(rev.u) or {}).asm
    p.recip  = rev ~= nil
    p.corrob = p.recip and not (af and af[f.d]) and not (ar and ar[rev.d])
  end

  -- Classify: corroborated links are offered the forest first, then deterministic
  -- order, then union-find over component ids.
  table.sort(links, function(x, y)
    if x.corrob ~= y.corrob then return x.corrob and true or false end
    if x.a ~= y.a then return x.a < y.a end
    return x.b < y.b
  end)
  -- lazy union-find: `uf[c] == nil` means c is its own root
  local uf = {}
  local function find(c)
    local r = c
    while uf[r] do r = uf[r] end
    while uf[c] and uf[c] ~= r do local nx = uf[c] ; uf[c] = r ; c = nx end
    return r
  end
  local n = { redundant = 0, forest = 0, cycle = 0, cross = 0 }
  for _, p in ipairs(links) do
    if not (inScope[p.a] and inScope[p.b]) then
      p.cls = "cross"
    else
      local ca, cb = comp[p.a], comp[p.b]
      p.ca, p.cb = ca, cb
      if ca == cb then
        p.cls = "redundant"
      else
        local ra, rb = find(ca), find(cb)
        if ra == rb then p.cls = "cycle" else uf[ra] = rb ; p.cls = "forest" end
      end
    end
    n[p.cls] = n[p.cls] + 1
  end
  return links, n
end

-- Occupancy footprint of one component in local coordinates, computed once and
-- translated per candidate. Room cells and edge cells are kept apart (collision vs
-- room-on-edge); `seg` is the exact edge list, since crossings cannot be asked of a raster.
local function vert_foot(comp, lc, adj)
  local cell, ecell, seg, rk, ek, sk = {}, {}, {}, {}, {}, {}
  local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
  for _, r in ipairs(comp) do
    local p = lc[r]
    if p then
      cell[#cell + 1] = p ; rk[p[1] .. ":" .. p[2]] = true
      if p[1] < minx then minx = p[1] end ; if p[1] > maxx then maxx = p[1] end
      if p[2] < miny then miny = p[2] end ; if p[2] > maxy then maxy = p[2] end
    end
  end
  for _, r in ipairs(comp) do
    local p = lc[r]
    if p then
      for _, v in each_exit(adj[r]) do
        local q = lc[v]
        if q then
          -- sampled 4x per cell, exactly as elro.blocked_by does, so a 1-cell room
          -- cannot be stepped over by a long stretched diagonal
          local dx, dy = q[1] - p[1], q[2] - p[2]
          local steps = math.max(math.abs(dx), math.abs(dy)) * 4
          for i = 1, steps - 1 do
            local t = i / steps
            local cx = math.floor(p[1] + dx * t + 0.5)
            local cy = math.floor(p[2] + dy * t + 0.5)
            local k = cx .. ":" .. cy
            if not rk[k] and not ek[k] then ek[k] = true ; ecell[#ecell + 1] = { cx, cy } end
          end
          -- ...and the segment itself, ONCE per undirected edge (`adj` carries both darts)
          local a1, b1, a2, b2 = p[1], p[2], q[1], q[2]
          if a1 > a2 or (a1 == a2 and b1 > b2) then a1, b1, a2, b2 = a2, b2, a1, b1 end
          local key = a1 .. ":" .. b1 .. ":" .. a2 .. ":" .. b2
          if not sk[key] then sk[key] = true ; seg[#seg + 1] = { a1, b1, a2, b2 } end
        end
      end
    end
  end
  return { cell = cell, ecell = ecell, seg = seg,
           minx = minx, miny = miny, maxx = maxx, maxy = maxy }
end

-- Does the connector strictly cross a placed edge? Sharing an endpoint is not a
-- crossing. Returns the segment (truthy) so callers can name the crossed rooms.
local function vert_run_crosses(G, px, py, qx, qy)
  local lox, hix = (px < qx) and px or qx, (px > qx) and px or qx
  local loy, hiy = (py < qy) and py or qy, (py > qy) and py or qy
  local S = G.seg
  for i = 1, #S do
    local e = S[i]
    if not (e[1] < lox and e[3] < lox) and not (e[1] > hix and e[3] > hix)
       and not (e[2] < loy and e[4] < loy) and not (e[2] > hiy and e[4] > hiy) then
      if seg_cross_strict(px, py, qx, qy, e[1], e[2], e[3], e[4]) then return e end
    end
  end
  return false
end

-- Did the floor land inside a face? Flood the free cells from the child and ask whether
-- the flood escapes the mass's bounding box. The budget fails open (treated as exterior)
-- so the layout never depends on it.
local function vert_enclosed(G, foot, dx, dy)
  if foot.maxx + dx < G.minx or foot.minx + dx > G.maxx
     or foot.maxy + dy < G.miny or foot.miny + dy > G.maxy then return false end
  local x0, y0 = G.minx - 1, G.miny - 1
  local x1, y1 = G.maxx + 1, G.maxy + 1
  local seen, q, qh, n = {}, {}, 1, 0
  for i = 1, #foot.cell do
    local c = foot.cell[i]
    local x, y = c[1] + dx, c[2] + dy
    local k = x .. ":" .. y
    if not seen[k] then seen[k] = true ; q[#q + 1] = x ; q[#q + 1] = y end
  end
  local budget = TUNE.vertFloodCap
  while qh <= #q do
    local x, y = q[qh], q[qh + 1] ; qh = qh + 2
    if x <= x0 or x >= x1 or y <= y0 or y >= y1 then return false end   -- reached the open
    n = n + 1 ; if n > budget then return false end                     -- fail open
    for ox = -1, 1 do
      for oy = -1, 1 do
        if ox ~= 0 or oy ~= 0 then
          local nx, ny = x + ox, y + oy
          local k = nx .. ":" .. ny
          if not seen[k] and not G.cell[k] and not G.ecell[k] then
            seen[k] = true ; q[#q + 1] = nx ; q[#q + 1] = ny
          end
        end
      end
    end
  end
  return true
end

-- a fresh single-component group, ready to be docked onto
local function vert_group(comp, lc, foot)
  -- `rayUse` counts how many INDEPENDENT docks in this group have already taken each ray --
  -- see the fan-out term in vert_ray. Carried docks are deliberately not counted.
  local G = { coord = {}, cell = {}, ecell = {}, seg = {}, rayUse = {},
              minx = foot.minx, miny = foot.miny, maxx = foot.maxx, maxy = foot.maxy }
  for _, r in ipairs(comp) do
    local p = lc[r]
    if p then G.coord[r] = p ; G.cell[p[1] .. ":" .. p[2]] = true end
  end
  for _, c in ipairs(foot.ecell) do G.ecell[c[1] .. ":" .. c[2]] = true end
  for _, e in ipairs(foot.seg) do G.seg[#G.seg + 1] = e end
  return G
end

local function vert_merge(G, comp, lc, foot, dx, dy)
  for _, r in ipairs(comp) do
    local p = lc[r]
    if p then
      local x, y = p[1] + dx, p[2] + dy
      G.coord[r] = { x, y } ; G.cell[x .. ":" .. y] = true
    end
  end
  for _, c in ipairs(foot.ecell) do G.ecell[(c[1] + dx) .. ":" .. (c[2] + dy)] = true end
  for _, e in ipairs(foot.seg) do
    G.seg[#G.seg + 1] = { e[1] + dx, e[2] + dy, e[3] + dx, e[4] + dy }
  end
  if foot.minx + dx < G.minx then G.minx = foot.minx + dx end
  if foot.maxx + dx > G.maxx then G.maxx = foot.maxx + dx end
  if foot.miny + dy < G.miny then G.miny = foot.miny + dy end
  if foot.maxy + dy > G.maxy then G.maxy = foot.maxy + dy end
end

-- Does candidate (ray `o`, scale `k`) fit? Returns the translation (dx,dy) that puts
-- the child's link room `v` at gu + sgn*o*k, or nil. Split out of vert_ray so the
-- CARRY below can test one named candidate without re-entering the search.
local function vert_fit(G, gu, foot, o, k, sgn, vx, vy)
  local tx, ty = gu[1] + sgn * o[1] * k, gu[2] + sgn * o[2] * k
  local dx, dy = tx - vx, ty - vy
  -- `elro.vertOverRoom` relaxes only a room centre on the connector's own run. Collision,
  -- room-on-edge and edge-on-room are never relaxed. `vert_realised` reads the same knob
  -- and must not drift from this test.
  local overRoom = elro.vertOverRoom
  if foot.minx + dx <= G.maxx and foot.maxx + dx >= G.minx
     and foot.miny + dy <= G.maxy and foot.maxy + dy >= G.miny then
    for i = 1, #foot.cell do
      local c = foot.cell[i]
      local key = (c[1] + dx) .. ":" .. (c[2] + dy)
      if G.cell[key] then return nil, "collision" end
      if G.ecell[key] then return nil, "room-on-edge" end
    end
    for i = 1, #foot.ecell do
      local c = foot.ecell[i]
      if G.cell[(c[1] + dx) .. ":" .. (c[2] + dy)] then return nil, "edge-on-room" end
    end
  end
  -- The link's own run must be clear. The offset components are coprime, so the interior
  -- lattice points are exactly gu + sgn*o*j, j = 1..k-1: this is `elro.room_on_segment`
  -- specialised and exact. Deliberately not `blocked_by` (which would refuse corner clips);
  -- declined links are checked with `blocked_by` at draw time instead.
  if k > 1 and not overRoom then
    local seen = {}
    for i = 1, #foot.cell do
      local c = foot.cell[i]
      seen[(c[1] + dx) .. ":" .. (c[2] + dy)] = true
    end
    for j = 1, k - 1 do
      local key = (gu[1] + sgn * o[1] * j) .. ":" .. (gu[2] + sgn * o[2] * j)
      if G.cell[key] or seen[key] then return nil, "run" end
    end
  end
  -- A crossing is accepted out in the open but not inside a face. Cheap test first (the
  -- enclosure test is a flood). `~= false`: the knob defaults on.
  if elro.vertNoCrossInFace ~= false
     and vert_run_crosses(G, gu[1], gu[2], tx, ty)
     and vert_enclosed(G, foot, dx, dy) then
    return nil, "crossing inside a face"
  end
  return dx, dy
end

-- Did a link nobody placed come out canonical anyway? Draw-time only, moves nothing.
-- Same predicate the packer imposes: canonical ray, within the scale cap, correct y sign
-- (higher floor higher on screen), no room centre on the run. Shared with the bridge
-- piston, so keep it one function.
local function vert_realised(p, ax, ay, bx, by, occ, a, b)
  local dx, dy = bx - ax, by - ay
  local adx, ady = math.abs(dx), math.abs(dy)
  local k
  if ady == 2 * adx and adx >= 1 then k = adx
  elseif adx == 2 * ady and ady >= 1 then k = ady
  else return false end
  if k > vert_cap() then return false end
  local hi = vert_high(p)
  if not (((hi == b) and dy > 0) or ((hi == a) and dy < 0)) then return false end
  if elro.vertOverRoom then return true end
  return elro.room_on_segment(occ, ax, ay, bx, by, a, b) == nil
end

-- Diagnostic for the decline path. A room on the scale-1 cell of a ray lies inside every
-- longer run on that ray, so "no scale helps" is exact: only `vertOverRoom` can rescue it.
local function vert_diag(G, gu, foot, sgn, vx, vy)
  local parts, dead = {}, 0
  for oi = 1, #VERT_OFF do
    local o = VERT_OFF[oi]
    local _, why = vert_fit(G, gu, foot, o, 1, sgn, vx, vy)
    local d = G.cell[(gu[1] + sgn * o[1]) .. ":" .. (gu[2] + sgn * o[2])] and true or false
    if d then dead = dead + 1 end
    parts[#parts + 1] = string.format("(%+d,%+d) %s%s", sgn * o[1], sgn * o[2],
      why or "fits", d and " [no scale helps]" or "")
  end
  return table.concat(parts, "; "), dead
end

-- Separation term: docked-floor rooms 8-adjacent to a mass room they have no exit to.
-- A contact count (not a graded repel field) is zero for anything standing clear, which
-- is what lets it rank above the ratio preference without overriding it. The stair pair
-- itself is never 8-adjacent since every canonical offset has max(|dx|,|dy|) = 2.
local function vert_contacts(G, foot, dx, dy)
  local n = 0
  local x0, y0, x1, y1 = G.minx - 1, G.miny - 1, G.maxx + 1, G.maxy + 1
  for i = 1, #foot.cell do
    local c = foot.cell[i]
    local x, y = c[1] + dx, c[2] + dy
    if x >= x0 and x <= x1 and y >= y0 and y <= y1 then
      for ox = -1, 1 do
        for oy = -1, 1 do
          if (ox ~= 0 or oy ~= 0) and G.cell[(x + ox) .. ":" .. (y + oy)] then
            n = n + 1
          end
        end
      end
    end
  end
  return n
end

-- lexicographic compare of two ranking keys
local function vert_better(a, b)
  for i = 1, #a do
    if a[i] ~= b[i] then return a[i] < b[i] end
  end
  return false
end

-- Ray search: the smallest scale that fits wins outright. Within a scale, rank by
-- separation (vert_contacts), then the steep ratio, then fan-out (independent docks
-- already on this ray), then bbox area and perimeter as the last tie-break.
-- If the parent was itself docked by a vertical, its ray (`prefOi`) is carried and
-- wins outright at the smallest scale that fits; the scale is deliberately not carried.
local function vert_ray(G, gu, lc, comp, foot, v, sgn, cap, prefOi, prefK)
  local vx, vy = lc[v][1], lc[v][2]
  if prefOi then
    for k = 1, cap do
      local dx, dy = vert_fit(G, gu, foot, VERT_OFF[prefOi], k, sgn, vx, vy)
      if dx then
        return { dx = dx, dy = dy, k = k, oi = prefOi,
                 carry = (k == prefK) and "ladder" or "collinear" }
      end
    end
  end
  for k = 1, cap do
    local best
    for oi = 1, #VERT_OFF do
      local dx, dy = vert_fit(G, gu, foot, VERT_OFF[oi], k, sgn, vx, vy)
      if dx then
        local w = math.max(G.maxx, foot.maxx + dx) - math.min(G.minx, foot.minx + dx)
        local h = math.max(G.maxy, foot.maxy + dy) - math.min(G.miny, foot.miny + dy)
        local key = { vert_contacts(G, foot, dx, dy), (oi <= 2) and 0 or 1,
                      G.rayUse[oi] or 0, w * h, w + h, oi }
        if not best or vert_better(key, best.key) then
          best = { dx = dx, dy = dy, k = k, oi = oi, key = key }
        end
      end
    end
    if best then return best end
  end
  return nil
end

-- ======== BRIDGE PISTON (elro.vertPiston): stretch one Tarjan bridge so a near-miss
-- vertical draws straight. A bridge cancels out of every closure sum, so stretching it
-- is always truthful. Applied, measured, reverted unless no defect kind increases.

-- Rigidity graph of one group: compass edges plus honoured vertical links. Sides are
-- taken from this graph so a moved side carries every component docked beyond it.
local function vert_rigid(G, adj, hon)
  local rooms, radj, inG = {}, {}, {}
  for r in pairs(G.coord) do rooms[#rooms + 1] = r end
  table.sort(rooms)                       -- pairs order is per-process
  for _, r in ipairs(rooms) do inG[r] = true ; radj[r] = {} end
  for _, r in ipairs(rooms) do
    for d, v in each_exit(adj[r]) do
      local de = elro.delta[d]
      if inG[v] and de and (de[1] ~= 0 or de[2] ~= 0) then radj[r][d] = v end
    end
  end
  -- Verticals are keyed `^<id>` (no compass direction; `elro.delta[key]` is nil). These
  -- keys must be registered with `exits_extra` or the deterministic iterator drops them.
  local xk = {}
  for _, p in ipairs(hon) do
    if inG[p.a] and inG[p.b] then
      radj[p.a]["^" .. p.b] = p.b
      radj[p.b]["^" .. p.a] = p.a
      local ka = xk[p.a] ; if not ka then ka = {} ; xk[p.a] = ka end ; ka[#ka + 1] = "^" .. p.b
      local kb = xk[p.b] ; if not kb then kb = {} ; xk[p.b] = kb end ; kb[#kb + 1] = "^" .. p.a
    end
  end
  for r, keys in pairs(xk) do elro.exits_extra(radj[r], keys) end
  return rooms, radj
end

-- Bridges (a one-edge block of `blocks_adj`), then the 2-edge-connected condensation as
-- a rooted tree. A bridge separates a from b exactly when it lies on the tree path
-- between their nodes, so the candidates are one LCA climb.
local function vert_btree(rooms, radj)
  local blocks, _, nbr = elro.blocks_adj(rooms, radj)
  local isBr, nBr = {}, 0
  for _, blk in ipairs(blocks) do
    if #blk == 1 then
      local x, y = blk[1][1], blk[1][2]
      local k = ekey(x, y)
      if not isBr[k] then isBr[k] = true ; nBr = nBr + 1 end
    end
  end
  -- the condensation's NODES: flood over the NON-bridge edges
  local ec, nec, mem = {}, 0, {}
  for _, r in ipairs(rooms) do
    if not ec[r] then
      nec = nec + 1 ; ec[r] = nec ; mem[nec] = {}
      local q, h = { r }, 1
      while h <= #q do
        local u = q[h] ; h = h + 1
        local m = mem[nec] ; m[#m + 1] = u
        for _, v in ipairs(nbr[u] or {}) do
          local k = ekey(u, v)
          if not ec[v] and not isBr[k] then ec[v] = nec ; q[#q + 1] = v end
        end
      end
    end
  end
  -- its edges, the bridges, recorded once per direction
  local tn = {}
  for _, r in ipairs(rooms) do
    for _, v in ipairs(nbr[r] or {}) do
      local k = ekey(r, v)
      if isBr[k] then
        local c = ec[r] ; tn[c] = tn[c] or {}
        tn[c][#tn[c] + 1] = { to = ec[v], here = r, there = v }
      end
    end
  end
  local par, dep, pe = {}, {}, {}
  for c = 1, nec do
    if not dep[c] then
      dep[c] = 0
      local q, h = { c }, 1
      while h <= #q do
        local u = q[h] ; h = h + 1
        for _, e in ipairs(tn[u] or {}) do
          if not dep[e.to] then
            dep[e.to] = dep[u] + 1 ; par[e.to] = u
            -- `mv` is the endpoint inside the child subtree (moves), `st` outside (stays)
            pe[e.to] = { mv = e.there, st = e.here }
            q[#q + 1] = e.to
          end
        end
      end
    end
  end
  local subCache = {}
  local function sub(c)                   -- the room set below the bridge above `c`
    local s = subCache[c]
    if s then return s end
    s = {}
    local q, h, seen = { c }, 1, { [c] = true }
    while h <= #q do
      local u = q[h] ; h = h + 1
      for _, r in ipairs(mem[u] or {}) do s[r] = true end
      for _, e in ipairs(tn[u] or {}) do
        if not seen[e.to] and par[e.to] == u then seen[e.to] = true ; q[#q + 1] = e.to end
      end
    end
    subCache[c] = s
    return s
  end
  -- bridges separating a from b, tagged with which end the moving side holds
  local function path(a, b)
    local ca, cb, out = ec[a], ec[b], {}
    if not (ca and cb) or ca == cb then return out end
    while dep[ca] > dep[cb] do out[#out + 1] = { node = ca, holds = "a" } ; ca = par[ca] end
    while dep[cb] > dep[ca] do out[#out + 1] = { node = cb, holds = "b" } ; cb = par[cb] end
    while ca ~= cb do
      if not (par[ca] and par[cb]) then return {} end   -- two trees: nothing separates them
      out[#out + 1] = { node = ca, holds = "a" } ; ca = par[ca]
      out[#out + 1] = { node = cb, holds = "b" } ; cb = par[cb]
    end
    return out
  end
  return { sub = sub, path = path, pe = pe, nbridge = nBr }
end

-- Occupancy from group-local coordinates (not `elro.cell_census`, which reads Mudlet).
local function vert_occ(rooms, coord)
  local occ = {}
  for i = 1, #rooms do
    local p = coord[rooms[i]]
    if p then occ[p[1] .. ":" .. p[2]] = rooms[i] end
  end
  return occ
end

-- v == t * del for an integer t (del is a unit compass delta, so t is exact), or nil.
local function vert_mult(vx, vy, del)
  if vx * del[2] - vy * del[1] ~= 0 then return nil end
  if del[1] ~= 0 then return vx / del[1] end
  if del[2] ~= 0 then return vy / del[2] end
  return nil
end

-- The vertical links of one group, both ends present, in classify order.
local function vert_gl(G, links)
  local gl = {}
  for _, p in ipairs(links) do
    if p.cls ~= "cross" and G.coord[p.a] and G.coord[p.b] then gl[#gl + 1] = p end
  end
  return gl
end

-- Which links would draw straight, by the renderer's own predicate. Honoured links are
-- included deliberately: a piston could slide a room onto their run and nothing else
-- (count_defects cannot see connectors) would notice.
local function vert_drawn(rooms, coord, gl)
  local occ = vert_occ(rooms, coord)
  local set, n = {}, 0
  for i = 1, #gl do
    local p = gl[i]
    local a = p.from ; local b = (p.a == a) and p.b or p.a
    local pa, pb = coord[a], coord[b]
    if pa and pb and vert_realised(p, pa[1], pa[2], pb[1], pb[2], occ, a, b) then
      set[i] = true ; n = n + 1
    end
  end
  return set, n
end

-- defect-gate inputs. Built over `elro.dir_order`, not `pairs`, so traces reproduce.
local function vert_pedges(rooms, radj)
  local placed, pedges, seenE = {}, {}, {}
  for _, r in ipairs(rooms) do placed[r] = true end
  elro._bfGen = (elro._bfGen or 0) + 1
  for _, r in ipairs(rooms) do
    for _, d in ipairs(elro.dir_order) do
      local v = radj[r][d]
      if v then
        local k = ekey(r, v)
        if not seenE[k] then seenE[k] = true ; pedges[#pedges + 1] = { u = r, v = v } end
      end
    end
  end
  return placed, pedges
end

-- Bridge direction, asked at both ends (a one-way exit is still a bridge on the
-- undirected graph). Returns nil for a genuine vertical bridge.
local function vert_bridge_dir(radj, e)
  for _, dd in ipairs(elro.dir_order) do
    if radj[e.st][dd] == e.mv then return dd, elro.delta[dd] end
  end
  for _, dd in ipairs(elro.dir_order) do
    if radj[e.mv][dd] == e.st then
      local q = elro.delta[dd]
      return elro.reverse[dd], { -q[1], -q[2] }
    end
  end
  return nil
end

-- The piston pass over one group, run after every dock is finished. Returns tried, applied.
local function vert_piston(G, adj, links, hon, cap, gi)
  local rooms, radj = vert_rigid(G, adj, hon)
  if #rooms < 3 then return 0, 0 end
  local gl = vert_gl(G, links)
  if #gl == 0 then return 0, 0 end
  local function drawn_set() return vert_drawn(rooms, G.coord, gl) end
  local drawn, ndrawn = drawn_set()
  if ndrawn == #gl then return 0, 0 end        -- every link already draws straight

  local T = vert_btree(rooms, radj)
  if T.nbridge == 0 then return 0, 0 end
  local placed, pedges = vert_pedges(rooms, radj)

  local maxL1 = TUNE.vertPistonL1
  local budget = TUNE.vertPistonTries
  local _, bOv, bRoe, bX = elro.count_defects(G.coord, placed, pedges)
  local nTry, nApp = 0, 0

  for i = 1, #gl do
    if not drawn[i] and nTry < budget then
      local p = gl[i]
      local a = p.from ; local b = (p.a == a) and p.b or p.a
      local pa, pb = G.coord[a], G.coord[b]
      local ox, oy = pb[1] - pa[1], pb[2] - pa[2]
      local sgn = (vert_high(p) == b) and 1 or -1
      -- candidate corrections to (b - a); `best` is the nearest legal distance, for the trace
      local cands, best = {}, math.huge
      for k = 1, cap do
        for oi = 1, #VERT_OFF do
          local dx = sgn * VERT_OFF[oi][1] * k - ox
          local dy = sgn * VERT_OFF[oi][2] * k - oy
          local l1 = math.abs(dx) + math.abs(dy)
          if l1 > 0 and l1 < best then best = l1 end
          if l1 > 0 and l1 <= maxL1 then
            cands[#cands + 1] = { dx = dx, dy = dy, l1 = l1, k = k, oi = oi }
          end
        end
      end
      if #cands == 0 then
        -- `best` can be math.huge (cap 0); `%d` on it throws
        elro.tr(string.format("vert: piston %s %s %s -- nearest legal offset is %s cell(s)"
          .. " away, out of range (TUNE.vertPistonL1 = %d)",
          tostring(p.from), p.dir, tostring((p.a == p.from) and p.b or p.a),
          (best < math.huge) and string.format("%d", best) or "infinitely many", maxL1))
      end
      table.sort(cands, function(x, y)
        if x.l1 ~= y.l1 then return x.l1 < y.l1 end
        if x.k ~= y.k then return x.k < y.k end
        return x.oi < y.oi
      end)
      local path = (#cands > 0) and T.path(a, b) or {}
      -- smallest moving side first; node id breaks ties so the order is total
      for _, ent in ipairs(path) do ent.n = elro.tcount(T.sub(ent.node)) end
      table.sort(path, function(x, y)
        if x.n ~= y.n then return x.n < y.n end
        return x.node < y.node
      end)
      -- `nope` tallies why each (correction, bridge) pair was not tried
      local nope, done = {}, false
      local function no(k) nope[k] = (nope[k] or 0) + 1 end
      for ci = 1, #cands do
        if done or nTry >= budget then break end
        local cd = cands[ci]
        for pi = 1, #path do
          if done or nTry >= budget then break end
          local ent = path[pi]
          local e = T.pe[ent.node]
          -- the moving side holds exactly one of a / b
          local tx = (ent.holds == "b") and cd.dx or -cd.dx
          local ty = (ent.holds == "b") and cd.dy or -cd.dy
          -- Axis rule: the correction must be parallel to the bridge's declared direction,
          -- the bridge must already be truthful, and it may not shrink to or through zero.
          local d, del = vert_bridge_dir(radj, e)
          if not del then no("vertical bridge") else
            local qm, qs = G.coord[e.mv], G.coord[e.st]
            local m = vert_mult(qm[1] - qs[1], qm[2] - qs[2], del)
            local t = vert_mult(tx, ty, del)
            if not t then no("axis " .. d)
            elseif not m or m < 1 then no("skew " .. d)
            elseif t == 0 or (m + t) < 1 then no("would shrink " .. d)
            else
              elro.bg_tick("vert-piston")
              nTry = nTry + 1
              local S = T.sub(ent.node)
              local old = {}
              for r in pairs(S) do
                local q = G.coord[r]
                old[r] = q ; G.coord[r] = { q[1] + tx, q[2] + ty }
              end
              local _, nOv, nRoe, nX = elro.count_defects(G.coord, placed, pedges)
              local set2, n2 = drawn_set()
              local why
              if not set2[i] then why = "target still not drawable"
              elseif nOv > bOv then why = string.format("collisions %d -> %d", bOv, nOv)
              elseif nRoe > bRoe then why = string.format("room-on-edge %d -> %d", bRoe, nRoe)
              elseif nX > bX then why = string.format("crossings %d -> %d", bX, nX)
              else
                for j = 1, #gl do
                  if drawn[j] and not set2[j] then
                    local q = gl[j]
                    why = string.format("would un-draw %s %s %s", tostring(q.from), q.dir,
                                        tostring((q.a == q.from) and q.b or q.a))
                    break
                  end
                end
              end
              if why then
                for r, q in pairs(old) do G.coord[r] = q end
                elro.tr(string.format(
                  "vert: piston %s %s %s -- (%+d,%+d) on bridge %s-%s %s x%d REVERTED: %s",
                  tostring(p.from), p.dir, tostring((p.a == p.from) and p.b or p.a), tx, ty,
                  tostring(e.st), tostring(e.mv), d, t, why))
              else
                drawn, ndrawn = set2, n2
                bOv, bRoe, bX = nOv, nRoe, nX
                nApp = nApp + 1 ; done = true
                elro.step_snap(G.coord, string.format(
                  "vert: PISTON bridge %s-%s %s stretched %+d -- %s %s %s now draws straight",
                  tostring(e.st), tostring(e.mv), d, t,
                  tostring(p.from), p.dir, tostring((p.a == p.from) and p.b or p.a)), a, b)
                elro.tr(string.format(
                  "vert: PISTON group %d -- %s %s %s drawn by moving %d room(s) (%+d,%+d)"
                  .. " along bridge %s-%s %s (length %d -> %d)",
                  gi, tostring(p.from), p.dir, tostring((p.a == p.from) and p.b or p.a),
                  elro.tcount(S), tx, ty, tostring(e.st), tostring(e.mv), d, m, m + t))
              end
            end
          end
        end
      end
      if not done and #cands > 0 then
        local parts = {}
        for k, v in pairs(nope) do parts[#parts + 1] = k .. " x" .. v end
        table.sort(parts)
        local cs = {}
        for _, c in ipairs(cands) do
          cs[#cs + 1] = string.format("(%+d,%+d)", c.dx, c.dy)
        end
        elro.tr(string.format("vert: piston %s %s %s -- want %s; %d separating bridge(s),"
          .. " none applied [%s]",
          tostring(p.from), p.dir, tostring((p.a == p.from) and p.b or p.a),
          table.concat(cs, " or "), #path, table.concat(parts, ", ")))
      end
    end
  end
  return nTry, nApp
end

-- ======== MAKE ROOM (elro.vertMakeRoom, default off): free a cell on the mass before a
-- forest dock that would otherwise be declined. "Not worse" is measured on the mass alone.

-- Who owns each cell of the mass: the room in it, the compass edge through it, and each
-- segment's two rooms. Built over `elro.dir_order`, not `pairs`, so the named blocker
-- is deterministic.
local function vert_owners(rooms, coord, adj)
  local rk, ek, sk = {}, {}, {}
  for i = 1, #rooms do
    local p = coord[rooms[i]]
    if p then rk[p[1] .. ":" .. p[2]] = rooms[i] end
  end
  for i = 1, #rooms do
    local r = rooms[i] ; local p = coord[r]
    if p then
      for _, d in ipairs(elro.dir_order) do
        local v = (adj[r] or {})[d]
        local q = v and coord[v]
        if q then
          local dx, dy = q[1] - p[1], q[2] - p[2]
          local steps = math.max(math.abs(dx), math.abs(dy)) * 4
          for j = 1, steps - 1 do
            local t = j / steps
            local cx = math.floor(p[1] + dx * t + 0.5)
            local cy = math.floor(p[2] + dy * t + 0.5)
            local key = cx .. ":" .. cy
            if not rk[key] and not ek[key] then ek[key] = { r, v } end
          end
          local a1, b1, a2, b2 = p[1], p[2], q[1], q[2]
          if a1 > a2 or (a1 == a2 and b1 > b2) then a1, b1, a2, b2 = a2, b2, a1, b1 end
          sk[a1 .. ":" .. b1 .. ":" .. a2 .. ":" .. b2] = { r, v }
        end
      end
    end
  end
  return { room = rk, edge = ek, seg = sk }
end

-- Which mass rooms refuse this candidate (all of them, not the first). Must mirror
-- `vert_fit` refusal for refusal. Returns nil when the child's own room blocks the run,
-- since no piston on the mass can fix that.
local function vert_block_set(G, own, gu, foot, o, k, sgn, vx, vy)
  local tx, ty = gu[1] + sgn * o[1] * k, gu[2] + sgn * o[2] * k
  local dx, dy = tx - vx, ty - vy
  local W, seen = {}, {}
  local function add(r) if r and not seen[r] then seen[r] = true ; W[#W + 1] = r end end
  for i = 1, #foot.cell do
    local c = foot.cell[i] ; local key = (c[1] + dx) .. ":" .. (c[2] + dy)
    local o1 = own.room[key]
    if o1 then add(o1)                                        -- collision
    else
      local oe = own.edge[key]
      if oe then add(oe[1]) ; add(oe[2]) end                   -- room-on-edge
    end
  end
  for i = 1, #foot.ecell do                                    -- edge-on-room
    add(own.room[(foot.ecell[i][1] + dx) .. ":" .. (foot.ecell[i][2] + dy)])
  end
  if k > 1 and not elro.vertOverRoom then
    local mine = {}
    for i = 1, #foot.cell do
      mine[(foot.cell[i][1] + dx) .. ":" .. (foot.cell[i][2] + dy)] = true
    end
    for j = 1, k - 1 do
      local key = (gu[1] + sgn * o[1] * j) .. ":" .. (gu[2] + sgn * o[2] * j)
      if mine[key] then return nil end                         -- the child's own doing
      add(own.room[key])                                       -- a mass room on the run
    end
  end
  -- the face rule's blocker is the crossed edge's two rooms; asked last, it is the expensive test
  if #W == 0 and elro.vertNoCrossInFace ~= false then
    local e = vert_run_crosses(G, gu[1], gu[2], tx, ty)
    if e and vert_enclosed(G, foot, dx, dy) then
      local ow = own.seg[e[1] .. ":" .. e[2] .. ":" .. e[3] .. ":" .. e[4]]
      if ow then add(ow[1]) ; add(ow[2]) end
    end
  end
  return W
end

-- Rebuild the group's occupancy from its coordinates (a make-room piston runs before a
-- dock, and `vert_fit` reads cell/ecell/seg). The reserved connector runs of honoured
-- links must be re-added: they belong to no compass edge, and the gcd of the realised
-- offset is the scale.
local function vert_rebuild(G, adj, hon, rooms)
  local f = vert_foot(rooms, G.coord, adj)
  G.cell, G.ecell, G.seg = {}, {}, f.seg
  for _, c in ipairs(f.cell) do G.cell[c[1] .. ":" .. c[2]] = true end
  for _, c in ipairs(f.ecell) do G.ecell[c[1] .. ":" .. c[2]] = true end
  G.minx, G.miny, G.maxx, G.maxy = f.minx, f.miny, f.maxx, f.maxy
  for _, p in ipairs(hon) do
    local A, B = G.coord[p.a], G.coord[p.b]
    if A and B then
      local dx, dy = B[1] - A[1], B[2] - A[2]
      local g
      do local x, y = (dx < 0) and -dx or dx, (dy < 0) and -dy or dy
         while y ~= 0 do x, y = y, x % y end
         g = x
      end
      if g > 1 then
        local sx, sy = dx / g, dy / g
        for j = 1, g - 1 do G.ecell[(A[1] + sx * j) .. ":" .. (A[2] + sy * j)] = true end
      end
    end
  end
end

-- The make-room pass, run when the packer is about to decline. Returns the `vert_ray`
-- result of a dock that now fits (piston left applied), or nil after reverting everything.
local function vert_makeroom(G, adj, links, hon, lc, comp, foot, u, v, sgn, cap, prefOi, prefK)
  local rooms, radj = vert_rigid(G, adj, hon)
  if #rooms < 3 then return nil end
  local T = vert_btree(rooms, radj)
  if T.nbridge == 0 then return nil end
  local own = vert_owners(rooms, G.coord, adj)
  local gl = vert_gl(G, links)
  local drawn = vert_drawn(rooms, G.coord, gl)
  local placed, pedges = vert_pedges(rooms, radj)
  local _, bOv, bRoe, bX = elro.count_defects(G.coord, placed, pedges)
  local maxL1 = TUNE.vertPistonL1
  local budget = TUNE.vertRoomTries
  local maxWork = TUNE.vertRoomWork
  local vx, vy = lc[v][1], lc[v][2]
  local nTry, nope = 0, {}
  local function no(k) nope[k] = (nope[k] or 0) + 1 end

  -- nearest floor first, as the ray search itself scans
  for k = 1, cap do
    for oi = 1, #VERT_OFF do
      if nTry >= budget then break end
      local W = vert_block_set(G, own, G.coord[u], foot, VERT_OFF[oi], k, sgn, vx, vy)
      if W and #W > 0 then
        -- bridges that can help: every blocker on the far side, `u` on the near one
        local cand = {}
        for _, ent in ipairs(T.path(u, W[1])) do
          if ent.holds == "b" then
            local S = T.sub(ent.node)
            local all = true
            for i = 2, #W do if not S[W[i]] then all = false ; break end end
            if all then cand[#cand + 1] = { node = ent.node, n = elro.tcount(S), S = S } end
          end
        end
        if #cand == 0 then no("no bridge holds every blocker") end
        table.sort(cand, function(x, y)
          if x.n ~= y.n then return x.n < y.n end
          return x.node < y.node
        end)
        for _, c in ipairs(cand) do
          local e = T.pe[c.node]
          local d, del = vert_bridge_dir(radj, e)
          if not del then no("vertical bridge") else
            local qm, qs = G.coord[e.mv], G.coord[e.st]
            local m = vert_mult(qm[1] - qs[1], qm[2] - qs[2], del)
            if not m or m < 1 then no("skew " .. d) else
              -- same L1 cap as the other trigger
              local unit = math.abs(del[1]) + math.abs(del[2])
              for at = 1, math.floor(maxL1 / unit) do
                for si = 1, 2 do
                  local t = (si == 1) and at or -at
                  local work = c.n * at * unit
                  -- The defect gate cannot price inflation (a bridge stretch adds no defect),
                  -- so charge the work: rooms moved x cells moved, checked before the trial.
                  if work > maxWork then
                    no(string.format("too big: %d room(s) x %d cell(s)", c.n, at * unit))
                  elseif m + t >= 1 and nTry < budget then
                    -- must yield: every trial re-rasterises the whole group
                    elro.bg_tick("vert-makeroom")
                    nTry = nTry + 1
                    local tx, ty = t * del[1], t * del[2]
                    local old = {}
                    for r in pairs(c.S) do
                      local q = G.coord[r]
                      old[r] = q ; G.coord[r] = { q[1] + tx, q[2] + ty }
                    end
                    vert_rebuild(G, adj, hon, rooms)
                    local best = vert_ray(G, G.coord[u], lc, comp, foot, v, sgn, cap,
                                          prefOi, prefK)
                    local why
                    if not best then why = "still no room"
                    else
                      local _, nOv, nRoe, nX = elro.count_defects(G.coord, placed, pedges)
                      local set2 = vert_drawn(rooms, G.coord, gl)
                      if nOv > bOv then why = string.format("collisions %d -> %d", bOv, nOv)
                      elseif nRoe > bRoe then why = string.format("room-on-edge %d -> %d", bRoe, nRoe)
                      elseif nX > bX then why = string.format("crossings %d -> %d", bX, nX)
                      else
                        for j = 1, #gl do
                          if drawn[j] and not set2[j] then
                            local q = gl[j]
                            why = string.format("would un-draw %s %s %s", tostring(q.from),
                              q.dir, tostring((q.a == q.from) and q.b or q.a))
                            break
                          end
                        end
                      end
                    end
                    if why then
                      for r, q in pairs(old) do G.coord[r] = q end
                      vert_rebuild(G, adj, hon, rooms)
                      no(why)
                    else
                      elro.tr(string.format(
                        "vert: MAKE ROOM -- bridge %s-%s %s stretched %+d moves %d room(s)"
                        .. " out of the way (%d blocker(s): %s); dock now fits on ray %d"
                        .. " at scale %d",
                        tostring(e.st), tostring(e.mv), d, t, c.n, #W,
                        tostring(W[1]) .. ((#W > 1) and (" +" .. (#W - 1)) or ""),
                        best.oi, best.k))
                      elro.step_snap(G.coord, string.format(
                        "vert: MAKE ROOM -- bridge %s-%s %s stretched %+d to fit %s %s %s",
                        tostring(e.st), tostring(e.mv), d, t,
                        tostring(u), (sgn > 0) and "up" or "down", tostring(v)), u)
                      return best, nTry
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
  if nTry > 0 or next(nope) then
    local parts = {}
    for kk, vv in pairs(nope) do parts[#parts + 1] = kk .. " x" .. vv end
    table.sort(parts)
    elro.tr(string.format("vert: make room for %s -- %d piston(s) tried, none worked [%s]",
      tostring(v), nTry, table.concat(parts, ", ")))
  end
  return nil, nTry
end

-- Assembly: components arrive in local coordinates; decide where each sits and return
-- groups for the shelf pack. A declined link leaves its component where it was.
function elro.vert_assemble(comps, lcs, adj, compOf)
  local rooms = {}
  for _, c in ipairs(comps) do for _, r in ipairs(c) do rooms[#rooms + 1] = r end end
  table.sort(rooms)
  local links = elro.vert_classify(rooms, compOf, compOf)

  local nc = #comps
  local fnb = {}
  for i = 1, nc do fnb[i] = {} end
  local nforest = 0
  for _, p in ipairs(links) do
    if p.cls == "forest" then
      nforest = nforest + 1
      fnb[p.ca][#fnb[p.ca] + 1] = { c = p.cb, p = p }
      fnb[p.cb][#fnb[p.cb] + 1] = { c = p.ca, p = p }
    end
  end
  -- No forest link: `nil` tells compose_spqr_adj to shelf-pack bare components. The
  -- bridge piston still runs over trivial one-component groups (redundant stairs), which
  -- are arithmetically the same groups the fallback would build.
  if nforest == 0 then
    if elro.vertPiston == false then return nil, links end
    local g, nT, nA = {}, 0, 0
    for ci = 1, nc do g[ci] = { coord = lcs[ci] } end
    for gi, G in ipairs(g) do
      local a1, a2 = vert_piston(G, adj, links, {}, vert_cap(), gi)
      nT, nA = nT + a1, nA + a2
    end
    if nA == 0 then return nil, links end
    elro.tr(string.format("vert: piston pass (no forest link) -- %d tried, %d applied",
      nT, nA))
    -- `_vertStats` is a single global; stamp it on every path that returns groups
    elro._vertStats = { links = #links, forest = 0, honoured = 0, declined = 0,
                        carried = 0, comps = nc, groups = #g,
                        pistTry = nT, pistApp = nA }
    return g, links
  end
  for i = 1, nc do
    table.sort(fnb[i], function(x, y)
      if x.c ~= y.c then return x.c < y.c end
      if x.p.a ~= y.p.a then return x.p.a < y.p.a end
      return x.p.b < y.p.b
    end)
  end

  -- root each tree at its largest component; ties to the lowest index (total order)
  local treeOf, roots = {}, {}
  for i = 1, nc do
    if not treeOf[i] then
      local t = #roots + 1
      local q, h, best = { i }, 1, i
      treeOf[i] = t
      while h <= #q do
        local u = q[h] ; h = h + 1
        if #comps[u] > #comps[best] then best = u end
        for _, e in ipairs(fnb[u]) do
          if not treeOf[e.c] then treeOf[e.c] = t ; q[#q + 1] = e.c end
        end
      end
      roots[t] = best
    end
  end
  -- BFS emission order; a tree appears at the position of its first member
  local order, emitted, parentOf = {}, {}, {}
  for i = 1, nc do
    if not emitted[i] then
      local root = roots[treeOf[i]]
      local q, h = { root }, 1
      emitted[root] = true
      while h <= #q do
        local u = q[h] ; h = h + 1 ; order[#order + 1] = u
        for _, e in ipairs(fnb[u]) do
          if not emitted[e.c] then
            emitted[e.c] = true ; parentOf[e.c] = { c = u, p = e.p } ; q[#q + 1] = e.c
          end
        end
      end
    end
  end

  local cap = vert_cap()
  local feet, groups, placedIn = {}, {}, {}
  local hon, dec = {}, {}
  -- Shaft carry: `dockRay/dockScale[ci]` is what this component was docked with; its
  -- children prefer the same ray. Carried across the tree edge deliberately, so two
  -- stairs leaving one floor draw parallel.
  local dockRay, dockScale, nCarry = {}, {}, 0
  local nRoomTry, nRoomApp = 0, 0
  for _, ci in ipairs(order) do
    local lc = lcs[ci]
    feet[ci] = vert_foot(comps[ci], lc, adj)
    local par, docked = parentOf[ci], false
    if par and placedIn[par.c] then
      local G, p = groups[placedIn[par.c]], par.p
      -- v is this component's end of the link, u the already-placed one
      local v, u
      if p.ca == ci then v, u = p.a, p.b else v, u = p.b, p.a end
      if G.coord[u] and lc[v] then
        local sgn = (vert_high(p) == v) and 1 or -1
        local best = vert_ray(G, G.coord[u], lc, comps[ci], feet[ci], v, sgn, cap,
                              dockRay[par.c], dockScale[par.c])
        -- no room: make room, on the decline path only
        if not best and elro.vertMakeRoom then
          local nt
          best, nt = vert_makeroom(G, adj, links, hon, lc, comps[ci], feet[ci],
                                   u, v, sgn, cap, dockRay[par.c], dockScale[par.c])
          nRoomTry = nRoomTry + (nt or 0)
          if best then nRoomApp = nRoomApp + 1 end
        end
        if best then
          vert_merge(G, comps[ci], lc, feet[ci], best.dx, best.dy)
          -- reserve the link's own run as edge cells, so a later sibling cannot dock onto it
          local o = VERT_OFF[best.oi]
          for j = 1, best.k - 1 do
            G.ecell[(G.coord[u][1] + sgn * o[1] * j) .. ":"
                    .. (G.coord[u][2] + sgn * o[2] * j)] = true
          end
          placedIn[ci] = placedIn[par.c] ; docked = true
          dockRay[ci], dockScale[ci] = best.oi, best.k
          -- charge the ray only if this dock chose it (fan-out term)
          if not best.carry then G.rayUse[best.oi] = (G.rayUse[best.oi] or 0) + 1 end
          p.honoured = true ; p.scale = best.k
          if best.carry then nCarry = nCarry + 1 end
          hon[#hon + 1] = p
          -- mapstep frame in group-local coordinates
          elro.step_snap(G.coord, string.format(
            "vert: comp %d DOCKED by %d %s %d -- ray (%d,%d) x%d%s", ci,
            p.from, p.dir, (p.a == p.from) and p.b or p.a,
            sgn * VERT_OFF[best.oi][1], sgn * VERT_OFF[best.oi][2], best.k,
            best.carry and (" [" .. best.carry .. "]") or ""), v)
          elro.tr(string.format("vert: HONOURED %d %s %d -- comp %d docked on ray %d at scale %d%s%s",
            p.from, p.dir, (p.a == p.from) and p.b or p.a, ci, best.oi, best.k,
            best.carry and (" [" .. best.carry .. "]") or "",
            p.corrob and "" or " (uncorroborated)"))
        end
      end
    end
    if not docked then
      -- Decline: the component starts its own group; its children may still dock onto it.
      if par then
        dec[#dec + 1] = par.p
        local why, ndead = "?", 0
        local G0 = groups[placedIn[par.c]]
        if G0 then
          local v0 = (par.p.ca == ci) and par.p.a or par.p.b
          local u0 = (par.p.ca == ci) and par.p.b or par.p.a
          if G0.coord[u0] and lc[v0] then
            why, ndead = vert_diag(G0, G0.coord[u0], feet[ci],
              (vert_high(par.p) == v0) and 1 or -1, lc[v0][1], lc[v0][2])
          end
        end
        local G = groups[placedIn[par.c]]
        if G then
          elro.step_snap(G.coord, string.format(
            "vert: comp %d DECLINED -- %d %s %d found no room within scale %d", ci,
            par.p.from, par.p.dir, (par.p.a == par.p.from) and par.p.b or par.p.a, cap),
            (par.p.ca == ci) and par.p.b or par.p.a)
        end
        elro.tr(string.format("vert: DECLINED %d %s %d -- no room within scale %d.  %s%s",
          par.p.from, par.p.dir, (par.p.a == par.p.from) and par.p.b or par.p.a, cap, why,
          (ndead == #VERT_OFF)
            and "  ==> every ray is run-blocked by a room; a bigger vertScale cannot help,"
                .. " only vertOverRoom can"
            or ""))
      end
      groups[#groups + 1] = vert_group(comps[ci], lc, feet[ci])
      placedIn[ci] = #groups
    end
  end

  -- Bridge piston after every dock. It rewrites `G.coord` only; `G.cell/ecell/seg` are
  -- dead by now, so any dock added after this point must rebuild them first.
  if nRoomTry > 0 then
    elro.tr(string.format("vert: make-room pass -- %d piston(s) tried, %d dock(s) rescued",
      nRoomTry, nRoomApp))
  end
  local nPistTry, nPistApp = 0, 0
  -- `~= false`: the knob defaults on
  if elro.vertPiston ~= false then
    for gi, G in ipairs(groups) do
      local a1, a2 = vert_piston(G, adj, links, hon, cap, gi)
      nPistTry, nPistApp = nPistTry + a1, nPistApp + a2
    end
    if nPistTry > 0 then
      elro.tr(string.format("vert: piston pass -- %d candidate(s) tried, %d applied",
        nPistTry, nPistApp))
    end
  end

  elro._vertStats = { links = #links, forest = nforest,
                      honoured = #hon, declined = #dec, carried = nCarry,
                      comps = nc, groups = #groups,
                      pistTry = nPistTry, pistApp = nPistApp,
                      roomTry = nRoomTry, roomApp = nRoomApp }
  local nc2 = { redundant = 0, cycle = 0, cross = 0 }
  for _, p in ipairs(links) do
    if nc2[p.cls] then nc2[p.cls] = nc2[p.cls] + 1 end
  end
  elro.tr(string.format("vert: %d link(s) = %d forest + %d cycle + %d redundant + %d cross"
    .. " -- %d honoured (%d continuing a shaft's ray), %d declined;"
    .. " %d component(s) packed as %d group(s)",
    #links, nforest, nc2.cycle, nc2.redundant, nc2.cross,
    #hon, nCarry, #dec, nc, #groups))
  return groups, links
end

-- ---- VERTICAL EXIT CENSUS (mapvert) ---------------------------------------
-- up/down exits exist in the graph but every layout consumer filters them with the
-- planar test `de[1] ~= 0 or de[2] ~= 0`. Component placement is pure translation
-- (two free parameters), so ONE vertical link into a component is always exactly
-- satisfiable and a SECOND is over-determined. Hence: build the graph whose nodes
-- are compass components and whose edges are vertical links, and take a spanning
-- forest; forest edges are honourable by a vertical-aware packer, everything else
-- is draw-only. (Strictly stronger than "only link between the two floors" -- that
-- waves through a ring of staircases.)
-- Buckets: redundant (both ends in one compass component), forest (first link
-- joining two components), cycle (joins already-linked components, draw-only),
-- cross (far end on another canvas).
-- Mutates nothing: no setExit, no coordinates, no custom lines.
function elro.vert_census(areaID)
  local rooms, adj = area_adjacency(areaID)
  table.sort(rooms, function(a, b) return a < b end)
  local inArea = {}
  for _, r in ipairs(rooms) do inArea[r] = true end

  -- COMPASS COMPONENTS, undirected. A one-way exit still joins its two rooms:
  -- the question is "did the layout have to place these two apart", not trust,
  -- and adj carries darts only in the observed direction.
  local nb = {}
  for _, r in ipairs(rooms) do nb[r] = {} end
  for _, r in ipairs(rooms) do
    for _, d in ipairs(elro.dir_order) do
      local v = adj[r][d]
      if v and nb[v] then
        nb[r][#nb[r] + 1] = v
        nb[v][#nb[v] + 1] = r
      end
    end
  end
  local comp, ncomp = {}, 0
  for _, s in ipairs(rooms) do
    if not comp[s] then
      ncomp = ncomp + 1 ; comp[s] = ncomp
      local q, h = { s }, 1
      while h <= #q do
        local u = q[h] ; h = h + 1
        for _, v in ipairs(nb[u]) do
          if not comp[v] then comp[v] = ncomp ; q[#q + 1] = v end
        end
      end
    end
  end

  -- Classification is elro.vert_classify -- the same code the pack runs, deliberately,
  -- so report and packer can never disagree.
  local links, n = elro.vert_classify(rooms, comp, inArea)

  -- Drawability against the CURRENT picture. For a `forest` link this measures a
  -- layout that does not yet know the link, so a blocked row is the gap a
  -- vertical-aware packer would close; for `redundant`/`cycle` it is the real
  -- answer. blocked_by (enters an occupied cell) is the right test here;
  -- room_on_segment is the stricter, accusatory one.
  if type(getRoomCoordinates) == "function" then
    local coord = {}
    for _, r in ipairs(rooms) do
      local x, y = getRoomCoordinates(r)
      if x then coord[r] = { x, y } end
    end
    local occ = elro.cell_census(coord)
    for _, p in ipairs(links) do
      if p.cls ~= "cross" and coord[p.a] and coord[p.b] then
        local ax, ay = coord[p.a][1], coord[p.a][2]
        local bx, by = coord[p.b][1], coord[p.b][2]
        p.dist  = math.max(math.abs(bx - ax), math.abs(by - ay))
        p.block = elro.blocked_by(occ, ax, ay, bx, by, p.a, p.b)
      end
    end
  end

  return { aid = areaID, rooms = rooms, comp = comp, ncomp = ncomp,
           links = links, n = n }
end

local VERT_COL = { forest = "green", cycle = "yellow", redundant = "cyan", cross = "grey" }
local VERT_ORD = { forest = 1, cycle = 2, redundant = 3, cross = 4 }

-- mapvert [area] -- one area in full detail
function elro.vert_report(spec)
  spec = tostring(spec or ""):gsub("^%s+", ""):gsub("%s+$", "")
  -- `mapvert on|off` sets the preference; anything else is an area filter. An area
  -- literally named "on"/"off" would be unreachable, but `mapvert` takes a substring.
  local w = spec:lower()
  if w == "on" or w == "off" then return elro.set_vertpack(w == "on") end
  if spec:lower() == "all" then return elro.vert_report_all() end
  local aid
  if spec ~= "" then
    local a, _, amb = elro.find_area(spec)
    if amb then
      cecho("\n<yellow>[elro]: '" .. spec .. "' is ambiguous: " .. table.concat(amb, ", ") .. "\n<reset>")
      return
    end
    if not a then
      cecho("\n<red>[elro]: no area matching '" .. spec .. "'.\n<reset>") return
    end
    aid = a
  else
    if not elro.current then
      cecho("\n<red>[elro]: no current room -- 'mapcur <id|area>' first, or 'mapvert all'.\n<reset>")
      return
    end
    aid = getRoomArea(elro.current)
  end

  local c = elro.vert_census(aid)
  local nm = elro.areaName(aid) or "?"
  cecho(string.format("\n<cyan>[vert] %s (aid %s): %d vertical edge(s) -- %d redundant,"
    .. " %d forest, %d cycle, %d cross-area<reset>",
    nm, tostring(aid), #c.links, c.n.redundant, c.n.forest, c.n.cycle, c.n.cross))
  cecho(string.format("\n<grey>       %d compass component(s), %d after the vertical forest%s<reset>",
    c.ncomp, c.ncomp - c.n.forest,
    (c.n.cycle > 0) and ("  --  " .. c.n.cycle .. " over-determined, draw-only") or ""))
  -- What the pack actually did, last relayout. Whole-relayout global (like
  -- elro._demoted): after laying out a different area these are its numbers, not ours.
  local S = elro._vertStats
  if S and S.aid == aid then
    cecho(string.format("\n<grey>       last pack: %d honoured (%d continuing a shaft's ray),"
      .. " %d declined, %d comp(s) -> %d group(s)"
      .. "  |  drawn %d straight (%d landed right without being placed),"
      .. " %d bent, %d left to Mudlet's marker<reset>",
      S.honoured or 0, S.carried or 0, S.declined or 0, S.comps or 0, S.groups or 0,
      S.straight or 0, S.realised or 0, S.bend or 0, S.quiet or 0))
    -- Piston line: a tried/applied pair, not a success count -- this tier costs
    -- vertPack its monotonicity, so wanted-vs-allowed is the number to read.
    if elro.vertPiston ~= false or elro.vertMakeRoom then
      cecho(string.format("\n<grey>       piston: %d near-miss candidate(s) tried, %d applied"
        .. "  |  make room: %d tried, %d dock(s) rescued"
        .. "  (`mapdebug on` + relayout names every one and why it was reverted)<reset>",
        S.pistTry or 0, S.pistApp or 0, S.roomTry or 0, S.roomApp or 0))
    end
  elseif elro.vertPack == false then
    cecho("\n<grey>       (vertPack is OFF -- `lua elro.vertPack = nil` + relayout to honour"
      .. " the forest links)<reset>")
  end
  if #c.links == 0 then cecho("\n") return end

  table.sort(c.links, function(x, y)
    if VERT_ORD[x.cls] ~= VERT_ORD[y.cls] then return VERT_ORD[x.cls] < VERT_ORD[y.cls] end
    if x.a ~= y.a then return x.a < y.a end
    return x.b < y.b
  end)
  for _, p in ipairs(c.links) do
    local from = p.from
    local to   = (p.a == from) and p.b or p.a
    local geo
    if p.cls == "cross" then
      geo = "-> " .. tostring(elro.areaName(getRoomArea(to)) or "?")
    else
      geo = "comp " .. tostring(p.ca) .. ((p.ca ~= p.cb) and ("->" .. tostring(p.cb)) or "")
      if p.dist then
        geo = geo .. string.format("  dist %d  %s", p.dist,
                p.block and ("BLOCKED by " .. tostring(p.block)) or "clear")
      end
    end
    cecho(string.format("\n<%s>  %-10s %6s %-4s -> %-6s  %s%s<reset>",
      VERT_COL[p.cls] or "white", p.cls, tostring(from), p.dir, tostring(to), geo,
      p.corrob and "" or (p.recip and "   (assumed reverse)" or "   (one-way)")))
  end
  cecho("\n")
end

-- mapvert all -- the world population
function elro.vert_report_all()
  local swap = elro.cs_areas_swap() or {}
  local aids = {}
  for aid in pairs(swap) do aids[#aids + 1] = aid end
  table.sort(aids)

  local rows = {}
  local T = { v = 0, redundant = 0, forest = 0, cycle = 0, cross = 0, c0 = 0, c1 = 0 }
  -- A cross-area link is visible from both areas: per-area rows report what each
  -- sees; the TOTAL dedups on the pair key or every one is double-counted.
  local seenX, quiet = {}, 0
  for _, aid in ipairs(aids) do
    local c = elro.vert_census(aid)
    T.v         = T.v + #c.links
    T.redundant = T.redundant + c.n.redundant
    T.forest    = T.forest + c.n.forest
    T.cycle     = T.cycle + c.n.cycle
    T.c0        = T.c0 + c.ncomp
    T.c1        = T.c1 + c.ncomp - c.n.forest
    for _, p in ipairs(c.links) do
      if p.cls == "cross" and not seenX[p.key] then seenX[p.key] = true ; T.cross = T.cross + 1 end
    end
    if #c.links > 0 then
      rows[#rows + 1] = { nm = swap[aid] or ("aid " .. tostring(aid)), n = c.n,
                          v = #c.links, c0 = c.ncomp, c1 = c.ncomp - c.n.forest }
    else
      quiet = quiet + 1
    end
  end
  table.sort(rows, function(x, y)
    if x.v ~= y.v then return x.v > y.v end        -- busiest first
    return x.nm < y.nm
  end)

  cecho(string.format("\n<cyan>[vert] %d area(s): %d vertical edge(s) -- %d redundant,"
    .. " %d forest, %d cycle, %d cross-area<reset>",
    #aids, T.v, T.redundant, T.forest, T.cycle, T.cross))
  cecho(string.format("\n<grey>       compass components %d -> %d if every forest link were honoured"
    .. "  (%d area(s) with no vertical exit omitted)<reset>", T.c0, T.c1, quiet))
  cecho("\n<grey>  area                      vert  redun  forest  cycle  cross   comps<reset>")
  for _, r in ipairs(rows) do
    cecho(string.format("\n  %-24s %5d %6d %7d %6d %6d   %d->%d",
      r.nm:sub(1, 24), r.v, r.n.redundant, r.n.forest, r.n.cycle, r.n.cross, r.c0, r.c1))
  end
  cecho("\n")
end

-- Vertical exits, drawn from elro._vertLinks (verticals never enter `adj`). Three rungs:
--  1. honoured: the packer docked the floor at a canonical 2:1 / 1:2 offset, so a straight
--     line is provably not a compass angle.
--  2. declined but clear run: draw_demoted's single-bend shape, a canonical-angle stub then
--     straight to the far centre.
--  3. blocked run: draw nothing and leave the direction's custom-line slot unclaimed so
--     Mudlet's own up/down marker stands.
-- Dashed, never solid. Coordinates are passed in because `mapstep` re-lays each frame near
-- the origin; a helper reading the live map would be wrong there.
local function vert_polyline(p, ax, ay, bx, by, occ, a, b)
  if p.honoured then
    return { { ax, ay, 0 }, { bx, by, 0 } }, "dash line", "honoured"
  end
  if vert_realised(p, ax, ay, bx, by, occ, a, b) then
    -- the packer never placed this one, but the map came out satisfying its test anyway
    return { { ax, ay, 0 }, { bx, by, 0 } }, "dash line", "realised"
  end
  if elro.blocked_by(occ, ax, ay, bx, by, a, b) then return nil end
  -- the stub always leaves along the exit's own vertical sign, even when the far floor
  -- sits the other way; the resulting V is the honest picture
  local dx, dy = bx - ax, by - ay
  local rx, ry = 2, 1
  if math.abs(dy) > math.abs(dx) then rx, ry = 1, 2 end   -- the gentler bend
  local sx = (dx >= 0) and 1 or -1
  local sy = (p.dir == "up") and 1 or -1                  -- never flipped
  local vx, vy = sx * rx, sy * ry
  local len = math.sqrt(vx * vx + vy * vy)
  local st = TUNE.vertStub
  return { { ax, ay, 0 }, { ax + vx / len * st, ay + vy / len * st, 0 }, { bx, by, 0 } },
         "dot line", "bend"
end

-- Draw every vertical link of `coord` whose two ends are both present. `sink`, when
-- given, is called as sink(room, shortDir) for each line drawn -- `mapstep` uses it to
-- register the line for teardown; the map renderer leaves its lines for the next
-- clear_lines_area like every other overlay. Returns straight / bent / silent counts.
function elro.draw_vertical(coord, sink)
  local V = elro._vertLinks
  -- four return values here must match the real return: the caller string.formats all of them
  if not V or type(addCustomLine) ~= "function"
     or type(getRoomCoordinates) ~= "function" then return 0, 0, 0, 0 end
  local col = (elro.classColours and elro.classColours.vertical) or { 0, 210, 190 }
  local occ = elro.cell_census(coord)
  local nStraight, nBend, nQuiet, nReal = 0, 0, 0, 0
  for _, p in ipairs(V) do
    local a = p.from
    local b = (p.a == a) and p.b or p.a
    -- _vertLinks is a single global: skip links from another canvas or (under mapstep) a
    -- floor not yet docked in this frame
    if coord[a] and coord[b] and roomExists(a) and roomExists(b) then
      local ax, ay = getRoomCoordinates(a)
      local bx, by = getRoomCoordinates(b)
      if ax and bx and (ax ~= bx or ay ~= by) then
        local pts, style, kind = vert_polyline(p, ax, ay, bx, by, occ, a, b)
        if pts then
          local d = elro.shortDir(p.dir)
          pcall(addCustomLine, a, pts, d, style, col, false)
          if sink then sink(a, d) end
          if kind == "bend" then nBend = nBend + 1
          else
            nStraight = nStraight + 1
            if kind == "realised" then nReal = nReal + 1 end
          end
        else
          nQuiet = nQuiet + 1
        end
      end
    end
  end
  return nStraight, nBend, nQuiet, nReal
end

-- the map renderer's wrapper: draw, then record the counts for `mapvert`. Only this path
-- records; mapstep's replay must not overwrite them.
function elro.draw_vertical_map(coord)
  local nStraight, nBend, nQuiet, nReal = elro.draw_vertical(coord)
  local S = elro._vertStats or {}
  S.straight, S.bend, S.quiet, S.realised = nStraight, nBend, nQuiet, nReal
  elro._vertStats = S
  elro.tr(string.format("vert: drew %d straight (%d of them a link the packer never"
    .. " placed), %d bent (clear run), %d left to Mudlet's marker (blocked run)",
    nStraight, nReal, nBend, nQuiet))
end
