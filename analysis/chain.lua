-- "Pick a part of the 8 where there are no other connections between the nodes."
-- Operationally: in the 2-CORE, a maximal run of DEGREE-2 rooms. No chords, no branches, nothing
-- else attached -- so a crossing placed inside it disturbs nothing and cannot interact with other
-- structure. Report every such chain, longest first.
local FANG = { east=0, northeast=45, north=90, northwest=135,
               west=180, southwest=225, south=270, southeast=315 }
local REV = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" }
local adj, ids = {}, {}
for line in io.lines("mael.txt") do
  local id = line:match("^(%d+)")
  adj[id] = adj[id] or {} ; ids[#ids+1] = id
  for d,t in line:gmatch("(%a+):(%d+)") do if FANG[d] then adj[id][d] = t end end
end
for _, u in ipairs(ids) do
  for d, v in pairs(adj[u]) do
    if adj[v] then
      local back ; for d2,w in pairs(adj[v]) do if w==u then back=d2 end end
      if not back then adj[v][REV[d]] = u end
    end
  end
end
local rep = true
while rep do
  rep = false
  for _, u in ipairs(ids) do
    if adj[u] then
      local n = 0 ; for _, v in pairs(adj[u]) do if adj[v] then n = n + 1 end end
      if n <= 1 then
        for d, v in pairs(adj[u]) do
          if adj[v] then for d2,w in pairs(adj[v]) do if w==u then adj[v][d2]=nil end end end
        end
        adj[u] = nil ; rep = true
      end
    end
  end
end
local core = {} ; for _, u in ipairs(ids) do if adj[u] then core[#core+1] = u end end
table.sort(core)
local function deg(u) local n=0 ; for _,v in pairs(adj[u]) do if adj[v] then n=n+1 end end return n end
print("2-core: " .. #core .. " rooms")
-- maximal degree-2 runs
local used, chains = {}, {}
for _, s in ipairs(core) do
  if deg(s) == 2 and not used[s] then
    local ch, seen = { s }, { [s] = true } ; used[s] = true
    for _, dir in ipairs({1,2}) do
      local prev, cur = s, nil
      local k = 0
      for _, v in pairs(adj[s]) do if adj[v] then k = k + 1 ; if k == dir then cur = v end end end
      while cur and deg(cur) == 2 and not seen[cur] do
        seen[cur] = true ; used[cur] = true
        if dir == 1 then ch[#ch+1] = cur else table.insert(ch, 1, cur) end
        local nxt
        for _, v in pairs(adj[cur]) do if adj[v] and v ~= prev then nxt = v end end
        prev, cur = cur, nxt
      end
      if cur then if dir == 1 then ch[#ch+1] = "["..cur.."]" else table.insert(ch, 1, "["..cur.."]") end end
    end
    chains[#chains+1] = ch
  end
end
table.sort(chains, function(a,b) return #a > #b end)
for i, ch in ipairs(chains) do
  if #ch >= 3 then
    print(string.format("  chain %d (%d rooms, junctions in []): %s", i, #ch, table.concat(ch, " -> ")))
  end
end
