-- Drives the REAL elro.wire_cross out of layout.lua (via wire_extract.sh) over the area dumps.
-- Run: luajit test_wire.lua            (add a dump filename to run just that one, verbosely)
--
-- WHAT EACH DUMP IS FOR:
--   mael_min.txt    the user's 16-room MINIMAL WITNESS -- must prove exactly ONE pair, and it must
--                   cover 4135-4136 x 4127-4128. This is the case the face/genus pass can detect
--                   the NEED for but has never been able to locate.
--   mael_edge.txt   maelstorm + the added 4248 -east-> 4119. Needs TWO crossings; the old pass only
--                   ever produces sites for one.
--   lyr.txt         must prove 2475-2490 x 2509-2512 -- the one crossing the EDGE-granularity
--                   forced_cross already proves. The wire test is a strict generalisation of it, so
--                   losing this would mean the V-and-H-share-no-room condition is too strong.
--   titleist*.txt   ZERO. Genus 0; their real crossings are free diagonal grid-X or removable.
--   world_block.txt ZERO. Predicted 0 crossings; its layout's 2 are the removable ones.
-- ⚠ A FALSE POSITIVE ON A PLANAR AREA IS THE FAILURE MODE OF THIS WHOLE CHANGE -- a stronger prover
-- laundering a fixable room-on-edge into an accepted crossing is exactly what must not happen.
_G.elro = {
  delta = { east={1,0}, west={-1,0}, north={0,1}, south={0,-1},
            northeast={1,1}, northwest={-1,1}, southeast={1,-1}, southwest={-1,-1} },
  reverse = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" },
  tr = function(s) print("    [tr] " .. s) end,
}
dofile("wire_extract.lua")
local function mk(adj) elro._wireCache, elro._wireAdj = nil, nil ; return elro.wire_cross(adj) end
local function ekey2(a, b) return (a < b) and (a .. ":" .. b) or (b .. ":" .. a) end

-- same loader as test_topo.lua: walk_branches symmetrises adj before anything sees it, so the
-- harness must too, or the two disagree about the same map (see [[project_asymmetric_exits]]).
local function load(file)
  local adj, coord = {}, {}
  for line in io.lines(file) do
    -- ⚠ TWO DUMP FORMATS and they need TWO coord patterns. `mapdumpsel` writes
    -- `4119 (5,7,0) area=... [east->4120]`; the older dumps write `4127 7 5 south:4128 north:4125`.
    -- Parsing only the first left `coord` EMPTY on mael.txt, and the budget assertions below then
    -- passed VACUOUSLY (0 sites crossing, nothing chosen, no failure reported) while defects.lua was
    -- naming a real crossing between two legal sites. Hence the hard coverage check after the loop:
    -- silence must not be able to look like success.
    local id, x, y = line:match("^%s*(%d+)%s*%((-?%d+),(-?%d+)")
    if not id then id, x, y = line:match("^%s*(%d+)%s+(-?%d+)%s+(-?%d+)") end
    if not id then id = line:match("^%s*(%d+)") end
    if id then
      id = tonumber(id)
      adj[id] = adj[id] or {}
      if x then coord[id] = { tonumber(x), tonumber(y) } end
      for d, t in line:gmatch("(%a+)%s*%->%s*(%d+)") do if elro.delta[d] then adj[id][d] = tonumber(t) end end
      for d, t in line:gmatch("(%a+):(%d+)")        do if elro.delta[d] then adj[id][d] = tonumber(t) end end
    end
  end
  for u, nb in pairs(adj) do
    for d, v in pairs(nb) do
      if adj[v] then
        local back = false
        for _, w in pairs(adj[v]) do if w == u then back = true break end end
        if not back then adj[v][elro.reverse[d]] = u end
      end
    end
  end
  for u, nb in pairs(adj) do for d, v in pairs(nb) do if not adj[v] then nb[d] = nil end end end
  return adj, coord
end

local fail, only = 0, arg and arg[1]
local function bad(msg) fail = fail + 1 ; print("      *** FAIL: " .. msg) end

local FILES = { "mael_min.txt", "mael_edge.txt", "mael.txt", "lyr.txt",
                "titleist.txt", "titleist_full.txt", "world_block.txt" }
local PLANAR = { ["titleist.txt"] = true, ["titleist_full.txt"] = true, ["world_block.txt"] = true }

