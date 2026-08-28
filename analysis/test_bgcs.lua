-- Harness for the C-SPACE SNAPSHOT + BACKGROUND RELAYOUT coroutine (core.lua).
--
-- Run:  luajit analysis/test_bgcs.lua      (from client/)
--
-- ⭐ WHY THIS EXISTS AND WHAT IT CAN AND CANNOT PROVE.
-- Mudlet runs STOCK LUA 5.1, which cannot yield across a C-call boundary; the
-- only interpreter on this box is LuaJIT, which CAN. So a plain LuaJIT run would
-- happily execute the one bug this design is most exposed to -- a pcall left on
-- the coroutine's stack -- and report success. Test 7 therefore shadows `pcall`
-- with a depth-counting wrapper and makes the harness's bg_tick refuse to yield
-- inside one, which turns the 5.1 restriction into a deterministic assertion
-- this interpreter CAN enforce.
--
-- Everything else here is ordinary behaviour: materialization, precise
-- invalidation from onRoom, the per-area staleness token, and the write
-- boundary. The Mudlet API is stubbed by a tiny in-memory map so the whole
-- thing runs offline.

local FAIL = 0
local function ok(cond, what)
  if cond then print("  ok   " .. what)
  else FAIL = FAIL + 1 ; print("  FAIL " .. what) end
end
local function eq(a, b, what)
  if a == b then print("  ok   " .. what)
  else FAIL = FAIL + 1 ; print(string.format("  FAIL %s (got %s, want %s)", what, tostring(a), tostring(b))) end
end

-- ---------------------------------------------------------------- fake Mudlet
local M                                   -- the fake map
local calls                               -- C-call counters, per API
local function bump(k) calls[k] = (calls[k] or 0) + 1 end

local function reset_map()
  M = { rooms = {}, areas = { world = 1, ["world 2"] = 2 }, nextArea = 3 }
  calls = {}
end

local function newroom(id, area, exits, ud)
  M.rooms[id] = { area = area or 1, exits = exits or {}, ud = ud or {}, x = 0, y = 0 }
end

