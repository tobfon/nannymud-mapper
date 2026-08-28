-- Harness for elro.count_defects -- the shared defect scanner every layout gate calls BEFORE and
-- AFTER every trial move, and (measured on two large areas, kadagar and the world map) ~32% of the
-- background relayout's over-budget probes.
--
-- Run:  luajit analysis/test_count_defects.lua        (from client/)
--       BENCH=0 luajit analysis/test_count_defects.lua   -- correctness only, no timings
--
-- ⭐ WHAT THIS CAN AND CANNOT PROVE.
--   CAN: that the optimised scanner returns EXACTLY the old four numbers. The optimisation is meant
--        to be output-identical -- unlike the cell_overlap plan, there is no blocker identity to
--        tie-break here, count_defects returns counts only. So "not one number moved on any input"
--        is the whole correctness claim, and it is checkable.
--   CANNOT: predict the speedup in Mudlet. This box only has LuaJIT; Mudlet is stock Lua 5.1. The
--        benchmark below runs with the JIT OFF as the closer analogue, and it is still only
--        indicative -- memory records a harness that predicted 4.2% and delivered 58%. The real
--        number comes from `lua elro.timeGuillo = true` in game (_cdT / _cdN).
--
-- THREE implementations are compared, never two:
--   brute  -- in this file, no index at all, transcribed from the DEFINITION of each defect
--   ref    -- cd_ref.lua, the frozen pre-optimisation body (the BEFORE side of the benchmark)
--   live   -- cut out of lua/layout.lua at run time, so it can never go stale
-- brute-vs-ref catches "I froze the reference wrong"; ref-vs-live is the actual claim.

local FAIL, CHECKS = 0, 0
local function ok(c, w) CHECKS = CHECKS + 1
  if c then return true end
  FAIL = FAIL + 1 ; print("  FAIL " .. w) ; return false
end

-- ------------------------------------------------------------------ the live cut
-- Cut `function elro.count_defects ... end` straight out of the engine file. No generated
-- intermediate file, so there is no re-cut step to forget (topo_extract.sh's stale-extract hazard).
local function cut_live(path)
  local src, inside = {}, false
  for line in io.lines(path) do
    if not inside and line:match("^function elro%.count_defects") then inside = true end
    if inside then
      src[#src + 1] = line
      if line == "end" and #src > 1 then break end
    end
  end
  assert(#src > 2, "could not find elro.count_defects in " .. path)
  local chunk = assert(loadstring(table.concat(src, "\n"), "@" .. path))
  chunk()
  return elro.count_defects, #src
end

_G.elro = { bg_tick = function() end, crossBucket = 4 }
local live, nlines = cut_live("lua/canvas.lua")
local ref = dofile("analysis/cd_ref.lua")
print(("cut live count_defects (%d lines) out of lua/canvas.lua"):format(nlines))

-- ------------------------------------------------------------------ the oracle
-- Straight from the definitions, all-pairs, no spatial structure whatsoever. Deliberately the
-- stupidest possible code: this is the thing that decides whether the clever code is right.
--   overlap      : rooms beyond the first in a cell  (a cell with k rooms scores k-1, NOT k(k-1)/2)
--   room-on-edge : a placed room, not an endpoint OF THIS EDGE, whose cell lies on the closed segment
--   crossing     : the engine's strict-sign straddle test, per unordered edge pair sharing no room id
local function brute(coord, placed, pedges)
  local cnt, nOv, nRoe, nX = 0, 0, 0, 0
  local cellOf = {}
  for rr in pairs(placed) do
    local p = coord[rr]
    if p then local k = p[1] .. ":" .. p[2]
      if cellOf[k] then cnt = cnt + 1 ; nOv = nOv + 1 else cellOf[k] = rr end
    end
  end
  local function ori(ax, ay, bx, by, cx, cy) return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax) end
  for _, e in ipairs(pedges) do
    local c, d = coord[e.u], coord[e.v]
    if c and d then
      local xlo, xhi = math.min(c[1], d[1]), math.max(c[1], d[1])
      local ylo, yhi = math.min(c[2], d[2]), math.max(c[2], d[2])
      for rr in pairs(placed) do
        if rr ~= e.u and rr ~= e.v then
          local p = coord[rr]
          if p and p[1] >= xlo and p[1] <= xhi and p[2] >= ylo and p[2] <= yhi
             and ori(c[1], c[2], d[1], d[2], p[1], p[2]) == 0 then cnt = cnt + 1 ; nRoe = nRoe + 1 end
        end
      end
    end
  end
  for i = 1, #pedges do
    local e1 = pedges[i] ; local a, b = coord[e1.u], coord[e1.v]
    if a and b then
      for j = i + 1, #pedges do
        local e2 = pedges[j]
        if e1.u ~= e2.u and e1.u ~= e2.v and e1.v ~= e2.u and e1.v ~= e2.v then
          local c, d = coord[e2.u], coord[e2.v]
          if c and d then
            local d1 = ori(c[1], c[2], d[1], d[2], a[1], a[2])
            local d2 = ori(c[1], c[2], d[1], d[2], b[1], b[2])
            local d3 = ori(a[1], a[2], b[1], b[2], c[1], c[2])
            local d4 = ori(a[1], a[2], b[1], b[2], d[1], d[2])
            if ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0)) then cnt = cnt + 1 ; nX = nX + 1 end
          end
        end
      end
    end
  end
  return cnt, nOv, nRoe, nX
