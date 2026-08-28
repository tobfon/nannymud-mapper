-- The closure-equation walk (walk_branches) and the live entry point layout_eqw.
-- Split out of layout.lua; see lua/modules.lua for the load order.

elro = elro or {}
local G = elro.g or error("walk.lua: lua/geom.lua must be loaded first (see elro.modules)")
local ori = G.ori
local within = G.within
local seg = G.seg
local seg_hits = G.seg_hits
local K = elro.k or error("walk.lua: lua/keys.lua must be loaded first (see elro.modules)")
local ekey = K.edge
local crosskey = K.cross
local crosspair = K.pair
local roomedge_key = K.roomedge
local eid = K.eid
local each_exit = elro.exits or error("walk.lua: lua/core.lua must be loaded first")
local CLK = elro.clk or error("walk.lua: lua/core.lua must be loaded first")
local TUNE = elro.TUNE or error("walk.lua: lua/tune.lua must be loaded first")
local try_chunk_impl = elro.try_chunk or error("walk.lua: lua/place.lua must be loaded first")
local repair_run_impl = elro.repair_run or error("walk.lua: lua/place.lua must be loaded first")
local query_ring_dilate_levers_impl = elro.query_ring_dilate_levers or error("walk.lua: lua/eqlevers.lua must be loaded first")
local query_eq_2d_levers_impl = elro.query_eq_2d_levers or error("walk.lua: lua/eqlevers.lua must be loaded first")
local query_eq_levers_impl = elro.query_eq_levers or error("walk.lua: lua/eqlevers.lua must be loaded first")
local query_cut_levers_impl = elro.query_cut_levers or error("walk.lua: lua/eqlevers.lua must be loaded first")
local tighten_ring_1_impl = elro.tighten_ring_1 or error("walk.lua: lua/eqw.lua must be loaded first")
local eqw_close_core_1_impl = elro.eqw_close_core_1 or error("walk.lua: lua/eqw.lua must be loaded first")
local eqw_make_room_impl = elro.eqw_make_room or error("walk.lua: lua/eqw.lua must be loaded first")
local eqw_diag_shift_impl = elro.eqw_diag_shift or error("walk.lua: lua/eqw.lua must be loaded first")
local rigid_pendants_impl = elro.rigid_pendants or error("walk.lua: lua/eqw.lua must be loaded first")
local eqw_field_shift_impl = elro.eqw_field_shift or error("walk.lua: lua/eqw.lua must be loaded first")
local eqw_forced_shift_impl = elro.eqw_forced_shift or error("walk.lua: lua/eqw.lua must be loaded first")
local place_room_impl = elro.place_room or error("walk.lua: lua/place.lua must be loaded first")

