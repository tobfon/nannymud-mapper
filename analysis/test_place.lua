-- PLACEMENT THAT HONOURS 45 DEGREES AND MINIMUM EDGE LENGTHS -- AND NOTHING ELSE.
--
--   luajit analysis/test_place.lua analysis/nib_live.txt
--   luajit analysis/test_place.lua analysis/rand.txt --core --min=1908:1911=2
--
-- The question this exists to answer, and it had NOT been asked: the engine resolves nib's 1956 with
-- the whole biconnected lever stack -- guillotines, cascades, plates, compaction. The user's point is
-- that **placing rooms while honouring 45-degree diagonals and minimum edge lengths is a far easier
-- problem than that**, and that the lever stack may largely be compensating for a placement that
-- never honoured those constraints to begin with.
--
-- ⛔ The earlier `MINLEN=` run did NOT test this. It asserted minimums and then let the entire
-- existing walk run, so every failure it produced belonged to the repair machinery (compaction
-- passes with their own hardcoded 1, levers parking slack into a diagonal) rather than to the idea.
--
-- SO: place in BFS order, and derive each room's coordinates from its ALREADY-PLACED neighbours by
-- the four-family rules only --
--     E/W  -> same row, free length >= m        N/S    -> same column, free length >= m
--     NE/SW-> v = x-y equal, free length >= m   NW/SE  -> u = x+y equal, free length >= m
-- -- taking the SMALLEST legal placement, and REPORTING every case where the constraints cannot all
-- be met at once. No levers, no plates, no compaction, no repair of any kind.
--
-- What the output means:
--   conflict   the placed neighbours DISAGREE about where this room goes. This is the real measure:
--              it is the number of times honouring truthfulness + 45 degrees + min length is
--              genuinely impossible at placement time, i.e. the number of situations that actually
--              need a lever. Everything else the walk currently levers is self-inflicted.
--   collide    two rooms on one cell. NOT a constraint violation -- these rules say nothing about
--              cells being distinct, which is exactly the job left over for the placement machinery.
--   skew/lie   must be ZERO by construction; printed as a self-check on the solver.

local dumpPath = arg[1] or error("usage: test_place.lua <dump> [--core] [--min=a:b=n,...] [-v]")
local CORE, VERB, MINSPEC = false, false, nil
for i = 2, #arg do
  if arg[i] == "--core" then CORE = true end
  if arg[i] == "-v" then VERB = true end
  local m = arg[i]:match("^%-%-min=(.+)$") ; if m then MINSPEC = m end
end

local DELTA = { east = {1,0}, northeast = {1,1}, north = {0,1}, northwest = {-1,1},
                west = {-1,0}, southwest = {-1,-1}, south = {0,-1}, southeast = {1,-1} }
local REV = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" }

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
for _, u in ipairs(ORDER) do
  for d, v in pairs(ADJ[u]) do
    if POS[v] then
      local back ; for d2, w in pairs(ADJ[v]) do if w == u then back = d2 end end
      if not back then ADJ[v][REV[d]] = u end
    end
  end
