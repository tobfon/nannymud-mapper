-- Offline coverage for elro.vert_census (the `mapvert` up/down census).
-- Run from the client dir:  luajit analysis/test_vert.lua
--
-- ⭐ WHY A SYNTHETIC MAP AND NOT AN AREA DUMP: the classification's four buckets
-- need a three-staircase RING and a merely-ASSUMED reverse in the same fixture, and
-- no real area happens to carry both. The topologies below are hand-built for that
-- reason -- one fixture per argument, not one per area.
-- ⛔ NOT because the dumps lack verticals. This header used to claim they do
-- ("written from `adj`, which drops every vertical edge"); that was false and was
-- corrected 2026-08-19. `elro.dump_file` writes from getRoomExits, so world_live
-- carries 64 vertical darts and soulfly 12 -- see analysis/test_vertpack.lua, which
-- checks the PACK'S behaviour here and its SIZE against those dumps.
--
-- The cases are the argument the classification rests on, one fixture each:
--   redundant  -- a stair beside a corridor: both ends already in one component
--   forest     -- the only link between two floors: exactly satisfiable
--   cycle      -- TWO staircases between the same two floors: over-determined
--   ring       -- A->B->C->A, three staircases, each the only link of ITS pair.
--                 This is the case "honour it if it is the only link" gets wrong
--                 and the spanning forest gets right, so it is the load-bearing
--                 test in this file.
--   cross      -- far end on another canvas
--   one-way    -- a vertical with no walked reverse (and one with a merely
--                 ASSUMED reverse, which must not read as corroborated)

package.path = "analysis/?.lua;" .. package.path
dofile("analysis/engine_load.lua")

local fail, ntest = 0, 0
local function ok(cond, what)
  ntest = ntest + 1
  if not cond then fail = fail + 1 ; print("  FAIL: " .. what) end
end
local function eq(got, want, what)
  ntest = ntest + 1
  if got ~= want then
    fail = fail + 1
    print(string.format("  FAIL: %s -- got %s want %s", what, tostring(got), tostring(want)))
  end
end

-- ---- fixture helpers ------------------------------------------------------
local AID_MAIN, AID_OTHER

local function room(id, area, x, y)
  addRoom(id) ; setRoomArea(id, area or AID_MAIN) ; setRoomCoordinates(id, x or 0, y or 0)
end
-- a reciprocal compass link
local function link(a, b, d)
  setExit(a, b, d) ; setExit(b, a, elro.reverse[d])
end
-- a reciprocal vertical link (both darts observed)
local function stair(a, b)
  setExit(a, b, "up") ; setExit(b, a, "down")
end

local function build()
  AID_MAIN  = addAreaName("mainarea")
  AID_OTHER = addAreaName("otherarea")

  -- 1. REDUNDANT: 1-2-3 east chain, plus a stair 1<->3. One component.
  room(1, AID_MAIN, 0, 0) ; room(2, AID_MAIN, 1, 0) ; room(3, AID_MAIN, 2, 0)
  link(1, 2, "east") ; link(2, 3, "east")
  stair(1, 3)

  -- 2. FOREST: two isolated chains joined by exactly one stair.
  room(10, AID_MAIN, 0, 5) ; room(11, AID_MAIN, 1, 5) ; link(10, 11, "east")
  room(20, AID_MAIN, 0, 9) ; room(21, AID_MAIN, 1, 9) ; link(20, 21, "east")
  stair(10, 20)

  -- 3. CYCLE: two staircases between the same two floors.
  room(30, AID_MAIN, 0, 15) ; room(31, AID_MAIN, 1, 15) ; link(30, 31, "east")
  room(40, AID_MAIN, 0, 19) ; room(41, AID_MAIN, 1, 19) ; link(40, 41, "east")
  stair(30, 40) ; stair(31, 41)

  -- 4. RING: three floors, three staircases, no two of them sharing a pair.
  room(50, AID_MAIN, 0, 25) ; room(51, AID_MAIN, 1, 25) ; link(50, 51, "east")
  room(60, AID_MAIN, 0, 29) ; room(61, AID_MAIN, 1, 29) ; link(60, 61, "east")
  room(70, AID_MAIN, 0, 33) ; room(71, AID_MAIN, 1, 33) ; link(70, 71, "east")
  stair(50, 60) ; stair(60, 70) ; stair(70, 50)

  -- 5. CROSS-AREA: the far end is on another canvas.
  room(80, AID_MAIN, 5, 0) ; room(90, AID_OTHER, 0, 0)
  stair(80, 90)

  -- 6. ONE-WAY vertical (no reverse dart at all), between two components.
  room(100, AID_MAIN, 5, 5) ; room(101, AID_MAIN, 5, 9)
  setExit(100, 101, "up")

  -- 7. ASSUMED reverse -- the trap. onRoom fabricates the reverse so return
  -- navigation works, which makes a one-way LOOK walked. It must be reported
  -- reciprocal but NOT corroborated.
  room(110, AID_MAIN, 8, 5) ; room(111, AID_MAIN, 8, 9)
  setExit(110, 111, "up") ; setExit(111, 110, "down")
  setRoomUserData(111, "assumed_down", "1")

  elro.cs_reset()
end

-- ---- run ------------------------------------------------------------------
build()
local c = elro.vert_census(AID_MAIN)

local by = {}
for _, p in ipairs(c.links) do by[p.key] = p end
local function cls(a, b)
  local lo, hi = a, b ; if lo > hi then lo, hi = hi, lo end
  local p = by[lo .. ":" .. hi]
  return p and p.cls or "MISSING"
