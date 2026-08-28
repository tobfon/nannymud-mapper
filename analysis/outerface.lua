-- WHICH FACE MAY BE THE OUTER ONE?  (coordinate-free, compass exits only)
--
-- genus.lua / eqw_topo_cross ask whether the rotation system embeds on the SPHERE. On a sphere
-- every face is interchangeable, so a graph can pass genus 0 and still be undrawable: a straight
-- compass drawing lives in the PLANE, and there exactly one face may be unbounded.
--
-- Trace the faces of the 2-core and total the turning of each. A face that bounds a bounded region
-- turns +360; a face whose interior is the whole rest of the plane turns -360. So:
--
--     #faces with turn <= -360  ==  how many faces DEMAND to be the outer one
--     more than one  =>  a crossing is FORCED, and (count - 1) is a lower bound.
--
-- Trees are stripped first: each pendant excursion adds a spurious +360 to the face it sits in.
--
--   luajit outerface.lua gurk.txt        V=1 luajit outerface.lua gurk.txt   (list the odd faces)
local FANG = { east=0, northeast=45, north=90, northwest=135,
               west=180, southwest=225, south=270, southeast=315 }
local adj, ids = {}, {}
for line in io.lines(arg[1] or error("usage: outerface.lua <dump>")) do
  local id = line:match("^%s*(%d+)")
  if id then
    if not adj[id] then adj[id] = {} ; ids[#ids+1] = id end
    for d,t in line:gmatch("(%a+)%s*%->%s*(%d+)") do if FANG[d] then adj[id][d]=t end end
    for d,t in line:gmatch("(%a+):(%d+)")         do if FANG[d] then adj[id][d]=t end end
  end
end
-- ONE undirected edge per room pair, angle taken from whichever end declares it.
-- NB do NOT symmetrise by writing adj[v][REV[d]] = u: that slot may already hold a DIFFERENT room,
-- and overwriting it desynchronises the two ends (rand / kadagar / dannoc_on all trip it).
local dirAt, nbr = {}, {}
for _,u in ipairs(ids) do dirAt[u], nbr[u] = {}, {} end
for _,u in ipairs(ids) do for d,v in pairs(adj[u]) do
  if adj[v] and v ~= u then dirAt[u][v] = dirAt[u][v] or FANG[d] end end end
-- TWOWAY=1: keep only edges declared at BOTH ends (a one-way exit -- a merge seam, or a builder's
-- mistake -- then contributes no cycle, so the blocks it glued together come apart again).
for _,u in ipairs(ids) do for v,a in pairs(dirAt[u]) do
  if not os.getenv("TWOWAY") or dirAt[v][u] then
    nbr[u][v] = a ; nbr[v][u] = dirAt[v][u] or (a + 180) % 360
  end end end
-- 2-core
repeat
  local cut = false
  for _,u in ipairs(ids) do
    local n = 0 ; for _ in pairs(nbr[u]) do n = n + 1 end
    if n == 1 then for v in pairs(nbr[u]) do nbr[v][u] = nil end ; nbr[u] = {} ; cut = true end
  end
until not cut
local rot, idx, nV, nE = {}, {}, 0, 0
for _,u in ipairs(ids) do
  local l = {} ; for v,a in pairs(nbr[u]) do l[#l+1] = {v=v,a=a} end
  if #l > 0 then nV = nV + 1 ; nE = nE + #l end
  table.sort(l, function(x,y) if x.a ~= y.a then return x.a < y.a end return x.v < y.v end)
  rot[u] = l ; idx[u] = {} ; for i,e in ipairs(l) do idx[u][e.v] = i end
end
nE = nE / 2
local seen, faces = {}, {}
for _,u in ipairs(ids) do for _,e0 in ipairs(rot[u]) do
  if not seen[u..">"..e0.v] then
    local walk, a, b = {}, u, e0.v
    repeat
      seen[a..">"..b] = true ; walk[#walk+1] = {a,b}
      local i = idx[b][a] ; local j = (i-2) % #rot[b] + 1
      a, b = b, rot[b][j].v
    until seen[a..">"..b]
    local turn = 0
    for i = 1, #walk do
      local w = walk[(i % #walk) + 1]
      local t = (nbr[w[1]][w[2]] - nbr[walk[i][1]][walk[i][2]]) % 360
      if t > 180 then t = t - 360 end
      turn = turn + t
    end
    faces[#faces+1] = { turn = turn, walk = walk }
  end
end end
table.sort(faces, function(x,y) if x.turn ~= y.turn then return x.turn < y.turn end
                                return #x.walk > #y.walk end)
local outer = 0
for _,f in ipairs(faces) do if f.turn <= -360 then outer = outer + 1 end end
-- which BICONNECTED BLOCK does each outer-claiming face live in?  (a -360 face is a simple cycle,
-- so it lies in exactly one block).  gurk's two claimants sit in DIFFERENT blocks joined by
-- bridges; that is the shape the seed override is for.
do
  local disc, low, par, st, comps, ord = {}, {}, {}, {}, {}, 0
  local function dfs(root)
    local stack = { { root, nil } } ; disc[root], low[root], ord = 1, 1, 1
    local it = {}
    for _,u in ipairs(ids) do it[u] = nil end
    local function nbrs(u) local l = {} for v in pairs(nbr[u]) do l[#l+1] = v end table.sort(l) return l end
    local function go(u, p)
      ord = ord + 1 ; disc[u], low[u] = ord, ord
      for _, v in ipairs(nbrs(u)) do
        if not disc[v] then
          st[#st+1] = { u, v } ; go(v, u)
          if low[v] < low[u] then low[u] = low[v] end
          if low[v] >= disc[u] then
            local c = {}
            while #st > 0 do
              local e = table.remove(st) ; c[#c+1] = e
              if e[1] == u and e[2] == v then break end
            end
            comps[#comps+1] = c
          end
        elseif v ~= p and disc[v] < disc[u] then
          st[#st+1] = { u, v } ; if disc[v] < low[u] then low[u] = disc[v] end
        end
      end
    end
    go(root, nil)
  end
  disc = {}
  for _,u in ipairs(ids) do if next(nbr[u]) and not disc[u] then dfs(u) end end
  local bid = {}
  for i, c in ipairs(comps) do
    if #c > 1 then for _, e in ipairs(c) do
      local k = (e[1] < e[2]) and (e[1]..":"..e[2]) or (e[2]..":"..e[1]) ; bid[k] = i end end
  end
  local seen, list = {}, {}
  for _, f in ipairs(faces) do
    if f.turn <= -360 then
      local b
      for i = 1, #f.walk do
        local a2, b2 = f.walk[i][1], f.walk[i][2]
        local k = (a2 < b2) and (a2..":"..b2) or (b2..":"..a2)
        if bid[k] then b = bid[k] break end
      end
      list[#list+1] = tostring(b) ; if b then seen[b] = true end
    end
  end
  local nb2 = 0 ; for _ in pairs(seen) do nb2 = nb2 + 1 end
  if outer > 0 then
    print(("   outer-claiming faces live in block(s): %s  -> %d DISTINCT block(s)%s"):format(
      table.concat(list, ", "), nb2, nb2 > 1 and "   <== the seed override's shape" or ""))
  end
  -- PER-BLOCK claims (BLOCKS=1): a block's faces are simple cycles, so the turn test is always
  -- meaningful there, where a merged 2-core's boundary retraces a bridge corridor and turns 0.
  if os.getenv("BLOCKS") then
    for i, c in ipairs(comps) do
      if #c > 1 then
        local bn, bv = {}, {}
        for _, e in ipairs(c) do
          local a2, b2 = e[1], e[2]
          bn[a2] = bn[a2] or {} ; bn[b2] = bn[b2] or {}
          bn[a2][b2] = nbr[a2][b2] ; bn[b2][a2] = nbr[b2][a2]
          bv[a2] = true ; bv[b2] = true
        end
        local brot, bidx, nBV = {}, {}, 0
        for u in pairs(bv) do
          nBV = nBV + 1
          local l = {} ; for v, a in pairs(bn[u]) do l[#l+1] = { v = v, a = a } end
          table.sort(l, function(x, y) if x.a ~= y.a then return x.a < y.a end return x.v < y.v end)
          brot[u] = l ; bidx[u] = {} ; for k, e in ipairs(l) do bidx[u][e.v] = k end
        end
        local bs, bfaces = {}, {}
        local vs = {} ; for u in pairs(bv) do vs[#vs+1] = u end ; table.sort(vs)
        for _, u in ipairs(vs) do for _, e0 in ipairs(brot[u]) do
          if not bs[u..">"..e0.v] then
            local walk, a, b = {}, u, e0.v
            repeat
              bs[a..">"..b] = true ; walk[#walk+1] = { a, b }
              local k = bidx[b][a] ; local j = (k-2) % #brot[b] + 1
              a, b = b, brot[b][j].v
            until bs[a..">"..b]
            local turn = 0
            for k = 1, #walk do
              local w = walk[(k % #walk) + 1]
              local t = (bn[w[1]][w[2]] - bn[walk[k][1]][walk[k][2]]) % 360
              if t > 180 then t = t - 360 end
              turn = turn + t
            end
            bfaces[#bfaces+1] = { turn = turn, walk = walk }
          end
        end end
        local claims, biggest = {}, 0
        for _, f in ipairs(bfaces) do
          if #f.walk > biggest then biggest = #f.walk end
          if f.turn <= -359 then claims[#claims+1] = f end
        end
        if #claims > 0 or os.getenv("BLOCKS") == "all" then
          print(("   block %2d: %3d room(s) %3d edge(s) %3d face(s), largest %3d half-edges, CLAIMS %d"):format(
            i, nBV, #c, #bfaces, biggest, #claims))
          for _, f in ipairs(claims) do
            local s = {} ; for k = 1, math.min(#f.walk, 24) do s[#s+1] = f.walk[k][1] end
            print(("      turn %+5d over %3d half-edges : %s%s"):format(
              f.turn, #f.walk, table.concat(s, " "), #f.walk > 24 and " ..." or ""))
          end
        end
      end
    end
  end
end
print(("%-30s 2-core V=%d E=%d F=%d  genus %.0f  |  faces demanding to be OUTER: %d%s"):format(
  arg[1], nV, nE, #faces, (2 - (nV - nE + #faces)) / 2, outer,
  outer > 1 and ("   ==> " .. (outer - 1) .. " crossing(s) FORCED") or ""))
if os.getenv("V") then
  for _,f in ipairs(faces) do if f.turn ~= 360 then
    local s = {} ; for i = 1, math.min(#f.walk, 60) do s[#s+1] = f.walk[i][1] end
    print(("   turn %+5d over %3d half-edges : %s%s"):format(
      f.turn, #f.walk, table.concat(s, " "), #f.walk > 60 and " ..." or ""))
  end end
end
