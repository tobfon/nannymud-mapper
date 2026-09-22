-- Typed-exit docking: after the vertical pass, bring the two groups a recorded special exit
-- joins next to each other, when they fit. Loaded after vert.lua (reads elro.vert_foot).

elro = elro or {}
local vert_foot = elro.vert_foot or error("special.lua: lua/vert.lua must be loaded first")
local G_ = elro.g or error("special.lua: lua/geom.lua must be loaded first")
local seg_cross_strict = G_.seg_cross_strict

-- Offsets tried for the child's exit room, relative to the anchor room, nearest first.
-- None is a compass direction or a 45 (a typed exit has no direction, and the geometry
-- must not claim one) and none is the 1:2 / 2:1 of a vertical dock. Ring 3 first: at
-- ring 2 the child's own edges land on the anchor's neighbours more often than not.
local OFF = {}
for _, o in ipairs({ { 3, 1 }, { 1, 3 }, { 3, 2 }, { 2, 3 }, { 4, 1 }, { 1, 4 }, { 4, 3 }, { 3, 4 },
                     { 5, 2 }, { 2, 5 }, { 5, 3 }, { 3, 5 }, { 6, 1 }, { 1, 6 }, { 7, 2 }, { 2, 7 },
                     { 7, 4 }, { 4, 7 }, { 8, 3 }, { 3, 8 } }) do
  for _, sx in ipairs({ 1, -1 }) do
    for _, sy in ipairs({ 1, -1 }) do
      OFF[#OFF + 1] = { o[1] * sx, o[2] * sy, math.max(o[1], o[2]) }
    end
  end
end

-- The recorded pairs (from elro.smap) whose two rooms lie in different groups.
local function candidates(groupOf)
  if elro.smap == nil then elro.load_smap() end
  local out, seen = {}, {}
  local keys = {}
  for k in pairs(elro.smap or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local a, b = string.match(k, "^(%d+):(%d+)$")
    a, b = tonumber(a), tonumber(b)
    if a and b and groupOf[a] and groupOf[b] and groupOf[a] ~= groupOf[b] then
      local key = math.min(a, b) .. ":" .. math.max(a, b)
      if not seen[key] then seen[key] = true ; out[#out + 1] = { a = a, b = b } end
    end
  end
  return out
end

local function fits(G, foot, dx, dy)
  if foot.minx + dx <= G.maxx and foot.maxx + dx >= G.minx
     and foot.miny + dy <= G.maxy and foot.maxy + dy >= G.miny then
    for i = 1, #foot.cell do
      local c = foot.cell[i]
      local key = (c[1] + dx) .. ":" .. (c[2] + dy)
      if G.cell[key] or G.ecell[key] then return false end
    end
    for i = 1, #foot.ecell do
      local c = foot.ecell[i]
      if G.cell[(c[1] + dx) .. ":" .. (c[2] + dy)] then return false end
    end
  end
  return true
end

-- The dotted line is drawn straight from the anchor to the exit room, so that run must be
-- clear: through no room of either group and across no placed edge. Cells of the moved group
-- are its own, so only the anchor group's occupancy is asked, plus the moved group's cells
-- other than the exit room itself.
local function run_clear(G, foot, dx, dy, ax, ay, tx, ty)
  local mine = {}
  for i = 1, #foot.cell do
    local c = foot.cell[i]
    mine[(c[1] + dx) .. ":" .. (c[2] + dy)] = true
  end
  mine[tx .. ":" .. ty] = nil
  -- ⛔ G.seg rasterises only axis and 45 runs and every offset here is neither; sample the
  -- segment four times per cell instead, as vert_foot does for the same reason
  local ddx, ddy = tx - ax, ty - ay
  local steps = math.max(math.abs(ddx), math.abs(ddy)) * 4
  for i = 1, steps - 1 do
    local t = i / steps
    local x = math.floor(ax + ddx * t + 0.5)
    local y = math.floor(ay + ddy * t + 0.5)
    if (x ~= ax or y ~= ay) and (x ~= tx or y ~= ty) then
      local k = x .. ":" .. y
      if G.cell[k] or mine[k] then return false end
    end
  end
  local S = G.seg
  for i = 1, #S do
    local e = S[i]
    if seg_cross_strict(ax, ay, tx, ty, e[1], e[2], e[3], e[4]) then return false end
  end
  return true
end

-- How open the slot is: free cells in the 5x5 around the exit room's landing, so a group
-- goes to the anchor's open side and not into the first hole that fits.
local function openness(G, tx, ty)
  local n = 0
  for x = tx - 2, tx + 2 do
    for y = ty - 2, ty + 2 do
      local k = x .. ":" .. y
      if not G.cell[k] and not G.ecell[k] then n = n + 1 end
    end
  end
  return n
end

local function rebuild(G, adj)
  local rooms = {}
  for r in pairs(G.coord) do rooms[#rooms + 1] = r end
  table.sort(rooms)
  local f = vert_foot(rooms, G.coord, adj)
  G.cell, G.ecell, G.seg = {}, {}, f.seg
  for _, c in ipairs(f.cell) do G.cell[c[1] .. ":" .. c[2]] = true end
  for _, c in ipairs(f.ecell) do G.ecell[c[1] .. ":" .. c[2]] = true end
  G.minx, G.miny, G.maxx, G.maxy = f.minx, f.miny, f.maxx, f.maxy
  G.rooms = rooms
  return f
end

local function merge(G, H, dx, dy)
  for r, p in pairs(H.coord) do G.coord[r] = { p[1] + dx, p[2] + dy } end
end

-- Dock groups joined by a typed exit. `groups` is what vert_assemble returned (or one per
-- component); returns the new list. The smaller group moves, its exit room placed at the
-- nearest free offset from the anchor. Declined pairs leave both groups where they were.
function elro.special_assemble(groups, adj)
  if elro.specialDock == false or not groups or #groups < 2 then return groups end
  local groupOf = {}
  for gi, G in ipairs(groups) do for r in pairs(G.coord) do groupOf[r] = gi end end
  local pairs_ = candidates(groupOf)
  if #pairs_ == 0 then return groups end
  local alive, ndock, ndecl = {}, 0, 0
  for gi in ipairs(groups) do alive[gi] = true end
  local footOf = {}
  for gi, G in ipairs(groups) do footOf[gi] = rebuild(G, adj) end
  for _, p in ipairs(pairs_) do
    local ga, gb = groupOf[p.a], groupOf[p.b]
    if ga ~= gb then
      -- the smaller group moves; ties to the higher index, so the order is total
      local big, small, bigRoom, smallRoom = ga, gb, p.a, p.b
      local na, nb = #groups[ga].rooms, #groups[gb].rooms
      if nb > na or (nb == na and gb < ga) then
        big, small, bigRoom, smallRoom = gb, ga, p.b, p.a
      end
      local G, H = groups[big], groups[small]
      local anchor, sr = G.coord[bigRoom], H.coord[smallRoom]
      -- the best slot in the nearest ring that has one: fits, a clear run, then the most open
      local placed, bestScore, bestRing
      for _, o in ipairs(OFF) do
        if bestRing and o[3] > bestRing then break end
        local tx, ty = anchor[1] + o[1], anchor[2] + o[2]
        local dx, dy = tx - sr[1], ty - sr[2]
        if fits(G, footOf[small], dx, dy)
           and run_clear(G, footOf[small], dx, dy, anchor[1], anchor[2], tx, ty) then
          local s = openness(G, tx, ty)
          if not placed or s > bestScore then placed, bestScore, bestRing = { dx, dy, o }, s, o[3] end
        end
      end
      if placed then
        merge(G, H, placed[1], placed[2])
        for r in pairs(H.coord) do groupOf[r] = big end
        alive[small] = false
        footOf[big] = rebuild(G, adj)
        ndock = ndock + 1
        elro.tr(string.format("special: %d <-> %d -- group of %d docked at (%d,%d), ring %d",
          bigRoom, smallRoom, #H.rooms, placed[3][1], placed[3][2], placed[3][3]))
      else
        ndecl = ndecl + 1
        elro.tr(string.format("special: %d <-> %d DECLINED -- no room within ring %d",
          bigRoom, smallRoom, OFF[#OFF][3]))
      end
    end
  end
  local out = {}
  for gi, G in ipairs(groups) do if alive[gi] then out[#out + 1] = G end end
  elro._specialDock = { pairs = #pairs_, docked = ndock, declined = ndecl,
                        before = #groups, after = #out }
  elro.tr(string.format("special: %d pair(s) across groups -- %d docked, %d declined; %d group(s) -> %d",
    #pairs_, ndock, ndecl, #groups, #out))
  return out
end
