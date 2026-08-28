-- DIAGONAL EQUATIONS -- a four-family closure over room DISPLACEMENTS.
--
--   luajit analysis/test_diageq.lua <dump> [--classes] [--diag=all|square|none]
--                                          [--anchor=ID,ID] [--seed=ID:dx,dy] [--apply]
--
-- The engine's `eqw_classes` builds TWO union-finds: E/W chains lock a ROW (equal y), N/S chains lock
-- a COLUMN (equal x). Under the SOFT assumption that a diagonal edge wants to sit at 45 degrees,
-- diagonals lock the ROTATED coordinates the same way:
--
--     u = x + y     NW/SE edges hold u equal      (step (-1,+1) / (+1,-1) => du = 0)
--     v = x - y     NE/SW edges hold v equal      (step (+1,+1) / (-1,-1) => dv = 0)
--
-- Every one of the four is the same statement about a DISPLACEMENT d = (dx,dy): some fixed projection
-- `n . d` is equal at both endpoints.
--
--     E/W edge  -> n = (0,1)      N/S edge  -> n = (1,0)
--     NE/SW     -> n = (1,-1)     NW/SE     -> n = (1,1)
--
-- ⭐ WHY THIS IS NOT A UNION-FIND ANY MORE, AND WHY THAT IS THE POINT. With one family per axis a
-- room's membership is a BOOLEAN and the whole class moves by one scalar. With four families over a
-- 2-vector, ANY TWO independent projections determine d outright -- so a room can inherit `du` from
-- one neighbour and `dv` from another and end up displaced in a direction NEITHER neighbour moved.
-- That is exactly the DILATION the plate representation (`movedCls[a][c]` boolean + scalar SH) cannot
-- express, and it falls out of propagation rather than out of a solver.
--
-- ⚠ AXIAL CONSTRAINTS ARE HARD, DIAGONAL ONES ARE SOFT. A truthful map REQUIRES the row/column
-- equalities; it does not require a diagonal to be square (dx=+3,dy=+7 is a perfectly truthful NE).
-- So a diagonal contradiction is not an infeasibility, it is a diagonal that has to SKEW -- DECLINE
-- it and carry on. `--diag=square` only admits diagonals that are square in the CURRENT geometry
-- (what a live lever would see); `--diag=all` admits every truthful diagonal (the ideal-45 model,
-- which is what says where the geometry SHOULD be).

local dumpPath = arg[1] or error("usage: test_diageq.lua <dump> [opts]")

local OPT = { diag = "all" }
for i = 2, #arg do
  local k, v = arg[i]:match("^%-%-([%w_]+)=?(.*)$")
  if not k then error("bad option: " .. arg[i]) end
  OPT[k] = (v == "") and true or v
end

-- --------------------------------------------------------------------------- the dump
local D = { north = {0,1}, south = {0,-1}, east = {1,0}, west = {-1,0},
            northeast = {1,1}, northwest = {-1,1}, southeast = {1,-1}, southwest = {-1,-1} }

