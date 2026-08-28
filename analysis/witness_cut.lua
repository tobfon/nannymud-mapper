-- What does the boundary of a candidate absorb-set actually look like?
-- Prints the set, and every edge leaving it, split by axis: an edge ALONG axis `a` is an
-- inequality (it stretches/compresses), an edge ACROSS `a` is an equality (pass 1 contracts it,
-- so the far room is in the SAME class and moves with the set whether we like it or not).
local D = { north={0,1}, south={0,-1}, east={1,0}, west={-1,0},
            northeast={1,1}, northwest={-1,1}, southeast={1,-1}, southwest={-1,-1} }
local file = arg[1] or "world_new.txt"
local set = {}
for r in (arg[2] or ""):gmatch("%d+") do set[r] = true end
local coord, adj, ids = {}, {}, {}
for line in io.lines(file) do
  local id, x, y = line:match("^%s*(%d+)%s+%(?(-?%d+),?%s*(-?%d+)")
  if id then
    coord[id] = { tonumber(x), tonumber(y) } ; adj[id] = {} ; ids[#ids+1] = id
    for d, t in line:gmatch("(%a+)%s*%->%s*(%d+)") do if D[d] then adj[id][d] = t end end
    for d, t in line:gmatch("(%a+):(%d+)")        do if D[d] then adj[id][d] = t end end
  end
end
local keys = {}
for r in pairs(set) do keys[#keys+1] = r end
table.sort(keys, function(p,q) return tonumber(p) < tonumber(q) end)
print("== SET ==")
for _, r in ipairs(keys) do
  local out = {}
  for d, w in pairs(adj[r]) do out[#out+1] = ("%s->%s%s"):format(d, w, set[w] and "" or " *OUT*") end
  table.sort(out)
  print(("  %-5s (%d,%d)  %s"):format(r, coord[r][1], coord[r][2], table.concat(out, ", ")))
end
print("== BOUNDARY EDGES ==")
local seen = {}
local nx, ny, neqx, neqy = 0, 0, 0, 0
for _, r in ipairs(keys) do
  for d, w in pairs(adj[r]) do
    local de = D[d]
    if de and coord[w] and not set[w] then
      local k = r..":"..w..":"..d
      if not seen[k] then
        seen[k] = true
        local kind = {}
        if de[1] ~= 0 then kind[#kind+1] = "x-INEQ" ; nx = nx + 1 else kind[#kind+1] = "x-eq" ; neqx = neqx + 1 end
        if de[2] ~= 0 then kind[#kind+1] = "y-INEQ" ; ny = ny + 1 else kind[#kind+1] = "y-eq" ; neqy = neqy + 1 end
        print(("  %-5s (%3d,%3d) -%-9s-> %-5s (%3d,%3d)   %s"):format(
          r, coord[r][1], coord[r][2], d, w, coord[w][1], coord[w][2], table.concat(kind, " ")))
      end
    end
  end
end
print(("== axis x: %d inequality, %d EQUALITY (far room is in the same class)"):format(nx, neqx))
print(("== axis y: %d inequality, %d EQUALITY (far room is in the same class)"):format(ny, neqy))
