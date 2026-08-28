-- Harness for the 45-DEGREE PREFERENCE: elro._stretch_energy's shear return, its shearOnly
-- fast path, the diagonal stretch surcharge, and elro._rank_cands' shear-before-score key.
--
-- ⭐ NO EXTRACT. layout.lua loads standalone under luajit (`elro = {} ; dofile "layout.lua"`), so
-- this drives the REAL functions and cannot go stale the way the sed/awk extracts do.
--   cd area/map_helper/client/lua && luajit ../analysis/test_shear.lua
elro = {}
for _, m in ipairs(dofile("modules.lua")) do dofile(m) end
-- core.lua:102 verbatim; core.lua itself needs Mudlet, layout.lua does not.
elro.delta = {
  north = { 0, 1, 0}, south = { 0,-1, 0}, east = { 1, 0, 0}, west = {-1, 0, 0},
  northeast = { 1, 1, 0}, northwest = {-1, 1, 0},
  southeast = { 1,-1, 0}, southwest = {-1,-1, 0},
  up = { 0, 0, 1}, down = { 0, 0,-1},
}

local DIR = {}
for _, d in ipairs({ "east", "west", "north", "south",
                     "northeast", "northwest", "southeast", "southwest" }) do
  DIR[d] = elro.delta[d]
end
local REV = { east = "west", west = "east", north = "south", south = "north",
              northeast = "southwest", southwest = "northeast",
              northwest = "southeast", southeast = "northwest" }

local fails, checks = 0, 0
local function ok(cond, what)
  checks = checks + 1
  if not cond then fails = fails + 1 ; print("FAIL: " .. what) end
end
local function near(a, b) return math.abs(a - b) < 1e-9 end

