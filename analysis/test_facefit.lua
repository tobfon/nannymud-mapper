-- HOW BIG DOES A FACE NEED TO BE, BEFORE ANYTHING IS PLACED?
--
--   luajit analysis/test_facefit.lua analysis/nib_live.txt
--   luajit analysis/test_facefit.lua analysis/rand.txt --all
--
-- The user's proposal: identify inward pendants, find the face that must CONTAIN each one, solve
-- that face's size first, and hand the answer to the walk so the face is built big enough from the
-- start instead of being expanded into shape one shearing lever at a time.
--
-- ⛔⛔ AND THE EXISTING `inward` CODE CANNOT BE REUSED. `core_classify` decides inward-vs-outward
-- with a POINT-IN-POLYGON test against `Scoord` -- it needs coordinates, which is exactly what
-- "before placing anything" forbids -- and under the live engine it is dead anyway
-- (`if elro.eqwalk then inward = {} end`; the whole split is overwritten). It belongs to the spqr
-- path the roadmap retires.
--
-- ⭐⭐⭐ BUT INWARD-NESS IS RECOVERABLE WITH NO COORDINATES. Every exit FIXES its edge's compass
-- angle, so the edges at a vertex have a fixed CYCLIC ORDER. The faces meeting that vertex are the
-- angular SECTORS between consecutive core edges, and a pendant's own first edge direction falls in
-- exactly one sector -- hence exactly one face. That is a rotation system, not a drawing.
--
-- ⭐⭐ AND THE SIZE CONSTRAINT IS PICK'S THEOREM. For a lattice polygon  A = I + B/2 - 1, so the
-- interior lattice points are  I = A - B/2 + 1.  Every boundary edge is `len` unit steps, so
-- B = sum(len). A face must offer at least one interior cell per room it has to contain:
--
--     I(face)  >=  (rooms of every pendant assigned to it)
--
-- ⭐ SCALING IS THE CHEAP FAMILY: multiplying every length by k preserves the cycle equation
-- EXACTLY (it is linear), and grows the area like k^2 while the boundary grows like k -- so there is
-- always a k that fits, and the smallest one is a straight answer to "how big does it need to be".
-- ⚠ Uniform scaling is A legal family, not the optimal one: a long thin face may fit the pendant at
-- a smaller total length by growing on one axis only. `k` is therefore an UPPER bound on the size
-- needed, which is the safe direction for a constraint the walk will build to.

dofile("analysis/engine_load.lua")   -- shipped elro.faces / elro.pick_outer_face
local dumpPath = arg[1] or error("usage: test_facefit.lua <dump> [--all] [--top=N]")
local TOP, ALL = 10, false
for i = 2, #arg do
  local n = arg[i]:match("^%-%-top=(%d+)$") ; if n then TOP = tonumber(n) end
  if arg[i] == "--all" then ALL = true end
end

local DELTA = { east = {1,0}, northeast = {1,1}, north = {0,1}, northwest = {-1,1},
                west = {-1,0}, southwest = {-1,-1}, south = {0,-1}, southeast = {1,-1} }
local ANG = { east = 0, northeast = 45, north = 90, northwest = 135,
              west = 180, southwest = 225, south = 270, southeast = 315 }
local REV = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" }