function roomExists(id) bump("roomExists") return M.rooms[id] ~= nil end
function getRooms() bump("getRooms") local t = {} for id, r in pairs(M.rooms) do t[id] = "room " .. id end return t end
function getRoomExits(id) bump("getRoomExits") local r = M.rooms[id] ; return r and r.exits or {} end
function getRoomUserData(id, k) bump("getRoomUserData") local r = M.rooms[id] ; return r and r.ud[k] or "" end
function setRoomUserData(id, k, v) bump("setRoomUserData") local r = M.rooms[id] ; if r then r.ud[k] = v end end
function getRoomArea(id) bump("getRoomArea") local r = M.rooms[id] ; return r and r.area or -1 end
function setRoomArea(id, a) bump("setRoomArea") local r = M.rooms[id] ; if r then r.area = a end end
function getAreaRooms(a) bump("getAreaRooms") local t = {} for id, r in pairs(M.rooms) do if r.area == a then t[#t + 1] = id end end return t end
function getAreaTable() bump("getAreaTable") local t = {} for n, a in pairs(M.areas) do t[n] = a end return t end
function getAreaTableSwap() bump("getAreaTableSwap") local t = {} for n, a in pairs(M.areas) do t[a] = n end return t end
function addAreaName(n) bump("addAreaName") M.areas[n] = M.nextArea ; M.nextArea = M.nextArea + 1 ; return M.areas[n] end
function deleteArea(a) bump("deleteArea") for n, id in pairs(M.areas) do if id == a then M.areas[n] = nil end end end
function addRoom(id) bump("addRoom") newroom(id, 1) end
function deleteRoom(id) bump("deleteRoom") M.rooms[id] = nil end
function setRoomName(id, n) bump("setRoomName") end
function getRoomName(id) return "room " .. id end
function setExit(a, b, d) bump("setExit") local r = M.rooms[a] ; if r then if b == -1 then r.exits[d] = nil else r.exits[d] = b end end end
function setExitStub() bump("setExitStub") end
function addSpecialExit() end
function getRoomCoordinates(id) local r = M.rooms[id] ; return r and r.x or 0, r and r.y or 0, 0 end
function setRoomCoordinates(id, x, y) local r = M.rooms[id] ; if r then r.x, r.y = x, y end end
function getCustomLines() return {} end
function removeCustomLine() end
function centerview() end
function updateMap() end
function cecho(s) if os.getenv("VERBOSE") then io.write((s:gsub("<[^>]->", ""))) end end
function getMapUserData() return "" end
function setMapUserData() end
function getEpoch() return os.clock() end

-- the timer queue: tempTimer just records, the harness pumps it by hand so the
-- test drives the coroutine frame by frame instead of racing a real clock
local TIMERS, TID = {}, 0
function tempTimer(_, fn) TID = TID + 1 ; TIMERS[TID] = fn ; return TID end
function killTimer(id) TIMERS[id] = nil end
local function pump()                       -- run every queued callback once
  local n = 0
  while true do
    local id, fn = next(TIMERS)
    if not id then break end
    TIMERS[id] = nil ; fn() ; n = n + 1
    if n > 10000 then error("timer storm") end
  end
  return n
end

reset_map()
dofile("lua/geom.lua")   -- geometry prelude; must precede both
dofile("lua/keys.lua")   -- key-format contract; must precede both
dofile("lua/core.lua")
elro.debug = false

local function fresh()
  reset_map()
  elro.cs_reset()
  elro.cs_hit, elro.cs_miss = 0, 0
  elro.dirty = {}
  elro.merge, elro.smap = {}, {}
  elro.areamin_loaded, elro.margin_loaded, elro.mode_loaded = true, true, true
  elro.current = nil
  TIMERS = {}
end

-- ============================================================== 1. MATERIALIZE
print("1. materialization reads Mudlet once per room")
fresh()
newroom(10, 1, { north = 11 }, { sarea = "lyr", assumed_north = "1" })
newroom(11, 1, { south = 10 }, { sarea = "lyr" })
local r10 = elro.cs_room(10)
eq(r10.ex.north, 11, "exits materialized")
eq(r10.asm.north, true, "assumed_<dir> materialized")
eq(r10.sarea, "lyr", "sarea materialized")
eq(r10.area, 1, "area materialized")
local before = calls.getRoomExits
for _ = 1, 50 do elro.cs_room(10) end
eq(calls.getRoomExits, before, "50 re-reads cost ZERO getRoomExits")
eq(elro.cs_hit, 50, "hits counted")

print("   ...and only reads assumed_<dir> for directions that HAVE an exit")
fresh()
newroom(20, 1, { north = 21 }, {})
newroom(21, 1, {}, {})
calls.getRoomUserData = 0
elro.cs_room(20)
-- 4 fields (sarea/adopt/fold/via) + one assumed_ for the single exit. The point of
-- the bound is that assumed_ is read PER EXIT, not per direction; bump it when a
-- field regionalization genuinely needs is added, never to paper over a stray read.
ok(calls.getRoomUserData <= 5, "<=5 userdata reads for a 1-exit room (got " ..
   tostring(calls.getRoomUserData) .. "; the naive version reads 10 for assumed_ alone)")

-- ============================================================ 2. INVALIDATION
print("2. cs_dirty forgets the room and stales exactly its area")
fresh()
newroom(30, 1, { east = 31 }, {}) ; newroom(31, 7, {}, {})
M.areas.other = 7
elro.cs_room(30) ; elro.cs_room(31)
local t1, tOther = elro.cs_token(1), elro.cs_token(7)
elro.cs_dirty(30)
ok(elro.cs[30] == nil, "record dropped")
ok(elro.cs_token(1) ~= t1, "its own area's token moved")
eq(elro.cs_token(7), tOther, "an unrelated area's token did NOT move")

print("   cross-area edge stales BOTH sides")
local t1b, t7b = elro.cs_token(1), elro.cs_token(7)
elro.cs_dirty(31, 1)
ok(elro.cs_token(7) ~= t7b and elro.cs_token(1) ~= t1b, "both tokens moved")

print("   cs_reset stales every area at once")
local tA = elro.cs_token(1)
elro.cs_reset()
ok(elro.cs_token(1) ~= tA, "epoch bump invalidates tokens with no per-area work")

-- ================================================= 3. onRoom PRECISE STALENESS
print("3. onRoom: plain traversal of known territory invalidates NOTHING")
fresh()
-- Build two rooms the way onRoom itself would, then SETTLE the corridor by
-- walking it both ways once.
-- ⚠ The settling round trip is not scaffolding, it is the point: the FIRST
-- walk back converts the reverse onRoom fabricated (assumed_south on 101) into
-- an observed edge, and that legitimately changes what edge_provenance sees --
-- so it MUST stale the area. Only once every edge is observed does re-walking
-- become free. Measuring before the settle would have asserted the wrong thing.
elro.onRoom(100, nil, "none", "start", "lyr", "north")
elro.onRoom(101, 100, "north", "next", "lyr", "south")
elro.onRoom(100, 101, "south", "start", "lyr", "north")   -- settle: observe the reverse
elro.onRoom(101, 100, "north", "next", "lyr", "south")
local tok = elro.cs_token(elro.cs_room(101).area)
local wr0 = (calls.setExit or 0) + (calls.setRoomUserData or 0)
for _ = 1, 3 do                                           -- now pace up and down
  elro.onRoom(100, 101, "south", "start", "lyr", "north")
  elro.onRoom(101, 100, "north", "next", "lyr", "south")
end
eq(elro.cs_token(elro.cs_room(101).area), tok,
   "token unchanged after six known moves -- an in-flight layout survives a walking player")
ok(elro.cs[100] ~= nil and elro.cs[101] ~= nil, "records survived (not blindly forgotten)")
eq((calls.setExit or 0) + (calls.setRoomUserData or 0), wr0,
   "and no redundant setExit/setRoomUserData was issued at all")

print("   ...but a genuinely NEW room does stale the area")
local tok2 = elro.cs_token(elro.cs_room(101).area)
elro.onRoom(102, 101, "north", "third", "lyr", "south")
ok(elro.cs_token(elro.cs_room(101).area) ~= tok2, "new room -> token moved")

print("   ...and so does a NEW EDGE between two known rooms")
elro.onRoom(100, nil, "none", "start", "lyr", "north,east")
local tok3 = elro.cs_token(elro.cs_room(100).area)
elro.onRoom(102, 100, "east", "third", "lyr", "west")     -- 100 -east-> 102 is new
ok(elro.cs_token(elro.cs_room(100).area) ~= tok3, "new edge -> token moved")

print("   ...and clearing an ASSUMED reverse counts as a change")
fresh()
elro.onRoom(200, nil, "none", "a", "lyr", "north")
elro.onRoom(201, 200, "north", "b", "lyr", "south")       -- fabricates 201 -south-> 200
ok(elro.cs_room(201).asm.south == true, "reverse recorded as assumed")
local tok4 = elro.cs_token(elro.cs_room(201).area)
elro.onRoom(200, 201, "south", "a", "lyr", "north")       -- now actually walked
ok(elro.cs_token(elro.cs_room(201).area) ~= tok4,
   "observing an assumed edge stales the area (edge_provenance would read it differently)")
ok(elro.cs_room(201).asm.south ~= true, "and the flag is gone from the fresh record")

-- ===================================================== 4. THE COROUTINE DRIVER
print("4. background driver: yields, resumes, completes")
fresh()
local steps, seen_inside = 0, false
elro.bgSlice = 0                                   -- yield at every tick
-- ⚠ count frames/yields from the DRIVER, not from pump() calls: pump drains the
-- whole timer queue including the follow-up timers bg_step re-arms, so one pump
-- can carry the entire run. Counting pumps measured the harness, not the engine.
local done, dFrames, dYields = false, 0, 0
elro.bg_start(function()
  for _ = 1, 5 do
    steps = steps + 1
    seen_inside = seen_inside or elro.bg_inside()
    elro.bg_tick()
  end
end, "test", function(bg) done = true ; dFrames, dYields = bg.frames, bg.yields end)
ok(elro.bg_busy(), "run is in flight after bg_start")
local frames = 0
while elro.bg_busy() and frames < 50 do pump() ; frames = frames + 1 end
eq(steps, 5, "body ran to completion")
ok(seen_inside, "bg_inside() true on the coroutine")
eq(dYields, 5, "it yielded at every tick")
eq(dFrames, 6, "and needed 6 resumes to get through 5 yields")
ok(done, "done callback fired")
ok(not elro.bg_busy(), "driver cleaned up")

print("   bg_tick is a no-op on the main thread")
elro.bg_tick()                                     -- must not error or yield
ok(true, "main-thread tick returns normally")
-- ⚠ and it must stay a no-op WHILE a run is in flight: between frames the main
-- thread is live and `bg.live` is false, which is the whole reason bg_tick can
-- avoid paying for coroutine.running() on the fast path.
fresh()
elro.bgSlice = 0
elro.bg_start(function() elro.bg_tick() ; elro.bg_tick() end, "test")
local mainOk = pcall(elro.bg_tick)                 -- main thread, run in flight
ok(mainOk, "main-thread tick is still a no-op while a run is in flight")
while elro.bg_busy() do pump() end

print("   the driver reports WHERE it could not yield")
fresh()
elro.bgSlice = 5
local prof
elro.bg_start(function()
  elro.tr("phase A")
  elro.bg_tick()
  elro.tr("phase B -- the un-tickable one")
  local t = os.clock() ; while os.clock() - t < 0.06 do end   -- 60ms with no tick
  elro.tr("phase C")
  elro.bg_tick()
end, "test", function(bg) prof = bg end)
while elro.bg_busy() do pump() end
ok((prof.maxFrame or 0) >= 0.05, string.format("worst frame captured (%.0fms)", (prof.maxFrame or 0) * 1000))
ok(prof.maxFrom == "phase B -- the un-tickable one" or prof.maxTo == "phase C",
   "and it is labelled with the phase it was in: " .. tostring(prof.maxFrom) .. " .. " .. tostring(prof.maxTo))
ok((prof.busyT or 0) > 0, "busy time accumulated (busy vs wall is what separates 'no tick here' from 'timer gap too long')")
ok((prof.overruns or 0) >= 1, "over-budget frames counted")

print("   ...and which TICK ended the worst frame (the other end of the bracket)")
fresh()
elro.bgSlice = 5
local prof2
elro.bg_start(function()
  elro.bg_tick("cheap")
  local t = os.clock() ; while os.clock() - t < 0.05 do end
  elro.bg_tick("the-expensive-one")
end, "test", function(bg) prof2 = bg end)
while elro.bg_busy() do pump() end
eq(prof2.maxSite, "the-expensive-one", "worst frame names the tick that ended it")
ok(prof2.sites and prof2.sites["the-expensive-one"], "and a per-site yield histogram is kept")

print("   ...and the overrun hook names the SOURCE LINE that blew the budget")
-- LuaJIT does not call count hooks from compiled traces, so this test measures
-- nothing at all unless the JIT is off. Mudlet is stock 5.1 and has no such
-- problem; this line is purely so the harness can exercise the feature here.
if type(jit) == "table" and jit.off then jit.off() end
-- ⭐ This is the instrument that ends the guess-and-check loop: the tick histogram
-- can only say which tick CAUGHT an overrun, never which code caused it. The hook
-- reports the line directly. ⛔ It can only REPORT -- stock Lua 5.1 cannot yield
-- from a hook -- so the fix is still an elro.bg_tick, just placed on the first try.
fresh()
elro.bgSlice = 5
elro.bgHook = 2000
local prof3
local function burn()                              -- a named, findable hot loop
  local t = os.clock() ; local x = 0
  while os.clock() - t < 0.08 do x = x + 1 end
  return x
end
elro.bg_start(function()
  elro.bg_tick("start")
  burn()
  elro.bg_tick("after-burn")
end, "test", function(bg) prof3 = bg end)
while elro.bg_busy() do pump() end
elro.bgHook = 0
ok((prof3.overN or 0) > 0, "overrun probes recorded: " .. tostring(prof3.overN))
local hit, top = false, nil
for k, n in pairs(prof3.over or {}) do
  if not top or n > (prof3.over[top] or 0) then top = k end
  if k:match("test_bgcs%.lua:%d+") then hit = true end
end
ok(hit, "and they name this file and a line number (top: " .. tostring(top) .. ")")

print("   time spent YIELDED is excluded from the engine's own timers")
-- ⭐ THE BUG THIS PINS. mapstep's per-step `dt` and elro.tr's "+Nms" are both wall-clock
-- differences taken inside the engine. Under a background run a pair of readings can straddle a
-- yield, and then the whole tempTimer gap lands in the measurement -- a 1ms placement reads as
-- 400ms purely for following a frame boundary. That does not just add noise, it INVENTS hot
-- spots. bg_idle_ms is the driver's running total of not-executing time; every such timer
-- subtracts its change.
fresh()
elro.bgSlice = 0                                   -- yield at every tick
local GAP = 0.05                                   -- 50ms of "Mudlet event loop" per frame
local realpump = pump
local gappy = function()
  while true do
    local id, fn = next(TIMERS)
    if not id then return end
    TIMERS[id] = nil
    local t = os.clock() ; while os.clock() - t < GAP do end   -- the gap the old code charged to the engine
    fn()
  end
end
local d1, d2
elro.bg_start(function()
  local a = elro.now_ms() ; local i0 = elro.bg_idle_ms()
  elro.bg_tick()                                   -- yields; a full GAP passes here
  d1 = elro.now_ms() - a                           -- the naive (wall) measurement
  d2 = d1 - (elro.bg_idle_ms() - i0)               -- ...and the corrected one
end, "test")
local g = 0
while elro.bg_busy() and g < 50 do gappy() ; g = g + 1 end
ok(d1 >= 40, string.format("wall-clock span across a yield is inflated (%.0fms)", d1 or -1))
ok(d2 < 20, string.format("...and the idle-corrected span is not (%.0fms)", d2 or -1))
pump = realpump

print("   an error in the body is caught, reported, and clears elro.eqwalk")
fresh()
elro.eqwalk = true
elro.bg_start(function() error("boom") end, "test")
pump()
ok(not elro.bg_busy(), "driver torn down after an error")
ok(elro.eqwalk == nil, "eqwalk cleared -- the guarantee layout_eqw gave up its pcall for")

-- ============================================== 5. THE WRITE BOUNDARY / STALE
print("5. write boundary: MIXED input is refused; merely OUTDATED input commits")
fresh()
newroom(300, 5, {}, {}) ; M.areas.zone = 5
elro._writeArea, elro._writeCo, elro._writeCleared = 5, nil, false
elro.bg_guard(5)
ok(elro.write_begin(), "fresh input -> write allowed")

-- ⭐ A BUMP ON ITS OWN IS NO LONGER ENOUGH TO REFUSE. The solve's input is still
-- whole -- just out of date -- and dropping a finished solve for that is what never
-- converged while the player explored.
elro.bg_guard(5)
elro.cs_dirty(300)                                 -- the player walked into it
elro._writeCleared = false
ok(elro.write_begin(), "outdated-but-consistent input -> write ALLOWED")
ok(elro.bg_guard_moved(elro._bgGuard), "...and the guard still knows it moved, so the area stays dirty")

-- ...and the same bump FOLLOWED BY A FRESH READ is MIXED: cs_dirty deleted room
-- 300's record, so this cs_room re-materializes it from live state and the solve is
-- now holding old records for everything else and a new one for this.
-- guard_fresh_read only counts reads made by a live background frame, so stand one in.
-- ⭐⭐⭐⭐ AND SINCE 2026-08-19 THAT IS COMMITTED TOO (the user: *"I would rather redraw
-- with the layout produced by the rebuild even if new rooms have been mapped since"*).
-- The guard still RECORDS it -- that is what keeps the redo a correctness redo, run
-- whether or not autoflush is on -- but the write goes through.
-- ⛔ BOTH LEGS PINNED. `elro.bgDropMixed` is the escape hatch back to the old drop, and
-- an A/B whose "off" leg is the bare default stops testing anything the day the default
-- moves -- which is exactly how test 17d over in test_vertpack rotted.
local function mixed_guard()
  elro.bg_guard(5)
  elro._bg = { live = true }
  elro.cs_dirty(300)
  elro.cs_room(300)
  elro._bg = nil
  elro._writeCleared = false
end
elro.bgDropMixed = nil
mixed_guard()
ok(elro.write_begin(), "mixed input -> COMMITTED (the picture is fresh, not consistent)")
ok(elro._bgGuard.mixed, "and the guard still records it, so the area stays dirty")
ok(elro._writeCleared == true, "...and the area's stale lines WERE cleared for it")
elro.bgDropMixed = true
mixed_guard()
ok(not elro.write_begin(), "bgDropMixed -> the old behaviour is still one knob away")
ok(elro._writeCleared == false, "...and then no lines are cleared, so dropping stays free")
elro.bgDropMixed = nil
elro._writeArea, elro._bgGuard = nil, nil

print("   the write context belongs to the thread that armed it")
-- deliberately MIXED, so the thread check is the only thing that can allow this
elro._writeArea, elro._writeCo = 5, coroutine.create(function() end)
elro.bg_guard(5)
elro._bg = { live = true } ; elro.cs_dirty(300) ; elro.cs_room(300) ; elro._bg = nil
ok(elro._bgGuard.mixed, "(the guard is mixed, so only the thread gate can pass this)")
ok(elro.write_begin(), "a main-thread mapstep redraw is NOT gated by the coroutine's context")
elro._writeArea, elro._writeCo, elro._bgGuard = nil, nil, nil

-- ============================================ 6. FULL RELAYOUT, BOTH PATHS
print("6. relayout: foreground and background agree, and the write gate holds")
local laid
local function stub_layout()
  elro.layout_one = function(aid) elro.bg_tick() ; if elro.write_begin() then laid[#laid + 1] = aid end end
  elro.layout_world2 = function(aid) if elro.write_begin() then laid[#laid + 1] = aid end end
  elro.draw_portals = function() end
end
stub_layout()

fresh() ; laid = {}
newroom(400, 1, {}, { sarea = "world" })
newroom(401, 1, {}, { sarea = "world" })
elro.bgLayout = false
elro.dirty = { [1] = true }
local n = elro.flush_dirty()
eq(n, 1, "foreground flush_dirty laid 1 map")
eq(#laid, 1, "and wrote it")
ok(next(elro.dirty) == nil, "dirty cleared")

fresh() ; laid = {}
newroom(400, 1, {}, { sarea = "world" })
elro.bgLayout = true ; elro.bgSlice = 0
elro.dirty = { [1] = true }
eq(elro.flush_dirty(), -1, "background flush_dirty hands off immediately")
ok(elro.bg_busy(), "and a run is in flight")
frames = 0
while elro.bg_busy() and frames < 200 do pump() ; frames = frames + 1 end
eq(#laid, 1, "background run wrote the same 1 map")
ok(next(elro.dirty) == nil, "dirty cleared")

print("   a walk DURING the solve leaves the input OUTDATED, which now COMMITS")
-- ⭐ THE ASSERTION INVERTED DELIBERATELY (it used to be "the stale result was
-- DROPPED"). A bump with no snapshot read after it leaves the solve's own input
-- whole -- only out of date -- and throwing away a completed 9-17s solve for that
-- was the behaviour that never converged while the player explored.
fresh() ; laid = {}
newroom(400, 1, {}, { sarea = "world" })
elro.bgLayout = true ; elro.bgSlice = 0
elro.autoflush = false                             -- keep the level loop out of this test
elro.layout_one = function(aid)
  elro.cs_dirty(400)                               -- simulate onRoom mid-solve
  elro.bg_tick()
  if elro.write_begin() then laid[#laid + 1] = aid end
end
elro.dirty = { [1] = true }
elro.flush_dirty()
frames = 0
while elro.bg_busy() and frames < 200 do pump() ; frames = frames + 1 end
eq(#laid, 1, "the OUTDATED result was committed, not dropped")

print("   ...but a snapshot READ after the bump is MIXED input, and that IS dropped")
-- cs_dirty deleted room 400's record, so this cs_room re-materializes it from live
-- state -- old records for every other room, a new one for this. That graph
-- satisfies no consistent set of equations, which is the one case worth losing.
fresh() ; laid = {}
newroom(400, 1, {}, { sarea = "world" })
newroom(401, 1, {}, { sarea = "world" })
elro.bgLayout = true ; elro.bgSlice = 0
elro.layout_one = function(aid)
  elro.cs_dirty(400)
  elro.cs_room(400)                                -- ...and read it back: MIXED
  elro.bg_tick()
  if elro.write_begin() then laid[#laid + 1] = aid end
end
elro.dirty = { [1] = true }
elro.flush_dirty()
frames = 0
while elro.bg_busy() and frames < 200 do pump() ; frames = frames + 1 end
-- ⭐⭐⭐ THREE, NOT ONE, AND NOT FOREVER. Every run of this stub re-reads a bumped
-- record, so every run is mixed -- it commits, stays dirty, and queues the next. The
-- bound is the spin guard, which counts CLEAN commits: a stale commit is progress for
-- the PICTURE and not for CONVERGENCE. ⛔ Basing it on `st.n` (as it was while a mixed
-- result was dropped, when the two were the same thing) makes this a literal timer
-- storm -- which is how this test caught it.
eq(#laid, 3, "the mixed-input result was COMMITTED, and the redo chain is BOUNDED")
ok(elro.dirty[1], "and the area is still dirty so `maprelayout` or the next step retries")
eq(elro.bg_busy(), false, "...and it stopped rather than spinning on a picture that never settles")

print("   ...a graph change during a COMMITTED run queues the next build by itself")
-- ⭐ THE LEVEL LOOP. Run 1 commits and, because elro.gchg moved while it ran,
-- relayout_done launches run 2 -- which finds the area still dirty because
-- bg_guard_moved kept the flag that relayout_body would otherwise have cleared.
fresh() ; laid = {}
newroom(400, 1, {}, { sarea = "world" })
elro.bgLayout = true ; elro.bgSlice = 0 ; elro.autoflush = true
local runs = 0
elro.layout_one = function(aid)
  runs = runs + 1
  if runs == 1 then                                -- one walk, during the first build
    elro.gchg = (elro.gchg or 0) + 1
    elro.dirty[1] = true
    elro.cs_dirty(400)
  end
  elro.bg_tick()
  if elro.write_begin() then laid[#laid + 1] = aid end
end
elro.dirty = { [1] = true }
elro.flush_dirty()
frames = 0
while elro.bg_busy() and frames < 200 do pump() ; frames = frames + 1 end
eq(runs, 2, "the run committed and then rebuilt itself exactly once")
eq(#laid, 2, "both builds wrote")
ok(next(elro.dirty) == nil, "and the second build left nothing dirty")
stub_layout()

print("   ...and the redo loop cannot spin forever when nothing ever commits")
-- the run above re-queues itself (mixed input is a correctness redo, so it ignores
-- autoflush). Every attempt drops, so the spin guard has to stop it; without the
-- guard this test hangs on the timer storm.
eq(elro.bg_busy(), false, "the loop stopped instead of running forever")
stub_layout()
elro.autoflush = true

-- ============================== 6b. THE CELL INDEX AND THE COLLISION TRIGGER
print("6b. onRoom's unit-step guess, and whether it landed on somebody")
fresh() ; laid = {}
elro.autoflush = true ; elro.bgLayout = false
stub_layout()

-- a straight corridor: every guess lands on an empty cell
elro.onRoom(500, 0, "none", "a room", "world", "north")
elro.onRoom(501, 500, "north", "b room", "world", "north,south")
elro.onRoom(502, 501, "north", "c room", "world", "north,south")
local x, y = getRoomCoordinates(502)
eq(y, 2, "three rooms north of each other: the third guess is two steps up")
eq(elro.cell_at(1, 0, 1), 501, "the index knows who is on (0,1)")
ok(elro.cell_at(1, 0, 5) == nil, "...and that (0,5) is empty")

-- ⭐ THE COLLISION: an evil-room style loop that comes back on itself. 503 is
-- entered going north from 502, so it is guessed at (0,3); then 504 is entered
-- going SOUTH from 503, which guesses (0,2) -- where 502 already stands.
print("   a guess that lands on an occupied cell reports the occupant")
elro.onRoom(503, 502, "north", "d room", "world", "north,south")
eq(elro.cell_at(1, 0, 2), 502, "502 holds (0,2)")
local before = elro.gchg
elro.onRoom(504, 503, "south", "e room", "world", "north")
ok(elro.gchg > before, "the graph change was counted")
eq(select(1, getRoomCoordinates(504)), 0, "504 was guessed onto 502's column")
eq(select(2, getRoomCoordinates(504)), 2, "...and onto 502's row: they overlap")

print("   a layout commit drops the index, because every room just moved")
elro.cell_put(1, 99, 99, 777)
eq(elro.cell_at(1, 99, 99), nil, "a planted entry for a nonexistent room is ignored")
elro.cell_drop(1)
ok(elro.cell_at(1, 0, 1) == 501, "and a dropped index rebuilds itself from the map")

-- ================== 6c. area_min FOLDS INTO THE AREA YOU CAME IN FROM, NOT world
print("6c. a sub-area_min area is absorbed by the area you entered it from")
fresh()
elro.area_min = 3
elro.autoflush = false ; elro.bgLayout = false

-- a kept area: 4 rooms in a chain, comfortably over area_min
newroom(600, 1, { north = 601 }, { sarea = "forest" })
newroom(601, 1, { south = 600, north = 602 }, { sarea = "forest" })
newroom(602, 1, { south = 601, north = 603 }, { sarea = "forest" })
newroom(603, 1, { south = 602 }, { sarea = "forest" })
-- a 2-room hut hanging off it, entered from forest
newroom(610, 1, { north = 611 }, { sarea = "hut", via = "forest" })
newroom(611, 1, { south = 610 }, { sarea = "hut", via = "forest" })
-- ...one reached with no entry room at all (teleport / special exit)
newroom(620, 1, {}, { sarea = "hut2", via = elro.VIA_NONE })
-- ...and one that predates the feature: no via at all, sitting on the world map
newroom(630, 1, {}, { sarea = "hut3" })

elro.recompute_areas()
local A = elro.cs_areas()
eq(getRoomArea(610), A.forest, "the hut joins the forest it was entered from")
eq(getRoomArea(611), A.forest, "...and so does the room deeper inside it")
eq(getRoomArea(600), A.forest, "the forest itself is untouched")
ok(A.hut == nil or next(getAreaRooms(A.hut)) == nil, "and the hut tab is gone")

print("   ...with no entry room it keeps its own tab instead of vanishing into world")
eq(getRoomArea(620), A.hut2, "a teleport-only room is exempt from the fold")

print("   ...and a room that predates `via` still folds into world (nothing moves)")
eq(getRoomArea(630), A.world, "backfilled from where it already sat")
eq(getRoomUserData(630, "via"), "world", "and the backfill recorded that")

print("   ⭐ AND onRoom AGREES WITH recompute -- the anti-flicker property")
-- this is the whole reason `via` is stored rather than re-derived: re-entering the
-- hut must not yank it back out of the forest and onto a tab of its own.
elro.onRoom(611, 610, "north", "hut b", "hut", "south")
eq(getRoomArea(611), A.forest, "re-entering the hut leaves it in the forest")

print("   ⭐ ...and a room discovered DEEPER inside inherits it transitively")
-- no cluster-level machinery: 611's effective area IS forest by now, so a room
-- created off it reads forest as its own entry area and the hut keeps following.
elro.onRoom(613, 611, "east", "hut c", "hut", "west")
eq(getRoomUserData(613, "via"), "forest", "the new room's via came off its absorbed neighbour")
eq(getRoomArea(613), A.forest, "so it lands in the forest too, not on a hut tab")
setExit(613, 611, "west")

print("   ⭐ and a hut that grows past area_min gets its own tab back")
newroom(612, 1, { south = 611 }, { sarea = "hut", via = "forest" })
setExit(611, 612, "north")
elro.cs_reset()
elro.recompute_areas()
A = elro.cs_areas()
eq(getRoomArea(610), A.hut, "3 rooms now: `via` is ignored and the hut is its own area")
eq(getRoomArea(612), A.hut, "...for every room in it")

elro.area_min = 2

-- ===================== 6d. FOLLOWING THE PLAYER: ordering and the area switch
print("6d. the view follows the player, and updateMap comes first")
fresh()
elro.autoflush = false ; elro.bgLayout = false
elro.area_min = 2
elro._viewArea, elro._viewTimer = nil, nil
stub_layout()

-- centerview and updateMap are no-op stubs, so shadow them to record what happened
local seq, centered = {}, {}
local realCenter, realUpdate = centerview, updateMap
_G.centerview = function(id) seq[#seq + 1] = "center" ; centered[#centered + 1] = id end
_G.updateMap  = function()   seq[#seq + 1] = "update" end

newroom(700, 1, {}, { sarea = "world" })
newroom(701, 1, {}, { sarea = "world" })
elro.current = 700 ; elro.recenter() ; pump()      -- prime _viewArea

centered = {}
elro.current = 701 ; elro.recenter()
eq(#centered, 1, "an ordinary step centers exactly once")
eq(pump(), 0, "...and arms no timer at all while the canvas is unchanged")

print("   ...but crossing to another canvas re-asserts once on the next tick")
-- ⭐ THE CASE THAT WAS BROKEN. mapstep's own comment records that centerview is
-- only reliable when it does NOT have to change area, which is exactly what a
-- relayout asks of it after recompute_areas moves rooms between tabs.
M.areas.zone = 5
newroom(702, 5, {}, { sarea = "zone" })
centered = {}
elro.current = 702 ; elro.recenter()
eq(#centered, 1, "centers immediately")
-- ⭐⭐ TWO deferred attempts, not one, and the second is what the user was still
-- missing: *"the centering still doesn't work properly if the room you are in switches
-- canvas during a relayout"*. A single tempTimer(0) can land INSIDE the next build of a
-- level-loop chain -- the canvas is being cleared and rewritten around it -- and there
-- is nothing after it to correct the view. The later one settles it.
eq(pump(), 2, "and arms TWO deferred re-asserts -- an immediate one and a settling one")
eq(#centered, 3, "which center again once Mudlet has caught up")
eq(centered[2], 702, "on the room the player is actually in")
eq(centered[3], 702, "...and so does the settling attempt")

print("   ...and two canvas changes in a row re-assert ONCE, not twice")
centered = {}
elro.current = 700 ; elro.recenter()
elro.current = 702 ; elro.recenter()
eq(#centered, 2, "both steps centered immediately")
pump()
eq(#centered, 4, "but only ONE PAIR of deferred re-asserts survived the re-arm")

print("   \226\173\144 a relayout pushes the map BEFORE it recenters")
seq = {}
elro.dirty = { [1] = true, [5] = true }
elro.flush_dirty()
local iu, ic
for i, w in ipairs(seq) do
  if w == "update" and not iu then iu = i end
  if w == "center" and not ic then ic = i end
end
ok(iu ~= nil, "the relayout pushed the map")
ok(ic ~= nil, "and recentered")
ok(iu and ic and iu < ic, "updateMap ran BEFORE centerview (it used to be the other way round)")

-- ⭐⭐ AND ONE ASSERTION PUSHES THE MAP ON BOTH SIDES. The header's updateMap-then-
-- centerview rule was derived from the RELAYOUT, where coordinates are already final by
-- the time we center. A canvas SWITCH is the other case -- Mudlet has to change which
-- area the widget shows -- and that is the step the user watched fail twice: *"it's
-- still incorrectly centered after that canvas swap, until I chart another room"*.
-- Pushing on both sides costs one no-op call and removes the guess about which side
-- needs it.
seq = {}
elro._viewSwap = nil
elro.view_assert("test")
eq(table.concat(seq, ","), "update,center,update",
   "view_assert pushes the map, centers, and pushes again")

-- ⭐⭐⭐⭐ AND ON A REAL CANVAS SWITCH IT MUTATES THE MAP FIRST. Three rounds of
-- instrumentation established that `centerview` CANNOT recover a stuck cross-area view
-- -- the user ran it by hand, repeatedly, and nothing happened, while mapping one more
-- room fixed it instantly. What onRoom does that we did not is CHANGE THE MAP, so a
-- scratch room is added into the target area on the current room's own cell and deleted
-- again: net change to the map none, and the widget has to rebuild the area.
-- ⚠ The two assertions that matter are that it leaves NOTHING behind, and that it fires
-- only on an actual tab switch -- a relayout passes `always` even when the canvas did
-- not move, and mutating the map on every relayout would be a bad trade.
local before = 0 ; for _ in pairs(M.rooms) do before = before + 1 end
elro._viewSwap = true
elro.view_assert("swap")
local after = 0 ; for _ in pairs(M.rooms) do after = after + 1 end
eq(after, before, "the unstick leaves no scratch room behind")
eq(elro._viewSwap, nil, "...and clears the swap latch, so it fires once per switch")
elro.view_assert("again")
eq(elro._viewSwap, nil, "a second assertion for the same step does not mutate again")

elro.viewUnstick = false
elro._viewSwap = true
seq = {}
elro.view_assert("disabled")
eq(table.concat(seq, ","), "update,center,update", "viewUnstick=false turns it off outright")
elro.viewUnstick = nil ; elro._viewSwap = nil

-- ⭐⭐⭐⭐ AND A RELAYOUT ARMS IT, not just a tab switch. CONFIRMED IN GAME: the scratch
-- room is what recovers the view, so what goes stale is Mudlet's CACHED AREA SPAN --
-- recalculated when the area's ROOM SET changes, never when coordinates change -- and a
-- relayout rewrites every coordinate on the canvas.
-- ⛔ THE HOLE THIS CLOSES: onRoom moves the room to its new area and recenters BEFORE
-- any layout runs, so a switch-only latch was consumed by an unstick fired while the
-- area was still unlaid, and the relayout that followed re-staled the span with the
-- latch already cleared. The REWRITE is the event that matters.
before = 0 ; for _ in pairs(M.rooms) do before = before + 1 end
elro.dirty = { [1] = true }
elro._viewSwap = nil
elro.flush_dirty()
ok(elro._viewSwap, "a relayout ARMS the unstick, whether or not the canvas changed")
pump()                                   -- ...and the deferred assertion spends it
ok(elro._viewSwap == nil, "...which the next view assertion then spends")
local after2 = 0 ; for _ in pairs(M.rooms) do after2 = after2 + 1 end
eq(after2, before, "...leaving no scratch room behind")

-- lplp AND IT RE-ASSERTS EVEN THOUGH THE CANVAS DID NOT CHANGE. A relayout
-- rewrites every coordinate, so the view needs the same second attempt a canvas
-- switch gets -- and in a level-loop chain the later runs would otherwise all
-- early-return on the unchanged-canvas gate.
centered = {}
elro.dirty = { [1] = true }
elro.flush_dirty()
local immediate = #centered
eq(pump(), 2, "a relayout arms the deferred re-asserts even on an unchanged canvas")
eq(#centered, immediate + 2, "and they fire")

_G.centerview, _G.updateMap = realCenter, realUpdate
elro.autoflush = true

-- ======================================= 7. THE LUA 5.1 C-CALL BOUNDARY RULE
print("7. no pcall may sit on the coroutine's stack (emulating stock Lua 5.1)")
-- LuaJIT permits yielding across pcall, so this interpreter cannot reproduce the
-- failure on its own. Count pcall depth and refuse to yield inside one, which is
-- exactly the restriction Mudlet's stock 5.1 enforces in the VM.
local realpcall, depth, violation = pcall, 0, nil
local realtick = elro.bg_tick
_G.pcall = function(f, ...)
  depth = depth + 1
  local a, b, c = realpcall(f, ...)
  depth = depth - 1
  return a, b, c
end
elro.bg_tick = function()
  local bg = elro._bg
  if bg and coroutine.running() == bg.co and depth > 0 then
    violation = "yield attempted with " .. depth .. " pcall frame(s) on the stack"
  end
  return realtick()
end

fresh() ; laid = {}
newroom(400, 1, {}, { sarea = "world" })
elro.bgLayout = true ; elro.bgSlice = 0
-- the real shape of the bug: layout_eqw used to pcall the whole solve
elro.layout_one = function(aid)
  if elro.bg_inside() then
    elro.bg_tick() ; if elro.write_begin() then laid[#laid + 1] = aid end   -- the fixed path
  else
    pcall(function() elro.bg_tick() ; laid[#laid + 1] = aid end)            -- the old path
  end
end
elro.dirty = { [1] = true }
elro.flush_dirty()
frames = 0
while elro.bg_busy() and frames < 200 do pump() ; frames = frames + 1 end
eq(#laid, 1, "the solve completed")
ok(violation == nil, "no yield happened inside a pcall" .. (violation and (" -- " .. violation) or ""))

print("   ...and the harness itself detects the violation when it IS there")
violation = nil
fresh()
elro.bgSlice = 0
elro.bg_start(function() pcall(function() elro.bg_tick() end) end, "bad")
frames = 0
while elro.bg_busy() and frames < 50 do pump() ; frames = frames + 1 end
ok(violation ~= nil, "detector is not vacuous: " .. tostring(violation))

_G.pcall = realpcall
elro.bg_tick = realtick

print("")
if FAIL == 0 then print("ALL PASS") else print(FAIL .. " FAILURE(S)") ; os.exit(1) end