local ROOMS, ORDER = {}, {}
do
  local f = assert(io.open(dumpPath, "r"))
  for ln in f:lines() do
    local id, x, y, ar, ex = ln:match("^%s*(%d+) %((-?%d+),(-?%d+),%-?%d+%) area=(%S+) %[(.*)%]%s*$")
    if id then
      id = tonumber(id)
      ROOMS[id] = { x = tonumber(x), y = tonumber(y), area = ar, exits = {} }
      ORDER[#ORDER + 1] = id
      for d, t in ex:gmatch("(%a+)%->(%d+)") do ROOMS[id].exits[d] = tonumber(t) end
    end
  end
  f:close()
end
local P = {}
for _, id in ipairs(ORDER) do P[id] = { ROOMS[id].x, ROOMS[id].y } end

-- --------------------------------------------------------------------------- constraint edges
-- One entry per UNDIRECTED edge, in a deterministic order (⚠ never `pairs()` order -- LuaJIT
-- randomises string hashing per process, so a hash-ordered sweep is not reproducible across runs).
-- Reverse-aware by construction: an exit a -(d)-> b is recorded once whichever direction it was seen
-- from, so an asymmetric pair still contributes its constraint exactly once.
local FAM = {                                       -- family -> projection n and a label
  row  = { n = {0, 1},  label = "row  y" },         -- E/W chain
  col  = { n = {1, 0},  label = "col  x" },         -- N/S chain
  v    = { n = {1, -1}, label = "diag v=x-y" },     -- NE/SW
  u    = { n = {1, 1},  label = "diag u=x+y" },     -- NW/SE
}

local EDGES, seen = {}, {}
for _, id in ipairs(ORDER) do
  local ds = {}
  for d in pairs(ROOMS[id].exits) do ds[#ds + 1] = d end
  table.sort(ds)
  for _, d in ipairs(ds) do
    local t, de = ROOMS[id].exits[d], D[d]
    if de and P[t] then
      local a, b = id, t ; if a > b then a, b = b, a end
      local k = a .. ":" .. b
      if not seen[k] then
        local fam
        if de[1] ~= 0 and de[2] ~= 0 then fam = (de[1] == de[2]) and "v" or "u"
        elseif de[1] ~= 0 then fam = "row"
        else fam = "col" end
        -- squareness of the CURRENT drawing, for the soft gate and for reporting
        local gx, gy = P[t][1] - P[id][1], P[t][2] - P[id][2]
        local square = (math.abs(gx) == math.abs(gy))
        seen[k] = true
        EDGES[#EDGES + 1] = { a = a, b = b, dir = d, fam = fam, square = square, gx = gx, gy = gy }
      end
    end
  end
end

local INC = {}                                      -- room -> incident constraint edges
for _, id in ipairs(ORDER) do INC[id] = {} end
local function admit(e)
  if e.fam ~= "u" and e.fam ~= "v" then return true end
  if OPT.diag == "none" then return false end
  if OPT.diag == "square" then return e.square end
  return true
end
local nAdm = 0
for _, e in ipairs(EDGES) do
  if admit(e) then
    nAdm = nAdm + 1
    INC[e.a][#INC[e.a] + 1] = e ; INC[e.b][#INC[e.b] + 1] = e
  end
end

print(("dump %s -- %d rooms, %d edges (%d admitted, diag=%s)")
  :format(dumpPath, #ORDER, #EDGES, nAdm, tostring(OPT.diag)))

-- --------------------------------------------------------------------------- the four partitions
if OPT.classes then
  for _, fam in ipairs({ "col", "row", "v", "u" }) do
    local p = {}
    local function find(a) while p[a] ~= a do p[a] = p[p[a]] ; a = p[a] end return a end
    for _, id in ipairs(ORDER) do p[id] = id end
    for _, e in ipairs(EDGES) do
      if e.fam == fam and admit(e) then
        local ra, rb = find(e.a), find(e.b) ; if ra ~= rb then p[ra] = rb end
      end
    end
    local mem, order = {}, {}
    for _, id in ipairs(ORDER) do
      local c = find(id)
      if not mem[c] then mem[c] = {} ; order[#order + 1] = c end
      table.insert(mem[c], id)
    end
    local big = {}
    for _, c in ipairs(order) do if #mem[c] > 1 then big[#big + 1] = mem[c] end end
    table.sort(big, function(x, y) return #x > #y end)
    print(("\n[%s] %d non-trivial class(es):"):format(FAM[fam].label, #big))
    for i = 1, math.min(#big, 12) do print("   " .. table.concat(big[i], " ")) end
    if #big > 12 then print(("   ... %d more"):format(#big - 12)) end
  end
end

-- --------------------------------------------------------------------------- the propagation
-- Each room accumulates equations `n . d = c`. Two INDEPENDENT ones determine d; a third is a
-- CONSISTENCY CHECK, not new information. Every pair of our four n's is independent, so the second
-- equation always solves -- but det(n1,n2) = ±2 for the two DIAGONAL families, which is where the
-- half-integers come from and why a rhombus cannot be dilated by an odd amount.
local eqs, dsp, conflict, declined, cseen = {}, {}, {}, {}, {}
local HARD = { row = true, col = true, u = false, v = false }
for _, id in ipairs(ORDER) do eqs[id] = {} end

local function dot(n, d) return n[1] * d[1] + n[2] * d[2] end

local queue, qh = {}, 1
local function push(r) queue[#queue + 1] = r end

-- returns ok, why
local function add_eq(r, n, c, src, fam)
  if dsp[r] then
    if dot(n, dsp[r]) ~= c then return false, "determined" end
    return true
  end
  for _, e in ipairs(eqs[r]) do
    if e.n[1] == n[1] and e.n[2] == n[2] then
      if e.c ~= c then return false, "same-projection" end
      return true                                    -- nothing new
    end
  end
  eqs[r][#eqs[r] + 1] = { n = n, c = c, src = src, fam = fam }
  if #eqs[r] == 2 then
    local e1, e2 = eqs[r][1], eqs[r][2]
    local det = e1.n[1] * e2.n[2] - e1.n[2] * e2.n[1]
    local dx = (e1.c * e2.n[2] - e2.c * e1.n[2]) / det
    local dy = (e1.n[1] * e2.c - e2.n[1] * e1.c) / det
    dsp[r] = { dx, dy }
  end
  push(r)
  return true
end

local function known(r, n)
  if dsp[r] then return dot(n, dsp[r]) end
  for _, e in ipairs(eqs[r]) do
    if e.n[1] == n[1] and e.n[2] == n[2] then return e.c end
  end
  return nil
end

-- seeds: --anchor=ID,ID pins d = (0,0); --seed=ID:dx,dy pins a displacement
local function pin(r, dx, dy, why)
  if not P[r] then error("no such room: " .. tostring(r)) end
  add_eq(r, {1, 0}, dx, why, "col") ; add_eq(r, {0, 1}, dy, why, "row")
end
if OPT.anchor then
  for s in tostring(OPT.anchor):gmatch("[^,]+") do pin(tonumber(s), 0, 0, "anchor") end
end
local seedList = {}
if OPT.seed then
  for spec in tostring(OPT.seed):gmatch("[^;]+") do
    local id, dx, dy = spec:match("^(%d+):(-?%d+),(-?%d+)$")
    if not id then error("bad --seed (want ID:dx,dy): " .. spec) end
    pin(tonumber(id), tonumber(dx), tonumber(dy), "seed")
    seedList[#seedList + 1] = tonumber(id)
  end
end

local function drain()
  while qh <= #queue do
    local r = queue[qh] ; qh = qh + 1
    for _, e in ipairs(INC[r]) do
      local n = FAM[e.fam].n
      local c = known(r, n)
      if c then
        local o = (e.a == r) and e.b or e.a
        local ok, why = add_eq(o, n, c, r, e.fam)
        if not ok then
          -- an edge is reached from both endpoints and a room can re-enter the queue: dedup, or one
          -- disagreement prints up to four times
          local k = e.a .. ":" .. e.b
          if not cseen[k] then
            cseen[k] = true
            local rec = { edge = e, from = r, to = o, n = n, c = c, why = why }
            if HARD[e.fam] then conflict[#conflict + 1] = rec
            else declined[#declined + 1] = rec end
          end
        end
      end
    end
  end
end
drain()

-- ⭐ COMPLETION -- the free component of a HARD partial is the drag rule's business, and its minimal
-- answer is ZERO (pure stretch is free; only a squash forces a drag). For a row equation `(0,1).d=c`
-- that is d=(0,c), for a column one `(1,0).d=c` it is d=(c,0) -- UNAMBIGUOUS, because the free
-- direction is a coordinate axis. Determining one room lets the propagation continue, so this runs to
-- a fixpoint. ⚠ SQUASH IS NOT MODELLED HERE: a real drag rule would push the free component off zero
-- where an edge would fall below length 1. This is the minimal plate, not the final one.
-- A SOFT partial is completed only under `--soft`, and by a DIFFERENT rule. `(1,1).d = 2` is
-- satisfied by (1,1), (2,0), (0,2), ... -- the free direction is not a coordinate axis, so "set the
-- other coordinate to zero" is not canonical. ⭐ The minimum-NORM solution is, and it is one line:
-- `d = c*n/(n.n)`, i.e. (c/2, c/2) for u and (c/2, -c/2) for v. It is integral exactly when c is
-- EVEN -- the same parity that makes a rhombus dilate by 2 and not by 1 -- so the rule
-- "take the minimum-norm solution, DECLINE if it is not integral" needs no tie-break and no knob.
-- ⚠ `--complete` and `--drag` are COMPETING answers to the same freedom and must not be combined:
-- completion pins a hard partial's free component at 0 permanently, so the drag rule can no longer
-- move it and every squash becomes an unresolvable residual. `--drag` is the squash-aware one and
-- subsumes `--complete`; the latter is kept only to show what the forced part alone determines.
-- `--soft` is independent of both -- it settles SOFT partials, which the drag rule never touches.
local completed = {}
if OPT.complete or OPT.soft then
  local changed = true
  while changed do
    changed = false
    for _, id in ipairs(ORDER) do
      if not dsp[id] and #eqs[id] == 1 then
        local e = eqs[id][1]
        if HARD[e.fam] and OPT.complete then
          local n2 = (e.n[1] == 0) and {1, 0} or {0, 1} -- the orthogonal axis, pinned to 0
          add_eq(id, n2, 0, "complete", (n2[1] == 1) and "col" or "row")
          completed[#completed + 1] = id ; changed = true ; drain()
        elseif not HARD[e.fam] and OPT.soft and e.c % 2 == 0 then   -- minimum-norm, integral only
          local h = e.c / 2
          add_eq(id, {1, 0}, h, "soft", "col")
          add_eq(id, {0, 1}, (e.n[2] == 1) and h or -h, "soft", "row")
          completed[#completed + 1] = id ; changed = true ; drain()
        end
      end
    end
  end
end

-- --------------------------------------------------------------------------- report
local det, part, frac = {}, {}, {}
for _, id in ipairs(ORDER) do
  if dsp[id] then
    det[#det + 1] = id
    if dsp[id][1] % 1 ~= 0 or dsp[id][2] % 1 ~= 0 then frac[#frac + 1] = id end
  elseif #eqs[id] == 1 then part[#part + 1] = id end
end

local function fmt(d) return ("(%s,%s)"):format(tostring(d[1]), tostring(d[2])) end

print(("\npropagation: %d determined (%d by completion), %d partial (one projection), %d untouched")
  :format(#det, #completed, #part, #ORDER - #det - #part))
if #frac > 0 then
  print(("⛔ %d room(s) land on HALF-INTEGER cells -- this seed is infeasible at this magnitude:")
    :format(#frac))
  for _, id in ipairs(frac) do print(("     %d -> %s"):format(id, fmt(dsp[id]))) end
end

local moved = {}
for _, id in ipairs(det) do if dsp[id][1] ~= 0 or dsp[id][2] ~= 0 then moved[#moved + 1] = id end end
print(("\nMOVED (%d of %d determined):"):format(#moved, #det))
do  -- group by displacement, biggest group first
  local g, ks = {}, {}
  for _, id in ipairs(moved) do
    local k = fmt(dsp[id])
    if not g[k] then g[k] = {} ; ks[#ks + 1] = k end
    table.insert(g[k], id)
  end
  table.sort(ks, function(a, b) return #g[a] > #g[b] end)
  for _, k in ipairs(ks) do
    print(("   d=%-10s x%-3d %s"):format(k, #g[k], table.concat(g[k], " ")))
  end
end

if #part > 0 then
  print(("\nPARTIAL -- one projection fixed, the free direction is what the drag/squash rule must "
      .. "settle (%d):"):format(#part))
  for i = 1, math.min(#part, 20) do
    local id = part[i] ; local e = eqs[id][1]
    print(("   %d: (%d,%d).d = %s"):format(id, e.n[1], e.n[2], tostring(e.c)))
  end
  if #part > 20 then print(("   ... %d more"):format(#part - 20)) end
end

if #declined > 0 then
  print(("\nDECLINED diagonals -- these walls must SKEW (soft, not an infeasibility) (%d):")
    :format(#declined))
  for i = 1, math.min(#declined, 20) do
    local r = declined[i]
    print(("   %s %s-%s (%s) via %d [%s]"):format(r.edge.dir, r.edge.a, r.edge.b,
      FAM[r.edge.fam].label, r.from, r.why))
  end
  if #declined > 20 then print(("   ... %d more"):format(#declined - 20)) end
end

if #conflict > 0 then
  print(("\n⛔ AXIAL CONFLICTS -- hard equalities disagree, the seed is over-determined (%d):")
    :format(#conflict))
  for i = 1, math.min(#conflict, 20) do
    local r = conflict[i]
    print(("   %s %s-%s (%s) via %d [%s]"):format(r.edge.dir, r.edge.a, r.edge.b,
      FAM[r.edge.fam].label, r.from, r.why))
  end
end

-- --------------------------------------------------------------------------- phase 2: the drag rule
-- Phase 1 is FORCED -- the equations leave no choice. What it does NOT fix is the free component of a
-- partially-determined room, and "0" is only the MINIMAL answer, not always a legal one: on rand,
-- 5307 moving north by 2 with its own column 5308/5309/5310 left at zero turns `5307 north-> 5308`
-- into a southward edge. That is the ordinary squash the engine's `eqw_forced_shift` already handles.
--   * an edge ACROSS axis a (de[a] == 0) demands EQUAL displacement on a -- the hard class lock;
--   * an edge ALONG it demands the gap keep its sign and stay >= 1 -- pure stretch is free, a squash
--     below 1 drags the free endpoint out.
-- ⚠ A component pinned by phase 1 may NOT be bumped. If both endpoints are pinned and the edge is
-- still violated, that is a genuine infeasibility of the seed and is reported, not papered over.
-- ⛔ NOT a global re-solve. Longest-path/LP compaction minimises each coordinate INDEPENDENTLY and is
-- recorded as destructive on sprawling maps (gore: 5 defects -> 917). This only ever pushes a free
-- component outward, from a violation, exactly like the closure it models.
local resid = {}
if OPT.drag then
  local fixedA, dv = {}, {}
  for _, id in ipairs(ORDER) do
    local f = { false, false }
    local d = { 0, 0 }
    if dsp[id] then f = { true, true } ; d = { dsp[id][1], dsp[id][2] }
    elseif #eqs[id] == 1 then
      local e = eqs[id][1]
      if e.fam == "col" then f[1] = true ; d[1] = e.c            -- (1,0).d = c pins dx
      elseif e.fam == "row" then f[2] = true ; d[2] = e.c end    -- (0,1).d = c pins dy
      -- u/v pin NEITHER component on their own: the free direction is not a coordinate axis
    end
    fixedA[id], dv[id] = f, d
  end
  -- ⭐⭐ THE DRAG RULE COPIES, IT DOES NOT COMPUTE. A first cut that solved each violated edge for a
  -- fresh displacement value never settled (201 rounds, thrashing): two free endpoints can each
  -- "repair" the edge by moving, and they take turns. The engine's rule has no such freedom -- a
  -- dragged room joins the plate and moves by exactly what dragged it. Copying restores the ORIGINAL
  -- gap `g`, which was truthful by construction, so one assignment always suffices.
  -- ⇒ each component is assigned AT MOST ONCE and then frozen. That makes this a monotone SET
  -- CLOSURE (O(V) assignments), which is what makes it terminate and what makes it comparable to
  -- `eqw_forced_shift` rather than to a solver.
  local rounds, wl, wh = 0, {}, 1
  for _, id in ipairs(ORDER) do if dsp[id] or #eqs[id] > 0 then wl[#wl + 1] = id end end
  local rseen = {}
  local function take(x, a, val, e, kind, g2)
    if fixedA[x][a] then
      -- an edge is reached from BOTH endpoints and a room can re-enter the worklist, so dedup or the
      -- same residual prints two and four times
      local k = e.a .. ":" .. e.b .. ":" .. a
      if dv[x][a] ~= val and not rseen[k] then
        rseen[k] = true ; resid[#resid + 1] = { e = e, a = a, kind = kind, g2 = g2 }
      end
      return false
    end
    dv[x][a] = val ; fixedA[x][a] = true ; wl[#wl + 1] = x
    return true
  end
  while wh <= #wl and rounds < 100000 do
    local r = wl[wh] ; wh = wh + 1 ; rounds = rounds + 1
    for _, e in ipairs(INC[r]) do
      local u, w = e.a, e.b
      local de = D[e.dir]
      if ROOMS[u].exits[e.dir] ~= w then u, w = w, u end          -- orient along the declared exit
      for a = 1, 2 do
        if fixedA[u][a] or fixedA[w][a] then
          local g = P[w][a] - P[u][a]
          local g2 = g + dv[w][a] - dv[u][a]
          if de[a] == 0 then                                      -- across the axis: hard class lock
            if g2 ~= 0 then
              if fixedA[u][a] then take(w, a, dv[u][a], e, "class-lock", g2)
              else take(u, a, dv[w][a], e, "class-lock", g2) end
            end
          elseif g2 * de[a] < 1 then                              -- squashed below length 1: drag
            if fixedA[u][a] then take(w, a, dv[u][a], e, "squash", g2)
            else take(u, a, dv[w][a], e, "squash", g2) end
          end
        end
      end
    end
  end
  for _, id in ipairs(ORDER) do
    if dv[id][1] ~= 0 or dv[id][2] ~= 0 then dsp[id] = dv[id] elseif dsp[id] then dsp[id] = dv[id] end
  end
  local nm = 0
  for _, id in ipairs(ORDER) do if dsp[id] and (dsp[id][1] ~= 0 or dsp[id][2] ~= 0) then nm = nm + 1 end end
  print(("\nDRAG: settled in %d round(s), %d room(s) move, %d unresolvable edge(s)")
    :format(rounds, nm, #resid))
  local g, ks = {}, {}
  for _, id in ipairs(ORDER) do
    local d = dsp[id]
    if d and (d[1] ~= 0 or d[2] ~= 0) then
      local k = fmt(d) ; if not g[k] then g[k] = {} ; ks[#ks + 1] = k end
      table.insert(g[k], id)
    end
  end
  table.sort(ks, function(x, y) return #g[x] > #g[y] end)
  for _, k in ipairs(ks) do
    print(("   d=%-10s x%-3d %s"):format(k, #g[k], table.concat(g[k], " ")))
  end
  for i = 1, math.min(#resid, 12) do
    local r = resid[i]
    print(("   ⛔ %s on axis %d: %s %s-%s (gap %s)")
      :format(r.kind, r.a, r.e.dir, r.e.a, r.e.b, tostring(r.g2)))
  end
end

-- --------------------------------------------------------------------------- apply + census
-- ⚠ Only FULLY DETERMINED rooms move. A partial room's free component is a real choice the drag rule
-- owns, and picking one here would report a geometry the algebra did not derive.
if OPT.apply then
  local function census(Q)
    local cell, dup = {}, 0
    for _, id in ipairs(ORDER) do
      local k = Q[id][1] .. ":" .. Q[id][2]
      if cell[k] then dup = dup + 1 else cell[k] = id end
    end
    local skew, lie = 0, 0
    for _, e in ipairs(EDGES) do
      local de = D[e.dir]
      local dx, dy = Q[e.b][1] - Q[e.a][1], Q[e.b][2] - Q[e.a][2]
      local a1, b1 = e.a, e.b
      -- EDGES stores a<b but `dir` was read from whichever end declared it; recover the sign
      if ROOMS[e.a].exits[e.dir] ~= e.b then dx, dy = -dx, -dy ; a1, b1 = b1, a1 end
      local vx, vy = de[1], de[2]
      if (vx == 0) ~= (dx == 0) or (vy == 0) ~= (dy == 0) or dx * vx < 0 or dy * vy < 0 then
        lie = lie + 1
      elseif vx ~= 0 and vy ~= 0 and math.abs(dx) ~= math.abs(dy) then skew = skew + 1 end
    end
    local cross = 0
    for i = 1, #EDGES do
      for j = i + 1, #EDGES do
        local a, b = EDGES[i], EDGES[j]
        if a.a ~= b.a and a.a ~= b.b and a.b ~= b.a and a.b ~= b.b then
          local p, q, r, s = Q[a.a], Q[a.b], Q[b.a], Q[b.b]
          local function cp(o, u, v) return (u[1]-o[1])*(v[2]-o[2]) - (u[2]-o[2])*(v[1]-o[1]) end
          local d1, d2, d3, d4 = cp(r,s,p), cp(r,s,q), cp(p,q,r), cp(p,q,s)
          if ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0)) then cross = cross + 1 end
        end
      end
    end
    local roe = 0
    for _, e in ipairs(EDGES) do
      local p, q = Q[e.a], Q[e.b]
      local dx, dy = q[1] - p[1], q[2] - p[2]
      for _, id in ipairs(ORDER) do
        if id ~= e.a and id ~= e.b then
          local x, y = Q[id][1], Q[id][2]
          if (x - p[1]) * dy - (y - p[2]) * dx == 0
             and x >= math.min(p[1], q[1]) and x <= math.max(p[1], q[1])
             and y >= math.min(p[2], q[2]) and y <= math.max(p[2], q[2]) then roe = roe + 1 end
        end
      end
    end
    return ("collide=%d lie=%d cross=%d room-on-edge=%d skew-diag=%d")
      :format(dup, lie, cross, roe, skew)
  end
  local Q = {}
  for _, id in ipairs(ORDER) do
    local d = dsp[id]
    Q[id] = d and { P[id][1] + d[1], P[id][2] + d[2] } or { P[id][1], P[id][2] }
  end
  print("\nbefore  " .. census(P))
  print("after   " .. census(Q))
end