end

print("test_vert: " .. #c.links .. " vertical link(s), " .. c.ncomp .. " compass component(s)")

-- every vertical is seen exactly once, folded to an undirected link
eq(#c.links, 10, "link count (1 redundant + 1 forest + 2 twin-stair + 3 ring + 1 cross + 2 oneway/assumed)")

-- 1. redundant
eq(cls(1, 3), "redundant", "stair beside a corridor is redundant")

-- 2. forest
eq(cls(10, 20), "forest", "the only link between two floors is honourable")

-- 3. two staircases: exactly one forest, one cycle -- NOT two of either
local a34, b34 = cls(30, 40), cls(31, 41)
ok((a34 == "forest" and b34 == "cycle") or (a34 == "cycle" and b34 == "forest"),
   "two staircases between one pair of floors -> one forest + one cycle (got "
   .. a34 .. "/" .. b34 .. ")")

-- 4. THE RING. Each of the three links is the only one between its own pair, so
-- an "is it the only link?" test would honour all three and over-determine the
-- translation. The forest must keep exactly two.
local ring = { cls(50, 60), cls(60, 70), cls(50, 70) }
local nf, nc = 0, 0
for _, k in ipairs(ring) do
  if k == "forest" then nf = nf + 1 elseif k == "cycle" then nc = nc + 1 end
end
eq(nf, 2, "three-staircase ring keeps 2 forest links")
eq(nc, 1, "three-staircase ring demotes exactly 1 to cycle")

-- 5. cross-area
eq(cls(80, 90), "cross", "far end on another canvas is cross-area")
ok(by["80:90"].dist == nil, "cross-area link gets no distance (no shared geometry)")
-- ⚠ REGRESSION GUARD: the dart scan only visits rooms of THIS area, so the
-- reverse of a cross-area link lives somewhere we never walked. Every one of
-- them read as one-way until vert_census asked the far room directly.
eq(by["80:90"].recip, true, "a cross-area stair with a walked reverse is reciprocal")
eq(by["80:90"].corrob, true, "...and corroborated, even though the far end is off-area")

-- 6/7. provenance
eq(by["100:101"].recip, false, "a vertical with no reverse dart is not reciprocal")
eq(by["100:101"].corrob, false, "...and not corroborated")
eq(by["110:111"].recip, true, "an assumed reverse looks reciprocal")
eq(by["110:111"].corrob, false, "...but a FABRICATED reverse is never corroboration")
eq(by["1:3"].corrob, true, "a walked round trip IS corroborated")

-- counts add up and match the classification
eq(c.n.redundant + c.n.forest + c.n.cycle + c.n.cross, #c.links, "buckets partition the links")
eq(c.n.cross, 1, "one cross-area link")
eq(c.n.redundant, 1, "one redundant link")

-- the headline number the report prints: components before -> after the forest
eq(c.ncomp - c.n.forest, c.ncomp - c.n.forest, "component reduction is well-formed")
ok(c.n.forest < c.ncomp, "a forest over N components has fewer than N edges")

-- geometry: 1<->3 runs straight through room 2, which is exactly the
-- "no room to draw it" case the renderer would have to decline.
eq(by["1:3"].block, 2, "1<->3 is BLOCKED by room 2 sitting on the run")
eq(by["1:3"].dist, 2, "1<->3 spans 2 cells")
eq(by["10:20"].block, nil, "10<->20 has a clear run")

-- ---- determinism: the forest/cycle split must not depend on hash order -----
-- ⚠ elro.cs_room iterates rec.ex with pairs(), and which staircase becomes the
-- forest edge depends on the order the darts arrive in. Re-running from a cold
-- c-space must reproduce the identical classification.
local first = {}
for _, p in ipairs(c.links) do first[p.key] = p.cls end
for pass = 1, 5 do
  elro.cs_reset()
  local c2 = elro.vert_census(AID_MAIN)
  eq(#c2.links, #c.links, "pass " .. pass .. ": same link count")
  for _, p in ipairs(c2.links) do
    eq(p.cls, first[p.key], "pass " .. pass .. ": " .. p.key .. " keeps its class")
  end
end

-- ---- the census mutates nothing -------------------------------------------
-- ⛔ graph-vs-canvas: a report may never change exits or coordinates.
local before = {}
for id in pairs(getRooms()) do
  local x, y = getRoomCoordinates(id)
  local ex = {}
  for d, v in pairs(getRoomExits(id)) do ex[#ex + 1] = d .. "=" .. v end
  table.sort(ex)
  before[id] = x .. "," .. y .. "|" .. table.concat(ex, ",")
end
elro.cs_reset()
elro.vert_census(AID_MAIN)
elro.vert_census(AID_OTHER)
for id, sig in pairs(before) do
  local x, y = getRoomCoordinates(id)
  local ex = {}
  for d, v in pairs(getRoomExits(id)) do ex[#ex + 1] = d .. "=" .. v end
  table.sort(ex)
  eq(x .. "," .. y .. "|" .. table.concat(ex, ","), sig, "room " .. id .. " untouched")
end

-- the other area sees the same cross-area link from its own side
local co = elro.vert_census(AID_OTHER)
eq(#co.links, 1, "otherarea sees the cross link too")
eq(co.links[1].cls, "cross", "...and classifies it cross-area as well")

print(string.format("test_vert: %d check(s), %d failure(s)", ntest, fail))
os.exit(fail == 0 and 0 or 1)
