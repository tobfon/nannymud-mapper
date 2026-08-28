-- WHICH OBJECTS WOULD `crossCostTau` FIRE ON, ACROSS THE WHOLE CORPUS?
--
--   luajit analysis/test_cross_rank.lua analysis/*.txt          -- rank everything
--   TAU=200 luajit analysis/test_cross_rank.lua analysis/*.txt  -- and mark what fires
--
-- The threshold question is not answerable one dump at a time: a tau is only safe if the object it
-- is meant to catch sits ABOVE every object it must not. This ranks every priced face and curl in
-- the corpus by REALISABLE gain, so the gaps -- and the collisions -- are visible in one list.
--
-- ⭐ THE RANKING AS OF 2026-08-15, and the two things it settled:
--     252.0  soulfly face 6                 <- want
--     131.6  world_live / sel face 3        <- must NOT fire (share 0.54 -- see below)
--     112.0  soulfly CURL          COLLIDES <- want, and it is SANDWICHED
--      84.0  rand rhombus                   <- must not fire
--      48.8  lyr face 7 (already forced)
--   1. Raw area/crossing put soulfly's face at 252 and world_live's at 243 -- a 4% gap, which is
--      luck, not a margin. Discounting by LOAD CONCENTRATION (the biggest single attachment's share
--      of the load: contents split over attachments pointing different ways cannot all leave through
--      one wall) takes world_live to 131.6 and leaves soulfly at 252.
--   2. soulfly's CURL still sits BELOW world_live, so no threshold caught both soulfly objects --
--      not tunable. It is exempted instead, because its window closes at ZERO displacement: the
--      planar alternative is a ROOM COLLISION, which per [[project_defect_severity]] outranks any
--      area comparison. ⭐ The flag fires on that curl alone across all 30 dumps, and NOT on
--      `soulfly_curl_planar` -- the hand-drawn curl that IS drawable planar.
-- ⇒ tau in (131.6, 252] takes soulfly's face and its curl and nothing else in the corpus.
--
-- ⚠ ONE PROCESS PER INVOCATION, so the numbers are comparable across dumps here; the LAYOUT is not
-- (LuaJIT hash seed). This measures the ANALYSIS only -- no walk, no coordinates.
dofile("analysis/engine_load.lua")

local DELTA = { east = {1,0}, northeast = {1,1}, north = {0,1}, northwest = {-1,1},
                west = {-1,0}, southwest = {-1,-1}, south = {0,-1}, southeast = {1,-1} }
local rows = {}
for i = 1, #arg do
  local ADJ, ORDER = {}, {}
  local f = assert(io.open(arg[i]))
  for ln in f:lines() do
    local id, _, _, ex = ln:match("^%s*(%d+) %((-?%d+),(-?%d+),%-?%d+%) area=%S+ %[(.*)%]%s*$")
    if id then
      id = tonumber(id) ; ORDER[#ORDER + 1] = id ; ADJ[id] = {}
      for d, t in ex:gmatch("(%a+)%->(%d+)") do if DELTA[d] then ADJ[id][d] = tonumber(t) end end
    end
  end
  f:close()
  -- ⛔ walk_adj, ALWAYS: the engine demotes fan-in extras and refuted soft edges before mirroring,
  -- and a harness that symmetrises by hand is modelling a different graph (soulfly read 61 bounded
  -- faces in game against 60 offline, and every number was quietly low).
  ADJ = elro.walk_adj(ADJ)
  elro.crossCost = true
  elro.TUNE.crossCostTau = tonumber(os.getenv("TAU") or "1e-9")   -- tiny, not 0: 0 skips the verdict
  elro._crossQuartets, elro._crossPairKeys, elro.minLen = nil, nil, nil
  local ok, _, rep = pcall(elro.facefit, ORDER, ADJ)
  local name = arg[i]:match("([^/\\]+)%.txt$") or arg[i]
  if not ok then
    rows[#rows + 1] = { g = -1, s = string.format("%-20s CRASHED: %s", name, tostring(rep)) }
  elseif rep then
    for _, C in ipairs(rep.faceCost or {}) do
      if (C.gain or 0) > 0.5 then
        rows[#rows + 1] = { g = C.gain, s = string.format(
          "%-20s %-5s %-5s area+%-5d esc %-5s share %.2f%s%s", name,
          C.curl and "CURL" or ("f" .. C.fi), C.fi, (C.area or 0) - (C.area0 or 0),
          tostring(C.esc), C.share or -1,
          (C.multi and string.format("  MULTI %d", #(C.att or {})) or "") .. ((not C.esc) and "  BLOCKED" or ""), C.wanted and "   ** WANTED **" or "") }
      end
    end
  end
end
table.sort(rows, function(a, b) if a.g ~= b.g then return a.g > b.g end return a.s < b.s end)
print(string.format("%8s   %-20s %-5s %-5s %-10s %-9s %s",
  "GAIN", "dump", "kind", "face", "area saved", "escape", "share"))
for _, r in ipairs(rows) do print(string.format("%8.1f   %s", r.g, r.s)) end
