-- Functions extracted from walk_branches (lua/walk.lua). Each takes the walk context table W,
-- populated by a shim in walk_branches at every call, and binds what it needs to locals.
-- Split out of walk.lua; see lua/modules.lua for the load order.

elro = elro or {}
local each_exit = elro.exits or error("eqw.lua: lua/core.lua must be loaded first")
local CLK = elro.clk or error("eqw.lua: lua/core.lua must be loaded first")
local TUNE = elro.TUNE or error("eqw.lua: lua/tune.lua must be loaded first")
local K = elro.k or error("eqw.lua: lua/keys.lua must be loaded first (see elro.modules)")
local ekey = K.edge

-- Truthfulness census over the placed graph: edges whose rendered direction disagrees with the
-- declared exit (a flipped or bent edge). Differential use only: repairs compare after - before.
-- The field form leaves an inequality behind when its far side is pinned, so a plate CAN walk a
-- room through its neighbour; the callers that rank plates (make-room, closure) price that here.
-- Returns the SET of untruthful directed edges (key r * 1000003 + x). A net count would let a
-- repair hide a new lie behind the one it fixes, so callers take `new_lies(base)`.
local function lie_set(coord, adj, placed, DELTA)
  local S = {}
  for r in pairs(placed) do
    local pr = coord[r]
    if pr then
      for d, x in each_exit(adj[r]) do
        local dE = DELTA[d]
        local px = coord[x]
        if placed[x] and px and dE and (dE[1] ~= 0 or dE[2] ~= 0) then
          local dx, dy = px[1] - pr[1], px[2] - pr[2]
          local ok
          if dE[1] ~= 0 and dE[2] ~= 0 then ok = (dx * dE[1] > 0 and dy * dE[2] > 0)
          elseif dE[1] ~= 0 then ok = (dy == 0 and dx * dE[1] >= 1)
          else ok = (dx == 0 and dy * dE[2] >= 1) end
          if not ok then S[r * 1000003 + x] = true end
        end
      end
    end
  end
  return S
end
local function new_lies(base, coord, adj, placed, DELTA)
  local n = 0
  for k in pairs(lie_set(coord, adj, placed, DELTA)) do
    if not base[k] then n = n + 1 end
  end
  return n
end
elro.lie_set, elro.new_lies = lie_set, new_lies

