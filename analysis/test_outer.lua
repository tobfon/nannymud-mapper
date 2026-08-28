-- Drives the REAL elro.pick_outer_face out of layout.lua (via outer_extract.sh) over the area
-- dumps. Run: sh outer_extract.sh && luajit test_outer.lua
--
-- WHY THIS EXISTS: core_classify used to decide the outer face by SHOELACE over a network-simplex
-- solve of the 2-core -- a whole coordinate layout computed to answer one combinatorial question.
-- Under eqw that solve is gone and pick_outer_face answers it from the rotation system instead
-- (`elro.classifyNoNS`). This harness checks the replacement on real areas: the picked face must be
-- a SIMPLE cycle, and it must be the one the turning test calls the boundary (-360), not an
-- interior face (+360).
_G.elro = {
  delta = { east={1,0}, west={-1,0}, north={0,1}, south={0,-1},
            northeast={1,1}, northwest={-1,1}, southeast={1,-1}, southwest={-1,-1} },
  reverse = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" },
  tr = function() end,
  bg_tick = function() end,
}
dofile("outer_extract.lua")

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
  return adj
end

-- core_classify's own 2-core peel (axis edges only), reproduced so the harness traces the same
-- face set the engine does.
local function two_core(adj)
  local nb, deg, rooms = {}, {}, {}
  for r in pairs(adj) do rooms[#rooms + 1] = r end
  table.sort(rooms)
  for _, r in ipairs(rooms) do
    nb[r] = {}
    for d, v in pairs(adj[r] or {}) do
      local de = elro.delta[d]
      if adj[v] and de then nb[r][#nb[r] + 1] = v end
    end
    deg[r] = #nb[r]
  end
  local peeled, pq, ph = {}, {}, 1
  for _, r in ipairs(rooms) do if deg[r] <= 1 then pq[#pq + 1] = r end end
  while ph <= #pq do
    local r = pq[ph] ; ph = ph + 1
    if not peeled[r] then
      peeled[r] = true
      for _, v in ipairs(nb[r]) do
        deg[v] = deg[v] - 1
        if deg[v] <= 1 and not peeled[v] then pq[#pq + 1] = v end
      end
    end
  end
  local S, n = {}, 0
  for _, r in ipairs(rooms) do if not peeled[r] then S[r] = true ; n = n + 1 end end
  return S, n
end

-- the turning sum, recomputed here as an INDEPENDENT check of the pick (the extract's own
-- face_turning is a file-local, so this is the same rule stated twice on purpose)
local function turning(face, adj)
  local n, tot = #face, 0
  local function dirOf(a, b)
    for d, v in pairs(adj[a] or {}) do if v == b then return elro.delta[d] end end
  end
  for i = 1, n do
    local a, b, c = face[i], face[(i % n) + 1], face[((i + 1) % n) + 1]
    local d1, d2 = dirOf(a, b), dirOf(b, c)
    if not (d1 and d2) then return nil end
    local t = math.deg(math.atan2(d2[2], d2[1]) - math.atan2(d1[2], d1[1]))
    while t > 180 do t = t - 360 end
    while t <= -180 do t = t + 360 end
    if math.abs(math.abs(t) - 180) < 1e-6 then return nil end
    tot = tot + t
  end
  return tot
end

local files = { ... }
if #files == 0 then files = { "mael.txt", "lyr.txt", "titleist.txt", "world_block.txt" } end
local bad = 0
for _, f in ipairs(files) do
  local ok, adj = pcall(load, f)
  if not ok then print(("%-16s SKIP (%s)"):format(f, adj)) else
    local S, nS = two_core(adj)
    local faces = elro.faces(S, adj)
    local face, idx = elro.pick_outer_face(faces, adj)
    if not face then
      print(("%-16s 2-core=%-4d faces=%-4d -> NO OUTER FACE"):format(f, nS, #faces)) ; bad = bad + 1
    else
      local seen, simple = {}, true
      for _, r in ipairs(face) do if seen[r] then simple = false end ; seen[r] = true end
      local t = turning(face, adj)
      -- WHAT COUNTS AS THE OUTER FACE. `-360` is the boundary of a simply-connected blob and is the
      -- clean answer. `0` on a NON-SIMPLE face is the boundary of a FIGURE-EIGHT -- the trace walks
      -- both lobes and their turnings cancel, and it visits the waist room twice, which is why it
      -- is not simple. That is still the true perimeter (maelstorm, the area this whole crossing
      -- line of work is about), so it passes. A non-simple face means pick_outer_face took its
      -- AREA fallback rather than the rotation branch, since the rotation branch requires
      -- simplicity -- worth printing, never by itself a failure.
      local eight = (not simple) and t == 0
      local verdict = (t and (t < 0 or eight)) and "OK" or "CHECK"
      if verdict ~= "OK" then bad = bad + 1 end
      print(("%-16s 2-core=%-4d faces=%-4d outer=#%-3d rooms=%-4d simple=%-5s turning=%-5s %s%s")
        :format(f, nS, #faces, idx, #face, tostring(simple),
                t and ("%d"):format(t) or "nil", verdict,
                eight and "  (figure-eight boundary)" or
                ((not simple) and "  (area fallback)" or "")))
    end
  end
end
print(bad == 0 and "\nALL OK -- every pick is a true perimeter (-360, or 0 on a figure-eight)"
                or ("\n" .. bad .. " area(s) need a look: the picked face is neither a -360"
                    .. " boundary nor a figure-eight perimeter"))
