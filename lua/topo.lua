-- Topology: blocks, faces, outer face, face fit, and the wire/topo crossing provers.
-- Split out of layout.lua; see lua/modules.lua for the load order.

elro = elro or {}
local G = elro.g or error("topo.lua: lua/geom.lua must be loaded first (see elro.modules)")
local ori = G.ori
local orip = G.orip
local within = G.within
local K = elro.k or error("topo.lua: lua/keys.lua must be loaded first (see elro.modules)")
local ekey = K.edge
local crosspair = K.pair
local eid = K.eid
local each_exit = elro.exits or error("topo.lua: lua/core.lua must be loaded first")
local TUNE = elro.TUNE or error("topo.lua: lua/tune.lua must be loaded first")

-- ============================ RANK ENGINE (v2) =========================
-- Geometry-seeded coordinate assignment: spanning-tree delta-sum as a per-axis
-- floor, then a bounded Bellman-Ford push that inserts slack only where a loop
-- closure demands it. Equality classes (pure N/S share a column, pure E/W a row)
-- are merged so corridors stay straight. Inconsistent geometry is a positive
-- constraint cycle: the push is capped at |classes| iterations, leaving the
-- irreducible mismatch as one over-stretched edge. Collision bump as safety net.
-- Biconnected decomposition takes an explicit (rooms, adj) so callers can run
-- it on a selection/subgraph.
-- Source stamp -- `lua display(elro._srcStamp)`; bump on every edit so "change
-- did nothing" and "change not loaded" are distinguishable.
elro._srcStamp = "vert-piston+makeroom"

