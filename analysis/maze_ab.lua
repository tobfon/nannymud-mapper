-- A/B a dump WITH and WITHOUT the maze vertex, on real area topology.
--
-- A dump carries rooms, exits and coordinates only -- no fold data -- so the maze
-- doors in it point at ids that are simply absent, and both the knob-on and
-- knob-off runs would drop them. This rig supplies the missing half: it creates
-- the folded cluster the doors lead into, then lays the area out both ways.
--
--   luajit analysis/maze_ab.lua analysis/lyr.txt 2487,2506,2507
--   luajit analysis/maze_ab.lua analysis/lyr.txt          (every absent destination)
--
-- Reports the box, how many edges are drawn truthfully, and -- the point -- which
-- maze doors the solver satisfied and which it had to give up.
dofile("analysis/engine_load.lua")

local dumpPath = arg[1] or error("usage: maze_ab.lua <dump> [mazeRoomIds,...]")
local want = {}
if arg[2] then for id in arg[2]:gmatch("%d+") do want[tonumber(id)] = true end end

local ROOMS, ORDER = {}, {}
do
  local f = assert(io.open(dumpPath, "r"))
  for ln in f:lines() do
    local id, x, y, ar, ex = ln:match("^%s*(%d+) %((-?%d+),(-?%d+),%-?%d+%) area=(%S+) %[(.*)%]%s*$")
    if id then
      id = tonumber(id)
      ROOMS[id] = { area = ar, exits = {}, x = tonumber(x), y = tonumber(y) }
      ORDER[#ORDER + 1] = id
      for d, t in ex:gmatch("(%a+)%->(%d+)") do ROOMS[id].exits[d] = tonumber(t) end
    end
  end
  f:close()
end

-- The cluster is either rooms named on the command line (folded OUT of the area,
-- which is what detection does to a dump taken before it ran) or, with no names,
-- every destination the dump does not contain.
local doors, mazeIds = {}, {}
local named = next(want) ~= nil
if named then
  for t in pairs(want) do mazeIds[t] = true end
else
  for _, r in ipairs(ORDER) do
    for _, t in pairs(ROOMS[r].exits) do if not ROOMS[t] then mazeIds[t] = true end end
  end
end
for _, r in ipairs(ORDER) do
  if not mazeIds[r] then                       -- a door comes from OUTSIDE the cluster
    for d, t in pairs(ROOMS[r].exits) do
      if mazeIds[t] and elro.delta[d] and (elro.delta[d][1] ~= 0 or elro.delta[d][2] ~= 0) then
        doors[#doors + 1] = { room = r, dir = d, dest = t }
      end
    end
  end
end
local KEEP = {}
for _, r in ipairs(ORDER) do if not mazeIds[r] then KEEP[#KEEP + 1] = r end end
ORDER = KEEP
table.sort(doors, function(a, b)
  if a.room ~= b.room then return a.room < b.room end
  return a.dir < b.dir
end)

local function build()
  reset_map() ; elro.cs_reset()
  local aid = addAreaName("dump")
  local mids = {}
  for t in pairs(mazeIds) do mids[#mids + 1] = t end
  table.sort(mids)
  local maid = addAreaName("maze-" .. (mids[1] or 0))
  for _, r in ipairs(ORDER) do
    if not mazeIds[r] then addRoom(r) ; setRoomArea(r, aid) end
  end
  for _, t in ipairs(mids) do
    addRoom(t) ; setRoomArea(t, maid) ; setRoomUserData(t, "fold", "maze-" .. mids[1])
  end
  for _, r in ipairs(ORDER) do
    for d, t in pairs(ROOMS[r].exits) do
      if ROOMS[t] or mazeIds[t] then setExit(r, t, d) end
    end
  end
  elro.cs_reset()
  return aid
end

local function truthful_count()
  local good, bad = 0, 0
  for _, r in ipairs(ORDER) do
    local rx, ry = getRoomCoordinates(r)
    for d, t in pairs(ROOMS[r].exits) do
      local de = elro.delta[d]
      if ROOMS[t] and de and (de[1] ~= 0 or de[2] ~= 0) and rx then
        local tx, ty = getRoomCoordinates(t)
        if elro.drawn_direction_ok(de, tx - rx, ty - ry) then good = good + 1 else bad = bad + 1 end
      end
    end
  end
  return good, bad
end

-- Rooms sitting ON someone else's edge -- the defect the engine ranks just under a
-- collision. Counted here because "the maze vertex made this area worse" has to be
-- answerable in the engine's own currency, not only in doors satisfied.
local function roe_count()
  local occ = {}
  for _, r in ipairs(ORDER) do
    local x, y = getRoomCoordinates(r)
    if x then occ[x .. ":" .. y] = r end
  end
  local hits, list = 0, {}
  for _, r in ipairs(ORDER) do
    local ax, ay = getRoomCoordinates(r)
    for d, t in pairs(ROOMS[r].exits) do
      local de = elro.delta[d]
      if ROOMS[t] and de and (de[1] ~= 0 or de[2] ~= 0) and ax then
        local bx, by = getRoomCoordinates(t)
        if bx and r < t then
          local o = elro.room_on_segment(occ, ax, ay, bx, by, r, t)
          if o then
            hits = hits + 1
            list[#list + 1] = string.format("%d on %d-%d", o, r, t)
          end
        end
      end
    end
  end
  return hits, list
end

local function box()
  local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
  for _, r in ipairs(ORDER) do
    local x, y = getRoomCoordinates(r)
    if x then
      if x < minx then minx = x end ; if x > maxx then maxx = x end
      if y < miny then miny = y end ; if y > maxy then maxy = y end
    end
  end
  return maxx - minx + 1, maxy - miny + 1
end

local function run(on)
  elro.mazeVertex = on
  elro._mazePos = nil
  if not on then elro.maze_veto_clear() end
  local aid = build()
  local okrun, err = pcall(elro.layout_one, aid)
  local w, h = box()
  local g, b = truthful_count()
  local roe, roelist = roe_count()
  -- ⛔ PER DOOR, not per cluster. The first cut of this took ONE arbitrary entry
  -- out of _mazePos and checked every door against it, which was fine while a maze
  -- was a single cell and pure fiction once it became a block -- it reported both
  -- leowon and lyr as regressions that were partly the instrument's own doing.
  local cells, vx, vy = 0, nil, nil
  for _, p in pairs(elro._mazePos or {}) do cells = cells + 1 ; vx, vy = p[1], p[2] end
  local byDoor = (elro._mazeDoor or {})[aid] or {}
  local function cell_of(dr)
    local bd = byDoor[dr.room]
    local vid = bd and bd[dr.dir]
    return vid and (elro._mazePos or {})[vid] or nil
  end
  local sat, miss = 0, {}
  if cells > 0 then
    for _, dr in ipairs(doors) do
      local rx, ry = getRoomCoordinates(dr.room)
      local c = cell_of(dr)
      if rx and c and elro.drawn_direction_ok(elro.delta[dr.dir], c[1] - rx, c[2] - ry) then
        sat = sat + 1
      else miss[#miss + 1] = dr.room .. " " .. dr.dir end
    end
  end
  -- how far apart the cells landed: unchained they are held together only by the
  -- doors, and two markers at opposite ends of the map would read as two mazes
  local xs, ys = {}, {}
  for _, p in pairs(elro._mazePos or {}) do xs[#xs + 1] = p[1] ; ys[#ys + 1] = p[2] end
  local spread
  if #xs > 1 then
    table.sort(xs) ; table.sort(ys)
    spread = string.format("%dx%d cells", xs[#xs] - xs[1] + 1, ys[#ys] - ys[1] + 1)
  end
  return { ok = okrun, err = err, w = w, h = h, good = g, bad = b, spread = spread,
           roe = roe, roelist = roelist,
           vx = vx, vy = vy, cells = cells, sat = sat, miss = miss }
end

print(("dump %s -- %d rooms, %d maze door(s) into %d cluster room(s)")
      :format(dumpPath, #ORDER, #doors, (function() local n = 0 for _ in pairs(mazeIds) do n = n + 1 end return n end)()))
for _, d in ipairs(doors) do print(("   %5d %-10s -> %d"):format(d.room, d.dir, d.dest)) end

-- the third pass re-solves with the vertex still on: if the first pass vetoed the
-- area, this is what the next relayout in game would produce
for _, on in ipairs({ false, true, true }) do
  local r = run(on)
  if not r.ok then
    print(("\n%s  LAYOUT FAILED: %s"):format(on and "vertex ON " or "vertex OFF", tostring(r.err)))
  else
    print(("\n%s  box %dx%d   truthful %d/%d edges   room-on-edge %d%s")
          :format(on and "vertex ON " or "vertex OFF", r.w, r.h, r.good, r.good + r.bad, r.roe,
                  (r.roe > 0) and ("  [" .. table.concat(r.roelist, ", ") .. "]") or ""))
    if r.vx then
      print(("            %d cell(s)   doors satisfied %d/%d%s"):format(r.cells, r.sat, #doors,
            r.spread and ("   cells span " .. r.spread) or ""))
      if #r.miss > 0 then
        print("            given up: " .. table.concat(r.miss, ", "))
        -- WHY: walk the ray the door would need and say what is standing on it.
        -- "the solver would not" and "the solver could not" are different answers.
        local occ = {}
        for _, rr in ipairs(ORDER) do
          local x, y = getRoomCoordinates(rr)
          if x then occ[x .. ":" .. y] = rr end
        end
        for _, m in ipairs(r.miss) do
          local rid, dir = m:match("^(%d+) (%a+)$")
          rid = tonumber(rid)
          local u = elro.delta[dir]
          local rx, ry = getRoomCoordinates(rid)
          -- where would this room have to sit for its door to point at the vertex?
          local blockers, free = {}, nil
          for k = 1, 12 do
            local wx, wy = r.vx - u[1] * k, r.vy - u[2] * k
            local o = occ[wx .. ":" .. wy]
            if o and o ~= rid then blockers[#blockers + 1] = o .. "@(" .. wx .. "," .. wy .. ")"
            elseif not free then free = "(" .. wx .. "," .. wy .. ")" end
          end
          local deg = 0
          for d2, t2 in pairs(ROOMS[rid].exits) do
            if ROOMS[t2] and elro.delta[d2] then deg = deg + 1 end
          end
          print(("              %d %s: sits at (%d,%d), %d edge(s) inside the area")
                :format(rid, dir, rx, ry, deg))
          print(("                 nearest free spot on its ray %s; occupied by %s")
                :format(free or "none within 12", #blockers > 0 and table.concat(blockers, " ") or "nothing"))
        end
      end
    end
  end
end
elro.mazeVertex = false