-- The walk's shadow adjacency: edges whose provenance cannot support an equality are demoted out,
-- survivors are mirrored so a one-way exit constrains both ends. Memo keyed on table identity.
-- Republishes `elro._demoted` / `elro._trapSinks` for the draw layer.
function elro.walk_adj(adj)
  local DELTA, REVERSE = elro.delta, elro.reverse
  -- Demotion runs BEFORE mirroring: mirroring would launder every one-way edge into a reciprocal pair.
  -- Local shadow only: the graph is never mutated and setExit is never called. The memo is weak-keyed
  -- on table identity and cleared at relayout entry. No `goto`: Mudlet is stock Lua 5.1.
  local _wbAdj0 = adj
  local _wbMemo = elro._wbAdjMemo
  if not _wbMemo then
    _wbMemo = setmetatable({}, { __mode = "k" })
    elro._wbAdjMemo = _wbMemo
  end
  local _wbHit = _wbMemo and _wbMemo[_wbAdj0]
  if _wbHit then
    adj = _wbHit.adj
    elro._demoted, elro._trapSinks = _wbHit.demoted, _wbHit.sinks
  else
  local drop, list, _, sink = elro.demotion_set(adj)
  elro._demoted = list
  elro._trapSinks = sink
  if #list > 0 then
    local shadow = {}
    for r, nb in pairs(adj) do
      elro.bg_tick("demote-shadow")
      local t = {}
      for d, v in pairs(nb) do if not (drop[r] and drop[r][d]) then t[d] = v end end
      shadow[r] = t
    end
    adj = shadow
    elro.tr(string.format("walk: %d edge(s) demoted out of the equations (mapaudit for why)", #list))
  end
  -- Reverse-aware adjacency: adj is directed, so infer sym[v][reverse(d)] = u where no compass exit
  -- exists back. Never clobbers a real exit; `add` is sorted so slot arbitration is deterministic.
  do
    local add = {}
    for u, nb in pairs(adj) do
      -- O(E * deg) over the whole map; tick so a bg frame does not run straight through it
      elro.bg_tick("mirror-exits")
      for d, v in pairs(nb) do
        local de, rev = DELTA[d], REVERSE[d]
        if rev and de and (de[1] ~= 0 or de[2] ~= 0) and adj[v] then
          local back = false
          for _, x in each_exit(adj[v]) do if x == u then back = true ; break end end
          if not back then add[#add + 1] = { v = v, d = rev, u = u } end
        end
      end
    end
    if #add > 0 then
      table.sort(add, function(a, b)
        if a.v ~= b.v then return a.v < b.v end
        if a.d ~= b.d then return a.d < b.d end
        return a.u < b.u
      end)
      local sym = {}
      -- a full copy of adj, so it is the same O(E) as the scan above and needs its own tick
      for r, nb in pairs(adj) do
        elro.bg_tick("mirror-copy")
        local t = {} ; for d, v in pairs(nb) do t[d] = v end ; sym[r] = t
      end
      local n = 0
      for _, e in ipairs(add) do
        if sym[e.v][e.d] == nil then sym[e.v][e.d] = e.u ; n = n + 1 end
      end
      adj = sym
      if elro.debug then elro.tr(string.format("walk: %d asymmetric exit(s) mirrored into adj", n)) end
    end
  end
  if _wbMemo then
    _wbMemo[_wbAdj0] = { adj = adj, demoted = elro._demoted, sinks = elro._trapSinks }
  end
  end   -- _wbHit
  return adj
end

function elro.walk_branches(coord, adj, outwardSet, space, branchSet, units, artery, hints, inwardSet)
  local W = {}                                   -- context handed to the extracted functions (lua/place.lua)
  -- localized globals: built once at load, never reassigned
  local DELTA, REVERSE, DIRORDER = elro.delta, elro.reverse, elro.dir_order
  if elro.timeGuillo then elro._wbEnter = CLK() end
  adj = elro.walk_adj(adj)
  local function key(x, y) return x .. ":" .. y end
  inwardSet = inwardSet or {}
  -- map every frozen-unit room -> its unit index; unitDone guards against re-insertion.
  -- unitInward[ui] = the unit is an INWARD block (its rooms live in a core face) -> placed in
  -- PASS 0 before the outward skeleton, so its containing face expands against empty exterior.
  local unitByRoom, unitDone, unitInward = {}, {}, {}
  for i, U in ipairs(units or {}) do
    for r in pairs(U.rooms) do unitByRoom[r] = i ; if inwardSet[r] then unitInward[i] = true end end
  end
  local placed, occ = {}, {}
  for r in pairs(coord) do if not outwardSet[r] then placed[r] = true end end
  elro._bfGen = (elro._bfGen or 0) + 1
  -- placement ROOT = the core settled before the walk (main block + inward, or just the seed on
  -- a pure tree). The live LCA trace walks branches back to this root; on a pure tree it is the
  -- first-placed room, so the LCA falls out even with no rigid block to anchor on.
  local coreSet = {}
  for r in pairs(placed) do coreSet[r] = true end
  -- artery set from compose_spqr_adj; trunk continuation is chosen by artery membership.
  -- Fallback {} (never artery) = pure small-first DFS.
  local arteryRooms = artery or {}
  local function mark(r)
    local p = coord[r] ; occ[key(p[1], p[2])] = r
    for _, v in each_exit(adj[r]) do
      if coord[v] and placed[v] then
        seg(p[1], p[2], coord[v][1], coord[v][2],
          function(x, y) if not occ[key(x, y)] then occ[key(x, y)] = r end end)
      end
    end
  end
  -- placed 2D edge list (dedup u<v) for crossing tests
  local pedges, seenPE = {}, {}
  local eqwReconciled = {}   -- eqw: back-edges (loop closers) already reconciled -- dedup
  local function add_edges(r)
    for d, v in each_exit(adj[r]) do
      local de = DELTA[d]
      if placed[v] and de and (de[1] ~= 0 or de[2] ~= 0) then
        -- dedup by canonical key, NOT r<v: the higher-id endpoint is often placed later, so
        -- an r<v gate silently drops that edge
        local ek = ekey(r, v)
        if not seenPE[ek] then seenPE[ek] = true ; pedges[#pedges + 1] = { u = r, v = v } end
      end
    end
  end
  for r in pairs(coord) do if placed[r] then mark(r) ; add_edges(r) end end
  -- proper (optional): when true an endpoint-on-edge touch is a room-on-edge, not a crossing. The
  -- detector callers stay strict: a room on a non-45 stretched edge has no lattice point the raster could catch.
  -- isDiag: a 45-degree diagonal edge.
  local function isDiag(p, q) local dx, dy = q[1] - p[1], q[2] - p[2] ; return dx ~= 0 and (dx == dy or dx == -dy) end
  -- gridx_quad: a real wizard grid-X is an axial 4-cycle carrying both diagonals, asked of the
  -- structure, not the geometry. `adj` can be asymmetric, so ask both directions.
  local function axial_link(a, b)
    for d, w in each_exit(adj[a]) do
      if w == b then local de = DELTA[d] ; if de and ((de[1] == 0) ~= (de[2] == 0)) then return true end end
    end
    return false
  end
  local function diag_link_q(a, b)          -- is a -> b declared as a DIAGONAL exit?
    for d, w in each_exit(adj[a]) do
      if w == b then local de = DELTA[d] ; if de and de[1] ~= 0 and de[2] ~= 0 then return true end end
    end
    return false
  end
  -- Shear-invariant on purpose: a geometric 45 test lapses when the quad shears, and
  -- `pull_makes_crossing` would veto a crossing nothing created. `sheared_gridx` is this + "not square".
  local function gridx_quad(a1, a2, b1, b2)
    if a1 == b1 or a1 == b2 or a2 == b1 or a2 == b2 then return false end
    -- both crossing segments must be DECLARED diagonal exits (not merely diagonal-looking geometry)
    if not (diag_link_q(a1, a2) or diag_link_q(a2, a1)) then return false end
    if not (diag_link_q(b1, b2) or diag_link_q(b2, b1)) then return false end
    -- ...and the four axial walls of the quad they are the diagonals of
    return (axial_link(a1, b1) or axial_link(b1, a1)) and (axial_link(a1, b2) or axial_link(b2, a1))
       and (axial_link(a2, b1) or axial_link(b1, a2)) and (axial_link(a2, b2) or axial_link(b2, a2))
  end
  -- ===== PROVABLY UNAVOIDABLE CROSSINGS ==================================================
  -- Decidable from the sign constraints: an E/W chain locks a row class, an N/S chain a column class,
  -- and the per-axis order DAG forces a vertical/horizontal pair to cross when
  -- col(W) < col(vert) < col(E) and row(S) < row(horiz) < row(N). A property of the graph; built once.
  local ordCache, forcedSeen = nil, {}
  local function eqw_order()
    if ordCache then return ordCache end
    ordCache = {}
    for axis = 1, 2 do
      local p = {}
      local function find(a)
        if p[a] == nil then p[a] = a end
        while p[a] ~= a do p[a] = p[p[a]] ; a = p[a] end
        return a
      end
      for r, nb in pairs(adj) do
        find(r)
        for d, v in pairs(nb) do
          local de = DELTA[d]
          if de and adj[v] and (de[1] ~= 0 or de[2] ~= 0) and de[axis] == 0 then
            local ra, rb = find(r), find(v) ; if ra ~= rb then p[ra] = rb end
          end
        end
      end
      local succ = {}
      for r, nb in pairs(adj) do
        for d, v in pairs(nb) do
          local de = DELTA[d]
          if de and adj[v] and (de[1] ~= 0 or de[2] ~= 0) and de[axis] ~= 0 then
            local a, b
            if de[axis] > 0 then a, b = find(r), find(v) else a, b = find(v), find(r) end
            if a ~= b then succ[a] = succ[a] or {} ; succ[a][b] = true end
          end
        end
      end
      ordCache[axis] = { find = find, succ = succ, reach = {} }
    end
    return ordCache
  end
  -- is `a` PROVABLY strictly less than `b` on this axis? (reachability, memoised per class)
  local function ord_lt(axis, a, b)
    local A = eqw_order()[axis]
    local ca, cb = A.find(a), A.find(b)
    if ca == cb then return false end
    local seen = A.reach[ca]
    if not seen then
      seen = {}
      local stack = {}
      for x in pairs(A.succ[ca] or {}) do stack[#stack + 1] = x end
      while #stack > 0 do
        local x = table.remove(stack)
        if not seen[x] then
          seen[x] = true
          for y in pairs(A.succ[x] or {}) do if not seen[y] then stack[#stack + 1] = y end end
        end
      end
      A.reach[ca] = seen
    end
    return seen[cb] == true
  end
  -- Returns forced, reason. "not-VxH" = the proof does not cover this shape; an `order:` failure
  -- = the shape is right but the partial order has not pinned the relation.
  local function forced_cross(a1, b1, a2, b2)
    if a1 == a2 or a1 == b2 or b1 == a2 or b1 == b2 then return false, "shared-endpoint" end
    local O = eqw_order()
    local function kind(x, y)
      if O[1].find(x) == O[1].find(y) then return "V" end   -- one column class -> vertical
      if O[2].find(x) == O[2].find(y) then return "H" end   -- one row class    -> horizontal
      return nil
    end
    local k1, k2 = kind(a1, b1), kind(a2, b2)
    local S, N, W, E
    if k1 == "V" and k2 == "H" then S, N, W, E = a1, b1, a2, b2
    elseif k1 == "H" and k2 == "V" then S, N, W, E = a2, b2, a1, b1
    else
      return false, string.format("not-VxH (%s x %s)", tostring(k1 or "free"), tostring(k2 or "free"))
    end
    if ord_lt(2, N, S) then S, N = N, S end          -- orient S below N
    if ord_lt(1, E, W) then W, E = E, W end          -- orient W left of E
    -- named so the diagnostic can say WHICH relation is missing rather than just "unproved"
    local tests = {
      { ord_lt(2, S, N), "S<N" },  { ord_lt(1, W, E), "W<E" },
      { ord_lt(1, W, S), "W<S" },  { ord_lt(1, S, E), "S<E" },   -- vertical between W and E
      { ord_lt(2, S, W), "S<W" },  { ord_lt(2, W, N), "W<N" },   -- horizontal between S and N
    }
    for _, t in ipairs(tests) do
      if not t[1] then return false, "order:" .. t[2] end
    end
    return true, "forced"
  end
  -- both edges locked to one row class, or both to one column class => parallel, cannot cross
  local function parallel_pair(a1, b1, a2, b2)
    local O = eqw_order()
    local function kind(x, y)
      if O[1].find(x) == O[1].find(y) then return "V" end
      if O[2].find(x) == O[2].find(y) then return "H" end
      return nil
    end
    local k1, k2 = kind(a1, b1), kind(a2, b2)
    return k1 ~= nil and k1 == k2
  end
  local function eqw_topo_cross() return elro.topo_cross(adj, parallel_pair) end
  -- O(1) after the one build. Returns forced, reason -- same shape as forced_cross.
  local function topo_forced(a1, b1, a2, b2)
    local T = eqw_topo_cross()
    if T.n == 0 and T.nsite == 0 then
      return false, (T.genus > 0 and "topo:no-pair" or "topo:planar")
    end
    local k1, k2 = ekey(a1, b1), ekey(a2, b2)
    local k = crosspair(k1, k2)
    if T.pair[k] then return true, "topo" end
    -- chain site: one designated edge, partner unknown by construction; a crossing has to go somewhere in that face
    if T.site[k1] or T.site[k2] then return true, "topo:chain-site" end
    return false, "topo:other-pair"
  end
  -- The wire prover sits between forced_cross and topo_forced in strength, so it is asked second.
  local function eqw_wire_cross() return elro.wire_cross(adj) end
  -- A forced pair proves the two wires meet ONCE, but the prover registers the whole |ves| x |hes|
  -- cross product, so among the pair's sites actually crossing only the lexicographically smallest is
  -- free; the rest stay defects. Stateless (a pure function of current coordinates) so a trial geometry
  -- cannot leak through a revert. Module scope so it is testable. Returns forced, reason.
  local function wire_forced(a1, b1, a2, b2)
    local W = eqw_wire_cross()
    -- W.n counts PROVEN pairs only; cost pairs live in wires/pairIdx without touching n, so test both.
    if W.n == 0 and #(W.wires or {}) == 0 then return false, "wire:none" end
    local k1, k2 = ekey(a1, b1), ekey(a2, b2)
    local kk = crosspair(k1, k2)
    local pi = W.pairIdx[kk]
    if not pi then return false, "wire:other-pair" end
    elro._wcBudgetN = (elro._wcBudgetN or 0) + 1
    local best = elro.wire_site_min(W.wires[pi], coord)
    if best ~= kk then return false, "wire:over-budget" end
    return true, "wire"
  end
  -- bucket -> pedges keyed by the cells each edge's bbox spans: a superset of what a segment can cross,
  -- so filtering by it changes no verdict. Stale the instant anything moves; rebuild after a shift.
  -- `e.pi` = position in pedges; consumers restore pedges order so an indexed scan returns the same edge.
  local function edge_bucket_index()
    local idx, floor, B = {}, math.floor, (elro.crossBucket or 4)
    for j = 1, #pedges do
      local e = pedges[j] ; local a, b = coord[e.u], coord[e.v]
      e.pi = j
      if a and b then
        for bx = floor((a[1] < b[1] and a[1] or b[1]) / B), floor((a[1] > b[1] and a[1] or b[1]) / B) do
          for by = floor((a[2] < b[2] and a[2] or b[2]) / B), floor((a[2] > b[2] and a[2] or b[2]) / B) do
            local k = bx * 1000003 + by ; local l = idx[k]
            if l then l[#l + 1] = e else idx[k] = { e } end
          end
        end
      end
    end
    return idx
  end
  -- `idx` (optional, from edge_bucket_index): probe only bucket-sharing edges. One implementation of the
  -- crossing test so the grid-X exemption and the forced-cross acceptance cannot drift.
  -- licensed_pair: one definition of "this crossing is allowed", shared by the detector, the pick-loop
  -- guard and the lever eval (`elro._licPair`), tested in this order.
  local function licensed_pair(a1, b1, a2, b2)
    if forced_cross(a1, b1, a2, b2) then return true end
    if wire_forced(a1, b1, a2, b2) then return true end
    if topo_forced(a1, b1, a2, b2) then return true end
    return false
  end
  elro._licPair = licensed_pair
  local function first_crossing(su, sv, proper, idx)
    local a, b = coord[su], coord[sv]
    -- bbox cull: a pedge whose bbox is disjoint from the segment cannot cross it
    local aLoX = (a[1] < b[1]) and a[1] or b[1] ; local aHiX = (a[1] > b[1]) and a[1] or b[1]
    local aLoY = (a[2] < b[2]) and a[2] or b[2] ; local aHiY = (a[2] > b[2]) and a[2] or b[2]
    local cand, seen = pedges, nil
    if idx then
      local floor, B = math.floor, (elro.crossBucket or 4)
      cand, seen = {}, {}
      local nb = 0
      for bx = floor(aLoX / B), floor(aHiX / B) do
        for by = floor(aLoY / B), floor(aHiY / B) do
          local l = idx[bx * 1000003 + by]
          if l then nb = nb + 1 ; for i = 1, #l do local e = l[i]
            if not seen[e] then seen[e] = true ; cand[#cand + 1] = e end
          end end
        end
      end
      -- restore pedges order when several buckets interleave, so this returns the same edge as the unindexed scan
      if nb > 1 and #cand > 1 then table.sort(cand, function(p, q) return p.pi < q.pi end) end
    end
    for _, e in ipairs(cand) do
      if e.u ~= su and e.u ~= sv and e.v ~= su and e.v ~= sv then
        local c, d = coord[e.u], coord[e.v]
        if not ((c[1] < aLoX and d[1] < aLoX) or (c[1] > aHiX and d[1] > aHiX)
             or (c[2] < aLoY and d[2] < aLoY) or (c[2] > aHiY and d[2] > aHiY)) then
        local d1 = ori(c[1], c[2], d[1], d[2], a[1], a[2])
        local d2 = ori(c[1], c[2], d[1], d[2], b[1], b[2])
        local d3 = ori(a[1], a[2], b[1], b[2], c[1], c[2])
        local d4 = ori(a[1], a[2], b[1], b[2], d[1], d[2])
        local touch = proper and (d1 == 0 or d2 == 0 or d3 == 0 or d4 == 0)
        if not touch and ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0)) then
          -- A truthful grid-X (two declared diagonals of a wizard quad) is not a defect; `gridx_quad` is
          -- structural and shear-invariant.
          local gx = gridx_quad(su, sv, e.u, e.v)
          if gx then elro._gxN = (elro._gxN or 0) + 1 end
          if isDiag(a, b) and isDiag(c, d) then
            if not gx then
              elro._gxFake = (elro._gxFake or 0) + 1
              -- name them: an exemption is otherwise invisible
              elro._gxFakeList = elro._gxFakeList or {}
              if #elro._gxFakeList < 12 then
                elro._gxFakeList[#elro._gxFakeList + 1] = su .. "-" .. sv .. "x" .. e.u .. "-" .. e.v
              end
            end
          end
          if not gx then
            -- Unavoidable crossings are accepted: the order proof first (strongest), then the wire
            -- prover, then topology (the widest net, and the only one that fires on a diagonal).
            local isForced, fcWhy = forced_cross(su, sv, e.u, e.v)
            local byTopo, byWire = false, false
            if not isForced then
              local wf, wwhy = wire_forced(su, sv, e.u, e.v)
              if wf then isForced, byWire = true, true else fcWhy = fcWhy .. " / " .. wwhy end
            end
            if not isForced then
              local tf, twhy = topo_forced(su, sv, e.u, e.v)
              if tf then isForced, byTopo = true, true else fcWhy = fcWhy .. " / " .. twhy end
            end
            if isForced then
              -- canonical pair key, so the same crossing seen from either side counts once
              local e1 = ekey(su, sv)
              local e2 = ekey(e.u, e.v)
              local fk = (e1 < e2) and (e1 .. "/" .. e2) or (e2 .. "/" .. e1)
              if not forcedSeen[fk] then
                forcedSeen[fk] = true
                if byWire then
                  elro._wcProved = (elro._wcProved or 0) + 1
                  elro._wcList = elro._wcList or {}
                  if #elro._wcList < 12 then
                    elro._wcList[#elro._wcList + 1] = su .. "-" .. sv .. "x" .. e.u .. "-" .. e.v
                  end
                  elro.tr(string.format("  forced crossing accepted: %d-%d x %d-%d"
                    .. " (two equality wires must meet -- proved from the row/col equations)",
                    su, sv, e.u, e.v))
                elseif byTopo then
                  elro._tcProved = (elro._tcProved or 0) + 1
                  elro._tcList = elro._tcList or {}
                  if #elro._tcList < 12 then
                    elro._tcList[#elro._tcList + 1] = su .. "-" .. sv .. "x" .. e.u .. "-" .. e.v
                  end
                  elro.tr(string.format("  forced crossing accepted: %d-%d x %d-%d"
                    .. " (face cannot be drawn flat; these two bridges interleave)", su, sv, e.u, e.v))
                else
                  elro._fcProved = (elro._fcProved or 0) + 1
                  elro.tr(string.format("  forced crossing accepted: %d-%d x %d-%d"
                    .. " (proved unavoidable from the row/col order)", su, sv, e.u, e.v))
                end
              end
            else
              -- histogram of why the proof declined; if not-VxH dominates, the proof's shape is the limit
              elro._fcWhy = elro._fcWhy or {}
              elro._fcWhy[fcWhy or "?"] = (elro._fcWhy[fcWhy or "?"] or 0) + 1
              return e
            end
          end
        end
        end
      end
    end
    return nil
  end
  -- edge-on-room: a placed room (not su/sv) on the raster of edge su-sv. `rc` (numeric cell -> room
  -- over placed rooms) is built once by the caller; `x * 1000003 + y` is injective for |y| < 500000,
  -- and the last writer in pairs(placed) order wins a shared cell.
  local function rcell_key(x, y) return x * 1000003 + y end
  local function edge_over_room(su, sv, rc)
    local a, b = coord[su], coord[sv]
    local hit
    seg(a[1], a[2], b[1], b[2], function(x, y)
      local r = rc[rcell_key(x, y)]
      if r and r ~= su and r ~= sv then hit = r end
    end)
    return hit
  end
  -- Check EVERY 2D edge of v to a placed room, not just the entry edge. Returns the branch endpoint
  -- w + the defect. `idx` optional, same frozen-geometry contract as edge_over_room_v's `rc`.
  local function first_crossing_v(v, idx)
    elro.bg_tick("det-crossing")
    for d, w in each_exit(adj[v]) do
      local de = DELTA[d]
      if placed[w] and de and (de[1] ~= 0 or de[2] ~= 0) then
        local ce = first_crossing(v, w, nil, idx) ; if ce then return w, ce end
      end
    end
  end
  -- A sheared grid-X (a wizard quad that is not square) is not a placement defect: the only cure is
  -- squaring the quad, which a published minimum often forbids. The test is structural (reads `adj`);
  -- only the final shear check is geometric.
  local function diag_link(a, b)          -- is a -> b declared as a DIAGONAL exit?
    for d, w in each_exit(adj[a]) do
      if w == b then local de = DELTA[d] ; if de and de[1] ~= 0 and de[2] ~= 0 then return true end end
    end
    return false
  end
  local function side_link(a, b)          -- is a -> b any 2D exit at all? (the quad's four walls)
    for d, w in each_exit(adj[a]) do
      if w == b then local de = DELTA[d] ; if de and (de[1] ~= 0 or de[2] ~= 0) then return true end end
    end
    return false
  end
  -- Literally `gridx_quad` + "not square", so the feasibility gate and the crossing exemption cannot drift.
  local function sheared_gridx(a1, a2, b1, b2)
    if not gridx_quad(a1, a2, b1, b2) then return false end
    local p, q = coord[a1], coord[a2]     -- sheared = the quad is not square, i.e. why we are here
    if not (p and q) then return false end
    local dx, dy = q[1] - p[1], q[2] - p[2]
    return dx ~= 0 and dy ~= 0 and (dx < 0 and -dx or dx) ~= (dy < 0 and -dy or dy)
  end
  -- _gxDiag: is this diagonal one of a wizard quad's two diagonals? The 45-preservation rules must not
  -- lock these. Structural and shear-invariant; candidates come from `adj[r]` only, so a wall declared
  -- solely from the far side is missed (one-sided error, keeps the old behaviour).
  -- _whyList: formats a void-reason census for the step trace, worst-first, capped at four kinds.
  elro._whyList = function(w)
    if not w then return "" end
    local ks = {}
    for k in pairs(w) do ks[#ks + 1] = k end
    if #ks == 0 then return "" end
    table.sort(ks, function(a2, b2)
      if w[a2] ~= w[b2] then return w[a2] > w[b2] end
      return a2 < b2                     -- total order: `pairs` is hash order
    end)
    local ps = {}
    for i2 = 1, (#ks < 4 and #ks or 4) do ps[#ps + 1] = ks[i2] .. " " .. w[ks[i2]] end
    if #ks > 4 then ps[#ps + 1] = "+" .. (#ks - 4) .. " more" end
    return " [" .. table.concat(ps, ", ") .. "]"
  end
  -- On `elro`, not a local: this function is at Lua's 200-local ceiling. The cache lives beside it for the same reason.
  elro._gxDiag = function(r, x)
    if elro._gxdAdj ~= adj then elro._gxdAdj, elro._gxdCache = adj, {} end
    local _gxdCache = elro._gxdCache
    local k = eid(r, x)
    local hit = _gxdCache[k]
    if hit ~= nil then return hit end
    hit = false
    if diag_link_q(r, x) or diag_link_q(x, r) then
      local cand = {}
      for d, w in each_exit(adj[r]) do
        local de = DELTA[d]
        if de and ((de[1] == 0) ~= (de[2] == 0)) and w ~= x
           and (axial_link(x, w) or axial_link(w, x)) then cand[#cand + 1] = w end
      end
      table.sort(cand)                   -- `each_exit` is ordered, but be explicit: this is a set
      for i = 1, #cand do
        for j = i + 1, #cand do
          if gridx_quad(r, x, cand[i], cand[j]) then hit = true ; break end
        end
        if hit then break end
      end
    end
    _gxdCache[k] = hit
    return hit
  end
  -- Does the graph contain a wizard quad at all? One scan per relayout; warms `_gxDiag`'s cache.
  elro._gxAnyQuad = function()
    if elro._gxAnyAdj == adj then return elro._gxAny end
    local any = false
    for r, row in pairs(adj) do
      for d, x in each_exit(row) do
        local de = DELTA[d]
        if de and de[1] ~= 0 and de[2] ~= 0 and elro._gxDiag(r, x) then any = true ; break end
      end
      if any then break end
    end
    elro._gxAnyAdj, elro._gxAny = adj, any
    return any
  end
  -- True only when v has at least one crossing and every one is a sheared grid-X: v sits in the only
  -- cell its exits allow and the defect is the quad's aspect, not a leftover.
  local function gridx_only(v)
    local any = false
    for d, w in each_exit(adj[v]) do
      local de = DELTA[d]
      if placed[w] and de and (de[1] ~= 0 or de[2] ~= 0) then
        local ce = first_crossing(v, w)
        if ce then
          if not sheared_gridx(v, w, ce.u, ce.v) then return false end
          any = true
        end
      end
    end
    return any
  end
  -- `rcIn` (optional): a caller-supplied cell->room map for sweeps over frozen geometry. Must be built
  -- exactly as below (last writer in pairs(placed) order wins a shared cell).
  local function edge_over_room_v(v, rcIn)
    elro.bg_tick("det-edgeroom")
    local rc = rcIn                           -- else built lazily: a room with no 2D neighbour pays nothing
    for d, w in each_exit(adj[v]) do
      local de = DELTA[d]
      if placed[w] and de and (de[1] ~= 0 or de[2] ~= 0) then
        if not rc then rc = {}
          for r in pairs(placed) do local p = coord[r] ; if p then rc[rcell_key(p[1], p[2])] = r end end
        end
        local R = edge_over_room(v, w, rc) ; if R then return w, R end
      end
    end
  end
  -- Mirror of edge_over_room_v: v's own cell landing on a placed edge. Returns the straddling edge.
  -- `idx` optional: the one bucket holding the cell is a superset, in pedges order, so the returned edge is unchanged.
  local function room_on_pedge_v(v, idx)
    elro.bg_tick("det-roomedge")
    local p = coord[v] ; if not p then return end
    local px, py = p[1], p[2]
    local cand = pedges
    if idx then
      local B = elro.crossBucket or 4
      cand = idx[math.floor(px / B) * 1000003 + math.floor(py / B)]
      if not cand then return end
    end
    for _, e in ipairs(cand) do
      if e.u ~= v and e.v ~= v then
        local a, b = coord[e.u], coord[e.v]
        -- bbox cull before rastering; pedges order is kept, so the returned edge (the blocker) is unchanged
        if a and b
           and px >= (a[1] < b[1] and a[1] or b[1]) and px <= (a[1] > b[1] and a[1] or b[1])
           and py >= (a[2] < b[2] and a[2] or b[2]) and py <= (a[2] > b[2] and a[2] or b[2]) then
          if seg_hits(a[1], a[2], b[1], b[2], px, py) then return e end
        end
      end
    end
  end
  -- The SET of edge-edge crossings in the current frame, keyed by the identity of the two edges. A pull
  -- is rejected iff it introduces a pair that did not exist before; persisting crossings never veto.
  -- `crossing_set(v)` and `crossings_moved(moved, v)` are the BEFORE and AFTER halves of one diff in
  -- `pull_makes_crossing`, so they must share one implementation and one definition of a crossing.
  -- `moved` restricts the probes; two edges wholly inside a rigidly moved set cannot change their
  -- crossing. The result is a set, so bucket order is irrelevant. `timeSlot` names the index-build accumulator.
  local function crossing_scan(moved, v, timeSlot)
    local S = {}
    local proper = true   -- endpoint-on-edge touch = room-on-edge, not a crossing
    local floor, B = math.floor, (elro.crossBucket or 4)
    local _b0 = timeSlot and elro.timeGuillo and CLK()
    local xidx = edge_bucket_index()
    if _b0 then elro[timeSlot] = (elro[timeSlot] or 0) + (CLK() - _b0) end
    for i = 1, #pedges do
      local e1 = pedges[i]
      if (not moved) or moved[e1.u] or moved[e1.v] then
        local e1full = moved and moved[e1.u] and moved[e1.v]
        local a, b = coord[e1.u], coord[e1.v]
        local axlo, axhi = (a[1] < b[1]) and a[1] or b[1], (a[1] > b[1]) and a[1] or b[1]
        local aylo, ayhi = (a[2] < b[2]) and a[2] or b[2], (a[2] > b[2]) and a[2] or b[2]
        local seenj = {}
        for bx = floor(axlo / B), floor(axhi / B) do
          for by = floor(aylo / B), floor(ayhi / B) do
            local l = xidx[bx * 1000003 + by]
            if l then for t = 1, #l do
              local e2 = l[t]
              if e2 ~= e1 and not seenj[e2] then
                seenj[e2] = true
                -- a rigid translation moves both edges together, so their crossing cannot change
                if not (e1full and moved[e2.u] and moved[e2.v])
                   and e1.u ~= e2.u and e1.u ~= e2.v and e1.v ~= e2.u and e1.v ~= e2.v then
                  local c, d = coord[e2.u], coord[e2.v]
                  -- bbox cull first: disjoint boxes cannot cross, and this is cheaper than 4 ori
                  local disjoint = (c[1] > axhi and d[1] > axhi) or (c[1] < axlo and d[1] < axlo)
                                or (c[2] > ayhi and d[2] > ayhi) or (c[2] < aylo and d[2] < aylo)
                  if not disjoint then
                    local d1 = ori(c[1], c[2], d[1], d[2], a[1], a[2])
                    local d2 = ori(c[1], c[2], d[1], d[2], b[1], b[2])
                    local d3 = ori(a[1], a[2], b[1], b[2], c[1], c[2])
                    local d4 = ori(a[1], a[2], b[1], b[2], d[1], d[2])
                    local touch = proper and (d1 == 0 or d2 == 0 or d3 == 0 or d4 == 0)
                    -- grid-X exemption, once, for both halves of the diff
                    if not touch and ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0))
                       and not gridx_quad(e1.u, e1.v, e2.u, e2.v) then
                      S[crosskey(e1.u, e1.v, e2.u, e2.v)] = true
                    end
                  end
                end
              end
            end end
          end
        end
      end
    end
    -- v's edges aren't in pedges yet (add_edges(v) runs after the resolve loop), so test them
    -- against the placed set explicitly -- this is the sibling-crossing a bad pull introduces.
    -- No index here: `first_crossing` returns ONE edge, and both halves of the diff must agree on which.
    if v then
      for d, w in each_exit(adj[v]) do
        local de = DELTA[d]
        if placed[w] and de and (de[1] ~= 0 or de[2] ~= 0) then
          local e = first_crossing(v, w, proper)
          if e then S[crosskey(v, w, e.u, e.v)] = true end
        end
      end
    end
    return S
  end
  -- the two former entry points, kept as names because ~11 call sites read better for them
  local function crossing_set(v) return crossing_scan(nil, v) end
  local function crossings_moved(moved, v) return crossing_scan(moved, v, "_cmBT") end
  -- An accepted crossing is a constraint: its endpoints lie on opposite sides of the wall. Kept as
  -- per-axis room-pair inequalities (the axial shadow: both x-ranges and y-ranges must overlap), each
  -- with a determined drag resolution. Weaker than the exact side condition for diagonals, but sound
  -- for every family combination. Pairs are captured per walk step (`elro._bfGen`); values are read
  -- live from `coord`, and a bound already below 1 is skipped.
  -- eqw_field_shift is forward-declared here and defined after eqw_forced_shift.
  local eqw_field_shift
  local bridge_forest, rigid_pendants
  local xbGen, xbBy = -1, nil
  local function crossing_bounds()
    if xbBy and xbGen == (elro._bfGen or 0) then return xbBy end
    local by = {}
    xbGen, xbBy = (elro._bfGen or 0), by
    local _t0 = elro.timeGuillo and CLK()
    local floor, B = math.floor, (elro.crossBucket or 4)
    local xidx = edge_bucket_index()
    -- counters separating "no crossing seen" from "every bound was degenerate"
    local nX, nAdd, nFlat, nSame, nQuad = 0, 0, 0, 0, 0
    -- A crossing on an untruthful edge is not a constraint to preserve: there is no line there yet and
    -- the walk is about to rewrite it. The filter is on the edge, not the crossing.
    local function xb_ok(e)
      local a, b = coord[e.u], coord[e.v]
      if not (a and b) then return false end
      for d, x in each_exit(adj[e.u]) do
        local de = DELTA[d]
        if x == e.v and de and (de[1] ~= 0 or de[2] ~= 0) then
          return elro.edge_truthful(de, b[1] - a[1], b[2] - a[2])
        end
      end
      for d, x in each_exit(adj[e.v]) do
        local de = DELTA[d]
        if x == e.u and de and (de[1] ~= 0 or de[2] ~= 0) then
          return elro.edge_truthful({ -de[1], -de[2] }, b[1] - a[1], b[2] - a[2])
        end
      end
      return false
    end
    local function add(hi, lo, ax)
      if hi == lo then nSame = nSame + 1 ; return end
      if coord[hi][ax] - coord[lo][ax] < 1 then nFlat = nFlat + 1 ; return end   -- no straddle
      nAdd = nAdd + 1
      local rec = { hi, lo, ax }
      local t = by[hi] ; if t then t[#t + 1] = rec else by[hi] = { rec } end
      t = by[lo] ; if t then t[#t + 1] = rec else by[lo] = { rec } end
    end
    for i = 1, #pedges do
      local e1 = pedges[i]
      local a, b = coord[e1.u], coord[e1.v]
      if a and b then
        local axlo, axhi = (a[1] < b[1]) and a[1] or b[1], (a[1] > b[1]) and a[1] or b[1]
        local aylo, ayhi = (a[2] < b[2]) and a[2] or b[2], (a[2] > b[2]) and a[2] or b[2]
        local seenj = {}
        for bx = floor(axlo / B), floor(axhi / B) do
          for byy = floor(aylo / B), floor(ayhi / B) do
            local l = xidx[bx * 1000003 + byy]
            if l then for t = 1, #l do
              local e2 = l[t]
              if e2 ~= e1 and not seenj[e2] then
                seenj[e2] = true
                if e1.u ~= e2.u and e1.u ~= e2.v and e1.v ~= e2.u and e1.v ~= e2.v then
                  local c, d = coord[e2.u], coord[e2.v]
                  if c and d then
                    local disjoint = (c[1] > axhi and d[1] > axhi) or (c[1] < axlo and d[1] < axlo)
                                  or (c[2] > ayhi and d[2] > ayhi) or (c[2] < aylo and d[2] < aylo)
                    if not disjoint then
                      local d1 = ori(c[1], c[2], d[1], d[2], a[1], a[2])
                      local d2 = ori(c[1], c[2], d[1], d[2], b[1], b[2])
                      local d3 = ori(a[1], a[2], b[1], b[2], c[1], c[2])
                      local d4 = ori(a[1], a[2], b[1], b[2], d[1], d[2])
                      -- PROPER crossings only, and the grid-X exemption, exactly as crossing_scan
                      -- reads them: a touch is a room-on-edge and two 45s meeting in a quad is a
                      -- legitimate wizard connection, neither is a constraint to preserve.
                      if d1 ~= 0 and d2 ~= 0 and d3 ~= 0 and d4 ~= 0
                         and ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0))
                         and gridx_quad(e1.u, e1.v, e2.u, e2.v) then
                        nQuad = nQuad + 1
                      elseif d1 ~= 0 and d2 ~= 0 and d3 ~= 0 and d4 ~= 0
                         and ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0))
                         and not (xb_ok(e1) and xb_ok(e2)) then
                        -- one of the two is not a drawn line: no bound, and say so
                        elro._xbLie = (elro._xbLie or 0) + 1
                      elseif d1 ~= 0 and d2 ~= 0 and d3 ~= 0 and d4 ~= 0
                         and ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0))
                         and not licensed_pair(e1.u, e1.v, e2.u, e2.v) then
                        -- Only a LICENSED crossing becomes a hard bound; an unlicensed one is still a
                        -- counted defect but must not block its own repair.
                        elro._xbUnlic = (elro._xbUnlic or 0) + 1
                      elseif d1 ~= 0 and d2 ~= 0 and d3 ~= 0 and d4 ~= 0
                         and ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0)) then
                        nX = nX + 1
                        for ax = 1, 2 do
                          -- (a) THE RANGE-OVERLAP PAIR. Necessary for any two segments to meet:
                          -- each edge's high end is above the other's low end.
                          local lo1, hi1 = e1.u, e1.v
                          if coord[lo1][ax] > coord[hi1][ax] then lo1, hi1 = hi1, lo1 end
                          local lo2, hi2 = e2.u, e2.v
                          if coord[lo2][ax] > coord[hi2][ax] then lo2, hi2 = hi2, lo2 end
                          add(hi1, lo2, ax)
                          add(hi2, lo1, ax)
                          -- (b) the side-of-segment pair, needed to hold a wall a plate is deforming: an
                          -- endpoint strictly outside the other edge's range on this axis is bounded
                          -- against both of its endpoints. Exact, since a segment's coordinate lies
                          -- between its endpoints'.
                          local function sides(pu, pv, qu, qv)
                            local qlo = (coord[qu][ax] < coord[qv][ax]) and coord[qu][ax] or coord[qv][ax]
                            local qhi = (coord[qu][ax] > coord[qv][ax]) and coord[qu][ax] or coord[qv][ax]
                            for _, r0 in ipairs({ pu, pv }) do
                              if coord[r0][ax] > qhi then add(r0, qu, ax) ; add(r0, qv, ax)
                              elseif coord[r0][ax] < qlo then add(qu, r0, ax) ; add(qv, r0, ax) end
                            end
                          end
                          sides(e1.u, e1.v, e2.u, e2.v)
                          sides(e2.u, e2.v, e1.u, e1.v)
                        end
                      end
                    end
                  end
                end
              end
            end end
          end
        end
      end
    end
    if _t0 then elro._xbT = (elro._xbT or 0) + (CLK() - _t0) end
    elro._xbN = (elro._xbN or 0) + 1
    return by
  end
  -- The total (dx,dy) a candidate shifts room r by: rigid pulls move every room in pick.set by
  -- (dx*dist, dy*dist); graded pulls carry per-room pick.deltas[r] = {dx,dy}. The single place that
  -- knows how to move a room for a candidate; apply/revert/guards/commit/repel all funnel through it.
  local function cand_shift(pick, r)
    local d = pick.deltas
    if d then local e = d[r] ; if e then return e[1], e[2] end ; return 0, 0 end
    if pick.set and pick.set[r] then return (pick.dx or 0) * (pick.dist or 0), (pick.dy or 0) * (pick.dist or 0) end
    return 0, 0
  end
  -- Free a rider that lands on a wall. The gate is the CALL SITE, not this function: `eqw_close` uses
  -- `elro.closeSqRider` (on), the pick loop `elro.ringNoRider` (off).
  -- A rider owes its connecting axial edge the perpendicular component (direction) and nothing along
  -- it (length): zero the along-edge component, keep the other, drop the room only if nothing is left.
  -- Ring rooms are never touched. A diagonal connecting edge owes both components, so that rider can only be dropped.
  local function ring_free_rider(c, keys)
    if not (c and c.set and c.deltas) then return nil end
    local onR = c.ringSet
    if not onR then
      onR = {}
      for _, gg in ipairs(elro.faceRings or {}) do
        for _, r in ipairs(gg) do onR[r] = true end
      end
    end
    local free, nf = {}, 0
    local function want(k)
      local id = k and K.roomedge_room(k)
      if not (id and c.set[id]) or onR[id] or free[id] ~= nil then return end
      -- a rider with a square diagonal into the plate keeps its full displacement: zeroing one component tips the 45
      for d, x in each_exit(adj[id]) do
        local de = DELTA[d]
        if de and de[1] ~= 0 and de[2] ~= 0 and c.set[x] then
          local pi, px = coord[id], coord[x]
          if pi and px and math.abs(px[1] - pi[1]) == math.abs(px[2] - pi[2]) then return end
        end
      end
      local ax = 0                       -- 0 = drop the room outright
      for d, x in each_exit(adj[id]) do
        local de = DELTA[d]
        if de and c.set[x] and ((de[1] == 0) ~= (de[2] == 0)) then
          ax = (de[1] ~= 0) and 1 or 2   -- the axis ALONG the edge: its length, not its direction
          break
        end
      end
      free[id] = ax ; nf = nf + 1
    end
    if type(keys) == "table" then for _, k in ipairs(keys) do want(k) end else want(keys) end
    if nf == 0 then return nil end
    local set2, del2, changed = {}, {}, false
    for r in pairs(c.set) do
      local dx, dy = cand_shift(c, r)
      local ax = free[r]
      if ax then
        if ax == 1 then dx = 0 elseif ax == 2 then dy = 0 else dx, dy = 0, 0 end
        changed = true
      end
      if dx ~= 0 or dy ~= 0 then set2[r] = true ; del2[r] = { dx, dy } end
    end
    if not (changed and next(set2)) then return nil end
    local alt = {}
    for k, vv in pairs(c) do alt[k] = vv end
    -- `deltas` is authoritative for a graded pull (see `cand_shift`), so the rigid dx/dy must go
    alt.set, alt.deltas, alt.dx, alt.dy = set2, del2, 0, 0
    alt.ek = tostring(c.ek) .. ":norider"
    local nr = 0 ; for _ in pairs(set2) do nr = nr + 1 end
    alt.rooms = nr
    return alt, nf
  end
  -- r -> a key identifying how far `pick` displaces r. Two rooms share a key iff they translate
  -- together, which is what lets roomedge_moved skip a rigid (room, edge) triple SOUNDLY even for a
  -- graded chord pull. Rigid levers give every set member the same key (the old assumption).
  local function disp_of(pick)
    local D = {}
    for r in pairs(pick.set or {}) do local dx, dy = cand_shift(pick, r) ; D[r] = dx .. "," .. dy end
    return D
  end
  -- would committing `pick` introduce a NEW crossing (one not already present)? `before` = the
  -- pre-pull crossing set (pass it in to compute once per collision; falls back to a full scan).
  -- The after-set only needs moved-edge crossings -- a new crossing must involve a moved edge.
  local function pull_makes_crossing(pick, v, before)
    before = before or crossing_set(v)
    local saved = {}
    for r in pairs(pick.set) do saved[r] = coord[r] end
    for r in pairs(pick.set) do local dx, dy = cand_shift(pick, r) ; coord[r] = { coord[r][1] + dx, coord[r][2] + dy } end
    local after = crossings_moved(pick.set, v)
    for r, c in pairs(saved) do coord[r] = c end
    -- Return ALL new crossing keys, sorted: `pairs(after)` order is hash-seed dependent.
    local newK = nil
    for k in pairs(after) do
      if not before[k] then
        -- The guard must accept what the detector accepts: a licensed crossing is not a new one.
        local lic = false
        if true then
          local a1, b1, a2, b2 = k:match("^(%d+):(%d+)|(%d+):(%d+)$")
          if a1 then
            a1, b1, a2, b2 = tonumber(a1), tonumber(b1), tonumber(a2), tonumber(b2)
            lic = licensed_pair(a1, b1, a2, b2)
            if lic then elro._pmcLic = (elro._pmcLic or 0) + 1 end
          end
        end
        if not lic then newK = newK or {} ; newK[#newK + 1] = k end
      end
    end
    if newK then table.sort(newK) ; return true, newK end   -- sorted: pairs() order is hash-seeded
    return false
  end
  -- Proper-crossing semantics: an endpoint-on-edge touch (any ori determinant == 0) is a room-on-edge
  -- owned by the raster detectors, not a crossing.
  -- Room-on-edge incidences are keyed by identity (room @ edge) and use the exact collinear-interior ori
  -- test, not the occ raster: a stretched non-45 edge rasters only its endpoints.
  -- on_edge_now: the single incidence test behind roomedge_set / roomedge_moved, for re-testing one pair in O(1).
  local function on_edge_now(r, u, w)
    if r == u or r == w then return false end
    local p, a, b = coord[r], coord[u], coord[w]
    if not (p and a and b) then return false end
    return p[1] >= math.min(a[1], b[1]) and p[1] <= math.max(a[1], b[1])
      and p[2] >= math.min(a[2], b[2]) and p[2] <= math.max(a[2], b[2])
      and ori(a[1], a[2], b[1], b[2], p[1], p[2]) == 0
      and not (p[1] == a[1] and p[2] == a[2]) and not (p[1] == b[1] and p[2] == b[2])
  end
  -- One room-on-edge scan: `roomedge_set(v)` and `roomedge_moved(moved, v, disp)` are the BEFORE and
  -- AFTER of one diff in `pull_makes_roomedge`. Pass 1 probes edges against nearby rooms, pass 2
  -- (moved only) probes moved rooms against nearby edges, pass 3 v's own edges.
  -- Values are always the `{room, u, v}` triple. `rigid3` skips a triple only when all three moved
  -- TOGETHER: `disp` makes that exact for graded pulls; with no `moved` nothing is rigid.
  local function roomedge_scan(moved, v, disp, timeSlot)
    local S, pr = {}, {}
    for r in pairs(placed) do if coord[r] then pr[#pr + 1] = r end end
    local floor, B = math.floor, (elro.crossBucket or 4)
    local function rigid3(r, a, b)
      if not moved then return false end
      if not (moved[r] and moved[a] and moved[b]) then return false end
      if not disp then return true end
      local d = disp[r] ; return d ~= nil and d == disp[a] and d == disp[b]
    end
    -- room r (!= sa,sb) strictly inside edge a-b? bbox bounds first (cheap), then exact collinearity
    local function hit(a, b, sa, sb, r)
      if r == sa or r == sb then return false end
      local p = coord[r] ; if not p then return false end
      return p[1] >= math.min(a[1], b[1]) and p[1] <= math.max(a[1], b[1])
         and p[2] >= math.min(a[2], b[2]) and p[2] <= math.max(a[2], b[2])
         and ori(a[1], a[2], b[1], b[2], p[1], p[2]) == 0
         and not (p[1] == a[1] and p[2] == a[2]) and not (p[1] == b[1] and p[2] == b[2])
    end
    local _b0 = timeSlot and elro.timeGuillo and CLK()
    local roomIdx = {}
    for _, r in ipairs(pr) do
      local p = coord[r]
      local k = floor(p[1] / B) * 1000003 + floor(p[2] / B)
      local l = roomIdx[k] ; if l then l[#l + 1] = r else roomIdx[k] = { r } end
    end
    local edgeIdx
    if moved then
      edgeIdx = {}
      for j = 1, #pedges do
        local e = pedges[j] ; local a, b = coord[e.u], coord[e.v]
        if a and b then
          for bx = floor((a[1] < b[1] and a[1] or b[1]) / B), floor((a[1] > b[1] and a[1] or b[1]) / B) do
            for by = floor((a[2] < b[2] and a[2] or b[2]) / B), floor((a[2] > b[2] and a[2] or b[2]) / B) do
              local k = bx * 1000003 + by ; edgeIdx[k] = edgeIdx[k] or {} ; edgeIdx[k][#edgeIdx[k] + 1] = j
            end
          end
        end
      end
    end
    if _b0 then elro[timeSlot] = (elro[timeSlot] or 0) + (CLK() - _b0) end
    -- an incidence needs the room inside the edge's bbox, so the two share a bucket: the candidate
    -- list is a SUPERSET and the resulting set is identical (it is a set, so order is irrelevant)
    local function edge_vs_rooms(a, b, sa, sb, checkRigid)
      local seen = {}
      for bx = floor((a[1] < b[1] and a[1] or b[1]) / B), floor((a[1] > b[1] and a[1] or b[1]) / B) do
        for by = floor((a[2] < b[2] and a[2] or b[2]) / B), floor((a[2] > b[2] and a[2] or b[2]) / B) do
          local bk = roomIdx[bx * 1000003 + by]
          if bk then for t = 1, #bk do
            local r = bk[t]
            if not seen[r] then
              seen[r] = true
              if not (checkRigid and rigid3(r, sa, sb)) and hit(a, b, sa, sb, r) then
                S[roomedge_key(r, sa, sb)] = { r, sa, sb }
              end
            end
          end end
        end
      end
    end
    -- 1. probe edges (every one, or only those the pull displaced) against nearby rooms
    for _, e in ipairs(pedges) do
      if (not moved) or moved[e.u] or moved[e.v] then
        local a, b = coord[e.u], coord[e.v]
        if a and b then edge_vs_rooms(a, b, e.u, e.v, true) end
      end
    end
    -- 2. moved rooms against nearby edges -- the other side a pull can create an incidence from
    if moved then
      for r in pairs(moved) do
        local p = coord[r]
        if p then
          local bk = edgeIdx[floor(p[1] / B) * 1000003 + floor(p[2] / B)]
          if bk then
            local seen = {}
            for _, j in ipairs(bk) do
              if not seen[j] then
                seen[j] = true
                local e = pedges[j]
                if not rigid3(r, e.u, e.v) then
                  local a, b = coord[e.u], coord[e.v]
                  if a and b and hit(a, b, e.u, e.v, r) then S[roomedge_key(r, e.u, e.v)] = { r, e.u, e.v } end
                end
              end
            end
          end
        end
      end
    end
    -- 3. v's own edges, which are not in pedges yet
    if v then
      for _, w in each_exit(adj[v]) do
        if placed[w] then
          local a, b = coord[v], coord[w]
          if a and b then edge_vs_rooms(a, b, v, w, false) end
        end
      end
    end
    return S
  end
  -- the two former entry points, kept as names because ~15 call sites read better for them
  local function roomedge_set(v) return roomedge_scan(nil, v) end
  local function roomedge_moved(moved, v, disp) return roomedge_scan(moved, v, disp, "_rmBT") end
  -- would committing `pick` introduce a NEW room-on-edge incidence? Diff the sets on a saved
  -- snapshot, revert. Rejects a pull that lands any room on an edge (or drags an edge over a
  -- room) that wasn't already so -- while letting it RESOLVE pre-existing ones. Applied to every
  -- conflict type, not just overlaps: this is a big part of the sanity checking movesV used to
  -- give implicitly, now that openness (blind to geometry away from v) is the primary key.
  local function pull_makes_roomedge(pick, v, before)
    before = before or roomedge_set(v)
    local saved = {}
    for r in pairs(pick.set) do saved[r] = coord[r] end
    for r in pairs(pick.set) do local dx, dy = cand_shift(pick, r) ; coord[r] = { coord[r][1] + dx, coord[r][2] + dy } end
    -- `disp` for graded picks only; a rigid pull passes nil. Without it `rigid3` would skip a triple
    -- whose members moved by different amounts and report the pick clean.
    local after = roomedge_moved(pick.set, v, pick.deltas and disp_of(pick) or nil)
    for r, c in pairs(saved) do coord[r] = c end
    for k in pairs(after) do if not before[k] then return true, k end end  -- a NEW room-on-edge (key = room@edge)
    return false
  end
  -- ANY residual conflict over the WHOLE frame (a lever that moved a shared room can
  -- create a crossing / overlap on geometry we already walked past -- the per-edge guard
  -- misses it). Severity order: room-on-room overlap, then crossing, then edge-on-room.
  local function find_any_conflict()
    local cellOf = {}
    for r in pairs(placed) do
      if coord[r] then
        local k = key(coord[r][1], coord[r][2])
        if cellOf[k] then return { kind = "overlap", A = cellOf[k], B = r } end
        cellOf[k] = r
      end
    end
    for i = 1, #pedges do
      local e1 = pedges[i] ; local a, b = coord[e1.u], coord[e1.v]
      for j = i + 1, #pedges do
        local e2 = pedges[j]
        if e1.u ~= e2.u and e1.u ~= e2.v and e1.v ~= e2.u and e1.v ~= e2.v then
          local c, d = coord[e2.u], coord[e2.v]
          local d1 = ori(c[1], c[2], d[1], d[2], a[1], a[2])
          local d2 = ori(c[1], c[2], d[1], d[2], b[1], b[2])
          local d3 = ori(a[1], a[2], b[1], b[2], c[1], c[2])
          local d4 = ori(a[1], a[2], b[1], b[2], d[1], d[2])
          if ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0)) then
            return { kind = "cross", e1 = e1, e2 = e2 }
          end
        end
      end
    end
    local rc = {}
    for r in pairs(placed) do if coord[r] then rc[key(coord[r][1], coord[r][2])] = r end end
    for _, e in ipairs(pedges) do
      local a, b = coord[e.u], coord[e.v] ; local R
      seg(a[1], a[2], b[1], b[2], function(x, y)
        local r = rc[key(x, y)] ; if r and r ~= e.u and r ~= e.v then R = r end
      end)
      if R then return { kind = "roomedge", R = R, e = e } end
    end
    return nil
  end
  -- rebuild the occupancy raster from scratch (after a bulk coordinate shift). occ is an
  -- upvalue shared with mark(); clear in place so every closure sees the same table.
  local function rebuild_occ()
    for k in pairs(occ) do occ[k] = nil end
    for r in pairs(placed) do mark(r) end
  end
  local leftover = {}
  -- SUBCOMPONENT TAG: the top-level pendant branch (or block unit) each walked room descends
  -- from. mapmargin pads separations BETWEEN subcomponents (a room and its blocker carry
  -- different tags, or the blocker is core/artery = nil tag), but NOT inside one (same tag =
  -- the branch folding against its own earlier rooms), so the mesh interior stays tight.
  local branchOf = {}
  -- PLACEMENT TREE: parentOf[v] = the room v was walked off of. The LCA of a colliding pair (v, B)
  -- is the JUNCTION where their two branches diverge -- length-invariant (unlike centrality, which
  -- drifts onto the bendier branch). A collision between two branches off that junction is cleanly
  -- resolved by SLIDING one branch out at J (or, if J is a block, a guillotine cut) -- see the
  -- junction preference in place_room's pick loop.
  local parentOf = {}
  local function lca_junction_tree(a, b)
    if parentOf[a] == nil or parentOf[b] == nil then return nil end
    local anc, x = {}, a               -- a's ancestor chain (including a)
    while x ~= nil do
      anc[x] = true
      local p = parentOf[x] ; if p == nil or p == x then break end ; x = p
    end
    local child, y = nil, b            -- climb b; `child` trails one step below y
    while y ~= nil do
      if anc[y] then
        if y == a or y == b then return nil end   -- one is an ancestor of the other, not two branches
        local z = a ; while z ~= nil and parentOf[z] ~= y do z = parentOf[z] end   -- a's child of J
        if z == nil or child == nil then return nil end
        return y, z, child             -- J, child-toward-a, child-toward-b
      end
      local p = parentOf[y] ; if p == nil or p == y then break end
      child = y ; y = p
    end
    return nil
  end
  -- LIVE LCA: the divergence junction from the CURRENT placed geometry. Trace a back to the placement
  -- root, then BFS from b until it hits that path. Rigid blocks are one node: if b reaches a block the
  -- a-path passed through, the LCA is that block (guillotine). Returns J, cV, cB, isBlock.
  local function lca_junction_live(a, b)
    if not placed[a] or not placed[b] then return nil, nil, nil, nil, "unplaced" end
    local roomBlock = (hints and hints.roomBlock) or {}
    -- trace1: BFS a -> nearest placement-ROOT room (core) over the placed graph
    local par1, q, qh, target = { [a] = a }, { a }, 1, nil
    while qh <= #q do
      local xx = q[qh] ; qh = qh + 1
      if coreSet[xx] then target = xx ; break end
      for d, v in each_exit(adj[xx]) do
        local de = DELTA[d]
        if de and (de[1] ~= 0 or de[2] ~= 0) and placed[v] and par1[v] == nil then par1[v] = xx ; q[#q + 1] = v end
      end
    end
    if not target then return nil, nil, nil, nil, "v!core" end
    local chain = {} ; local cur = target
    while true do chain[#chain + 1] = cur ; if cur == a then break end ; cur = par1[cur] end
    local S1, order = {}, {}                       -- a..target with index (1=a)
    local i = 0
    for k = #chain, 1, -1 do i = i + 1 ; S1[chain[k]] = i ; order[i] = chain[k] end
    local blkTouched = {}                           -- blocks the a-path passes through
    for r in pairs(S1) do local B = roomBlock[r] ; if B then blkTouched[B] = true end end
    -- trace2: BFS b until it hits the a-path OR a block the a-path touched
    local par2, q2, qh2 = { [b] = b }, { b }, 1
    local J, isBlk = nil, false
    while qh2 <= #q2 do
      local xx = q2[qh2] ; qh2 = qh2 + 1
      local B = roomBlock[xx]
      if B and blkTouched[B] then J = xx ; isBlk = true ; break end   -- BLOCK LCA -> guillotine
      if S1[xx] then J = xx ; break end                                -- room LCA
      for d, v in each_exit(adj[xx]) do
        local de = DELTA[d]
        if de and (de[1] ~= 0 or de[2] ~= 0) and placed[v] and par2[v] == nil then par2[v] = xx ; q2[#q2 + 1] = v end
      end
    end
    if not J then return nil, nil, nil, nil, "b!apath" end   -- b's BFS never reached a-path or touched block
    if isBlk then return J, nil, nil, true end
    if J == a or J == b then                          -- one is a graph-ancestor of the other (same strand)
      return nil, nil, nil, nil, (J == b and "J==b(b anc a)" or "J==a(a anc b)")
    end
    local cV = order[S1[J] - 1]                      -- J's neighbour toward a
    local cB = par2[J] ; if cB == J then cB = nil end -- J's neighbour toward b
    if not cV or not cB then return nil, nil, nil, nil,
      "no-child(cV=" .. tostring(cV) .. " cB=" .. tostring(cB) .. ")" end
    if roomBlock[J] then return J, cV, cB, true end  -- J itself rigid -> guillotine
    return J, cV, cB, false
  end
  local function lca_junction(a, b)
    elro.bg_tick("lca")
    if next(coreSet) then return lca_junction_live(a, b) end
    return lca_junction_tree(a, b)
  end
  -- ACCUMULATE placement order + pulls across every branch of a layout run (reset once by
  -- the caller, compose_spqr_adj). maporder reads + filters these, so it shows exactly what
  -- the live walk did rather than a re-run that might classify the selection differently.
  elro._walkOrder = elro._walkOrder or {}
  elro._walkPulls = elro._walkPulls or {}
  elro._walkN = elro._walkN or 0
  -- subtree size reachable through neighbour v (not crossing back through parent u). Used to
  -- ORDER the non-artery branches (small dead-ends settle first into local empty space).
  -- Memoised: a pure function of (adj, outwardSet), both fixed for the whole walk.
  -- `elro.szMemo = false` restores the recompute.
  local szMemo = {}
  local function subtree_size(u, v)
    local mk
    if elro.szMemo ~= false then
      mk = u * 1000003 + v                    -- numeric key: no string concat in a hot path
      local c = szMemo[mk] ; if c then return c end
    end
    local seen, q, qh, n = { [u] = true, [v] = true }, { v }, 1, 1
    while qh <= #q do
      elro.bg_tick("subtree-size")            -- a full BFS of the outward set, per kid per visit
      local x = q[qh] ; qh = qh + 1
      for _, w in each_exit(adj[x]) do
        if outwardSet[w] and not seen[w] then seen[w] = true ; n = n + 1 ; q[#q + 1] = w end
      end
    end
    if mk then szMemo[mk] = n end
    return n
  end
  -- placed-subgraph degree: used to detect block-adjacent frontier rooms. A settled room
  -- with ≥2 placed 2D neighbours is inside a cyclic block (not just a road node); an
  -- outward room whose settled attach has high degree is "block-face" = more constrained.
  local function placed_degree(r)
    local n = 0
    for d, v in each_exit(adj[r]) do
      local de = DELTA[d]
      if placed[v] and de and (de[1] ~= 0 or de[2] ~= 0) then n = n + 1 end
    end
    return n
  end
  -- TRUNK-LAST walk: place every non-artery neighbour first (ascending subtree size, block-face kids
  -- first), then follow the artery last into the open space beyond them.
  -- cell_overlap: a placed room (other than v) on v's cell. `cenIn` (optional): cell -> { first, second }
  -- occupant in pairs(placed) order; two because the question is "some room OTHER than v". Under a
  -- census the returned room may differ from the linear scan's, so a caller using it as a BLOCKER must pass nothing.
  local function cell_overlap(v, cenIn)
    elro.bg_tick("det-overlap")
    local p = coord[v]
    if cenIn then
      local c = cenIn[rcell_key(p[1], p[2])]
      if not c then return nil end
      if c[1] ~= v then return c[1] end
      return c[2]
    end
    for r in pairs(placed) do
      if r ~= v and coord[r] and coord[r][1] == p[1] and coord[r][2] == p[2] then return r end
    end
    return nil
  end
  -- optional per-detector timing (elro.timeGuillo); `_detT/_detN` stay as the union
  if elro.timeGuillo then
    local function wrap(f, slot) local kt, kn = "_det" .. slot .. "T", "_det" .. slot .. "N"
      return function(...)
      local t = CLK() ; elro._detN = (elro._detN or 0) + 1 ; elro[kn] = (elro[kn] or 0) + 1
      -- `elro.detWho`: attribute calls to the caller line (too expensive to leave on; its own probe)
      if elro.detWho then
        local i = debug.getinfo(2, "l")
        local k = slot .. "@" .. (i and i.currentline or "?")
        elro._detWho = elro._detWho or {} ; elro._detWho[k] = (elro._detWho[k] or 0) + 1
      end
      local a, b = f(...) ; local d = CLK() - t
      elro._detT = (elro._detT or 0) + d ; elro[kt] = (elro[kt] or 0) + d ; return a, b
    end end
    cell_overlap = wrap(cell_overlap, "Ov") ; first_crossing_v = wrap(first_crossing_v, "Cr")
    edge_over_room_v = wrap(edge_over_room_v, "Eor") ; room_on_pedge_v = wrap(room_on_pedge_v, "Rpe")
  end
  -- Frozen-geometry indices for the four detectors, built once per sweep. `rc` keeps the LAST writer in
  -- pairs order, the census the FIRST TWO; both must match the detectors' own builds exactly.
  local function det_sweep()
    elro._dsN = (elro._dsN or 0) + 1
    local _ds0 = elro.timeGuillo and CLK()
    local rc, cen = {}, {}
    for r in pairs(placed) do
      local p = coord[r]
      if p then
        local k = rcell_key(p[1], p[2])
        rc[k] = r
        local c = cen[k]
        if not c then cen[k] = { r } elseif not c[2] then c[2] = r end
      end
    end
    local ebi = edge_bucket_index()
    if _ds0 then elro._dsT = (elro._dsT or 0) + (CLK() - _ds0) end
    return ebi, rc, cen
  end
  -- would applying `pick` land any moved room on a stationary placed room (room-on-room overlap)?
  -- Trial-shift + revert; returns the stationary room hit, or nil. Routes overlap-makers to the
  -- cascade pool instead of misfiling them as makes-room-on-edge.
  local function pull_makes_overlap(pick)
    -- census of the STATIONARY rooms, valid either side of the trial shift; asking it directly for a
    -- stationary occupant can only find more overlaps than an arbitrary co-occupant scan, never fewer
    local stat = {}
    for r in pairs(placed) do
      if not pick.set[r] then local p = coord[r]
        if p then local k = key(p[1], p[2]) ; if stat[k] == nil then stat[k] = r end end
      end
    end
    local saved = {}
    for r in pairs(pick.set) do saved[r] = coord[r] end
    for r in pairs(pick.set) do local dx, dy = cand_shift(pick, r) ; coord[r] = { coord[r][1] + dx, coord[r][2] + dy } end
    local hit
    for r in pairs(pick.set) do
      local p = coord[r]
      local o = p and stat[key(p[1], p[2])]
      if o then hit = o ; break end   -- moved room r landed on a stationary room o
    end
    for r, c in pairs(saved) do coord[r] = c end
    return hit
  end
  -- guard-phase timing split (elro.timeGuillo); these buckets nest into the detector buckets
  if elro.timeGuillo then
    -- `elro._gudWho` is set by each tier around its own calls, so the buckets can be attributed to a caller
    local function wrap(f, slot) local kt, kn = "_" .. slot .. "T", "_" .. slot .. "N"
      return function(...)
      local t = CLK() ; elro[kn] = (elro[kn] or 0) + 1
      local a, b = f(...) ; local d = CLK() - t
      elro[kt] = (elro[kt] or 0) + d
      -- the two whole-map prescans, summed per step
      if slot == "cs" or slot == "rs" then elro._preT = (elro._preT or 0) + d end
      local W = elro._gudBy or {} ; elro._gudBy = W
      local k = (elro._gudWho or "?") .. "/" .. slot
      local e = W[k] ; if not e then e = { t = 0, n = 0 } ; W[k] = e end
      e.t = e.t + d ; e.n = e.n + 1
      return a, b
    end end
    crossing_set = wrap(crossing_set, "cs") ; roomedge_set = wrap(roomedge_set, "rs")
    crossings_moved = wrap(crossings_moved, "cm") ; roomedge_moved = wrap(roomedge_moved, "rm")
    pull_makes_crossing = wrap(pull_makes_crossing, "pmc")
    pull_makes_roomedge = wrap(pull_makes_roomedge, "pmr")
    pull_makes_overlap = wrap(pull_makes_overlap, "pmo")
  end
  -- does segment (ax,ay)-(bx,by) strictly cross any placed edge (skipping edges incident to
  -- skip_a/skip_b)? Used for trial unit positions not yet in coord.
  local function seg_cross_xy(ax, ay, bx, by, skip_a, skip_b)
    for _, e in ipairs(pedges) do
      if e.u ~= skip_a and e.v ~= skip_a and e.u ~= skip_b and e.v ~= skip_b then
        local c, dd = coord[e.u], coord[e.v]
        if c and dd then
          local d1 = ori(c[1], c[2], dd[1], dd[2], ax, ay) ; local d2 = ori(c[1], c[2], dd[1], dd[2], bx, by)
          local d3 = ori(ax, ay, bx, by, c[1], c[2])       ; local d4 = ori(ax, ay, bx, by, dd[1], dd[2])
          if ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0)) then return e end
        end
      end
    end
  end
  -- One-sided repel field energy between the two junction branches (windowed members Vm, Bm) in the
  -- state `coord` + `pulls` (a list of {set,dx,dy,dist,deltas}). Each pair within radius R contributes
  -- (R-L)^2. Shared by junction_score and two_lever_search so a lever and a pair are scored on
  -- identical terms. Positions are read live from coord.
  -- pos_after: position of room r after applying `pulls`, or nil if unplaced.
  local function pos_after(r, pulls)
    local p = coord[r] ; if not p then return nil end
    local x, y = p[1], p[2]
    for _, pl in ipairs(pulls) do
      if pl.deltas then local e = pl.deltas[r] ; if e then x = x + e[1] ; y = y + e[2] end
      elseif pl.set[r] then x = x + pl.dx * pl.dist ; y = y + pl.dy * pl.dist end
    end
    return x, y
  end
  -- Edge-as-rooms model (TUNE.repelEdgeW): each edge's interior cells are virtual repel sources of
  -- weight ew, so a corridor stretched alongside B is priced. otherSet: cross-branch attachment edges
  -- are skipped. memSet: a same-branch edge counts once (o<w). Points are at POST-PULL positions.
  local function branch_points(mem, memSet, otherSet, ew, pulls, aSet)
    local pts = {}
    for _, r in ipairs(mem) do local x, y = pos_after(r, pulls) ; if x then pts[#pts + 1] = { x, y, 1 } end end
    if ew ~= 0 then
      local seen = {}                                    -- dedup shared edge cells by "x:y"
      for _, o in ipairs(mem) do
        local ox, oy = pos_after(o, pulls)
        if ox then
          for d, w in each_exit(adj[o]) do
            local de = DELTA[d]
            if de and (de[1] ~= 0 or de[2] ~= 0) and placed[w] and not otherSet[w]
               and not (aSet and aSet[w])   -- V's anchor: its corridors are attachment, not wall
               and not (memSet[w] and tostring(o) >= tostring(w)) then   -- same-branch edge: one endpoint only
              local wx, wy = pos_after(w, pulls)
              if wx then
                local ddx, ddy = wx - ox, wy - oy
                local steps = math.max(math.abs(ddx), math.abs(ddy))     -- cell count of the corridor
                for i = 1, steps - 1 do                                   -- INTERIOR cells (endpoints are rooms)
                  local px, py = ox + ddx * i / steps, oy + ddy * i / steps
                  local key = px .. ":" .. py
                  if not seen[key] then seen[key] = true ; pts[#pts + 1] = { px, py, ew } end
                end
              end
            end
          end
        end
      end
    end
    return pts
  end
  local function repel_energy_core(Vm, Bm, R, pulls, oSet, aSet)
    local ew = TUNE.repelEdgeW   -- DEFAULT 1 (an edge cell repels like a room); 0 disables (0 is truthy)
    local Vset = {}
    for _, r in ipairs(Vm) do Vset[r] = true end
    -- Dynamic O-neutrality: an O member that V is 8-way adjacent to at the EVALUATED state is a
    -- legitimate touch, so drop it from B.
    local Bm2 = Bm
    if oSet and next(oSet) then
      local Vc = {}
      for _, r in ipairs(Vm) do local x, y = pos_after(r, pulls) ; if x then Vc[x .. ":" .. y] = true end end
      Bm2 = {}
      for _, r in ipairs(Bm) do
        local drop = false
        if oSet[r] then
          local x, y = pos_after(r, pulls)
          if x then
            for dx = -1, 1 do for dy = -1, 1 do
              if not (dx == 0 and dy == 0) and Vc[(x + dx) .. ":" .. (y + dy)] then drop = true end
            end end
          end
        end
        if not drop then Bm2[#Bm2 + 1] = r end
      end
    end
    local Bset = {}
    for _, r in ipairs(Bm2) do Bset[r] = true end
    -- pair energy is w_a*w_b*(R-L)^2
    local VP = branch_points(Vm, Vset, Bset, ew, pulls, aSet)
    local BP = branch_points(Bm2, Bset, Vset, ew, pulls, aSet)
    local rep = 0
    for _, a in ipairs(VP) do
      local ax, ay, aw = a[1], a[2], a[3]
      for _, b in ipairs(BP) do
        local ddx, ddy = ax - b[1], ay - b[2]
        local L = math.sqrt(ddx * ddx + ddy * ddy)
        if L < R then local d = R - L ; rep = rep + aw * b[3] * d * d end
      end
    end
    return rep
  end
  -- optional scoring timing (elro.timeGuillo)
  local repel_energy = repel_energy_core
  if elro.timeGuillo then
    repel_energy = function(...)
      local t = CLK() ; elro._repN = (elro._repN or 0) + 1
      local a = repel_energy_core(...) ; elro._repT = (elro._repT or 0) + (CLK() - t) ; return a
    end
  end
  -- junction_score: LCA(subj, blk) divides the placed geometry into subj's branch (V) and the blocker's
  -- (B); each candidate is scored mult*repel + stretch at its resulting state. Overwrites c.score and
  -- re-ranks. Returns { J,isBlk,Vm,Bm,R,mult,role,spr }, or nil when there is no junction (the caller
  -- keeps the _score_cands ordering). Windowed to a box around subj.
  -- _pull_stretch_price: one move, one price, wherever it is asked for (single levers and both two-lever
  -- tiers). Chord = 0. A ring dilation (`c.corridor` = the dilation step) is one corridor priced k*G^2.
  -- A rigid set with a uniform displacement is one corridor priced k*gap^2 regardless of how many edges
  -- straddle it. Graded pulls (`deltas`) keep the per-edge sum: their edges deform by different amounts.
  -- The rigid guard is "does anything straddle", not `strE > 0`: _stretch_energy charges extension
  -- only, so a squashing plate would read as free. Shear is priced separately in `_pref_key`.
  -- An `elro.` field, not a local: the enclosing function is at the 200-local ceiling.


  elro._pull_stretch_price = function(c, strE)
    if not c then return strE end
    if c.kind == "chord" then return 0 end
    local k = TUNE.springK
    if c.corridor then return k * c.corridor * c.corridor end
    if c.set and not c.deltas and (c.dist or 0) > 0 then
      local gap = c.dist or 1
      -- straddle, not stretch: _stretch_energy charges extension only
      local straddles = false
      for r in pairs(c.set) do
        for d, w in each_exit(adj[r]) do
          local de = DELTA[d]
          if de and (de[1] ~= 0 or de[2] ~= 0) and placed[w] and not c.set[w] then
            straddles = true ; break
          end
        end
        if straddles then break end
      end
      return straddles and (k * gap * gap) or 0
    end
    return strE
  end

  local function junction_score(cands, subj, blk)
    -- Setup (LCA, stopSet, branch BFS, windowing, O-set pass) is O(placed) per collision; timed as _jsT.
    elro.bg_tick("junction-score")
    local _js0 = elro.timeGuillo and CLK()
    local function jsDone()
      if _js0 then elro._jsT = (elro._jsT or 0) + (CLK() - _js0) ; elro._jsN = (elro._jsN or 0) + 1 end
    end
    local J, cV, cB, isBlk, why = lca_junction(subj, blk)
    elro._lcaReason = why                             -- surfaced by the NON-JUNCTION traces below
    -- histogram of nil-LCA reasons: no junction means both two-lever tiers are skipped
    if why then
      elro._lcaWhy = elro._lcaWhy or {}
      elro._lcaWhy[why] = (elro._lcaWhy[why] or 0) + 1
    else
      elro._lcaOk = (elro._lcaOk or 0) + 1
    end
    if not J then jsDone() ; return nil end
    local stopSet = {}
    local blkInGrid = false   -- is the BLOCKER itself a grid member (collision vs the grid)?
    if isBlk then
      local roomBlock = (hints and hints.roomBlock) or {}
      local Bid = roomBlock[J]
      if Bid then
        for r, bi in pairs(roomBlock) do if bi == Bid then stopSet[r] = true end end
        blkInGrid = (roomBlock[blk] == Bid)
      else stopSet[J] = true ; blkInGrid = (blk == J) end
    else
      stopSet[J] = true
    end
    local function branch_rooms(start)                     -- placed rooms on start's side of the LCA
      if stopSet[start] then return {} end
      local seen, q, qh, out = { [start] = true }, { start }, 1, { start }
      while qh <= #q and #out < 500 do
        local x = q[qh] ; qh = qh + 1
        for d, vv in each_exit(adj[x]) do
          local de = DELTA[d]
          if de and (de[1] ~= 0 or de[2] ~= 0) and placed[vv] and not seen[vv] and not stopSet[vv] then
            seen[vv] = true ; q[#q + 1] = vv ; out[#out + 1] = vv
          end
        end
      end
      return out
    end
    local branchVset, branchBset = {}, {}
    for _, r in ipairs(branch_rooms(subj)) do branchVset[r] = true end
    for _, r in ipairs(branch_rooms(blk)) do branchBset[r] = true end
    -- Probe: do V and B overlap? `branch_rooms` stops only at the LCA, and removing one vertex cannot
    -- separate two rooms on a common cycle, so on a loop closure both sets hold both rooms and the
    -- field charges a structure against itself. Counted here only.
    do
      local ov, nv, nb = 0, 0, 0
      for r in pairs(branchVset) do nv = nv + 1 ; if branchBset[r] then ov = ov + 1 end end
      for _ in pairs(branchBset) do nb = nb + 1 end
      elro._jsN2 = (elro._jsN2 or 0) + 1
      if ov > 0 then
        elro._jsOverlapN = (elro._jsOverlapN or 0) + 1
        elro._jsOverlapCells = (elro._jsOverlapCells or 0) + ov
        if branchVset[blk] and branchBset[subj] then
          elro._jsMutual = (elro._jsMutual or 0) + 1
        end
      end
    end
    -- Victim tagging: vs the grid, the grid is the victim (added to B); vs another branch, only that
    -- branch is, and the shared grid stays neutral (the branch legitimately attaches to it).
    if isBlk and blkInGrid then for r in pairs(stopSet) do branchBset[r] = true end end
    -- V's attachment is not a wall: block rooms joined to a V room by a real exit (attachSet) are neutral,
    -- else the branch is charged for lying alongside the corridor feeding its own anchor. Do not extend
    -- vAdj for this (the collision itself is maximally adjacent) nor neutralise the whole grid (B empties).
    local attachSet = {}
    for r in pairs(branchVset) do
      for d, w in each_exit(adj[r]) do
        local de = DELTA[d]
        -- never the blocker itself, or B empties for that pair
        if de and (de[1] ~= 0 or de[2] ~= 0) and w ~= blk and branchBset[w] and stopSet[w] then
          attachSet[w] = true
        end
      end
    end
    for r in pairs(attachSet) do branchBset[r] = nil end
    local role = {}                                        -- room -> "V"/"B"/"G" for the mapstep grid
    for r in pairs(branchVset) do role[r] = "V" end
    for r in pairs(branchBset) do role[r] = "B" end
    for r in pairs(attachSet) do role[r] = "G" end          -- neutral: V's own anchor in the block
    -- NEUTRAL grid: the shared LCA block, when the collision is vs a BRANCH (not the grid itself), is
    -- tagged "G" so mapstep shows it distinct from generic other rooms -- it repels neither branch.
    for r in pairs(stopSet) do if not role[r] then role[r] = "G" end end
    -- Radius 3: at R=2 the one-sided (R-L)^2 field has no gradient past distance 1 and degenerates
    -- into a count of adjacent blocker rooms.
    local R = TUNE.repelRadius
    local mult = TUNE.repelMult
    local cxr, cyr = coord[subj][1], coord[subj][2]
    local WINr = TUNE.junctionWin
    local Vm, Bm = {}, {}                                  -- windowed branch members (all-pairs is local)
    for r in pairs(branchVset) do local p = coord[r] ; if p and math.abs(p[1] - cxr) <= WINr and math.abs(p[2] - cyr) <= WINr then Vm[#Vm + 1] = r end end
    for r in pairs(branchBset) do local p = coord[r] ; if p and math.abs(p[1] - cxr) <= WINr and math.abs(p[2] - cyr) <= WINr then Bm[#Bm + 1] = r end end
    -- Other-room repel: a windowed placed room outside V, B and the neutral grid repels like B unless
    -- it is currently 8-way adjacent to a V room (its attachment / spine contact).
    local Vcells = {}
    for r in pairs(branchVset) do local p = coord[r] ; if p then Vcells[p[1] .. ":" .. p[2]] = true end end
    local function vAdj(p)
      for ddx = -1, 1 do for ddy = -1, 1 do
        if not (ddx == 0 and ddy == 0) and Vcells[(p[1] + ddx) .. ":" .. (p[2] + ddy)] then return true end
      end end
      return false
    end
    local oSet = {}                                       -- O (other-room) members, for DYNAMIC re-neutralize
    for r in pairs(placed) do
      if not branchVset[r] and not branchBset[r] and not stopSet[r] then
        local p = coord[r]
        if p and math.abs(p[1] - cxr) <= WINr and math.abs(p[2] - cyr) <= WINr and not vAdj(p) then
          Bm[#Bm + 1] = r ; role[r] = "O" ; oSet[r] = true -- not adjacent to V (at this state) -> repel like B
        end
      end
    end
    jsDone()                        -- setup ends here; the loop below is the per-candidate cost
    for _, c in ipairs(cands) do
      local pulls = { { set = c.set or {}, dx = c.dx or 0, dy = c.dy or 0, dist = c.dist or 0, deltas = c.deltas } }
      -- Shear is measured for every kind from the same pass; chords and guillotines opt out of the
      -- stretch energy (`shearOnly`) but can still tip a settled 45.
      local shearOnly = (c.kind == "chord" or c.kind == "guillotine")
      local strE, shear, shEdges, dLen = elro._stretch_energy(coord, adj, pulls, shearOnly)
      c.shear = shear ; c.shearEdges = shEdges ; c.dLen = dLen
      local stretch = elro._pull_stretch_price(c, strE)
      -- keep both halves for the trace
      local repE = mult * repel_energy(Vm, Bm, R, pulls, oSet, attachSet)
      c.repelE, c.stretchE = repE, stretch
      c.score = repE + stretch
    end
    -- A derived square companion may not outrank its seed: floor it at the seed's energy (shear lives
    -- in `_pref_key`), so its only edge is the shear it was built to avoid. Not a veto: the companion
    -- is right when the seed really is the best move.
    local seedScore
    for _, c in ipairs(cands) do
      if c.compSeedEk then
        if not seedScore then
          seedScore = {}
          for _, d in ipairs(cands) do
            local s = seedScore[d.ek]
            if d.score and (not s or d.score < s) then seedScore[d.ek] = d.score end
          end
        end
        local sc = seedScore[c.compSeedEk]
        if sc and c.score and c.score < sc then c.score = sc end
      end
    end
    elro._rank_cands(cands)
    return { J = J, isBlk = isBlk, Vm = Vm, Bm = Bm, R = R, mult = mult, role = role, oSet = oSet, aSet = attachSet,
      spr = "R" .. R .. "x" .. mult .. ":" .. #Vm .. "v/" .. #Bm .. "b" }
  end
  -- forward declarations: defined further down but called from insert_unit;
  -- without them they resolve to nil globals and still parse clean.
  local query_cut_levers, query_eq_levers
  -- forward: class_seam and class_shearfree_seeds live with the class generator below, but
  -- query_eq_levers needs them here
  local class_seam
  local class_shearfree_seeds
  -- The equation-plate label, in one place: `eq:<seed>:<dir><mag>[:<annotation>]`. Compass letters
  -- survive maptop's digit-collapsing bucket and cannot be read backwards.
  -- Axis 1 is x (east/west), axis 2 is y, +y is north (`elro.delta`).
  local EQ_DIR = { [1] = { [-1] = "w", [1] = "e" }, [2] = { [-1] = "s", [1] = "n" } }
  local EQ_INV = { w = "e", e = "w", n = "s", s = "n" }
  -- The same compass grammar for the repair passes, built off `EQ_DIR` so the two spellings cannot
  -- diverge. No `eq:` prefix: these are not lever labels and nothing sorts on them.
  local function plate_label(start, axis, sh)
    local d = EQ_DIR[axis] and EQ_DIR[axis][(sh or 0) >= 0 and 1 or -1] or "?"
    return string.format("%s:%s%d", tostring(start), d, math.abs(sh or 0))
  end
  local AXIS_WORD = { [1] = "east/west", [2] = "north/south" }
  -- 1D: eq_ek(seed, axis, sign, mag, ann) -> "eq:308:w1:u"
  -- 2D: eq_ek(seed, nil, nil, nil, ann, sh) with sh = {dx, dy} -> "eq:308:e2n1" / "eq:308:ne2"
  -- An equal-magnitude diagonal collapses to one compass word (`ne2`); unequal magnitudes keep both components.
  local function eq_ek(seed, axis, sign, mag, ann, sh)
    local body
    if sh then
      local sx, sy = sh[1] or 0, sh[2] or 0
      if sx ~= 0 and sy ~= 0 and math.abs(sx) == math.abs(sy) then
        body = EQ_DIR[2][sy > 0 and 1 or -1] .. EQ_DIR[1][sx > 0 and 1 or -1] .. math.abs(sx)
      else
        body = ""
        if sx ~= 0 then body = body .. EQ_DIR[1][sx > 0 and 1 or -1] .. math.abs(sx) end
        if sy ~= 0 then body = body .. EQ_DIR[2][sy > 0 and 1 or -1] .. math.abs(sy) end
      end
    else
      body = EQ_DIR[axis][sign > 0 and 1 or -1] .. math.abs(mag)
    end
    return "eq:" .. seed .. ":" .. body .. (ann and (":" .. ann) or "")
  end
  -- The label is a sort key (`_rank_cands` tie-breaks on tostring(ek)). `_ek_ord` reconstructs the
  -- legacy label so the comparator keeps the order the current layouts were tuned against.
  local function _ek_ord(ek)
    if type(ek) ~= "string" then return ek end
    local pfx, rest = ek:match("^(diag)eq:(.*)$")
    if not pfx then pfx, rest = "", ek:match("^eq:(.*)$") end
    if not rest then return ek end
    local seed, body, ann = rest:match("^(%d+):([nsew%d]+):?(.*)$")
    if not seed then return ek end
    local A = { w = { 1, "-" }, e = { 1, "+" }, s = { 2, "-" }, n = { 2, "+" } }
    local one = body:match("^([nsew])(%d+)$")
    if one then                                   -- 1D: eq:<seed>:<d><m> -> eq:<axis>:<seed>:<sign><m>
      local d, m = body:match("^([nsew])(%d+)$")
      return pfx .. "eq:" .. A[d][1] .. ":" .. seed .. ":" .. A[d][2] .. m
             .. ((ann ~= "") and (":" .. ann) or "")
    end
    -- 2D: legacy prefix was `eq2d:`, body = x component then y component, each <sign><magnitude>.
    local sx, sy
    local d1, d2, m = body:match("^([nsew])([nsew])(%d+)$")
    if d1 then
      for _, d in ipairs({ d1, d2 }) do
        if A[d][1] == 1 then sx = A[d][2] .. m else sy = A[d][2] .. m end
      end
    else
      for d, mm in body:gmatch("([nsew])(%d+)") do
        if A[d][1] == 1 then sx = A[d][2] .. mm else sy = A[d][2] .. mm end
      end
    end
    return "eq2d:" .. seed .. ":" .. (sx or "+0") .. (sy or "+0")
           .. ((ann ~= "") and (":" .. ann) or "")
  end
  elro._ek_ord = _ek_ord
  -- The inverse label: the same plate pushed the other way. Annotation is preserved (`:sf` inverts to `:sf`).
  local function eq_ek_inverse(ek)
    if type(ek) ~= "string" then return nil end
    local seed, body, ann = ek:match("^eq:(%d+):([nsew]+%d+[nsew]*%d*):?(.*)$")
    if not seed then return nil end
    local flipped = body:gsub("[nsew]", function(d) return EQ_INV[d] end)
    return "eq:" .. seed .. ":" .. flipped .. ((ann ~= "") and (":" .. ann) or "")
  end
  -- graded wrapper over class_seam
  local function seam2d(setB, dl)
    local t = class_seam(setB, nil, nil, dl)
    if t < math.huge then return t end
    return nil, true                               -- computed, and FREE (see the renderer)
  end
  -- 2D (two-axis) equation plates; defined further down.
  local query_eq_2d_levers
  -- Ring dilation: grow every diagonal of one family on a bounded face ring together; defined further down.
  local query_ring_dilate_levers
  -- Insert a frozen block unit one step off `anchor` in `dname`, entering at `entry`. The block is
  -- rigid: collisions are cleared by moving the blocker with the normal lever engine, never by sliding the block.
  local function insert_unit(idx, anchor, dname, entry)
    local U = units[idx] ; local L = U.coord ; local de = DELTA[dname]
    local ax, ay = coord[anchor][1], coord[anchor][2]
    local ex, ey = L[entry][1], L[entry][2]
    for r in pairs(U.rooms) do
      coord[r] = { ax + de[1] + (L[r][1] - ex), ay + de[2] + (L[r][2] - ey) } ; placed[r] = true
      elro._bfGen = (elro._bfGen or 0) + 1
      elro._walkN = elro._walkN + 1 ; elro._walkOrder[r] = elro._walkN
    end
    -- the block's own edges are registered after resolution, so detectors see the block vs already-placed geometry only
    local attachEk = ekey(anchor, entry)
    -- `skip`: block rooms whose collision had no clean lever this pass; return the first colliding block room not in skip.
    local function block_conflict(skip)
      for r in pairs(U.rooms) do
        if not (skip and skip[r]) then
          local X = cell_overlap(r)
          if X and not U.rooms[X] then
            return r, X, elro.cheapest_lever_overlap(coord, adj, r, X, branchSet, entry) end
          local w, ce = first_crossing_v(r)
          if ce and not (U.rooms[ce.u] and U.rooms[ce.v]) then
            return r, ce.u, elro.cheapest_lever(coord, adj, { u = r, v = w }, { u = ce.u, v = ce.v }, branchSet, entry) end
          local w2, R = edge_over_room_v(r)
          if R and not U.rooms[R] then
            return r, R, elro.cheapest_lever_roomedge(coord, adj, R, { u = r, v = w2 }, branchSet, entry) end
          local ve = room_on_pedge_v(r)
          if ve and not (U.rooms[ve.u] and U.rooms[ve.v]) then
            return r, ve.u, elro.cheapest_lever_roomedge(coord, adj, r, ve, branchSet, entry) end
        end
      end
    end
    local guard, blk = 0, nil
    local tries = {}   -- per-iteration lever-attempt trace for mapcaps/mapstep (stage="block")
    local stuckR, stuckRanked, stuckDiag   -- captured on the STUCK iteration (no clean pick)
    local lastQblReason   -- why query_block_levers emitted (or didn't) a face cut this iteration
    local skip = {}   -- block rooms whose collision had no clean lever THIS pass (retry others first)
    while guard < 100 do
      guard = guard + 1
      local r, b2, cands = block_conflict(skip)
      if not r then break end   -- no untried collision left: either fully clean, or all remaining stuck
      blk = b2
      local nGuilloRaw, nGuilloKept = 0, 0   -- how many face-expansion cuts query_block_levers made / kept
      if blk then
        local bw, bh = 0, 0
        do
          local mnx, mny, mxx, mxy = math.huge, math.huge, -math.huge, -math.huge
          for _, p in pairs(L) do
            if p[1] < mnx then mnx = p[1] end ; if p[1] > mxx then mxx = p[1] end
            if p[2] < mny then mny = p[2] end ; if p[2] > mxy then mxy = p[2] end
          end
          bw, bh = mxx - mnx, mxy - mny
        end
        local gg = {}
        -- chord slack-redistribution: slide the unit along its wall using existing slack
        for _, c in ipairs(query_cut_levers(anchor, blk, r, U.rooms, U.rooms)) do gg[#gg + 1] = c end
        if #gg > 0 then
          elro._score_cands(coord, adj, r, r, blk, gg)
          for _, c in ipairs(gg) do cands[#cands + 1] = c end
          elro._rank_cands(cands)
        end
      end
      -- score the block's levers by the same LCA-junction repel field as a lone room; nil on no junction (fallback ordering stands)
      local jd = junction_score(cands, r, blk)
      if not jd then
        elro.tr(string.format("NON-JUNCTION block lever: r=%s blk=%s unit=%d (lca %s) -> rooms+dist fallback",
          tostring(r), tostring(blk), idx, tostring(elro._lcaReason)))
      end
      -- pick the first ranked lever that is into-empty and does not extend the attach bridge, make a crossing, or land a room on an edge
      local pick, ranked = nil, {}
      local nCasc, nCross, nRE, nAttach, nGuilloRanked = 0, 0, 0, 0, 0
      -- before-sets once; identical for every candidate
      local beforeCross = crossing_set(r)
      local beforeRE = roomedge_set(r)
      for _, c in ipairs(cands or {}) do
        local why
        if c.kind == "guillotine" then nGuilloRanked = nGuilloRanked + 1 end
        local _mc, _mcList
        if c.intoEmpty then _mc, _mcList = pull_makes_crossing(c, r, beforeCross) end
        -- a crossing the cost pass asked for is not a demerit; scoped to the cost keys only, never all of `W.pair`
        if _mc and _mcList and elro._crossPairKeys then
          local allWanted = true
          for _, k in ipairs(_mcList) do
            if not elro._crossPairKeys[k] then allWanted = false ; break end
          end
          if allWanted then _mc = nil ; c.crossWanted = true end
        end
        if not c.intoEmpty then why = "cascade" ; nCasc = nCasc + 1
        elseif _mc then why = "makes-crossing" ; nCross = nCross + 1 ; c.crossNew = _mcList
        elseif c.ek == attachEk then why = "attach-edge" ; nAttach = nAttach + 1
        elseif _re then why = "makes-room-on-edge" ; nRE = nRE + 1
        elseif not pick then pick = c ; why = "PICKED"
        else why = "ranked-lower" end

        -- a forced lever (`elro.forceLever`) overrides the guards; the verdict is still reported and `_flOverride` counts it
        if c._forced and pick ~= c and why and why ~= "PICKED" and why ~= "ranked-lower" then
          why = "FORCED-OVERRIDE"
          pick = c
          elro._flOverride = (elro._flOverride or 0) + 1
        end
        if #ranked < 20 then
          ranked[#ranked + 1] = { ek = c.ek, kind = c.kind, cost = c.cost, score = c.score,
            -- the snapshot copies a fixed field list; a field added to a candidate must be added here and at the cascade/apply site too
            pAbs = c.pAbs,
            repelE = c.repelE, stretchE = c.stretchE,   -- elro.repelDump: the two halves of the score
            rooms = c.rooms, roomsFull = c.roomsFull, artic = c.artic, why = why, shear = c.shear,
            artic2 = c.artic2, dist = c.dist,
            crossNew = c.crossNew,
            shearEdges = c.shearEdges, seamTight = c.seamTight, seamFree = c.seamFree,
            seamEdges = c.seamEdges, seamAtMin = c.seamAtMin, seamGrow = c.seamGrow,
            rides = c.rides }
        end
        if pick then break end                          -- clean pick found; the rest is never reached
      end
      tries[#tries + 1] = { r = r, blocker = blk, ncands = #cands, guilloRaw = nGuilloRaw,
        guilloKept = nGuilloKept, guilloRanked = nGuilloRanked, nCasc = nCasc, nCross = nCross,
        nRE = nRE, nAttach = nAttach, picked = pick and { kind = pick.kind, dist = pick.dist } or nil }
      if not pick then
        -- no clean lever for this collision: skip it and try another; capture the rejected-candidate detail in case the block ends up stuck
        skip[r] = true
        stuckR, stuckRanked = r, ranked
        stuckDiag = string.format("guillo raw=%d kept=%d ranked=%d | cand=%d casc=%d cross=%d roomedge=%d attach=%d\n    query_block_levers: %s",
          nGuilloRaw, nGuilloKept, nGuilloRanked, #cands, nCasc, nCross, nRE, nAttach, tostring(lastQblReason))
      else
        skip = {}   -- progress: geometry changed -> re-evaluate every collision fresh next pass
        elro._walkPulls[#elro._walkPulls + 1] = { v = entry, kind = pick.kind, ek = pick.ek,
          dx = pick.dx, dy = pick.dy, dist = pick.dist, rooms = pick.rooms }
        for rr in pairs(pick.set) do
          local dx, dy = cand_shift(pick, rr) ; coord[rr] = { coord[rr][1] + dx, coord[rr][2] + dy }
        end
        elro.step_snap(coord, string.format("block lever: %s for unit %d (%dr dist %d)",
          pick.kind, idx, pick.rooms or 0, pick.dist), entry, blk,
          { ek = pick.ek, kind = pick.kind, cost = pick.cost, score = pick.score, cent = pick.cent,
            open = pick.open, rooms = pick.rooms, dist = pick.dist,
            artic = pick.artic, ckind = "block", blocker = blk, ranked = ranked })
      end
    end
    -- FINAL verdict: any collision still remaining (ignoring skip) marks the block STUCK -> leftover.
    do local _, fblk = block_conflict() ; blk = fblk end
    for r in pairs(U.rooms) do mark(r) ; add_edges(r) end
    unitDone[idx] = true
    if blk then
      for r in pairs(U.rooms) do leftover[r] = true end
      -- stuck block: record the rejected-lever detail for mapcaps (stage="block")
      elro._capLog = elro._capLog or {}
      elro._capLog[#elro._capLog + 1] = { stage = "block", A = anchor, room = entry, dir = dname,
        n = elro.tcount(U.rooms), kind = "block", blocker = blk, tries = tries, ranked = stuckRanked,
        reason = (stuckDiag or "no clean lever") ..
          ((tries[#tries] and (tries[#tries].guilloRaw or 0) == 0)
            and "  -> NO guillotine created (anchor/blocker not one focal block, or no clearing gap<=cap)"
            or "") }
    end
    elro.step_snap(coord, "block unit inserted (" .. elro.tcount(U.rooms) .. "r off " .. anchor ..
      " " .. dname .. (blk and (", STUCK -- " .. (stuckDiag or "")) or "") .. ")", entry,
      blk or (stuckR), { ckind = "block", blocker = blk, ranked = stuckRanked })
  end
  -- runaway guard: cap total visit calls so a malformed unit/tail loop errors instead of freezing the client
  local visitCalls, VISIT_CAP = 0, 200000
  local function runaway(u)
    visitCalls = visitCalls + 1
    if visitCalls == VISIT_CAP then
      elro.tr("  walk_branches: RUNAWAY at " .. tostring(u) .. " _walkN=" .. tostring(elro._walkN))
      error("walk_branches runaway (visitCalls=" .. VISIT_CAP .. ")")
    end
  end
  -- gather + order the placeable neighbours of u, tagged isArtery. Not filtered by `placed`: the pass-2 spine walk needs placed artery neighbours.
  local function gather_kids(u)
    local udeg = placed_degree(u)
    local kids = {}
    for d, v in each_exit(adj[u]) do
      local de = DELTA[d]
      if de and (de[1] ~= 0 or de[2] ~= 0) then
        if outwardSet[v] then
          kids[#kids + 1] = { v = v, d = d, sz = subtree_size(u, v), blk = udeg >= 2 }
        elseif unitByRoom[v] then
          -- a frozen block unit off u; surfaced even if already inserted so pass 2 can walk through it
          local ui = unitByRoom[v]
          kids[#kids + 1] = { v = v, d = d, sz = elro.tcount(units[ui].rooms), blk = true, unit = ui }
        end
      end
    end
    for _, k in ipairs(kids) do k.isArtery = (not k.unit) and arteryRooms[k.v] and true or false end
    -- order: pendant (non-artery) kids FIRST -- block-face/unit (most constrained) then
    -- small-subtree-first; artery kids LAST, shorter spurs before the deeper road.
    table.sort(kids, function(a, b)
      if a.isArtery ~= b.isArtery then return b.isArtery end   -- non-artery first
      if a.blk ~= b.blk then return a.blk end
      if a.sz ~= b.sz then return a.sz < b.sz end
      return a.v < b.v
    end)
    return kids
  end
  -- lever candidates + conflict kind/blocker for v's CURRENT conflict on the live coord
  -- (the same dispatch place_room's resolve loop uses). Returns cands, ckind, cblk or nil.
  local function lever_for(v)
    local X = cell_overlap(v)
    if X then return elro.cheapest_lever_overlap(coord, adj, v, X, branchSet, v), "overlap", X end
    local w, ce = first_crossing_v(v)
    if ce then return elro.cheapest_lever(coord, adj, { u = v, v = w }, { u = ce.u, v = ce.v }, branchSet, v), "cross", ce.u end
    local w2, R = edge_over_room_v(v)
    if R then return elro.cheapest_lever_roomedge(coord, adj, R, { u = v, v = w2 }, branchSet, v), "edge-on-room", R end
    local ve = room_on_pedge_v(v)
    if ve then return elro.cheapest_lever_roomedge(coord, adj, v, ve, branchSet, v), "room-on-edge", ve.u end
    return nil
  end
  -- `elro.probeMove = <roomid>` (or a list): trace every pull that moves the watched rooms, APPLY/REVERT tagged.
  local function probe_move(pick, tag)
    local w = elro.probeMove ; if not w or not pick.set then return end
    local list = (type(w) == "table") and w or { w }
    local hit = false
    for _, r in ipairs(list) do if pick.set[r] then hit = true ; break end end
    if not hit then return end
    local st = {}
    for _, r in ipairs(list) do
      st[#st + 1] = string.format("%s%s(%s)", pick.set[r] and "*" or "", tostring(r),
        coord[r] and (coord[r][1] .. "," .. coord[r][2]) or "-")
    end
    cecho(string.format("\n<magenta>[probe] %s #%s %s %s d=(%d,%d) plate=%d | %s<reset>",
      tag, tostring(elro._walkN), tostring(pick.kind), tostring(pick.ek or "-"),
      (pick.dx or 0) * (pick.dist or 0), (pick.dy or 0) * (pick.dist or 0),
      elro.tcount(pick.set), table.concat(st, " ")))
  end
  -- Census (timeGuillo): does an applied pull cut a biconnected block (part of it in the
  -- moved set) or deform one (a graded pull moving its members by different amounts)?
  -- A torn REMOTE block is a seam-walk failure by the user's rule (a working walk never splits one),
  -- so this count is the walk's regression signal, not something the ranking may price away.
  local function block_cut_census(pick)
    if not (pick.set and elro.blocks_adj) or pick._bcutSeen then return end
    pick._bcutSeen = true                   -- trial apply + commit: count a pick once
    -- the block the conflict lives in is MEANT to stretch; only remote blocks count
    local home = { [elro._placingV or -1] = true, [pick.eqStart or -1] = true, [pick.eqAnchor or -1] = true }
    local rooms, radj = {}, {}
    for r in pairs(placed) do if coord[r] then rooms[#rooms + 1] = r end end
    for _, r in ipairs(rooms) do
      radj[r] = {}
      for d, x in each_exit(adj[r]) do if placed[x] and coord[x] then radj[r][d] = x end end
    end
    local T = elro._bcut or {} ; elro._bcut = T
    local kind = tostring(pick.kind)
    local cut, deformed = 0, 0
    for _, comp in ipairs(elro.blocks_adj(rooms, radj)) do
      if #comp >= 3 then
        local mem, n = {}, 0
        for _, e in ipairs(comp) do
          for i = 1, 2 do local r = e[i] ; if not mem[r] then mem[r] = true ; n = n + 1 end end
        end
        local inN, dxs, dys, mixed = 0, nil, nil, false
        local isHome = false
        for r in pairs(mem) do if home[r] then isHome = true ; break end end
        for r in pairs(mem) do
          if not isHome and pick.set[r] then
            inN = inN + 1
            local dx, dy = cand_shift(pick, r)
            if dxs == nil then dxs, dys = dx, dy elseif dx ~= dxs or dy ~= dys then mixed = true end
          end
        end
        if isHome then
        elseif inN > 0 and inN < n then cut = cut + 1
        elseif inN == n and mixed then deformed = deformed + 1 end
      end
    end
    local e = T[kind] ; if not e then e = { n = 0, cut = 0, deformed = 0 } ; T[kind] = e end
    e.n = e.n + 1
    if cut > 0 then e.cut = e.cut + 1 end
    if deformed > 0 then e.deformed = e.deformed + 1 end
    if (cut > 0 or deformed > 0) and elro.timeGuillo then
      local L = elro._bcutList or {} ; elro._bcutList = L
      if #L < 30 then L[#L + 1] = string.format("%s %s cut=%d deformed=%d (%dr)", kind, tostring(pick.ek), cut, deformed, elro.tcount(pick.set)) end
    end
  end
  local function apply_pull(pick)
    if elro.timeGuillo then block_cut_census(pick) end
    for r in pairs(pick.set) do
      local dx, dy = cand_shift(pick, r) ; coord[r] = { coord[r][1] + dx, coord[r][2] + dy }
    end
    if elro.probeMove then probe_move(pick, "APPLY ") end
  end
  local function revert_pull(pick)
    for r in pairs(pick.set) do
      local dx, dy = cand_shift(pick, r) ; coord[r] = { coord[r][1] - dx, coord[r][2] - dy }
    end
    if elro.probeMove then probe_move(pick, "REVERT") end
  end
  -- Lives here (not with the other pull_makes_* guards) because it needs apply_pull/revert_pull above.
  -- Does this pull turn a truthful edge into a lie? Only edges with exactly one endpoint moving (or a
  -- graded pull's unequal pair) can flip. Incoming edges matter: `adj` is directed and the mirror
  -- pass only fills an empty reverse slot, so index the reverse adjacency once (adj is stable for the walk).
  local lieRadj
  local function lie_radj()
    if lieRadj then return lieRadj end
    lieRadj = {}
    for u, nb in pairs(adj) do
      for d, x in pairs(nb) do
        local t = lieRadj[x] ; if not t then t = {} ; lieRadj[x] = t end
        t[#t + 1] = { u = u, d = d }
      end
    end
    return lieRadj
  end
  -- Second return names the fresh lying edges (into `whyDetail`).
  local function pull_makes_lie(pick, v)
    local set = pick and pick.set
    if not set then return false end
    local RA = lie_radj()
    local function boundary_lies()
      local n, keys = 0, {}
      local function test(r, d, x)
        local de = DELTA[d]
        if placed[x] and coord[x] and placed[r] and coord[r]
           and de and (de[1] ~= 0 or de[2] ~= 0) then
          -- both endpoints moving identically => rigid => truthfulness fixed. cand_shift returns two numbers, not a table.
          local rdx, rdy = cand_shift(pick, r)
          local xdx, xdy = cand_shift(pick, x)
          local rigid = set[r] and set[x] and rdx == xdx and rdy == xdy
          if not rigid then
            local dx, dy = coord[x][1] - coord[r][1], coord[x][2] - coord[r][2]
            local ok
            if de[1] ~= 0 and de[2] ~= 0 then ok = (dx * de[1] > 0 and dy * de[2] > 0)
            elseif de[1] ~= 0 then ok = (dy == 0 and dx * de[1] >= 1)
            else ok = (dx == 0 and dy * de[2] >= 1) end
            if not ok then
              n = n + 1
              -- key names the edge and which end the plate carried: `+dx,+dy` = in the plate, `-` = outside it
              keys[r .. "-" .. tostring(d) .. "->" .. x
                   .. "[" .. (set[r] and string.format("%+d,%+d", rdx, rdy) or "-")
                   .. "|" .. (set[x] and string.format("%+d,%+d", xdx, xdy) or "-") .. "]"] = true
            end
          end
        end
      end
      for r in pairs(set) do
        for d, x in each_exit(adj[r]) do test(r, d, x) end       -- outgoing
        for _, e in ipairs(RA[r] or {}) do test(e.u, e.d, r) end   -- incoming
      end
      return n, keys
    end
    local before, kBefore = boundary_lies()
    apply_pull(pick)
    local after, kAfter = boundary_lies()
    revert_pull(pick)
    if after <= before then return false end
    -- sorted, at most three: `pairs` order would make the name differ between runs
    local fresh = {}
    for k in pairs(kAfter) do if not kBefore[k] then fresh[#fresh + 1] = k end end
    table.sort(fresh)
    return true, (#fresh > 0) and table.concat(fresh, " ", 1, math.min(#fresh, 3)) or nil
  end

  -- Total lying edges over every placed room at the current coordinates. The cascade needs an
  -- absolute count judged from a pre-pull1 baseline: a pair can create a lie neither pull makes alone.
  -- Iterating adj[r] over all placed r visits every directed edge once. O(E) per surviving candidate.
  local function lie_census()
    local n = 0
    for r in pairs(placed) do
      local pr = coord[r]
      if pr then
        for d, x in each_exit(adj[r]) do
          local de = DELTA[d]
          local px = coord[x]
          if placed[x] and px and de and (de[1] ~= 0 or de[2] ~= 0) then
            local dx, dy = px[1] - pr[1], px[2] - pr[2]
            local ok
            if de[1] ~= 0 and de[2] ~= 0 then ok = (dx * de[1] > 0 and dy * de[2] > 0)
            elseif de[1] ~= 0 then ok = (dy == 0 and dx * de[1] >= 1)
            else ok = (dx == 0 and dy * de[2] >= 1) end
            if not ok then n = n + 1 end
          end
        end
      end
    end
    return n
  end

  -- Part B: two-lever search. `pull1` is the best blocked single candidate. Apply it, re-detect v's
  -- conflict, and among the new candidates pick a pull2 that clears v cleanly. Scored at the final
  -- state: mult*repel + stretch(pull1) + stretch(pull2), comparable to a single lever's S1. Non-destructive.
  -- Returns best pull2, minCombined, ntried, ncands2, ckind2, minK; the caller decides adoption.
  -- `keyFn(c2, combined, shearC) -> key or nil` optionally replaces the default `_pref_key` ranking.
  local function two_lever_search(v, pull1, attachEk, Vm, Bm, R, mult, oSet, aSet, keyFn)
    -- `deltas` must be carried: a graded pull (eq2d, chord, diag-eq) has dx = dy = 0 and reads as stretch 0 / shear 0 without it.
    local pull1L = { { set = pull1.set or {}, dx = pull1.dx or 0, dy = pull1.dy or 0,
                       dist = pull1.dist or 0, deltas = pull1.deltas } }
    -- price pull1 the way the single tier prices it (corridor-priced), so it is comparable to S1
    local stretch1 = elro._stretch_energy(coord, adj, pull1L)   -- pull1 stretch from the ORIGINAL config
    stretch1 = elro._pull_stretch_price(pull1, stretch1)
    -- pull1's numeric displacement, so the pair's shear can be read against the pre-pull1 geometry
    local preD = {}
    for r in pairs(pull1.set or {}) do local dx, dy = cand_shift(pull1, r) ; preD[r] = { dx, dy } end
    -- a room-on-edge pull1 creates must be pull2's to clear: baseline before pull1, diff after
    local disp1 = disp_of(pull1)
    local preRE1 = roomedge_moved(pull1.set, v, disp1)          -- BEFORE pull1
    apply_pull(pull1)                                           -- coord now reflects pull1
    local pendRE = {}
    for k, t in pairs(roomedge_moved(pull1.set, v, disp1)) do
      if not preRE1[k] then pendRE[#pendRE + 1] = t end
    end
    local cands2, ckind2, cblk2 = lever_for(v)
    -- pull2 pool: bridge levers plus the eq-plate and chord generators for the residual conflict
    if cblk2 and coord[v] and coord[cblk2] then
      local g2
      -- `eqLazyCap` bounds the eq magnitude here; there is no escalation path for a pull2 the cap hides
      g2 = query_eq_levers(v, cblk2, nil, TUNE.eqLazyCap)
      for _, c in ipairs(query_cut_levers(v, cblk2, v)) do g2[#g2 + 1] = c end
      if #g2 > 0 then
        -- scores are not read by the ranking here; fills roomsFull/rooms for the trace and tie-breaks
        elro._score_cands(coord, adj, v, v, cblk2, g2)
        for _, c in ipairs(g2) do cands2[#cands2 + 1] = c end
      end
    end
    -- diagnostic label only: a strict `cross` with no proper crossing is a degenerate endpoint touch
    if ckind2 == "cross" then
      local genuine = false
      for dd, w in each_exit(adj[v]) do
        local de = DELTA[dd]
        if placed[w] and de and (de[1] ~= 0 or de[2] ~= 0) and first_crossing(v, w, true) then
          genuine = true ; break
        end
      end
      if not genuine then ckind2 = "room-on-edge(touch)" end
    end
    -- guard baselines hoisted: coord is post-pull1 and every candidate applies/reverts, so they are invariant
    local guardCross = crossing_set(v)
    local guardRE    = roomedge_set(v)
    local best, minC, minK, ntried = nil, math.huge, math.huge, 0
    for _, c2 in ipairs(cands2 or {}) do
      -- does pull2 leave any incidence pull1 created still standing?
      local function pend_ok()
        if #pendRE == 0 then return true end
        apply_pull(c2)
        local ok = true
        for _, t in ipairs(pendRE) do
          if on_edge_now(t[1], t[2], t[3]) then ok = false ; break end
        end
        revert_pull(c2)
        return ok
      end
      -- pull2 may not be pull1 or its inverse
      local selfPair = c2.ek and pull1.ek and
        (c2.ek == pull1.ek or c2.ek == tostring(pull1.ek):gsub("(:-?)(%d+)$", function(sg, mg)
          return (sg == ":-") and (":" .. mg) or (":-" .. mg) end))
      if c2.intoEmpty and c2.ek ~= attachEk and not selfPair
         and (function() elro._gudWho = "partB" ; return true end)()
         and not pull_makes_crossing(c2, v, guardCross)
         and not pull_makes_roomedge(c2, v, guardRE)
         and pend_ok() then
        ntried = ntried + 1
        -- energy at the final state; coord is post-pull1. `deltas` carried (see pull1L).
        local pulls2 = { { set = c2.set or {}, dx = c2.dx or 0, dy = c2.dy or 0,
                           dist = c2.dist or 0, deltas = c2.deltas } }
        local rep = repel_energy(Vm, Bm, R, pulls2, oSet, aSet)
        local stretch2 = elro._stretch_energy(coord, adj, pulls2)
        stretch2 = elro._pull_stretch_price(c2, stretch2)
        local combined = mult * rep + stretch1 + stretch2
        -- shear of the composite pair, read against the pre-pull1 geometry
        local _, shearC = elro._stretch_energy(coord, adj, pulls2, true, preD)
        -- a keyFn returning nil means skip; do not fall through to the default key
        local key
        if keyFn then key = keyFn(c2, combined, shearC) else key = elro._pref_key(combined, shearC) end
        if key and key < minK then minK = key ; minC = combined ; best = c2 ; best.shearC = shearC end
      end
    end
    -- the pair must actually clear v; one apply/revert on the winner only
    if best then
      apply_pull(best)
      local stillBad = cell_overlap(v)
      if not stillBad then local _, ce = first_crossing_v(v) ; stillBad = ce end
      if not stillBad then local _, R2 = edge_over_room_v(v) ; stillBad = R2 end
      if not stillBad then stillBad = room_on_pedge_v(v) end
      revert_pull(best)
      if stillBad then
        best, minC, minK = nil, math.huge, math.huge
        elro._pbNotClear = (elro._pbNotClear or 0) + 1
      end
    end
    revert_pull(pull1)
    return best, minC, ntried, (cands2 and #cands2 or 0), ckind2, minK
  end
  -- Pendant repair pass (`elro.pendRepair`), collector half: called at every commit site with the
  -- picks just applied; records edges the move stretched past their minimum (grew AND over min).
  -- Attempts run at end of step in repair_run, never here. A piston's own seed edge is excluded.
  -- `cv`/`cb` = the conflict pair the move was resolving, stored so repair_run can refuse to repair
  -- the arm the move deliberately reshaped.
  local function repair_after(cv, cb, ...)
    local picks = { ... }
    local sh, ownEk = {}, {}
    for _, P in ipairs(picks) do
      if P and P.set then
        if P.kind == "piston" and P.ek then ownEk[P.ek] = true end
        for r in pairs(P.set) do
          local dx, dy = cand_shift(P, r)
          local t = sh[r]
          if t then t[1] = t[1] + dx ; t[2] = t[2] + dy else sh[r] = { dx, dy } end
        end
      end
    end
    local seen = {}
    for r, shr in pairs(sh) do
      if placed[r] and coord[r] then
        for d, x in each_exit(adj[r]) do
          local de = DELTA[d]
          if placed[x] and coord[x] and de and (de[1] ~= 0 or de[2] ~= 0) then
            local k = ekey(r, x)
            if not seen[k] and not ownEk[k] then
              seen[k] = true
              local ex = coord[x][1] - coord[r][1] ; local ey = coord[x][2] - coord[r][2]
              local shx = sh[x]
              local px = ex - ((shx and shx[1] or 0) - shr[1])
              local py = ey - ((shx and shx[2] or 0) - shr[2])
              if ex < 0 then ex = -ex end ; if ey < 0 then ey = -ey end
              if px < 0 then px = -px end ; if py < 0 then py = -py end
              local len = (ex > ey) and ex or ey
              local lenB = (px > py) and px or py
              if len > lenB and len > (elro.min_len(r, x) or 1) then
                -- attempted edges are blocked for the relayout (`_repSeen`, marked at attempt); pending dedupes by key
                local RS = elro._repSeen
                local PD = elro._repPending ; if not PD then PD = {} ; elro._repPending = PD end
                if not (RS and RS[k]) and not PD[k] then
                  PD[k] = true ; PD[#PD + 1] = { r, x, len, lenB, k, cv, cb }
                end
              end
            end
          end
        end
      end
    end
  end
  local function repair_run()
    W.DELTA, W.adj, W.apply_pull, W.cell_overlap, W.coord, W.edge_over_room_v, W.first_crossing_v, W.placed = DELTA, adj, apply_pull, cell_overlap, coord, edge_over_room_v, first_crossing_v, placed
    W.pull_makes_lie, W.revert_pull, W.room_on_pedge_v, W.two_lever_search = pull_makes_lie, revert_pull, room_on_pedge_v, two_lever_search
    return repair_run_impl(W)
  end
  -- the back-edge reconcile calls stitch_one during the walk, so it needs the chord toolbox now
  elro._stitchTools = { qcl = query_cut_levers }
  -- ===== CLOSURE EQUATIONS (eqw) =====
  -- The hard facts are equalities: rooms joined by a chain of axial E/W edges share a row, by N/S
  -- edges a column. Edge lengths are free (>=1, correct sign). Classes are topological (over the
  -- whole walk scope, placed or not), so an unplaced room still conducts a lock.
  -- eqwCls[pa][r] = id of the class whose coordinate on axis `pa` is locked equal;
  --   pa=2 (y locked) <- E/W edges ; pa=1 (x locked) <- N/S edges.
  -- exA/exB = the closure edge under repair (excluded from the constraints); exRoom drops every
  -- edge incident to that room.
  -- The plain form is memoized per walk: `adj` is never written after setup and no consumer writes
  -- into the returned tables. Keyed calls are not memoized.
  local _ecMemoCls, _ecMemoMem
  local function eqw_classes(exA, exB, exRoom)
    -- two union-finds over the whole graph per call
    elro.bg_tick("eqw-classes")
    local _ec0 = elro.timeGuillo and CLK()
    local plain = not (exA or exB or exRoom)
    local ek = plain and "plain" or "keyed"
    elro._ecN = elro._ecN or {} ; elro._ecN[ek] = (elro._ecN[ek] or 0) + 1
    if plain and _ecMemoCls then
      elro._ecN.memo = (elro._ecN.memo or 0) + 1
      return _ecMemoCls, _ecMemoMem
    end
    local function build(edgeAxis)          -- edgeAxis 1 = E/W edges, 2 = N/S edges
      local p = {}
      local function find(a)
        while p[a] ~= a do p[a] = p[p[a]] ; a = p[a] end
        return a
      end
      for r, nb in pairs(adj) do
        if p[r] == nil then p[r] = r end
        for d, x in pairs(nb) do
          local de = DELTA[d]
          if de and adj[x] and de[edgeAxis] ~= 0 and de[3 - edgeAxis] == 0
             and not ((r == exA and x == exB) or (r == exB and x == exA))
             and r ~= exRoom and x ~= exRoom then
            if p[x] == nil then p[x] = x end
            local ra, rb = find(r), find(x)
            if ra ~= rb then p[ra] = rb end
          end
        end
      end
      local cls, mem = {}, {}
      for r in pairs(p) do
        local c = find(r) ; cls[r] = c
        local m = mem[c] ; if not m then m = {} ; mem[c] = m end
        m[#m + 1] = r
      end
      return cls, mem
    end
    local rowCls, rowMem = build(1)         -- E/W chains -> y locked
    local colCls, colMem = build(2)         -- N/S chains -> x locked
    if _ec0 then elro._ecT = (elro._ecT or 0) + (CLK() - _ec0) end
    local cls, mem = { [1] = colCls, [2] = rowCls }, { [1] = colMem, [2] = rowMem }
    -- the exclusions travel with the partition (weak-keyed): the field form rebuilds the partition from
    -- real edges and must honour them, or it re-imposes the equalities just removed
    local _xo = elro._ecExOf
    if not _xo then _xo = setmetatable({}, { __mode = "k" }) ; elro._ecExOf = _xo end
    _xo[cls] = (exA or exB or exRoom) and { a = exA, b = exB, r = exRoom } or false
    if plain then _ecMemoCls, _ecMemoMem = cls, mem end
    return cls, mem
  end
  -- forward declaration: face_tight(e) = smallest room count among the faces e borders; defined with the closure ranking
  local face_tight
  local function eqw_forced_shift(cls, mem, pa, start, s, anchor, rigidDiag, seeds, encl, pin, occIn, capN, dtBlkIn)
    W.DELTA, W.adj, W.coord, W.eqw_field_shift, W.placed, W.rigid_pendants = DELTA, adj, coord, eqw_field_shift, placed, rigid_pendants
    return eqw_forced_shift_impl(W, cls, mem, pa, start, s, anchor, rigidDiag, seeds, encl, pin, occIn, capN, dtBlkIn)
  end

  eqw_field_shift = function(cls, mem, seeds, anchorR, capN, occIn, start0, rigidAx, pinIn, blkIn)
    W.DELTA, W.adj, W.coord, W.crossing_bounds, W.placed = DELTA, adj, coord, crossing_bounds, placed
    return eqw_field_shift_impl(W, cls, mem, seeds, anchorR, capN, occIn, start0, rigidAx, pinIn, blkIn)
  end
  do                                   -- whole-call bucket for the field form (`timeGuillo`)
    local impl = eqw_field_shift
    eqw_field_shift = function(...)
      if not elro.timeGuillo then return impl(...) end
      local t0 = CLK()
      local a, b, c, d = impl(...)
      local dt = CLK() - t0
      elro._ffTime = (elro._ffTime or 0) + dt
      elro._ffCalls = (elro._ffCalls or 0) + 1
      if elro.probeField and not a and c then
        local rax = select(8, ...)
        local k = (rax and ("rigid" .. tostring(rax)) or "perm") .. (elro._gxFree and "+gxfree" or "")
        local w = tostring(c):gsub("<%-.*", "")
        w = w:gsub("@%d+", "@#") ; w = w:gsub("%d+%-%d+", "#-#")
        k = k .. " " .. w
        local T = elro._ffWhy ; if not T then T = {} ; elro._ffWhy = T end
        T[k] = (T[k] or 0) + 1
      end
      -- build cost bucketed by result size; a void is bucketed separately
      do
        local n = 0
        if a then for _ in pairs(a) do n = n + 1 end end
        local k = (not a) and "void" or (n <= 4 and "n_le4") or (n <= 16 and "n_le16")
          or (n <= 64 and "n_le64") or (n <= 256 and "n_le256") or "n_gt256"
        local F = elro._ffSize ; if not F then F = {} ; elro._ffSize = F end
        local e = F[k] ; if not e then e = { t = 0, n = 0 } ; F[k] = e end
        e.t = e.t + dt ; e.n = e.n + 1
      end
      return a, b, c, d
    end
  end
  -- Rigid-pendant rule (correctness, not preference): a bridge side holding no room the dilation asked to
  -- move has exactly one position that leaves the map otherwise unchanged, its anchor's displacement.
  -- Symmetric (left behind or carried too far), cannot create shear or lies, no size cap.
  -- The bridge forest is geometry-free: built once per generator call and reused by every candidate.
  bridge_forest = function()
    local bf = elro._rdBF
    if bf and bf.gen == elro._bfGen then return bf end
    local disc, low, par, br, kids, idx, skipped = {}, {}, {}, {}, {}, {}, {}
    local T = 0
    local function nbrs(u)
      local t = kids[u]
      if not t then
        t = {}
        for d, y in each_exit(adj[u]) do
          local de = DELTA[d]
          if de and (de[1] ~= 0 or de[2] ~= 0) and placed[y] then t[#t + 1] = y end
        end
        table.sort(t)                  -- never pairs() order: the hash seed moves it
        kids[u] = t
      end
      return t
    end
    -- an accepted-crossing bound is an edge of the constraint graph: Tarjan and the 2-edge-connected
    -- flood run over `nbrs_all` (bounds included, so the side is no longer a pendant), the forest over
    -- `nbrs` alone (a bound has no length to preserve, so it never becomes a tree edge).
    local XBN, kids2 = {}, {}
    do
      for r0, l in pairs(crossing_bounds()) do
        if placed[r0] then
          local real = {}
          for _, y in ipairs(nbrs(r0)) do real[y] = true end
          local t = {}
          for i = 1, #l do
            local o = (l[i][1] == r0) and l[i][2] or l[i][1]
            if placed[o] and o ~= r0 and not real[o] then real[o] = true ; t[#t + 1] = o end
          end
          table.sort(t)
          if #t > 0 then XBN[r0] = t end
        end
      end
    end
    local function nbrs_all(u)
      local x = XBN[u] ; if not x then return nbrs(u) end
      local t = kids2[u]
      if not t then
        t = {}
        for _, y in ipairs(nbrs(u)) do t[#t + 1] = y end
        for _, y in ipairs(x) do t[#t + 1] = y end
        kids2[u] = t
      end
      return t
    end
    for s0 in pairs(placed) do
      if not disc[s0] then
        T = T + 1 ; disc[s0] = T ; low[s0] = T ; idx[s0] = 1
        local st = { s0 }
        while #st > 0 do
          local u = st[#st]
          local t = nbrs_all(u)
          local i = idx[u]
          if i <= #t then
            idx[u] = i + 1
            local y = t[i]
            if y == par[u] and not skipped[u] then
              skipped[u] = true        -- skip exactly ONE parent edge (a doubled edge is real)
            elseif not disc[y] then
              T = T + 1 ; disc[y] = T ; low[y] = T ; par[y] = u ; idx[y] = 1
              st[#st + 1] = y
            elseif disc[y] < low[u] then
              low[u] = disc[y]
            end
          else
            st[#st] = nil
            local w = par[u]
            if w then
              if low[u] < low[w] then low[w] = low[u] end
              if low[u] > disc[w] then br[K.eid(u, w)] = true end
            end
          end
        end
      end
    end
    -- 2-edge-connected components: the graph MINUS the bridges
    local comp, cn = {}, 0
    for s0 in pairs(placed) do
      if not comp[s0] then
        cn = cn + 1 ; comp[s0] = cn
        local q, h = { s0 }, 1
        while h <= #q do
          local u = q[h] ; h = h + 1
          for _, y in ipairs(nbrs_all(u)) do
            if not comp[y] and not br[K.eid(u, y)] then comp[y] = cn ; q[#q + 1] = y end
          end
        end
      end
    end
    local tree, mem = {}, {}
    for s0 in pairs(placed) do
      local t = mem[comp[s0]] ; if t then t[#t + 1] = s0 else mem[comp[s0]] = { s0 } end
      for _, y in ipairs(nbrs(s0)) do
        if br[K.eid(s0, y)] then
          local a = tree[comp[s0]] ; if not a then a = {} ; tree[comp[s0]] = a end
          a[#a + 1] = { comp[y], s0, y }          -- child comp, my end, their end
        end
      end
    end
    bf = { comp = comp, tree = tree, mem = mem, gen = elro._bfGen }
    elro._rdBF = bf
    return bf
  end
  rigid_pendants = function(set, deltas, seedR, tag)
    W.DELTA, W.adj, W.bridge_forest, W.coord, W.placed = DELTA, adj, bridge_forest, coord, placed
    return rigid_pendants_impl(W, set, deltas, seedR, tag)
  end

  -- How many square truthful 45-degree walls does this displacement knock off 45? Deduped by
  -- edge so the count is comparable between plates. `pairs(deltas)` hash order is safe here:
  -- the result is a sum over a deduped edge set.
  -- `out` collects cascade premises from the FINAL geometry, one-end-stationary walls only
  -- (both-ends-moved is a disagreement between two frozen values -- nothing to propose). The
  -- premise is exact: the stationary end takes the moving end's projection, (nx, ny) from the
  -- wall's own family.
  -- `also`: walls this plate does not touch, included so two plates' counts range over the
  -- same union.
  local function diag_skew_n(deltas, out, also)
    local n, seen = 0, {}
    local src = deltas
    if also then
      src = {}
      for r, v in pairs(deltas) do src[r] = v end
      for r in pairs(also) do if src[r] == nil then src[r] = false end end
    end
    for r in pairs(src) do
      local cr = coord[r]
      for _, d in ipairs(DIRORDER) do
        local x = adj[r] and adj[r][d]
        local de = x and DELTA[d]
        if de and de[1] ~= 0 and de[2] ~= 0 and placed[x] and coord[x] and cr then
          local ek2 = ekey(r, x)
          if not seen[ek2] then
            local gx, gy = coord[x][1] - cr[1], coord[x][2] - cr[2]
            if gx ~= 0 and math.abs(gx) == math.abs(gy)
               and gx * de[1] >= 1 and gy * de[2] >= 1 then
              seen[ek2] = true
              local dr, dxx = deltas[r], deltas[x]
              local ox = (dxx and dxx[1] or 0) - (dr and dr[1] or 0)
              local oy = (dxx and dxx[2] or 0) - (dr and dr[2] or 0)
              if math.abs(gx + ox) ~= math.abs(gy + oy) then
                n = n + 1
                if out and (dr ~= nil) ~= (dxx ~= nil) then
                  local mv, st = r, x ; if dxx then mv, st = x, r end
                  local nx, ny = 1, (gx == gy) and -1 or 1
                  local d = deltas[mv]
                  -- `mv` rides along so the caller can find the CYCLE through this wall -- that is
                  -- what decides which edges could absorb its slack (see `absorbers`)
                  out[#out + 1] = { st, nx, ny, nx * d[1] + ny * d[2], mv }
                end
              end
            end
          end
        end
      end
    end
    return n
  end
  query_cut_levers = function(gwSubject, blk, clearRoom, ignore, riders)
    W.DELTA, W.adj, W.bridge_forest, W.cell_overlap, W.coord, W.det_sweep, W.diag_skew_n = DELTA, adj, bridge_forest, cell_overlap, coord, det_sweep, diag_skew_n
    W.edge_over_room_v, W.eqw_classes, W.eqw_forced_shift, W.first_crossing_v, W.placed, W.room_on_pedge_v = edge_over_room_v, eqw_classes, eqw_forced_shift, first_crossing_v, placed, room_on_pedge_v
    local _t0 = elro.timeGuillo and CLK()
    local r = query_cut_levers_impl(W, gwSubject, blk, clearRoom, ignore, riders)
    if _t0 then elro._cutT = (elro._cutT or 0) + (CLK() - _t0) ; elro._cutN = (elro._cutN or 0) + 1 end
    return r
  end
  local function eqw_diag_shift(start, pa, s, anchor, sep, seedSet, axc, noSoft, pin, cut)
    W.DELTA, W.DIRORDER, W.adj, W.coord, W.diag_skew_n, W.placed = DELTA, DIRORDER, adj, coord, diag_skew_n, placed
    return eqw_diag_shift_impl(W, start, pa, s, anchor, sep, seedSet, axc, noSoft, pin, cut)
  end
  -- Diagonal companion of a 1D plate. `clear_now` is per-generator (nil: the pick loop's
  -- guards judge).
  local function diag_companion(out, start, pa, s, anchor, mv, n, A, B, clear_now)
    local seedEk = out[#out].ek
    local ds2 = s
    -- `intoEmpty` is the first sort key, so a plate leaving one room on another ranks below
    -- every clean plate. The separation build runs as a second attempt only when the plain
    -- build landed dirty, and never replaces a plate with a void. The flag is verified.
    local function verify(set, dl)         -- clears v? lands in empty cells?
      local saved = {}
      for r in pairs(set) do
        local p = coord[r] ; saved[r] = p ; local e = dl[r]
        coord[r] = { p[1] + e[1], p[2] + e[2] }
      end
      local okd, empty = (clear_now == nil) or clear_now(), true
      if okd then
        local occ = {}
        for r in pairs(placed) do
          local p = coord[r]
          if p then
            local k = p[1] .. ":" .. p[2]
            if occ[k] then
              if set[r] or set[occ[k]] then empty = false ; break end
            else occ[k] = r end
          end
        end
      end
      for r, c in pairs(saved) do coord[r] = c end
      return okd, empty
    end
    local cascX = {}                       -- cascade plates at a DOUBLED magnitude (own candidates)
    -- `lock-diag-drag`: rebuild with the blocking rooms' soft equations refused, bounded at 4.
    local function build(sep, axc, pin, cut)
      local noSoft, set, nn, dl, xs, xd, xn, lock
      for _ = 1, 4 do
        local lock2
        set, nn, dl, xs, xd, xn, lock, lock2 =
          eqw_diag_shift(start, pa, ds2, anchor, sep, mv, axc, noSoft, pin, cut)
        if set or nn ~= "lock-diag-drag" or not lock then break end
        local grew = false
        for _, q in ipairs({ lock, lock2 }) do
          if not (noSoft and noSoft[q]) then
            noSoft = noSoft or {} ; noSoft[q] = true ; grew = true
          end
        end
        if not grew then break end
        elro._diagSoft = (elro._diagSoft or 0) + 1
      end
      if not (set and dl) then return nil, nn end
      local okd, empty = verify(set, dl)
      if not okd then return nil, "not-clear" end
      return set, nn, dl, empty
    end
    local dset, dn, ddl, empty = build(false)
    -- a uniform plate found nothing; retry with the axial completion only as a fallback
    if not dset and dn == "uniform-skew" then
      local aset, an, adl, aempty = build(false, true)
      if aset then dset, dn, ddl, empty = aset, an, adl, aempty
        elro._diagAxc = (elro._diagAxc or 0) + 1 end
    end
    if not dset and dn == "parity" then
      -- the retry changes the move, so `ek`/dist/cost must change with it
      ds2 = s * 2
      dset, dn, ddl, empty = build(false)
    end
    -- A repair tier may improve a plate or do nothing; it may never rescue a voided one.
    if dset and not empty then
      elro._diagSepT = (elro._diagSepT or 0) + 1
      local sset, sn, sdl, sempty = build(true)
      if sset and sempty then
        dset, dn, ddl, empty = sset, sn, sdl, sempty
        elro._diagSepW = (elro._diagSepW or 0) + 1
      end
    end
    -- Rigid-pendant rule on a non-ring plate: a side hanging off one bridge that contains
    -- neither start nor anchor carries no requirement and takes its class's displacement.
    if dset and ddl and rigid_pendants then
      local seedR = { [start] = true, [anchor] = true }
      if type(seedSet) == "table" then
        for k, v in pairs(seedSet) do
          if v == true then seedR[k] = true elseif type(v) == "number" then seedR[v] = true end
        end
      end
      local nf = rigid_pendants(dset, ddl, seedR,
        "diag" .. eq_ek(start, pa, ds2, ds2))
      if nf > 0 then
        dn = 0 ; for _ in pairs(dset) do dn = dn + 1 end
        elro._peRigid = (elro._peRigid or 0) + 1
      end
    end
    if dset and ddl then
        out[#out + 1] = { kind = "diag-eq",
          ek = "diag" .. eq_ek(start, pa, ds2, ds2),
          dx = 0, dy = 0,                 -- GRADED: the move lives in `deltas`
          dist = math.abs(ds2), cost = math.abs(ds2),
          rooms = dn, set = dset, deltas = ddl, intoEmpty = empty,
          -- a derived alternative may not outrank the plate it derives from
          compSeedEk = seedEk }
        elro._diagEqN = (elro._diagEqN or 0) + 1
        if elro.probeMove then           
          local ds = {}
          for r, e in pairs(ddl) do ds[#ds + 1] = r .. "(" .. e[1] .. "," .. e[2] .. ")" end
          table.sort(ds)
          cecho(string.format("\n<yellow>[diageq] %s seed=%s A=%s B=%s rooms=%d  %s<reset>",
            out[#out].ek, tostring(seedEk), tostring(A), tostring(B), dn,
            table.concat(ds, " ")))
        end
    elseif dn then
      elro._diagEqVoid = elro._diagEqVoid or {}
      elro._diagEqVoid[dn] = (elro._diagEqVoid[dn] or 0) + 1
      if elro.probeMove then         
        cecho(string.format("\n<red>[diageq-void] %s start=%s pa=%d s=%d anchor=%s A=%s B=%s<reset>",
          tostring(dn), tostring(start), pa, s, tostring(anchor), tostring(A), tostring(B)))
      end
    end
    -- doubled cascade plates: a different move (magnitude 2s), own candidates
    for _, c in ipairs(cascX) do
      out[#out + 1] = { kind = "diag-eq",
        ek = "diag" .. eq_ek(start, pa, c.s, c.s),
        dx = 0, dy = 0,
        dist = math.abs(c.s), cost = math.abs(c.s),
        rooms = c.rooms, set = c.set, deltas = c.deltas, intoEmpty = c.empty,
        compSeedEk = seedEk }
      elro._diagEqN = (elro._diagEqN or 0) + 1
      if elro.probeMove then           
        cecho(string.format("\n<yellow>[diageq-casc] %s seed=%s A=%s B=%s rooms=%d<reset>",
          out[#out].ek, tostring(seedEk), tostring(A), tostring(B), c.rooms))
      end
    end
  end

  -- Equation-derived separation plates. A plate is determined, not searched for: only
  -- equalities are hard, so the forced shift from start to anchor is the minimal plate.
  -- The shift magnitude is still geometric and is walked 1..CAP per direction.
  -- Bridges of the placed graph, memoised per placed count (bridges depend on adj and
  -- placed only, never on coord).
  local _brCache, _brCacheN = nil, -1
  local function placed_bridges()
    local n = 0
    for _ in pairs(placed) do n = n + 1 end
    if _brCache and _brCacheN == n then return _brCache end
    local rooms, radj = {}, {}
    for r in pairs(placed) do if coord[r] then rooms[#rooms + 1] = r end end
    table.sort(rooms)                       -- pairs order is hash order
    for _, r in ipairs(rooms) do
      radj[r] = {}
      for d, x in each_exit(adj[r]) do if placed[x] and coord[x] then radj[r][d] = x end end
    end
    local br = {}
    for _, comp in ipairs(elro.blocks_adj(rooms, radj)) do
      if #comp == 1 then
        local a, b = comp[1][1], comp[1][2]
        br[ekey(a, b)] = true
      end
    end
    _brCache, _brCacheN = br, n
    elro._brIdxN = (elro._brIdxN or 0) + 1
    return br
  end
  -- boundary bridges of a plate: sorted "a:b" list, or nil. Display only.
  local function plate_rides(mv)
    if not elro.probeSeam then return nil end
    local br = placed_bridges()
    local out, seen = nil, nil
    for r in pairs(mv) do
      for d, x in each_exit(adj[r]) do
        if DELTA[d] and placed[x] and not mv[x] and coord[x] then
          local k = ekey(r, x)
          if br[k] then
            out = out or {} ; seen = seen or {}
            if not seen[k] then seen[k] = true ; out[#out + 1] = k end
          end
        end
      end
    end
    if out then table.sort(out) ; elro._eqRide = (elro._eqRide or 0) + 1 end
    return out
  end
  query_eq_levers = function(A, B, clearSet, cap, pin, used)
    W.DELTA, W.adj, W.cell_overlap, W.class_seam, W.coord, W.diag_companion, W.diag_skew_n, W.edge_over_room_v = DELTA, adj, cell_overlap, class_seam, coord, diag_companion, diag_skew_n, edge_over_room_v
    W.eq_ek, W.eq_ek_inverse, W.eqw_classes, W.eqw_forced_shift, W.first_crossing_v, W.placed, W.plate_rides = eq_ek, eq_ek_inverse, eqw_classes, eqw_forced_shift, first_crossing_v, placed, plate_rides
    W.query_eq_2d_levers, W.room_on_pedge_v = query_eq_2d_levers, room_on_pedge_v
    return query_eq_levers_impl(W, A, B, clearSet, cap, pin, used)
  end
  query_eq_2d_levers = function(A, B, clearSet, cap, pin, mode, p1, p2, p3, p4, seedN, otherSg)
    W.cell_overlap, W.coord, W.edge_over_room_v, W.eq_ek, W.eqw_classes, W.eqw_forced_shift, W.first_crossing_v, W.placed = cell_overlap, coord, edge_over_room_v, eq_ek, eqw_classes, eqw_forced_shift, first_crossing_v, placed
    W.room_on_pedge_v, W.seam2d = room_on_pedge_v, seam2d
    return query_eq_2d_levers_impl(W, A, B, clearSet, cap, pin, mode, p1, p2, p3, p4, seedN, otherSg)
  end

  query_ring_dilate_levers = function(v, blk)
    W.DELTA, W.DIRORDER, W.adj, W.class_seam, W.coord, W.eqw_classes, W.eqw_field_shift, W.placed = DELTA, DIRORDER, adj, class_seam, coord, eqw_classes, eqw_field_shift, placed
    W.rigid_pendants, W.seam2d = rigid_pendants, seam2d
    return query_ring_dilate_levers_impl(W, v, blk)
  end
  -- count_defects does not count untruthful edges; this does. Shared by both compaction
  -- strategies below.
  local function eqw_lies()
    local n = 0
    for r in pairs(placed) do
      for d, x in each_exit(adj[r]) do
        local de = DELTA[d]
        if placed[x] and de and (de[1] ~= 0 or de[2] ~= 0) then
          local dx, dy = coord[x][1] - coord[r][1], coord[x][2] - coord[r][2]
          local ok
          if de[1] ~= 0 and de[2] ~= 0 then ok = (dx * de[1] > 0 and dy * de[2] > 0)
          elseif de[1] ~= 0 then ok = (dy == 0 and dx * de[1] >= 1)
          else ok = (dx == 0 and dy * de[2] >= 1) end
          if not ok then n = n + 1 end
        end
      end
    end
    return n
  end
  -- Is a crossing proved necessary in block B? Proved means the analysis placed a quartet or a
  -- chain site wholly inside the block; a pair straddling two blocks proves nothing about either.
  local function block_needs_cross(B)
    if B == nil then return false end
    local rb = (hints and hints.roomBlock) or {}
    -- the wire prover first: its quartet is a proof, a topo quartet only says one bridge must give
    local Wc = eqw_wire_cross()
    if Wc.n > 0 then
      for _, q in ipairs(Wc.quartet) do
        local all = true
        for i = 1, 4 do if rb[q[i]] ~= B then all = false ; break end end
        if all then return true, "wire" end
      end
    end
    local T = eqw_topo_cross()
    if T.n == 0 and T.nsite == 0 then return false end
    for _, q in ipairs(T.quartet or {}) do
      local all = true
      for i = 1, 4 do if rb[q[i]] ~= B then all = false ; break end end
      if all then return true, "quartet" end
    end
    for _, s in ipairs(T.siteList or {}) do
      if rb[s[1]] == B and rb[s[2]] == B then return true, "chain-site" end
    end
    return false
  end
  -- Crossing conversion: a room-on-edge about to be accepted inside a block proved to need a
  -- crossing is turned into a crossing with two ordinary levers. Overlaps and lies may not
  -- increase, room-on-edge must strictly drop. Returns true if it converted.
  local function cross_convert(v, inc, src)
    local R, wa, wb
    if inc then R, wa, wb = inc[1], inc[2], inc[3]
    else
      local ve = room_on_pedge_v(v)
      if ve then R, wa, wb = v, ve.u, ve.v
      else
        local w2, RR = edge_over_room_v(v)
        if RR then R, wa, wb = RR, v, w2 end
      end
    end
    if not R or not placed[R] or not placed[wa] or not placed[wb] then return false end
    -- gate: ask of every room in the incidence, since artery rooms have no roomBlock
    local rb = (hints and hints.roomBlock) or {}
    local ok, gwhy
    for _, r in ipairs({ R, wa, wb, v }) do
      if r and not ok then ok, gwhy = block_needs_cross(rb[r]) end
    end
    if not ok then
      elro._ccWhy = elro._ccWhy or {} ; elro._ccWhy["block-not-proved"] = (elro._ccWhy["block-not-proved"] or 0) + 1
      return false
    end
    elro._ccTry = (elro._ccTry or 0) + 1
    src = src or "walk"
    -- R travels perpendicular to the wire; a diagonal wire pins neither axis
    local A, Bp = coord[wa], coord[wb]
    local axes
    if A[2] == Bp[2] and A[1] ~= Bp[1] then axes = { 2 }
    elseif A[1] == Bp[1] and A[2] ~= Bp[2] then axes = { 1 }
    else axes = { 1, 2 } end
    local _, bOv, bRoe, bX = elro.count_defects(coord, placed, pedges)
    local beforeLie = eqw_lies()
    local snap = {} ; for r in pairs(placed) do snap[r] = coord[r] end
    local function shift(mv, axis, s)
      for r in pairs(mv) do
        local p = coord[r]
        coord[r] = (axis == 1) and { p[1] + s, p[2] } or { p[1], p[2] + s }
      end
      rebuild_occ()
    end
    local function restore()
      for r, p in pairs(snap) do coord[r] = p end ; rebuild_occ()
    end
    -- R's pinning neighbours on (axis, s): placed neighbours with zero slack in that direction.
    -- The wire's own endpoints are excluded (moving them is a plain separation).
    local function pinning(axis, s)
      local out = {}
      for d2, w in each_exit(adj[R]) do
        local de2 = DELTA[d2]
        if placed[w] and de2 and de2[axis] ~= 0 and w ~= wa and w ~= wb then
          local gap = coord[w][axis] - coord[R][axis]
          -- truthful now, squashed below length 1 the moment R steps by s
          if gap * de2[axis] >= 1 and (gap - s) * de2[axis] < 1 then out[#out + 1] = w end
        end
      end
      return out
    end
    local best
    for _, axis in ipairs(axes) do
      for _, s in ipairs({ -1, 1 }) do
        for _, w in ipairs(pinning(axis, s)) do
          -- pull 1 opens R's interval, anchored on R so the plate cannot carry R along
          local cls, mem = eqw_classes()
          local mv1, n1 = eqw_forced_shift(cls, mem, axis, w, s, R)
          if mv1 and not mv1[R] then
            shift(mv1, axis, s)
            -- pull 2 steps R into the freed cell, computed on the post-pull-1 geometry and
            -- anchored on w
            local cls2, mem2 = eqw_classes()
            local mv2, n2 = eqw_forced_shift(cls2, mem2, axis, R, s, w)
            if mv2 and not mv2[w] then
              shift(mv2, axis, s)
              local _, aOv, aRoe, aX = elro.count_defects(coord, placed, pedges)
              local aLie = eqw_lies()
              if aOv <= bOv and aRoe < bRoe and aLie <= beforeLie
                 and not room_on_pedge_v(R) then
                local cand = { w = w, axis = axis, s = s, mv1 = mv1, mv2 = mv2,
                               n = (n1 or 0) + (n2 or 0), ov = aOv, roe = aRoe, x = aX }
                -- lexicographic by severity, then plate size
                if not best
                   or cand.ov < best.ov
                   or (cand.ov == best.ov and cand.roe < best.roe)
                   or (cand.ov == best.ov and cand.roe == best.roe and cand.x < best.x)
                   or (cand.ov == best.ov and cand.roe == best.roe and cand.x == best.x
                       and cand.n < best.n) then
                  best = cand
                end
              end
            end
            restore()
          end
        end
      end
    end
    if not best then
      elro._ccWhy = elro._ccWhy or {} ; elro._ccWhy["no-pair"] = (elro._ccWhy["no-pair"] or 0) + 1
      return false
    end
    shift(best.mv1, best.axis, best.s)
    shift(best.mv2, best.axis, best.s)
    elro._ccN = (elro._ccN or 0) + 1
    elro._ccSrc = elro._ccSrc or {} ; elro._ccSrc[src] = (elro._ccSrc[src] or 0) + 1
    elro._walkPulls[#elro._walkPulls + 1] = { v = v, kind = "cross-convert-1",
      ek = "class:" .. best.axis .. ":" .. best.w .. ":" .. best.s,
      dx = (best.axis == 1) and best.s or 0, dy = (best.axis == 2) and best.s or 0,
      dist = 1, rooms = elro.tcount(best.mv1) }
    elro._walkPulls[#elro._walkPulls + 1] = { v = v, kind = "cross-convert-2",
      ek = "class:" .. best.axis .. ":" .. R .. ":" .. best.s,
      dx = (best.axis == 1) and best.s or 0, dy = (best.axis == 2) and best.s or 0,
      dist = 1, rooms = elro.tcount(best.mv2) }
    -- trace only: does the topology test name the crossing we bought?
    local named = {}
    for k in pairs(crossing_set(R)) do
      local p, q, r2, s2 = k:match("^(%d+):(%d+)|(%d+):(%d+)$")
      if p then
        local tok, twhy = topo_forced(tonumber(p), tonumber(q), tonumber(r2), tonumber(s2))
        named[#named + 1] = string.format("%s-%s x %s-%s (%s)", p, q, r2, s2, tok and "topo" or twhy)
      end
    end
    elro.tr(string.format("  CROSSING CONVERSION for %s: %s was on the %s-%s wire; shifted %s's"
      .. " class (axis %d %+d) then stepped %s into the freed cell -- room-on-edge %d -> %d,"
      .. " crossings %d -> %d [block proved by %s] %s",
      tostring(v), tostring(R), tostring(wa), tostring(wb), tostring(best.w), best.axis, best.s,
      tostring(R), bRoe, best.roe, bX, best.x, tostring(gwhy),
      #named > 0 and ("| " .. table.concat(named, ", ")) or ""))
    elro.step_snap(coord, string.format(
      "walk CROSSING CONVERSION for %s: %s off the %s-%s wire via %s (%dr) -- room-on-edge %d->%d,"
      .. " crossings %d->%d", tostring(v), tostring(R), tostring(wa), tostring(wb),
      tostring(best.w), best.n, bRoe, best.roe, bX, best.x), v, wa,
      { ek = "cross-convert", kind = "cross-convert", dist = 1, rooms = best.n,
        ckind = "room-on-edge", blocker = wa })
    return true
  end
  -- total L1 edge length, deduped per undirected edge; second return is the count of truthful
  -- diagonals that are off 45 (binary per edge, not the size of the bend)
  local function eqw_edge_cost()
    local n, skew, seen = 0, 0, {}
    for r in pairs(placed) do
      for d, x in each_exit(adj[r]) do
        local de = DELTA[d]
        if placed[x] and de and (de[1] ~= 0 or de[2] ~= 0) then
          local k = eid(r, x)
          if not seen[k] then
            seen[k] = true
            local dx, dy = coord[x][1] - coord[r][1], coord[x][2] - coord[r][2]
            n = n + math.abs(dx) + math.abs(dy)
            if de[1] ~= 0 and de[2] ~= 0 and dx * de[1] > 0 and dy * de[2] > 0
               and math.abs(dx) ~= math.abs(dy) then
              skew = skew + 1
            end
          end
        end
      end
    end
    return n, skew
  end
  -- Whole-map objective: L1 length plus TUNE.diagSkew cells per off-45 truthful diagonal.
  -- A weight is right here because both terms are cells; TUNE.diagSkewCap is the lever-side
  -- constant and a different quantity. Deliberately a weight, not a rigidity rule.
  local function eqw_score()
    local n, skew = eqw_edge_cost()
    return n + TUNE.diagSkew * skew, n, skew
  end
  -- Closure trace: one line per MOVE, folded by step_snap into the frame of the room being
  -- placed. `quiet` = only under elro.probeClose.
  local function ctrace(quiet, fmt, ...)
    if quiet and not elro.probeClose then return end
    local p = elro._closeTracePending or {} ; elro._closeTracePending = p
    local ln = string.format(fmt, ...)
    p[#p + 1] = ln
    if elro.closeEcho then print((ln:gsub("<[^>]->", ""))) end   -- strip cecho tags for a terminal
  end
  -- How tight must edge k stay: the room count of the smallest bounded face it borders (nil on
  -- the outer face only, which is free). Small faces have no tolerance for an extra cell; it is
  -- a min, not a sum, so a big face cannot hide a small one.
  function face_tight(k)                            -- forward-declared above eqw_forced_shift
    local T = elro.faceCost
    if not T or elro._faceCostSrc ~= elro.faceRings then
      T = {} ; elro.faceCost = T ; elro._faceCostSrc = elro.faceRings
      for _, g in ipairs(elro.faceRings or {}) do
        local n = #g
        for i = 1, n do
          local a, b = g[i], g[(i % n) + 1]
          local kk = ekey(a, b)
          if not T[kk] or n < T[kk] then T[kk] = n end
        end
      end
    end
    return T[k]
  end
  -- `sg` may be -inf ("nothing grows"); %d on an infinity is undefined in stock 5.1
  local function sgtxt(x)
    if x == -math.huge then return "none" end
    return string.format("%d", x or 0)
  end
  -- Ranks an option by the tightest bounded face any of its GROWING boundary edges borders
  -- (negated, so smaller is better; -inf when nothing grows). Second return: diagonals grown.
  -- `extra` is a room to treat as placed: eqw_make_room runs before placed[v] is set, and
  -- without it v's own attach edge would be invisible to the score. Counts, no weights.
  local function eqw_shared_grow(set, axis, sh, extra)
    local U = elro.faceUse
    local n, nd, seen, tightMin = 0, 0, {}, nil
    for r in pairs(set) do
      for d2, x in each_exit(adj[r]) do
        local de2 = DELTA[d2]
        if (placed[x] or x == extra) and not set[x] and de2 and (de2[1] ~= 0 or de2[2] ~= 0)
           and coord[x] then
          local k = ekey(r, x)
          if not seen[k] then
            seen[k] = true
            local dx, dy = coord[x][1] - coord[r][1], coord[x][2] - coord[r][2]
            local nx, ny = dx, dy
            if axis == 1 then nx = dx - sh else ny = dy - sh end
            local oldL = (math.abs(dx) > math.abs(dy)) and math.abs(dx) or math.abs(dy)
            local newL = (math.abs(nx) > math.abs(ny)) and math.abs(nx) or math.abs(ny)
            if newL > oldL then
              do
                local t = face_tight(k)
                if t and (not tightMin or t < tightMin) then tightMin = t end
              end
              if de2[1] ~= 0 and de2[2] ~= 0 then nd = nd + 1 end
            end
          end
        end
      end
    end
    -- nothing grows is the best outcome and must rank below every real score (-inf, never 0)
    n = tightMin and -tightMin or -math.huge
    return n, nd
  end
  -- Empty-lane elimination: delete a row/column with no room in it. Cannot lengthen an edge,
  -- reorder anything or create an overlap; diagonals spanning the lane change slope and a
  -- shortened edge can sweep a new cell, so the result is still gated.
  local function eqw_compact_lanes(tag, onlyAxis)
    local removed, before, beforeLie, snap = { 0, 0 }, nil, nil, nil
    local bOv, bRoe, bX = nil, nil, nil   -- severity breakdown, filled with `before`
    for axis = onlyAxis or 1, onlyAxis or 2 do
      local guard = 0
      while guard < 200 do
        guard = guard + 1
        local occupied, lo, hi = {}, nil, nil
        for r in pairs(placed) do
          local c = coord[r][axis] ; occupied[c] = true
          if lo == nil or c < lo then lo = c end
          if hi == nil or c > hi then hi = c end
        end
        local cut
        for c = (lo or 0) + 1, (hi or 0) - 1 do
          if not occupied[c] then
            -- every edge straddling the lane must survive losing one step
            local ok = true
            for r in pairs(placed) do
              if coord[r][axis] > c then
                for d, x in each_exit(adj[r]) do
                  local de = DELTA[d]
                  if placed[x] and de and (de[1] ~= 0 or de[2] ~= 0) and coord[x][axis] < c then
                    local gap = coord[r][axis] - coord[x][axis] - 1     -- after the shift
                    -- the edge minimum applies here too, or this pass undoes the walk's work
                    if gap < elro.min_len(r, x) then ok = false ; break end
                    if de[1] ~= 0 and de[2] ~= 0 then                   -- diagonal: keep its octant
                      local perp = math.abs(coord[r][3 - axis] - coord[x][3 - axis])
                      if perp == 0 or gap == 0 then ok = false ; break end
                      -- a square, truthful 45 may not be knocked off 45 (shear is neither a
                      -- defect nor a lie, so the gate below would not catch it). `gap` is already
                      -- post-shift, so perp == gap + 1 means square right now.
                      if perp == gap + 1
                         and de[axis] < 0
                         and (coord[x][3 - axis] - coord[r][3 - axis]) * de[3 - axis] > 0 then
                        elro._cnsVeto = (elro._cnsVeto or 0) + 1
                        ok = false ; break
                      end
                      local lng, sht = math.max(gap, perp), math.min(gap, perp)
                      if lng > 2.4142135 * sht then ok = false ; break end
                    end
                  end
                end
                if not ok then break end
              end
            end
            if ok then cut = c ; break end
          end
        end
        if not cut then break end
        if before == nil then
          before, bOv, bRoe, bX = elro.count_defects(coord, placed, pedges)
          beforeLie = eqw_lies()
          snap = {} ; for r in pairs(placed) do snap[r] = coord[r] end
        end
        for r in pairs(placed) do
          if coord[r][axis] > cut then
            local p = coord[r]
            coord[r] = (axis == 1) and { p[1] - 1, p[2] } or { p[1], p[2] - 1 }
          end
        end
        removed[axis] = removed[axis] + 1
      end
    end
    if removed[1] == 0 and removed[2] == 0 then
      elro.tr(string.format("  eqw_compact %s: no empty lane to reclaim", tostring(tag)))
      return
    end
    rebuild_occ()
    local after, aOv, aRoe, aX = elro.count_defects(coord, placed, pedges)
    local afterLie = eqw_lies()
    if elro.state_worse(after, aOv, aRoe, aX, before, bOv, bRoe, bX) or afterLie > beforeLie then
      for r, p in pairs(snap) do coord[r] = p end ; rebuild_occ()
      elro._eqcRev = (elro._eqcRev or 0) + 1
      elro.tr(string.format("  eqw_compact %s: REVERTED (defects %d -> %d, lies %d -> %d)",
        tostring(tag), before, after, beforeLie, afterLie))
      return false
    end
    elro.tr(string.format("  eqw_compact %s: removed %d empty column(s), %d empty row(s) (defects %d, lies %d)",
      tostring(tag), removed[1], removed[2], after, afterLie))
    elro.step_snap(coord, string.format("eqw compaction: -%d col, -%d row", removed[1], removed[2]))
    return true
  end
  local function eqw_compact(tag, onlyAxis)
    local t0 = CLK()
    local r = eqw_compact_lanes(tag, onlyAxis)
    local s = nil
    elro._eqcT = (elro._eqcT or 0) + (CLK() - t0) ; elro._eqcN = (elro._eqcN or 0) + 1
    return r or s
  end
  -- Is r defective (overlap, crossing, edge-on-room, room-on-edge)? Called in sweeps with the
  -- geometry frozen; xi/rc/cen are the sweep's det_sweep indices. Shared by eqw_close_core and
  -- eqw_make_room.
  local function defective(r, xi, rc, cen)
    return cell_overlap(r, cen) or first_crossing_v(r, xi) or edge_over_room_v(r, rc)
           or room_on_pedge_v(r, xi)
  end
  -- what r is stuck on, in severity order, and the room to move to free it (for a crossing,
  -- one endpoint of the crossed edge)
  local function defect_blocker(r)
    local X = cell_overlap(r) ; if X then return X, "overlap" end
    local _, ce = first_crossing_v(r) ; if ce then return ce.u, "cross" end
    local _, R = edge_over_room_v(r) ; if R then return R, "edge-on-room" end
    local ve = room_on_pedge_v(r) ; if ve then return ve.u, "room-on-edge" end
  end
  local function eqw_make_room(v, u, de)
    W.DELTA, W.adj, W.coord, W.ctrace, W.defect_blocker, W.defective, W.det_sweep, W.eqw_classes = DELTA, adj, coord, ctrace, defect_blocker, defective, det_sweep, eqw_classes
    W.eqw_forced_shift, W.eqw_score, W.eqw_shared_grow, W.pedges, W.placed, W.plate_label, W.query_eq_levers, W.rebuild_occ = eqw_forced_shift, eqw_score, eqw_shared_grow, pedges, placed, plate_label, query_eq_levers, rebuild_occ
    W.sgtxt = sgtxt
    return eqw_make_room_impl(W, v, u, de)
  end
  -- Loop-closure driver: make the back-edge v-w truthful by pulling w's side onto v's axis or
  -- v's side onto w's, with the closure equations naming which rooms travel. Cheaper valid side
  -- wins. Returns ok, movedSomething.
  local eqw_close_core_1
  local function eqw_close_core(v, w, del)
    -- the plate builder reads _inClose; saved/restored so nested closes keep the outer state
    local prev = elro._inClose ; elro._inClose = true
    local a, b, c = eqw_close_core_1(v, w, del)
    elro._inClose = prev
    return a, b, c
  end
  -- off-45 diagonals on the face rings touching a-b; what the squarify hook accepts on, since
  -- count_defects cannot see a shear
  local function ring_shear_at(a, b)
    local rings = elro.faceRings
    if not rings then return 0 end
    local sh, seenE = 0, {}
    for _, gg in ipairs(rings) do
      local hit = false
      for _, r in ipairs(gg) do if r == a or r == b then hit = true ; break end end
      if hit then
        local m = #gg
        for i = 1, m do
          local u, x = gg[i], gg[(i % m) + 1]
          local key = ekey(u, x)
          if not seenE[key] then
            seenE[key] = true
            local d
            for _, dd in ipairs(DIRORDER) do if adj[u] and adj[u][dd] == x then d = dd ; break end end
            local de = d and DELTA[d]
            local pu, px = coord[u], coord[x]
            if de and de[1] ~= 0 and de[2] ~= 0 and pu and px then
              local vx, vy = px[1] - pu[1], px[2] - pu[2]
              if vx * de[2] - vy * de[1] ~= 0 then sh = sh + 1 end
            end
          end
        end
      end
    end
    return sh
  end

  eqw_close_core_1 = function(v, w, del)
    W.AXIS_WORD, W.DELTA, W.adj, W.cand_shift, W.class_seam, W.class_shearfree_seeds, W.coord, W.cross_convert = AXIS_WORD, DELTA, adj, cand_shift, class_seam, class_shearfree_seeds, coord, cross_convert
    W.crossing_bounds, W.ctrace, W.defect_blocker, W.defective, W.det_sweep, W.diag_skew_n, W.eqw_classes, W.eqw_compact, W.eqw_field_shift = crossing_bounds, ctrace, defect_blocker, defective, det_sweep, diag_skew_n, eqw_classes, eqw_compact, eqw_field_shift
    W.eqw_forced_shift, W.eqw_score, W.eqw_shared_grow, W.eqw_topo_cross, W.eqw_wire_cross, W.on_edge_now, W.pedges, W.placed = eqw_forced_shift, eqw_score, eqw_shared_grow, eqw_topo_cross, eqw_wire_cross, on_edge_now, pedges, placed
    W.plate_label, W.query_cut_levers, W.query_ring_dilate_levers, W.rebuild_occ, W.ring_free_rider, W.ring_shear_at, W.roomedge_set, W.sgtxt = plate_label, query_cut_levers, query_ring_dilate_levers, rebuild_occ, ring_free_rider, ring_shear_at, roomedge_set, sgtxt
    return eqw_close_core_1_impl(W, v, w, del)
  end
  -- A successful close closes by stretching, so the reclaim hangs off the SUCCESS path.
  -- Tighten the WHOLE ring, not just the edge that closed it: the loop's slack is distributed
  -- around the ring. eqw_close_core is fully re-entrant (all state is call-local), so this is a
  -- plain re-invocation per ring edge over its minimum, worst first, geometry re-read each time.
  -- `ring_of` is declared below (shared with eqw_settle_ring); hence the forward local.
  local ring_of
  local tighten_ring_1
  local function tighten_ring(v, w)               -- closure-family: builds are minimal (see _inClose)
    local prev = elro._inClose ; elro._inClose = true
    local _t0 = elro.timeGuillo and CLK()
    local a, b, c = tighten_ring_1(v, w)
    if _t0 then elro._trT = (elro._trT or 0) + (CLK() - _t0)
      elro._trN = (elro._trN or 0) + 1 end
    elro._inClose = prev
    return a, b, c
  end
  tighten_ring_1 = function(v, w)
    W.DELTA, W.adj, W.class_seam, W.class_shearfree_seeds, W.coord, W.ctrace, W.defective, W.det_sweep = DELTA, adj, class_seam, class_shearfree_seeds, coord, ctrace, defective, det_sweep
    W.diag_skew_n, W.eqw_classes, W.eqw_close_core, W.eqw_forced_shift, W.placed, W.rebuild_occ, W.ring_of = diag_skew_n, eqw_classes, eqw_close_core, eqw_forced_shift, placed, rebuild_occ, ring_of
    return tighten_ring_1_impl(W, v, w)
  end
  local function eqw_close(v, w, del)
    local ok, worked = eqw_close_core(v, w, del)
    -- axis the closure stretched; a diagonal close can have worked on BOTH, so scope to neither
    local ax = (del[1] ~= 0 and del[2] ~= 0) and nil or ((del[1] ~= 0) and 2 or 1)
    -- the ring is only a ring once the edge that closes it is truthful
    if ok then tighten_ring(v, w) end
    if ok and worked and elro.eqwCompactLive then
      eqw_compact(string.format("post-close %d-%d", v, w), ax)
    end
    -- The redistribution does not hang off this function: place_room runs ONE spread once every
    -- back-edge of v is reconciled, rather than per closure.
    return ok
  end
  -- assigned to the forward local declared above tighten_ring (its other consumer); also
  -- exposed via elro._ring_of for the seed census, read-only.
  function ring_of(v, w)
    -- shortest placed path from w back to v NOT using the edge v-w == the loop v-w just closed
    local prev, seen, q, head = { [w] = false }, { [w] = true }, { w }, 1
    while head <= #q do
      local r = q[head] ; head = head + 1
      for d2, x in each_exit(adj[r]) do
        local de2 = DELTA[d2]
        if placed[x] and de2 and (de2[1] ~= 0 or de2[2] ~= 0) and not seen[x]
           and not (r == w and x == v) and not (r == v and x == w) then
          seen[x] = true ; prev[x] = r ; q[#q + 1] = x
          if x == v then
            local ring, cur = { v }, v
            while prev[cur] do cur = prev[cur] ; ring[#ring + 1] = cur end
            return ring                      -- v ... w, closed by the edge w-v
          end
        end
      end
    end
  end
  elro._ring_of = ring_of      -- read by the closure tighten (ring extremes)
  -- Class-shift levers: when v and its blocker sit on the same arm, shift the blocker's
  -- row/column class one step perpendicular so the edges bounding the segment absorb it.
  -- L1 over a closed cycle is invariant to which edge carries the slack, so a single-class
  -- pull inside a ring only moves slack; taking it out is the seam's job.
  function class_shearfree_seeds(mv, pa)           -- forward-declared far above; see there
    local cap = TUNE.classShearWalk
    local perp = 3 - pa
    -- Determinism: collect boundaries and SORT before walking -- pairs(mv) order depends on the
    -- per-process string hash seed. (The _sf* counters are still not reproducible across
    -- processes; they are a "did it fire" check only, layouts converge.)
    local bnd = {}
    for r in pairs(mv) do
      for d, x in each_exit(adj[r]) do
        local de = DELTA[d]
        -- a boundary edge (moved -> stationary) that is DIAGONAL and currently SQUARE: the shift
        -- tips it. Anything else is already off 45, axial, or not a boundary -- leave it alone.
        if de and placed[x] and not mv[x] and de[pa] ~= 0 and de[perp] ~= 0
           and math.abs(coord[x][pa] - coord[r][pa]) == math.abs(coord[x][perp] - coord[r][perp]) then
          bnd[#bnd + 1] = { r, x, de }
        end
      end
    end
    table.sort(bnd, function(A, B)
      if A[1] ~= B[1] then return A[1] < B[1] end
      return A[2] < B[2]
    end)
    -- Walk EVERY boundary diagonal and union the seeds (a plate may stop on several settled
    -- 45s). Union is in insertion order, deliberately: `bnd` is sorted, so it is deterministic.
    local allSeeds, seen1 = nil, {}
    do
      for _, e in ipairs(bnd) do
        local r, x = e[1], e[2]
        do
          -- _sfSeen/_sfHit/_sfMulti are "did it fire" counters only.
          elro._sfSeen = (elro._sfSeen or 0) + 1
          -- Bounded flood from the diagonal's far end (never back into the plate); each branch
          -- stops at the first edge axial along pa (it absorbs the step), seeding every room on
          -- the way. Neighbours visited in sorted room order for determinism.
          local seeds, n = {}, 0
          local visited, from = { [r] = true, [x] = true }, { [x] = r }
          local queue, qi, hit = { x }, 1, false
          while qi <= #queue and n < cap do
            local cur = queue[qi] ; qi = qi + 1
            local outs = {}
            for d2, y in each_exit(adj[cur]) do
              local de2 = DELTA[d2]
              if de2 and placed[y] and (de2[1] ~= 0 or de2[2] ~= 0) and not mv[y] and y ~= from[cur] then
                outs[#outs + 1] = { y, de2 }
              end
            end
            table.sort(outs, function(A, B) return A[1] < B[1] end)
            local absorbs = false
            for _, o in ipairs(outs) do
              local y, de2 = o[1], o[2]
              if de2[perp] == 0 and de2[pa] ~= 0 then absorbs = true ; break end
            end
            if absorbs then
              -- `cur` sits on an absorbing axial edge: cur and its path back to the diagonal
              -- are the seeds for this branch
              elro._sfHit = (elro._sfHit or 0) + 1
              hit = true
              local w = cur
              while w and w ~= r do
                if not seen1[w] then seen1[w] = true
                  allSeeds = allSeeds or {} ; allSeeds[#allSeeds + 1] = w end
                w = from[w]
              end
            else
              for _, o in ipairs(outs) do
                local y = o[1]
                if not visited[y] then
                  visited[y] = true ; from[y] = cur ; queue[#queue + 1] = y ; n = n + 1
                end
              end
            end
          end
        end
      end
    end
    if allSeeds and #allSeeds > 0 then
      elro._sfMulti = (elro._sfMulti or 0) + 1
      return allSeeds
    end
    return nil
  end
  -- The seam: a class shift cuts the map along a line and every boundary edge crossing the cut
  -- stretches. Score by min tightness over stretching edges, then re-offer with the boundary
  -- pushed past the binding edges. `deltas` = per-room displacement for graded plates.
  function class_seam(mv, pa, s, deltas, skip)     -- forward-declared far above; see there
    -- nAtMin = how many seam edges sit on the tightest face; a cut crossing one face twice grows
    -- it twice, so ties break on fewer edges at the minimum.
    local best, bind, nAtMin = math.huge, {}, 0
    -- grow = cells this cut injects, summed over the whole seam (min tightness is blind to it).
    local grow = 0
    -- Probe (`elro.probeSeam`): list the whole seam. Allocation gated, runs per plate per probe.
    local allE = elro.probeSeam and {} or nil
    for r in pairs(mv) do
      local sx, sy
      if deltas then
        local dr = deltas[r] ; sx, sy = dr and dr[1] or 0, dr and dr[2] or 0
      elseif pa == 1 then sx, sy = s, 0
      else sx, sy = 0, s end
      for d, x in each_exit(adj[r]) do
        local de = DELTA[d]
        if de and placed[x] and not mv[x] and coord[x] and (de[1] ~= 0 or de[2] ~= 0) then
          local dx, dy = coord[x][1] - coord[r][1], coord[x][2] - coord[r][2]
          local nx, ny = dx - sx, dy - sy
          if dx < 0 then dx = -dx end ; if dy < 0 then dy = -dy end
          if nx < 0 then nx = -nx end ; if ny < 0 then ny = -ny end
          local o = (dx > dy) and dx or dy
          local nn = (nx > ny) and nx or ny
          if nn > o then                          -- a STRETCHING boundary edge: part of the seam
            local t = face_tight(ekey(r, x)) or math.huge
            if allE then
              allE[#allE + 1] = string.format("%d:%d(%d->%d,t=%s)", r, x, o, nn,
                (t < math.huge) and tostring(t) or "free")
            end
            grow = grow + (nn - o)
            if not (skip and skip(x)) then
              if t < best then best, bind, nAtMin = t, { x }, 1
              elseif t == best and best < math.huge then
                bind[#bind + 1] = x ; nAtMin = nAtMin + 1
              end
            end
          end
        end
      end
    end
    if allE then
      table.sort(allE)
      local ms = {}
      for r in pairs(mv) do ms[#ms + 1] = r end
      table.sort(ms)
      allE.plate = table.concat(ms, " ")
    end
    if best == math.huge then return best, nil, 0, allE, grow end
    table.sort(bind)                              -- determinism: `pairs(mv)` is hash order
    return best, bind, nAtMin, allE, grow
  end
  -- Piston composition rule: for every candidate piston with far side F, the plate P must satisfy
  -- P intersect F in { empty, F }. Partial coverage tears the free body the piston would move
  -- whole. The test is only against the pistons candidate for THIS conflict (cascade-flagged ones
  -- count). Rather than veto, the caller re-runs the shift with F as `seeds`.
  -- Face-chunk snap: once a pre-solved face's ring AND interior are all placed by the ordinary
  -- walk, move the interior into its container in one chunk if it fits. Not a deferral -- the walk
  -- still places every room, so a failed gate simply leaves them as placed. Nothing is frozen.
  local chunkOf, chunkDone = nil, {}
  if elro._faceChunks then
    chunkOf = {}
    for i, C in ipairs(elro._faceChunks) do
      -- Index both ring and interior rooms: the interior is usually placed after the ring closes.
      for _, r in ipairs(C.ring) do
        local t = chunkOf[r] ; if not t then t = {} ; chunkOf[r] = t end
        t[#t + 1] = i
      end
      for r in pairs(C.rooms) do
        local t = chunkOf[r] ; if not t then t = {} ; chunkOf[r] = t end
        t[#t + 1] = i
      end
    end
  end
  local function try_chunk(v)
    W.DELTA, W.add_edges, W.adj, W.cell_overlap, W.chunkDone, W.chunkOf, W.coord, W.edge_over_room_v = DELTA, add_edges, adj, cell_overlap, chunkDone, chunkOf, coord, edge_over_room_v
    W.first_crossing_v, W.occ, W.pedges, W.placed, W.rebuild_occ, W.room_on_pedge_v, W.seenPE = first_crossing_v, occ, pedges, placed, rebuild_occ, room_on_pedge_v, seenPE
    return try_chunk_impl(W, v)
  end
  local function place_room(u, kid, root)
    W.DELTA, W.add_edges, W.adj, W.apply_pull, W.arteryRooms, W.branchOf, W.branchSet, W.cand_shift = DELTA, add_edges, adj, apply_pull, arteryRooms, branchOf, branchSet, cand_shift
    W.eq_ek, W.eqw_classes, W.eqw_forced_shift = eq_ek, eqw_classes, eqw_forced_shift
    W.cell_overlap, W.coord, W.cross_convert, W.crossing_set, W.crossings_moved, W.ctrace, W.edge_over_room_v = cell_overlap, coord, cross_convert, crossing_set, crossings_moved, ctrace, edge_over_room_v
    W.eqwReconciled, W.eqw_close, W.eqw_make_room, W.eqw_topo_cross, W.eqw_wire_cross, W.first_crossing_v, W.forced_cross, W.gridx_only = eqwReconciled, eqw_close, eqw_make_room, eqw_topo_cross, eqw_wire_cross, first_crossing_v, forced_cross, gridx_only
    W.junction_score, W.leftover, W.mark, W.parentOf, W.placed, W.pull_makes_crossing = junction_score, leftover, mark, parentOf, placed, pull_makes_crossing
    W.pull_makes_lie, W.pull_makes_overlap, W.pull_makes_roomedge, W.query_cut_levers, W.query_eq_2d_levers, W.query_eq_levers, W.query_ring_dilate_levers, W.rebuild_occ = pull_makes_lie, pull_makes_overlap, pull_makes_roomedge, query_cut_levers, query_eq_2d_levers, query_eq_levers, query_ring_dilate_levers, rebuild_occ
    W.repair_after, W.repair_run, W.revert_pull, W.room_on_pedge_v, W.roomedge_set, W.sheared_gridx, W.topo_forced, W.try_chunk = repair_after, repair_run, revert_pull, room_on_pedge_v, roomedge_set, sheared_gridx, topo_forced, try_chunk
    return place_room_impl(W, u, kid, root)
  end
  -- a frozen block unit GATES artery if it sits between placed skeleton and still-unplaced
  -- artery (an artery arc continues on its far side). Such a block must be placed AS PART
  -- of the skeleton (as a whole unit) so the artery beyond it can be laid before pendants.
  local function unit_gates_artery(ui, accept)
    for r in pairs(units[ui].rooms) do
      for d, v in each_exit(adj[r]) do
        local de = DELTA[d]
        if de and (de[1] ~= 0 or de[2] ~= 0) and not units[ui].rooms[v]
           and outwardSet[v] and arteryRooms[v] and not placed[v]
           and (not accept or accept(v)) then return true end
      end
    end
    return false
  end
  -- PASS 1 -- SKELETON: lay the artery spine first, no pendant kids yet. lay_skeleton floods
  -- all artery reachable without a block, inserts one gating block, re-floods, repeats.
  local function place_skeleton(u, accept)         -- artery-only DFS flood (no block insertion)
    runaway(u)
    for _, kid in ipairs(gather_kids(u)) do
      if kid.isArtery and not placed[kid.v] and (not accept or accept(kid.v)) then
        place_room(u, kid, nil)   -- artery skeleton carries no subcomponent tag
        place_skeleton(kid.v, accept)
      end
    end
  end
  -- the next artery-gating block to insert, scanned DETERMINISTICALLY (earliest-placed anchor
  -- first, then gather order) so block-insertion order -- and thus the layout -- is stable.
  local function next_gating_block(accept)
    local placedList = {}
    for r in pairs(placed) do placedList[#placedList + 1] = r end
    table.sort(placedList, function(a, b)
      local oa, ob = elro._walkOrder[a] or 0, elro._walkOrder[b] or 0
      if oa ~= ob then return oa < ob end
      return tostring(a) < tostring(b)
    end)
    for _, u in ipairs(placedList) do
      for _, kid in ipairs(gather_kids(u)) do
        if kid.unit and not unitDone[kid.unit] and unit_gates_artery(kid.unit, accept) then return u, kid end
      end
    end
    return nil
  end
  -- every placed room, earliest-walked first, so every flood/scan below is deterministic.
  local function placed_in_order()
    local list = {}
    for r in pairs(placed) do list[#list + 1] = r end
    table.sort(list, function(a, b)
      local oa, ob = elro._walkOrder[a] or 0, elro._walkOrder[b] or 0
      if oa ~= ob then return oa < ob end
      return tostring(a) < tostring(b)
    end)
    return list
  end
  -- ===== eqw SKELETON ORDERING ===========================================================
  -- eqw has no rigid block units, so one block (eqwBlock = hints.roomBlock, room -> block
  -- index) is walked to completion, then the block-free artery it opened is flooded, then the
  -- next block. Keeps the closure equations from reconciling loops against moving geometry.
  local eqwBlock = (hints and hints.roomBlock) or {}
  local function eqw_flood(filter)
    for _, r in ipairs(placed_in_order()) do place_skeleton(r, filter) end
  end
  -- the next block with a FOOTHOLD: some placed room has an unplaced artery kid in it. Scanned
  -- earliest-placed-anchor first so block order (and thus the layout) is stable across relayouts.
  local function next_eqw_block(done, accept)
    for _, u in ipairs(placed_in_order()) do
      for _, kid in ipairs(gather_kids(u)) do
        local B = eqwBlock[kid.v]
        if B and not done[B] and not placed[kid.v] and kid.isArtery
           and (not accept or accept(kid.v)) then return B end
      end
    end
    return nil
  end
  -- FACE-ONION ORDER inside one block: trace faces, take the outer one by rotation
  -- (combinatorial, no coordinates), BFS the dual graph away from it, and release rooms in
  -- cumulative waves so the outer ring settles before anything it encloses exists.
  -- Returns nil when there is nothing to order; the caller's plain flood then stands.
  local function eqw_face_waves(B)
    local set, n = {}, 0
    for r, b in pairs(eqwBlock) do if b == B then set[r] = true ; n = n + 1 end end
    if n < 4 then return nil end
    -- density gate: laying the perimeter of a dense 8-directional mesh first boxes the
    -- interior in. Same signal solve_block_ns guards on (nsEdgeRatio).
    local dens, nv, ne = elro.block_density(adj, set)
    if elro.probeChunkFace then
      cecho(string.format("\n[cff] block %d entry: %d rooms, %d edges, %.2fx/room (gate %.2f)\n",
        B, nv, ne, dens, TUNE.nsEdgeRatio))
    end
    -- A block carrying a big pre-solved interior (>= chunkFaceMin rooms) is seeded on that
    -- chunk's face instead of the outer face, and skips the density gate -- but only when a
    -- traced face actually MATCHES the chunk ring (facefit traces over the whole component,
    -- this over one block, and they can disagree). A dense block with no match keeps the gate.
    local chunkFaces = {}
    if elro._faceChunks then
      for i = 1, #elro._faceChunks do
        local C = elro._faceChunks[i]
        if C.ring and elro.tcount(C.rooms or {}) >= TUNE.chunkFaceMin then
          local all = true
          for _, r in ipairs(C.ring) do if not set[r] then all = false ; break end end
          if all then chunkFaces[#chunkFaces + 1] = C end
        end
      end
    end
    local function fkey(list)
      local t = {} ; for _, r in ipairs(list) do t[#t + 1] = r end
      table.sort(t) ; return table.concat(t, ",")
    end
    local faces, outer, seedIdx
    if #chunkFaces > 0 then
      faces = elro.faces(set, adj)
      local _, out0 = elro.pick_outer_face(faces, adj)
      local want = {}
      for _, C in ipairs(chunkFaces) do want[fkey(C.ring)] = true end
      if elro.probeChunkFace then
        local ks = {} ; for k in pairs(want) do ks[#ks + 1] = k end
        cecho(string.format("\n[cff] block %d: %d face(s), outer=%s; chunk ring(s): %s\n",
          B, #faces, tostring(out0), table.concat(ks, " | ")))
        for i, f in ipairs(faces) do cecho(string.format("[cff]   face %d: %s\n", i, fkey(f))) end
      end
      for i, f in ipairs(faces) do
        if i ~= out0 and want[fkey(f)] then seedIdx = i ; break end
      end
      if not seedIdx then elro._cffMiss = (elro._cffMiss or 0) + 1 end
      outer = out0
    end
    if not seedIdx and dens > TUNE.nsEdgeRatio then
      elro.tr(string.format("eqw skeleton: block %d dense (%d rooms, %d edges, %.1fx/room)"
              .. " -- no face order", B, nv, ne, dens))
      return nil
    end
    if not faces then
      faces = elro.faces(set, adj)
      local _, o = elro.pick_outer_face(faces, adj) ; outer = o
    end
    if not outer then return nil end
    -- the waves grow outward from the chunk face (most-constrained first); this only reorders
    if seedIdx then
      elro.tr(string.format("eqw skeleton: block %d seeded on CHUNK FACE %d (%d rooms)"
        .. " instead of the outer face", B, seedIdx, #faces[seedIdx]))
      elro._cffN = (elro._cffN or 0) + 1
      outer = seedIdx
    end
    local function fedges(f)
      local t, m = {}, #f
      for i = 1, m do
        local a, b = f[i], f[(i % m) + 1]
        t[#t + 1] = ekey(a, b)
      end
      return t
    end
    local byEdge = {}
    for i, f in ipairs(faces) do
      for _, e in ipairs(fedges(f)) do
        byEdge[e] = byEdge[e] or {}
        byEdge[e][#byEdge[e] + 1] = i
      end
    end
    local dist, q, qh, maxd = { [outer] = 0 }, { outer }, 1, 0
    while qh <= #q do
      local fi = q[qh] ; qh = qh + 1
      for _, e in ipairs(fedges(faces[fi])) do
        for _, fj in ipairs(byEdge[e] or {}) do
          if not dist[fj] then
            dist[fj] = dist[fi] + 1 ; q[#q + 1] = fj
            if dist[fj] > maxd then maxd = dist[fj] end
          end
        end
      end
    end
    local waves, cum = {}, {}
    for d = 0, maxd do
      local grew = false
      for fi, dd in pairs(dist) do
        if dd == d then
          for _, r in ipairs(faces[fi]) do
            if set[r] and not cum[r] then cum[r] = true ; grew = true end
          end
        end
      end
      if grew then
        local w = {} ; for r in pairs(cum) do w[r] = true end
        waves[#waves + 1] = w
      end
    end
    if #waves < 2 then return nil end
    return waves
  end
  -- CROSSING FIRST: the crossing a map needs is computable from the exits alone
  -- (eqw_topo_cross), so its rooms are released as wave 0 of their block. eqw_flood only
  -- reaches rooms adjacent to placed ones, so the shortest paths from the block's frontier to
  -- each target are released too.
  local function eqw_cross_wave(B, accept)
    local T = eqw_topo_cross()
    if #T.quartet == 0 and #T.siteList == 0 then return nil end
    local target, nt = {}, 0
    -- a chain site names ONE edge; both its rooms are targets just like a quartet's four
    for _, s in ipairs(T.siteList) do
      if eqwBlock[s[1]] == B and eqwBlock[s[2]] == B then
        for _, r in ipairs(s) do if not target[r] then target[r] = true ; nt = nt + 1 end end
      end
    end
    for _, q in ipairs(T.quartet) do
      local all = true
      for _, r in ipairs(q) do if eqwBlock[r] ~= B then all = false ; break end end
      -- only a quartet wholly inside this block: a pair straddling two blocks has no single
      -- placement moment, and forcing one would drag the other block's rooms in early
      if all then
        for _, r in ipairs(q) do if not target[r] then target[r] = true ; nt = nt + 1 end end
      end
    end
    if nt == 0 then return nil end
    -- BFS inside B from every unplaced block room that already touches placed geometry
    local par, q2, qh = {}, {}, 1
    for _, r in ipairs(placed_in_order()) do
      for _, kid in ipairs(gather_kids(r)) do
        if eqwBlock[kid.v] == B and not placed[kid.v] and not par[kid.v] then
          par[kid.v] = kid.v ; q2[#q2 + 1] = kid.v          -- own root
        end
      end
    end
    while qh <= #q2 do
      local x = q2[qh] ; qh = qh + 1
      for _, y in each_exit(adj[x]) do
        if eqwBlock[y] == B and not placed[y] and not par[y] then par[y] = x ; q2[#q2 + 1] = y end
      end
    end
    local wave, n = {}, 0
    for r in pairs(target) do
      if par[r] then                                        -- reachable this block-step
        local x = r
        while x and not wave[x] do
          wave[x] = true ; n = n + 1
          if par[x] == x then break end
          x = par[x]
        end
      end
    end
    if n == 0 then return nil end
    return wave, n, nt
  end
  local function lay_skeleton_eqw(accept)
    local done, guard = {}, 0
    local function free(v) return (not eqwBlock[v]) and (not accept or accept(v)) end
    -- the crossing is built on demand (cross_convert); wave 0 below only drives to it first
    while guard < 100000 do
      guard = guard + 1
      -- a block we are standing in wins over the road leaving it: finish the loops first.
      local B = next_eqw_block(done, accept)
      if B then
        done[B] = true
        -- wave 0 (crossing), then face waves outermost first, then the unrestricted flood
        local cw, ncw, nt = eqw_cross_wave(B, accept)
        if cw then
          eqw_flood(function(v) return eqwBlock[v] == B and cw[v] and (not accept or accept(v)) end)
          elro.tr(string.format("eqw skeleton: block %d CROSSING FIRST -- %d room(s) released"
            .. " (%d of them the crossing's own)", B, ncw, nt))
          elro.step_snap(coord, string.format(
            "eqw skeleton: block %d crossing placed first (%d rooms)", B, ncw))
        end
        -- one tick per wave: each eqw_flood sorts every placed room
        for wi, w in ipairs(eqw_face_waves(B) or {}) do
          elro.bg_tick("eqw-wave")
          eqw_flood(function(v) return eqwBlock[v] == B and w[v] and (not accept or accept(v)) end)
          elro.tr(string.format("eqw skeleton: block %d face-wave %d (%d rooms released)",
                  B, wi, elro.tcount(w)))
        end
        eqw_flood(function(v) return eqwBlock[v] == B and (not accept or accept(v)) end)
        elro.step_snap(coord, string.format("eqw skeleton: block %d complete", B))
      else
        local before = elro.tcount(placed)
        eqw_flood(free)                          -- no reachable block: extend along free artery
        if elro.tcount(placed) == before then break end
      end
    end
  end
  -- flood all block-free artery reachable from every placed room, then one gating block at a
  -- time (re-flooding after each). Deterministic seed order. Used by PASS 1 and PASS 1.5.
  local function lay_skeleton(accept)
    if eqwBlock then return lay_skeleton_eqw(accept) end
    for _, r in ipairs(placed_in_order()) do place_skeleton(r, accept) end   -- flood all currently-reachable artery
    local guard = 0
    while guard < 100000 do
      guard = guard + 1
      local u, kid = next_gating_block(accept)
      if not u then break end
      insert_unit(kid.unit, u, kid.d, kid.v)                -- ONE block
      for r in pairs(units[kid.unit].rooms) do place_skeleton(r, accept) end   -- flood artery beyond it
    end
  end
  local function run_skeleton()
    lay_skeleton()                                         -- old recursive DFS (unchanged order)
  end
  -- PASS 2 -- KIDS: walk back along the (now fully placed) artery and, at each artery node,
  -- place ALL its non-artery kids + block units (each fully descended) before stepping to the
  -- next artery node. `seen` guards re-entry so the spine walk never doubles back.
  local seen = {}
  -- root = the subcomponent tag flowing down this pendant subtree. nil while on the artery
  -- spine; set to the top-level pendant kid the first time we leave the artery, then inherited
  -- by everything deeper so a whole branch shares one tag (see branchOf).
  local function place_pendants(u, root)
    if seen[u] then return end
    seen[u] = true
    runaway(u)
    local kids = gather_kids(u)
    -- non-artery kids (+ units): fully place each pendant subtree off u
    for _, kid in ipairs(kids) do
      if not kid.isArtery then
        local kroot = root or kid.v   -- top-level pendant establishes the tag; deeper inherit
        if kid.unit then
          if not unitDone[kid.unit] then
            insert_unit(kid.unit, u, kid.d, kid.v)
            for r in pairs(units[kid.unit].rooms) do branchOf[r] = kroot end
          end
          -- walk the unit's tails whether we just inserted it OR PASS 1 did (a PASS-1
          -- gating insertion sets unitDone, so without this its far-side pendants drop).
          for r in pairs(units[kid.unit].rooms) do place_pendants(r, kroot) end
        else
          -- place if new, but always recurse: PASS 1.5 may have placed a non-artery connector
          if not placed[kid.v] then place_room(u, kid, kroot) end
          place_pendants(kid.v, kroot)
        end
      end
    end
    -- continue along the artery spine (already placed in pass 1). Fallback: if an artery room
    -- was somehow not reached by pass 1 (disconnected artery), place it now so it isn't dropped.
    for _, kid in ipairs(kids) do
      if kid.isArtery then
        if not placed[kid.v] then place_room(u, kid, nil) end
        place_pendants(kid.v, nil)
      end
    end
  end
  -- PASS 1.5 -- REACH ARTERY ISLANDS: artery walled off from the skeleton by pendant tails or
  -- units. BFS from the placed set to the nearest unplaced artery room, place the connecting
  -- chain, walk the island, repeat.
  local function connect_artery_islands()
    local guard = 0
    while guard < 300 do
      guard = guard + 1
      local par, q, qh, target = {}, {}, 1, nil
      local function push(u)
        for d, v in each_exit(adj[u]) do
          local de = DELTA[d]
          if de and (de[1] ~= 0 or de[2] ~= 0) and not placed[v] and par[v] == nil
             and (outwardSet[v] or unitByRoom[v]) then
            par[v] = { u = u, d = d } ; q[#q + 1] = v
          end
        end
      end
      for r in pairs(placed) do push(r) end
      while qh <= #q do
        local u = q[qh] ; qh = qh + 1
        if outwardSet[u] and arteryRooms[u] then target = u ; break end
        push(u)
      end
      if not target then break end
      -- reconstruct the chain (placed anchor -> target) and place it anchor-outward
      local chain, cur = {}, target
      while cur ~= nil and not placed[cur] do chain[#chain + 1] = cur ; local p = par[cur] ; cur = p and p.u or nil end
      for i = #chain, 1, -1 do
        local room = chain[i]
        if not placed[room] then
          local p = par[room]
          if unitByRoom[room] and not unitDone[unitByRoom[room]] then
            insert_unit(unitByRoom[room], p.u, p.d, room)   -- whole block, never partial
          else
            place_room(p.u, { v = room, d = p.d }, nil)
          end
        end
      end
      run_skeleton()   -- lay the now-connected island's artery (block-free first, then blocks)
    end
  end
  -- PASS 0 -- INWARD: inward pendant trees and blocks off the settled core, before the outward
  -- skeleton, so a face-expanding shift moves a still-empty exterior.
  local inwardSeen = {}
  local function walk_inward(u, root)   -- root = the top-level inward branch tag (see place_pendants)
    if inwardSeen[u] then return end
    inwardSeen[u] = true
    runaway(u)
    for _, kid in ipairs(gather_kids(u)) do
      local isIn = (kid.unit and unitInward[kid.unit]) or (not kid.unit and inwardSet[kid.v])
      if isIn then
        local kroot = root or kid.v   -- top-level establishes the tag; deeper inherit
        if kid.unit then
          if not unitDone[kid.unit] then
            insert_unit(kid.unit, u, kid.d, kid.v)
            for r in pairs(units[kid.unit].rooms) do branchOf[r] = kroot end
          end
          for r in pairs(units[kid.unit].rooms) do walk_inward(r, kroot) end
        else
          if not placed[kid.v] then place_room(u, kid, kroot) end
          walk_inward(kid.v, kroot)
        end
      end
    end
  end
  local seeds = {}   -- snapshot the settled core before placement mutates coord
  for r in pairs(coord) do if placed[r] then seeds[#seeds + 1] = r end end
  if elro.timeGuillo then
    -- jump split: since the previous component's last placement, and the setup part of it.
    -- `_wbEnter` is stamped at the caller-visible entry, not by a bracket inside this function.
    local now = CLK()
    local sincePlace = (now - (elro._prLast or now)) * 1000
    local setup = (now - (elro._wbEnter or now)) * 1000
    elro._jumpT = (elro._jumpT or 0) + sincePlace
    elro._jumpSetupT = (elro._jumpSetupT or 0) + setup
    elro._jumpN = (elro._jumpN or 0) + 1
  end
  elro.step_snap(coord, "walk start: core settled (" .. #seeds .. " rooms), " ..
    elro.tcount(outwardSet) .. " outward to walk")
  elro.tr("  walk_branches: ENTER seeds=" .. #seeds .. " outward=" .. elro.tcount(outwardSet) .. " units=" .. #(units or {}))
  -- Counters are per CANVAS: `_tgOpen` arms them on the first walk, elro.tg_report prints and
  -- disarms. Every counter must appear in this reset list, or it reports a session total.
  if elro.timeGuillo and not elro._tgOpen then elro._tgOpen = true ; elro._qblT, elro._qblN, elro._qblReduceT = 0, 0, 0 ; elro._grLocal, elro._grGlobal = 0, 0 ; elro._detT, elro._detN = 0, 0
    elro._qenT, elro._qenN, elro._gFullDup = 0, 0, 0
    elro._eqgT, elro._eqgN, elro._eqgOut, elro._eqgVoid, elro._eqgTry = 0, 0, 0, 0, 0
    elro._eqgClT, elro._eqgClN = 0, 0
    elro._eqgPostVoid, elro._eqgNonMono = 0, 0
    elro._eqPP, elro._eqPPnote = 0, 0                          -- the ping-pong guard
    elro._cutT, elro._cutN, elro._cutBuilt, elro._cutFanBuilt = 0, 0, 0, 0   -- query_cut_levers
    elro._cutBail, elro._cutVoid, elro._cutRej = {}, {}, {}
    elro._eqgMemo, elro._eqgDup, elro._eqgDupT = {}, 0, 0
    elro._eqgMagP, elro._eqgMagE = {}, {}
    elro._eqDeepN = 0
    elro._eqgWhy = {}
    elro._fsT, elro._fsN, elro._fsIter, elro._fsOccN = 0, 0, 0, 0
    elro._fsDragT, elro._fsOccT, elro._fsAncT, elro._fsCompT, elro._fsSepT = 0, 0, 0, 0, 0
    elro._fsReT, elro._fsRoomEdge, elro._fsReIdxT, elro._fsEbkT, elro._fsEbkN = 0, 0, 0, 0, 0
    elro._fsReDecline = 0
    elro._eqcT, elro._eqcN, elro._eqcRev = 0, 0, 0
    elro._ecT, elro._ecN = 0, nil                                          -- eqw_classes
    elro._rgCensus = nil
    elro._eqUnvDup, elro._eqUnvWin, elro._eqUnvOver, elro._eqUnvAlone = 0, 0, 0, 0
    elro._eqUnvDupList, elro._eqUnvOverList = {}, {}                       -- the `:u` census
    elro._ekRank, elro._ekTop, elro._ekTopList, elro._ekClass, elro._ekOther = 0, 0, {}, nil, nil   -- the label-tie census
    elro._cnrLazy, elro._cnrLazyHit = 0, 0                                 -- lazy corner generation
    elro._dsN, elro._detWho = 0, nil                                       -- eqw_close's frozen-geometry index
    elro._mrIter, elro._mrStall = 0, 0                                     -- make_room's repair loop
    elro._fsWho, elro._fsWhoT = nil, nil                                   -- forced_shift by caller
    elro._sntInert = 0
    elro._ctHop, elro._ctWalks, elro._ctSeam, elro._ctEmit, elro._ctTry = nil, 0, 0, 0, 0 ; elro._ctSeq = nil
    elro._wkT = nil
    elro._gsSplit, elro._rdSplitT, elro._rdBig = nil, nil, 0
    elro._ffPh, elro._ffTime, elro._ffCalls = nil, 0, 0
    elro._ffSize = nil
    elro._ffKey, elro._ffKeyHit, elro._ffKeyMiss = nil, 0, 0
    elro._ffKey0, elro._ffKey0Hit, elro._ffKey0Miss = nil, 0, 0
    elro._ffLast, elro._ffLastHit, elro._ffLastMiss = nil, 0, 0
    elro._ffP1Hit, elro._ffP1Miss = 0, 0
    elro._rpT, elro._rpN, elro._rpFix, elro._rpBFT, elro._rpBFN = 0, 0, 0, 0, 0
    elro._rpPh = nil
    elro._rpJob, elro._rpNoop = 0, 0
    elro._rpClN, elro._rpClFix = 0, 0
    elro._clAttT, elro._clAttN, elro._clPhN, elro._clPhHint = 0, 0, 0, 0
    elro._trT, elro._trN, elro._trTry = 0, 0, 0
    elro._eqcRingPong, elro._eqcRingCells = 0, 0
    elro._dsT, elro._dsN = 0, 0
    elro._clPh = nil
    elro._ctSfSkip, elro._ctSubset = 0, 0
    elro._repT, elro._repN, elro._strT, elro._strN = 0, 0, 0, 0
    elro._jsT, elro._jsN = 0, 0 ; elro._cdT, elro._cdN = 0, 0
    elro._genT, elro._genN, elro._gudT, elro._gudN = 0, 0, 0, 0
    elro._regenT, elro._regenN = 0, 0                    -- the escalation's generator re-run
    elro._dspT, elro._dspN, elro._mrT, elro._mrN = 0, 0, 0, 0
    elro._mrsT, elro._mrsN, elro._mrSeedAdd, elro._mrSeedWin = 0, 0, 0, 0
    elro._mrCascN, elro._mrCascCarry = 0, 0
    elro._optGen, elro._optEval, elro._optSteps = 0, 0, 0
    elro._optWhy, elro._optKind, elro._optDiag, elro._optSuf, elro._optWalkRank = nil, nil, nil, nil, nil
    elro._optSize = nil
    elro._optWalkSc = nil
    elro._optWalkSB = nil
    elro._wlWalk, elro._wlHeld, elro._wlT = 0, 0, 0
    elro._eqWalkEsc = 0
    elro._reLazyEsc, elro._reLazyJoin = 0, 0
    elro._eq2dBy, elro._eq2dT, elro._eq2dN, elro._eq2dOut, elro._eq2dTry = nil, 0, 0, 0, 0
    elro._e2mag = nil
    elro._clT, elro._clN, elro._rcT, elro._rcN = 0, 0, 0, 0
    elro._sedT, elro._sedN = 0, 0
    elro._diagEqN, elro._diagSkew, elro._diagC1, elro._diagC2 = 0, 0, 0, 0
    elro._diagSepT, elro._diagSepW = 0, 0
    elro._diagEqVoid = {}
    elro._lcSetT, elro._lcSetN, elro._lcFarT, elro._lcFarN, elro._lcEvT, elro._lcEvN = 0, 0, 0, 0, 0, 0
    elro._lcPtHit, elro._lcOwnHit = 0, 0
    -- per-detector split of _detT and the guard-phase split of _gudT
    elro._detOvT, elro._detOvN, elro._detCrT, elro._detCrN = 0, 0, 0, 0
    elro._detEorT, elro._detEorN, elro._detRpeT, elro._detRpeN = 0, 0, 0, 0
    elro._csT, elro._csN, elro._rsT, elro._rsN, elro._cmT, elro._cmN, elro._rmT, elro._rmN = 0, 0, 0, 0, 0, 0, 0, 0
    elro._preT = 0                                       -- cs + rs, for the per-step `(prescan)` bucket
    elro._pmcT, elro._pmcN, elro._pmrT, elro._pmrN, elro._pmoT, elro._pmoN = 0, 0, 0, 0, 0, 0
    elro._gudBy, elro._gudWho = nil, nil
    elro._noopT, elro._noopN, elro._cmBT, elro._rmBT = 0, 0, 0, 0
    elro._evCoT, elro._evOvT, elro._evEdT = 0, 0, 0
    elro._evDN, elro._evCN, elro._evSetN, elro._evEdgN = 0, 0, 0, 0
    elro._evRasN, elro._evEorC, elro._evEorS = 0, 0, 0
    elro._evFO, elro._evFE, elro._evOut = 0, 0, {}
    elro._evLag, elro._evLagMax, elro._evWaste = {}, 0, 0
    elro._prT, elro._prN, elro._prCf = 0, 0, 0
    elro._brN, elro._brPart, elro._brSplit, elro._brMissMax, elro._brOverlap = 0, 0, 0, 0, 0
    elro._brOne = 0
    elro._gapT, elro._gapN, elro._gapTop = {}, {}, {}
    elro._jumpT, elro._jumpSetupT, elro._jumpN = 0, 0, 0
    -- `_prLast` survives between walk_branches calls (the between-component jump) but must be
    -- cleared per canvas, or the first placement is charged the idle time since the last run.
    elro._prLast, elro._prLastRoom, elro._prLastPhase = nil, nil, nil
    end
  elro._eqsT, elro._eqsN, elro._eqsRev, elro._eqFlushN, elro._eqsMovedN, elro._eqsPre = 0, 0, 0, 0, 0, 0
  elro._eqcOrder2, elro._eqcUnstuck = 0, 0
  elro._lsFallback, elro._lsFbKind, elro._lsX, elro._lsAvoided = 0, {}, {}, 0
  elro._ccN, elro._ccTry, elro._ccWhy, elro._ccSrc = 0, 0, {}, {}
  elro._fcProved, elro._fcWhy = 0, {}
  elro._tcProved, elro._tcGenus, elro._tcPairs, elro._tcFaces, elro._tcList, elro._tcRan = 0, 0, 0, 0, {}, false
  elro._wcProved, elro._wcList, elro._wcRan = 0, {}, false
  elro._woN, elro._woEq, elro._woLie, elro._woBad = 0, 0, 0, 0
  elro._lcaWhy, elro._lcaOk = {}, 0
  -- gap accumulators; the "last placement" stamps must survive across walk_branches calls
  elro._gapT = elro._gapT or {} ; elro._gapN = elro._gapN or {} ; elro._gapTop = elro._gapTop or {}
  elro._wbPhase = "walk-setup"
  if next(inwardSet) then
    elro._wbPhase = "pass0-inward"
    for _, r in ipairs(seeds) do walk_inward(r) end   -- PASS 0: inward pendants first (empty exterior)
    elro.step_snap(coord, "PASS 0 inward placed, now outward skeleton")
    elro.tr("  walk_branches: PASS0 inward done (_walkN=" .. tostring(elro._walkN) .. ")")
  end
  elro._wbPhase = "pass1-skeleton"
  run_skeleton()                                       -- PASS 1: artery skeleton (block-free first, then one block at a time)
  elro.tr("  walk_branches: PASS1 skeleton done (_walkN=" .. tostring(elro._walkN) .. ")")
  elro._wbPhase = "pass1.5-islands"
  connect_artery_islands()                             -- PASS 1.5: reach walled-off artery
  elro.tr("  walk_branches: PASS1.5 islands done (_walkN=" .. tostring(elro._walkN) .. ")")
  if elro.debug then   -- why did PASS 1 stop? report unplaced artery + neighbour status
    local un = {}
    for r in pairs(outwardSet) do if arteryRooms[r] and not placed[r] then un[#un + 1] = r end end
    cecho(string.format("\n<magenta>[walk] PASS1 done: %d unplaced artery room(s)<reset>", #un))
    for i = 1, math.min(#un, 20) do
      local r, nb = un[i], {}
      for d, v in each_exit(adj[r]) do
        local de = DELTA[d]
        if de and (de[1] ~= 0 or de[2] ~= 0) then
          local cls = arteryRooms[v] and "A" or (unitByRoom[v] and ("U" .. unitByRoom[v]
            .. (unitDone[unitByRoom[v]] and "done" or "")) or (outwardSet[v] and "o" or "core"))
          nb[#nb + 1] = v .. (placed[v] and "P:" or "u:") .. cls
        end
      end
      cecho(string.format("\n<yellow>  artery %d nbrs: %s<reset>", r, table.concat(nb, " ")))
    end
    for ui, U in ipairs(units or {}) do
      if not unitDone[ui] then
        local placedNb, arteryNb = {}, {}
        for rr in pairs(U.rooms) do
          for d, v in each_exit(adj[rr]) do
            local de = DELTA[d]
            if de and (de[1] ~= 0 or de[2] ~= 0) and not U.rooms[v] then
              if placed[v] then placedNb[#placedNb + 1] = rr .. "<-" .. v
                .. (arteryRooms[v] and "A" or (outwardSet[v] and "o" or "core")) end
              if outwardSet[v] and arteryRooms[v] and not placed[v] then arteryNb[#arteryNb + 1] = v end
            end
          end
        end
        cecho(string.format("\n<cyan>  unit %d (%dr) gates=%s  placedNbrs={%s}  unplacedArteryNbrs={%s}<reset>",
          ui, elro.tcount(U.rooms), tostring(unit_gates_artery(ui)),
          table.concat(placedNb, " "), table.concat(arteryNb, ",")))
      end
    end
  end
  elro.step_snap(coord, "skeleton placed (" .. elro.tcount(outwardSet) .. " outward), now walking kids")
  elro.tr("  walk_branches: PASS2 begin (kids)")
  -- one phase for the whole pendant walk; the gap toplist carries from->to room ids
  elro._wbPhase = "pass2-pendants"
  for _, r in ipairs(seeds) do place_pendants(r) end    -- PASS 2: kids per artery node
  elro.tr("  walk_branches: PASS2 walk done, _walkN=" .. tostring(elro._walkN))
  elro._wbPhase = "pass3-compact"
  eqw_compact("post-walk")   -- PASS 3 (eqw): reclaim the slack the closures had to add
  -- assigned here, called at the end of the canvas. Captures nothing (reads only elro.* and cecho).
  elro.tg_report = function()
  if not elro.timeGuillo then return end
  -- nothing new since the last dump: say nothing
  if not elro._tgOpen then return end
    local rt = (elro._qblReduceT or 0)
    local loc, glob = (elro._grLocal or 0), (elro._grGlobal or 0)
    cecho(string.format("\n<yellow>[time] query_block_levers TOTAL: %.0fms over %d calls (reduce_far %.0fms = local %.0f + global %.0f + verify %.0f)<reset>",
      (elro._qblT or 0) * 1000, elro._qblN or 0, rt * 1000,
      loc * 1000, glob * 1000, (rt - loc - glob) * 1000))
    cecho(string.format("\n<yellow>[time]   qbl enumeration: %.0fms over %d (line,config) probes -- %.1f per call; emission (qbl - enum) %.0fms | fullDup %d suppressed<reset>",
      (elro._qenT or 0) * 1000, elro._qenN or 0,
      (elro._qblN or 0) > 0 and (elro._qenN or 0) / elro._qblN or 0,
      ((elro._qblT or 0) - (elro._qenT or 0)) * 1000, elro._gFullDup or 0))
    -- the equation-derived generator; `void` = separations the equations prove impossible
    if (elro._eqgN or 0) > 0 then
      cecho(string.format("\n<yellow>[time] query_eq_levers (eqGuillo): %.0fms over %d calls -- %d plate(s) emitted (%.1f/call), %d probes, %d void<reset>",
        (elro._eqgT or 0) * 1000, elro._eqgN or 0, elro._eqgOut or 0,
        (elro._eqgOut or 0) / (elro._eqgN or 1), elro._eqgTry or 0, elro._eqgVoid or 0))
      cecho(string.format("\n<yellow>[time]   ping-pong guard: %d shift(s) refused, %d committed shift(s) recorded<reset>",
        elro._eqPP or 0, elro._eqPPnote or 0))
      -- `clear-probe` is the apply / 4-detector / revert probe; the rest is plate building
      cecho(string.format("\n<yellow>[time]   eq split: clear-probe %.0fms/%d<reset>",
        (elro._eqgClT or 0) * 1000, elro._eqgClN or 0))
      cecho(string.format("\n<yellow>[time]   eq REPEATS: %d of %d call(s) had an identical (A,B,cap,pin,clearSet) AND identical placed-geometry fingerprint -- %.0fms<reset>",
        elro._eqgDup or 0, elro._eqgN or 0, (elro._eqgDupT or 0) * 1000))
      cecho(string.format("\n<yellow>[time]   deep-magnitude escalations (no clean pick -> regenerate at eqGuilloDeep): %d<reset>",
        elro._eqDeepN or 0))
      local wk = {}
      for k, n2 in pairs(elro._eqgWhy or {}) do wk[#wk + 1] = k .. "=" .. n2 end
      table.sort(wk)
      cecho(string.format("\n<yellow>[time]   eq void reasons: %s<reset>", table.concat(wk, " ")))
      local mp, me = elro._eqgMagP or {}, elro._eqgMagE or {}
      local mparts = {}
      for m = 1, TUNE.eqGuilloDeep do
        if (mp[m] or 0) > 0 then
          mparts[#mparts + 1] = string.format("s%d: %d probe(s) -> %d plate(s)", m, mp[m], me[m] or 0)
        end
      end
      cecho(string.format("\n<yellow>[time]   eq magnitudes: %s<reset>", table.concat(mparts, " | ")))
    if elro._e2mag then
      local ms, parts = {}, {}
      for k in pairs(elro._e2mag) do ms[#ms + 1] = k end
      table.sort(ms)
      for _, k in ipairs(ms) do parts[#parts + 1] = "m" .. k .. "=" .. elro._e2mag[k] end
      cecho("\n<yellow>[time]   APPLIED eq2d magnitudes: " .. table.concat(parts, " ") .. "<reset>")
    end
    if elro._eq2dBy then
      local names = {} ; for k in pairs(elro._eq2dBy) do names[#names + 1] = k end
      table.sort(names)                       -- never pairs() order in a diagnostic
      local parts = {}
      for _, k in ipairs(names) do
        local m = elro._eq2dBy[k]
        parts[#parts + 1] = string.format("%s %.0fms/%d -> %d plate(s) from %d probe(s), %d call(s) empty",
          k, m.t * 1000, m.n, m.out, m.try, m.empty)
      end
      cecho("\n<yellow>[time] query_eq_2d_levers by mode: " .. table.concat(parts, " | ") .. "<reset>")
      if elro._eq2dCapN then
        cecho(string.format("\n<yellow>[time]   eq2dProbeCap: %d call(s) run under the budget<reset>", elro._eq2dCapN or 0))
      end
    end
      do
        local b, v, rj = {}, {}, {}
        for k, e in pairs(elro._cutBail or {}) do b[#b + 1] = string.format("%s %.0fms/%d", k, e.t * 1000, e.n) end
        for k, n in pairs(elro._cutVoid or {}) do v[#v + 1] = k .. "=" .. n end
        for k, n in pairs(elro._cutRej or {}) do rj[#rj + 1] = k .. "=" .. n end
        table.sort(b) ; table.sort(v) ; table.sort(rj)
        cecho(string.format("\n<yellow>[time] query_cut_levers: %.0fms over %d call(s), %d build(s) (%d in fans) | by outcome %s | voids %s | plates %s<reset>",
          (elro._cutT or 0) * 1000, elro._cutN or 0, elro._cutBuilt or 0, elro._cutFanBuilt or 0,
          table.concat(b, " | "), table.concat(v, " "), table.concat(rj, " ")))
      end
      cecho(string.format("\n<yellow>[time]   void monotonicity: %d probe(s) ran after a void in the same direction, %d of which still built a plate<reset>",
        elro._eqgPostVoid or 0, elro._eqgNonMono or 0))
      do   -- the room-on-edge reseed: retries, kept plates and why the retry voided
        local w = {}
        for k, n in pairs(elro._ffReKeepWhy or {}) do w[#w + 1] = k .. "=" .. n end
        table.sort(w)
        cecho(string.format("\n<yellow>[time]   room-on-edge reseed: %d retr(y/ies) seeding %d room(s) (%d mirror) -> %d rebuilt, %d kept the first plate (retry void: %s); %d identical retr(y/ies) repeated<reset>",
          elro._ffReTry or 0, elro._ffReSeeds or 0, elro._ffReMir or 0, elro._ffReOK or 0, elro._ffReKeep or 0,
          #w > 0 and table.concat(w, " ") or "-", elro._ffReDup or 0))
      end
    end
    -- label-decided picks: a high share means the comparator is missing a key
    if (elro._ekRank or 0) > 0 then
      cecho(string.format("\n<yellow>[time] label-decided picks: %d of %d ranking(s) (%.1f%%) tie through every real key<reset>",
        elro._ekTop or 0, elro._ekRank or 0, 100 * (elro._ekTop or 0) / (elro._ekRank or 1)))
      if #(elro._ekTopList or {}) > 0 then
        cecho("\n<yellow>[time]   e.g. " .. table.concat(elro._ekTopList, " | ") .. "<reset>")
      end
      if elro._ekClass then
        local ks = {} ; for k, v in pairs(elro._ekClass) do ks[#ks + 1] = k .. "=" .. v end ; table.sort(ks)
        cecho("\n<yellow>[time]   tie classes: " .. table.concat(ks, " ") .. "<reset>")
        if elro._ekOther then cecho("\n<yellow>[time]   non-twin: " .. table.concat(elro._ekOther, " | ") .. "<reset>") end
      end
    end
    if (elro._cnrLazy or 0) > 0 then
      cecho(string.format("\n<yellow>[time] lazy corner generation: asked %d time(s) at the give-up point, found a pair %d time(s)<reset>",
        elro._cnrLazy or 0, elro._cnrLazyHit or 0))
    end
    cecho(string.format("\n<yellow>[time] walk detectors (cell_overlap/crossing/edge-over-room/room-on-edge): %.0fms over %d calls<reset>",
      (elro._detT or 0) * 1000, elro._detN or 0))
    cecho(string.format("\n<yellow>[time]   detectors split: overlap %.0fms/%d | crossing %.0fms/%d | edge-over-room %.0fms/%d | room-on-edge %.0fms/%d<reset>",
      (elro._detOvT or 0) * 1000, elro._detOvN or 0, (elro._detCrT or 0) * 1000, elro._detCrN or 0,
      (elro._detEorT or 0) * 1000, elro._detEorN or 0, (elro._detRpeT or 0) * 1000, elro._detRpeN or 0))
    -- a high stall ratio is the healthy reading (mrStallBreak doing its job)
    cecho(string.format("\n<yellow>[time]   make-room repair loop: %d re-iteration(s), %d cut as STALLED"
      .. " (the round left `read(axis)` identical)<reset>", elro._mrIter or 0, elro._mrStall or 0))
    if elro._fsWho then
      local t = {} ; for k, n in pairs(elro._fsWho) do t[#t + 1] = { k, n } end
      table.sort(t, function(a, b) return a[2] > b[2] end)
      local T = elro._fsWhoT or {}
      local o = {} ; for i = 1, math.min(#t, 12) do o[#o + 1] = string.format("%s:%d/%.0fms", t[i][1], t[i][2], (T[t[i][1]] or 0) * 1000) end
      cecho("\n<yellow>[time]   eqw_forced_shift BY CALLER LINE (calls/ms): " .. table.concat(o, " | ") .. "<reset>")
    end
    do
      local function kv(t)
        local o = {} ; for k, n in pairs(t or {}) do o[#o + 1] = { tostring(k), n } end
        table.sort(o, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
        local p = {} ; for i = 1, #o do p[#p + 1] = o[i][1] .. "=" .. o[i][2] end
        return table.concat(p, " ")
      end
      cecho(string.format("\n<yellow>[time]     seam: sf-walk dedup %d, subset probes %d<reset>",
        elro._ctSfSkip or 0, elro._ctSubset or 0))
      do local o = {} ; for k, n in pairs(elro._ctHop or {}) do o[#o + 1] = k .. "=" .. n end ; table.sort(o)
        cecho(string.format("\n<yellow>[time]     seam walk: %d walk(s), %d hop(s), %d emit(s) | hop outcomes [%s]<reset>", elro._ctWalks or 0, elro._ctSeam or 0, elro._ctEmit or 0, table.concat(o, " "))) end
      do
        local W, ks = elro._wkT or {}, {}
        for k in pairs(W) do ks[#ks + 1] = k end ; table.sort(ks)
        local o = {}
        for _, k in ipairs(ks) do
          local e = W[k]
          o[#o + 1] = string.format("%s %.0fms/%d%s", k, e.t * 1000, e.n, (k:find(":WALK", 1, true) and (" (" .. e.emit .. " emitted)") or ""))
        end
        if #o > 0 then cecho("\n<yellow>[time]       walk classes (ms/builds; WALK = whole walk incl. class_seam): " .. table.concat(o, " | ") .. "<reset>") end
      end
      do local o = {} ; for k, n in pairs(elro._ctSeq or {}) do o[#o + 1] = k .. "=" .. n end ; table.sort(o)
        cecho("\n<yellow>[time]       BETTER after k no-better hops (first = before any best, recover = after one): " .. table.concat(o, " ") .. "<reset>") end
      if (elro._wlWalk or 0) + (elro._wlHeld or 0) > 0 then
        cecho(string.format("\n<yellow>[time]       eqWalkLazy: %d base(s) walked, %d HELD (not in the tied-best score group) -- scoring cost %.0fms<reset>",
          elro._wlWalk or 0, elro._wlHeld or 0, (elro._wlT or 0) * 1000))
        if (elro._eqWalkEsc or 0) > 0 then
          cecho(string.format("\n<yellow>[time]         ...of which %d conflict(s) found no clean pick and ESCALATED to the held walks<reset>", elro._eqWalkEsc or 0))
        end
      end
      cecho(string.format("\n<yellow>[time]     seamNoTight: %d walk winner(s) SKIPPED the rebuild (the builder has no tightness drag, so it would be the winning hop again)<reset>",
        elro._sntInert or 0))
    end
    if elro._detWho then
      local t = {} ; for k, n in pairs(elro._detWho) do t[#t + 1] = { k, n } end
      table.sort(t, function(a, b) return a[2] > b[2] end)
      local o = {} ; for i = 1, math.min(#t, 20) do o[#o + 1] = t[i][1] .. " " .. t[i][2] end
      cecho("\n<yellow>[time]   detectors BY CALLER: " .. table.concat(o, " | ") .. " || det_sweep builds " .. tostring(elro._dsN) .. "<reset>")
    end
    -- guard phase: prescans should be ~1 per conflict plus one per two-lever search
    cecho(string.format("\n<yellow>[time]   guard prescans: crossing_set %.0fms/%d | roomedge_set %.0fms/%d<reset>",
      (elro._csT or 0) * 1000, elro._csN or 0, (elro._rsT or 0) * 1000, elro._rsN or 0))
    cecho(string.format("\n<yellow>[time]   guards split: makes-crossing %.0fms/%d (moved-idx %.0fms/%d) | makes-roomedge %.0fms/%d (moved-idx %.0fms/%d) | makes-overlap %.0fms/%d | is-noop %.0fms/%d<reset>",
      (elro._pmcT or 0) * 1000, elro._pmcN or 0, (elro._cmT or 0) * 1000, elro._cmN or 0,
      (elro._pmrT or 0) * 1000, elro._pmrN or 0, (elro._rmT or 0) * 1000, elro._rmN or 0,
      (elro._pmoT or 0) * 1000, elro._pmoN or 0, (elro._noopT or 0) * 1000, elro._noopN or 0))
    -- by caller: pmc = makes-crossing, pmr = makes-roomedge, pmo = makes-overlap
    if elro._gudBy then
      local W, ks = elro._gudBy, {}
      for k in pairs(W) do ks[#ks + 1] = k end
      table.sort(ks, function(a2, b2) if W[a2].t ~= W[b2].t then return W[a2].t > W[b2].t end
        return a2 < b2 end)
      local parts = {}
      for _, k in ipairs(ks) do
        parts[#parts + 1] = string.format("%s %.0fms/%d", k, W[k].t * 1000, W[k].n)
      end
      cecho("\n<yellow>[time]   guards BY CALLER: " .. table.concat(parts, " | ") .. "<reset>")
    end
    cecho(string.format("\n<yellow>[time]   moved-idx build vs scan: crossings_moved build %.0fms / scan %.0fms | roomedge_moved build %.0fms / scan %.0fms<reset>",
      (elro._cmBT or 0) * 1000, ((elro._cmT or 0) - (elro._cmBT or 0)) * 1000,
      (elro._rmBT or 0) * 1000, ((elro._rmT or 0) - (elro._rmBT or 0)) * 1000))
    do local o = {} ; for k, n in pairs(elro._rgCensus or {}) do o[#o + 1] = k .. "=" .. n end ; table.sort(o)
      cecho("\n<yellow>[time]   eqw_close rigid variant census: " .. table.concat(o, " ") .. "<reset>") end
    cecho(string.format("\n<yellow>[time] eqw_classes: %.0fms over plain %d (%d memo hits) + keyed %d call(s)<reset>", (elro._ecT or 0) * 1000, (elro._ecN or {}).plain or 0, (elro._ecN or {}).memo or 0, (elro._ecN or {}).keyed or 0))
    cecho(string.format("\n<yellow>[time] eqw_compact: %.0fms over %d pass(es), %d reverted<reset>",
      (elro._eqcT or 0) * 1000, elro._eqcN or 0, elro._eqcRev or 0))
    cecho(string.format("\n<yellow>[time] candidate SCORING: field setup %.0fms over %d collision(s) | repel %.0fms over %d + stretch %.0fms over %d<reset>",
      (elro._jsT or 0) * 1000, elro._jsN or 0,
      (elro._repT or 0) * 1000, elro._repN or 0, (elro._strT or 0) * 1000, elro._strN or 0))
    cecho(string.format("\n<yellow>[time] count_defects (WHOLE-MAP pass, every gate before+after): %.0fms over %d calls<reset>",
      (elro._cdT or 0) * 1000, elro._cdN or 0))
    -- place_room's conflict loop; these buckets nest
    cecho(string.format("\n<yellow>[time] place_room loop: dispatch %.0fms over %d (of which seeding %.0fms over %d -> detect-only %.0fms) | generators %.0fms over %d (incl qbl %.0fms) | guards %.0fms over %d<reset>",
      (elro._dspT or 0) * 1000, elro._dspN or 0,
      (elro._sedT or 0) * 1000, elro._sedN or 0, ((elro._dspT or 0) - (elro._sedT or 0)) * 1000,
      (elro._genT or 0) * 1000, elro._genN or 0, (elro._qblT or 0) * 1000,
      (elro._gudT or 0) * 1000, elro._gudN or 0))
    if (elro._ffCalls or 0) > 0 then
      local F, ks = elro._ffPh or {}, {}
      for k in pairs(F) do ks[#ks + 1] = k end
      table.sort(ks, function(a2, b2) return F[a2].t > F[b2].t end)
      local parts = {}
      for _, k in ipairs(ks) do
        parts[#parts + 1] = string.format("%s %.0fms/%d", k, F[k].t * 1000, F[k].n)
      end
      cecho(string.format("\n<yellow>[time] eqw_field_shift: %.0fms over %d call(s) -- %s<reset>",
        (elro._ffTime or 0) * 1000, elro._ffCalls or 0, table.concat(parts, " | ")))
      cecho(string.format("\n<yellow>[time]   pass-1 cache (%d slot(s) per generation): %d full hit(s) + %d base-only COPY(s) for a rigid build, %d rebuild(s) (a hit skips a whole-canvas union-find over both axes)<reset>",
        TUNE.eqwPass1Slots or 12, elro._ffP1Hit or 0, elro._ffP1Copy or 0, elro._ffP1Miss or 0))
      do
        local F, order = elro._ffSize or {}, { "n_le4", "n_le16", "n_le64", "n_le256", "n_gt256", "void" }
        local o = {}
        for _, k in ipairs(order) do
          local e = F[k]
          if e then o[#o + 1] = string.format("%s %.0fms/%d", k, e.t * 1000, e.n) end
        end
        if #o > 0 then
          cecho("\n<yellow>[time]   build cost BY RESULT SIZE: " .. table.concat(o, " | ") .. "<reset>")
        end
      end
      cecho(string.format("\n<yellow>[time]   rigid-pendant rule: %.0fms over %d call(s) (%d room(s) re-assigned) -- of which bridge_forest %.0fms over %d build(s)<reset>",
        (elro._rpT or 0) * 1000, elro._rpN or 0, elro._rpFix or 0,
        (elro._rpBFT or 0) * 1000, elro._rpBFN or 0))
      cecho(string.format("\n<yellow>[time]     ...of which INSIDE the closure driver (`_inClose`,"
        .. " where a plate is meant to be minimal): %d call(s), %d room(s) re-assigned<reset>",
        elro._rpClN or 0, elro._rpClFix or 0))
      do local P = elro._rpPh or {}
        cecho(string.format("\n<yellow>[time]     rigid-pendant split: tree+jobs %.0fms | landing test %.0fms over %d whole-canvas scan(s)<reset>",
          (P.tree or 0) * 1000, (P.landing or 0) * 1000, P.landingN or 0))
        if elro.probeRigid then
          cecho(string.format("\n<yellow>[time]     NO-OP job census (probeRigid): %d of %d side(s)"
            .. " re-assigned (0,0) from (0,0) -- anchor stationary AND no plate room inside<reset>",
            elro._rpNoop or 0, elro._rpJob or 0))
        end
        cecho(string.format("\n<yellow>[time]     ...and the block-cut tree BFS (order/parent/pedge,"
          .. " one root): %.0fms<reset>", (P.bfs or 0) * 1000)) end
      if elro.probeField then
        local ks = {}
        for k in pairs(elro._ffWhy or {}) do ks[#ks + 1] = k end
        table.sort(ks, function(a2, b2) return elro._ffWhy[a2] > elro._ffWhy[b2] end)
        local ps = {}
        for i2 = 1, math.min(#ks, 40) do ps[#ps + 1] = ks[i2] .. "=" .. elro._ffWhy[ks[i2]] end
        cecho("\n<yellow>[time]   FIELD VOIDS by rigidity: " .. table.concat(ps, " | ") .. "<reset>")
      end
      if elro.probeField then
        cecho(string.format("\n<yellow>[time]   pass-1 REPEAT census (probeField): %d of %d run(s) rebuilt a partition an earlier call had already built<reset>",
          elro._ffKeyHit or 0, (elro._ffKeyHit or 0) + (elro._ffKeyMiss or 0)))
        cecho(string.format("\n<yellow>[time]     ...of which SOUNDLY cacheable (rigidAx unset, so"
          .. " the key is complete): %d hit(s) of %d run(s)<reset>",
          elro._ffKey0Hit or 0, (elro._ffKey0Hit or 0) + (elro._ffKey0Miss or 0)))
        cecho(string.format("\n<yellow>[time]     ...and with a ONE-SLOT cache: %d hit(s) of %d"
          .. " run(s)<reset>", elro._ffLastHit or 0,
          (elro._ffLastHit or 0) + (elro._ffLastMiss or 0)))
      end
    end
    if elro._rdSplitT or (elro._rdBig or 0) > 0 then
      local RS, ks = elro._rdSplitT or {}, {}
      for k in pairs(RS) do ks[#ks + 1] = k end
      table.sort(ks, function(a2, b2) return RS[a2].t > RS[b2].t end)
      local parts = {}
      for _, k in ipairs(ks) do
        parts[#parts + 1] = string.format("%s %.0fms/%d", k, RS[k].t * 1000, RS[k].n)
      end
      if #parts == 0 then parts[1] = "no build" end
      -- no silent caps: say how many rings ringSizeCap refused
      cecho(string.format("\n<yellow>[time]   ring builds (canonical vs split cut set, then by"
        .. " ring size): %s | ringSizeCap(%d) skipped %d oversize ring visit(s)<reset>",
        table.concat(parts, " | "), TUNE.ringSizeCap or 0, elro._rdBig or 0))
    end
    if elro._gsSplit then
      local ks = {}
      for k in pairs(elro._gsSplit) do ks[#ks + 1] = k end
      table.sort(ks, function(a2, b2) return elro._gsSplit[a2].t > elro._gsSplit[b2].t end)
      local parts, tot = {}, 0
      for _, k in ipairs(ks) do
        local a = elro._gsSplit[k]
        parts[#parts + 1] = string.format("%s %.0fms/%d", k, a.t * 1000, a.n)
        tot = tot + a.t
      end
      cecho(string.format("\n<yellow>[time]   generators BY GENERATOR (sums to %.0fms of %.0fms): %s<reset>",
        tot * 1000, (elro._genT or 0) * 1000, table.concat(parts, " | ")))
    end
    if (elro._regenN or 0) > 0 then
      cecho(string.format("\n<yellow>[time]   ...of which ESCALATION regeneration: %.0fms over %d"
        .. " re-run(s) -- counted in generators, no longer in guards<reset>",
        (elro._regenT or 0) * 1000, elro._regenN or 0))
    end
    -- place_room total vs the sum of its measured parts
    do
      local parts = (elro._dspT or 0) + (elro._genT or 0) + (elro._gudT or 0)
        + (elro._mrT or 0) + (elro._clT or 0) + (elro._rcT or 0) + (elro._eqsT or 0)
      local tot, n, cf = (elro._prT or 0), (elro._prN or 0), (elro._prCf or 0)
      cecho(string.format("\n<yellow>[time] place_room TOTAL %.0fms over %d call(s) (%d with a conflict, %d clean) | measured parts %.0fms | UNACCOUNTED %.0fms (%.1fms per clean placement)<reset>",
        tot * 1000, n, cf, n - cf, parts * 1000, (tot - parts) * 1000,
        (n - cf) > 0 and (tot - parts) * 1000 / (n - cf) or 0))
    end
    -- the gap between placements: gap total + _prT should be the walk
    do
      local g, keys, tot = elro._gapT or {}, {}, 0
      for k, v in pairs(g) do keys[#keys + 1] = k ; tot = tot + v end
      table.sort(keys, function(a, b) return g[a] > g[b] end)
      local parts = {}
      for _, k in ipairs(keys) do
        parts[#parts + 1] = string.format("%s %.0fms/%d", k, g[k] * 1000, (elro._gapN or {})[k] or 0)
      end
      cecho(string.format("\n<yellow>[time] GAP between placements: %.0fms total -- %s<reset>",
        tot * 1000, table.concat(parts, " | ")))
      cecho(string.format("\n<yellow>   of which JUMP between walks: %.0fms over %d walk(s) (%.1fms each) -- wb-setup %.0fms, compose %.0fms<reset>",
        elro._jumpT or 0, elro._jumpN or 0,
        (elro._jumpN or 0) > 0 and (elro._jumpT or 0) / elro._jumpN or 0,
        elro._jumpSetupT or 0, (elro._jumpT or 0) - (elro._jumpSetupT or 0)))
      local top = elro._gapTop or {}
      table.sort(top, function(a, b) return a.ms > b.ms end)
      for i = 1, math.min(#top, 12) do
        local e = top[i]
        cecho(string.format("\n<yellow>   gap %2d. %6.0fms  [%s]  %s -> %s<reset>",
          i, e.ms, e.ph, tostring(e.from), tostring(e.to)))
      end
      if #top > 12 then
        local rest = 0
        for i = 13, #top do rest = rest + top[i].ms end
        cecho(string.format("\n<yellow>   ...and %d more gap(s) over 4ms totalling %.0fms<reset>", #top - 12, rest))
      end
    end
    -- `reverted` is per axis-solve, not per pass
    cecho(string.format("\n<yellow>[time]   eqw redistribute: spread %.0fms over %d pass(es), %d moved something | %d reverted (%d pre-gate) | flush-skip %d room(s)<reset>",
      (elro._eqsT or 0) * 1000, elro._eqsN or 0, elro._eqsMovedN or 0,
      elro._eqsRev or 0, elro._eqsPre or 0, elro._eqFlushN or 0))
    if (elro._lsFallback or 0) > 0 or (elro._lsAvoided or 0) > 0 then
      local k = elro._lsFbKind or {}
      cecho(string.format("\n<yellow>[time]   least-severe last resort: %d room(s) -- %d took a crossing, %d a room-on-edge<reset>",
        elro._lsFallback, k.crossing or 0, k["room-on-edge"] or 0))
      if (elro._lsAvoided or 0) > 0 then
        cecho(string.format("\n<yellow>[time]     %d deliberate defect(s) AVOIDED: deferred past the corner tier, which then cleared it<reset>",
          elro._lsAvoided))
      end
      -- new crossings by proof: `forced` = proved unavoidable; the rest name the failed condition
      local xs, parts = elro._lsX or {}, {}
      for reason, n in pairs(xs) do parts[#parts + 1] = reason .. "=" .. n end
      table.sort(parts)
      if #parts > 0 then
        cecho(string.format("\n<yellow>[time]     new crossings by proof: %s<reset>", table.concat(parts, " ")))
      end
    end
    -- crossing conversion: `block-not-proved` is the gate doing its job; `no-pair` is the
    -- case to come back to
    if (elro._ccN or 0) > 0 or (elro._ccTry or 0) > 0 or next(elro._ccWhy or {}) then
      local w, wp = elro._ccWhy or {}, {}
      for reason, n in pairs(w) do wp[#wp + 1] = reason .. "=" .. n end
      table.sort(wp)
      local sp = {}
      for src, n in pairs(elro._ccSrc or {}) do sp[#sp + 1] = src .. "=" .. n end
      table.sort(sp)
      cecho(string.format("\n<yellow>[time]   crossing conversion: %d room-on-edge(s) converted to a crossing"
        .. " (%d attempt(s) in a proved block)%s | declined: %s<reset>",
        elro._ccN or 0, elro._ccTry or 0,
        #sp > 0 and (" [" .. table.concat(sp, " ") .. "]") or "",
        #wp > 0 and table.concat(wp, " ") or "(none)"))
    end
    if (elro._fcProved or 0) > 0 or next(elro._fcWhy or {}) then
      local w, wp = elro._fcWhy or {}, {}
      for reason, n in pairs(w) do wp[#wp + 1] = reason .. "=" .. n end
      table.sort(wp)
      cecho(string.format("\n<yellow>[time]   forced-crossing proof: %d proved unavoidable | declined: %s<reset>",
        elro._fcProved or 0, #wp > 0 and table.concat(wp, " ") or "(none)"))
    end
    -- wire prover: `min crossings >= N` is a certified lower bound. Deliberately not nested
    -- inside the _tcRan gate below (which also swallows the LCA line).
    if elro._wcRan then
      cecho(string.format("\n<yellow>[time]   wire proof: %d crossing(s) accepted as unavoidable"
        .. " | min crossings >= %d, %d forced wire pair(s)<reset>",
        elro._wcProved or 0, elro._wcMin or 0, elro._wcPairs or 0))
      if #(elro._wcList or {}) > 0 then
        cecho(string.format("\n<yellow>[time]     accepted: %s<reset>", table.concat(elro._wcList, " ")))
      end
      -- order clamp: if `reverted` dominates `clamped`, the clamp is effectively off
      if (elro._woN or 0) + (elro._woEq or 0) + (elro._woLie or 0) + (elro._woBad or 0) > 0 then
        cecho(string.format("\n<yellow>[time]   order clamp: %d clamped | %d axis determined by an"
          .. " equality | %d reverted to stay truthful | %d contradictory bound(s)<reset>",
          elro._woN or 0, elro._woEq or 0, elro._woLie or 0, elro._woBad or 0))
      end
      if (elro._wcCycles or 0) > 0 or (elro._wcArcs or 0) > 0 then
        cecho(string.format("\n<red>[time]     INFEASIBLE: %d class(es) on an order cycle,"
          .. " %d strict order(s) demanded inside one equality class"
          .. " -- no truthful drawing of this graph exists<reset>",
          elro._wcCycles or 0, elro._wcArcs or 0))
      end
    end
    -- topology test, printed whenever it built; `genus 0, 0 pair(s)` means it is inert here
    if elro._tcRan then
    -- LCA junction: a nil junction disables the two-lever tiers
    if (elro._lcaOk or 0) > 0 or next(elro._lcaWhy or {}) then
      local w, wp = elro._lcaWhy or {}, {}
      for reason, n in pairs(w) do wp[#wp + 1] = reason .. "=" .. n end
      table.sort(wp)
      cecho(string.format("\n<yellow>[time]   LCA junction: %d found | nil: %s<reset>",
        elro._lcaOk or 0, #wp > 0 and table.concat(wp, " ") or "(none)"))
    end
      cecho(string.format("\n<yellow>[time]   topology test: %d crossing(s) accepted as unavoidable"
        .. " | genus %.0f, %d non-closing face(s), %d pair(s) available<reset>",
        elro._tcProved or 0, elro._tcGenus or 0, elro._tcFaces or 0, elro._tcPairs or 0))
      if #(elro._tcList or {}) > 0 then
        cecho(string.format("\n<yellow>[time]     accepted: %s<reset>", table.concat(elro._tcList, " ")))
      end
    end
    if (elro._eqcOrder2 or 0) > 0 or (elro._eqcUnstuck or 0) > 0 then
      cecho(string.format("\n<yellow>[time]   eqw close: %d closure(s) rescued by the REVERSED phase order | %d room(s) un-stuck after closing<reset>",
        elro._eqcOrder2 or 0, elro._eqcUnstuck or 0))
    end
    -- the option funnel: read `evaluated`, not `offered` (the pick loop breaks at the first clean one)
    if (elro._optSteps or 0) > 0 then
      local eqP, eqO = elro._eqgTry or 0, elro._eqgOut or 0
      local twP, twO = elro._eq2dTry or 0, elro._eq2dOut or 0
      local function pct(a, b) return 100 * a / math.max(1, b) end
      cecho(string.format("\n<yellow>[time] option funnel: probes %d (eq %d + 2d %d) -> %d plate(s)"
        .. " (%.0f%% survive) -> %d offered over %d conflict(s) (%.1f each)<reset>",
        eqP + twP, eqP, twP, eqO + twO, pct(eqO + twO, eqP + twP),
        elro._optGen or 0, elro._optSteps or 0,
        (elro._optGen or 0) / math.max(1, elro._optSteps or 1)))
      cecho(string.format("\n<yellow>[time]   -> %d EVALUATED (%.0f%% of those offered)"
        .. " = %.1f guard sweep(s) per conflict -> %d LEGAL (%.0f%% of evaluated)<reset>",
        elro._optEval or 0, pct(elro._optEval or 0, elro._optGen or 0),
        (elro._optEval or 0) / math.max(1, elro._optSteps or 1),
        (elro._optWhy or {}).PICKED or 0, pct((elro._optWhy or {}).PICKED or 0, elro._optEval or 0)))
      local T, parts = elro._optWhy or {}, {}
      local names = {} ; for k in pairs(T) do names[#names + 1] = k end
      table.sort(names, function(a, b) if T[a] ~= T[b] then return T[a] > T[b] end return a < b end)
      for _, k in ipairs(names) do parts[#parts + 1] = k .. " " .. T[k] end
      cecho("\n<yellow>[time]   verdicts (worst-first): " .. table.concat(parts, " | ") .. "<reset>")
      local K, kp = elro._optKind or {}, {}
      local kn = {} ; for k in pairs(K) do kn[#kn + 1] = k end
      table.sort(kn, function(a, b) if K[a] ~= K[b] then return K[a] > K[b] end return a < b end)
      for i2 = 1, math.min(#kn, 14) do kp[#kp + 1] = kn[i2] .. " " .. K[kn[i2]] end
      if #kp > 0 then
        cecho("\n<yellow>[time]   by kind/verdict (worst-first): " .. table.concat(kp, " | ") .. "<reset>")
      end
      do
        local R, ks = elro._optWalkRank or {}, {}
        for k in pairs(R) do ks[#ks + 1] = k end ; table.sort(ks)
        local o = {} ; for _, k in ipairs(ks) do o[#o + 1] = k .. " x" .. R[k] end
        if #o > 0 then cecho("\n<yellow>[time]   picked walk products: rank of their BASE among the conflict's base eq-plates: " .. table.concat(o, " | ") .. "<reset>") end
      end
      do
        local Z, ks = elro._optWalkSB or {}, {}
        for k in pairs(Z) do ks[#ks + 1] = k end ; table.sort(ks)
        local o = {} ; for _, k in ipairs(ks) do o[#o + 1] = k .. " x" .. Z[k] end
        if #o > 0 then cecho("\n<yellow>[time]   ...and SHEAR-BLIND (score alone): " .. table.concat(o, " | ") .. "<reset>") end
      end
      -- the suffix census: offered / evaluated / PICKED per generation class (see optSuf)
      do
        local S, ks = elro._optSuf or {}, {}
        for k in pairs(S) do ks[#ks + 1] = k end
        table.sort(ks, function(a, b)
          if S[a].picked ~= S[b].picked then return S[a].picked > S[b].picked end
          if S[a].offered ~= S[b].offered then return S[a].offered > S[b].offered end
          return a < b end)
        local o = {}
        for _, k in ipairs(ks) do
          o[#o + 1] = string.format("%s %d/%d/%d", k, S[k].offered, S[k].evaluated, S[k].picked)
        end
        if #o > 0 then
          cecho("\n<yellow>[time]   by SUFFIX class (offered/evaluated/PICKED): " .. table.concat(o, " | ") .. "<reset>")
        end
      end
      do
        local B = elro._optSize or {}
        local order = { "n_le4", "n_le16", "n_le64", "n_le256", "n_gt256" }
        local o = {}
        for _, k in ipairs(order) do
          local e = B[k]
          if e then o[#o + 1] = string.format("%s %d/%d/%d", k, e.offered, e.evaluated, e.picked) end
        end
        if #o > 0 then
          cecho("\n<yellow>[time]   by PLATE SIZE (offered/evaluated/PICKED): " .. table.concat(o, " | ") .. "<reset>")
        end
      end
      if elro._optWalkSc then
        local W = elro._optWalkSc
        cecho(string.format("\n<yellow>[time]   walk product vs its BASE score: %d identical, %d DIFFERENT (%d worse, %d better), %d base not offered%s<reset>",
          W.same, W.diff, W.worse, W.best, W.noBase,
          (#W > 0) and ("  [" .. table.concat(W, " | ") .. "]") or ""))
        cecho(string.format("\n<yellow>[time]     biggest amount a variant BEAT its own base by:"
          .. " %.6g%s<reset>", W.maxGain or 0, W.maxWho and ("  (" .. W.maxWho .. ")") or ""))
      end
      -- a release costs the whole pick loop a second time, so these should be small
      if (elro._reLazyEsc or 0) + (elro._reLazyJoin or 0) > 0 then
        cecho(string.format("\n<yellow>[time]   reangleLazy: held re-angles rejoined at another escalation %d time(s), needed a rung of their own %d time(s)<reset>",
          elro._reLazyJoin or 0, elro._reLazyEsc or 0))
      end
      local D, dp = elro._optDiag or {}, {}
      local dn = {} ; for k in pairs(D) do dn[#dn + 1] = k end
      table.sort(dn, function(a, b) if D[a] ~= D[b] then return D[a] > D[b] end return a < b end)
      for i2 = 1, #dn do dp[#dp + 1] = dn[i2] .. " " .. D[dn[i2]] end
      if #dp > 0 then
        cecho("\n<yellow>[time]   DIAGONAL placements only: " .. table.concat(dp, " | ") .. "<reset>")
      end
      -- guard sweeps: the tiers sweep exhaustively, the pick loop stops at the first clean one
      local pl = elro._optEval or 0
      local tot = (elro._pmcN or 0) + (elro._pmrN or 0) + (elro._pmoN or 0)
      cecho(string.format("\n<yellow>[time]   guard sweeps: %d total, of which the PICK LOOP"
        .. " evaluated %d (%.0f%%) -- the other %d are the tiers,"
        .. " which do not stop at the first clean pick<reset>",
        tot, pl, 100 * pl / math.max(1, tot), math.max(0, tot - pl)))
    end
    cecho(string.format("\n<yellow>[time] eqw repair: make-room %.0fms over %d | close %.0fms over %d | reclaim %.0fms over %d<reset>",
      (elro._mrT or 0) * 1000, elro._mrN or 0, (elro._clT or 0) * 1000, elro._clN or 0,
      (elro._rcT or 0) * 1000, elro._rcN or 0))
    cecho(string.format("\n<yellow>[time]   ring tighten (the WHOLE ring after a closure lands): %.0fms over %d call(s), %d edge attempt(s) -- %d REVERTED as a closed-cycle redistribution, %d cell(s) of area won<reset>",
      (elro._trT or 0) * 1000, elro._trN or 0, elro._trTry or 0, elro._eqcRingPong or 0,
      elro._eqcRingCells or 0))
    cecho(string.format("\n<yellow>[time]   close split: eq_phase %d call(s) (%d took the carried hint) | attempt() %.0fms over %d apply/scan/revert cycle(s)<reset>",
      elro._clPhN or 0, elro._clPhHint or 0, (elro._clAttT or 0) * 1000, elro._clAttN or 0))
    do local P = elro._clPh or {}
      cecho(string.format("\n<yellow>[time]     attempt() split: unwind+rebuild_occ %.0fms/%d | eqw_score %.0fms/%d | eqw_shared_grow %.0fms/%d | first_bad %.0fms/%d<reset>",
        (P.unwind or 0) * 1000, P.unwindN or 0, (P.score or 0) * 1000, P.scoreN or 0,
        (P.grow or 0) * 1000, P.growN or 0, (P.firstbad or 0) * 1000, P.firstbadN or 0)) end
    cecho(string.format("\n<yellow>[time]   det_sweep (the frozen-geometry index set): %.0fms over %d build(s)<reset>", (elro._dsT or 0) * 1000, elro._dsN or 0))
    -- mr_seeds is billed to make-room, not to generators
    if (elro._mrsN or 0) > 0 then
      cecho(string.format("\n<yellow>[time]   of which mr_seeds (query_eq_levers on the repaired pair):"
        .. " %.0fms over %d call(s) = %.0f%% of make-room -- %d seed(s) added, %d won<reset>",
        (elro._mrsT or 0) * 1000, elro._mrsN or 0,
        100 * (elro._mrsT or 0) / math.max(1e-9, elro._mrT or 0),
        elro._mrSeedAdd or 0, elro._mrSeedWin or 0))
    end
    if (elro._mrCascN or 0) > 0 then
      cecho(string.format("\n<yellow>[time]   make-room CASCADE: %d level(s) applied"
        .. " (a probed option broke a clean room; its blocker's class shifted the same way)<reset>",
        elro._mrCascN))
      if (elro._mrCascCarry or 0) > 0 then
        cecho(string.format("<yellow>  -- of which %d took the CARRY form (the level re-seeded with"
          .. " what it would otherwise have stretched, and it won on make-room's key)<reset>",
          elro._mrCascCarry))
      end
    end
    -- which generator wins, read off elro._walkPulls (what was committed, not offered)
    local kc, ko = {}, {}
    for _, p in ipairs(elro._walkPulls or {}) do
      local k = tostring(p.kind or "?")
      if kc[k] == nil then ko[#ko + 1] = k ; kc[k] = 0 end
      kc[k] = kc[k] + 1
    end
    table.sort(ko, function(a, b) return kc[a] > kc[b] end)
    local parts = {}
    for _, k in ipairs(ko) do parts[#parts + 1] = k .. "=" .. kc[k] end
    cecho(string.format("\n<yellow>[time] APPLIED pull kinds: %s<reset>",
      #parts > 0 and table.concat(parts, " ") or "(none)"))
    -- applied eq-plate magnitudes; the pattern must track the ek grammar `eq:<seed>:<dir><mag>`
    local mag = {}
    for _, w in ipairs(elro._walkPulls or {}) do
      local m = tostring(w.ek or ""):match("^eq:%d+:[nsew](%d+)$")
      if m then mag[tonumber(m)] = (mag[tonumber(m)] or 0) + 1 end
    end
    local mparts2 = {}
    for m = 1, 32 do if mag[m] then mparts2[#mparts2 + 1] = "s" .. m .. "=" .. mag[m] end end
    -- applied chord gaps: `chord:<axis>:<a>:<b>:<dir>:<g>` (optional `:@room` suffix)
    local cmag = {}
    for _, w in ipairs(elro._walkPulls or {}) do
      local g = tostring(w.ek or ""):match("^chord:%d+:%d+:%d+:%-?%d+:(%d+)")
      if g then cmag[tonumber(g)] = (cmag[tonumber(g)] or 0) + 1 end
    end
    local cparts = {}
    for m = 1, 64 do if cmag[m] then cparts[#cparts + 1] = "g" .. m .. "=" .. cmag[m] end end
    -- and which plan shape won (greedy vs `:@room` rigid-prefix)
    local cGreedy, cRigid = 0, 0
    for _, w in ipairs(elro._walkPulls or {}) do
      local ek = tostring(w.ek or "")
      if ek:match("^chord:") then
        if ek:match(":@%d+$") then cRigid = cRigid + 1 else cGreedy = cGreedy + 1 end
      end
    end
    cparts[#cparts + 1] = string.format("| shape: greedy=%d rigid-prefix(@)=%d", cGreedy, cRigid)
    cecho(string.format("\n<yellow>[time]   APPLIED chord gaps: %s<reset>",
      #cparts > 0 and table.concat(cparts, " ") or "(none applied)"))
    cecho(string.format("\n<yellow>[time]   APPLIED eq-plate magnitudes: %s<reset>",
      #mparts2 > 0 and table.concat(mparts2, " ") or "(none applied)"))
    -- _lever_core internals: three disjoint regions
    cecho(string.format("\n<yellow>[time] _lever_core: setup %.0fms over %d | farside BFS %.0fms over %d | eval %.0fms over %d<reset>",
      (elro._lcSetT or 0) * 1000, elro._lcSetN or 0, (elro._lcFarT or 0) * 1000, elro._lcFarN or 0,
      (elro._lcEvT or 0) * 1000, elro._lcEvN or 0))
    -- consider_bridge emits one side per bridge only where sA and sB partition the placed rooms
    cecho(string.format("\n<yellow>[time] bridge sides: %d bridge(s) -- partition %d, split %d (max %d rooms unclaimed, %d overlapping), one-side %d<reset>",
      elro._brN or 0, elro._brPart or 0, elro._brSplit or 0, elro._brMissMax or 0, elro._brOverlap or 0,
      elro._brOne or 0))
    local _evO = (elro._lcEvT or 0) - (elro._evCoT or 0) - (elro._evOvT or 0) - (elro._evEdT or 0)
    -- ptHit = moved rooms rejected by cellPts; ownHit = stretched edges rejected against their own side
    cecho(string.format("\n<yellow>[time]   eval split: conflict-probe %.0fms (%d dist) | ov+occ %.0fms (%d clean, %d setRooms) | edges %.0fms (%d edgePairs) | other %.0fms<reset>",
      (elro._evCoT or 0) * 1000, elro._evDN or 0, (elro._evOvT or 0) * 1000,
      elro._evCN or 0, elro._evSetN or 0,
      (elro._evEdT or 0) * 1000, elro._evEdgN or 0, _evO * 1000))
    cecho(string.format("\n<yellow>[time]   eval symmetry: ptHit %d | ownHit %d<reset>",
      elro._lcPtHit or 0, elro._lcOwnHit or 0))
    cecho(string.format("\n<yellow>[time]   edges shape: rasterCells %d | eorCalls %d | eorScanned %d (%.1f per call)<reset>",
      elro._evRasN or 0, elro._evEorC or 0, elro._evEorS or 0,
      (elro._evEorC or 0) > 0 and (elro._evEorS or 0) / (elro._evEorC or 1) or 0))
    local eo, oparts = elro._evOut or {}, {}
    for _, k in ipairs({ "clean", "cascade", "none" }) do
      if eo[k] then oparts[#oparts + 1] = k .. "=" .. eo[k] end
    end
    cecho(string.format("\n<yellow>[time]   eval outcomes: %s | clean-checks failed at occ %d, at edges %d<reset>",
      #oparts > 0 and table.concat(oparts, " ") or "(none)",
      elro._evFO or 0, (elro._evFE or 0) - (elro._evFO or 0)))
    -- lag = distances past the first feasible one a clean result arrived (bucketed, not averaged)
    local lg, lparts = elro._evLag or {}, {}
    for _, k in ipairs({ "0", "1", "2", "3", "4", "5+" }) do
      if lg[k] then lparts[#lparts + 1] = "lag" .. k .. "=" .. lg[k] end
    end
    cecho(string.format("\n<yellow>[time]   clean-result lag past firstClear: %s (max %d) | wasted tail probes %d<reset>",
      #lparts > 0 and table.concat(lparts, " ") or "(no clean results)",
      elro._evLagMax or 0, elro._evWaste or 0))
  elro._tgOpen = nil            -- next canvas re-arms the reset
  end
  -- POST-WALK SWEEP: mop up residual conflicts one cheapest into-empty lever at a time.
  -- Off by default on the live walk (elro.walkSweep) so residuals stay where the walk put them.
  if branchSet == nil or elro.walkSweep then
    elro.tr("  walk_branches: -> sweep")
    local sg, triedC = 0, {}
    while sg < 60 do
      elro.bg_tick("sweep")     -- each sweep round is a whole-map conflict scan
      sg = sg + 1
      local cf = find_any_conflict()
      if not cf then break end
      -- oscillation guard: a recurring conflict stops the sweep
      local sig
      if cf.kind == "overlap" then sig = "o:" .. ekey(cf.A, cf.B)
      elseif cf.kind == "cross" then sig = "x:" .. ekey(cf.e1.u, cf.e1.v) .. "|" .. ekey(cf.e2.u, cf.e2.v)
      else sig = "r:" .. roomedge_key(cf.R, cf.e.u, cf.e.v) end
      if triedC[sig] then break end
      triedC[sig] = true
      local cands
      if cf.kind == "overlap" then cands = elro.cheapest_lever_overlap(coord, adj, cf.A, cf.B, branchSet)
      elseif cf.kind == "cross" then cands = elro.cheapest_lever(coord, adj, cf.e1, cf.e2, branchSet)
      else cands = elro.cheapest_lever_roomedge(coord, adj, cf.R, cf.e, branchSet) end
      local pick
      for _, c in ipairs(cands) do if c.intoEmpty then pick = c ; break end end
      if not pick then break end
      elro._walkPulls[#elro._walkPulls + 1] = { v = "sweep", kind = pick.kind, ek = pick.ek,
        dx = pick.dx, dy = pick.dy, dist = pick.dist, rooms = pick.rooms }
      for r in pairs(pick.set) do
        coord[r] = { coord[r][1] + pick.dx * pick.dist, coord[r][2] + pick.dy * pick.dist }
      end
      elro.step_snap(coord, "walk sweep: " .. cf.kind .. " resolved")
    end
  end
  -- residual report (live walk only): problem edges + leftover rooms, stashed in elro._walkResidual
  if branchSet ~= nil then
    local lo = {}
    for r in pairs(leftover) do lo[#lo + 1] = r end
    local nd, problist = 0, nil
    if type(getRoomExits) == "function" then
      nd, problist = elro.dash_problem_edges(coord, true)
      nd = nd or 0
    end
    elro._walkResidual = { leftover = lo, problems = problist or {} }
    elro.tr("  walk_branches: residual = " .. nd .. " problem edge(s), " ..
      #lo .. " leftover room(s)")
  end
  elro.step_snap(coord, "walk done" ..
    (next(leftover) and (" (" .. elro.tcount(leftover) .. " leftover)") or ""))
  -- expose the chord closure for the loop-cut stitch that runs on the same coord next
  elro._stitchTools = { qcl = query_cut_levers }
  elro._wbPhase = "between-walks"
  -- chunk report: name why an interior did not go in as a chunk
  if chunkOf and elro._faceChunks then
    local never = 0
    for i = 1, #elro._faceChunks do if not chunkDone[i] then never = never + 1 end end
    cecho(string.format("\n<cyan>[chunk] %d interior(s): %d snapped, %d already in place, %d refused"
      .. " (does not fit or worse), %d never had a finished container; %d placed AS A CHUNK when"
      .. " their face closed<reset>",
      #elro._faceChunks, elro._chunkN or 0, elro._chunkSame or 0, elro._chunkFail or 0, never,
      elro._chunkEarly or 0))
    -- per-walk counters reset here; the compose-wide totals accumulate
    elro._chunkTotEarly = (elro._chunkTotEarly or 0) + (elro._chunkEarly or 0)
    elro._chunkTotN = (elro._chunkTotN or 0) + (elro._chunkN or 0)
    elro._chunkTotFail = (elro._chunkTotFail or 0) + (elro._chunkFail or 0)
    elro._chunkTot = (elro._chunkTot or 0) + #elro._faceChunks
    elro._chunkN, elro._chunkSame, elro._chunkFail, elro._chunkEarly = 0, 0, 0, 0
  end
  return coord, leftover
end


-- Live: lay out one area and write it to Mudlet. No pcall on the background path: stock
-- Lua 5.1 cannot yield across a C-call boundary (LuaJIT can, so a local harness will not
-- reproduce this; test_bgcs.lua enforces it).
function elro.layout_eqw(areaID, space)
  if elro.bg_inside() then
    local coord = elro.compose_spqr(areaID, space)
    elro.write_compose(coord)
    return
  end
  local ok, coord = pcall(elro.compose_spqr, areaID, space)
  if not ok then error(coord, 0) end
  elro.write_compose(coord)
end
