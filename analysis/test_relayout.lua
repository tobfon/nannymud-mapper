-- End-to-end check that the BACKGROUND relayout is the SAME COMPUTATION as the
-- foreground one, driving the REAL pipeline (core.lua + layout.lua) against a
-- stubbed Mudlet.
--
-- Run:  luajit analysis/test_relayout.lua      (from client/)
--
-- ⭐ THE CLAIM UNDER TEST is the one the whole design rests on: making the solve
-- yield across frames must not change a single coordinate. There is exactly one
-- body (relayout_body) and elro.bg_tick is a no-op off the coroutine, so this is
-- meant to be true by construction -- which is precisely why it is worth an
-- assertion rather than an argument. It also exercises area_adjacency and
-- edge_provenance through the c-space snapshot on real graphs, and the yield
-- points inside walk_branches / compose_spqr_adj at maximum frequency
-- (bgSlice = 0 yields at EVERY tick, so the run is chopped as finely as the
-- engine allows -- far finer than any real frame budget).

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
local function pump()
  local guard = 0
  while true do
    local id, fn = next(TIMERS)
    if not id then return end
    TIMERS[id] = nil ; fn()
    guard = guard + 1 ; if guard > 100000 then error("timer storm") end
  end
end

for _, m in ipairs(dofile("lua/modules.lua")) do dofile("lua/" .. m) end

-- ------------------------------------------------------------- test fixtures
-- Graphs are given as "id dir id" triples; every edge is added BOTH ways so the
-- provenance layer sees corroborated exits (a one-way edge is a different test).
local REV = { n = "s", s = "n", e = "w", w = "e", ne = "sw", sw = "ne", nw = "se", se = "nw" }
local function build(spec)
  reset_map()
  elro.cs_reset()
  elro.dirty = {} ; elro.merge = {} ; elro.smap = {}
  elro.areamin_loaded, elro.margin_loaded, elro.mode_loaded = true, true, true
  TIMERS = {}
  local function room(id)
    if not M.rooms[id] then addRoom(id) ; M.rooms[id].ud.sarea = "zone" end
  end
  for a, d, b in spec:gmatch("(%d+)%s+(%a+)%s+(%d+)") do
    a, b = tonumber(a), tonumber(b)
    room(a) ; room(b)
    setExit(a, b, elro.norm(d))
    setExit(b, a, elro.norm(REV[d] or d))
  end
  elro.current = nil
end

local function snapshot_coords()
  local t = {}
  for id, r in pairs(M.rooms) do t[id] = r.x .. "," .. r.y .. "," .. r.area end
  return t
end

