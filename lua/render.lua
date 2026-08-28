-- Step snapshots, overlays, drawing, and the mapstep replay.
-- Split out of layout.lua; see lua/modules.lua for the load order.

elro = elro or {}
local G = elro.g or error("render.lua: lua/geom.lua must be loaded first (see elro.modules)")
local ori = G.ori
local seg = G.seg
local K = elro.k or error("render.lua: lua/keys.lua must be loaded first (see elro.modules)")
local ekey = K.edge
local crosspair = K.pair
local each_exit = elro.exits or error("render.lua: lua/core.lua must be loaded first")
local TUNE = elro.TUNE or error("render.lua: lua/tune.lua must be loaded first")
local area_adjacency = elro.area_adjacency or error("render.lua: lua/canvas.lua must be loaded first")

function elro.tcount(t) local n = 0 ; for _ in pairs(t) do n = n + 1 end ; return n end

-- Materialize one step frame's flat snapshot into the { room -> {x,y} } map the
-- replay reads. Memoised for ONE frame only, deliberately: caching more would put
-- back the live set the flat format exists to remove.
function elro.step_loc(s)
  if not s or not s.flat then return {} end
  local c = elro._locCache
  if c and c.f == s then return c.m end
  local m, fl = {}, s.flat
  for i = 1, #fl, 3 do m[fl[i]] = { fl[i + 1], fl[i + 2] } end
  elro._locCache = { f = s, m = m }
  return m
end

-- is room `id` present in this frame's snapshot? Scans the flat array rather than
-- materializing the map -- first_placed_step asks this of EVERY frame.
function elro.step_has(s, id)
  local fl = s and s.flat
  if not fl then return false end
  for i = 1, #fl, 3 do if fl[i] == id then return true end end
  return false