-- Cell index of the placed canvas: cell key -> room, or an ascending list where rooms share a cell
-- (a plate usually exists because two rooms do). Built once per build; the scans that ask "who is at
-- this cell" read it instead of walking the canvas.
function elro.placed_cells(placed, coord)
  local ix, lists = {}, nil
  for r in pairs(placed) do
    local pr = coord[r]
    if pr then
      local k = pr[1] * 1000003 + pr[2]
      local o = ix[k]
      if o == nil then ix[k] = r
      elseif type(o) == "table" then o[#o + 1] = r
      else
        local t = { o, r } ; ix[k] = t
        if lists then lists[#lists + 1] = t else lists = { t } end
      end
    end
  end
  if lists then for i = 1, #lists do table.sort(lists[i]) end end
  return ix
end
-- the lowest-id room standing at cell k (no displacement under `deltas`), or nil
function elro.standing_at(ix, k, deltas)
  local o = ix[k]
  if o == nil then return nil end
  if type(o) ~= "table" then return (not deltas[o]) and o or nil end
  for i = 1, #o do if not deltas[o[i]] then return o[i] end end
  return nil
end
-- Exact geometry check: the placed rooms' cells, compared on every entry (a few hundred table
-- reads). Structures cached on the generation it returns stay valid while it holds, and no site
-- that writes a coordinate has to know about them. The probes of one generator call restore the
-- canvas between builds, so their builds share one generation.
function elro.geo_gen(placed, coord, adj)
  local G = elro._geo
  if not G then G = { snap = {}, n = 0, gen = 0 } ; elro._geo = G end
  local snap, n, same = G.snap, 0, (G.adj == adj)
  if same then
    for r in pairs(placed) do
      local p = coord[r]
      if p then
        n = n + 1
        if snap[r] ~= p[1] * 1000003 + p[2] then same = false ; break end
      end
    end
  end
  if same and n == G.n then return G.gen end
  snap, n = {}, 0
  for r in pairs(placed) do
    local p = coord[r]
    if p then n = n + 1 ; snap[r] = p[1] * 1000003 + p[2] end
  end
  G.snap, G.n, G.gen, G.adj = snap, n, G.gen + 1, adj
  elro._placedIx, elro._edgeIx = nil, nil
  elro._geoRebuilds = (elro._geoRebuilds or 0) + 1
  return G.gen
end
-- Interior cells of the placed edges of length >= 2: cell key -> the edge as u * 1000003 + v, or an
-- ascending list where edges cross. Edges are the (u, v) with u < v and an exit u -> v, as the
-- reseed always enumerated them. Cached on the geometry generation.
function elro.edge_index(placed, coord, adj, DELTA)
  local ix, lists = {}, nil
  for r in pairs(placed) do
    local pr = coord[r]
    if pr then
      for d, x in each_exit(adj[r]) do
        local de = DELTA[d]
        if de and (de[1] ~= 0 or de[2] ~= 0) and r < x and placed[x] and coord[x] then
          local px = coord[x]
          local gx, gy = px[1] - pr[1], px[2] - pr[2]
          local h1 = (gx < 0) and -gx or gx
          local h2 = (gy < 0) and -gy or gy
          while h2 ~= 0 do h1, h2 = h2, h1 % h2 end
          if h1 > 1 then
            local ex, ey = gx / h1, gy / h1
            local ek = r * 1000003 + x
            for j = 1, h1 - 1 do
              local k = (pr[1] + j * ex) * 1000003 + (pr[2] + j * ey)
              local o = ix[k]
              if o == nil then ix[k] = ek
              elseif type(o) == "table" then o[#o + 1] = ek
              else
                local t = { o, ek } ; ix[k] = t
                if lists then lists[#lists + 1] = t else lists = { t } end
              end
            end
          end
        end
      end
    end
  end
  if lists then for i = 1, #lists do table.sort(lists[i]) end end
  return ix
end
-- eqw_forced_shift: shim mapping the old call shape onto `eqw_field_shift`'s seed map.
-- 2D returns (set, nMoved, deltas); 1D returns (set, nMoved); a void returns (nil, reason).
-- `s` may be a table {sx, sy} (2D; `pa` ignored). `encl`, `dtBlkIn` and (except for the room-on-edge
-- reseed) `pin` are dead arguments kept because call sites pass them. `capN` is a per-call plate
-- budget replacing TUNE.eqwShiftCap. `elro._cbLast`/`_sepLast`/`_fsCap`/`_fsAbsW` are no longer written.
function elro.eqw_forced_shift(W, cls, mem, pa, start, s, anchor, rigidDiag, seeds, encl, pin, occIn, capN, dtBlkIn)
  local DELTA, adj, coord, eqw_field_shift, placed, rigid_pendants = W.DELTA, W.adj, W.coord, W.eqw_field_shift, W.placed, W.rigid_pendants
  -- `detWho` attributes builds by caller line
  local _whoK, _who0
  if elro.detWho then
    local i = debug.getinfo(2, "l")
    _whoK = tostring(i and i.currentline or "?") ; _who0 = CLK()
    elro._fsWho = elro._fsWho or {} ; elro._fsWho[_whoK] = (elro._fsWho[_whoK] or 0) + 1
  end
  local function whoT()
    if _who0 then elro._fsWhoT = elro._fsWhoT or {} ; elro._fsWhoT[_whoK] = (elro._fsWhoT[_whoK] or 0) + (CLK() - _who0) end
  end
  local sm, sv = {}, (type(s) == "table") and { s[1], s[2] }
    or { (pa == 1) and s or 0, (pa == 2) and s or 0 }
  sm[start] = sv
  if seeds then for _, r in ipairs(seeds) do sm[r] = sv end end
  -- 1D -> the axis (a pass-1 union); 2D -> 0, the squareness loop. Both are `rigidDiag`.
  local rigidAxUsed = rigidDiag
    and ((type(s) == "table") and 0 or pa) or nil
  -- `pin` is forwarded for the room-on-edge reseed only
  local set, deltas, bad, nm = eqw_field_shift(cls, mem, sm, anchor, capN, occIn, start,
    rigidAxUsed, pin)
  -- Room-on-edge repair as a reseed: after the build, find rooms landing on translating edges (and
  -- moved rooms landing on stationary edges) and retry a fresh build with them seeded. One round,
  -- and it can never void the plate: a failed retry keeps the plate already built.
  if set and deltas then
    local _tre = elro.timeGuillo and CLK()
    -- up to three rounds: a retry can create the next incidence (a translated edge over a standing
    -- room, a mover on the next edge), and the plate is only repaired when a round finds none
    local reRound = 0
    while reRound < 3 do
    reRound = reRound + 1
    local vic = nil
    -- who stands at a cell after the move: a mover's destination, else the standing canvas
    local cellOf, md = W.cellOf, {}
    local movers = {}
    for r2 in pairs(set) do movers[#movers + 1] = r2 end
    table.sort(movers)
    for i2 = 1, #movers do
      local r2 = movers[i2]
      local p2, e2 = coord[r2], deltas[r2]
      md[(p2[1] + e2[1]) * 1000003 + (p2[2] + e2[2])] = r2
    end
    local function at(k)
      local m = md[k] ; if m then return m end
      return elro.standing_at(cellOf, k, deltas)
    end
    -- An edge is the (r2, x2) with r2 < x2 and an exit r2 -> x2, as it always was enumerated. Only
    -- the edges with a moved endpoint and the standing edges under a landing are looked at, so the
    -- work follows the plate: the standing edges come from the geometry's interior-cell index.
    local function edge_moved(r2, x2, pr)
            local du, dw = deltas[r2], deltas[x2]
            -- TRANSLATING only: both ends carried by the same displacement
            if du and dw and du[1] == dw[1] and du[2] == dw[2] then
              local px = coord[x2]
              local ax, ay = pr[1] + du[1], pr[2] + du[2]
              local bx, by = px[1] + dw[1], px[2] + dw[2]
              local gx, gy = bx - ax, by - ay
              local g1 = (gx < 0) and -gx or gx
              local g2 = (gy < 0) and -gy or gy
              while g2 ~= 0 do g1, g2 = g2, g1 % g2 end
              if g1 > 1 then
                local sx, sy = gx / g1, gy / g1
                for k2 = 1, g1 - 1 do
                  local cx, cy = ax + k2 * sx, ay + k2 * sy
                  local v2 = at(cx * 1000003 + cy)
                  if v2 and not deltas[v2] and v2 ~= r2 and v2 ~= x2 and v2 ~= pin
                     and v2 ~= anchor and v2 ~= start and not sm[v2] then
                    -- NEW incidences only: already on the PRE-shift segment is not ours
                    local qx, qy = px[1] - pr[1], px[2] - pr[2]
                    local tx, ty = coord[v2][1] - pr[1], coord[v2][2] - pr[2]
                    local pre = (qx * ty - qy * tx == 0)
                      and (tx * qx + ty * qy > 0) and (tx * tx + ty * ty < qx * qx + qy * qy)
                    if not pre then
                      vic = vic or {}
                      vic[v2] = { du[1], du[2] }
                    end
                  end
                end
              end
            end
    end
    -- edges with a moved endpoint: from the mover for r2 < x2; a lower-id standing neighbour's
    -- exits back to the mover are the (x2 -> mover) edges the canvas walk enumerated from x2
    for i2 = 1, #movers do
      elro.bg_tick("eqw-roe")      -- O(movers * deg) room-on-edge scan over the whole plate
      local r2 = movers[i2]
      local pr = coord[r2]
      for d2, x2 in each_exit(adj[r2]) do
        local de2 = DELTA[d2]
        if de2 and (de2[1] ~= 0 or de2[2] ~= 0) and placed[x2] and coord[x2] then
          if r2 < x2 then
            edge_moved(r2, x2, pr)
          elseif not deltas[x2] then
            local px = coord[x2]
            for d3, y3 in each_exit(adj[x2]) do
              local de3 = DELTA[d3]
              if y3 == r2 and de3 and (de3[1] ~= 0 or de3[2] ~= 0) then edge_moved(x2, r2, px) end
            end
          end
        end
      end
    end
    -- a moved room dragged onto a standing edge: seed one endpoint (the nearer one, ties by room id;
    -- never `pairs` order) at the moved room's displacement so the edge comes along
    local edgeIx = elro._edgeIx
    if not edgeIx then edgeIx = elro.edge_index(placed, coord, adj, DELTA) ; elro._edgeIx = edgeIx end
    local reSkip = nil          -- stepDebug: standing-edge endpoints the mirror could not seed
    local function mirror(r2, x2, mv1, mx, my)
      if deltas[r2] or deltas[x2] or mv1 == r2 or mv1 == x2 then return end
      local pr, px1 = coord[r2], coord[x2]
      local gx1, gy1 = px1[1] - pr[1], px1[2] - pr[2]
      local dmv = deltas[mv1]
      -- was it already on this edge BEFORE the move? then not ours to repair
      local c0 = coord[mv1]
      local t0x, t0y = c0[1] - pr[1], c0[2] - pr[2]
      local pre0 = (gx1 * t0y - gy1 * t0x == 0)
        and (t0x * gx1 + t0y * gy1 > 0)
        and (t0x * t0x + t0y * t0y < gx1 * gx1 + gy1 * gy1)
      if not pre0 then
        -- the whole edge takes the mover's displacement: seeding one endpoint only deforms the
        -- edge, and a mover that hit it broadside is still on it after the retry
        local any = false
        for _, pk in ipairs({ r2, x2 }) do
          if pk ~= pin and pk ~= anchor and pk ~= start and not sm[pk] then
            vic = vic or {}
            vic[pk] = { dmv[1], dmv[2] }
            any = true
          elseif elro.stepDebug then
            reSkip = reSkip or {}
            reSkip[#reSkip + 1] = string.format("%d@%d:%d %s", mv1, r2, x2,
              (pk == pin and "pin") or (pk == anchor and "anchor") or (pk == start and "start") or "seeded")
          end
        end
        if any then elro._ffReMir = (elro._ffReMir or 0) + 1 end
      end
    end
    for i2 = 1, #movers do
      local mv1 = movers[i2]
      local p2, e2 = coord[mv1], deltas[mv1]
      local mx, my = p2[1] + e2[1], p2[2] + e2[2]
      local o = edgeIx[mx * 1000003 + my]
      if type(o) == "table" then
        for j = 1, #o do
          local ek = o[j]
          local x2 = ek % 1000003
          mirror((ek - x2) / 1000003, x2, mv1, mx, my)
        end
      elseif o then
        local x2 = o % 1000003
        mirror((o - x2) / 1000003, x2, mv1, mx, my)
      end
    end
    if _tre then local F = elro._ffPh ; if not F then F = {} ; elro._ffPh = F end
      local a = F["reseed-scan"] ; if not a then a = { t = 0, n = 0 } ; F["reseed-scan"] = a end
      a.t = a.t + (CLK() - _tre) ; a.n = a.n + 1 end
    -- per-plate record for the mapstep trace (stepDebug): what the reseed saw and did
    if reRound == 1 then elro._ffReLast = nil end
    if reSkip then elro._ffReLast = (elro._ffReLast and (elro._ffReLast .. " ") or "") .. "reseed-skipped[" .. table.concat(reSkip, " ") .. "]" end
    if elro.stepDebug and not vic and not reSkip and reRound == 1 then
      local l = {}
      for i2 = 1, math.min(#movers, 8) do
        local r2 = movers[i2] ; local p2, e2 = coord[r2], deltas[r2]
        l[#l + 1] = string.format("%d@(%d,%d)", r2, p2[1] + e2[1], p2[2] + e2[2])
      end
      elro._ffReLast = "reseed-none land:" .. table.concat(l, " ")
    end
    if vic then
      local sm2 = {}
      for k2, v3 in pairs(sm) do sm2[k2] = v3 end
      local nv = 0
      for k2, v3 in pairs(vic) do sm2[k2] = v3 ; nv = nv + 1 end
      elro._ffReTry = (elro._ffReTry or 0) + 1
      elro._ffReSeeds = (elro._ffReSeeds or 0) + nv
      if elro.timeGuillo then   -- census: identical retry (seed map + anchor + geometry) seen before?
        local ks = {}
        for k2, v3 in pairs(sm2) do ks[#ks + 1] = k2 .. ":" .. v3[1] .. ":" .. v3[2] end
        table.sort(ks)
        local key = tostring(anchor) .. "|" .. tostring(elro._geo and elro._geo.gen) .. "|" .. table.concat(ks, ",")
        local M = elro._ffReMemo ; if not M then M = {} ; elro._ffReMemo = M end
        if M[key] then elro._ffReDup = (elro._ffReDup or 0) + 1 else M[key] = true end
      end
      local s2, d2, b2, n2 = eqw_field_shift(cls, mem, sm2, anchor, capN, occIn, start,
        rigidAxUsed, pin)
      if elro.stepDebug then
        local vs = {}
        for k2, v3 in pairs(vic) do vs[#vs + 1] = string.format("%d(%+d,%+d)", k2, v3[1], v3[2]) end
        table.sort(vs)
        elro._ffReLast = (elro._ffReLast and (elro._ffReLast .. " ") or "") .. string.format("reseed[%s] -> %s", table.concat(vs, " "),
          s2 and ("rebuilt " .. tostring(elro.tcount(s2)) .. "r") or ("VOID " .. tostring(b2) .. ", kept"))
      end
      if s2 then
        elro._ffReOK = (elro._ffReOK or 0) + 1
        set, deltas, bad, nm = s2, d2, b2, n2
        sm = sm2   -- the rigid-pendant rule below reads the seeds: the reseeded rooms are seeds now
        if reRound > 1 then elro._ffReRound2 = (elro._ffReRound2 or 0) + 1 end
      else
        elro._ffReKeep = (elro._ffReKeep or 0) + 1
        elro._ffReKeepWhy = elro._ffReKeepWhy or {}
        local kk = tostring(b2):gsub("@.*", "")
        elro._ffReKeepWhy[kk] = (elro._ffReKeepWhy[kk] or 0) + 1
        break
      end
    else
      break
    end
    end   -- reRound
  end
  whoT()
  elro._ffN = (elro._ffN or 0) + 1
  if not set then
    elro._ffVoid = (elro._ffVoid or 0) + 1
    elro._ffWhy = elro._ffWhy or {}
    local k = tostring(bad):gsub("@.*", "")
    elro._ffWhy[k] = (elro._ffWhy[k] or 0) + 1
    return nil, bad
  end
  -- The field form has no drag rule: it moves a room only when a constraint forces it. The rigid-pendant
  -- rule is the replacement: a seed-free subtree hanging off one bridge takes its anchor's displacement.
  -- Safe for the 1D contract (a pendant gets its anchor's `s`); runs before the non-uniformity audit.
  if rigid_pendants then
    local seedF = {}
    for r in pairs(sm) do seedF[r] = true end
    if anchor then seedF[anchor] = true end
    rigid_pendants(set, deltas, seedF, "field")
    nm = 0 ; for _ in pairs(set) do nm = nm + 1 end
  end
  -- Zero-stretch absorption. A connected set of stationary placed rooms whose every placed
  -- neighbour outside it is a mover with ONE shared displacement rides along by that displacement:
  -- every edge into it keeps its length, where leaving it stretches each of those edges. The
  -- pendant rule is the case where the set hangs by a single bridge; this is the same rule for a
  -- set the plate encloses (an arc of a ring both of whose ends moved). Never the anchor's set,
  -- never a set bigger than the plate (that is the map, not an arc), and never onto a cell a
  -- stationary room holds.
  if set then
    local cellOf = elro._placedIx
    local seen = {}
    local cand = {}
    for r in pairs(set) do
      elro.bg_tick("eqw-cand")     -- O(|set| * deg) over the whole plate
      for _, x in each_exit(adj[r]) do
        if placed[x] and coord[x] and not set[x] and not seen[x] then seen[x] = true ; cand[#cand + 1] = x end
      end
    end
    table.sort(cand)
    local done = {}
    local nAbs = 0
    for i = 1, #cand do
      elro.bg_tick("eqw-absorb")   -- floods a stationary component per candidate: O(cand * E)
      local r0 = cand[i]
      if not done[r0] and not set[r0] then
        -- flood the stationary component from r0
        local comp, q, h, ok, dx, dy = {}, { r0 }, 1, true, nil, nil
        done[r0] = true
        while h <= #q do
          local r = q[h] ; h = h + 1
          comp[#comp + 1] = r
          if r == anchor then ok = false end
          for _, x in each_exit(adj[r]) do
            if placed[x] and coord[x] then
              if set[x] then
                local d = deltas[x]
                if dx == nil then dx, dy = d[1], d[2]
                elseif d[1] ~= dx or d[2] ~= dy then ok = false end
              elseif not done[x] then done[x] = true ; q[#q + 1] = x end
            end
          end
          if #comp > nm then ok = false ; break end
        end
        if ok and dx ~= nil then
          -- landing: no stationary occupant on any target cell
          for _, r in ipairs(comp) do
            local p = coord[r]
            local occ = cellOf and cellOf[(p[1] + dx) * 1000003 + (p[2] + dy)]
            if occ then
              if type(occ) == "table" then
                for _, o in ipairs(occ) do if not set[o] and o ~= r then ok = false end end
              elseif not set[occ] and occ ~= r then ok = false end
            end
            if not ok then break end
          end
        end
        if ok and dx ~= nil then
          for _, r in ipairs(comp) do set[r] = true ; deltas[r] = { dx, dy } end
          nAbs = nAbs + #comp
        end
      end
    end
    if nAbs > 0 then
      nm = 0 ; for _ in pairs(set) do nm = nm + 1 end
      elro._ffAbsorb = (elro._ffAbsorb or 0) + 1 ; elro._ffAbsorbN = (elro._ffAbsorbN or 0) + nAbs
    end
  end
  if type(s) == "table" then return set, nm, deltas end
  -- the 1D return contract is a membership set applied uniformly with `s`; count how many field results were non-uniform
  local nonuni = 0
  for r in pairs(set) do
    local d = deltas[r]
    if d[pa] ~= s or d[3 - pa] ~= 0 then nonuni = nonuni + 1 end
  end
  if nonuni > 0 then
    elro._ffNonUni = (elro._ffNonUni or 0) + 1
    elro._ffNonUniR = (elro._ffNonUniR or 0) + nonuni
    -- (and voiding these for a 45-RIGID call specifically -- on the theory that uniform
  end
  elro._ffOneD = (elro._ffOneD or 0) + 1
  return set, nm
end

-- eqw_field_shift: the plate as a field solve. Takes a seed map (room -> displacement) and closes
-- once. Three constraint kinds: EQUALITY (classes from eqw_classes plus real axial edges),
-- INEQUALITY (min_len and accepted-crossing bounds, `u[p] - u[q] >= c`, never a clash), and DRAG,
-- which is just the inequality relaxation. Only what is forced moves; bounded rounds bail `no-fixpoint`.
-- Pass-1 partition cache: sound only where `rigidAx` is unset (a rigid build reads coordinate values
-- and the 2D squareness pass mutates `par`). `blkIn` = { [axis] = { [room] = true } } classes to leave behind.
function elro.eqw_field_shift(W, cls, mem, seeds, anchorR, capN, occIn, start0, rigidAx, pinIn, blkIn)
  local DELTA, adj, coord, crossing_bounds, placed = W.DELTA, W.adj, W.coord, W.crossing_bounds, W.placed
  -- phase timers (timeGuillo)
  local _ffP = elro.timeGuillo and function(k, t0)
    local F = elro._ffPh ; if not F then F = {} ; elro._ffPh = F end
    local a = F[k] ; if not a then a = { t = 0, n = 0 } ; F[k] = a end
    a.t = a.t + (CLK() - t0) ; a.n = a.n + 1
  end or nil
  local _p0 = _ffP and CLK()
  local C1, C2, M1, M2 = cls[1], cls[2], mem[1], mem[2]
  local u = { {}, {} }                 -- axis -> class -> displacement
  local pin = { {}, {} }               -- axis -> class -> seeded/anchored, may not be re-decided
  local XB = crossing_bounds()
  local CAP = capN or TUNE.eqwShiftCap
  -- Pass 1: equalities only, built from the real edges starting from the caller's partition (which
  -- carries unplaced-room conduits), honouring the caller's exclusions (the closure edge and every edge
  -- incident to the room under repair) or the repair is undone. Inequalities still walk every real edge.
  local _ex = elro._ecExOf and elro._ecExOf[cls]
  local exA0, exB0, exR = nil, nil, nil
  if _ex then exA0, exB0, exR = _ex.a, _ex.b, _ex.r end
  local par = { {}, {} }
  -- the slot lives on `elro`: the enclosing function is at LuaJIT's 200-local ceiling
  local _p1 = elro._ffP1Slot ; if not _p1 then _p1 = {} ; elro._ffP1Slot = _p1 end
  -- Cache keyed (cls, _bfGen, placed count) -> (start0, anchorR) slots; cleared whole on overflow (never
  -- LRU: `pairs` order is per-process). A rigid build copies the base partition and never stores its own.
  local _p1np, _p1hit, _p1key, _p1adj = nil, false, nil, false   -- `_p1key` holds the HIT ENTRY, not a key
  do
    local np = 0 ; for _ in pairs(placed) do np = np + 1 end
    if not rigidAx then _p1np = np end
    if not (_p1.cls == cls and _p1.gen == (elro._bfGen or 0) and _p1.np == np) then
      _p1.cls, _p1.gen, _p1.np = cls, elro._bfGen or 0, np
      _p1.slots, _p1.n = {}, 0
    end
    -- The (start0, anchorR) exclusion below only bites on an axial placed edge between the two
    -- (a diagonal unions nothing); every other pair builds the same partition, so it shares one slot.
    local adjAx = {}                 -- the axis (or axes) the excluded edge would have unioned
    if start0 and anchorR and coord[start0] and coord[anchorR] then
      for d, x in each_exit(adj[start0]) do
        local de = DELTA[d]
        if x == anchorR and de and (de[1] == 0) ~= (de[2] == 0) then _p1adj = true ; adjAx[(de[1] == 0) and 1 or 2] = true end
      end
      for d, x in each_exit(adj[anchorR]) do
        local de = DELTA[d]
        if x == start0 and de and (de[1] == 0) ~= (de[2] == 0) then _p1adj = true ; adjAx[(de[1] == 0) and 1 or 2] = true end
      end
    end
    -- nested tables, not a concatenated string key (allocation on the hottest path)
    local s1 = _p1.slots[_p1adj and start0 or false]
    local e = s1 and s1[_p1adj and anchorR or false]
    -- An excluded edge changes exactly one class on the axis it would have unioned: derive that
    -- partition from the shared base by resetting the class and re-unioning it without the edge.
    -- Every other class, and the other axis, stay shared with the base.
    -- A closure per call (it reads this call's start/anchor/axes); kept on `_p1`, not a local:
    -- the enclosing function is at LuaJIT's 200-local ceiling.
    _p1.derive = function(b0)
      local e = { p1 = b0.p1, p2 = b0.p2, l1 = b0.l1, l2 = b0.l2 }
      for a2 = 1, 2 do
        if adjAx[a2] then
          local P0, L0 = (a2 == 1) and b0.p1 or b0.p2, (a2 == 1) and b0.l1 or b0.l2
          local P, L = {}, {}
          for k, x in pairs(P0) do P[k] = x end
          for k, x in pairs(L0) do L[k] = x end
          local function fd(r)
            local x = P[r] ; if x == nil then P[r] = r ; return r end
            while P[x] ~= x do P[x] = P[P[x]] ; x = P[x] end
            P[r] = x ; return x
          end
          local function un(r, x) local ra, rb = fd(r), fd(x) ; if ra ~= rb then P[ra] = rb end end
          local Ca = (a2 == 1) and C1 or C2
          local rK = fd(start0)
          local members = L[rK] or { rK }
          -- the class: its placed members plus the unplaced conduits they union through
          local inK, nodes = {}, {}
          for _, m in ipairs(members) do inK[m] = true ; nodes[#nodes + 1] = m end
          for _, m in ipairs(members) do
            local c = Ca[m] ; if c and not inK[c] then inK[c] = true ; nodes[#nodes + 1] = c end
          end
          for _, m in ipairs(nodes) do P[m] = m end
          table.sort(nodes)
          for _, r in ipairs(nodes) do
            if placed[r] then local c = Ca[r] ; if c and c ~= r then un(r, c) end end
          end
          for _, r in ipairs(nodes) do
            if placed[r] and coord[r] and r ~= exR then
              for d, x in each_exit(adj[r]) do
                local de = DELTA[d]
                if de and (de[1] ~= 0 or de[2] ~= 0) and de[a2] == 0 and inK[x] and placed[x] and coord[x]
                   and x ~= exR
                   and not ((r == exA0 and x == exB0) or (r == exB0 and x == exA0))
                   and not ((r == start0 and x == anchorR) or (r == anchorR and x == start0)) then
                  un(r, x)
                end
              end
            end
          end
          L[rK] = nil
          for _, m in ipairs(members) do
            local c = fd(m) ; local t = L[c] ; if t then t[#t + 1] = m else L[c] = { m } end
          end
          if a2 == 1 then e.p1, e.l1 = P, L else e.p2, e.l2 = P, L end
        end
      end
      elro._ffP1Derive = (elro._ffP1Derive or 0) + 1
      if _p1.n >= (TUNE.eqwPass1Slots or 12) then _p1.slots, _p1.n = {}, 0 end
      local sd = _p1.slots[start0] ; if not sd then sd = {} ; _p1.slots[start0] = sd end
      sd[anchorR] = e ; _p1.n = _p1.n + 1
      return e
    end
    if not e and _p1adj then
      local b0 = _p1.slots[false] ; b0 = b0 and b0[false]
      if b0 then e = _p1.derive(b0) end
    end
    if e then
      _p1key = e
      if rigidAx then
        local d1, d2 = {}, {}
        for k, x in pairs(e.p1) do d1[k] = x end
        for k, x in pairs(e.p2) do d2[k] = x end
        par[1], par[2] = d1, d2
        elro._ffP1Copy = (elro._ffP1Copy or 0) + 1
      else
        _p1hit = true ; par[1], par[2] = e.p1, e.p2
      end
    end
  end
  local function find(a, r)
    local pa2 = par[a]
    local x = pa2[r] ; if x == nil then pa2[r] = r ; return r end
    while pa2[x] ~= x do pa2[x] = pa2[pa2[x]] ; x = pa2[x] end
    pa2[r] = x
    return x
  end
  local function union(a, r, x)
    local ra, rb = find(a, r), find(a, x)
    if ra ~= rb then par[a][ra] = rb end
  end
  -- one traversal, both axes; the two phases (`cls` first, then real edges) decide the roots and may not be merged
  if not _p1key then
  for r in pairs(placed) do
    local c1 = C1[r] ; if c1 and c1 ~= r then union(1, r, c1) end
    local c2 = C2[r] ; if c2 and c2 ~= r then union(2, r, c2) end
  end
  for r in pairs(placed) do
    if coord[r] and r ~= exR then
      for d, x in each_exit(adj[r]) do
        local de = DELTA[d]
        if de and (de[1] ~= 0 or de[2] ~= 0) and placed[x] and coord[x]
           and x ~= exR
           and not ((r == exA0 and x == exB0) or (r == exB0 and x == exA0))
           -- with an effective exclusion this builds the BASE (no exclusion) and derives from it below
           and (_p1adj or not ((r == start0 and x == anchorR) or (r == anchorR and x == start0))) then
          -- an edge axial across an axis pins that axis; a diagonal pins neither
          if de[1] == 0 then union(1, r, x) elseif de[2] == 0 then union(2, r, x) end
        end
      end
    end
  end
  end
  if not _p1key and _p1adj then
    -- the base was just built (exclusion off): store it, then derive this call's partition
    local L1, L2 = {}, {}
    for r in pairs(placed) do
      local c = find(1, r)
      local t = L1[c] ; if t then t[#t + 1] = r else L1[c] = { r } end
      c = find(2, r)
      t = L2[c] ; if t then t[#t + 1] = r else L2[c] = { r } end
    end
    local b0 = { p1 = par[1], p2 = par[2], l1 = L1, l2 = L2 }
    if _p1.n >= (TUNE.eqwPass1Slots or 12) then _p1.slots, _p1.n = {}, 0 end
    local s0 = _p1.slots[false] ; if not s0 then s0 = {} ; _p1.slots[false] = s0 end
    s0[false] = b0 ; _p1.n = _p1.n + 1
    local e = _p1.derive(b0)
    _p1key = e
    if rigidAx then
      local d1, d2 = {}, {}
      for k, x in pairs(e.p1) do d1[k] = x end
      for k, x in pairs(e.p2) do d2[k] = x end
      par[1], par[2] = d1, d2
    else
      _p1hit = true ; par[1], par[2] = e.p1, e.p2
    end
  end
  -- 1D 45-preservation: a square truthful diagonal is unioned on the moving axis so its ends move
  -- together. A seed beats the lock (two differently-seeded classes are not welded), and the anchor's
  -- class may not grow. 1D only; 2D uses the squareness pass below. Sorted seed order for determinism.
  if rigidAx and rigidAx > 0 then
    elro._sq1N = (elro._sq1N or 0) + 1
    local a = rigidAx
    local pv = {}                      -- class root -> the displacement already demanded on `a`
    local anchorC = anchorR and find(a, anchorR) or nil
    if anchorC then pv[anchorC] = 0 end
    do
      local sr = {}
      for r in pairs(seeds) do sr[#sr + 1] = r end
      table.sort(sr)
      for i = 1, #sr do
        local c = find(a, sr[i])
        if pv[c] == nil then pv[c] = seeds[sr[i]][a] end
      end
    end
    for r in pairs(placed) do
      local pr = coord[r]
      if pr and r ~= exR then
        for d, x in each_exit(adj[r]) do
          local de = DELTA[d]
          if de and de[1] ~= 0 and de[2] ~= 0 and placed[x] and coord[x]
             and x ~= exR
             and not ((r == exA0 and x == exB0) or (r == exB0 and x == exA0))
             and not ((r == start0 and x == anchorR) or (r == anchorR and x == start0)) then
            local gap = coord[x][a] - pr[a]
            local perp = coord[x][3 - a] - pr[3 - a]
            if (gap == perp or gap == -perp) and not (elro._gxFree and elro._gxDiag(r, x)) then
              if gap * de[a] >= 1 and perp * de[3 - a] >= 1 then
                local cr, cx = find(a, r), find(a, x)
                local vr, vx = pv[cr], pv[cx]
                if cr ~= cx and anchorC and (cr == anchorC or cx == anchorC) then
                  elro._rigAnchSkip = (elro._rigAnchSkip or 0) + 1
                elseif cr ~= cx and vr ~= nil and vx ~= nil and vr ~= vx then
                  elro._rigSeedSkip = (elro._rigSeedSkip or 0) + 1
                else
                  union(a, r, x)
                  local nc = find(a, r)
                  if pv[nc] == nil then pv[nc] = (vr ~= nil) and vr or vx end
                end
              end
            end
          end
        end
      end
    end
  end
  local LM = { {}, {} }
  local function build_LM()
    LM[1], LM[2] = {}, {}
    local L1, L2 = LM[1], LM[2]      -- one traversal, both axes; per-axis append order unchanged
    for r in pairs(placed) do
      local c = find(1, r)
      local t = L1[c] ; if t then t[#t + 1] = r else L1[c] = { r } end
      c = find(2, r)
      t = L2[c] ; if t then t[#t + 1] = r else L2[c] = { r } end
    end
  end
  if _p1hit then
    LM[1], LM[2] = _p1key.l1, _p1key.l2
    elro._ffP1Hit = (elro._ffP1Hit or 0) + 1
  else
    build_LM()
    elro._ffP1Miss = (elro._ffP1Miss or 0) + 1
    if _p1np then
      if _p1.n >= (TUNE.eqwPass1Slots or 12) then _p1.slots, _p1.n = {}, 0 end
      local k1 = _p1adj and start0 or false
      local s1 = _p1.slots[k1] ; if not s1 then s1 = {} ; _p1.slots[k1] = s1 end
      s1[_p1adj and anchorR or false] = { p1 = par[1], p2 = par[2], l1 = LM[1], l2 = LM[2] }
      _p1.n = _p1.n + 1
    end
  end
  local function mem_of(a, c) return LM[a][c] or { c } end
  local function amt(a, c) return u[a][c] or 0 end
  -- the anchor is pinned at 0 on both axes; pinBy records who pinned a class for the void message
  local pinBy = { {}, {} }
  if anchorR then
    for a = 1, 2 do local c = find(a, anchorR) ; u[a][c] = 0 ; pin[a][c] = true
      pinBy[a][c] = "anchor " .. anchorR end
  end
  for r, d in pairs(seeds) do
    for a = 1, 2 do
      local c = find(a, r)
      if pin[a][c] and (u[a][c] or 0) ~= d[a] then
        return nil, nil, string.format("seed-clash@%d:ax%d", r, a)
      end
      u[a][c] = d[a] ; pin[a][c] = true
      if pinBy[a][c] == nil then pinBy[a][c] = "seed " .. r end
    end
  end
  -- The plate's direction per axis (the sign every seed shares; false when the seeds disagree, nil
  -- when none moves on that axis). A violated inequality is never repaired by moving a class
  -- AGAINST that direction while the other end can still move along it: the relaxation is
  -- order-dependent otherwise, and a repair toward zero can undo a push a pinned class demanded,
  -- leaving only the pinned side to give (mael 309:w2 -- 1121 relaxed first raised 1034 back).
  local monoDir = { nil, nil }
  for _, d in pairs(seeds) do
    for a = 1, 2 do
      if d[a] ~= 0 then
        local sgn = (d[a] > 0) and 1 or -1
        if monoDir[a] == nil then monoDir[a] = sgn
        elseif monoDir[a] ~= sgn then monoDir[a] = false end
      end
    end
  end
  -- fieldWatch: this build's seed map, so lines from different builds in one step tell apart
  local wTag
  if elro.fieldWatch then
    local t = {}
    for r, d in pairs(seeds) do t[#t + 1] = string.format("%d(%+d,%+d)", r, d[1], d[2]) end
    table.sort(t)
    wTag = "build[" .. table.concat(t, " ") .. (anchorR and (" anchor " .. anchorR) or "") .. "]"
  end
  local geo = elro.geo_gen(placed, coord, adj)
  local cellOf = elro._placedIx
  if not cellOf then cellOf = elro.placed_cells(placed, coord) ; elro._placedIx = cellOf end
  W.cellOf, W.geoGen = cellOf, geo
  -- `blkIn`: leave these classes behind by pinning them at 0 (the field form's only reading of 'do not
  -- drag'). Strictly stronger than the old optional-drag block: a forced class voids. Sorted order,
  -- keyed by room (a caller class id does not name a class in here).
  if blkIn then
    for a = 1, 2 do
      local t = blkIn[a]
      if t then
        local rs = {}
        for r in pairs(t) do rs[#rs + 1] = r end
        table.sort(rs)
        for i = 1, #rs do
          local r = rs[i]
          local c = find(a, r)
          if pin[a][c] and (u[a][c] or 0) ~= 0 then
            return nil, nil, string.format("blk-clash@%d:ax%d held by %s", r, a,
              tostring(pinBy[a][c] or "?"))
          end
          u[a][c] = 0 ; pin[a][c] = true
          if pinBy[a][c] == nil then pinBy[a][c] = "no-drag " .. r end
        end
      end
    end
  end
  if _ffP then _ffP("pass1(eq union + LM)", _p0) end
  -- measurement only (`probeField`): would a pass-1 cache hit?
  if elro.probeField then
    local k = tostring(cls) .. "|" .. (elro._bfGen or 0) .. "|" .. tostring(start0)
      .. "|" .. tostring(anchorR) .. "|" .. tostring(rigidAx)
    local H = elro._ffKey ; if not H then H = {} ; elro._ffKey = H end
    if H[k] then elro._ffKeyHit = (elro._ffKeyHit or 0) + 1
    else H[k] = true ; elro._ffKeyMiss = (elro._ffKeyMiss or 0) + 1 end
    if not rigidAx then
      local H2 = elro._ffKey0 ; if not H2 then H2 = {} ; elro._ffKey0 = H2 end
      if H2[k] then elro._ffKey0Hit = (elro._ffKey0Hit or 0) + 1
      else H2[k] = true ; elro._ffKey0Miss = (elro._ffKey0Miss or 0) + 1 end
      if elro._ffLast == k then elro._ffLastHit = (elro._ffLastHit or 0) + 1
      else elro._ffLast = k ; elro._ffLastMiss = (elro._ffLastMiss or 0) + 1 end
    end
  end
  -- work queue (Bellman-Ford with a queue): a constraint is re-checked only when one of its classes moved
  local Q, qh, inQ, steps, work = {}, 1, {}, 0, 0
  local LIM = 40 * (CAP + 8)
  local nPart = 0                      -- constraints left behind because the far side is pinned
  local function push_cls(a, c)
    local k = a * 16777216 + c
    if not inQ[k] then inQ[k] = true ; Q[#Q + 1] = { a, c, k } end
  end
  -- narrow `c` to at least/at most `v`. Returns changed, or nil when the far side is pinned; a pinned
  -- far side is not a void, the edge is left behind and priced as a defect.
  local leftBehind = { {}, {} }        -- axis -> class -> true: a constraint on it was not applied
  local wR, wX                         -- the edge being relaxed (fieldWatch)
  local function want(a, c, v, lower)
    local cur = u[a][c] or 0
    if lower then if cur >= v then return false end else if cur <= v then return false end end
    -- fieldWatch (PROBES, a room id or a list): every narrowing of a watched room's class, with the
    -- edge that asked for it. Into the mapstep frame, never the console: a line without its step
    -- cannot be related to anything.
    if elro.fieldWatch then
      local wl = (type(elro.fieldWatch) == "table") and elro.fieldWatch or { elro.fieldWatch }
      for _, wr in ipairs(wl) do
        if find(a, wr) == c then
          local pnd = elro._closeTracePending or {} ; elro._closeTracePending = pnd
          pnd[#pnd + 1] = string.format("<magenta>  [fieldwatch] %s ax%d class(%d) %d -> %d (at %s) via %s-%s%s<reset>",
            tostring(wTag), a, wr, cur, v, lower and "least" or "most", tostring(wR), tostring(wX),
            pin[a][c] and ("  PINNED " .. tostring(pinBy[a][c] or "?") .. " -> left behind") or "")
        end
      end
    end
    if pin[a][c] then leftBehind[a][c] = true ; return nil end
    u[a][c] = v
    push_cls(a, c)
    return true
  end
  -- the partial escape is allowed only when the left-behind class is a pendant: a room in a biconnected block is structure
  local rigidSet
  local function rigid_rooms()
    if rigidSet then return rigidSet end
    local np = 0 ; for _ in pairs(placed) do np = np + 1 end
    -- cached on `_bfGen` + `adj`, which identify the decomposition exactly
    if elro._ffRigCache and elro._ffRigGen == (elro._bfGen or 0) and elro._ffRigAdj == adj then
      rigidSet = elro._ffRigCache ; return rigidSet
    end
    local roomsL, radj = {}, {}
    for r in pairs(placed) do roomsL[#roomsL + 1] = r end
    table.sort(roomsL)
    for _, r in ipairs(roomsL) do
      radj[r] = {}
      for d, v in each_exit(adj[r]) do
        local de = DELTA[d]
        if placed[v] and de and (de[1] ~= 0 or de[2] ~= 0) then radj[r][d] = v end
      end
    end
    -- OPEN BUG: `blocks_adj` returns blocks as lists of {u, v} edge pairs, so `rg[m]` here stores a
    -- table key and the pendant gate in fail() never matches. Not fixed: it is a behaviour change.
    local rg = {}
    for _, comp in ipairs(elro.blocks_adj(roomsL, radj)) do
      if #comp > 1 then for _, m in ipairs(comp) do rg[m] = true end end
    end
    elro._ffRigCache, elro._ffRigGen, elro._ffRigAdj = rg, elro._bfGen or 0, adj
    rigidSet = rg
    return rg
  end
  -- `hard` = a constraint that may NEVER be left behind. An accepted crossing is one: preserving
  -- it is the point, and a build that cannot is a build that must not exist.
  local function fail(a, c, hard, fmt, ...)
    if hard then return string.format(fmt, ...) end
    local rg = rigid_rooms()
    for _, m in ipairs(mem_of(a, c)) do
      if rg[m] then return string.format(fmt, ...) end
    end
    nPart = nPart + 1
    return nil
  end
  -- one room's constraints on one axis: equality (axial across), inequality (along: sign + minimum; an accepted crossing keeps its side)
  local function relax_room(a, r)
    local pr = coord[r] ; if not pr then return nil end
    local ua = u[a]                    -- `amt(a, c)` inlined: this is the walk's innermost loop
    local cr = find(a, r)
    local ur = ua[cr] or 0
    for d, x in each_exit(adj[r]) do
      local de = DELTA[d]
      if de and (de[1] ~= 0 or de[2] ~= 0) and placed[x] and coord[x] then
        local skip = (r == start0 and x == anchorR) or (r == anchorR and x == start0)
        local cx = find(a, x)
        if not skip and cx ~= cr then
          local sg = de[a]
          if sg ~= 0 then
            local g = coord[x][a] - pr[a]
            -- a diagonal's minimum is on its length, not each component; per axis it owes only sign and >= 1
            local m = elro.min_len(r, x)
            if de[1] ~= 0 and de[2] ~= 0 and m > 1 then m = 1 end
            if sg * g >= m then                -- only a currently-legal edge constrains
              local ux = ua[cx] or 0
              if sg * (g + ux - ur) < m then
                wR, wX = r, x
                local ch
                -- narrowing x here would move it against the plate's direction (an "at least" in a
                -- westward plate raises x back east); push r's own class further along the direction
                -- instead, and fall back to x only when r's class is pinned
                local md = monoDir[a]
                if md and ((sg > 0 and md < 0) or (sg < 0 and md > 0)) then
                  wR, wX = x, r
                  ch = want(a, cr, (sg > 0) and (ux + g - m) or (ux + g + m), sg < 0)
                  if ch then ur = ua[cr] or 0 end
                  if ch == nil then wR, wX = r, x ; ch = want(a, cx, (sg > 0) and (ur + m - g) or (ur - m - g), sg > 0) end
                else
                  ch = want(a, cx, (sg > 0) and (ur + m - g) or (ur - m - g), sg > 0)
                end
                if ch == nil then
                  -- never leave a diagonal behind: a diagonal that loses a component flattens into a lie
                  local e = fail(a, cx, de[1] ~= 0 and de[2] ~= 0, "lock@%d-%d:ax%d", r, x, a)
                  if e then return e end
                end
              end
            end
          end
        end
      end
    end
    local bl = XB and XB[r]
    if bl then
      for i = 1, #bl do
        local b = bl[i]
        if b[3] == a then
          local hi, lo = b[1], b[2]
          local ch2, cl2 = find(a, hi), find(a, lo)
          if ch2 ~= cl2 and coord[hi] and coord[lo] then
            local g = coord[hi][a] - coord[lo][a]
            if g >= 1 then                     -- only a bound that currently HOLDS constrains
              local uh, ul = ua[ch2] or 0, ua[cl2] or 0
              if g + uh - ul < 1 then
                local ch
                local cRef
                if r == hi then cRef = cl2 ; ch = want(a, cl2, uh + g - 1, false)
                else cRef = ch2 ; ch = want(a, ch2, ul + 1 - g, true) end
                if ch == nil then
                  local e = fail(a, cRef, true, "lock-cross@%d-%d:ax%d", hi, lo, a)
                  if e then return e end
                end
              end
            end
          end
        end
      end
    end
    return nil
  end
  -- the separation pass re-relaxes from what it absorbed (seeds are (axis, room) pairs), not from all
  -- of `u`. Complete only because the constraint graph is symmetric: sources of one-way exits are
  -- pushed unconditionally (list built once per `adj`, sorted since `pairs(adj)` is hash order).
  local function relax_i(seed)
    Q, qh, inQ = {}, 1, {}
    if seed then
      for i = 1, #seed, 2 do
        local r = seed[i + 1]
        if placed[r] and coord[r] then push_cls(seed[i], find(seed[i], r)) end
      end
      local OW = elro._owCache
      if not OW then OW = setmetatable({}, { __mode = "k" }) ; elro._owCache = OW end
      local ow = OW[adj]
      if not ow then
        ow = {}
        local REV = elro.reverse
        for r, row in pairs(adj) do
          for d, x in each_exit(row) do
            local de = DELTA[d]
            if de and (de[1] ~= 0 or de[2] ~= 0) then
              local rv = REV[d]
              if not (rv and adj[x] and adj[x][rv] == r) then ow[#ow + 1] = r ; break end
            end
          end
        end
        table.sort(ow)                 -- `pairs(adj)` is hash order; the list must not be
        OW[adj] = ow
      end
      for i = 1, #ow do
        local r = ow[i]
        if placed[r] and coord[r] then push_cls(1, find(1, r)) ; push_cls(2, find(2, r)) end
      end
    else
    for a = 1, 2 do
      for c in pairs(u[a]) do push_cls(a, c) end
    end
    end
    while qh <= #Q do
      local t = Q[qh] ; qh = qh + 1
      inQ[t[3]] = nil
      steps = steps + 1
      if steps > LIM then return "no-fixpoint" end
      for _, r in ipairs(mem_of(t[1], t[2])) do
        if placed[r] then
          -- Counts ROOMS RELAXED, not queue pops. `steps` bounds nothing for a frame: one pop
          -- relaxes a whole class, so a single pop on a large class already overruns. `steps`
          -- keeps its own meaning as the no-fixpoint guard above -- do not merge the two.
          work = work + 1
          if (work % 256) == 0 then elro.bg_tick("eqw-field") end
          local e = relax_room(t[1], r)
          if e then return e end
        end
      end
    end
    return nil
  end
  local function relax(...)
    if not _ffP then return relax_i(...) end
    local t0 = CLK() ; local e = relax_i(...) ; _ffP("relax queue", t0) ; return e
  end
  -- collect from `u`, not from `placed`: movers are the members of non-zero classes
  local function collect_i()
    local st, dl, n2 = {}, {}, 0
    local u1, u2 = u[1], u[2]          -- `amt`/`cls_of` inlined: four Lua calls per moved room
    for a = 1, 2 do
      for c, v in pairs(u[a]) do
        if v ~= 0 then
          for _, r in ipairs(mem_of(a, c)) do
            if placed[r] and coord[r] and not st[r] then
              local dx, dy = u1[find(1, r)] or 0, u2[find(2, r)] or 0
              if dx ~= 0 or dy ~= 0 then
                n2 = n2 + 1
                if n2 > CAP then return nil, "cap" end
                st[r] = true ; dl[r] = { dx, dy }
              end
            end
          end
        end
      end
    end
    return st, dl, n2
  end
  local function collect(...)
    if not _ffP then return collect_i(...) end
    local t0 = CLK() ; local a, b, c = collect_i(...) ; _ffP("collect", t0) ; return a, b, c
  end
  local why = relax()
  if why then return nil, nil, why end
  -- 2D squareness pass: keep square truthful diagonals square after both components move; iterates
  -- since it depends on the answer. Merging reconciles displacements: both pinned at different values
  -- is `lock-square`; a single pinned side wins; otherwise the larger magnitude. Sorted room order.
  if rigidAx == 0 then
    elro._sqN = (elro._sqN or 0) + 1
    local roomsL = {}
    for r in pairs(placed) do if coord[r] then roomsL[#roomsL + 1] = r end end
    table.sort(roomsL)
    for _ = 1, 8 do
      local merged = false
      for _, r in ipairs(roomsL) do
        if r ~= exR then
          local pr = coord[r]
          for d, x in each_exit(adj[r]) do
            local de = DELTA[d]
            if de and de[1] ~= 0 and de[2] ~= 0 and placed[x] and coord[x] and x ~= exR
               and not ((r == exA0 and x == exB0) or (r == exB0 and x == exA0))
               and not ((r == start0 and x == anchorR) or (r == anchorR and x == start0)) then
              local gx, gy = coord[x][1] - pr[1], coord[x][2] - pr[2]
              -- square + truthful only: an already-skewed diagonal has genuine slack and a lying
              -- one is the closure's to repair. Neither is this pass's business.
              if (gx == gy or gx == -gy) and gx * de[1] >= 1 and gy * de[2] >= 1
                 and not (elro._gxFree and elro._gxDiag(r, x)) then
                local ddx = amt(1, find(1, r)) - amt(1, find(1, x))
                local ddy = amt(2, find(2, r)) - amt(2, find(2, x))
                local sx, sy = gx - ddx, gy - ddy
                if sx < 0 then sx = -sx end
                if sy < 0 then sy = -sy end
                if sx ~= sy then
                  for a = 1, 2 do
                    local c1, c2 = find(a, r), find(a, x)
                    if c1 ~= c2 then
                      local v1, v2 = amt(a, c1), amt(a, c2)
                      local p1, p2 = pin[a][c1], pin[a][c2]
                      if p1 and p2 and v1 ~= v2 then return nil, nil, "lock-square" end
                      union(a, r, x)
                      local nc = find(a, r)
                      local nv
                      if p1 then nv = v1
                      elseif p2 then nv = v2
                      else
                        local m1 = (v1 < 0) and -v1 or v1
                        local m2 = (v2 < 0) and -v2 or v2
                        nv = (m1 >= m2) and v1 or v2
                      end
                      if c1 ~= nc then u[a][c1] = nil ; pin[a][c1] = nil end
                      if c2 ~= nc then u[a][c2] = nil ; pin[a][c2] = nil end
                      u[a][nc] = nv
                      if p1 or p2 then pin[a][nc] = true end
                      merged = true
                    end
                  end
                end
              end
            end
          end
        end
      end
      if not merged then break end
      elro._sqMerge = (elro._sqMerge or 0) + 1
      build_LM()
      local why2 = relax()
      if why2 then return nil, nil, why2 end
    end
  end
  local set, deltas, n = collect()
  if not set then return nil, nil, deltas end
  -- Separation: two rooms may not share a cell. Absorb every stationary victim into its mover's
  -- displacement, re-relax, re-collect. Two rooms the plate already moves differently void.
  -- One cell index of the canvas as it stands, per build; coordinates do not change inside a build, so
  -- every "who is at this cell" question below (separation rounds, the landing test, the reseed) reads
  -- it instead of re-walking the canvas. Published on `W` for the caller's post-build passes.
  for _ = 1, 24 do
    local _s0 = _ffP and CLK()
    local pairsHit = {}
    -- only a collision the plate is responsible for: two stationary rooms sharing a cell are not its to
    -- repair. Movers in room order, never `pairs` order: the absorption below reads the list in sequence.
    local movers = {}
    for r in pairs(set) do movers[#movers + 1] = r end
    table.sort(movers)
    -- Per cell the lowest-id occupant (standing or arriving) is the recorded one and every other
    -- occupant pairs with it -- one pair per extra occupant, as the canvas scan produced. Arrivals
    -- come in ascending order, so the first arrival at a cell decides the recorded occupant; `fk`
    -- remembers it for later arrivals. Scalar maps only: no per-cell tables.
    local fk = {}
    for i = 1, #movers do
      local r = movers[i]
      local pr, e = coord[r], deltas[r]
      local k = (pr[1] + e[1]) * 1000003 + (pr[2] + e[2])
      local first = fk[k]
      if first then
        pairsHit[#pairsHit + 1] = { first, r }
      else
        local o = cellOf[k]
        if type(o) == "table" then
          first = r
          for j = 1, #o do local oj = o[j] ; if not deltas[oj] and oj < first then first = oj end end
          for j = 1, #o do
            local oj = o[j]
            if oj ~= first and not deltas[oj] and first == r then pairsHit[#pairsHit + 1] = { first, oj } end
          end
          if first ~= r then pairsHit[#pairsHit + 1] = { first, r } end
        elseif o and not deltas[o] then
          if o < r then first = o else first = r end
          pairsHit[#pairsHit + 1] = { first, (first == o) and r or o }
        else
          first = r
        end
        fk[k] = first
      end
    end
    if _s0 then _ffP("separation scan", _s0) end
    if #pairsHit == 0 then
      -- settled on room-vs-room
      if elro.probeField and nPart > 0 then
        elro._ffPart = (elro._ffPart or 0) + 1 ; elro._ffPartN = (elro._ffPartN or 0) + nPart
      end
      return set, deltas, nil, n
    end
    local moved = false
    local sepSeed = {}
    for _, h in ipairs(pairsHit) do
      local a1, b1 = h[1], h[2]
      local da, db = deltas[a1], deltas[b1]
      -- both movers: the one that moved less rides the other, as a stationary room would (brom
      -- step 85: a seam-walk hop pushed 6523 to +1 under a seed pinned at +2, and the pass voided
      -- without trying the in-direction repair). Equal displacements are the void below: the
      -- reader's first question is who moved less.
      if da and db then
        local la = (da[1] < 0 and -da[1] or da[1]) + (da[2] < 0 and -da[2] or da[2])
        local lb = (db[1] < 0 and -db[1] or db[1]) + (db[2] < 0 and -db[2] or db[2])
        if la ~= lb then
          if lb < la then db = nil else da = nil end   -- the lesser mover becomes the victim
          elro._sepRideN = (elro._sepRideN or 0) + 1
        end
      end
      if da and db then
        -- and whether either room's class was held: pinned by whom, or a constraint on it left behind
        local held = {}
        for _, r0 in ipairs({ a1, b1 }) do
          for a = 1, 2 do
            local c = find(a, r0)
            if pin[a][c] or leftBehind[a][c] then
              held[#held + 1] = string.format("%d:%s%s%s", r0, (a == 1) and "x" or "y",
                pin[a][c] and (" pinned(" .. tostring(pinBy[a][c] or "?") .. ")") or "",
                leftBehind[a][c] and " left-behind" or "")
            end
          end
        end
        return nil, nil, string.format("sep@%d-%d(%+d,%+d)/(%+d,%+d)%s", a1, b1, da[1], da[2], db[1], db[2],
          (#held > 0) and (" [" .. table.concat(held, " ") .. "]") or "")
      end
      local mover = da and a1 or b1
      local vic = (mover == a1) and b1 or a1
      -- `pinIn` (a room id or a set): the room(s) the move exists to separate from may not be absorbed;
      -- absorbing preserves the offset the plate was built to change
      local dm = deltas[mover]
      if pinIn and not deltas[vic]
         and (pinIn == vic or (type(pinIn) == "table" and pinIn[vic])) then
        return nil, nil, string.format("sep-blocked@%d<-%d(%+d,%+d)", vic, mover, dm[1], dm[2])
      end
      local ok, okAx = true, nil
      for a = 1, 2 do
        local c = find(a, vic)
        if pin[a][c] then if amt(a, c) ~= dm[a] then ok = false ; okAx = okAx or a end
        else u[a][c] = dm[a] ; moved = true
          sepSeed[#sepSeed + 1] = a ; sepSeed[#sepSeed + 1] = vic end
      end
      -- name the victim, the mover, and what holds the victim's class
      if not ok then
        local ax = okAx or 1
        return nil, nil, string.format("sep-pin@%d<-%d(%+d,%+d) held by %s", vic, mover,
          dm[1], dm[2], tostring(pinBy[ax][find(ax, vic)] or "?"))
      end
    end
    if not moved then return nil, nil, string.format("sep-stuck") end
    why = relax(sepSeed)
    if why then return nil, nil, why end
    set, deltas, n = collect()
    if not set then return nil, nil, deltas end
  end
  return nil, nil, "sep-loop"
end

-- apply the rule to one built plate, in place. `seedR` = every room the move ASKED to move.
function elro.rigid_pendants(W, set, deltas, seedR, tag)
  local DELTA, adj, bridge_forest, coord, placed = W.DELTA, W.adj, W.bridge_forest, W.coord, W.placed
  local _rp0 = elro.timeGuillo and CLK()
  local bf = bridge_forest()
  if _rp0 then elro._rpBFT = (elro._rpBFT or 0) + (CLK() - _rp0)
    elro._rpBFN = (elro._rpBFN or 0) + 1 end
  local comp, tree, mem = bf.comp, bf.tree, bf.mem
  local hasSeed, root = {}, nil
  for r in pairs(seedR) do
    local c = comp[r] ; if c then hasSeed[c] = true ; root = root or c end
  end
  if not root then
    if _rp0 then elro._rpT = (elro._rpT or 0) + (CLK() - _rp0)
      elro._rpN = (elro._rpN or 0) + 1 end
    return 0
  end
  -- Canonical rooting of the forest, one per geometry (cached on it): parent comp, depth, the child's
  -- end of the bridge to its parent, and which way that bridge can be crossed. `tree` lists a bridge
  -- from the side that has the exit, so a one-way exit gives a one-way bridge; the walk only ever
  -- reached what it could cross in the direction of travel from the first seed, and that is kept.
  -- The rule's jobs are the seed-free subtrees hanging off the seeds' Steiner tree, which no choice
  -- of root changes; so the work below is over the seeds, the moved rooms and the jobs, never over
  -- the whole tree.
  local R = bf.rooted
  if not R then
    -- undirected adjacency with the two directions' presence
    local nb = {}
    for c, lst in pairs(tree) do
      for _, e in ipairs(lst) do
        local d, myEnd, theirEnd = e[1], e[2], e[3]
        local a = nb[c] ; if not a then a = {} ; nb[c] = a end
        local k = myEnd * 1000003 + theirEnd
        local x = a[k] ; if not x then x = { d, myEnd, theirEnd, false, false } ; a[k] = x end
        x[4] = true                                        -- c -> d crossable
        local b = nb[d] ; if not b then b = {} ; nb[d] = b end
        local k2 = theirEnd * 1000003 + myEnd
        local y = b[k2] ; if not y then y = { c, theirEnd, myEnd, false, false } ; b[k2] = y end
        y[5] = true                                        -- d -> c crossable (seen from d: its reverse)
      end
    end
    -- per comp, entries in ascending (myEnd, theirEnd) order: never pairs() order
    local nbl = {}
    for c, a in pairs(nb) do
      local l = {}
      for _, x in pairs(a) do l[#l + 1] = x end
      table.sort(l, function(p, q) if p[2] ~= q[2] then return p[2] < q[2] end ; return p[3] < q[3] end)
      nbl[c] = l
    end
    local parent, upEnd, depth, troot, canDown, canUp = {}, {}, {}, {}, {}, {}
    for c0 = 1, #mem do
      if depth[c0] == nil then
        depth[c0] = 0 ; troot[c0] = c0
        local q, h = { c0 }, 1
        while h <= #q do
          local cc = q[h] ; h = h + 1
          for _, x in ipairs(nbl[cc] or {}) do
            local y = x[1]
            if depth[y] == nil then
              depth[y] = depth[cc] + 1 ; parent[y] = cc ; upEnd[y] = x[3] ; troot[y] = c0
              canDown[y] = x[4]        -- parent -> child entry exists
              canUp[y] = x[5]          -- child -> parent entry exists
              q[#q + 1] = y
            end
          end
        end
      end
    end
    R = { parent = parent, upEnd = upEnd, depth = depth, troot = troot, canDown = canDown, canUp = canUp }
    bf.rooted = R
  end
  local parent, upEnd, depth, troot, canDown, canUp = R.parent, R.upEnd, R.depth, R.troot, R.canDown, R.canUp
  -- Reachable from the first seed's comp along crossable bridges: up from the root to the common
  -- ancestor (child -> parent crossings), then down to the comp (parent -> child crossings).
  local reachMemo = { [root] = true }
  local function reachable(x)
    local m = reachMemo[x] ; if m ~= nil then return m end
    if troot[x] ~= troot[root] then reachMemo[x] = false ; return false end
    local a, b = root, x
    local da, db = depth[a], depth[b]
    local ok = true
    while da > db do if not canUp[a] then ok = false ; break end ; a = parent[a] ; da = da - 1 end
    local pathB = {}
    while ok and db > da do pathB[#pathB + 1] = b ; b = parent[b] ; db = db - 1 end
    while ok and a ~= b do
      if not canUp[a] then ok = false ; break end
      pathB[#pathB + 1] = b
      a = parent[a] ; b = parent[b]
    end
    if ok then for i = 1, #pathB do if not canDown[pathB[i]] then ok = false ; break end end end
    reachMemo[x] = ok
    return ok
  end
  for c in pairs(hasSeed) do if not reachable(c) then hasSeed[c] = nil end end
  if _rp0 then elro._rpPh = elro._rpPh or {}
    elro._rpPh.bfs = (elro._rpPh.bfs or 0) + (CLK() - _rp0) end
  local _rpA = _rp0 and CLK()
  -- Per touched comp, how many of the marked comps lie in its subtree: walk up from each mark with
  -- an early stop, then accumulate bottom-up over the touched comps in depth order.
  local function subtree_counts(marks)
    local cnt, tset, tlist, total = {}, {}, {}, 0
    for c in pairs(marks) do
      total = total + 1
      cnt[c] = (cnt[c] or 0) + 1
      local p = c
      while p and not tset[p] do tset[p] = true ; tlist[#tlist + 1] = p ; p = parent[p] end
    end
    table.sort(tlist, function(a, b)
      local da, db = depth[a], depth[b]
      if da ~= db then return da > db end
      return a < b
    end)
    for i = 1, #tlist do
      local c = tlist[i]
      local p = parent[c]
      if p and cnt[c] then cnt[p] = (cnt[p] or 0) + cnt[c] end
    end
    return cnt, total, tlist
  end
  local sCnt, sTotal, sList = subtree_counts(hasSeed)
  -- the seeds' LCA is the deepest comp holding all of them; the Steiner tree is every comp holding
  -- some but not all, plus the LCA
  local lca
  for i = 1, #sList do local c = sList[i] ; if sCnt[c] == sTotal then lca = c ; break end end
  local steiner = {}
  for i = 1, #sList do
    local c = sList[i]
    if sCnt[c] and (sCnt[c] < sTotal or c == lca) then steiner[c] = true end
  end
  local hasMv = {}
  for r in pairs(set) do local c = comp[r] ; if c and reachable(c) then hasMv[c] = true end end
  local mCnt, mTotal = subtree_counts(hasMv)
  -- Skip sides that cannot change anything (displacement (0,0) onto (0,0), nothing moved). Cheaper,
  -- and a no-op side could otherwise absorb one of the landing test's capped revert rounds that
  -- the real culprit needed.
  local jobs, _nNoop, _nJob = {}, 0, 0
  local function consider(cq, anchorRoom, movedInside, collect, pathChild)
    local d = deltas[anchorRoom]
    local noop = not (d and (d[1] ~= 0 or d[2] ~= 0)) and not movedInside
    if elro.probeRigid then
      _nJob = _nJob + 1 ; if noop then _nNoop = _nNoop + 1 end
    end
    if noop then return end
    local rooms = collect()
    table.sort(rooms)                  -- never pairs() order downstream of this
    jobs[#jobs + 1] = { dx = d and d[1] or 0, dy = d and d[2] or 0,
                        rooms = rooms, was = {}, on = false, croot = cq, pathChild = pathChild }
  end
  -- OUTERMOST seed-free subtrees only: a nested side hangs off the outer one by a bridge whose
  -- parent end is inside the outer job, so once that room moves the nested side must take the
  -- same displacement or that bridge stretches. Splitting nested sides into their own jobs was
  -- tried and refuted; do not redo. A side is entered the way the walk entered it: through the
  -- entries of `tree`, so a bridge crossable only towards the seeds hides what lies beyond it.
  for p in pairs(steiner) do
    for _, e in ipairs(tree[p] or {}) do
      local q = e[1]
      if parent[q] == p and not steiner[q] then
        consider(q, e[2], (mCnt[q] or 0) > 0, function()
          local rooms, qq, h = {}, { q }, 1
          while h <= #qq do
            local cc = qq[h] ; h = h + 1
            for _, r in ipairs(mem[cc] or {}) do rooms[#rooms + 1] = r end
            for _, e2 in ipairs(tree[cc] or {}) do
              if parent[e2[1]] == cc then qq[#qq + 1] = e2[1] end
            end
          end
          return rooms
        end)
      end
    end
  end
  -- the part of the tree above the LCA hangs off it by its parent bridge; `pathChild` tells the
  -- landing test's split which way its anchor lies from a comp on the LCA-to-root path
  if lca and parent[lca] and canUp[lca] then
    local pathChild = {}
    do local c = lca ; while parent[c] do pathChild[parent[c]] = c ; c = parent[c] end end
    consider(parent[lca], upEnd[lca], (mCnt[lca] or 0) < mTotal, function()
      local rooms, qq, h, seen = {}, { parent[lca] }, 1, { [lca] = true, [parent[lca]] = true }
      while h <= #qq do
        local cc = qq[h] ; h = h + 1
        for _, r in ipairs(mem[cc] or {}) do rooms[#rooms + 1] = r end
        for _, e2 in ipairs(tree[cc] or {}) do
          local y = e2[1]
          if not seen[y] then seen[y] = true ; qq[#qq + 1] = y end
        end
      end
      return rooms
    end, pathChild)
  end
  table.sort(jobs, function(a, b) return a.rooms[1] < b.rooms[1] end)
  if _rpA then elro._rpPh = elro._rpPh or {}
    elro._rpPh.tree = (elro._rpPh.tree or 0) + (CLK() - _rpA) end
  local function apply(j, on)
    if j.on == on then return end
    j.on = on
    for _, r in ipairs(j.rooms) do
      if on then
        local e = deltas[r]
        j.was[r] = e and { e[1], e[2] } or false
        if j.dx == 0 and j.dy == 0 then deltas[r] = nil ; set[r] = nil
        else deltas[r] = { j.dx, j.dy } ; set[r] = true end
      else
        local w = j.was[r]
        if w then deltas[r] = { w[1], w[2] } ; set[r] = true
        else deltas[r] = nil ; set[r] = nil end
      end
    end
  end
  for _, j in ipairs(jobs) do apply(j, true) end
  -- The landing test: a rigid translation preserves every internal vector and the bridge,
  -- so a side cannot lie, squash or shear -- it can only land ON something. A side that does
  -- is reverted alone, never the candidate.
  local nfix, guard = 0, 0
  -- Budget 32: per-subtree reverts remove little geometry, so a side with scattered
  -- collisions needs more rounds than the old whole-side form did.
  local GUARD = 32
  local _rpB = _rp0 and CLK()
  -- the standing canvas: the builder's per-build index where this is its post-pass (the builder set
  -- it just now, same coordinates), else built here
  local cellOf = (tag == "field") and W.cellOf
  if not cellOf then cellOf = elro.placed_cells(placed, coord) end
  while guard < GUARD do
    guard = guard + 1
    -- One table per COLLIDED cell only: a lone occupant is stored as the bare room id.
    -- Key set and insertion order are unchanged on purpose -- `hit` is the first offender
    -- `pairs(dest)` reaches, so a different table shape would revert a different side.
    local owner = {}
    for i, j in ipairs(jobs) do
      if j.on then for _, r in ipairs(j.rooms) do owner[r] = i end end
    end
    -- Movers against the standing canvas (`cellOf`) and against each other. A collision between two
    -- sides, or a side and a room outside every side, names the side to revert; the lowest-id room
    -- among the candidates decides, never `pairs` order.
    local movers = {}
    for r in pairs(set) do movers[#movers + 1] = r end
    table.sort(movers)
    local md, hit, hitR = {}, nil, nil
    local function cand(a, b)
      local oa, ob = owner[a], owner[b]
      if oa == ob then return nil end
      if oa and ob then return (a < b) and a or b end
      return oa and a or b
    end
    for i = 1, #movers do
      local r = movers[i]
      local pr, e = coord[r], deltas[r]
      local k = (pr[1] + e[1]) * 1000003 + (pr[2] + e[2])
      local o = cellOf[k]
      if type(o) == "table" then
        for j = 1, #o do
          local oj = o[j]
          if oj ~= r and not deltas[oj] then
            local c = cand(oj, r) ; if c and (not hitR or c < hitR) then hitR = c end
          end
        end
      elseif o and o ~= r and not deltas[o] then
        local c = cand(o, r) ; if c and (not hitR or c < hitR) then hitR = c end
      end
      local m = md[k]
      if m then
        local c = cand(m, r) ; if c and (not hitR or c < hitR) then hitR = c end
      else md[k] = r end
    end
    if hitR then hit = owner[hitR] end
    if not hit then break end
    -- Revert the colliding subtree, not the whole side: exactly one bridge stretches by
    -- exactly `d` either way, so the split has the same cost and strands fewer rooms.
    -- It splits only ON REVERT (never up front from pre-application deltas), keeping one
    -- displacement per job. A collider in the job's own root component cannot be split off;
    -- that falls back to reverting the whole side.
    local didSplit = false
    if hitR then
      local j = jobs[hit]
      local cr = comp[hitR]
      if cr and cr ~= j.croot then
        local rooms2, q2, qs2, h2 = {}, { cr }, { [cr] = true }, 1
        while h2 <= #q2 do
          local cc = q2[h2] ; h2 = h2 + 1
          local away = (j.pathChild and j.pathChild[cc]) or parent[cc]
          for _, rr in ipairs(mem[cc] or {}) do rooms2[#rooms2 + 1] = rr end
          for _, e in ipairs(tree[cc] or {}) do
            if e[1] ~= away and not qs2[e[1]] then qs2[e[1]] = true ; q2[#q2 + 1] = e[1] end
          end
        end
        local drop = {}
        for _, rr in ipairs(rooms2) do drop[rr] = true end
        -- The stretching bridge must be able to STRETCH: an axial bridge perpendicular to
        -- `d` does not get longer, it TIPS (stops being truthful). Where the split would
        -- lie, take the whole-side revert instead. Differential: an edge already untruthful
        -- at the solver's own deltas is not this split's to answer for.
        local tips = false
        for _, rr in ipairs(rooms2) do
          local pr = coord[rr] ; local wr = j.was[rr]
          if pr then
            local ax0, ay0 = pr[1] + (wr and wr[1] or 0), pr[2] + (wr and wr[2] or 0)
            for d3, x3 in each_exit(adj[rr]) do
              local de3 = DELTA[d3]
              if de3 and (de3[1] ~= 0 or de3[2] ~= 0) and not drop[x3]
                 and placed[x3] and coord[x3] then
                local px3 = coord[x3]
                local e3 = deltas[x3]
                local bx0, by0 = px3[1] + (e3 and e3[1] or 0), px3[2] + (e3 and e3[2] or 0)
                local w3 = j.was[x3]
                local cx0, cy0 = px3[1] + (w3 and w3[1] or 0), px3[2] + (w3 and w3[2] or 0)
                if elro.edge_truthful(de3, cx0 - ax0, cy0 - ay0)
                   and not elro.edge_truthful(de3, bx0 - ax0, by0 - ay0) then
                  tips = true ; break
                end
              end
            end
          end
          if tips then break end
        end
        if tips then elro._rsTip = (elro._rsTip or 0) + 1 end
        if #rooms2 > 0 and #rooms2 < #j.rooms and not tips then
          for _, rr in ipairs(rooms2) do        -- put just these back where the solver had them
            local w = j.was[rr]
            if w then deltas[rr] = { w[1], w[2] } ; set[rr] = true
            else deltas[rr] = nil ; set[rr] = nil end
            j.was[rr] = nil
          end
          local keep = {}
          for _, rr in ipairs(j.rooms) do if not drop[rr] then keep[#keep + 1] = rr end end
          j.rooms = keep
          elro._rsSplit = (elro._rsSplit or 0) + 1
          elro._rsKept = (elro._rsKept or 0) + #keep
          didSplit = true
        end
      end
    end
    if not didSplit then apply(jobs[hit], false) end
    elro._rdRigidRev = (elro._rdRigidRev or 0) + 1
  end
  if _rpB then elro._rpPh = elro._rpPh or {}
    elro._rpPh.landing = (elro._rpPh.landing or 0) + (CLK() - _rpB)
    elro._rpPh.landingN = (elro._rpPh.landingN or 0) + guard end
  for _, j in ipairs(jobs) do
    j.n = 0
    if j.on then
      for _, r in ipairs(j.rooms) do
        local w, e = j.was[r], deltas[r]
        local ox, oy = w and w[1] or 0, w and w[2] or 0
        if ox ~= (e and e[1] or 0) or oy ~= (e and e[2] or 0) then
          nfix = nfix + 1 ; j.n = j.n + 1
        end
      end
    end
  end
  if nfix > 0 then
    elro._rdRigid = (elro._rdRigid or 0) + 1
    elro._rdRigidR = (elro._rdRigidR or 0) + nfix
  end
  -- `elro.probeRigid`: name every side this rule moved and every one the landing test
  -- reverted, into the same per-step funnel as `[plate-gen]` (the rule rewrites a plate
  -- before ranking, so it is invisible in a mapstep candidate line). Silent when nothing
  -- changed.
  if elro.probeRigid then
    local w, nrev = {}, 0
    for _, j in ipairs(jobs) do
      if not j.on then
        nrev = nrev + 1
        w[#w + 1] = string.format("REVERTED:%s+%dr", tostring(j.rooms[1]), #j.rooms)
      elseif (j.n or 0) > 0 then
        w[#w + 1] = string.format("%s+%dr->(%d,%d)x%d",
          tostring(j.rooms[1]), #j.rooms, j.dx, j.dy, j.n)
      end
    end
    if #w > 0 then
      local rp = elro._guilloTracePending or {} ; elro._guilloTracePending = rp
      local h = string.format(
        "rigid-pendant %s -> %d room(s) re-assigned over %d side(s), %d reverted: %s",
        tostring(tag or "?"), nfix, #jobs - nrev, nrev, table.concat(w, " "))
      -- Collapse consecutive identical lines; a repeat that comes back after something
      -- else still prints (a different answer to a different build).
      local last = rp[#rp]
      if last and last.rpKey == h then
        last.rpN = (last.rpN or 1) + 1
        last.header = h .. string.format("   [x%d]", last.rpN)
      else
        rp[#rp + 1] = { header = h, rpKey = h }
      end
    end
  end
  if _rp0 then elro._rpT = (elro._rpT or 0) + (CLK() - _rp0)
    elro._rpN = (elro._rpN or 0) + 1 ; elro._rpFix = (elro._rpFix or 0) + nfix end
  if elro.probeRigid then elro._rpJob = (elro._rpJob or 0) + _nJob
    elro._rpNoop = (elro._rpNoop or 0) + _nNoop end
  -- Split by caller: a closure/TIGHTEN plate is supposed to be minimal, so re-assignments
  -- inside one are worth seeing.
  if _rp0 and elro._inClose then
    elro._rpClN = (elro._rpClN or 0) + 1 ; elro._rpClFix = (elro._rpClFix or 0) + nfix
  end
  return nfix
end

-- Diagonal equations: a four-family closure over displacements. Each edge family is a
-- projection `n . d` equal across the edge (E/W (0,1), N/S (1,0), NE/SW (1,-1), NW/SE (1,1));
-- two independent projections determine d, which is what lets a plate express a dilation.
-- Axial equations are hard, diagonal ones soft (square truthful diagonals only). Odd shifts
-- can land on half-integer cells: `nil, "parity"` asks the caller to retry at 2s.
-- Returns `set, nMoved, deltas` or `nil, why`. `noSoft`: rooms refused soft equations this
-- attempt. `pin`: premises entered as hard equations. `cut`: one edge across which no
-- equality propagates (the slack absorber); it applies to the equality passes only, never
-- to `drag`.
function elro.eqw_diag_shift(W, start, pa, s, anchor, sep, seedSet, axc, noSoft, pin, cut)
  local DELTA, DIRORDER, adj, coord, diag_skew_n, placed = W.DELTA, W.DIRORDER, W.adj, W.coord, W.diag_skew_n, W.placed
  elro.bg_tick("eqw-diag")
  -- family of an edge, as the PROJECTION n that must agree across it
  local function fam_of(de)
    if de[1] ~= 0 and de[2] ~= 0 then
      if de[1] == de[2] then return 1, -1, false end          -- NE/SW -> v = x-y, soft
      return 1, 1, false                                      -- NW/SE -> u = x+y, soft
    elseif de[1] ~= 0 then return 0, 1, true                  -- E/W   -> row y,   hard
    else return 1, 0, true end                                -- N/S   -> col x,   hard
  end
  -- per room: up to two equations `n . d = c`, then a solved displacement
  local eq1n, eq1c, eq2n, eq2c, dsp = {}, {}, {}, {}, {}
  local dspList, dspN = {}, 0             -- solve order, for the parity/-0 sweep
  local queue, qh, nQ = {}, 1, 0
  local CAP = TUNE.eqwShiftCap
  local voided
  local function add_eq(r, nx, ny, c, hard)
    local d = dsp[r]
    if d then
      if nx * d[1] + ny * d[2] ~= c then return hard and "conflict" or "skew" end
      return nil
    end
    local a1 = eq1n[r]
    if a1 then
      if a1[1] == nx and a1[2] == ny then
        if eq1c[r] ~= c then return hard and "conflict" or "skew" end
        return nil                                            -- nothing new
      end
      -- second independent projection (every pair of the four n's is independent): solve
      local det = a1[1] * ny - a1[2] * nx
      local dx = (eq1c[r] * ny - c * a1[2]) / det
      local dy = (a1[1] * c - nx * eq1c[r]) / det
      eq2n[r], eq2c[r] = { nx, ny }, c
      dsp[r] = { dx, dy }
      dspN = dspN + 1 ; dspList[dspN] = r
    else
      eq1n[r], eq1c[r] = { nx, ny }, c
    end
    nQ = nQ + 1 ; queue[nQ] = r
    return nil
  end
  -- The anchor is a propagation SOURCE pinned at zero, not merely a barrier: a room needs
  -- two independent projections, and a dilation gets them from opposite sides. Pinning only
  -- ever shrinks the moved set; a hard disagreement is the reached-the-anchor void.
  local function at_anchor(r) return r == anchor end
  local cutA, cutB = cut and cut[1], cut and cut[2]
  local function is_cut(a, b)
    return cutA ~= nil and ((a == cutA and b == cutB) or (a == cutB and b == cutA))
  end
  -- is_leaf: exactly one placed neighbour. sq_diag: the room sits on a square truthful
  -- diagonal (same gate the propagation admits a diagonal edge under).
  local function is_leaf(r)
    local n = 0
    for _, d in ipairs(DIRORDER) do
      local x = adj[r] and adj[r][d]
      local de = x and DELTA[d]
      if de and (de[1] ~= 0 or de[2] ~= 0) and placed[x] then
        n = n + 1 ; if n > 1 then return false end
      end
    end
    return n == 1
  end
  local function sq_diag(r)
    local cr = coord[r] ; if not cr then return false end
    for _, d in ipairs(DIRORDER) do
      local x = adj[r] and adj[r][d]
      local de = x and DELTA[d]
      if de and de[1] ~= 0 and de[2] ~= 0 and placed[x] and coord[x] then
        local gx, gy = coord[x][1] - cr[1], coord[x][2] - cr[2]
        if gx ~= 0 and math.abs(gx) == math.abs(gy)
           and gx * de[1] >= 1 and gy * de[2] >= 1 then return true end
      end
    end
    return false
  end
  if pa == 1 then add_eq(start, 1, 0, s, true) ; add_eq(start, 0, 1, 0, true)
  else add_eq(start, 1, 0, 0, true) ; add_eq(start, 0, 1, s, true) end
  if anchor and placed[anchor] and anchor ~= start then
    add_eq(anchor, 1, 0, 0, true) ; add_eq(anchor, 0, 1, 0, true)
  end
  -- Premises go in BEFORE propagation: a soft equation is decided by first arrival, so
  -- seeding the wish as hard inverts that race and nothing else. It may void ("this wall
  -- cannot be kept"); the caller keeps the plate it already had.
  if pin then
    for _, p in ipairs(pin) do
      if add_eq(p[1], p[2], p[3], p[4], true) then return nil, "pin" end
    end
  end
  local nSkew = 0
  local function propagate()
    while qh <= nQ do
      local r = queue[qh] ; qh = qh + 1
      -- dir_order, never `pairs` over adj: the plate must not depend on the LuaJIT hash seed
      for _, d in ipairs(DIRORDER) do
        local x = adj[r] and adj[r][d]
        local de = x and DELTA[d]
        if de and placed[x] and placed[r] and coord[x] and coord[r]
           and (de[1] ~= 0 or de[2] ~= 0) and not is_cut(r, x) then
          local nx, ny, hard = fam_of(de)
          local admit = hard
          if not hard then                                     -- square + truthful diagonals only
            local gx, gy = coord[x][1] - coord[r][1], coord[x][2] - coord[r][2]
            -- square truthful diagonals only: an already-skewed wall has slack to spend
            admit = (gx ~= 0) and math.abs(gx) == math.abs(gy)
                    and gx * de[1] >= 1 and gy * de[2] >= 1
          end
          if admit and not (not hard and noSoft and noSoft[x]) then
            local c
            local dr = dsp[r]
            if dr then c = nx * dr[1] + ny * dr[2]
            elseif eq1n[r] and eq1n[r][1] == nx and eq1n[r][2] == ny then c = eq1c[r] end
            if c then
              if at_anchor(x) and c ~= 0 then return "lock-diag" end
              local bad = add_eq(x, nx, ny, c, hard)
              if bad == "conflict" then return "lock-diag-axial"
              elseif bad == "skew" then nSkew = nSkew + 1 end
              if nQ > CAP * 4 then return "cap" end
            end
          end
        end
      end
    end
  end
  -- Soft completion: a room carrying one diagonal equation whose neighbour is going
  -- nowhere gets the missing projection as 0. Cursor over `queue`, not a rescan: rooms
  -- only ever become more determined, so re-examining an entry cannot find anything new.
  local ci = 1
  local function complete()
    while ci <= nQ do
        -- `nQ` grows inside this body.
        elro.bg_tick("eqw-diag-propagate")
        local r = queue[ci] ; ci = ci + 1
        local a1 = eq1n[r]
        local isDiag = a1 and not (a1[1] == 0 or a1[2] == 0)
        -- A lone axial equation is also completed (only for rooms on a square truthful
        -- diagonal), or the projection never flows along the wall.
        if a1 and not dsp[r] and (isDiag or (axc and sq_diag(r))) then
          -- Pass order: a lone diagonal prefers a diagonal completion (keeps both walls); a lone
          -- axial prefers an axial one (a diagonal completion would terminate the chain here).
          for pass = 1, 2 do
            local wantHard = (isDiag and pass == 2) or (not isDiag and pass == 1)
            local done = false
            for _, d in ipairs(DIRORDER) do
              local x = adj[r] and adj[r][d]
              local de = x and DELTA[d]
              -- the test is "not going anywhere", not "unreached": no displacement and nothing non-zero known
              if de and placed[x] and coord[x] and (de[1] ~= 0 or de[2] ~= 0)
                 and not is_cut(r, x)
                 and not dsp[x] and (not eq1n[x] or eq1c[x] == 0) then
                local nx, ny, hard = fam_of(de)
                if hard == wantHard then
                  local admit = hard
                  if not hard then
                    local gx, gy = coord[x][1] - coord[r][1], coord[x][2] - coord[r][2]
                    -- square truthful only (see propagate)
            admit = (gx ~= 0) and math.abs(gx) == math.abs(gy)
                    and gx * de[1] >= 1 and gy * de[2] >= 1
                  end
                  -- A completion is an equality guess and may not squash an incident edge to an
                  -- already-determined room below min_len; only edges legal now are protected.
                  local okLen = true
                  if admit then
                    local det2 = a1[1] * ny - a1[2] * nx
                    local cdx = (eq1c[r] * ny) / det2
                    local cdy = (-nx * eq1c[r]) / det2
                    for _, d2 in ipairs(DIRORDER) do
                      local y2 = adj[r] and adj[r][d2]
                      local de2 = y2 and DELTA[d2]
                      if de2 and placed[y2] and coord[y2] and dsp[y2]
                         and (de2[1] ~= 0 or de2[2] ~= 0) then
                        local m2 = elro.min_len(r, y2)
                        for ax2 = 1, 2 do
                          if de2[ax2] ~= 0 then
                            local g0 = coord[y2][ax2] - coord[r][ax2]
                            local g1 = g0 + dsp[y2][ax2] - ((ax2 == 1) and cdx or cdy)
                            if g0 * de2[ax2] >= m2 and g1 * de2[ax2] < m2 then okLen = false end
                          end
                        end
                      end
                    end
                    if not okLen then elro._diagLenRej = (elro._diagLenRej or 0) + 1 end
                  end
                  if admit and okLen and not (a1[1] == nx and a1[2] == ny)
                     and not (not hard and noSoft and noSoft[r]) then
                    if add_eq(r, nx, ny, 0, hard) == nil then
                      if pass == 1 then elro._diagC1 = (elro._diagC1 or 0) + 1
                      else elro._diagC2 = (elro._diagC2 or 0) + 1 end
                      done = true
                    end
                    if done then break end
                  end
                end
              end
            end
            if done then break end
          end
        end
    end
  end
  -- Parity gate: half-integer cells mean the magnitude is infeasible on the rotated
  -- lattice; the caller doubles and retries. The solve divides, so normalise -0.
  -- Walk `dspList` (solve order), never pairs(dsp).
  local ni = 1
  local function normalise()
    while ni <= dspN do
      local d = dsp[dspList[ni]] ; ni = ni + 1
      if d[1] % 1 ~= 0 or d[2] % 1 ~= 0 then return "parity" end
      if d[1] == 0 then d[1] = 0 end ; if d[2] == 0 then d[2] = 0 end   -- kill -0
    end
  end
  -- ------------------------------------------------------------------ phase 2: the drag closure
  -- A component is pinned by phase 1, or free at 0 until a squash or a class lock assigns
  -- it, after which it is frozen. Assign-once, so monotone, so it terminates.
  local fixX, fixY, dvX, dvY = {}, {}, {}, {}
  local wl, wn, wh = {}, 0, 1
  local nAssign, initd, fed = 0, {}, false
  local lockRoom, lockRoom2               -- rooms the drag rule could not repair (see `noSoft`)
  -- The two phases are one alternated closure: a drag feeds back as an equation via
  -- `take`, and `sync` mirrors phase-1 displacements into phase 2 once per round (cursor).
  local si = 1
  local function sync()
    while si <= nQ do
      elro.bg_tick("eqw-diag-sync")     -- `nQ` grows in-body; see the propagate loop above
      local r = queue[si] ; si = si + 1
      local d = dsp[r]
      if d then
        -- cannot fire: every phase-2 assignment is registered through `add_eq`, so any displacement
        -- derived afterwards already satisfies it. Voids loudly rather than shipping a plate whose
        -- two halves disagree about where a room goes.
        if (fixX[r] and dvX[r] ~= d[1]) or (fixY[r] and dvY[r] ~= d[2]) then return "lock-diag-sync" end
        if not (fixX[r] and fixY[r]) then
          initd[r] = true
          fixX[r], fixY[r], dvX[r], dvY[r] = true, true, d[1], d[2]
          wn = wn + 1 ; wl[wn] = r
        end
      elseif not initd[r] then
        initd[r] = true
        local a1 = eq1n[r]
        if not fixX[r] then dvX[r] = 0 end
        if not fixY[r] then dvY[r] = 0 end
        -- a lone AXIAL equation pins exactly one component; a lone DIAGONAL one pins NEITHER (its
        -- free direction is not a coordinate axis, so there is no canonical minimal answer -- we
        -- decline and let that wall skew, unless a later round supplies the second projection)
        if a1[1] == 1 and a1[2] == 0 then
          if not fixX[r] then fixX[r], dvX[r] = true, eq1c[r] end
        elseif a1[1] == 0 and a1[2] == 1 then
          if not fixY[r] then fixY[r], dvY[r] = true, eq1c[r] end
        end
        wn = wn + 1 ; wl[wn] = r
      end
    end
  end
  local function take(x, ax, val, dry)
    local nx, ny = (ax == 1) and 1 or 0, (ax == 1) and 0 or 1
    if ax == 1 then
      if fixX[x] then return dvX[x] == val end
    elseif fixY[x] then return dvY[x] == val end
    -- `fix*` lags the equation system within a round, so ask the equations too
    local d0 = dsp[x]
    if d0 then return (ax == 1 and d0[1] or d0[2]) == val end
    local a0 = eq1n[x]
    if a0 and a0[1] == nx and a0[2] == ny and eq1c[x] ~= val then return false end
    if dry then return true end
    if ax == 1 then fixX[x], dvX[x] = true, val else fixY[x], dvY[x] = true, val end
    nAssign = nAssign + 1
    if nAssign > CAP then return false, true end
    wn = wn + 1 ; wl[wn] = x
    fed = true                    -- something changed: the alternation must run at least once more
    -- Feed an axial assignment back as an equation (a projection, never a rigid copy across
    -- the diagonal: a dilation needs the two corners to displace differently). Gated on a
    -- square truthful diagonal being incident, which is what keeps it free elsewhere.
    if not sq_diag(x) then return true end
    add_eq(x, nx, ny, val, true)
    return true
  end
  local function drag()
    while wh <= wn do
      -- `wn` grows inside this loop (take appends)
      elro.bg_tick("eqw-diag-drag")
      local r = wl[wh] ; wh = wh + 1
      for _, d in ipairs(DIRORDER) do
        local x = adj[r] and adj[r][d]
        local de = x and DELTA[d]
        if de and placed[x] and coord[x] and coord[r] and (de[1] ~= 0 or de[2] ~= 0) then
          for ax = 1, 2 do
            local fr = (ax == 1) and fixX[r] or fixY[r]
            local fx = (ax == 1) and fixX[x] or fixY[x]
            if fr or fx then
              local dr = (ax == 1) and (dvX[r] or 0) or (dvY[r] or 0)
              local dx_ = (ax == 1) and (dvX[x] or 0) or (dvY[x] or 0)
              local gap = coord[x][ax] - coord[r][ax]
              local g2 = gap + dx_ - dr
              local need
              if de[ax] == 0 then need = (g2 ~= 0)              -- across the axis: hard class lock
              -- squashed below the edge's minimum: drag (a diagonal carries the same magnitude on
              -- both components, so no separate case)
              else need = (g2 * de[ax] < elro.min_len(r, x)) end
              local tgt, val
              if fr then tgt, val = x, dr else tgt, val = r, dx_ end
              -- Stretch case: when the edge grows and the copy target is a leaf, drag it too --
              -- a left-behind leaf is pure injected slack. Still assign-once through `take`.
              if not need and de[ax] ~= 0
                 and g2 * de[ax] > gap * de[ax] and is_leaf(tgt) then
                need = true ; elro._dragLeaf = (elro._dragLeaf or 0) + 1
              end
              if need then
                if at_anchor(tgt) and val ~= 0 then return "lock-diag" end
                local ok, capped = take(tgt, ax, val)
                if capped then return "cap" end
                if not ok then
                  -- both endpoints: which one holds the soft value is not knowable here
                  lockRoom, lockRoom2 = tgt, (tgt == r) and x or r
                  return "lock-diag-drag"
                end
              end
            end
          end
        end
      end
    end
  end
  -- Separation: a stationary room a mover lands on rides along on the mover's
  -- displacement. Decline, never void: an unrepairable collision leaves the plate as it was.
  local sepIdx
  local function separate()
    if not sepIdx then
      sepIdx = {}
      for r in pairs(placed) do
        local p = coord[r]
        if p then
          local k = p[1] .. ":" .. p[2]
          local o = sepIdx[k]
          -- min-id tie-break: pairs(placed) is hash order
          if not o or r < o then sepIdx[k] = r end
        end
      end
    end
    for i = 1, wn do
      local r = wl[i]
      local dx, dy = dvX[r] or 0, dvY[r] or 0
      local p = coord[r]
      if p and (dx ~= 0 or dy ~= 0) then
        local o = sepIdx[(p[1] + dx) .. ":" .. (p[2] + dy)]
        -- a victim is the cell's ORIGINAL occupant that is not itself going anywhere; one that
        -- moves off is not in the way, and a moved-on-moved landing is a disagreement between two
        -- frozen displacements that this pass has no authority to resolve
        if o and o ~= r and (dvX[o] or 0) == 0 and (dvY[o] or 0) == 0 and not at_anchor(o)
           and take(o, 1, dx, true) and take(o, 2, dy, true) then
          take(o, 1, dx) ; take(o, 2, dy)
        end
      end
    end
  end
  -- Termination is an argument (every feed consumes one of at most CAP assignments), not a
  -- bound, so a round guard and a tick keep a broken feeder from freezing the client.
  local rounds = 0
  repeat
    rounds = rounds + 1
    if rounds > (elro._diagRoundMax or 0) then elro._diagRoundMax = rounds end
    if rounds > TUNE.diagRoundCap then
      elro._diagRoundBail = (elro._diagRoundBail or 0) + 1
      return nil, "rounds", nil, nil, nil, nil, lockRoom, lockRoom2
    end
    elro.bg_tick("eqw-diag-round")   -- the walk must stay interruptible inside the alternation
    fed = false
    local bad = propagate() or complete() or normalise() or sync() or drag()
    if bad then return nil, bad, nil, nil, nil, nil, lockRoom, lockRoom2 end
    if sep and not fed then separate() end  -- only once the closure has settled
  until not fed
  local set, deltas, n = {}, {}, 0
  for _, r in ipairs(wl) do
    if set[r] == nil then
      local dx, dy = dvX[r] or 0, dvY[r] or 0
      if dx ~= 0 or dy ~= 0 then
        set[r] = true ; deltas[r] = { dx, dy } ; n = n + 1
      else set[r] = false end
    end
  end
  for r, v in pairs(set) do if v == false then set[r] = nil end end
  if n == 0 then return nil, "noop" end
  -- Drop a uniform plate only when its set is contained in the seed's; a uniform plate
  -- reaching further is a translation the 1D builder cannot express.
  local ux, uy, uniform = nil, nil, true
  for _, d in pairs(deltas) do
    if ux == nil then ux, uy = d[1], d[2]
    elseif d[1] ~= ux or d[2] ~= uy then uniform = false ; break end
  end
  -- `rescue`: does this plate keep a 45-degree wall the seed's own move would skew? Only
  -- meaningful when the plate is a strict superset of the seed's set.
  local rescue, superset = false, uniform and seedSet ~= nil
  if superset then
    for r in pairs(seedSet) do
      if not set[r] then superset = false ; break end
    end
  end
  -- count both geometries over every square truthful diagonal; substitute only on a net improvement
  if superset then
    local sdx, sdy = (pa == 1) and s or 0, (pa == 2) and s or 0
    local nSeed, nPlate, seen = 0, 0, {}
    for r in pairs(set) do
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
              local ex = (seedSet[x] and sdx or 0) - (seedSet[r] and sdx or 0)
              local ey = (seedSet[x] and sdy or 0) - (seedSet[r] and sdy or 0)
              if math.abs(gx + ex) ~= math.abs(gy + ey) then nSeed = nSeed + 1 end
              local px = (deltas[x] and deltas[x][1] or 0) - (deltas[r] and deltas[r][1] or 0)
              local py = (deltas[x] and deltas[x][2] or 0) - (deltas[r] and deltas[r][2] or 0)
              if math.abs(gx + px) ~= math.abs(gy + py) then nPlate = nPlate + 1 end
            end
          end
        end
      end
    end
    rescue = nPlate < nSeed
  end
  -- A uniform plate is never emitted as an extra candidate; `rescue` is handed to the
  -- caller to substitute for the seed. Skip the retry when nothing is skewed.
  if uniform then
    return nil, (diag_skew_n(deltas) > 0) and "uniform-skew" or "uniform",
           nil, rescue and set, rescue and deltas, rescue and n
  end
  elro._diagSkew = (elro._diagSkew or 0) + nSkew
  return set, n, deltas
end

-- Make room for v before placing it: per axis, placed neighbours either pin v's coordinate
-- (edge across the axis) or bound it to one side. An equality conflict pulls one class onto
-- the other; an empty interval pushes one class outward by the deficit. Both sides are tried,
-- and the whole repair is gated on count_defects and reverted if v still has no feasible cell.
function elro.eqw_make_room(W, v, u, de)
  local DELTA, adj, coord, ctrace, defect_blocker, defective, det_sweep, eqw_classes = W.DELTA, W.adj, W.coord, W.ctrace, W.defect_blocker, W.defective, W.det_sweep, W.eqw_classes
  local eqw_forced_shift, eqw_score, eqw_shared_grow, pedges, placed, plate_label, query_eq_levers, rebuild_occ = W.eqw_forced_shift, W.eqw_score, W.eqw_shared_grow, W.pedges, W.placed, W.plate_label, W.query_eq_levers, W.rebuild_occ
  local sgtxt = W.sgtxt
  -- eqw_classes is two whole-graph union-finds and most calls repair nothing: compute lazily
  local cls, mem
  local function classes()
    if not cls then cls, mem = eqw_classes(nil, nil, v) end
    return cls, mem
  end
  -- baseline kept by kind, not as a flat total
  local restore, before, bOv, bRoe, bX = nil, nil, nil, nil, nil
  local function snapshot()
    if restore then return end
    restore = {} ; for r in pairs(placed) do restore[r] = coord[r] end
    before, bOv, bRoe, bX = elro.count_defects(coord, placed, pedges)
  end
  -- per-axis constraint read; returns eqs (pins) and the [lo,hi] interval
  local function read(axis)
    local eqs, lo, hi, loW, hiW = {}, nil, nil, nil, nil
    for d2, w in each_exit(adj[v]) do
      local de2 = DELTA[d2]
      if placed[w] and de2 and (de2[1] ~= 0 or de2[2] ~= 0) then
        local c = coord[w][axis]
        -- the feasible window honours the edge minimum, as the drag rules do
        local mW = elro.min_len(v, w)
        if de2[axis] == 0 then eqs[#eqs + 1] = { w = w, val = c }
        elseif de2[axis] > 0 then if hi == nil or c - mW < hi then hi, hiW = c - mW, w end
        else if lo == nil or c + mW > lo then lo, loW = c + mW, w end end
      end
    end
    return eqs, lo, hi, loW, hiW
  end
  -- 0..2 plates for this shift: the permissive one and, when it differs, the 45-rigid one.
  -- `a` is the anchor, carried so `best` can name the pair the repair is about.
  local function try_shift(axis, moveRoom, s, anchorRoom)
    local out = {}
    local cls, mem = classes()
    local mv, n = eqw_forced_shift(cls, mem, axis, moveRoom, s, anchorRoom)
    if not mv then return out end
    out[1] = { set = mv, n = n, s = s, axis = axis, start = moveRoom, a = anchorRoom }
    local mv2, n2 = eqw_forced_shift(cls, mem, axis, moveRoom, s, anchorRoom, true)
    if mv2 and n2 ~= n then
      out[#out + 1] = { set = mv2, n = n2, s = s, axis = axis, start = moveRoom,
                        a = anchorRoom, rigid = true }
    end
    return out
  end
  -- is this axis satisfiable as things stand? (the acceptance gate's question, for one axis)
  local function axis_ok(axis)
    local eqs, lo, hi = read(axis)
    local val = (#eqs > 0) and eqs[1].val or nil
    for i = 2, #eqs do if eqs[i].val ~= val then return false end end
    if val then
      if lo and val < lo then return false end
      if hi and val > hi then return false end
    elseif lo and hi and lo > hi then return false end
    return true
  end
  local function apply(o)
    snapshot()
    -- scored across the move: after - before is the space this repair injected elsewhere
    local c0 = eqw_score()
    for r in pairs(o.set) do
      local p = coord[r]
      coord[r] = (o.axis == 1) and { p[1] + o.s, p[2] } or { p[1], p[2] + o.s }
    end
    rebuild_occ()
    local c1 = eqw_score()
    local ids, nid = {}, 0
    for r in pairs(o.set) do
      nid = nid + 1
      if nid <= 12 then ids[#ids + 1] = tostring(r) end
    end
    table.sort(ids)                        -- never pairs() order in a diagnostic
    ctrace(false, "[make-room %d] plate %s -- MOVED %d room(s) {%s%s},"
      .. " total length %d -> %d (%+d)%s", v, plate_label(o.start, o.axis, o.s), o.n,
      table.concat(ids, " "), (nid > 12) and (" +" .. (nid - 12) .. " more") or "",
      c0, c1, c1 - c0,
      (o.cascade and (" [cascaded: + " .. o.cascade .. "]") or "")
        .. (o.rigid and " [45-rigid plate]" or ""))
    if elro.debug then
      elro.tr(string.format("  eqw make-room %d: plate %s (%d room(s))%s",
        v, plate_label(o.start, o.axis, o.s), o.n, o.rigid and " [45-rigid plate]" or "")) end
  end
  -- Trial-apply an option and cascade it like eq_phase, up to TUNE.eqwCascadeDepth. Returns
  -- the composed set (written back so apply moves what was priced). `carry` re-probes a level
  -- with the far ends of every stretched boundary edge as seeds.
  -- Truthfulness: a repair may not flip or bend an edge (an inverted vertical edge is a lie the
  -- defect columns cannot see); priced differentially, see lie_count.
  local function probe(o, carry)
    local snap, full, wasClean, trail = {}, {}, {}, nil
    local lie0 = lie_set(coord, adj, placed, DELTA)
    -- a room an earlier level already moved must not move again: apply shifts the composed
    -- set exactly once by o.s, and probe must measure that same geometry
    local function step(set)
      local xi, rc, cen
      for r in pairs(set) do
        if not full[r] then
          if snap[r] == nil then snap[r] = coord[r] end
          if wasClean[r] == nil then
            if not xi then xi, rc, cen = det_sweep() end  -- built once; geometry frozen until the shift
            wasClean[r] = not defective(r, xi, rc, cen)
          end
        end
      end
      for r in pairs(set) do
        if not full[r] then
          local p = coord[r]
          coord[r] = (o.axis == 1) and { p[1] + o.s, p[2] } or { p[1], p[2] + o.s }
          full[r] = true
        end
      end
      rebuild_occ()
    end
    step(o.set)
    local depth = math.max(1, TUNE.eqwCascadeDepth)
    for lvl = 1, depth do
      -- a room this move broke (differential: only rooms that were clean count)
      local bad, xi, rc, cen
      for r in pairs(full) do
        if wasClean[r] then
          if not xi then xi, rc, cen = det_sweep() end
          if defective(r, xi, rc, cen) then bad = r ; break end
        end
      end
      if not bad or lvl == depth then break end
      local blk, kind = defect_blocker(bad)
      if not blk or full[blk] then break end   -- nothing to move, or it is already in the move
      local cls2, mem2 = classes()
      local mv2, n2 = eqw_forced_shift(cls2, mem2, o.axis, blk, o.s, o.a)
      if not mv2 then break end
      if carry then
        -- far end of every boundary edge this level would stretch; sorted, since the seed
        -- list reaches the builder in order
        local seeds, seen = {}, {}
        for r in pairs(mv2) do
          for d2, y in each_exit(adj[r]) do
            local de2 = DELTA[d2]
            if placed[y] and coord[y] and de2 and (de2[1] ~= 0 or de2[2] ~= 0)
               and not mv2[y] and not full[y] and not seen[y] then
              local g = coord[y][o.axis] - coord[r][o.axis]
              local h = g - o.s
              if (h < 0 and -h or h) > (g < 0 and -g or g) then
                seen[y] = true ; seeds[#seeds + 1] = y
              end
            end
          end
        end
        if #seeds > 0 then
          table.sort(seeds)
          local mv3, n3 = eqw_forced_shift(cls2, mem2, o.axis, blk, o.s, o.a, nil, seeds)
          -- it has to actually be the bigger move; an equal one is the same plate renamed
          if mv3 and n3 and n3 > (n2 or 0) then mv2, n2 = mv3, n3 end
        end
      end
      -- a level that adds no new room is the same move renamed
      local grew = false
      for r in pairs(mv2) do if not full[r] then grew = true ; break end end
      if not grew then break end
      step(mv2)
      trail = (trail and (trail .. " + ") or "")
        .. string.format("%d%+d(%dr,%s%s)", blk, o.s, n2 or elro.tcount(mv2), tostring(kind),
                         carry and ",carry" or "")
      if not carry then elro._mrCascN = (elro._mrCascN or 0) + 1 end
    end
    local _, ov, roe, x = elro.count_defects(coord, placed, pedges)
    local sc = eqw_score()
    local lie = new_lies(lie0, coord, adj, placed, DELTA)
    for r, p in pairs(snap) do coord[r] = p end
    rebuild_occ()
    local n = 0 ; for _ in pairs(full) do n = n + 1 end
    return ov, roe, x, sc, full, n, trail, lie
  end
  -- Extra 1D options for the pair (start, anchor) from query_eq_levers. Every seed must clear
  -- axis_ok: a plate that does not resolve the violation is not a cheaper option. Graded (2D)
  -- plates cannot be expressed by this pass's rigid per-axis apply and are counted only.
  local function mr_seeds(all)
    if not (all[1] and all[1].a) then return end
    local A, B = all[1].start, all[1].a
    local have = {}
    local function sig(set, dx, dy)
      local ids = {}
      for r in pairs(set) do ids[#ids + 1] = r end
      table.sort(ids)                        -- never pairs() order in a signature
      return table.concat(ids, ",") .. "|" .. dx .. "," .. dy
    end
    for _, o in ipairs(all) do
      have[sig(o.set, (o.axis == 1) and o.s or 0, (o.axis == 2) and o.s or 0)] = true
    end
    -- no pcall around this: it reaches elro.bg_tick, and stock Lua 5.1 cannot yield across a
    -- pcall (background relayout only)
    local out = {}
    for _, c in ipairs(query_eq_levers(A, B, nil, TUNE.eqGuilloCap)) do
      if c.set and not c.deltas then
        local dx = (c.dx or 0) * (c.dist or 0)
        local dy = (c.dy or 0) * (c.dist or 0)
        if (dx == 0) ~= (dy == 0) and not have[sig(c.set, dx, dy)] then
          local cand = { set = c.set, n = c.rooms or 0, ek = c.ek,
                         axis = (dx ~= 0) and 1 or 2, s = (dx ~= 0) and dx or dy,
                         start = c.eqStart or A, a = c.eqAnchor or B, seeded = true }
          local snap = {}
          for r in pairs(cand.set) do
            snap[r] = coord[r]
            local p = coord[r]
            coord[r] = (cand.axis == 1) and { p[1] + cand.s, p[2] } or { p[1], p[2] + cand.s }
          end
          rebuild_occ()
          local okAxis = axis_ok(cand.axis)
          for r, p in pairs(snap) do coord[r] = p end
          rebuild_occ()
          if okAxis then
            have[sig(cand.set, dx, dy)] = true
            out[#out + 1] = cand
          end
        end
      elseif c.set then
        elro._mrs2D = (elro._mrs2D or 0) + 1     -- graded: stage 2 territory
      end
    end
    return out
  end
  local function best(la, lb)
    local all = {}
    for _, lst in ipairs({ la or {}, lb or {} }) do
      for _, o in ipairs(lst) do all[#all + 1] = o end
    end
    -- seeds are added before the lone-option early-out; timed separately since mr_seeds runs
    -- the whole eq generator
    if #all > 0 then
      local _ms0 = elro.timeGuillo and CLK()
      local seeds = mr_seeds(all) or {}
      if _ms0 then elro._mrsT = (elro._mrsT or 0) + (CLK() - _ms0)
        elro._mrsN = (elro._mrsN or 0) + 1 end
      for _, c in ipairs(seeds) do
        all[#all + 1] = c ; elro._mrSeedAdd = (elro._mrSeedAdd or 0) + 1
      end
    end
    if #all < 2 then return all[1] end
    elro._mrOpts = (elro._mrOpts or 0) + 1
    local pick, key
    local rows = {}                 -- display only, printed ranked after the pick is decided
    for _, o in ipairs(all) do
      -- probe first, then score the composed set; the set is written back onto the option so
      -- apply moves what was priced. v's own attach edge is deliberately NOT priced here (no
      -- `extra`): it is the designated release valve, and pricing it measured worse.
      local ov, roe, x, sc, cset, cn, ctrail, lie = probe(o)
      -- if a level fired, try the carry form on the same key
      if ctrail then
        local ov2, roe2, x2, sc2, cset2, cn2, ctrail2, lie2 = probe(o, true)
        if ctrail2 then
          local a, b = { ov2, lie2, roe2, x2, sc2 }, { ov, lie, roe, x, sc }
          for i = 1, 5 do
            if a[i] ~= b[i] then
              if a[i] < b[i] then
                ov, roe, x, sc, cset, cn, ctrail, lie = ov2, roe2, x2, sc2, cset2, cn2, ctrail2, lie2
                elro._mrCascCarry = (elro._mrCascCarry or 0) + 1
              end
              break
            end
          end
        end
      end
      if ctrail then o.set, o.n, o.cascade = cset, cn, ctrail end
      local sg, dg = eqw_shared_grow(o.set, o.axis, o.s)
      -- key order: defects by severity, then diagonals tipped (dg), then tightest face grown
      -- (sg), then length, then size. dg above sc is a deliberate preference; dg above sg is
      -- the rule that a diagonal is protected before a shared wall.
      local k = { ov, lie, roe, x, dg, sg, sc, o.n }
      if lie > 0 then elro._mrLie = (elro._mrLie or 0) + 1 end
      rows[#rows + 1] = { i = #rows + 1, o = o, k = k, ov = ov, roe = roe, x = x,
                          sg = sg, dg = dg, sc = sc, lie = lie }
      if not pick then pick, key = o, k else
        for i = 1, 8 do
          if k[i] ~= key[i] then
            if k[i] < key[i] then pick, key = o, k end
            break
          end
        end
      end
    end
    -- display only: pick is already decided
    table.sort(rows, function(a, b)
      for i = 1, 8 do if a.k[i] ~= b.k[i] then return a.k[i] < b.k[i] end end
      return a.i < b.i
    end)
    ctrace(false, "<grey>  options (best first; ranked on defects, then 45s, then shared walls,"
      .. " then length, then size):")
    for _, r in ipairs(rows) do
      local col = (r.o == pick) and "green" or "grey"
      local function dn(n)
        return (n > 0) and string.format("<red>%d<%s>", n, col) or tostring(n)
      end
      ctrace(false, "<%s>  plate  %-12s overlap=%s lie=%s room-edge=%s cross=%s  sg=%-5s dg=%d"
        .. "  length=%d  (rooms=%d)%s  %s",
        col, plate_label(r.o.start, r.o.axis, r.o.s), dn(r.ov), dn(r.lie or 0), dn(r.roe), dn(r.x),
        sgtxt(r.sg), r.dg, r.sc, r.o.n,
        -- the label names the first pull; the counts are the composed move's
        (r.o.cascade and (" [+casc " .. r.o.cascade .. "]") or "")
          .. (r.o.rigid and " [45-rigid]" or ""),
        (r.o == pick) and "PICKED" or "ranked-lower")
    end
    if pick and pick.seeded then elro._mrSeedWin = (elro._mrSeedWin or 0) + 1 end
    return pick
  end
  -- signature of read(axis), the loop's only control input: a round that leaves it unchanged
  -- would ask for the same correction again, so the loop stalls instead
  local function rsig(axis)
    local eqs, lo, hi = read(axis)
    local t = {}
    for _, e in ipairs(eqs) do t[#t + 1] = e.w .. "=" .. e.val end
    table.sort(t)                       -- pairs(adj) order must not reach a control decision
    return table.concat(t, ",") .. "|" .. tostring(lo) .. "|" .. tostring(hi)
  end
  for axis = 1, 2 do
    local guard = 0
    local psig = nil
    while guard < 4 do
      guard = guard + 1
      local sig = rsig(axis)
      if psig then
        elro._mrIter = (elro._mrIter or 0) + 1
        if sig == psig then
          elro._mrStall = (elro._mrStall or 0) + 1
          break
        end
      end
      psig = sig
      local eqs, lo, hi, loW, hiW = read(axis)
      -- (1) equality conflict: bring every dissenting pin onto the first one's value
      local fixed = false
      if #eqs > 1 then
        for i = 2, #eqs do
          if eqs[i].val ~= eqs[1].val then
            local o = best(try_shift(axis, eqs[i].w, eqs[1].val - eqs[i].val, eqs[1].w),
                           try_shift(axis, eqs[1].w, eqs[i].val - eqs[1].val, eqs[i].w))
            if not o then return nil end
            apply(o) ; fixed = true ; break
          end
        end
      end
      if not fixed then
        -- (2) empty interval: open it by the deficit, from whichever side lands cleanest
        local want = (#eqs > 0) and eqs[1].val or nil
        local need = 0
        if lo and hi and lo > hi then need = lo - hi
        elseif want and lo and want < lo then need = lo - want
        elseif want and hi and want > hi then need = want - hi end
        if need == 0 then break end
        -- every branch offers both sides: move the bound to meet the pin, or the pin's class
        -- to meet the bound (opposite sign)
        local o
        if lo and hi and lo > hi then
          o = best(hiW and try_shift(axis, hiW, need, loW) or nil,
                   loW and try_shift(axis, loW, -need, hiW) or nil)
        elseif want and lo and want < lo then
          o = best(loW and try_shift(axis, loW, -need, eqs[1].w) or nil,
                   try_shift(axis, eqs[1].w, need, loW))
        else
          o = best(hiW and try_shift(axis, hiW, need, eqs[1].w) or nil,
                   try_shift(axis, eqs[1].w, -need, hiW))
        end
        if not o then return nil end
        apply(o)
      end
    end
  end
  if not restore then return nil end        -- nothing needed repairing
  -- did it work? every placed neighbour must now admit a truthful spot for v
  local eqs1, lo1, hi1 = read(1)
  local eqs2, lo2, hi2 = read(2)
  local function pick(eqs, lo, hi, fallback)
    local val = (#eqs > 0) and eqs[1].val or fallback
    for i = 2, #eqs do if eqs[i].val ~= val then return nil end end
    if lo and val < lo then return nil end
    if hi and val > hi then return nil end
    return val
  end
  local x = pick(eqs1, lo1, hi1, coord[u][1] + de[1])
  local y = pick(eqs2, lo2, hi2, coord[u][2] + de[2])
  -- gate by kind: overlaps and room-on-edge may not increase; crossings may, since a crossing
  -- is cheaper than leaving v at a cell that contradicts its own constraints
  local after, aOv, aRoe, aX = nil, nil, nil, nil
  if x and y then after, aOv, aRoe, aX = elro.count_defects(coord, placed, pedges) end
  local accept = x and y and aOv <= bOv and aRoe <= bRoe
  if accept then
    elro.tr(string.format("  eqw make-room %d -> (%d,%d) (defects %d -> %d%s)", v, x, y, before, after,
      (aX > bX) and string.format("; +%d crossing(s), accepted to keep the edge truthful", aX - bX) or ""))
    return { x, y }
  end
  for r, p in pairs(restore) do coord[r] = p end ; rebuild_occ()
  elro.tr(string.format("  eqw make-room %d: REVERTED (%s)", v,
    (not (x and y)) and "still infeasible"
      or string.format("would add defects: overlap %d->%d, room-edge %d->%d", bOv, aOv, bRoe, aRoe)))
  return nil
end

function elro.eqw_close_core_1(W, v, w, del)
  local AXIS_WORD, DELTA, adj, cand_shift, class_seam, class_shearfree_seeds, coord, cross_convert = W.AXIS_WORD, W.DELTA, W.adj, W.cand_shift, W.class_seam, W.class_shearfree_seeds, W.coord, W.cross_convert
  local crossing_bounds, ctrace, defect_blocker, defective, det_sweep, eqw_classes, eqw_compact, eqw_field_shift = W.crossing_bounds, W.ctrace, W.defect_blocker, W.defective, W.det_sweep, W.eqw_classes, W.eqw_compact, W.eqw_field_shift
  local eqw_forced_shift, eqw_score, eqw_shared_grow, eqw_topo_cross, eqw_wire_cross, on_edge_now, pedges, placed = W.eqw_forced_shift, W.eqw_score, W.eqw_shared_grow, W.eqw_topo_cross, W.eqw_wire_cross, W.on_edge_now, W.pedges, W.placed
  local plate_label, query_cut_levers, query_ring_dilate_levers, rebuild_occ, ring_free_rider, ring_shear_at, roomedge_set, sgtxt = W.plate_label, W.query_cut_levers, W.query_ring_dilate_levers, W.rebuild_occ, W.ring_free_rider, W.ring_shear_at, W.roomedge_set, W.sgtxt
  local pa = (del[1] ~= 0) and 2 or 1          -- perpendicular axis (AXIAL del only)
  local da = 3 - pa                            -- del axis
  -- Per-axis debt. An axial del asserts one equality and one ordering; a diagonal del asserts
  -- no equality, only two orderings. Treating a diagonal as pure-x would flatten it.
  local mL = elro.min_len(v, w)
  -- `tight`: pull to the minimum, do not merely accept the direction. A truthful edge fifteen
  -- cells long is where a loop's area comes from; this is the last pass with the equations.
  local function need_on(axis, tight)          -- required change in coord[w][axis]-coord[v][axis]
    local cur = coord[w][axis] - coord[v][axis]
    if del[axis] == 0 then return -cur end             -- equality: land on v's lane
    if not tight then
      if del[1] ~= 0 and del[2] ~= 0 then
        -- A diagonal that must move lands on a 45: both components go to the shorter one (never
        -- under the minimum). A diagonal that owes nothing on either axis is left alone -- it is
        -- truthful, and the tighten/squarify pass below is what squares it.
        local o1, o2 = coord[w][1] - coord[v][1], coord[w][2] - coord[v][2]
        if o1 * del[1] >= mL and o2 * del[2] >= mL then return 0 end
        if o1 < 0 then o1 = -o1 end ; if o2 < 0 then o2 = -o2 end
        local T = (o1 < o2) and o1 or o2 ; if T < mL then T = mL end
        return del[axis] * T - cur
      end
      if cur * del[axis] >= mL then return 0 end       -- ordering: far enough the right way
      return del[axis] * mL - cur                      -- pull to exactly the minimum
    end
    local L = (cur < 0) and -cur or cur
    if L <= mL then return 0 end                       -- already tight on this axis
    if tight == 2 then return del[axis] * mL - cur end -- the whole slack in one move
    return -del[axis]                                  -- ...or shorten by exactly one cell
  end
  -- how many cells this edge carries BEYOND its minimum (0 = already tight)
  local function excess()
    local e = 0
    for a = 1, 2 do
      if del[a] ~= 0 then
        local cur = coord[w][a] - coord[v][a]
        local L = (cur < 0) and -cur or cur
        if L > mL then e = e + (L - mL) end
      end
    end
    return e
  end
  local function truthful() return need_on(1) == 0 and need_on(2) == 0 end
  -- Trace what the closure did, including nothing and why: the edge is usually already
  -- truthful on arrival and a silent return is indistinguishable from a pass that ran.
  local tightPass = 1
  local function ctr(quiet, ...) return ctrace(quiet or (tightPass > 1), ...) end
  elro._eqcEntry = (elro._eqcEntry or 0) + 1
  local off1, off2 = coord[w][1] - coord[v][1], coord[w][2] - coord[v][2]
  -- TIGHTEN MODE: the edge is already truthful but carries slack. Nothing is owed, so a failure
  -- here is not a failed closure -- it reverts and the edge keeps the state it arrived in.
  local tighten = false
  local closedSkew = false   -- an untruthful diagonal closed off-45: the squarify re-solve runs for it too
  if truthful() then
    local ex = excess()
    if not (ex > 0) then
      elro._eqcAlready = (elro._eqcAlready or 0) + 1
      ctr(true, "[close] %d-%d del=(%d,%d) off=(%d,%d) min=%d -- NOT RUN: %s", v, w, del[1], del[2],
        off1, off2, mL,
        (ex > 0) and string.format("truthful but %d cell(s) OVER its minimum"
          .. " (the tighten pass will try to pull it in)", ex)
                  or "the edge is already truthful AND tight; there is nothing to choose")
      return true, false
    end
    tighten = true
    elro._eqcTight = (elro._eqcTight or 0) + 1
    ctr(false, "[close] %d-%d del=(%d,%d) off=(%d,%d) min=%d -- TIGHTEN: truthful but %d cell(s)"
      .. " over the minimum", v, w, del[1], del[2], off1, off2, mL, ex)
  else
    ctr(false, "[close] %d-%d del=(%d,%d) off=(%d,%d) min=%d -- owes x %+d y %+d", v, w, del[1],
      del[2], off1, off2, mL, need_on(1), need_on(2))
  end
  -- The closure is where room-on-edge defects are born: the walk is never stuck here, this
  -- pass is what accepts. `ccWatch` diffs incidences before/after so each new one is handed
  -- to the crossing conversion.
  local ccWatch = true
                  and (function()
                         if eqw_wire_cross().n > 0 then return true end
                         local T = eqw_topo_cross() ; return T.n > 0 or T.nsite > 0
                       end)()
  local ccBefore = ccWatch and roomedge_set(nil) or nil
  -- Diff the incidences and hand each NEW one to the conversion. Keys are `room@u:w`, so the
  -- triple is read straight back out of the key -- no second detector pass, and no guessing which
  -- of several defects this closure is responsible for.
  local function cc_after(tag)
    if not ccBefore then return end
    local after = roomedge_set(nil)
    for k in pairs(after) do
      if not ccBefore[k] then
        local r, a, b = K.roomedge_parse(k)
        if r then
          r, a, b = tonumber(r), tonumber(a), tonumber(b)
          if on_edge_now(r, a, b) and cross_convert(r, { r, a, b }, "close:" .. tag) then
            elro.tr(string.format("  eqw close %d-%d (%s): the room-on-edge it created was"
              .. " CONVERTED to a crossing", v, w, tag))
            return
          end
        end
      end
    end
  end
  -- Equation-driven closure: the offset is known exactly and the row/col equalities say which
  -- rooms travel with each endpoint, so the cut is calculated, not searched. Two starting
  -- points (pull w's side, push v's side), each expanded by eqw_forced_shift; cheaper valid wins.
  local eqCls, eqMem = eqw_classes(v, w)
  local eqRestore = {}
  -- `dl` (optional): per-room deltas on `axis`. Without it every room takes `sh` (the 1D
  -- contract). assert_eq flattens a class whose members disagree, so its rooms differ and
  -- `sh` may not overwrite them; a room absent from `dl` still takes `sh`.
  local function eq_apply(set, axis, sh, dl)
    for r in pairs(set) do
      if eqRestore[r] == nil then eqRestore[r] = coord[r] end

      local p = coord[r]
      local sr = (dl and dl[r]) or sh
      coord[r] = (axis == 1) and { p[1] + sr, p[2] } or { p[1], p[2] + sr }
    end
    rebuild_occ()
  end
  -- Close `axis` by `need`. Mode C: assert the equality directly -- relax every class to the
  -- least solution above where things are (Bellman-Ford over the ordering constraints), so a
  -- class whose placed members disagree is flattened rather than translated.
  local function assert_eq(axis)
    if del[axis] ~= 0 then return nil, "not-an-equality-axis" end
    local p1 = {}
    local function find1(r)
      local x = p1[r] ; if x == nil then p1[r] = r ; return r end
      while p1[x] ~= x do p1[x] = p1[p1[x]] ; x = p1[x] end
      p1[r] = x ; return x
    end
    local function uni1(r, x)
      local a1, b1 = find1(r), find1(x) ; if a1 ~= b1 then p1[a1] = b1 end
    end
    -- Seeded from `eqCls` (built over the whole graph), not from placed edges alone: an equality
    -- asserted through unplaced rooms must still arrive here.
    local C = eqCls[axis]
    for r in pairs(placed) do
      local c = C[r] ; if c and c ~= r then uni1(r, c) end
    end
    for r in pairs(placed) do
      if coord[r] then
        for d, x in each_exit(adj[r]) do
          local de = DELTA[d]
          if de and de[axis] == 0 and de[3 - axis] ~= 0 and placed[x] and coord[x] then
            uni1(r, x)
          end
        end
      end
    end
    -- Arming is measured BEFORE the closure edge is unioned: mode C earns its place only where
    -- an equality is asserted but not realised; elsewhere the two forms are identical.
    local preflat = 0
    do
      local seen = {}
      for r in pairs(placed) do
        if coord[r] then
          local c = find1(r)
          local q = seen[c]
          if q == nil then seen[c] = coord[r][axis]
          elseif q ~= coord[r][axis] and q ~= true then seen[c] = true ; preflat = preflat + 1 end
        end
      end
    end
    if preflat == 0 then return nil, "all-flat" end
    uni1(v, w)                                  -- the closure edge, which pass 1 refuses
    local mem = {}
    for r in pairs(placed) do
      if coord[r] then
        local c = find1(r)
        local m = mem[c] ; if not m then m = {} ; mem[c] = m end
        m[#m + 1] = r
      end
    end
    local Y, nCls = {}, 0
    for c, l in pairs(mem) do
      nCls = nCls + 1
      local lo
      for i = 1, #l do
        local vv = coord[l[i]][axis]
        if lo == nil or vv < lo then lo = vv end
      end
      -- Least solution above where things are: start every class at its minimum and only raise,
      -- so nothing moves unless a constraint forces it.
      Y[c] = lo
    end
    -- ---- the inequalities: for a placed edge ALONG `axis`, `Y[hi] >= Y[lo] + m` --------------
    local cons, nc = {}, 0
    for r in pairs(placed) do
      local pr = coord[r]
      if pr then
        for d, x in each_exit(adj[r]) do
          local de = DELTA[d]
          if de and de[axis] ~= 0 and placed[x] and coord[x] then
            local cr, cx = find1(r), find1(x)
            if cr ~= cx then
              local sg = de[axis]
              -- A diagonal's minimum is on its length, not per component: per axis it owes only sign and >= 1.
              local m = (de[3 - axis] ~= 0) and 1 or elro.min_len(r, x)
              local g = coord[x][axis] - pr[axis]
              -- Only a currently-legal edge constrains; otherwise the solve also repairs violations the
              -- closure never touched.
              if sg * g >= m then
                nc = nc + 1
                cons[nc] = (sg > 0) and { cr, cx, m } or { cx, cr, m }
              end
            end
          end
        end
      end
    end
    -- An accepted crossing keeps its side (same source and same holds-now guard as relax_room).
    local XBc = crossing_bounds()
    if XBc then
      for r in pairs(placed) do
        local bl = XBc[r]
        if bl then
          for i = 1, #bl do
            local b = bl[i]
            -- Records are filed under both endpoints; take each from the `hi` side only.
            if b[3] == axis and b[1] == r then
              local hi, lo = b[1], b[2]
              if coord[hi] and coord[lo] and placed[hi] and placed[lo] then
                local ch, cl = find1(hi), find1(lo)
                if ch ~= cl and (coord[hi][axis] - coord[lo][axis]) >= 1 then
                  nc = nc + 1 ; cons[nc] = { cl, ch, 1 }
                end
              end
            end
          end
        end
      end
    end
    -- Bellman-Ford's bound: nCls sweeps settle unless there is a positive cycle, in which case
    -- there is no solution -- running out of rounds is a VOID, never a truncated answer.
    local settled = false
    for _ = 1, nCls + 1 do
      local ch2 = false
      for i = 1, nc do
        local k = cons[i]
        local nv = Y[k[1]] + k[3]
        if Y[k[2]] < nv then Y[k[2]] = nv ; ch2 = true end
      end
      if not ch2 then settled = true ; break end
    end
    if not settled then return nil, "positive-cycle" end
    if find1(v) ~= find1(w) then return nil, "not-merged" end
    local set, dl, n = {}, {}, 0
    for c, l in pairs(mem) do
      local yc = Y[c]
      for i = 1, #l do
        local r = l[i]
        local d2 = yc - coord[r][axis]
        if d2 ~= 0 then
          n = n + 1
          if n > TUNE.eqwShiftCap then return nil, "cap" end
          set[r] = true ; dl[r] = d2
        end
      end
    end
    if n == 0 then return nil, "no-op" end
    return set, dl, n
  end
  local carry = {}
  local function eq_phase(axis, need, hint)
    if need == 0 then return true end
    if elro.timeGuillo then elro._clPhN = (elro._clPhN or 0) + 1
      elro._clPhHint = (elro._clPhHint or 0) + (hint and 1 or 0) end
    local want = (coord[w][axis] - coord[v][axis]) + need
    local depth = math.max(1, TUNE.eqwCascadeDepth)
    local opts = {}
    -- Options that never produced a plate go in the same trace block as the ones that did.
    local voids = {}
    -- the carried option restricts BOTH the side and the rigidity; without a hint this is the
    -- full pair of sides and both rigidities, exactly as before
    local sides = { { s = w, sh = need, a = v }, { s = v, sh = -need, a = w } }
    if hint then
      sides = { hint.side == "w" and { s = w, sh = need, a = v }
                                  or { s = v, sh = -need, a = w } }
    end
    -- A tighten seeds the ring's extremes and ONLY those: the closure rooms are non-extreme and
    -- cannot pull the extent in. Extreme seeds are scanned inward when the extreme is blocked.
    if tighten and not hint and elro._ring_of then
      local rg = elro._ring_of(v, w)
      if rg and #rg >= 4 then
        local lo, hi
        for i = 1, #rg do
          local r2 = rg[i] ; local pp = coord[r2]
          if pp then
            if not hi or pp[axis] > coord[hi][axis]
               or (pp[axis] == coord[hi][axis] and r2 < hi) then hi = r2 end
            if not lo or pp[axis] < coord[lo][axis]
               or (pp[axis] == coord[lo][axis] and r2 < lo) then lo = r2 end
          end
        end
        if lo and hi and lo ~= hi then
          local mag = (need < 0) and -need or need
          sides = { { s = hi, sh = -mag, a = lo }, { s = lo, sh = mag, a = hi } }
          elro._tesUsed = (elro._tesUsed or 0) + 1
        else
          elro._tesSkip = (elro._tesSkip or 0) + 1
        end
      else
        elro._tesSkip = (elro._tesSkip or 0) + 1
      end
    end
    -- Pin escalation: pin what the plate would drag into a conflict and move BOTH closure ends
    -- further out until clear. TUNE.closePinEscalate is the cost cap on how far the pair walks
    -- (0 = off). A bare pin alone is usually infeasible; the escalation makes it expressible.
    local function pin_escalate(sIn, shIn, aIn, mv)
      if not mv then return nil end
      local dir = (shIn > 0) and 1 or -1
      -- 1. what would this plate drag into a conflict? (trial-apply, then the engine's own
      --    detectors -- crossing, room-on-edge and edge-on-room, in the severity order)
      local snap = {}
      for r in pairs(mv) do
        snap[r] = coord[r]
        local pp = coord[r]
        coord[r] = (axis == 1) and { pp[1] + shIn, pp[2] } or { pp[1], pp[2] + shIn }
      end
      rebuild_occ()
      local xi, rc, cen = det_sweep()
      local vic, nvic = {}, 0
      local ids = {}
      for r in pairs(mv) do ids[#ids + 1] = r end
      table.sort(ids)                 -- never `pairs` order: this becomes a seed map
      for _, r in ipairs(ids) do
        if r ~= sIn and r ~= aIn and coord[r] and defective(r, xi, rc, cen) then
          vic[#vic + 1] = r ; nvic = nvic + 1
        end
      end
      for r, pp in pairs(snap) do coord[r] = pp end
      rebuild_occ()
      if nvic == 0 then return nil end
      elro._peN = (elro._peN or 0) + 1
      -- 2. pin them where they are, and walk both closure ends out until nothing is left on them
      for k = 1, TUNE.closePinEscalate do
        local sm2 = {}
        for i2 = 1, nvic do sm2[vic[i2]] = { 0, 0 } end
        sm2[sIn] = (axis == 1) and { shIn + dir * k, 0 } or { 0, shIn + dir * k }
        sm2[aIn] = (axis == 1) and { dir * k, 0 } or { 0, dir * k }
        local set2, dl2 = eqw_field_shift(eqCls, eqMem, sm2, vic[1], nil, nil, sIn)
        if set2 and dl2 then
          local snap2, n2, dl = {}, 0, {}
          for r in pairs(set2) do
            local d0 = dl2[r]
            dl[r] = d0 and d0[axis] or 0
            snap2[r] = coord[r]
            local pp = coord[r]
            coord[r] = (axis == 1) and { pp[1] + dl[r], pp[2] } or { pp[1], pp[2] + dl[r] }
            n2 = n2 + 1
          end
          rebuild_occ()
          local xi2, rc2, cen2 = det_sweep()
          local clean = true
          for r in pairs(set2) do
            if r ~= sIn and coord[r] and defective(r, xi2, rc2, cen2) then clean = false ; break end
          end
          -- ...and it may not pay for the repair with a LIE: `defective` says nothing about
          -- truthfulness, and an escalated plate moves rooms by different amounts, so also check
          -- that no edge with one end inside is bent off its declared direction.
          if clean then
            for r in pairs(set2) do
              local pr = coord[r]
              if pr then
                for d2, x2 in each_exit(adj[r]) do
                  local de2 = DELTA[d2]
                  if de2 and (de2[1] ~= 0 or de2[2] ~= 0) and placed[x2] and coord[x2] then
                    local q0, q1 = snap2[r] or pr, snap2[x2] or coord[x2]
                    if elro.edge_truthful(de2, q1[1] - q0[1], q1[2] - q0[2])
                       and not elro.edge_truthful(de2, coord[x2][1] - pr[1],
                                                       coord[x2][2] - pr[2]) then
                      clean = false ; break
                    end
                  end
                end
              end
              if not clean then break end
            end
          end
          for r, pp in pairs(snap2) do coord[r] = pp end
          rebuild_occ()
          if clean then
            elro._peOK = (elro._peOK or 0) + 1
            elro._peK = (elro._peK or 0) + k
            return set2, n2, dl
          end
        end
      end
      elro._peNo = (elro._peNo or 0) + 1
      return nil
    end
    for _, o in ipairs(sides) do
      -- Not `cond and f() or nil`: an and/or expression drops the second return value.
      local mv, n, mvdl
      if not (hint and hint.rigid) then
        mv, n = eqw_forced_shift(eqCls, eqMem, axis, o.s, o.sh, o.a)
        local p2, pn, pdl = pin_escalate(o.s, o.sh, o.a, mv)
        if p2 then mv, n, mvdl = p2, pn, pdl end
      end
      -- The carry deliberately does not pin the seam variants: the :sf/:t/:sf:t reseeds are
      -- generated underneath the hint regardless.
      if mv then
        opts[#opts + 1] = { set = mv, sh = o.sh, n = n, s = o.s, a = o.a,
                            dl = mvdl, ae = mvdl and true or nil,
                            ann = mvdl and "pin" or nil }
      end
      -- The closure's seam family: :sf, :t, :sf:t, the same variants query_eq_levers offers,
      -- gated on fieldClosure.
      if mv then
        local function reseed(sd, ann)
          if not sd or #sd == 0 then return nil end
          local m2, k2 = eqw_forced_shift(eqCls, eqMem, axis, o.s, o.sh, o.a, nil, sd)
          if m2 and k2 ~= n then
            opts[#opts + 1] = { set = m2, sh = o.sh, n = k2, s = o.s, a = o.a, ann = ann }
            elro._csFam = elro._csFam or {}
            elro._csFam[ann] = (elro._csFam[ann] or 0) + 1
            return m2, k2
          end
          return nil
        end
        -- `:sf` stays as a separate arm even though rigidDiag already drags the same rooms in the
        -- solver: dropping it measured worse.
        local sd = class_shearfree_seeds(mv, axis)
        local mvSf, nSf = reseed(sd, "sf")
        -- `:t` / `:sf:t`: the seam walk (elro.seam_walk), the same construction the generator uses
        local function walk(bmv, bn, seeds, ann)
          local m2, k2 = elro.seam_walk(W, { cls = eqCls, mem = eqMem, pa = axis, start = o.s,
            s = o.sh, anchor = o.a, seeds = seeds, mv = bmv, n = bn,
            tag = plate_label(o.s, axis, o.sh) .. ":" .. ann, wkCls = "close:" .. ann })
          if m2 and k2 ~= n then
            opts[#opts + 1] = { set = m2, sh = o.sh, n = k2, s = o.s, a = o.a, ann = ann }
            elro._csFam = elro._csFam or {}
            elro._csFam[ann] = (elro._csFam[ann] or 0) + 1
          end
        end
        walk(mv, n, nil, "t")
        if mvSf then walk(mvSf, nSf, sd, "sf:t") end
      end
      -- and the plate that refuses to shear a settled 45 (see eqw_forced_shift's rigidDiag).
      -- Ranked against the permissive one on eqw_score like any other option -- it wins only
      -- where keeping the diagonal whole is worth what dragging its class costs.
      if mv or (hint and hint.rigid) then
        -- Skip the rigid build when it cannot differ: rigidDiag adds exactly one drag (across a
        -- square truthful diagonal whose far class is outside the plate), so if the finished base
        -- plate has no such boundary diagonal the rigid plate is the base plate.
        local anyDiag = false
        if mv then
          for r in pairs(mv) do
            local cr = coord[r]
            for d, x in each_exit(adj[r]) do
              local de = DELTA[d]
              if de and de[1] ~= 0 and de[2] ~= 0 and placed[x] and coord[x] and not mv[x] and cr then
                local gx, gy = coord[x][1] - cr[1], coord[x][2] - cr[2]
                if math.abs(gx) == math.abs(gy) and gx * de[1] >= 1 and gy * de[2] >= 1 then anyDiag = true ; break end
              end
            end
            if anyDiag then break end
          end
        end
        local mv2, n2
        local skipR = mv and not anyDiag
        if not skipR then
          mv2, n2 = eqw_forced_shift(eqCls, eqMem, axis, o.s, o.sh, o.a, true)
        end
        local kk = skipR and "nodiag>SKIPPED" or ((mv and (anyDiag and "diag" or "nodiag") or "hint")
          .. (mv2 and (n2 ~= n and ">DIFF" or ">same") or ">void"))
        elro._rgCensus = elro._rgCensus or {} ; elro._rgCensus[kk] = (elro._rgCensus[kk] or 0) + 1
        if mv2 and n2 ~= n then
          opts[#opts + 1] = { set = mv2, sh = o.sh, n = n2, s = o.s, a = o.a, rigid = true }
        end
      end
      if not mv and not (hint and hint.rigid) then
        voids[#voids + 1] = { s = o.s, sh = o.sh, why = tostring(n) .. ", no plate on this side" }
        if elro.debug then
          elro.tr(string.format("  eqw-eq axis=%d start=%d sh=%d -> VOID(%s)", axis, o.s, o.sh, tostring(n))) end
      end
    end
    -- Third option: assert the equality (closeAssertEq), ranked on the same key and vetoed by
    -- the same first_bad as the other two. `sh = need` is nominal; the rooms move by `dl`.
    if not hint and del[axis] == 0 then
      local aset, adl, an = assert_eq(axis)
      if aset then
        opts[#opts + 1] = { set = aset, sh = need, n = an, s = w, a = v, dl = adl, ae = true,
                            ann = "ae" }
        elro._aeOpt = (elro._aeOpt or 0) + 1
      else
        local why = tostring(adl)
        voids[#voids + 1] = { s = w, sh = need, why = why .. " (assert-eq)" }
        elro._aeWhy = elro._aeWhy or {} ; elro._aeWhy[why] = (elro._aeWhy[why] or 0) + 1
      end
    end
    -- what is blocking room r -- the structure the next equation shift has to move aside
    -- eqw_score, not the raw L1: an option that closes the loop by shearing a settled 45 has to
    -- pay for it here, or the ranking cannot see the difference at all.
    local baseCost, _, baseSkew = eqw_score()
    local baseLie = lie_set(coord, adj, placed, DELTA)
    -- All options close the same offset, so total injected length is equal; what differs is
    -- which edge carries it. Edges shared by two bounded faces are charged more. Only boundary
    -- edges (one end in the moved set) change length. faceUse absent => term is zero.

    -- carry ONE option to completion; always reverts. -> { set, sh, n, cost } | nil, why
    local function attempt(o)
      -- Snapshot lazily, first-write-wins, only rooms that move (cascade levels included:
      -- a later level must not overwrite the original coordinate).
      local snap = {}
      local wasClean, full, trail = {}, {}, {}
      local function unwind()
        local _u0 = elro.timeGuillo and CLK()
        for r, q in pairs(snap) do coord[r] = q end ; rebuild_occ()
        if _u0 then elro._clPh = elro._clPh or {}
          elro._clPh.unwind = (elro._clPh.unwind or 0) + (CLK() - _u0)
          elro._clPh.unwindN = (elro._clPh.unwindN or 0) + 1 end
      end
      -- A level may not re-shift a room an earlier level already moved: the winner is applied
      -- as ONE eq_apply of the union, so measuring must shift each room once too. Skipping the
      -- overlap is the correct composition (forced shifts are whole classes). Filtered here,
      -- not in eq_apply, which also applies the winner where the whole union must move.
      local function apply(set, tag)
        -- wasClean is sampled BEFORE the set moves, so it really is the room's prior state --
        -- a half-built block already carries defects and only NEW ones may veto.
        local xi, rc, cen
        local fresh = {}
        for r in pairs(set) do
          if not full[r] then
            fresh[r] = true
            if snap[r] == nil then snap[r] = coord[r] end
            if wasClean[r] == nil then
              -- built once, geometry frozen until eq_apply below
              if not xi then xi, rc, cen = det_sweep() end
              wasClean[r] = not defective(r, xi, rc, cen)
            end
          end
        end
        -- o.dl only reaches the option's own level; cascade levels are uniform shifts filtered
        -- against `full`, so mode-C moved rooms are never re-shifted here.
        eq_apply(fresh, axis, o.sh, o.dl)
        for r in pairs(fresh) do full[r] = true end
        trail[#trail + 1] = tag
      end
      local function first_bad()
        local _f0 = elro.timeGuillo and CLK()
        local xi, rc, cen
        local function fin(x)
          if _f0 then elro._clPh = elro._clPh or {}
            elro._clPh.firstbad = (elro._clPh.firstbad or 0) + (CLK() - _f0)
            elro._clPh.firstbadN = (elro._clPh.firstbadN or 0) + 1 end
          return x
        end
        for r in pairs(full) do
          if wasClean[r] then
            if not xi then xi, rc, cen = det_sweep() end
            if defective(r, xi, rc, cen) then return fin(r) end
          end
        end
        return fin(nil)
      end
      apply(o.set, string.format("%d%+d(%dr%s)", o.s, o.sh, o.n, o.rigid and ",45" or ""))
      local why
      -- An assert-equality (mode C) plate takes NO cascade: its rooms move by dl, not a single
      -- sh, so a cascade level built on the nominal sh is a different move and lands on the
      -- closure rooms. OPEN: the right mode-C cascade would be a re-solve with the blocker's
      -- class constrained.
      local depthAE = o.ae and 1 or depth
      for lvl = 1, depthAE do
        if (coord[w][axis] - coord[v][axis]) ~= want then why = "offset" ; break end
        local bad = first_bad()
        if not bad then
          local nm = 0 ; for _ in pairs(full) do nm = nm + 1 end
          local _s0 = elro.timeGuillo and CLK()
          local cost, _, skew = eqw_score()
          if _s0 then elro._clPh = elro._clPh or {}
            elro._clPh.score = (elro._clPh.score or 0) + (CLK() - _s0)
            elro._clPh.scoreN = (elro._clPh.scoreN or 0) + 1 end
          local moved = {} ; for r in pairs(full) do moved[r] = true end
          -- new lies this option would leave (a pinned far side lets a plate walk a room through
          -- its neighbour); measured on the applied geometry, before the unwind
          local lie = new_lies(baseLie, coord, adj, placed, DELTA)
          if lie > 0 then elro._clLie = (elro._clLie or 0) + 1 end
          unwind()
          -- After the unwind: eqw_shared_grow reads the CURRENT geometry and applies sh itself,
          -- and it needs the completed set (cascade levels included), hence its position here.
          local _g0 = elro.timeGuillo and CLK()
          local sg, dg = eqw_shared_grow(moved, axis, o.sh)
          if _g0 then elro._clPh = elro._clPh or {}
            elro._clPh.grow = (elro._clPh.grow or 0) + (CLK() - _g0)
            elro._clPh.growN = (elro._clPh.growN or 0) + 1 end
          -- grow/nmin: cells this cut injects (sg is deliberately blind to that). Computed only
          -- when actually used -- class_seam runs per option and a tighten carries several
          -- options per cell of slack.
          local grow, nmin
          if elro.probeSeam then
            local _, _, nAtMin, _, gr = class_seam(moved, axis, o.sh)
            grow, nmin = gr, nAtMin
          end
          return { set = moved, sh = o.sh, n = nm, cost = cost, skew = skew, sg = sg, dg = dg,
                   grow = grow, nmin = nmin, s = o.s, trail = trail, dl = o.dl, ae = o.ae,
                   lie = lie }
        end
        if lvl == depthAE then
          why = (o.ae and "defect@" or "depth@") .. bad ; break end
        local blk, kind = defect_blocker(bad)
        if not blk then why = "no-blocker@" .. bad ; break end
        -- a rigid option stays rigid all the way down: its premise is that settled 45s do not
        -- shear, and a cascade level that shears one would undo what the option was chosen for.
        local mv2, r2 = eqw_forced_shift(eqCls, eqMem, axis, blk, o.sh, o.a, o.rigid)
        if not mv2 then
          why = string.format("cascade-void@%d %s(%s)", blk, tostring(kind), tostring(r2)) ; break
        end
        apply(mv2, string.format("%d%+d(%dr,%s)", blk, o.sh, elro.tcount(mv2), tostring(kind)))
      end
      unwind()
      return nil, why, trail
    end
    -- Rank tuple (not an edge key): dg = diagonals this option would lengthen (off-45),
    -- sg = sum of other faces sharing each grown edge. Both sit above cost -- they decide
    -- WHERE the length goes; cost (total L1) is the same for every option and only ties.
    -- dg before sg, matching eqw_make_room, so the two ranking sites cannot drift apart.
    -- `grow` is measured and shown but deliberately not in the key.
    local function rank_key(r)
      return { r.lie or 0, r.dg or 0, r.sg or 0, r.cost, r.n }
    end
    local best, bestK
    local viable = {}
    -- Display only: option lines are buffered so they print ranked, like the collision dump.
    -- Selection is untouched -- best is still chosen in evaluation order below.
    local rows = {}
    for _, z in ipairs(voids) do
      rows[#rows + 1] = { i = #rows + 1, s = z.s, sh = z.sh, why = z.why }
    end
    for _, o in ipairs(opts) do
      local _at0 = elro.timeGuillo and CLK()
      local res, why, trail = attempt(o)
      if _at0 then elro._clAttT = (elro._clAttT or 0) + (CLK() - _at0)
        elro._clAttN = (elro._clAttN or 0) + 1 end
      if elro.debug then
        elro.tr(string.format("  eqw-eq axis=%d start=%d sh=%+d [%s] -> %s", axis, o.s, o.sh,
          table.concat((res and res.trail) or trail or {}, " + "),
          res and string.format("OK %dr cost %d->%d sg=%s dg=%d", res.n, baseCost, res.cost,
                                sgtxt(res.sg), res.dg or 0)
              or ("rej(" .. tostring(why) .. ")")))
      end
      local row = { i = #rows + 1, s = o.s, sh = o.sh, res = res, why = why, rigid = o.rigid,
                    ann = o.ann,
                    trail = table.concat((res and res.trail) or trail or {}, " + ") }
      rows[#rows + 1] = row
      -- A tighten may not buy area with a 45: a tighten is optional (the edge is already
      -- truthful), so any option leaving more sheared diagonals than it found is refused
      -- outright; if that empties the pool the slack stays. A closure must land its offset,
      -- so there dg is only a preference.
      if res and tighten and (res.skew or 0) > baseSkew then
        row.refused = string.format("REFUSED: shears %d more diagonal(s)", res.skew - baseSkew)
        elro._eqcTightShear = (elro._eqcTightShear or 0) + 1
        res = nil
      end
      if res then
        viable[#viable + 1] = res
        local k = rank_key(res)
        if not best then best, bestK = res, k else
          for i = 1, 5 do
            if k[i] ~= bestK[i] then
              if k[i] < bestK[i] then best, bestK = res, k end
              break
            end
          end
        end
      end
    end
    -- _eqcOpts = closures that had a choice at all; _eqcFlip = choices the sg/dg key decided
    -- differently from the old cost-then-size rule.
    if #viable > 1 then
      elro._eqcOpts = (elro._eqcOpts or 0) + 1
      local old
      for _, r in ipairs(viable) do
        if not old or r.cost < old.cost or (r.cost == old.cost and r.n < old.n) then old = r end
      end
      if old ~= best then elro._eqcFlip = (elro._eqcFlip or 0) + 1 end
    end
    elro._eqcCall = (elro._eqcCall or 0) + 1
    -- Options block in the collision dump's shape: one line per option, best first, with a
    -- verdict (PICKED / ranked-lower / REFUSED / VOID). Rejected options stay in the list.
    local order = "new lies, then 45s, then shared walls, then cost, then size"
    -- rank for DISPLAY: viable by the same `ekey` the pick used, then refused, then void. `i` is
    -- the evaluation index and makes the order total, so the block cannot depend on sort stability.
    local function rowkey(r)
      if r.res then local k = rank_key(r.res) ; return { 0, k[1], k[2], k[3], k[4], k[5], r.i } end
      return { r.refused and 1 or 2, 0, 0, 0, 0, 0, r.i }
    end
    table.sort(rows, function(a, b)
      local ka, kb = rowkey(a), rowkey(b)
      for i = 1, 7 do if ka[i] ~= kb[i] then return ka[i] < kb[i] end end
      return false
    end)
    if #rows > 0 then
      ctr(false, "<grey>  %s options (best first; ranked on %s):", AXIS_WORD[axis] or "?", order)
    end
    for _, r in ipairs(rows) do
      -- the collision dump's palette, so the two blocks read the same way: GREEN is the pick,
      -- GREY is a live option that lost on the key, RED is whatever REJECTED an option.
      local col, verdict
      if r.res == best and best then col, verdict = "green", "PICKED"
      elseif r.res then col, verdict = "grey", "ranked-lower"
      elseif r.refused then col, verdict = "red", r.refused
      else col, verdict = "red", "VOID (" .. tostring(r.why) .. ")" end
      if r.res then
        ctr(false, "<%s>  plate  %-12s lie=%d cost %d->%d  sg=%-5s dg=%d  (rooms=%d)%s  %s",
          col, plate_label(r.s or -1, axis, r.sh) .. (r.ann and (":" .. r.ann) or "")
            .. (r.res.grow and string.format(" grow=%d/%d", r.res.grow, r.res.nmin or 0) or ""),
          r.res.lie or 0, baseCost, r.res.cost, sgtxt(r.res.sg),
          r.res.dg or 0, r.res.n, r.rigid and " [45-rigid]" or "", verdict)
      else
        -- Keep the annotation on rejected rows too, or a voided variant prints the same label
        -- as the plain option it derived from.
        ctr(false, "<%s>  plate  %-12s %s%s", col,
          plate_label(r.s or -1, axis, r.sh) .. (r.ann and (":" .. r.ann) or ""),
          verdict, r.rigid and "  [45-rigid]" or "")
      end
      -- the cascade trail is what actually moved; keep it, but out of the aligned columns
      if r.res and r.trail ~= "" and r.trail ~= string.format("%d%+d(%dr)", r.s or -1, r.sh, r.res.n) then
        ctr(false, "<grey>           via %s", r.trail)
      end
    end
    if not best then
      -- A carry probe that finds nothing is not a failed phase -- the caller re-runs the full
      -- search, so stay silent and let the real pass speak.
      if hint then elro._ccMiss = (elro._ccMiss or 0) + 1 ; return false end
      ctr(false, "<red>  %s -> NO viable option: %s", AXIS_WORD[axis] or "?",
        tighten and "the slack stays where it is" or "the edge stays untruthful")
      return false
    end
    -- remember the side+rigidity that won, for the next unit pass of this same tighten.
    -- An assert-equality win carries nothing: mode C picked no side, its nominal s/sh are
    -- label-only.
    carry[axis] = (not best.ae)
      and { side = (best.s == w) and "w" or "v", rigid = best.rigid or false } or nil
    if hint then elro._ccHit = (elro._ccHit or 0) + 1 end
    if best.ae then elro._aePick = (elro._aePick or 0) + 1 end
    eq_apply(best.set, axis, best.sh, best.dl)
    elro.tr(string.format("  eqw-eq axis=%d APPLY [%s] %d room(s), cost %d -> %d (sg=%s dg=%d)",
      axis, table.concat(best.trail, " + "), best.n, baseCost, best.cost, sgtxt(best.sg), best.dg or 0))
    return true
  end
  do
    -- Phase 1 kills the perpendicular offset; phase 2 (only if still owed) opens the parallel
    -- gap. Both orders are tried when the first fails, since the phases are not independent.
    local mode = tighten and 1 or false
    -- A unit pass reclaims exactly one cell, so the pass budget is the cells of slack;
    -- closeTightCap is only a safety bound on a pathological edge.
    local passes = tighten and math.min(excess() + 1, TUNE.closeTightCap) or 1
    local gained = 0
    for pass = 1, passes do
      tightPass = pass
      local exBefore = tighten and excess() or 0
      local n_pa, n_da = need_on(pa, mode), need_on(da, mode)
      if n_pa == 0 and n_da == 0 then break end
      local orders = { { pa, da } }
      if n_pa ~= 0 and n_da ~= 0 then orders[2] = { da, pa } end
      local done = false
      for oi, order in ipairs(orders) do
        local ok = true
        ctr(false, "  phase order %d/%d: %s then %s", oi, #orders,
          AXIS_WORD[order[1]] or "?", AXIS_WORD[order[2]] or "?")
        for _, axis in ipairs(order) do
          if not ok then break end
          local n = need_on(axis, mode)
          if n ~= 0 then
            -- Try the carried option first; only inside a tighten (a closure has one pass,
            -- so never a previous pick to carry).
            ok = false
            if tighten and carry[axis] then
              ok = eq_phase(axis, n, carry[axis])
              if not ok then carry[axis] = nil end     -- it stopped working; stop betting on it
            end
            if not ok then ok = eq_phase(axis, n) end
          end
        end
        if ok and truthful() then
          if oi > 1 then
            elro.tr(string.format("  eqw close %d-%d: closed on the REVERSED phase order (%d then %d)",
              v, w, order[1], order[2]))
            elro._eqcOrder2 = (elro._eqcOrder2 or 0) + 1
          end
          done = true
          break
        end
        -- revert everything this order moved before the next one reads the geometry
        if next(eqRestore) then
          for r, p in pairs(eqRestore) do coord[r] = p end ; rebuild_occ()
          eqRestore = {}
        end
      end
      if not done then
        -- the whole pull was refused: drop to unit steps and let the loop try again from here.
        -- Anything else (a unit step refused, or a real closure) is the end of the road.
        if mode == 2 then
          mode = 1
          ctr(false, "  the whole %d-cell pull was refused -- retrying one cell at a time", exBefore)
        else
          break
        end
      else
        -- a closure counts as one win; a tighten counts the CELLS it actually reclaimed
        gained = gained + (tighten and (exBefore - excess()) or 1)
        -- An accepted pass is kept: dropping the restore log means a later failed pass reverts
        -- only what that pass moved.
        eqRestore = {}
        if not tighten then break end
      end
    end
    if gained > 0 and truthful() then
      if tighten then
        elro._eqcTightWon = (elro._eqcTightWon or 0) + 1
        elro._eqcTightCells = (elro._eqcTightCells or 0) + gained
        tightPass = 1        -- the summary always prints, however many passes it took
        ctr(false, "<green>  TIGHTEN reclaimed %d cell(s) over %d pass(es); %d still over the minimum",
          gained, math.min(gained, passes), excess())
      end
      -- BEFORE the snap, so mapstep shows the closure and its conversion as one settled state
      cc_after("eq-shift")
      elro.step_snap(coord, string.format("eqw close %d-%d %s", v, w,
        tighten and string.format("TIGHTEN -%d", gained) or "eq-shift"), w, v)
      local o1, o2 = coord[w][1] - coord[v][1], coord[w][2] - coord[v][2]
      if o1 < 0 then o1 = -o1 end ; if o2 < 0 then o2 = -o2 end
      if tighten or del[1] == 0 or del[2] == 0 or o1 == o2 then return true, true end
      closedSkew = true
      ctr(false, "  closed off-45 (%d,%d): trying the squarify re-solve", o1, o2)
    end
  end
  -- Live compaction is tried before the generator cascade: one solve + one gate, and the
  -- equality classes include this closure edge so it often closes the loop outright.
  -- Axis-scoped to the axis this closure stretched.
  -- A tighten that fails is NOT a failed closure -- the edge is still truthful; the fallbacks
  -- below exist for an edge that is not.
  if tighten or closedSkew then
    -- Squarify at the closure: a tighten only shrinks, and a ring whose diagonal wall is off
    -- 45 needs a re-solve (a dilation cannot change a wall's parity). Same generator the walk
    -- uses, squarify candidates only; accepted only on strict improvement -- ring diagonals go
    -- square and count_defects gets no worse on any kind.
    local sqOK = false
    -- The generator is expensive; two free gates rule out most calls:
    --   1. the edge must be a diagonal (an axial closure has no 45 to repair);
    --   2. a ring near the pair must actually be bent (ring_shear_at > 0).
    local shear0 = (del[1] ~= 0 and del[2] ~= 0) and ring_shear_at(v, w) or 0
    if shear0 > 0
       and query_ring_dilate_levers
       and (elro._sqCalls or 0) < (TUNE.sqCloseCap or 64) then
      elro._sqCalls = (elro._sqCalls or 0) + 1
      -- Must not build under _inClose: that flag turns off the room-on-edge clearance sweeps,
      -- which is right for a tighten (minimal plates) and backwards for a re-solve whose job
      -- is to inject space.
      local _pic = elro._inClose ; elro._inClose = nil
      elro._sqGen = true
      local cands = query_ring_dilate_levers(v, w) or {}
      elro._inClose = _pic ; elro._sqGen = nil
      local sq = {}
      for _, c in ipairs(cands) do
        if c.squarify and c.set and c.deltas then sq[#sq + 1] = c end
      end
      -- Try them all, smallest first -- only some holds move the rooms this closure can move.
      table.sort(sq, function(x, y) return (x.rooms or 0) < (y.rooms or 0) end)
      local d0, o0, e0, x0 = elro.count_defects(coord, placed, pedges)
      local re0 = roomedge_set()
      -- A crossing wire may not be dragged onto the wall it crosses: the leaf-stretch rule is
      -- false for a wire, whose length must span the wall. A non-ring rider that lands on a
      -- wall is dropped from the plate and its edge left to stretch (a rider is a room the drag
      -- chose to carry, never one the re-solve requires; the gate re-checks all defect kinds).
      for _, best in ipairs(sq) do
        if sqOK then break end
        local saved = {}
        for r in pairs(best.set) do
          local q = coord[r]
          if q then
            saved[r] = { q[1], q[2] }
            local dx, dy = cand_shift(best, r)
            coord[r] = { q[1] + dx, q[2] + dy }
          end
        end
        rebuild_occ()
        local d1, o1, e1, x1 = elro.count_defects(coord, placed, pedges)
        local shear1 = ring_shear_at(v, w)
        local why, reNew
        -- count_defects returns (total, overlaps, room-on-edge, crossings); test the specific
        -- kinds first, the total is only the catch-all.
        if shear1 >= shear0 then why = "shear " .. shear0 .. " -> " .. shear1
        elseif (o1 or 0) > (o0 or 0) then
          why = "overlap"
          local cell, at = {}, {}
          for r in pairs(placed) do
            local q = coord[r]
            if q then
              local k = q[1] * 1000003 + q[2]
              if cell[k] then at[#at + 1] = math.min(r, cell[k]) .. "<->" .. math.max(r, cell[k])
              else cell[k] = r end
            end
          end
          if #at > 0 then table.sort(at) ; why = why .. " [" .. table.concat(at, " ") .. "]" end
        elseif (e1 or 0) > (e0 or 0) then
          why = "room-on-edge"
          local re1 = roomedge_set()
          local nw = {}
          for k in pairs(re1) do if not re0[k] then nw[#nw + 1] = k end end
          table.sort(nw)
          if #nw > 0 then why = why .. " [" .. table.concat(nw, " ") .. "]" end
          reNew = nw
        elseif (x1 or 0) > (x0 or 0) then why = "crossing"
        elseif (d1 or 0) > (d0 or 0) then why = "defects " .. (d0 or 0) .. " -> " .. (d1 or 0) end
        if not why then
          sqOK = true
          elro._sqClose = (elro._sqClose or 0) + 1
          ctr(false, "<green>  SQUARIFY %s: the ring re-solved, %d room(s), shear %d -> %d",
            tostring(best.ek), best.rooms or 0, shear0, shear1)
          cc_after("squarify")
          elro.step_snap(coord, string.format("eqw close %d-%d SQUARIFY %s", v, w,
            tostring(best.ek)), w, v)
        else
          -- ONE retry, with the riders that landed on a wall dropped
          local alt, nd = nil, 0
          if reNew and #reNew > 0 then
            alt, nd = ring_free_rider(best, reNew)
          end
          if alt then
            for r, q in pairs(saved) do coord[r] = q end
            rebuild_occ()
            local saved2 = {}
            for r in pairs(alt.set) do
              local q = coord[r]
              if q then
                saved2[r] = { q[1], q[2] }
                local dx, dy = cand_shift(alt, r)
                coord[r] = { q[1] + dx, q[2] + dy }
              end
            end
            rebuild_occ()
            local a1, ao1, ae1, ax1 = elro.count_defects(coord, placed, pedges)
            local ash = ring_shear_at(v, w)
            if ash < shear0 and (ao1 or 0) <= (o0 or 0) and (ae1 or 0) <= (e0 or 0)
               and (ax1 or 0) <= (x0 or 0) and (a1 or 0) <= (d0 or 0) then
              sqOK = true
              elro._sqClose = (elro._sqClose or 0) + 1
              elro._sqRider = (elro._sqRider or 0) + 1
              ctr(false, "<green>  SQUARIFY %s: the ring re-solved, %d room(s), shear %d -> %d"
                .. " (%d rider(s) left behind -- the crossing wire stretches instead)",
                tostring(alt.ek), alt.rooms or 0, shear0, ash, nd)
              cc_after("squarify")
              elro.step_snap(coord, string.format("eqw close %d-%d SQUARIFY %s", v, w,
                tostring(alt.ek)), w, v)
            else
              for r, q in pairs(saved2) do coord[r] = q end
              rebuild_occ()
              saved = {}
            end
          end
          if sqOK then break end
          elro._sqCloseNo = (elro._sqCloseNo or 0) + 1
          -- Print the plate, not just the verdict; `+` marks a room not on the ring (one the
          -- drag rule chose to carry).
          local pl, onR = {}, {}
          for _, gg in ipairs(elro.faceRings or {}) do
            for _, r in ipairs(gg) do onR[r] = true end
          end
          for r in pairs(best.set) do
            local dx, dy = cand_shift(best, r)
            pl[#pl + 1] = string.format("%d(%d,%d)%s", r, dx, dy, onR[r] and "" or "+")
          end
          table.sort(pl)
          ctr(false, "  [sq] %s (%dr) declined: %s | plate: %s", tostring(best.ek),
            best.rooms or 0, why, table.concat(pl, " "))
          for r, q in pairs(saved) do coord[r] = q end
          rebuild_occ()
        end
      end
    end
    if sqOK or closedSkew then return true, true end
    ctr(false, "<red>  TIGHTEN failed -- no plate could take the slack out; the edge keeps its length")
    return true, false
  end
  ctr(false, "  the equation driver did not close it -- falling through to %s",
    elro.eqwCompactLive and "live compaction, then the chord generators"
                        or "the chord generators (eqwCompactLive is OFF)")
  if elro.eqwCompactLive then
    for _, ax in ipairs({ pa, da }) do
      eqw_compact(string.format("close %d-%d", v, w), ax)
      if truthful() then
        elro.step_snap(coord, string.format("eqw close %d-%d compaction", v, w), w, v)
        return true, false      -- compaction already reclaimed; nothing left to clean up
      end
    end
  end
  -- candidate shift applicator (guillotine per-room `deltas`, or flat set*dx*dist), same
  -- form the walk/stitch use.
  local function cshift(c, r)
    if c.deltas then local e = c.deltas[r] ; if e then return e[1], e[2] end ; return 0, 0 end
    if c.set and c.set[r] then return (c.dx or 0) * (c.dist or 0), (c.dy or 0) * (c.dist or 0) end
    return 0, 0
  end
  -- Gather chord-pull candidates, anchored both ways; keep the first that lands v-w truthful
  -- with no new defect on a moved room. In practice the eq-shift above closes every loop
  -- first, so this loop is rarely (if ever) entered.
  local cands = {}
  for _, c in ipairs(query_cut_levers(v, w, w) or {}) do cands[#cands + 1] = c end
  for _, c in ipairs(query_cut_levers(w, v, v) or {}) do cands[#cands + 1] = c end
  if elro.debug then elro.tr(string.format("eqw_close %d-%d del=(%d,%d) off=(%d,%d) %d cand(s)",
    v, w, del[1], del[2], coord[w][1] - coord[v][1], coord[w][2] - coord[v][2], #cands)) end
  for _, c in ipairs(cands) do
    local snap = {}
    for r in pairs(placed) do
      local dx, dy = cshift(c, r)
      if dx ~= 0 or dy ~= 0 then snap[r] = coord[r] end        -- original coord, not yet moved
    end
    if next(snap) then
      -- DIFFERENTIAL gate: the half-built block already carries defects, so only reject a
      -- move that gives a PREVIOUSLY-CLEAN moved room a NEW defect (matches the chord's
      -- cleanShift). An absolute check wrongly threw away valid min-cut guillotines.
      local wasClean = {}
      for r in pairs(snap) do wasClean[r] = not defective(r) end
      for r in pairs(snap) do local dx, dy = cshift(c, r) ; coord[r] = { snap[r][1] + dx, snap[r][2] + dy } end
      rebuild_occ()
      local ok, why = truthful(), nil
      if not ok then why = string.format("not-truthful off=(%d,%d)", coord[w][1] - coord[v][1], coord[w][2] - coord[v][2]) end
      if ok then for r in pairs(snap) do
        if wasClean[r] and defective(r) then ok = false ; why = "new-defect@" .. r ; break end
      end end
      if elro.debug then
        local nm = 0 ; for _ in pairs(snap) do nm = nm + 1 end
        elro.tr(string.format("  cand %s dx=%d dy=%d dist=%s moved=%d -> %s",
          tostring(c.kind), c.dx or 0, c.dy or 0, tostring(c.dist), nm, ok and "APPLY" or why)) end
      if ok then
        -- the generator path carries the SAME differential gate as the eq-shift above (only a
        -- previously-clean MOVED room may veto), so it can create the same room-on-edge
        cc_after(tostring(c.kind or "lever"))
        elro.step_snap(coord, string.format("eqw close %d-%d %s", v, w, tostring(c.kind or "lever")), w, v)
        return true, true
      end
      for r, p in pairs(snap) do coord[r] = p end ; rebuild_occ()
    end
  end
  -- Last resort. If stitch_one cannot make it truthful either, the back-edge stays a lie --
  -- the one outcome the walk must never hide, so say so on the step timeline.
  local st = elro.stitch_one(coord, adj, v, w, del)
  if not st then
    elro.tr(string.format("  eqw close %d-%d FAILED -- edge left UNTRUTHFUL"
      .. " (off=(%d,%d), want del=(%d,%d))", v, w,
      coord[w][1] - coord[v][1], coord[w][2] - coord[v][2], del[1], del[2]))
    elro.step_snap(coord, string.format("eqw close %d-%d FAILED: edge left UNTRUTHFUL", v, w), w, v)
  else
    cc_after("stitch")        -- stitch_one nudges residuals and can land a room on a wire too
  end
  return st, true
end

function elro.tighten_ring_1(W, v, w)
  local DELTA, adj, class_seam, class_shearfree_seeds, coord, ctrace, defective, det_sweep = W.DELTA, W.adj, W.class_seam, W.class_shearfree_seeds, W.coord, W.ctrace, W.defective, W.det_sweep
  local eqw_classes, eqw_close_core, eqw_forced_shift, placed, rebuild_occ, ring_of = W.eqw_classes, W.eqw_close_core, W.eqw_forced_shift, W.placed, W.rebuild_occ, W.ring_of
  -- Every decline is traced. Scope: only ring_of(v, w), the one ring containing the edge just
  -- closed; slack on a neighbouring face is never looked at.
  local ring = ring_of(v, w)
  if not ring or #ring < 4 then
    ctrace(false, "<grey>  ring tighten: %d-%d SKIPPED -- %s", v, w,
      ring and ("ring of " .. #ring .. " room(s), too small") or "no ring through this edge")
    elro._trNoRing = (elro._trNoRing or 0) + 1
    return
  end
  elro._eqcRing = (elro._eqcRing or 0) + 1
  -- how far one ring edge is over its own minimum (0 if the two rooms are not actually adjacent
  -- in the direction graph, which `ring_of` can produce through a special exit)
  local function edge_excess(a, b)
    if not (coord[a] and coord[b]) then return 0 end
    for d2, x in each_exit(adj[a]) do
      local de2 = DELTA[d2]
      if x == b and de2 and (de2[1] ~= 0 or de2[2] ~= 0) then
        local m, ex = elro.min_len(a, b), 0
        for ax = 1, 2 do
          if de2[ax] ~= 0 then
            local c = coord[b][ax] - coord[a][ax]
            local L = (c < 0) and -c or c
            if L > m then ex = ex + (L - m) end
          end
        end
        return ex, de2
      end
    end
    return 0
  end
  local function ring_excess()
    local t = 0
    for i = 1, #ring do t = t + edge_excess(ring[i], ring[(i % #ring) + 1]) end
    return t
  end
  -- Area is the only honest acceptance test: inside a closed ring the direction totals are
  -- fixed, so a single-class pull can only redistribute slack between the ring's edges --
  -- ring_excess is invariant under these moves, but area is not. Order candidates by excess,
  -- accept on area, revert anything that does not strictly shrink the ring.
  local function ring_area()
    local s2, n = 0, #ring
    for i = 1, n do
      local p, q = coord[ring[i]], coord[ring[(i % n) + 1]]
      if not (p and q) then return nil end
      s2 = s2 + (p[1] * q[2] - q[1] * p[2])
    end
    return ((s2 < 0) and -s2 or s2) / 2
  end
  -- Ping-pong guard: measure the RING, not the edge -- the walk continues only while the
  -- ring's total excess strictly falls, and no edge is attempted twice.
  local seen, total, area = {}, ring_excess(), ring_area()
  if not area then return end
  -- Push the extremes inward (ringTightenExtreme): only the extremes set the ring's extent.
  -- Anchored on the opposite extreme; repeats while the area strictly falls; same differential
  -- veto as eq_phase's probe. OPEN: can leave one face imperfectly shrunk.
  do
    local function push_extreme(axis)
      local lo, hi
      for i = 1, #ring do
        local r = ring[i] ; local pp = coord[r]
        if pp then
          if not hi or pp[axis] > coord[hi][axis]
             or (pp[axis] == coord[hi][axis] and r < hi) then hi = r end
          if not lo or pp[axis] < coord[lo][axis]
             or (pp[axis] == coord[lo][axis] and r < lo) then lo = r end
        end
      end
      if not (lo and hi) or lo == hi then return end
      -- tightenSeedScan (default off): a blocked extreme seed is replaced by scanning inward in
      -- (coordinate, id) order, deduped by class, stopping at the anchor. plate_len is the exact
      -- cost of a rigid unit translation: only edges with exactly one end inside change length.
      local function plate_len(setx)
        local t = 0
        for r in pairs(setx) do
          local p = coord[r]
          if p then
            for d2, x in each_exit(adj[r]) do
              local de2 = DELTA[d2]
              if de2 and (de2[1] ~= 0 or de2[2] ~= 0) and not setx[x] and placed[x]
                 and coord[x] then
                local dx = coord[x][1] - p[1] ; local dy = coord[x][2] - p[2]
                t = t + ((dx < 0) and -dx or dx) + ((dy < 0) and -dy or dy)
              end
            end
          end
        end
        return t
      end
      local function seed_queue(sgn, st0, anc)
        if not elro.tightenSeedScan then return { st0 } end
        local ord = {}
        for i = 1, #ring do if coord[ring[i]] then ord[#ord + 1] = ring[i] end end
        table.sort(ord, function(a, b)
          local pa, pb = coord[a][axis], coord[b][axis]
          if pa ~= pb then if sgn > 0 then return pa < pb else return pa > pb end end
          return a < b
        end)
        local cls0 = eqw_classes()            -- plain: memoised, and used ONLY to dedupe seeds
        local stop = coord[anc] and coord[anc][axis]
        local q, seenC = {}, {}
        for _, r in ipairs(ord) do
          if stop and coord[r][axis] == stop then break end
          local c = cls0[axis][r] or -r
          if not seenC[c] then
            seenC[c] = true ; q[#q + 1] = r
            if #q >= (TUNE.tightenSeedCap or 6) then break end
          end
        end
        if #q == 0 then q[1] = st0 end
        return q
      end
      for _, side in ipairs({ { hi, -1, lo }, { lo, 1, hi } }) do
        local st0, sgn, anc = side[1], side[2], side[3]
        local queue = seed_queue(sgn, st0, anc)
        local si, won = 1, false
        local st = queue[1]
        local going = true
        while going do
          going = false
          -- eqw_classes(st, anc): the partition must drop the edge between pushed room and
          -- anchor, or the two are one class and the push is a no-op.
          local cls2, mem2 = eqw_classes(st, anc)
          local mv0, n0 = eqw_forced_shift(cls2, mem2, axis, st, sgn, anc)
          -- Seam family, same construction as the closure's and the generator's:
          --   :sf    class_shearfree_seeds(mv, axis)
          --   :t     elro.seam_walk from the base plate
          --   :sf:t  elro.seam_walk from the sf plate, carrying the sf seeds
          -- The family only works as a set (:t alone shears); all forms are offered and the
          -- ranking below chooses.
          local mv = mv0
          if mv0 then
            local cand = { { mv0, 0 } }
            local sd = class_shearfree_seeds(mv0, axis)
            local mvSf, nSf
            if sd and #sd > 0 then
              mvSf, nSf = eqw_forced_shift(cls2, mem2, axis, st, sgn, anc, nil, sd)
              if mvSf then cand[#cand + 1] = { mvSf, 2 } end
            end
            local mvT = elro.seam_walk(W, { cls = cls2, mem = mem2, pa = axis, start = st, s = sgn,
              anchor = anc, mv = mv0, n = n0, tag = "tighten:" .. st .. ":t", wkCls = "tighten:t" })
            if mvT then cand[#cand + 1] = { mvT, 1 } end
            if mvSf then
              local mv3 = elro.seam_walk(W, { cls = cls2, mem = mem2, pa = axis, start = st, s = sgn,
                anchor = anc, seeds = sd, mv = mvSf, n = nSf, tag = "tighten:" .. st .. ":sf:t",
                wkCls = "tighten:sf:t" })
              if mv3 then cand[#cand + 1] = { mv3, 3 } end
            end
            -- No `#cand > 1` guard: the shear veto must run on a lone candidate too.
            if #cand >= 1 then
              -- Rank 45s first, then the seam, then area. Area and shear are predicted in closed form
              -- (rigid 1D shift). Shear is a hard veto, not a rank term.
              local function pred(setx)
                local s3, n3 = 0, #ring
                for i = 1, n3 do
                  local r1, r2 = ring[i], ring[(i % n3) + 1]
                  local p1, p2 = coord[r1], coord[r2]
                  if not (p1 and p2) then return nil end
                  local x1, y1, x2, y2 = p1[1], p1[2], p2[1], p2[2]
                  if setx[r1] then if axis == 1 then x1 = x1 + sgn else y1 = y1 + sgn end end
                  if setx[r2] then if axis == 1 then x2 = x2 + sgn else y2 = y2 + sgn end end
                  s3 = s3 + (x1 * y2 - x2 * y1)
                end
                local a3 = ((s3 < 0) and -s3 or s3) / 2
                local sh3 = 0
                for r1 in pairs(setx) do
                  local p1 = coord[r1]
                  if p1 then
                    for d3, r2 in each_exit(adj[r1]) do
                      local de3 = DELTA[d3]
                      if de3 and de3[1] ~= 0 and de3[2] ~= 0 and placed[r2] and coord[r2]
                         and not setx[r2] then
                        local gx3 = coord[r2][1] - p1[1]
                        local gy3 = coord[r2][2] - p1[2]
                        if (gx3 == gy3 or gx3 == -gy3)
                           and gx3 * de3[1] >= 1 and gy3 * de3[2] >= 1 then
                          sh3 = sh3 + 1        -- a square truthful diagonal cut by the boundary
                        end
                      end
                    end
                  end
                end
                return a3, sh3
              end
              local function seam_of(setx)
                local sn = {}
                for r in pairs(setx) do
                  sn[r] = coord[r]
                  local pp = coord[r]
                  coord[r] = (axis == 1) and { pp[1] + sgn, pp[2] } or { pp[1], pp[2] + sgn }
                end
                rebuild_occ()
                local sm3 = class_seam(setx, axis, sgn)
                for r, pp in pairs(sn) do coord[r] = pp end
                rebuild_occ()
                return (sm3 and sm3 < math.huge) and sm3 or -1
              end
              local bA, bSm, bR
              for _, c in ipairs(cand) do
                local a3, sh3 = pred(c[1])
                if a3 and sh3 == 0 and a3 < area then          -- VETO: any shear at all
                  local sm3 = seam_of(c[1])
                  local win
                  if not bA then win = true
                  elseif sm3 ~= bSm then win = (sm3 > bSm)     -- the seam
                  elseif a3 ~= bA then win = (a3 < bA)         -- then area
                  else win = (c[2] > (bR or -1)) end           -- then the repaired form
                  if win then bA, bSm, bR, mv = a3, sm3, c[2], c[1] end
                elseif a3 and sh3 and sh3 > 0 then
                  elro._trExShear = (elro._trExShear or 0) + 1
                end
              end
              if not bA then mv = nil end                      -- every candidate shears: decline
              if bR and bR > 0 then elro._trExT = (elro._trExT or 0) + 1 end
            end
          end
          if mv then
            local snap, xi, rc, cen = {}, nil, nil, nil
            local wasClean = {}
            for r in pairs(mv) do
              snap[r] = coord[r]
              if not xi then xi, rc, cen = det_sweep() end
              wasClean[r] = not defective(r, xi, rc, cen)
            end
            local bl0 = elro.tightenSeedScan and plate_len(mv) or nil
            for r in pairs(mv) do
              local pp = coord[r]
              coord[r] = (axis == 1) and { pp[1] + sgn, pp[2] } or { pp[1], pp[2] + sgn }
            end
            rebuild_occ()
            local now = ring_area()
            local bl1 = bl0 and plate_len(mv)
            local lenOk = (not bl0) or (bl1 - bl0 <= (TUNE.tightenLenOk or 0))
            if now and now < area and not lenOk then
              elro._trExLen = (elro._trExLen or 0) + 1
            end
            -- A push may not inject slack: ring excess is tested per step. TUNE.tightenSlackOk:
            -- 0 = strict, 1 = flat redistribution allowed.
            local slackOk = TUNE.tightenSlackOk or 0
            local nowEx = elro.tightenSeedScan and ring_excess() or nil
            local ok = now and now < area and lenOk
              and (not nowEx or nowEx < total + slackOk)
            if now and now < area and nowEx and nowEx >= total + slackOk then
              elro._trExSlack = (elro._trExSlack or 0) + 1
            end
            local broke = false
            if ok then
              local xi2, rc2, cen2 = det_sweep()
              for r in pairs(mv) do
                if wasClean[r] and defective(r, xi2, rc2, cen2) then broke = true ; break end
              end
            end
            if ok and not broke then
              elro._trExCells = (elro._trExCells or 0) + (area - now)
              area = now ; total = ring_excess()
              elro._trExOK = (elro._trExOK or 0) + 1
              going = true ; won = true
            else
              for r, pp in pairs(snap) do coord[r] = pp end
              rebuild_occ()
              elro._trExNo = (elro._trExNo or 0) + 1
            end
          end
          -- Advance the seed only when this seed produced nothing; once a seed has won the side
          -- stays with it until it converges, so this never turns an accepted push into a search.
          if not going and not won and si < #queue then
            si = si + 1 ; st = queue[si] ; going = true
            elro._trExScan = (elro._trExScan or 0) + 1
          end
        end
        if won and si > 1 then elro._trExScanOK = (elro._trExScanOK or 0) + 1 end
      end
    end
    -- the axis the slack is ON: an edge's excess belongs to the axis it runs along
    local exX, exY = 0, 0
    for i = 1, #ring do
      local a2, b2 = ring[i], ring[(i % #ring) + 1]
      local e2 = edge_excess(a2, b2)
      if e2 > 0 and coord[a2] and coord[b2] then
        if coord[a2][2] == coord[b2][2] then exX = exX + e2
        elseif coord[a2][1] == coord[b2][1] then exY = exY + e2 end
      end
    end
    if exX > 0 then push_extreme(1) end
    if exY > 0 then push_extreme(2) end
    -- The edge walk below is skipped entirely: once the extreme push runs, the walk wins
    -- nothing -- what remains is the redistribution it can only ever do. With
    -- ringTightenExtreme off the walk is untouched and stays as the A/B.
    return
  end
  for _ = 1, #ring do
    local bestA, bestB, bestD, bestEx = nil, nil, nil, 0
    for i = 1, #ring do
      local a, b = ring[i], ring[(i % #ring) + 1]
      local k = ekey(a, b)
      if not seen[k] and not ((a == v and b == w) or (a == w and b == v)) then
        local ex, de2 = edge_excess(a, b)
        -- ties broken by room id, never pairs() order: a layout that picks a different edge each
        -- run is worse than one that picks a slightly worse edge
        if ex > bestEx or (ex == bestEx and ex > 0 and bestA and a < bestA) then
          bestA, bestB, bestD, bestEx = a, b, de2, ex
        end
      end
    end
    if not bestA then
      if _ == 1 then
        ctrace(false, "<grey>  ring tighten: %d-%d nothing to do -- no ring edge is over its"
          .. " minimum (ring of %d room(s), slack %d)", v, w, #ring, total)
        elro._trNoEdge = (elro._trNoEdge or 0) + 1
      end
      return
    end
    seen[ekey(bestA, bestB)] = true
    elro._trTry = (elro._trTry or 0) + 1
    ctrace(false, "<grey>  ring tighten: %d-%d carries %d cell(s) over its minimum (ring area %d,"
      .. " slack %d)", bestA, bestB, bestEx, area, total)
    -- STRICT IMPROVE OR REVERT, so a redistribution that merely relocates the slack is undone
    -- rather than left behind for the next edge to relocate again
    local snap = {} ; for r in pairs(placed) do snap[r] = coord[r] end
    eqw_close_core(bestA, bestB, bestD)
    -- Accept: the ring got smaller, OR it stayed the same size and the slack moved somewhere
    -- better (an area-neutral move is still a move onto a less-shared wall). Only an area
    -- INCREASE is refused.
    local now, ex = ring_area(), ring_excess()
    if not now or now > area or (now == area and ex >= total) then
      for r, p in pairs(snap) do coord[r] = p end ; rebuild_occ()
      ctrace(false, "<red>  ring tighten: REVERTED %d-%d -- %s; a single-class pull on a closed cycle"
        .. " can only move slack BETWEEN its edges, never out", bestA, bestB,
        now and string.format("area %d -> %d, slack %d -> %d", area, now, total, ex) or "ring broken")
      elro._eqcRingPong = (elro._eqcRingPong or 0) + 1
    else
      elro._eqcRingCells = (elro._eqcRingCells or 0) + (area - now)
      area, total = now, ex
    end
  end
end
