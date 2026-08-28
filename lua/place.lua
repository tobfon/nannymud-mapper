-- Functions extracted from walk_branches (lua/walk.lua). Each takes the walk context table W,
-- populated by a shim in walk_branches at every call, and binds what it needs to locals.
-- Split out of walk.lua; see lua/modules.lua for the load order.

elro = elro or {}
local G = elro.g or error("place.lua: lua/geom.lua must be loaded first (see elro.modules)")
local ori = G.ori
local K = elro.k or error("place.lua: lua/keys.lua must be loaded first (see elro.modules)")
local ekey = K.edge
local each_exit = elro.exits or error("place.lua: lua/core.lua must be loaded first")
local CLK = elro.clk or error("place.lua: lua/core.lua must be loaded first")
local TUNE = elro.TUNE or error("place.lua: lua/tune.lua must be loaded first")

-- place ONE room v at exactly one step off u, then resolve the conflicts it introduced with
-- one cheapest into-empty lever at a time (room-on-room OVERLAP, edge CROSSING, edge over a
-- room, or v itself landing on a placed edge). Refuses cascades / crossing-making pulls.
function elro.place_room(W, u, kid, root)
  local DELTA, add_edges, adj, apply_pull, arteryRooms, branchOf, branchSet, cand_shift = W.DELTA, W.add_edges, W.adj, W.apply_pull, W.arteryRooms, W.branchOf, W.branchSet, W.cand_shift
  local cell_overlap, coord, cross_convert, crossing_set, crossings_moved, ctrace, edge_over_room_v = W.cell_overlap, W.coord, W.cross_convert, W.crossing_set, W.crossings_moved, W.ctrace, W.edge_over_room_v
  local eqwReconciled, eqw_close, eqw_make_room, eqw_topo_cross, eqw_wire_cross, first_crossing_v, forced_cross, gridx_only = W.eqwReconciled, W.eqw_close, W.eqw_make_room, W.eqw_topo_cross, W.eqw_wire_cross, W.first_crossing_v, W.forced_cross, W.gridx_only
  local junction_score, leftover, mark, parentOf, placed, pull_makes_crossing = W.junction_score, W.leftover, W.mark, W.parentOf, W.placed, W.pull_makes_crossing
  local pull_makes_lie, pull_makes_overlap, pull_makes_roomedge, query_cut_levers, query_eq_2d_levers, query_eq_levers, query_ring_dilate_levers, rebuild_occ = W.pull_makes_lie, W.pull_makes_overlap, W.pull_makes_roomedge, W.query_cut_levers, W.query_eq_2d_levers, W.query_eq_levers, W.query_ring_dilate_levers, W.rebuild_occ
  local repair_after, repair_run, revert_pull, room_on_pedge_v, roomedge_set, sheared_gridx, topo_forced, try_chunk = W.repair_after, W.repair_run, W.revert_pull, W.room_on_pedge_v, W.roomedge_set, W.sheared_gridx, W.topo_forced, W.try_chunk
  local eq_ek, eqw_classes, eqw_forced_shift = W.eq_ek, W.eqw_classes, W.eqw_forced_shift
  -- The walk's yield point; must stay at the top, before any geometry is touched (`coord` is
  -- the solver's own table, nothing has reached Mudlet). No-op off the coroutine.
  elro.bg_tick("place-room")
  local _pr0 = elro.timeGuillo and CLK()
  local v, d, de = kid.v, kid.d, DELTA[kid.d]
  elro._placingV = v                 -- read by _rank_cands for a room-scoped `maplever <ek>@<room>`
  -- Gap timing: charge the interval since the previous placement ended to the phase the walk
  -- was in at the START of the gap. Reuses `_pr0`/`_prLast`; no new os.clock in this hot path.
  if _pr0 then
    local ph = elro._prLastPhase or elro._wbPhase or "?"
    local gap = _pr0 - (elro._prLast or _pr0)
    elro._gapT[ph] = (elro._gapT[ph] or 0) + gap
    elro._gapN[ph] = (elro._gapN[ph] or 0) + 1
    if gap > 0.004 then
      local g = elro._gapTop
      g[#g + 1] = { ms = gap * 1000, ph = ph, from = elro._prLastRoom, to = v }
    end
  end
  branchOf[v] = root   -- nil for artery/core; the top-level pendant root for kids
  parentOf[v] = u      -- placement tree: v was walked off of u (for LCA-junction detection)
  -- Place at exactly one step (no slide: sliding past an obstruction drags the edge over it).
  -- placed[v] is set only AFTER the eqw block below, or the repair routes around v instead of
  -- moving it. Step out at the edge's minimum length (elro.minLen, absent = 1).
  local mL = elro.min_len(u, v)
  coord[v] = { coord[u][1] + de[1] * mL, coord[u][2] + de[2] * mL }
  -- Constrained placement: a placed N/S neighbour fixes v's column, a placed E/W neighbour its
  -- row. Applied only when every placed neighbour ends up truthful.
  local mrFix                       -- did eqw_make_room stretch the geometry to fit v in?
  local cpFix                       -- did CONSTRAINED PLACEMENT put v somewhere other than the unit step?
  local cpsFix                      -- did the CHORD PRE-STEP slide a neighbour to meet v?
  -- Chord pre-step: instead of moving v to satisfy a row/column lock, slide the locking
  -- neighbour along its own chord to meet v when existing slack pays for it. A construction
  -- step, deliberately not gated on the defect count; the only gate is truthfulness plus
  -- `slide_paid`. Purely local and geometric -- not a class/equation question.
  -- slide_ok: can X slide by `sh` on axis `pa` and leave every one of its own edges truthful?
  local function slide_ok(X, pa, sh)
    local nx = { coord[X][1], coord[X][2] } ; nx[pa] = nx[pa] + sh
    for dd, y in each_exit(adj[X]) do
      local dey = DELTA[dd]
      if placed[y] and dey and (dey[1] ~= 0 or dey[2] ~= 0) and y ~= X then
        local dx, dy = coord[y][1] - nx[1], coord[y][2] - nx[2]
        if not elro.edge_ok(X, y, dx, dy, dey) then return false end
      end
    end
    return true
  end
  -- Never slide a room that belongs to a forced crossing: it could collapse the crossing into
  -- a room-on-edge. Must use the topo pass's forced pairs -- the wire is not on the canvas yet.
  local forcedRoom = {}
  local T = eqw_topo_cross()
  if T and T.n and T.n > 0 then
    for _, q in ipairs(T.quartet) do
      forcedRoom[q[1]] = true ; forcedRoom[q[2]] = true
      forcedRoom[q[3]] = true ; forcedRoom[q[4]] = true
    end
  end
  -- slide_paid: the slide must be paid by existing slack -- net edge length must not increase
  -- and no square diagonal may be lost. (Truthfulness alone lets a slide inject space and shear.)
  local function slide_paid(X, pa, sh)
    local nx = { coord[X][1], coord[X][2] } ; nx[pa] = nx[pa] + sh
    local dL, dSq = 0, 0
    for dd, y in each_exit(adj[X]) do
      local dey = DELTA[dd]
      if placed[y] and dey and (dey[1] ~= 0 or dey[2] ~= 0) and y ~= X then
        local ax, ay = coord[y][1] - coord[X][1], coord[y][2] - coord[X][2]
        local bx, by = coord[y][1] - nx[1], coord[y][2] - nx[2]
        local function len(p, q) p = (p < 0) and -p or p ; q = (q < 0) and -q or q
          return (p > q) and p or q end
        dL = dL + len(bx, by) - len(ax, ay)
        if dey[1] ~= 0 and dey[2] ~= 0 then
          local wasSq = ((ax < 0) and -ax or ax) == ((ay < 0) and -ay or ay)
          local isSq  = ((bx < 0) and -bx or bx) == ((by < 0) and -by or by)
          if wasSq and not isSq then dSq = dSq - 1
          elseif isSq and not wasSq then dSq = dSq + 1 end
        end
      end
    end
    return dL <= 0 and dSq >= 0
  end
  for _, d2 in ipairs(elro.dir_order) do          -- dir_order, not pairs: the pick is order-free
    local w = (adj[v] or {})[d2]
    local de2 = DELTA[d2]
    if w and placed[w] and de2 and ((de2[1] ~= 0) ~= (de2[2] ~= 0)) then
      -- an E/W edge must MATCH on axis 2 (same row); an N/S edge on axis 1 (same column)
      local pa = (de2[1] ~= 0) and 2 or 1
      local need = coord[v][pa] - coord[w][pa]     -- move w by this to line up with v
      if need ~= 0 and not forcedRoom[w] and not forcedRoom[v] and slide_ok(w, pa, need)
         and slide_paid(w, pa, need) then
        coord[w] = (pa == 1) and { coord[w][1] + need, coord[w][2] }
                              or { coord[w][1], coord[w][2] + need }
        rebuild_occ()
        cpsFix = true
        if elro.debug then
          elro.tr(string.format("  eqw pre-step %d: slid %d by %+d on axis %d to make %d-%s->%d truthful",
            v, w, need, pa, v, d2, w)) end
      end
    end
  end
  -- if v's placed neighbours leave it NO feasible cell, repair the geometry first (see
  -- eqw_make_room) -- then the constrained placement below simply reads off the answer.
  local _mr0 = elro.timeGuillo and CLK()
  local _mrK0 = _mr0 and collectgarbage("count")
  local fix = eqw_make_room(v, u, de)
  if _mr0 then elro._mrK = (elro._mrK or 0) + (collectgarbage("count") - _mrK0)
    elro._mrT = (elro._mrT or 0) + (CLK() - _mr0)
    elro._mrN = (elro._mrN or 0) + 1 end
  mrFix = fix
  if fix then coord[v] = fix end
  -- Collect the distinct lock values per axis via dir_order (not pairs) so which lock wins is
  -- deterministic. The first one is taken; scoring the combinations was measured a no-op.
  local lockX, lockY, seenX, seenY = {}, {}, {}, {}
  for _, d2 in ipairs(elro.dir_order) do
    local w = (adj[v] or {})[d2]
    local de2 = DELTA[d2]
    if w and placed[w] and de2 and coord[w] then
      if de2[1] == 0 and de2[2] ~= 0 then
        local x = coord[w][1]
        if not seenX[x] then seenX[x] = true ; lockX[#lockX + 1] = x end
      elseif de2[2] == 0 and de2[1] ~= 0 then
        local y = coord[w][2]
        if not seenY[y] then seenY[y] = true ; lockY[#lockY + 1] = y end
      end
    end
  end
  local px, py = lockX[1], lockY[1]
  if px or py then
    local cand = { px or coord[v][1], py or coord[v][2] }
    local ok = true
    for d2, w in each_exit(adj[v]) do
      local de2 = DELTA[d2]
      if placed[w] and de2 and (de2[1] ~= 0 or de2[2] ~= 0) then
        local dx, dy = coord[w][1] - cand[1], coord[w][2] - cand[2]
        -- edge_ok also enforces the edge's minimum length; nothing later would notice a breach
        if not elro.edge_ok(v, w, dx, dy, de2) then ok = false ; break end
      end
    end
    if ok and (cand[1] ~= coord[v][1] or cand[2] ~= coord[v][2]) then
      if elro.debug then
        elro.tr(string.format("  eqw place %d: constrained (%d,%d) instead of unit-step (%d,%d)",
          v, cand[1], cand[2], coord[v][1], coord[v][2])) end
      coord[v] = cand
      cpFix = true      -- a slack producer: the edge is truthful at once, so no closure notices
    end
  end
  -- Realise a forced crossing at its site: when u->v is one half of an accepted pair and the
  -- partner wire is on the canvas, step v out until the edge properly crosses it. A room may
  -- JUMP the wire but never land on it; every placed neighbour must stay truthful.
  if de and (de[1] ~= 0 or de[2] ~= 0) then
    local T = eqw_topo_cross()
    if T.n > 0 then
      local myk = ekey(u, v)
      local partner
      for _, q in ipairs(T.quartet) do
        local k1, k2 = ekey(q[1], q[2]), ekey(q[3], q[4])
        if k1 == myk and placed[q[3]] and placed[q[4]] then partner = { q[3], q[4] }
        elseif k2 == myk and placed[q[1]] and placed[q[2]] then partner = { q[1], q[2] } end
        if partner then break end
      end
      if partner and partner[1] ~= u and partner[1] ~= v and partner[2] ~= u and partner[2] ~= v then
        local P, Q = coord[partner[1]], coord[partner[2]]
        local base, cap = coord[u], (elro.crossJumpCap or 6)
        local function crosses(c)
          local d1 = ori(P[1], P[2], Q[1], Q[2], base[1], base[2])
          local d2 = ori(P[1], P[2], Q[1], Q[2], c[1], c[2])
          local d3 = ori(base[1], base[2], c[1], c[2], P[1], P[2])
          local d4 = ori(base[1], base[2], c[1], c[2], Q[1], Q[2])
          if d1 == 0 or d2 == 0 or d3 == 0 or d4 == 0 then return false end  -- touch, not a crossing
          return ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0))
        end
        local function truthful(c)
          for d2, w in each_exit(adj[v]) do
            local de2 = DELTA[d2]
            if placed[w] and de2 and (de2[1] ~= 0 or de2[2] ~= 0) then
              local dx, dy = coord[w][1] - c[1], coord[w][2] - c[2]
              if not elro.edge_ok(v, w, dx, dy, de2) then return false end
            end
          end
          return true
        end
        if not crosses(coord[v]) then
          for n = 1, cap do
            local c = { base[1] + de[1] * n, base[2] + de[2] * n }
            if crosses(c) and truthful(c) then
              elro.tr(string.format("  crossing site: %s -%s-> %s stepped to %d so the edge JUMPS"
                .. " the %s-%s wire (never onto it)", tostring(u), tostring(kid.d), tostring(v),
                n, tostring(partner[1]), tostring(partner[2])))
              coord[v] = c
              elro._cjN = (elro._cjN or 0) + 1
              break
            end
          end
        end
      end
    end
  end
  -- Order clamp: move v to the nearest cell satisfying the proved order relations against
  -- placed rooms (pays in edge length, never reorders). A steering device, not a correctness
  -- fix. Restricted to rooms a forced crossing can be moved by -- the column/row class members
  -- and corner quartet of each proved wire pair; the set is cached on the wire table.
  local Wc = eqw_wire_cross()
  if Wc then
    local S = Wc._clampSet
    if not S then
      S = {}
      for _, wr in ipairs(Wc.wires or {}) do
        for _, ms in ipairs({ wr.vm, wr.hm }) do
          for i = 1, #(ms or {}) do S[ms[i]] = true end
        end
        for _, q in ipairs({ wr.S, wr.N, wr.W, wr.E }) do if q then S[q] = true end end
      end
      Wc._clampSet = S
    end
    if not S[v] then Wc = nil ; elro._woSkip = (elro._woSkip or 0) + 1 end
  end
  if Wc then
  local p = coord[v]
  for axis = 1, 2 do
    local A = Wc.O[axis]
    local cv = A.find(v)
    local lo, hi = nil, nil            -- inclusive bounds from PLACED rooms only
    -- An equality outranks an order bound: if a placed room shares v's class on this axis the
    -- coordinate is determined (constrained placement's job), so skip the axis.
    local determined = false
    for r in pairs(placed) do
      if r ~= v and coord[r] and A.find(r) == cv then determined = true ; break end
    end
    if determined then
      elro._woEq = (elro._woEq or 0) + 1
    else
    for r in pairs(placed) do
      local q = coord[r]
      if q and r ~= v then
        local cr = A.find(r)
        if cr ~= cv then
          if elro.wire_lt(A, cr, cv) then
            if lo == nil or q[axis] + 1 > lo then lo = q[axis] + 1 end
          elseif elro.wire_lt(A, cv, cr) then
            if hi == nil or q[axis] - 1 < hi then hi = q[axis] - 1 end
          end
        end
      end
    end
    -- A lie corrupts the classes and every bound derived through them; the equality skip above
    -- and the truthfulness check below are the protection.
    local want = p[axis]
    if lo and want < lo then want = lo end
    if hi and want > hi then want = hi end
    -- lo > hi: the placed geometry already contradicts the order; leave v alone
    if lo and hi and lo > hi then want = p[axis] ; elro._woBad = (elro._woBad or 0) + 1 end
    if want ~= p[axis] then
      local was = p[axis]
      p[axis] = want
      -- Truthfulness backstop over every placed neighbour. Sign convention: for an edge v->w in
      -- direction dd, `coord[w] - coord[v]` must carry the sign of DELTA[dd].
      local lied = false
      for dd, w in each_exit(adj[v]) do
        local dde = DELTA[dd]
        if dde and placed[w] and coord[w] and (dde[1] ~= 0 or dde[2] ~= 0) then
          local need = coord[w][axis] - p[axis]          -- must have the sign of dde[axis]
          if dde[axis] == 0 and need ~= 0 then lied = true ; break end
          if dde[axis] > 0 and need <= 0 then lied = true ; break end
          if dde[axis] < 0 and need >= 0 then lied = true ; break end
          -- signs are not enough for a sized diagonal: a one-axis move can un-square a wall
          if elro.minLen and not elro.edge_ok(v, w, coord[w][1] - p[1], coord[w][2] - p[2], dde)
          then lied = true ; break end
        end
      end
      if lied then
        p[axis] = was
        elro._woLie = (elro._woLie or 0) + 1
      else
        elro.tr(string.format("  order clamp: %s axis %d %d -> %d (proved bounds %s..%s)",
          tostring(v), axis, was, want, tostring(lo), tostring(hi)))
        elro._woN = (elro._woN or 0) + 1
        -- cells this pass moves rooms by
        elro._woCells = (elro._woCells or 0) + ((want > was) and (want - was) or (was - want))
        ctrace(true, "[order clamp %d] axis %d: %d -> %+d (proved bounds %s..%s) -- the attach edge"
          .. " is %d cell(s) longer for it", v, axis, was, want - was, tostring(lo), tostring(hi),
          (want > was) and (want - was) or (was - want))
      end
    end
    end
  end
  end
  -- Seat v so every placed neighbour's edge meets its minimum: step further along the parent
  -- ray (only lengthens the parent edge); decline if no cell within reach works.
  if elro.minLen and de and (de[1] ~= 0 or de[2] ~= 0) then
    local function seated(c)
      for d2, w in each_exit(adj[v]) do
        local de2 = DELTA[d2]
        if placed[w] and de2 and (de2[1] ~= 0 or de2[2] ~= 0) then
          local dx, dy = coord[w][1] - c[1], coord[w][2] - c[2]
          if not elro.edge_ok(v, w, dx, dy, de2) then return false end
        end
      end
      return true
    end
    if not seated(coord[v]) then
      local base = coord[u]
      for n = mL + 1, mL + 8 do
        local c = { base[1] + de[1] * n, base[2] + de[2] * n }
        if seated(c) then
          elro.tr(string.format("  min_len: %d stepped out to %d cell(s) off %d so every edge meets"
            .. " its minimum", v, n, u))
          coord[v] = c
          break
        end
      end
    end
  end
  elro._wdRoom = v      -- watchdog breadcrumb: the room the walk is working on
  elro._bfGen = (elro._bfGen or 0) + 1
  placed[v] = true      -- NOW it is on the canvas (see the note at the unit-step assignment)
  -- The face chunk goes in AFTER the closures below, not here: a just-closed face is still one
  -- eq-shift away from its final shape.
  elro._walkN = elro._walkN + 1 ; elro._walkOrder[v] = elro._walkN
  local tries = {}   -- per-room lever-attempt trace for mapcaps (stage="walk")
  -- class-shift / eq-plate ek's COMMITTED for this room, so their inverses stop being offered.
  -- Recorded only where a pull is kept (a reverted trial must not count).
  local classUsed = {}
  local function note_class(c)
    if c and c.ek and (c.kind == "class-shift" or c.kind == "eq-plate") then
      classUsed[c.ek] = true
      elro._eqPPnote = (elro._eqPPnote or 0) + 1
    end
  end
  local hadConflict = false   -- did any guard iteration detect a collision? (skip the redundant
                              -- post-loop stuck re-check when the room placed cleanly)
  -- `ckind`/`cblk` are scoped to the loop body; the tiers after the loop read these instead.
  local lastCkind, lastCblk
  local pendingLS             -- least-severe choice deferred until after the corner tier
  -- conflict deferred until the closure has run (set at dispatch, re-read at the stuck
  -- re-check and after the closure loop)
  local closeDefer
  -- Apply the deliberate defect; runs inline when no corner pair exists, or after the corner
  -- tier when one does and failed to clear. `baseCross` (crossing set from BEFORE this pull)
  -- must be sampled by the caller, since `coord` may have moved under the corner pulls.
  local function take_least_severe(fb, fbWhy, ckind, cblk, ranked, baseCross)
    note_class(fb) ; apply_pull(fb)
    elro._walkPulls[#elro._walkPulls + 1] = { v = v, kind = fb.kind, ek = fb.ek,
      dx = fb.dx, dy = fb.dy, dist = fb.dist, rooms = fb.rooms }
    elro._lsFallback = (elro._lsFallback or 0) + 1
    elro._lsFbKind = elro._lsFbKind or {}
    elro._lsFbKind[fbWhy] = (elro._lsFbKind[fbWhy] or 0) + 1
    -- Histogram whether each crossing this tier took was provably forced (`_lsX`).
    local after = crossings_moved(fb.set, v)
    for k in pairs(after) do
      if not baseCross[k] then
        local p, q, r2, s2 = k:match("^(%d+):(%d+)|(%d+):(%d+)$")
        if p then
          local ok, reason = forced_cross(tonumber(p), tonumber(q), tonumber(r2), tonumber(s2))
          if not ok then
            -- ask the wider test too, else a crossing the topology proves unavoidable is filed
            -- here as "papered over"
            local tok, twhy = topo_forced(tonumber(p), tonumber(q), tonumber(r2), tonumber(s2))
            if tok then ok, reason = true, "topo" else reason = reason .. " / " .. twhy end
          end
          elro._lsX = elro._lsX or {}
          local bucket = ok and "forced" or reason
          elro._lsX[bucket] = (elro._lsX[bucket] or 0) + 1
          elro.tr(string.format("  least-severe crossing %s-%s x %s-%s: %s",
            p, q, r2, s2, ok and "PROVED forced" or ("unproved (" .. tostring(reason) .. ")")))
        end
      end
    end
    elro.step_snap(coord, string.format(
      "walk LEAST-SEVERE %s for %s: no clean lever, took %s (%dr dist %d) rather than keep the %s",
      fbWhy, tostring(v), fb.kind, fb.rooms or 0, fb.dist or 0, tostring(ckind)), v, cblk,
      { ek = fb.ek, kind = fb.kind, dist = fb.dist, rooms = fb.rooms, score = fb.score,
        ckind = ckind, blocker = cblk, ranked = ranked })
  end
  local guard = 0
  while guard < 8 do
    -- yield per guard iteration: the per-candidate tick is unreachable on an empty list
    elro.bg_tick("guard-iter")
    guard = guard + 1
    elro._wdGuard = guard      -- watchdog breadcrumb: how deep into the conflict loop we are
    -- dispatch timing: the detectors plus the cheapest_lever_* seeding
    local _dsp0 = elro.timeGuillo and CLK()
    local _dspK0 = _dsp0 and collectgarbage("count")
    local cands, ckind, cblk
    -- the neighbour whose edge is the defective one (nil for an overlap), so the attach-edge
    -- veto can be limited to conflicts ON the attach edge
    local cEdgeW
    local cEdgeOn        -- room-on-edge: the edge v sits ON (for the licensed-extension exception)
    local cdiag          -- is the offending edge a 45-degree wall? (trigger for the "diag" 2D family)
    -- seed timing, split out of dispatch (the detectors run every iteration, seeding only on conflict)
    local function seed(f, ...)
      if not _dsp0 then return f(...) end
      local t = CLK() ; local r = f(...)
      elro._sedT = (elro._sedT or 0) + (CLK() - t) ; elro._sedN = (elro._sedN or 0) + 1
      return r
    end
    local X = cell_overlap(v)
    if X then ckind, cblk = "overlap", X ; lastCkind, lastCblk = ckind, cblk
      cands = seed(elro.cheapest_lever_overlap, coord, adj, v, X, branchSet, v)
    else
      local w, ce = first_crossing_v(v)
      -- A sheared grid-X can only be cured by squaring the quad, so skip the SEARCH (not the
      -- verdict: `hadConflict` is set as the normal path would).
      if ce and sheared_gridx(v, w, ce.u, ce.v) then
        elro._gxSkipN = (elro._gxSkipN or 0) + 1
        hadConflict = true
        lastCkind, lastCblk = "cross", ce.u
        if _dsp0 then elro._dspK = (elro._dspK or 0) + (collectgarbage("count") - _dspK0)
          elro._dspT = (elro._dspT or 0) + (CLK() - _dsp0)
          elro._dspN = (elro._dspN or 0) + 1 end
        elro.tr(string.format("  walk: %s x %s is a SHEARED GRID-X (%s-%s-%s-%s) -- "
          .. "no lever can square the quad, skipping the search", tostring(v), tostring(ce.u),
          tostring(v), tostring(w), tostring(ce.u), tostring(ce.v)))
        break
      end
      -- Do not lever against a back-edge the closure below is about to rewrite: when the
      -- crossing is on an UNTRUTHFUL and UNRECONCILED back-edge, defer and re-test after the
      -- closure loop. Skips the search, not the verdict. Only useful together with
      -- `xboundTruthOnly` (a crossing on a lie must not become a hard bound).
      if ce and w ~= u and placed[w]
         and not eqwReconciled[ekey(v, w)] and coord[v] and coord[w] then
        local dv
        for d3, x3 in each_exit(adj[v]) do
          local de3 = DELTA[d3]
          if x3 == w and de3 and (de3[1] ~= 0 or de3[2] ~= 0) then dv = de3 ; break end
        end
        if dv and not elro.edge_truthful(dv, coord[w][1] - coord[v][1], coord[w][2] - coord[v][2]) then
          closeDefer = { w = w, cu = ce.u, cv = ce.v }
          hadConflict = true
          lastCkind, lastCblk = "cross", ce.u
          elro._dcDefer = (elro._dcDefer or 0) + 1
          if _dsp0 then elro._dspK = (elro._dspK or 0) + (collectgarbage("count") - _dspK0)
            elro._dspT = (elro._dspT or 0) + (CLK() - _dsp0)
            elro._dspN = (elro._dspN or 0) + 1 end
          elro.tr(string.format("  walk: %s x %s is on %s-%s, an UNTRUTHFUL back-edge with a"
            .. " closure queued -- deferring the lever until after it runs",
            tostring(v), tostring(ce.u), tostring(v), tostring(w)))
          break
        end
      end
      if ce then ckind, cblk = "cross", ce.u ; lastCkind, lastCblk = ckind, cblk
        cEdgeW = w
        cands = seed(elro.cheapest_lever, coord, adj, { u = v, v = w }, { u = ce.u, v = ce.v }, branchSet, v)
      else
        local w2, R = edge_over_room_v(v)
        if R then ckind, cblk = "edge-on-room", R ; lastCkind, lastCblk = ckind, cblk
          cEdgeW = w2
          cdiag = elro.diag_edge(coord, v, w2)
          cands = seed(elro.cheapest_lever_roomedge, coord, adj, R, { u = v, v = w2 }, branchSet, v)
        else
          local ve = room_on_pedge_v(v)
          if ve then ckind, cblk = "room-on-edge", ve.u ; lastCkind, lastCblk = ckind, cblk
            cEdgeOn = ve
            cdiag = elro.diag_edge(coord, ve.u, ve.v)
            cands = seed(elro.cheapest_lever_roomedge, coord, adj, v, ve, branchSet, v) end
        end
      end
    end
    if _dsp0 then elro._dspK = (elro._dspK or 0) + (collectgarbage("count") - _dspK0)
      elro._dspT = (elro._dspT or 0) + (CLK() - _dsp0)
      elro._dspN = (elro._dspN or 0) + 1 end
    if not cands then break end
    hadConflict = true   -- a collision was found this iteration; the stuck re-check is warranted
    -- v's current conflict signature (kind, blocker, rooms involved). A pull that leaves kind
    -- AND blocker identical resolved nothing (the pull_makes_* guards only test for NEW
    -- defects); any real progress changes one of them.
    local function conflict_sig(r)
      local X2 = cell_overlap(r) ; if X2 then return "overlap", X2, { r, X2 } end
      local w2, ce2 = first_crossing_v(r)
      if ce2 then return "cross", ce2.u, { r, w2, ce2.u, ce2.v } end
      local w3, R2 = edge_over_room_v(r) ; if R2 then return "edge-on-room", R2, { r, w3, R2 } end
      local ve2 = room_on_pedge_v(r) ; if ve2 then return "room-on-edge", ve2.u, { ve2.u, ve2.v } end
      return nil, nil, nil
    end
    -- `_noopWhy` (stepDebug only; the verdict must not depend on the trace): which conflict
    -- rooms the plate carried (`*`), and whether the crossing travelled with it rigidly.
    local function pull_is_noop(c)
      local _t = elro.timeGuillo and CLK()
      apply_pull(c)
      local k2, b2, rooms2 = conflict_sig(v)
      revert_pull(c)
      if _t then elro._noopT = (elro._noopT or 0) + (CLK() - _t)
        elro._noopN = (elro._noopN or 0) + 1 end
      local same = (k2 == ckind and b2 == cblk)
      if same and elro.stepDebug and rooms2 then
        local t, nIn = {}, 0
        for i = 1, #rooms2 do
          local rr = rooms2[i]
          if rr then
            local inSet = c.set and c.set[rr] and true or false
            if inSet then nIn = nIn + 1 end
            t[#t + 1] = tostring(rr) .. (inSet and "*" or "")
          end
        end
        local shape = ""
        if k2 == "cross" and #t == 4 then
          local a1 = c.set and c.set[rooms2[1]] and c.set[rooms2[2]]
          local b1 = c.set and c.set[rooms2[3]] and c.set[rooms2[4]]
          if a1 and b1 then shape = " -- the plate carries BOTH edges: the crossing travels with it"
          elseif a1 or b1 then shape = " -- one edge translates WHOLE; it cannot stop crossing the other"
          elseif nIn == 0 then shape = " -- the plate touches NEITHER edge" end
          t = { t[1] .. "-" .. t[2], "x", t[3] .. "-" .. t[4] }
        end
        elro._noopWhy = table.concat(t, " ") .. shape
      elseif same then
        elro._noopWhy = nil
      end
      return same
    end
    local eqPass1N = 0           -- eq plates pass 1 emitted; none means no held walk to release
    if cblk then
      local _gen0 = elro.timeGuillo and CLK()
      local _genK0 = _gen0 and collectgarbage("count")
      -- per-generator timing split of `_genT`
      local _gsplit = _gen0 and function(k, t0)
        local S = elro._gsSplit ; if not S then S = {} ; elro._gsSplit = S end
        local a = S[k] ; if not a then a = { t = 0, n = 0 } ; S[k] = a end
        a.t = a.t + (CLK() - t0) ; a.n = a.n + 1
      end or nil
      -- PLATE GENERATION
      local g
      do
        -- Equation plates, first pass at magnitude cap TUNE.eqLazyCap; the escalation below
        -- regenerates at deeper caps when nothing clean turns up.
        local _t0 = _gsplit and CLK()
        g = query_eq_levers(v, cblk, nil, TUNE.eqLazyCap, nil, classUsed)
        eqPass1N = #g
        if _gsplit then _gsplit("eq", _t0) end
      end
      -- CHORD slack-redistribution levers: relocate v along its wall using existing slack.
      -- Anchored on BOTH sides of the collision -- v's own chord and the blocker's chord
      -- (clearRoom still v), since the slack often lives on the blocker side.
      do
        local _t0 = _gsplit and CLK()
        for _, c in ipairs(query_cut_levers(v, cblk, v)) do g[#g + 1] = c end
        for _, c in ipairs(query_cut_levers(cblk, v, v)) do g[#g + 1] = c end
        if _gsplit then _gsplit("chord", _t0) end
      end
      if cdiag then          -- 45-degree wall: grow it without skewing it
        local _t0 = _gsplit and CLK()
        for _, c in ipairs(query_eq_2d_levers(v, cblk, nil, nil, v, "diag")) do g[#g + 1] = c end
        if _gsplit then _gsplit("eq2d:diag", _t0) end
      end
      do                     -- diagonal bridges as 2D plates (the 1D ones ride in `g` above)
        local _t0 = _gsplit and CLK()
        for _, c in ipairs(query_eq_2d_levers(v, cblk, nil, nil, v, "bridge")) do g[#g + 1] = c end
        if _gsplit then _gsplit("eq2d:bridge", _t0) end
      end
      -- Ring dilation (not gated on `cdiag`; the generator's own ring test is the gate). A ring
      -- plate whose exact move (`room:dx:dy` over the sorted set) duplicates an existing plate is
      -- dropped, since the ring copy would carry a different price for the same displacement.
      do
        local _t0 = _gsplit and CLK()
        local rd = query_ring_dilate_levers(v, cblk)
        if #rd > 0 then
          local function sig(c)
            local rs = {}
            for r in pairs(c.set or {}) do rs[#rs + 1] = r end
            table.sort(rs)
            local t = {}
            for i = 1, #rs do
              local dx, dy = cand_shift(c, rs[i])
              t[i] = rs[i] .. ":" .. dx .. ":" .. dy
            end
            return table.concat(t, ",")
          end
          local have = {}
          for _, c in ipairs(g) do if c.set then have[sig(c)] = c.ek or true end end
          for _, c in ipairs(rd) do
            local k = sig(c)
            if have[k] then
              elro._rdDup = (elro._rdDup or 0) + 1
            else
              have[k] = c.ek ; g[#g + 1] = c
            end
          end
        end
        if _gsplit then _gsplit("ring-dilate", _t0) end
      end
      if #g > 0 then
        local _t0 = _gsplit and CLK()
        elro._score_cands(coord, adj, v, v, cblk, g)
        for _, c in ipairs(g) do cands[#cands + 1] = c end
        elro._rank_cands(cands)
        if _gsplit then _gsplit("score+rank", _t0) end
      end
      if _gen0 then elro._genK = (elro._genK or 0) + (collectgarbage("count") - _genK0)
        elro._genT = (elro._genT or 0) + (CLK() - _gen0)
        elro._genN = (elro._genN or 0) + 1 end
    end
    -- JUNCTION preference: if v and its blocker are two branches diverging at J = LCA(v, blocker)
    -- in the placement tree, candidates that move a whole branch out at J rank first; the
    -- repel-field score breaks ties. A plain local collision falls back to rooms+dist ordering.
    local junctionJ, junctionBlk, junctionSpr, junctionChecked, junctionRole
    if cblk then
      junctionChecked = true                    -- the LCA lever ran (so we can print LCA=N/A on a miss)
      -- score every candidate by the LCA-junction repel field (v's branch vs the blocker's)
      local jd = junction_score(cands, v, cblk)
      if jd then
        junctionJ = jd.J ; junctionBlk = jd.isBlk ; junctionSpr = jd.spr ; junctionRole = jd.role
      end
    end
    if not junctionJ then
      elro.tr(string.format("NON-JUNCTION pull: v=%s blk=%s ckind=%s (lca %s) -> rooms+dist fallback",
        tostring(v), tostring(cblk), tostring(ckind),
        junctionChecked and ("returned nil: " .. tostring(elro._lcaReason)) or "not run (no blocker)"))
    end
    -- Pick the cheapest into-empty lever that does not drag an edge over a room. Extending the
    -- new room's own attach edge (u->v) is excluded: it just shoves v further out.
    local attachEk = ekey(u, v)
    local pick, nEmpty, nCross, nRE, nLie = nil, 0, 0, 0, 0
    local blockedX, blockedRE          -- best blocked candidate by defect KIND (least-severe tier)
    local ranked = {}   -- per-candidate outcome for the mapstep lever-choice dump, kept across escalations
    local escRound, escalateWhy
    local evaluated = {}   -- candidate table -> verdict, across passes (an escalation re-ranks the same tables)
    -- pre-pull crossing / room-on-edge sets are identical for every candidate: scan once here
    local _gud0 = elro.timeGuillo and CLK()
    local _gudK0 = _gud0 and collectgarbage("count")
    local beforeCross = crossing_set(v)
    local beforeRE = roomedge_set(v)
    -- Escalation stages. Pass 1 judges the candidates built above; if no clean pick, later passes
    -- regenerate eq-plates deeper and re-run the whole loop (rebuild + re-rank, not append).
    -- These flags live OUTSIDE the repeat or a stage re-fires forever.
    local deepTried = false
    local eqTried = false
    local eq2dTried, extra2d = false, {}   -- stage 2: two-axis completions of blocked candidates
    -- the cheap-side cap's per-CONFLICT state: reset so nothing leaks into the next conflict
    elro._eqSideCapHit, elro._eqSideNoCap = nil, nil
    elro._eqWalkAll = nil          -- the lazy seam walk's per-conflict re-ask (see the rung below)
    -- Re-angle is always held on pass 1; held candidates rejoin at the first escalation of any
    -- kind, or get a rung of their own if nothing else fires.
    local reHeld = true
    local reHeldAny = false
    repeat
    local escalate = false
    local eqCap
    -- option census: offered vs evaluated (guard-swept) vs picked, counted per pass
    elro._optGen = (elro._optGen or 0) + #cands
    elro._optSteps = (elro._optSteps or 0) + 1
    -- generation class: kind for non-eq candidates, the label suffix past `eq:<start>:<dir><mag>` for eq-plates
    local function optSuf(c)
      local k = tostring(c.kind)
      if k == "eq-plate" then
        local suf = tostring(c.ek):match("^eq:%-?%d+:%a+%d+(.*)$")
        if suf == nil then return "eq-plate/?" end
        return "eq" .. (suf == "" and "" or suf)
      end
      return k
    end
    local function optSufN(c, f)
      local S = elro._optSuf or {} ; elro._optSuf = S
      local cls = optSuf(c)
      local e = S[cls] ; if not e then e = { offered = 0, evaluated = 0, picked = 0 } ; S[cls] = e end
      e[f] = e[f] + 1
      -- the same census by plate size
      local N = c.n or (c.set and elro.tcount(c.set)) or 0
      local B = elro._optSize or {} ; elro._optSize = B
      local bk = (N <= 4 and "n_le4") or (N <= 16 and "n_le16") or (N <= 64 and "n_le64")
        or (N <= 256 and "n_le256") or "n_gt256"
      local b = B[bk] ; if not b then b = { offered = 0, evaluated = 0, picked = 0 } ; B[bk] = b end
      b[f] = b[f] + 1
    end
    for ci = 1, #cands do optSufN(cands[ci], "offered") end
    -- diagnostic (`timeGuillo`): does a seam-walk product (`:sf`/`:t`) ever score differently
    -- from its base plate? `maxGain` sizes the margin a lazy-walk skip rule would need.
    if elro.timeGuillo then
      local baseSc = {}
      for ci = 1, #cands do
        local d = cands[ci]
        if d.kind == "eq-plate" and optSuf(d) == "eq" and d.ek then baseSc[d.ek] = d.score end
      end
      for ci = 1, #cands do
        local c2 = cands[ci]
        local cls2 = optSuf(c2)
        if cls2 ~= "eq" and cls2:sub(1, 3) == "eq:" and c2.ek then
          local bek = tostring(c2.ek):match("^(eq:%-?%d+:%a+%d+)")
          local bs = bek and baseSc[bek]
          if bs then
            local W = elro._optWalkSc or { same = 0, diff = 0, worse = 0, best = 0, noBase = 0 }
            elro._optWalkSc = W
            local a2, b2 = c2.score or 0, bs
            if a2 == b2 then W.same = W.same + 1
            else
              W.diff = W.diff + 1
              if a2 > b2 then W.worse = W.worse + 1 else
                W.best = W.best + 1
                local imp = b2 - a2
                if imp > (W.maxGain or 0) then W.maxGain = imp
                  W.maxWho = tostring(c2.ek) .. string.format(" %.6g<-%.6g", a2, b2) end
              end
              if W.diff <= 6 then
                W[#W + 1] = string.format("%s %.6g vs base %.6g", tostring(c2.ek), a2, b2)
              end
            end
          elseif bek then
            local W = elro._optWalkSc or { same = 0, diff = 0, worse = 0, best = 0, noBase = 0 }
            elro._optWalkSc = W ; W.noBase = W.noBase + 1
          end
        end
      end
    end
    local stopAt
    -- a while, not a numeric for: a composed candidate is inserted right after its base
    local ci = 0
    while ci < #cands do
      ci = ci + 1
      local c = cands[ci]
      -- per-candidate yield point (the guard sweeps are where a step's cost varies); safe
      -- because nothing has been written to Mudlet yet
      elro.bg_tick("guard")
      elro._gudWho = "pick-loop"
      -- held: no guard sweep; `ranked` still gets a row
      if reHeld and c.kind == "re-angle" then
        reHeldAny = true
        evaluated[c] = "held(re-angle-lazy)"
        if #ranked < (tonumber(elro.stepRanked) or 40) then
          ranked[#ranked + 1] = { ek = c.ek, kind = c.kind, cost = c.cost, score = c.score,
                                  rooms = c.rooms, why = "held(re-angle-lazy)" }
        end
      else
      elro._optEval = (elro._optEval or 0) + 1
      optSufN(c, "evaluated")
      -- per-option cost, only while the trace records. CLK(), never os.clock (bg yields).
      local _c0 = elro.stepDebug and CLK()
      local why, whyDetail
      if not c.intoEmpty then why = "cascade" ; whyDetail = c.cascWhy
      else
        nEmpty = nEmpty + 1
        -- proper-crossing semantics: a room-on-edge endpoint touch is NOT a crossing and falls
        -- through to the room-on-edge guard below
        local _mc, _mcList = pull_makes_crossing(c, v, beforeCross)
        if _mc then nCross = nCross + 1 ; why = "makes-crossing" ; c.crossNew = _mcList
          if (c.pSep or 0) > 0 then local R = elro._sepRej or {} ; elro._sepRej = R ; R.cross = (R.cross or 0) + 1 end
        elseif c.ek == attachEk and (cEdgeW == nil or cEdgeW == u)
           -- exception: v sits on an edge the attach edge u->v is LICENSED to cross, so
           -- extending u->v across it takes the crossing the analysis reserved the gap for
           and not (cEdgeOn and ckind == "room-on-edge"
                    and elro._licPair and elro._licPair(u, v, cEdgeOn.u, cEdgeOn.v)) then
          -- conflict on the attach edge itself (or a plain overlap); on a back-edge conflict
          -- (cEdgeW ~= u) the extension stays available
          elro._attachVeto = (elro._attachVeto or 0) + 1
          why = "attach-edge" -- extension: skip (never a lone room)
        else
          -- overlap takes precedence over room-on-edge
          local lieKey
          local ov = pull_makes_overlap(c)
          if ov then why = "makes-overlap" ; whyDetail = "ov@" .. tostring(ov)
            if (c.pSep or 0) > 0 then local R = elro._sepRej or {} ; elro._sepRej = R ; R.overlap = (R.overlap or 0) + 1 end
          else
            -- a pull must not create a new room-on-edge / edge-on-room anywhere
            local re, reKey = pull_makes_roomedge(c, v, beforeRE)
            -- `elro.ringNoRider` (off here) and `closeSqRider` are separate knobs on purpose.
            if re then nRE = nRE + 1 ; why = "makes-room-on-edge" ; whyDetail = reKey
              if (c.pSep or 0) > 0 then local R = elro._sepRej or {} ; elro._sepRej = R ; R.roomedge = (R.roomedge or 0) + 1 end
            -- Truthfulness last in the chain (expensive), but it outranks every cosmetic win.
            -- The closure lets the second return reach `whyDetail` inside the elseif chain.
            elseif (function() local a, b = pull_makes_lie(c, v) ; lieKey = b ; return a end)() then
              nLie = nLie + 1 ; why = "makes-lie" ; whyDetail = lieKey
            elseif not pick and not pull_is_noop(c) then pick = c ; why = "PICKED"
              if elro.timeGuillo then
                elro._ekRank = (elro._ekRank or 0) + 1
                local T = cands._ekTie
                if T and c == cands[1] then
                  elro._ekTop = (elro._ekTop or 0) + 1
                  local C = elro._ekClass or {} ; elro._ekClass = C
                  C[T.cls] = (C[T.cls] or 0) + 1
                  if T.cls ~= "twin" then
                    local O = elro._ekOther or {} ; elro._ekOther = O
                    if #O < 60 then O[#O + 1] = string.format("room %s %s: %s", tostring(v), T.cls, T.ek) end
                  end
                end
              end
              -- applied 2D magnitude census (m2 plates do get adopted; keep eq2dCap at 2)
              if c.eq2dMag then
                local M = elro._e2mag or {} ; elro._e2mag = M
                M[c.eq2dMag] = (M[c.eq2dMag] or 0) + 1
              end
              if c.ek == attachEk then elro._attachPick = (elro._attachPick or 0) + 1 end
            elseif not pick then why = "no-op"
              whyDetail = ckind .. "@" .. tostring(cblk)
                .. (elro._noopWhy and (": " .. elro._noopWhy) or "")
            else why = "ranked-lower" end
          end
        end
      end
      -- Verdict tally: `ranked-lower` marks a well-ranked list.
      do
        local T = elro._optWhy or {} ; elro._optWhy = T
        local k = tostring(why)
        T[k] = (T[k] or 0) + 1
        if c.bridge then local Bw = elro._bsWhy or {} ; elro._bsWhy = Bw ; Bw[k] = (Bw[k] or 0) + 1 end
        if k == "PICKED" then
          optSufN(c, "picked")
          -- when a walk product is picked, where did its base plate rank among the base eq-plates?
          local cls = optSuf(c)
          if cls ~= "eq" and cls:sub(1, 3) == "eq:" then
            local baseEk = tostring(c.ek):match("^(eq:%-?%d+:%a+%d+)")
            local rank, pos, found = 0, 0, nil
            for cj = 1, #cands do
              local d = cands[cj]
              if d.kind == "eq-plate" and optSuf(d) == "eq" then
                rank = rank + 1
                if d.ek == baseEk and not found then found = rank ; pos = cj end
              end
            end
            -- the same rank shear-blind (score alone): count bases scoring strictly better
            local sbRank, sbTot = 1, 0
            do
              local bsc
              for cj = 1, #cands do
                local d = cands[cj]
                if d.kind == "eq-plate" and optSuf(d) == "eq" and d.ek == baseEk then
                  bsc = d.score ; break
                end
              end
              for cj = 1, #cands do
                local d = cands[cj]
                if d.kind == "eq-plate" and optSuf(d) == "eq" then
                  sbTot = sbTot + 1
                  if bsc and (d.score or 0) < bsc then sbRank = sbRank + 1 end
                end
              end
              -- score ties are common, so also size the tie group at the best score
              local best, tie = nil, 0
              for cj = 1, #cands do
                local d = cands[cj]
                if d.kind == "eq-plate" and optSuf(d) == "eq" then
                  local sc2 = d.score or 0
                  if not best or sc2 < best then best = sc2 end
                end
              end
              for cj = 1, #cands do
                local d = cands[cj]
                if d.kind == "eq-plate" and optSuf(d) == "eq" and (d.score or 0) == best then
                  tie = tie + 1
                end
              end
              local Z = elro._optWalkSB or {} ; elro._optWalkSB = Z
              local zk = "shear-blind base@" .. sbRank .. "/" .. sbTot .. " tie" .. tie
              Z[zk] = (Z[zk] or 0) + 1
            end
            local R = elro._optWalkRank or {} ; elro._optWalkRank = R
            local key = cls .. " base@" .. tostring(found or "absent") .. "/" .. rank .. (found and (" (list#" .. pos .. ", pick#" .. ci .. ")") or "")
            R[key] = (R[key] or 0) + 1
          end
        end
        -- kind x verdict
        local K = elro._optKind or {} ; elro._optKind = K
        local kk = tostring(c.kind) .. "/" .. k
        K[kk] = (K[kk] or 0) + 1
        -- the same tally for diagonal placements only
        if de and de[1] ~= 0 and de[2] ~= 0 then
          local D = elro._optDiag or {} ; elro._optDiag = D
          D[kk] = (D[kk] or 0) + 1
        end
      end
      -- A rigid 1D plate refused for the incidence it creates derives its own separation: a unit
      -- shift on the other axis, built on the post-plate geometry, seeded on the riding endpoint
      -- (deform), the victim (translate) or the standing edge's endpoint (landed). The two are
      -- composed into ONE graded candidate evaluated next, through every guard. Depth one: a
      -- composed candidate is never re-derived (seed for the collision, closure, one separation).
      if why == "makes-room-on-edge" and not c._composed and not c.deltas
         and (((c.dx or 0) ~= 0) ~= ((c.dy or 0) ~= 0)) then
        local vic, eu, ew = tostring(whyDetail):match("^(%d+)@(%d+):(%d+)")
        vic, eu, ew = tonumber(vic), tonumber(eu), tonumber(ew)
        local order, shp
        if vic and eu and ew then
          local inU, inW = c.set[eu], c.set[ew]
          if inU or inW then
            local ride = (inU and not inW) and eu or ((inW and not inU) and ew or eu)
            if inU and inW then shp = "translate" ; order = { { vic, ride }, { ride, vic } }
            else shp = "deform" ; order = { { ride, vic }, { vic, ride } } end
          elseif c.set[vic] then
            shp = "landed" ; order = { { eu, vic }, { vic, eu } }
          end
        end
        if order then
          local pa1 = ((c.dx or 0) ~= 0) and 1 or 2
          local perp = 3 - pa1
          local s1 = (pa1 == 1) and (c.dx * (c.dist or 0)) or (c.dy * (c.dist or 0))
          local saved = {}
          for r in pairs(c.set) do
            local p = coord[r] ; saved[r] = p
            coord[r] = (pa1 == 1) and { p[1] + s1, p[2] } or { p[1], p[2] + s1 }
          end
          rebuild_occ()
          local cls, mem = eqw_classes()
          local made = 0
          for _, pr in ipairs(order) do
            for _, s in ipairs({ 1, -1 }) do
              local mv = eqw_forced_shift(cls, mem, perp, pr[1], s, pr[2])
              if mv then
                local deltas, set, cnt = {}, {}, 0
                for r in pairs(c.set) do set[r] = true ; deltas[r] = (pa1 == 1) and { s1, 0 } or { 0, s1 } end
                for r in pairs(mv) do
                  local d = deltas[r]
                  if not d then d = { 0, 0 } ; deltas[r] = d ; set[r] = true end
                  d[perp] = d[perp] + s
                end
                for r, d in pairs(deltas) do
                  if d[1] == 0 and d[2] == 0 then deltas[r] = nil ; set[r] = nil end
                end
                for _ in pairs(set) do cnt = cnt + 1 end
                made = made + 1
                table.insert(cands, ci + made, { kind = "eq-plate", ek = tostring(c.ek) .. ":d" .. made,
                  set = set, deltas = deltas, dx = 0, dy = 0, dist = 0, cost = (c.cost or 0) + 1,
                  rooms = cnt, intoEmpty = true, score = c.score, eqStart = c.eqStart,
                  eqAnchor = c.eqAnchor, eqAxis = c.eqAxis, eqShift = c.eqShift,
                  _composed = true, derivedFrom = c.ek, derivedP2 = eq_ek(pr[1], perp, s, 1),
                  derivedShape = shp })
              end
            end
          end
          for r, q in pairs(saved) do coord[r] = q end
          rebuild_occ()
          elro._cdCompose = (elro._cdCompose or 0) + 1
          elro._cdComposeN = (elro._cdComposeN or 0) + made
        end
      end
      -- A forced lever (`elro.forceLever`, debugging only) overrides the guards; the verdict
      -- it stepped over is still carried into `whyDetail`.
      if c._forced and pick ~= c and why and why ~= "PICKED" and why ~= "ranked-lower" then
        whyDetail = whyDetail and (why .. " " .. tostring(whyDetail)) or why
        why = "FORCED-OVERRIDE"
        pick = c
        elro._flOverride = (elro._flOverride or 0) + 1
      end
      evaluated[c] = why
      if #ranked < (tonumber(elro.stepRanked) or 40) then
        ranked[#ranked + 1] = { ms = _c0 and (CLK() - _c0) * 1000,
          ek = c.ek, kind = c.kind, cost = c.cost, score = c.score,
          -- fixed field list: a new trace field must be added here AND at the not-evaluated snapshot
          pAbs = c.pAbs,
          repelE = c.repelE, stretchE = c.stretchE,   -- elro.repelDump: the two halves of the score
          rooms = c.rooms, roomsFull = c.roomsFull, artic = c.artic, why = why, shear = c.shear,
          artic2 = c.artic2, detail = whyDetail,
          crossNew = c.crossNew,
          shearEdges = c.shearEdges, seamTight = c.seamTight, seamFree = c.seamFree,
          seamEdges = c.seamEdges, seamAtMin = c.seamAtMin, seamGrow = c.seamGrow,
          rides = c.rides }
      end
      -- best blocked candidate of each kind, for the least-severe last resort (rank order,
      -- so the first is the best). Overlaps are never accepted deliberately.
      -- The last resort takes the blocked candidate moving the FEWEST rooms, not the best-ranked
      -- one: a deliberate defect wants the least collateral, and the ranking (re-angles last,
      -- seam keys) would hand it a 170-room plate over a one-room re-angle (world 435).
      local function lsPick(old, c2)
        if not old then return c2 end
        local a, b = old.roomsFull or old.rooms or 0, c2.roomsFull or c2.rooms or 0
        return (b < a) and c2 or old
      end
      if why == "makes-crossing" then blockedX = lsPick(blockedX, c)
      elseif why == "makes-room-on-edge" then blockedRE = lsPick(blockedRE, c) end
      -- Early-out at the first clean pick, under stepDebug too.
      end   -- held guard
      if pick then stopAt = ci ; break end
    end
    -- trace rows for the tail the break never reached (stepDebug only). Candidates already
    -- judged in an earlier pass collapse to one note line.
    if elro.stepDebug and stopAt then
      local nRe = 0
      for ci = stopAt + 1, #cands do
        local c = cands[ci]
        if evaluated[c] then nRe = nRe + 1
        elseif #ranked < (tonumber(elro.stepRanked) or 40) then
          -- `cascWhy` is set by the piston builder only; plate generators leave it nil
          local nwhy = "not-evaluated"
          if not c.intoEmpty then nwhy = "cascade/not-evaluated" end
          ranked[#ranked + 1] = { ek = c.ek, kind = c.kind, cost = c.cost, score = c.score,
            pAbs = c.pAbs, repelE = c.repelE, stretchE = c.stretchE,
            rooms = c.rooms, roomsFull = c.roomsFull, artic = c.artic, shear = c.shear,
            artic2 = c.artic2, shearEdges = c.shearEdges, seamTight = c.seamTight,
            seamFree = c.seamFree, seamEdges = c.seamEdges, seamAtMin = c.seamAtMin,
            seamGrow = c.seamGrow, rides = c.rides, why = nwhy, detail = c.cascWhy }
        end
      end
      if nRe > 0 then
        ranked[#ranked + 1] = { noteMark = true, text = string.format(
          "%d more candidate(s) below the pick were re-offered from an earlier pass -- verdicts above",
          nRe) }
      end
    end
    -- Escalation stages, cheapest first; each fires only when the loop found no clean pick.
    local liveNow = cblk and coord[v] and coord[cblk]
    -- 2D completion: a blocked 1D candidate carries eqStart/eqAnchor/eqAxis/eqShift, so the
    -- two-axis plate Part B would otherwise have to search for is built directly. Bounded by
    -- eq2dSeedCap, seeds taken in ranked order.
    if (not pick) and not eq2dTried and liveNow then
      -- generator time, billed to gen and taken off the guard bucket
      local _rg0 = _gud0 and CLK()
      eq2dTried = true
      local seen2d, tried2d, add = {}, 0, {}
      for _, c in ipairs(cands) do
        if tried2d >= TUNE.eq2dSeedCap then break end
        if c.eqStart and c.eqAxis and c.eqShift and not c.deltas then
          local k = c.eqAxis .. ":" .. c.eqStart .. ":" .. c.eqShift
          if not seen2d[k] then
            seen2d[k] = true ; tried2d = tried2d + 1
            -- dedup on the resulting move (ek), not the seed: different seeds complete to the same plate
            local seedN = c.roomsFull or c.rooms
            for _, g in ipairs(query_eq_2d_levers(v, cblk, nil, nil, v, "complete",
                                                  c.eqStart, c.eqAnchor, c.eqAxis, c.eqShift, seedN)) do
              if not seen2d[g.ek] then seen2d[g.ek] = true ; add[#add + 1] = g end
            end
          end
        end
      end
      -- A diagonal placement that collides always gets the 2D generator, seeded from the
      -- conflict pair itself (the 1D seeds above may be empty). Deduped through the same seen2d.
      if de and de[1] ~= 0 and de[2] ~= 0 and cblk then
        -- Seed u first (the structure v attaches to). Seed v as well only when v has an
        -- axial edge to a placed room: eqw_classes locks only along axial edges, so
        -- otherwise v's class is {v} and shifting it is merely re-placing v.
        local vAxial = false
        for d2, w2 in each_exit(adj[v]) do
          local de2 = DELTA[d2]
          if placed[w2] and de2 and ((de2[1] ~= 0) ~= (de2[2] ~= 0)) then vAxial = true ; break end
        end
        if vAxial then elro._eq2dSeedV = (elro._eq2dSeedV or 0) + 1
        else elro._eq2dSeedVSkip = (elro._eq2dSeedVSkip or 0) + 1 end
        local svs = vAxial and { u, v } or { u }
        -- the direction is `de`: the blocker's side travels with v, the parent's side opposite
        local dx = (de[1] > 0) and 1 or -1
        local dy = (de[2] > 0) and 1 or -1
        local frames = {}
        for _, sv in ipairs(svs) do
          if sv then
            frames[#frames + 1] = { cblk, sv, dx, dy }
            frames[#frames + 1] = { sv, cblk, -dx, -dy }
          end
        end
        for _, fr in ipairs(frames) do
          for ax = 1, 2 do
            local sgList = fr[3] and { (ax == 1) and fr[3] or fr[4] } or { 1, -1 }
            for _, sg in ipairs(sgList) do
              -- same key shape as the candidate-derived seeds above, so they dedup
              local k = ax .. ":" .. fr[1] .. ":" .. sg
              if not seen2d[k] then
                seen2d[k] = true
                -- and the FANNED axis is pinned to the same diagonal (nil = full fan)
                local oSg = fr[3] and ((ax == 1) and fr[4] or fr[3]) or nil
                for _, g in ipairs(query_eq_2d_levers(v, cblk, nil, nil, v, "complete",
                                                      fr[1], fr[2], ax, sg, nil, oSg)) do
                  if not seen2d[g.ek] then seen2d[g.ek] = true ; add[#add + 1] = g end
                end
              end
            end
          end
        end
      end
      if #add > 0 then
        escalate = true ; escalateWhy = "2D completions added"
        elro._eq2dEsc = (elro._eq2dEsc or 0) + 1
        for _, g in ipairs(add) do extra2d[#extra2d + 1] = g end
      end
      if _rg0 then
        local d = CLK() - _rg0
        elro._regenT = (elro._regenT or 0) + d ; elro._regenN = (elro._regenN or 0) + 1
        elro._genT = (elro._genT or 0) + d
        _gud0 = _gud0 + d
      end
    end
    if (not pick) and elro.eqWalkLazy ~= false and not elro._eqWalkAll and liveNow and eqPass1N == 0 then
      -- pass 1 emitted no eq plate, so no walk was held: the rung would repeat pass 1's
      -- generator call verbatim. Skip it, but walk everything at the deeper rungs as it would have.
      elro._eqWalkAll = true
      elro._eqWalkEscSkip = (elro._eqWalkEscSkip or 0) + 1
    end
    if (not pick) and elro.eqWalkLazy ~= false and not elro._eqWalkAll and liveNow then
      -- eqWalkLazy: pass 1 walked only the bases tied at the best score; now walk them all
      elro._eqWalkAll = true ; escalate = true ; eqCap = eqCap or TUNE.eqLazyCap
      escalateWhy = "no clean pick -> the HELD seam walks"
      elro._eqWalkEsc = (elro._eqWalkEsc or 0) + 1
    elseif (not pick) and not eqTried and liveNow then
      eqTried = true ; escalate = true ; eqCap = TUNE.eqGuilloCap
      escalateWhy = "no clean pick -> eq plates generated"
      elro._eqLazyN = (elro._eqLazyN or 0) + 1
    elseif (not pick) and not deepTried
      and TUNE.eqGuilloDeep > TUNE.eqGuilloCap and liveNow then
      eqTried, deepTried = true, true ; escalate = true ; eqCap = TUNE.eqGuilloDeep
      escalateWhy = "still no clean pick -> eq plates at the DEEP magnitude cap"
      elro._eqDeepN = (elro._eqDeepN or 0) + 1
    elseif (not pick) and elro._eqSideCapHit and not elro._eqSideNoCap and liveNow then
      -- a mirror-side plate aborted on the cap and nothing clean was picked: re-run uncapped
      elro._eqSideNoCap = true ; escalate = true ; eqCap = eqCap or TUNE.eqGuilloCap
      escalateWhy = "no clean pick and a mirror plate was CAPPED -> eq plates re-generated uncapped"
      elro._eqSideCapRetry = (elro._eqSideCapRetry or 0) + 1
    elseif (not pick) and reHeld and reHeldAny and liveNow then
      -- the last rung: nothing else left to try, so the held re-angles get their sweep
      escalate = true ; escalateWhy = "held re-angles RELEASED (last rung)"
      elro._reLazyEsc = (elro._reLazyEsc or 0) + 1
    end
    -- a held re-angle rejoins the list at the first escalation of any kind (no extra pass)
    if escalate and reHeld then
      reHeld = false
      if reHeldAny then elro._reLazyJoin = (elro._reLazyJoin or 0) + 1 end
    end
    if escalate then
      -- the regeneration is generator time: billed to gen and subtracted from guards
      local _rg0 = _gud0 and CLK()
      local keep = {}
      for _, c in ipairs(cands) do if c.kind ~= "eq-plate" then keep[#keep + 1] = c end end
      -- eqCap is nil on a 2D-only escalation: nothing to regenerate, the eq plates we stripped are
      -- simply put back and the completions join them.
      local dg = eqCap and query_eq_levers(v, cblk, nil, eqCap) or {}
      if not eqCap then
        for _, c in ipairs(cands) do if c.kind == "eq-plate" then dg[#dg + 1] = c end end
      end
      for _, g in ipairs(extra2d) do dg[#dg + 1] = g end
      extra2d = {}
      if #dg > 0 then elro._score_cands(coord, adj, v, v, cblk, dg) end
      for _, c in ipairs(dg) do keep[#keep + 1] = c end
      cands = keep
      if _rg0 then
        local d = CLK() - _rg0
        elro._regenT = (elro._regenT or 0) + d ; elro._regenN = (elro._regenN or 0) + 1
        elro._genT = (elro._genT or 0) + d          -- it IS generator time
        _gud0 = _gud0 + d                           -- ...so take it back off the guard bucket
      end
      -- Re-score the whole list, not just the new plates: junction_score overwrites every
      -- score with the repel-field energy, and mixing scales in one sort is a real effect.
      if cblk then junction_score(cands, v, cblk) end
      elro._rank_cands(cands)
      blockedX, blockedRE = nil, nil
      -- `ranked` is deliberately NOT reset: it is the trace of every pass.
      pick, nEmpty, nCross, nRE, nLie = nil, 0, 0, 0, 0
      escRound = (escRound or 0) + 1
      ranked[#ranked + 1] = { escMark = true, why = escalateWhy or "escalate",
                              round = escRound }
    end
    until not escalate
    if _gud0 then elro._gudK = (elro._gudK or 0) + (collectgarbage("count") - _gudK0)
      elro._gudT = (elro._gudT or 0) + (CLK() - _gud0)
      elro._gudN = (elro._gudN or 0) + 1 end
    tries[#tries + 1] = { kind = ckind, blocker = cblk, ncands = #cands, nEmpty = nEmpty,
      nCross = nCross, nRE = nRE, nLie = nLie,
      picked = pick and { kind = pick.kind, dist = pick.dist } or nil }
    if pick then
    note_class(pick)
    -- `:u` win census (timeGuillo): `over` = won against a verified plate in the same list,
    -- `alone` = the only plate. Totals are read from elro._walkPulls, which every commit path feeds.
    if elro.timeGuillo and pick.ek and pick.ek:sub(-2) == ":u" then
      local ver = false
      for _, c in ipairs(cands) do
        if c ~= pick and c.kind == "eq-plate" and c.ek and c.ek:sub(-2) ~= ":u" then
          ver = true ; break
        end
      end
      if ver then
        elro._eqUnvOver = (elro._eqUnvOver or 0) + 1
        local L = elro._eqUnvOverList or {} ; elro._eqUnvOverList = L
        if #L < 12 then L[#L + 1] = string.format("%s for %s", pick.ek, tostring(v)) end
      else
        elro._eqUnvAlone = (elro._eqUnvAlone or 0) + 1
      end
    end
    elro._walkPulls[#elro._walkPulls + 1] = { v = v, kind = pick.kind, ek = pick.ek,
      dx = pick.dx, dy = pick.dy, dist = pick.dist, rooms = pick.rooms }
    -- v's offset from its blocker before the pull: unchanged means v and the blocker moved
    -- together, so the shift is dead for this conflict (see classUsed).
    local offBefore = (cblk and coord[v] and coord[cblk])
      and { coord[v][1] - coord[cblk][1], coord[v][2] - coord[cblk][2] } or nil
    for r in pairs(pick.set) do
      local dx, dy = cand_shift(pick, r) ; coord[r] = { coord[r][1] + dx, coord[r][2] + dy }
    end
    if offBefore and (pick.kind == "class-shift" or pick.kind == "eq-plate")
       and pick.ek and coord[v] and coord[cblk]
       and coord[v][1] - coord[cblk][1] == offBefore[1]
       and coord[v][2] - coord[cblk][2] == offBefore[2] then
      classUsed["dead:" .. pick.ek] = true
      elro.tr(string.format("  dead class-shift %s for %d: blocker %d moved with it"
        .. " (offset unchanged) -- retired", tostring(pick.ek), v, cblk))
    end
    -- mapmargin: pad the gap only between different subcomponents; back off any padding
    -- cell that lands the moved set on a placed room.
    local margin = elro.pull_margin or 0
    if margin > 0 and cblk and branchOf[cblk] ~= branchOf[v] and not pick.deltas then   -- rigid pulls only (a graded chord has no single dx/dy to pad)
      for _ = 1, margin do
        for r in pairs(pick.set) do coord[r] = { coord[r][1] + pick.dx, coord[r][2] + pick.dy } end
        local bad = false
        for r in pairs(pick.set) do if cell_overlap(r) then bad = true ; break end end
        if bad then
          for r in pairs(pick.set) do coord[r] = { coord[r][1] - pick.dx, coord[r][2] - pick.dy } end
          break
        end
      end
    end
    local guillo = nil   -- no generator emits kind=="guillotine" any more
    local lbl = ("walk lever: " .. pick.kind .. " for " .. v ..
        " (" .. (pick.rooms or "?") .. "r dist " .. pick.dist .. ")")
    elro.step_snap(coord, lbl .. (junctionJ and (" [junction " .. tostring(junctionJ) .. "]") or ""), v, X,
      { ek = pick.ek, kind = pick.kind, cost = pick.cost, score = pick.score, cent = pick.cent,
        open = pick.open, rooms = pick.rooms, dist = pick.dist, guillo = guillo,
        artic = pick.artic, ckind = ckind, blocker = cblk, ranked = ranked,
        junction = junctionJ, junctionBlk = junctionBlk, jspr = junctionSpr, jchecked = junctionChecked, lcaReason = elro._lcaReason,
        roleMap = junctionRole })
    repair_after(v, cblk, pick)               -- phase-2 pendant repair, immediately after the move
    else
      -- LEAST-SEVERE LAST RESORT: nothing is clean and no pair was found, so the choice is
      -- which defect. A crossing (or failing that a room-on-edge) beats the collision v sits
      -- on. One shot, then leave the loop: re-entering would re-detect the deliberate defect.
      local fb, fbWhy = blockedX, "crossing"
      if not fb then fb, fbWhy = blockedRE, "room-on-edge" end
      if fb then
        take_least_severe(fb, fbWhy, ckind, cblk, ranked, beforeCross)
      end
      break
    end
  end
  add_edges(v)   -- register v's edges NOW so count_defects/block_split see them (dedups later)
  -- stuck re-check only when a conflict was actually detected this placement
  local stuck = hadConflict and
    (cell_overlap(v) or first_crossing_v(v) or edge_over_room_v(v) or room_on_pedge_v(v)) or false
  -- a sheared grid-X is not a leftover (see gridx_only); only when the quad's own
  -- diagonals are the sole remaining defect
  local gxOnly = false
  if stuck and not cell_overlap(v) and not edge_over_room_v(v)
     and not room_on_pedge_v(v) and gridx_only(v) then
    gxOnly, stuck = true, false
    elro._gxOnlyN = (elro._gxOnlyN or 0) + 1
  end
  -- a deferred conflict is not a leftover either: the verdict is taken again after the
  -- closures. Narrow like gxOnly: only when the sole remaining defect is a crossing.
  if stuck and closeDefer and not cell_overlap(v) and not edge_over_room_v(v)
     and not room_on_pedge_v(v) then
    stuck = false
  elseif closeDefer and not stuck then
    -- the loop broke on the deferral, so the detectors above never ran on a real conflict
  else
    closeDefer = nil          -- something worse is present; it was handled the ordinary way
  end
  -- CROSSING CONVERSION: v is still stuck on a room-on-edge inside a block proved non-planar,
  -- so take the crossing instead (see cross_convert). Runs after every tier that can still
  -- solve it cleanly. A successful conversion must not re-enter resolution: the residual it
  -- leaves IS a crossing, so `stuck` is re-read without first_crossing_v.
  local converted = stuck and cross_convert(v) or false
  if converted then
    stuck = cell_overlap(v) or edge_over_room_v(v) or room_on_pedge_v(v) or false
  end
  -- now the deferred deliberate defect, if v is still stuck. The crossing baseline is sampled
  -- here so the diff attributes only what this lever introduces.
  if pendingLS then
    if converted then
      elro._lsAvoided = (elro._lsAvoided or 0) + 1
      elro.tr(string.format("  least-severe %s for %s AVOIDED: the crossing conversion took it",
        pendingLS.fbWhy, tostring(v)))
    elseif stuck then
      local L = pendingLS
      take_least_severe(L.fb, L.fbWhy, L.ckind, L.cblk, L.ranked, crossing_set(v))
      stuck = cell_overlap(v) or first_crossing_v(v) or edge_over_room_v(v) or room_on_pedge_v(v)
    else
      elro._lsAvoided = (elro._lsAvoided or 0) + 1
      elro.tr(string.format("  least-severe %s for %s AVOIDED: the corner pair cleared it",
        pendingLS.fbWhy, tostring(v)))
    end
    pendingLS = nil
  end
  -- a room nothing could clear goes to leftover and surfaces in mapcaps
  local capIdx
  if stuck then
    leftover[v] = true
    local last = tries[#tries]
    elro._capLog = elro._capLog or {}
    capIdx = #elro._capLog + 1
    elro._capLog[#elro._capLog + 1] = { stage = "walk", A = u, room = v, dir = d, n = 1,
      kind = last and last.kind or "?", blocker = last and last.blocker or nil, tries = tries,
      reason = (not last and "no-conflict?")
        or (last.nEmpty == 0 and "no into-empty lever")
        or "into-empty levers all drag an edge over a room (structural/piston-group case) -- no corner pair found" }
  end
  mark(v) ; add_edges(v)
  -- STEP 2 (eqw constructive block): v may CLOSE one or more loops. Reconcile each
  -- BACK-EDGE (a placed neighbour other than the parent u) toward truthful with
  -- stitch_one (run-redistribution + tools). Fires ONLY for cyclic block rooms -- a
  -- pendant/tree room has only its parent placed, so this is a no-op there.
  local moved = false
  local closedRings = nil
  for d2, w in each_exit(adj[v]) do
    local de2 = DELTA[d2]
    if w ~= u and placed[w] and de2 and (de2[1] ~= 0 or de2[2] ~= 0) then
      local ekw = ekey(v, w)
      if not eqwReconciled[ekw] then
        eqwReconciled[ekw] = true
        local _cl0 = elro.timeGuillo and CLK()
        local _clK0 = _cl0 and collectgarbage("count")
        if eqw_close(v, w, { de2[1], de2[2] }) then moved = true end
        if _cl0 then elro._clK = (elro._clK or 0) + (collectgarbage("count") - _clK0)
          elro._clT = (elro._clT or 0) + (CLK() - _cl0)
          elro._clN = (elro._clN or 0) + 1 end
      end
    end
  end
  if moved then rebuild_occ() end
  -- the deferred conflict, re-checked after the closure. A survivor goes to leftover; it is
  -- not re-levered here (re-entering the conflict loop after mark(v) is a different machine).
  if closeDefer then
    -- name the survivor by kind, and whether it is the same one
    local sk, sb
    local sX = cell_overlap(v) ; if sX then sk, sb = "overlap", sX end
    if not sk then local _, sc = first_crossing_v(v) ; if sc then sk, sb = "cross", sc.u end end
    if not sk then local _, sr = edge_over_room_v(v) ; if sr then sk, sb = "edge-on-room", sr end end
    if not sk then local sv2 = room_on_pedge_v(v) ; if sv2 then sk, sb = "room-on-edge", sv2.u end end
    if sk then
      elro._dcLeft = (elro._dcLeft or 0) + 1
      local same = (sk == "cross" and sb == closeDefer.cu)
      elro._dcSame = (elro._dcSame or 0) + (same and 1 or 0)
      leftover[v] = true
      elro.tr(string.format("  walk: the deferred conflict on %s-%s SURVIVED its closure as"
        .. " %s@%s%s -- %s goes to leftover", tostring(v), tostring(closeDefer.w),
        sk, tostring(sb), same and " (THE SAME ONE -- the closure was not the repair)" or " (a DIFFERENT one)",
        tostring(v)))
    else
      elro._dcGone = (elro._dcGone or 0) + 1
      elro.tr(string.format("  walk: the deferred conflict on %s-%s went away with the closure"
        .. " -- the lever was never needed", tostring(v), tostring(closeDefer.w)))
    end
    closeDefer = nil
  end
  -- the interior can be dropped in now, against a container whose closures have run
  try_chunk(v)
  -- FLUSH = every placed neighbour sits exactly one step away along its exit's delta, i.e.
  -- v consumed whatever space was opened for it and left nothing behind.
  local flush = true
  for d2, w in each_exit(adj[v]) do
    local de2 = DELTA[d2]
    if placed[w] and de2 and (de2[1] ~= 0 or de2[2] ~= 0) then
      if coord[w][1] - coord[v][1] ~= de2[1] or coord[w][2] - coord[v][2] ~= de2[2] then
        flush = false ; break
      end
    end
  end
  -- The slack-redistribution passes that stood here are gone; a repair pass must own the
  -- damage it tidies (leave damage where the walk put it). Only the flush counter survives.
  if (mrFix or cpFix or moved) and not flush and elro.timeGuillo then
    elro._eqFlushN = (elro._eqFlushN or 0) + 1
  end
  -- stuck was decided before the closures ran, and they routinely repair it: re-read it.
  -- Can only clear the flag, never set it.
  if stuck and not (cell_overlap(v) or first_crossing_v(v)
                    or edge_over_room_v(v) or room_on_pedge_v(v)) then
    stuck = false
    leftover[v] = nil
    -- drop the leftover's mapcaps entry too, but only if it is still ours: the eqw block can
    -- append its own, and removing by stale index would delete somebody else's diagnostic.
    local e = capIdx and elro._capLog and elro._capLog[capIdx]
    if e and e.room == v and e.stage == "walk" then table.remove(elro._capLog, capIdx) end
    elro.tr(string.format("  walk: %d was STUCK, but the eqw closures cleared it -- not a leftover", v))
    elro._eqcUnstuck = (elro._eqcUnstuck or 0) + 1
  end
  -- whole-call total, BEFORE the step snapshot (whose deep coord copy is a stepDebug artefact and
  -- must not be charged to the placement).
  if _pr0 then local _pr1 = CLK()
    elro._prT = (elro._prT or 0) + (_pr1 - _pr0)
    elro._prN = (elro._prN or 0) + 1
    elro._prLast, elro._prLastRoom = _pr1, v    -- the gap clock: reuses this same stamp
    elro._prLastPhase = elro._wbPhase           -- ...and where the walk was when it stopped placing
    if hadConflict then elro._prCf = (elro._prCf or 0) + 1 end end
  elro.step_snap(coord, "walk: placed " .. v .. " off " .. u .. " " .. d ..
    (arteryRooms[v] and " [ARTERY]" or "") .. (stuck and " (STUCK -> leftover)"
      or (gxOnly and " (grid-X not square -- naive placement infeasible)" or "")),
    v, stuck or nil)
  repair_run()   -- phase-2 pendant repair, after the placement, on what the step's commits collected
end

-- runner half: once per walk step after the placement snap. Tighten the pendant side toward the
-- root by the growth; a colliding tighten goes through two_lever_search. <=2 attempts per step, once per edge.
function elro.repair_run(W)
  local DELTA, adj, apply_pull, cell_overlap, coord, edge_over_room_v, first_crossing_v, placed = W.DELTA, W.adj, W.apply_pull, W.cell_overlap, W.coord, W.edge_over_room_v, W.first_crossing_v, W.placed
  local pull_makes_lie, revert_pull, room_on_pedge_v, two_lever_search = W.pull_makes_lie, W.revert_pull, W.room_on_pedge_v, W.two_lever_search
  local edges = elro._repPending
  elro._repPending = nil
  if not edges or #edges == 0 then return end
  table.sort(edges, function(a, b) return a[3] > b[3] end)
  -- lazy biconnected-block set (rigidity is topological; once per call)
  local rg
  local function rigidset()
    if rg then return rg end
    local roomsL, radj = {}, {}
    for r in pairs(placed) do roomsL[#roomsL + 1] = r end
    for _, r in ipairs(roomsL) do
      radj[r] = {}
      for d, x in each_exit(adj[r]) do
        local de = DELTA[d]
        if placed[x] and de and (de[1] ~= 0 or de[2] ~= 0) then radj[r][d] = x end
      end
    end
    rg = {}
    for _, comp in ipairs(elro.blocks_adj(roomsL, radj)) do
      if #comp > 1 then for _, e in ipairs(comp) do rg[e[1]] = true ; rg[e[2]] = true end end
    end
    return rg
  end
  -- flood one side of the edge (a, forbidden other endpoint b): nil when it reaches b through
  -- any path but the a:b edge itself (= cycle) or exceeds the cap
  local function side(a, b)
    local Sv, ord, i = { [a] = true }, { a }, 1
    while i <= #ord do
      local y = ord[i] ; i = i + 1
      for d, z in each_exit(adj[y]) do
        local de = DELTA[d]
        if placed[z] and de and (de[1] ~= 0 or de[2] ~= 0) and not Sv[z] then
          if z == b then
            if y ~= a then return nil end          -- reached b around the edge: cycle
          else
            Sv[z] = true ; ord[#ord + 1] = z
            if #ord > 24 then return nil end
          end
        end
      end
    end
    return Sv, #ord
  end
  local done = 0
  for _, e in ipairs(edges) do
    if done >= 2 then break end
    local p, q = e[1], e[2]
    local RS = elro._repSeen ; if not RS then RS = {} ; elro._repSeen = RS end
    -- (no goto here: layout.lua runs in Mudlet's Lua 5.1)
    local live = placed[p] and placed[q] and coord[p] and coord[q] and not RS[e[5]]
    local S, nS, tip, root
    if live then
      local Sq, nq = side(q, p)
      local Sp, np2 = side(p, q)
      -- the side to MOVE is the pendant tree side; when both qualify take the smaller
      if Sq and (not Sp or nq <= np2) then S, nS, tip, root = Sq, nq, q, p
      elseif Sp then S, nS, tip, root = Sp, np2, p, q end
      -- arm-self-collision gate: a stretch on the arm containing the conflict pair is the move's own injected space; skip it
      if S and ((e[6] and S[e[6]]) or (e[7] and S[e[7]])) then
        elro._repSelfSkip = (elro._repSelfSkip or 0) + 1
        RS[e[5]] = true ; S = nil
      end
      if S then
        RS[e[5]] = true                            -- attempted (or consumed) once per relayout
      end
    end
    if S then
      local rgs = rigidset()
      for m2 in pairs(S) do if rgs[m2] then S = nil ; break end end
    end
    if S then
      local dxE = coord[root][1] - coord[tip][1]
      local dyE = coord[root][2] - coord[tip][2]
      local adx = (dxE < 0) and -dxE or dxE
      local ady = (dyE < 0) and -dyE or dyE
      -- tighten by the growth this move caused, never past the pre-move length; both re-measured now
      local exc = ((adx > ady) and adx or ady) - (elro.min_len(tip, root) or 1)
      local grow = ((adx > ady) and adx or ady) - e[4]
      if grow < exc then exc = grow end
      local ux = (adx >= ady) and ((dxE > 0) and 1 or -1) or 0
      local uy = (ady > adx) and ((dyE > 0) and 1 or -1) or 0
      -- axis-aligned targets only: a diagonal's excess is not free slack
      if adx > 0 and ady > 0 then exc = 0 end
      if exc > 0 then
        local P = { kind = "repair", ek = "rep:" .. tip .. ":" .. root .. ":" .. exc,
                    set = S, dx = ux, dy = uy, dist = exc, rooms = nS }
        if not pull_makes_lie(P) then
          apply_pull(P)
          local m
          for rm in pairs(S) do
            if cell_overlap(rm) then m = rm ; break end
            local _, ce2 = first_crossing_v(rm) ; if ce2 then m = rm ; break end
            local _, R2 = edge_over_room_v(rm) ; if R2 then m = rm ; break end
            if room_on_pedge_v(rm) then m = rm ; break end
          end
          if not m then
            -- a clean tighten is never committed: it relocates the pendant and leaves the lever's injected space as an enclosed hole
            revert_pull(P)
            elro._repCleanSkip = (elro._repCleanSkip or 0) + 1
          else
            revert_pull(P)
              do
            -- the induced conflict is the target: resolve it with two_lever_search, ranked on slack removed
            -- from the pendant (net > 0), measured by applying pull2 and re-measuring the pendant's over-min
            -- edges; net == 0 is pure relocation and is rejected.
            local Stree = {}
            for m2 in pairs(S) do Stree[m2] = true end
            Stree[root] = true
            local function pend_slack()
              local sl = 0
              for a2 in pairs(Stree) do
                for d2, b2 in each_exit(adj[a2]) do
                  local de2 = DELTA[d2]
                  if Stree[b2] and a2 < b2 and de2 and (de2[1] ~= 0 or de2[2] ~= 0)
                     and coord[a2] and coord[b2] then
                    local ex2 = coord[b2][1] - coord[a2][1] ; local ey2 = coord[b2][2] - coord[a2][2]
                    if ex2 < 0 then ex2 = -ex2 end ; if ey2 < 0 then ey2 = -ey2 end
                    local L = (ex2 > ey2) and ex2 or ey2
                    local over = L - (elro.min_len(a2, b2) or 1)
                    if over > 0 then sl = sl + over end
                  end
                end
              end
              return sl
            end
            local slack0 = pend_slack()          -- pull1 NOT applied yet here: the pre-repair slack
            -- the ranking is folded into the repair frame
            local rk, netPos = {}, {}
            local function repair_key(c2, combined, shearC)
              apply_pull(c2)
              local slack1 = pend_slack()
              revert_pull(c2)
              local net = slack0 - slack1
              local key = (net > 0) and (-net * 1e6 + elro._pref_key(combined, shearC)) or nil
              if key then netPos[#netPos + 1] = { c2, net, key } end
              rk[#rk + 1] = string.format("<%s>    %-22s slack %d->%d net=%+d energy=%.1f%s -> %s<reset>",
                key and "cyan" or "grey", tostring(c2.ek) .. "(" .. tostring(c2.kind) .. ")",
                slack0, slack1, net, combined or 0,
                (shearC and shearC ~= 0) and string.format(" shear=%+d", shearC) or "",
                key and "ranked" or "REJECT relocation")
              return key
            end
            local q2, mc, nt, nc, ck2 = two_lever_search(m, P, nil, {}, {}, 0, 1, nil, nil, repair_key)
            local pnd = elro._closeTracePending or {} ; elro._closeTracePending = pnd
            pnd[#pnd + 1] = string.format("<yellow>  [repair] %d:%d excess %d, pendant %dr {%s} -> "
              .. "conflict %s; pull2 pool %d, %d survived guards:<reset>", tip, root, exc, nS,
              (function() local t = {} ; for r2 in pairs(S) do t[#t + 1] = r2 end
                         table.sort(t) ; return table.concat(t, ",") end)(),
              tostring(m), nc or 0, nt or 0)
            for _, ln in ipairs(rk) do pnd[#pnd + 1] = ln end
            if q2 then
              apply_pull(P) ; apply_pull(q2)
              elro._pendRepN = (elro._pendRepN or 0) + 1
              elro._walkPulls[#elro._walkPulls + 1] = { v = tip, kind = "repair-1", ek = P.ek,
                dx = P.dx, dy = P.dy, dist = P.dist, rooms = P.rooms }
              elro._walkPulls[#elro._walkPulls + 1] = { v = tip, kind = "repair-2", ek = q2.ek,
                dx = q2.dx, dy = q2.dy, dist = q2.dist, rooms = q2.rooms }
              elro.step_snap(coord, string.format(
                "REPAIR pair: tightened %d:%d by %d (%dr) + %s(%s) cleared %s, combined %s",
                tip, root, exc, nS, tostring(q2.ek), tostring(q2.kind), tostring(m),
                mc and string.format("%.1f", mc) or "-"), tip, root)
              done = done + 1
            else
              -- repair cascade: take the net-positive pull2s in key order, find the residual conflict among what
              -- pull2 moved (or m), and search a pull3 with pull2 as the new pull1. <= 3 seeds.
              local best3, b2, bnet, bmc, tried3 = nil, nil, nil, nil, 0
              table.sort(netPos, function(a, b) return a[3] < b[3] end)
              for i = 1, math.min(#netPos, 3) do
                local c2 = netPos[i][1]
                apply_pull(P) ; apply_pull(c2)
                local m2
                for rm in pairs(c2.set or {}) do
                  if placed[rm] and coord[rm] then
                    if cell_overlap(rm) then m2 = rm ; break end
                    local _, ce3 = first_crossing_v(rm) ; if ce3 then m2 = rm ; break end
                    local _, R3 = edge_over_room_v(rm) ; if R3 then m2 = rm ; break end
                    if room_on_pedge_v(rm) then m2 = rm ; break end
                  end
                end
                if not m2 and cell_overlap(m) then m2 = m end
                revert_pull(c2)          -- two_lever_search applies its own pull1 (= c2)
                if m2 then
                  tried3 = tried3 + 1
                  local function key3(c3, combined3, shearC3)
                    apply_pull(c3)
                    local sl = pend_slack()
                    revert_pull(c3)
                    local net3 = slack0 - sl
                    if net3 <= 0 then return nil end
                    return -net3 * 1e6 + elro._pref_key(combined3, shearC3)
                  end
                  -- coord is post-P here; the search applies c2, ranks pull3s, reverts c2
                  local q3, mc3 = two_lever_search(m2, c2, nil, {}, {}, 0, 1, nil, nil, key3)
                  if q3 then
                    apply_pull(c2) ; apply_pull(q3)
                    local net3 = slack0 - pend_slack()
                    revert_pull(q3) ; revert_pull(c2)
                    pnd[#pnd + 1] = string.format("<cyan>    cascade: %s -> residual %s -> %s(%s) net=%+d energy=%.1f<reset>",
                      tostring(c2.ek), tostring(m2), tostring(q3.ek), tostring(q3.kind), net3, mc3 or 0)
                    if net3 > 0 and (not bnet or net3 > bnet or (net3 == bnet and (mc3 or 0) < (bmc or 0))) then
                      best3, b2, bnet, bmc = q3, c2, net3, mc3
                    end
                  else
                    pnd[#pnd + 1] = string.format("<grey>    cascade: %s -> residual %s -> no clean pull3<reset>",
                      tostring(c2.ek), tostring(m2))
                  end
                end
                revert_pull(P)
              end
              if best3 then
                apply_pull(P) ; apply_pull(b2) ; apply_pull(best3)
                elro._pendRepN = (elro._pendRepN or 0) + 1
                elro._repCascN = (elro._repCascN or 0) + 1
                elro._walkPulls[#elro._walkPulls + 1] = { v = tip, kind = "repair-1", ek = P.ek,
                  dx = P.dx, dy = P.dy, dist = P.dist, rooms = P.rooms }
                elro._walkPulls[#elro._walkPulls + 1] = { v = tip, kind = "repair-2", ek = b2.ek,
                  dx = b2.dx, dy = b2.dy, dist = b2.dist, rooms = b2.rooms }
                elro._walkPulls[#elro._walkPulls + 1] = { v = tip, kind = "repair-3", ek = best3.ek,
                  dx = best3.dx, dy = best3.dy, dist = best3.dist, rooms = best3.rooms }
                elro.step_snap(coord, string.format(
                  "REPAIR cascade: tightened %d:%d by %d (%dr) + %s(%s) + %s(%s), pendant slack net %+d",
                  tip, root, exc, nS, tostring(b2.ek), tostring(b2.kind),
                  tostring(best3.ek), tostring(best3.kind), bnet), tip, root)
                done = done + 1
              else
                elro._repDecl = (elro._repDecl or 0) + 1
                -- a FRAME, not just a tr line, so the ranking above is readable in mapstep
                elro.step_snap(coord, string.format(
                  "REPAIR declined %d:%d by %d: conflict at %s, no net-positive clean pull2 (resid=%s, %d/%d), cascade %d seed(s) no clean pull3",
                  tip, root, exc, tostring(m), tostring(ck2), nt or 0, nc or 0, tried3), tip, root)
              end
            end
            end
          end
        end
      end
    end
  end
end

function elro.try_chunk(W, v)
  local DELTA, add_edges, adj, cell_overlap, chunkDone, chunkOf, coord, edge_over_room_v = W.DELTA, W.add_edges, W.adj, W.cell_overlap, W.chunkDone, W.chunkOf, W.coord, W.edge_over_room_v
  local first_crossing_v, occ, pedges, placed, rebuild_occ, room_on_pedge_v, seenPE = W.first_crossing_v, W.occ, W.pedges, W.placed, W.rebuild_occ, W.room_on_pedge_v, W.seenPE
  if not chunkOf or not chunkOf[v] then return end
  for _, ci in ipairs(chunkOf[v]) do
    local C = elro._faceChunks[ci]
    if not chunkDone[ci] then
      local ready = placed[C.A] and coord[C.A]
      for _, r in ipairs(C.ring) do if not (placed[r] and coord[r]) then ready = false ; break end end
      -- Fit test is on real geometry: every target cell free and strictly inside the BUILT
      -- ring, and no interior edge crossing a wall.
      if ready then
        -- the container as a polygon, in the BUILT frame -- used by every test below
        local P = {}
        for i = 1, #C.ring do P[i] = coord[C.ring[i]] end
        -- target cells, in the built frame, anchored on the attachment room
        local tgt, free = {}, true
        local ax, ay = coord[C.A][1], coord[C.A][2]
        local lx, ly = C.loc[C.A] and C.loc[C.A][1] or C.rloc[C.A][1],
                       C.loc[C.A] and C.loc[C.A][2] or C.rloc[C.A][2]
        for r in pairs(C.rooms) do
          local x, y = ax + (C.loc[r][1] - lx), ay + (C.loc[r][2] - ly)
          tgt[r] = { x, y }
          -- `occ` also rasters edges (storing the source room id), so a cell is held by a
          -- ROOM only when that room's own coordinates are this cell.
          local o = occ[x .. ":" .. y]
          if o and not C.rooms[o] and coord[o] and coord[o][1] == x and coord[o][2] == y then
            free = false ; elro._chunkWhy = "cell " .. x .. "," .. y .. " held by room " .. o
            break
          end
        end
        -- every target strictly inside the BUILT ring (the container may have grown unevenly)
        if free then
          for r in pairs(C.rooms) do
            local inside, n = false, #P
            for i = 1, n do
              local p, q = P[i], P[(i % n) + 1]
              if (p[2] > tgt[r][2]) ~= (q[2] > tgt[r][2]) then
                local t = (tgt[r][2] - p[2]) / (q[2] - p[2])
                if tgt[r][1] < p[1] + t * (q[1] - p[1]) then inside = not inside end
              end
            end
            if not inside then
              free = false
              elro._chunkWhy = "room " .. r .. " lands outside the built ring"
              break
            end
          end
          -- no interior edge (the attach edge included) may cross a wall
          if free then
            for r in pairs(C.rooms) do
              for d2, w in each_exit(adj[r]) do
                local q = (C.rooms[w] and tgt[w]) or (w == C.A and coord[C.A])
                if q and DELTA[d2] then
                  for i = 1, #P do
                    local u1, u2 = P[i], P[(i % #P) + 1]
                    local o1 = ori(tgt[r][1], tgt[r][2], q[1], q[2], u1[1], u1[2])
                    local o2 = ori(tgt[r][1], tgt[r][2], q[1], q[2], u2[1], u2[2])
                    local o3 = ori(u1[1], u1[2], u2[1], u2[2], tgt[r][1], tgt[r][2])
                    local o4 = ori(u1[1], u1[2], u2[1], u2[2], q[1], q[2])
                    if o1 ~= 0 and o2 ~= 0 and o3 ~= 0 and o4 ~= 0
                       and ((o1 > 0) ~= (o2 > 0)) and ((o3 > 0) ~= (o4 > 0)) then
                      free = false
                      elro._chunkWhy = "edge " .. r .. "-" .. w .. " would cross a wall"
                      break
                    end
                  end
                end
                if not free then break end
              end
              if not free then break end
            end
          end
        end
        -- Two moments: NONE of the interior placed (face just closed) -- place it whole, gated
        -- by the geometric tests plus a land-clean check; ALL placed -- a repair, compared by
        -- defect count and reverted if worse; PART placed -- wait for the last room to ask again.
        local nPlaced = 0
        for r in pairs(C.rooms) do if placed[r] then nPlaced = nPlaced + 1 end end
        local early = (nPlaced == 0)
        local pending = (nPlaced > 0 and nPlaced < C.n)
        if pending then free = false end
        -- skip the two whole-map defect counts when the walk already matches the solve
        if free and not pending and not early then
          local same = true
          for r in pairs(C.rooms) do
            if coord[r][1] ~= tgt[r][1] or coord[r][2] ~= tgt[r][2] then same = false ; break end
          end
          if same then
            chunkDone[ci] = true ; elro._chunkSame = (elro._chunkSame or 0) + 1
            free = false
          end
        end
        -- The early snap must land clean by the engine's own detectors (foreign geometry may
        -- already run through the face): apply, then revert if any snapped room is defective.
        -- The revert must truncate `pedges` and clear its `seenPE` keys.
        if free and early then
          -- the face has just closed and the interior has not been walked yet: put it in
          local pe0 = #pedges
          for r in pairs(C.rooms) do
            coord[r] = tgt[r] ; placed[r] = true
            elro._bfGen = (elro._bfGen or 0) + 1
            elro._walkN = elro._walkN + 1 ; elro._walkOrder[r] = elro._walkN
            add_edges(r)
          end
          rebuild_occ()
          -- Only defects involving something OUTSIDE the interior (plus A) disqualify: a defect
          -- wholly inside the piece is translation-invariant and refusing the snap cannot remove
          -- it. cell_overlap stays strict either way.
          local function own(r) return r ~= nil and (C.rooms[r] or r == C.A) end
          local bad
          for r in pairs(C.rooms) do
            if cell_overlap(r) then bad = r ; break end
            local w, ce = first_crossing_v(r)
            if ce and not (own(w) and own(ce.u) and own(ce.v)) then bad = r ; break end
            local w2, R = edge_over_room_v(r)
            if R and not (own(w2) and own(R)) then bad = r ; break end
            local e = room_on_pedge_v(r)
            if e and not (own(e.u) and own(e.v)) then bad = r ; break end
          end
          if bad then
            for i = #pedges, pe0 + 1, -1 do
              local e = pedges[i]
              seenPE[ekey(e.u, e.v)] = nil
              pedges[i] = nil
            end
            for r in pairs(C.rooms) do coord[r] = nil ; placed[r] = nil end
            elro._bfGen = (elro._bfGen or 0) + 1
            rebuild_occ()
            chunkDone[ci] = true
            elro._chunkFail = (elro._chunkFail or 0) + 1
            free = false
          end
        end
        if free and early then
          chunkDone[ci] = true
          elro._chunkEarly = (elro._chunkEarly or 0) + 1
          elro.tr(string.format("facefit chunk: %d-room interior placed as ONE piece off %d, at"
            .. " face close", C.n, C.A))
          elro.step_snap(coord, string.format("facefit CHUNK: %d-room interior placed in one piece"
            .. " inside its just-closed face (off %d)", C.n, C.A), C.A)
        elseif free and not pending then
          local snap, moved = {}, 0
          -- No lie test needed: the snap reproduces the solve's geometry exactly, anchored on A.
          local b0, bOv, bRoe, bX = elro.count_defects(coord, placed, pedges)
          for r in pairs(C.rooms) do
            snap[r] = coord[r]
            if coord[r][1] ~= tgt[r][1] or coord[r][2] ~= tgt[r][2] then moved = moved + 1 end
            coord[r] = tgt[r]
          end
          rebuild_occ()
          local a0, aOv, aRoe, aX = elro.count_defects(coord, placed, pedges)
          if elro.state_worse(a0, aOv, aRoe, aX, b0, bOv, bRoe, bX) then
            for r, q in pairs(snap) do coord[r] = q end
            rebuild_occ()
            chunkDone[ci] = true
            elro._chunkFail = (elro._chunkFail or 0) + 1
            moved = nil
          end
          if moved then
          chunkDone[ci] = true
          elro._chunkN = (elro._chunkN or 0) + 1
          elro.step_snap(coord, string.format("facefit chunk: %d-room interior placed inside its"
            .. " solved face (off %d)", C.n, C.A), C.A)
          end
        elseif not pending and not chunkDone[ci] then    -- (already-in-place has set it, and is
                                                          --  not a refusal)
          chunkDone[ci] = true      -- the container is built and it does not fit: do not re-ask
          elro._chunkFail = (elro._chunkFail or 0) + 1
        end
      end
    end
  end
end
