-- CYCLE SIZES BEFORE COORDINATES -- how big does each rigid inner shape NEED to be?
--
--   luajit analysis/test_cycles.lua analysis/rand.txt
--   luajit analysis/test_cycles.lua analysis/nib_live.txt --top=12
--
-- Every exit FIXES its edge's direction; only the LENGTH is free. So walking a cycle and coming back
-- to the start is one equation:
--
--     sum_i  len_i * dir_i  =  0        len_i >= 1, integer
--
-- That is the whole "inner geometry" question, and it is answerable with no coordinates at all.
-- rand's rhombus (NE,NW,SW,SE with lengths a,b,c,d):
--     a(1,1) + b(-1,1) + c(-1,-1) + d(1,-1) = 0   =>   a = c,  b = d
-- minimal a=b=c=d=1, and growing it means a=c=2, b=d=2 -- the PARITY-2 QUANTUM that
-- [[project_eq_2d_shift]] found the hard way, derived here before anything is placed.
--
-- ⭐ WHY THIS MATTERS TO THE WALK: a plate changes essentially ONE edge length, but a cycle equation
-- constrains a COMBINATION of them. So no single 1D move can grow a cycle without breaking the
-- equation somewhere -- and "breaking it" is exactly the shear the lever tiers then chase. The user:
-- *"you cannot find a 1d move that expands the pentagon without shearing something... the damage is
-- already done."*
--
-- ⚠ WHAT THIS IS **NOT**. Satisfying every cycle equation does NOT give a legal layout: two rooms in
-- unrelated parts of the same component can still land in one cell, and nothing here sees that.
-- Cycle feasibility is necessary, not sufficient -- the collision machinery is still needed. What
-- this buys is that a rigid shape ARRIVES at its correct size instead of being grown into it.
--
-- ⚠ AND THE GLOBAL SYSTEM IS THE WHOLE LAYOUT PROBLEM. Given lengths satisfying every cycle
-- equation you can integrate around to get coordinates, and vice versa -- so solving ALL cycles at
-- once is not a cheaper subproblem, it IS the layout. The leverage comes from doing it PER SMALL
-- CORE: trees carry no cycle constraint at all, so every bit of the difficulty lives in the 2-core.

local dumpPath = arg[1] or error("usage: test_cycles.lua <dump> [--top=N] [--all]")
local TOP, ALL = 8, false
for i = 2, #arg do
  local n = arg[i]:match("^%-%-top=(%d+)$") ; if n then TOP = tonumber(n) end
  if arg[i] == "--all" then ALL = true end
end

local DELTA = { east = {1,0}, west = {-1,0}, north = {0,1}, south = {0,-1},
                northeast = {1,1}, northwest = {-1,1},
                southeast = {1,-1}, southwest = {-1,-1} }
local REV = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" }

