-- Is a planar drawing possible AT ALL? The compass exits fix a rotation system, so the embedding
-- is determined -- no coordinates required. Trace faces on it and apply Euler: V - E + F = 2 - 2g.
-- g > 0 => crossings are FORCED, and the count is a lower bound on how many.
local FANG = { east=0, northeast=45, north=90, northwest=135,
               west=180, southwest=225, south=270, southeast=315 }
local REV = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" }
local adj, ids = {}, {}
for line in io.lines("mael.txt") do
  local id = line:match("^(%d+)")
  adj[id] = adj[id] or {} ; ids[#ids+1] = id
  for d, t in line:gmatch("(%a+):(%d+)") do if FANG[d] then adj[id][d] = t end end
end
-- symmetrise: a one-way exit still draws one edge; give the far end the reverse direction
for _, u in ipairs(ids) do
  for d, v in pairs(adj[u]) do
    if adj[v] then
      local back
      for d2, w in pairs(adj[v]) do if w == u then back = d2 end end
      if not back then adj[v][REV[d]] = u end
    end
  end
end
-- rotation: neighbours of each room sorted by compass angle
local rot, pos = {}, {}
for _, u in ipairs(ids) do
  local l = {}
  for d, v in pairs(adj[u]) do if adj[v] then l[#l+1] = { v = v, a = FANG[d] } end end
  table.sort(l, function(x, y) if x.a ~= y.a then return x.a < y.a end return x.v < y.v end)
  rot[u] = l ; pos[u] = {}
  for i, e in ipairs(l) do pos[u][e.v] = i end
end
-- components
local comp, cid = {}, 0
for _, u in ipairs(ids) do
  if not comp[u] then
    cid = cid + 1 ; local st = { u } ; comp[u] = cid
    while #st > 0 do
      local x = table.remove(st)
      for _, e in ipairs(rot[x]) do if not comp[e.v] then comp[e.v] = cid ; st[#st+1] = e.v end end
    end
  end
end
for c = 1, cid do
  local V, E, F, seen = 0, 0, 0, {}
  local members = {}
  for _, u in ipairs(ids) do if comp[u] == c then V = V + 1 ; members[#members+1] = u ; E = E + #rot[u] end end
  E = E / 2
  -- face tracing: from half-edge (u,v), next is (v,w) with w the PREDECESSOR of u in v's rotation
  for _, u in ipairs(members) do
    for _, e0 in ipairs(rot[u]) do
      local k = u .. ">" .. e0.v
      if not seen[k] then
        F = F + 1
        local a, b = u, e0.v
        repeat
          seen[a .. ">" .. b] = true
          local i = pos[b][a]
          local j = (i - 2) % #rot[b] + 1        -- predecessor, cyclically
          a, b = b, rot[b][j].v
        until seen[a .. ">" .. b]
      end
    end
  end
  local euler = V - E + F
  local g = (2 - euler) / 2
  if V > 2 then
    print(string.format("component %d: V=%d E=%d F=%d | V-E+F=%d -> genus %.1f  =>  %s",
      c, V, E, F, euler, g,
      g > 0 and string.format("NOT PLANAR: at least %d crossing(s) FORCED", math.ceil(g))
             or "planar: a crossing-free drawing exists"))
  end
end
