-- GRID FORCING, computed during face tracing at no extra cost.
-- Each edge's compass direction is FIXED, so walking a face boundary the turn at every vertex is
-- determined -- there is nothing to solve. A face that can be drawn as a simple closed curve must
-- turn exactly +360 (interior, CCW) or -360 (outer). Any other total means the boundary cannot
-- close as a simple curve with these directions: it winds more than once, so it MUST self-cross.
-- That is grid forcing, localised to a face, before any coordinate exists.
local FANG = { east=0, northeast=45, north=90, northwest=135,
               west=180, southwest=225, south=270, southeast=315 }
local REV = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" }
local function load(keep)
  local adj, ids = {}, {}
  for line in io.lines("mael.txt") do
    local id = line:match("^(%d+)")
    if (not keep) or keep[id] then
      adj[id] = adj[id] or {} ; ids[#ids+1] = id
      for d, t in line:gmatch("(%a+):(%d+)") do
        if FANG[d] and ((not keep) or keep[t]) then adj[id][d] = t end
      end
    end
  end
  for _, u in ipairs(ids) do
    for d, v in pairs(adj[u]) do
      if adj[v] then
        local back ; for d2, w in pairs(adj[v]) do if w == u then back = d2 end end
        if not back then adj[v][REV[d]] = u end
      end
    end
  end
  return adj, ids
end
local function analyse(label, keep)
  local adj, ids = load(keep)
  local rot, pos, dirOf = {}, {}, {}
  for _, u in ipairs(ids) do
    local l = {} ; dirOf[u] = {}
    for d, v in pairs(adj[u]) do
      if adj[v] then l[#l+1] = { v = v, a = FANG[d] } ; dirOf[u][v] = FANG[d] end
    end
    table.sort(l, function(x,y) if x.a ~= y.a then return x.a < y.a end return x.v < y.v end)
    rot[u] = l ; pos[u] = {} ; for i, e in ipairs(l) do pos[u][e.v] = i end
  end
  local seen, faces = {}, {}
  for _, u in ipairs(ids) do
    for _, e0 in ipairs(rot[u]) do
      if not seen[u..">"..e0.v] then
        local walk, a, b = {}, u, e0.v
        repeat
          seen[a..">"..b] = true ; walk[#walk+1] = { a, b }
          local i = pos[b][a] ; local j = (i - 2) % #rot[b] + 1
          a, b = b, rot[b][j].v
        until seen[a..">"..b]
        faces[#faces+1] = walk
      end
    end
  end
  print("== " .. label .. " ==")
  local bad = 0
  for fi, f in ipairs(faces) do
    local turn = 0
    for i = 1, #f do
      local cur, nxt = f[i], f[(i % #f) + 1]
      local t = dirOf[nxt[1]][nxt[2]] - dirOf[cur[1]][cur[2]]
      t = (t + 180) % 360 - 180          -- normalise to (-180,180]
      turn = turn + t
    end
    local ok = (turn == 360 or turn == -360)
    if not ok then bad = bad + 1 end
    local rooms = {}
    for _, e in ipairs(f) do rooms[#rooms+1] = e[1] end
    print(string.format("  face %d: %2d edges, turn %+5d  %s", fi, #f, turn,
      ok and (turn == -360 and "(outer)" or "") or "<<< CANNOT CLOSE -- crossing FORCED in this face"))
    if not ok then print("     rooms: " .. table.concat(rooms, " ")) end
  end
  print(string.format("  faces %d, non-closing %d", #faces, bad))
end
local K31 = {}
for id in ("4119 4120 4121 4125 4127 4128 4129 4132 4134 4135 4136 4137 4138 4139 4140 4141 "
        .. "4145 4146 4147 4148 4153 4156 4159 4160 4161 4162 4168 4169 4170 4171 4185"):gmatch("%S+") do K31[id]=true end
analyse("31-room state (genus 0 -- topologically planar)", K31)
analyse("whole maelstorm area (97 rooms, genus 5)", nil)
