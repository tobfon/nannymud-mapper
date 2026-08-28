-- Drives the REAL eqw_topo_cross out of layout.lua (via topo_extract.sh) over the area dumps, and
-- checks the accepted pairs against what the standalone prototypes decided. Run: luajit test_topo.lua
_G.elro = {
  delta = { east={1,0}, west={-1,0}, north={0,1}, south={0,-1},
            northeast={1,1}, northwest={-1,1}, southeast={1,-1}, southwest={-1,-1} },
  reverse = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" },
  tr = function(s) print("    [tr] " .. s) end,
  bg_tick = function() end,
  topoBudget = tonumber(arg and arg[1]) or nil,
  topoFaceCap = tonumber(arg and arg[2]) or nil,
}
-- topo_cross reads its caps out of layout.lua's module-local TUNE, which the cut does not carry;
-- mirror the live defaults here (and re-sync if they move).
_G.TUNE = { topoRings = 4, topoFaceCap = 40, topoBudget = 200000 }
dofile("topo_extract.lua")
-- topo_cross is a MODULE function now; reset the memo between areas
local function mk(adj) elro._topoCache, elro._topoAdj = nil, nil
  return function() return elro.topo_cross(adj) end end
local function ekey2(a, b) return (a < b) and (a .. ":" .. b) or (b .. ":" .. a) end

local function load(file)
  local adj = {}
  for line in io.lines(file) do
    local id = line:match("^%s*(%d+)")
    if id then
      id = tonumber(id)
      adj[id] = adj[id] or {}
      for d, t in line:gmatch("(%a+)%s*%->%s*(%d+)") do if elro.delta[d] then adj[id][d] = tonumber(t) end end
      for d, t in line:gmatch("(%a+):(%d+)")        do if elro.delta[d] then adj[id][d] = tonumber(t) end end
    end
  end
  for u, nb in pairs(adj) do                    -- walk_branches symmetrises before anything sees adj
    for d, v in pairs(nb) do
      if adj[v] then
        local back = false
        for _, w in pairs(adj[v]) do if w == u then back = true break end end
        if not back then adj[v][elro.reverse[d]] = u end
      end
    end
  end
  for u, nb in pairs(adj) do for d, v in pairs(nb) do if not adj[v] then nb[d] = nil end end end
  return adj
end

local EXPECT = {
  ["mael.txt"]        = { "4208:4209|4209:4210", "4193:4208|4191:4209" },  -- see check below
  ["lyr.txt"]         = {},
  ["titleist.txt"]    = {},
  ["world_block.txt"] = {},
}
local fail = 0
for _, f in ipairs({ "mael.txt", "lyr.txt", "titleist.txt", "world_block.txt" }) do
  local adj = load(f)
  local t0 = os.clock()
  local T = mk(adj)()
  local ms = (os.clock() - t0) * 1000
  local ks = {}
  for k in pairs(T.pair) do ks[#ks + 1] = k end
  table.sort(ks)
  print(string.format("%-16s genus %.0f | non-closing faces %d | accepted pairs %d | %.1fms",
    f, T.genus, T.faces, T.n, ms))
  for _, k in ipairs(ks) do print("      " .. k) end

  -- the two areas with a real forced crossing must accept the pair the analysis named, and the two
  -- planar ones must accept NOTHING (accepting there would tolerate a removable defect)
  local function accepted(a1,b1,a2,b2)
    local k1,k2 = ekey2(a1,b1), ekey2(a2,b2)
    local k = (k1<k2) and (k1.."|"..k2) or (k2.."|"..k1)
    return T.pair[k] == true
  end
  if f == "lyr.txt" then
    local got = accepted(2475, 2490, 2509, 2512)
    print("      lyr 2475-2490 x 2509-2512 accepted: " .. tostring(got) .. "   (the REAL crossing)")
    if not got then fail = fail + 1 ; print("      *** FAIL") end
    if accepted(2475, 2490, 2473, 2474) then fail = fail + 1 ; print("      *** FAIL: accepted an unrelated pair") end
  elseif f == "mael.txt" then
    local got = accepted(4193, 4208, 4191, 4209)
    print("      mael 4193-4208 x 4191-4209 accepted: " .. tostring(got) .. "   (bridges 4208 x 4209)")
    if not got then fail = fail + 1 ; print("      *** FAIL") end
  elseif T.n > 0 then
    fail = fail + 1 ; print("      *** FAIL: planar area accepted " .. T.n .. " pair(s)")
  end
end
-- SCALE: the build runs once per walk, but it runs INSIDE the walk, and performance is the standing
-- concern in this engine. A plain grid is the cheap case (genus 0 -> the early exit). The expensive
-- case is a big NON-PLANAR scope, so replicate maelstorm -- real shape, real genus, real ring hunts --
-- rather than a synthetic grid, whose wrap edges just nest as concentric arcs and stay planar.
do
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
    local T = mk(adj)()
    print(string.format("%2d x maelstorm (%4d rooms): genus %.0f, %d non-closing face(s), %d pair(s), %.0fms",
      k, n, T.genus, T.faces, T.n, (os.clock() - t0) * 1000))
  end
end
-- and the cheap planar case at scale, which is what most areas actually are
do
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
  local T = mk(adj)()
  print(string.format("%dx%d grid   (%4d rooms): genus %.0f, %d non-closing face(s), %d pair(s), %.0fms  (the planar early exit)",
    N, N, N * N, T.genus, T.faces, T.n, (os.clock() - t0) * 1000))
end

print(fail == 0 and "\nALL OK" or ("\n" .. fail .. " FAILURE(S)"))