for _, f in ipairs(FILES) do
 if not only or only == f then
  local adj, coord = load(f)
  local n, nc = 0, 0
  for _ in pairs(adj) do n = n + 1 end
  for _ in pairs(coord) do nc = nc + 1 end
  -- COVERAGE, not correctness: without coordinates every budget assertion below is vacuous.
  if nc < n then bad(f .. ": only " .. nc .. " of " .. n .. " rooms have coordinates") end
  local t0 = os.clock()
  local W = mk(adj)
  local ms = (os.clock() - t0) * 1000
  print(string.format("%-18s %4d rooms | forced pairs %d (min crossings >= %d) | infeasible: %d cycle-class(es), %d same-class arc(s) | %.1fms",
    f, n, W.n, W.min, W.cycles, W.sameClassArcs, ms))
  for _, b in ipairs(W.badArcs) do print("      same-class order arc: " .. b) end
  for i, p in ipairs(W.wires) do
    local vn, hn = #p.vm, #p.hm
    print(string.format("      pair %d: column wire of %d room(s) x row wire of %d room(s)"
      .. "   witness S=%s N=%s W=%s E=%s   sites %dv x %dh",
      i, vn, hn, tostring(p.S), tostring(p.N), tostring(p.W), tostring(p.E), p.vn, p.hn))
    local vs, hs = {}, {}
    for k in pairs(p.ves) do vs[#vs + 1] = k end ; table.sort(vs)
    for k in pairs(p.hes) do hs[#hs + 1] = k end ; table.sort(hs)
    print("        V edges: " .. table.concat(vs, " "))
    print("        H edges: " .. table.concat(hs, " "))
    -- ⚠ every reported wire edge must be AXIAL BY DIRECTION. A diagonal joins no class and so can
    -- never be part of a wire -- if one shows up here the class construction is wrong and the free
    -- grid-X exemption is no longer safe.
    -- ⚠ Test the DECLARED DIRECTION, never the dump's coordinates. An untruthful layout draws an
    -- axial edge diagonally (mael.txt has `lies 1`, and it is exactly 4125-4126), so a coordinate
    -- test flags a lie in the INPUT as a bug in the prover. The engine's own guard asks the same
    -- question the same way: `de[sameAxis] == 0`.
    for _, set in ipairs({ vs, hs }) do
      for _, k in ipairs(set) do
        local a, b = tonumber(k:match("^(%d+)")), tonumber(k:match(":(%d+)$"))
        local diag = nil
        for d, v in pairs(adj[a] or {}) do
          if v == b then local de = elro.delta[d]
            if de[1] ~= 0 and de[2] ~= 0 then diag = d else diag = nil ; break end
          end
        end
        if diag then bad("reported a DIAGONAL wire edge " .. k .. " (" .. diag .. ")") end
      end
    end
  end

  -- THE BUDGET, driven over the dump's OWN coordinates (which are a real layout the engine
  -- produced). A forced pair licenses ONE meeting, but `pair` holds the whole ves x hes cross
  -- product, so exactly one site may come back free and the rest must read over-budget. In game,
  -- before this existed, maelstorm accepted 10 crossings against a budget of 2.
  for i, p in ipairs(W.wires) do
    local best = elro.wire_site_min(p, coord)
    local nCross = 0
    for vk in pairs(p.ves) do for hk in pairs(p.hes) do
      local one = { { vk, hk } }
      local sub = { ves = { [vk] = true }, hes = { [hk] = true } }
      if elro.wire_site_min(sub, coord) then nCross = nCross + 1 end
      local _ = one
    end end
    print(string.format("      pair %d budget: %d of %d legal site(s) crossing in this layout"
      .. " -> free site %s", i, nCross, p.vn * p.hn, tostring(best)))
    if nCross > 0 and best == nil then bad("sites are crossing but no free site was chosen") end
    if nCross == 0 and best ~= nil then bad("chose a free site with nothing crossing") end
  end

  local function accepted(a1, b1, a2, b2)
    local k1, k2 = ekey2(a1, b1), ekey2(a2, b2)
    return W.pair[(k1 < k2) and (k1 .. "|" .. k2) or (k2 .. "|" .. k1)] == true
  end

  if f == "mael_min.txt" then
    if W.n ~= 1 then bad("the minimal witness must prove EXACTLY 1 pair, got " .. W.n) end
    local got = accepted(4135, 4136, 4127, 4128)
    print("      4135-4136 x 4127-4128 accepted: " .. tostring(got) .. "   (the witness's crossing)")
    if not got then bad("the minimal witness's own crossing is not accepted") end
  elseif f == "mael_edge.txt" then
    if W.n < 2 then bad("mael_edge needs TWO crossings, prover found " .. W.n) end
  elseif f == "lyr.txt" then
    local got = accepted(2475, 2490, 2509, 2512)
    print("      2475-2490 x 2509-2512 accepted: " .. tostring(got) .. "   (what forced_cross proves)")
    if not got then bad("lost the crossing edge-granularity forced_cross already proves") end
  elseif PLANAR[f] and W.n > 0 then
    bad("planar area proved " .. W.n .. " pair(s) -- a removable defect would be laundered here")
  end
 end
end

-- SCALE: the build runs once per walk but it runs INSIDE the walk, and perf is the standing concern
-- in this engine. Replicate maelstorm rather than a synthetic grid -- real shape, real class counts.
if not only then
  local base = load("mael.txt")
  for _, k in ipairs({ 1, 5, 20 }) do
    local adj, n = {}, 0
    for c = 0, k - 1 do
      local off = c * 100000
      for u, nb in pairs(base) do
        adj[u + off] = {} ; n = n + 1
        for d, v in pairs(nb) do adj[u + off][d] = v + off end
      end
    end
    local t0 = os.clock()
    local W = mk(adj)
    print(string.format("%2d x maelstorm (%4d rooms): %d pair(s), %.0fms", k, n, W.n,
      (os.clock() - t0) * 1000))
  end
  -- and the cheap dense-planar case, which is what most areas are. Every column wire meets every
  -- row wire AT A ROOM, so the disjointness condition must keep this at zero.
  local N = 40
  local adj = {}
  local function id(x, y) return y * 1000 + x + 1 end
  for y = 0, N - 1 do
    for x = 0, N - 1 do
      local u = id(x, y) ; adj[u] = adj[u] or {}
      if x < N - 1 then local v = id(x + 1, y) ; adj[u].east = v ; adj[v] = adj[v] or {} ; adj[v].west = u end
      if y < N - 1 then local v = id(x, y + 1) ; adj[u].north = v ; adj[v] = adj[v] or {} ; adj[v].south = u end
    end
  end
  local t0 = os.clock()
  local W = mk(adj)
  print(string.format("%dx%d grid   (%4d rooms): %d pair(s), %.0fms  (must be 0 -- every wire pair shares a room)",
    N, N, N * N, W.n, (os.clock() - t0) * 1000))
  if W.n > 0 then bad("a plain grid needs no crossing") end
end

print(fail == 0 and "\nALL OK" or ("\n" .. fail .. " FAILURE(S)"))
