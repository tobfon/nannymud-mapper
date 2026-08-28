-- END-TO-END: does swapping count_defects move a single room?
--
-- Run:  luajit analysis/test_cd_layout.lua            (from client/)
--       luajit analysis/test_cd_layout.lua titleist.txt   -- one dump, verbose diff
--
-- ⭐ WHY THIS EXISTS SEPARATELY FROM test_count_defects.lua.
-- That harness proves the scanner returns the same four numbers on the geometries it is HANDED.
-- It cannot prove the engine walks the same path, because the engine calls count_defects thousands
-- of times on PARTIAL, mid-walk geometries that no static dump contains. This one runs the real
-- layout pipeline over the real area dumps twice -- once with the live scanner, once with the
-- frozen pre-optimisation body swapped in -- and diffs the coordinates. That is the actual claim
-- ("no layout moves"), tested directly instead of inferred.

local FAIL = 0
local function ok(c, w) if c then print("  ok   " .. w) else FAIL = FAIL + 1 ; print("  FAIL " .. w) end end

-- ---------------------------------------------------------------- fake Mudlet
local M, TIMERS, TID = nil, {}, 0
local function reset_map()
  M = { rooms = {}, areas = { world = 1, ["world 2"] = 2 }, nextArea = 3 }
end
reset_map()

