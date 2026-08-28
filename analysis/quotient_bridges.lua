-- QUOTIENT-PENDANT COVERAGE PROBE  (no engine, no behaviour change)
--
-- `bridge_forest()` in layout.lua finds bridges of the ROOM graph, and the rigid-pendant rule
-- rides on them. But `eqw_field_shift` pass 1 first CONTRACTS every edge axial ACROSS the axis
-- (`de[a] == 0`), so on axis `a` the constraint graph is the QUOTIENT, which contains only
-- along-`a` edges. Contraction can only create bridges.
--
-- Question: how much pendant structure does contraction expose that the room graph hides?
-- That is exactly the coverage of a "run the pendant rule on the quotient" drag rule.
--
-- Usage: luajit quotient_bridges.lua [dump] [room,room,...]
local D = { north={0,1}, south={0,-1}, east={1,0}, west={-1,0},
            northeast={1,1}, northwest={-1,1}, southeast={1,-1}, southwest={-1,-1} }
local file = arg[1] or "world_new.txt"
local want = {}
if arg[2] then for r in arg[2]:gmatch("%d+") do want[r] = true end end

local coord, adj, ids = {}, {}, {}
for line in io.lines(file) do
  local id, x, y = line:match("^%s*(%d+)%s+%(?(-?%d+),?%s*(-?%d+)")
  if id then
    coord[id] = { tonumber(x), tonumber(y) } ; adj[id] = {} ; ids[#ids+1] = id
    for d, t in line:gmatch("(%a+)%s*%->%s*(%d+)") do if D[d] then adj[id][d] = t end end
    for d, t in line:gmatch("(%a+):(%d+)")        do if D[d] then adj[id][d] = t end end
  end
end
table.sort(ids, function(p,q) return tonumber(p) < tonumber(q) end)

-- undirected pair -> set of declared deltas (BOTH directions, as pass 1 walks them)
local pairsK, plist = {}, {}
for _, r in ipairs(ids) do
  for d, w in pairs(adj[r]) do
    local de = D[d]
    if de and coord[w] then
      local k = (tonumber(r) < tonumber(w)) and (r..":"..w) or (w..":"..r)
      local e = pairsK[k]
      if not e then
        local a, b = k:match("^(%d+):(%d+)$")
        e = { a = a, b = b, de = {} } ; pairsK[k] = e ; plist[#plist+1] = e
      end
      e.de[#e.de+1] = de
    end
  end
end

local function mk_uf()
  local par = {}
  local function find(r)
    local x = par[r] ; if x == nil then par[r] = r ; return r end
    while par[x] ~= x do par[x] = par[par[x]] ; x = par[x] end
    par[r] = x ; return x
  end
  return find, function(r, x) local a,b = find(r), find(x) ; if a ~= b then par[a] = b end end
end

-- bridges of a multigraph given vertex list + edge list {u,v}; returns set of edge indices
local function bridges(verts, E)
  local nbr = {}
  for _, v in ipairs(verts) do nbr[v] = {} end
  for i, e in ipairs(E) do
    nbr[e[1]][#nbr[e[1]]+1] = { e[2], i }
    nbr[e[2]][#nbr[e[2]]+1] = { e[1], i }
  end
  local disc, low, br, T = {}, {}, {}, 0
  for _, s in ipairs(verts) do
    if not disc[s] then
      T = T + 1 ; disc[s] = T ; low[s] = T
      local st = { { s, nil, 1 } }
      while #st > 0 do
        local fr = st[#st]
        local u, pe, i = fr[1], fr[2], fr[3]
        local l = nbr[u]
        if i <= #l then
          fr[3] = i + 1
          local v, ei = l[i][1], l[i][2]
          if ei ~= pe then                       -- skip by EDGE ID: parallel edges stay visible
            if not disc[v] then
              T = T + 1 ; disc[v] = T ; low[v] = T
              st[#st+1] = { v, ei, 1 }
            elseif disc[v] < low[u] then low[u] = disc[v] end
          end
        else
          st[#st] = nil
          local p = st[#st]
          if p then
            if low[u] < low[p[1]] then low[p[1]] = low[u] end
            if low[u] > disc[p[1]] then br[pe] = true end
          end
        end
      end
    end
  end
  return br
end

-- side sizes of a bridge: rooms on the smaller side
local function sides(verts, E, br, memberOf)
  local nbr = {}
  for _, v in ipairs(verts) do nbr[v] = {} end
  for i, e in ipairs(E) do
    if not br[i] then
      nbr[e[1]][#nbr[e[1]]+1] = e[2] ; nbr[e[2]][#nbr[e[2]]+1] = e[1]
    end
  end
  local comp, cid = {}, 0
  for _, s in ipairs(verts) do
    if not comp[s] then
      cid = cid + 1
      local q, h = { s }, 1 ; comp[s] = cid
      while h <= #q do
        local u = q[h] ; h = h + 1
        for _, v in ipairs(nbr[u]) do if not comp[v] then comp[v] = cid ; q[#q+1] = v end end
      end
    end
  end
  return comp, cid
end

print(("== %s : %d rooms, %d undirected edges =="):format(file, #ids, #plist))

-- ---- baseline: the ROOM graph, what bridge_forest() sees today ----
local RE = {}
for _, e in ipairs(plist) do RE[#RE+1] = { e.a, e.b } end
local rbr = bridges(ids, RE)
local nrbr = 0 ; for _ in pairs(rbr) do nrbr = nrbr + 1 end
local rcomp, rn = sides(ids, RE, rbr)
print(("room graph      : %d bridges, %d 2-edge-connected components"):format(nrbr, rn))

for a = 1, 2 do
  local axn = (a == 1) and "x (contract N/S)" or "y (contract E/W)"
  local find, union = mk_uf()
  for _, r in ipairs(ids) do find(r) end
  local acr = {}
  for _, e in ipairs(plist) do
    local across = false
    for _, de in ipairs(e.de) do if de[a] == 0 then across = true end end
    if across then union(e.a, e.b) ; acr[e] = true end
  end
  local cls, clist, seenc = {}, {}, {}
  for _, r in ipairs(ids) do
    local c = find(r) ; cls[r] = c
    if not seenc[c] then seenc[c] = true ; clist[#clist+1] = c end
  end
  local QE, qmap = {}, {}
  for _, e in ipairs(plist) do
    if not acr[e] then
      local u, v = cls[e.a], cls[e.b]
      if u ~= v then QE[#QE+1] = { u, v } ; qmap[#QE] = e end
    end
  end
  local qbr = bridges(clist, QE)
  local nqbr = 0 ; for _ in pairs(qbr) do nqbr = nqbr + 1 end
  local qcomp, qn = sides(clist, QE, qbr)

  -- NEW pendant structure: a quotient bridge whose underlying room edge is NOT a room bridge
  local newbr, newrooms = 0, {}
  for i in pairs(qbr) do
    local e = qmap[i]
    local ri ; for j, re in ipairs(plist) do if re == e then ri = j break end end
    if not rbr[ri] then
      newbr = newbr + 1
      newrooms[#newrooms+1] = e
    end
  end
  print(("axis %d %-18s: %d classes, %d quotient edges, %d bridges (%d NOT room bridges)")
    :format(a, axn, #clist, #QE, nqbr, newbr))

  -- witness check
  if next(want) then
    local cs = {}
    for r in pairs(want) do cs[cls[r]] = true end
    local qc = {}
    for r in pairs(want) do qc[qcomp[cls[r]]] = true end
    local nqc = 0 ; for _ in pairs(qc) do nqc = nqc + 1 end
    local nrc = {} ; for r in pairs(want) do nrc[rcomp[r]] = true end
    local nnrc = 0 ; for _ in pairs(nrc) do nnrc = nnrc + 1 end
    -- how many OTHER rooms share those quotient components
    local extra = 0
    for _, r in ipairs(ids) do if qc[qcomp[cls[r]]] and not want[r] then extra = extra + 1 end end
    print(("   witness: %d quotient bridge-component(s) (room graph: %d), %d other room(s) share them")
      :format(nqc, nnrc, extra))
  end
end