function elro.blocks_adj(rooms, adj)
  local nbr, nseen, inset = {}, {}, {}
  for _, r in ipairs(rooms) do nbr[r] = {} ; inset[r] = true end
  for _, u in ipairs(rooms) do
    elro.bg_tick("blocks")
    -- only edges WITHIN `rooms`: a neighbour outside the set has no nbr[] entry,
    -- and callers passing a subset rely on this guard.
    for _, v in each_exit(adj[u]) do
      if inset[v] then
        local k = eid(u, v)
        if not nseen[k] then
          nseen[k] = true
          nbr[u][#nbr[u] + 1] = v
          nbr[v][#nbr[v] + 1] = u
        end
      end
    end
  end
  for _, r in ipairs(rooms) do table.sort(nbr[r], function(a, b) return a < b end) end

  local disc, low, tnum = {}, {}, 0
  local estack, blocks, art = {}, {}, {}

  local function dfs(u, parent)
    tnum = tnum + 1 ; disc[u] = tnum ; low[u] = tnum
    local children = 0
    for _, v in ipairs(nbr[u]) do
      if not disc[v] then
        children = children + 1
        estack[#estack + 1] = { u, v }
        dfs(v, u)
        if low[v] < low[u] then low[u] = low[v] end
        if low[v] >= disc[u] then
          if parent ~= nil then art[u] = true end
          local comp = {}
          while #estack > 0 do
            local e = estack[#estack] ; estack[#estack] = nil
            comp[#comp + 1] = e
            if e[1] == u and e[2] == v then break end
          end
          blocks[#blocks + 1] = comp
        end
      elseif v ~= parent and disc[v] < disc[u] then
        estack[#estack + 1] = { u, v }            -- back edge
        if disc[v] < low[u] then low[u] = disc[v] end
      end
    end
    if parent == nil and children > 1 then art[u] = true end
  end

  local order = {}
  for _, r in ipairs(rooms) do order[#order + 1] = r end
  table.sort(order, function(a, b) return a < b end)
  for _, r in ipairs(order) do if not disc[r] then dfs(r, nil) end end
  return blocks, art, nbr, rooms
end

-- signed-ish polygon area of a face (abs), from compass-delta positions
local function face_area(face, adj)
  local cx, cy, pts = 0, 0, { { 0, 0 } }
  for i = 1, #face - 1 do
    local a, b, del = face[i], face[i + 1], nil
    for d, v in each_exit(adj[a]) do if v == b then del = elro.delta[d] ; break end end
    if del then cx = cx + del[1] ; cy = cy + del[2] end
    pts[#pts + 1] = { cx, cy }
  end
  local A = 0
  for i = 1, #pts do
    local p, q = pts[i], pts[(i % #pts) + 1]
    A = A + (p[1] * q[2] - q[1] * p[2])
  end
  return math.abs(A) / 2
end

-- SIGNED TOTAL TURNING of a traced face, in degrees. The compass exits ARE the rotation
-- system, so elro.faces walks every interior face one way round and the OUTER boundary the
-- other: interior faces total +360, the outer face -360. Purely combinatorial -- no
-- coordinates, no solve. Returns nil when the face contains a 180-degree reversal (a
-- dead-end spur, or an edge whose direction we cannot read), where the sign is meaningless.
local function face_turning(face, adj)
  local n = #face
  if n < 3 then return nil end
  local ang = {}
  for i = 1, n do
    local a, b, de = face[i], face[(i % n) + 1], nil
    for d, v in each_exit(adj[a]) do
      local dd = elro.delta[d]
      if v == b and dd and (dd[1] ~= 0 or dd[2] ~= 0) then de = dd ; break end
    end
    if not de then return nil end
    ang[i] = math.deg(math.atan2(de[2], de[1]))
  end
  local T = 0
  for i = 1, n do
    local t = (ang[(i % n) + 1] - ang[i]) % 360
    if t > 180 then t = t - 360 end
    if math.abs(math.abs(t) - 180) < 1e-6 then return nil end   -- reversal: not orientable
    T = T + t
  end
  return T
end

-- compass-edge density (undirected edges per room) of a node set. A ring or tree runs ~1x, a
-- normal block 1.2-1.5x, an 8-directional super-grid 3-4x -- the same signal solve_block_ns
-- uses to decide NS will degenerate. Returns ratio, nv, ne.
function elro.block_density(adj, nodeset)
  local nv, ne = 0, 0
  for r in pairs(nodeset) do
    nv = nv + 1
    for d, v in each_exit(adj[r]) do
      local de = elro.delta[d]
      if nodeset[v] and de and (de[1] ~= 0 or de[2] ~= 0) then ne = ne + 1 end
    end
  end
  ne = math.floor(ne / 2)
  return ne / math.max(nv, 1), nv, ne
end

-- Pick the OUTER face out of a traced face list. Rotation first: the one simple face
-- turning the other way IS the boundary; largest-area survives only as the fallback
-- when the turning test cannot judge. Requiring exactly ONE such face keeps this safe
-- on graphs that are not fully planar. Returns the face and its index, or nil.
--
-- Per-edge minimum length: `elro.minLen` is keyed by the unordered pair "lo:hi"; an
-- edge with no entry is 1, so an empty or absent table is a no-op. Consumers: the two
-- drag rules and the unit step in place_room. Deliberately module-level, not a
-- closure: the pre-pass fills it before any placement.
function elro.min_len(u, v)
  local m = elro.minLen
  if not m then return 1 end
  local k = ekey(u, v)
  return m[k] or 1
end

-- Is this edge seated? (dx, dy) is the delta from u to v along compass delta de.
-- LENGTH: at least min_len(u, v) the right way along each nonzero component.
-- SHAPE, only for a sized diagonal: a minimum is a per-axis floor, so (6,5) can
-- satisfy a minimum of 5 while destroying the 45; a sized diagonal of length m
-- means (+-m, +-m). Gated on m > 1 so unsized diagonals keep the plain
-- "both components run the right way" rule.
function elro.edge_ok(u, v, dx, dy, de)
  local m = elro.min_len(u, v)
  if de[1] ~= 0 and de[2] ~= 0 then
    if not (dx * de[1] >= m and dy * de[2] >= m) then return false end
    -- the only hard 45-degree rule in the engine, switched on by min_len > 1:
    -- the edge then becomes a rigid |dx| == |dy| equality coupling the two axes.
    if m > 1 and (dx > 0 and dx or -dx) ~= (dy > 0 and dy or -dy) then return false end
    return true
  elseif de[1] ~= 0 then return dy == 0 and dx * de[1] >= m
  else return dx == 0 and dy * de[2] >= m end
end

-- Is there a straight compass segment here at all (the reference truthfulness test):
-- axial means the perpendicular component is zero and the parallel one runs the right
-- way; diagonal means both run the right way. Anything else is a lie -- drawn bent or
-- demoted, never a straight segment. NOT elro.edge_ok, which is a different question:
-- edge_ok asks "is this edge SEATED" (honours min_len and the sized-diagonal shape
-- rule); this asks "does this edge EXIST as drawn". Keep the two predicates apart.
-- Takes the delta rather than the rooms so it allocates nothing.
function elro.edge_truthful(de, dx, dy)
  if de[1] ~= 0 and de[2] ~= 0 then return dx * de[1] >= 1 and dy * de[2] >= 1
  elseif de[1] ~= 0 then return dy == 0 and dx * de[1] >= 1
  else return dx == 0 and dy * de[2] >= 1 end
end

-- Audit. OPEN: not every writer honours min_len yet (place_room's constrained
-- placement derives coordinates from row/column locks and never consults it), so a
-- violated minimum must be loud rather than silent. Free when elro.minLen is unset.
-- Returns the number of violations and (with elro.tr) names them.
function elro.min_len_audit(coord, adj, placed)
  if not elro.minLen then return 0 end
  local bad, seen = 0, {}
  for r in pairs(placed) do
    for d, x in each_exit(adj[r]) do
      local de = elro.delta[d]
      if placed[x] and coord[r] and coord[x] and de and (de[1] ~= 0 or de[2] ~= 0) then
        local k = ekey(r, x)
        if not seen[k] then
          seen[k] = true
          local m = elro.minLen[k]
          if m then
            local gx, gy = coord[x][1] - coord[r][1], coord[x][2] - coord[r][2]
            local L = math.max(math.abs(gx), math.abs(gy))
            if L < m then
              bad = bad + 1
              elro.tr(string.format("  min_len VIOLATED %s: length %d < %d", k, L, m))
            end
          end
        end
      end
    end
  end
  if bad > 0 then
    cecho(string.format("\n<red>[minlen] %d edge(s) BELOW their asserted minimum<reset>", bad))
  end
  elro._minLenBad = bad
  return bad
end

function elro.pick_outer_face(faces, adj, usePick)
  -- `usePick` (core_classify only -- never the per-block skeleton): a room the user marked as
  -- ON THE OUTER FACE (`mapouter`, `elro.outerPick`) decides first: the face holding the most
  -- picked rooms; then one turning negative; then the most half-edges (the real boundary of a
  -- merged set revisits rooms, so its turn is nil and its area meaningless -- its length is not).
  if usePick then elro._outerPicked = nil end
  local pick = usePick and elro.outerPick
  if pick and next(pick) then
    local best, bi, bestK, bestNeg
    for i, f in ipairs(faces) do
      if #f >= 3 then
        local k, seenP = 0, {}
        for _, r in ipairs(f) do if pick[r] and not seenP[r] then seenP[r] = true ; k = k + 1 end end
        if k > 0 then
          local seen, sim = {}, true
          for _, r in ipairs(f) do if seen[r] then sim = false ; break end ; seen[r] = true end
          local T = sim and face_turning(f, adj) or nil
          local isNeg = (T ~= nil and T < 0)
          elro.tr(string.format("  outer-pick: face %d holds %d picked room(s), %d half-edge(s), turn %s: %s%s",
            i, k, #f, sim and tostring(T) or "nil (revisits a room)",
            table.concat(f, " ", 1, math.min(#f, 40)), (#f > 40) and " ..." or ""))
          if not best or k > bestK or (k == bestK and isNeg and not bestNeg)
             or (k == bestK and isNeg == bestNeg and #f > #best) then
            best, bi, bestK, bestNeg = f, i, k, isNeg
          end
        end
      end
    end
    if best then elro._outerPicked = bi ; return best, bi end
  end
  local neg, nneg = nil, 0
  for i, f in ipairs(faces) do
    elro.bg_tick("outer-face")
    if #f >= 3 then
      local seen, sim = {}, true
      for _, r in ipairs(f) do if seen[r] then sim = false ; break end ; seen[r] = true end
      local T = sim and face_turning(f, adj) or nil
      if T and T < 0 then neg, nneg = i, nneg + 1 end
    end
  end
  if nneg == 1 then return faces[neg], neg end
  local best, bestA, bi
  for i, f in ipairs(faces) do
    if #f >= 3 then
      local a = face_area(f, adj)
      if not best or a > bestA then best, bestA, bi = f, a, i end
    end
  end
  return best, bi
end
-- `elro.ns_cap` survives: the room count above which an area falls back to the
-- flood, still a live path (see elro.layout_one).


-- Step 2.5: planar FACE detection. The compass directions give us a rotation
-- system for free (order each room's exits by angle), so we can trace faces
-- without computing a planar embedding. Returns a list of faces (each a room
-- sequence). The outer boundary is the face of largest area -- that's the "box"
-- the castle walls should form, with all other faces nested inside it.
local FANG = { east = 0, northeast = 45, north = 90, northwest = 135,
               west = 180, southwest = 225, south = 270, southeast = 315 }

function elro.faces(nodeset, adj)
  local nb = {}
  for u in pairs(nodeset) do
    -- safe to yield from: the provers that call this under pcall declare a
    -- no-yield window (see elro.bg_tick).
    elro.bg_tick("faces")
    local lst = {}
    for d, v in each_exit(adj[u]) do
      if nodeset[v] and FANG[d] then
        -- A one-way exit (v has no exit back to u) is left out of the rotation, as in
        -- topo_cross: it contributes no cycle, and tracing it bails the face at v (a merge seam
        -- glued gurk's annulus and mael's core into one block whose faces were not simple).
        local keep = false
        for _, w in each_exit(adj[v]) do if w == u then keep = true ; break end end
        if keep then lst[#lst + 1] = { v = v, ang = FANG[d] } end
      end
    end
    table.sort(lst, function(a, b)
      if a.ang ~= b.ang then return a.ang < b.ang end
      return a.v < b.v
    end)
    nb[u] = lst
  end
  local function idx(u, v)
    for i, e in ipairs(nb[u]) do if e.v == v then return i end end
  end
  local visited, faces = {}, {}
  for u in pairs(nodeset) do
    elro.bg_tick("faces-trace")
    for _, e0 in ipairs(nb[u]) do
      if not visited[u .. ":" .. e0.v] then
        local face = {}
        local ca, cb = u, e0.v
        while not visited[ca .. ":" .. cb] do
          visited[ca .. ":" .. cb] = true
          face[#face + 1] = ca
          local i = idx(cb, ca)               -- reverse half-edge at cb
          local deg = #nb[cb]
          if not i or deg == 0 then                -- asymmetric exit: bail this face
            elro.tr(string.format("  faces: bail at %d->%d (no reverse half-edge at %d, degree %d) after %d room(s)",
              ca, cb, cb, deg, #face))
            break
          end
          local ni = (i - 2) % deg + 1         -- clockwise predecessor (1-based)
          ca, cb = cb, nb[cb][ni].v
        end
        faces[#faces + 1] = face
      end
    end
  end
  return faces
end


-- ===================================================================================
-- FACE FIT -- how big does a face have to be, before anything is placed?
-- Pure topology: the compass angles give a rotation system, faces are the angular sectors
-- between consecutive core edges, and a pendant's first edge falls in exactly one sector.
-- In order: closure (sum(len_i * dir_i) = 0, len >= 1), capacity (Pick: I = A - B/2 + 1,
-- one interior cell per held room), then per-edge lower bounds combined by MAX.
-- Returns (minLen, report) -- minLen keyed "lo:hi" as elro.min_len reads it.
-- faceFitCap is a runaway guard on a face-local solve's total length per held room.
elro.faceFitCap = elro.faceFitCap or 2
elro.faceFitRounds = elro.faceFitRounds or 60
elro.faceFitLenCap = elro.faceFitLenCap or 64     -- divergence ceiling on any one edge
elro.faceFitRoomCap = elro.faceFitRoomCap or 150  -- biggest face-local solve worth running
elro.faceFitTimeCap = elro.faceFitTimeCap or 3    -- seconds, over the whole pre-pass

-- `topoOnly`: run only the topology prologue (rotation system, 2-core, faces, rings) and return
-- once `rep.useN` is published; no closure, no per-face solve, no minimums.
-- Diagonal family table over a set of rings; pure topology, reads `rings` and `dirOf` only.
-- A 45-degree diagonal preserves one of two scalars:
--     family "u": NW (-1,1) and SE (1,-1)   preserve  x + y
--     family "v": NE (1,1)  and SW (-1,-1)  preserve  x - y
-- Two cut edges of the same family can be translated along it without shear; mixed families must
-- shear, but sliding one cut end along the ring may convert the pair.
-- Returns { rings = { [k] = { n, fam = {per edge index}, key = {per edge index},
--                            diag = {edge indices that are diagonal},
--                            same = {{i,j},...}   -- same-family pairs (the usable cuts)
--                            mixed = {{i,j,apex},...} } },  -- adjacent mixed pairs + shared room
--           edge = { ["lo:hi"] = { ring = k, idx = i, fam = "u"/"v" } } }
-- `edge` keeps the first ring that claims an edge; a consumer repairing a ring must pass the ring.
local FAMILY = { northwest = "u", southeast = "u", northeast = "v", southwest = "v" }
function elro.face_families(rings, dirOf)
  local out = { rings = {}, edge = {} }
  for k, g in ipairs(rings or {}) do
    local n = #g
    local R = { n = n, fam = {}, key = {}, diag = {}, same = {}, mixed = {} }
    for i = 1, n do
      local a, b = g[i], g[(i % n) + 1]
      local d = dirOf[a] and dirOf[a][b]
      local f = d and FAMILY[d]
      R.key[i] = ekey(a, b)
      if f then
        R.fam[i] = f
        R.diag[#R.diag + 1] = i
        if not out.edge[R.key[i]] then
          out.edge[R.key[i]] = { ring = k, idx = i, fam = f }
        end
      end
    end
    for x = 1, #R.diag do
      for y = x + 1, #R.diag do
        local i, j = R.diag[x], R.diag[y]
        if R.fam[i] == R.fam[j] then
          R.same[#R.same + 1] = { i, j }
        elseif ((j - i) % n) == 1 or ((i - j) % n) == 1 then
          -- adjacent and mixed: the shared room is the later edge's tail
          local sec = (((j - i) % n) == 1) and j or i
          R.mixed[#R.mixed + 1] = { i, j, g[sec] }
        end
      end
    end
    out.rings[k] = R
  end
  return out
end

function elro.facefit(rooms, adj, topoOnly)
local DELTA = elro.delta
  local rep = { rooms = #rooms, core = 0, faces = 0, bounded = 0, pend = 0, assigned = 0,
                open = 0, rounds = 0, edges = 0, bumped = 0, maxLen = 1, maxK = 1, loads = {},
                chunks = {}, spans = {}, minspans = {}, groupFrames = {} }
  local inset = {}
  for _, r in ipairs(rooms) do inset[r] = true end
  -- ---------------------------------------------------------------- the rotation system
  -- MUTUAL edges only, ONE dart per neighbour (a doubled exit to the same room is not two darts),
  -- lowest angle wins, sorted -- so nothing here depends on pairs() order.
  local rot = {}
  for _, u in ipairs(rooms) do
    elro.bg_tick("facefit-rot")     -- O(E * deg): the back-check rescans each neighbour's exits
    local l = {}
    for d, v in each_exit(adj[u]) do
      if inset[v] and FANG[d] and v ~= u then
        local back = false
        for _, w in each_exit(adj[v]) do if w == u then back = true ; break end end
        if back then l[#l + 1] = { v = v, d = d, a = FANG[d] } end
      end
    end
    table.sort(l, function(p, q) if p.a ~= q.a then return p.a < q.a end return p.v < q.v end)
    local ded, sv = {}, {}
    for _, e in ipairs(l) do if not sv[e.v] then sv[e.v] = true ; ded[#ded + 1] = e end end
    rot[u] = ded
  end
  -- --------------------------------------------------------------------------- the 2-core
  -- A tree carries no cycle constraint at all, so every bit of this lives in the 2-core.
  local core = {}
  for _, r in ipairs(rooms) do core[r] = true end
  local changed = true
  while changed do
    elro.bg_tick("facefit-core")   -- peels one degree-1 layer per pass: O(V) passes worst case
    changed = false
    for _, u in ipairs(rooms) do
      if core[u] then
        local dg = 0
        for _, e in ipairs(rot[u]) do if core[e.v] then dg = dg + 1 end end
        if dg <= 1 then core[u] = false ; changed = true end
      end
    end
  end
  local coreSet, cadj, dirOf = {}, {}, {}
  for _, u in ipairs(rooms) do
    elro.bg_tick("facefit-core2")   -- builds a per-room dart map: O(V * deg)
    if core[u] then
      rep.core = rep.core + 1
      coreSet[u] = true
      local t, m = {}, {}
      for _, e in ipairs(rot[u]) do
        if core[e.v] then t[e.d] = e.v ; m[e.v] = e.d end
      end
      cadj[u], dirOf[u] = t, m
    end
  end
  if rep.core < 3 then return nil, rep end
  -- ------------------------------------------------------------------------------- faces
  local raw = elro.faces(coreSet, cadj)
  local outer = elro.pick_outer_face(raw, cadj)
  rep.faces = #raw
  local function ang_of(u, v) return FANG[dirOf[u] and dirOf[u][v]] end
  -- A face of the 2-core need not be a simple cycle (a bridge corridor is walked out and back).
  -- Split at repeated vertices: everything since the first occurrence is a closed sub-ring. The
  -- stack leftover is a path, so adjacency (including the wrap) is verified per sub-ring below.
  local function split_face(f)
    local out, stack, pos = {}, {}, {}
    for i = 1, #f do
      local r = f[i]
      if pos[r] then
        local sub = {}
        for j = pos[r], #stack do sub[#sub + 1] = stack[j] end
        for j = #stack, pos[r] + 1, -1 do pos[stack[j]] = nil ; stack[j] = nil end
        if #sub >= 3 then out[#out + 1] = sub end
      else
        stack[#stack + 1] = r ; pos[r] = #stack
      end
    end
    if #stack >= 3 then out[#out + 1] = stack end
    return out
  end
  -- No extra (outer) ring may enter `rings`/`RE`/`useN`/the closure: `len` is keyed by ekey and
  -- shared, so an extra ring changes the joint fixed point even if its outputs are gated.
  local rings = {}
  -- ringRaw[ring index] = the trace it came from; split_face can cut one trace into several rings.
  local ringRaw = {}
  for rawi, f in ipairs(raw) do
    if f ~= outer then
      for _, g in ipairs(split_face(f)) do
        local ok, turn, seen = (#g >= 3), 0, {}
        for _, r in ipairs(g) do if seen[r] then ok = false ; break end ; seen[r] = true end
        -- turn total: +360 closes as a bounded face, -360 IS the outer boundary, anything else is a
        -- face that cannot close as a simple curve with these directions at all.
        if ok then
          for i = 1, #g do
            local a = ang_of(g[i], g[(i % #g) + 1])
            local b = ang_of(g[(i % #g) + 1], g[((i + 1) % #g) + 1])
            if not a or not b then ok = false ; break end     -- also catches a non-adjacent wrap
            local dt = (b - a) % 360 ; if dt > 180 then dt = dt - 360 end
            turn = turn + dt
          end
        end
        if ok and turn > 0 then rings[#rings + 1] = g ; ringRaw[#rings] = rawi end
      end
    end
  end
  rep.bounded = #rings
  if #rings == 0 then return nil, rep end
  -- --------------------------------- what hangs off the rings, and which face must hold each
  -- A side component at a cut vertex: delete ring room A, and every component not containing the
  -- rest of the ring hangs off A (pendant tree or nested block alike). Components with more than
  -- one entry edge wrap around A and are counted and skipped.
  local inRing, ringRooms = {}, {}
  for fi, f in ipairs(rings) do
    for _, r in ipairs(f) do
      if not inRing[r] then inRing[r] = {} ; ringRooms[#ringRooms + 1] = r end
      inRing[r][fi] = true
    end
  end
  table.sort(ringRooms)                     -- deterministic: never depends on pairs() order
  local pend = {}
  for _, A in ipairs(ringRooms) do
    -- a side-component flood PER RING ROOM, so this is O(ringRooms * E): 91.5% of the worst
    -- frame measured in game, reached from compose_spqr_adj's topoOnly facefit
    elro.bg_tick("facefit-side")
    local seen = { [A] = true }
    for _, e0 in ipairs(rot[A]) do          -- angular order => deterministic entry choice
      if not seen[e0.v] then
        local comp, q, qh = { e0.v }, { e0.v }, 1
        seen[e0.v] = true
        local entries = 0
        while qh <= #q do
          local u = q[qh] ; qh = qh + 1
          for _, e in ipairs(rot[u]) do
            if e.v == A then entries = entries + 1
            elseif not seen[e.v] then
              seen[e.v] = true ; q[#q + 1] = e.v ; comp[#comp + 1] = e.v
            end
          end
        end
        if entries > 1 then
          rep.multi = (rep.multi or 0) + 1
        else
          local set = {}
          for _, r in ipairs(comp) do set[r] = true end
          pend[#pend + 1] = { n = #comp, A = A, d = e0.d, set = set }
        end
      end
    end
  end
  rep.pend = #pend
  -- Sector test: at each vertex a bounded face (traced counter-clockwise) occupies the wedge from
  -- its leaving edge ccw to the reverse of its arriving edge; a pendant whose first edge points
  -- into that wedge is inside that face.
  local function in_wedge(from, to, a)
    local w, x = (to - from) % 360, (a - from) % 360
    return x > 0 and x < w
  end
  -- Several rings can meet at A; take the tightest containing wedge, strictly inside (x > 0 and
  -- x < w), since the pendant may leave along a core edge that is not an edge of this ring.
  local load_ = {}
  for _, p in ipairs(pend) do
    local pa = FANG[p.d]
    local hit, tight
    if pa then
      for fi in pairs(inRing[p.A] or {}) do
        local f = rings[fi]
        for i = 1, #f do
          if f[i] == p.A then
            local aOut = ang_of(f[i], f[(i % #f) + 1])
            local aIn = ang_of(f[i], f[((i - 2) % #f) + 1])
            if aOut and aIn and in_wedge(aOut, aIn, pa) then
              local w = (aIn - aOut) % 360
              -- ties by face index, never by pairs() order
              if not tight or w < tight or (w == tight and fi < hit) then hit, tight = fi, w end
            end
          end
        end
      end
    end
    -- a component that contains part of the face it was assigned to is not INSIDE it
    if hit then
      for _, r in ipairs(rings[hit]) do if p.set[r] then hit = nil ; break end end
    end
    if hit then
      p.face = hit
      load_[hit] = (load_[hit] or 0) + p.n
      rep.assigned = rep.assigned + 1
    end
  end
  -- ------------------------------------------------------- 1. CLOSURE, jointly over shared edges
  local len = {}
  for _, f in ipairs(rings) do
    for i = 1, #f do len[ekey(f[i], f[(i % #f) + 1])] = 1 end
  end
  for _ in pairs(len) do rep.edges = rep.edges + 1 end
  local function ring_edges(f)
    local E = {}
    for i = 1, #f do
      local u, v = f[i], f[(i % #f) + 1]
      E[i] = { k = ekey(u, v), D = DELTA[dirOf[u][v]] }
    end
    return E
  end
  local RE, useN = {}, {}
  for fi, f in ipairs(rings) do
    elro.bg_tick("facefit-use")     -- ring_edges walks the whole ring, per ring
    RE[fi] = ring_edges(f)
    for i = 1, #RE[fi] do useN[RE[fi][i].k] = (useN[RE[fi][i].k] or 0) + 1 end
  end
  -- Published before every early return: how many bounded faces use each edge (topology, not a
  -- length). Read by _stretch_energy.
  rep.useN = useN
  -- The bounded faces: the one deterministic enumeration in the engine; the harness reads these.
  rep.rings = rings
  -- Raw traces for callers pricing chords (the face a chord bounds is what split_face discards).
  rep.coreSet, rep.cadj, rep.dirOf, rep.raw, rep.outer = coreSet, cadj, dirOf, raw, outer
  -- Wedge assignment, published ahead of the sizing return since it asserts no size.
  rep.load, rep.pendants = load_, pend
  if topoOnly then return nil, rep end   -- shared-edge topology only; nothing below is sizing-free
  local function resid(E, lenT)
    local rx, ry = 0, 0
    for i = 1, #E do
      local L = (lenT or len)[E[i].k]
      rx = rx + L * E[i].D[1] ; ry = ry + L * E[i].D[2]
    end
    return rx, ry
  end
  -- Exact ring closure: the ring equation has two rows, so an optimal basic solution uses at most
  -- two directions. Enumerate single directions and pairs, solve each 2x2, take the cheapest.
  local function close_ring(E, lenT, frozen)
    lenT = lenT or len
    local tx, ty = resid(E, lenT)
    if tx == 0 and ty == 0 then return true, false end
    tx, ty = -tx, -ty
    local dirs, seen = {}, {}
    for i = 1, #E do
      local D = E[i].D
      local key = D[1] .. "," .. D[2]
      if not seen[key] then seen[key] = true ; dirs[#dirs + 1] = D end
    end
    table.sort(dirs, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
    local best
    local function offer(i, ti, j, tj, cost)
      if not best or cost < best.cost then best = { i = i, ti = ti, j = j, tj = tj, cost = cost } end
    end
    for a = 1, #dirs do
      local D = dirs[a]
      -- one direction alone: it has to hit the target exactly
      local t
      if D[1] ~= 0 and tx % D[1] == 0 then t = tx / D[1] elseif D[1] == 0 and tx ~= 0 then t = nil
      elseif D[2] ~= 0 and ty % D[2] == 0 then t = ty / D[2] end
      if t and t > 0 and t * D[1] == tx and t * D[2] == ty then offer(a, t, nil, 0, t) end
      for b = a + 1, #dirs do
        local F = dirs[b]
        local det = D[1] * F[2] - D[2] * F[1]
        if det ~= 0 then
          local n1, n2 = tx * F[2] - ty * F[1], D[1] * ty - D[2] * tx
          if n1 % det == 0 and n2 % det == 0 then
            local t1, t2 = n1 / det, n2 / det
            if t1 >= 0 and t2 >= 0 and (t1 + t2) > 0 then offer(a, t1, b, t2, t1 + t2) end
          end
        end
      end
    end
    if not best then return false, false end
    -- Where the added length lands: prefer an edge this face owns (useN <= 1), then an unfrozen
    -- shared edge, then any; spread round-robin rather than pile on one edge. `frozen` marks
    -- edges a neighbour's face-local solve already placed rooms against.
    local function park(D, amt)
      if not D or amt <= 0 then return end
      local own, free, any = {}, {}, {}
      for i = 1, #E do
        if E[i].D[1] == D[1] and E[i].D[2] == D[2] then
          local k = E[i].k
          any[#any + 1] = k
          if not (frozen and frozen[k]) then
            free[#free + 1] = k
            if (useN[k] or 1) <= 1 then own[#own + 1] = k end
          end
        end
      end
      local pick = (#own > 0) and own or ((#free > 0) and free or any)
      if #pick == 0 then return end
      table.sort(pick)                       -- deterministic: never depends on where the trace began
      -- divide, do not loop: amt is a residual and can be huge on a diverging fixed point
      local base, extra = math.floor(amt / #pick), amt % #pick
      for i = 1, #pick do
        lenT[pick[i]] = lenT[pick[i]] + base + ((i <= extra) and 1 or 0)
      end
    end
    park(dirs[best.i], best.ti)
    if best.j then park(dirs[best.j], best.tj) end
    return true, true
  end
  -- Divergence is multiplicative, so a length ceiling is needed as well as a round limit.
  local LCAP = elro.faceFitLenCap or 64
  for it = 1, (elro.faceFitRounds or 60) do
    rep.rounds = it
    local moved = false
    for fi = 1, #RE do
      local _, grew = close_ring(RE[fi])
      if grew then moved = true end
    end
    for _, L in pairs(len) do
      if L > LCAP then rep.diverged = "length" ; break end
    end
    if rep.diverged or not moved then break end
  end
  -- ---------------------------------------------------------- 2. CAPACITY, per face, by scaling
  local function measure(E, sc, lenT)
    local x, y, B, pts = 0, 0, 0, {}
    lenT = lenT or len
    for i = 1, #E do
      pts[i] = { x, y }
      local L = lenT[E[i].k] * sc
      x, y = x + E[i].D[1] * L, y + E[i].D[2] * L ; B = B + L
    end
    local A2 = 0
    for i = 1, #pts do
      local p, q = pts[i], pts[(i % #pts) + 1]
      A2 = A2 + (p[1] * q[2] - q[1] * p[2])
    end
    local ar = math.abs(A2) / 2
    return (x == 0 and y == 0), ar - B / 2 + 1, pts   -- closed?, Pick interior, the polygon
  end
  -- Pick's theorem only holds for a simple polygon; a closed ring can still self-cross, so the
  -- polygon is tested (once, at k = 1; simplicity is scale-invariant). Returns the offending
  -- pair (false, i, j) since curl growth needs to know which strands to separate.
  local function poly_simple(pts)
    local n = #pts
    local o = orip
    for i = 1, n do
      local a, b = pts[i], pts[(i % n) + 1]
      for j = i + 1, n do
        local c, d = pts[j], pts[(j % n) + 1]
        local adjacent = (j == i + 1) or (i == 1 and j == n)
        local o1, o2, o3, o4 = o(a, b, c), o(a, b, d), o(c, d, a), o(c, d, b)
        if adjacent then
          -- consecutive edges legitimately share one endpoint; they may not lie along each other
          if o1 == 0 and o2 == 0 then
            local ux, uy = b[1] - a[1], b[2] - a[2]
            local vx, vy = d[1] - c[1], d[2] - c[2]
            if ux * vx + uy * vy < 0 then return false, i, j end -- a u-turn: the ring doubles back
          end
        elseif o1 ~= 0 and o2 ~= 0 and o3 ~= 0 and o4 ~= 0 then
          if ((o1 > 0) ~= (o2 > 0)) and ((o3 > 0) ~= (o4 > 0)) then return false, i, j end
        else
          if (o1 == 0 and within(a, b, c)) or (o2 == 0 and within(a, b, d))
            or (o3 == 0 and within(c, d, a)) or (o4 == 0 and within(c, d, b)) then return false, i, j end
        end
      end
    end
    return true
  end
  -- Crossing count: the gradient the curl un-cross greedy follows.
  local function poly_crossings(pts)
    local n, cnt = #pts, 0
    local o = orip
    for i = 1, n do
      local a, b = pts[i], pts[(i % n) + 1]
      for j = i + 1, n do
        local c, d = pts[j], pts[(j % n) + 1]
        local adjacent = (j == i + 1) or (i == 1 and j == n)
        local o1, o2, o3, o4 = o(a, b, c), o(a, b, d), o(c, d, a), o(c, d, b)
        if adjacent then
          if o1 == 0 and o2 == 0 then
            local ux, uy = b[1] - a[1], b[2] - a[2]
            local vx, vy = d[1] - c[1], d[2] - c[2]
            if ux * vx + uy * vy < 0 then cnt = cnt + 1 end
          end
        elseif o1 ~= 0 and o2 ~= 0 and o3 ~= 0 and o4 ~= 0 then
          if ((o1 > 0) ~= (o2 > 0)) and ((o3 > 0) ~= (o4 > 0)) then cnt = cnt + 1 end
        else
          if (o1 == 0 and within(a, b, c)) or (o2 == 0 and within(a, b, d))
            or (o3 == 0 and within(c, d, a)) or (o4 == 0 and within(c, d, b)) then cnt = cnt + 1 end
        end
      end
    end
    return cnt
  end
  -- Per-face planarity cost. Each face with a non-zero load is priced alone on its own all-ones
  -- table (the joint closure may diverge; a per-face cost needs no agreement between faces).
  -- Metric: got - base, total added length. Edges grow individually by minimum total length;
  -- the capacity test is a minimum axial box from the order DAG's longest chain, not an area.
  -- Analytic, no placement. Two low biases: the chain under-reports order-independent components,
  -- and the static DAG is weaker than what the walk discovers.
  rep.faceCost = {}
  if elro.crossCost or TUNE.crossCostTau > 0 then
    -- (a) WHAT THE FACE MUST HOLD -- the ROOMS, not the count. `load_` has only the count, and a
    -- count cannot be asked what shape it is.
    local contents = {}
    for _, p in ipairs(pend) do
      if p.face then
        local t = contents[p.face]
        if not t then t = {} ; contents[p.face] = t end
        for r in pairs(p.set) do t[r] = true end
      end
    end
    -- (b) minimum extent along an axis = longest path in the order DAG induced on the room set's
    -- classes. `wire_cross` caches on table identity; eviction here is safe. An equality class
    -- shares a coordinate exactly, so the profile is rank r (longest chain ending at the class)
    -- against M[r], the widest class at that rank.
    local W = elro.wire_cross(adj)
    -- W.n counts topologically forced crossings; those faces' savings are already banked.
    rep.forced = W.n or 0
    local function axis_profile(set, axis)
      local A = W.O[axis] ; if not A then return 1, { 1 } end
      local C, size = {}, {}
      for r in pairs(set) do
        local c = A.find(r)
        C[c] = true ; size[c] = (size[c] or 0) + 1
      end
      -- An order cycle is condensed, not bailed out of: Tarjan, then longest path over the
      -- condensation (one SCC = one coordinate). Iterative; class count is unbounded.
      local order = {}
      for c in pairs(C) do order[#order + 1] = c end
      table.sort(order)                     -- never pairs() order: the LuaJIT hash seed moves it
      local idx, index, low, onstk, S, comp, ncomp = 0, {}, {}, {}, {}, {}, 0
      for _, s in ipairs(order) do
        if not index[s] then
          index[s], low[s], idx = idx, idx, idx + 1
          S[#S + 1] = s ; onstk[s] = true
          local frames = { { v = s, i = 1 } }
          while #frames > 0 do
            local F = frames[#frames]
            local v = F.v
            if not F.sc then
              local a = {}
              for b in pairs(A.succ[v] or {}) do if C[b] then a[#a + 1] = b end end
              table.sort(a)
              F.sc = a
            end
            if F.i <= #F.sc then
              local w = F.sc[F.i] ; F.i = F.i + 1
              if not index[w] then
                index[w], low[w], idx = idx, idx, idx + 1
                S[#S + 1] = w ; onstk[w] = true
                frames[#frames + 1] = { v = w, i = 1 }
              elseif onstk[w] and index[w] < low[v] then low[v] = index[w] end
            else
              frames[#frames] = nil
              if low[v] == index[v] then
                ncomp = ncomp + 1
                local w
                repeat
                  w = S[#S] ; S[#S] = nil ; onstk[w] = nil ; comp[w] = ncomp
                until w == v
              end
              local P = frames[#frames]
              if P and low[v] < low[P.v] then low[P.v] = low[v] end
            end
          end
        end
      end
      -- Tarjan closes a component only after everything reachable FROM it, so a component's
      -- successors always carry a SMALLER id: `up` (chain rising from a component) resolves in
      -- increasing id order, `down` (chain arriving at it, i.e. its rank) in decreasing.
      local up, down = {}, {}
      for k = 1, ncomp do up[k] = 1 ; down[k] = 1 end
      local arcs = {}
      for _, v in ipairs(order) do
        for w in pairs(A.succ[v] or {}) do
          if C[w] and comp[w] ~= comp[v] then arcs[#arcs + 1] = { comp[v], comp[w] } end
        end
      end
      table.sort(arcs, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
      for i = 1, #arcs do
        local a = arcs[i]
        if up[a[2]] + 1 > up[a[1]] then up[a[1]] = up[a[2]] + 1 end
      end
      for i = #arcs, 1, -1 do
        local a = arcs[i]
        if down[a[1]] + 1 > down[a[2]] then down[a[2]] = down[a[1]] + 1 end
      end
      local mx, M = 0, {}
      for _, c in ipairs(order) do
        local r = down[comp[c]]
        if r > mx then mx = r end
        if (M[r] or 0) < size[c] then M[r] = size[c] end
      end
      for i = 1, mx do M[i] = M[i] or 1 end
      return mx, M
    end
    -- (c) can the interior hold the contents? Rasterise the strictly interior lattice points and
    -- ask necessary conditions: row/column profiles dominate MH/MW in order, and cells >= need.
    -- Necessary, not sufficient: it under-reports, the safe direction for a rule admitting crossings.
    local RCAP = 40000
    local function cap_fit(pts, wN, hN, need, MW, MH)
      local n = #pts
      local lox, hix, loy, hiy = math.huge, -math.huge, math.huge, -math.huge
      for i = 1, n do
        local p = pts[i]
        if p[1] < lox then lox = p[1] end ; if p[1] > hix then hix = p[1] end
        if p[2] < loy then loy = p[2] end ; if p[2] > hiy then hiy = p[2] end
      end
      local nw, nh = hix - lox + 1, hiy - loy + 1
      if nw <= 0 or nh <= 0 or nw * nh > RCAP then return false, 0, 0 end
      local function interior(x, y)
        local c = false
        for i = 1, n do
          local a, b = pts[i], pts[(i % n) + 1]
          local cr = (b[1] - a[1]) * (y - a[2]) - (b[2] - a[2]) * (x - a[1])
          if cr == 0 and math.min(a[1], b[1]) <= x and x <= math.max(a[1], b[1])
             and math.min(a[2], b[2]) <= y and y <= math.max(a[2], b[2]) then return false end
          if (a[2] > y) ~= (b[2] > y) then
            if a[1] + (y - a[2]) / (b[2] - a[2]) * (b[1] - a[1]) > x then c = not c end
          end
        end
        return c
      end
      -- strict form: the interior must contain a filled wN x hN axis-aligned box
      local col, row, cells, up, boxw = {}, {}, 0, {}, 0
      for i = 1, nw do up[i] = 0 ; col[i] = 0 end
      for j = 1, nh do
        -- per ROW, not per cell: the scan is up to RCAP cells x n edges and facefit had no
        -- tick anywhere, which is what put this window over the frame budget
        elro.bg_tick("facefit-fit")
        local run = 0
        row[j] = 0
        for i = 1, nw do
          if interior(lox + i - 1, loy + j - 1) then
            cells = cells + 1 ; col[i] = col[i] + 1 ; row[j] = row[j] + 1 ; up[i] = up[i] + 1
          else up[i] = 0 end
          if up[i] >= hN then run = run + 1 ; if run > boxw then boxw = run end else run = 0 end
        end
      end
      local sw, sh = 0, 0
      for i = 1, nw do if col[i] > 0 then sw = sw + 1 end end
      for j = 1, nh do if row[j] > 0 then sh = sh + 1 end end
      -- cells >= need catches what the width bound (no antichain term) misses
      if true then
        return (boxw >= wN and hN > 0 and cells >= need), sw, sh, cells
      end
      -- the order-preserving greedy: take each row as soon as it is wide enough for the next class
      local function stair(counts, nn, M, K)
        local r = 1
        for j = 1, nn do
          if counts[j] >= M[r] then
            r = r + 1
            if r > K then return true end
          end
        end
        return K < 1
      end
      return (cells >= need and stair(col, nw, MW, wN) and stair(row, nh, MH, hN)), sw, sh, cells
    end
    -- (d) one unit of closed growth; `park`'s rules apply (prefer owned edges, spread). `allow`
    -- restricts which edge takes the length; the curl un-cross needs a direction grown inside
    -- the crossing span specifically.
    local function bump(E, L, D, allow)
      local best
      for i = 1, #E do
        local e = E[i]
        if (not allow or allow(i)) and e.D[1] == D[1] and e.D[2] == D[2] then
          local own = ((useN[e.k] or 1) <= 1) and 1 or 0
          if not best or own > best.own or (own == best.own and L[e.k] < best.len)
             or (own == best.own and L[e.k] == best.len and e.k < best.k) then
            best = { k = e.k, own = own, len = L[e.k] }
          end
        end
      end
      if not best then return false end
      L[best.k] = L[best.k] + 1
      return true
    end
    -- The price of a crossing: shortest path in the planar dual from the face to open space,
    -- built on the traces (every dart belongs to exactly one traced face; `ringRaw` maps back).
    -- Wrap adjacency is verified since `elro.faces` breaks mid-walk on an asymmetric exit.
    -- `rawLoad` is inward load per trace, so the march can tell empty faces from occupied ones.
    local rawLoad = {}
    for fi in ipairs(rings) do
      local rw = ringRaw[fi]
      if rw and (load_[fi] or 0) > 0 then rawLoad[rw] = (rawLoad[rw] or 0) + load_[fi] end
    end
    local escape = nil
    if outer then
      local faceOf = {}
      for fi, f in ipairs(raw) do
        local n = #f
        for i = 1, n do
          local a, b = f[i], f[(i % n) + 1]
          local ok = false
          for _, w in pairs(cadj[a] or {}) do if w == b then ok = true ; break end end
          if ok then
            local k = a .. ":" .. b
            if not faceOf[k] then faceOf[k] = fi end
          end
        end
      end
      -- Every trace turning -360 is an outer boundary (one per component) and a BFS source.
      local dual, src, dualE = {}, {}, {}
      for fi, f in ipairs(raw) do
        if f == outer then src[fi] = true
        else
          local turn, ok = 0, (#f >= 3)
          for i = 1, #f do
            local a = ang_of(f[i], f[(i % #f) + 1])
            local b = ang_of(f[(i % #f) + 1], f[((i + 1) % #f) + 1])
            if not a or not b then ok = false ; break end
            local dt = (b - a) % 360 ; if dt > 180 then dt = dt - 360 end
            turn = turn + dt
          end
          if ok and turn < 0 then src[fi] = true end
        end
        local n = #f
        for i = 1, n do
          local a, b = f[i], f[(i % n) + 1]
          local s1, s2 = faceOf[a .. ":" .. b], faceOf[b .. ":" .. a]
          if s1 and s2 and s1 ~= s2 then
            dual[s1] = dual[s1] or {} ; dual[s1][s2] = true
            dual[s2] = dual[s2] or {} ; dual[s2][s1] = true
          end
          -- per dart, carrying the wall's outward normal (face on the left, so (dy, -dx))
          if s1 == fi and s2 then
            local dd = dirOf[a] and dirOf[a][b]
            local De = dd and DELTA[dd]
            if De then
              dualE[fi] = dualE[fi] or {}
              dualE[fi][#dualE[fi] + 1] = { to = s2, nx = De[2], ny = -De[1] }
            end
          end
        end
      end
      -- The escape march: from the attachment direction, keep crossing walls whose outward normal
      -- faces that way, face after face, until an outer trace is reached. The direction never
      -- changes; the count is a minimum over admissible walls at each step; a face already holding
      -- something is impassable; past ESCCAP the search stops and nil reads as blocked.
      local ESCCAP = 4                    -- one past the accepted maximum of 3
      escape = function(rawIdx, D)
        local best
        local function go(fi, depth, seen)
          if depth >= ESCCAP or (best and depth + 1 >= best) then return end
          local out = {}
          for _, e in ipairs(dualE[fi] or {}) do
            if e.nx * D[1] + e.ny * D[2] > 0 then out[#out + 1] = e.to end
          end
          table.sort(out)                 -- never pairs() order: the LuaJIT hash seed moves it
          for _, to in ipairs(out) do
            if src[to] then
              if not best or depth + 1 < best then best = depth + 1 end
            -- a loaded face is impassable, not merely expensive (rawLoad is per trace)
            elseif (rawLoad[to] or 0) > 0 then          -- blocked: somebody already lives there
            elseif not seen[to] then
              seen[to] = true             -- a face is never worth re-entering on one straight run
              go(to, depth + 1, seen)
              seen[to] = nil
            end
          end
        end
        go(rawIdx, 0, { [rawIdx] = true })
        return best
      end
    end
    -- which pendants attach to each face, so the escape can be pointed the way they hang
    local attach = {}
    for _, p in ipairs(pend) do
      if p.face then
        attach[p.face] = attach[p.face] or {}
        -- n: how the load splits over attachments decides whether one site can evict it
        table.insert(attach[p.face], { A = p.A, d = p.d, n = p.n, set = p.set })
      end
    end
    -- every pendant by its attachment room, including those assigned to no face (RULE 4 needs them)
    local pendAt = {}
    for _, p in ipairs(pend) do
      pendAt[p.A] = pendAt[p.A] or {}
      table.insert(pendAt[p.A], { n = p.n, face = p.face })
    end
    local cands = {}
    for fi = 1, #rings do
      if (load_[fi] or 0) > 0 and contents[fi] then
        cands[#cands + 1] = { fi = fi, ring = rings[fi], need = load_[fi], set = contents[fi],
                              att = attach[fi] }
      end
    end
    -- A face with several inward structures does not empty when one leaves: price it a second
    -- time (a shadow) with the largest structure removed, and let the difference be the saving.
    -- Shadow fi is negated-and-offset so it cannot collide with a face index or a curl's.
    do
      local shadows = {}
      for _, C in ipairs(cands) do
        if #(C.att or {}) > 1 then
          local big
          for _, a in ipairs(C.att) do if not big or (a.n or 0) > (big.n or 0) then big = a end end
          if big and big.set and (big.n or 0) < C.need then
            local set, n = {}, 0
            for r in pairs(C.set) do if not big.set[r] then set[r] = true ; n = n + 1 end end
            if n > 0 then
              shadows[#shadows + 1] = { fi = -1000 - C.fi, ring = C.ring, need = n, set = set,
                                        att = C.att, esc = C.esc, shadow = C.fi }
            end
          end
        end
      end
      for _, s in ipairs(shadows) do cands[#cands + 1] = s end
    end
    -- The curl: a degree-2 arm turning a full 360 encloses a pocket no face enumeration sees (the
    -- arm is a bridge, so both darts land in the same traced face). Accumulate turn along the arm;
    -- when a window reaches 360 the edge leaving its first vertex and the edge entering its last
    -- are the two strands that must cross. The loop is the window, not the whole arm.
    do
      -- angles off rot, not ang_of: dirOf is core-only and an arm is exactly what the peel strips
      local function rang(u, v)
        for _, e in ipairs(rot[u] or {}) do if e.v == v then return e.a, e.d end end
      end
      local deg = {}
      for _, u in ipairs(rooms) do deg[u] = #(rot[u] or {}) end
      local seenRun = {}
      for _, u0 in ipairs(rooms) do
        elro.bg_tick("facefit-runs")   -- each deg-2 run is walked out from here: O(V * deg + runs)
        if deg[u0] ~= 2 then
          for _, e0 in ipairs(rot[u0] or {}) do
            if deg[e0.v] == 2 and not seenRun[e0.v] then
              local path, prev, cur = { u0, e0.v }, u0, e0.v
              while deg[cur] == 2 do
                seenRun[cur] = true
                local nxt
                for _, e in ipairs(rot[cur] or {}) do if e.v ~= prev then nxt = e.v ; break end end
                if not nxt then break end
                path[#path + 1] = nxt ; prev, cur = cur, nxt
              end
              if #path >= 4 and path[1] ~= path[#path] then
                local tv = {}
                for i = 2, #path - 1 do
                  local x, y = rang(path[i - 1], path[i]), rang(path[i], path[i + 1])
                  if x and y then
                    local dt = (y - x) % 360 ; if dt > 180 then dt = dt - 360 end
                    tv[i] = dt
                  end
                end
                local p0, q0
                -- Reversals inside the window are allowed (a zigzag cancels and never reaches
                -- 360). Take the minimal window by length, not the first match; a longer window
                -- has straight run-up glued to it. Untested for the reversing case.
                local bestW
                for i = 2, #path - 1 do
                  if tv[i] and tv[i] ~= 0 then
                    local acc = 0
                    for j = i, #path - 1 do
                      if not tv[j] then break end
                      acc = acc + tv[j]
                      if math.abs(acc) >= 360 then
                        if not bestW or (j - i) < (bestW[2] - bestW[1]) then bestW = { i, j } end
                        break
                      end
                    end
                  end
                end
                if bestW then p0, q0 = bestW[1], bestW[2] end
                if p0 then
                  rep.curlDbg = (rep.curlDbg or '') .. string.format(' [win %d..%d of %d]', p0, q0, #path)
                  local loop = {}
                  for i = p0, q0 do loop[#loop + 1] = path[i] end
                  -- The two sides: delete the loop and flood from the off-loop neighbour of each
                  -- window end. The smaller side must go inside the spiral if the crossing is
                  -- refused. Sides, not components: a disconnected part of the area is neither.
                  local onC = {}
                  for _, r in ipairs(loop) do onC[r] = true end
                  local function side_of(endRoom)
                    local best
                    for _, e in ipairs(rot[endRoom] or {}) do
                      if not onC[e.v] then
                        local seen, q, qh = { [e.v] = true }, { e.v }, 1
                        while qh <= #q do
                          local w = q[qh] ; qh = qh + 1
                          for _, e2 in ipairs(rot[w] or {}) do
                            if not onC[e2.v] and not seen[e2.v] then
                              seen[e2.v] = true ; q[#q + 1] = e2.v
                            end
                          end
                        end
                        -- a window end can have several off-loop neighbours; they are all the same
                        -- side, so take the largest flood rather than double-counting overlaps
                        if not best or #q > #best.q then best = { q = q, seen = seen } end
                      end
                    end
                    return best
                  end
                  local sA, sB = side_of(loop[1]), side_of(loop[#loop])
                  local need, cset = 0, {}
                  local pick, anchor
                  if sA and sB then
                    if #sA.q <= #sB.q then pick, anchor = sA, loop[1] else pick, anchor = sB, loop[#loop] end
                  elseif sA then pick, anchor = sA, loop[1]
                  elseif sB then pick, anchor = sB, loop[#loop] end
                  if pick then
                    -- the anchor (window end the side hangs off) counts toward the side
                    need = #pick.q + 1
                    for _, r in ipairs(pick.q) do cset[r] = true end
                    cset[anchor] = true
                  end
                  local E, disp, okE = {}, { 0, 0 }, true
                  for i = 1, #loop - 1 do
                    local _, d = rang(loop[i], loop[i + 1])
                    local De = d and DELTA[d]
                    if not De then okE = false ; break end
                    E[#E + 1] = { k = ekey(loop[i], loop[i + 1]), D = De }
                    disp[1], disp[2] = disp[1] + De[1], disp[2] + De[2]
                  end
                  rep.curlDbg = (rep.curlDbg or '') .. string.format(' [okE=%s E=%d need=%d]', tostring(okE), #E, need)
                  if okE and #E >= 3 and need > 0 then
                    -- close the window EXACTLY over the full compass (one virtual edge of length 1
                    -- cannot, and `close_ring` only ADDS in directions the ring already has)
                    local dl = {}
                    for d in pairs(DELTA) do if FANG[d] then dl[#dl + 1] = d end end
                    table.sort(dl)          -- never pairs() order: the LuaJIT hash seed moves it
                    -- A window that already closes (displacement 0) needs no virtual edge; that is
                    -- the collision case (last room on the first room's cell), the normal case for
                    -- a full turn.
                    local tx, ty, best = -disp[1], -disp[2], nil
                    if tx == 0 and ty == 0 then best = { none = true, t1 = 0, t2 = 0 } end
                    for i = 1, (best and 0 or #dl) do
                      local Da = DELTA[dl[i]]
                      for j = i + 1, #dl do
                        local Db = DELTA[dl[j]]
                        local det = Da[1] * Db[2] - Da[2] * Db[1]
                        if det ~= 0 then
                          local n1, n2 = tx * Db[2] - ty * Db[1], Da[1] * ty - Da[2] * tx
                          if n1 % det == 0 and n2 % det == 0 then
                            local t1, t2 = n1 / det, n2 / det
                            if t1 >= 0 and t2 >= 0 and (t1 + t2) > 0
                               and (not best or t1 + t2 < best.c) then
                              best = { a = Da, b = Db, t1 = t1, t2 = t2, c = t1 + t2 }
                            end
                          end
                        end
                      end
                    end
                    if best then
                      if best.t1 > 0 then
                        E[#E + 1] = { k = "curl1:" .. loop[1], D = best.a, len0 = best.t1,
                                      virt = true }
                      end
                      if best.t2 > 0 then
                        E[#E + 1] = { k = "curl2:" .. loop[1], D = best.b, len0 = best.t2,
                                      virt = true }
                      end
                      -- orient by signed area (the virtual edge contributes turn too); carry
                      -- len0/virt through the reversal or the ring re-opens
                      local x, y, pts, A2 = 0, 0, {}, 0
                      for i = 1, #E do pts[i] = { x, y } ; x, y = x + E[i].D[1], y + E[i].D[2] end
                      for i = 1, #pts do
                        local pp, qq = pts[i], pts[(i % #pts) + 1]
                        A2 = A2 + (pp[1] * qq[2] - qq[1] * pp[2])
                      end
                      if A2 < 0 then
                        local rv = {}
                        for i = #E, 1, -1 do
                          rv[#rv + 1] = { k = E[i].k, D = { -E[i].D[1], -E[i].D[2] },
                                          len0 = E[i].len0, virt = E[i].virt }
                        end
                        E = rv
                      end
                      -- the crossing pair's four rooms, a quartet as the wire prover produces one
                      cands[#cands + 1] = { fi = -(#cands + 1), ring = loop, need = need,
                                            set = cset, E = E, curl = true, esc = 1,
                                            pair = { loop[1], loop[2],
                                                     loop[#loop - 1], loop[#loop] } }
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    for _, C in ipairs(cands) do
      -- C.E lets a synthetic curl ring through: its closing edge is virtual, so ring_edges cannot build it
      local E = C.E or ring_edges(C.ring)
      local L = {} ; for i = 1, #E do L[E[i].k] = E[i].len0 or 1 end
      local wN, MW = axis_profile(C.set, 1)
      local hN, MH = axis_profile(C.set, 2)
      local rec = { fi = C.fi, n = #E, need = C.need, ring = C.ring, r = E[1].k, w = wN, h = hN,
                    esc = C.esc, curl = C.curl, turn = C.turn, pair = C.pair,
                    shadow = C.shadow }
      local okC = close_ring(E, L)
      local closed, _, pts = measure(E, 1, L)
      -- one march per attachment direction, cheapest wins; a curl costs exactly one crossing and
      -- needs no escape
      rec.esc = C.esc
      if escape and not C.curl then
        local seenD = {}
        for _, at in ipairs(C.att or {}) do
          local D = DELTA[at.d]
          if D and not seenD[at.d] then
            seenD[at.d] = true
            local e = escape(ringRaw[C.fi] or -1, D)
            if e and (not rec.esc or e < rec.esc) then rec.esc = e end
          end
        end
      end
      -- a curl starts self-crossing by design, so simplicity joins the fit condition instead of
      -- gating entry
      if okC and closed and (poly_simple(pts) or C.curl) then
        -- virtual gap edges of a synthetic curl ring are not inflated
        local base = 0
        for i = 1, #E do if not E[i].virt then base = base + L[E[i].k] end end
        -- snapshot the closed lengths: which edges grew is what `grown` counts
        local L0 = {} ; for i = 1, #E do L0[E[i].k] = L[E[i].k] end
        -- Moves this ring can grow on: a set of directions whose deltas sum to zero, one unit
        -- each, cost = size. Opposite pairs (cost 2) first; zero-sum triples for triangular faces.
        -- dkey negates into a fresh zero: -0 formats as "-0" and would miss every axial pair.
        local function dkey(x, y)
          if x == 0 then x = 0 end ; if y == 0 then y = 0 end
          return x .. "," .. y
        end
        local have, dirs, moves = {}, {}, {}
        for i = 1, #E do
          local k = dkey(E[i].D[1], E[i].D[2])
          if not have[k] then have[k] = E[i].D ; dirs[#dirs + 1] = k end
        end
        table.sort(dirs)                    -- never pairs() order: the LuaJIT hash seed moves it
        local function add_move(ds, key)
          local ax, ay, pure = 0, 0, 0
          for _, D in ipairs(ds) do
            if D[1] ~= 0 then ax = 1 end
            if D[2] ~= 0 then ay = 1 end
            if D[1] == 0 or D[2] == 0 then pure = 1 end
          end
          moves[#moves + 1] = { ds = ds, ax = ax, ay = ay, pure = pure, cost = #ds, key = key }
        end
        for _, k in ipairs(dirs) do
          local D = have[k]
          local O = have[dkey(-D[1], -D[2])]
          if O and (D[1] > 0 or (D[1] == 0 and D[2] > 0)) then add_move({ D, O }, k) end
        end
        if #moves == 0 then
          for a = 1, #dirs do
            for b = a + 1, #dirs do
              local D, F = have[dirs[a]], have[dirs[b]]
              local G = have[dkey(-(D[1] + F[1]), -(D[2] + F[2]))]
              if G then add_move({ D, F, G }, dirs[a] .. "|" .. dirs[b]) end
            end
          end
        end
        -- Zero-sum multiset (a wall direction taken more than once) when neither generator above
        -- produced a move, e.g. a triangle with two diagonals and an axial base (2E + NW + SW = 0).
        -- #dirs <= 8 and multiplicity is capped at 6.
        if #moves == 0 then
          local best = nil
          local function rec(i, ds, sx, sy, n)
            if best and n >= #best then return end
            if n >= 2 and sx == 0 and sy == 0 then
              local c = {} ; for j = 1, n do c[j] = ds[j] end ; best = c ; return
            end
            if n >= 6 or i > #dirs then return end
            local D = have[dirs[i]]
            for m = 0, 6 - n do
              if m > 0 then ds[n + m] = D end
              rec(i + 1, ds, sx + m * D[1], sy + m * D[2], n + m)
            end
          end
          rec(1, {}, 0, 0, 0)
          if best then
            local ks = {} ; for _, D in ipairs(best) do ks[#ks + 1] = dkey(D[1], D[2]) end
            table.sort(ks)                  -- never pairs() order: the LuaJIT hash seed moves it
            add_move(best, "mult:" .. table.concat(ks, "+"))
          end
        end
        -- cheapest first, then AXIAL first so a face that can widen squarely is never charged for a
        -- diagonal detour, then the direction key -- a total order that never depends on hash order
        table.sort(moves, function(a, b)
          if a.cost ~= b.cost then return a.cost < b.cost end
          if a.pure ~= b.pure then return a.pure > b.pure end
          return a.key < b.key
        end)
        -- The growth is a deliberate greedy: each unit move is minimal and the axis is forced by
        -- which bound is short; `stall` exits after 8 moves that widen nothing.
        -- Un-crossing a curl is a targeted lengthening: grow one direction inside the crossing
        -- span (i+1..j from poly_simple) and cancel it with a zero-sum combination outside it, in
        -- both polarities. Exact opposites alone are a no-op when both lie inside the span.
        local function uncross_moves(ci, cj)
          local inD, outD, ks, os_, out = {}, {}, {}, {}, {}
          for i = 1, #E do
            local t = (i > ci and i <= cj) and inD or outD
            t[dkey(E[i].D[1], E[i].D[2])] = E[i].D
          end
          for k in pairs(inD) do ks[#ks + 1] = k end
          for k in pairs(outD) do os_[#os_ + 1] = k end
          table.sort(ks) ; table.sort(os_)  -- never pairs() order: the LuaJIT hash seed moves it
          local function gen(growKeys, growT, payKeys, payT, growInside)
            for _, k in ipairs(growKeys) do
              local D = growT[k]
              local tx, ty = -D[1], -D[2]
              for a = 1, #payKeys do
                local Fa = payT[payKeys[a]]
                local t
                if Fa[1] ~= 0 and tx % Fa[1] == 0 then t = tx / Fa[1]
                elseif Fa[1] == 0 and tx == 0 and Fa[2] ~= 0 then t = ty / Fa[2] end
                if t and t > 0 and t * Fa[1] == tx and t * Fa[2] == ty then
                  out[#out + 1] = { ds = { D, Fa }, mult = { 1, t }, cost = 1 + t,
                                    side = { growInside, not growInside } }
                end
                for b = a + 1, #payKeys do
                  local Fb = payT[payKeys[b]]
                  local det = Fa[1] * Fb[2] - Fa[2] * Fb[1]
                  if det ~= 0 then
                    local n1, n2 = tx * Fb[2] - ty * Fb[1], Fa[1] * ty - Fa[2] * tx
                    if n1 % det == 0 and n2 % det == 0 then
                      local t1, t2 = n1 / det, n2 / det
                      if t1 >= 0 and t2 >= 0 and (t1 + t2) > 0 then
                        out[#out + 1] = { ds = { D, Fa, Fb }, mult = { 1, t1, t2 },
                                          cost = 1 + t1 + t2,
                                          side = { growInside, not growInside, not growInside } }
                      end
                    end
                  end
                end
              end
            end
          end
          gen(ks, inD, os_, outD, true)
          gen(os_, outD, ks, inD, false)
          table.sort(out, function(x, y)
            if x.cost ~= y.cost then return x.cost < y.cost end
            return dkey(x.ds[1][1], x.ds[1][2]) < dkey(y.ds[1][1], y.ds[1][2])
          end)
          return out
        end
        local CAP, stall = elro.faceFitLenCap or 64, 0
        local simple, ci, cj = poly_simple(pts)
        local fit, sw, sh, cells = cap_fit(pts, wN, hN, C.need, MW, MH)
        fit = fit and simple
        local got = base
        while not fit and got - base < CAP and stall < 8 and #moves > 0 do
          -- a still-crossing curl: trial every candidate separation on a copy and keep the one
          -- that reduces the crossing count
          local umv
          if C.curl and not simple and ci then
            local base0 = poly_crossings(pts)
            local inSpan = function(i) return i > ci and i <= cj end
            local outSpan = function(i) return not (i > ci and i <= cj) end
            local bestC
            local cands2 = uncross_moves(ci, cj)
            for _, m in ipairs(cands2) do
              local L2 = {} ; for k, v in pairs(L) do L2[k] = v end
              local okT = true
              for i2, D in ipairs(m.ds) do
                for _ = 1, (m.mult and m.mult[i2] or 1) do
                  if not bump(E, L2, D, m.side[i2] and inSpan or outSpan) then okT = false end
                end
              end
              if okT then
                local ct, _, pt2 = measure(E, 1, L2)
                if ct then
                  local x2 = poly_crossings(pt2)
                  if x2 < base0 and (not bestC or x2 < bestC.x
                     or (x2 == bestC.x and m.cost < bestC.m.cost)) then
                    bestC = { x = x2, m = m, L = L2 }
                  end
                end
              end
            end
            if bestC then
              umv = bestC.m
              for k, v in pairs(bestC.L) do L[k] = v end
            end
          end
          if umv then
            got = got + umv.cost
            local cu, _, pu = measure(E, 1, L)
            if not cu then rec.selfint = true ; break end
            local su, ui, uj = poly_simple(pu)
            local fu, wu, hu, nu = cap_fit(pu, wN, hN, C.need, MW, MH)
            fit, sw, sh, cells, pts = (fu and su), wu, hu, nu, pu
            simple, ci, cj = su, ui, uj
          else
          -- grow the axis that is SHORT; if both bounds are met it is population that is missing, so
          -- grow the narrower axis -- a square buys the most interior per unit of boundary
          local want
          if sw < wN then want = 1 elseif sh < hN then want = 2
          else want = (sw <= sh) and 1 or 2 end
          -- flip the axis while stalled: a ring one cell thick has no interior to steer by
          if stall > 0 then want = 3 - want end
          -- among moves serving that axis take the currently shortest (spread rule), or an
          -- all-diagonal ring grows into a sliver
          local mv, mvw
          for _, P in ipairs(moves) do
            if (want == 1 and P.ax == 1) or (want == 2 and P.ay == 1) then
              local w = 0
              for i = 1, #E do
                local d = E[i].D
                for _, D in ipairs(P.ds) do
                  if d[1] == D[1] and d[2] == D[2] then w = w + L[E[i].k] ; break end
                end
              end
              w = w / #P.ds                      -- per direction, or a triple always looks longer
              if not mv or w < mvw then mv, mvw = P, w end
            end
          end
          mv = mv or moves[1]
          local okB = true
          for _, D in ipairs(mv.ds) do if not bump(E, L, D) then okB = false end end
          if not okB then break end
          got = got + mv.cost
          local c2, _, p2 = measure(E, 1, L)
          if not c2 then rec.selfint = true ; break end
          local s2 = poly_simple(p2)
          -- only a non-curl may bail here; a curl still crossing keeps paying
          if not s2 and not C.curl then rec.selfint = true ; break end
          local f2, w2, h2, n2 = cap_fit(p2, wN, hN, C.need, MW, MH)
          f2 = f2 and s2
          if w2 > sw or h2 > sh or n2 > cells or (s2 and not simple) then stall = 0
          else stall = stall + 1 end
          fit, sw, sh, cells, pts = f2, w2, h2, n2, p2
          simple = s2
          if not s2 then local _, a2, b2 = poly_simple(p2) ; ci, cj = a2, b2 end
          end
        end
        -- got is read back off the non-virtual edges, so growth landing on a virtual gap edge is
        -- not charged
        got = 0
        for i = 1, #E do if not E[i].virt then got = got + L[E[i].k] end end
        rec.base, rec.box, rec.cells = base, sw .. "x" .. sh, cells
        -- area is the second currency and separates better than length; no diagonal penalty
        local _, iFit = measure(E, 1, L) ; local _, iBase, pBase = measure(E, 1, L0)
        rec.area, rec.area0 = iFit, iBase
        -- measurement only: the ring at its base size in its own frame, for crossing-site distances
        rec.E, rec.L0, rec.pts0, rec.att = E, L0, pBase, C.att
        local grown, longest = 0, 0
        for i = 1, #E do
          local k = E[i].k
          if L[k] > L0[k] then grown = grown + 1 end
          if L[k] > longest then longest = L[k] end
        end
        rec.grown, rec.longest = grown, longest
        if fit then rec.got, rec.excess = got, got - base else rec.unfit = true end
      else rec.open = true end
      rep.faceCost[#rep.faceCost + 1] = rec
    end
    -- The verdict: a face or curl whose area saved per crossing clears TUNE.crossCostTau is
    -- licensed (its ring rooms published for the crossing gate); nothing is built here, and
    -- `cross_convert` stays demand-driven. A blocked face (no esc) never qualifies.
    -- crossing_site: `ves` = walls whose outward normal is maximally aligned (by cosine, not raw
    -- dot) with the attachment direction; `hes` = the maximal bridge run out of the attachment
    -- room. All maximal walls are licensed; the walk chooses among them.
    local function crossing_site(C)
      local A                                -- the dominant attachment: one site must free the load
      for _, a in ipairs(C.att or {}) do if not A or (a.n or 0) > (A.n or 0) then A = a end end
      if not A or not C.pts0 or not C.E then return nil end
      local ai ; for i = 1, #C.ring do if C.ring[i] == A.A then ai = i end end
      local AD = DELTA[A.d]
      if not ai or not AD then return nil end
      -- orientation from the ring's own signed area, so the outward normal is outward either way
      local A2 = 0
      for i = 1, #C.pts0 do
        local p, q = C.pts0[i], C.pts0[(i % #C.pts0) + 1]
        A2 = A2 + (p[1] * q[2] - q[1] * p[2])
      end
      local sgn = (A2 < 0) and -1 or 1
      local ves, best, need = {}, 0, nil
      local cosw, vpair = {}, nil
      for i = 1, math.min(#C.E, #C.ring) do
        local D = C.E[i].D
        local nx, ny = sgn * D[2], sgn * -D[1]
        local dot = nx * AD[1] + ny * AD[2]
        if dot > 0 then
          local c = dot / math.sqrt((nx * nx + ny * ny) * (AD[1] * AD[1] + AD[2] * AD[2]))
          cosw[i] = c ; if c > best then best = c end
        end
      end
      -- RULE 3: the crossing must be perpendicular, an axial wall cut by an axial bridge on the
      -- other axis (forced_cross is V x H only; a diagonal wall has no slack to give).
      -- RULE 4: nothing may be stacked against the far side of the wall (pendants in the outer
      -- face, which rawLoad cannot see).
      local axialB = (AD[1] == 0 or AD[2] == 0)
      for i = 1, math.min(#C.E, #C.ring) do
        local D = C.E[i].D
        local a, b = C.ring[i], C.ring[(i % #C.ring) + 1]
        local perp = axialB and (D[1] == 0 or D[2] == 0)
                     and (D[1] * AD[1] + D[2] * AD[2] == 0)     -- and not parallel to the bridge
        local blocked = false
        for _, w in ipairs({ a, b }) do
          for _, p in ipairs(pendAt[w] or {}) do
            if p.face ~= C.fi then blocked = true end
          end
        end
        -- RULE 4 is disabled below: pendAt's face can disagree with C.att (a room read as both
        -- inward and stacked outside); the real fix is to make them agree
        blocked = false
        if cosw[i] and (not perp or blocked) then cosw[i] = nil end
      end
      best = 0
      for i = 1, math.min(#C.E, #C.ring) do
        if cosw[i] and cosw[i] > best then best = cosw[i] end
      end
      for i = 1, math.min(#C.E, #C.ring) do
        if cosw[i] and cosw[i] > best - 1e-9 then
          local ek = ekey(C.ring[i], C.ring[(i % #C.ring) + 1])
          ves[#ves + 1] = ek
          vpair = vpair or { C.ring[i], C.ring[(i % #C.ring) + 1] }
          -- how far the escaping edge must reach: the attachment's depth inside the wall on the
          -- base ring, plus one; overshooting is the safe direction
          local D = C.E[i].D
          local nx, ny = sgn * D[2], sgn * -D[1]
          local P, Q = C.pts0[ai], C.pts0[i]
          local side = (P[1] - Q[1]) * nx + (P[2] - Q[2]) * ny
          local rate = AD[1] * nx + AD[2] * ny
          if rate > 0 then
            local t = math.floor(-side / rate) + 1
            if t >= 1 and (not need or t < need) then need = t end
          end
        end
      end
      -- the bridge run out of the attachment room: walk while the next room is a plain degree-2 link
      local hes, u, v, hpair = {}, A.A, nil, nil
      for _, e in ipairs(rot[A.A] or {}) do if e.d == A.d then v = e.v end end
      while v do
        hes[#hes + 1] = ekey(u, v)
        hpair = hpair or { u, v }
        if #(rot[v] or {}) ~= 2 then break end
        local w ; for _, e in ipairs(rot[v] or {}) do if e.v ~= u then w = e.v end end
        if not w then break end
        u, v = v, w
      end
      if #ves == 0 or #hes == 0 or not vpair or not hpair then return nil end
      return { ves = ves, hes = hes, minLen = need, A = A.A,
               q = { vpair[1], vpair[2], hpair[1], hpair[2] },
               share = (A.n or 0) / math.max(C.need, 1) }
    end
    -- the shadow solves, keyed by the face they belong to: this ring holding everything ONE crossing
    -- does not release. A shadow that did not fit publishes nothing, and the face falls back to
    -- `area0` -- the optimistic floor, flagged below rather than silently believed.
    local shadowArea = {}
    for _, C in ipairs(rep.faceCost) do
      if C.shadow and C.area then shadowArea[C.shadow] = C.area end
    end
    local tau = TUNE.crossCostTau
    -- scored always; licensed only at tau > 0
    for _, C in ipairs(rep.faceCost) do
      -- A shadow is a measurement of its parent, never a candidate. Plain `if`, not goto: the
      -- game runs stock Lua 5.1, no 5.2 syntax anywhere in this file.
      if not C.shadow then
        C.site = (not C.curl) and crossing_site(C) or nil
        -- share: fraction of the load carried by the biggest attachment (diagnostic only)
        C.share = C.curl and 1 or (C.site and C.site.share) or 0
        -- post-crossing size is the re-priced shadow ring when one exists, else area0
        C.floor = shadowArea[C.fi] or C.area0 or 0
        C.gain = ((C.area or 0) - C.floor) / math.max(C.esc or 99, 1)
        -- RULE 1: a face with more than one inward structure is not a candidate
        C.multi = #(C.att or {}) > 1
        -- unless the dominant attachment carries at least crossDomShare of the load
        if C.multi and TUNE.crossDomShare > 0 then
          local share = TUNE.crossDomShare
          local best, tot = 0, 0
          for _, a in ipairs(C.att or {}) do
            tot = tot + (a.n or 0) ; if (a.n or 0) > best then best = a.n end
          end
          if tot > 0 and best / tot >= share then C.multi = false end
        end
        -- RULE 2 arrives as esc == nil; no site (or pair for a curl) means no verdict
        if C.excess and not C.multi and C.esc and (C.site or C.pair)
           and tau > 0 and C.gain >= tau then
          C.wanted = true
          -- the same rails as a curl's named pair, but a SET on each side rather than one edge
          if C.site then
            local Q = elro._crossQuartets or {} ; elro._crossQuartets = Q
            -- The quartet is a representative pair; the site sets are the licence.
            -- block_needs_cross needs one concrete pair; the acceptance set is ves x hes.
            Q[#Q + 1] = { C.site.q[1], C.site.q[2], C.site.q[3], C.site.q[4],
                          ves = C.site.ves, hes = C.site.hes, ring = C.ring }
            if C.site.minLen and C.site.minLen > 1 then
              local ML = elro.minLen or {} ; elro.minLen = ML ; elro._minLenOwn = true
              local k = C.site.hes[1]
              if (ML[k] or 1) < C.site.minLen then ML[k] = C.site.minLen end
            end
            elro._wireMemo = nil
          end
          -- Plug the verdict into the wire-crossing framework: block_needs_cross tests
          -- quartet containment, and compose_spqr roots the walk at the south end of the
          -- widest wire pair so it climbs toward the crossing.
          if C.pair then
            local Q = elro._crossQuartets or {} ; elro._crossQuartets = Q
            Q[#Q + 1] = { C.pair[1], C.pair[2], C.pair[3], C.pair[4], ring = C.ring }
            -- Minimum length 2 on the two crossing edges is structural (a unit-length window lands
            -- its last room on its first). Publishes into elro.minLen; take the MAX, never overwrite.
            local ML = elro.minLen or {} ; elro.minLen = ML ; elro._minLenOwn = true
            for _, e in ipairs({ { C.pair[1], C.pair[2] }, { C.pair[3], C.pair[4] } }) do
              local a, b = e[1], e[2]
              local k = ekey(a, b)
              if (ML[k] or 1) < 2 then ML[k] = 2 end
            end
            -- bust the wire cache: wire_cross memoises on table identity
            elro._wireMemo = nil
          end
        end
      end                                     -- if not C.shadow
    end
    -- worst first; ties by face index so the order never depends on the LuaJIT hash seed
    table.sort(rep.faceCost, function(a, b)
      local x, y = a.excess or -1, b.excess or -1
      if x ~= y then return x > y end
      return a.fi < b.fi
    end)
  end
  return minLen, rep
end
-- elro.facefit_report (mapfacefit) drives the crossing-cost census (TUNE.crossCostTau).
function elro.facefit_report()
  local rooms, adj, label = elro.sel_or_area()
  if not rooms then
    cecho("\n<red>[elro]: select rooms or set 'mapcur <id>' first.\n<reset>") return
  end
  local ml, rep = elro.facefit(rooms, elro.walk_adj(adj))
  cecho(string.format("\n<cyan>[facefit] %s: %d rooms, 2-core %d, %d face(s) (%d bounded, %d open,"
    .. " %d self-crossing), %d pendant tree(s), %d assigned inward%s<reset>",
    label, rep.rooms, rep.core, rep.faces, rep.bounded, rep.open, rep.selfint or 0, rep.pend,
    rep.assigned, (rep.diverged and "; SIZING DIVERGED -- nothing published" or "")
      .. ((rep.capped or 0) > 0 and ("; " .. rep.capped .. " edge(s) CAPPED at faceFitCap") or "")))
  -- the cost census, sorted worst first
  if not elro.crossCost then
    cecho("\n<grey>  cost: not measured -- `lua elro.crossCost = true` to price every face that"
      .. " contains something (measurement only, publishes nothing)<reset>")
  elseif #(rep.faceCost or {}) == 0 then
    cecho("\n<grey>  cost: no face contains anything -- nothing for a crossing to buy<reset>")
  else
    if (rep.forced or 0) > 0 then
      cecho(string.format("\n<yellow>  cost: ⚠ this area ALREADY has %d forced crossing witness(es)"
        .. " -- block_needs_cross can fire here on its own, so these savings are largely ALREADY"
        .. " BANKED, not available. This pass is for PLANAR areas.<reset>", rep.forced))
    end
    -- SCORE = (area holding the load - area after the crossing) / escape crossings,
    -- where "after" is `base` for a single-structure face and the re-priced ring (the
    -- `shadow` solve) when the face keeps something. Judged against TUNE.crossCostTau.
    cecho(string.format("\n<grey>  cost: SCORE = (area with load - area after) / escape crossings,"
      .. " judged against crossCostTau = %s<reset>", tostring(TUNE.crossCostTau)))
    for _, C in ipairs(rep.faceCost) do
      -- why this face is or is not taken, in the order the gate applies it
      local verdict, vcol
      if C.shadow then verdict, vcol = "(re-price of face " .. C.shadow .. ")", "grey"
      elseif C.open or C.unfit then verdict, vcol = "NOT MEASURABLE", "grey"
      elseif C.multi then
        verdict, vcol = string.format("RULE 1: %d inward structures -- one crossing frees only one",
          #(C.att or {})), "red"
      elseif not C.esc then
        verdict, vcol = "BLOCKED: no way out that misses a loaded face (RULE 2)", "red"
      elseif not (C.site or C.pair) then
        verdict, vcol = "NO CLEAN SITE: every candidate wall is diagonal (RULE 3) or has rooms"
          .. " stacked against its far side (RULE 4)", "red"
      elseif C.wanted then verdict, vcol = "** WANTED **", "yellow"
      elseif TUNE.crossCostTau <= 0 then
        verdict, vcol = "measure only (tau = 0)", "grey"
      else verdict, vcol = string.format("below tau (%s)",
        tostring(TUNE.crossCostTau)), "grey"
      end
      cecho(string.format("\n<%s>  cost: face %-5s %-11s SCORE %7.1f   %s<reset>", vcol,
        tostring(C.fi), C.r, C.gain or ((C.area or 0) - (C.area0 or 0)) / math.max(C.esc or 99, 1),
        verdict))
      local what = C.open and "ring does NOT close -- not measurable"
        or (C.unfit and string.format("NO FIT within +%d (best box %s%s)", elro.faceFitLenCap or 64,
              C.box or "?", C.selfint and ", ring self-crossed while growing" or ""))
        -- Ring geometry only; the header carries the score and verdict. excess = got - base
        -- is the SAVING a crossing buys (base = ring closed at unit with no containment
        -- requirement; got = the ring forced to hold its load); the per-edge ratios are
        -- diagnostics only. ESCAPE is the dual distance to open space.
        or string.format("%d edges holding %d (needs %dx%d): length %d->%d (+%d), area %d->%d;"
             .. " %d wall(s) grew, longest %d, %.2f/edge",
             C.n, C.need, C.w or 0, C.h or 0, C.base, C.got, C.excess,
             C.area0 or 0, C.area or 0, C.grown or 0, C.longest or 0, C.excess / C.n)
      cecho(string.format("\n<grey>        ring:  %s<reset>", what))
      -- `share` = fraction of the load the biggest single attachment carries; only that
      -- fraction of the saving is collectable through one wall.
      if not C.shadow and not C.open and not C.unfit then
        cecho(string.format("\n<grey>        score: area %d holding %d, area %d after%s = %d saved,"
          .. " over %s = %.1f<reset>",
          C.area or 0, C.need, C.floor or 0,
          ((C.floor or 0) > (C.area0 or 0))
            and string.format(" (a RE-PRICE still holding %d, not the empty ring at %d)",
                  C.need - math.floor((C.share or 0) * C.need + 0.5), C.area0 or 0) or "",
          (C.area or 0) - (C.floor or 0),
          C.esc and (C.esc .. " crossing(s)") or "NO route out", C.gain or 0))
      end
      if C.site then
        cecho(string.format("\n<%s>        site: %d wall(s) %s  x  %d bridge(s) %s"
          .. "   [%.0f%% of the load off %d%s]<reset>",
          C.wanted and "yellow" or "grey", #C.site.ves, table.concat(C.site.ves, " "),
          #C.site.hes, table.concat(C.site.hes, " "), 100 * (C.share or 0), C.site.A,
          C.site.minLen and (", min_len " .. C.site.minLen) or ""))
      elseif C.pair then
        -- a curl names its pair from the turning window, not an attachment, so it has
        -- no `site`; print it anyway
        cecho(string.format("\n<%s>        site: %d:%d x %d:%d (turning window, self-crossing --"
          .. " the pocket is released on the spot, escape 1)<reset>",
          C.wanted and "yellow" or "grey", C.pair[1], C.pair[2], C.pair[3], C.pair[4]))
      end
    end
  end
  local nTight = 0
  for fi, f in ipairs(rep.rings or {}) do
    local L, tot = {}, 0
    for i = 1, math.min(#f, 12) do L[#L + 1] = f[i] end
    if #f > 12 then L[#L + 1] = "..." end
    for i = 1, #f do
      local a, b = f[i], f[(i % #f) + 1]
      tot = tot + ((rep.len or {})[(ekey(a, b))] or 1)
    end
    if tot == #f then nTight = nTight + 1 end
    cecho(string.format("\n<yellow>  face %-2d  %2d edges  closed length %-3d%s  holds %-3d  %s<reset>",
      fi, #f, tot, (tot > #f) and " (cannot close at unit)" or "",
      (rep.load or {})[fi] or 0, table.concat(L, "-")))
  end
  -- A ring that cannot close at unit lengths means inconsistent exits OR a sub-cycle
  -- that is not really a face (split_face cuts sub-cycles from a trace that bailed on
  -- an asymmetric exit) -- not a verdict on the exits alone.
  if #(rep.rings or {}) > 0 and nTight < #rep.rings then
    cecho(string.format("\n<cyan>  %d of %d bounded ring(s) cannot close at unit lengths"
      .. " -- inconsistent exits, or a sub-cycle that is not really a face<reset>",
      #rep.rings - nTight, #rep.rings))
  end
  for _, p in ipairs(rep.pendants or {}) do
    cecho(string.format("\n<%s>  pendant %3d room(s)  hangs %-9s off %-6d  -> %s<reset>",
      p.face and "green" or "grey", p.n, tostring(p.d), p.A,
      p.face and ("face " .. p.face) or "OUTER face (not enclosed)"))
  end
  for _, L in ipairs(rep.loads or {}) do
    cecho(string.format(
      "\n<%s>  %s %s  %d edges, holds %d, Pick I=%d, closed length %d -> %d  %s<reset>",
      L.outer and "yellow" or "cyan", L.outer and "OUTER:" or "sized:", L.r, L.n, L.need, L.I,
      L.base, L.got,
      L.outer and ("EXCESS +" .. (L.got - L.base) .. " -- what planarity costs this area")
        or ((L.left > 0) and (L.left .. " room(s) LEFTOVER -- did not fit") or "every room placed")))
  end
  local mls = {}
  for k, v in pairs(ml or {}) do mls[#mls + 1] = { k = k, v = v } end
  table.sort(mls, function(a, b) if a.v ~= b.v then return a.v > b.v end return a.k < b.k end)
  for i = 1, math.min(#mls, 24) do
    cecho(string.format("\n<green>  minLen %-14s %d<reset>", mls[i].k, mls[i].v))
  end
  local nml = 0 ; for _ in pairs(ml or {}) do nml = nml + 1 end
  cecho(string.format("\n<cyan>  %d edge minimum(s) would be published%s<reset>\n", nml,
    ""))
end

-- Is class `ca` provably strictly less than `cb` on this axis? Reachability in the order DAG,
-- memoised per source class in `A.reach`. Arguments are class reps (`A.find(room)`). Module
-- scope so wire_cross and the place_room order clamp share ONE implementation.
function elro.wire_lt(A, ca, cb)
  if ca == cb then return false end
  local s = A.reach[ca]
  if not s then
    s = {}
    local stack = {}
    for x in pairs(A.succ[ca] or {}) do stack[#stack + 1] = x end
    while #stack > 0 do
      local x = table.remove(stack)
      if not s[x] then s[x] = true
        for y in pairs(A.succ[x] or {}) do if not s[y] then stack[#stack + 1] = y end end
      end
    end
    A.reach[ca] = s
  end
  return s[cb] == true
end

function elro.wire_cross(adj)
  -- Memoised on the adj table identity, not one slot: distinct adjacency tables alternate here
  -- and a single-slot cache thrashes.
  local memo = elro._wireMemo
  if not memo then memo = setmetatable({}, { __mode = "k" }) ; elro._wireMemo = memo end
  local hit = memo[adj] ; if hit then return hit end
  local W = { O = {}, pair = {}, pairIdx = {}, n = 0, min = 0, quartet = {}, wires = {},
              cycles = 0, cycleAxis = nil, sameClassArcs = 0, badArcs = {} }
  memo[adj] = W
  local dlt = elro.delta

  -- (1) Per axis: equality classes (union-find over edges that do not move on this axis) and
  -- strict-order arcs between classes, kept in both directions -- the backward table answers
  -- "strictly inside that wire's span" with one BFS per side.
  for axis = 1, 2 do
    local p = {}
    local function find(a)
      if p[a] == nil then p[a] = a end
      while p[a] ~= a do p[a] = p[p[a]] ; a = p[a] end
      return a
    end
    for r, nb in pairs(adj) do
      find(r)
      for d, v in pairs(nb) do
        local de = dlt[d]
        if de and adj[v] and (de[1] ~= 0 or de[2] ~= 0) and de[axis] == 0 then
          local ra, rb = find(r), find(v) ; if ra ~= rb then p[ra] = rb end
        end
      end
    end
    local succ, pred, seen = {}, {}, {}
    for r, nb in pairs(adj) do
      for d, v in pairs(nb) do
        local de = dlt[d]
        -- `v ~= r` skips self-loops here, not in tier 0(b) below: self-loops never enter the
        -- layout graph, so reporting one as infeasible would be a permanent false alarm.
        if de and adj[v] and v ~= r and (de[1] ~= 0 or de[2] ~= 0) and de[axis] ~= 0 then
          local a, b
          if de[axis] > 0 then a, b = find(r), find(v) else a, b = find(v), find(r) end
          if a ~= b then
            succ[a] = succ[a] or {} ; succ[a][b] = true
            pred[b] = pred[b] or {} ; pred[b][a] = true
          else
            -- Tier 0(b): a strict order demanded between rooms locked to one class means no
            -- truthful drawing exists (a forced lie, not a crossing). Counted per canonical
            -- pair, since a symmetric adj presents every edge twice. Reported only.
            local k = ekey(r, v)
            if not seen[k] then
              seen[k] = true
              W.sameClassArcs = W.sameClassArcs + 1
              if #W.badArcs < 8 then
                W.badArcs[#W.badArcs + 1] = string.format("%d-%s->%d (axis %d)", r, d, v, axis)
              end
            end
          end
        end
      end
    end
    -- field names match eqw_order's so the two can be folded together later without churn
    W.O[axis] = { find = find, succ = succ, pred = pred, reach = {} }
  end

  -- (2) Tier 0(a): a cycle in an axis order DAG means no truthful drawing exists. Kahn: any
  -- class left with non-zero in-degree is on or downstream of a cycle.
  for axis = 1, 2 do
    local A = W.O[axis]
    local indeg, nn = {}, 0
    for a, s in pairs(A.succ) do
      if indeg[a] == nil then indeg[a] = 0 ; nn = nn + 1 end
      for b in pairs(s) do
        if indeg[b] == nil then indeg[b] = 1 ; nn = nn + 1 else indeg[b] = indeg[b] + 1 end
      end
    end
    local q, done = {}, 0
    for a, d in pairs(indeg) do if d == 0 then q[#q + 1] = a end end
    while #q > 0 do
      local a = table.remove(q) ; done = done + 1
      for b in pairs(A.succ[a] or {}) do
        indeg[b] = indeg[b] - 1
        if indeg[b] == 0 then q[#q + 1] = b end
      end
    end
    if done < nn then
      W.cycles = W.cycles + (nn - done)
      W.cycleAxis = W.cycleAxis or axis
    end
  end

  -- (3) strict reachability. `lt` is the single-class form; `reach_set` the set form -- one BFS
  -- seeded from every class of a wire at once, O(E) per wire instead of per room.
  local lt = elro.wire_lt          -- ONE implementation, shared with the place_room order clamp
  local function reach_set(tbl, seeds)
    local s, stack = {}, {}
    for k in pairs(seeds) do for x in pairs(tbl[k] or {}) do stack[#stack + 1] = x end end
    while #stack > 0 do
      local x = table.remove(stack)
      if not s[x] then s[x] = true
        for y in pairs(tbl[x] or {}) do if not s[y] then stack[#stack + 1] = y end end
      end
    end
    return s
  end

  -- (4) The wires. A single-room class spans nothing and is not a wire. `inside[axis][c]` = the
  -- classes on the other axis provably strictly within class c's span.
  local mem = { {}, {} }
  for r in pairs(adj) do
    for axis = 1, 2 do
      local c = W.O[axis].find(r)
      local m = mem[axis][c] ; if m then m[#m + 1] = r else mem[axis][c] = { r } end
    end
  end
  local inside = { {}, {} }
  for axis = 1, 2 do
    local other = 3 - axis
    local A = W.O[other]
    for c, ms in pairs(mem[axis]) do
      if #ms >= 2 then
        local seeds = {}
        for i = 1, #ms do seeds[A.find(ms[i])] = true end
        local fwd, bwd = reach_set(A.succ, seeds), reach_set(A.pred, seeds)
        local ins, any = {}, false
        for k in pairs(fwd) do if bwd[k] then ins[k] = true ; any = true end end
        if any then inside[axis][c] = ins end
      end
    end
  end

  -- (5) The pairs. Iterating the small `inside` sets keeps this O(sum |inside|), not O(classes^2).
  for cv, insY in pairs(inside[1]) do            -- cv = a COLUMN class = a vertical wire
    local vm = mem[1][cv]
    local vset = {}                              -- hoisted: invariant across the ch loop
    for i = 1, #vm do vset[vm[i]] = true end
    for ch in pairs(insY) do                     -- ch = a row class strictly inside cv's row span
      local insX = inside[2][ch]
      if insX and insX[cv] then
        -- Disjoint room sets: a shared room satisfies the meeting legitimately (which is what
        -- stops plain grids and diagonal quads from proving anything).
        local hm = mem[2][ch]
        local share = false
        for i = 1, #hm do if vset[hm[i]] then share = true ; break end end
        if not share then
          -- The witness: one member of each wire on each side of the meeting point -- the
          -- quartet block_needs_cross tests for containment. Take the TIGHTEST bracket
          -- (DAG-maximal among those proved below, DAG-minimal among those proved above): it is
          -- the right walk root and likelier to lie wholly inside one block. Ties break by
          -- lowest room id, never by iteration order (hash-seed dependent).
          local O1, O2 = W.O[1], W.O[2]
          local function tightest(ms, A, target, below)
            local cand = {}
            for i = 1, #ms do
              local c = A.find(ms[i])
              if below and lt(A, c, target) or not below and lt(A, target, c) then
                cand[#cand + 1] = ms[i]
              end
            end
            local best
            for _, r in ipairs(cand) do
              local outer = false        -- is some other candidate strictly INSIDE r's side?
              for _, q in ipairs(cand) do
                if q ~= r then
                  local a, b = A.find(r), A.find(q)
                  if below and lt(A, a, b) or not below and lt(A, b, a) then outer = true ; break end
                end
              end
              if not outer and (best == nil or r < best) then best = r end
            end
            return best
          end
          local S  = tightest(vm, O2, ch, true)
          local N  = tightest(vm, O2, ch, false)
          local Wr = tightest(hm, O1, cv, true)
          local Er = tightest(hm, O1, cv, false)
          -- The site: the crossing must be between an internal edge of V spanning row `ch` and
          -- one of H spanning column `cv`; where a wire is non-monotone fall back to all its
          -- internal edges. `de[sameAxis] == 0` is not redundant with the class test: dropping
          -- it leaks a diagonal, and this prover must never be able to name a diagonal x
          -- diagonal grid-X (that is a free crossing).
          local function span_edges(ms, sameAxis, spanAxis, target)
            local es, n = {}, 0
            local Asame, Aspan = W.O[sameAxis], W.O[spanAxis]
            local function internal(u, v, de)
              return de and adj[v] and de[sameAxis] == 0 and de[spanAxis] ~= 0
                     and Asame.find(v) == Asame.find(u)
            end
            for i = 1, #ms do
              local u = ms[i]
              for d, v in each_exit(adj[u]) do
                if internal(u, v, dlt[d]) then
                  local a, b = Aspan.find(u), Aspan.find(v)
                  if lt(Aspan, a, target) and lt(Aspan, target, b)
                     or lt(Aspan, b, target) and lt(Aspan, target, a) then
                    local k = ekey(u, v) ; if not es[k] then es[k] = true ; n = n + 1 end
                  end
                end
              end
            end
            if n == 0 then
              -- Undetermined: no single edge provably brackets the target, so every internal
              -- edge is a candidate -- except an edge with both endpoints proved on the same
              -- side of the target, which cannot span it.
              for i = 1, #ms do
                local u = ms[i]
                for d, v in each_exit(adj[u]) do
                  if internal(u, v, dlt[d]) then
                    local a, b = Aspan.find(u), Aspan.find(v)
                    local bothLo = lt(Aspan, a, target) and lt(Aspan, b, target)
                    local bothHi = lt(Aspan, target, a) and lt(Aspan, target, b)
                    if not bothLo and not bothHi then
                      local k = ekey(u, v) ; if not es[k] then es[k] = true ; n = n + 1 end
                    end
                  end
                end
              end
            end
            return es, n
          end
          local ves, vn = span_edges(vm, 1, 2, ch)   -- V: one column class, spans ROWS
          local hes, hn = span_edges(hm, 2, 1, cv)   -- H: one row class,    spans COLUMNS
          if vn > 0 and hn > 0 then
            W.n = W.n + 1
            W.min = W.n
            W.wires[W.n] = { cv = cv, ch = ch, vm = vm, hm = hm, ves = ves, hes = hes,
                             S = S, N = N, W = Wr, E = Er, vn = vn, hn = hn }
            if S and N and Wr and Er then W.quartet[#W.quartet + 1] = { S, N, Wr, Er } end
            -- `pairIdx` maps each key back to its forced pair, not just a boolean: the site is
            -- a range so the cross product holds many keys while the proof licenses exactly ONE
            -- meeting -- the caller must reach the pair to budget it.
            for k1 in pairs(ves) do
              for k2 in pairs(hes) do
                local k = crosspair(k1, k2)
                W.pair[k] = true ; W.pairIdx[k] = W.n
              end
            end
          end
        end
      end
    end
  end
  -- Synthetic quartets from the cost pass ("a crossing is CHEAPER"), carried on the same rails
  -- as the forced pairs. Must run AFTER the pair loop: proven pairs are stored at `W.wires[W.n]`
  -- where W.n is not #W.wires, so injecting first gets silently overwritten. W.n is left alone
  -- (it counts PROVEN pairs and gates the site budget and min-crossing bound); only `quartet`
  -- and `wires` grow. Every appended entry must carry vn/hn: the diagnostic formats them with %d.
  if elro._crossQuartets then
    for _, q in ipairs(elro._crossQuartets) do
      local S = q[1]
      for i = 2, 4 do if q[i] < S then S = q[i] end end
      -- the two EDGES the turning window named, in the prover's own key form
      local e1, e2 = ekey(q[1], q[2]), ekey(q[3], q[4])
      -- A curl names one edge per side; a FACE publishes q.ves/q.hes as sets, and every
      -- combination must be legal -- the used site is decided by the ring's drawn shape.
      local ves, hes = {}, {}
      for _, k in ipairs(q.ves or { e1 }) do ves[k] = true end
      for _, k in ipairs(q.hes or { e2 }) do hes[k] = true end
      local vn, hn = 0, 0
      for _ in pairs(ves) do vn = vn + 1 end
      for _ in pairs(hes) do hn = hn + 1 end
      W.quartet[#W.quartet + 1] = { q[1], q[2], q[3], q[4], cost = true }
      W.wires[#W.wires + 1] = { S = S, vm = q.ring or {}, hm = {}, ves = ves, hes = hes,
                                vn = vn, hn = hn, cost = true }
      -- Registering the pair makes the walk ACCEPT the crossing (`W.pair` is the acceptance
      -- set). The keys also go on their own set `CK`: the lever-ranking exemption must apply to
      -- COST pairs only, never to the proven pairs that share `W.pair`.
      local CK = elro._crossPairKeys or {} ; elro._crossPairKeys = CK
      for k1 in pairs(ves) do
        for k2 in pairs(hes) do
          local ck = crosspair(k1, k2)
          W.pair[ck] = true ; W.pairIdx[ck] = #W.wires
          CK[ck] = true
        end
      end
    end
  end
  -- Publish what the build found, separately from what the walk went on to use.
  elro._wcPairs, elro._wcMin, elro._wcRan = W.n, W.min, true
  elro._wcCycles, elro._wcArcs = W.cycles, W.sameClassArcs
  if elro.debug or W.n > 0 or W.cycles > 0 or W.sameClassArcs > 0 then
    elro.tr(string.format("wire crossings: %d forced pair(s), min crossings >= %d"
      .. " | infeasible: %d cycle-class(es), %d same-class order arc(s)",
      W.n, W.min, W.cycles, W.sameClassArcs))
    for _, p in ipairs(W.wires) do
      -- A cost pair has no witness roles or site sets; it must print through its own format.
      if p.cost then
        elro.tr(string.format("  cost pair (crossCostTau): seed %s, ring of %d room(s)"
          .. " -- a crossing is CHEAPER here, not forced", tostring(p.S), #(p.vm or {})))
      else
        elro.tr(string.format("  wire pair: column of %d x row of %d -- witness %s/%s x %s/%s,"
          .. " %d v-site(s) x %d h-site(s)", #p.vm, #p.hm, tostring(p.S), tostring(p.N),
          tostring(p.W), tostring(p.E), p.vn, p.hn))
      end
    end
    for _, b in ipairs(W.badArcs) do
      elro.tr("  UNSATISFIABLE: strict order demanded inside one equality class: " .. b)
    end
  end
  return W
end

-- Budget for one forced wire pair: the proof licenses ONE meeting, but wire_cross registers the
-- whole ves x hes cross product. Among the pair's legal sites actually crossing in the given
-- geometry, exactly the lexicographically smallest is free; the rest stay reported defects.
-- Stateless on purpose -- a pure function of `coord`: a counter would be captured by trial
-- geometry, survive reverts, and depend on hash-order visit order. A pair genuinely needing two
-- meetings has its second refused (the safe direction to be wrong in).
-- Returns the winning combined key, or nil when no legal site is currently crossing.
function elro.wire_site_min(p, coord)
  local best = nil
  for vk in pairs(p.ves) do
    local vu, vv = vk:match("^(%d+):(%d+)$")
    local a, b = coord[tonumber(vu)], coord[tonumber(vv)]
    if a and b then
      for hk in pairs(p.hes) do
        local k = crosspair(vk, hk)
        if best == nil or k < best then
          local hu, hv = hk:match("^(%d+):(%d+)$")
          local c, d = coord[tonumber(hu)], coord[tonumber(hv)]
          -- a shared endpoint means the wires meet AT A ROOM, which is not a crossing at all
          if c and d and vu ~= hu and vu ~= hv and vv ~= hu and vv ~= hv then
            local d1 = ori(c[1], c[2], d[1], d[2], a[1], a[2])
            local d2 = ori(c[1], c[2], d[1], d[2], b[1], b[2])
            if (d1 > 0) ~= (d2 > 0) then
              local d3 = ori(a[1], a[2], b[1], b[2], c[1], c[2])
              local d4 = ori(a[1], a[2], b[1], b[2], d[1], d[2])
              if (d3 > 0) ~= (d4 > 0) then best = k end
            end
          end
        end
      end
    end
  end
  return best
end

  -- Decide the crossings before any coordinate exists: does a crossing-free drawing exist at
  -- all? A property of the graph, built once per walk. The compass exits fix a rotation system:
  --   1 planarise the permitted grid-X (two 45-degree diagonals crossing is a free connection),
  --   2 strip to the 2-core (a pendant's 180-degree reversal makes a face's turn sign meaningless),
  --   3 Euler per component: genus 0 => a crossing-free drawing exists => accept nothing here,
  --   4 per-face turn total: +-360 closes as a simple curve, anything else must self-cross,
  --   5 in such a face, two bridges whose ring attachments interleave cannot both be drawn on
  --     one side, so a crossing between that pair is the price.
  -- Not a proof that THIS pair must cross (interleaving says one of the two must give), so
  -- accepting risks tolerating an avoidable crossing; that trade is deliberate -- a crossing is
  -- the least severe defect. `elro.topo_cross = false` restores the old behaviour.
  -- Deliberately local: a bridge at least as big as its own ring is the rest of the map, and
  -- pairs involving one are dropped.
function elro.topo_cross(adj, parallel_pair)
    -- Memoised on the adj table identity; a one-slot cache thrashes between graphs.
    local tmemo = elro._topoMemo
    if not tmemo then tmemo = setmetatable({}, { __mode = "k" }) ; elro._topoMemo = tmemo end
    local topoCache = tmemo[adj]
    if topoCache then return topoCache end
    -- `quartet` = the four rooms of each accepted pair (the two edges that must cross); the
    -- skeleton order lays these first so the crossing is established in open space.
    topoCache = { pair = {}, n = 0, faces = 0, genus = 0, quartet = {},
                  site = {}, nsite = 0, siteList = {} }
    local T = topoCache
    -- Stored BEFORE the analysis runs so the two cheap early returns below are cached too;
    -- otherwise planar areas recompute the whole analysis on every call.
    tmemo[adj] = topoCache
    local dlt = elro.delta
    -- (1) a working copy of the symmetrised adjacency, compass edges only
    local padj, ids = {}, {}
    for u, nb in pairs(adj) do
      local t = {}
      for d, v in pairs(nb) do
        local de = dlt[d]
        if de and adj[v] and (de[1] ~= 0 or de[2] ~= 0) then t[d] = v end
      end
      padj[u] = t ; ids[#ids + 1] = u
    end
    table.sort(ids)
    -- Two-way edges only, decided here and not at the caller: walk_branches hands in a symmetric
    -- adj but compose_spqr's is the raw directed adjacency, and the two must agree about the same map.
    for _, u in ipairs(ids) do
      for d, v in each_exit(padj[u]) do
        if padj[v] then
          local back = false
          for _, w in each_exit(padj[v]) do if w == u then back = true ; break end end
          -- A one-way exit contributes no cycle to the census (dropped, not given a fabricated
          -- reverse): a merge seam glued gurk's annulus and mael's core into one block whose
          -- faces were not simple, so nothing claimed the annulus. elro.faces applies the same rule.
          if not back then padj[u][d] = nil end
        end
      end
    end
    local function dirOf(u, v) for d, w in each_exit(padj[u]) do if w == v then return d end end end
    local function isD(d) local de = dlt[d] ; return de and de[1] ~= 0 and de[2] ~= 0 end
    -- (1) permitted grid-X: an axial 4-cycle a-b-c-d carrying both diagonals. Enumerated over
    -- common neighbours -- O(E * deg^2), not O(V^3).
    local dummies, nd = {}, 0
    do
      local seenq = {}
      for _, a in ipairs(ids) do
        for d1, c in each_exit(padj[a]) do
          if isD(d1) and padj[c] then
            local axial = {}
            for d2, b in each_exit(padj[a]) do
              if not isD(d2) then
                local dbc = dirOf(b, c)
                if dbc and not isD(dbc) then axial[#axial + 1] = b end
              end
            end
            for i = 1, #axial do
              for j = 1, #axial do
                if i ~= j then
                  local b, dd = axial[i], axial[j]
                  local dbd = dirOf(b, dd)
                  if dbd and isD(dbd) then
                    local q = { a, b, c, dd } ; table.sort(q)
                    local k = table.concat(q, ",")
                    if not seenq[k] then
                      seenq[k] = true
                      nd = nd + 1
                      local X = -nd                    -- dummy ids are negative: never a room id
                      padj[X] = {} ; dummies[X] = true ; ids[#ids + 1] = X
                      local function relink(u, w)      -- u -dir-> w  becomes  u -dir-> X -dir-> w
                        local dv = dirOf(u, w) ; if not dv then return end
                        local rv = elro.reverse[dv] ; if not rv then return end
                        padj[u][dv] = X ; padj[X][rv] = u
                        padj[X][dv] = w ; padj[w][rv] = X
                      end
                      relink(a, c) ; relink(b, dd)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    -- (2) 2-core
    local core, alive = {}, {}
    for _, u in ipairs(ids) do alive[u] = true end
    local changed = true
    while changed do
      changed = false
      for _, u in ipairs(ids) do
        if alive[u] then
          local n = 0
          for _, v in each_exit(padj[u]) do if alive[v] then n = n + 1 end end
          if n <= 1 then alive[u] = false ; changed = true end
        end
      end
    end
    local nCore = 0
    for _, u in ipairs(ids) do if alive[u] then core[u] = true ; nCore = nCore + 1 end end
    if nCore < 4 then return T end
    local nbrs = {}
    for u in pairs(core) do
      local l = {}
      for _, v in each_exit(padj[u]) do if core[v] then l[#l + 1] = v end end
      table.sort(l) ; nbrs[u] = l
    end
    -- (3) genus per component: V - E + F = 2 - 2g. Genus 0 everywhere => a crossing-free drawing
    -- exists => nothing below can be forced, and this is the cheap exit taken by most areas.
    local faces = elro.faces(core, padj)
    local par = {}
    local function find(a) while par[a] and par[a] ~= a do par[a] = par[par[a]] ; a = par[a] end return a end
    for u in pairs(core) do par[u] = par[u] or u end
    local V, E = nCore, 0
    for u in pairs(core) do
      E = E + #nbrs[u]
      for _, v in ipairs(nbrs[u]) do
        local ra, rb = find(u), find(v) ; if ra ~= rb then par[ra] = rb end
      end
    end
    E = E / 2
    local comps = {}
    for u in pairs(core) do comps[find(u)] = true end
    local nC = 0 ; for _ in pairs(comps) do nC = nC + 1 end
    local g = (2 * nC - V + E - #faces) / 2
    T.genus = g
    -- (3b) Genus is a SPHERE test but the drawing lives in the PLANE: a face turning +360 bounds
    -- a bounded region and is fine anywhere; a face turning -360 demands to be the outer face,
    -- and two such faces in one component cannot both be satisfied. Per-face turn is hoisted
    -- here so this gate can read it; `angOf` keeps the same first-hit-in-pairs-order semantics
    -- as the old per-half-edge rescan but is O(E) once. (Named angOf, not dirOf -- dirOf is
    -- already a function in this scope.)
    local angOf = {}
    for a in pairs(core) do
      local m = {}
      for d, w in each_exit(padj[a]) do
        local dd = dlt[d]
        if dd and (dd[1] ~= 0 or dd[2] ~= 0) and m[w] == nil then
          m[w] = math.deg(math.atan2(dd[2], dd[1]))
        end
      end
      angOf[a] = m
    end
    local fturn, outerClaims, claimByComp = {}, 0, {}
    for fi, f in ipairs(faces) do
      local n = #f
      if n >= 3 then
        local turn, ok = 0, true
        local prev = (angOf[f[n]] or {})[f[1]]
        if not prev then ok = false end
        for i = 1, n do
          if not ok then break end
          local cur = (angOf[f[i]] or {})[f[(i % n) + 1]]
          if not cur then ok = false break end
          local t = (cur - prev) % 360 ; if t > 180 then t = t - 360 end
          turn = turn + t ; prev = cur
        end
        if ok then
          fturn[fi] = turn
          -- Count outer-face claims per 2-core component and take the worst: two claimants only conflict in the same component.
          if turn <= -359 then
            local c = find(f[1])
            claimByComp[c] = (claimByComp[c] or 0) + 1
            if claimByComp[c] > outerClaims then outerClaims = claimByComp[c] end
          end
        end
      end
    end
    T.outerClaims = outerClaims
    if g <= 0 and outerClaims <= 1 then return T end
    local unresolved = {}   -- non-closing faces that produced no interleaving pair
    -- (4) per-face turn: only a face that cannot close as a simple curve can force anything
    local cap = TUNE.topoFaceCap
    local budget = TUNE.topoBudget
    -- Wall-clock bail as well as the step budget: longest-cycle enumeration is exponential in the worst case, and a timeout degrades to no sites from this face.
    local tStart, tCap = os.clock(), (elro.topoTimeCap or 0.5)
    elro.tr("topo crossings: analysing (" .. #faces .. " faces)")
    for fi, f in ipairs(faces) do
      local n = #f
      do
        local turn = fturn[fi]
        if turn then
          if math.abs(math.abs(turn) - 360) > 1 then
            -- distinct rooms of this face
            local S, ns = {}, 0
            for i = 1, n do if not S[f[i]] then S[f[i]] = true ; ns = ns + 1 end end
            if ns >= 4 and ns <= cap and budget > 0 then
              T.faces = T.faces + 1
              local pairsBefore = T.n
              -- (5) The rings of this face, then the bridges hanging off each.
              -- Keep every maximal ring, not one winner: the longest cycle ties routinely and
              -- the tie decides the answer. The union over maximal rings is also the right
              -- answer: each ring names a legitimate site for the same forced crossing.
              local rings, bestLen, ringSeen = {}, 0, {}
              local maxRings = TUNE.topoRings
              do
                local function canon(c)             -- rotation- and direction-independent key
                  local m, mi = c[1], 1
                  for i = 2, #c do if c[i] < m then m, mi = c[i], i end end
                  local fwd, bwd = {}, {}
                  for i = 0, #c - 1 do
                    fwd[#fwd + 1] = c[(mi - 1 + i) % #c + 1]
                    bwd[#bwd + 1] = c[(mi - 1 - i) % #c + 1]
                  end
                  local a, b = table.concat(fwd, ","), table.concat(bwd, ",")
                  return (a < b) and a or b
                end
                local function keep(path)
                  if #path < bestLen then return end
                  if #path > bestLen then rings, bestLen, ringSeen = {}, #path, {} end
                  if #rings >= maxRings then return end
                  local c = {} ; for i = 1, #path do c[i] = path[i] end
                  local k = canon(c)
                  if not ringSeen[k] then ringSeen[k] = true ; rings[#rings + 1] = c end
                end
                local order = {} ; for u in pairs(S) do order[#order + 1] = u end
                table.sort(order)
                for _, s0 in ipairs(order) do
                  local path, on = { s0 }, { [s0] = true }
                  local function dfs(u)
                    if budget <= 0 then return end
                    for _, v in ipairs(nbrs[u]) do
                      if S[v] then
                        budget = budget - 1
                        if budget % 4096 == 0 and (os.clock() - tStart) > tCap then budget = 0 end
                        if budget <= 0 then return end
                        if v == s0 then
                          if #path >= 4 then keep(path) end
                        elseif v > s0 and not on[v] then
                          path[#path + 1] = v ; on[v] = true
                          dfs(v)
                          on[v] = nil ; path[#path] = nil
                        end
                      end
                    end
                  end
                  dfs(s0)
                  if budget <= 0 then break end
                end
              end
              for _, ring in ipairs(rings) do
                T.rings = (T.rings or 0) + 1
                local onR, idxR = {}, {}
                for i, u in ipairs(ring) do onR[u] = true ; idxR[u] = i end
                local cycE = {}
                for i = 1, #ring do
                  local a, b = ring[i], ring[(i % #ring) + 1]
                  cycE[a .. ":" .. b] = true ; cycE[b .. ":" .. a] = true
                end
                local brs, doneC = {}, {}
                for i = 1, #ring do
                  for _, v in ipairs(nbrs[ring[i]]) do
                    if onR[v] and not cycE[ring[i] .. ":" .. v] then
                      local k = ekey(ring[i], v)
                      if not doneC[k] then
                        doneC[k] = true
                        brs[#brs + 1] = { att = { idxR[ring[i]], idxR[v] }, inner = {},
                                          edges = { { ring[i], v } } }
                      end
                    end
                  end
                end
                local mark = {}
                for u in pairs(core) do
                  if not onR[u] and not mark[u] then
                    local comp, st, att = {}, { u }, {}
                    mark[u] = true
                    while #st > 0 do
                      local x = table.remove(st) ; comp[#comp + 1] = x
                      for _, v in ipairs(nbrs[x]) do
                        if onR[v] then att[idxR[v]] = true
                        elseif not mark[v] then mark[v] = true ; st[#st + 1] = v end
                      end
                    end
                    local a = {} ; for i in pairs(att) do a[#a + 1] = i end
                    table.sort(a)
                    -- a bridge at least as big as its ring is the REST OF THE MAP, not a site
                    if #a >= 2 and #comp < #ring then
                      local es, inSet = {}, {}
                      for _, x in ipairs(comp) do inSet[x] = true end
                      local seenE = {}
                      for _, x in ipairs(comp) do
                        for _, v in ipairs(nbrs[x]) do
                          if inSet[v] or onR[v] then
                            local k = ekey(x, v)
                            if not seenE[k] then seenE[k] = true ; es[#es + 1] = { x, v } end
                          end
                        end
                      end
                      brs[#brs + 1] = { att = a, inner = comp, edges = es }
                    end
                  end
                end
                local function interleaves(b1, b2)
                  for _, i in ipairs(b1.att) do
                    for _, j in ipairs(b1.att) do
                      if i < j then
                        local ins, outs = false, false
                        for _, k in ipairs(b2.att) do
                          if k ~= i and k ~= j then
                            if k > i and k < j then ins = true else outs = true end
                          end
                        end
                        if ins and outs then return true end
                      end
                    end
                  end
                  return false
                end
                for i = 1, #brs do
                  for j = i + 1, #brs do
                    if interleaves(brs[i], brs[j]) or interleaves(brs[j], brs[i]) then
                      for _, e1 in ipairs(brs[i].edges) do
                        for _, e2 in ipairs(brs[j].edges) do
                          -- an edge through a dummy is half of a permitted grid-X: already exempt
                          if not (dummies[e1[1]] or dummies[e1[2]]
                               or dummies[e2[1]] or dummies[e2[2]])
                             -- provably parallel pairs (both edges locked to one row class, or
                             -- one column class) can never meet
                             and not (parallel_pair and parallel_pair(e1[1], e1[2], e2[1], e2[2])) then
                            local k1, k2 = ekey(e1[1], e1[2]), ekey(e2[1], e2[2])
                            if k1 ~= k2 then
                              local k = crosspair(k1, k2)
                              if not T.pair[k] then
                                T.pair[k] = true ; T.n = T.n + 1
                                T.quartet[#T.quartet + 1] = { e1[1], e1[2], e2[1], e2[2] }
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
              -- A face that cannot close and produced no interleaving pair is unresolved -- the
              -- figure-eight case: the maximal cycle runs through both lobes, so the chain the
              -- crossing belongs in becomes ring edges, which are never reported as crossing.
              if T.n == pairsBefore then unresolved[#unresolved + 1] = S end
            end
          end
        end
      end
    end
    -- Clean-chain sites: the answer for unresolved faces. A crossing may sit in any gap of a
    -- maximal degree-2 run; a room that hangs anything outside the 2-core is a WALL. Unlike a
    -- bridge pair this names ONE edge, not two -- the partner is whatever the loop ends up
    -- routing through the gap.
    if #unresolved > 0 and elro.chainSites ~= false then
      local used = {}
      for u in pairs(core) do
        if #nbrs[u] == 2 and not used[u] then
          local ch = { u } ; used[u] = true
          for side = 1, 2 do
            local prev, cur = u, nbrs[u][side]
            while cur and core[cur] and #nbrs[cur] == 2 and not used[cur] do
              used[cur] = true
              if side == 1 then ch[#ch + 1] = cur else table.insert(ch, 1, cur) end
              local nxt
              for _, w in ipairs(nbrs[cur]) do if w ~= prev then nxt = w end end
              prev, cur = cur, nxt
            end
          end
          -- The chain's TERMINAL JUNCTIONS belong to the run for gap purposes: the gap next to one
          -- is legal, so the run is [j1] + ch + [j2].
          local run = {}
          do
            local function term(endRoom, inward)
              for _, w in ipairs(nbrs[endRoom]) do if w ~= inward then return w end end
            end
            local j1 = term(ch[1], ch[2])
            local j2 = term(ch[#ch], ch[#ch - 1])
            if j1 and j1 ~= ch[1] then run[#run + 1] = j1 end
            for _, r in ipairs(ch) do run[#run + 1] = r end
            if j2 and j2 ~= ch[#ch] and j2 ~= j1 then run[#run + 1] = j2 end
          end
          -- A WALL is a chain room hanging a subtree outside the 2-core; a terminal junction is
          -- not a wall (what hangs off it is the loop itself). A gap is legal unless BOTH its
          -- rooms hang structure -- a wire threaded between two pendant-carrying rooms has
          -- nowhere to go. Walls split the chain into ZONES; the crossing runs between zones.
          local inCh = {}
          for _, r in ipairs(ch) do inCh[r] = true end
          local function wall(r)
            if not inCh[r] then return false end
            local n2 = 0 ; for _ in each_exit(padj[r]) do n2 = n2 + 1 end
            return n2 > 2
          end
          local function freeBead(r)
            local n2 = 0 ; for _ in each_exit(padj[r]) do n2 = n2 + 1 end
            return n2 == 2
          end
          -- T.site feeds two uses, deliberately split: every in-face gap of the chain is
          -- LICENSED at topo_forced (the chain provably must be crossed somewhere; which gap the
          -- geometry lands on is the walk's business), but only unwalled gaps may SEED via
          -- `zones` below. The licence is per-edge and has no budget, unlike the wire prover's.
          local zones, cur = {}, nil
          for i = 1, #run - 1 do
            local a, b = run[i], run[i + 1]
            if not dummies[a] and not dummies[b] then
              local inFace = false
              for _, S in ipairs(unresolved) do if S[a] and S[b] then inFace = true ; break end end
              local walled = wall(a) and wall(b)
              if inFace then
                local k = ekey(a, b)
                if not T.site[k] then
                  T.site[k] = true ; T.nsite = T.nsite + 1
                  T.siteList[#T.siteList + 1] = { a, b, walled = walled or nil }
                end
              end
              if inFace and not walled then
                local score = (freeBead(a) and 1 or 0) + (freeBead(b) and 1 or 0)
                if not cur then cur = { gaps = {} } ; zones[#zones + 1] = cur end
                cur.gaps[#cur.gaps + 1] = { a, b, score }
              else cur = nil end                     -- a walled gap ENDS the zone
            else cur = nil end
          end
          -- Seed pair: two gaps of the same chain (a figure-eight is the chain folding back
          -- across itself), taken from two zones either side of the walled middle. Tie-break =
          -- smallest rectangle: the last gap of one zone against the first of the next -- the
          -- two gaps facing each other across the walls; a tighter fold is less stretch.
          for i = 1, #zones - 1 do
            local z1, z2 = zones[i], zones[i + 1]
            local g1, g2 = z1.gaps[#z1.gaps], z2.gaps[1]
            T.quartet[#T.quartet + 1] = { g1[1], g1[2], g2[1], g2[2], chain = true }
            T.chainQuartet = (T.chainQuartet or 0) + 1
            break                                    -- one seed per chain
          end
        end
      end
    end
    -- Publish what the build found, separately from what the walk went on to use.
    elro._tcGenus, elro._tcPairs, elro._tcFaces, elro._tcRan = T.genus, T.n, T.faces, true
    elro._tcSites = T.nsite
    if elro.debug or T.n > 0 or T.nsite > 0 then
      elro.tr(string.format("topo crossings: genus %.0f, %d outer-claiming face(s), %d non-closing"
        .. " face(s), %d ring(s), %d accepted pair(s), %d chain site(s)",
        T.genus, T.outerClaims or 0, T.faces, T.rings or 0, T.n, T.nsite))
      for _, s in ipairs(T.siteList) do
        -- A walled site is licence-only: it may be crossed but never seeds a constructed pair.
        elro.tr(string.format("  chain site: %s-%s (a legal gap in a clean chain of a face that cannot close)%s",
          tostring(s[1]), tostring(s[2]),
          s.walled and " [WALLED -- licence only, never seeds]" or ""))
      end
    end
    return T
end
