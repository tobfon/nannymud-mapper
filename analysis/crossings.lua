-- THE PIPELINE, steps 1-5, on any area dump -- no coordinates used anywhere below.
--   1 planarise permitted grid-X   2 2-core   3 per-face turn test   4 clean chains   5 free beads
-- Usage: luajit crossings.lua <dump> [--quiet]
-- Accepts both dump shapes: the reduced "id x y dir:target ..." and raw mapdumpsel
-- "  id (x,y,z) area=A [dir->target, dir->target]".
local FANG = { east=0, northeast=45, north=90, northwest=135,
               west=180, southwest=225, south=270, southeast=315 }
local REV = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" }
local DIAG = { northeast=true, northwest=true, southeast=true, southwest=true }

local file  = arg[1] or "mael.txt"
local quiet = false
for i = 2, #arg do if arg[i] == "--quiet" then quiet = true end end

---------------------------------------------------------------- load + symmetrise
local function load()
  local adj, ids = {}, {}
  for line in io.lines(file) do
    local id = line:match("^%s*(%d+)")
    if id then
      adj[id] = adj[id] or {} ; ids[#ids+1] = id
      -- reduced form uses "dir:target", raw mapdumpsel uses "dir->target"
      for d, t in line:gmatch("(%a+)%s*%->%s*(%d+)") do if FANG[d] then adj[id][d] = t end end
      for d, t in line:gmatch("(%a+):(%d+)")        do if FANG[d] then adj[id][d] = t end end
    end
  end
  -- a one-way exit still draws one edge: give the far end the reverse direction
  for _, u in ipairs(ids) do
    for d, v in pairs(adj[u]) do
      if adj[v] then
        local back ; for d2, w in pairs(adj[v]) do if w == u then back = d2 end end
        if not back then adj[v][REV[d]] = u end
      end
    end
  end
  -- drop exits leaving the dump
  for _, u in ipairs(ids) do
    for d, v in pairs(adj[u]) do if not adj[v] then adj[u][d] = nil end end
  end
  return adj, ids
end

local function dirOf(adj, u, v) for d, w in pairs(adj[u]) do if w == v then return d end end end
local function deg(adj, u) local n = 0 ; for _ in pairs(adj[u]) do n = n + 1 end return n end

---------------------------------------------------------------- rotation system + faces
-- The compass exits FIX the rotation at every room, so the embedding is determined with no
-- coordinates. Faces are traced on it; Euler per connected component gives the genus.
local function embed(adj, ids)
  local rot, pos, ang = {}, {}, {}
  for _, u in ipairs(ids) do
    local l = {} ; ang[u] = {}
    for d, v in pairs(adj[u]) do l[#l+1] = { v = v, a = FANG[d] } ; ang[u][v] = FANG[d] end
    table.sort(l, function(x, y) if x.a ~= y.a then return x.a < y.a end return x.v < y.v end)
    rot[u] = l ; pos[u] = {} ; for i, e in ipairs(l) do pos[u][e.v] = i end
  end
  local seen, faces = {}, {}
  for _, u in ipairs(ids) do
    for _, e0 in ipairs(rot[u]) do
      if not seen[u .. ">" .. e0.v] then
        local walk, a, b = {}, u, e0.v
        repeat
          seen[a .. ">" .. b] = true ; walk[#walk+1] = { a, b }
          local i = pos[b][a] ; local j = (i - 2) % #rot[b] + 1   -- predecessor, cyclically
          a, b = b, rot[b][j].v
        until seen[a .. ">" .. b]
        faces[#faces+1] = walk
      end
    end
  end
  return rot, ang, faces
end

local function components(adj, ids)
  local comp, cid = {}, 0
  for _, u in ipairs(ids) do
    if not comp[u] then
      cid = cid + 1 ; comp[u] = cid ; local st = { u }
      while #st > 0 do
        local x = table.remove(st)
        for _, v in pairs(adj[x]) do if not comp[v] then comp[v] = cid ; st[#st+1] = v end end
      end
    end
  end
  return comp, cid
end

local function genus(adj, ids, label)
  local rot, _, faces = embed(adj, ids)
  local comp, nc = components(adj, ids)
  local tot = 0
  for c = 1, nc do
    local V, E, F = 0, 0, 0
    for _, u in ipairs(ids) do if comp[u] == c then V = V + 1 ; E = E + #rot[u] end end
    E = E / 2
    for _, f in ipairs(faces) do if comp[f[1][1]] == c then F = F + 1 end end
    local g = (2 - (V - E + F)) / 2
    if V > 2 then
      tot = tot + g
      if not quiet then
        print(string.format("  %-32s comp %d: V=%3d E=%3d F=%3d  genus %.1f%s",
          label, c, V, E, F, g, g > 0 and string.format("  => >=%d crossing(s) FORCED", math.ceil(g)) or ""))
      end
    end
  end
  return tot
end

---------------------------------------------------------------- step 1: permitted grid-X
-- Two 45-degree diagonals crossing is a legitimate wizard-grid connection, so it is a FREE
-- crossing: planarise it with a dummy vertex and see what non-planarity SURVIVES.
local function planarise(adj, ids)
  local found, seenq = {}, {}
  for _, a in ipairs(ids) do
    for d1, c in pairs(adj[a]) do
      if DIAG[d1] then
        for _, b in ipairs(ids) do
          if b ~= a and b ~= c and adj[a][dirOf(adj, a, b) or "x"] == b and dirOf(adj, b, c)
             and not DIAG[dirOf(adj, a, b)] and not DIAG[dirOf(adj, b, c)] then
            for _, dd in ipairs(ids) do
              if dd ~= a and dd ~= b and dd ~= c and dirOf(adj, a, dd) and dirOf(adj, dd, c)
                 and not DIAG[dirOf(adj, a, dd)] and not DIAG[dirOf(adj, dd, c)]
                 and DIAG[dirOf(adj, b, dd) or "x"] then
                local q = { a, b, c, dd } ; table.sort(q)
                local k = table.concat(q, ",")
                if not seenq[k] then seenq[k] = true ; found[#found+1] = { a = a, b = b, c = c, d = dd } end
              end
            end
          end
        end
      end
    end
  end
  local n = 0
  for _, q in ipairs(found) do
    n = n + 1
    local X = "X" .. n ; adj[X] = {} ; ids[#ids+1] = X
    local function relink(u, w)                        -- u -dir-> w  becomes  u -dir-> X -dir-> w
      local d = dirOf(adj, u, w) ; if not d then return end
      adj[u][d] = X ; adj[X][REV[d]] = u
      adj[X][d] = w ; adj[w][REV[d]] = X
    end
    relink(q.a, q.c) ; relink(q.b, q.d)
  end
  return found
end

---------------------------------------------------------------- step 3: turn test
-- Every edge's compass direction is fixed, so the turn at each vertex of a face boundary is
-- determined. A face drawable as a simple closed curve turns exactly +-360; anything else winds
-- and MUST self-cross. That names the rooms, before any coordinate exists.
local function turns(adj, ids)
  local _, ang, faces = embed(adj, ids)
  local bad = {}
  for _, f in ipairs(faces) do
    local turn = 0
    for i = 1, #f do
      local cur, nxt = f[i], f[(i % #f) + 1]
      local t = ang[nxt[1]][nxt[2]] - ang[cur[1]][cur[2]]
      turn = turn + ((t + 180) % 360 - 180)
    end
    if turn ~= 360 and turn ~= -360 then
      local rooms = {} ; for _, e in ipairs(f) do rooms[#rooms+1] = e[1] end
      bad[#bad+1] = { turn = turn, n = #f, rooms = rooms }
    end
  end
  table.sort(bad, function(a, b) return a.n < b.n end)
  return bad, #faces
end

---------------------------------------------------------------- steps 2/4/5: 2-core, chains, beads
-- Pendants carry a 180-degree turn at the tip and are walked out-and-back, polluting every turn
-- measure -- strip them. In what is left, a maximal degree-2 run is a stretch where a crossing
-- disturbs nothing. Within a chain the crossing may sit in any gap separating only FREE BEADS
-- (rooms with nothing hanging off them); rooms that carry a pendant are the walls.
local function chains(adj0, ids)
  local adj = {}
  for u, t in pairs(adj0) do adj[u] = {} ; for d, v in pairs(t) do adj[u][d] = v end end
  local rep = true
  while rep do
    rep = false
    for _, u in ipairs(ids) do
      if adj[u] and deg(adj, u) <= 1 then
        for _, v in pairs(adj[u]) do
          for d2, w in pairs(adj[v]) do if w == u then adj[v][d2] = nil end end
        end
        adj[u] = nil ; rep = true
      end
    end
  end
  local core = {} ; for _, u in ipairs(ids) do if adj[u] then core[#core+1] = u end end
  table.sort(core)
  local used, out = {}, {}
  for _, s in ipairs(core) do
    if deg(adj, s) == 2 and not used[s] then
      local ch, seen = { s }, { [s] = true } ; used[s] = true
      for _, side in ipairs({ 1, 2 }) do
        local prev, cur, k = s, nil, 0
        for _, v in pairs(adj[s]) do k = k + 1 ; if k == side then cur = v end end
        while cur and deg(adj, cur) == 2 and not seen[cur] do
          seen[cur] = true ; used[cur] = true
          if side == 1 then ch[#ch+1] = cur else table.insert(ch, 1, cur) end
          local nxt ; for _, v in pairs(adj[cur]) do if v ~= prev then nxt = v end end
          prev, cur = cur, nxt
        end
        if cur then
          if side == 1 then ch[#ch+1] = "[" .. cur .. "]" else table.insert(ch, 1, "[" .. cur .. "]") end
        end
      end
      out[#out+1] = ch
    end
  end
  table.sort(out, function(a, b) return #a > #b end)
  return core, out, adj
end

---------------------------------------------------------------- run
local adj, ids = load()
print(("== %s : %d rooms =="):format(file, #ids))

print("\n-- step 1: genus of the rotation system --")
local g0 = genus(adj, ids, "as-is (grid-X = blocker)")
local quads = planarise(adj, ids)
print(("  permitted grid-X quads: %d"):format(#quads))
for _, q in ipairs(quads) do
  print(("    %s-%s (%s) x %s-%s (%s)"):format(q.a, q.c, dirOf(adj, q.a, "X") or "diag",
        q.b, q.d, "diag"))
end
local g1 = genus(adj, ids, "after planarising grid-X")
print(("  TOPOLOGY-FORCED crossings: %d  (was %d before grid-X was discounted)"):format(math.ceil(g1), math.ceil(g0)))

print("\n-- step 3: per-face turn test (on the planarised graph) --")
local bad, nf = turns(adj, ids)
print(("  faces %d, non-closing %d"):format(nf, #bad))
for i, b in ipairs(bad) do
  if i <= 6 then
    print(("    turn %+5d over %d edges%s"):format(b.turn, b.n, b.turn == 0 and "  <<< FIGURE EIGHT" or ""))
    print("      rooms: " .. table.concat(b.rooms, " "))
  end
end
if #bad > 6 then print(("    ... and %d more"):format(#bad - 6)) end

print("\n-- steps 2/4/5: 2-core, clean chains, free beads --")
local core, chs = chains(adj, ids)
print(("  2-core: %d of %d rooms"):format(#core, #ids))
local shown = 0
for _, ch in ipairs(chs) do
  if #ch >= 4 and shown < 12 then
    shown = shown + 1
    local marks = {}
    for _, r in ipairs(ch) do
      local id = r:match("^%[(%d+)%]$")
      if id then marks[#marks+1] = "[" .. id .. "]"                      -- junction
      elseif deg(adj, r) > 2 then marks[#marks+1] = r .. "*"             -- hangs a subtree: wall
      else marks[#marks+1] = r end                                       -- free bead
    end
    print(("    chain (%d): %s"):format(#ch, table.concat(marks, " -> ")))
  end
end
print("    ([junction]  id* hangs structure outside the 2-core = wall  bare id = free bead;")
print("     a crossing may go in any gap between two free beads)")
