-- Exit stubs: created for advertised exits we have not walked, RETRACTED once the
-- real edge is known.
--
-- ⛔ THE BUG THIS PINS: onRoom used to call setExitStub(id, dir, true) for every
-- advertised compass direction on every arrival, with no check for a real link and
-- nothing ever retracting one. A fully explored room in a dense area therefore
-- carried a stub AND an edge in every direction -- geometry proportional to how
-- interconnected the area is, redrawn by Mudlet whether or not you move.
--   cd .../map_helper/client && luajit analysis/test_stubs.lua
dofile("analysis/engine_load.lua")

local fails, checks = 0, 0
local function ok(cond, what)
  checks = checks + 1
  if not cond then fails = fails + 1 ; print("  FAIL  " .. what) end
end

-- a stub-aware fake Mudlet: the real setExitStub takes a direction NUMBER
local STUBS, WRITES = {}, 0
_G.setExitStub = function(id, n, on)
  WRITES = WRITES + 1
  STUBS[id] = STUBS[id] or {}
  STUBS[id][n] = (on ~= false) or nil
end
_G.getExitStubs = function(id)
  local t = {}
  for n in pairs(STUBS[id] or {}) do t[#t + 1] = n end
  return t
end
local function count(id)
  local n = 0 ; for _ in pairs(STUBS[id] or {}) do n = n + 1 end ; return n
end

local MAPUD = {}
_G.setMapUserData = function(k, v) MAPUD[k] = v end
_G.getMapUserData = function(k) return MAPUD[k] or "" end

local aid
local function fresh()
  reset_map() ; elro.cs_reset() ; STUBS = {} ; WRITES = 0
  aid = addAreaName("t")
  for i = 1, 3 do addRoom(i) ; setRoomArea(i, aid) end
end

print("stub_set -- shape tolerance")
STUBS = { [1] = { [1] = true, [4] = true } }
local set = elro.stub_set(1)
ok(set[1] and set[4], "reads a list of direction numbers")
_G.getExitStubs = function() return { [1] = true, [4] = true } end   -- the other shape
set = elro.stub_set(1)
ok(set[1] and set[4], "...and a table keyed by them -- neither half is trusted")
_G.getExitStubs = function() error("no such function in this build") end
ok(next(elro.stub_set(1)) == nil, "a build without it degrades to an empty set, not a crash")
_G.getExitStubs = function(id)
  local t = {} ; for n in pairs(STUBS[id] or {}) do t[#t + 1] = n end ; return t
end

print("created for what has not been walked")
fresh()
elro.onRoom(1, 0, "none", "Hall", "t", "north,south,east,west", "indoors")
ok(count(1) == 4, "four advertised exits, four stubs (" .. count(1) .. ")")

print("retracted when the edge is learned")
-- ⭐ ON THE FIRST ARRIVAL, not on a revisit: the stub pass runs after the edge
-- write and reads exits LIVE, because elro.cs_room is not invalidated until the
-- end of onRoom and would still be showing the room as it was.
elro.onRoom(2, 1, "east", "Yard", "t", "west", "outdoors")
ok(count(2) == 0, "room 2 advertises only the way it came, so it keeps no stub (" .. count(2) .. ")")
-- ⚠ ONLY THE ARRIVAL ROOM IS TOUCHED. Walking 1->2 runs onRoom for 2, so room 1
-- still carries its east stub until you go back -- which is exactly why mapstubs
-- clear exists for a map that already accumulated them.
ok(count(1) == 4, "room 1 keeps its now-stale east stub until it is entered again")
WRITES = 0
elro.onRoom(1, 2, "west", "Hall", "t", "north,south,east,west", "indoors")
ok(count(1) == 3, "re-entering room 1 drops the east stub (" .. count(1) .. ")")
ok(WRITES == 1, "and writes ONLY that one retraction (" .. WRITES .. ")")
-- nothing may be stubbed on a direction that already has a real edge
local redundant = 0
for _, r in ipairs({ 1, 2, 3 }) do
  local ex = elro.cs_exits(r)
  for n in pairs(elro.stub_set(r)) do
    for d, num in pairs(elro.dirNum) do
      if num == n and ex[d] then redundant = redundant + 1 end
    end
  end
end
ok(redundant == 0, "no stub is left on a direction that has a real edge (" .. redundant .. ")")

print("no write when nothing changed")
-- the old code re-stubbed every direction on every arrival; a map mutation is not
-- free even when it changes nothing
WRITES = 0
elro.onRoom(1, 2, "west", "Hall", "t", "north,south,east,west", "indoors")
ok(WRITES == 0, "a second revisit writes no stubs at all (" .. WRITES .. ")")

print("hiding is LOSSLESS")
-- ⛔ THE FLAW THIS FIXES: an advertised COMPASS exit used to be stored nowhere --
-- xspec keeps only the non-compass ones -- so the Mudlet stub WAS the record, and
-- clearing stubs destroyed knowledge only re-walking could restore. xcomp persists
-- it, which is what makes the toggle safe to use.
fresh()
elro.onRoom(1, 0, "none", "Hall", "t", "north,south,east,west", "indoors")
ok(getRoomUserData(1, "xcomp") == "east,north,south,west",
   "the advertised list is recorded, sorted (got '" .. getRoomUserData(1, "xcomp") .. "')")
local before = count(1)
elro.set_stubshow(false) ; elro.stub_resync(nil)
ok(count(1) == 0, "off clears every stub (" .. count(1) .. ")")
ok(getRoomUserData(1, "xcomp") ~= "", "...but not the record they were derived from")
elro.set_stubshow(true) ; elro.stub_resync(nil)
ok(count(1) == before, "on rebuilds exactly what was there (" .. count(1) .. " vs " .. before .. ")")
ok(getMapUserData("elro.stubsShown") == "on", "and the preference is persisted, not session-only")

print("backfill for rooms mapped before xcomp existed")
fresh()
STUBS[1] = { [1] = true, [4] = true }            -- an old room: stubs, no record
setRoomUserData(1, "xcomp", "")
ok(elro.stub_backfill(1), "a room with stubs and no record is backfilled")
local xc = getRoomUserData(1, "xcomp")
ok(xc:find("north", 1, true) and xc:find("east", 1, true),
   "...from its stubs (got '" .. xc .. "')")
ok(not elro.stub_backfill(1), "and only once")

print("resync repairs a map that drifted")
-- the fix stops new ones; a map where a link arrived behind the mapper's back
-- still needs sweeping, which is what a resync does
fresh()
elro.onRoom(1, 0, "none", "Hall", "t", "north,east", "indoors")
ok(count(1) == 2, "two advertised, two stubs (" .. count(1) .. ")")
setExit(1, 2, "north")                       -- a link the mapper never saw
elro.cs_reset()
elro.stub_resync(aid)
ok(count(1) == 1, "resync retracts the stub the new edge made redundant (" .. count(1) .. ")")
ok(elro.stub_set(1)[elro.dirNum.east], "leaving the one still telling the truth")

print("the halo")
-- ⭐ Bounded by the RADIUS, not by how much of the map is explored -- which is the
-- only property that keeps a growing map from getting slower, since Mudlet
-- repaints every stub in the viewport every frame.
reset_map() ; elro.cs_reset() ; STUBS = {} ; WRITES = 0
aid = addAreaName("grid")
-- a 21x1 corridor: room i at (i,0), every room advertising all four compass dirs
for i = 1, 21 do
  addRoom(i) ; setRoomArea(i, aid) ; setRoomCoordinates(i, i, 0, 0)
  setRoomUserData(i, "xcomp", "east,north,south,west")
end
for i = 1, 20 do setExit(i, i + 1, "east") ; setExit(i + 1, i, "west") end
elro.cs_reset()
elro.set_stubshow(true)
elro.stubHalo = 3
elro.stubHaloMin = 1000                      -- far above what this area has
elro.current = 11
elro._stubOn = nil ; elro._stubHaloActive = nil
elro.stub_resync(nil)
local total = 0 ; for i = 1, 21 do total = total + count(i) end
ok(total > 0, "below the threshold every stub shows (" .. total .. ")")
local shownAll = total

-- ⚠ and the threshold is the point: a small area is not worth hiding anything in
elro.stubHaloMin = 10                        -- now the area qualifies
elro.stub_count_dirty()
elro.stub_halo_update()
local near, far = 0, 0
for i = 1, 21 do
  if math.abs(i - 11) <= 3 then near = near + count(i) else far = far + count(i) end
end
ok(far == 0, "beyond the halo, no stubs (" .. far .. ")")
ok(near > 0, "within it, they stay -- that is where you are mapping (" .. near .. ")")

-- walking moves the halo with you: what you approach comes back
elro.current = 18
elro.stub_halo_update()
ok(count(18) > 0, "walking to room 18 brings its stubs back")
ok(count(11) > 0 or count(8) == 0, "and the ones left behind go quiet")
local behind = 0
for i = 1, 14 do behind = behind + count(i) end
ok(behind == 0, "everything more than 3 cells behind is hidden (" .. behind .. ")")

-- dropping back below the threshold restores everything it hid
elro.stubHaloMin = 1000
elro.stub_count_dirty()
elro.stub_halo_update()
total = 0 ; for i = 1, 21 do total = total + count(i) end
ok(total == shownAll, "falling below the threshold puts them ALL back (" .. total .. "/" .. shownAll .. ")")

-- and the record was never touched by any of it
ok(getRoomUserData(7, "xcomp") == "east,north,south,west",
   "the advertised record survives every hide and show")
elro.stubHalo = 0 ; elro.stubHaloMin = 100
elro._stubOn = nil ; elro._stubHaloActive = nil

print("the knob")
fresh()
elro.exitStubs = false
elro.onRoom(1, 0, "none", "Hall", "t", "north,south,east,west", "indoors")
ok(count(1) == 0, "elro.exitStubs = false creates none at all")
elro.exitStubs = true

print("")
if fails == 0 then print("PASS  " .. checks .. "/" .. checks .. " checks passed")
else print("FAIL  " .. fails .. "/" .. checks .. " checks failed") ; os.exit(1) end
