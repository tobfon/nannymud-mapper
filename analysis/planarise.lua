-- A permitted grid-X (two 45-degree diagonals crossing) is a LEGITIMATE connection, not a defect.
-- So it should not be counted as an obstruction: planarise it away with a dummy vertex -- the
-- standard planarization move, at zero cost here because the crossing is allowed. Whatever
-- non-planarity SURVIVES is a real forced crossing.
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
local function dirOf(u, v) for d, w in pairs(adj[u]) do if w == v then return d end end end
local function linked(u, v) return dirOf(u, v) ~= nil end

local function genus(label)
  local rot, pos, list = {}, {}, {}
  for u in pairs(adj) do list[#list+1] = u end
  table.sort(list)
  for _, u in ipairs(list) do
    local l = {}
    for d, v in pairs(adj[u]) do if adj[v] then l[#l+1] = { v = v, a = FANG[d] } end end
    table.sort(l, function(x,y) if x.a ~= y.a then return x.a < y.a end return x.v < y.v end)
    rot[u] = l ; pos[u] = {} ; for i,e in ipairs(l) do pos[u][e.v] = i end
  end
  local V, E, F, seen = #list, 0, 0, {}
  for _, u in ipairs(list) do E = E + #rot[u] end ; E = E/2
  for _, u in ipairs(list) do
    for _, e0 in ipairs(rot[u]) do
      if not seen[u..">"..e0.v] then
        F = F + 1 ; local a, b = u, e0.v
        repeat
          seen[a..">"..b] = true
          local i = pos[b][a] ; local j = (i-2) % #rot[b] + 1
          a, b = b, rot[b][j].v
        until seen[a..">"..b]
      end
    end
  end
  print(string.format("%-34s V=%3d E=%3d F=%3d  V-E+F=%3d  genus %.1f", label, V, E, F, V-E+F, (2-(V-E+F))/2))
  return (2-(V-E+F))/2
end

genus("as-is (grid-X counted as blocker)")

-- find permitted grid-X: an AXIAL 4-cycle a-b-c-d carrying BOTH diagonals a-c and b-d
local found, seenq = {}, {}
for _, a in ipairs(ids) do
  for d1, c in pairs(adj[a]) do
    if DIAG[d1] then
      for _, b in ipairs(ids) do
        if b ~= a and b ~= c and linked(a,b) and linked(b,c) and not DIAG[dirOf(a,b)] and not DIAG[dirOf(b,c)] then
          for _, dd in ipairs(ids) do
            if dd ~= a and dd ~= b and dd ~= c and linked(a,dd) and linked(dd,c)
               and not DIAG[dirOf(a,dd)] and not DIAG[dirOf(dd,c)] and DIAG[dirOf(b,dd) or "x"] then
              local q = {a,b,c,dd} ; table.sort(q)
              local k = table.concat(q, ",")
              if not seenq[k] then seenq[k] = true ; found[#found+1] = { a=a, b=b, c=c, d=dd } end
            end
          end
        end
      end
    end
  end
end
print("\npermitted grid-X quads found: " .. #found)
local n = 0
for _, q in ipairs(found) do
  print(string.format("  %s-%s (%s)  x  %s-%s (%s)", q.a, q.c, dirOf(q.a,q.c), q.b, q.d, dirOf(q.b,q.d)))
  -- planarise: dummy vertex on the two crossing diagonals
  n = n + 1
  local X = "X" .. n
  adj[X] = {}
  local function relink(u, w)                       -- u -dir-> w  becomes  u -dir-> X -dir-> w
    local d = dirOf(u, w) ; if not d then return end
    adj[u][d] = X ; adj[X][REV[d]] = u
    adj[X][d] = w ; adj[w][REV[d]] = X
  end
  relink(q.a, q.c) ; relink(q.b, q.d)
  ids[#ids+1] = X
end
print("")
genus("after planarising the grid-X")
