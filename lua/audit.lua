-- Constraint provenance and audit: edge trust tiers, refutation, demotion set, mapaudit.
-- Split out of layout.lua; see lua/modules.lua for the load order.

elro = elro or {}
local K = elro.k or error("audit.lua: lua/keys.lua must be loaded first (see elro.modules)")
local ekey = K.edge
local each_exit = elro.exits or error("audit.lua: lua/core.lua must be loaded first")
local area_adjacency = elro.area_adjacency or error("audit.lua: lua/canvas.lua must be loaded first")

-- ---- CONSTRAINT PROVENANCE + AUDIT ----------------------------------------
-- Not every asserted exit is equally true: a reciprocal pair walked both ways is
-- corroborated; a one-way exit is a single unchecked assertion (often a wizard typo,
-- which makes the system unsatisfiable); an onRoom-fabricated reverse must never count
-- as corroboration. This establishes a priority so that when constraints conflict, the
-- corroborated one wins.
--
-- elro.edge_provenance(adj [, assumedFn]) -> prov, stats
-- One entry per UNDIRECTED compass edge, keyed "lo:hi":
--   { a, b, dirs = { {r, x, d, de, assumed}, ... }, tier, why }
-- tier:
--   "hard"     both directions present, mutually reverse, neither assumed
--   "assumed"  reciprocal-looking, but a direction is an onRoom fabrication
--   "oneway"   only one direction exists
--   "fanin"    a corroborated pair plus extra directions to the same room;
--              resolvable: keep the corroborated one, demote the extras (`e.extra`)
--   "conflict" directions that are not mutual reverses and none corroborated;
--              unsatisfiable, needs a source fix
--   "selfloop" an exit from a room to itself; never drawable
-- `e.rep` is the representative direction downstream consumers read: the corroborated
-- one where there is one. `assumedFn(room, dir)` is injectable for harness use.
function elro.edge_provenance(adj, assumedFn)
  -- Snapshot, not Mudlet: cs_room materialized the assumed_<dir> flags, so this is
  -- a table lookup.
  assumedFn = assumedFn or function(r, d)
    local rec = elro.cs_room(r)
    return rec ~= nil and rec.asm[d] == true
  end
  local prov, stats = {}, { hard = 0, assumed = 0, oneway = 0, fanin = 0, conflict = 0, selfloop = 0 }
  for r, nb in pairs(adj) do
    elro.bg_tick("provenance")
    for d, x in pairs(nb) do
      local de = elro.delta[d]
      if de and adj[x] and (de[1] ~= 0 or de[2] ~= 0) then
        local lo, hi = r, x
        if lo > hi then lo, hi = hi, lo end
        local k = ekey(lo, hi)
        local e = prov[k]
        if not e then e = { a = lo, b = hi, dirs = {} } ; prov[k] = e end
        e.dirs[#e.dirs + 1] = { r = r, x = x, d = d, de = de,
                                assumed = assumedFn(r, d) and true or false }
      end
    end
  end
  for _, e in pairs(prov) do
    -- deterministic order: the report and (later) the admission order must not
    -- depend on pairs() iteration, or relayouts flip between demotion choices.
    table.sort(e.dirs, function(p, q)
      if p.r ~= q.r then return p.r < q.r end
      return p.d < q.d
    end)
    local fromA, fromB = {}, {}
    for _, s in ipairs(e.dirs) do
      if s.r == e.a then fromA[#fromA + 1] = s else fromB[#fromB + 1] = s end
    end
    -- a corroborated pair is any s (a->b) whose exact reverse t (b->a) exists.
    -- Prefer a fully-observed mutual reverse: a pair containing an assumption is not
    -- corroboration, and without the preference a stale fabrication could be elected
    -- primary over a later real observation.
    local ps, pt
    for _, s in ipairs(fromA) do
      for _, t in ipairs(fromB) do
        if elro.reverse[s.d] == t.d then
          if not (s.assumed or t.assumed) then
            if not ps or ps.assumed or pt.assumed then ps, pt = s, t end
          elseif not ps then ps, pt = s, t end
        end
      end
    end
    local primAssumed = ps and (ps.assumed or pt.assumed)
    e.rep = ps or e.dirs[1]
    if e.a == e.b then
      e.tier, e.why = "selfloop", "an exit from the room to itself"
    elseif ps and #e.dirs == 2 then
      if primAssumed then
        e.tier, e.why = "assumed", "the reverse is an onRoom assumption, not an observation"
      else
        e.tier, e.why = "hard", "walked both ways"
      end
    elseif ps and primAssumed then
      -- the only mutual reverse rests on a fabrication, and a real observation
      -- disagrees with it. Nothing here is corroborated, so nothing is preferred.
      e.tier, e.why = "conflict", "an observed direction contradicts an assumed reverse"
    elseif ps then
      -- corroborated, but with extra directions to the same room piled on.
      e.extra = {}
      for _, s in ipairs(e.dirs) do
        if s ~= ps and s ~= pt then e.extra[#e.extra + 1] = s end
      end
      e.tier = "fanin"
      e.why = string.format("%d extra direction(s) beside the corroborated %s/%s",
        #e.extra, ps.d, pt.d)
    elseif #fromA == 0 or #fromB == 0 then
      local s = fromA[1] or fromB[1]
      if #e.dirs > 1 then
        e.tier, e.why = "conflict", "two different directions out of the same room to the same target"
      else
        e.tier = s.assumed and "assumed" or "oneway"
        e.why = s.assumed and "the only direction is an onRoom assumption"
                          or "no reverse exit was ever observed"
      end
    else
      e.tier, e.why = "conflict", "the directions between this pair are not mutual reverses"
    end
    stats[e.tier] = (stats[e.tier] or 0) + 1
  end
  return prov, stats
end

-- Per-axis order structure over a chosen edge set: a union-find over edges that do
-- not move along the axis (equal coordinate) plus a strict-order DAG over edges that
-- do, restricted to an edge filter. Returns { [axis] = { find, lt } }; lt(a, b) is
-- "a is provably strictly less than b" by reachability, memoised per class.
function elro.constraint_order(prov, accept)
  local out = {}
  for axis = 1, 2 do
    elro.bg_tick("constraint-order")
    local p = {}
    local function find(a)
      if p[a] == nil then p[a] = a end
      while p[a] ~= a do p[a] = p[p[a]] ; a = p[a] end
      return a
    end
    local edges = {}
    for _, e in pairs(prov) do
      -- only self-loops are excluded outright (never drawable); whether a
      -- CONFLICT may contribute is the caller's decision, because once one of its
      -- directions has been chosen the edge is an ordinary live constraint.
      if e.tier ~= "selfloop" and accept(e) then
        local s = e.rep                     -- the corroborated direction, where there is one
        edges[#edges + 1] = s
        find(s.r) ; find(s.x)
        if s.de[axis] == 0 then
          local ra, rb = find(s.r), find(s.x) ; if ra ~= rb then p[ra] = rb end
        end
      end
    end
    local succ, via = {}, {}
    for _, s in ipairs(edges) do
      if s.de[axis] ~= 0 then
        local a, b
        if s.de[axis] > 0 then a, b = find(s.r), find(s.x) else a, b = find(s.x), find(s.r) end
        if a ~= b then
          succ[a] = succ[a] or {} ; succ[a][b] = true
          via[a] = via[a] or {} ; via[a][b] = via[a][b] or s   -- witness edge for the report
        end
      end
    end
    -- rooms in a class share the coordinate, so name a member the reader will
    -- recognise rather than the arbitrary union-find representative.
    local members = {}
    for _, s in ipairs(edges) do
      elro.bg_tick("constraint-order")
      for _, r in ipairs({ s.r, s.x }) do
        local c = find(r)
        if members[c] == nil or r < members[c] then members[c] = r end
      end
    end
    local reach = {}
    local function lt(a, b)
      local ca, cb = find(a), find(b)
      if ca == cb then return false end
      local seen = reach[ca]
      if not seen then
        seen = {}
        local stack = {}
        for y in pairs(succ[ca] or {}) do stack[#stack + 1] = y end
        while #stack > 0 do
          local y = table.remove(stack)
          if not seen[y] then
            seen[y] = true
            for z in pairs(succ[y] or {}) do if not seen[z] then stack[#stack + 1] = z end end
          end
        end
        reach[ca] = seen
      end
      return seen[cb] == true
    end
    -- Witness: BFS over the same succ graph lt uses, returning the shortest chain
    -- of witness edges (or nil). Not memoised: runs only when a contradiction is
    -- reported.
    local function why(a, b)
      local ca, cb = find(a), find(b)
      if ca == cb then return nil end
      local prev, q, qh = {}, { ca }, 1
      while qh <= #q do
        local x = q[qh] ; qh = qh + 1
        for y in pairs(succ[x] or {}) do
          if prev[y] == nil and y ~= ca then
            prev[y] = x
            if y == cb then
              local chain, cur = {}, cb
              while cur ~= ca do
                local pv = prev[cur]
                table.insert(chain, 1, via[pv] and via[pv][cur])
                cur = pv
              end
              return chain
            end
            q[#q + 1] = y
          end
        end
      end
      return nil
    end
    out[axis] = { find = find, lt = lt, why = why, members = members, succ = succ }
  end
  return out
end

-- Is this edge's own assertion refutable by the order structure `O`?
--   de[axis] == 0: the edge asserts an equality on that axis; refuted if the
--                  accepted set already proves the two rooms ordered.
--   de[axis] ~= 0: the edge asserts a strict order; refuted if the accepted set
--                  forces them equal or proves the opposite order.
-- Returns nil when consistent, else a human-readable reason.
local AXNAME = { [1] = "column (x)", [2] = "row (y)" }
local AXLESS = { [1] = "west of", [2] = "south of" }
function elro.constraint_refutes(O, s)
  for axis = 1, 2 do
    local A = O[axis]
    local r, x, de = s.r, s.x, s.de
    if de[axis] == 0 then
      if A.lt(r, x) then
        return string.format("needs the same %s, but %d is provably %s %d",
          AXNAME[axis], r, AXLESS[axis], x), A.why(r, x)
      elseif A.lt(x, r) then
        return string.format("needs the same %s, but %d is provably %s %d",
          AXNAME[axis], x, AXLESS[axis], r), A.why(x, r)
      end
    else
      local lo, hi = r, x
      if de[axis] < 0 then lo, hi = x, r end     -- lo must end up less than hi
      if A.find(r) == A.find(x) then
        return string.format("needs %d strictly %s %d, but they are locked to the same %s",
          lo, AXLESS[axis], hi, AXNAME[axis])
      elseif A.lt(hi, lo) then
        return string.format("needs %d %s %d, but the reverse is provable",
          lo, AXLESS[axis], hi), A.why(hi, lo)
      end
    end
  end
  return nil
end

-- Suspect reverse: the typo detector. A mistyped link need not be unsatisfiable --
-- it just draws the wrong map -- so this reports rather than demotes. Signature:
-- u -d-> v with no reverse, while v's reverse(d) points at some w ~= u that does not
-- point back either; v's reverse(d) should almost certainly be u. Requiring the v->w
-- edge to also be unreciprocated keeps genuine one-ways quiet.
function elro.suspect_reverses(adj)
  local out = {}
  local function reciprocated(r, x)
    for _, y in each_exit(adj[x]) do if y == r then return true end end
    return false
  end
  for u, nb in pairs(adj) do
    for d, v in pairs(nb) do
      local de = elro.delta[d]
      if de and adj[v] and u ~= v and (de[1] ~= 0 or de[2] ~= 0) and not reciprocated(u, v) then
        local rv = elro.reverse[d]
        local w = rv and adj[v][rv]
        if w and w ~= u and not reciprocated(v, w) then
          out[#out + 1] = { u = u, d = d, v = v, rv = rv, w = w }
        end
      end
    end
  end
  table.sort(out, function(p, q)
    if p.u ~= q.u then return p.u < q.u end
    return p.d < q.d
  end)
  return out
end

-- The audit: build the order structure from hard edges only, then admit the soft
-- ones in deterministic order, rejecting any the accepted set refutes. A rejected
-- edge is a demotion candidate. Read-only. Returns list, stats, prov.
function elro.constraint_audit(adj, assumedFn)
  local prov, stats = elro.edge_provenance(adj, assumedFn)
  local bad = {}
  for _, e in pairs(prov) do
    if e.tier == "selfloop" or e.tier == "conflict" then
      bad[#bad + 1] = { e = e, s = e.rep, reason = e.why, against = "self" }
    end
  end
  -- hard skeleton first: the layout we would get if no exit were mistyped
  local accepted = {}
  -- a fan-in's primary direction was walked both ways, so it counts as hard;
  -- only its extras are soft.
  local function corroborated(e) return e.tier == "hard" or e.tier == "fanin" end
  local O = elro.constraint_order(prov, corroborated)
  -- a hard edge can still be refuted by the rest of the hard set; report those
  -- but never demote them here -- that is a judgement call to surface, not make.
  local soft = {}
  for _, e in pairs(prov) do
    if corroborated(e) then
      local why, wit = elro.constraint_refutes(O, e.rep)
      if why then bad[#bad + 1] = { e = e, s = e.rep, reason = why, witness = wit, against = "hard" } end
    elseif e.tier ~= "selfloop" and e.tier ~= "conflict" then
      soft[#soft + 1] = e
    end
  end
  table.sort(soft, function(p, q)
    if p.a ~= q.a then return p.a < q.a end
    return p.b < q.b
  end)
  local CAP = elro.auditSoftCap or 4000
  local truncated = #soft > CAP
  for i = 1, math.min(#soft, CAP) do
    local e = soft[i]
    local why, wit = elro.constraint_refutes(O, e.rep)
    if why then
      bad[#bad + 1] = { e = e, s = e.rep, reason = why, witness = wit, against = "accepted" }
    else
      accepted[e] = true
      -- the accepted set grew, so previously-unprovable orders may now be
      -- provable; rebuild rather than trying to patch the reachability memo.
      O = elro.constraint_order(prov, function(x) return corroborated(x) or accepted[x] end)
    end
  end
  table.sort(bad, function(p, q)
    if p.e.a ~= q.e.a then return p.e.a < q.e.a end
    return p.e.b < q.e.b
  end)
  stats.truncated = truncated
  stats.softTested = math.min(#soft, CAP)
  return bad, stats, prov, elro.suspect_reverses(adj)
end

-- The demotion set: which directed edges walk_branches drops from the equations.
-- Module scope so the harness exercises the same code the engine runs.
-- Returns drop[room][dir] = true, and an ordered list of {r, d, x, why}.
-- Sources: fan-in extras, conflict extras (keep the deterministic representative so
-- the system becomes satisfiable), and refuted soft edges. Deliberately NOT
-- hard-vs-hard refutations: picking a victim there is the wizard's judgement.
--
-- Trap sinks: rooms that more than 8 other rooms claim to be adjacent to. A grid
-- cell has exactly eight neighbours, so at least N-8 of N claims are lies by
-- pigeonhole -- teleports wearing compass clothing. The ordinary conflict rule is
-- not enough (it keeps one direction per pair, so a 17-room trap still lands 17
-- constraints); once a room fails the pigeonhole test, only its corroborated edges
-- survive. Returns sink[room] = claimed neighbour count, for rooms over the bound.
-- elro.trap_sinks = false disables the pigeonhole entirely: the edges then stay in
-- the equations and a dump room's area can go unsatisfiable again.
function elro.trap_sinks(adj)
  local nb = {}
  local function note(a, b)
    if a == b then return end
    local t = nb[a] ; if not t then t = {} ; nb[a] = t end
    t[b] = true
  end
  for u, e in pairs(adj) do
    for d, v in pairs(e) do
      local de = elro.delta[d]
      if adj[v] and de and (de[1] ~= 0 or de[2] ~= 0) then note(u, v) ; note(v, u) end
    end
  end
  local sink = {}
  for r, t in pairs(nb) do
    local n = 0 ; for _ in pairs(t) do n = n + 1 end
    if n > 8 then sink[r] = n end
  end
  return sink
end

function elro.demotion_set(adj, assumedFn)
  local prov = elro.edge_provenance(adj, assumedFn)
  local drop, list = {}, {}
  local sink = elro.trap_sinks(adj)
  -- `noDraw` = demoted AND not worth drawing a corridor for. Only trap-sink edges
  -- use it; Mudlet's own exit stub still marks that the exit exists.
  local function demote(s, why, noDraw)
    if not s then return end
    drop[s.r] = drop[s.r] or {}
    if drop[s.r][s.d] == nil then
      drop[s.r][s.d] = true
      list[#list + 1] = { r = s.r, d = s.d, x = s.x, why = why, noDraw = noDraw }
    end
  end
  -- deterministic edge order throughout: a relayout that flips which member of a
  -- tie it demotes would move rooms for no reason.
  local all = {}
  for _, e in pairs(prov) do all[#all + 1] = e end
  table.sort(all, function(p, q)
    if p.a ~= q.a then return p.a < q.a end
    return p.b < q.b
  end)
  -- PASS 1 -- decisions that need no geometry: self-loops and the extras of a
  -- fan-in (whose survivor is already decided, the corroborated one).
  for _, e in ipairs(all) do
    if e.tier == "fanin" then
      -- a fan-in ON a trap sink is still a trap: its extras must be noDraw, so the
      -- sink check has to be repeated here.
      local atSink = (sink[e.a] or sink[e.b]) and true or nil
      for _, s in ipairs(e.extra) do demote(s, "fan-in extra", atSink) end
    elseif e.tier == "selfloop" then
      for _, s in ipairs(e.dirs) do demote(s, "self loop") end
    end
  end
  -- The trap-sink drop deliberately runs LAST (PASS 4) and drops only as far as
  -- the pigeonhole proves; running it early pre-empts the conflict pass and
  -- punishes once-walked corridors.
  local function live(e)
    local s = e.rep
    return not (drop[s.r] and drop[s.r][s.d])
  end
  local function corroborated(e)
    return (e.tier == "hard" or e.tier == "fanin") and live(e)
  end
  local accepted = {}                  -- shared by both admission passes below
  local O = elro.constraint_order(prov, corroborated)

  -- PASS 2 -- uncorroborated edges the surviving set refutes.
  for _, e in ipairs(all) do
    if e.tier ~= "hard" and e.tier ~= "fanin" and e.tier ~= "selfloop"
       and e.tier ~= "conflict" and live(e) then
      if elro.constraint_refutes(O, e.rep) then
        demote(e.rep, "refuted by corroborated exits")
      else
        accepted[e] = true
        O = elro.constraint_order(prov, function(x) return corroborated(x) or accepted[x] end)
      end
    end
  end
  -- PASS 3 -- conflicts. The survivor is chosen on evidence, not order: the accepted
  -- set usually refutes one direction and not the other. Ties fall back to the
  -- deterministic representative. Runs after the soft admission above because the
  -- richer the accepted set, the more informative the refutation test.
  for _, e in ipairs(all) do
    if e.tier == "conflict" then
      local keep
      for _, s in ipairs(e.dirs) do
        if not elro.constraint_refutes(O, s) then keep = s ; break end
      end
      keep = keep or e.rep
      e.rep = keep
      for _, s in ipairs(e.dirs) do
        if s ~= keep then demote(s, "conflicting direction") end
      end
      -- the survivor is now an ordinary live constraint, so later soft edges
      -- must be tested against it too.
      accepted[e] = true
      O = elro.constraint_order(prov, function(x) return corroborated(x) or accepted[x] end)
    end
  end

  -- PASS 4 -- CELL CONTENTION. `A -d-> X` asserts pos(A) = pos(X) - delta(d), so
  -- every room claiming direction d into X must occupy the same cell, and at most one
  -- claim can be true (same for X's own exit X -d-> B, from the other side). This
  -- subsumes the 8-neighbour pigeonhole and names which claims collide.
  -- A corroborated claim is never demoted, even when it loses the cell: two
  -- walked-both-ways edges contending is a source bug for mapaudit, not a victim
  -- for the layout engine to pick.
  -- elro.cellContention = false disables the pass (a bisect handle).
  local nHeld = 0        -- provably false but load-bearing; deliberately left live
  if elro.cellContention ~= false then
    local REV = elro.reverse
    local tierOf = {}                    -- dart -> its edge's tier
    for _, e in ipairs(all) do
      for _, s in ipairs(e.dirs) do tierOf[s] = e.tier end
    end
    local function alive(s) return not (drop[s.r] and drop[s.r][s.d]) end
    -- The anchor floor: a compass edge pins a row or a column, never both, so two
    -- independent live edges are the minimum that locate a room in 2D. A room left
    -- with one live edge slides freely on the other axis and collides -- so a
    -- provably-false claim that is load-bearing stays; mapaudit keeps reporting it.
    local liveDeg = {}
    for _, e in ipairs(all) do
      if e.tier ~= "selfloop" then
        for _, sd in ipairs(e.dirs) do
          if alive(sd) then
            liveDeg[sd.r] = liveDeg[sd.r] or {} ; liveDeg[sd.r][sd.x] = true
            liveDeg[sd.x] = liveDeg[sd.x] or {} ; liveDeg[sd.x][sd.r] = true
          end
        end
      end
    end
    local function deg(r)
      local n = 0 ; for _ in pairs(liveDeg[r] or {}) do n = n + 1 end ; return n
    end
    local FLOOR = elro.anchorFloor or 2
    -- "Would cross below", not "is at or under": a room at exactly FLOOR is
    -- protected (the next drop costs it an axis), but a room already under it
    -- cannot be located by holding claims anyway -- the pendant walk places it
    -- from its parent. Writing `<= FLOOR` here undoes the whole pass.
    local function load_bearing(x, y)
      if not (liveDeg[x] and liveDeg[x][y]) then return false end
      return deg(x) == FLOOR or deg(y) == FLOOR
    end
    local function forget_pair(x, y)
      if liveDeg[x] then liveDeg[x][y] = nil end
      if liveDeg[y] then liveDeg[y][x] = nil end
    end
    -- Index every dart under BOTH cells it makes a claim about: the one it points
    -- into from r, and -- read backwards -- the one r itself must occupy relative
    -- to x. A wrong claim is usually only visible from the target's side, which is
    -- exactly the trap-sink shape.
    local keys, bykey = {}, {}
    local function claim(room, d, occupant, s)
      if not d then return end
      local k = room .. ":" .. d
      local t = bykey[k]
      if not t then t = {} ; bykey[k] = t ; keys[#keys + 1] = k end
      t[occupant] = t[occupant] or {}
      table.insert(t[occupant], s)
    end
    for _, e in ipairs(all) do
      if e.tier ~= "selfloop" then
        for _, s in ipairs(e.dirs) do
          claim(s.r, s.d, s.x, s)
          claim(s.x, REV[s.d], s.r, s)
        end
      end
    end
    table.sort(keys)                     -- deterministic: relayouts must not flip victims
    for _, k in ipairs(keys) do
      elro.bg_tick("cell-contention")
      local groups = {}
      for occupant, darts in pairs(bykey[k]) do
        local anyLive = false
        for _, s in ipairs(darts) do
          if alive(s) then anyLive = true ; break end
        end
        if anyLive then groups[#groups + 1] = { room = occupant, darts = darts } end
      end
      if #groups > 1 then
        local function corroborated_group(g)
          for _, s in ipairs(g.darts) do
            local t = tierOf[s]
            if t == "hard" or t == "fanin" then return true end
          end
          return false
        end
        -- Survivor chosen on evidence: corroborated first; then the orthogonal
        -- claim over the diagonal (a diagonal pins both axes, so dropping it buys
        -- back the most freedom); then id, so the choice is reproducible.
        local function diagonal_group(g)
          for _, s in ipairs(g.darts) do
            if s.de[1] ~= 0 and s.de[2] ~= 0 then return true end
          end
          return false
        end
        -- Before falling back to geometry, rank by evidence that the rooms are
        -- neighbours at all: assumed (traversed, only the reverse's direction
        -- inferred) > conflict (both rooms name each other) > oneway.
        local TRANK = { assumed = 1, conflict = 2, oneway = 3 }
        local function rank_group(g)
          local best = 99
          for _, s in ipairs(g.darts) do
            local r = TRANK[tierOf[s]] or 99
            if r < best then best = r end
          end
          return best
        end
        table.sort(groups, function(p, q)
          local cp, cq = corroborated_group(p), corroborated_group(q)
          if cp ~= cq then return cp end
          local rp, rq = rank_group(p), rank_group(q)
          if rp ~= rq then return rp < rq end
          local dp, dq = diagonal_group(p), diagonal_group(q)
          if dp ~= dq then return dq end        -- non-diagonal sorts first = survives
          return p.room < q.room
        end)
        for i = 2, #groups do
          local g = groups[i]
          -- never demote a corroborated claim, even a losing one (see the note above)
          if not corroborated_group(g) then
            local lo, hi = g.darts[1].r, g.darts[1].x
            if lo > hi then lo, hi = hi, lo end
            -- The floor yields to the pigeonhole, and only to it: a trap sink may
            -- take a room under the floor, an ordinary contention may not.
            -- Without this split the two rules deadlock.
            if load_bearing(lo, hi) and not (sink[lo] or sink[hi]) then
              nHeld = nHeld + 1
            else
              forget_pair(lo, hi)
              for _, s in ipairs(g.darts) do
                -- noDraw follows the TRAP-SINK flag, not this rule: a room that is
                -- wildly over-subscribed has no geometry worth asserting and gets
                -- spikes, while an ordinary two-way contention gets a real corridor.
                demote(s, string.format(
                  "cell contention: %d rooms claim the cell %s of %s",
                  #groups, k:match(":(.*)$"), k:match("^(%d+)")),
                  (sink[s.r] or sink[s.x]) and true or nil)
              end
            end
          end
        end
      end
    end
  end

  elro._heldClaims = nHeld
  if nHeld > 0 then
    elro.tr(string.format("demote: %d contended claim(s) KEPT -- dropping them would "
      .. "leave a room under the %d-anchor floor (mapaudit still reports them)",
      nHeld, elro.anchorFloor or 2))
  end
  return drop, list, prov, sink
end

-- mapaudit [all] -- report exits whose asserted geometry the trustworthy exits
-- refute. These are the edges that make a layout unsatisfiable.
function elro.cmd_audit(arg)
  local scope = (arg or ""):match("^%s*(%S*)")
  local areas = {}
  if scope == "all" then
    for nm, aid in pairs(getAreaTable() or {}) do areas[#areas + 1] = { nm, aid } end
    table.sort(areas, function(p, q) return p[1] < q[1] end)
  else
    local cur = elro.current and getRoomArea(elro.current)
    if not cur then
      cecho("\n<yellow>[elro]: no current room -- walk somewhere, or use 'mapaudit all'.\n<reset>")
      return
    end
    areas[1] = { elro.areaName(cur) or ("area " .. cur), cur }
  end
  local totBad = 0
  for _, A in ipairs(areas) do
    local name, aid = A[1], A[2]
    local rooms, adj = area_adjacency(aid, true)   -- keep selfloops: the audit REPORTS them
    local bad, stats, prov, suspect = elro.constraint_audit(adj)
    local fanin = {}
    for _, e in pairs(prov) do if e.tier == "fanin" then fanin[#fanin + 1] = e end end
    table.sort(fanin, function(x, y) if x.a ~= y.a then return x.a < y.a end return x.b < y.b end)
    if scope ~= "all" or #bad > 0 or #suspect > 0 or #fanin > 0 then
      cecho(string.format("\n<cyan>[elro] constraint audit -- '%s' (%d rooms)<reset>", name, #rooms))
      cecho(string.format("\n<cyan>  hard %d | oneway %d | assumed %d | fanin %d | conflict %d | selfloop %d<reset>",
        stats.hard, stats.oneway, stats.assumed, stats.fanin, stats.conflict, stats.selfloop))
      if stats.truncated then
        cecho(string.format("\n<yellow>  (only the first %d soft edges tested -- raise elro.auditSoftCap)<reset>",
          stats.softTested))
      end
      -- Two findings, two remedies -- do not merge these sections: a CONTRADICTION
      -- means no truthful drawing exists (soften an edge); a SUSPECT LINK may be
      -- satisfiable and just draws the wrong map (fix the source).
      if #bad == 0 then
        cecho("\n<green>  no contradictions -- every exit's geometry is satisfiable.<reset>")
      else
        cecho(string.format("\n<red>  %d CONTRADICTION(S) -- no truthful drawing exists while all of these stand:<reset>", #bad))
        for _, b in ipairs(bad) do
          cecho(string.format("\n<red>    %d -%s-> %d<reset>  <yellow>[%s]<reset>  %s",
            b.s.r, b.s.d, b.s.x, b.e.tier, b.reason))
          -- the mistyped link is one of the exits in this chain
          if b.witness and #b.witness > 0 then
            local parts = {}
            for _, w in ipairs(b.witness) do
              parts[#parts + 1] = w and (w.r .. " -" .. w.d .. "-> " .. w.x) or "?"
            end
            cecho("\n<cyan>        proof: " .. table.concat(parts, " ; ") .. "<reset>")
          end
        end
      end
      if #suspect > 0 then
        cecho(string.format("\n<yellow>  %d SUSPECT LINK(S) -- one-way out, and the room back has a reverse exit<reset>", #suspect))
        cecho("\n<yellow>  pointing somewhere else that nothing points back from:<reset>")
        for _, s in ipairs(suspect) do
          cecho(string.format("\n<yellow>    %d -%s-> %d<reset>, but <yellow>%d -%s-> %d<reset>   (should %d's %s be %d?)",
            s.u, s.d, s.v, s.v, s.rv, s.w, s.v, s.rv, s.u))
        end
      end
      -- FAN-IN is the third outcome and the only self-resolving one: the
      -- corroborated direction stands and the extras are demoted. No source fix.
      if #fanin > 0 then
        cecho(string.format("\n<cyan>  %d FAN-IN(S) -- several directions into one room. The walked-both-ways<reset>", #fanin))
        cecho("\n<cyan>  direction is kept; the extras below are redundant and get demoted:<reset>")
        for _, e in ipairs(fanin) do
          local ex = {}
          for _, x in ipairs(e.extra) do ex[#ex + 1] = x.r .. " -" .. x.d .. "-> " .. x.x end
          cecho(string.format("\n<cyan>    keep %d -%s-> %d<reset>, demote <yellow>%s<reset>",
            e.rep.r, e.rep.d, e.rep.x, table.concat(ex, ", ")))
        end
      end
      if #bad > 0 or #suspect > 0 then
        cecho("\n<cyan>  Contradictions and suspect links are usually mistyped: the wizard meant a<reset>" ..
              "\n<cyan>  bidirectional pair and set one target (or direction) wrong. Check the source.<reset>")
      end
      cecho("\n")
    end
    totBad = totBad + #bad + #suspect
  end
  if scope == "all" then
    cecho(string.format("\n<cyan>[elro] %d contradiction(s) across %d area(s).<reset>\n", totBad, #areas))
  end
end
