-- Harness for the constraint provenance + audit layer (elro.edge_provenance /
-- constraint_order / constraint_refutes / constraint_audit).
--
-- ⭐ This harness LOADS THE REAL FILES. No awk/sed extraction, so it can never
-- go stale against the engine -- which is the whole reason those functions were
-- put at module scope. Run from area/map_helper/client:
--     luajit analysis/test_audit.lua
for _, m in ipairs(dofile("lua/modules.lua")) do dofile("lua/" .. m) end

local fails, checks = 0, 0
local function check(name, got, want)
  checks = checks + 1
  if got ~= want then
    fails = fails + 1
    print(string.format("FAIL %-46s got %s want %s", name, tostring(got), tostring(want)))
  end
end

-- build a directed adj from {from, dir, to} triples
local function mk(edges)
  local adj = {}
  for _, e in ipairs(edges) do
    adj[e[1]] = adj[e[1]] or {} ; adj[e[3]] = adj[e[3]] or {}
    adj[e[1]][e[2]] = e[3]
  end
  return adj
end
-- both directions of a walked-both-ways corridor
local function pair(a, d, b) return { { a, d, b }, { b, elro.reverse[d], a } } end
local function cat(...)
  local out = {}
  for _, t in ipairs({ ... }) do for _, e in ipairs(t) do out[#out + 1] = e end end
  return out
end
local none = function() return false end          -- nothing is an onRoom assumption

local function tierOf(prov, a, b)
  local lo, hi = a, b ; if lo > hi then lo, hi = hi, lo end
  local e = prov[lo .. ":" .. hi]
  return e and e.tier or "(absent)"
end
local function badSet(bad)
  local t = {}
  for _, b in ipairs(bad) do t[b.s.r .. "-" .. b.s.d .. "->" .. b.s.x] = b.reason end
  return t
end

-- ---------------------------------------------------------------- 1. CLEAN
-- a 2x2 loop, every corridor walked both ways: all hard, nothing refuted.
do
  local adj = mk(cat(pair(1, "east", 2), pair(2, "south", 3), pair(3, "west", 4), pair(4, "north", 1)))
  local bad, stats, prov = elro.constraint_audit(adj, none)
  check("clean/hard count", stats.hard, 4)
  check("clean/soft count", stats.oneway + stats.assumed + stats.conflict, 0)
  check("clean/contradictions", #bad, 0)
  check("clean/tier 1-2", tierOf(prov, 1, 2), "hard")
end

-- ------------------------------------------------- 2. THE WIZARD TYPO CASE
-- 1-2-3 is a walked E/W corridor. Someone then adds a one-way `1 north 3`.
-- The corridor row-locks all three AND proves 1 west of 3, so the new edge's
-- own assertion (same column, 3 north of 1) is refuted twice over. This is the
-- unsatisfiable system that makes an area unlayoutable.
do
  local adj = mk(cat(pair(1, "east", 2), pair(2, "east", 3), { { 1, "north", 3 } }))
  local bad, stats, prov = elro.constraint_audit(adj, none)
  check("typo/tier", tierOf(prov, 1, 3), "oneway")
  check("typo/hard count", stats.hard, 2)
  check("typo/contradictions", #bad, 1)
  local b = badSet(bad)
  check("typo/edge named", b["1-north->3"] ~= nil, true)
  -- and the hard corridor itself is never blamed
  check("typo/corridor clean", b["1-east->2"], nil)
end

-- ---------------------------------------- 3. A CONSISTENT ONE-WAY SURVIVES
-- Most one-way exits are fine. `1 north 4` with 4 otherwise unconstrained is
-- satisfiable, so the audit must stay silent -- the point is priority when
-- constraints CONFLICT, not a blanket discount on one-way exits.
do
  local adj = mk(cat(pair(1, "east", 2), pair(2, "east", 3), { { 1, "north", 4 } }))
  local bad, stats, prov = elro.constraint_audit(adj, none)
  check("oneway-ok/tier", tierOf(prov, 1, 4), "oneway")
  check("oneway-ok/contradictions", #bad, 0)
end

-- ------------------------------------ 4. NON-MUTUAL DIRECTIONS = CONFLICT
-- 1 -east-> 2 and 2 -north-> 1. east locks the ROW, north locks the COLUMN, so
-- the pair is forced into one cell. Unsatisfiable with no other edge involved.
do
  local adj = mk({ { 1, "east", 2 }, { 2, "north", 1 } })
  local bad, stats, prov = elro.constraint_audit(adj, none)
  check("conflict/tier", tierOf(prov, 1, 2), "conflict")
  check("conflict/count", stats.conflict, 1)
  check("conflict/reported", #bad, 1)
end

-- STALE ASSUMED REVERSE: onRoom fabricated 2 -west-> 1, then the real reverse
-- 2 -north-> 1 was walked and nothing removed the assumption.
-- ⚠ THIS IS WHERE PROVENANCE EARNS ITS KEEP, and the pair of cases below is the
-- proof. From the graph ALONE the shape is indistinguishable from a legitimate
-- fan-in, and 1-east/2-west is a perfectly good mutual reverse -- so with no
-- provenance the honest verdict is "fanin". Knowing 2 -west-> 1 is a
-- FABRICATION flips it: a real observation now disagrees with an assumption,
-- nothing is corroborated, and electing the fabrication primary (demoting the
-- observation as a redundant extra) would be exactly backwards.
do
  local adj = mk({ { 1, "east", 2 }, { 2, "west", 1 }, { 2, "north", 1 } })
  local _, _, provN = elro.constraint_audit(adj, none)
  check("stale-assumed/no provenance reads fanin", tierOf(provN, 1, 2), "fanin")

  local assumed = function(r, d) return r == 2 and d == "west" end
  local bad, _, prov = elro.constraint_audit(adj, assumed)
  check("stale-assumed/with provenance", tierOf(prov, 1, 2), "conflict")
  check("stale-assumed/reported", #bad, 1)
  -- and the fabrication must never have been elected the representative
  check("stale-assumed/rep not the fabrication", prov["1:2"].rep.d ~= "west", true)
end

-- ------------------------------------------ 4b. FAN-IN IS NOT A TYPO
-- andra 1557 has southeast/south/southwest ALL leading to 1556, the single room
-- on the row below -- deliberate MUD design. `south` is corroborated by
-- 1556 -north-> 1557, so the resolution is to keep it and demote the other two.
-- Reporting this as a source bug (as a flat "conflict" tier did) is wrong.
do
  local adj = mk(cat(pair(1556, "north", 1557),
    { { 1557, "southeast", 1556 } }, { { 1557, "southwest", 1556 } }))
  local bad, stats, prov = elro.constraint_audit(adj, none)
  check("fanin/tier", tierOf(prov, 1556, 1557), "fanin")
  check("fanin/count", stats.fanin, 1)
  check("fanin/extras", #prov["1556:1557"].extra, 2)
  check("fanin/representative is the corroborated dir", prov["1556:1557"].rep.d, "north")
  -- resolvable by demotion, so it is NOT a contradiction needing a source fix
  check("fanin/not a contradiction", #bad, 0)
end

-- ------------------------- 5. AN ASSUMED REVERSE IS NOT CORROBORATION
-- The trap: onRoom's fabricated reverse makes a one-way typo LOOK reciprocal.
-- With the reverse marked assumed the edge must read "assumed", not "hard" --
-- otherwise the typo is admitted to the trusted skeleton and the audit is blind
-- to the very case it exists for.
do
  local edges = cat(pair(1, "east", 2), pair(2, "east", 3), pair(1, "north", 3))
  local adj = mk(edges)
  local assumed = function(r, d) return r == 3 and d == "south" end
  local bad, stats, prov = elro.constraint_audit(adj, assumed)
  check("assumed/tier", tierOf(prov, 1, 3), "assumed")
  check("assumed/hard count", stats.hard, 2)
  check("assumed/contradictions", #bad, 1)
  check("assumed/edge named", badSet(bad)["1-north->3"] ~= nil, true)

  -- CONTROL: the identical graph with nothing assumed reads as three hard edges,
  -- and the contradiction is then reported against the hard set instead of
  -- demoted. Same defect, different verdict -- which is exactly why provenance
  -- has to be tracked rather than inferred from the shape of the graph.
  local bad2, stats2 = elro.constraint_audit(adj, none)
  check("assumed/control hard count", stats2.hard, 3)
  check("assumed/control still caught", #bad2 > 0, true)
  check("assumed/control blames hard", bad2[1].against, "hard")
end

-- ------------------------------------------------------ 6. SELF LOOP
do
  local adj = mk(cat(pair(1, "east", 2), { { 1, "north", 1 } }))
  local bad, stats, prov = elro.constraint_audit(adj, none)
  check("selfloop/tier", tierOf(prov, 1, 1), "selfloop")
  check("selfloop/reported", #bad, 1)
end

-- --------------------------------------------------- 7. DIAGONAL REFUTED
-- 1 -southeast-> 3 needs 3 east of AND south of 1; the hard corridor row-locks
-- them, so the south half is refuted. Covers the de[axis] ~= 0 / same-class arm
-- for a non-axial edge.
do
  local adj = mk(cat(pair(1, "east", 2), pair(2, "east", 3), { { 1, "southeast", 3 } }))
  local bad = elro.constraint_audit(adj, none)
  check("diagonal/contradictions", #bad, 1)
  check("diagonal/edge named", badSet(bad)["1-southeast->3"] ~= nil, true)
end

-- ------------------------------------------- 8. TRANSITIVE ORDER (reachability)
-- A long corridor 1..6 proves 1 west of 6 through five hops; a one-way
-- `6 east 1` is refuted only if reachability, not adjacency, is consulted.
do
  local e = {}
  for i = 1, 5 do for _, x in ipairs(pair(i, "east", i + 1)) do e[#e + 1] = x end end
  e[#e + 1] = { 6, "east", 1 }
  local bad = elro.constraint_audit(mk(e), none)
  check("transitive/contradictions", #bad, 1)
  check("transitive/edge named", badSet(bad)["6-east->1"] ~= nil, true)
end

-- ------------------------------------------------------ 9. DETERMINISM
-- Admission order decides WHICH of a mutually-inconsistent soft pair is
-- demoted, so the result must not depend on pairs() iteration order -- a
-- relayout that flips its choice would move rooms for no reason.
do
  local adj = mk(cat(pair(1, "east", 2), pair(2, "east", 3),
    { { 1, "north", 3 } }, { { 3, "northeast", 1 } }, { { 2, "north", 3 } }))
  local first
  for trial = 1, 40 do
    local bad = elro.constraint_audit(adj, none)
    local sig = {}
    for _, b in ipairs(bad) do sig[#sig + 1] = b.s.r .. b.s.d .. b.s.x end
    sig = table.concat(sig, "|")
    if not first then first = sig end
    if sig ~= first then check("determinism/trial " .. trial, sig, first) ; break end
  end
  checks = checks + 1
  print("       determinism signature: " .. first)
end

-- ------------------------------------- 10. SOFT EDGES CONSTRAIN EACH OTHER
-- Two one-way edges, neither refuted by the hard set, but mutually
-- inconsistent. The first admitted becomes part of the accepted set, so the
-- second is caught -- exactly one of the two is demoted, never both.
do
  local adj = mk(cat(pair(1, "east", 2), { { 2, "north", 3 } }, { { 3, "north", 1 } }))
  local bad = elro.constraint_audit(adj, none)
  check("soft-vs-soft/at most one demoted", #bad <= 1, true)
end

-- ------------------------------------------- 11. REAL AREAS (the census)
-- ⚠ PROCESS: measure the POPULATION before reading anything into the findings.
-- These dumps are areas that LAY OUT CLEANLY today, so the audit must be nearly
-- silent on them -- a contradiction here would mean the refutation rule is too
-- eager, which is far worse than missing one. NB the dumps are read RAW: the
-- loader must NOT symmetrise the way test_outer.lua does, or every one-way exit
-- is laundered into a reciprocal pair and the provenance split reads all-hard.
do
  local function load(file)
    local adj, f = {}, io.open(file)
    if not f then return nil end
    f:close()
    for line in io.lines(file) do
      local id = line:match("^%s*(%d+)")
      if id then
        id = tonumber(id) ; adj[id] = adj[id] or {}
        -- both dump shapes: "east->4120" and "east:4120". ⚠ mael.txt uses the
        -- second and silently read as ZERO EDGES with only the first pattern --
        -- a row of zeros in the census is a parse failure, not a clean area.
        for _, pat in ipairs({ "(%a+)%s*%->%s*(%d+)", "(%a+):(%d+)" }) do
          for d, t in line:gmatch(pat) do
            local de = elro.delta[d]
            if de and (de[1] ~= 0 or de[2] ~= 0) then adj[id][d] = tonumber(t) end
          end
        end
      end
    end
    -- drop edges leaving the dump, exactly as area_adjacency's inArea filter does
    for _, nb in pairs(adj) do
      for d, v in pairs(nb) do if not adj[v] then nb[d] = nil end end
    end
    return adj
  end
  -- want = expected {contradictions, suspects}; nil = census only, no assertion
  local corpus = {
    { "lyr.txt",          { 0, 0 } },   -- lays out clean today; 1 legitimate one-way (2481-west->2482)
    { "titleist.txt",     { 0, 0 } },
    { "world_block.txt",  { 0, 0 } },
    { "mael.txt",         { 0, 0 } },
    -- ⭐ REAL BUGS, user-supplied. gore is ORDER-SATISFIABLE (the area draws
    -- truthfully) so it must report NO contradiction and exactly one suspect,
    -- naming 2339's southwest. darkmoon's two conflicts are non-mutual
    -- direction pairs; its suspect (1127's north pointing at 1136, skipping
    -- 1126) is a third bug the contradiction rule alone does not reach.
    { "gore_bug.txt",     { 0, 1 } },
    { "darkmoon_bug.txt", { 2, 1 } },
  }
  _G.__load_dump = load
  for _, C in ipairs(corpus) do
    local file, want = C[1], C[2]
    local adj = load("analysis/" .. file) or load(file)
    if adj then
      local bad, stats, _, susp = elro.constraint_audit(adj, none)
      local n = 0 ; for _ in pairs(adj) do n = n + 1 end
      print(string.format("       %-18s %4d rooms | hard %4d oneway %3d assumed %3d conflict %2d self %2d -> %d contra, %d suspect",
        file, n, stats.hard, stats.oneway, stats.assumed, stats.conflict, stats.selfloop, #bad, #susp))
      for _, b in ipairs(bad) do
        print(string.format("           CONTRA  %d -%s-> %d [%s] %s", b.s.r, b.s.d, b.s.x, b.e.tier, b.reason))
      end
      for _, s in ipairs(susp) do
        print(string.format("           SUSPECT %d -%s-> %d, but %d -%s-> %d (should %d's %s be %d?)",
          s.u, s.d, s.v, s.v, s.rv, s.w, s.v, s.rv, s.u))
      end
      if want then
        check(file .. "/contradictions", #bad, want[1])
        check(file .. "/suspects", #susp, want[2])
      end
    else
      print("       " .. file .. ": (missing, skipped)")
    end
  end
end

-- ------------------------------------ 12. THE DEMOTION SET (what LAYOUT sees)
-- The audit only reports; `elro.demotion_set` is what walk_branches actually
-- removes from the equations, so this is the part that moves rooms.
-- ⭐ THE INVARIANT THAT MATTERS: after demotion the surviving constraint system
-- must be SATISFIABLE -- no cycle in the strict-order DAG per axis, and no edge
-- refuted by the rest. If demotion left a contradiction it would have done
-- nothing except lose an exit.
do
  local function satisfiable(adj)
    local prov = elro.edge_provenance(adj, none)
    for _, e in pairs(prov) do
      if e.tier == "conflict" or e.tier == "selfloop" then return false, "tier " .. e.tier end
    end
    local O = elro.constraint_order(prov, function() return true end)
    for _, e in pairs(prov) do
      local why = elro.constraint_refutes(O, e.rep)
      if why then return false, why end
    end
    return true
  end
  local function apply(adj, drop)
    local out = {}
    for r, nb in pairs(adj) do
      local t = {}
      for d, v in pairs(nb) do if not (drop[r] and drop[r][d]) then t[d] = v end end
      out[r] = t
    end
    return out
  end

  -- andra's fan-in: the two extra directions go, `south` survives
  local andra = mk(cat(pair(1556, "north", 1557),
    { { 1557, "southeast", 1556 } }, { { 1557, "southwest", 1556 } }))
  local drop, list = elro.demotion_set(andra, none)
  check("demote/andra count", #list, 2)
  check("demote/andra keeps south", andra[1557].south, 1556)
  check("demote/andra drops southeast", drop[1557] and drop[1557].southeast, true)
  check("demote/andra satisfiable after", (satisfiable(apply(andra, drop))), true)

  -- the wizard-typo shape: the refuted one-way goes, the corridor survives
  local typo = mk(cat(pair(1, "east", 2), pair(2, "east", 3), { { 1, "north", 3 } }))
  local d2, l2 = elro.demotion_set(typo, none)
  check("demote/typo count", #l2, 1)
  check("demote/typo drops the one-way", d2[1] and d2[1].north, true)
  check("demote/typo satisfiable after", (satisfiable(apply(typo, d2))), true)

  -- a consistent one-way is NEVER demoted
  local ok1 = mk(cat(pair(1, "east", 2), pair(2, "east", 3), { { 1, "north", 4 } }))
  local d3, l3 = elro.demotion_set(ok1, none)
  check("demote/consistent one-way untouched", #l3, 0)

  -- and on every real area: demotion must leave a SATISFIABLE system
  for _, C in ipairs({ { "lyr.txt", 0 }, { "titleist.txt", 0 }, { "world_block.txt", 0 },
                       { "mael.txt", 0 }, { "gore_bug.txt", 0 }, { "darkmoon_bug.txt", nil } }) do
    local file, wantN = C[1], C[2]
    local adj = _G.__load_dump and _G.__load_dump("analysis/" .. file)
    if adj then
      local dd, ll = elro.demotion_set(adj, none)
      local after = apply(adj, dd)
      local sat, why = satisfiable(after)
      print(string.format("       demote %-18s -> %2d edge(s) dropped | satisfiable after: %s%s",
        file, #ll, tostring(sat), sat and "" or ("  (" .. tostring(why) .. ")")))
      for _, x in ipairs(ll) do
        print(string.format("           drop %d -%s-> %d  (%s)", x.r, x.d, x.x, x.why))
      end
      check(file .. "/satisfiable after demotion", sat, true)
      if wantN then check(file .. "/demoted count", #ll, wantN) end
    end
  end
end

print(string.format("\n%d checks, %d failures", checks, fails))
os.exit(fails == 0 and 0 or 1)
