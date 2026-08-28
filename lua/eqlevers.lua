-- Functions extracted from walk_branches (lua/walk.lua). Each takes the walk context table W,
-- populated by a shim in walk_branches at every call, and binds what it needs to locals.
-- Split out of walk.lua; see lua/modules.lua for the load order.

elro = elro or {}
local CLK = elro.clk or error("eqlevers.lua: lua/core.lua must be loaded first")
local TUNE = elro.TUNE or error("eqlevers.lua: lua/tune.lua must be loaded first")
local each_exit = elro.exits or error("eqlevers.lua: lua/core.lua must be loaded first")
local K = elro.k or error("eqlevers.lua: lua/keys.lua must be loaded first (see elro.modules)")
local ekey = K.edge
local RDHALF_ENV = os.getenv("RDHALF")
-- Read once at load, not per candidate: these sit inside the ring-dilation ranking loop.
local RDWATCH_ENV = os.getenv("RDWATCH")

-- Cascade two-lever search (last resort). `pull1` clears v's original conflict but lands the moved
-- set on another room (m, T). Apply pull1, find the new collision among the moved rooms (else v),
-- search a pull2 that clears it while leaving v and every moved room conflict-free. Scored on the
-- primary v-vs-blocker field at the final state plus summed stretch. Non-destructive.
-- Returns best, minC, ntried, ncands2, ckind2, m, T, minK.
-- Chord lever as a cut through the field: slide the subject along its wall on existing slack, adding
-- no net space. Seed the subject's gateway X (its nearest placed room on a cycle) by g along one axis
-- with the blocker anchored; the field compresses the nearest gap ahead of X and moves only what that
-- forces -- the greedy chord plan, with pendants riding by the rigid-pendant rule. Re-seeding a plate's
-- movers at the full g pushes the absorption one cut further out: the rigid-prefix fan. A plate is a
-- chord iff it moves nothing backward, sideways or past g, adds no drawn length, tips no square
-- truthful 45 and clears `clearRoom` without giving a clean mover a new defect. Candidates keep
-- `kind = "chord"` and the `chord:<axis>:<X>:<far>:<dir>:<g>` label (a sort key).
-- gwSubject = the room whose gateway is X; clearRoom = the room that must end up conflict-free;
-- ignore = rooms excluded from the gateway search; riders = rooms that ride X (nil for a lone room).
function elro.query_cut_levers(W, gwSubject, blk, clearRoom, ignore, riders)
  local DELTA, adj, bridge_forest, cell_overlap, coord, det_sweep, diag_skew_n = W.DELTA, W.adj, W.bridge_forest, W.cell_overlap, W.coord, W.det_sweep, W.diag_skew_n
  local edge_over_room_v, eqw_classes, eqw_forced_shift, first_crossing_v, placed, room_on_pedge_v = W.edge_over_room_v, W.eqw_classes, W.eqw_forced_shift, W.first_crossing_v, W.placed, W.room_on_pedge_v
  local out = {}
  local _t0 = elro.timeGuillo and CLK()
  local _tr0 = elro.stepDebug and CLK()    -- per-call ms for the mapstep plate-gen trace
  local builds0 = elro._cutBuilt or 0
  elro._cutBuilt = builds0
  local X
  local function done(why)
    if _tr0 then
      local eks = {}
      for _, c in ipairs(out) do eks[#eks + 1] = c.ek .. "(" .. c.rooms .. "r)" end
      local rp = elro._guilloTracePending or {} ; elro._guilloTracePending = rp
      rp[#rp + 1] = { header = string.format("query_cut_levers gw=%s blk=%s X=%s -> %d plate(s) [%s] %s, %d build(s) %.0fms",
        tostring(gwSubject), tostring(blk), tostring(X), #out, table.concat(eks, " "), why,
        elro._cutBuilt - builds0, (CLK() - _tr0) * 1000) }
    end
    if _t0 then
      local B = elro._cutBail ; if not B then B = {} ; elro._cutBail = B end
      local e = B[why] ; if not e then e = { t = 0, n = 0 } ; B[why] = e end
      e.t = e.t + (CLK() - _t0) ; e.n = e.n + 1
    end
    return out
  end
  if not (coord[gwSubject] and coord[clearRoom]) then return done("no-coord") end
  -- X: the nearest placed room on a cycle, by hops from the subject (ties by room id)
  local bf = bridge_forest()
  local comp, mem = bf.comp, bf.mem
  do
    local seen, frontier, hops = { [gwSubject] = true }, { gwSubject }, 0
    while #frontier > 0 and not X and hops < 64 do
      hops = hops + 1
      table.sort(frontier)
      local nxt = {}
      for _, r in ipairs(frontier) do
        local m = comp[r] and mem[comp[r]]
        if placed[r] and m and #m > 1 then X = r ; break end
        for d, w in each_exit(adj[r]) do
          local de = DELTA[d]
          if de and (de[1] ~= 0 or de[2] ~= 0) and placed[w] and coord[w] and not seen[w]
             and not (ignore and ignore[w]) then
            seen[w] = true ; nxt[#nxt + 1] = w
          end
        end
      end
      frontier = nxt
    end
  end
  if not X then return done("no-gateway") end
  local anchor = (blk and blk ~= X and placed[blk] and coord[blk]) and blk or nil
  local cls, mem2 = eqw_classes()
  local function clears() return not (cell_overlap(clearRoom) or first_crossing_v(clearRoom)
    or edge_over_room_v(clearRoom) or room_on_pedge_v(clearRoom)) end
  local function applyD(deltas, sign)
    for r, e in pairs(deltas) do local p = coord[r] ; coord[r] = { p[1] + sign * e[1], p[2] + sign * e[2] } end
  end
  -- the lowest-id stationary room a mover's axial edge along `axis` leads to: the label's far end
  local function farOf(set, axis)
    local far
    for r in pairs(set) do
      for d, w in each_exit(adj[r]) do
        local de = DELTA[d]
        if de and de[axis] ~= 0 and de[3 - axis] == 0 and placed[w] and coord[w] and not set[w]
           and (not far or w < far) then far = w end
      end
    end
    return far
  end
  local planSeen = {}
  local function rej_count(k)
    if not _t0 then return end
    local R = elro._cutRej ; if not R then R = {} ; elro._cutRej = R end
    R[k] = (R[k] or 0) + 1
  end
  local function accept(set, deltas, axis, dir, g, fan)
    for _, e in pairs(deltas) do
      if e[3 - axis] ~= 0 or e[axis] * dir <= 0 or e[axis] * dir > g then return false, "shape" end
    end
    local ks, n = {}, 0
    for r in pairs(deltas) do n = n + 1 ; ks[n] = r end
    table.sort(ks)
    for i = 1, n do ks[i] = ks[i] .. "=" .. deltas[ks[i]][axis] end
    local sig = table.concat(ks, ",")
    if planSeen[sig] ~= nil then return planSeen[sig], "dup" end
    local pulls = { { set = set, dx = 0, dy = 0, dist = 0, deltas = deltas } }
    local _, _, _, dL = elro._stretch_energy(coord, adj, pulls, true)
    if dL > 0 then planSeen[sig] = false ; return false, "adds-length" end
    if diag_skew_n(deltas) > 0 then planSeen[sig] = false ; return false, "shear" end
    -- clearance first (one room), the per-mover audit only for a plate that clears
    applyD(deltas, 1)
    local good, rej = clears(), nil
    applyD(deltas, -1)
    if not good then rej = "no-clear"
    else
      local xi, rc, cen = det_sweep()
      local wasClean = {}
      for m in pairs(set) do wasClean[m] = not (cell_overlap(m, cen) or room_on_pedge_v(m, xi)
        or edge_over_room_v(m, rc) or first_crossing_v(m, xi)) end
      applyD(deltas, 1)
      xi, rc, cen = det_sweep()
      for m in pairs(set) do
        if wasClean[m] and (cell_overlap(m, cen) or room_on_pedge_v(m, xi)
                            or edge_over_room_v(m, rc) or first_crossing_v(m, xi)) then
          good = false ; rej = "new-defect" ; break
        end
      end
      applyD(deltas, -1)
    end
    planSeen[sig] = good
    if good then
      local far = farOf(set, axis) or X
      out[#out + 1] = { kind = "chord",
        ek = "chord:" .. axis .. ":" .. tostring(X) .. ":" .. tostring(far) .. ":" .. dir .. ":" .. g
          .. (fan and (":@" .. tostring(far)) or ""),
        dx = 0, dy = 0, dist = g, cost = g, rooms = elro.tcount(set),
        intoEmpty = true, set = set, deltas = deltas,
        isH = (axis == 1), chordAnchor = X }
    end
    return good, rej
  end
  -- an axial placed edge out of X along `axis` toward `dir`: without one the seed only translates
  local function ahead(axis, dir)
    for d, w in each_exit(adj[X]) do
      local de = DELTA[d]
      if de and de[3 - axis] == 0 and de[axis] * dir > 0 and placed[w] and coord[w] then return true end
    end
    return false
  end
  for axis = 1, 2 do
    for _, dir in ipairs({ 1, -1 }) do
      if ahead(axis, dir) then
      local prevVoid, twoVoidAt, prevIds, sameRun, twoSameAt = nil, nil, nil, 0, nil
      local nVoid, lastKind, flipAt = 0, nil, nil
      for g = 1, TUNE.chordMaxSteps do
        local sg = (axis == 1) and { dir * g, 0 } or { 0, dir * g }
        local seeds, gapOK, nPlans = nil, false, 0
        while nPlans <= TUNE.chordMaxPlans do   -- plan 0 is the greedy plate, the rest the fan
          elro.bg_tick("cut-plan")   -- one full closure build per plan; eqlevers had no tick at all
          elro._cutBuilt = (elro._cutBuilt or 0) + 1
          if nPlans > 0 then elro._cutFanBuilt = (elro._cutFanBuilt or 0) + 1 end
          local set, nm, deltas = eqw_forced_shift(cls, mem2, axis, X, sg, anchor, nil, seeds, nil, nil, nil,
            TUNE.chordPlateCap)
          if not set then
            -- a `cap` void says nothing about slack: it feeds no stop rule
            if nPlans == 0 and nm ~= "cap" then
              local k = tostring(nm)
              if k == prevVoid then twoVoidAt = twoVoidAt or g end
              prevVoid = k
              nVoid = nVoid + 1
              if lastKind == "A" then flipAt = flipAt or g end
              lastKind = "V"
            end
            if _t0 then
              local V = elro._cutVoid ; if not V then V = {} ; elro._cutVoid = V end
              local k = tostring(nm):gsub("@.*", "") ; V[k] = (V[k] or 0) + 1
            end
            break
          end
          if riders then
            for r in pairs(riders) do
              if not deltas[r] and coord[r] then set[r] = true ; deltas[r] = { sg[1], sg[2] } end
            end
          end
          local ok, rej = accept(set, deltas, axis, dir, g, nPlans > 0)
          if rej == "dup" then break end
          rej_count((ok and "ok" or rej) .. (nPlans > 0 and "(fan)" or ""))
          if ok then gapOK = true end
          if nPlans == 0 then
            prevVoid = nil
            if rej == "adds-length" and lastKind == "V" then flipAt = flipAt or g end
            lastKind = ok and "K" or (rej == "adds-length" and "A") or rej
            if rej == "adds-length" then
              local ids = {}
              for r in pairs(set) do ids[#ids + 1] = r end
              table.sort(ids)
              ids = table.concat(ids, ",")
              if ids == prevIds then
                sameRun = sameRun + 1
                if sameRun >= 2 then twoSameAt = twoSameAt or g end
              else sameRun = 0 end
              prevIds = ids
            else
              prevIds = nil ; sameRun = 0
            end
          end
          -- the fan runs only where the greedy plan failed on a moved room's new defect
          -- (every plan for a g moves X the same; they differ in who pays)
          if nPlans == 0 and rej ~= "new-defect" then break end
          -- fixpoint: every mover already at g, nothing ahead absorbed
          local allFull = true
          for r, e in pairs(deltas) do
            if not (riders and riders[r]) and e[axis] * dir < g then allFull = false ; break end
          end
          if allFull then break end
          seeds = {}
          for r in pairs(set) do if placed[r] and r ~= X then seeds[#seeds + 1] = r end end
          table.sort(seeds)
          nPlans = nPlans + 1
        end
        if gapOK then break end
        -- stop rules, each measured free across the corpus (no accepted plate ever followed
        -- one): two p0 voids, the same room set adding length at two consecutive g, or a
        -- void and an adds-length back to back -- larger g only repeats the failure
        if nVoid >= 2 or twoSameAt or flipAt then break end
      end
      end
    end
  end
  return done(#out > 0 and "(emitted)" or "nothing-clean")
end

-- The `:t` seam walk over one built base plate: walk the cut family while the plate grows and
-- stays buildable, keep the best cut (fewer sheared walls, then a bigger tightest face, then
-- that face crossed fewer times). One construction site for every caller that offers a `:t`
-- variant (the conflict generator, the loop closure, the ring tighten).
-- spec: cls, mem, pa, start, s, anchor, pin, occ, seeds (carried by every hop, the
-- `:sf:t` composition), hops (cap), tag (trace label), wkCls (timeGuillo class), swp (trace
-- sink or nil), lock (drop anchor-locked bind rooms from the seed list; default true).
-- Returns mvBest, nBest, info { seeds, abs, t, c, e, g, hops, stop, t0, bind0, locked }
-- or nil, nil, info when no hop beat the base seam.
function elro.seam_walk(W, spec)
  local class_seam, diag_skew_n, eqw_forced_shift = W.class_seam, W.diag_skew_n, W.eqw_forced_shift
  local cls, mem, pa, start, s, anchor = spec.cls, spec.mem, spec.pa, spec.start, spec.s, spec.anchor
  local pinAB, occB, baseSeeds, tag = spec.pin, spec.occ, spec.seeds, spec.tag
  local swp, _wkCls = spec.swp, spec.wkCls or "t"
  local hopCap = spec.hops or TUNE.classTightHops
  local function plate_shear(mvX)
    local D = {}
    for r in pairs(mvX) do D[r] = (pa == 1) and { s, 0 } or { 0, s } end
    return diag_skew_n(D)
  end
  -- walk-class build accounting (timeGuillo)
  local function wkAcc(k, t0, emitted)
    if not t0 then return end
    local T = elro._wkT or {} ; elro._wkT = T
    local e = T[k] ; if not e then e = { t = 0, n = 0, emit = 0 } ; T[k] = e end
    e.t = e.t + (CLK() - t0) ; e.n = e.n + 1
    if emitted then e.emit = e.emit + 1 end
  end
  local bmv, bn = spec.mv, spec.n
  local _wk0 = elro.timeGuillo and CLK()
  elro._inSeamWalk = true
  local t0, bind, c0
  -- the dragged base stays the reference
  local mvBest, nBest, tBest, cBest, nCur = nil, bn, nil, nil, bn
  local absBest, eBest, gBest, seedsBest = 0, nil, nil, nil
  local shBest = plate_shear(bmv)          -- the cut we start from
  local hops, noRun = 0, 0 ; local wkStop
  -- Anchor-locked bind rooms are dropped from the seed list (`seedable`); the edge still
  -- stretches and `class_seam` still prices it on the next hop.
  local anchorCls = cls[pa] and (cls[pa][anchor] or anchor) or anchor
  local locked = (spec.lock ~= false) and function(r)
    return (cls[pa] and (cls[pa][r] or r)) == anchorCls
  end or nil
  -- dedups: class_seam returns one entry per edge, so a room can appear twice
  local function seedable(b)
    local t, drop, seen = {}, 0, {}
    for _, r in ipairs(b) do
      if locked and locked(r) then drop = drop + 1
      elseif not seen[r] then seen[r] = true ; t[#t + 1] = r end
    end
    if drop > 0 then elro._ctLocked = (elro._ctLocked or 0) + 1 end
    return t
  end
  -- Seed accumulation: each hop closes over the accumulated seed set, so the boundary only
  -- ever moves outward.
  local acc, accSeen = {}, {}
  local function accum(b)
    for _, r in ipairs(b) do
      if not accSeen[r] then accSeen[r] = true ; acc[#acc + 1] = r end
    end
  end
  -- the tightest WALKABLE seam: anchor-locked bind rooms cannot form the tier
  t0, bind, c0 = class_seam(bmv, pa, s, nil, locked)
  tBest, cBest = t0, c0
  local bind0 = bind
  bind = bind and seedable(bind)
  if swp then
    swp(string.format("%s start: t0=%s bind={%s} seedable={%s}%s",
      tostring(tag), tostring(t0), bind0 and table.concat(bind0, ",") or "-",
      bind and table.concat(bind, ",") or "-",
      (bind0 and #bind0 > 0 and (not bind or #bind == 0)) and "  <- ALL ANCHOR-LOCKED, no walk" or ""))
  end
  while bind and #bind > 0 and hops < hopCap do
    hops = hops + 1
    elro._ctSeam = (elro._ctSeam or 0) + 1
    accum(bind)
    -- sorted: the seed list reaches `push` in order and must not depend on discovery order
    local useSeeds = {} ; for i = 1, #acc do useSeeds[i] = acc[i] end
    table.sort(useSeeds)
    if baseSeeds and #baseSeeds > 0 then
      -- base seeds FIRST (fixed order), then the walk's own; `push` dedups by class
      local u = {}
      for i = 1, #baseSeeds do u[#u + 1] = baseSeeds[i] end
      for i = 1, #useSeeds do u[#u + 1] = useSeeds[i] end
      useSeeds = u
    end
    local _b0 = elro.timeGuillo and CLK()
    local mv2, n2 = eqw_forced_shift(cls, mem, pa, start, s, anchor, nil, useSeeds,
                                     nil, pinAB, occB)
    wkAcc(_wkCls .. ":hop", _b0)
    -- A voided hop (`lock-*` or any `sep-*` code except `sep@a-b`) retries with the seedable
    -- subset: probe each bind room alone, keep the ones that build, rebuild with that subset.
    -- Void path only; bounded by #bind, but a `sep-loop` void is expensive to probe.
    local _subRetry = (n2 == "lock-drag" or n2 == "lock-seed" or n2 == "lock-sep")
    if not _subRetry and type(n2) == "string"
       and n2:find("^sep%-") ~= nil then
      _subRetry = true
      local S = elro._ssSep ; if not S then S = {} ; elro._ssSep = S end
      local k = n2:gsub("@.*", "")
      S[k] = (S[k] or 0) + 1
    end
    if not mv2 and _subRetry
       and #bind > 1 then
      local keep = {}
      local keepMv, keepN, keepAbs   -- the last surviving probe's build
      for _, r1 in ipairs(bind) do
        local one = {}
        for i = 1, #acc do if acc[i] ~= r1 then one[#one + 1] = acc[i] end end
        -- (the accumulated seeds minus this hop's tier, plus r1 alone)
        local probeSeeds = {}
        if baseSeeds then for _, r0 in ipairs(baseSeeds) do probeSeeds[#probeSeeds + 1] = r0 end end
        for _, r0 in ipairs(one) do
          local inTier = false
          for _, b in ipairs(bind) do if b == r0 then inTier = true ; break end end
          if not inTier then probeSeeds[#probeSeeds + 1] = r0 end
        end
        probeSeeds[#probeSeeds + 1] = r1
        local _p0 = elro.timeGuillo and CLK()
        local mvP, nP = eqw_forced_shift(cls, mem, pa, start, s, anchor, nil, probeSeeds,
                                         nil, pinAB, occB)
        wkAcc(_wkCls .. ":probe", _p0)
        if mvP then keep[#keep + 1] = r1 ; keepMv, keepN, keepAbs = mvP, nP, elro._cbLast end
      end
      if #keep > 0 and #keep < #bind then
        local sub = {}
        if baseSeeds then for _, r0 in ipairs(baseSeeds) do sub[#sub + 1] = r0 end end
        for i = 1, #acc do
          local inTier = false
          for _, b in ipairs(bind) do if b == acc[i] then inTier = true ; break end end
          if not inTier then sub[#sub + 1] = acc[i] end
        end
        for _, r1 in ipairs(keep) do sub[#sub + 1] = r1 end
        local _s0 = elro.timeGuillo and CLK()
        if #keep == 1 then
          -- one survivor: `sub` is that probe's seed list verbatim, so its build is the answer
          mv2, n2 = keepMv, keepN ; elro._cbLast = keepAbs
        else
          mv2, n2 = eqw_forced_shift(cls, mem, pa, start, s, anchor, nil, sub, nil, pinAB, occB)
        end
        wkAcc(_wkCls .. ":sub", _s0)
        if mv2 then
          useSeeds = sub
          elro._ctSubset = (elro._ctSubset or 0) + 1
          elro._ssKept = (elro._ssKept or 0) + 1
          if swp then swp(string.format("  hop %d: full tier voided; subset {%s} builds n=%s",
            hops, table.concat(keep, ","), tostring(n2))) end
        end
      end
    end
    local seedsThisHop = useSeeds        -- remembered for the winning cut (see :t:sf)
    local abs2 = elro._cbLast or 0   -- per-cut, and only the WINNING cut is emitted
    if swp then
      swp(string.format("%s hop=%d seeds={%s} -> %s n=%s (was %s)",
        tostring(tag), hops, table.concat(bind, ","), tostring(mv2 and "plate" or "VOID"),
        tostring(n2), tostring(nCur)))
    end
    local function hopK(k) elro._ctHop = elro._ctHop or {} ; elro._ctHop[k] = (elro._ctHop[k] or 0) + 1
      wkStop = k end
    if not mv2 then hopK("void:" .. tostring(n2):gsub("<%-.*", "")) ; break end
    if not (n2 and n2 > nCur) then hopK("no-grow") ; break end
    elro._ctTry = (elro._ctTry or 0) + 1
    local t2, b2, c2, e2, g2 = class_seam(mv2, pa, s, nil, locked)
    local sh2 = plate_shear(mv2)
    -- better = fewer sheared walls, then a bigger tightest face, then that face crossed fewer times
    local better = (sh2 < shBest)
      or (sh2 == shBest and (t2 > tBest or (t2 == tBest and c2 < cBest)))
    if swp then
      swp(string.format("  shear %s->%s  t %s->%s  nAtMin %s->%s  %s",
        tostring(shBest), tostring(sh2), tostring(tBest), tostring(t2),
        tostring(cBest), tostring(c2), better and "BETTER" or "no better"))
    end
    hopK(better and "BETTER" or (mvBest and "no-better(after best)" or "no-better"))
    if better then
      local H = mvBest and "recover" or "first"
      elro._ctSeq = elro._ctSeq or {}
      local kk = H .. ":" .. tostring(noRun)
      elro._ctSeq[kk] = (elro._ctSeq[kk] or 0) + 1
      noRun = 0
    else noRun = noRun + 1 end
    if better then
      mvBest, nBest, tBest, cBest, absBest = mv2, n2, t2, c2, abs2
      eBest, gBest, shBest = e2, g2, sh2 ; seedsBest = seedsThisHop
    end
    nCur, bind = n2, b2 and seedable(b2)
  end
  elro._ctWalks = (elro._ctWalks or 0) + 1
  wkAcc(_wkCls .. ":WALK", _wk0, mvBest ~= nil)
  elro._inSeamWalk = nil
  -- `_sntInert`: only meaningful if a drag was actually suppressed (the field form has none)
  if mvBest then elro._sntInert = (elro._sntInert or 0) + 1 end
  local info = { hops = hops, stop = wkStop, t0 = t0, bind0 = bind0, locked = locked }
  if not mvBest then return nil, nil, info end
  elro._ctEmit = (elro._ctEmit or 0) + 1
  -- report the emitted plate's seam unrestricted, as every other candidate does
  local tR, _, cR, eR, gR = class_seam(mvBest, pa, s)
  info.seeds, info.abs, info.t, info.c, info.e, info.g = seedsBest, absBest, tR, cR, eR, gR
  return mvBest, nBest, info
end

-- `pin`: see eqw_forced_shift.
function elro.query_eq_levers(W, A, B, clearSet, cap, pin, used)
  local DELTA, adj, cell_overlap, class_seam, coord, diag_companion, diag_skew_n, edge_over_room_v = W.DELTA, W.adj, W.cell_overlap, W.class_seam, W.coord, W.diag_companion, W.diag_skew_n, W.edge_over_room_v
  local eq_ek, eq_ek_inverse, eqw_classes, eqw_forced_shift, first_crossing_v, placed, plate_rides = W.eq_ek, W.eq_ek_inverse, W.eqw_classes, W.eqw_forced_shift, W.first_crossing_v, W.placed, W.plate_rides
  local query_eq_2d_levers, room_on_pedge_v = W.query_eq_2d_levers, W.room_on_pedge_v
  local out = {}
  -- Lazy seam walk (`elro.eqWalkLazy`, default on): defer every `:t`/`:sf` walk, score
  -- the bases, walk only the group tied at the best score. Heuristic, not a bound; the
  -- escalation re-asks with `elro._eqWalkAll` set when no clean pick exists.
  local deferWalk = (elro.eqWalkLazy ~= false and not elro._eqWalkAll) and {} or nil
  if not (coord[A] and coord[B] and placed[A] and placed[B]) then return out end
  local _t0 = elro.timeGuillo and CLK()
  -- separate clock for the mapstep trace line
  local _tr0 = elro.stepDebug and CLK()
  -- Magnitude cap (`TUNE.eqGuilloCap`); the deep tail is deferred to `TUNE.eqGuilloDeep`
  -- when the pick loop finds no clean candidate.
  local CAP = cap or TUNE.eqGuilloCap
  local cls, mem = eqw_classes()
  -- Clearance, same four detectors as query_block_levers, cheapest first (first_crossing_v
  -- is by far the most expensive). `clWhy`/`clX` name the refusing detector and pair;
  -- diagnostic only, and hash-order-dependent when clearSet holds several rooms.
  local clWhy, clX
  local function clear_one(r)
    if cell_overlap(r) then clWhy = "overlap" ; return false end
    local e = room_on_pedge_v(r)
    if e then clWhy = "room-on-edge"
      local function at(x) local c = coord[x] ; return tostring(x) .. (c and ("(" .. c[1] .. "," .. c[2] .. ")") or "") end
      clX = at(r) .. "@" .. at(e.u) .. ":" .. at(e.v) ; return false end
    local w0, R0 = edge_over_room_v(r)
    if w0 then clWhy = "edge-on-room" ; clX = tostring(R0) .. "@" .. tostring(r) .. ":" .. tostring(w0) ; return false end
    local w, ce = first_crossing_v(r)
    if w then
      clWhy = "crossing"
      -- name the pair: a crossing surfacing here is one nothing has licensed
      clX = tostring(r) .. "-" .. tostring(w) .. " x " .. tostring(ce.u) .. "-" .. tostring(ce.v)
      return false
    end
    return true
  end
  local function clear_now()
    clWhy, clX = nil, nil
    if clearSet then
      for r in pairs(clearSet) do
        if not clear_one(r) then return false end
      end
      return true
    end
    return clear_one(A)
  end
  -- batch occupancy index (`occIn`): geometry is frozen for the whole generator
  local occB = {}
  for r in pairs(placed) do
    local p = coord[r]
    if p then
      local k = p[1] * 1000003 + p[2] ; local l = occB[k]
      if l then l[#l + 1] = r else occB[k] = { r } end
    end
  end
  -- probe (timeGuillo): how often is this call a repeat at identical geometry? Counts only.
  if elro.timeGuillo then
    local fp = 0
    for r in pairs(placed) do
      local pc = coord[r]
      if pc then fp = (fp + r * 7919 + pc[1] * 131 + pc[2] * 17) % 2147483647 end
    end
    local cs = 0
    if clearSet then for r in pairs(clearSet) do cs = cs + r end end
    local k = A .. ":" .. B .. ":" .. tostring(cap) .. ":" .. tostring(pin) .. ":" .. cs .. ":" .. fp
    local M = elro._eqgMemo or {} ; elro._eqgMemo = M
    if M[k] then elro._eqgDup = (elro._eqgDup or 0) + 1 ; elro._eqgDupMark = true else M[k] = true end
  end
  -- Ping-pong guard: never offer the inverse of a shift already committed for this room,
  -- nor re-offer a `dead:` shift (one that moved v and its blocker by the same amount).
  -- Annotations are enumerated because the committed pick may have been a variant.
  local ANN = { "", ":sf", ":u", ":t", ":sf:t", ":t:sf" }   -- the two seam/shear compositions
  local function blocked(ek)
    if not used then return false end
    local inv = eq_ek_inverse(ek)
    for _, a in ipairs(ANN) do
      if (inv and used[inv .. a]) or used["dead:" .. ek .. a] then
        elro._eqPP = (elro._eqPP or 0) + 1
        return true
      end
    end
    return false
  end
  -- the protection set (the repeat-detector key uses `pin`'s tostring)
  local pinAB = { [A] = true, [B] = true }
  if pin then pinAB[pin] = true end
  local nVoid, nTried = 0, 0
  -- per-probe log lines (stepDebug): plate, verdict and `:r` sibling together
  local pLog = {}
  -- rigid-sibling census; one table, not three locals (LuaJIT's 200-local ceiling)
  local rC = { t = 0, v = 0, d = 0 }       -- rigid siblings: tried / voided / identical-to-base
  -- clearance refusals by detector, plus the first few crossing pairs
  local noClear, noClearX = {}, {}
  -- what A is sitting on before any plate moves; the magnitude gate below reads `baseWhy`
  local baseWhy, baseX
  if not clear_now() then baseWhy, baseX = clWhy, clX end
  -- A crossed wire is the one conflict that needs magnitude 2 (the rooms must end up past
  -- each other); scoped to a crossing base so no smaller plate exists for e2 to out-compete.
  local magMore = (baseWhy == "crossing") and 2 or 0
  local sideN = {}                       -- (pa, relative direction) -> smallest completed n
  local sideK = nil              -- retired cheap-side cap
  -- Probes: both framings of the conflict pair on both axes and signs, plus one probe per bridge
  -- on the block-cut path (the piston tier's enumeration): start = the bridge's far end, anchor =
  -- its near end, the sign pointing away from the anchor. The whole loop body (seam walks, :r,
  -- :u, escalation) then applies to bridge plates unchanged.
  local probes = {}
  for pa = 1, 2 do
    for _, sa in ipairs({ { A, B }, { B, A } }) do
      for _, sign in ipairs({ 1, -1 }) do
        probes[#probes + 1] = { pa = pa, start = sa[1], anchor = sa[2], sign = sign, isA = (sa[1] == A) }
      end
    end
  end
  local eq_ek0 = eq_ek
  do
    local BS = elro._bridgeSpecs
    if BS and ((BS.A == A and BS.B == B) or (BS.A == B and BS.B == A)) then
      for _, sp in ipairs(BS) do
        local a1, b1 = tostring(sp.ek):match("^(%d+):(%d+)")
        a1, b1 = tonumber(a1), tonumber(b1)
        if a1 and b1 and (sp.set[a1] ~= nil) ~= (sp.set[b1] ~= nil) then
          local far, near = (sp.set[a1] and a1 or b1), (sp.set[a1] and b1 or a1)
          -- the attach edge is never a lever (see the pick loop); diagonal bridges are 2D (not yet)
          if far ~= A and near ~= A and (sp.vx == 0 or sp.vy == 0) and coord[far] and coord[near] then
            probes[#probes + 1] = { pa = (sp.vx ~= 0) and 1 or 2, start = far, anchor = near,
              sign = (sp.vx ~= 0) and sp.vx or sp.vy, br = sp }
            elro._bsProbe = (elro._bsProbe or 0) + 1
          elseif sp.vx ~= 0 and sp.vy ~= 0 then
            elro._bsDiagSkip = (elro._bsDiagSkip or 0) + 1
          end
        end
      end
    end
  end
  for _, pr in ipairs(probes) do
    local pa, start, anchor, sign, brSpec = pr.pa, pr.start, pr.anchor, pr.sign, pr.br
    -- A bridge plate is the piston's rigid far side: every placed room of it is a seed of the
    -- SAME shift in a fresh build (seeding the far end alone lets the field leave the rest behind
    -- and stretch an edge instead). Sorted: the seed list reaches the builder in order.
    local brSeeds
    if brSpec then
      brSeeds = {}
      for r in pairs(brSpec.set) do
        if r ~= start and placed[r] and coord[r] then brSeeds[#brSeeds + 1] = r end
      end
      table.sort(brSeeds)
      if #brSeeds == 0 then brSeeds = nil end
    end
    -- bridge plates carry the near end in the label (`:b<near>`), so they never share a label
    -- with the conflict-pair probes; variants concatenate onto it as usual
    local eq_ek = brSpec and function(seed, axis, sg, mg, ann, sh)
      return eq_ek0(seed, axis, sg, mg, "b" .. anchor .. (ann and (":" .. ann) or ""), sh)
    end or eq_ek0
    -- a bridge plate's far side may carry the conflict pair (the piston's far side does); only the
    -- seed-at-A probes protect A/B from absorption
    local pinAB = (not brSpec) and pinAB or nil
    do
      do
        -- the mirror of (start=A, sign) is (start=B, -sign): same axis, same relative motion
        local relKey = brSpec and ("b" .. start .. ":" .. anchor .. ":" .. pa .. ":" .. sign)
          or (pa .. ":" .. (pr.isA and sign or -sign))
        local sideCapN = sideK and sideN[relKey] and math.floor(sideN[relKey] * sideK) or nil
        -- probe: is a void monotone in |s|? `postVoid`/`nonMono` count.
        local sawVoid = false
        -- magnitude-1 plate, kept for the unverified fallback
        local emitted, fbMv, fbN, fbAbs = false, nil, nil, 0
        local cascEmitted = false        -- bridge probe: one cascade seed per direction (piston contract)
        local capAborted = false                 -- a probe in THIS direction hit the cheap-side cap
        local emit_seam                          -- defined below; needs the per-magnitude locals
        local lastSeamStart                      -- the base walk's (tag,t0,bind): the :sf walk dedups against it
        -- a while, not a for: `magMore` extends the range
        local magCap = CAP + magMore
        -- a bridge sweeps like the piston it replaces: s1, s2, ... until it clears or voids, in the
        -- first pass -- the lazy cap would leave a bridge that needs s2 to the escalation rungs
        if brSpec and magCap < TUNE.eqGuilloCap then magCap = TUNE.eqGuilloCap end
        -- `maplever eq:<start>:<dir><mag>[@room]` (debugging): a forced label names a seed the
        -- sweep would not reach -- past this direction's cap, or past its first clearing shift.
        -- Build it too: the cap rises to the forced magnitude and the sweep does not stop early.
        local forcedMag
        if elro.forceLever and not brSpec then
          for ek, scope in pairs(elro.forceLever) do
            if scope == true or scope == elro._placingV then
              local fs, fd, fm = tostring(ek):match("^eq:(%d+):([nsew])(%d+)")
              if fs and tonumber(fs) == start then
                local fpa = (fd == "e" or fd == "w") and 1 or 2
                local fsg = (fd == "e" or fd == "n") and 1 or -1
                if fpa == pa and fsg == sign then forcedMag = math.max(forcedMag or 0, tonumber(fm)) end
              end
            end
          end
          if forcedMag and magCap < forcedMag then magCap = forcedMag end
        end
        local mag = 0
        -- pass 2: a direction that aborted on the cheap-side cap and emitted nothing re-runs uncapped
        for capPass = 1, 2 do
        if capPass == 2 then
          if not (capAborted and not emitted) then break end
          sideCapN = nil ; mag = 0 ; capAborted = false
          elro._eqSideCapRetry2 = (elro._eqSideCapRetry2 or 0) + 1
        end
        while mag < magCap do
          mag = mag + 1
          local s = sign * mag
          -- ping-pong guard per magnitude and label; a refused shift is not counted as a probe
          local skip = blocked(eq_ek(start, pa, sign, mag))
          local mv, n
          if not skip then
            mv, n = eqw_forced_shift(cls, mem, pa, start, s, anchor, nil, brSeeds, nil, pinAB, occB, sideCapN)
            if not mv and n == "cap" and sideCapN then
              elro._eqSideCapHit = true            -- the mirror side aborted on the cheap-side cap
              elro._eqSideCapN = (elro._eqSideCapN or 0) + 1
              capAborted = true
            end
            -- the cheap side is a side that built clean at this magnitude
            if mv and n and (not sideN[relKey] or n < sideN[relKey]) then sideN[relKey] = n end
          else
            n = "ping-pong"
          end
          if brSpec and not skip then
            local Bv = elro._bsVoid or {} ; elro._bsVoid = Bv
            local k = mv and "built" or ("void:" .. tostring(n):gsub("@.*", ""))
            Bv[k] = (Bv[k] or 0) + 1
          end
          local sepPrim = (not skip) and (elro._sepLast or 0) or 0
          local pSeeds = brSeeds               -- the :r sibling carries the far side too
          -- `_cbLast` is reset per eqw_forced_shift call; capture here
          local pAbs = (not skip) and (elro._cbLast or 0) or 0
          local pSep = (not skip) and (elro._sepLast or 0) or 0
          local pSepP
          if not skip and elro._sepPairs and #elro._sepPairs > 0 then
            pSepP = {} ; for i, e in ipairs(elro._sepPairs) do pSepP[i] = { e[1], e[2] } end
          end
          if not skip then nTried = nTried + 1 end
          local pRec
          if elro.stepDebug and not skip then
            pRec = { ek = eq_ek(start, pa, sign, mag) }
            pLog[#pLog + 1] = pRec
          end
          -- probe (timeGuillo): probes per magnitude
          if elro.timeGuillo then
            local P = elro._eqgMagP or {} ; elro._eqgMagP = P ; P[mag] = (P[mag] or 0) + 1
          end
          if sawVoid then elro._eqgPostVoid = (elro._eqgPostVoid or 0) + 1 end
          if not mv then nVoid = nVoid + 1 ; sawVoid = true
            if pRec then pRec.why = "VOID " .. tostring(n) end
            -- probe: which lock voided, at which magnitude
            if elro.timeGuillo then
              local W = elro._eqgWhy or {} ; elro._eqgWhy = W
              -- strip the `<-mover...` suffix so census keys stay aggregable
              local k = tostring(n):gsub("<%-.*", "")
              W[k] = (W[k] or 0) + 1
              if mag == 1 then W[k .. "@s1"] = (W[k .. "@s1"] or 0) + 1 end
            end
            -- a bridge extends until it clears or is BLOCKED: a void ends the direction (the sweep
            -- must not push the far side through the wall that stopped it)
            if brSpec and not skip then break end
          else
            if sawVoid then elro._eqgNonMono = (elro._eqgNonMono or 0) + 1 end
            if pRec then pRec.re = elro._ffReLast end
            if mag == 1 then fbMv, fbN, fbAbs = mv, n, pAbs end  -- for the unverified fallback below
        -- Seam walk (`:t`): elro.seam_walk over this base; emit the winning cut, then its `:t:r`
        -- sibling. `baseSeeds`: seeds every hop must carry (the `:sf:t` composition).
        -- plate_shear: truthful square diagonals a rigid 1D plate knocks off 45.
            local function plate_shear(mvX)
              local D = {}
              for r in pairs(mvX) do D[r] = (pa == 1) and { s, 0 } or { 0, s } end
              return diag_skew_n(D)
            end
            emit_seam = function(bmv, bn, tag, baseSeeds)
              local _wkCls = tag:find(":sf", 1, true) and "sf:t" or "t"
              -- probeSeam lines go to the mapstep frame
              local swp = elro.probeSeam and function(ln)
                local pnd = elro._closeTracePending or {} ; elro._closeTracePending = pnd
                pnd[#pnd + 1] = "<grey>  [seamwalk] " .. ln .. "<reset>"
              end
              local mvBest, nBest, wk = elro.seam_walk(W, { cls = cls, mem = mem, pa = pa, start = start,
                s = s, anchor = anchor, pin = pinAB, occ = occB, seeds = baseSeeds,
                mv = bmv, n = bn, tag = tag, wkCls = _wkCls, swp = swp })
              if not tag:find(":sf", 1, true) then
                lastSeamStart = { tag = tag, t0 = wk.t0, bind = wk.bind0, locked = wk.locked }
              end
              -- the trace row: what the walk did (a walk that dies on a pinned room says so here)
              if pRec then
                pRec.t = mvBest and string.format("E* (%d hop(s))", wk.hops)
                  or string.format("no plate after %d hop(s), stop=%s", wk.hops, tostring(wk.stop or "?"))
              end
              if not mvBest then return end
              local tBest, cBest, eBest, gBest, seedsBest, absBest = wk.t, wk.c, wk.e, wk.g, wk.seeds, wk.abs
              out[#out + 1] = { kind = "eq-plate", ek = tag .. ":t", pAbs = absBest,
                dx = (pa == 1) and sign or 0, dy = (pa == 2) and sign or 0,
                dist = mag, cost = mag, rooms = nBest, intoEmpty = true, set = mvBest,
                axis = pa, isH = (pa == 2),
                seamTight = (tBest < math.huge) and tBest or nil,
                seamFree = (tBest == math.huge) or nil, seamEdges = eBest,
                seamAtMin = cBest, seamGrow = gBest,
                eqStart = start, eqAnchor = anchor, eqAxis = pa, eqShift = s }
              -- `:t:r`: the 45-rigid rebuild of the walked cut, using the winning cut's seeds. One
              -- build, not a second walk; not recursive; strictly additive. Gated on the walked plate
              -- actually shearing, since `rigidAx` disables the field form's pass-1 cache.
              if plate_shear(mvBest) > 0 then
                elro._eqTrTry = (elro._eqTrTry or 0) + 1
                local _r0 = elro.timeGuillo and CLK()
                local mvR2, nR2 = eqw_forced_shift(cls, mem, pa, start, s, anchor, true, seedsBest,
                                                   nil, pinAB, occB)
                if _r0 then
                  local T = elro._wkT or {} ; elro._wkT = T
                  local k = _wkCls .. ":t:r"
                  local e = T[k] ; if not e then e = { t = 0, n = 0, emit = 0 } ; T[k] = e end
                  e.t = e.t + (CLK() - _r0) ; e.n = e.n + 1
                end
                local absR2 = elro._cbLast or 0   -- reset by every build; capture immediately
                if not mvR2 then elro._eqTrVoid = (elro._eqTrVoid or 0) + 1
                elseif nR2 == nBest then elro._eqTrDup = (elro._eqTrDup or 0) + 1 end
                if mvR2 and nR2 ~= nBest then
                  elro._eqTr = (elro._eqTr or 0) + 1
                  local t4, _, c4, e4, g4 = class_seam(mvR2, pa, s)
                  out[#out + 1] = { kind = "eq-plate", ek = tag .. ":t:r", pAbs = absR2,
                    dx = (pa == 1) and sign or 0, dy = (pa == 2) and sign or 0,
                    dist = mag, cost = mag, rooms = nR2, intoEmpty = true, set = mvR2,
                    axis = pa, isH = (pa == 2),
                    seamTight = (t4 < math.huge) and t4 or nil,
                    seamFree = (t4 == math.huge) or nil, seamEdges = e4,
                    seamAtMin = c4, seamGrow = g4,
                    eqStart = start, eqAnchor = anchor, eqAxis = pa, eqShift = s }
                end
              end
            end
            local _c0 = _t0 and CLK()
            local saved = {}
            for r in pairs(mv) do
              local p = coord[r] ; saved[r] = p
              coord[r] = (pa == 1) and { p[1] + s, p[2] } or { p[1], p[2] + s }
            end
            -- emit_rigid: the 45-rigid sibling. Also tried where the permissive plate failed
            -- clearance on a crossing (a sheared slant manufactures crossings); `mustClear` makes it
            -- earn its own verdict. `wantR` gate: no boundary square truthful diagonal means the
            -- rigid build is identical to the base.
            local function emit_rigid(mustClear)
                local wantR = false
                if mv then
                  elro._eqRigidTry = (elro._eqRigidTry or 0) + 1
                  for r2 in pairs(mv) do
                    local p2 = coord[r2]
                    if p2 then
                      for d2, x2 in each_exit(adj[r2]) do
                        local de2 = DELTA[d2]
                        if de2 and de2[1] ~= 0 and de2[2] ~= 0 and placed[x2] and coord[x2]
                           and not mv[x2] then
                          local gx2, gy2 = coord[x2][1] - p2[1], coord[x2][2] - p2[2]
                          if (gx2 == gy2 or gx2 == -gy2)
                             and gx2 * de2[1] >= 1 and gy2 * de2[2] >= 1 then
                            wantR = true ; break
                          end
                        end
                      end
                    end
                    if wantR then break end
                  end
                  if not wantR then elro._eqRigidSkip = (elro._eqRigidSkip or 0) + 1 end
                end
                if wantR then
                  rC.t = rC.t + 1
                  -- `pSeeds`, not nil: the sibling must be a variant of the plate actually on offer
                  local mvR, nR = eqw_forced_shift(cls, mem, pa, start, s, anchor, true, pSeeds,
                                                   nil, pinAB, occB)
                  -- name the void reason (`nR`)
                if not mvR then
                  rC.v = rC.v + 1
                  local w = rC.w ; if not w then w = {} ; rC.w = w end
                  local wk = tostring(nR):gsub("<%-.*", "")
                  w[wk] = (w[wk] or 0) + 1
                  if pRec then pRec.r = "VOID " .. wk end
                elseif nR == n then rC.d = rC.d + 1
                  if pRec then pRec.r = "same-as-base" end
                end
                  if mvR and nR ~= n and mustClear then
                    local sv = {}
                    for r2 in pairs(mvR) do
                      local p2 = coord[r2] ; sv[r2] = p2
                      coord[r2] = (pa == 1) and { p2[1] + s, p2[2] } or { p2[1], p2[2] + s }
                    end
                    local okR = clear_now()
                    for r2, c2 in pairs(sv) do coord[r2] = c2 end
                    if not okR then mvR = nil ; rC.n = (rC.n or 0) + 1
                    if pRec then pRec.r = "no-clear " .. tostring(clWhy) end
                  end
                  end
                  if mvR and nR ~= n then
                    -- captured after the rigid build; every build resets `_cbLast`/`_sepLast`
                    local rAbs, rSep = (elro._cbLast or 0), (elro._sepLast or 0)
                    local rT, rF, rE, rN, rG
                    do
                      local t0, _, nm, aE, gr = class_seam(mvR, pa, s)
                      rE, rN, rG = aE, nm, gr
                      if t0 < math.huge then rT = t0 else rF = true end
                    end
                    elro._eqRigidN = (elro._eqRigidN or 0) + 1
                  if pRec then pRec.r = mustClear and "E* (RESCUED the no-clear probe)" or "E*" end
                  if mustClear then rC.r = (rC.r or 0) + 1
                    elro._eqRigidNC = (elro._eqRigidNC or 0) + 1 end
                    out[#out + 1] = { kind = "eq-plate",
                      ek = eq_ek(start, pa, sign, mag) .. ":r", pAbs = rAbs, pSep = rSep,
                      dx = (pa == 1) and sign or 0, dy = (pa == 2) and sign or 0,
                      dist = mag, cost = mag, rooms = nR, intoEmpty = true, set = mvR,
                      axis = pa, isH = (pa == 2),
                      seamTight = rT, seamFree = rF, seamEdges = rE,
                      seamAtMin = rN, seamGrow = rG, rides = plate_rides(mvR),
                      eqStart = start, eqAnchor = anchor, eqAxis = pa, eqShift = s }
                  end
                end
            end
            local ok = clear_now()
            local baseWhyR = clWhy
            -- A bridge plate that resolves the A-B pair but lands A on ANOTHER room is what the
            -- piston tier emitted as a cascade seed (`cascade [occ@r]`); keep that path.
            local cascX
            if brSpec and not ok and not cascEmitted and clWhy == "overlap" then
              cascX = cell_overlap(A)
              if cascX == B or cascX == nil then cascX = nil end
            end
            if pRec then
              -- a bridge probe names what its plate did to the pair: the piston contract is
              -- "the far side moves rigidly", and the field form may leave B behind or carry A
              local brNote = ""
              if brSpec and not ok then
                brNote = string.format(" {%dr, A %s, B %s}", n or 0,
                  mv[A] and "moved" or "stayed", mv[B] and "moved" or "stayed")
              end
              pRec.why = ok and "E*"
                or (cascX and ("cascade seed [occ@" .. tostring(cascX) .. "]" .. brNote)
                or ("no-clear " .. tostring(clWhy) .. (clX and (" [" .. clX .. "]") or "") .. brNote))
            end
            if not ok then
              local k = clWhy or "?"
              noClear[k] = (noClear[k] or 0) + 1
              -- keep the first few pairs
              if clX and #noClearX < 3 then noClearX[#noClearX + 1] = clX end
            end
            for r, c in pairs(saved) do coord[r] = c end
            if _c0 then elro._eqgClT = (elro._eqgClT or 0) + (CLK() - _c0)
              elro._eqgClN = (elro._eqgClN or 0) + 1 end
            -- only where the refusal was a crossing
            if not ok and baseWhyR == "crossing" then emit_rigid(true) end
            if cascX then
              cascEmitted = true
              elro._bsCasc = (elro._bsCasc or 0) + 1
              out[#out + 1] = { kind = "eq-plate",
                ek = eq_ek(start, pa, sign, mag), pAbs = pAbs, pSep = pSep, sepPairs = pSepP,
                dx = (pa == 1) and sign or 0, dy = (pa == 2) and sign or 0,
                dist = mag, cost = mag, rooms = n, intoEmpty = false, set = mv,
                cascWhy = "occ@" .. tostring(cascX),
                axis = pa, isH = (pa == 2),
                eqStart = start, eqAnchor = anchor, eqAxis = pa, eqShift = s }
            end
            if ok then
              -- `intoEmpty = true` is honest: the separation pass guarantees room-vs-room clearance
              -- (not that v comes off an edge).
              if elro.probeMove then                  
                cecho(string.format("\n<cyan>[eqgen] %s  A=%s B=%s start=%s anchor=%s rooms=%d<reset>",
                  eq_ek(start, pa, sign, mag), tostring(A), tostring(B),
                  tostring(start), tostring(anchor), n))
              end
              if elro.timeGuillo then
                local E = elro._eqgMagE or {} ; elro._eqgMagE = E ; E[mag] = (E[mag] or 0) + 1
              end
              -- Known flaw: `class_seam` prices which edges stretch, not by how much, so a magnitude-2
              -- plate's seam is under-priced.
              local rides = plate_rides(mv)   -- display only; see plate_rides
              local seamT, seamF, seamE, seamN, seamG
              do
                local t0, _, nm, aE, gr = class_seam(mv, pa, s)
                seamE, seamN, seamG = aE, nm, gr
                if t0 < math.huge then seamT = t0 else seamF = true end
              end
              out[#out + 1] = { kind = "eq-plate",
                -- `pSep`: rooms the separation pass swallowed (trace only)
                ek = eq_ek(start, pa, sign, mag), pAbs = pAbs, pSep = pSep, sepPairs = pSepP,
                dx = (pa == 1) and sign or 0, dy = (pa == 2) and sign or 0,
                dist = mag, cost = mag, rooms = n, intoEmpty = true, set = mv,
                axis = pa, isH = (pa == 2),
                seamTight = seamT, seamFree = seamF, seamEdges = seamE,
                seamAtMin = seamN, seamGrow = seamG, rides = rides,
                eqStart = start, eqAnchor = anchor, eqAxis = pa, eqShift = s }
              -- The 45-rigid sibling: offer the rigid plate beside the permissive one, never instead
              -- of it. `n ~= nR` drops duplicates.
              emit_rigid(false)
              -- Square companion: a boundary square truthful diagonal r->x with |gx| == |gy| survives
              -- the shift iff sy = s * sigx * sigy, so the second component is derived, not searched.
              -- Square + truthful only; generalising to "any shear change" regresses.
              if true then
                local seedEk = out[#out].ek            -- the 1D plate emitted just above
                local wantS, wantO = false, false      -- companions sy = +s and sy = -s
                for r in pairs(mv) do
                  local pr = coord[r]
                  for d, x in each_exit(adj[r]) do
                    local de = DELTA[d]
                    if de and de[1] ~= 0 and de[2] ~= 0 and placed[x] and not mv[x] and coord[x] then
                      local gx, gy = coord[x][1] - pr[1], coord[x][2] - pr[2]
                      if gx ~= 0 and math.abs(gx) == math.abs(gy)
                         and gx * de[1] >= 1 and gy * de[2] >= 1 then
                        -- does THIS shift skew it? (only the moved end displaces)
                        local hx = (pa == 1) and (gx - s) or gx
                        local hy = (pa == 2) and (gy - s) or gy
                        if math.abs(hx) ~= math.abs(hy) then
                          if (gx > 0) == (gy > 0) then wantS = true else wantO = true end
                        end
                      end
                    end
                  end
                end
                -- fixed order, never `pairs` over a numeric key set: the plate list must not
                -- depend on hash order (see the LuaJIT hash-seed rule).
                for _, sy in ipairs({ wantS and s or false, wantO and -s or false }) do
                  if sy then
                    local sh2 = {} ; sh2[pa] = s ; sh2[3 - pa] = sy
                    for _, g in ipairs(query_eq_2d_levers(A, B, clearSet, nil, pin, "companion",
                                                          start, anchor, sh2)) do
                      -- the seed this companion derives from (junction_score floors its energy at it)
                      g.compSeedEk = seedEk
                      -- a companion may not drag more rooms than the seed it replaces
                      if (g.rooms or math.huge) <= n then
                      out[#out + 1] = g ; elro._eqCompN = (elro._eqCompN or 0) + 1
                      end
                    end
                  end
                end
              end
              -- Diagonal-equation plate: the companion generalised to the whole four-family closure,
              -- seeded from the 1D plate just emitted. Parity retry doubles the shift once.
              diag_companion(out, start, pa, s, anchor, mv, n, A, B, clear_now)
              -- rebuild the ek: diag_companion may have appended
              local baseEk = eq_ek(start, pa, sign, mag)
              -- probe: does an honest plate exist for a watched boundary edge?
              if elro.probeSeam and elro._brWatch then
                for w in pairs(elro._brWatch) do
                  if placed[w] and not mv[w] then
                    local mv3, n3 = eqw_forced_shift(cls, mem, pa, start, s, anchor, nil, { w },
                                                     nil, pinAB, occB)
                    print(string.format("[honest] %s + seed %s -> %s n=%s (base %s)",
                      baseEk, tostring(w), mv3 and "plate" or "VOID", tostring(n3), tostring(n)))
                  end
                end
              end
              -- Deferred closures close over this probe's locals; sound only because a generator moves
              -- nothing. Base walk first, then the sf reseed.
              if deferWalk then
                deferWalk[#deferWalk + 1] = { ek = baseEk, mv = mv, n = n, seam = emit_seam, seeds = brSeeds }
              else
                emit_seam(mv, n, baseEk, brSeeds)
              end
              emitted = true
              -- smallest clearing shift for this direction; larger is worse -- unless a forced
              -- label asks for a larger one
              if not (forcedMag and mag < forcedMag) then break end
            end
          end
        end
        end -- capPass
      end
    end
  end
  -- bridge plates: carry the piston's ranking fields (path position for the tie-break, artic)
  do
    local BS = elro._bridgeSpecs
    if BS then
      local byFN = {}
      for _, sp in ipairs(BS) do
        local a1, b1 = tostring(sp.ek):match("^(%d+):(%d+)")
        a1, b1 = tonumber(a1), tonumber(b1)
        if a1 and b1 then
          local far, near = (sp.set[a1] and a1 or b1), (sp.set[a1] and b1 or a1)
          byFN[far .. ":" .. near] = sp
        end
      end
      for _, c in ipairs(out) do
        local far, near = tostring(c.ek):match("^eq:(%d+):[nsew]+%d+:b(%d+)")
        local sp = far and byFN[far .. ":" .. near]
        if sp then c.hops, c.hopsA, c.artic, c.bridge = sp.hops, sp.hopsA, sp.artic, true
          elro._bsEmit = (elro._bsEmit or 0) + 1 end
      end
    end
  end
  -- Deferred walks: score the bases now, take the tie group at the best score, walk those.
  -- `_score_cands(coord, adj, A, A, B, ...)` is the call site's own call.
  if deferWalk and #deferWalk > 0 then
    local _w0 = elro.timeGuillo and CLK()
    -- score a copy: `_score_cands` sorts in place and `out`'s order is a tie-break contract
    local tmp = {}
    for i2 = 1, #out do tmp[i2] = out[i2] end
    elro._score_cands(coord, adj, A, A, B, tmp)
    -- the tie group is over the base plates, not over `out`
    local byEk = {}
    for _, c in ipairs(out) do if c.ek then byEk[c.ek] = c end end
    -- Walk the best base of EACH conflict-pair family (start room x axis; at most four) plus its
    -- ties, not the single best overall: the pre-score is stretch-only, so one small clean base
    -- held every other family's walk (world 329: eq:4:e1 never walked, no :t on the ranking).
    -- Bridge bases are walked only when they beat the best conflict-pair base.
    local best, bestOf = nil, {}
    for _, d in ipairs(deferWalk) do
      local b = byEk[d.ek]
      local sc = b and not b.bridge and b.score
      if sc then
        if not best or sc < best then best = sc end
        local k = tostring(b.eqStart) .. ":" .. tostring(b.eqAxis)
        if not bestOf[k] or sc < bestOf[k] then bestOf[k] = sc end
      end
    end
    local walked, held = 0, 0
    for _, d in ipairs(deferWalk) do
      local b = byEk[d.ek]
      local go = false
      if b and b.score then
        -- a bridge base that absorbed rooms in the separation pass is the one a walk can improve
        if b.bridge then go = (best ~= nil and b.score <= best) or (b.pSep or 0) > 0
        else go = (b.score == bestOf[tostring(b.eqStart) .. ":" .. tostring(b.eqAxis)]) end
      end
      if go then
        walked = walked + 1
        d.seam(d.mv, d.n, d.ek, d.seeds)
      else
        held = held + 1
      end
    end
    elro._wlWalk = (elro._wlWalk or 0) + walked
    elro._wlHeld = (elro._wlHeld or 0) + held
    if _w0 then elro._wlT = (elro._wlT or 0) + (CLK() - _w0) end
  end
  if _t0 and elro._eqgDupMark then
    elro._eqgDupT = (elro._eqgDupT or 0) + (CLK() - _t0) ; elro._eqgDupMark = nil
  end
  if _t0 then elro._eqgT = (elro._eqgT or 0) + (CLK() - _t0)
    elro._eqgN = (elro._eqgN or 0) + 1
    elro._eqgOut = (elro._eqgOut or 0) + #out ; elro._eqgVoid = (elro._eqgVoid or 0) + nVoid
    elro._eqgTry = (elro._eqgTry or 0) + nTried end
  -- `:u` duplicate census (timeGuillo): signature = sorted moved set plus displacement
  if elro.timeGuillo and #out > 1 then
    local sig, us = {}, nil
    for _, c in ipairs(out) do
      if c.set then
        local ids = {}
        for r in pairs(c.set) do ids[#ids + 1] = r end
        table.sort(ids)
        local k = table.concat(ids, ",") .. "|" .. tostring(c.dx) .. "," .. tostring(c.dy)
        c._uSig = k
        if c.ek and c.ek:sub(-2) == ":u" then us = us or {} ; us[#us + 1] = c
        else sig[k] = sig[k] or c end     -- first VERIFIED holder of this signature wins the slot
      end
    end
    for _, c in ipairs(us or {}) do
      local twin = sig[c._uSig]
      if twin then
        elro._eqUnvDup = (elro._eqUnvDup or 0) + 1
        local L = elro._eqUnvDupList or {} ; elro._eqUnvDupList = L
        if #L < 12 then L[#L + 1] = c.ek .. " == " .. tostring(twin.ek) end
      end
    end
  end
  if elro.stepDebug then
    local rp = elro._guilloTracePending or {} ; elro._guilloTracePending = rp
    local parts = {}
    for _, c in ipairs(out) do
      -- `sepN`: rooms the separation pass swallowed
      parts[#parts + 1] = c.ek .. "(" .. c.rooms .. "r"
        .. ((c.pSep and c.pSep > 0) and (",sep" .. c.pSep) or "") .. ")"
    end
    -- per-call ms; fixed detector order, never pairs
    local nc = {}
    for _, k in ipairs({ "overlap", "room-on-edge", "edge-on-room", "crossing", "?" }) do
      if noClear[k] then nc[#nc + 1] = k .. " " .. noClear[k] end
    end
    rp[#rp + 1] = { header = string.format("query_eq_levers A=%s B=%s%s -> %d plate(s) [%s] (%d probes, %d void%s)%s%s",
      tostring(A), tostring(B),
      -- what A was already sitting on
      baseWhy and (" base=" .. baseWhy .. (baseX and (" [" .. baseX .. "]") or "")) or "",
      #out, table.concat(parts, " "), nTried, nVoid,
      -- parenthesised: `..` binds tighter than `or`
      (((#nc > 0) and ("; no-clear: " .. table.concat(nc, ", ")) or "")
        .. ((rC.t > 0) and string.format("; :r %d tried, %d void%s, %d same-as-base%s",
                                         rC.t, rC.v, elro._whyList(rC.w), rC.d,
                                         ((rC.r or 0) > 0 or (rC.n or 0) > 0)
                                           and string.format(", %d RESCUED a no-clear probe (%d also refused)",
                                                             rC.r or 0, rC.n or 0) or "") or "")),
      (#noClearX > 0) and (" [" .. table.concat(noClearX, "; ") .. "]") or "",
      _tr0 and string.format(" %.0fms", (CLK() - _tr0) * 1000) or ""),
      lines = (#pLog > 0) and (function()
        local L = {}
        for i2 = 1, #pLog do
          local e = pLog[i2]
          L[#L + 1] = string.format("%-14s %s%s%s%s", tostring(e.ek), tostring(e.why or "?"),
            e.r and ("   :r " .. e.r) or "", e.t and ("   :t " .. e.t) or "",
            e.re and ("   " .. e.re) or "")
        end
        return L
      end)() or nil }
  end
  return out
end

-- Two-axis equation plates: eqw_forced_shift in 2D mode returns a union plate plus
-- per-room deltas, an ordinary graded candidate. Modes: "wedge" (one displacement, two
-- framings), "diag" (|sx| == |sy| with rigidDiag on, four signs), "complete", "companion".
function elro.query_eq_2d_levers(W, A, B, clearSet, cap, pin, mode, p1, p2, p3, p4, seedN, otherSg)
  local cell_overlap, coord, edge_over_room_v, eq_ek, eqw_classes, eqw_forced_shift, first_crossing_v, placed = W.cell_overlap, W.coord, W.edge_over_room_v, W.eq_ek, W.eqw_classes, W.eqw_forced_shift, W.first_crossing_v, W.placed
  local room_on_pedge_v, seam2d = W.room_on_pedge_v, W.seam2d
  local out = {}
  if not (coord[A] and coord[B] and placed[A] and placed[B]) then return out end
  local _t0 = elro.timeGuillo and CLK()
  -- separate clock for the mapstep trace line
  local _tr0 = elro.stepDebug and CLK()
  local CAP = cap or TUNE.eq2dCap
  local cls, mem = eqw_classes()
  -- clearance, split by detector as in query_eq_levers
  local clWhy, clX
  local function clear_one(r)
    if cell_overlap(r) then clWhy = "overlap" ; return false end
    local e = room_on_pedge_v(r)
    if e then clWhy = "room-on-edge"
      local function at(x) local c = coord[x] ; return tostring(x) .. (c and ("(" .. c[1] .. "," .. c[2] .. ")") or "") end
      clX = at(r) .. "@" .. at(e.u) .. ":" .. at(e.v) ; return false end
    local w0, R0 = edge_over_room_v(r)
    if w0 then clWhy = "edge-on-room" ; clX = tostring(R0) .. "@" .. tostring(r) .. ":" .. tostring(w0) ; return false end
    local w, ce = first_crossing_v(r)
    if w then
      clWhy = "crossing"
      -- name the pair
      clX = tostring(r) .. "-" .. tostring(w) .. " x " .. tostring(ce.u) .. "-" .. tostring(ce.v)
      return false
    end
    return true
  end
  local function clear_now()
    clWhy, clX = nil, nil
    if clearSet then
      for r in pairs(clearSet) do
        if not clear_one(r) then return false end
      end
      return true
    end
    return clear_one(A)
  end
  -- shared batch occupancy index (the `occIn` contract -- build it exactly as the shift does)
  local occB = {}
  for r in pairs(placed) do
    local p = coord[r]
    if p then
      local k = p[1] * 1000003 + p[2] ; local l = occB[k]
      if l then l[#l + 1] = r else occB[k] = { r } end
    end
  end
  local nTried, nVoid = 0, 0
  -- void reasons: build (chain returned nil), union, no-clear (built, refused), shear (rescued), cap
  local why = { build = 0, union = 0, ["no-clear"] = 0, shear = 0 }
  local noClear = {}                       -- the `no-clear` total, split by refusing detector
  -- the (start, anchor, shift) triples this mode wants to try
  local plan = {}
  local rg = true
  if mode == "complete" then
    -- complete: keep the blocked candidate's axis and shift, add the other axis.
    local start, anchor, ax, sh0 = p1, p2, p3, p4
    local other = 3 - ax
    -- Magnitude ascending; the emit loop stops a direction at its first clearing shift (the
    -- score prefers the bigger shove). `otherSg` restricts the fanned axis when the caller knows.
    local sgs = otherSg and { otherSg } or { 1, -1 }
    for _, sg in ipairs(sgs) do
      for m = 1, CAP do
        local sh = {}
        sh[ax] = sh0 ; sh[other] = sg * m
        plan[#plan + 1] = { start, anchor, sh, rigid = rg, dir = sg }
      end
    end
  elseif mode == "companion" then
    -- companion: one derived shift, no search
    plan[#plan + 1] = { p1, p2, { p3[1], p3[2] }, rigid = rg }
  elseif mode == "bridge" then
    -- Diagonal bridges on the anchor path (the piston tier's `:ne`-style moves): the far end
    -- seeded along the bridge's own diagonal, the near end pinned. Same contract as the 1D bridge
    -- probes in query_eq_levers.
    local BS = elro._bridgeSpecs
    if BS and ((BS.A == A and BS.B == B) or (BS.A == B and BS.B == A)) then
      for _, sp in ipairs(BS) do
        if sp.vx ~= 0 and sp.vy ~= 0 then
          local a1, b1 = tostring(sp.ek):match("^(%d+):(%d+)")
          a1, b1 = tonumber(a1), tonumber(b1)
          if a1 and b1 and (sp.set[a1] ~= nil) ~= (sp.set[b1] ~= nil) then
            local far, near = (sp.set[a1] and a1 or b1), (sp.set[a1] and b1 or a1)
            if far ~= A and near ~= A and coord[far] and coord[near] then
              local seeds = {}
              for r in pairs(sp.set) do
                if r ~= far and placed[r] and coord[r] then seeds[#seeds + 1] = r end
              end
              table.sort(seeds)
              if #seeds == 0 then seeds = nil end
              for m = 1, CAP do
                plan[#plan + 1] = { far, near, { sp.vx * m, sp.vy * m }, rigid = true,
                                    dir = "b" .. far .. ":" .. near, br = sp, seeds = seeds }
              end
              elro._bsProbe2d = (elro._bsProbe2d or 0) + 1
            end
          end
        end
      end
    end
  else
    for _, sa in ipairs({ { A, B }, { B, A } }) do
      for m = 1, CAP do
        for _, sg in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
          plan[#plan + 1] = { sa[1], sa[2], { sg[1] * m, sg[2] * m }, rigid = true,
                              dir = tostring(sa[1]) .. ":" .. sg[1] .. ":" .. sg[2] }
        end
      end
    end
  end
  -- `eq2dProbeCap`: the expensive side aborts mid-flood (`n == "cap"`); nothing retries it.
  local probeCap
  if mode == "complete" then probeCap = TUNE.eq2dProbeCap end
  local doneDir = {}
  for _, pl in ipairs(plan) do
   if not (pl.dir and doneDir[pl.dir]) then
    local start, anchor, sh = pl[1], pl[2], pl[3]
    -- No pin when the anchor is the blocker: the anchor is stationary, so absorbing v is the
    -- whole move. Adds candidates only; every plate still passes clear_now().
    local pinEff = pin
    if pin and B and anchor == B then
      pinEff = nil ; elro._eq2dPinFree = (elro._eq2dPinFree or 0) + 1
    end
    if pl.br then pinEff = nil end       -- a bridge plate's far side may carry the conflict pair
    local rigidUsed = pl.rigid           -- the rigidity the SURVIVING plate was actually built at
    local mv, n, dl = eqw_forced_shift(cls, mem, nil, start, sh, anchor, pl.rigid, pl.seeds, nil, pinEff, occB, probeCap)
    -- name the rigid tier's void
    if not mv then
      local wk = tostring(n):gsub("<%-.*", "")
      why.rigidW = why.rigidW or {}
      why.rigidW[wk] = (why.rigidW[wk] or 0) + 1
    end
    -- Rescues where every rigid build voided, strictly additive: first a rigid build with
    -- grid-X quad diagonals freed (`_gxFree`; a quad's shape is set by its axial walls, and
    -- `sheared_gridx` already treats a non-square quad as legitimate), then without the
    -- 45-lock at all.
    if not mv and pl.rigid and elro._gxAnyQuad() then
      elro._gxFree = true
      mv, n, dl = eqw_forced_shift(cls, mem, nil, start, sh, anchor, pl.rigid, pl.seeds, nil, pinEff, occB, probeCap)
      elro._gxFree = nil
      if mv then elro._eq2dGxN = (elro._eq2dGxN or 0) + 1
      else
        local wk = tostring(n):gsub("<%-.*", "")
        why.gxW = why.gxW or {}
        why.gxW[wk] = (why.gxW[wk] or 0) + 1
      end
    end
    if not mv and pl.rigid then
      mv, n, dl = eqw_forced_shift(cls, mem, nil, start, sh, anchor, false, pl.seeds, nil, pinEff, occB, probeCap)
      local _sh0 = true
      if mv and _sh0 then why.shear = why.shear + 1 end
      -- the plate's rigidity travels with it (`rigidUsed`), not the plan's flag
      if mv then rigidUsed = false end
    end
    nTried = nTried + 1
    -- `why.union` is booked by the union bound (`eq2dUnionBound`, default off, bare truthy test).
    if not mv then
      nVoid = nVoid + 1
      why.build = why.build + 1
    else
      local saved = {}
      for r in pairs(mv) do
        local p = coord[r] ; saved[r] = p
        local e = dl[r]
        coord[r] = { p[1] + e[1], p[2] + e[2] }
      end
      local ok = clear_now()
      for r, c in pairs(saved) do coord[r] = c end
      if not ok then
        why["no-clear"] = why["no-clear"] + 1
        local k = clWhy or "?"
        noClear[k] = (noClear[k] or 0) + 1
      end
      if ok then
        -- `intoEmpty` honest for the same reason as a 1D eq-plate: room-vs-room clearance only
        local setB = {}
        for r in pairs(mv) do setB[r] = true end
        local sm2T, sm2F = seam2d(setB, dl)     -- ONE call; it walks the whole plate boundary
        out[#out + 1] = { kind = "eq2d",
          ek = eq_ek(start, nil, nil, nil, pl.br and ("b" .. anchor) or nil, sh),
          dx = 0, dy = 0,                      -- GRADED: the move lives in `deltas`
          dist = math.abs(sh[1]) + math.abs(sh[2]),
          cost = math.abs(sh[1]) + math.abs(sh[2]),
          eq2dMag = math.max(math.abs(sh[1]), math.abs(sh[2])),
          rooms = n, intoEmpty = true, set = setB, deltas = dl,
          -- graded seam; without it a 2D plate abstains from the tie-break
          seamTight = sm2T, seamFree = sm2F }
        if pl.br then
          local c = out[#out]
          c.hops, c.hopsA, c.artic, c.bridge = pl.br.hops, pl.br.hopsA, pl.br.artic, true
          elro._bsEmit2d = (elro._bsEmit2d or 0) + 1
        end
        if mode == "companion" then break end  -- one derived shift; there is nothing else to try
        if pl.dir then doneDir[pl.dir] = true end   -- minimal margin: this direction is settled
      end
    end
   end
  end
  if probeCap then elro._eq2dCapN = (elro._eq2dCapN or 0) + 1 end
  elro._eq2dShN = (elro._eq2dShN or 0) + why.shear
  if _t0 then elro._eq2dT = (elro._eq2dT or 0) + (CLK() - _t0)
    elro._eq2dN = (elro._eq2dN or 0) + 1
    elro._eq2dOut = (elro._eq2dOut or 0) + #out
    elro._eq2dTry = (elro._eq2dTry or 0) + nTried
    -- per mode
    local M = elro._eq2dBy or {} ; elro._eq2dBy = M
    local mk = mode or "?"
    local m = M[mk] ; if not m then m = { n = 0, out = 0, try = 0, t = 0, empty = 0 } ; M[mk] = m end
    m.n = m.n + 1 ; m.out = m.out + #out ; m.try = m.try + nTried
    m.t = m.t + (CLK() - _t0)
    if #out == 0 then m.empty = m.empty + 1 end end
  if elro.stepDebug then
    local rp = elro._guilloTracePending or {} ; elro._guilloTracePending = rp
    local parts = {}
    for _, c in ipairs(out) do parts[#parts + 1] = c.ek .. "(" .. c.rooms .. "r)" end
    rp[#rp + 1] = { header = string.format(
      "query_eq_2d_levers A=%s B=%s mode=%s%s -> %d plate(s) [%s] (%d probes, %d void%s)%s",
      tostring(A), tostring(B), tostring(mode),
      -- name the seed: A/B are identical on every call of a conflict
      (mode == "complete" and p1) and string.format(" seed=%s>%s ax%s%+d",
        tostring(p1), tostring(p2), tostring(p3), p4 or 0) or "",
      #out, table.concat(parts, " "), nTried, nVoid,
      -- why, not just how many
      (function()
        local w = {}
        if why.build > 0 then w[#w + 1] = "build " .. why.build end
        if why.union > 0 then w[#w + 1] = "union-bound " .. why.union end
        if why["no-clear"] > 0 then
          -- fixed order, never `pairs` -- a trace line must not depend on the hash seed
          local d = {}
          for _, k in ipairs({ "overlap", "room-on-edge", "edge-on-room", "crossing", "?" }) do
            if noClear[k] then d[#d + 1] = k .. " " .. noClear[k] end
          end
          w[#w + 1] = "no-clear " .. why["no-clear"]
            .. ((#d > 0) and (" (" .. table.concat(d, ", ") .. ")") or "")
        end
        if why.rigidW then w[#w + 1] = "rigid-void" .. elro._whyList(why.rigidW) end
        if why.gxW then w[#w + 1] = "gxfree-void" .. elro._whyList(why.gxW) end
        if why.shear > 0 then w[#w + 1] = "(" .. why.shear .. " rescued by shear)" end
        -- the reasons belong to the other probes, not to the plate(s) listed
        return (#w > 0) and ("; rejected: " .. table.concat(w, ", ")) or ""
      end)(),
      _tr0 and string.format(" %.0fms", (CLK() - _tr0) * 1000) or "") }
  end
  return out
end

-- Ring dilation (`elro.ringDilate`): cut a face ring at the diagonals of one family
-- (two cuts only) and translate one arc along that family's unit vector; every cut edge
-- lengthens and nothing shears. The per-room delta is the union of two 1D closures (dx
-- and dy). Emits nothing when the two arcs share an equality class on either axis.
function elro.query_ring_dilate_levers(W, v, blk)
  local DELTA, DIRORDER, adj, class_seam, coord, eqw_classes, eqw_field_shift, placed = W.DELTA, W.DIRORDER, W.adj, W.class_seam, W.coord, W.eqw_classes, W.eqw_field_shift, W.placed
  local rigid_pendants, seam2d = W.rigid_pendants, W.seam2d
  local out = {}
  -- stepDebug: write a `[plate-gen]` header like every other generator
  local _tr0 = elro.stepDebug and CLK()
  local rej = elro.stepDebug and {} or nil
  local rings = elro.faceRings
  if not (rings and #rings > 0) then
    if rej then
      local rp = elro._guilloTracePending or {} ; elro._guilloTracePending = rp
      rp[#rp + 1] = { header = string.format(
        "query_ring_dilate_levers v=%s blk=%s -> NO RINGS (elro.faceRings empty)",
        tostring(v), tostring(blk)) }
    end
    return out
  end
  -- room -> ring indices, built once per ring table (the table is replaced per compose)
  local RX = elro._rdIdx
  if not (RX and RX.gen == rings) then
    RX = { gen = rings, at = {} }
    for i, g in ipairs(rings) do
      for _, r in ipairs(g) do
        local t = RX.at[r] ; if t then t[#t + 1] = i else RX.at[r] = { i } end
      end
    end
    elro._rdIdx = RX
  end
  -- rings in play: the conflict pair is usually the face's load, so widen one hop
  local want = {}
  -- in closure mode (`_sqGen`) only the ring this edge is a wall of
  if elro._sqGen then
    for _, i in ipairs(RX.at[v] or {}) do
      for _, j in ipairs(RX.at[blk] or {}) do if i == j then want[i] = true end end
    end
  else
  for _, r0 in ipairs({ v, blk }) do
    if r0 then
      for _, i in ipairs(RX.at[r0] or {}) do want[i] = true end
      for _, x in each_exit(adj[r0]) do
        for _, i in ipairs(RX.at[x] or {}) do want[i] = true end
      end
    end
  end
  end
  -- `TUNE.ringSizeCap`: a dilation is a face move; the bound is on the ring, not the
  -- plate, because the wall-split enumeration grows with the ring.
  local rsc = TUNE.ringSizeCap or 0
  local wl = {}
  for i in pairs(want) do
    if rsc <= 0 or #rings[i] <= rsc then wl[#wl + 1] = i
    else elro._rdBig = (elro._rdBig or 0) + 1 end
  end
  table.sort(wl)                      -- never pairs() order: the LuaJIT hash seed moves it
  if #wl == 0 then
    if rej then
      local rp = elro._guilloTracePending or {} ; elro._guilloTracePending = rp
      rp[#rp + 1] = { header = string.format(
        "query_ring_dilate_levers v=%s blk=%s -> NO RING within one hop of the conflict pair",
        tostring(v), tostring(blk)) }
    end
    return out
  end
  local cls, mem = eqw_classes()
  local occB = {}
  for r in pairs(placed) do
    local p = coord[r]
    if p then
      local k = p[1] * 1000003 + p[2] ; local l = occB[k]
      if l then l[#l + 1] = r else occB[k] = { r } end
    end
  end
  for _, ri in ipairs(wl) do
    local g = rings[ri]
    local n = #g
    local D, fam, ok = {}, {}, true
    for i = 1, n do
      local a, b = g[i], g[(i % n) + 1]
      local d
      for _, dd in ipairs(DIRORDER) do if adj[a] and adj[a][dd] == b then d = dd ; break end end
      local de = d and DELTA[d]
      if not de then ok = false ; break end
      D[i] = de
      if de[1] ~= 0 and de[2] ~= 0 then fam[i] = (de[1] * de[2] < 0) and "u" or "v" end
    end
    if ok then
      -- A cut set is a set of ring edges whose oriented directions sum to zero, so the ring
      -- still closes when every cut edge grows by one. Diagonals are chosen first; any residual
      -- is cancelled greedily with axial edges, in ring order (deterministic, never pairs).
      elro._rdRing = (elro._rdRing or 0) + 1
      local sets, seen = {}, {}
      local function addset(name, keep)
        local C, sx, sy = {}, 0, 0
        for i = 1, n do
          if fam[i] and keep(fam[i]) then C[#C + 1] = i ; sx = sx + D[i][1] ; sy = sy + D[i][2] end
        end
        -- at least two diagonals: one diagonal plus axial cancellation is a shear repair, not a
        -- dilation, and generates a set for almost every ring
        if #C < 2 then return end
        local needX, needY = -sx, -sy
        for i = 1, n do
          if not fam[i] and (needX ~= 0 or needY ~= 0) then
            local d = D[i]
            if d[1] ~= 0 and needX ~= 0 and d[1] * needX > 0 then
              C[#C + 1] = i ; needX = needX - d[1]
            elseif d[2] ~= 0 and needY ~= 0 and d[2] * needY > 0 then
              C[#C + 1] = i ; needY = needY - d[2]
            end
          end
        end
        if needX ~= 0 or needY ~= 0 then return end     -- residual cannot be cancelled
        table.sort(C)                                   -- the accumulation walk wants ring order
        -- The closure fixes how much each WALL grows; the split of that total over the wall's
        -- edges is free. The greedy's all-ones arrangement is kept as the canonical set and the
        -- other splits of the same per-wall total are offered as sibling candidates.
        local walls, wof = {}, {}          -- maximal ring runs of one direction; edge -> wall
        for i = 1, n do
          local pv = walls[#walls]
          local pi = (i == 1) and n or (i - 1)
          if pv and D[i][1] == D[pi][1] and D[i][2] == D[pi][2] then pv[#pv + 1] = i
          else walls[#walls + 1] = { i } end
          wof[i] = #walls
        end
        -- the ring is cyclic: a run spanning n -> 1 is one wall
        if #walls > 1 then
          local a, b = walls[1], walls[#walls]
          if D[a[1]][1] == D[b[1]][1] and D[a[1]][2] == D[b[1]][2] then
            for _, i in ipairs(a) do b[#b + 1] = i end
            table.remove(walls, 1)
            for wi, w in ipairs(walls) do for _, i in ipairs(w) do wof[i] = wi end end
          end
        end
        local tot = {}                     -- wall -> how much the greedy gave it
        for _, i in ipairs(C) do tot[wof[i]] = (tot[wof[i]] or 0) + 1 end
        -- one variant list per wall; single-edge and diagonal walls only get the greedy's own
        -- arrangement, and only walls given at least ringSplitMin are split
        local per = {}
        for wi = 1, #walls do
          local k = tot[wi]
          if k then
            local es = walls[wi]
            local opts = {}
            if #es == 1 or fam[es[1]]
               or k < (TUNE.ringSplitMin or 2) then
              local o = {} ; for _, i in ipairs(es) do o[i] = 0 end
              for _, i in ipairs(C) do if wof[i] == wi then o[i] = 1 end end
              opts[1] = o
            else
              -- the greedy's own arrangement must go first: it is the canonical set, and
              -- "first all-ones arrangement" is not the same thing
              local gd = {} ; for _, i in ipairs(es) do gd[i] = 0 end
              for _, i in ipairs(C) do if wof[i] == wi then gd[i] = 1 end end
              opts[1] = gd
              local cur = {}
              local function comp(t, rest)
                if t > #es then
                  if rest == 0 then
                    local o, same = {}, true
                    for j, i in ipairs(es) do o[i] = cur[j] ; if cur[j] ~= gd[i] then same = false end end
                    if not same then opts[#opts + 1] = o end
                  end
                  return
                end
                for q = 0, rest do cur[t] = q ; comp(t + 1, rest - q) end
              end
              comp(1, k)
            end
            per[#per + 1] = { wi = wi, opts = opts }
          end
        end
        -- bounded cross-product; the canonical (greedy) member is emitted first so the cap
        -- only ever costs variants. Canonical means "the set the greedy chose", not "all
        -- weights <= 1".
        local ck = {}
        for _, i in ipairs(C) do ck[#ck + 1] = i .. "x1" end
        local canonKey = table.concat(ck, ",")
        local emitted = 0
        local function walk(t, W)
          if emitted >= (TUNE.ringSplitCap or 8) then return end
          if t > #per then
            for _, i in ipairs(C) do if W[i] == nil then W[i] = 1 end end
            local CC = {}
            for i = 1, n do
              local w = W[i]
              if w and w > 0 then CC[#CC + 1] = i end
            end
            if #CC == 0 then return end
            local kp = {}
            for _, i in ipairs(CC) do kp[#kp + 1] = i .. "x" .. W[i] end
            local key = table.concat(kp, ",")
            local allOne = (key == canonKey)
            if not seen[key] then
              seen[key] = true ; emitted = emitted + 1
              -- the canonical member keeps the bare name; siblings take a suffix that names
              -- edges as well as weights, since the label is a sort key and a maplever address
              local nm = name
              if not allOne then nm = name .. "/" .. (key:gsub(",", "-")) end
              sets[#sets + 1] = { name = nm, C = CC, W = W, split = not allOne }
            end
            return
          end
          local first = true
          for _, o in ipairs(per[t].opts) do
            local W2 = {} ; for i, w in pairs(W) do W2[i] = w end
            for i, w in pairs(o) do W2[i] = w end
            walk(t + 1, W2)
            first = false
          end
        end
        walk(1, {})
      end
      -- closure mode (_sqGen) builds only the re-solves: cut sets are increments, which a
      -- failed tighten has already shown cannot help
      if not elro._sqGen then
        addset("all", function() return true end)
        addset("u", function(f) return f == "u" end)
        addset("v", function(f) return f == "v" end)
      end
      -- Squarify: re-solve the ring rather than increment it (a dilation preserves an axial
      -- wall's parity, so an out-of-square ring cannot be squared by any cut set). One unknown
      -- length per wall, sum L_w * D_w = 0, enumerated by increasing total.
      local function squarify_sets()
        -- only the closure asks for these (elro.sqWalkToo re-opens it for the walk)
        if not elro._sqGen then return end
        -- walls: maximal runs of one direction, cyclic (the n -> 1 run is ONE wall)
        local walls = {}
        for i = 1, n do
          local pv = walls[#walls]
          local pi = (i == 1) and n or (i - 1)
          if pv and D[i][1] == D[pi][1] and D[i][2] == D[pi][2] then pv[#pv + 1] = i
          else walls[#walls + 1] = { i } end
        end
        if #walls > 1 then
          local a, b = walls[1], walls[#walls]
          if D[a[1]][1] == D[b[1]][1] and D[a[1]][2] == D[b[1]][2] then
            for _, i in ipairs(a) do b[#b + 1] = i end
            table.remove(walls, 1)
          end
        end
        local W = #walls
        if W < 3 or W > (TUNE.sqWallCap or 5) then return end
        if n > (TUNE.sqRingCap or 8) then return end
        -- only a ring that is actually out of square; a square ring is a dilation's business
        local bent, hasDiag = false, false
        for _, es in ipairs(walls) do
          local d = D[es[1]]
          if d[1] ~= 0 and d[2] ~= 0 then
            hasDiag = true
            local a, b = g[es[1]], g[(es[#es] % n) + 1]
            local pa, pb = coord[a], coord[b]
            if not (pa and pb) then return end
            local vx, vy = pb[1] - pa[1], pb[2] - pa[2]
            -- a wall many cells off 45 is a different shape, not a squaring candidate
            local bend = vx * d[2] - vy * d[1]
            if bend ~= 0 then
              if math.abs(bend) > (TUNE.sqBendCap or 1) then return end
              bent = true
            end
          end
        end
        if not (hasDiag and bent) then return end
        -- per-wall minimum = the sum of its edges` own minimums
        local wmin, emin = {}, {}
        for wi, es in ipairs(walls) do
          local m = 0
          for _, i in ipairs(es) do
            local q = elro.min_len(g[i], g[(i % n) + 1]) or 1
            emin[i] = q ; m = m + q
          end
          wmin[wi] = m
        end
        -- enumerate wall lengths, closure-exact, by increasing total
        local GROW = TUNE.sqGrow or 3
        local sols = {}
        local L = {}
        local function rec(wi, sx, sy, tot)
          if wi > W then
            if sx == 0 and sy == 0 then
              local c = {} ; for j = 1, W do c[j] = L[j] end
              sols[#sols + 1] = { L = c, tot = tot }
            end
            return
          end
          local d = D[walls[wi][1]]
          for q = wmin[wi], wmin[wi] + GROW do
            L[wi] = q
            rec(wi + 1, sx + q * d[1], sy + q * d[2], tot + q)
          end
        end
        rec(1, 0, 0, 0)
        if #sols == 0 then return end
        table.sort(sols, function(x, y)
          if x.tot ~= y.tot then return x.tot < y.tot end
          for j = 1, W do if x.L[j] ~= y.L[j] then return x.L[j] < y.L[j] end end
          return false
        end)
        -- per solution: the intra-wall splits, then one `dof` per (solution, split)
        local made = 0
        for _, sol in ipairs(sols) do
          if made >= (TUNE.sqCap or 6) then break end
          -- compositions of L_w over the wall`s edges, each edge >= its own minimum
          local perW = {}
          for wi, es in ipairs(walls) do
            local opts, cur = {}, {}
            local function comp(t, rest)
              if #opts >= (TUNE.sqSplitCap or 6) then return end
              if t > #es then
                if rest == 0 then
                  local o = {} ; for j, i in ipairs(es) do o[i] = cur[j] end
                  opts[#opts + 1] = o
                end
                return
              end
              for q = emin[es[t]], rest do cur[t] = q ; comp(t + 1, rest - q) end
            end
            comp(1, sol.L[wi])
            if #opts == 0 then return end
            perW[wi] = opts
          end
          local pick = {}
          local function cross(wi)
            if made >= (TUNE.sqCap or 6) then return end
            if wi > W then
              local len = {}
              for j = 1, W do for i, q in pairs(pick[j]) do len[i] = q end end
              -- target position of every ring room, relative to g[1], then the DISPLACEMENT
              local rx, ry, dof, same = 0, 0, {}, true
              local base = coord[g[1]]
              for k = 1, n do
                local p = coord[g[k]]
                if not p then return end
                local ex, ey = rx - (p[1] - base[1]), ry - (p[2] - base[2])
                dof[g[k]] = { ex, ey }
                if ex ~= 0 or ey ~= 0 then same = false end
                rx, ry = rx + len[k] * D[k][1], ry + len[k] * D[k][2]
              end
              if same then return end            -- the ring is already at this solution
              local kp = {}
              for k = 1, n do kp[#kp + 1] = len[k] end
              local key = "sq" .. table.concat(kp, "-")
              if not seen[key] then
                seen[key] = true ; made = made + 1
                sets[#sets + 1] = { name = key, C = {}, dof = dof, squarify = true }
              end
              return
            end
            for _, o in ipairs(perW[wi]) do pick[wi] = o ; cross(wi + 1) end
          end
          cross(1)
        end
      end
      squarify_sets()
      -- Arcs by accumulation: walk the ring once, each room takes the running offset, and a
      -- cut edge adds its weighted direction. Pure topology, no coordinate is read. A squarify
      -- set brings its own per-room displacement (dof) instead.
      local function arc_groups(S)
        if S.dof then
          local grp, keys = {}, {}
          for k = 1, n do
            local e = S.dof[g[k]] ; local key = e[1] .. "," .. e[2]
            local t = grp[key]
            if not t then t = { dx = e[1], dy = e[2], rs = {} } ; grp[key] = t ; keys[#keys + 1] = key end
            t.rs[#t.rs + 1] = g[k]
          end
          return S.dof, grp, keys
        end
        local cutAt = {}
        for _, i in ipairs(S.C) do cutAt[i] = (S.W and S.W[i]) or 1 end
        local dof, ax, ay = {}, 0, 0
        for k = 1, n do
          dof[g[k]] = { ax, ay }
          if cutAt[k] then ax, ay = ax + cutAt[k] * D[k][1], ay + cutAt[k] * D[k][2] end
        end
        -- group by offset. The dilation is defined only up to a translation, so one arc is
        -- held still; every choice of held arc is a different move and all are tried.
        local grp, keys = {}, {}
        for k = 1, n do
          local e = dof[g[k]] ; local key = e[1] .. "," .. e[2]
          local t = grp[key]
          if not t then t = { dx = e[1], dy = e[2], rs = {} } ; grp[key] = t ; keys[#keys + 1] = key end
          t.rs[#t.rs + 1] = g[k]
        end
        return dof, grp, keys
      end
      -- One normalisation of one cut set -> (set, deltas) or a reason. `extra`: rooms riding an
      -- arc; `noDrag`/`noDragR`: classes/rooms no arc may drag; `dummies`: synthetic arcs.
      local function build_norm(S, dof, grp, fixed, occ, tag, extra, noDrag, dummies, noDragR)
        elro._rdNorm = (elro._rdNorm or 0) + 1
        local bx, by = grp[fixed].dx, grp[fixed].dy
        local anchor = grp[fixed].rs[1]
        local set, deltas, bad, nmove = {}, {}, false, 0
        -- own[r] is the move of the arc that first reached r; a partially dragged room's
        -- deltas[r] is not any group's move, so seeds must name own[r]
        local own = {}
        local groups = {}
        for _, t in pairs(grp) do groups[#groups + 1] = { t.dx - bx, t.dy - by, t.rs } end
        for _, t in ipairs(dummies or {}) do groups[#groups + 1] = { t[1], t[2], t[3] } end
        -- one field, one closure: all arc displacements are handed to eqw_field_shift together
        -- so a room constrained by two arcs gets the binding answer
        local sm = {}
        for _, gt in ipairs(groups) do
          for _, r in ipairs(gt[3] or {}) do sm[r] = { gt[1], gt[2] } end
        end
        for _, e in ipairs(extra or {}) do sm[e[1]] = { e[2], e[3] } end
        local capF = S.squarify and (TUNE.sqPlateCap or 48) or TUNE.ringDilateCap
        local st, dl, bad2 = eqw_field_shift(cls, mem, sm, anchor, capF, occ, nil, nil, nil,
                                             (elro.ringLeaveBehind == true) and noDragR or nil)
        elro._rfN = (elro._rfN or 0) + 1
        if not st then
          elro._rfVoid = (elro._rfVoid or 0) + 1
          elro._rfWhy = elro._rfWhy or {}
          local k = tostring(bad2):gsub("@.*", "")
          elro._rfWhy[k] = (elro._rfWhy[k] or 0) + 1
          return nil, nil, "field:" .. tostring(bad2), 0, nil
        end
        nmove = 0
        for _, gt in ipairs(groups) do
          if gt[1] ~= 0 or gt[2] ~= 0 then nmove = nmove + 1 end
        end
        for r in pairs(st) do own[r] = { dl[r][1], dl[r][2] } end
        -- the rigid-pendant rule still applies: the field has no opinion about a room nothing
        -- constrains
        do
          local seedF = {}
          for r in pairs(sm) do seedF[r] = true end
          rigid_pendants(st, dl, seedF, string.format("ring:%d:%s%s(field)", ri, S.name, tag or ""))
          for r in pairs(st) do own[r] = { dl[r][1], dl[r][2] } end
        end
        return st, dl, nil, nmove, own
      end
      -- emit: `deltas` is at original geometry; `ringSq` (the ring's own walls all stayed
      -- square) is what earns the corridor price
      local function emit(ekName, set, deltas, nmove, ringSq, own)
        local nr = 0 ; for _ in pairs(set) do nr = nr + 1 end
        -- diagnostic (RDHALF=1): riders whose delta is a strict subset of their arc's move
        if RDHALF_ENV and own then
          local nh = 0
          for r in pairs(set) do
            local d, o = deltas[r], own[r]
            if d and o and (d[1] ~= o[1] or d[2] ~= o[2]) then nh = nh + 1 end
          end
          elro._rdHalfR = (elro._rdHalfR or 0) + nh
          elro._rdHalfN = (elro._rdHalfN or 0) + nr
          elro._rdHalfP = (elro._rdHalfP or 0) + 1
          if nh > 0 then elro._rdHalfPP = (elro._rdHalfPP or 0) + 1 end
        end
        -- intoEmpty: no moved room may share a destination cell with any other room
        local dest, empty = {}, true
        for r in pairs(placed) do
          local p = coord[r]
          if p then
            local e = deltas[r]
            local k = (p[1] + (e and e[1] or 0)) .. ":" .. (p[2] + (e and e[2] or 0))
            if dest[k] then empty = false ; break end
            dest[k] = r
          end
        end
        local mag = 0
        for _, e in pairs(deltas) do
          local m = math.abs(e[1]) + math.abs(e[2]) ; if m > mag then mag = m end
        end
        local sT, sF = seam2d(set, deltas)
        out[#out + 1] = { kind = "ring-dilate",
          ek = string.format("ring:%d:%s", ri, ekName),
          squarify = (ekName:sub(1, 2) == "sq") or nil,   -- the closure hook picks these by name
          ringSet = (function() local t = {} for k = 1, n do t[g[k]] = true end return t end)(),  -- the plate's own ring, so a repair can tell solution from riders
          dx = 0, dy = 0,                    -- graded: the move lives in `deltas`
          dist = mag, cost = mag,
          corridor = ringSq and 1 or nil,    -- one corridor of width 1, priced as the rigid plates are
          rooms = nr, intoEmpty = empty, set = set, deltas = deltas,
          seamTight = sT, seamFree = sF }
        elro._rdOut = (elro._rdOut or 0) + 1
        if RDWATCH_ENV then
          print(string.format("  [rd] v=%s blk=%s ring=%d cut=%s arcs=%d rooms=%d intoEmpty=%s",
            tostring(v), tostring(blk), ri, ekName, nmove + 1, nr, tostring(empty)))
          if RDWATCH_ENV == "2" then
            local w = {}
            for k = 1, n do
              local r = g[k] ; local p0 = coord[r] ; local e = deltas[r]
              w[#w + 1] = string.format("%d(%d,%d)%s", r, p0[1], p0[2],
                e and string.format("->(%d,%d)", p0[1] + e[1], p0[2] + e[2]) or "")
            end
            print("        ring: " .. table.concat(w, " "))
            local ow = {}
            for r in pairs(set) do
              local onring = false
              for k = 1, n do if g[k] == r then onring = true ; break end end
              if not onring then
                local p0, e = coord[r], deltas[r]
                ow[#ow + 1] = string.format("%d(%d,%d)->(%d,%d)", r, p0[1], p0[2], p0[1] + e[1], p0[2] + e[2])
              end
            end
            table.sort(ow)
            print("        also: " .. table.concat(ow, " "))
          end
        end
      end
      if rej and #sets == 0 then
        local fs = {}
        for i = 1, n do fs[#fs + 1] = fam[i] or "-" end
        rej[#rej + 1] = string.format("%d:- no zero-sum cut set (families %s)", ri, table.concat(fs))
      end
      -- Exact infeasibility test, run before any closure: two ring rooms in one equality class
      -- on an axis cannot take different offsets on it. Only a proof of impossibility, never of
      -- feasibility; normalisation-independent, so one pass kills the whole set.
      local function set_locked(dof)
        for a = 1, 2 do
          local seenC = {}
          for k = 1, n do
            local r = g[k]
            local c = cls[a][r] or r
            local off = dof[r][a]
            local prev = seenC[c]
            if prev == nil then seenC[c] = off
            elseif prev ~= off then return true end
          end
        end
        return false
      end
      -- a ring room is never a seed: its arc is decided by the accumulation
      local onRing = {}
      for k = 1, n do onRing[g[k]] = true end
      -- Counts only the RING'S OWN diagonals that this plate tips (a tipped ring diagonal means
      -- the move is not a dilation; any other tipped 45 is the :sf re-seed's business).
      local function ring_shear(set, deltas)
        local cnt = 0
        for i = 1, n do
          if fam[i] then
            local a, b = g[i], g[(i % n) + 1]
            local pA, pB = coord[a], coord[b]
            if pA and pB then
              local gx, gy = pB[1] - pA[1], pB[2] - pA[2]
              local de = D[i]
              if gx * de[1] > 0 and gy * de[2] > 0 and math.abs(gx) == math.abs(gy) then
                local dA, dB = deltas[a], deltas[b]
                local ex = (dB and dB[1] or 0) - (dA and dA[1] or 0)
                local ey = (dB and dB[2] or 0) - (dA and dA[2] or 0)
                if math.abs(gx + ex) ~= math.abs(gy + ey) then cnt = cnt + 1 end
              end
            end
          end
        end
        return cnt
      end
      -- which arc a stationary room x should ride: the one its moved neighbour came in on
      -- (own[r], not deltas[r])
      local function arc_of(x, set, own)
        if onRing[x] then return nil end            -- a ring room's arc is the accumulation's
        for d, r in each_exit(adj[x]) do
          local de = DELTA[d]
          if de and (de[1] ~= 0 or de[2] ~= 0) and set[r] and own[r] then
            return own[r][1], own[r][2]
          end
        end
      end
      -- does this plate squash or flip any edge? A leave-behind is only taken when this holds.
      local function no_squash(set, deltas)
        for r in pairs(set) do
          local pr, dr = coord[r], deltas[r]
          if pr and dr then
            for d, x in each_exit(adj[r]) do
              local de = DELTA[d]
              if de and (de[1] ~= 0 or de[2] ~= 0) and placed[x] and coord[x] then
                local dxx = deltas[x]
                local nx = coord[x][1] + (dxx and dxx[1] or 0) - (pr[1] + dr[1])
                local ny = coord[x][2] + (dxx and dxx[2] or 0) - (pr[2] + dr[2])
                local mn = elro.min_len(r, x)
                for a = 1, 2 do
                  local g = (a == 1) and nx or ny
                  if de[a] ~= 0 then
                    if g * de[a] < mn then
                      return false, string.format("%d:%d axis%d -> %d (min %d)", r, x, a, g, mn),
                             r, x, a
                    end
                  elseif g ~= 0 then
                    return false, string.format("%d:%d axis%d off-line by %d", r, x, a, g), r, x, a
                  end
                end
              end
            end
          end
        end
        return true
      end
      local function shear_of(set, deltas, own)
        local cnt, seeds, seen, edge = 0, {}, {}, {}
        for r in pairs(set) do
          local pr = coord[r] ; local dr = deltas[r]
          if pr and dr then
            for d, x in each_exit(adj[r]) do
              local de = DELTA[d]
              if de and de[1] ~= 0 and de[2] ~= 0 and placed[x] and coord[x] then
                local gx, gy = coord[x][1] - pr[1], coord[x][2] - pr[2]
                if gx * de[1] > 0 and gy * de[2] > 0 and math.abs(gx) == math.abs(gy) then
                  local dxx = deltas[x]
                  local ex, ey = (dxx and dxx[1] or 0) - dr[1], (dxx and dxx[2] or 0) - dr[2]
                  local ek2 = ekey(r, x)
                  if math.abs(gx + ex) ~= math.abs(gy + ey) and not edge[ek2] then
                    edge[ek2] = true
                    cnt = cnt + 1
                    if elro._rdTipLog then
                      elro._rdTipLog[#elro._rdTipLog + 1] = string.format("%d:%d %s", r, x,
                        set[x] and "BOTH ENDS IN THE PLATE, different arcs -- NOT seedable"
                               or "far end stationary")
                    end
                    -- two seeds can save a wall: (a) pull the stationary end onto r's arc;
                    -- (b) complete r's partial drag by seeding r onto its own arc. A wall
                    -- spanning two arcs has no seed and must tip.
                    if own and own[r] then
                      local dr2 = deltas[r]
                      if (dr2[1] ~= own[r][1] or dr2[2] ~= own[r][2]) and not seen[r] then
                        seen[r] = true ; seeds[#seeds + 1] = { r, own[r][1], own[r][2] }
                      end
                    end
                    if own and not seen[x] and not onRing[x] and not set[x] and own[r] then
                      seen[x] = true ; seeds[#seeds + 1] = { x, own[r][1], own[r][2] } end
                    -- (d) translate the wall rigidly on a dummy arc. (c) leave r's class behind on its axis
                    -- (ringLeaveBehind, off by default), guarded by no_squash.
                  end
                end
              end
            end
          end
        end
        return cnt, seeds
      end
      -- Incremental re-seed shared by :sf and :t: seeds tried one at a time, a failing seed is
      -- dropped, not the repair. No move may raise the ring's own shear or exceed `shCap`.
      local function reseed(S, dof, grp, fixed, shR, set0, del0, own0, tag, seedsOf, scoreOf, budget)
        local best = scoreOf(set0, del0, own0)
        local shCap = shear_of(set0, del0, own0)
        local bset, bdel, bown, got = set0, del0, own0, false
        local extra, tried, why, noDrag, dummies = {}, {}, {}, nil, {}
        local noDragR = { {}, {} }        -- the ROOM form of `noDrag`, kept in lockstep
        -- dummy arcs go last (stable partition): a last resort for what is still tipped
        local function order(q)
          local a, b = {}, {}
          for _, e in ipairs(q) do
            if e[4] == "arc" then b[#b + 1] = e else a[#a + 1] = e end
          end
          for _, e in ipairs(b) do a[#a + 1] = e end
          return a
        end
        local queue, qi = order(seedsOf(set0, del0, own0)), 1
        if RDWATCH_ENV then
          print(string.format("        [%s] start: %d move(s) offered, budget %d",
            tag, #queue, budget))
        end
        while qi <= #queue and budget > 0 do
          local e = queue[qi] ; qi = qi + 1
          local blkMove, arcMove = (e[4] == "blk"), (e[4] == "arc")
          local kk = (e[4] or "s") .. e[1] .. ":" .. e[2] .. ":" .. e[3]
          if not tried[kk] then
            tried[kk] = true
            -- `blk` = leave this class behind; `arc` = dummy arc; anything else = bring this
            -- room along
            local bk
            if blkMove then
              bk = e[2] .. ":" .. e[3]
              noDrag = noDrag or {}
              if noDrag[bk] then bk = nil
              else noDrag[bk] = true ; noDragR[e[2]][e[1]] = true end
            elseif arcMove then
              dummies[#dummies + 1] = { e[2], e[3], { e[1] } }
            else
              extra[#extra + 1] = e
            end
            -- a leave-behind may not trade a shear for a squash (no_squash); before giving
            -- up, chase the squash by also leaving the culprit's class behind, up to 3 rounds
            local s2, d2, b2, nm2, o2
            local sqOK, sqWhy = true, nil
            local chased, chasedR = {}, {}
            for _ = 1, 3 do
              budget = budget - 1
              s2, d2, b2, nm2, o2 = build_norm(S, dof, grp, fixed, occB, tag, extra, noDrag,
                                               dummies, noDragR)
              local sqR, sqX, sqA
              sqOK, sqWhy, sqR, sqX, sqA = true, nil, nil, nil, nil
              if blkMove and (not b2) and nm2 > 0 then
                sqOK, sqWhy, sqR, sqX, sqA = no_squash(s2, d2)
              end
              if sqOK or b2 or nm2 == 0 or budget <= 0 then break end
              local cand = (d2[sqR] and sqR) or (d2[sqX] and sqX)
              if not cand then break end
              local ck = sqA .. ":" .. (cls[sqA][cand] or cand)
              if noDrag[ck] then break end
              noDrag[ck] = true ; noDragR[sqA][cand] = true
              chased[#chased + 1] = ck ; chasedR[#chasedR + 1] = { sqA, cand }
              if RDWATCH_ENV then
                local function dd(q) local e = d2[q] ; return e and (e[1] .. "," .. e[2]) or "-" end
                print(string.format("        [%s] ...chasing squash %s -> also leave %s behind"
                  .. "  [%d delta %s, %d delta %s]",
                  tag, tostring(sqWhy), ck, sqR, dd(sqR), sqX, dd(sqX)))
              end
            end
            local keep = false
            -- a dummy arc may only grow the plate by ringDummyCap rooms
            local dummyOK = true
            if arcMove and (not b2) and nm2 > 0 then
              local n2r, nbr = 0, 0
              for _ in pairs(s2) do n2r = n2r + 1 end
              for _ in pairs(bset) do nbr = nbr + 1 end
              dummyOK = (n2r - nbr) <= TUNE.ringDummyCap
            end
            if (not b2) and nm2 > 0 and ring_shear(s2, d2) <= shR and sqOK and dummyOK
               and shear_of(s2, d2, o2) <= shCap then
              local v2 = scoreOf(s2, d2, o2)
              if RDWATCH_ENV then
                local nr = 0 ; for _ in pairs(s2) do nr = nr + 1 end
                print(string.format("        [%s] %s %d (%d:%d): rooms=%d score=%s (best %s)",
                  tag, blkMove and "LEAVE-BEHIND" or arcMove and "DUMMY-ARC" or "seed",
                  e[1], e[2], e[3], nr, tostring(v2), tostring(best)))
              end
              if v2 > best then
                best, bset, bdel, bown, got, keep = v2, s2, d2, o2, true, true
                for _, e2 in ipairs(order(seedsOf(s2, d2, o2))) do queue[#queue + 1] = e2 end
              -- a neutral seed or leave-behind is carried (it may enable the next move); a
              -- neutral dummy arc is not, since it is a materially different plate
              elseif v2 == best and not arcMove then keep = true
              end
            else
              why[#why + 1] = e[1] .. " " .. (blkMove and "no-drag " or "")
                .. tostring(b2 or "ring-shear/squash")
              if RDWATCH_ENV then
                print(string.format("        [%s] %s %d (%d:%d): REJECT %s",
                  tag, blkMove and "LEAVE-BEHIND" or arcMove and "DUMMY-ARC" or "seed",
                  e[1], e[2], e[3],
                  tostring(b2 or sqWhy and ("SQUASH " .. sqWhy) or "ring-shear")))
              end
            end
            if not keep then
              if blkMove then
                if bk then noDrag[bk] = nil ; noDragR[e[2]][e[1]] = nil end
                for _, ck in ipairs(chased) do noDrag[ck] = nil end
                for _, cr in ipairs(chasedR) do noDragR[cr[1]][cr[2]] = nil end
              elseif arcMove then dummies[#dummies] = nil
              else extra[#extra] = nil end
            end
          end
        end
        return got and bset or nil, bdel, budget, bown, why
      end
      local famPlate = { u = {}, v = {} }     -- what the composite pass composes
      -- splits are built only if a canonical set emitted (stable partition, canonical first).
      -- A bound, not a theorem: a split could in principle build where the canonical clashes.
      do
        local can, spl = {}, {}
        for _, S in ipairs(sets) do
          if S.split then spl[#spl + 1] = S else can[#can + 1] = S end
        end
        for _, S in ipairs(spl) do can[#can + 1] = S end
        sets = can
      end
      local rdOut0 = elro._rdOut or 0
      for _, S in ipairs(sets) do
        if S.split and (elro._rdOut or 0) == rdOut0 then break end
        local dof, grp, keys = arc_groups(S)
        if set_locked(dof) then
          elro._rdLocked = (elro._rdLocked or 0) + 1
          if rej then rej[#rej + 1] = string.format("%d:%s class-locked", ri, S.name) end
          keys = {}
        end
        -- a re-solve gives every ring room its own offset, so its holds are capped (sqHoldCap)
        local _hc = 0
        for _, fixed in ipairs(keys) do
          if S.squarify then
            _hc = _hc + 1
            if _hc > (TUNE.sqHoldCap or 6) then break end
          end
          local _bt0 = elro.timeGuillo and CLK()
          local set, deltas, bad, nmove, own = build_norm(S, dof, grp, fixed, occB)
          if _bt0 then
            -- timing split: canonical vs split cut set, built vs void
            local K = elro._rdSplitT ; if not K then K = {} ; elro._rdSplitT = K end
            local kk = (S.split and "split" or "canon") .. (bad and ":void" or ":built")
            local a = K[kk] ; if not a then a = { t = 0, n = 0 } ; K[kk] = a end
            a.t = a.t + (CLK() - _bt0) ; a.n = a.n + 1
            local rb = "ring_le" .. (n <= 6 and 6 or (n <= 12 and 12 or (n <= 24 and 24 or
              (n <= 48 and 48 or (n <= 96 and 96 or 999)))))
            local b = K[rb] ; if not b then b = { t = 0, n = 0 } ; K[rb] = b end
            b.t = b.t + (CLK() - _bt0) ; b.n = b.n + 1
          end
          if RDWATCH_ENV and bad then
            print(string.format("  [rd] v=%s blk=%s ring=%d cut=%s hold=%s -> REJECT %s",
              tostring(v), tostring(blk), ri, S.name, fixed, tostring(bad)))
            if RDWATCH_ENV == "2" then
              local w = {}
              for k = 1, n do
                local r = g[k]
                w[#w + 1] = string.format("%d[x=%s y=%s off=%d,%d]", r,
                  tostring(cls[1][r]), tostring(cls[2][r]), dof[r][1], dof[r][2])
              end
              print("        ring: " .. table.concat(w, " "))
              local cw = {}
              for _, i in ipairs(S.C) do
                cw[#cw + 1] = string.format("%d->%d(%d,%d)x%d", g[i], g[(i % n) + 1],
                  D[i][1], D[i][2], (S.W and S.W[i]) or 1)
              end
              print("        cuts: " .. table.concat(cw, " "))
            end
          end
          if rej and bad then
            rej[#rej + 1] = string.format("%d:%s:%s %s", ri, S.name, fixed, tostring(bad))
          end
          if bad and tostring(bad):find("clash") then elro._rdClash = (elro._rdClash or 0) + 1
          elseif bad then elro._rdBuild = (elro._rdBuild or 0) + 1
          elseif nmove > 0 then
            -- a dilation that tips one of its own ring walls is not a dilation: it is dropped
            local base = S.name .. ":" .. fixed:gsub("[^%w]", "")
            local shR = ring_shear(set, deltas)
            if shR > 0 then
              elro._rdShearDrop = (elro._rdShearDrop or 0) + 1
              if rej then
                rej[#rej + 1] = string.format("%d:%s tips %d of its OWN wall(s)", ri, base, shR)
              end
            else
              emit(base, set, deltas, nmove, shR == 0, own)
              local fp = famPlate[S.name]
              if fp then fp[#fp + 1] = { fixed = fixed, set = set, deltas = deltas, nmove = nmove } end
              -- extra variants, as the eq tier offers them, emitted only if they improve on
              -- the base: `:sf` seeds the far ends of tipped 45s, `:t` seeds the far ends of
              -- the tightest seam edges, `:sf:t` is the seam walk from the sf plate. One budget
              -- (ringReseedCap builds) for all three, spent in that order.
              local sfSet, sfDel, sfOwn
              local budget = TUNE.ringReseedCap
              local function seam_score(setX, delX)
                return (class_seam(setX, nil, nil, delX))   -- math.huge = a FREE seam = best
              end
              local function shear_score(setX, delX, ownX)
                return -(shear_of(setX, delX, ownX))        -- higher is better
              end
              local function sf_seeds(setX, delX, ownX)
                local _, sd = shear_of(setX, delX, ownX) ; return sd
              end
              local function t_seeds(setX, delX, ownX)
                local t, bind = class_seam(setX, nil, nil, delX)
                local q = {}
                if bind and t < math.huge then
                  for _, x in ipairs(bind) do
                    local dx, dy = arc_of(x, setX, ownX)
                    if dx then q[#q + 1] = { x, dx, dy } end
                  end
                end
                if RDWATCH_ENV then
                  local b = {}
                  for _, x in ipairs(bind or {}) do
                    b[#b + 1] = x .. (onRing[x] and "(ON RING)" or (arc_of(x, setX, ownX) and "(ok)" or "(no arc)"))
                  end
                  print(string.format("        [t_seeds] seam t=%s bind={%s} -> %d move(s)",
                    tostring(t), table.concat(b, " "), #q))
                end
                return q
              end
              if RDWATCH_ENV then
                elro._rdTipLog = {}
                shear_of(set, deltas, own)
                print("        tipped: " .. table.concat(elro._rdTipLog, " | "))
                elro._rdTipLog = nil
              end
              local nTip, tipSeeds = shear_of(set, deltas, own)
              if nTip > 0 then
                local s2, d2, b2, o2, w2 = reseed(S, dof, grp, fixed, shR, set, deltas, own, ":sf",
                                                  sf_seeds, shear_score, budget)
                budget = b2
                if s2 then
                  sfSet, sfDel, sfOwn = s2, d2, o2
                  elro._rdSf = (elro._rdSf or 0) + 1
                  if RDWATCH_ENV then
                    elro._rdTipLog = {}
                    local nt = shear_of(s2, d2, o2)
                    print(string.format("        AFTER :sf tipped=%d: %s", nt,
                      table.concat(elro._rdTipLog, " | ")))
                    elro._rdTipLog = nil
                  end
                  emit(base .. ":sf", s2, d2, nmove, ring_shear(s2, d2) == 0, o2)
                elseif rej then
                  rej[#rej + 1] = string.format("%d:%s :sf %d wall(s) tipped, %d seedable%s",
                    ri, base, nTip, #tipSeeds,
                    (#w2 > 0) and (" -- seeds refused: " .. table.concat(w2, ", ")) or "")
                end
              end
              if budget > 0 then
                local s3, d3, b3 = reseed(S, dof, grp, fixed, shR, set, deltas, own, ":t",
                                          t_seeds, seam_score, budget)
                budget = b3
                if s3 then
                  elro._rdT = (elro._rdT or 0) + 1
                  emit(base .. ":t", s3, d3, nmove, ring_shear(s3, d3) == 0, own)
                end
              end
              if sfSet and budget > 0 then
                local s4, d4 = reseed(S, dof, grp, fixed, shR, sfSet, sfDel, sfOwn, ":sf:t",
                                      t_seeds, seam_score, budget)
                if s4 then
                  elro._rdSfT = (elro._rdSfT or 0) + 1
                  emit(base .. ":sf:t", s4, d4, nmove, ring_shear(s4, d4) == 0)
                end
              end
            end
          end
        end
      end
      -- Uniform dilation composes two plates: build u, displace coord, build v on that geometry,
      -- add deltas, revert unconditionally into the existing coord tables (identity is shared).
      if #famPlate.u > 0 and not elro._sqGen then
        for _, P1 in ipairs(famPlate.u) do
          for _, Sv in ipairs(sets) do
            if Sv.name == "v" then
              local dofV, grpV, keysV = arc_groups(Sv)
              for _, fx2 in ipairs(keysV) do
                local saved = {}
                for r, e in pairs(P1.deltas) do
                  local p = coord[r]
                  if p then saved[r] = { p[1], p[2] } ; p[1], p[2] = p[1] + e[1], p[2] + e[2] end
                end
                local occ2 = {}
                for r in pairs(placed) do
                  local p = coord[r]
                  if p then
                    local k = p[1] * 1000003 + p[2] ; local l = occ2[k]
                    if l then l[#l + 1] = r else occ2[k] = { r } end
                  end
                end
                local set2, deltas2, bad2, nmove2 = build_norm(Sv, dofV, grpV, fx2, occ2, "+")
                for r, p0 in pairs(saved) do local p = coord[r] ; p[1], p[2] = p0[1], p0[2] end
                if bad2 then
                  if rej then
                    rej[#rej + 1] = string.format("%d:uni:%s+%s %s", ri, P1.fixed, fx2, tostring(bad2))
                  end
                  elro._rdComp2 = (elro._rdComp2 or 0) + 1
                  if RDWATCH_ENV then
                    print(string.format("  [rd] v=%s blk=%s ring=%d cut=u:%s+v:%s -> REJECT %s",
                      tostring(v), tostring(blk), ri, P1.fixed, fx2, tostring(bad2)))
                  end
                elseif nmove2 > 0 then
                  local set, deltas = {}, {}
                  for r, e in pairs(P1.deltas) do set[r] = true ; deltas[r] = { e[1], e[2] } end
                  for r, e in pairs(deltas2) do
                    local d = deltas[r]
                    if d then d[1], d[2] = d[1] + e[1], d[2] + e[2]
                    else set[r] = true ; deltas[r] = { e[1], e[2] } end
                  end
                  for r, e in pairs(deltas) do
                    if e[1] == 0 and e[2] == 0 then set[r] = nil ; deltas[r] = nil end
                  end
                  -- same rule as the halves; no :sf retry across two closures
                  local shC = ring_shear(set, deltas)
                  if shC > 0 then
                    elro._rdShearDrop = (elro._rdShearDrop or 0) + 1
                    if rej then
                      rej[#rej + 1] = string.format("%d:uni:%s+%s tips %d of its OWN wall(s)",
                        ri, P1.fixed, fx2, shC)
                    end
                  else
                    emit(string.format("uni:%s%s", P1.fixed:gsub("[^%w]", ""), fx2:gsub("[^%w]", "")),
                      set, deltas, P1.nmove + nmove2, shC == 0)
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  if rej then
    local rp = elro._guilloTracePending or {} ; elro._guilloTracePending = rp
    local parts = {}
    for _, c in ipairs(out) do parts[#parts + 1] = c.ek .. "(" .. c.rooms .. "r)" end
    rp[#rp + 1] = { header = string.format(
      "query_ring_dilate_levers v=%s blk=%s ring(s)=%s -> %d plate(s) [%s]%s %.0fms",
      tostring(v), tostring(blk), table.concat(wl, ","), #out, table.concat(parts, " "),
      (#rej > 0) and ("; rejected: " .. table.concat(rej, ", ")) or "",
      (CLK() - _tr0) * 1000) }
  end
  return out
end