end
-- elro.stepTime: per-step timing without stepDebug's coord snapshot (no `flat`, nothing
-- to replay). Frames land in _stepTimeLog, NOT _stepLog -- mapstep's replay reads `flat`
-- from every frame and a mix of shapes would render empty maps. Set both, stepDebug wins.
function elro.step_snap(coord, label, focus, blocker, pull)
  local snap = elro.stepDebug
  if not (snap or elro.stepTime) then return end
  -- dt = engine time between the END of the previous snapshot and the START of this
  -- one, excluding the snapshot machinery. Wall clock via elro.now_ms minus the change
  -- in elro.bg_idle_ms() -- otherwise a step straddling a coroutine yield is charged
  -- the whole frame gap. Step 1 has no predecessor and reports 0.
  local t0 = elro.now_ms()
  local idle0 = elro.bg_idle_ms()
  -- heap after this step (kb) and its change (dkb): a large negative dkb marks a GC
  -- collection charged to whichever step provoked it.
  local kb0 = collectgarbage("count")
  -- per-step bucket split (needs elro.timeGuillo): diff the engine's monotonic timing
  -- accumulators against their values at the previous snapshot. `eval`/`qbl` NEST
  -- inside the others -- reported separately, must not be added in. Computed into
  -- locals here; `frame` does not exist yet.
  local split, ksplit, nsplit
  if elro.timeGuillo then
    -- (prescan) nests inside guards and is usually all of it: crossing_set/roomedge_set
    -- are whole-map prescans built once per conflict, not per-option cost.
    -- Parenthesised like (qbl)/(eval) because it nests -- do not add it to guards.
    local ACC = { dispatch = "_dspT", gen = "_genT", guards = "_gudT",
                  ["make-room"] = "_mrT", close = "_clT", reclaim = "_rcT",
                  spread = "_eqsT", ["(qbl)"] = "_qblT", ["(eval)"] = "_lcEvT",
                  ["(prescan)"] = "_preT" }
    -- same split for allocation. NET heap growth, not bytes allocated: a collection
    -- inside the bracket understates it, so a large number is evidence and a small
    -- one proves nothing.
    local KACC = { dispatch = "_dspK", gen = "_genK", guards = "_gudK",
                   ["make-room"] = "_mrK", close = "_clK", reclaim = "_rcK",
                   ["(qbl)"] = "_qblK", ["(eval)"] = "_lcEvK" }
    local base, cur = elro._stepAcc or {}, {}
    local kbase, kcur = elro._stepKAcc or {}, {}
    split = {}
    for k, f in pairs(ACC) do
      local v = elro[f] or 0
      cur[k] = v
      local d = (v - (base[k] or 0)) * 1000
      if d >= 0.5 then split[k] = d end     -- drop sub-millisecond noise
    end
    -- count of whole-map index rebuilds: one per conflict is expected; a number in
    -- the dozens means a tier is rebuilding a baseline once per CANDIDATE.
    local NACC = { ["crossing_set"] = "_csN", ["roomedge_set"] = "_rsN",
                   ["crossings_moved"] = "_cmN", ["roomedge_moved"] = "_rmN",
                   ["makes-crossing"] = "_pmcN", ["makes-roomedge"] = "_pmrN",
                   ["makes-overlap"] = "_pmoN" }
    -- option funnel per step, same monotonic-counter diff as the buckets. `evaluated`
    -- is the number that costs; a step where offered == evaluated had no clean candidate.
    for k, f in pairs({ offered = "_optGen", evaluated = "_optEval" }) do NACC[k] = f end
    local nbase, ncur = elro._stepNAcc or {}, {}
    nsplit = {}
    for k, f in pairs(NACC) do
      local v = elro[f] or 0
      ncur[k] = v
      local d = v - (nbase[k] or 0)
      if d > 0 then nsplit[k] = d end
    end
    elro._stepNAcc = ncur
    ksplit = {}
    for k, f in pairs(KACC) do
      local v = elro[f] or 0
      kcur[k] = v
      local d = v - (kbase[k] or 0)
      if d >= 64 then ksplit[k] = d end     -- drop anything under 64kB
    end
    elro._stepAcc, elro._stepKAcc = cur, kcur
  end
  elro._stepLog = elro._stepLog or {}
  -- flat snapshot: one array of (id, x, y) triples per step, not a map of per-room
  -- pairs -- far fewer live objects for the collector to mark. stepDebug still
  -- perturbs what it measures, just far less.
  local c, ci = nil, 0
  if snap then
    c = {}
    for r, p in pairs(coord) do c[ci + 1], c[ci + 2], c[ci + 3] = r, p[1], p[2] ; ci = ci + 3 end
  end
  local dt = 0
  if elro._stepPrevEnd then
    dt = (t0 - elro._stepPrevEnd) - (idle0 - (elro._stepPrevIdle or 0))
    if dt < 0 then dt = 0 end        -- clock skew across a yield; never report negative
  end
  local frame = { flat = c, label = label, focus = focus, blocker = blocker, pull = pull,
                  split = split, ksplit = ksplit, nsplit = nsplit, dt = dt,
                  kb = kb0, dkb = elro._stepPrevKb and (kb0 - elro._stepPrevKb) or 0 }
  -- fold any pending guillotine per-cut trace (from query_block_levers this iteration) into THIS
  -- frame, tying it to the room being placed; then clear it so it isn't re-shown on later steps.
  if elro._guilloTracePending then
    frame.guilloTrace = elro._guilloTracePending ; elro._guilloTracePending = nil
  end
  -- same fold for the CLOSURE driver's own account of itself (eqw_close): which back-edge it was
  -- asked to close, whether it had to do anything at all, and if it did, every option it ranked.
  if elro._closeTracePending then
    frame.closeTrace = elro._closeTracePending ; elro._closeTracePending = nil
  end
  -- always into the time log, additionally into the replay log under stepDebug --
  -- the SAME frame object in both. _stepLog is reset per compose; the time log is not.
  if snap then elro._stepLog[#elro._stepLog + 1] = frame end
  local L = elro._stepTimeLog or {} ; elro._stepTimeLog = L
  frame.seg = elro._stepTimeSeg or 1 ; L[#L + 1] = frame
  -- baselines for the NEXT step, all taken after the copy so the snapshot machinery
  -- (which is O(placed) and allocates) is charged to nobody
  elro._stepPrevEnd = elro.now_ms()
  elro._stepPrevIdle = elro.bg_idle_ms()
  elro._stepPrevKb = collectgarbage("count")
end

-- build (crooms, adj) from the map-viewer selection if any, else the current
-- room's whole area. Shared by the SPQR test commands.
function elro.sel_or_area()
  -- selection first, so this works OFFLINE (no !MAP -> no elro.current needed)
  local sel = (type(getMapSelection) == "function") and (getMapSelection() or {}) or {}
  local ids = sel.rooms or sel
  if type(ids) == "table" and next(ids) ~= nil then
    local crooms, inset = {}, {}
    for _, id in ipairs(ids) do if not inset[id] then inset[id] = true ; crooms[#crooms + 1] = id end end
    local adj = {}
    for _, r in ipairs(crooms) do
      adj[r] = {}
      for dn, dest in pairs(getRoomExits(r) or {}) do
        local d = elro.norm(dn) ; local de = elro.delta[d]
        if de and (de[1] ~= 0 or de[2] ~= 0) and inset[dest] then adj[r][d] = dest end
      end
    end
    return crooms, adj, "selection"
  end
  local cur = elro.current
  if not cur then return nil end
  local crooms, adj = area_adjacency(getRoomArea(cur))
  return crooms, adj, "area"
end

-- mapcur <id|area>: set the "current room" manually so area-based commands work offline.
-- An area name resolves via elro.find_area; the room chosen is the lowest id (deterministic).
function elro.set_current(spec)
  spec = tostring(spec or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local id = tonumber(spec)
  if not id then
    if spec == "" then
      cecho("\n<yellow>[elro]: usage: mapcur <room id|area name>\n<reset>") return
    end
    local aid, nm, amb = elro.find_area(spec)
    if amb then
      cecho("\n<yellow>[elro]: '" .. spec .. "' is ambiguous: " .. table.concat(amb, ", ") .. "\n<reset>")
      return
    end
    if not aid then
      cecho("\n<red>[elro]: no room id or area matching '" .. spec .. "'.\n<reset>") return
    end
    for _, r in ipairs(elro.cs_area_rooms(aid)) do
      if roomExists(r) and (not id or r < id) then id = r end
    end
    if not id then
      cecho("\n<red>[elro]: area '" .. nm .. "' has no rooms.\n<reset>") return
    end
  end
  if not roomExists(id) then
    cecho("\n<red>[elro]: no such room id.\n<reset>") return
  end
  elro.current = id
  local aid = getRoomArea(id)
  cecho(string.format("\n<green>[elro]: current = %d (area %s '%s')\n<reset>",
        id, tostring(aid), tostring((elro.cs_areas_swap() or {})[aid] or "?")))
end


-- mapcrossings: every crossing on the live map as the two edges that cross, and who licensed
-- it: `cost` (a crossCostTau quartet), `wire` (a proven forced pair), `-` (nobody).
function elro.crossings_report()
  local crooms, adj, label = elro.sel_or_area()
  if not crooms then
    cecho("\n<red>[elro]: select rooms or set 'mapcur <id>' first.\n<reset>") return
  end
  if type(getRoomCoordinates) ~= "function" then
    cecho("\n<red>[elro]: getRoomCoordinates unavailable.\n<reset>") return
  end
  local coord = {}
  for _, r in ipairs(crooms) do
    local x, y = getRoomCoordinates(r)
    if x then coord[r] = { x, y } end
  end
  local _, problist = elro.dash_problem_edges(coord, true)   -- nodraw: this is a report
  -- attribute by pair key, not by the quartet's four rooms: a face's quartet is only a representative
  local costK = {}
  for _, q in ipairs(elro._crossQuartets or {}) do
    for _, k1 in ipairs(q.ves or { ekey(q[1], q[2]) }) do
      for _, k2 in ipairs(q.hes or { ekey(q[3], q[4]) }) do
        costK[crosspair(k1, k2)] = q
      end
    end
  end
  local wireP = {}
  do
    elro._noYield = true
    local okW, W = pcall(elro.wire_cross, elro.walk_adj(adj))
    elro._noYield = nil
    if okW and W and W.pair then for k in pairs(W.pair) do wireP[k] = true end end
  end
  local rows, seen = {}, {}
  for _, pe in ipairs(problist or {}) do
    if pe.why == "cross" and pe.px then
      local k1, k2 = ekey(pe.u, pe.v), ekey(pe.px, pe.py)
      local key = crosspair(k1, k2)
      if not seen[key] then
        seen[key] = true
        local who = costK[key] and "cost" or (wireP[key] and "wire" or "-")
        rows[#rows + 1] = { a = k1, b = k2, who = who, key = key }
      end
    end
  end
  table.sort(rows, function(x, y)
    if x.who ~= y.who then return x.who > y.who end   -- licensed first, unlicensed last
    return x.key < y.key
  end)
  local nc, nw, nu = 0, 0, 0
  for _, r in ipairs(rows) do
    if r.who == "cost" then nc = nc + 1 elseif r.who == "wire" then nw = nw + 1 else nu = nu + 1 end
  end
  cecho(string.format("\n<cyan>[crossings] %s: %d crossing(s) -- %d licensed by cost, %d by a proven"
    .. " wire pair, %d unlicensed<reset>", label, #rows, nc, nw, nu))
  for _, r in ipairs(rows) do
    cecho(string.format("\n<%s>  %-13s x %-13s   %s<reset>",
      (r.who == "cost") and "green" or ((r.who == "wire") and "cyan" or "yellow"),
      r.a, r.b,
      (r.who == "cost") and "COST -- the analysis asked for this one"
        or ((r.who == "wire") and "wire -- proven forced" or "unlicensed -- the walk's own")))
  end
  if #(elro._crossQuartets or {}) > 0 then
    cecho("\n<grey>  cost quartets published this relayout:<reset>")
    for _, q in ipairs(elro._crossQuartets) do
      local got
      for _, r in ipairs(rows) do if costK[r.key] == q then got = r ; break end end
      -- A published quartet that did NOT become a crossing means the licence went unused.
      -- A face licenses a whole product, so a hit names which site was taken.
      local what = q.ves and string.format("%d wall(s) %s  x  %d bridge(s) %s", #q.ves,
                     table.concat(q.ves, " "), #q.hes, table.concat(q.hes, " "))
                   or string.format("%d, %d, %d, %d", q[1], q[2], q[3], q[4])
      cecho(string.format("\n<%s>    %s -- %s<reset>", got and "green" or "red", what,
        got and ("CROSSED at " .. got.a .. " x " .. got.b) or "NOT crossed (licence unused)"))
    end
  end
  cecho("\n")
end


-- mapcaps: read the CAP log pack_branches fills during an spqr render. For each branch
-- that could NOT slide clear, it records WHAT blocked it -- captured from the SLIDE
-- ATTEMPT, not the failed-fallback dump (whose coords are garbage). Classifies each
-- blocker by skeleton (block / road / branch): the blocker's piston is the lever the
-- resolver will pull to open room. Render the area with 'mapengine spqr' first.
function elro.dump_caps()
  local crooms, adj, label = elro.sel_or_area()
  if not crooms then
    cecho("\n<red>[elro]: select rooms or set 'mapcur <id>' first.\n<reset>") return
  end
  local log = elro._capLog or {}
  if #log == 0 then
    cecho("\n<yellow>[elro]: no CAP data recorded -- render this area with 'maprelayout this' first.\n<reset>")
    return
  end
  -- absorb-aware skeleton, to classify each blocker
  local blocks = elro.blocks_adj(crooms, adj)
  local realBlocks = {}
  for _, comp in ipairs(blocks) do
    if #comp > 1 then
      local base, n = {}, 0
      for _, e in ipairs(comp) do
        if not base[e[1]] then base[e[1]] = true ; n = n + 1 end
        if not base[e[2]] then base[e[2]] = true ; n = n + 1 end
      end
      realBlocks[#realBlocks + 1] = { base = base, n = n }
    end
  end
  table.sort(realBlocks, function(a, b) return a.n > b.n end)
  local rigidId = {}
  for _, rb in ipairs(realBlocks) do
    local already = true
    for r in pairs(rb.base) do if not rigidId[r] then already = false ; break end end
    if not already then
      -- Interior pendants are no longer folded into the block class (that needed a
      -- full NS layout just for an inside-test), so a pendant inside a block
      -- classifies as "road"; only the class label of a few interior rooms is coarser.
      for r in pairs(rb.base) do rigidId[r] = true end
    end
  end
  local artery = elro.classify_artery(crooms, adj, rigidId)
  local function cls(r)
    if r == nil then return "open?" end
    if rigidId[r] then return "block" end
    if artery[r] then return "road" end
    return "branch"
  end
  local isBridge = {}
  for _, comp in ipairs(blocks) do
    if #comp == 1 then isBridge[ekey(comp[1][1], comp[1][2])] = true end
  end
  -- the LEVER: nearest Tarjan bridge on the path from the branch attach to the blocker.
  -- Extending it shifts the blocker side away -> opens room. nil = attach and blocker
  -- share a 2-core (no bridge between them) = genuinely stuck (piston-group territory).
  local function sepBridge(a, b)
    if not a or not b then return nil end
    local par, q, qh = { [a] = a }, { a }, 1
    while qh <= #q do
      local u = q[qh] ; qh = qh + 1
      if u == b then break end
      for _, v in each_exit(adj[u]) do if par[v] == nil then par[v] = u ; q[#q + 1] = v end end
    end
    if par[b] == nil then return nil end
    local cur = b
    while cur ~= a do
      local p = par[cur]
      if isBridge[ekey(cur, p)] then return cur .. "-" .. p end
      cur = p
    end
    return nil
  end

  -- inward pendant failures (stage="inward"): separate section
  local inwardLog, packLog, walkLog, blockLog = {}, {}, {}, {}
  for _, c in ipairs(log) do
    if c.stage == "inward" then inwardLog[#inwardLog+1] = c
    elseif c.stage == "walk" then walkLog[#walkLog+1] = c
    elseif c.stage == "block" then blockLog[#blockLog+1] = c
    else packLog[#packLog+1] = c end
  end
  if #blockLog > 0 then
    cecho(string.format("\n<cyan>[elro] %s: %d block unit(s) STUCK on insert -> leftover<reset>", label, #blockLog))
    for _, c in ipairs(blockLog) do
      local bk = c.blocker and cls(c.blocker) or "?"
      cecho(string.format("\n  unit %dr entry %s off %s %s  blocker %s [%s]  <red>%s<reset>",
        c.n or 0, tostring(c.room), tostring(c.A), tostring(c.dir), tostring(c.blocker), bk, c.reason or "?"))
      -- per-iteration candidate counts (each iteration resolved one colliding block room)
      for ti, tr in ipairs(c.tries or {}) do
        cecho(string.format("\n      iter %d: room %s blk %s  cand=%d (guillo raw/kept/rank=%d/%d/%d, casc=%d cross=%d roomedge=%d attach=%d)  -> %s",
          ti, tostring(tr.r), tostring(tr.blocker), tr.ncands or 0, tr.guilloRaw or 0, tr.guilloKept or 0,
          tr.guilloRanked or 0, tr.nCasc or 0, tr.nCross or 0, tr.nRE or 0, tr.nAttach or 0,
          tr.picked and string.format("<green>pulled %s d%s<reset>", tostring(tr.picked.kind), tostring(tr.picked.dist))
            or "<red>NO clean lever<reset>"))
      end
      -- the final (stuck) iteration's rejected candidates, best-ranked first
      for _, rk in ipairs(c.ranked or {}) do
        cecho(string.format("\n        %s %s  score=%s dist=%s  <yellow>%s<reset>",
          tostring(rk.kind), tostring(rk.ek), tostring(rk.score and string.format("%.0f", rk.score) or "?"),
          tostring(rk.dist), tostring(rk.why)))
      end
    end
    cecho("\n")
  end
  if #walkLog > 0 then
    cecho(string.format("\n<cyan>[elro] %s: %d walked room(s) stuck -> leftover<reset>", label, #walkLog))
    for _, c in ipairs(walkLog) do
      local bk = c.blocker and cls(c.blocker) or "?"
      cecho(string.format("\n  room %s off %s %s  conflict %s with %s [%s]  reason <red>%s<reset>",
        tostring(c.room), tostring(c.A), tostring(c.dir), tostring(c.kind),
        tostring(c.blocker), bk, c.reason or "?"))
      if c.tries then
        for ti, tr in ipairs(c.tries) do
          local res
          if tr.picked then
            res = string.format("<green>pulled %s d%s<reset>", tostring(tr.picked.kind), tostring(tr.picked.dist))
          elseif tr.nEmpty == 0 then
            res = string.format("<red>no into-empty lever (%d cand)<reset>", tr.ncands)
          else
            res = string.format("<red>%d into-empty but all make a crossing<reset>", tr.nEmpty)
          end
          cecho(string.format("\n      try %d: %s with %s  -> %s",
            ti, tostring(tr.kind), tostring(tr.blocker), res))
        end
      end
    end
    cecho("\n")
  end
  if #inwardLog > 0 then
    cecho(string.format("\n<cyan>[elro] %s: %d inward pendant tree(s) fell through to slide_pendants<reset>", label, #inwardLog))
    for _, c in ipairs(inwardLog) do
      local bstr = c.blocker and tostring(c.blocker) or "none"
      local bk = c.blocker and cls(c.blocker) or "?"
      local kstr = c.kind and (" via " .. c.kind) or ""
      cecho(string.format("\n  anchor %s  room %s  BLOCKED-BY %s [%s]%s  reason <red>%s<reset>",
        tostring(c.A), tostring(c.room), bstr, bk, kstr, c.reason or "?"))
      -- per-room attempt trace: every cell the room tried + what blocked it + whether a
      -- piston pull cleared it. The trailing entries (all pulled=false) are where it gave up.
      if c.tries and #c.tries > 0 then
        for ti, tr in ipairs(c.tries) do
          local tgt = tr.target and (tr.target[1] .. "," .. tr.target[2]) or "?"
          local pulled
          if tr.pulled then
            local ax = tr.pull and (tr.pull.is_h and "H" or "V") or "?"
            local sh = tr.pull and string.format("(%d,%d)", tr.pull.sx or 0, tr.pull.sy or 0) or ""
            pulled = string.format("<green>pulled %s%s<reset>", ax, sh)
          else
            pulled = "<red>NO GROUP<reset>"
          end
          cecho(string.format("\n      try %d: at %s  blk %s [%s]  -> %s",
            ti, tgt, tostring(tr.blocker), tostring(tr.kind), pulled))
        end
      end
    end
    cecho("\n")
  end

  local byClass = {}
  local solvable, stuck = 0, 0
  cecho(string.format("\n<cyan>[elro] %s: %d CAPed branch(es) -- blocker from the slide attempt<reset>",
    label, #packLog))
  local sorted = {} ; for _, c in ipairs(packLog) do sorted[#sorted + 1] = c end
  table.sort(sorted, function(a, b) return a.n > b.n end)
  for _, c in ipairs(sorted) do
    local k = cls(c.blocker)
    byClass[k] = (byClass[k] or 0) + 1
    -- "lever" = the bridge actually pulled (from pulls[1].ek), falling back to sepBridge
    -- prediction for unresolved cases where no pull landed.
    local actualLever = c.pulls and c.pulls[1] and c.pulls[1].ek
    local lever = actualLever or sepBridge(c.A, c.blocker)
    if lever then solvable = solvable + 1 else stuck = stuck + 1 end
    local res = c.result and (c.result == "resolved" and ("<green>" .. c.result .. "<reset>")
      or ("<red>" .. c.result .. "<reset>")) or "?"
    local leverLabel = lever and (actualLever and lever or ("<yellow>" .. lever .. "?<reset>")) or "<red>none<reset>"
    cecho(string.format("\n  branch n=%d attach %s via %s  BLOCKED-BY %s [%s]  lever %s  result %s",
      c.n, tostring(c.A), tostring(c.dir), tostring(c.blocker), k, leverLabel, res))
    -- pulls: each shift the resolve applied (amount @ direction). Two distinct directions
    -- = a placement that needed extension on both axes -- the over-extension suspect.
    if c.pulls and #c.pulls > 0 then
      local parts, dirs = {}, {}
      for _, pp in ipairs(c.pulls) do
        local dn = (pp.dy > 0 and "N") or (pp.dy < 0 and "S") or (pp.dx > 0 and "E") or (pp.dx < 0 and "W") or "?"
        dirs[dn] = true
        parts[#parts + 1] = pp.amt .. dn .. "(" .. pp.n .. "r, " .. (pp.ek or "?") .. ")"
      end
      local nd = 0 ; for _ in pairs(dirs) do nd = nd + 1 end
      cecho(string.format("\n      pulls: %s%s", table.concat(parts, " "),
        nd >= 2 and "  <red>[TWO DIRECTIONS]<reset>" or ""))
    end
  end
  if #packLog > 0 then
    cecho(string.format("\n<cyan>  blockers: block %d, road %d, branch %d, other %d  |  <green>%d piston-solvable<reset>, <red>%d stuck<reset>\n",
      byClass.block or 0, byClass.road or 0, byClass.branch or 0, byClass["open?"] or 0, solvable, stuck))
  end
end

-- VISUAL DIAGNOSTIC: dash every edge that CROSSES another edge or runs OVER a room
-- cell, so layout defects (mostly the per-room-slide fallback) are visible at a
-- glance. Edge set is read live from getRoomExits over the rooms in `coord`; defects
-- are translation-invariant so we test on `coord` directly. Overrides the edge's auto
-- line with a red dash. Cleared with all custom lines on the next relayout.
function elro.dash_problem_edges(coord, nodraw)
  if type(getRoomExits) ~= "function" then return end
  if not nodraw and type(addCustomLine) ~= "function" then return end
  local function key(x, y) return x .. ":" .. y end
  local occ = {}
  local cellRooms = {}
  for r, p in pairs(coord) do
    local k = key(p[1], p[2])
    occ[k] = r
    cellRooms[k] = cellRooms[k] or {} ; cellRooms[k][#cellRooms[k] + 1] = r
  end
  -- edge list (dedup u<v), 2D edges only
  local edges, seenE = {}, {}
  for u, p in pairs(coord) do
    for dn, v in pairs(getRoomExits(u) or {}) do
      if coord[v] then
        local d = elro.norm(dn)
        local de = elro.delta[d]
        if de and (de[1] ~= 0 or de[2] ~= 0) then
          local ek = ekey(u, v)
          if not seenE[ek] then
            seenE[ek] = true
            edges[#edges + 1] = { u = u, v = v, d = d,
              x1 = p[1], y1 = p[2], x2 = coord[v][1], y2 = coord[v][2],
              rd = (de[1] ~= 0 and de[2] ~= 0) }   -- real diagonal exit (NE/NW/SE/SW)
          end
        end
      end
    end
  end
  local function seg_cells(e, f) return seg(e.x1, e.y1, e.x2, e.y2, f) end
  -- bound the work for the giant world area: a hugely stretched edge expands into
  -- hundreds of cells / dozens of buckets and would hang the pass. An edge spanning
  -- more than MAXSPAN is itself a gross defect -> flag it directly and skip its scan
  -- + bucketing. Dense buckets beyond BUCKETCAP skip the O(k^2) pairwise.
  local MAXSPAN, BUCKETCAP = 48, 80
  local function span(e) return math.max(math.abs(e.x2 - e.x1), math.abs(e.y2 - e.y1)) end
  local problem, why, onRoom, crossWith = {}, {}, {}, {}
  -- ROOM-ON-EDGE: an interior cell of the edge holds a (non-endpoint) room
  for i, e in ipairs(edges) do
    if span(e) > MAXSPAN then
      problem[i] = true ; why[i] = "long"
    else
      seg_cells(e, function(x, y)
        local rid = occ[key(x, y)]
        if rid and rid ~= e.u and rid ~= e.v then
          problem[i] = true ; why[i] = why[i] or "on-room" ; onRoom[i] = onRoom[i] or rid
        end
      end)
    end
  end
  -- EDGE-CROSSING: coarse-bucket by bbox (catches diagonal X-crossings that share no
  -- integer cell), then precise segment-intersection on co-bucketed pairs.
  local CS, bucket = 8, {}
  for i, e in ipairs(edges) do
    if span(e) <= MAXSPAN then
      for cx = math.floor(math.min(e.x1, e.x2) / CS), math.floor(math.max(e.x1, e.x2) / CS) do
        for cy = math.floor(math.min(e.y1, e.y2) / CS), math.floor(math.max(e.y1, e.y2) / CS) do
          local k = cx .. ":" .. cy ; bucket[k] = bucket[k] or {} ; bucket[k][#bucket[k] + 1] = i
        end
      end
    end
  end
  local function crosses(e1, e2)
    if e1.u == e2.u or e1.u == e2.v or e1.v == e2.u or e1.v == e2.v then return false end
    -- two genuine diagonal exits crossing is geometry the graph demands (e.g. both
    -- diagonals of a K4 quad) -- not a layout defect, so don't flag it.
    if e1.rd and e2.rd then return false end
    local d1 = ori(e2.x1, e2.y1, e2.x2, e2.y2, e1.x1, e1.y1)
    local d2 = ori(e2.x1, e2.y1, e2.x2, e2.y2, e1.x2, e1.y2)
    local d3 = ori(e1.x1, e1.y1, e1.x2, e1.y2, e2.x1, e2.y1)
    local d4 = ori(e1.x1, e1.y1, e1.x2, e1.y2, e2.x2, e2.y2)
    return ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0))
  end
  local tested = {}
  for _, list in pairs(bucket) do
    if #list <= BUCKETCAP then
      for a = 1, #list - 1 do
        for b = a + 1, #list do
          local i, j = list[a], list[b]
          local pk = (i < j) and (i * 100000 + j) or (j * 100000 + i)
          if not tested[pk] then
            tested[pk] = true
            if crosses(edges[i], edges[j]) then
              problem[i] = true ; why[i] = why[i] or "cross" ; crossWith[i] = crossWith[i] or j
              problem[j] = true ; why[j] = why[j] or "cross" ; crossWith[j] = crossWith[j] or i
            end
          end
        end
      end
    end
  end
  local ndash, problist = 0, {}
  for i, e in ipairs(edges) do
    if problem[i] then
      ndash = ndash + 1
      local pe = { u = e.u, v = e.v, why = why[i] or "?", onroom = onRoom[i] }
      if crossWith[i] then local o = edges[crossWith[i]] ; pe.px, pe.py = o.u, o.v end
      problist[#problist + 1] = pe
      if not nodraw then
        pcall(addCustomLine, e.u, e.v, e.d, "dash line", { 255, 60, 60 }, true)
        -- override the REVERSE half too, else v's auto line shows solid under the dash
        local rd
        for dn, dest in pairs(getRoomExits(e.v) or {}) do
          if dest == e.u then rd = elro.norm(dn) ; break end
        end
        if rd then pcall(addCustomLine, e.v, e.u, rd, "dash line", { 255, 60, 60 }, true) end
      end
    end
  end
  -- ROOM-ON-ROOM overlap: two rooms on the same cell. One is drawn over the other (looks
  -- like a room vanished) and the edge tests miss it entirely, so surface it explicitly.
  for _, rs in pairs(cellRooms) do
    if #rs > 1 then
      table.sort(rs)
      for j = 2, #rs do
        ndash = ndash + 1
        problist[#problist + 1] = { u = rs[1], v = rs[j], why = "overlap" }
      end
    end
  end
  return ndash, problist
end


-- Half-length blue stubs for cross-area exits, replacing Mudlet's long portal arrow. `roomMap`
-- is any table keyed by room id; coords are read live, so call after positioning.
-- Where THIS DOOR's cell of the maze block was placed, or nil when there is none
-- (knob off, or the solve published nothing). Per door, not per cluster: a maze
-- wide enough to need several cells gives each door its own, which is the whole
-- point of the block. The lookup is the one area_adjacency published -- the cell
-- assignment lives there, and recomputing it here would be a second copy.
function elro.maze_door_pos(areaID, room, dir)
  local byArea = elro._mazeDoor
  local doors = byArea and byArea[areaID]
  if not doors or not elro._mazePos then return nil end
  local byDir = doors[room]
  local vid = byDir and byDir[dir]
  return vid and elro._mazePos[vid] or nil
end

function elro.draw_area_stubs(roomMap)
  if type(addCustomLine) ~= "function" or type(getRoomExits) ~= "function"
     or type(getRoomCoordinates) ~= "function" then return end
  for r in pairs(roomMap) do
    if roomExists(r) then
      local rx, ry = getRoomCoordinates(r)
      if rx then
        local ra = getRoomArea(r)
        for dname, dest in pairs(getRoomExits(r) or {}) do
          local d = elro.norm(dname)
          local del = elro.delta[d]
          if del and (del[1] ~= 0 or del[2] ~= 0)
             and dest and roomExists(dest) and getRoomArea(dest) ~= ra then
            local hx, hy = rx + del[1] * 0.5, ry + del[2] * 0.5
            -- a stub INTO a maze submap is drawn in the maze colour so the parent map
            -- shows at a glance which exits lead into an untruthful area; else blue.
            local col = { 80, 160, 255 }
            local dn = elro.areaName and elro.areaName(getRoomArea(dest))
            local mazebound = elro.is_maze_area and elro.is_maze_area(dn)
            if mazebound then
              col = (elro.classColours and elro.classColours.maze) or { 150, 40, 200 }
            end
            -- ⭐ THE SPOKE. When the solver placed a vertex for this maze, the door
            -- runs all the way TO it instead of stopping half a cell out -- which is
            -- the whole point of PLAN-maze: every door of one cluster ends at the same
            -- point, so the map says "these are the same maze, and it is here", and it
            -- says it truthfully because the geometry was solved for it.
            local vp = mazebound and elro.maze_door_pos(ra, r, d) or nil
            -- ⛔ EVERY DOOR DRAWS, dogleg and all. Two earlier cuts gated this --
            -- first on truthfulness, then on distance -- and both were answering the
            -- wrong question: gating it stopped leowon showing rooms that really do
            -- connect to its maze. Drawing is an OVERLAY; a bent spoke that crosses
            -- something costs nothing and still tells you the connection is there.
            -- What must never be paid for is the BASE LAYOUT, and that is guarded
            -- where it belongs -- in the solve, by the veto in canvas.lua, which is
            -- what took lyr's long ugly spoke away by removing its cause.
            if vp then
              -- Three points, always. The middle one is half a cell along the door's
              -- REAL direction, so the departure is a fact even when the rest is only
              -- routing -- the same rule draw_demoted follows. When the solver did
              -- satisfy this door the midpoint is collinear and the kink vanishes, so
              -- a straight spoke means "truthful" without needing a second style.
              pcall(addCustomLine, r,
                { { rx, ry, 0 }, { hx, hy, 0 }, { vp[1], vp[2], 0 } }, d,
                "dash line", col, true)
            else
              pcall(addCustomLine, r, { { rx, ry, 0 }, { hx, hy, 0 } }, d,
                "solid line", col, true)
            end
          end
        end
      end
    end
  end
end


-- Demoted edges (dropped by the equations) still exist and are drawn magenta/dotted, allowed
-- to cross other geometry, as a continuation of Mudlet's own stub (Mudlet always draws it).
-- Trap sinks are highlighted in the same magenta only when spikes are on (the spike does not
-- point at its target). Highlights are not custom lines, so the off path must unhighlight.
function elro.paint_trap_sinks()
  if not elro.demotedSpikes then
    if type(unHighlightRoom) == "function" then
      for r in pairs(elro._trapSinks or {}) do
        if roomExists(r) then pcall(unHighlightRoom, r) end
      end
    end
    return
  end
  if type(highlightRoom) ~= "function" then return end
  local col = (elro.classColours and elro.classColours.demoted) or { 255, 60, 220 }
  for r in pairs(elro._trapSinks or {}) do
    if roomExists(r) then
      pcall(highlightRoom, r, col[1], col[2], col[3], col[1], col[2], col[3], 1, 200, 50)
    end
  end
end

-- The one definition of "the drawing tells the truth about this exit", shared by both overlay
-- renderers so they cannot contradict each other. Direction, not distance: an orthogonal exit
-- needs zero off-axis offset and the right sign; a diagonal needs the right quadrant.
function elro.drawn_direction_ok(de, dx, dy)
  if de[1] == 0 then
    return dx == 0 and dy * de[2] > 0
  elseif de[2] == 0 then
    return dy == 0 and dx * de[1] > 0
  end
  return dx * de[1] > 0 and dy * de[2] > 0
end

-- ---- SHARED DRAW-TIME GEOMETRY ---------------------------------------------
-- Live coords: callers must run after positioning.
function elro.cell_census(coord)
  local occ = {}
  for r in pairs(coord) do
    if roomExists(r) then
      local x, y = getRoomCoordinates(r)
      if x then occ[x .. ":" .. y] = r end
    end
  end
  return occ
end

-- Exact: does this segment pass through the CENTRE of an occupied cell? Integer coords make
-- the cross product exact, so no epsilon (elro.onEdgeTol > 0 re-enables a fuzzy test).
-- Use blocked_by for routing; this one is for reporting.
function elro.room_on_segment(occ, ax, ay, bx, by, a, b)
  local ex, ey = bx - ax, by - ay
  local len2 = ex * ex + ey * ey
  if len2 == 0 then return nil end
  local tol = elro.onEdgeTol or 0
  for cx = math.ceil(math.min(ax, bx)), math.floor(math.max(ax, bx)) do
    for cy = math.ceil(math.min(ay, by)), math.floor(math.max(ay, by)) do
      local o = occ[cx .. ":" .. cy]
      if o and o ~= a and o ~= b then
        -- strictly BETWEEN the endpoints, so a room just beyond the far end never counts
        local dot = (cx - ax) * ex + (cy - ay) * ey
        if dot > 0 and dot < len2 then
          local cross = (cx - ax) * ey - (cy - ay) * ex
          if cross == 0 then return o end
          if tol > 0 and (cross * cross) <= (tol * tol * len2) then return o end
        end
      end
    end
  end
  return nil
end


-- Does the straight run p->q pass through a room that is not an endpoint?
-- Sampled 4x per cell so a 1-cell room cannot be stepped over.
function elro.blocked_by(occ, px, py, qx, qy, a, b)
  local dx, dy = qx - px, qy - py
  local steps = math.max(math.abs(dx), math.abs(dy)) * 4
  if steps < 1 then return nil end
  for i = 1, steps - 1 do
    local t = i / steps
    local cx = math.floor(px + dx * t + 0.5)
    local cy = math.floor(py + dy * t + 0.5)
    local o = occ[cx .. ":" .. cy]
    if o and o ~= a and o ~= b then return o end
  end
  return nil
end

function elro.draw_demoted(coord)
  elro.paint_trap_sinks()
  local dem = elro._demoted
  if not dem or #dem == 0 or type(addCustomLine) ~= "function"
     or type(getRoomCoordinates) ~= "function" then return end
  local col = (elro.classColours and elro.classColours.demoted) or { 255, 60, 220 }
  local occ = elro.cell_census(coord)
  local function blocked_by(px, py, qx, qy, a, b)
    return elro.blocked_by(occ, px, py, qx, qy, a, b)
  end
  for _, e in ipairs(dem) do
    local a, b, d = e.r, e.x, e.d
    if coord[a] and coord[b] and roomExists(a) and roomExists(b) then
      local ax, ay = getRoomCoordinates(a)
      local bx, by = getRoomCoordinates(b)
      local va = elro.delta[d]
      -- Only mark a demoted edge the drawing actually gets wrong (demotion is about the
      -- equations, this is about the drawing). elro.demotedMarkAll marks every one.
      local truthful = false
      if ax and bx and va and not elro.demotedMarkAll then
        truthful = elro.drawn_direction_ok(va, bx - ax, by - ay)
      end
      if ax and bx and va and not truthful then
        -- Single bend: start at the tip of Mudlet's own stub (which cannot be suppressed; a
        -- custom line is drawn BESIDE the native one), run straight to the far centre. No
        -- arrival stub: only the departure direction is a fact about this edge.
        -- demotedStub = Mudlet's stub length (~2/3 cell); demotedFork = fraction along it we
        -- branch. Forking early does not shorten anything, so keep it near the tip.
        local st = (elro.demotedStub or (2 / 3)) * TUNE.demotedFork
        local pts
        -- trap exit spikes are opt-in (elro.demotedSpikes): they suppress nothing and leave a
        -- misleading native line unmarked
        if e.noDraw and elro.demotedSpikes then
          -- short spike with no target end: a teleport has no geometry worth asserting
          local ts = TUNE.trapSpike
          pts = { { ax, ay, 0 }, { ax + va[1] * ts, ay + va[2] * ts, 0 } }
        else
          pts = { { ax + va[1] * st, ay + va[2] * st, 0 }, { bx, by, 0 } }
          -- bow around an intervening room on whichever side is clear, else stay straight
          local blk = blocked_by(pts[1][1], pts[1][2], bx, by, a, b)
          if blk then
            local mx, my = (pts[1][1] + bx) / 2, (pts[1][2] + by) / 2
            local ex, ey = bx - pts[1][1], by - pts[1][2]
            local len = math.sqrt(ex * ex + ey * ey)
            if len > 0 then
              -- a full cell: blocked_by tests the nearest cell, so a half-cell offset still
              -- rounds onto the blocked room
              local bow = TUNE.demotedBow
              local nx, ny = -ey / len * bow, ex / len * bow
              for _, sgn in ipairs({ 1, -1 }) do
                local px, py = mx + nx * sgn, my + ny * sgn
                if not blocked_by(pts[1][1], pts[1][2], px, py, a, b)
                   and not blocked_by(px, py, bx, by, a, b) then
                  pts = { pts[1], { px, py, 0 }, { bx, by, 0 } } ; break
                end
              end
            end
          end
        end
        -- short direction key: this build files custom lines under "n", not "north"
        pcall(addCustomLine, a, pts, elro.shortDir(d), "dot line", col, false)
        -- the kept reverse direction is left to Mudlet
      end
    end
  end
end


-- Residual overlay: edges the engine KEPT but drew off-axis (red), and rooms buried under a
-- stretched edge (yellow ring). See classColours.residual.
function elro.draw_residual(coord)
  if type(addCustomLine) ~= "function" or type(getRoomCoordinates) ~= "function"
     or type(getRoomExits) ~= "function" then return end
  local occ = elro.cell_census(coord)
  local red = (elro.classColours and elro.classColours.residual) or { 255, 60, 60 }
  local yel = (elro.classColours and elro.classColours.occluded) or { 255, 210, 0 }
  -- Highlights are not custom lines, so clear last relayout's rings by hand, and only for
  -- rooms on THIS canvas. Driven by the `occl` userdata rather than the live table so the
  -- ring survives a restart. `occl` is redrawable overlay state, not graph state (no cs_dirty).
  elro._onEdgeRooms = elro._onEdgeRooms or {}
  for r in pairs(coord) do
    if roomExists(r) and getRoomUserData(r, "occl") == "1" then
      setRoomUserData(r, "occl", "")
      elro.highlight_paint(r)          -- falls back to maze / terrain / nothing
    end
    elro._onEdgeRooms[r] = nil
  end
  -- one custom line per room+direction: never take a slot draw_demoted or draw_area_stubs claimed
  local taken = {}
  if type(getCustomLines) == "function" then
    for r in pairs(coord) do
      local cl = getCustomLines(r)
      if type(cl) == "table" then
        for k in pairs(cl) do taken[r .. ":" .. k] = true end
      end
    end
  end
  local st = (elro.demotedStub or (2 / 3)) * TUNE.demotedFork
  local function two_way(a, b)
    for _, t in pairs(getRoomExits(b) or {}) do if t == a then return true end end
    return false
  end
  -- style carries directionality (dashed = one-way, matching Mudlet's stub beside ours).
  -- fromStub: start at the stub tip when the native line lies (red); centre-to-centre when
  -- the edge is truthful and only needs recolouring (yellow).
  local function mark(a, b, d, de, col, fromStub)
    if taken[a .. ":" .. elro.shortDir(d)] then return false end
    local ax, ay = getRoomCoordinates(a)
    local bx, by = getRoomCoordinates(b)
    if not (ax and bx) then return false end
    local pts = fromStub
      and { { ax + de[1] * st, ay + de[2] * st, 0 }, { bx, by, 0 } }
      or  { { ax, ay, 0 }, { bx, by, 0 } }
    pcall(addCustomLine, a, pts, elro.shortDir(d),
          two_way(a, b) and "solid line" or "dash line", col, false)
    taken[a .. ":" .. elro.shortDir(d)] = true
    return true
  end

  local n, onEdge, inbound = 0, {}, {}
  for a in pairs(coord) do
    if roomExists(a) then
      local ax, ay = getRoomCoordinates(a)
      for dn, b in pairs(getRoomExits(a) or {}) do
        local d = elro.norm(dn)
        local de = elro.delta[d]
        if ax and de and coord[b] and roomExists(b) and b ~= a
           and (de[1] ~= 0 or de[2] ~= 0) then
          local bx, by = getRoomCoordinates(b)
          if bx then
            local dx, dy = bx - ax, by - ay
            if (dx ~= 0 or dy ~= 0) and not elro.drawn_direction_ok(de, dx, dy) then
              -- CATEGORY 4: kept by the equations, drawn off-axis. Red.
              if mark(a, b, d, de, red, true) then n = n + 1 end
            elseif elro.markOnEdge ~= false
                   and (math.abs(dx) > 1 or math.abs(dy) > 1) then
              -- room-on-edge: mark the buried ROOM and its inbound edges, not the (truthful)
              -- long edge. Only a stretched edge can bury anything.
              local o = elro.room_on_segment(occ, ax, ay, bx, by, a, b)
              if o then onEdge[o] = true end
            end
            -- inbound index for the marking pass below
            if not inbound[b] then inbound[b] = {} end
            table.insert(inbound[b], { a = a, d = d, de = de })
            if false then
            end
          end
        end
      end
    end
  end

  local nOcc, nEdge = 0, 0
  local ids = {}
  for r in pairs(onEdge) do ids[#ids + 1] = r end
  table.sort(ids)                       -- deterministic across relayouts
  for _, r in ipairs(ids) do
    nOcc = nOcc + 1
    elro._onEdgeRooms[r] = true
    -- record, then paint from the record: elro.highlight_paint owns the one highlight slot
    -- (occluded > maze > terrain) and draws the ring
    setRoomUserData(r, "occl", "1")
    elro.highlight_paint(r)
    -- mark the edges leading TO the room (outbound ones would run away along the burying
    -- axis and mislead). Every way in is marked; onEdgeHideUnfollowable drops buried ones.
    for _, inb in ipairs(inbound[r] or {}) do
      local a, d, de = inb.a, inb.d, inb.de
      local ok = true
      if elro.onEdgeHideUnfollowable then
        local ax, ay = getRoomCoordinates(a)
        local bx, by = getRoomCoordinates(r)
        ok = not (ax and bx and elro.room_on_segment(occ, ax, ay, bx, by, a, r))
      end
      if ok and mark(a, r, d, de, yel) then nEdge = nEdge + 1 end
    end
  end
  elro._residualCount, elro._occludedCount = n, nOcc
  if n + nOcc > 0 then
    elro.tr(string.format(
      "draw: %d sheared edge(s) red; %d room(s) buried under an edge marked yellow with %d of their own exit(s)",
      n, nOcc, nEdge))
  end
end

-- Wipe every fake portal-label room (tagged elro_fake) -- cleanup utility for the parked
-- cross-area-name experiment; safe to run anytime. Run: lua elro.fakepurge()
-- No caller by design (invoked by hand); keep.
function elro.fakepurge()
  if type(getRooms) ~= "function" or type(deleteRoom) ~= "function" then
    cecho("\n<red>[diag]: getRooms/deleteRoom missing.\n<reset>") return
  end
  local n = 0
  for id in pairs(getRooms() or {}) do
    if roomExists(id) and getRoomUserData(id, "elro_fake") == "1" then
      pcall(deleteRoom, id) ; n = n + 1
    end
  end
  if type(updateMap) == "function" then updateMap() end
  cecho(string.format("\n<green>[diag]: purged %d fake room(s).\n<reset>", n))
end


-- mapsteps / mapstep: replay the assembly steps recorded in elro._stepLog (populated only
-- under elro.stepDebug, reset at the top of every compose_spqr_adj). mapsteps lists them;
-- mapstep [n] writes that step's coordinates to the live map with focus (green) and
-- blocker (red) highlighted and the pulled cut in orange.
function elro.dump_steps()
  local log = elro._stepLog or {}
  if #log == 0 then
    cecho("\n<yellow>[elro]: no step data -- set 'lua elro.stepDebug = true' then run 'maprelayout this'.\n<reset>")
    return
  end
  -- PER-STEP TIME. Colour the outliers so a slow step is findable by eye in a log of hundreds:
  -- red >= 10x the mean, yellow >= 3x. The mean is over steps 2..n (step 1 has no predecessor).
  local total, nT, mx = 0, 0, 0
  for i, s in ipairs(log) do
    if i > 1 and s.dt then total = total + s.dt ; nT = nT + 1 ; if s.dt > mx then mx = s.dt end end
  end
  local mean = (nT > 0) and (total / nT) or 0
  local function dtCol(dt)
    if not dt or mean <= 0 then return "grey" end
    if dt >= 10 * mean then return "red" elseif dt >= 3 * mean then return "yellow" end
    return "grey"
  end
  cecho(string.format("\n<cyan>[elro] %d placement steps<reset> <grey>(%.0fms total, mean %.1fms, max %.0fms)<reset>\n",
    #log, total, mean, mx))
  for i, s in ipairs(log) do
    cecho(string.format("<yellow>  %2d.<reset> <%s>%7.1fms<reset> <yellow>%s<reset>\n",
      i, dtCol(s.dt), s.dt or 0, s.label or "?"))
  end
  -- ...and the ranked worst offenders, which is what you actually want when hunting a slow relayout.
  if nT > 0 then
    local ord = {}
    for i, s in ipairs(log) do if i > 1 and s.dt then ord[#ord + 1] = { i = i, s = s } end end
    table.sort(ord, function(a, b) return a.s.dt > b.s.dt end)
    cecho("<cyan>  slowest steps:<reset>\n")
    for k = 1, math.min(#ord, 10) do
      local e = ord[k]
      -- the two biggest buckets inline, so the worst offenders are diagnosed from the LIST rather
      -- than by stepping to each one.
      local top = ""
      if e.s.split and next(e.s.split) then
        local ks = {}
        for kk in pairs(e.s.split) do ks[#ks + 1] = kk end
        table.sort(ks, function(a, b) return e.s.split[a] > e.s.split[b] end)
        local p = {}
        for i = 1, math.min(#ks, 2) do p[#p + 1] = string.format("%s %.0f", ks[i], e.s.split[ks[i]]) end
        top = "  <cyan>[" .. table.concat(p, ", ") .. "]<grey>"
      end
      cecho(string.format("<grey>   %7.1fms (%4.1f%%)  step %d: %s%s<reset>\n",
        e.s.dt, total > 0 and (100 * e.s.dt / total) or 0, e.i, e.s.label or "?", top))
    end
  end
  cecho("<grey>  'mapstep <roomid>' to stop just before a room is placed; 'mapstep step N' to view a step; 'mapstep' to advance; 'mapstep off' to restore.<reset>\n")
end

-- maptop [n]: the slowest steps across the whole relayout, from elro.stepTime's snapshot-free
-- log (stepDebug numbers are inflated by its per-step coord copy). Then the same time grouped
-- by label kind, then the tail.
function elro.dump_steptop(n)
  n = tonumber(n) or 15
  local log = elro._stepTimeLog
  -- stepDebug frames carry `flat`; those numbers include the per-step coord copy and are inflated.
  local src = (log and log[1] and log[1].flat)
    and "stepDebug -- PERTURBED, +1 full coord copy per step; use stepTime alone for real ms"
    or "stepTime"
  if not log or #log == 0 then
    cecho("\n<yellow>[elro]: no step timings -- 'lua elro.stepTime = true' then relayout." ..
          " Add 'lua elro.timeGuillo = true' for the per-step bucket split.\n<reset>")
    return
  end
  local total, segs = 0, {}
  for i, s in ipairs(log) do
    if i > 1 and s.dt then total = total + s.dt end
    local g = s.seg or 1 ; segs[g] = (segs[g] or 0) + 1
  end
  local nseg = 0 ; for _ in pairs(segs) do nseg = nseg + 1 end
  cecho(string.format("\n<cyan>[elro] %d step(s) over %d canvas(es), %.0fms total<reset> <grey>(%s)<reset>\n",
    #log, nseg, total, src))
  local ord = {}
  for i, s in ipairs(log) do if i > 1 and s.dt then ord[#ord + 1] = { i = i, s = s } end end
  table.sort(ord, function(a, b)
    if a.s.dt ~= b.s.dt then return a.s.dt > b.s.dt end
    return a.i < b.i                      -- stable: equal steps must not reorder between runs
  end)
  local shown = 0
  for k = 1, math.min(#ord, n) do
    local e = ord[k] ; shown = shown + e.s.dt
    local top = ""
    if e.s.split and next(e.s.split) then
      local ks = {}
      for kk in pairs(e.s.split) do ks[#ks + 1] = kk end
      table.sort(ks, function(a, b)
        if e.s.split[a] ~= e.s.split[b] then return e.s.split[a] > e.s.split[b] end
        return a < b
      end)
      local pp = {}
      for j = 1, math.min(#ks, 3) do pp[#pp + 1] = string.format("%s %.0f", ks[j], e.s.split[ks[j]]) end
      top = "  <cyan>[" .. table.concat(pp, ", ") .. "]<reset>"
    end
    cecho(string.format("<yellow>%3d.<reset> <grey>%8.1fms (%4.1f%%)<reset>  step %d/c%d: <yellow>%s<reset>%s\n",
      k, e.s.dt, total > 0 and (100 * e.s.dt / total) or 0, e.i, e.s.seg or 1, e.s.label or "?", top))
  end
  -- BY KIND. Labels carry a room id ("place 1234", "pull class:1:516:-1"), so the id is stripped to
  -- leave the kind -- otherwise every step is its own group and the grouping says nothing.
  local kinds, korder = {}, {}
  for i, s in ipairs(log) do
    if i > 1 and s.dt then
      local k = (s.label or "?"):gsub("%d+", "#"):gsub("%s+$", "")
      local e = kinds[k]
      if not e then e = { ms = 0, n = 0, k = k } ; kinds[k] = e ; korder[#korder + 1] = e end
      e.ms = e.ms + s.dt ; e.n = e.n + 1
    end
  end
  table.sort(korder, function(a, b)
    if a.ms ~= b.ms then return a.ms > b.ms end
    return a.k < b.k
  end)
  cecho("<cyan>  by kind:<reset>\n")
  for k = 1, math.min(#korder, 12) do
    local e = korder[k]
    cecho(string.format("<grey>   %8.1fms (%4.1f%%)  %5d x %6.1fms  %s<reset>\n",
      e.ms, total > 0 and (100 * e.ms / total) or 0, e.n, e.ms / e.n, e.k))
  end
  cecho(string.format("<grey>  top %d = %.0fms (%.0f%% of the walk); the other %d step(s) hold %.0fms.<reset>\n",
    math.min(#ord, n), shown, total > 0 and (100 * shown / total) or 0,
    math.max(#ord - n, 0), total - shown))
end

-- clear the highlight/custom-line overlays drawn for the previous step
local function step_clear_overlays()
  elro._stepHL = elro._stepHL or {}
  if type(unHighlightRoom) == "function" then
    for _, r in ipairs(elro._stepHL) do pcall(unHighlightRoom, r) end
  end
  elro._stepHL = {}
  elro._stepLines = elro._stepLines or {}
  if type(removeCustomLine) == "function" then
    for _, e in ipairs(elro._stepLines) do pcall(removeCustomLine, e.u, e.d) end
  end
  elro._stepLines = {}
  elro._stepLabels = elro._stepLabels or {}
  if type(deleteMapLabel) == "function" then
    for _, L in ipairs(elro._stepLabels) do pcall(deleteMapLabel, L.area, L.id) end
  end
  elro._stepLabels = {}
end

-- In-place isolation: this client's addAreaName/setRoomArea don't actually create or
-- assign a scratch area, so we can't use a separate canvas. Instead we CLEAR the home
-- area's canvas -- park every room far off-screen once (saving originals) -- then each
-- step positions only the snapshot rooms ("composed so far") back near the origin. The
-- view stays in the home area so centerview reliably recenters; parked rooms sit so far
-- away that exits to them only leave short stubs off the viewport edge.
local STEP_PARK = 1000000

-- Mudlet auto-draws every exit of a visible room, so a shown room still draws a line to its
-- parked neighbour a million units away. Suppress those WITHOUT touching the graph: override the
-- exit's rendering with a zero-length (invisible) CUSTOM LINE. A custom line replaces the default
-- straight exit line for that direction; making it degenerate hides the long line while the exit
-- itself is untouched. Custom lines are pure drawing (cleared+redrawn on every relayout), so a
-- crash/unclean close can never corrupt connectivity -- the whole point of the mapstep rewrite.
local function step_show_exit_lines()   -- remove the invisible override lines (restore auto-draw)
  if elro._stepHideLines and type(removeCustomLine) == "function" then
    for _, e in ipairs(elro._stepHideLines) do pcall(removeCustomLine, e.room, e.dir) end
  end
  elro._stepHideLines = {}
end

local function step_hide_exits(shown)
  step_show_exit_lines()
  if type(getRoomExits) ~= "function" or type(addCustomLine) ~= "function"
     or type(getRoomCoordinates) ~= "function" then return end
  elro._stepHideLines = {}
  for room in pairs(shown) do
    if roomExists(room) then
      local ex = getRoomExits(room)
      if type(ex) == "table" then
        local rx, ry = getRoomCoordinates(room)
        if rx then
          for dir, dest in pairs(ex) do
            if not shown[dest] then
              -- zero-length line at the room -> nothing drawn, but the auto exit line is overridden
              pcall(addCustomLine, room, { { rx, ry, 0 }, { rx, ry, 0 } }, dir, "solid line", { 0, 0, 0 }, false)
              elro._stepHideLines[#elro._stepHideLines + 1] = { room = room, dir = dir }
            end
          end
        end
      end
    end
  end
end

-- park all rooms of the home area off-screen, once per stepping session
local function step_enter(homeArea)
  if elro._stepBaseline then return end
  if type(getAreaRooms) ~= "function" or type(getRoomCoordinates) ~= "function"
     or type(setRoomCoordinates) ~= "function" then return end
  local rooms = getAreaRooms(homeArea)
  if type(rooms) ~= "table" then return end
  elro._stepBaseline, elro._stepShown = {}, {}
  for _, r in pairs(rooms) do
    if roomExists(r) then
      local x, y, z = getRoomCoordinates(r)
      elro._stepBaseline[r] = { x, y, z }
      setRoomCoordinates(r, STEP_PARK, STEP_PARK, 0)
    end
  end
  -- clear the blue cross-area stubs: their points are fixed map coords, so once rooms park
  -- off-screen the stale stubs would litter the origin. step_restore redraws them on exit.
  if type(getCustomLines) == "function" and type(removeCustomLine) == "function" then
    for _, r in pairs(rooms) do
      if roomExists(r) then
        local cl = getCustomLines(r)
        if type(cl) == "table" then for dir in pairs(cl) do pcall(removeCustomLine, r, dir) end end
      end
    end
  end
end

local function step_isolate(snap)
  if type(getRoomArea) ~= "function" or type(setRoomCoordinates) ~= "function" then return end
  local any ; for r in pairs(snap) do any = r ; break end
  if not any or not roomExists(any) then return end
  step_enter(getRoomArea(any))   -- clear the canvas once
  elro._stepShown = elro._stepShown or {}
  local minx, miny = math.huge, math.huge
  for _, p in pairs(snap) do
    if p[1] < minx then minx = p[1] end
    if p[2] < miny then miny = p[2] end
  end
  -- rooms shown last step but not in this snapshot: re-park off-screen
  for r in pairs(elro._stepShown) do
    if not snap[r] then
      if roomExists(r) then setRoomCoordinates(r, STEP_PARK, STEP_PARK, 0) end
      elro._stepShown[r] = nil
    end
  end
  -- position the snapshot rooms near the origin
  for r, p in pairs(snap) do
    if roomExists(r) then
      setRoomCoordinates(r, p[1] - minx, p[2] - miny, 0)
      elro._stepShown[r] = true
    end
  end
  step_hide_exits(elro._stepShown)   -- drop exits to not-yet-shown rooms (kills long lines)
end

local function step_restore()
  step_show_exit_lines()
  if elro._stepBaseline and type(setRoomCoordinates) == "function" then
    for r, p in pairs(elro._stepBaseline) do
      if roomExists(r) then setRoomCoordinates(r, p[1], p[2], p[3]) end
    end
    elro.draw_area_stubs(elro._stepBaseline)   -- rooms are back; restore the blue stubs
  end
  elro._stepBaseline, elro._stepShown = nil, nil
end

-- Tear down an active mapstep session: restore parked rooms + hidden exits, clear overlays,
-- reset the counter. No-op if no session is active. Called at the start of every relayout so a
-- relayout (or area switch) WHILE stepping never writes onto parked / exit-stripped rooms --
-- otherwise the old area's rooms stay a million units away with exits missing = haywire map.
function elro.step_teardown()
  if not elro._stepBaseline then return end
  step_clear_overlays()
  step_restore()
  elro._stepCur = 0
end

-- render step index n on the scratch canvas (highlights + piston cut + center)
local function render_step(n)
  local log = elro._stepLog or {}
  if n < 1 then n = 1 elseif n > #log then n = #log end
  elro._stepCur = n
  local s = log[n]

  step_clear_overlays()
  local sloc = elro.step_loc(s)          -- built once per replayed step (see step_loc)
  step_isolate(sloc)    -- move "composed so far" onto the scratch canvas (re-run each step)

  -- keep the structural class colours (mapclassify) visible through playback: base
  -- layer, tracked in _stepHL so the next frame clears + repaints it; focus/blocker
  -- highlight on top below.
  if elro._classMap and type(highlightRoom) == "function" then
    local COL = elro.classColours
    for r in pairs(sloc) do
      local c = elro._classMap[r]
      if c and roomExists(r) then
        local col = COL[c] or COL.outward
        pcall(highlightRoom, r, col[1], col[2], col[3], col[1], col[2], col[3], 1, 200, 50)
        elro._stepHL[#elro._stepHL + 1] = r
      end
    end
  end

  -- room to center the scratch canvas on: focus if present, else any snapshot room.
  -- Always needed -- the init/pull steps have no focus, and without centering the
  -- view stays on the world area where the snapshot rooms just vanished to scratch.
  local center = s.focus
  if not center or not roomExists(center) then
    for r in pairs(sloc) do if roomExists(r) then center = r ; break end end
  end

  -- highlight focus (green) + blocker (red)
  if type(highlightRoom) == "function" then
    if s.focus and roomExists(s.focus) then
      pcall(highlightRoom, s.focus, 0, 255, 0, 0, 255, 0, 1, 200, 50)
      elro._stepHL[#elro._stepHL+1] = s.focus
    end
    if s.blocker and roomExists(s.blocker) then
      pcall(highlightRoom, s.blocker, 255, 0, 0, 255, 0, 0, 1, 200, 50)
      elro._stepHL[#elro._stepHL+1] = s.blocker
    end
  end

  -- vertical connectors: must run AFTER step_isolate (it re-lays the frame near the origin);
  -- the sink registers each line in _stepLines for the next frame's teardown
  if elro._vertLinks and type(addCustomLine) == "function" then
    elro.draw_vertical(sloc, function(u, d)
      elro._stepLines[#elro._stepLines + 1] = { u = u, d = d }
    end)
  end

  -- draw the pulled piston cut
  if s.pull and s.pull.edges and type(addCustomLine) == "function" then
    for _, e in ipairs(s.pull.edges) do
      if e.d and roomExists(e.u) then
        pcall(addCustomLine, e.u, e.v, e.d, "solid line", { 255, 140, 0 }, true)
        elro._stepLines[#elro._stepLines+1] = { u = e.u, d = e.d }
      end
    end
  end

  -- LCA branch visualization as a CONSOLE grid (elro.drawSprings): touches nothing persistent -- no map
  -- mutation, nothing to leak on a crash. A window around v: * = v, V = v-branch room, B = b-branch
  -- room (green/red in the classmap sense), o = other placed room, . = empty. Adjacent V|B cells are
  -- the repel springs, V|V the attract springs, so the parallel-branch "sandwich" is visible directly.
  if elro.drawSprings and s.pull and s.focus and sloc[s.focus] then
    local role = s.pull.roleMap or {}
    local cell = {}
    for r, p in pairs(sloc) do cell[p[1] .. "," .. p[2]] = r end
    local cx, cy = sloc[s.focus][1], sloc[s.focus][2]
    local bx, by = s.blocker and sloc[s.blocker] and sloc[s.blocker][1], s.blocker and sloc[s.blocker] and sloc[s.blocker][2]
    local W = TUNE.junctionWin
    local out = { "" }
    for yy = cy + W, cy - W, -1 do
      local row = {}
      for xx = cx - W, cx + W do
        local r = cell[xx .. "," .. yy]
        local ch
        if bx and xx == bx and yy == by then ch = "<yellow>X<grey>"          -- the collision room (blocker)
        elseif xx == cx and yy == cy then ch = "<white>*<grey>"              -- v
        elseif r == nil then ch = "."
        elseif role[r] == "V" then ch = "<green>V<grey>"                     -- v-branch (victim side V)
        elseif role[r] == "B" then ch = "<red>B<grey>"                       -- b-branch (victim side B)
        elseif role[r] == "G" then ch = "<cyan>G<grey>"                      -- neutral shared grid
        elseif role[r] == "O" then ch = "<magenta>O<grey>"                   -- other room, NOT adjacent to V -> repels like B
        else ch = "o" end                                                    -- other room adjacent to V -> neutral
        row[#row + 1] = ch
      end
      out[#out + 1] = "   " .. table.concat(row, " ")
    end
    cecho("\n<cyan>[springs] *=v X=collision-room <green>V<cyan>=v-branch <red>B<cyan>=b-branch <cyan>G=neutral-grid <magenta>O<cyan>=other-repel o=other-neutral .=empty (V repels B and O)<reset>"
      .. "<grey>" .. table.concat(out, "\n") .. "<reset>\n")
  end

  if type(updateMap) == "function" then updateMap() end
  if center and type(centerview) == "function" then centerview(center) end
  -- per-step wall clock (see step_snap): the engine time that PRODUCED this step, snapshot
  -- machinery excluded. Shown against the run's mean so a step reads as fast or slow in context.
  local tot, nT = 0, 0
  for i, f in ipairs(log) do if i > 1 and f.dt then tot = tot + f.dt ; nT = nT + 1 end end
  local mean = (nT > 0) and (tot / nT) or 0
  local dtStr = ""
  if s.dt then
    local col = (mean > 0 and s.dt >= 10 * mean) and "red"
      or ((mean > 0 and s.dt >= 3 * mean) and "yellow" or "grey")
    dtStr = string.format(" <%s>[%.1fms%s]<reset>", col, s.dt,
      mean > 0 and string.format(", %.1fx mean", s.dt / mean) or "")
    -- heap delta: a large negative dkb on a slow step means a GC pause, not work
    -- (stepDebug's own coord copy per step is part of that allocation)
    if s.dkb and math.abs(s.dkb) >= 256 then
      dtStr = dtStr .. string.format(" <%s>[heap %+.0fkB%s]<reset>",
        s.dkb < 0 and "magenta" or "grey", s.dkb,
        (s.dkb < -1024 and mean > 0 and s.dt >= 3 * mean) and " -- GC pause, not work" or "")
    end
  end
  cecho(string.format("\n<cyan>[elro] step %d/%d:<reset> <yellow>%s<reset>%s\n", n, #log, s.label or "?", dtStr))
  -- ...and WHERE that time went, biggest first. `(qbl)`/`(eval)` are parenthesised because they
  -- NEST inside the buckets beside them and must not be summed with them.
  if s.ksplit and next(s.ksplit) then
    local ks = {}
    for k in pairs(s.ksplit) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return s.ksplit[a] > s.ksplit[b] end)
    local parts = {}
    for _, k in ipairs(ks) do parts[#parts + 1] = string.format("%s %.0fkB", k, s.ksplit[k]) end
    cecho(string.format("\n<magenta>  alloc: %s<reset>", table.concat(parts, " | ")))
  end
  -- option funnel: offered vs evaluated (the pick loop breaks at the first clean candidate,
  -- so evaluated == offered on a pick means the winner ranked last)
  if s.nsplit and (s.nsplit.offered or s.nsplit.evaluated) then
    local off, ev = s.nsplit.offered or 0, s.nsplit.evaluated or 0
    cecho(string.format("\n<magenta>  options: %d offered -> %d EVALUATED (%.0f%%)%s<reset>",
      off, ev, 100 * ev / math.max(1, off),
      (ev >= off and off > 1) and "  ⚠ every offered option was priced -- the winner ranked last" or ""))
  end
  if s.nsplit and next(s.nsplit) then
    local ks = {}
    for k in pairs(s.nsplit) do
      if k ~= "offered" and k ~= "evaluated" then ks[#ks + 1] = k end
    end
    table.sort(ks, function(a, b) return s.nsplit[a] > s.nsplit[b] end)
    local parts = {}
    for _, k in ipairs(ks) do parts[#parts + 1] = string.format("%s x%d", k, s.nsplit[k]) end
    if #parts > 0 then
      cecho(string.format("\n<magenta>  whole-map rebuilds: %s<reset>", table.concat(parts, " | ")))
    end
  end
  if s.split and next(s.split) then
    local ks = {}
    for k in pairs(s.split) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return s.split[a] > s.split[b] end)
    local parts = {}
    for _, k in ipairs(ks) do parts[#parts + 1] = string.format("%s %.0fms", k, s.split[k]) end
    cecho("<grey>  split: " .. table.concat(parts, " | ") .. "<reset>\n")
  end
  -- lever-choice dump: WHY this pull won -- the picked bridge + its cost/centrality/settledness,
  -- then the ranked candidate list (in sort order: cost < centrality < freshness < rooms) with
  -- the reason each losing candidate was skipped (cascade / crossing / attach-edge / room-on-edge).
  local p = s.pull
  if p and p.ranked then
    local function nn(x) return x == nil and "-" or tostring(x) end
    local function cc(x) return x == nil and "-" or string.format("%.1f", x) end
    local function yn(x) return x and "Y" or "-" end
    local jstr = p.junction and string.format(" | LCA=%s(%s)", tostring(p.junction), p.junctionBlk and "block" or "bridge")
      or (p.jchecked and (" | LCA=N/A(" .. tostring(p.lcaReason or "?") .. ")") or "")
    if p.jspr then jstr = jstr .. " | repel=" .. p.jspr end
    cecho(string.format("<grey>  conflict=%s blocker=%s -> pull %s %s dist=%s | artic=%s score=%s (rooms=%s cost=%s)%s<reset>\n",
      nn(p.ckind), nn(p.blocker), nn(p.kind), nn(p.ek), nn(p.dist), yn(p.artic), nn(p.score), nn(p.rooms), nn(p.cost), jstr))
    -- evaluation order is best-first WITHIN a pass, not across passes: an escalation rebuilds
    -- and re-ranks the list, so a merged sort would be misleading
    cecho("<grey>  candidates (score = repel force field + stretch energy; shear = cells off 45,"
      .. " ranked BEFORE score) -- best first WITHIN each pass, in evaluation order:<reset>\n")
    for _, c in ipairs(p.ranked) do
      if c.escMark then
        cecho(string.format("<yellow>  -- ESCALATION %d: %s -- list rebuilt, re-ranked,"
          .. " evaluation restarts --<reset>\n", c.round or 0, tostring(c.why)))
      elseif c.noteMark then
        cecho(string.format("<grey>  -- %s --<reset>\n", tostring(c.text)))
      else
      local col = (c.why == "PICKED") and "green" or "grey"
      local rstr = (c.roomsFull ~= nil and c.roomsFull ~= c.rooms) and (nn(c.rooms) .. "/" .. nn(c.roomsFull)) or nn(c.rooms)
      -- "+Np" = rooms the pendant rule absorbed into this plate
      if (c.pAbs or 0) > 0 then rstr = rstr .. " +" .. c.pAbs .. "p" end
      local ptstr = ""
      local shstr = (c.shear and c.shear ~= 0)
        and string.format(" <%s>%+dshear<%s>", (c.shear > 0) and "red" or "cyan", c.shear, col) or ""
      -- shearEdges: which edges, `+` = a settled 45 tipped, `-` = one restored to square
      if c.shearEdges and #c.shearEdges > 0 then
        shstr = shstr .. string.format(" <%s>[%s]<%s>",
          (c.shear and c.shear > 0) and "red" or "cyan", table.concat(c.shearEdges, " "), col)
      end
      -- crossNew: each entry `a:b|c:d` is a pair of edges that now cross
      if c.crossNew and #c.crossNew > 0 then
        shstr = shstr .. string.format(" <red>[x %s]<%s>", table.concat(c.crossNew, " "), col)
      end
      -- seam=N is min tight over the stretched edges (larger is safer); seam=free means it was
      -- computed and only the outer face absorbs it; seam=- means the kind abstains from the
      -- tie-break. These are distinct claims and must print differently.
      local smstr = ""
      do
        smstr = c.seamTight and string.format(" <cyan>seam=%d<%s>", c.seamTight, col)
          or (c.seamFree and string.format(" <cyan>seam=free<%s>", col))
          or string.format(" <grey>seam=-<%s>", col)
        if c.seamGrow then
          smstr = smstr .. string.format(" <cyan>+%dcell<%s>", c.seamGrow, col)
        end
      end
      -- rides: bridges on the plate boundary the plate slides for free (a piston's job)
      if c.rides and #c.rides > 0 then
        smstr = smstr .. string.format(" <yellow>rides %s<%s>", table.concat(c.rides, ","), col)
      end
      -- repelDump splits the score into field and spring halves (a chord hard-codes stretch 0)
      local rsplit = (elro.repelDump and c.repelE)
        and string.format(" <cyan>[rep=%.2f str=%.2f]<%s>", c.repelE, c.stretchE or 0, col) or ""
      local msstr = (c.ms and c.ms >= 1)
        and string.format(" <%s>%.0fms<%s>", (c.ms >= 20) and "red" or "yellow", c.ms, col) or ""
      cecho(string.format("  <%s>%-8s %-11s score=%s%s%s%s (rooms=%s cost=%s)%s  %s%s%s%s<reset>\n",
        col, nn(c.kind), nn(c.ek), nn(c.score), rsplit, smstr, shstr, rstr, nn(c.cost), ptstr, nn(c.why), msstr,
        c.detail and (" [" .. tostring(c.detail) .. "]") or "",
        c.artic2 and " [JUNCTION]" or ""))
      end
    end
  end
  -- closure trace: a line that opens with a colour tag keeps it, anything else is cyan
  if s.closeTrace then
    for _, ln in ipairs(s.closeTrace) do
      cecho((ln:match("^<%a+>") and "" or "<cyan>") .. "  " .. ln .. "<reset>\n")
    end
  end
  -- plate generation trace: E* = a VALID cut that survived pruning and became a candidate
  if s.guilloTrace then
    cecho("<yellow>  [plate-gen] plates evaluated (E*=emitted as candidate; else pruned/rejected):<reset>\n")
    for _, rec in ipairs(s.guilloTrace) do
      if rec.header then
        cecho(string.format("<grey>   -- %s<reset>\n", rec.header))
        -- one line per plate + verdict (see pLog in query_eq_levers)
        for _, ln in ipairs(rec.lines or {}) do
          local col = ln:find("E%*") and "green" or (ln:find("no%-clear") and "red" or "grey")
          cecho(string.format("<%s>        %s<reset>\n", col, ln))
        end
      else
        local mark = (rec.verdict == "VALID") and (rec.emitted and "E*" or "  ") or "  "
        local col = (rec.verdict == "VALID") and (rec.emitted and "green" or "red") or "grey"
        cecho(string.format("   <%s>%s axis=%d cut=%6.1f dir=%+d far=%3d gap=%-4s str=%d %s%s%s<reset>\n",
          col, mark, rec.axis, rec.cut, rec.dir, rec.far, tostring(rec.gap), rec.str, rec.verdict,
          rec.reduced and " (min-cut reduced)" or (rec.unreduced and " (unreduced half-plane)" or ""),
          rec.block and (" blocked-by " .. rec.block .. " @maxshift") or ""))
        -- why not a SHORTER pull? the blocker at each distance this cut tried and rejected.
        if rec.gapWhy then
          local parts = {}
          for d = 1, (rec.gap or 1) - 1 do
            if rec.gapWhy[d] then parts[#parts + 1] = d .. ": " .. rec.gapWhy[d] end
          end
          if #parts > 0 then
            cecho("<grey>        shorter pulls rejected -- " .. table.concat(parts, " | ") .. "<reset>\n")
          end
        end
        -- the actual straddling edges this cut stretches (r on the far side -> w stationary), with
        -- the rendered delta and a ! flag on any that would shear off its truthful exit direction.
        if rec.edges then
          local parts = {}
          for _, e in ipairs(rec.edges) do
            parts[#parts + 1] = string.format("%s>%s %s(%+d,%+d)%s",
              tostring(e.r), tostring(e.w), tostring(e.d), e.ox, e.oy, e.sheared and "!" or "")
          end
          cecho("<grey>        edges: " .. table.concat(parts, "  ") .. "<reset>\n")
        end
      end
    end
  end
  local shown = 0 ; if elro._stepShown then for _ in pairs(elro._stepShown) do shown = shown + 1 end end
  cecho(string.format("<grey>  [showing %d room(s); centered on %s]<reset>\n", shown, tostring(center)))
end

-- first step index at which room `id` is present in loc (i.e. it has been placed),
-- or nil if it never appears in any snapshot.
local function first_placed_step(id)
  local log = elro._stepLog or {}
  for i, s in ipairs(log) do
    if elro.step_has(s, id) then return i end
  end
  return nil
end

-- mapstep dispatcher:
--   off|reset        -> restore the live map, clear the counter
--   (no arg)         -> advance to the next step
--   step <n>         -> jump to raw step index n
--   <roomid>         -> run up to the step just BEFORE roomid is placed, so the
--                       next 'mapstep' is the one that places it (a breakpoint)
function elro.dump_step(arg)
  if tostring(arg) == "off" or tostring(arg) == "reset" then
    elro.step_teardown()
    elro._stepMoveErr = nil
    if type(updateMap) == "function" then updateMap() end
    cecho("\n<cyan>[elro] step view reset -- counter cleared, rooms restored to the live map.<reset>\n")
    return
  end
  local log = elro._stepLog or {}
  if #log == 0 then
    cecho("\n<yellow>[elro]: no step data -- set 'lua elro.stepDebug = true' then run 'maprelayout this'.\n<reset>")
    return
  end

  arg = arg and tostring(arg) or ""
  if arg == "back" then                          -- step one back
    render_step((elro._stepCur or 1) - 1)
    return
  end
  local rawN = arg:match("^step%s+(%d+)$")
  if rawN then                                  -- explicit raw step index
    render_step(tonumber(rawN))
    return
  end

  local id = tonumber(arg)
  if id then                                    -- room breakpoint
    local placed = first_placed_step(id)
    if not placed then
      cecho(string.format("\n<yellow>[elro]: room %d is never placed in the %d recorded steps.<reset>\n", id, #log))
      return
    end
    if placed <= 1 then
      cecho(string.format("\n<yellow>[elro]: room %d is already placed at step 1 -- nothing precedes it.<reset>\n", id))
      render_step(1)
      return
    end
    cecho(string.format("\n<cyan>[elro] breakpoint: room %d is placed at step %d; stopping at step %d (next 'mapstep' places it).<reset>\n",
      id, placed, placed - 1))
    render_step(placed - 1)
    return
  end

  -- no arg: advance one step
  render_step((elro._stepCur or 0) + 1)
end
