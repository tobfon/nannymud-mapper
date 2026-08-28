-- Exact defect inventory for a layout dump, using the engine's own predicates:
--   collision  : two rooms in one cell
--   room-on-edge: a room strictly interior-collinear on a truthful edge (bbox + ori==0 + not endpoint)
--   lie        : an edge whose geometry contradicts its exit direction
--   crossing   : two truthful edges meeting at a point interior to both
-- Usage: luajit defects.lua [dump]   (default mael.txt; both dump shapes accepted)
local D = { north={0,1}, south={0,-1}, east={1,0}, west={-1,0},
            northeast={1,1}, northwest={-1,1}, southeast={1,-1}, southwest={-1,-1} }
local file = arg[1] or "mael.txt"
local coord, adj, ids = {}, {}, {}
for line in io.lines(file) do
  -- reduced "id x y dir:target ..." or raw mapdumpsel "  id (x,y,z) area=A [dir->target, ...]"
  local id, x, y = line:match("^%s*(%d+)%s+%(?(-?%d+),?%s*(-?%d+)")
  if id then
    coord[id] = { tonumber(x), tonumber(y) } ; adj[id] = {} ; ids[#ids+1] = id
    for d, t in line:gmatch("(%a+)%s*%->%s*(%d+)") do if D[d] then adj[id][d] = t end end
    for d, t in line:gmatch("(%a+):(%d+)")        do if D[d] then adj[id][d] = t end end
  end
end
print(("== %s : %d rooms =="):format(file, #ids))

print("== ROOM-ON-ROOM COLLISIONS ==")
local cell, ncoll = {}, 0
for _, r in ipairs(ids) do
  local k = coord[r][1] .. ":" .. coord[r][2]
  if cell[k] then ncoll = ncoll + 1 ; print(("  %s and %s both at (%s)"):format(cell[k], r, k))
  else cell[k] = r end
end

-- undirected truthful edge list
local seen, edges, lies = {}, {}, {}
for _, r in ipairs(ids) do
  for d, w in pairs(adj[r]) do
    local de = D[d]
    if de and coord[w] then
      local k = (r < w) and (r..":"..w) or (w..":"..r)
      if not seen[k] then
        seen[k] = true
        local a, b = coord[r], coord[w]
        local dx, dy = b[1]-a[1], b[2]-a[2]
        local ok
        if de[1] ~= 0 and de[2] ~= 0 then ok = (dx*de[1] >= 1) and (dy*de[2] >= 1)
        elseif de[1] ~= 0 then ok = (dy == 0) and (dx*de[1] >= 1)
        else ok = (dx == 0) and (dy*de[2] >= 1) end
        if ok then edges[#edges+1] = { r, w, d } else lies[#lies+1] = { r, w, d, dx, dy } end
      end
    end
  end
end

print("== UNTRUTHFUL EDGES (lies) ==")
for _, e in ipairs(lies) do
  print(("  %s -%s-> %s : offset (%d,%d)"):format(e[1], e[3], e[2], e[4], e[5]))
end

print("== ROOM ON EDGE ==")
local n = 0
for _, e in ipairs(edges) do
  local a, b = coord[e[1]], coord[e[2]]
  local lox, hix = math.min(a[1],b[1]), math.max(a[1],b[1])
  local loy, hiy = math.min(a[2],b[2]), math.max(a[2],b[2])
  for _, r in ipairs(ids) do
    if r ~= e[1] and r ~= e[2] then
      local p = coord[r]
      if p[1] >= lox and p[1] <= hix and p[2] >= loy and p[2] <= hiy
         and (b[1]-a[1])*(p[2]-a[2]) - (b[2]-a[2])*(p[1]-a[1]) == 0
         and not (p[1]==a[1] and p[2]==a[2]) and not (p[1]==b[1] and p[2]==b[2]) then
        n = n + 1
        print(("  %s (%d,%d) sits on edge %s(%d,%d) -%s-> %s(%d,%d)")
          :format(r, p[1], p[2], e[1], a[1], a[2], e[3], e[2], b[1], b[2]))
      end
    end
  end
end

print("== EDGE CROSSINGS ==")
-- proper intersection only: a shared endpoint (two exits off one room) is not a crossing.
local function ori(p, q, r)
  local v = (q[1]-p[1])*(r[2]-p[2]) - (q[2]-p[2])*(r[1]-p[1])
  return v > 0 and 1 or (v < 0 and -1 or 0)
end
local nx = 0
for i = 1, #edges do
  for j = i+1, #edges do
    local e, f = edges[i], edges[j]
    if e[1] ~= f[1] and e[1] ~= f[2] and e[2] ~= f[1] and e[2] ~= f[2] then
      local p1, p2, p3, p4 = coord[e[1]], coord[e[2]], coord[f[1]], coord[f[2]]
      local d1, d2 = ori(p3, p4, p1), ori(p3, p4, p2)
      local d3, d4 = ori(p1, p2, p3), ori(p1, p2, p4)
      if d1 ~= d2 and d3 ~= d4 then
        nx = nx + 1
        print(("  %s-%s (%s) x %s-%s (%s)"):format(e[1], e[2], e[3], f[1], f[2], f[3]))
      end
    end
  end
end
print(("\n  TOTALS: collisions %d, lies %d, room-on-edge %d, crossings %d   (edges %d)")
  :format(ncoll, #lies, n, nx, #edges))