function roomExists(id) return M.rooms[id] ~= nil end
function getRooms() local t = {} for id in pairs(M.rooms) do t[id] = "room " .. id end return t end
function getRoomExits(id) local r = M.rooms[id] ; return r and r.exits or {} end
function getRoomUserData(id, k) local r = M.rooms[id] ; return r and r.ud[k] or "" end
function setRoomUserData(id, k, v) local r = M.rooms[id] ; if r then r.ud[k] = v end end
function getRoomArea(id) local r = M.rooms[id] ; return r and r.area or -1 end
function setRoomArea(id, a) local r = M.rooms[id] ; if r then r.area = a end end
function getAreaRooms(a) local t = {} for id, r in pairs(M.rooms) do if r.area == a then t[#t+1] = id end end table.sort(t) return t end
function getAreaTable() local t = {} for n, a in pairs(M.areas) do t[n] = a end return t end
function getAreaTableSwap() local t = {} for n, a in pairs(M.areas) do t[a] = n end return t end
function addAreaName(n) M.areas[n] = M.nextArea ; M.nextArea = M.nextArea + 1 ; return M.areas[n] end
function deleteArea(a) for n, id in pairs(M.areas) do if id == a then M.areas[n] = nil end end end
function addRoom(id) M.rooms[id] = { area = 1, exits = {}, ud = {}, x = 0, y = 0 } end
function deleteRoom(id) M.rooms[id] = nil end
function setRoomName() end
function getRoomName(id) return "room " .. id end
function setExit(a, b, d) local r = M.rooms[a] ; if r then if b == -1 then r.exits[d] = nil else r.exits[d] = b end end end
function setExitStub() end
function addSpecialExit() end
function getSpecialExits() return {} end
function getRoomCoordinates(id) local r = M.rooms[id] ; if not r then return 0, 0, 0 end return r.x, r.y, 0 end
function setRoomCoordinates(id, x, y) local r = M.rooms[id] ; if r then r.x, r.y = x, y end end
function getCustomLines() return {} end
function removeCustomLine() end
function addCustomLine() end
function highlightRoom() end
function unHighlightRoom() end
function createMapLabel() end
function deleteMapLabel() end
function getMapSelection() return {} end
function centerview() end
function updateMap() end
function cecho(s) if os.getenv("VERBOSE") then io.write((tostring(s):gsub("<[^>]->", ""))) end end
function getMapUserData() return "" end
function setMapUserData() end
function saveMap() end
function getEpoch() return os.clock() end
function tempTimer(_, fn) TID = TID + 1 ; TIMERS[TID] = fn ; return TID end
function killTimer(id) TIMERS[id] = nil end

for _, m in ipairs(dofile("lua/modules.lua")) do dofile("lua/" .. m) end
elro.debug = false

local LIVE = elro.count_defects                 -- already wrapped by the timing shim; that is fine
local REF_BODY = dofile("analysis/cd_ref.lua")
local REF = function(coord, placed, pedges) return REF_BODY(coord, placed, pedges, elro.crossBucket or 4) end

-- ------------------------------------------------------------ dump -> fake map
local DIRS = { north = true, south = true, east = true, west = true,
               northeast = true, northwest = true, southeast = true, southwest = true }
local REV = { north = "south", south = "north", east = "west", west = "east",
              northeast = "southwest", southwest = "northeast",
              northwest = "southeast", southeast = "northwest" }

local function build(file)
  reset_map()
  elro.cs_reset()
  elro.dirty, elro.merge, elro.smap = {}, {}, {}
  elro.areamin_loaded, elro.margin_loaded, elro.mode_loaded = true, true, true
  elro.current = nil
  TIMERS = {}
  local adj, ids = {}, {}
  for line in io.lines("analysis/" .. file) do
    local id = line:match("^%s*(%d+)")
    if id then
      id = tonumber(id) ; adj[id] = adj[id] or {} ; ids[#ids + 1] = id
      for d, t in line:gmatch("(%a+)%s*%->%s*(%d+)") do if DIRS[d] then adj[id][d] = tonumber(t) end end
      for d, t in line:gmatch("(%a+):(%d+)")        do if DIRS[d] then adj[id][d] = tonumber(t) end end
    end
  end
  local function room(id)
    if not M.rooms[id] then addRoom(id) ; M.rooms[id].ud.sarea = file:gsub("%.txt", "") end
  end
  for _, u in ipairs(ids) do room(u) end
  -- Symmetrise: the walk sees corroborated exits, so the layout does not depend on which
  -- direction the dump happened to record. Targets outside the dump are dropped.
  for _, u in ipairs(ids) do
    for d, v in pairs(adj[u]) do
      if adj[v] then setExit(u, v, d) ; setExit(v, u, REV[d]) end
    end
  end
  return #ids
end

local function snapshot()
  local t = {}
  for id, r in pairs(M.rooms) do t[id] = r.x .. "," .. r.y end
  return t
end

-- ⚠⚠ ORDER MATTERS AND IT SILENTLY DID NOT. `elro.engine` is keyed by AREA NAME, and the area
-- does not exist until recompute_areas() has run -- so setting it from `pairs(M.areas)` first
-- (which at that point holds only the two stock world entries) set the flag for nobody, and every
-- "engine = eqw" run quietly used the DEFAULT engine instead. That made this harness VACUOUS for
-- its whole first outing: elro.count_defects was called ZERO times per relayout, so swapping it
-- could not possibly change a coordinate and the test passed by proving nothing.
-- The `calls` counter below exists so that can never happen again undetected -- assert on it.
local CALLS = 0
local function lay(file, cd, engine)
  build(file)
  elro.mode = "r"
  elro.engine, elro.engineCache, elro.engineSpace = {}, {}, {}
  elro.bgLayout = false
  elro.recompute_areas()                       -- creates the area, so its NAME now exists
  if engine == "eqw" then
    for n in pairs(getAreaTable()) do elro.engine[n] = "eqw" end
  end
  CALLS = 0
  elro.count_defects = function(...) CALLS = CALLS + 1 ; return cd(...) end
  for _, aid in pairs(getAreaTable()) do elro.dirty[aid] = true end
  elro.flush_dirty()
  return snapshot(), CALLS
end

local ONLY = ...
local FILES = ONLY and { ONLY } or { "titleist.txt", "lyr.txt", "world_block.txt", "mael.txt" }

-- ⭐ BASELINE MODE: `BASELINE=1 luajit analysis/test_cd_layout.lua <dump>` does ONE layout in a
-- FRESH PROCESS and prints `<calls> <coords>`. That is the only trustworthy way to compare across a
-- `git stash` (the two bodies cannot coexist in one process), and it exists because the in-process
-- loop is NOT state-clean: an extra `build(f)` before `lay(f, ...)` changes the engine's path and
-- its count_defects call count. Successive lay() calls in one process are reproducible, but a
-- DIFFERENT number of preceding calls is not, so never compare a number from one script shape
-- against a number from another. One process, one measurement.
if os.getenv("BASELINE") then
  assert(ONLY, "BASELINE mode needs a dump file argument")
  -- BURN=<n>: allocate n throwaway tables before laying out and change NOTHING else. If the output
  -- moves, layout depends on ALLOCATION ORDER -- in LuaJIT that means some set is keyed by table or
  -- function (hashed by ADDRESS), so pairs() over it reorders with allocation history. Any A/B of
  -- two code versions would then be meaningless, because a change in allocation volume alone moves
  -- the layout. This probe is the difference between "my edit moved a room" and "any edit would".
  if os.getenv("TOPOCAP") then elro.topoTimeCap = tonumber(os.getenv("TOPOCAP")) end
  local burn = tonumber(os.getenv("BURN") or "0")
  if burn > 0 then
    local keep = {} ; for i = 1, burn do keep[i] = { i, i, i } end ; _G.__burn_keep = keep
  end
  -- INTCHECK=1: also assert every coordinate handed to count_defects is an exact integer. The
  -- segment-walk room-on-edge enumerates lattice points via gcd and is MEANINGLESS off Z^2 --
  -- measured, half-integer coords make it under-count room-on-edge. This is that precondition,
  -- checked on the same path the layout actually takes.
  local body = LIVE
  local nonint, worst = 0, nil
  if os.getenv("INTCHECK") then
    body = function(coord, placed, pedges)
      for r in pairs(placed) do local p = coord[r]
        if p then for i = 1, 2 do local v = p[i]
          if type(v) ~= "number" or v % 1 ~= 0 then
            nonint = nonint + 1
            worst = worst or (r .. " = (" .. tostring(p[1]) .. "," .. tostring(p[2]) .. ")")
          end
        end end
      end
      return LIVE(coord, placed, pedges)
    end
  end
  local s, calls = lay(ONLY, body, "eqw")
  if os.getenv("INTCHECK") then
    print(("INTCHECK %s: %d calls, %d non-integer coordinate(s)%s")
      :format(ONLY, calls, nonint, worst and ("  e.g. " .. worst) or ""))
    return
  end
  local ids = {} ; for id in pairs(s) do ids[#ids + 1] = id end ; table.sort(ids)
  local t = {} ; for _, id in ipairs(ids) do t[#t + 1] = id .. "=" .. s[id] end
  print(calls .. " " .. table.concat(t, " "))
  return
end

for _, engine in ipairs({ "eqw", "flood" }) do
  print("engine = " .. engine)
  for _, f in ipairs(FILES) do
    local n = build(f)
    local a, ca = lay(f, REF, engine)
    local b, cb = lay(f, LIVE, engine)
    -- ⭐ POPULATION CHECK FIRST. Agreement is worthless if the function under test never ran.
    -- Only eqw is required to exercise it: the flood pipeline reaches count_defects solely through
    -- place_inward_pendants, which these graphs need not trigger. Its run is still worth keeping --
    -- it is a free check that the swap does not perturb the OTHER engine -- but it is not evidence.
    if engine == "eqw" then
      ok(ca > 0 and cb > 0, ("%-16s exercises count_defects at all (ref %d calls, live %d calls)")
        :format(f, ca, cb))
    end
    local diffs = {}
    for id, v in pairs(a) do if b[id] ~= v then diffs[#diffs + 1] = ("%s: ref %s vs live %s"):format(id, v, tostring(b[id])) end end
    for id in pairs(b) do if a[id] == nil then diffs[#diffs + 1] = id .. ": missing in ref" end end
    table.sort(diffs)
    ok(#diffs == 0, ("%-16s (%d rooms, %d count_defects calls): layout identical old vs new%s")
      :format(f, n, ca, #diffs == 0 and "" or ("  -- %d ROOM(S) MOVED"):format(#diffs)))
    for i = 1, math.min(#diffs, ONLY and 40 or 6) do print("        " .. diffs[i]) end
  end
end

print("")
if FAIL == 0 then print("ALL PASS -- no layout moved") else print(FAIL .. " FAILURE(S)") ; os.exit(1) end