end
-- deterministic neighbour list (never `pairs` for anything that decides geometry)
local NB = {}
for _, u in ipairs(ORDER) do
  local l, seen = {}, {}
  for d, v in pairs(ADJ[u]) do
    if POS[v] and not seen[v] then seen[v] = true ; l[#l + 1] = { d = d, v = v } end
  end
  table.sort(l, function(a, b) return a.v < b.v end)
  NB[u] = l
end
local keep = {}
for _, u in ipairs(ORDER) do keep[u] = true end
if CORE then                                    -- 2-core: peel degree-1 repeatedly
  local ch = true
  while ch do
    ch = false
    for _, u in ipairs(ORDER) do
      if keep[u] then
        local d = 0
        for _, e in ipairs(NB[u]) do if keep[e.v] then d = d + 1 end end
        if d <= 1 then keep[u] = false ; ch = true end
      end
    end
  end
end
local MIN = {}
if MINSPEC then
  for kv in MINSPEC:gmatch("[^,]+") do
    local a, b, n = kv:match("^(%d+):(%d+)=(%d+)$")
    if not a then error("bad --min entry: " .. kv) end
    a, b = tonumber(a), tonumber(b)
    if a > b then a, b = b, a end
    MIN[a .. ":" .. b] = tonumber(n)
  end
end
local function minlen(u, v)
  local k = (u < v) and (u .. ":" .. v) or (v .. ":" .. u)
  return MIN[k] or 1
end

-- ---------------------------------------------------------------- the placement
-- A placed neighbour u constrains v to a RAY: `v = u + de * L`, L >= m. Intersecting the rays of all
-- placed neighbours is the whole solver -- no search, because each ray is one-dimensional and any
-- two non-parallel rays meet in at most one point.
local C = {}
local function ray_point(u, de, L) return { C[u][1] + de[1] * L, C[u][2] + de[2] * L } end
local function on_ray(p, u, de, m)
  local dx, dy = p[1] - C[u][1], p[2] - C[u][2]
  if de[1] == 0 then if dx ~= 0 then return false end
  elseif de[2] == 0 then if dy ~= 0 then return false end
  else if math.abs(dx) ~= math.abs(dy) then return false end end          -- 45 degrees
  local L = math.max(math.abs(dx), math.abs(dy))
  if L < m then return false end
  return dx == de[1] * L and dy == de[2] * L                              -- and the right direction
end

local nConf, nColl, conflicts = 0, 0, {}
local order = {}
for _, u in ipairs(ORDER) do if keep[u] then order[#order + 1] = u end end
-- ⚠ EVERY COMPONENT NEEDS ITS OWN SEED. rand's dump carries isolated out-of-area stub rooms, and
-- seeding on `order[1]` placed 2 of 91 rooms. Components are laid out independently here -- they
-- cannot constrain each other, and their relative offset is a packing question this file has no
-- opinion about.
local q, qh, queued = {}, 1, {}
local comps = 0
for _, s in ipairs(order) do
  if not C[s] then
    comps = comps + 1
    C[s] = { comps * 10000, 0 }      -- far apart: cross-component "collisions" would be meaningless
    q[#q + 1] = s ; queued[s] = true
  end
while qh <= #q do
  local u = q[qh] ; qh = qh + 1
  for _, e in ipairs(NB[u]) do
    local v = e.v
    if keep[v] and not C[v] then
      -- every already-placed neighbour of v, as a ray
      local rays = {}
      for _, f in ipairs(NB[v]) do
        if C[f.v] then
          rays[#rays + 1] = { u = f.v, de = DELTA[REV[f.d]], m = minlen(v, f.v) }
        end
      end
      -- candidate points: walk the FIRST ray outward and keep the first point every other ray
      -- accepts. Smallest legal placement, and it terminates -- the rays are straight.
      local r1, best = rays[1], nil
      for L = r1.m, 60 do
        local p = ray_point(r1.u, r1.de, L)
        local ok = true
        for i = 2, #rays do
          if not on_ray(p, rays[i].u, rays[i].de, rays[i].m) then ok = false ; break end
        end
        if ok then best = p ; break end
      end
      if best then
        C[v] = best
      else
        nConf = nConf + 1
        conflicts[#conflicts + 1] = { v = v, n = #rays }
        C[v] = ray_point(r1.u, r1.de, r1.m)     -- park it on its parent ray and carry on
      end
      if not queued[v] then queued[v] = true ; q[#q + 1] = v end
    end
  end
end
end

-- ------------------------------------------------------------------ self-check
local skew, lie, cells = 0, 0, {}
local seenE = {}
for _, u in ipairs(order) do
  for _, e in ipairs(NB[u]) do
    if C[u] and C[e.v] then
      local k = (u < e.v) and (u .. ":" .. e.v) or (e.v .. ":" .. u)
      if not seenE[k] then
        seenE[k] = true
        local de = DELTA[e.d]
        local dx, dy = C[e.v][1] - C[u][1], C[e.v][2] - C[u][2]
        if (de[1] == 0) ~= (dx == 0) or (de[2] == 0) ~= (dy == 0)
           or dx * de[1] < 0 or dy * de[2] < 0 then lie = lie + 1
        elseif de[1] ~= 0 and de[2] ~= 0 and math.abs(dx) ~= math.abs(dy) then skew = skew + 1 end
      end
    end
  end
end
for _, u in ipairs(order) do
  if C[u] then
    local k = C[u][1] .. ":" .. C[u][2]
    if cells[k] then nColl = nColl + 1 else cells[k] = u end
  end
end
print(("%s%s -- placed %d/%d   CONFLICT=%d   collide=%d   (self-check: lie=%d skew=%d)")
  :format(dumpPath, CORE and " [2-core]" or "", (function()
    local n = 0 for _ in pairs(C) do n = n + 1 end return n end)(), #order, nConf, nColl, lie, skew))
if VERB then
  for _, c in ipairs(conflicts) do
    print(("   conflict at %d (%d placed neighbour(s) disagree)"):format(c.v, c.n))
  end
end