end

-- ------------------------------------------------------------------ comparison
local function fmt(a, b, c, d) return ("%d (ov %d roe %d x %d)"):format(a or -1, b or -1, c or -1, d or -1) end

local worst = nil
local function agree(what, coord, placed, pedges, B)
  elro.crossBucket = B
  local b1, b2, b3, b4 = brute(coord, placed, pedges)
  local r1, r2, r3, r4 = ref(coord, placed, pedges, B)
  local l1, l2, l3, l4 = live(coord, placed, pedges)
  local okr = ok(b1 == r1 and b2 == r2 and b3 == r3 and b4 == r4,
    ("%s B=%d: FROZEN REF disagrees with brute -- brute %s, ref %s"):format(what, B, fmt(b1, b2, b3, b4), fmt(r1, r2, r3, r4)))
  local okl = ok(b1 == l1 and b2 == l2 and b3 == l3 and b4 == l4,
    ("%s B=%d: LIVE disagrees with brute -- brute %s, live %s"):format(what, B, fmt(b1, b2, b3, b4), fmt(l1, l2, l3, l4)))
  if not (okr and okl) and not worst then worst = { coord = coord, placed = placed, pedges = pedges, B = B, what = what } end
  return b1, b2, b3, b4
end

-- ------------------------------------------------------------------ generators
-- Every awkward shape the engine can hand this function, on purpose:
--   rooms in `placed` with NO coord (mid-walk, not yet placed)
--   edges whose endpoints are not in `placed` at all
--   duplicate edges, and self/zero-length edges (a room shifted onto its neighbour)
--   long chords (the case where a bbox spans many buckets but holds almost no lattice points)
local function gen(seed, opt)
  math.randomseed(seed)
  opt = opt or {}
  local N = opt.N or math.random(4, 60)
  local W = opt.W or math.max(2, math.floor(math.sqrt(N) * (opt.spread or 1.2)))
  local coord, placed, ids = {}, {}, {}
  for i = 1, N do
    local id = i * 7                                  -- non-contiguous ids, like real room numbers
    ids[#ids + 1] = id ; placed[id] = true
    if math.random() < (opt.unplaced or 0.05) then coord[id] = nil
    else coord[id] = { math.random(-W, W), math.random(-W, W) } end
  end
  local pedges = {}
  local E = opt.E or math.random(0, N * 2)
  for _ = 1, E do
    local u, v = ids[math.random(#ids)], ids[math.random(#ids)]
    local roll = math.random()
    if roll < 0.05 then v = u                          -- degenerate: both ends the same room
    elseif roll < 0.10 then v = 999999                 -- endpoint not placed / no coord
    end
    pedges[#pedges + 1] = { u = u, v = v }
  end
  if opt.dup and #pedges > 0 then                      -- duplicate a few edges verbatim
    for _ = 1, 3 do local e = pedges[math.random(#pedges)] ; pedges[#pedges + 1] = { u = e.u, v = e.v } end
  end
  return coord, placed, pedges
end

-- a dense lattice: maximises collinearity, which is where room-on-edge and the sign tests get hard
local function gen_lattice(seed, n, step)
  math.randomseed(seed)
  local coord, placed, ids, pedges = {}, {}, {}, {}
  for x = 0, n - 1 do for y = 0, n - 1 do
    local id = (x * n + y + 1) * 3
    ids[#ids + 1] = id ; placed[id] = true ; coord[id] = { x * step, y * step }
  end end
  for _ = 1, n * n do
    pedges[#pedges + 1] = { u = ids[math.random(#ids)], v = ids[math.random(#ids)] }
  end
  return coord, placed, pedges
end

-- ------------------------------------------------------------------ real areas
local DIRS = { north = true, south = true, east = true, west = true,
               northeast = true, northwest = true, southeast = true, southwest = true }
local function load_dump(file)
  local coord, placed, adj, ids = {}, {}, {}, {}
  local fh = io.open("analysis/" .. file)
  if not fh then return nil end
  fh:close()
  for line in io.lines("analysis/" .. file) do
    local id, x, y = line:match("^%s*(%d+)%s+%(?(-?%d+),?%s*(-?%d+)")
    if id then
      id = tonumber(id)
      coord[id] = { tonumber(x), tonumber(y) } ; placed[id] = true ; adj[id] = {} ; ids[#ids + 1] = id
      for d, t in line:gmatch("(%a+)%s*%->%s*(%d+)") do if DIRS[d] then adj[id][d] = tonumber(t) end end
      for d, t in line:gmatch("(%a+):(%d+)")        do if DIRS[d] then adj[id][d] = tonumber(t) end end
    end
  end
  local seen, pedges = {}, {}
  for _, u in ipairs(ids) do
    for _, v in pairs(adj[u]) do
      if coord[v] then
        local k = (u < v) and (u .. ":" .. v) or (v .. ":" .. u)
        if not seen[k] then seen[k] = true ; pedges[#pedges + 1] = { u = u, v = v } end
      end
    end
  end
  return coord, placed, pedges, #ids
end

-- ============================================================== 1. RANDOM TRIALS
print("1. random layouts: live == frozen ref == brute force, on all four returns")
local TRIALS = tonumber(os.getenv("TRIALS")) or 1200
local tot = { 0, 0, 0, 0 }
for s = 1, TRIALS do
  local B = ({ 1, 2, 3, 4, 8 })[(s % 5) + 1]
  local coord, placed, pedges = gen(s, { dup = (s % 3 == 0) })
  local a, b, c, d = agree("random#" .. s, coord, placed, pedges, B)
  tot[1] = tot[1] + a ; tot[2] = tot[2] + b ; tot[3] = tot[3] + c ; tot[4] = tot[4] + d
  if FAIL > 0 then break end
end
print(("   %d trials, %s defects seen in total"):format(TRIALS, fmt(tot[1], tot[2], tot[3], tot[4])))
-- ⚠ a harness that agrees because every case was empty proves nothing. Measure the population.
ok(tot[2] > 0, "population: random trials produced at least one OVERLAP")
ok(tot[3] > 0, "population: random trials produced at least one ROOM-ON-EDGE")
ok(tot[4] > 0, "population: random trials produced at least one CROSSING")

print("2. dense lattices (maximal collinearity) at several grid steps")
for _, step in ipairs({ 1, 2, 3, 5 }) do
  for _, B in ipairs({ 1, 4, 8 }) do
    local coord, placed, pedges = gen_lattice(step * 100 + B, 9, step)
    local a, b, c, d = agree(("lattice step=%d"):format(step), coord, placed, pedges, B)
    if B == 4 then print(("   step %d: %s"):format(step, fmt(a, b, c, d))) end
  end
end

print("3. long-chord stress (bboxes spanning many buckets, few lattice points inside)")
for s = 1, 200 do
  local B = ({ 1, 2, 4, 8 })[(s % 4) + 1]
  local coord, placed, pedges = gen(90000 + s, { N = 80, spread = 6, E = 200 })
  agree("chord#" .. s, coord, placed, pedges, B)
  if FAIL > 0 then break end
end
print("   200 sparse/long-edge trials")

print("4. real area dumps")
local REAL = {}
for _, f in ipairs({ "world_block.txt", "lyr.txt", "titleist.txt", "mael.txt" }) do
  local coord, placed, pedges, n = load_dump(f)
  if coord then
    REAL[#REAL + 1] = { f = f, coord = coord, placed = placed, pedges = pedges, n = n }
    local a, b, c, d = agree(f, coord, placed, pedges, 4)
    print(("   %-16s %3d rooms, %3d edges -> %s"):format(f, n, #pedges, fmt(a, b, c, d)))
  end
end

-- ================================================================== 5. BENCHMARK
if os.getenv("BENCH") ~= "0" then
  print("5. benchmark (JIT OFF -- the closest this box gets to Mudlet's stock 5.1 interpreter)")
  if type(jit) == "table" and jit.off then jit.off(nil, true) end
  elro.crossBucket = 4
  local function bench(name, coord, placed, pedges, reps)
    local t0 = os.clock() ; for _ = 1, reps do ref(coord, placed, pedges, 4) end
    local tr = os.clock() - t0
    t0 = os.clock() ; for _ = 1, reps do live(coord, placed, pedges) end
    local tl = os.clock() - t0
    print(("   %-22s ref %7.1fms  live %7.1fms   %5.2fx  (%d reps)")
      :format(name, tr * 1000, tl * 1000, tr / math.max(tl, 1e-9), reps))
    return tr, tl
  end
  local TR, TL = 0, 0
  for _, R in ipairs(REAL) do
    -- enough reps that os.clock's ~1ms granularity is not the measurement
    local a, b = bench(("%s (%dr)"):format(R.f:gsub("%.txt", ""), R.n), R.coord, R.placed, R.pedges, 1500)
    TR, TL = TR + a, TL + b
  end
  local coord, placed, pedges = gen_lattice(1, 24, 1)         -- 576 rooms, the size that hurts
  local a, b = bench("lattice 576r/576e", coord, placed, pedges, 30)
  TR, TL = TR + a, TL + b
  print(("   %-22s ref %7.1fms  live %7.1fms   %5.2fx  OVERALL")
    :format("TOTAL", TR * 1000, TL * 1000, TR / math.max(TL, 1e-9)))
  print("   ⚠ indicative only. The number that decides this is _cdT/_cdN in game.")
end

print("")
if FAIL == 0 then print(("ALL PASS (%d checks)"):format(CHECKS))
else print(("%d FAILURE(S) of %d checks"):format(FAIL, CHECKS)) ; os.exit(1) end