-- ground truth: net change in |(|dx|-|dy|)| over every truthful-both-ways diagonal edge, computed
-- from scratch over canonical pairs (no reliance on the function's own traversal).
local function truth_shear(coord, adj, pulls)
  local moved = {}
  for _, pl in ipairs(pulls) do for r in pairs(pl.set) do moved[r] = true end end
  local function after(r)
    local p = coord[r] ; local x, y = p[1], p[2]
    for _, pl in ipairs(pulls) do if pl.set[r] then x = x + pl.dx * pl.dist ; y = y + pl.dy * pl.dist end end
    return x, y
  end
  local seen, s = {}, 0
  for r, nb in pairs(adj) do
    for d, w in pairs(nb) do
      local de = DIR[d]
      local k = (r < w) and (r .. ":" .. w) or (w .. ":" .. r)
      if de and coord[w] and not seen[k] and (de[1] ~= 0 and de[2] ~= 0) then
        seen[k] = true
        local cx, cy = coord[r][1] - coord[w][1], coord[r][2] - coord[w][2]
        local rx, ry = after(r) ; local wx, wy = after(w)
        local ax, ay = rx - wx, ry - wy
        if cx * de[1] < 0 and cy * de[2] < 0 and ax * de[1] < 0 and ay * de[2] < 0 then
          local wasSq, isSq = (math.abs(cx) == math.abs(cy)), (math.abs(ax) == math.abs(ay))
          if wasSq and not isSq then s = s + 1 elseif isSq and not wasSq then s = s - 1 end
        end
      end
    end
  end
  return s
end

local function link(adj, a, b, d)
  adj[a] = adj[a] or {} ; adj[b] = adj[b] or {}
  adj[a][d] = b ; adj[b][REV[d]] = a          -- symmetric, as walk_branches guarantees
end

-- ---------------------------------------------------------------- 1. the dunstan shape
-- 1393 -northeast-> 1391, square; pull 1393's row five cells south and the edge goes (1,1)->(1,5).
do
  local coord = { [1393] = { 11, 10 }, [1391] = { 12, 11 } }
  local adj = {} ; link(adj, 1393, 1391, "northeast")
  local pulls = { { set = { [1393] = true }, dx = 0, dy = -1, dist = 5 } }
  local _, sh = elro._stretch_energy(coord, adj, pulls)
  ok(sh == 1, "dunstan: a square NE knocked off 45 costs 1, however far it bends, got " .. tostring(sh))
  -- and the reverse move earns a credit
  local coord2 = { [1393] = { 11, 5 }, [1391] = { 12, 11 } }
  local _, sh2 = elro._stretch_energy(coord2, adj, { { set = { [1393] = true }, dx = 0, dy = 1, dist = 5 } })
  ok(sh2 == -1, "dunstan: restoring the 45 earns -1, got " .. tostring(sh2))
  -- a RIGID co-move of both endpoints is free
  local _, sh3 = elro._stretch_energy(coord, adj,
    { { set = { [1393] = true, [1391] = true }, dx = 0, dy = -1, dist = 5 } })
  ok(sh3 == 0, "rigid co-move shears nothing, got " .. tostring(sh3))
end

-- ---------------------------------------------------------------- 2. axial edges never shear
do
  local coord = { [1] = { 0, 0 }, [2] = { 3, 0 } }
  local adj = {} ; link(adj, 1, 2, "east")
  local _, sh = elro._stretch_energy(coord, adj, { { set = { [2] = true }, dx = 1, dy = 0, dist = 4 } })
  ok(sh == 0, "axial stretch has no shear, got " .. tostring(sh))
end

-- ---------------------------------------------------------------- 3. the diagonal surcharge
-- A 45 stretched by N grid steps used to cost exactly what an axial stretched by N cells costs.
-- ⛔ THESE THREE ASSERTIONS FAILED FOR NINE DAYS AND THE TEST STILL SAID SO EVERY RUN. They set
-- `elro.diagStretchMult`, and the surcharge moved into `TUNE.diagStretchMult` -- so the assignments
-- landed on a field nothing reads and the energy never budged. A test that A/Bs a knob that does not
-- exist does not error: it FAILS, quietly, and reads as a broken feature rather than a broken test.
-- Same rot as the ~45 comments naming switches with no read site (2026-08-21 knob review).
-- ⚠ `TUNE` IS FILE-LOCAL TO layout.lua, not a field of `elro`, so the multiplier cannot be reached
-- from here at all. What is testable is the SHAPE of the surcharge at its shipped value, and that is
-- what these now check -- the ratio, not the knob.
do
  local ca = { [1] = { 0, 0 }, [2] = { 1, 0 } } ; local aa = {} ; link(aa, 1, 2, "east")
  local cd = { [1] = { 0, 0 }, [2] = { 1, 1 } } ; local ad = {} ; link(ad, 1, 2, "northeast")
  local pull = function(dx, dy) return { { set = { [2] = true }, dx = dx, dy = dy, dist = 2 } } end
  local ea = elro._stretch_energy(ca, aa, pull(1, 0))
  local ed = elro._stretch_energy(cd, ad, pull(1, 1))
  -- a 45 stretched one grid step spans sqrt(2) cells and is then charged TUNE.diagStretchMult on top
  ok(ed > ea, "a stretched diagonal costs MORE than the same stretch on an axial edge")
  -- `ext` is divided by the edge's own natural length first, so the diagonal is NOT charged for its
  -- sqrt(2); the ratio is the bare multiplier. That distinction is exactly what the comment at the
  -- use site makes, and what the old `diagStretchMult = 1` case existed to pin down.
  ok(near(ed, 2 * ea), "the surcharge is the shipped 2x, on GRID STEPS not on cells")
  local ea2 = elro._stretch_energy(ca, aa, pull(1, 0))
  ok(near(ea2, ea), "the surcharge leaves AXIAL energy untouched")
end

-- ---------------------------------------------------------------- 4. random: shear + shearOnly
do
  math.randomseed(20260730)
  local dirs = {} ; for d in pairs(DIR) do dirs[#dirs + 1] = d end
  table.sort(dirs)
  local nTrial, nNonZero = 4000, 0
  for _ = 1, nTrial do
    local N = 3 + math.random(7)
    local coord, adj = {}, {}
    for r = 1, N do coord[r] = { math.random(-6, 6), math.random(-6, 6) } end
    for r = 2, N do
      local w = math.random(r - 1)
      local d = dirs[math.random(#dirs)]
      if not (adj[r] and adj[r][d]) and not (adj[w] and adj[w][REV[d]]) then link(adj, r, w, d) end
    end
    local set = {}
    for r = 1, N do if math.random() < 0.5 then set[r] = true end end
    local pulls = { { set = set, dx = math.random(-1, 1), dy = math.random(-1, 1), dist = math.random(4) } }
    local eFull, sFull = elro._stretch_energy(coord, adj, pulls)
    local eOnly, sOnly = elro._stretch_energy(coord, adj, pulls, true)
    local want = truth_shear(coord, adj, pulls)
    if want ~= 0 then nNonZero = nNonZero + 1 end
    if sFull ~= want then
      ok(false, string.format("random shear: got %s want %s", tostring(sFull), tostring(want)))
      break
    end
    if sOnly ~= sFull then ok(false, "shearOnly disagrees with the full pass") break end
    if eOnly ~= 0 then ok(false, "shearOnly must not accumulate energy") break end
    if eFull < 0 then ok(false, "energy went negative") break end
  end
  ok(true, "random trials completed")
  print(string.format("  %d random trials, %d with a non-zero shear", nTrial, nNonZero))
end

-- ------------------------------------------------- 4b. the COMPOSITE (`pre`) two-lever measurement
-- A pair is ONE move. The engine scores pull2 with pull1 already applied to `coord`, so it passes
-- `pre` = pull1's displacement; the result must equal what you would get by measuring the original
-- geometry against the fully-applied one.
do
  -- (i) coverage: pull1 moves a room pull2 never touches. A pull2-only pass cannot see that edge.
  local coord = { [1] = { 0, 0 }, [2] = { 1, 1 }, [3] = { 5, 5 } }
  local adj = {} ; link(adj, 1, 2, "northeast") ; link(adj, 2, 3, "northeast")
  local shift1 = { [1] = { -2, 0 } }               -- 1 goes west: edge 1->2 becomes (3,1), shear +2
  local post = { [1] = { -2, 0 }, [2] = { 0, 0 }, [3] = { 0, 0 } }
  local moved1 = { [1] = { coord[1][1] - 2, coord[1][2] }, [2] = coord[2], [3] = coord[3] }
  local pulls2 = { { set = { [3] = true }, dx = 0, dy = 1, dist = 1 } }   -- 3 north: 2->3 (4,5)->(4,6)
  local _, comp = elro._stretch_energy(moved1, adj, pulls2, true, shift1)
  -- ground truth from the ORIGINAL geometry against the final one
  local final = { [1] = { -2, 0 }, [2] = { 1, 1 }, [3] = { 5, 6 } }
  local function skew_of(c)
    local s = 0
    local seen = {}
    for r, nb in pairs(adj) do
      for d, w in pairs(nb) do
        local de = DIR[d]
        local k = (r < w) and (r .. ":" .. w) or (w .. ":" .. r)
        if de and not seen[k] and de[1] ~= 0 and de[2] ~= 0 then
          seen[k] = true
          local dx, dy = c[w][1] - c[r][1], c[w][2] - c[r][2]
          if dx * de[1] > 0 and dy * de[2] > 0 and math.abs(dx) ~= math.abs(dy) then s = s + 1 end
        end
      end
    end
    return s
  end
  ok(comp == skew_of(final) - skew_of(coord),
     string.format("composite covers pull1-only edges: got %s want %s",
       tostring(comp), tostring(skew_of(final) - skew_of(coord))))
  -- (ii) pull2 undoing pull1's shear costs the pair NOTHING
  local c2 = { [1] = { 0, 0 }, [2] = { 1, 1 } }
  local a2 = {} ; link(a2, 1, 2, "northeast")
  local mid = { [1] = { -2, 0 }, [2] = { 1, 1 } }             -- pull1 sheared it to (3,1)
  local _, undo = elro._stretch_energy(mid, a2, { { set = { [1] = true }, dx = 1, dy = 0, dist = 2 } },
                                       true, { [1] = { -2, 0 } })
  ok(undo == 0, "a shear pull1 creates and pull2 undoes costs the PAIR nothing, got " .. tostring(undo))
  -- ...while the same pull2 judged on its own reads as a -2 credit it does not deserve
  local _, alone = elro._stretch_energy(mid, a2, { { set = { [1] = true }, dx = 1, dy = 0, dist = 2 } }, true)
  ok(alone == -1, "and pull2 alone would have claimed the credit (why `pre` exists), got " .. tostring(alone))
  ok(select(2, elro._stretch_energy(c2, a2, { { set = {}, dx = 0, dy = 0, dist = 0 } }, true)) == 0,
     "an empty pull shears nothing")
  -- WHICH edge sheared (3rd return, stepDebug-gated). The count alone could not be acted on: the
  -- whole question is whether a shear-free alternative existed on the same chord, and that needs
  -- the edge, not the tally.
  -- dy = -1, NOT +1: moving 1 UP flattens 1-2 to horizontal, which is a LIE (an edge the pull
  -- falsifies), and the shear pass deliberately skips those. Pulling DOWN keeps it truthful and
  -- merely off-square, which is what shear means.
  local pull = { { set = { [1] = true }, dx = 0, dy = -1, dist = 1 } }
  ok(select(3, elro._stretch_energy(c2, a2, pull, true)) == nil,
     "no collector without stepDebug (the hot path must not allocate)")
  elro.stepDebug = true
  local _, sh3, edges = elro._stretch_energy(c2, a2, pull, true)
  elro.stepDebug = nil
  ok(sh3 == 1 and edges and #edges == 1, "one sheared edge reported, got " ..
     tostring(sh3) .. "/" .. tostring(edges and #edges))
  -- 1(0,0)-2(1,1) northeast; pulling 1 down leaves the edge (1,2): square -> off-square, and the
  -- label carries the before->after delta so the trace shows WHAT it did, not just that it did.
  ok(edges[1] == "+1:2(1,1->1,2)", "labelled with the edge and its before->after delta, got " ..
     tostring(edges[1]))
  -- ...and the delta is oriented to the CANONICAL key, not to whichever endpoint the traversal
  -- happened to reach first. Same edge, same label, but reached via the HIGH id: an unoriented
  -- label flips sign here, which is how 408:409 printed as (1,-1) for a (-1,+2) edge.
  elro.stepDebug = true
  local _, _, edges2 = elro._stretch_energy(c2, a2,
    { { set = { [2] = true }, dx = 0, dy = 1, dist = 1 } }, true)
  elro.stepDebug = nil
  ok(edges2 and edges2[1] == "+1:2(1,1->1,2)",
     "delta orientation follows the key, not the traversal, got " .. tostring(edges2 and edges2[1]))
end

-- ---------------------------------------------------------------- 5. the ranking key
do
  local skewWas = elro.TUNE.diagSkewCap
  elro.TUNE.diagSkewCap = 100
  -- leowon: the shearing candidate is 20.9 energy cheaper and must still LOSE.
  local cands = {
    { ek = "shears", kind = "class-shift", intoEmpty = true, score = 5.34, shear = 1 },
    { ek = "clean",  kind = "piston",      intoEmpty = true, score = 26.24, shear = 0 },
  }
  elro._rank_cands(cands)
  ok(cands[1].ek == "clean", "leowon: a one-cell shear loses to a 20.9-dearer clean candidate")
  -- ...but not at ANY price: the cap bounds what we will pay.
  local cands2 = {
    { ek = "shears", kind = "class-shift", intoEmpty = true, score = 5, shear = 1 },
    { ek = "brutal", kind = "guillotine",  intoEmpty = true, score = 5000, shear = 0 },
  }
  elro._rank_cands(cands2)
  ok(cands2[1].ek == "shears", "the cap refuses to buy a 5000-energy move to save one cell")
  -- THE CREDIT IS OFF BY DEFAULT (flipped 2026-07-30): a restoring candidate does NOT outrank a
  -- neutral one of equal energy, and -- the world 291 case -- must not outrank a CHEAPER one.
  local cands3 = {
    { ek = "neutral", kind = "piston", intoEmpty = true, score = 10, shear = 0 },
    { ek = "restore", kind = "piston", intoEmpty = true, score = 10, shear = -1 },
  }
  elro._rank_cands(cands3)
  ok(cands3[1].ek == "neutral", "by default, squaring an unrelated diagonal buys no rank")
  local cands3c = {
    { ek = "restore", kind = "piston", intoEmpty = true, score = 20.5, shear = -1 },
    { ek = "cheap",   kind = "chord",  intoEmpty = true, score = 9,    shear = 0 },
  }
  elro._rank_cands(cands3c)
  ok(cands3c[1].ek == "cheap", "world 291: a shear-neutral chord is not buried by a -1shear credit")
  -- ...and the PENALTY is untouched by the flip
  local cands3b = {
    { ek = "shears", kind = "piston", intoEmpty = true, score = 5, shear = 1 },
    { ek = "clean",  kind = "piston", intoEmpty = true, score = 20, shear = 0 },
  }
  elro._rank_cands(cands3b)
  ok(cands3b[1].ek == "clean", "the default drop of the credit leaves the PENALTY intact")
  -- ⛔ THE `elro.diagSkewBonus = true` OPT-IN WAS REMOVED 2026-08-12 (user: *"a solution I don't
  -- like, so it can go as well"*) and this assertion outlived it, failing on every run since. The
  -- credit is now ALWAYS declined and there is nothing to opt back into -- so the check that means
  -- something is that no setting brings it back.
  elro.diagSkewBonus = true
  elro._rank_cands(cands3)
  ok(cands3[1].ek ~= "restore", "diagSkewBonus is GONE -- setting it does not restore the credit")
  elro.diagSkewBonus = nil
  -- shear never overrides intoEmpty or the re-angle demotion
  local cands4 = {
    { ek = "casc",  kind = "piston", intoEmpty = false, score = 1, shear = -5 },
    { ek = "clean", kind = "piston", intoEmpty = true,  score = 99, shear = 5 },
  }
  elro._rank_cands(cands4)
  ok(cands4[1].ek == "clean", "intoEmpty still outranks everything")
  -- nil shear (the no-junction fallback path) behaves as zero
  local cands5 = {
    { ek = "nilshear", kind = "piston", intoEmpty = true, score = 10 },
    { ek = "worse",    kind = "piston", intoEmpty = true, score = 20 },
  }
  elro._rank_cands(cands5)
  ok(cands5[1].ek == "nilshear", "a nil shear ranks as zero, not as an error")
  elro.TUNE.diagSkewCap = skewWas
end

print(string.format("%d checks, %d failures", checks, fails))
os.exit(fails == 0 and 0 or 1)