-- ------------------------------------------------------------------- the dump
local ADJ, ORDER, POS = {}, {}, {}
do
  local f = assert(io.open(dumpPath, "r"))
  for ln in f:lines() do
    local id, x, y, ex = ln:match("^%s*(%d+) %((-?%d+),(-?%d+),%-?%d+%) area=%S+ %[(.*)%]%s*$")
    if id then
      id = tonumber(id) ; ORDER[#ORDER + 1] = id ; ADJ[id] = ADJ[id] or {}
      POS[id] = { tonumber(x), tonumber(y) }
      for d, t in ex:gmatch("(%a+)%->(%d+)") do if DELTA[d] then ADJ[id][d] = tonumber(t) end end
    end
  end
  f:close()
end
for _, u in ipairs(ORDER) do                       -- symmetrise (see the asymmetric-exit fix)
  for d, v in pairs(ADJ[u]) do
    if POS[v] then
      local back ; for d2, w in pairs(ADJ[v]) do if w == u then back = d2 end end
      if not back then ADJ[v][REV[d]] = u end
    end
  end
end
-- ⚠ MUTUAL EDGES ONLY. The symmetrise above cannot add a back-edge when that compass slot is
-- already taken by a DIFFERENT room (the asymmetric-exit case -- see [[project_asymmetric_exits]]),
-- which leaves a one-way edge. Face tracing needs a genuine ROTATION SYSTEM: every dart must have a
-- reverse, or `next_dart` walks off the end (rand crashes on exactly this). Drop the one-way ones.
local function mutual(u, v)
  if not ADJ[v] then return false end
  for _, w in pairs(ADJ[v]) do if w == u then return true end end
  return false
end
-- deterministic direction list per room (sorted by ANGLE -- this IS the rotation system)
local ROT = {}
for _, u in ipairs(ORDER) do
  local l, seenv = {}, {}
  for d, v in pairs(ADJ[u]) do
    -- one entry per NEIGHBOUR (lowest angle wins): a doubled exit to the same room is not two darts
    if POS[v] and mutual(u, v) and not seenv[v] then
      seenv[v] = true ; l[#l + 1] = { d = d, v = v, a = ANG[d] }
    end
  end
  table.sort(l, function(p, q) if p.a ~= q.a then return p.a < q.a end return p.v < q.v end)
  ROT[u] = l
end

-- --------------------------------------------------------------------- 2-core
local core = {}
for _, u in ipairs(ORDER) do core[u] = true end
local changed = true
while changed do
  changed = false
  for _, u in ipairs(ORDER) do
    if core[u] then
      local d = 0
      for _, e in ipairs(ROT[u]) do if core[e.v] then d = d + 1 end end
      if d <= 1 then core[u] = false ; changed = true end
    end
  end
end
-- rotation restricted to the core -- faces are traced on the core only
local CROT = {}
for _, u in ipairs(ORDER) do
  if core[u] then
    local l = {}
    for _, e in ipairs(ROT[u]) do if core[e.v] then l[#l + 1] = e end end
    CROT[u] = l
  end
end

-- ---------------------------------------------------------------- face tracing
-- ⭐⭐⭐ THE ENGINE ALREADY SHIPS THIS. `elro.faces(nodeset, adj)` is the same rotation-system walk
-- (neighbours sorted by FANG, step to the CLOCKWISE PREDECESSOR of the reverse half-edge) and it
-- carries the asymmetric-exit bail that a hand-rolled tracer here rediscovered by CRASHING on rand.
-- `elro.pick_outer_face` decides the outer boundary by TURN ANGLE, combinatorially. Use them: a
-- re-implementation drifts from the code that actually runs, and the answers have to agree.
-- ⚠ `elro.faces` returns a face as a list of ROOMS; this file wants DARTS (ordered pairs), so the
-- ring is re-paired here. Same cycle, different spelling.
local coreSet = {}
for _, u in ipairs(ORDER) do if core[u] then coreSet[u] = true end end
local cadj = {}
for _, u in ipairs(ORDER) do
  if core[u] then
    cadj[u] = {}
    for _, e in ipairs(CROT[u]) do cadj[u][e.d] = e.v end
  end
end
local rawFaces = elro.faces(coreSet, cadj)
local outerRing = elro.pick_outer_face(rawFaces, cadj)
local faces, outerIdx = {}, nil
for fi, f in ipairs(rawFaces) do
  local ring = {}
  for i = 1, #f do ring[#ring + 1] = { f[i], f[(i % #f) + 1] } end
  faces[#faces + 1] = ring
  if f == outerRing then outerIdx = #faces end
end
-- turn total tells interior (+360) from the outer boundary (-360); anything else is a face that
-- cannot close as a simple curve with these directions (turn.lua's grid forcing)
local function dir_between(u, v)
  local best
  for _, e in ipairs(ROT[u]) do if e.v == v and (not best or e.d < best) then best = e.d end end
  return best
end
local function turn_total(ring)
  local t = 0
  for i = 1, #ring do
    local d1 = ANG[dir_between(ring[i][1], ring[i][2])]
    local nx = ring[(i % #ring) + 1]
    local d2 = ANG[dir_between(nx[1], nx[2])]
    local dt = (d2 - d1) % 360 ; if dt > 180 then dt = dt - 360 end
    t = t + dt
  end
  return t
end

-- --------------------------------------------- pendant trees, and which face holds each
local pend, pseen = {}, {}
for _, s in ipairs(ORDER) do
  if not core[s] and not pseen[s] then
    local comp, q, qh = {}, { s }, 1 ; pseen[s] = true
    local A, dA
    while qh <= #q do
      local u = q[qh] ; qh = qh + 1 ; comp[#comp + 1] = u
      for _, e in ipairs(ROT[u]) do
        if core[e.v] then
          if not A or e.v < A then A, dA = e.v, e.d end       -- attachment (min id: deterministic)
        elseif not pseen[e.v] then pseen[e.v] = true ; q[#q + 1] = e.v end
      end
    end
    if A then pend[#pend + 1] = { rooms = comp, n = #comp, A = A, d = dA } end
  end
end
-- ⭐ THE SECTOR TEST. A face occupies, at each of its vertices, the angular wedge between the
-- REVERSE of the edge it arrived on and the edge it leaves on. A pendant whose first edge points
-- into that wedge is inside that face. Pure angles -- no drawing.
local function in_wedge(from, to, a)
  local w = (to - from) % 360
  local x = (a - from) % 360
  return x > 0 and x < w
end
local faceOf = {}
for pi, p in ipairs(pend) do
  local ang = ANG[p.d]                                  -- direction A -> pendant
  for fi, ring in ipairs(faces) do
    for i = 1, #ring do
      if ring[i][1] == p.A then
        local prev = ring[((i - 2) % #ring) + 1]
        local aIn = ANG[dir_between(prev[2], prev[1])]  -- reverse of the arriving edge
        local aOut = ANG[dir_between(ring[i][1], ring[i][2])]
        if in_wedge(aOut, aIn, ang) then faceOf[pi] = fi ; break end
      end
    end
    if faceOf[pi] then break end
  end
end

-- ------------------------------------------------ size the faces that carry pendants
-- ⛔⛔ A RING GENERALLY DOES **NOT** CLOSE AT UNIT LENGTHS, and measuring one that does not is
-- meaningless (the shoelace of an open chain gave negative interiors on most world/lyr faces).
-- Solve the cycle equation FIRST -- `sum(len_i * dir_i) = 0`, len >= 1 -- exactly as
-- `test_cycles.lua` does, and only then take the area. This is the join between the two prototypes:
-- test_cycles answers "how long must the edges be", this one answers "and is that big enough to
-- hold what must go inside".
local function solve_ring(ring)
  local D, len = {}, {}
  for i = 1, #ring do
    D[i] = DELTA[dir_between(ring[i][1], ring[i][2])] ; len[i] = 1
  end
  for _ = 1, 400 do
    local rx, ry = 0, 0
    for i = 1, #ring do rx = rx + len[i] * D[i][1] ; ry = ry + len[i] * D[i][2] end
    if rx == 0 and ry == 0 then return len, true end
    local bi, bg = nil, 0
    for i = 1, #ring do
      local g = 0
      if rx ~= 0 and D[i][1] ~= 0 then g = g + (((rx > 0) ~= (D[i][1] > 0)) and 1 or -1) end
      if ry ~= 0 and D[i][2] ~= 0 then g = g + (((ry > 0) ~= (D[i][2] > 0)) and 1 or -1) end
      if g > bg then bg, bi = g, i end
    end
    if not bi then return len, false end
    len[bi] = len[bi] + 1
  end
  return len, false
end
-- integrate the ring at the SOLVED lengths, scaled by k (scaling is linear, so it preserves the
-- cycle equation exactly -- which is what makes `k` a legal family to search)
local function geom(ring, len, k)
  k = k or 1
  local x, y, pts, B = 0, 0, {}, 0
  for i = 1, #ring do
    pts[#pts + 1] = { x, y }
    local D = DELTA[dir_between(ring[i][1], ring[i][2])]
    x, y = x + D[1] * len[i] * k, y + D[2] * len[i] * k ; B = B + len[i] * k
  end
  local closed = (x == 0 and y == 0)
  local A2 = 0                                          -- twice the shoelace area
  for i = 1, #pts do
    local p, q = pts[i], pts[(i % #pts) + 1]
    A2 = A2 + (p[1] * q[2] - q[1] * p[2])
  end
  local area = math.abs(A2) / 2
  return closed, area, B, (area - B / 2 + 1)            -- Pick: I = A - B/2 + 1
end

local load_ = {}
for pi, p in ipairs(pend) do
  local fi = faceOf[pi]
  if fi then load_[fi] = (load_[fi] or 0) + p.n end
end
-- ============================================================ JOINT SIZING (--joint)
-- ⛔⛔⛔ SIZING EACH FACE ALONE IS WRONG, AND IT IS WHAT MADE THE FIRST MEASUREMENT LOOK FALSIFYING.
-- FACES SHARE EDGES. A face can be forced well above its OWN minimum by a NEIGHBOUR's demand, so a
-- per-face answer is a lower bound on that face and says nothing about the assembly. nib is the
-- case: the contested face `1935-1951-1906-...` needs only 2 interior cells and reads `x1` alone,
-- while the face next to it holds 10 rooms and needs `x2` -- and they share `1933:1934`, `1934:1935`
-- and `1935:1951`. The user's two hand-built targets sit 2-3 units above that face's own minimum,
-- which per-face sizing cannot explain and joint sizing can.
--
-- ONE variable per CORE EDGE, shared by both faces that use it. Fixed point over two rules:
--   1. CLOSURE   -- every bounded face must satisfy  sum(len_i * dir_i) = 0
--   2. CAPACITY  -- every bounded face must satisfy  Pick interior I >= its pendant load
-- Growing an edge for rule 2 breaks a neighbour's rule 1, which is exactly the coupling we want to
-- see; iterate until nothing changes.
-- ⚠ This is a HEURISTIC fixed point, not an optimum: it reports A feasible joint sizing, so every
-- number is an UPPER bound on what that edge needs. That is the safe direction for "build it at
-- least this big", and it is the honest shape -- the exact problem is an integer program with a
-- QUADRATIC capacity term (Pick's area is quadratic in the lengths).
local EKEY = function(a, b) if a > b then a, b = b, a end return a .. ":" .. b end
local function joint()
  local len = {}
  local bounded = {}
  for fi, ring in ipairs(faces) do
    if fi ~= outerIdx then
      local tt = turn_total(ring)
      if tt > 0 then bounded[#bounded + 1] = fi end
    end
    for i = 1, #ring do len[EKEY(ring[i][1], ring[i][2])] = 1 end
  end
  local function resid(ring)
    local rx, ry = 0, 0
    for i = 1, #ring do
      local D = DELTA[dir_between(ring[i][1], ring[i][2])]
      local L = len[EKEY(ring[i][1], ring[i][2])]
      rx = rx + L * D[1] ; ry = ry + L * D[2]
    end
    return rx, ry
  end
  local function measure(ring, sc)
    sc = sc or 1
    local x, y, pts, B = 0, 0, {}, 0
    for i = 1, #ring do
      pts[#pts + 1] = { x, y }
      local D = DELTA[dir_between(ring[i][1], ring[i][2])]
      local L = len[EKEY(ring[i][1], ring[i][2])] * sc
      x, y = x + D[1] * L, y + D[2] * L ; B = B + L
    end
    local A2 = 0
    for i = 1, #pts do
      local p, q = pts[i], pts[(i % #pts) + 1]
      A2 = A2 + (p[1] * q[2] - q[1] * p[2])
    end
    local ar = math.abs(A2) / 2
    return (x == 0 and y == 0), ar, B, ar - B / 2 + 1
  end
  local rounds = 0
  for it = 1, 300 do
    rounds = it
    local moved = false
    for _, fi in ipairs(bounded) do            -- rule 1: closure
      local ring = faces[fi]
      for _ = 1, 200 do
        local rx, ry = resid(ring)
        if rx == 0 and ry == 0 then break end
        local bi, bg = nil, 0
        for i = 1, #ring do
          local D = DELTA[dir_between(ring[i][1], ring[i][2])]
          local g = 0
          if rx ~= 0 and D[1] ~= 0 then g = g + (((rx > 0) ~= (D[1] > 0)) and 1 or -1) end
          if ry ~= 0 and D[2] ~= 0 then g = g + (((ry > 0) ~= (D[2] > 0)) and 1 or -1) end
          if g > bg then bg, bi = g, i end
        end
        if not bi then break end
        local k = EKEY(ring[bi][1], ring[bi][2])
        len[k] = len[k] + 1 ; moved = true
      end
    end
    if not moved then break end
  end
  -- ⛔⛔⛔ CAPACITY GROWTH MUST BE MULTIPLICATIVE, AND THAT FORCES IT TO BE **GLOBAL**.
  -- Adding +1 to every edge of a ring preserves closure only when that ring's UNIT direction sum is
  -- already zero; after the closure repair has made lengths unequal on a ring that did NOT close at
  -- unit, the +1 shifts the residual, the repair regrows it, and it diverges (measured: nib ran 300
  -- rounds to total length 119494 with faces still OPEN). Scaling is linear, so it preserves closure
  -- exactly -- but an edge is SHARED, so scaling one face rescales its neighbour, and the only
  -- globally consistent closure-preserving growth is a UNIFORM SCALE OF THE WHOLE CORE.
  -- ⭐⭐⭐ THAT IS THE REAL RESULT, not a workaround: within "keep every face closed", the assembly
  -- has exactly ONE degree of freedom -- its overall size. Making ONE face bigger while its
  -- neighbours stay put is not a scaling at all; it is a REDISTRIBUTION, i.e. deciding which edges
  -- absorb the difference -- the absorber problem, arrived at from the opposite direction.
  local k = 1
  for _ = 1, 40 do
    local short = false
    for _, fi in ipairs(bounded) do
      local need = load_[fi]
      if need then
        local ok, _, _, I = measure(faces[fi], k)
        if ok and I < need then short = true break end
      end
    end
    if not short then break end
    k = k + 1
  end
  return len, bounded, measure, resid, rounds, k
end
if ALL or os.getenv("JOINT") then
  local len, bounded, measure, _, rounds, gk = joint()
  local tot, shared = 0, 0
  local use = {}
  for _, ring in ipairs(faces) do
    for i = 1, #ring do
      local k = EKEY(ring[i][1], ring[i][2]) ; use[k] = (use[k] or 0) + 1
    end
  end
  for k, L in pairs(len) do tot = tot + L ; if (use[k] or 0) > 1 then shared = shared + 1 end end
  print(("JOINT SIZING: %d bounded face(s), %d core edge(s) (%d shared), closed length %d in %d round(s); GLOBAL SCALE x%d -> total %d")
    :format(#bounded, (function() local n = 0 for _ in pairs(len) do n = n + 1 end return n end)(),
            shared, tot, rounds, gk, tot * gk))
  for _, fi in ipairs(bounded) do
    local need = load_[fi] or 0
    local ok, _, B, I = measure(faces[fi], gk)
    if need > 0 or B > #faces[fi] then
      local ids = {}
      for i = 1, math.min(#faces[fi], 8) do ids[#ids + 1] = faces[fi][i][1] end
      print(("  %-3d edges  len=%-4d I=%-4d hold=%-3d %s  %s"):format(
        #faces[fi], B, I, need, ok and "" or "OPEN", table.concat(ids, "-")))
    end
  end
end

local rows = {}
for fi, need in pairs(load_) do
  local ring = faces[fi]
  local tt = turn_total(ring)
  local len, ok = solve_ring(ring)
  local tot = 0 ; for i = 1, #len do tot = tot + len[i] end
  local closed, area, B, I = geom(ring, len, 1)
  local k, kI = 1, I
  if closed and tt > 0 then
    while kI < need and k < 40 do k = k + 1 ; local _, _, _, i2 = geom(ring, len, k) ; kI = i2 end
  end
  rows[#rows + 1] = { fi = fi, n = #ring, need = need, I = I, k = k, kI = kI, tot = tot,
                      closed = closed and ok, tt = tt, area = area, B = B, ring = ring }
end
table.sort(rows, function(a, b)
  if a.k ~= b.k then return a.k > b.k end
  return a.need > b.need
end)

local nCore = 0 ; for _, u in ipairs(ORDER) do if core[u] then nCore = nCore + 1 end end
local unass = 0 ; for pi in ipairs(pend) do if not faceOf[pi] then unass = unass + 1 end end
print(("%s -- %d rooms, 2-core %d, %d face(s), %d pendant tree(s), %d assigned to an INTERIOR face")
  :format(dumpPath, #ORDER, nCore, #faces, #pend, #pend - unass - 0))
print(("%-6s %-6s %-6s %-7s %-7s %-6s  %s"):format("edges", "hold", "len", "I@min", "scale", "I@k", "face (first rooms)"))
local shown = 0
for _, r in ipairs(rows) do
  if ALL or shown < TOP then
    shown = shown + 1
    local ids = {}
    for i = 1, math.min(#r.ring, 8) do ids[#ids + 1] = r.ring[i][1] end
    if #r.ring > 8 then ids[#ids + 1] = "..." end
    print(("%-6d %-6d %-6d %-7d %-7s %-6d  %s%s"):format(
      r.n, r.need, r.tot, r.I, (r.closed and r.tt > 0) and ("x" .. r.k) or "-", r.kI,
      table.concat(ids, "-"),
      (not r.closed) and "   [does not close at unit steps]"
        or ((r.fi == outerIdx or r.tt <= 0) and "   [outer boundary]" or "")))
  end
end
print(("%d face(s) carry pendants; %d pendant tree(s) sit in the OUTER face or unassigned")
  :format(#rows, unass))
