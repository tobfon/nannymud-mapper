-- STEP 2 of the pipeline: chords generalised to BRIDGES.
--
-- `chords.lua` only ever looked at single edges, so it missed the case that actually bites: two
-- attached PATHS across a ring. In maelstorm's +1080 face the culprits are the paths 4193-4208-4207
-- and 4191-4209-4195, invisible to a chord model.
--
-- A bridge of a cycle C is a connected component of G-C together with its attachment points on C
-- (a chord is the degenerate one-edge case). Two bridges whose attachments INTERLEAVE around C
-- cannot go on the same side, so one of them must cross. If the conflict graph is non-bipartite,
-- no assignment of sides works at all and a crossing is forced -- Auslander-Parter, and it names
-- the rooms with no coordinate in sight.
--
-- Canonical seeding, per the README's warning about `chords.lua`: cycles come from the rotation
-- system's non-closing faces, not from an arbitrary DFS of the whole graph.
--
-- Usage: luajit bridges.lua [dump]
local FANG = { east=0, northeast=45, north=90, northwest=135,
               west=180, southwest=225, south=270, southeast=315 }
local REV = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" }
local file = arg[1] or "mael.txt"

local adj, ids = {}, {}
for line in io.lines(file) do
  local id = line:match("^%s*(%d+)")
  if id then
    adj[id] = adj[id] or {} ; ids[#ids+1] = id
    for d, t in line:gmatch("(%a+)%s*%->%s*(%d+)") do if FANG[d] then adj[id][d] = t end end
    for d, t in line:gmatch("(%a+):(%d+)")        do if FANG[d] then adj[id][d] = t end end
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
for _, u in ipairs(ids) do for d, v in pairs(adj[u]) do if not adj[v] then adj[u][d] = nil end end end

---------------------------------------------------------------- step 1 first: planarise grid-X
-- Without this the four permitted grid-X quads in maelstorm show up as +1080 K4 faces and drown
-- the real culprits. A permitted crossing is free, so it must not be analysed as an obstruction.
local DIAG = { northeast=true, northwest=true, southeast=true, southwest=true }
local function dirOf(u, v) for d, w in pairs(adj[u]) do if w == v then return d end end end
do
  local found, seenq = {}, {}
  for _, a in ipairs(ids) do
    for d1, c in pairs(adj[a]) do
      if DIAG[d1] then
        for _, b in ipairs(ids) do
          if b ~= a and b ~= c and dirOf(a, b) and dirOf(b, c)
             and not DIAG[dirOf(a, b)] and not DIAG[dirOf(b, c)] then
            for _, dd in ipairs(ids) do
              if dd ~= a and dd ~= b and dd ~= c and dirOf(a, dd) and dirOf(dd, c)
                 and not DIAG[dirOf(a, dd)] and not DIAG[dirOf(dd, c)] and DIAG[dirOf(b, dd) or "x"] then
                local q = { a, b, c, dd } ; table.sort(q)
                local k = table.concat(q, ",")
                if not seenq[k] then seenq[k] = true ; found[#found+1] = { a=a, b=b, c=c, d=dd } end
              end
            end
          end
        end
      end
    end
  end
  for n, q in ipairs(found) do
    local X = "X" .. n ; adj[X] = {} ; ids[#ids+1] = X
    local function relink(u, w)
      local d = dirOf(u, w) ; if not d then return end
      adj[u][d] = X ; adj[X][REV[d]] = u
      adj[X][d] = w ; adj[w][REV[d]] = X
    end
    relink(q.a, q.c) ; relink(q.b, q.d)
  end
  print(("(planarised %d permitted grid-X quad(s) away first)"):format(#found))
end

-- `--core`: strip pendants first. Pendants carry a 180-degree reversal that makes a face's turn
-- sign meaningless, so the engine wants the analysis on the 2-core -- this flag is here to prove
-- the culprit faces survive the strip.
if arg[2] == "--core" then
  local rep = true
  while rep do
    rep = false
    for _, u in ipairs(ids) do
      if adj[u] then
        local n = 0 ; for _, v in pairs(adj[u]) do if adj[v] then n = n + 1 end end
        if n <= 1 then
          for _, v in pairs(adj[u]) do
            if adj[v] then for d2, w in pairs(adj[v]) do if w == u then adj[v][d2] = nil end end end
          end
          adj[u] = nil ; rep = true
        end
      end
    end
  end
  local keep, n = {}, 0
  for _, u in ipairs(ids) do if adj[u] then n = n + 1 ; keep[#keep+1] = u end end
  ids = keep
  print(("(2-core: %d rooms)"):format(n))
end

-- neighbour sets, sorted so every result below is deterministic
local nbr = {}
for _, u in ipairs(ids) do
  local l = {} ; for _, v in pairs(adj[u]) do l[#l+1] = v end
  table.sort(l) ; nbr[u] = l
end
local function linked(u, v)
  for _, w in ipairs(nbr[u]) do if w == v then return true end end
  return false
end

---------------------------------------------------------------- faces + turn (as in crossings.lua)
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
        local i = pos[b][a] ; local j = (i - 2) % #rot[b] + 1
        a, b = b, rot[b][j].v
      until seen[a .. ">" .. b]
      faces[#faces+1] = walk
    end
  end
end

---------------------------------------------------------------- longest simple cycle in a room set
-- Exhaustive, with a step budget: these face-induced subgraphs are small, and a long cycle is the
-- one worth analysing (the ring the bridges hang off).
local function longest_cycle(S)
  local list = {} ; for u in pairs(S) do list[#list+1] = u end
  table.sort(list)
  local best, budget = nil, 400000
  for _, start in ipairs(list) do
    local path, onpath = { start }, { [start] = true }
    local function dfs(u)
      if budget <= 0 then return end
      for _, v in ipairs(nbr[u]) do
        if S[v] and v > start or (S[v] and v == start) then
          budget = budget - 1
          if v == start and #path >= 3 then
            if not best or #path > #best then
              best = {} ; for i, x in ipairs(path) do best[i] = x end
            end
          elseif S[v] and not onpath[v] then
            path[#path+1] = v ; onpath[v] = true
            dfs(v)
            onpath[v] = nil ; path[#path] = nil
          end
        end
      end
    end
    dfs(start)
    if budget <= 0 then break end
  end
  return best
end

---------------------------------------------------------------- bridges of a cycle
local function bridges_of(C)
  local onC, idxC = {}, {}
  for i, u in ipairs(C) do onC[u] = true ; idxC[u] = i end
  local cyc = {}                                     -- consecutive cycle edges are not chords
  for i = 1, #C do
    local a, b = C[i], C[(i % #C) + 1]
    cyc[a .. ":" .. b] = true ; cyc[b .. ":" .. a] = true
  end
  local out = {}
  -- chords: an edge between two cycle rooms that is not a cycle edge
  local done = {}
  for i = 1, #C do
    for _, v in ipairs(nbr[C[i]]) do
      if onC[v] and not cyc[C[i] .. ":" .. v] then
        local k = (C[i] < v) and (C[i] .. ":" .. v) or (v .. ":" .. C[i])
        if not done[k] then
          done[k] = true
          out[#out+1] = { att = { idxC[C[i]], idxC[v] }, inner = {}, kind = "chord",
                          label = C[i] .. "-" .. v }
        end
      end
    end
  end
  -- path/blob bridges: connected components of G - C, plus the cycle rooms they touch
  local mark = {}
  for _, u in ipairs(ids) do
    if not onC[u] and not mark[u] then
      local comp, st, att = {}, { u }, {}
      mark[u] = true
      while #st > 0 do
        local x = table.remove(st) ; comp[#comp+1] = x
        for _, v in ipairs(nbr[x]) do
          if onC[v] then att[idxC[v]] = true
          elseif not mark[v] then mark[v] = true ; st[#st+1] = v end
        end
      end
      local a = {} ; for i in pairs(att) do a[#a+1] = i end
      table.sort(a)
      if #a >= 2 then
        table.sort(comp)
        local lab
        if #comp <= 5 then lab = table.concat(comp, "-")
        else lab = comp[1] .. "-" .. comp[2] .. "-..-" .. comp[#comp] .. ("(%d rooms)"):format(#comp) end
        out[#out+1] = { att = a, inner = comp, kind = "path", label = lab }
      end
    end
  end
  return out
end

-- two bridges conflict if their attachments interleave around C
local function conflict(b1, b2, n)
  for _, i in ipairs(b1.att) do
    for _, j in ipairs(b1.att) do
      if i < j then
        -- does b2 have attachments strictly inside AND strictly outside the arc (i,j)?
        local inside, outside = false, false
        for _, k in ipairs(b2.att) do
          if k ~= i and k ~= j then
            if k > i and k < j then inside = true else outside = true end
          end
        end
        if inside and outside then return true end
      end
    end
  end
  return false
end

---------------------------------------------------------------- run
print(("== %s : bridge analysis of the non-closing faces =="):format(file))
local any = false
for fi, f in ipairs(faces) do
  local turn = 0
  for i = 1, #f do
    local cur, nxt = f[i], f[(i % #f) + 1]
    turn = turn + ((ang[nxt[1]][nxt[2]] - ang[cur[1]][cur[2]] + 180) % 360 - 180)
  end
  if turn ~= 360 and turn ~= -360 then
    any = true
    local S, ns = {}, 0
    for _, e in ipairs(f) do if not S[e[1]] then S[e[1]] = true ; ns = ns + 1 end end
    print(("\nface %d: turn %+d, %d edges, %d distinct rooms%s")
      :format(fi, turn, #f, ns, turn == 0 and "  (figure eight)" or ""))
    local C = longest_cycle(S)
    if not C then print("  no simple cycle found in this face") else
      print("  ring (" .. #C .. "): " .. table.concat(C, " -> "))
      local bs = bridges_of(C)
      print(("  bridges: %d"):format(#bs))
      for _, b in ipairs(bs) do
        local at = {} ; for _, i in ipairs(b.att) do at[#at+1] = C[i] end
        print(("    %-6s %-22s attaches at %s"):format(b.kind, b.label, table.concat(at, ", ")))
      end
      local pairsn = 0
      for i = 1, #bs do
        for j = i + 1, #bs do
          if conflict(bs[i], bs[j], #C) or conflict(bs[j], bs[i], #C) then
            pairsn = pairsn + 1
            print(("    >>> INTERLEAVE: %s  x  %s   -- one of these must cross the other")
              :format(bs[i].label, bs[j].label))
          end
        end
      end
      if pairsn == 0 then print("    no interleaving bridges on this ring") end
      -- conflict graph 2-colouring: non-bipartite => no side assignment exists at all
      local col, ok = {}, true
      for i = 1, #bs do
        if not col[i] then
          col[i] = 1 ; local st = { i }
          while #st > 0 do
            local x = table.remove(st)
            for y = 1, #bs do
              if y ~= x and (conflict(bs[x], bs[y], #C) or conflict(bs[y], bs[x], #C)) then
                if not col[y] then col[y] = 3 - col[x] ; st[#st+1] = y
                elseif col[y] == col[x] then ok = false end
              end
            end
          end
        end
      end
      -- Necessary, not sufficient, and DELIBERATELY not the authority: bipartiteness asks whether
      -- the bridges could be split inside/outside in SOME embedding, whereas the compass exits
      -- have already fixed the rotation. maelstorm face 37 is bipartite here yet still genus 1.
      -- The genus/turn tests decide IF; this list decides WHICH PAIR.
      print(ok and "    (conflict graph bipartite -- some embedding splits them; the fixed rotation"
                .. " may still not, so genus decides)"
                or "    conflict graph is NOT bipartite: a crossing is FORCED among these bridges")
    end
  end
end
if not any then print("  every face closes at +-360 -- no bridge analysis needed") end
