-- WHAT DOES PLANARITY COST EACH FACE?
--
--   luajit analysis/test_face_cost.lua analysis/soulfly.txt
--   for f in analysis/*.txt; do luajit analysis/test_face_cost.lua $f --summary; done
--
-- Drives `elro.facefit(..., elro.crossCost = true)` rather than re-implementing anything: the face
-- enumeration, the wedge containment, the ring closure and the box-fit growth all live in the
-- engine, and a harness copy is how the two drift. Everything here is the DUMP LOADER and printing.
--
-- ⭐ THE TARGETS (hand-solved by the user; these are what the numbers must reproduce):
--     rand    rhombus 5283-5276-5307-5301   base 4  -> 20   (+16)
--     soulfly face holding 68 (the 10-cycle) base 10 -> ~48 (+38)
--     dannoc  the 28-edge face holding 51    base 28 -> ~33 (+5)
--     world / dunstan outer                  +0, planarity free
-- ⛔ AND THE RANKING IS TOTAL EXCESS, NEVER PER EDGE -- five metrics died of per-edge normalisation,
-- which puts rand ABOVE soulfly every single time.
dofile("analysis/engine_load.lua")
local dumpPath = arg[1] or error("usage: test_face_cost.lua <dump> [--summary]")
local summary = (arg[2] == "--summary")

local DELTA = { east = {1,0}, northeast = {1,1}, north = {0,1}, northwest = {-1,1},
                west = {-1,0}, southwest = {-1,-1}, south = {0,-1}, southeast = {1,-1} }
local REV = { east="west", west="east", north="south", south="north",
              northeast="southwest", southwest="northeast",
              northwest="southeast", southeast="northwest" }

local ADJ, ORDER, POS = {}, {}, {}
do
  local f = assert(io.open(dumpPath, "r"))
  for ln in f:lines() do
    local id, x, y, ex = ln:match("^%s*(%d+) %((-?%d+),(-?%d+),%-?%d+%) area=%S+ %[(.*)%]%s*$")
    if id then
      id = tonumber(id) ; ORDER[#ORDER + 1] = id ; ADJ[id] = ADJ[id] or {}
      POS[id] = { tonumber(x), tonumber(y) }
      for d, t in ex:gmatch("(%a+)%->(%d+)") do if DELTA[d] then ADJ[id][d] = tonumber(t) end end
    end
  end
  f:close()
end
-- ⛔⛔⛔ RUN `elro.walk_adj` -- THE HARNESS MUST TAKE THE ENGINE'S PATH, NOT A HAND-ROLLED ONE.
-- This used to symmetrise the exits itself and drop non-mutual ones. That is NOT what the engine
-- sees: `facefit_report` feeds `elro.walk_adj(adj)`, which demotes fan-in extras and refuted soft
-- edges FIRST and only then mirrors the survivors. The two graphs differ -- on soulfly, 61 bounded
-- faces in game against 60 here -- and every number this harness printed was systematically LOW
-- because of it: the 10-cycle priced 34 offline against **48 in game, which is the hand-solved
-- truth**. A harness that models the input differently from the engine is not a proxy for it.
-- ⚠ `walk_adj` is a pure function of `adj` (no Mudlet calls anywhere in it), so this is available
-- offline exactly as the engine runs it.
ADJ = elro.walk_adj(ADJ)

elro.crossCost = true
if os.getenv("NOBOX") then elro.crossCostBox = false end   -- crossCostBox is DEFAULT ON
elro.TUNE.crossCostTau = tonumber(os.getenv("TAU") or "0")
local _, rep = elro.facefit(ORDER, ADJ)
if not rep or not rep.faceCost then
  print(string.format("%s: nothing to price (%d rooms, core %d)", dumpPath, #ORDER,
    (rep and rep.core) or 0))
  os.exit(0)
end
local W = elro.wire_cross(ADJ)
local tot, nfit, nunfit = 0, 0, 0
for _, C in ipairs(rep.faceCost) do
  if C.excess then tot = tot + C.excess ; nfit = nfit + 1 else nunfit = nunfit + 1 end
end
print(string.format("%s: %d rooms, core %d, %d bounded face(s), %d priced -- TOTAL EXCESS %d"
  .. " (%d unpriced)%s", dumpPath, rep.rooms, rep.core, rep.bounded, nfit, tot, nunfit,
  (W.cycles > 0) and ("  [WARNING: " .. W.cycles .. " class(es) on an order cycle -- axis "
    .. tostring(W.cycleAxis) .. "; the chain bounds are unreliable]") or ""))
if summary then os.exit(0) end
print(string.format("%-6s %6s %6s %8s %6s %6s   %s",
  "face", "edges", "holds", "needs", "base", "got", "SAVED / escape cost"))
for _, C in ipairs(rep.faceCost) do
  local why = C.open and "RING DOES NOT CLOSE"
    or (C.unfit and string.format("NO FIT (best box %s%s)", C.box or "?",
          C.selfint and ", self-crossed while growing" or ""))
    or string.format("len +%-3d area +%-4d  ESCAPE %-8s area/cross %6.1f", C.excess, (C.area or 0)-(C.area0 or 0), tostring(C.esc or "BLOCKED"), ((C.area or 0)-(C.area0 or 0)) / math.max(C.esc or 99, 1))
  if C.wanted then why = "** WANTED ** " .. why end
  local L = {}
  for i = 1, math.min(#C.ring, 6) do L[#L + 1] = C.ring[i] end
  if #C.ring > 6 then L[#L + 1] = "..." end
  print(string.format("%-6d %6d %6d %8s %6s %6s   %-28s %s", C.fi, C.n, C.need,
    (C.w or 0) .. "x" .. (C.h or 0), tostring(C.base or "-"), tostring(C.got or "-"),
    why, table.concat(L, "-")))
end