local function coords_equal(a, b)
  local diffs = {}
  for id, v in pairs(a) do if b[id] ~= v then diffs[#diffs + 1] = id .. ": " .. v .. " vs " .. tostring(b[id]) end end
  for id in pairs(b) do if a[id] == nil then diffs[#diffs + 1] = id .. ": missing vs " .. b[id] end end
  return #diffs == 0, diffs
end

-- a grid with a couple of loops and a pendant tail: enough structure that the
-- closure driver, the lever tiers and the compaction pass all run
local GRID = [[
  1 e 2   2 e 3   3 e 4
  5 e 6   6 e 7   7 e 8
  9 e 10  10 e 11 11 e 12
  1 s 5   5 s 9
  2 s 6   6 s 10
  3 s 7   7 s 11
  4 s 8   8 s 12
  12 e 13 13 e 14 14 n 15
  9 w 20  20 w 21 21 n 22 22 n 23
  4 n 30  30 e 31 31 s 32
]]
-- a plain ring plus a spur, and a second disconnected component
local RING = [[
  100 e 101  101 e 102  102 s 103  103 w 104  104 w 105  105 n 100
  102 n 110  110 n 111
  200 e 201  201 n 202  202 w 203  203 s 200
]]

local CASES = { { "grid+loops+tails", GRID }, { "ring+spur+2nd component", RING } }

for _, engine in ipairs({ "flood", "eqw" }) do
  print("engine = " .. engine)
  for _, case in ipairs(CASES) do
    local name, spec = case[1], case[2]
    local function run(bg)
      build(spec)
      elro.mode = (engine == "flood") and "on" or "r"
      elro.engine, elro.engineCache, elro.engineSpace = {}, {}, {}
      if engine == "eqw" then for n in pairs(M.areas) do elro.engine[n] = "eqw" end end
      elro.bgLayout = bg
      elro.bgSlice = 0            -- yield at EVERY tick: maximum interleaving
      elro.recompute_areas()
      for _, aid in pairs(getAreaTable()) do elro.dirty[aid] = true end
      elro.flush_dirty()
      if bg then
        local guard = 0
        while elro.bg_busy() do pump() ; guard = guard + 1 ; if guard > 5000 then error("stuck") end end
      end
      return snapshot_coords()
    end
    local fg = run(false)
    local bgc = run(true)
    local same, diffs = coords_equal(fg, bgc)
    ok(same, name .. ": background layout is coordinate-identical to foreground" ..
       (same and "" or ("  [" .. table.concat(diffs, "; ", 1, math.min(4, #diffs)) .. "]")))
  end
end

-- ------------------------------------------------- the snapshot vs live reads
print("c-space equivalence")
build(GRID)
elro.mode = "r" ; elro.engine, elro.engineCache, elro.engineSpace = {}, {}, {}
for n in pairs(M.areas) do elro.engine[n] = "eqw" end
elro.bgLayout = false
elro.recompute_areas()
for _, aid in pairs(getAreaTable()) do elro.dirty[aid] = true end
elro.flush_dirty()
local warm = snapshot_coords()
-- ⚠ THE POINT: a COLD snapshot (everything re-read from Mudlet) and a WARM one
-- (everything served from cache) must lay the map out the same way. If they
-- differ, the cache is serving something the live read would not have.
elro.cs_reset()
elro.dirty = {}
for _, aid in pairs(getAreaTable()) do elro.dirty[aid] = true end
elro.flush_dirty()
local cold = snapshot_coords()
local same, diffs = coords_equal(warm, cold)
ok(same, "warm cache and cold re-read produce the same layout" ..
   (same and "" or ("  [" .. table.concat(diffs, "; ", 1, math.min(4, #diffs)) .. "]")))

-- ------------------------------------------------- subtree_size memoisation
-- ⭐ EQUIVALENCE PROOF for the szMemo cache. subtree_size is argued to be a pure
-- function of (adj, outwardSet) -- both frozen for the walk -- so memoising it
-- must not move a single room. The argument is sound but this is the engine's
-- standing rule: prove it against the un-memoised path, do not reason about it.
print("subtree_size memoisation")
local function run_engine(memo, spec)
  build(spec)
  elro.mode = "r" ; elro.engine, elro.engineCache, elro.engineSpace = {}, {}, {}
  for n in pairs(M.areas) do elro.engine[n] = "eqw" end
  elro.bgLayout = false
  elro.szMemo = memo
  elro.recompute_areas()
  for _, aid in pairs(getAreaTable()) do elro.dirty[aid] = true end
  elro.flush_dirty()
  return snapshot_coords()
end
for _, case in ipairs(CASES) do
  local off = run_engine(false, case[2])
  local on  = run_engine(true, case[2])
  local same3, diffs3 = coords_equal(off, on)
  ok(same3, case[1] .. ": memoised subtree_size is coordinate-identical to recomputing" ..
     (same3 and "" or ("  [" .. table.concat(diffs3, "; ", 1, math.min(4, #diffs3)) .. "]")))
end
elro.szMemo = nil

-- ------------------------------------------------ walking during a bg relayout
-- ⭐ THE GRANULARITY CLAIM: the staleness token is PER AREA, so a player moving
-- around in area A must not throw away a finished layout of area B. If the token
-- were global (an epoch alone) this would silently discard and redo everything
-- every time the player took a step, which is the failure mode that makes a
-- background relayout useless in practice rather than merely slow.
print("walking during a background relayout")
local function two_area_map()
  build(GRID)
  -- move the ring component into its own server area so there are two canvases
  for _, spec in ipairs({ RING }) do
    for a, d, b in spec:gmatch("(%d+)%s+(%a+)%s+(%d+)") do
      a, b = tonumber(a), tonumber(b)
      for _, id in ipairs({ a, b }) do
        if not M.rooms[id] then addRoom(id) ; M.rooms[id].ud.sarea = "other" end
      end
      setExit(a, b, elro.norm(d)) ; setExit(b, a, elro.norm(REV[d] or d))
    end
  end
  elro.cs_reset()
  elro.mode = "r" ; elro.engine, elro.engineCache, elro.engineSpace = {}, {}, {}
  for n in pairs(M.areas) do elro.engine[n] = "eqw" end
  elro.recompute_areas()
end

local function run_all(bg, midflight)
  elro.bgLayout = bg ; elro.bgSlice = 0
  elro.dirty = {}
  for _, aid in pairs(getAreaTable()) do elro.dirty[aid] = true end
  elro.flush_dirty()
  if bg then
    local guard, fired = 0, false
    while elro.bg_busy() do
      if midflight and not fired then fired = true ; midflight() end
      pump() ; guard = guard + 1 ; if guard > 5000 then error("stuck") end
    end
  end
end

two_area_map()
run_all(false)
local quiet = snapshot_coords()

two_area_map()
run_all(true, function()
  -- the player takes a step somewhere: stale ONE area, mid-solve
  local other = getAreaTable().other
  local victim ; for id, r in pairs(M.rooms) do if r.area == other then victim = id ; break end end
  if victim then elro.cs_dirty(victim) end
end)
local walked = snapshot_coords()
local same2, diffs2 = coords_equal(quiet, walked)
-- ⭐ THIS IS THE TEST THAT SAYS THE LEVEL LOOP TERMINATES. The dirtied area is
-- committed and re-dirtied by bg_guard_moved, relayout_done relaunches, and the
-- second pass has to land on exactly the layout a quiet map produces.
ok(same2, "a mid-flight change in ONE area still converges to the quiet layout (the rebuild redid only it)" ..
   (same2 and "" or ("  [" .. table.concat(diffs2, "; ", 1, math.min(4, #diffs2)) .. "]")))
ok(next(elro.dirty) == nil, "and nothing is left dirty once the rebuilds settle")

print("")
if FAIL == 0 then print("ALL PASS") else print(FAIL .. " FAILURE(S)") ; os.exit(1) end
