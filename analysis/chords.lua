-- PROTOTYPE: where must the crossing go, from the cycle + its chords, with NO coordinates.
--
-- Classical planarity on a cycle: each chord goes inside or outside, two chords whose endpoints
-- INTERLEAVE around the cycle cannot share a side, and the cycle is planar iff that conflict graph
-- is 2-colourable. Minimising crossings is then max-cut -- NP-hard.
-- The grid collapses that: a chord's compass direction PINS its side. At v_i the cycle occupies two
-- known directions, and the interior is the angular sector swept from the outgoing edge round to the
-- edge back toward v_(i-1). A chord whose direction falls in that sector is INSIDE and has no
-- choice. So there is nothing to colour -- interleaved chords on the SAME side ARE crossings.
local FANG = { east=0, northeast=45, north=90, northwest=135,
               west=180, southwest=225, south=270, southeast=315 }
local REV = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" }
local adj = {}
for line in io.lines("mael.txt") do
  local id = line:match("^(%d+)")
  adj[id] = adj[id] or {}
  for d, t in line:gmatch("(%a+):(%d+)") do if FANG[d] then adj[id][d] = t end end
end
for u, nb in pairs(adj) do
  for d, v in pairs(nb) do
    if adj[v] then
      local back ; for d2, w in pairs(adj[v]) do if w == u then back = d2 end end
      if not back then adj[v][REV[d]] = u end
    end
  end
end
local function dirOf(u, v) for d, w in pairs(adj[u]) do if w == v then return d end end end

local function analyse(label, rooms)
  local S = {} ; for _, r in ipairs(rooms) do S[r] = true end
  -- longest simple cycle by DFS (these sets are small; exactness matters more than speed here)
  local best
  local function dfs(start, cur, path, onpath)
    for d, v in pairs(adj[cur]) do
      if S[v] then
        if v == start and #path >= 3 then
          if not best or #path > #best then best = {} ; for z = 1, #path do best[z] = path[z] end end
        elseif not onpath[v] then
          onpath[v] = true ; path[#path+1] = v
          dfs(start, v, path, onpath)
          path[#path] = nil ; onpath[v] = nil
        end
      end
    end
  end
  local s = rooms[1]
  dfs(s, s, { s }, { [s] = true })
  if not best then print("== " .. label .. " ==\n  no cycle") return end
  local C, k = best, #best
  local idxOf = {} ; for i, r in ipairs(C) do idxOf[r] = i end
  -- orientation from the turn sum; normalise to counter-clockwise
  local function turnsum(cy)
    local t = 0
    for i = 1, #cy do
      local a, b, c = cy[i], cy[i%#cy+1], cy[(i+1)%#cy+1]
      local d1, d2 = FANG[dirOf(a,b)], FANG[dirOf(b,c)]
      local x = (d2 - d1 + 180) % 360 - 180
      t = t + x
    end
    return t
  end
  if turnsum(C) < 0 then
    local r = {} ; for i = #C, 1, -1 do r[#r+1] = C[i] end
    C = r ; idxOf = {} ; for i, x in ipairs(C) do idxOf[x] = i end
    k = #C
  end
  -- chords: edges of the induced subgraph that are not cycle edges
  local chords, seen = {}, {}
  for i, u in ipairs(C) do
    for d, v in pairs(adj[u]) do
      if idxOf[v] then
        local j = idxOf[v]
        local isCycle = (j == i % k + 1) or (i == j % k + 1)
        local key = (u < v) and (u..":"..v) or (v..":"..u)
        if not isCycle and not seen[key] then seen[key] = true
          chords[#chords+1] = { u = u, v = v, i = i, j = j, d = d }
        end
      end
    end
  end
  -- side: at u the interior is the sector swept CCW from (toward next) to (toward prev)
  local function side(u, target)
    local i = idxOf[u]
    local nxt, prv = C[i % k + 1], C[(i - 2) % k + 1]
    local ao, ap, a = FANG[dirOf(u, nxt)], FANG[dirOf(u, prv)], FANG[dirOf(u, target)]
    local span = (ap - ao) % 360
    local off  = (a  - ao) % 360
    if off == 0 or off == span then return "on-cycle" end
    return (off < span) and "in" or "out"
  end
  print("== " .. label .. " ==")
  print("  cycle (" .. k .. "): " .. table.concat(C, " -> "))
  for _, c in ipairs(chords) do
    local s1, s2 = side(c.u, c.v), side(c.v, c.u)
    c.side = (s1 == s2) and s1 or ("SPLIT(" .. s1 .. "/" .. s2 .. ")")
    print(string.format("  chord %s-%s (%s)  side=%s", c.u, c.v, c.d, c.side))
  end
  -- interleave: endpoints alternate around the cycle
  local function interleaves(a, b)
    local function between(x, lo, hi) return (x - lo) % k > 0 and (x - lo) % k < (hi - lo) % k end
    return between(b.i, a.i, a.j) ~= between(b.j, a.i, a.j)
  end
  local n = 0
  for x = 1, #chords do
    for y = x + 1, #chords do
      local A, B = chords[x], chords[y]
      if interleaves(A, B) and A.side == B.side and (A.side == "in" or A.side == "out") then
        -- CLASSIFY: two DIAGONAL exits can both be drawn at 45 degrees, and the engine already
        -- treats that X as a legitimate wizard-grid connection (elro.allowDiagCross, default on),
        -- NOT a defect. Only a crossing with at least one axial edge costs anything.
        local DIAG = { northeast=true, northwest=true, southeast=true, southwest=true }
        local gridX = DIAG[A.d] and DIAG[B.d]
        if not gridX then n = n + 1 end
        print(string.format("  >>> FORCED CROSSING: %s-%s (%s) x %s-%s (%s) -- %s",
          A.u, A.v, A.d, B.u, B.v, B.d,
          gridX and "grid-X, both diagonal: ALREADY EXEMPT (allowDiagCross)" or "REAL defect"))
      end
    end
  end
  print("  crossings that are REAL defects in this face: " .. n)
end

analyse("face 2  K4 diagonals", { "4120", "4126", "4171", "4185" })
analyse("face 3", { "4120", "4121", "4126", "4125" })
analyse("face 5", { "4125", "4179", "4126", "4181" })
analyse("face 7", { "4126", "4181", "4171", "4182" })
analyse("face 25", { "4190", "4207", "4208", "4193", "4192", "4191", "4209", "4195", "4194", "4196" })
