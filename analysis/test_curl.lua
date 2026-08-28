-- WHICH RUNS CURL? -- the detector for the SYNTHETIC FACE of a 360-degree arm.
--
--   luajit analysis/test_curl.lua analysis/soulfly.txt
--
-- ⭐ THE HYPOTHESIS THIS TESTS (user's): the order DAG measures the size a face needs WITH CROSSINGS
-- PERMITTED, not planar. Order arcs come from EDGES, and the inner and outer turns of a spiral are
-- not joined by an edge -- so nothing in the DAG forbids them from overlapping, and the chain bound
-- happily returns a size that can only be drawn by letting the arm pass through itself. rand has no
-- winding anywhere and its DAG bound IS its planar truth (20, exact); soulfly's arm winds a full
-- turn and its bound comes out 34 against a hand-drawn planar 48.
--
-- So a curl needs its own SYNTHETIC ring: an arm that turns through 360 encloses a region exactly
-- like a face does, but the face enumeration cannot see it -- both of a bridge's darts land in the
-- SAME face, so `elro.faces` walks down it and straight back.
--
-- ⛔ TURNING NUMBER PROVES NOTHING ABOUT SELF-INTERSECTION for an OPEN arc (a spiral is simple).
-- What it IS good for is SEGMENTATION: where cumulative turning passes +/-180 the arm has folded
-- back on itself and gained an inside, and where it passes +/-360 it has closed a full loop.
dofile("analysis/engine_load.lua")
local dumpPath = arg[1] or error("usage: test_curl.lua <dump>")

local DELTA = { east = {1,0}, northeast = {1,1}, north = {0,1}, northwest = {-1,1},
                west = {-1,0}, southwest = {-1,-1}, south = {0,-1}, southeast = {1,-1} }
local FANG = { east = 0, northeast = 45, north = 90, northwest = 135,
               west = 180, southwest = 225, south = 270, southeast = 315 }
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
      if not back and ADJ[v][REV[d]] == nil then ADJ[v][REV[d]] = u end
    end
  end
end
for _, u in ipairs(ORDER) do
  for d, v in pairs(ADJ[u]) do
    local ok = false
    for _, w in pairs(ADJ[v] or {}) do if w == u then ok = true ; break end end
    if not ok then ADJ[u][d] = nil end
  end
end

-- one dart per neighbour, angle-sorted -- the same rotation system facefit builds
local rot, deg = {}, {}
for _, u in ipairs(ORDER) do
  local l, sv = {}, {}
  for d, v in pairs(ADJ[u] or {}) do
    if FANG[d] and v ~= u and not sv[v] then sv[v] = true ; l[#l+1] = { v = v, d = d, a = FANG[d] } end
  end
  table.sort(l, function(p, q) if p.a ~= q.a then return p.a < q.a end return p.v < q.v end)
  rot[u] = l ; deg[u] = #l
end
local function ang(u, v)
  for _, e in ipairs(rot[u]) do if e.v == v then return e.a end end
end

-- MAXIMAL RUNS OF DEGREE-2 ROOMS, between two rooms that are not degree 2. This is the same object
-- the chord scan uses, but over the WHOLE graph rather than the 2-core, so a pendant arm counts.
local runs, seen = {}, {}
for _, u in ipairs(ORDER) do
  if deg[u] ~= 2 then
    for _, e0 in ipairs(rot[u]) do
      if deg[e0.v] == 2 and not seen[e0.v] then
        local path, prev, cur = { u, e0.v }, u, e0.v
        while deg[cur] == 2 do
          seen[cur] = true
          local nxt
          for _, e in ipairs(rot[cur]) do if e.v ~= prev then nxt = e.v ; break end end
          if not nxt then break end
          path[#path + 1] = nxt ; prev, cur = cur, nxt
        end
        runs[#runs + 1] = path
      end
    end
  end
end

-- CUMULATIVE TURNING along the run, and the extremes it reaches
-- ⛔ A CLOSED RUN IS A FACE, NOT A CURL, AND IT TURNS 360 BY DEFINITION. leowon's `997-1013-...-997`
-- is its face 1 -- already enumerated, already priced -- and it is the ONLY thing besides soulfly's
-- arm that clears 360 in the whole corpus. Drop closed runs and the test fires on soulfly alone.
local out = {}
for _, p in ipairs(runs) do
  if #p >= 4 and p[1] ~= p[#p] then
    local t, lo, hi, at360 = 0, 0, 0, nil
    for i = 2, #p - 1 do
      local a = ang(p[i-1], p[i])
      local b = ang(p[i], p[i+1])
      if a and b then
        local dt = (b - a) % 360 ; if dt > 180 then dt = dt - 360 end
        t = t + dt
        if t < lo then lo = t end
        if t > hi then hi = t end
        if not at360 and math.abs(t) >= 360 then at360 = i end
      end
    end
    -- geometric span on the dumped coordinates, purely as a cross-check on the run's real shape
    local lox, hix, loy, hiy = math.huge, -math.huge, math.huge, -math.huge
    for _, r in ipairs(p) do
      local q = POS[r]
      if q then
        if q[1] < lox then lox = q[1] end ; if q[1] > hix then hix = q[1] end
        if q[2] < loy then loy = q[2] end ; if q[2] > hiy then hiy = q[2] end
      end
    end
    out[#out+1] = { p = p, turn = t, lo = lo, hi = hi, at360 = at360,
                    span = (hix - lox) .. "x" .. (hiy - loy) }
  end
end
table.sort(out, function(a, b) return math.abs(a.turn) > math.abs(b.turn) end)

print(string.format("%s: %d run(s) of degree-2 rooms, %d long enough to measure", dumpPath,
  #runs, #out))
print(string.format("%-6s %6s %7s %7s %7s %8s   %s", "rooms", "turn", "min", "max", "at360",
  "span", "path"))
for i = 1, math.min(#out, 12) do
  local o = out[i]
  local L = {}
  for j = 1, math.min(#o.p, 8) do L[#L+1] = o.p[j] end
  if #o.p > 8 then L[#L+1] = "..." ; L[#L+1] = o.p[#o.p] end
  print(string.format("%-6d %6d %7d %7d %7s %8s   %s", #o.p, o.turn, o.lo, o.hi,
    tostring(o.at360 or "-"), o.span, table.concat(L, "-")))
end