-- ------------------------------------------------------------------- the dump
-- same format the other harnesses read: `id (x,y,z) area=NAME [dir->id, ...]`
local POS, ADJ, ORDER = {}, {}, {}
do
  local f = assert(io.open(dumpPath, "r"))
  for ln in f:lines() do
    local id, x, y, ex = ln:match("^%s*(%d+) %((-?%d+),(-?%d+),%-?%d+%) area=%S+ %[(.*)%]%s*$")
    if id then
      id = tonumber(id)
      POS[id] = { tonumber(x), tonumber(y) } ; ORDER[#ORDER + 1] = id
      ADJ[id] = ADJ[id] or {}
      for d, t in ex:gmatch("(%a+)%->(%d+)") do
        if DELTA[d] then ADJ[id][d] = tonumber(t) end
      end
    end
  end
  f:close()
end
-- symmetrise: an exit walked one way is an edge both ways (the engine's own assumption -- see the
-- asymmetric-exit fix; without it the 2-core and the cycle basis are both wrong)
for _, u in ipairs(ORDER) do
  for d, v in pairs(ADJ[u]) do
    if POS[v] and ADJ[v] then
      local back ; for d2, w in pairs(ADJ[v]) do if w == u then back = d2 end end
      if not back then ADJ[v][REV[d]] = u end
    end
  end
end
local function dir_of(u, v)
  -- ⚠ sorted, never `pairs`: a room can advertise two exits to the same neighbour and the choice
  -- must not depend on the hash seed
  local best
  for d, w in pairs(ADJ[u]) do
    if w == v and (not best or d < best) then best = d end
  end
  return best
end

-- --------------------------------------------------------------------- 2-core
-- peel degree-1 repeatedly. What survives carries every cycle; the pendant trees hanging off it are
-- unconstrained (a tree can always be drawn), which is the whole reason this decomposition pays.
local core = {}
for _, u in ipairs(ORDER) do core[u] = true end
local nbrs = {}
local function neighbours(u)
  local t = {}
  for _, v in pairs(ADJ[u] or {}) do if POS[v] then t[v] = true end end
  local l = {} ; for v in pairs(t) do l[#l + 1] = v end ; table.sort(l) ; return l
end
for _, u in ipairs(ORDER) do nbrs[u] = neighbours(u) end
local changed = true
while changed do
  changed = false
  for _, u in ipairs(ORDER) do
    if core[u] then
      local d = 0
      for _, v in ipairs(nbrs[u]) do if core[v] then d = d + 1 end end
      if d <= 1 then core[u] = false ; changed = true end
    end
  end
end
local coreN = 0 ; for _, u in ipairs(ORDER) do if core[u] then coreN = coreN + 1 end end

-- ------------------------------------------------------- fundamental cycle basis
-- ⛔⛔⛔ THIS BASIS IS **DETERMINISTIC BUT NOT CANONICAL**, AND analysis/README.md ALREADY WARNS
-- ABOUT EXACTLY THIS. A different spanning tree gives a different fundamental basis, so the cycle
-- list -- and every `slack` number derived from it -- is ONE basis among many. `chords.lua` was
-- abandoned for the same defect: *"It seeds from an arbitrary DFS cycle... The answer changed
-- between two runs purely from pairs() ordering. If this is ever revived it must seed from the
-- ROTATION SYSTEM'S FACES (canonical), not a DFS cycle."*
-- ⇒ The canonical basis is the FACE BOUNDARIES, and the engine ships them: `elro.faces(nodeset,
-- adj)` plus `elro.pick_outer_face`. `test_facefit.lua` uses those (via analysis/engine_load.lua)
-- and should be preferred; this file's totals are a first-cut signal, not an invariant.
-- ⚠ Sorting everything below makes the output REPRODUCIBLE, which is not the same as canonical --
-- do not read reproducibility as correctness here.
-- BFS spanning forest over the core; every NON-TREE edge closes exactly one fundamental cycle.
-- Deterministic throughout (sorted neighbour lists, ORDER as the root sequence).
local par, depth, seen = {}, {}, {}
local treeEdge = {}
local function ekey(a, b) if a > b then a, b = b, a end return a .. ":" .. b end
for _, r in ipairs(ORDER) do
  if core[r] and not seen[r] then
    seen[r], depth[r] = true, 0
    local q, qh = { r }, 1
    while qh <= #q do
      local u = q[qh] ; qh = qh + 1
      for _, v in ipairs(nbrs[u]) do
        if core[v] and not seen[v] then
          seen[v], par[v], depth[v] = true, u, depth[u] + 1
          treeEdge[ekey(u, v)] = true
          q[#q + 1] = v
        end
      end
    end
  end
end
local cycles = {}
do
  local done = {}
  for _, u in ipairs(ORDER) do
    if core[u] then
      for _, v in ipairs(nbrs[u]) do
        local k = ekey(u, v)
        if core[v] and not treeEdge[k] and not done[k] then
          done[k] = true
          -- path u..lca..v through the tree
          local a, b, pa, pb = u, v, {}, {}
          while depth[a] > depth[b] do pa[#pa + 1] = a ; a = par[a] end
          while depth[b] > depth[a] do pb[#pb + 1] = b ; b = par[b] end
          while a ~= b do
            pa[#pa + 1] = a ; a = par[a]
            pb[#pb + 1] = b ; b = par[b]
          end
          local ring = {}
          for i = 1, #pa do ring[#ring + 1] = pa[i] end
          ring[#ring + 1] = a
          for i = #pb, 1, -1 do ring[#ring + 1] = pb[i] end
          cycles[#cycles + 1] = ring
        end
      end
    end
  end
end

-- ------------------------------------------------- the equation, and the minimal solve
-- residual at ALL-UNIT lengths. Zero => the cycle closes with every edge at length 1, i.e. it is
-- already as small as it can be. Non-zero => something MUST stretch, and the residual says by how
-- much and in which direction, before any room is placed.
local function walk(ring)
  local es = {}
  for i = 1, #ring do
    local u, v = ring[i], ring[(i % #ring) + 1]
    local d = dir_of(u, v)
    if not d then return nil end
    es[#es + 1] = { u = u, v = v, d = d, D = DELTA[d] }
  end
  return es
end
-- Minimise sum(len) subject to sum(len_i * D_i) = 0, len_i >= 1. Coefficients are all in {-1,0,1},
-- so a greedy repair is exact here: each unit added to an edge moves the residual by that edge's
-- own direction, and we only ever add to an edge that reduces |residual| on the axis it is off.
local function solve(es)
  local len = {} ; for i = 1, #es do len[i] = 1 end
  local function resid()
    local rx, ry = 0, 0
    for i = 1, #es do rx = rx + len[i] * es[i].D[1] ; ry = ry + len[i] * es[i].D[2] end
    return rx, ry
  end
  for _ = 1, 200 do
    local rx, ry = resid()
    if rx == 0 and ry == 0 then return len, true end
    local bi, bg = nil, 0
    for i = 1, #es do
      local D = es[i].D
      -- gain = how much |residual| this unit removes, counting both axes
      local g = 0
      if rx ~= 0 and D[1] ~= 0 and ((rx > 0) ~= (D[1] > 0)) then g = g + 1 end
      if ry ~= 0 and D[2] ~= 0 and ((ry > 0) ~= (D[2] > 0)) then g = g + 1 end
      if rx ~= 0 and D[1] ~= 0 and ((rx > 0) == (D[1] > 0)) then g = g - 1 end
      if ry ~= 0 and D[2] ~= 0 and ((ry > 0) == (D[2] > 0)) then g = g - 1 end
      if g > bg then bg, bi = g, i end
    end
    if not bi then return len, false end                 -- no edge can reduce it: infeasible here
    len[bi] = len[bi] + 1
  end
  return len, false
end
-- what the SHIPPED layout actually spends on this cycle (the dump carries the in-game coordinates)
local function actual(es)
  local tot, skew = 0, 0
  for i = 1, #es do
    local a, b = POS[es[i].u], POS[es[i].v]
    local gx, gy = b[1] - a[1], b[2] - a[2]
    local L = math.max(math.abs(gx), math.abs(gy))
    tot = tot + L
    local D = es[i].D
    if D[1] ~= 0 and D[2] ~= 0 and math.abs(gx) ~= math.abs(gy) then skew = skew + 1 end
  end
  return tot, skew
end

local rows = {}
for _, ring in ipairs(cycles) do
  local es = walk(ring)
  if es then
    local len, ok = solve(es)
    local need = 0 ; for i = 1, #len do need = need + len[i] end
    local got, skew = actual(es)
    rows[#rows + 1] = { ring = ring, es = es, need = need, got = got, ok = ok,
                        slack = got - need, skew = skew, n = #es }
  end
end
table.sort(rows, function(a, b)
  if a.slack ~= b.slack then return a.slack > b.slack end
  return a.n < b.n
end)

print(("%s -- %d rooms, 2-core %d, %d independent cycle(s)")
  :format(dumpPath, #ORDER, coreN, #cycles))
print(("%-5s %-5s %-5s %-6s %-5s  %s"):format("edges", "need", "got", "slack", "skew", "cycle"))
local shown = 0
for _, r in ipairs(rows) do
  if ALL or shown < TOP then
    shown = shown + 1
    local ids = {}
    for i = 1, math.min(#r.ring, 10) do ids[#ids + 1] = r.ring[i] end
    if #r.ring > 10 then ids[#ids + 1] = "..." end
    print(("%-5d %-5d %-5d %-6d %-5d  %s%s"):format(
      r.n, r.need, r.got, r.slack, r.skew, table.concat(ids, "-"),
      r.ok and "" or "   [INFEASIBLE at unit steps]"))
  end
end
local tn, tg, inf = 0, 0, 0
for _, r in ipairs(rows) do
  tn = tn + r.need ; tg = tg + r.got ; if not r.ok then inf = inf + 1 end
end
-- ⚠⚠ READ THIS TOTAL NARROWLY. Each cycle is solved INDEPENDENTLY, so shared edges get different
-- lengths in different cycles and the sum is NOT a joint solution -- it is a sum of per-cycle lower
-- bounds. And `slack` is not waste: a cycle can only sit at its minimum if nothing has to NEST
-- INSIDE it (rand's rhombus contains the castle), and nothing here sees containment or collision.
-- ⭐ The one direction it IS safe in: `solve` is greedy, so `need` can only OVERSHOOT the true
-- minimum, which means the reported slack UNDERSTATES the excess rather than inflating it.
print(("TOTAL over %d cycles: need>=%d got=%d slack>=%d   infeasible=%d   (per-cycle bounds, not a joint solution)")
  :format(#rows, tn, tg, tg - tn, inf))
