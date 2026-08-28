-- WHERE DOES THE CROSSING GO ON A FIGURE-EIGHT FACE?
-- A face that turns 0 is an 8: two lobes winding +360 and -360 which cancel. Walk the boundary
-- accumulating turn; the point where the running total has completed a full +360 (or -360) is where
-- one lobe closes and the other begins -- the WAIST. The crossing sits there, between the edge that
-- closes lobe 1 and the edge that opens lobe 2. No coordinates needed.
local FANG = { east=0, northeast=45, north=90, northwest=135,
               west=180, southwest=225, south=270, southeast=315 }
local REV = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" }
local DIAG = { northeast=true, northwest=true, southeast=true, southwest=true }
local adj, ids = {}, {}
for line in io.lines("mael.txt") do
  local id = line:match("^(%d+)")
  adj[id] = adj[id] or {} ; ids[#ids+1] = id
  for d, t in line:gmatch("(%a+):(%d+)") do if FANG[d] then adj[id][d] = t end end
end
for _, u in ipairs(ids) do
  for d, v in pairs(adj[u]) do
    if adj[v] then
      local back ; for d2, w in pairs(adj[v]) do if w == u then back = d2 end end
      if not back then adj[v][REV[d]] = u end
    end
  end
end
-- THE RAW 8: reduce to the 2-CORE first. A pendant contributes a 180-degree turn at its tip and
-- walks out-and-back, which both pollutes the turn total and makes the lobe split land on a leaf.
-- Iteratively drop degree-1 rooms; what remains is the pure cycle structure.
local removed = true
while removed do
  removed = false
  for _, u in ipairs(ids) do
    if adj[u] then
      local n = 0 ; for _, v in pairs(adj[u]) do if adj[v] then n = n + 1 end end
      if n <= 1 then
        for d, v in pairs(adj[u]) do
          if adj[v] then for d2, w in pairs(adj[v]) do if w == u then adj[v][d2] = nil end end end
        end
        adj[u] = nil ; removed = true
      end
    end
  end
end
local kept = {} ; for _, u in ipairs(ids) do if adj[u] then kept[#kept+1] = u end end
ids = kept
print("2-core: " .. #ids .. " rooms (pendants stripped)")

local function dirOf(u,v) for d,w in pairs(adj[u]) do if w==v then return d end end end
local rot, pos = {}, {}
for _, u in ipairs(ids) do
  local l = {}
  for d, v in pairs(adj[u]) do if adj[v] then l[#l+1] = {v=v, a=FANG[d]} end end
  table.sort(l, function(x,y) if x.a~=y.a then return x.a<y.a end return x.v<y.v end)
  rot[u] = l ; pos[u] = {} ; for i,e in ipairs(l) do pos[u][e.v] = i end
end
local seen, faces = {}, {}
for _, u in ipairs(ids) do
  for _, e0 in ipairs(rot[u]) do
    if not seen[u..">"..e0.v] then
      local w, a, b = {}, u, e0.v
      repeat
        seen[a..">"..b] = true ; w[#w+1] = {a,b}
        local i = pos[b][a] ; local j = (i-2)%#rot[b]+1
        a, b = b, rot[b][j].v
      until seen[a..">"..b]
      faces[#faces+1] = w
    end
  end
end
for fi, f in ipairs(faces) do
  local turns, total = {}, 0
  for i = 1, #f do
    local cur, nxt = f[i], f[i%#f+1]
    local t = (FANG[dirOf(nxt[1],nxt[2])] - FANG[dirOf(cur[1],cur[2])] + 180) % 360 - 180
    turns[i] = t ; total = total + t
  end
  if total == 0 and #f > 6 then
    print(string.format("== face %d: %d edges, turn 0 -> FIGURE EIGHT ==", fi, #f))
    -- find the split: a prefix whose turn is exactly +360 (the first lobe closing)
    local run, split = 0, nil
    for i = 1, #f do
      run = run + turns[i]
      if run == 360 or run == -360 then split = i ; break end
    end
    if not split then print("   no clean lobe split found") else
      local l1, l2 = {}, {}
      for i = 1, split do l1[#l1+1] = f[i][1] end
      for i = split+1, #f do l2[#l2+1] = f[i][1] end
      print(string.format("   lobe A (%d edges): %s", #l1, table.concat(l1, " ")))
      print(string.format("   lobe B (%d edges): %s", #l2, table.concat(l2, " ")))
      local eA, eB = f[split], f[split % #f + 1]
      print(string.format("   WAIST between %s-%s (%s) and %s-%s (%s)",
        eA[1], eA[2], dirOf(eA[1],eA[2]), eB[1], eB[2], dirOf(eB[1],eB[2])))
      -- which rooms are shared between the lobes? those are the ones the 8 pinches at
      local inA = {} ; for _, r in ipairs(l1) do inA[r] = true end
      local shared = {}
      for _, r in ipairs(l2) do if inA[r] then shared[#shared+1] = r end end
      print("   rooms on BOTH lobes: " .. (#shared > 0 and table.concat(shared, " ") or "(none)"))
    end
  end
end
