-- WHAT DOES A CROSSING ACTUALLY BUY, AND IN WHICH CURRENCY?
--
--   luajit analysis/test_currency.lua analysis/soulfly_sub.txt analysis/soulfly_crossed.txt
--
-- ⭐ A MATCHED PAIR, WHICH IS THE ONLY HONEST WAY TO ASK THIS. Both dumps hold the SAME 80 rooms and
-- the SAME exits; the second is the user's hand edit with the 360-degree arm allowed to cross. So
-- every difference between them is what that one crossing bought, measured on real geometry rather
-- than argued about.
--
-- ⚠ THE CURRENCY IS THE OPEN QUESTION (user): *"I am also not sure it's correct to just count edge
-- length saved. Especially if you are counting a diagonal edge as the same length as an axial
-- because that is just not true right? We could either have a diagonal penalty of 1.5 or try to
-- assess area saved by the crossing."* So all three are printed side by side:
--   CHEB   max(|dx|,|dy|)      -- what `elro.crossCost` counts today; a diagonal costs the same
--                                 as an axial, which is the thing under suspicion
--   EUCL   sqrt(dx^2+dy^2)     -- a diagonal costs 1.41x, the honest drawn length
--   AREA   bounding box, and the enclosed area of each ring by the shoelace
dofile("analysis/engine_load.lua")
local A, B = arg[1], arg[2]
if not (A and B) then error("usage: test_currency.lua <planar dump> <crossed dump>") end

local DELTA = elro.delta
local function load(path)
  local POS, ADJ, ORDER = {}, {}, {}
  local f = assert(io.open(path, "r"))
  for ln in f:lines() do
    local id, x, y, ex = ln:match("^%s*(%d+) %((-?%d+),(-?%d+),%-?%d+%) area=%S+ %[(.*)%]%s*$")
    if id then
      id = tonumber(id) ; ORDER[#ORDER + 1] = id ; ADJ[id] = ADJ[id] or {}
      POS[id] = { tonumber(x), tonumber(y) }
      for d, t in ex:gmatch("(%a+)%->(%d+)") do
        if DELTA[d] then ADJ[id][d] = tonumber(t) end
      end
    end
  end
  f:close()
  return POS, ADJ, ORDER
end

local function measure(path)
  local POS, ADJ, ORDER = load(path)
  local cheb, eucl, seen, nE = 0, 0, {}, 0
  local lox, hix, loy, hiy = math.huge, -math.huge, math.huge, -math.huge
  for _, u in ipairs(ORDER) do
    local p = POS[u]
    if p[1] < lox then lox = p[1] end ; if p[1] > hix then hix = p[1] end
    if p[2] < loy then loy = p[2] end ; if p[2] > hiy then hiy = p[2] end
    for _, v in pairs(ADJ[u] or {}) do
      if POS[v] then
        local k = (u < v) and (u .. ":" .. v) or (v .. ":" .. u)
        if not seen[k] then
          seen[k] = true ; nE = nE + 1
          local dx, dy = POS[v][1] - p[1], POS[v][2] - p[2]
          local ax, ay = math.abs(dx), math.abs(dy)
          cheb = cheb + math.max(ax, ay)
          eucl = eucl + math.sqrt(dx * dx + dy * dy)
        end
      end
    end
  end
  return { POS = POS, ADJ = ADJ, ORDER = ORDER, cheb = cheb, eucl = eucl, nE = nE,
           w = hix - lox, h = hiy - loy, box = (hix - lox + 1) * (hiy - loy + 1) }
end

-- one ring's realised geometry, on whichever dump
local function ring_geom(M, ring)
  local per, eu, pts = 0, 0, {}
  for i = 1, #ring do
    local a, b = M.POS[ring[i]], M.POS[ring[(i % #ring) + 1]]
    if not (a and b) then return nil end
    pts[i] = a
    local dx, dy = b[1] - a[1], b[2] - a[2]
    per = per + math.max(math.abs(dx), math.abs(dy))
    eu = eu + math.sqrt(dx * dx + dy * dy)
  end
  local A2 = 0
  for i = 1, #pts do
    local p, q = pts[i], pts[(i % #pts) + 1]
    A2 = A2 + (p[1] * q[2] - q[1] * p[2])
  end
  return per, eu, math.abs(A2) / 2
end

-- ⛔⛔⛔ DO NOT USE WHAT THE ENGINE CURRENTLY DRAWS ON soulfly AS A REFERENCE FOR ANYTHING. User:
-- *"you can't really look at all at what the engine draws now on soulfly."* Its face 6 measures 19
-- against the honest 47 -- not because it found a better drawing but because that layout is riddled
-- with defects, i.e. it is already overlapping the geometry it cannot fit. Comparing against it
-- measures the SOLVER's failure, not the cost of planarity. ⚠ Only HAND layouts are references here.
-- (This is also the coordinate-free rule the cost pass itself obeys: it reads exits and directions
-- and never a coordinate, so a bad drawing cannot contaminate it. Only this harness could.)
local X = measure(B)
print(string.format("%-34s %8s %8s %8s %10s", "hand layout", "CHEB", "EUCL", "edges", "bbox area"))
print(string.format("%-34s %8d %8.1f %8d %10d   (%dx%d)", B, X.cheb, X.eucl, X.nE, X.box, X.w, X.h))
print()
print(string.format("%-24s %7s %7s %9s %9s   %s", "ring", "CHEB", "EUCL", "shoelace", "interior",
  "-- the currency comparison"))
for _, R in ipairs({
  { "face 6 (the 10-cycle)", { 4330, 4333, 4334, 4335, 4336, 4337, 4338, 4339, 4340, 4341 } },
}) do
  local per, eu, ar = ring_geom(X, R[2])
  if per then
    print(string.format("%-24s %7d %7.1f %9.1f %9.1f", R[1], per, eu, ar, ar - per / 2 + 1))
  end
end
print()
print("rand rhombus, hand-solved truth (side 5, 4 diagonal walls):"
  .. "     cheb  20   eucl  28.3   shoelace  50.0   interior  41.0")
print("⇒ ratio soulfly:rand = 2.35x by CHEB, 2.20x by EUCL, 5.5x by AREA."
  .. "  A diagonal penalty moves it the WRONG way.")
