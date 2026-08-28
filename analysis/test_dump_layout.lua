-- Relayout a DUMPED AREA offline, under the real engine, with knobs applied per run.
--
--   luajit analysis/test_dump_layout.lua analysis/dannoc_on.txt  enclLoopBack=false enclLoopBack=true
--
-- Each extra argument is one RUN: a comma-separated knob list (`k=v,k=v`, or `-` for defaults).
-- Every run is rebuilt from the dump in ONE process and the runs are diffed against each other.
--
-- ⛔⛔ WHY ONE PROCESS IS NOT OPTIONAL: LuaJIT randomises string hashing per process, so `pairs()`
-- order over the direction-keyed `adj` differs between invocations and the layout with it. A/B across
-- two `luajit` runs compares two different hash seeds, not two knob settings. See
-- [[reference_luajit_hash_seed]]. For the same reason the absolute coordinates here need not match
-- Mudlet's (stock Lua 5.1, unrandomised) -- what transfers is WHETHER A DEFECT REPRODUCES, and the
-- difference between runs.

local dumpPath = arg[1] or error("usage: test_dump_layout.lua <dump> [knobs...]")

-- ---------------------------------------------------------------- fake Mudlet
local M, TIMERS, TID = nil, {}, 0
local function reset_map() M = { rooms = {}, areas = {}, nextArea = 1 } end
reset_map()

function roomExists(id) return M.rooms[id] ~= nil end
function getRooms() local t = {} for id in pairs(M.rooms) do t[id] = "room " .. id end return t end
function getRoomExits(id) local r = M.rooms[id] ; return r and r.exits or {} end
function getRoomUserData(id, k) local r = M.rooms[id] ; return r and r.ud[k] or "" end
function setRoomUserData(id, k, v) local r = M.rooms[id] ; if r then r.ud[k] = v end end
function getRoomArea(id) local r = M.rooms[id] ; return r and r.area or -1 end
function setRoomArea(id, a) local r = M.rooms[id] ; if r then r.area = a end end
function getAreaRooms(a) local t = {} for id, r in pairs(M.rooms) do if r.area == a then t[#t+1] = id end end table.sort(t) return t end
function getAreaTable() local t = {} for n, a in pairs(M.areas) do t[n] = a end return t end
function getAreaTableSwap() local t = {} for n, a in pairs(M.areas) do t[a] = n end return t end
function addAreaName(n) M.areas[n] = M.nextArea ; M.nextArea = M.nextArea + 1 ; return M.areas[n] end
function deleteArea(a) for n, id in pairs(M.areas) do if id == a then M.areas[n] = nil end end end
function addRoom(id) M.rooms[id] = { area = 1, exits = {}, ud = {}, x = 0, y = 0 } end
function deleteRoom(id) M.rooms[id] = nil end
function setRoomName() end
function getRoomName(id) return "room " .. id end
function setExit(a, b, d) local r = M.rooms[a] ; if r then if b == -1 then r.exits[d] = nil else r.exits[d] = b end end end
function setExitStub() end
function addSpecialExit() end
function getSpecialExits() return {} end
function getRoomCoordinates(id) local r = M.rooms[id] ; if not r then return 0, 0, 0 end return r.x, r.y, 0 end
function setRoomCoordinates(id, x, y) local r = M.rooms[id] ; if r then r.x, r.y = x, y end end
function getCustomLines() return {} end
function removeCustomLine() end
function addCustomLine() end
function highlightRoom() end
function unHighlightRoom() end
function createMapLabel() end
function deleteMapLabel() end
function getMapSelection() return {} end
function centerview() end
function updateMap() end
function cecho(s) if os.getenv("VERBOSE") then io.write((tostring(s):gsub("<[^>]->", ""))) end end
function getMapUserData() return "" end
function setMapUserData() end
function saveMap() end
function getEpoch() return os.clock() end
function tempTimer(_, fn) TID = TID + 1 ; TIMERS[TID] = fn ; return TID end
function killTimer(id) TIMERS[id] = nil end

for _, m in ipairs(dofile("lua/modules.lua")) do dofile("lua/" .. m) end

-- ⛔⛔ TRACECHECK/RENDERSTEP RENDER THE **LAST** COMPOSE, NOT THE BIGGEST ONE. `_stepLog` is reset
-- per `compose_spqr_adj` (layout.lua, "mapstep replays ONE canvas"), and a dump whose area has
-- leftover singleton components composes those LAST -- so `brom.txt` rendered 16 frames of a
-- 15-singleton shelf-pack while the 700-frame walk that actually built the map was already gone,
-- silently. Keep a copy of the LARGEST log seen and hand it to the renderers at the end.
do
  local compose = elro.compose_spqr_adj
  elro.compose_spqr_adj = function(...)
    local a, b, c = compose(...)
    local log = elro._stepLog
    if log and #log > #(elro._bigStepLog or {}) then elro._bigStepLog = log end
    return a, b, c
  end
end

-- ------------------------------------------------------------------ the dump
-- `id (x,y,z) area=NAME [dir->id, dir->id]`. Coordinates are ignored -- the point is to lay it out
-- again from the EXITS. Targets outside the dump (other areas, filtered singletons) are created in
-- a separate sarea so the edge exists without joining this canvas.
local ROOMS, ORDER, AREA = {}, {}, {}
local OUTER
do
  local f = assert(io.open(dumpPath, "r"))
  for ln in f:lines() do
    local outer = ln:match("^%-%- outer=([%d,]+)")
    if outer then OUTER = {} ; for id in outer:gmatch("%d+") do OUTER[tonumber(id)] = true end end
    local id, x, y, ar, ex = ln:match("^%s*(%d+) %((-?%d+),(-?%d+),%-?%d+%) area=(%S+) %[(.*)%]%s*$")
    if id then
      id = tonumber(id)
      ROOMS[id] = { area = ar, exits = {}, x = tonumber(x), y = tonumber(y) }
      ORDER[#ORDER + 1] = id ; AREA[ar] = true
      for d, t in ex:gmatch("(%a+)%->(%d+)") do ROOMS[id].exits[d] = tonumber(t) end
    end
  end
  f:close()
end

local function build()
  reset_map()
  elro.cs_reset()
  elro.dirty, elro.merge, elro.smap = {}, {}, {}
  elro.areamin_loaded, elro.margin_loaded, elro.mode_loaded = true, true, true
  TIMERS = {}
  for _, id in ipairs(ORDER) do
    addRoom(id) ; M.rooms[id].ud.sarea = ROOMS[id].area
  end
  for _, id in ipairs(ORDER) do                    -- outside targets, in their own sarea
    for _, t in pairs(ROOMS[id].exits) do
      if not M.rooms[t] then addRoom(t) ; M.rooms[t].ud.sarea = "_outside" end
    end
  end
  for _, id in ipairs(ORDER) do
    for d, t in pairs(ROOMS[id].exits) do setExit(id, t, elro.norm(d)) end
  end
  elro.current = nil
  -- outer-face pick: the dump's `-- outer=` header, overridden by OUTERPICK=<ids> (OUTERPICK=none clears)
  elro.outerPick = {}
  for k in pairs(OUTER or {}) do elro.outerPick[k] = true end
  if os.getenv("OUTERPICK") then
    elro.outerPick = {}
    for id in os.getenv("OUTERPICK"):gmatch("%d+") do elro.outerPick[tonumber(id)] = true end
  end
end

-- both registries: `elro.PROBES` was split out of KNOBS on 2026-08-12, and specs routinely name a
-- probe (`stepTime=true`, `timeGuillo=true`), so validating against KNOBS alone would reject them.
local KNOBS = {}
for _, k in ipairs(elro.KNOBS or {}) do KNOBS[k] = true end
for _, k in ipairs(elro.PROBES or {}) do KNOBS[k] = true end

-- ⭐ INLINED TUNABLES ARE A/B-ABLE FROM A SPEC TOO (`diagStretchMult=1`). They are deliberately NOT
-- knobs -- they live in layout.lua's TUNE table and the engine never reads them through elro -- but
-- the LuaJIT hash seed makes an IN-PROCESS A/B the only honest identity check, so "compare two TUNE
-- values" has to be expressible as two specs in ONE run. Defaults are snapshotted once and restored
-- before every spec, exactly like the knob reset below, so one spec cannot leak into the next.
local TUNE0 = {}
for k, v in pairs(elro.TUNE or {}) do TUNE0[k] = v end

local function run(spec)
  build()
  -- CLOSE=1 echoes every closure/tighten trace line AS IT HAPPENS. Those lines otherwise live
  -- only inside the mapstep frame `step_snap` folds them into, i.e. they are reachable in game
  -- only -- which meant the closure trace format could not be checked without launching Mudlet.
  -- ⚠ set AFTER the knob reset above would be too late for nothing; it is not a knob, but it must
  -- be re-armed per spec because `run` is called once per spec.
  if os.getenv("CLOSE") then elro.closeEcho = true else elro.closeEcho = nil end
  if os.getenv("ELRODEBUG") then elro.debug = true end
  if os.getenv("BRWATCH") then
    elro._brWatch = {}
    for w in os.getenv("BRWATCH"):gmatch("%d+") do elro._brWatch[tonumber(w)] = true end
  end
  for _, k in ipairs(elro.KNOBS or {}) do elro[k] = nil end      -- reset_knobs, without the echo
  for _, k in ipairs(elro.PROBES or {}) do elro[k] = nil end
  -- (DRAGWATCH, the drag-verdict watch, was stripped 2026-08-18 with the probe in
  -- eqw_forced_shift_1; `probeMove`/`probeSeam` remain the per-step views of the walk)
  for k, v in pairs(TUNE0) do elro.TUNE[k] = v end
  if spec ~= "-" then
    for kv in spec:gmatch("[^,]+") do
      local k, v = kv:match("^(%w+)=(.+)$")
      if not k then error("bad knob spec: " .. kv) end
      if TUNE0[k] ~= nil then elro.TUNE[k] = tonumber(v) or v ; goto nextkv end
      -- ⚠ Validate ONLY when the loaded source has a knob registry. `elro.KNOBS` (and
      -- reset_knobs with it) is recent, so refusing unknown names makes every OLDER commit
      -- unrunnable -- which is exactly when this harness is most useful, bisecting a regression.
      if next(KNOBS) and not KNOBS[k] then error("not a resettable knob: " .. k) end
      if v:find("%+") then                                   -- `k=1+2+3` -> a list knob
        local t = {} ; for n in v:gmatch("[^%+]+") do t[#t + 1] = tonumber(n) or n end
        elro[k] = t
      elseif v == "true" then elro[k] = true
      elseif v == "false" then elro[k] = false
      -- ⛔⛔ THIS WAS `(v=="true") and true or (v=="false") and false or (tonumber(v) or v)`, WHICH
      -- CANNOT RETURN false. `x and false or y` always falls through to y -- the classic Lua and/or
      -- trap -- so `knob=false` set the STRING "false", which is TRUTHY. Every `X=false` A/B run
      -- through this harness therefore left the knob effectively ON, and any recorded "no difference"
      -- verdict for a `false` spec is void. Numbers and `true` were always fine.
      else elro[k] = tonumber(v) or v
      end
      ::nextkv::
    end
  end
  if os.getenv("KNOBDUMP") then
    for _, k in ipairs({"enclLoopBack","enclLoopSmaller","enclLoopBudget","enclVoidStep","enclSepSafe","enclPinV","eqGuillo","classBridgeRule"}) do
      print("   " .. k .. "=" .. tostring(elro[k]))
    end
  end
  -- FORCELEVER="ring:2:u:a,..." -- the offline stand-in for the `maplever` alias. Same table
  -- shape (`elro.forceLever` is KEYED BY ek), so the ranking AND the guard override behave exactly
  -- as they do in game. Not a knob: knob specs are scalars and this is a set.
  elro.forceLever = nil
  do
    local flv = os.getenv("FORCELEVER")
    if flv and flv ~= "" then
      local t = {} ; for ek in flv:gmatch("[^%s,]+") do t[ek] = true end
      elro.forceLever = t
    end
  end
  -- MINLEN="1908:1911=2,1935:1951=2" -- per-edge minimum lengths (elro.minLen). Absent = 1 = today.
  -- ⚠ Not a knob: knob specs are scalars, and this is a table. Set from the environment so a run can
  -- assert a hand-built target's edge lengths and ask whether the EXISTING walk then reaches it.
  elro.minLen = nil
  local ml = os.getenv("MINLEN")
  if ml and ml ~= "" then
    elro.minLen = {}
    for kv in ml:gmatch("[^,]+") do
      local a, b, n = kv:match("^(%d+):(%d+)=(%d+)$")
      if not a then error("bad MINLEN entry: " .. kv) end
      a, b = tonumber(a), tonumber(b)
      if a > b then a, b = b, a end
      elro.minLen[a .. ":" .. b] = tonumber(n)
    end
  end
  -- ⭐ NSCAP=<n> -- raise `elro.ns_cap`, the room count above which `layout_one` abandons the eqw
  -- engine for the flood. It is NOT a knob (a plain field on `elro`), so a spec cannot reach it, and
  -- a dump that trips it lays out in 0.01s with a catastrophic census and NO trace at all -- which
  -- reads exactly like a broken dump. world_new.txt (919 rooms + 94 outside stubs = 1013) is the
  -- first corpus dump to cross the default 1000.
  if os.getenv("NSCAP") then elro.ns_cap = tonumber(os.getenv("NSCAP")) end
  elro.mode = "r"
  elro.engine, elro.engineCache, elro.engineSpace = {}, {}, {}
  elro.bgLayout = false
  if os.getenv("SHWATCH") then elro._shWatch = {} ; for k in os.getenv("SHWATCH"):gmatch("[^,]+") do elro._shWatch[k] = true end end
  elro.recompute_areas()
  for n in pairs(getAreaTable()) do elro.engine[n] = "eqw" end
  for _, aid in pairs(getAreaTable()) do elro.dirty[aid] = true end
  local t0 = os.clock()
  elro.flush_dirty()
  if os.getenv("RDN") then
    print(("   ringDilate: rings=%s builds=%s emitted=%s | clash=%s void=%s class-locked=%s comp2=%s"):format(
      tostring(elro._rdRing or 0), tostring(elro._rdNorm or 0), tostring(elro._rdOut or 0),
      tostring(elro._rdClash or 0), tostring(elro._rdBuild or 0), tostring(elro._rdLocked or 0),
      tostring(elro._rdComp2 or 0)) .. (" | sf-rounds=%s shear-dropped=%s"):format(
      tostring(elro._rdSf or 0), tostring(elro._rdShearDrop or 0)))
    print(("   ringDilate: duplicates of an existing plate dropped = %s"):format(tostring(elro._rdDup or 0)))
    print(("   ringDilate: rider-dropped retries accepted = %s | squarify at close: %s ok, %s declined, %s via rider-drop"):format(
      tostring(elro._rdNoRider or 0), tostring(elro._sqClose or 0), tostring(elro._sqCloseNo or 0), tostring(elro._sqRider or 0)))
    elro._rdNoRider, elro._sqClose, elro._sqCloseNo, elro._sqRider = 0, 0, 0, 0
    elro._rdSf, elro._rdShearDrop, elro._rdDup = 0, 0, 0
    elro._rdRing, elro._rdNorm, elro._rdOut = 0, 0, 0
    elro._rdClash, elro._rdBuild, elro._rdLocked, elro._rdComp2 = 0, 0, 0, 0
  end
  if os.getenv("CNS") then
    print(("   compactNoShear: lane cuts vetoed by a square 45 = %s"):format(tostring(elro._cnsVeto or 0)))
    elro._cnsVeto = 0
  end
  if os.getenv("ATTACH") then
    print(("   attach-edge: generated=%s vetoed=%s picked=%s"):format(
      tostring(elro._attachGen or 0), tostring(elro._attachVeto or 0),
      tostring(elro._attachPick or 0)))
    elro._attachVeto, elro._attachPick, elro._attachGen = 0, 0, 0
  end
  if os.getenv("JSOVL") then
    print(("   junction_score: %s call(s), %s with V/B OVERLAP (%s shared rooms), %s where the"
      .. " blocker is in V AND the subject is in B"):format(
      tostring(elro._jsN2 or 0), tostring(elro._jsOverlapN or 0),
      tostring(elro._jsOverlapCells or 0), tostring(elro._jsMutual or 0)))
    elro._jsN2, elro._jsOverlapN, elro._jsOverlapCells, elro._jsMutual = 0, 0, 0, 0
  end
  if os.getenv("CLOSERANK") then
    print(("   close-rank: %s loop-closure conflict(s) ranked, %s where it CHANGED the top pick")
      :format(tostring(elro._crN or 0), tostring(elro._crMoved or 0)))
    elro._crN, elro._crMoved = 0, 0
  end
  if os.getenv("CLOSESOLVE") then
    print(("   close-solve: %s adopted, %s found-but-defective"):format(
      tostring(elro._csN or 0), tostring(elro._csFail or 0)))
    elro._csN, elro._csFail = 0, 0
  end
  if os.getenv("COUNTERS") then
    print(("   wcProved=%s tcProved=%s wcRan=%s demoted=%s wires(raw)=%s"):format(
      tostring(elro._wcProved), tostring(elro._tcProved), tostring(elro._wcRan),
      tostring(elro._demoted and #elro._demoted), tostring(elro._wireCache and elro._wireCache.n)))
    for _, e in ipairs(elro._demoted or {}) do
      print(("     DEMOTED %s -%s-> %s   %s"):format(tostring(e.r or e.u), tostring(e.d),
        tostring(e.v or e.x), tostring(e.why or e.reason or "")))
    end
    local vs = {}
    for k, v in pairs(elro._diagEqVoid or {}) do vs[#vs + 1] = k .. "=" .. v end
    table.sort(vs)
    print(("   diagEq: emitted=%s declined-walls=%s complete[diag=%s axial=%s] void[%s]"):format(
      tostring(elro._diagEqN), tostring(elro._diagSkew), tostring(elro._diagC1), tostring(elro._diagC2), table.concat(vs, " ")))
    print(("   diagSep: tried=%s won=%s rescue=%s"):format(tostring(elro._diagSepT), tostring(elro._diagSepW), tostring(elro._diagRescue)) .. "  axc=" .. tostring(elro._diagAxc))
    print(("   classTight: seams=%s tried=%s emitted=%s"):format(
      tostring(elro._ctSeam), tostring(elro._ctTry), tostring(elro._ctEmit)))
    print(("   t:r  : gate-passed=%s emitted=%s void=%s same-as-walked=%s | :r rescued a no-clear probe=%s"):format(
      tostring(elro._eqTrTry), tostring(elro._eqTr), tostring(elro._eqTrVoid), tostring(elro._eqTrDup), tostring(elro._eqRigidNC)))
    elro._eqRigidNC = 0
    do
      local vs = {}
      for k, v in pairs(elro._ssSep or {}) do vs[#vs + 1] = k .. "=" .. v end
      table.sort(vs)
      print(("   subsetRetry: sep-voids[%s] subset-found=%s (all-cause ctSubset=%s)"):format(
        table.concat(vs, " "), tostring(elro._ssKept), tostring(elro._ctSubset)))
    end
    print(("   eq2d: wedgeHits=%s calls=%s probes=%s plates=%s shear-rescued=%s gx-free-rescued=%s"):format(
      tostring(elro._eq2dWedge), tostring(elro._eq2dN), tostring(elro._eq2dTry), tostring(elro._eq2dOut), tostring(elro._eq2dShN), tostring(elro._eq2dGxN)))
    elro._eq2dShN, elro._eq2dGxN = 0, 0
    -- the ping-pong guard: how many (magnitude, label) probes it refused. ZERO means the mechanism
    -- is inert on this area, which is the one thing an identity A/B cannot tell you.
    print(("   pingpong: refused=%s (of %s committed shift(s) recorded)"):format(
      tostring(elro._eqPP or 0), tostring(elro._eqPPnote or 0)))
    elro._eqPP, elro._eqPPnote = 0, 0
    -- the piston composition rule: plates that straddled a piston's far side, and what became of
    -- them. `fixed` = re-seeded to the honest larger plate; `kept` = no all-or-nothing form exists
    -- on this axis, so the plate is offered as built (the class tier vetoed here -- see the rule).
    print(("   make-room seeds ADDED to the pool (mrSeeds): %s | seeded pick WON: %s | 2D-inexpressible=%s"):format(
      tostring(elro._mrSeedAdd or 0), tostring(elro._mrSeedWin or 0), tostring(elro._mrs2D or 0)))
    elro._mrSeedAdd, elro._mrSeedWin, elro._mrs2D = 0, 0, 0
    print(("   shear-free: seen=%s hit=%s emitted=%s | :u reseeds=%s | calls-with-seeds=%s"):format(
      tostring(elro._sfSeen or 0), tostring(elro._sfHit or 0), tostring(elro._eqSf or 0),
      tostring(elro._eqUnvSf or 0), tostring(elro._sfMulti or 0)))
    elro._eqUnvSf, elro._sfSeen, elro._sfHit, elro._eqSf, elro._sfMulti = 0, 0, 0, 0, 0
    print(("   piston ride (probeSeam only): %s plate(s) with a BRIDGE on the boundary"):format(
      tostring(elro._eqRide or 0)))
    elro._eqRide, elro._brIdxN = 0, 0
  end
  -- STEPTOP=n prints the slowest-placement-step toplist for this run (needs stepTime=true in the
  -- spec, and timeGuillo=true as well if you want the per-step bucket split). Prints unconditionally
  -- -- unlike cecho it is the thing you asked for, so VERBOSE should not be needed to see it.
  if os.getenv("STEPTOP") then
    local old = cecho
    cecho = function(x) io.write((tostring(x):gsub("<[^>]->", ""))) end
    elro.dump_steptop(tonumber(os.getenv("STEPTOP")))
    cecho = old
  end
  if os.getenv("STUCKLOG") then
    print(("   sheared grid-X: %s search(es) skipped, %s room(s) reclassified out of leftover"):format(
      tostring(elro._gxSkipN or 0), tostring(elro._gxOnlyN or 0)))
  end
  if elro._bcut then
    local ks = {}
    for k, e in pairs(elro._bcut) do ks[#ks + 1] = string.format("%s %d applied / %d cut a block / %d deformed one", k, e.n, e.cut, e.deformed) end
    table.sort(ks)
    print("   block-cut census: " .. table.concat(ks, " | "))
    for _, l in ipairs(elro._bcutList or {}) do print("      " .. l) end
    elro._bcut, elro._bcutList = nil, nil
  end
  if elro._bsProbe or elro._bsWhy then
    local ks = {} ; for k, v in pairs(elro._bsWhy or {}) do ks[#ks + 1] = k .. "=" .. v end ; table.sort(ks)
    print(string.format("   bridge-probes: %d (diag skipped %d) -> plates %d, 2d %d, cascade seeds %d; verdicts: %s",
      elro._bsProbe or 0, elro._bsDiagSkip or 0, elro._bsEmit or 0, elro._bsEmit2d or 0, elro._bsCasc or 0, table.concat(ks, " ")))
    local vs = {} ; for k, v in pairs(elro._bsVoid or {}) do vs[#vs + 1] = k .. "=" .. v end ; table.sort(vs)
    print("   bridge-builds: " .. table.concat(vs, " "))
    elro._bsProbe, elro._bsDiagSkip, elro._bsEmit, elro._bsWhy, elro._bsVoid, elro._bsEmit2d, elro._bsCasc = nil, nil, nil, nil, nil, nil, nil
  end
  local out = {}
  for _, id in ipairs(ORDER) do out[id] = { M.rooms[id].x, M.rooms[id].y } end
  -- MINLEN audit, from the FINAL coordinates. Deliberately harness-side and independent of the
  -- engine's own bookkeeping: the point is to catch a writer that never consulted `min_len`, so
  -- asking the engine whether it thinks it complied would defeat the check.
  if elro.minLen then
    local bad, seenML = 0, {}
    for _, id in ipairs(ORDER) do
      for _, t in pairs(ROOMS[id].exits) do
        if out[t] then
          local k = (id < t) and (id .. ":" .. t) or (t .. ":" .. id)
          local m = (not seenML[k]) and elro.minLen[k] or nil
          if m then
            seenML[k] = true
            local L = math.max(math.abs(out[t][1] - out[id][1]), math.abs(out[t][2] - out[id][2]))
            if L < m then
              bad = bad + 1
              print(("   minLen VIOLATED %s: length %d < %d"):format(k, L, m))
            end
          end
        end
      end
    end
    elro._minLenBad = bad
  end
  return out, os.clock() - t0
end

-- ----------------------------------------------------------------- defects
local D = { north = {0,1}, south = {0,-1}, east = {1,0}, west = {-1,0},
            northeast = {1,1}, northwest = {-1,1}, southeast = {1,-1}, southwest = {-1,-1} }
local function census(P)
  local edges, seen = {}, {}
  for _, id in ipairs(ORDER) do
    for d, t in pairs(ROOMS[id].exits) do
      if D[d] and P[t] then
        local a, b = id, t ; if a > b then a, b = b, a end
        local k = a .. ":" .. b
        if not seen[k] then seen[k] = true ; edges[#edges + 1] = { a, b } end
      end
    end
  end
  local cell, dup = {}, 0
  for _, id in ipairs(ORDER) do
    local k = P[id][1] .. ":" .. P[id][2]
    if cell[k] then dup = dup + 1 else cell[k] = id end
  end
  local skew, lie = 0, 0
  -- ⭐ LIEDUMP=1 NAMES THEM. A lie count answers "how bad"; it never answers "which
  -- edge", and an A/B between two knob settings is only actionable once you can see
  -- WHICH edges appeared -- a count of 4 vs 2 could be two new lies or four different
  -- ones. Sorted so two runs are diffable line for line.
  local LIES = {}
  for _, id in ipairs(ORDER) do
    for d, t in pairs(ROOMS[id].exits) do
      if D[d] and P[t] then
        local dx, dy = P[t][1] - P[id][1], P[t][2] - P[id][2]
        local vx, vy = D[d][1], D[d][2]
        if (vx == 0) ~= (dx == 0) or (vy == 0) ~= (dy == 0)
           or dx * vx < 0 or dy * vy < 0 then
          lie = lie + 1
          LIES[#LIES + 1] = string.format("%6d -%-9s-> %-6d declared (%2d,%2d) actual (%2d,%2d)",
                                          id, d, t, vx, vy, dx, dy)
        elseif vx ~= 0 and vy ~= 0 and math.abs(dx) ~= math.abs(dy) then
          skew = skew + 1
          -- SKEWDUMP=1 names them, for the same reason LIEDUMP does: a count of 3 vs 4 is not
          -- actionable until you can see WHICH 45 tipped.
          if os.getenv("SKEWDUMP") then
            LIES[#LIES + 1] = string.format("SKEW %6d -%-9s-> %-6d declared (%2d,%2d) actual (%2d,%2d)",
                                            id, d, t, vx, vy, dx, dy)
          end
        end
      end
    end
  end
  if os.getenv("LIEDUMP") or os.getenv("SKEWDUMP") then
    table.sort(LIES)
    for _, l in ipairs(LIES) do print("    LIE " .. l) end
  end
  local function side(e, x, y)
    local p, q = P[e[1]], P[e[2]]
    return (q[1] - p[1]) * (y - p[1] * 0 - p[2]) - (q[2] - p[2]) * (x - p[1])
  end
  local cross = 0
  -- WHAT IS A CROSSING WORTH COUNTING? User: *"then you are counting demoted edge crossings and
  -- quad X:es."* Both are inherent, not defects:
  --   QUAD X   -- the two unit diagonals of one unit square MUST cross; that is what a quad IS.
  --              rand's castle contributes FOUR, which the canary header already calls "the
  --              castle's own internal X's".
  --   DEMOTED  -- an edge whose provenance the walk refused (`elro._demoted`) is drawn bowed and is
  --              not a constraint; its crossings are a rendering artifact.
  --   LIE      -- a lying edge is drawn as an arbitrary long slant (rand: `d=(4,3)`, `d=(-6,1)`) and
  --              will cut across whatever is in the way. It is ALREADY counted, as a lie -- billing
  --              its crossings too charges one defect twice.
  -- WARN THE `cross=` FIELD IS DELIBERATELY LEFT ALONE. Every baseline in `canary_out.txt` and in
  -- the memory notes is a census STRING, so changing the field (or adding one) invalidates all of
  -- them at once. The breakdown is printed by `XDUMP=1` instead, which is where it is needed.
  local demoted = {}
  for _, e in ipairs(elro._demoted or {}) do
    local u, v = e[1] or e.u or e.a, e[2] or e.v or e.b
    if u and v then
      demoted[(u < v) and (u .. ":" .. v) or (v .. ":" .. u)] = true
    end
  end
  local xq, xd, xl = 0, 0, 0
  local function ekey(u, v) return (u < v) and (u .. ":" .. v) or (v .. ":" .. u) end
  local function lying(u, v)
    for d, t in pairs(ROOMS[u].exits) do
      if t == v and D[d] then
        local dd, pu, pv = D[d], P[u], P[v]
        local gx, gy = pv[1] - pu[1], pv[2] - pu[2]
        local okx = (dd[1] == 0 and gx == 0) or (dd[1] ~= 0 and gx * dd[1] > 0)
        local oky = (dd[2] == 0 and gy == 0) or (dd[2] ~= 0 and gy * dd[2] > 0)
        local sq  = (dd[1] == 0 or dd[2] == 0) or (math.abs(gx) == math.abs(gy))
        if okx and oky then return false end       -- one recorded direction is truthful
      end
    end
    return true
  end
  for i = 1, #edges do
    for j = i + 1, #edges do
      local a, b = edges[i], edges[j]
      if a[1] ~= b[1] and a[1] ~= b[2] and a[2] ~= b[1] and a[2] ~= b[2] then
        local p, q, r, s = P[a[1]], P[a[2]], P[b[1]], P[b[2]]
        local function cp(o, u, v) return (u[1]-o[1])*(v[2]-o[2]) - (u[2]-o[2])*(v[1]-o[1]) end
        local d1, d2, d3, d4 = cp(r,s,p), cp(r,s,q), cp(p,q,r), cp(p,q,s)
        if ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0)) then
          cross = cross + 1
          local isQuad, isDem, isLie = false, false, false
          do
            local xs, ys = {}, {}
            for _, id in ipairs({ a[1], a[2], b[1], b[2] }) do
              xs[P[id][1]] = true ; ys[P[id][2]] = true
            end
            local nx, ny = 0, 0
            for _ in pairs(xs) do nx = nx + 1 end
            for _ in pairs(ys) do ny = ny + 1 end
            local function unitDiag(u, v)
              local d1, d2 = P[v][1] - P[u][1], P[v][2] - P[u][2]
              return math.abs(d1) == 1 and math.abs(d2) == 1
            end
            isQuad = (nx == 2 and ny == 2 and unitDiag(a[1], a[2]) and unitDiag(b[1], b[2]))
            isDem = demoted[ekey(a[1], a[2])] or demoted[ekey(b[1], b[2])] or false
            isLie = lying(a[1], a[2]) or lying(b[1], b[2])
          end
          if isQuad then xq = xq + 1
          elseif isDem then xd = xd + 1
          elseif isLie then xl = xl + 1 end
          if os.getenv("XDUMP") then
            local function seg(u, v)
              local pu, pv = P[u], P[v]
              return ("%d(%d,%d)->%d(%d,%d) d=(%d,%d)"):format(u, pu[1], pu[2], v, pv[1], pv[2],
                pv[1] - pu[1], pv[2] - pu[2])
            end
            print(("     [cross]%s %s  x  %s"):format(
              isQuad and " QUAD-X" or isDem and " DEMOTED" or isLie and " LIE" or " REAL",
              seg(a[1], a[2]), seg(b[1], b[2])))
          end
        end
      end
    end
  end
  if os.getenv("XDUMP") then
    print(("     [cross] %d total = %d REAL + %d quad-X + %d demoted + %d lie-slant"):format(
      cross, cross - xq - xd - xl, xq, xd, xl))
  end
  local roe = 0
  for _, e in ipairs(edges) do
    local p, q = P[e[1]], P[e[2]]
    local dx, dy = q[1] - p[1], q[2] - p[2]
    for _, id in ipairs(ORDER) do
      if id ~= e[1] and id ~= e[2] then
        local x, y = P[id][1], P[id][2]
        if (x - p[1]) * dy - (y - p[2]) * dx == 0
           and x >= math.min(p[1], q[1]) and x <= math.max(p[1], q[1])
           and y >= math.min(p[2], q[2]) and y <= math.max(p[2], q[2]) then
          roe = roe + 1
          -- ROE=1: NAME the offending triple. `room-on-edge` outranks a crossing, so a delta here
          -- has to be read as geometry, not as a number.
          if os.getenv("ROE") then
            print(("     [roe] %d(%d,%d) sits on %d(%d,%d)->%d(%d,%d)"):format(
              id, x, y, e[1], p[1], p[2], e[2], q[1], q[2]))
          end
        end
      end
    end
  end
  -- ⭐⭐⭐ WASTED INTERNAL SPACE, because the defect counts above are BLIND to what the slack passes
  -- exist for. User: *"they are doing work though, you still haven't added wasted internal space in
  -- your census."* eqw_spread and eqw_reclaim do not remove defects, they decide WHERE slack sits
  -- and reclaim it -- so switching them off can leave every defect count flat (or better) while the
  -- map balloons, and the census would call that a win. Three numbers, cheapest first:
  --   span  = the bounding box, and `fill` = rooms per bbox cell -- the blunt "how airy is it".
  --   len   = TOTAL EDGE LENGTH in grid steps (max(|dx|,|dy|) per edge, so a 45 costs its own
  --           length, not its L1). This is essentially the objective eqw_spread descends on, so it
  --           is the number that should move most when the pass is disabled.
  --   hole  = EMPTY CELLS FULLY ENCLOSED by the drawing -- flood the bbox (4-connected) from
  --           outside over cells that hold no room and no edge raster; whatever the flood cannot
  --           reach is interior void. This is "wasted internal space" in the literal sense: space
  --           the layout has walled off and cannot use.
  local minx, maxx, miny, maxy = math.huge, -math.huge, math.huge, -math.huge
  for _, id in ipairs(ORDER) do
    local p = P[id]
    if p[1] < minx then minx = p[1] end ; if p[1] > maxx then maxx = p[1] end
    if p[2] < miny then miny = p[2] end ; if p[2] > maxy then maxy = p[2] end
  end
  local len = 0
  local solid = {}
  for _, id in ipairs(ORDER) do solid[P[id][1] .. ":" .. P[id][2]] = true end
  for _, e in ipairs(edges) do
    local p, q = P[e[1]], P[e[2]]
    local dx, dy = q[1] - p[1], q[2] - p[2]
    local n = math.max(math.abs(dx), math.abs(dy))
    len = len + n
    -- raster the edge into `solid` so a corridor counts as drawing, not as void
    if n > 0 and (dx == 0 or dy == 0 or math.abs(dx) == math.abs(dy)) then
      local sx, sy = dx / n, dy / n
      for i = 0, n do solid[(p[1] + sx * i) .. ":" .. (p[2] + sy * i)] = true end
    end
  end
  -- STRETCHED EDGES, ONE BY ONE (`EXT=1`). `len` is a TOTAL, so three edges stretched by one cell
  -- reads identically to one edge stretched by three -- and the user's actual complaint about rand
  -- is a COUNT: *"bad extensions ... I see one more now: 5261:5263, so 3 total"*, and *"fsDragLeaf
  -- =true has 3 bad extensions and fsDragLeaf=false has 3 OTHER bad extensions"*. A total cannot
  -- show that; a list can.
  -- WARN NOT EVERY STRETCH IS BAD. A face that had to grow pays for it on its walls, and a dilation
  -- lengthens its cut edges ON PURPOSE. This lists them all and lets the eye judge -- it is a
  -- DIAGNOSTIC, not a defect count, which is also why it is not in the census line.
  if os.getenv("EXT") then
    local ex, tot = {}, 0
    for _, e in ipairs(edges) do
      local p2, q2 = P[e[1]], P[e[2]]
      local n = math.max(math.abs(q2[1] - p2[1]), math.abs(q2[2] - p2[2]))
      local mn = (elro.min_len and elro.min_len(e[1], e[2])) or 1
      if n > mn then
        tot = tot + (n - mn)
        ex[#ex + 1] = { e[1], e[2], n, mn }
      end
    end
    table.sort(ex, function(A, B)
      if (A[3] - A[4]) ~= (B[3] - B[4]) then return (A[3] - A[4]) > (B[3] - B[4]) end
      if A[1] ~= B[1] then return A[1] < B[1] end
      return A[2] < B[2]
    end)
    -- ⭐ MARK THE STUB EDGES. `fsDragLeaf`/`fsDragPend` exist to keep a stub tight, so a
    -- stretched edge with a stub end is a MISS of that rule, while a stretched edge deep in the
    -- mass is ordinary injected slack (or a dilation's cut edge, which is the point of it).
    -- `*` = a LEAF end. `+` = a PENDANT-SUBTREE end -- that side hangs off this one edge (<= 32
    -- rooms), which is what `fs_leaf` cannot see, because a chain ROOT has two placed neighbours.
    local deg, nbr = {}, {}
    for _, e in ipairs(edges) do
      deg[e[1]] = (deg[e[1]] or 0) + 1 ; deg[e[2]] = (deg[e[2]] or 0) + 1
      nbr[e[1]] = nbr[e[1]] or {} ; nbr[e[1]][e[2]] = true
      nbr[e[2]] = nbr[e[2]] or {} ; nbr[e[2]][e[1]] = true
    end
    local function pend(r, x)
      local seen, stack, n = { [x] = true }, { x }, 1
      while #stack > 0 do
        local u = stack[#stack] ; stack[#stack] = nil
        for y in pairs(nbr[u] or {}) do
          if y == r then
            if u ~= x then return false end
          elseif not seen[y] then
            n = n + 1 ; if n > 32 then return false end
            seen[y] = true ; stack[#stack + 1] = y
          end
        end
      end
      return true
    end
    local parts, nleaf, npend = {}, 0, 0
    for _, t in ipairs(ex) do
      local a, b = t[1], t[2]
      local la, lb = deg[a] == 1, deg[b] == 1
      local pa = (not la) and pend(b, a) or false
      local pb = (not lb) and pend(a, b) or false
      -- ⚠ THE MARK GOES ON THE ID, NOT AT THE END. `683:684(3)+` cannot say WHICH end is the stub,
      -- and that is the only thing the line is for.
      local ma = la and "*" or pa and "+" or ""
      local mb = lb and "*" or pb and "+" or ""
      if la or lb then nleaf = nleaf + 1 elseif pa or pb then npend = npend + 1 end
      parts[#parts + 1] = ("%d%s:%d%s(%d)"):format(a, ma, b, mb, t[3])
    end
    print(("     [ext] %d stretched edge(s), %d excess cell(s) -- %d leaf, %d pendant, %d mid: %s")
      :format(#ex, tot, nleaf, npend, #ex - nleaf - npend, table.concat(parts, " ")))
  end
  local W, H = maxx - minx + 1, maxy - miny + 1
  -- flood the empty cells of a ONE-CELL-MARGIN box from its corner; anything empty and unreached
  -- afterwards is enclosed void
  local seenF, stack = {}, { { minx - 1, miny - 1 } }
  seenF[(minx - 1) .. ":" .. (miny - 1)] = true
  while #stack > 0 do
    local c = table.remove(stack)
    for _, d in ipairs({ {1,0}, {-1,0}, {0,1}, {0,-1} }) do
      local nx, ny = c[1] + d[1], c[2] + d[2]
      local k = nx .. ":" .. ny
      if nx >= minx - 1 and nx <= maxx + 1 and ny >= miny - 1 and ny <= maxy + 1
         and not seenF[k] and not solid[k] then
        seenF[k] = true ; stack[#stack + 1] = { nx, ny }
      end
    end
  end
  local hole = 0
  for x = minx, maxx do for y = miny, maxy do
    local k = x .. ":" .. y
    if not solid[k] and not seenF[k] then hole = hole + 1 end
  end end
  -- ⭐⭐⭐ FACE BLOAT -- how much of the wasted space is SOLVED FACES THAT GREW.
  -- `elro._faceSpans` carries, per face the pre-pass actually solved, the per-axis span of its ring
  -- IN THE SOLVE. Measure the same ring in the FINAL layout and sum the positive difference. A face
  -- that merely redistributed length between two walls on one axis contributes ZERO (the closure
  -- equations leave the individual walls free but pin the two axis totals), so this counts only
  -- growth -- injected space -- and never a legal reshuffle.
  -- `bloat` = total cells of growth, `bfaces` = how many solved faces grew at all.
  local bloat, bfaces, bmax, nspan, barea = 0, 0, 0, 0, 0
  for _, s in ipairs(elro._faceSpans or {}) do
    local lox, hix, loy, hiy = math.huge, -math.huge, math.huge, -math.huge
    local ok = true
    for _, r in ipairs(s.ring) do
      local p = P[r]
      if not p then ok = false ; break end
      if p[1] < lox then lox = p[1] end ; if p[1] > hix then hix = p[1] end
      if p[2] < loy then loy = p[2] end ; if p[2] > hiy then hiy = p[2] end
    end
    if ok then
      nspan = nspan + 1
      local gx, gy = (hix - lox) - s.sx, (hiy - loy) - s.sy
      if gx < 0 then gx = 0 end ; if gy < 0 then gy = 0 end
      if gx + gy > 0 then bfaces = bfaces + 1 end
      if gx + gy > bmax then bmax = gx + gy end
      bloat = bloat + gx + gy
      -- ...and the same growth as AREA, which is the unit `hole` is in, so the two can be compared
      -- directly. Span is the honest constraint (it is what the closure equations pin) but a linear
      -- number cannot be weighed against a count of enclosed cells.
      local ga = (hix - lox + 1) * (hiy - loy + 1) - (s.sx + 1) * (s.sy + 1)
      if ga > 0 then barea = barea + ga end
    end
  end
  -- ⭐⭐⭐ GROWTH OVER THE **CYCLE MINIMUM**, for every loaded face whether or not it was solved.
  -- `bloat` above is measured against the SOLVED span, so a face the pre-pass skipped
  -- (`faceShared=false`) drops out of it entirely and the column quietly changes meaning. The cycle
  -- minimum is the smallest a ring can be and still close, needs no solve, and is therefore the one
  -- yardstick every variant can be held to. User: *"faceShared=false makes some internal faces very
  -- big -- maybe we should try to initially make them as small as possible."*
  -- the SOLVED span, matched by ring table identity (both reports carry `rings[fi]` itself), so one
  -- row can show minimum -> solved -> built and separate "the solve asked too much" from "the walk
  -- overshot the solve"
  local solvedOf = {}
  for _, sp in ipairs(elro._faceSpans or {}) do solvedOf[sp.ring] = sp end
  local grow, gfaces, gmax, ngrow = 0, 0, 0, 0
  for _, s in ipairs(elro._faceMinSpans or {}) do
    local lox, hix, loy, hiy = math.huge, -math.huge, math.huge, -math.huge
    local ok = true
    for _, r in ipairs(s.ring) do
      local p = P[r]
      if not p then ok = false ; break end
      if p[1] < lox then lox = p[1] end ; if p[1] > hix then hix = p[1] end
      if p[2] < loy then loy = p[2] end ; if p[2] > hiy then hiy = p[2] end
    end
    if ok then
      ngrow = ngrow + 1
      local gx, gy = (hix - lox) - s.sx, (hiy - loy) - s.sy
      if gx < 0 then gx = 0 end ; if gy < 0 then gy = 0 end
      if gx + gy > 0 then gfaces = gfaces + 1 end
      if gx + gy > gmax then gmax = gx + gy end
      grow = grow + gx + gy
      if os.getenv("OVERMIN") and gx + gy > 0 then
        local sv = solvedOf[s.ring]
        GROWROWS[#GROWROWS + 1] = { r0 = s.ring[1], n = #s.ring, need = s.need,
                                    solved = s.solved, gx = gx, gy = gy,
                                    sx = s.sx, sy = s.sy, bx = hix - lox, by = hiy - loy,
                                    vx = sv and sv.sx, vy = sv and sv.sy, ring = s.ring }
      end
    end
  end
  return { grow = grow, gfaces = gfaces, gmax = gmax, ngrow = ngrow,
           dup = dup, lie = lie, cross = cross, roe = roe, skew = skew, edges = #edges,
           len = len, hole = hole, w = W, h = H, bloat = bloat, bfaces = bfaces,
           bmax = bmax, nspan = nspan, barea = barea,
           fill = #ORDER / (W * H) }
end

-- --------------------------------------------------------------------- go
local specs = {}
for i = 2, #arg do specs[#specs + 1] = arg[i] end
if #specs == 0 then specs = { "-" } end

print(("dump %s -- %d rooms, %d areas"):format(dumpPath, #ORDER, (function()
  local n = 0 ; for _ in pairs(AREA) do n = n + 1 end ; return n end)()))

GROWROWS = {}
local results = {}
for _, spec in ipairs(specs) do
  local P, secs = run(spec)
  local c = census(P)
  results[#results + 1] = { spec = spec, P = P, c = c }
  print(("%-40s %5.2fs  collide=%d lie=%d cross=%d room-on-edge=%d skew-diag=%d"
    .. "  | len=%d hole=%d box=%dx%d fill=%.2f  | bloat=%d(area %d) over %d/%d face(s) max=%d"
    .. "  | overmin=%d over %d/%d loaded face(s) max=%d")
    :format(spec, secs, c.dup, c.lie, c.cross, c.roe, c.skew,
            c.len, c.hole, c.w, c.h, c.fill, c.bloat, c.barea, c.bfaces, c.nspan, c.bmax,
            c.grow, c.gfaces, c.ngrow, c.gmax))
  if os.getenv("RDHALF") then
    print(("     [half] ring plates %d built, %d carry a HALF-MOVED rider; %d of %d moved rooms"):
      format(elro._rdHalfP or 0, elro._rdHalfPP or 0, elro._rdHalfR or 0, elro._rdHalfN or 0))
    print(("     [field] %d call(s), %d void, %d one-D of which %d NON-UNIFORM (%d room(s))"):
      format(elro._ffN or 0, elro._ffVoid or 0, elro._ffOneD or 0, elro._ffNonUni or 0, elro._ffNonUniR or 0))
    do
      local fw = {}
      for k, v in pairs(elro._ffWhy or {}) do fw[#fw + 1] = k .. "=" .. v end
      table.sort(fw)
      print("     [fieldwhy] " .. table.concat(fw, " ")
        .. "  | re: repaired=" .. tostring(elro._ffRoomEdge or 0)
        .. " declined=" .. tostring(elro._ffReDecline or 0)
        .. "  | pin: x=" .. tostring(elro._ffReX or 0) .. " roe=" .. tostring(elro._ffRePin or 0)
        .. "  | reseed: try=" .. tostring(elro._ffReTry or 0)
        .. " ok=" .. tostring(elro._ffReOK or 0)
        .. " keep=" .. tostring(elro._ffReKeep or 0)
        .. " seeds=" .. tostring(elro._ffReSeeds or 0))
      local kw = {}
      for k, v in pairs(elro._ffReKeepWhy or {}) do kw[#kw + 1] = k .. "=" .. v end
      table.sort(kw)
      if #kw > 0 then print("     [reseed-keep] " .. table.concat(kw, " ")) end
      elro._ffReKeepWhy = nil
      elro._ffWhy = nil
    end
    local rs = {}
    for k, v in pairs(elro._rfWhy or {}) do rs[#rs + 1] = k .. "=" .. v end
    table.sort(rs)
    print(("     [ringfield] %d build(s), %d void%s"):format(elro._rfN or 0, elro._rfVoid or 0,
      (#rs > 0) and ("  -- " .. table.concat(rs, " ")) or ""))
    elro._rfN, elro._rfVoid, elro._rfWhy = 0, 0, nil
    local ws = {}
    io.write(string.format("     [sq] 1D-union %d call(s), 2D-square %d call(s), %d merge round(s)\n",
      elro._sq1N or 0, elro._sqN or 0, elro._sqMerge or 0))
    elro._sq1N, elro._sqN, elro._sqMerge = 0, 0, 0
    print(string.format("     [tes] tighten extreme seeds: %d used, %d skipped",
      elro._tesUsed or 0, elro._tesSkip or 0))
    elro._tesUsed, elro._tesSkip = 0, 0
    print(string.format("     [trwhy] tighten declines: no-ring=%d nothing-over-min=%d",
      elro._trNoRing or 0, elro._trNoEdge or 0))
    elro._trNoRing, elro._trNoEdge = 0, 0
    print(string.format("     [trex] extreme push: %d accepted (%d cell(s) of area), %d refused",
      elro._trExOK or 0, elro._trExCells or 0, elro._trExNo or 0))
    elro._trExOK, elro._trExCells, elro._trExNo = 0, 0, 0
    -- ⭐ THE SCAN'S OWN VERDICT, and it is the whole reason `tightenSeedScan` is a knob: `tried`
    -- counts seeds offered PAST the blocked extreme, `won` counts sides an interior seed actually
    -- carried. `tried > 0, won = 0` is the refutation -- the scan paid for field solves and
    -- reclaimed nothing.
    -- Reports unconditionally: a counter gated on another feature's table prints nothing on
    -- exactly the areas where that feature never fires (how the tighten counters went missing once).
    if elro._trExScan or elro._trExScanOK or elro._trExSlack or elro._trExLen then
      print(string.format("     [trscan] seed scan past the extreme: %d tried, %d won"
        .. " | refused: %d slack-injecting, %d map-lengthening",
        elro._trExScan or 0, elro._trExScanOK or 0, elro._trExSlack or 0, elro._trExLen or 0))
      elro._trExScan, elro._trExScanOK = nil, nil
      elro._trExSlack, elro._trExLen = nil, nil
    end
    do
      local fs = {}
      for k, v in pairs(elro._csFam or {}) do fs[#fs + 1] = k .. "=" .. v end
      table.sort(fs)
      io.write("     [closefam] " .. ((#fs > 0) and table.concat(fs, " ") or "(none emitted)") .. "\n")
      elro._csFam = nil
    end
    for k, v in pairs(elro._ffWhy or {}) do ws[#ws + 1] = k .. "=" .. v end
    table.sort(ws)
    if #ws > 0 then print("     [field] void reasons: " .. table.concat(ws, " ")) end
    elro._ffWhy = nil
    elro._ffN, elro._ffVoid, elro._ffOneD, elro._ffNonUni, elro._ffNonUniR = 0,0,0,0,0
    print(("     [xb] %d bound scan(s)"):format(elro._xbN or 0))
    elro._xbN = 0
    print(("     [rigid] %d plate(s) corrected, %d room(s) re-assigned"):
      format(elro._rdRigid or 0, elro._rdRigidR or 0))
    elro._rdHalfP, elro._rdHalfPP, elro._rdHalfR, elro._rdHalfN = 0, 0, 0, 0
    elro._rdRigid, elro._rdRigidR = 0, 0
  end
  -- ⚠ PER RUN, not once at the end: the chunk counters are cumulative and the carry work is
  -- measured by an in-process A/B, so a single tail print would describe the last spec only.
  if os.getenv("OVERMIN") then
    table.sort(GROWROWS, function(x, y) return (x.gx + x.gy) > (y.gx + y.gy) end)
    for j = 1, math.min(#GROWROWS, 10) do
      local g = GROWROWS[j]
      print(("     face off %-6s %2d edges holding %3d room(s)  min %dx%d -> solve %s -> built %dx%d"
        .. "  (+%d over min)"):format(tostring(g.r0), g.n, g.need, g.sx, g.sy,
        g.vx and (g.vx .. "x" .. g.vy) or "SKIPPED", g.bx, g.by, g.gx + g.gy))
      local rr = {}
      for q = 1, math.min(#g.ring, 16) do rr[#rr + 1] = tostring(g.ring[q]) end
      print("        ring: " .. table.concat(rr, " ") .. ((#g.ring > 16) and " ..." or ""))
    end
    GROWROWS = {}
  end
-- FGRP=1 : the CONNECTED COMPONENTS of loaded faces over shared edges -- the unit a "presolve
-- them as a group" pass would solve in one piece. Built from _faceMinSpans (every loaded face, ring
-- included) plus faceUse (which edges are shared).
if os.getenv("FGRP") then
  local F = elro._faceMinSpans or {}
  local eset = {}
  for i, s2 in ipairs(F) do
    local E = {}
    local n = #s2.ring
    for j = 1, n do
      local u, v = s2.ring[j], s2.ring[(j % n) + 1]
      E[(u < v) and (u .. ":" .. v) or (v .. ":" .. u)] = true
    end
    eset[i] = E
  end
  local par = {}
  local function find(a2) while par[a2] and par[a2] ~= a2 do a2 = par[a2] end return a2 end
  for i = 1, #F do par[i] = i end
  for i = 1, #F do for j = i + 1, #F do
    local hit = false
    for k in pairs(eset[i]) do if eset[j][k] then hit = true ; break end end
    if hit then local a2, b2 = find(i), find(j) ; if a2 ~= b2 then par[b2] = a2 end end
  end end
  local comp = {}
  for i = 1, #F do
    local r = find(i)
    local c = comp[r] ; if not c then c = { nf = 0, ne = 0, need = 0 } ; comp[r] = c end
    c.nf = c.nf + 1 ; c.need = c.need + (F[i].need or 0)
    for _ in pairs(eset[i]) do c.ne = c.ne + 1 end
  end
  local rows = {}
  for _, c in pairs(comp) do rows[#rows + 1] = c end
  table.sort(rows, function(x, y) return x.nf > y.nf end)
  print(("     loaded-face groups: %d group(s) over %d loaded face(s)"):format(#rows, #F))
  for i = 1, math.min(#rows, 8) do
    print(("       group: %2d face(s), %3d ring edge(s), %3d inward room(s)")
      :format(rows[i].nf, rows[i].ne, rows[i].need))
  end
end

  if os.getenv("OCL") then
    print(("     order clamp: %s clamped (%s cell(s) of edge paid for it), %s reverted"):format(
      tostring(elro._woN or 0), tostring(elro._woCells or 0), tostring(elro._woLie or 0)))
    elro._woN, elro._woCells, elro._woLie = 0, 0, 0
  end
  if os.getenv("CJ") then
    print(("     crossing-site jumps: %s -- %s"):format(tostring(elro._cjN or 0),
      tostring(elro._cjLog or "(none)")))
    elro._cjN, elro._cjLog = 0, nil
  end
  if os.getenv("LSHR") then
    print(("     loop-shrink: called %s, triggered %s, applied %s move(s) (%s compressing cut(s))")
      :format(tostring(elro._lsCall or 0), tostring(elro._lsTrig or 0), tostring(elro._lsN or 0),
        tostring(elro._lsArc or 0)))
    elro._lsN, elro._lsCall, elro._lsTrig, elro._lsArc = 0, 0, 0, 0
  end
  if os.getenv("SHR") then
    local n, sh = 0, 0
    for _, v in pairs(elro.faceUse or {}) do n = n + 1 ; if v > 1 then sh = sh + 1 end end
    print(("     faceUse: %d edge(s) known, %d shared by >1 face; surcharge fired %s time(s)")
      :format(n, sh, tostring(elro._shrN or 0)))
    elro._shrN = 0
  end
  if os.getenv("CHUNK") then
    print(("     chunks: %s interior(s); %s placed AT FACE CLOSE, %s snapped later, %s refused;"
      .. " %s face(s) re-solved by the carry")
      :format(tostring(elro._chunkTot or 0), tostring(elro._chunkTotEarly or 0),
        tostring(elro._chunkTotN or 0), tostring(elro._chunkTotFail or 0),
        tostring(elro._ffResolved or 0)))
    print(("     carry: %s ring(s) re-closed (%s could NOT close and kept the joint closure);"
      .. " neighbours demanded %s cell(s), park compensated with %s")
      :format(tostring(elro._ffCarried or 0), tostring(elro._ffNoClose or 0),
        tostring(elro._ffRaise or 0), tostring(elro._ffCompensate or 0)))
    elro._ffCarried, elro._ffNoClose, elro._ffRaise, elro._ffCompensate = 0, 0, 0, 0
    elro._chunkTot, elro._chunkTotEarly, elro._chunkTotN, elro._chunkTotFail = 0, 0, 0, 0
    elro._ffResolved = 0
  end
end

if #results > 1 then
  local base = results[1]
  for i = 2, #results do
    local r = results[i]
    local groups, n = {}, 0
    for _, id in ipairs(ORDER) do
      local k = (r.P[id][1] - base.P[id][1]) .. "," .. (r.P[id][2] - base.P[id][2])
      groups[k] = groups[k] or {} ; groups[k][#groups[k] + 1] = id
      if k ~= "0,0" then n = n + 1 end
    end
    print(("\n[%s] vs [%s]: %d room(s) differ"):format(r.spec, base.spec, n))
    local ks = {} ; for k in pairs(groups) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return #groups[a] > #groups[b] end)
    for _, k in ipairs(ks) do
      local g = groups[k]
      local show = {}
      for j = 1, math.min(#g, 12) do show[j] = g[j] end
      print(("  delta (%s) x%d: %s%s"):format(k, #g, table.concat(show, " "), #g > 12 and " ..." or ""))
    end
  end
end

if os.getenv("ORDER") then
  local want = {}
  for w in os.getenv("ORDER"):gmatch("%d+") do want[tonumber(w)] = true end
  local seen, out = {}, {}
  for i, f in ipairs(elro._stepLog or {}) do
    local r = f.focus
    if r and want[r] and not seen[r] then seen[r] = true ; out[#out+1] = string.format("%s@step%d", r, i) end
  end
  print("placement order: " .. table.concat(out, "  ") .. "   (of " .. #(elro._stepLog or {}) .. " steps)")
end
if os.getenv("SEED") then print("move-1 exemptions fired: " .. tostring(elro._reWantedN or 0)) end
if os.getenv("SEED") then print("seed used: " .. tostring(elro._lastSeed)) end
if os.getenv("WRITE") then
  for _, r in ipairs(results) do
    local path = os.getenv("WRITE") .. "_" .. r.spec:gsub("[^%w]", "") .. ".txt"
    local f = assert(io.open(path, "w"))
    f:write(("-- offline relayout of %s [%s]\n"):format(dumpPath, r.spec))
    for _, id in ipairs(ORDER) do
      local ex, ds = {}, {}
      for d in pairs(ROOMS[id].exits) do ds[#ds + 1] = d end
      table.sort(ds)
      for _, d in ipairs(ds) do ex[#ex + 1] = d .. "->" .. ROOMS[id].exits[d] end
      f:write(("  %d (%d,%d,0) area=%s [%s]\n"):format(id, r.P[id][1], r.P[id][2],
        ROOMS[id].area, table.concat(ex, ", ")))
    end
    f:close()
    print("wrote " .. path)
  end
end
-- (debug tail) confirm the last run's knob state

-- STEPDELTA=101 : what a single step ACTUALLY moved. The ranked block says what was PICKED and
-- how big it claimed to be; this says what the committed frame differs from the one before it,
-- which is the only way to tell a plate that grew from a plate plus whatever ran after it.
if os.getenv("STEPDELTA") then
  local n = tonumber(os.getenv("STEPDELTA"))
  local L = elro._stepTimeLog or {}
  local function pos(i)
    local P = {} ; local fr = L[i]
    for j = 1, #((fr and fr.flat) or {}), 3 do P[fr.flat[j]] = { fr.flat[j + 1], fr.flat[j + 2] } end
    return P
  end
  local A, B = pos(n - 1), pos(n)
  local by = {}
  for id, q in pairs(B) do
    local p = A[id]
    if p and (p[1] ~= q[1] or p[2] ~= q[2]) then
      local k = (q[1] - p[1]) .. "," .. (q[2] - p[2])
      by[k] = by[k] or {} ; by[k][#by[k] + 1] = id
    end
  end
  local ks = {} ; for k in pairs(by) do ks[#ks + 1] = k end ; table.sort(ks)
  print(("step %d  %s"):format(n, tostring(L[n] and L[n].label):gsub("<[^>]->", "")))
  for _, k in ipairs(ks) do
    table.sort(by[k])
    print(("   delta (%s) x%d: %s"):format(k, #by[k], table.concat(by[k], " ")))
  end
end

-- ROESTEP=1 : replay the step log and print the frame where each room-on-edge incidence FIRST
-- appears. A census roe is a whole-relayout number; the actionable question is always which STEP
-- made it, because that names the pull whose guard should have refused it.
if os.getenv("ROESTEP") then
  local seen = {}
  for i, fr in ipairs(elro._stepTimeLog or {}) do
    local P = {}
    for j = 1, #(fr.flat or {}), 3 do P[fr.flat[j]] = { fr.flat[j + 1], fr.flat[j + 2] } end
    local es = {}
    for _, id in ipairs(ORDER) do
      if P[id] then
        for d, t in pairs(ROOMS[id].exits) do
          if D[d] and P[t] then
            local a, b = id, t ; if a > b then a, b = b, a end
            es[a .. ":" .. b] = { a, b }
          end
        end
      end
    end
    for k, e in pairs(es) do
      local p, q = P[e[1]], P[e[2]]
      local dx, dy = q[1] - p[1], q[2] - p[2]
      for _, id in ipairs(ORDER) do
        if P[id] and id ~= e[1] and id ~= e[2] then
          local x, y = P[id][1], P[id][2]
          if (x - p[1]) * dy - (y - p[2]) * dx == 0
             and x >= math.min(p[1], q[1]) and x <= math.max(p[1], q[1])
             and y >= math.min(p[2], q[2]) and y <= math.max(p[2], q[2]) then
            local kk = id .. "@" .. k
            if not seen[kk] then
              seen[kk] = true
              print(("step %4d  ROE %d(%d,%d) on %d(%d,%d)->%d(%d,%d)   %s"):format(
                i, id, x, y, e[1], p[1], p[2], e[2], q[1], q[2],
                tostring(fr.label):gsub("<[^>]->", "")))
            end
          end
        end
      end
    end
  end
end

-- XSTEP=1 : the crossing counterpart of ROESTEP. Replay the step log and print the frame where each
-- REAL crossing FIRST appears, plus the frame where it LAST disappears if the walk ever undoes it.
-- ⭐⭐ WHY IT IS WORTH ITS OWN PASS: a crossing that survives to the census has usually been a
-- CONSTRAINT for most of the walk, not just a result. `crossing_bounds()` turns every proper
-- crossing between two truthful edges into HARD bounds, so from the step it is first accepted every
-- plate that would move across it voids `lock-cross` -- including the tighten that would take the
-- slack back out. Naming the birth step is therefore naming the last moment it was cheap to refuse.
-- Quad-X (both edges unit diagonals of ONE unit square) is excluded, exactly as XDUMP excludes it.
if os.getenv("XSTEP") then
  local function ori(ax, ay, bx, by, cx, cy)
    local v = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
    return (v > 0) and 1 or ((v < 0) and -1 or 0)
  end
  local born, prev = {}, {}
  local L = elro._stepTimeLog or {}
  for i, fr in ipairs(L) do
    local P = {}
    for j = 1, #(fr.flat or {}), 3 do P[fr.flat[j]] = { fr.flat[j + 1], fr.flat[j + 2] } end
    local es, now = {}, {}
    for _, id in ipairs(ORDER) do
      if P[id] then
        for d, t in pairs(ROOMS[id].exits) do
          if D[d] and P[t] then
            local a, b = id, t ; if a > b then a, b = b, a end
            es[a .. ":" .. b] = { a, b }
          end
        end
      end
    end
    local list = {} ; for k, e in pairs(es) do list[#list + 1] = { k, e[1], e[2] } end
    table.sort(list, function(x, y) return x[1] < y[1] end)
    for m = 1, #list do
      for n = m + 1, #list do
        local e1, e2 = list[m], list[n]
        if e1[2] ~= e2[2] and e1[2] ~= e2[3] and e1[3] ~= e2[2] and e1[3] ~= e2[3] then
          local a, b, c, d = P[e1[2]], P[e1[3]], P[e2[2]], P[e2[3]]
          local d1 = ori(c[1], c[2], d[1], d[2], a[1], a[2])
          local d2 = ori(c[1], c[2], d[1], d[2], b[1], b[2])
          local d3 = ori(a[1], a[2], b[1], b[2], c[1], c[2])
          local d4 = ori(a[1], a[2], b[1], b[2], d[1], d[2])
          if d1 ~= 0 and d2 ~= 0 and d3 ~= 0 and d4 ~= 0
             and ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0)) then
            local xs, ys = {}, {}
            for _, q in ipairs({ a, b, c, d }) do xs[q[1]] = true ; ys[q[2]] = true end
            local nx, ny = 0, 0
            for _ in pairs(xs) do nx = nx + 1 end
            for _ in pairs(ys) do ny = ny + 1 end
            local quad = (nx == 2 and ny == 2)
            if not quad then now[e1[1] .. " x " .. e2[1]] = { a, b, c, d } end
          end
        end
      end
    end
    for k, q in pairs(now) do
      if not prev[k] then
        born[#born + 1] = { i, k, q, fr.label }
        print(("step %4d  CROSS BORN  %s   (%d,%d)-(%d,%d) x (%d,%d)-(%d,%d)   %s"):format(
          i, k, q[1][1], q[1][2], q[2][1], q[2][2], q[3][1], q[3][2], q[4][1], q[4][2],
          tostring(fr.label):gsub("<[^>]->", "")))
      end
    end
    for k in pairs(prev) do
      if not now[k] then
        print(("step %4d  cross gone   %s   %s"):format(
          i, k, tostring(fr.label):gsub("<[^>]->", "")))
      end
    end
    prev = now
  end
  print(("[xstep] %d crossing birth(s) over %d frame(s); %d still standing at the last frame"):format(
    #born, #L, (function() local n = 0 ; for _ in pairs(prev) do n = n + 1 end ; return n end)()))
end

-- QUAD="a,b,c,d" : replay the step log and print every frame in which the quad's geometry changes.
-- Written to find WHERE a face-local solve shears a grid-X quad (dannoc 3827/3831/3847/3848).
if os.getenv("QUAD") then
  local ids = {}
  for w in os.getenv("QUAD"):gmatch("%d+") do ids[#ids + 1] = tonumber(w) end
  local prev
  for i, f in ipairs(elro._stepTimeLog or {}) do
    local P = {}
    for j = 1, #(f.flat or {}), 3 do P[f.flat[j]] = { f.flat[j + 1], f.flat[j + 2] } end
    local parts = {}
    for _, id in ipairs(ids) do
      parts[#parts + 1] = P[id] and ("%d(%d,%d)"):format(id, P[id][1], P[id][2]) or ("%d-"):format(id)
    end
    local key = table.concat(parts, " ")
    if key ~= prev then
      prev = key
      print(("step %4d  %s\n            %s"):format(i, key, tostring(f.label):gsub("<[^>]->", "")))
    end
  end
end

-- PULL="1445,390" : print the RANKED CANDIDATE BLOCK for every frame whose label names one of
-- these rooms. The mapstep dump (`layout.lua`'s `step_snap` renderer) is the only place this is
-- readable in game; `pull` goes into the TIME log unconditionally, so offline it just needs
-- reading back out. Answers "which plates were on the table and why did this one win" without
-- launching Mudlet -- the question every seam/lever session opens with.
if os.getenv("PULL") then
  local want = {}
  for w in os.getenv("PULL"):gmatch("%d+") do want[w] = true end
  for i, f in ipairs(elro._stepTimeLog or {}) do
    local lab = tostring(f.label):gsub("<[^>]->", "")
    local hit = false
    for w in lab:gmatch("%d+") do if want[w] then hit = true end end
    if hit and f.pull and f.pull.ranked then
      local p = f.pull
      print(("step %4d  %s"):format(i, lab))
      print(("   conflict=%s blocker=%s -> pull %s %s dist=%s score=%s (rooms=%s cost=%s)"):format(
        tostring(p.ckind), tostring(p.blocker), tostring(p.kind), tostring(p.ek),
        tostring(p.dist), tostring(p.score), tostring(p.rooms), tostring(p.cost)))
      for _, c in ipairs(p.ranked) do
        print(("   %-8s %-22s score=%-20s seam=%-5s shear=%-3s rooms=%-4s cost=%-2s %s%s"):format(
          tostring(c.kind), tostring(c.ek), tostring(c.score),
          c.seamTight and tostring(c.seamTight) or (c.seamFree and "free" or "-"),
          tostring(c.shear or 0), tostring(c.rooms), tostring(c.cost), tostring(c.why),
          c.detail and (" [" .. tostring(c.detail) .. "]") or ""))
        if c.seamGrow then
          print(("        seam size: %d cell(s) injected over %s edge(s) at the tightest face"):format(
            c.seamGrow, tostring(c.seamAtMin)))
        end
        if c.seamEdges and #c.seamEdges > 0 then                 -- elro.probeSeam
          print(("        seam(%d edges): %s"):format(#c.seamEdges, table.concat(c.seamEdges, " ")))
          if c.seamEdges.plate then print("        plate: " .. c.seamEdges.plate) end
        end
      end
      -- the [plate-gen] funnel -- the block that distinguishes "offered and outranked" from "never
      -- generated". In game it renders from `step_snap`; offline it just needs reading back out.
      if f.guilloTrace then
        print("   [plate-gen]")
        for _, rec in ipairs(f.guilloTrace) do
          if rec.header then print("    -- " .. rec.header) end
        end
      end
    end
  end
end

-- ATSTEP=N : print every placed room in frame N, sorted by column then row. Answers "what was
-- actually in the way" for a room that was born far from its parent.
if os.getenv("ATSTEP") then
  local want = tonumber(os.getenv("ATSTEP"))
  local f = (elro._stepTimeLog or {})[want]
  if f and f.flat then
    local rows = {}
    for j = 1, #f.flat, 3 do
      rows[#rows + 1] = { id = f.flat[j], x = f.flat[j + 1], y = f.flat[j + 2] }
    end
    table.sort(rows, function(a2, b2)
      if a2.x ~= b2.x then return a2.x < b2.x end return a2.y < b2.y end)
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = ("%d(%d,%d)"):format(r.id, r.x, r.y) end
    print(("   step %d: %s"):format(want, table.concat(out, " ")))
  end
end

-- CLOSETRACE=1 : the loop-closure diagnostics (`probeClose`). They live in the STEP FRAME now, not
-- in cecho -- the user asked for mapstep -- so offline they have to be read back out of the log.
if os.getenv("CLOSETRACE") then
  for i, f in ipairs(elro._stepTimeLog or {}) do
    if f.closeTrace then
      for _, ln in ipairs(f.closeTrace) do print(("step %4d  %s"):format(i, ln)) end
    end
  end
end

-- PLACEORDER=1 : step index -> room, for every placement frame, so a placement ORDER claim
-- ("this block should have closed before that pendant was placed") can be checked directly.
if os.getenv("PLACEORDER") then
  for i, f in ipairs(elro._stepTimeLog or {}) do
    local lab = tostring(f.label):gsub("<[^>]->", "")
    local r = lab:match("^walk: placed (%d+)")
    if r then print(("step %4d  placed %s"):format(i, r))
    elseif lab:match("^facefit") or lab:match("^mesh composed") then
      print(("step %4d  -- %s"):format(i, lab))
    end
  end
end

-- GRIDX=1 : how often the geometric grid-X exemption in first_crossing fires, and how many of those
-- the STRUCTURAL test (`real_gridx`, elro.gridXReal) then rejects because the four rooms are not an
-- axial 4-cycle -- i.e. pairs that only LOOK like a wizard grid-X. `_gxPend` (degree-1 endpoints)
-- used to be reported here and was never assigned by anything; the fake count is the real question.
-- FACEAREA=1 : TOTAL AREA ACROSS ALL BOUNDED FACES -- the objective the user optimises for
-- (*"I am actually optimizing for minimum total area across ALL faces"*). Uses the ENGINE's own
-- face enumeration (facefit's topoOnly mode returns `rep.rings`) rather than a second rotation
-- system in the harness, so the measurement and the engine can never disagree about what a face is.
-- ⭐ A FACE CONTAINED IN ANOTHER COUNTS TWICE, deliberately -- user: *"a face contained in another
-- face should count double basically."* Shoelace over the ring gives the container's FULL area as
-- if solid, and the inner structure's own faces are separate rings that add their area again. That
-- is exactly the bias wanted: a big container holding a small structure is charged for the hole it
-- leaves AND for what sits in it, which is the face-fit bloat shape.
if os.getenv("FACEAREA") then
  local rooms = {}
  for _, id in ipairs(ORDER) do rooms[#rooms + 1] = id end
  local A = {}
  for _, id in ipairs(ORDER) do
    A[id] = {}
    for d, t in pairs(ROOMS[id].exits) do if ROOMS[t] then A[id][elro.norm(d)] = t end end
  end
  local _, rep = elro.facefit(rooms, elro.walk_adj(A), true)
  for _, r in ipairs(results) do
    local tot, n, big = 0, 0, {}
    for _, f in ipairs((rep and rep.rings) or {}) do
      local s2, ok = 0, true
      for i = 1, #f do
        local p1, p2 = r.P[f[i]], r.P[f[(i % #f) + 1]]
        if not (p1 and p2) then ok = false ; break end
        s2 = s2 + (p1[1] * p2[2] - p2[1] * p1[2])
      end
      if ok then
        local a = s2 / 2 ; if a < 0 then a = -a end
        tot = tot + a ; n = n + 1
        big[#big + 1] = { a = a, r0 = f[1], k = #f }
      end
    end
    table.sort(big, function(p, q) return p.a > q.a end)
    local names = {}
    for i = 1, math.min(#big, 5) do
      names[#names + 1] = ("%.0f@%d(%dr)"):format(big[i].a, big[i].r0, big[i].k)
    end
    print(("   %-38s face area %8.0f over %3d face(s)  largest: %s")
      :format(r.spec, tot, n, table.concat(names, " ")))
  end
end
-- EQC=1 : does the closure driver ever HAVE a choice, and does the sg/dg key decide it differently
-- from the old cost-then-size rule? A term that never fires and a term that fires and agrees look
-- the same in the census, and only the first is a reason to drop it.
if os.getenv("BFSTALE") then
  print(("   bridge_forest cache: %s hit(s) with a STALE placed count, max drift %s room(s)"):format(
    tostring(elro._bfStale or 0), tostring(elro._bfStaleMax or 0)))
end
-- ⭐⭐ LSEV=1 : every LEAST-SEVERE last-resort apply the walk took, with its step label. Needs only
-- `stepTime=true` (the label is set on every frame; only the coordinate `flat` needs stepDebug), so
-- it is cheap enough to sweep the whole corpus. The tier picks by a candidate's REJECTION LABEL and
-- audits crossings only ([[project_least_severe_label]]), so "was it entered at all, and on what"
-- is the question that says whether that bug is still reachable on a CURRENT dump.
if os.getenv("LSEV") then
  local n = 0
  for i, f in ipairs(elro._stepTimeLog or {}) do
    local lab = tostring(f.label):gsub("<[^>]->", "")
    if lab:find("LEAST%-SEVERE") then
      n = n + 1
      print(("   [lsev] step %4d  %s"):format(i, lab))
    end
  end
  print(("   [lsev] %d least-severe apply(ies) over %d frame(s)"):format(n, #(elro._stepTimeLog or {})))
  elro._stepTimeLog = {}
end
if os.getenv("RSPLIT") then
  print(("   rigidSplit: %s subtree split(s) taken (%s room(s) kept), %s refused because the split"
    .. " would TIP a bridge"):format(tostring(elro._rsSplit or 0), tostring(elro._rsKept or 0),
    tostring(elro._rsTip or 0)))
  elro._rsSplit, elro._rsKept, elro._rsTip = 0, 0, 0
end
if os.getenv("EQC") then
  print(("   eqw_close entered %s, ALREADY truthful %s | eqw-eq phases %s, with >1 viable option %s,"
    .. " sg/dg changed the pick %s"):format(
    tostring(elro._eqcEntry or 0), tostring(elro._eqcAlready or 0),
    tostring(elro._eqcCall or 0), tostring(elro._eqcOpts or 0), tostring(elro._eqcFlip or 0)))
  print(("   closeTight: %s truthful-but-slack edge(s) attempted, %s reclaimed something, %s cell(s)"
    .. " total | refused for shear %s | ring walks %s reclaiming %s cell(s)")
    :format(tostring(elro._eqcTight or 0), tostring(elro._eqcTightWon or 0),
            tostring(elro._eqcTightCells or 0), tostring(elro._eqcTightShear or 0),
            tostring(elro._eqcRing or 0), tostring(elro._eqcRingCells or 0)))
  print(("   closeRepair: %s closure(s) landed a defect, %s re-solved (%s incidence(s) cleared),"
    .. " %s had no improving re-solve | xbounds: %s unlicensed crossing(s) NOT locked, %s on a lie")
    :format(tostring(elro._crpN or 0), tostring(elro._crpOK or 0), tostring(elro._crpFix or 0),
            tostring(elro._crpNo or 0), tostring(elro._xbUnlic or 0), tostring(elro._xbLie or 0)))
  elro._crpN, elro._crpOK, elro._crpFix, elro._crpNo = 0, 0, 0, 0
  elro._xbUnlic, elro._xbLie = 0, 0
  print(("   eqw_make_room ranked %s choice(s), sg differed in %s, ONLY the graded count separated %s")
    :format(tostring(elro._mrOpts or 0), tostring(elro._mrSgSplit or 0), tostring(elro._mrGraded or 0)))
  -- ⭐ `closeAssertEq`: an option that never fires and an option that fires and loses are the same
  -- 0-rooms-differ in the census, and only the first is a reason to look at the ARMING rather than
  -- at the ranking. `built` = the plate was produced, `PICKED` = it won its phase.
  local w = {}
  for k, n in pairs(elro._aeWhy or {}) do w[#w + 1] = k .. "=" .. n end
  table.sort(w)
  -- ⭐ THE WHOLE VERDICT ON `deferPendingClose` IS THIS RATIO. `gone` means the closure WAS the
  -- repair and the lever the walk used to spend was waste; `left` means the conflict is real and
  -- the next piece is a post-closure lever tier rather than a leftover.
  print(("   xboundTruthOnly: %s crossing(s) denied a HARD bound because an edge was a lie"):format(
    tostring(elro._xbLie or 0)))
  print(("   deferPendingClose: %s deferred -> %s went away with the closure, %s SURVIVED"):format(
    tostring(elro._dcDefer or 0), tostring(elro._dcGone or 0), tostring(elro._dcLeft or 0)))
  print(("   assert-eq: %s built, %s PICKED | not built: %s"):format(
    tostring(elro._aeOpt or 0), tostring(elro._aePick or 0),
    (#w > 0) and table.concat(w, " ") or "-"))
end
-- SHARED="3 4 5 24" : the offline stand-in for the `mapshared` alias -- same reads, room list from
-- the environment instead of the map selection. Reports against the LAST spec's coordinates.
if os.getenv("SHARED") then
  RESULT_P = results[#results].P
  dofile(os.getenv("SHAREDPROBE") or "analysis/shared_probe.lua")
end
if os.getenv("GRIDX") then
  print(("   grid-X exemption: %s fired, %s rejected as not a real quad%s"):format(
    tostring(elro._gxN or 0), tostring(elro._gxFake or 0),
    elro._gxFakeList and ("  [" .. table.concat(elro._gxFakeList, " ") .. "]") or ""))
end

if os.getenv("CFF") then
  print(("   chunk-face-first: fired %s time(s), %s block(s) had a big chunk but NO matching face"):format(tostring(elro._cffN or 0), tostring(elro._cffMiss or 0)))
end


if os.getenv("FB") then
  print(("   face-bloat term: %s candidate(s) priced > 0"):format(tostring(elro._fbHit or 0)))
end

-- ONRING="a,b,c" : is each room on a SOLVED face's ring? (the only geometry face_bloat can see)
if os.getenv("ONRING") then
  local on = {}
  for i, s in ipairs(elro._faceSpans or {}) do
    for _, r in ipairs(s.ring) do on[r] = (on[r] and (on[r] .. ",") or "") .. i end
  end
  for w in os.getenv("ONRING"):gmatch("%d+") do
    print(("   room %-6s on solved ring(s): %s"):format(w, on[tonumber(w)] or "NONE"))
  end
end

if os.getenv("COVER") then
  local on, n = {}, 0
  for _, s in ipairs(elro._faceSpans or {}) do
    for _, r in ipairs(s.ring) do if not on[r] then on[r] = true ; n = n + 1 end end
  end
  print(("   solved-ring coverage: %d of %d room(s) (%.1f%%) lie on a solved face ring")
    :format(n, #ORDER, 100 * n / #ORDER))
end

if os.getenv("FACES") then
  local rooms = {}
  for _, id in ipairs(ORDER) do rooms[#rooms + 1] = id end
  local A = {}
  for _, id in ipairs(ORDER) do
    A[id] = {}
    for d, t in pairs(ROOMS[id].exits) do if ROOMS[t] then A[id][elro.norm(d)] = t end end
  end
  local _, rep = elro.facefit(rooms, elro.walk_adj(A))
  if rep then
    local ringRooms, n = {}, 0
    for _, f in ipairs(rep.rings or {}) do
      for _, r in ipairs(f) do if not ringRooms[r] then ringRooms[r] = true ; n = n + 1 end end
    end
    print(("   facefit traces %d face(s) (%d bounded); rings cover %d of %d room(s) (%.1f%%)")
      :format(rep.faces or 0, rep.bounded or 0, n, #ORDER, 100 * n / #ORDER))
  end
end

if os.getenv("DIAGR") then
  print(("   eqw_diag_shift alternation: max %s round(s), %s bail(s)")
    :format(tostring(elro._diagRoundMax or 0), tostring(elro._diagRoundBail or 0)))
end

if os.getenv("WD") then
  print(("   watchdog: fired=%s phase=%s room=%s guard=%s"):format(
    tostring(elro._wdFired), tostring(elro._wdPhase), tostring(elro._wdRoom), tostring(elro._wdGuard)))
end

if os.getenv("MLC") then
  print(("   minLen merge: %s demand(s) from solved faces, %s CONTESTED (two faces disagreed),"
    .. " %s cell(s) added by taking the max"):format(
    tostring(elro._mlWant or 0), tostring(elro._mlContested or 0), tostring(elro._mlOverMax or 0)))
end

if os.getenv("CPS") then
  print(("   constrained placement: %s cell(s) chosen differently from the first-lock answer")
    :format(tostring(elro._cpPick or 0)))
end

-- SHARED=1 : the SIZE OF THE SHARED-EDGE PROBLEM, before any joint solve is built. Each solved face
-- publishes a wish per ring edge (`sp.own`); this counts how often two SOLVED faces wish about the
-- SAME edge, and whether they agreed. `_mlContested` already counts the disagreements; what it
-- cannot say is how many shared edges there were to disagree about, i.e. whether "8 contested" is
-- 8 of 10 or 8 of 200. Read-only over the finished report -- it makes no decision.
if os.getenv("SHARED") then
  local wish, nFace = {}, 0
  for _, sp in ipairs(elro._faceSpans or {}) do
    if sp.own then
      nFace = nFace + 1
      for k, v in pairs(sp.own) do
        local w = wish[k] ; if not w then w = {} ; wish[k] = w end
        w[#w + 1] = { f = nFace, v = v }
      end
    end
  end
  local nEdge, nShared, nAgree, nDis, cells = 0, 0, 0, 0, 0
  local pairsSeen = {}
  local rows = {}
  for k, w in pairs(wish) do
    nEdge = nEdge + 1
    if #w > 1 then
      nShared = nShared + 1
      local lo, hi = math.huge, -math.huge
      for _, e in ipairs(w) do
        if e.v < lo then lo = e.v end ; if e.v > hi then hi = e.v end
      end
      if hi > lo then
        nDis = nDis + 1 ; cells = cells + (hi - lo)
        rows[#rows + 1] = { k = k, lo = lo, hi = hi, n = #w }
      else nAgree = nAgree + 1 end
      for a = 1, #w do for b = a + 1, #w do
        local key = w[a].f .. "|" .. w[b].f
        pairsSeen[key] = (pairsSeen[key] or 0) + 1
      end end
    end
  end
  local nPair = 0 ; for _ in pairs(pairsSeen) do nPair = nPair + 1 end
  -- ⭐⭐⭐ AND THE COST OF MERGING **PER EDGE** RATHER THAN PER SHARED CHAIN. A face's individual wall
  -- lengths are underdetermined -- sliding length between two walls on the same axis is free and the
  -- ring still closes -- so A's split is arbitrary, and taking the max edge by edge adds A's split
  -- AND B's split on the same run of shared edges. What both faces actually determined is the total
  -- across the shared run; anything above that is double-counted.
  do
    local own, tot = {}, 0
    for _, sp in ipairs(elro._faceSpans or {}) do
      if sp.own then own[#own + 1] = sp.own end
    end
    local waste, chains = 0, 0
    for a = 1, #own do for b = a + 1, #own do
      local sa, sb, sm, nsh = 0, 0, 0, 0
      for k, va in pairs(own[a]) do
        local vb = own[b][k]
        if vb then
          nsh = nsh + 1 ; sa = sa + va ; sb = sb + vb
          sm = sm + math.max((elro.minLen or {})[k] or 1, va, vb)
        end
      end
      if nsh > 0 then
        chains = chains + 1
        local need = (sa > sb) and sa or sb
        if sm > need then waste = waste + (sm - need) end
        tot = tot + nsh
      end
    end end
    print(("     per-edge merge vs per-run total: %d shared run(s), %d edge-share(s); the max-merge"
      .. " costs %d cell(s) over what both faces actually determined"):format(chains, tot, waste))
  end
  print(("   shared edges: %d solved face(s), %d distinct ring edge(s); %d shared by >1 solved face"
    .. " (%d agree, %d DISAGREE, %d cell(s) of spread) over %d face pair(s)")
    :format(nFace, nEdge, nShared, nAgree, nDis, cells, nPair))
  table.sort(rows, function(a, b) return (a.hi - a.lo) > (b.hi - b.lo) end)
  for j = 1, math.min(#rows, 8) do
    print(("     edge %-14s wished %d..%d by %d face(s)"):format(rows[j].k, rows[j].lo, rows[j].hi,
      rows[j].n))
  end
end

-- FORCED=1 : per solved face, how many of ITS edges carry a minimum RAISED by a neighbouring face,
-- and by how much. The user's hypothesis for pre-inward bloat: the ring is built to those raised
-- floors, its other edges keep their own preferred length, and nothing compensates -- so it cannot
-- close at its solved shape.
if os.getenv("FORCED") then
  local rows, tot, totF = {}, 0, 0
  for i, sp in ipairs(elro._faceSpans or {}) do
    if sp.own then
      local nRaise, cells = 0, 0
      for k, mine in pairs(sp.own) do
        local pub = (elro.minLen or {})[k] or 1
        if pub > mine then nRaise = nRaise + 1 ; cells = cells + (pub - mine) end
      end
      local n = 0 ; for _ in pairs(sp.own) do n = n + 1 end
      if nRaise > 0 then totF = totF + 1 end
      tot = tot + 1
      rows[#rows + 1] = { i = i, r0 = sp.ring[1], n = n, nRaise = nRaise, cells = cells }
    end
  end
  table.sort(rows, function(a, b) return a.cells > b.cells end)
  print(("   forced extensions: %d of %d solved face(s) have an edge raised by a NEIGHBOUR")
    :format(totF, tot))
  for j = 1, math.min(#rows, 8) do
    local r = rows[j]
    print(("     face off %-6s %2d edges  %2d raised by a neighbour  (+%d cells)")
      :format(tostring(r.r0), r.n, r.nRaise, r.cells))
  end
end

-- FACECOST=1 : is the per-edge bloat score actually populated in this configuration? `faceCost` is
-- built from `elro.faceRings`, which is published by the face-fit pre-pass OR (with faceFit=false) by
-- the `sharedEdges` topology pass -- so a knob set that turns both off leaves the term silently nil.
if os.getenv("FACECOST") then
  local n, lo, hi, sum = 0, nil, nil, 0
  for _, v in pairs(elro.faceCost or {}) do
    n = n + 1 ; sum = sum + v
    if not lo or v < lo then lo = v end
    if not hi or v > hi then hi = v end
  end
  print(("   faceCost: %d edge(s) scored, range %s..%s, mean %s | faceRings=%d faceUse=%s"):format(
    n, tostring(lo), tostring(hi), (n > 0) and ("%.1f"):format(sum / n) or "-",
    #(elro.faceRings or {}), elro.faceUse and "yes" or "NIL"))
end
-- Restore the biggest compose's frames (see the compose_spqr_adj wrapper above) so RENDERSTEP and
-- TRACECHECK below show the walk that built the map, not the last shelf-pack of leftovers.
if elro._bigStepLog and #elro._bigStepLog > #(elro._stepLog or {}) then
  elro._stepLog = elro._bigStepLog
end
-- RENDERSTEP=n : exercise the real mapstep frame renderer offline (it is otherwise in-game only)
-- SHAPE=<id,id,...> : print every step frame in which the listed rooms' geometry RELATIVE to each
-- other changes (a block riding whole is silent; a tear, stretch or shear of it is not). needs stepDebug
if os.getenv("SHAPE") then
  local ids = {}
  for id in os.getenv("SHAPE"):gmatch("%d+") do ids[#ids + 1] = tonumber(id) end
  local last
  for i, fr in ipairs(elro._stepTimeLog or {}) do
    if fr.flat then
      local P = {}
      for j = 1, #fr.flat, 3 do P[fr.flat[j]] = { fr.flat[j + 1], fr.flat[j + 2] } end
      local ref = P[ids[1]]
      if ref then
        local sig, parts = {}, {}
        for _, id in ipairs(ids) do
          local q = P[id]
          if q then
            local dx, dy = q[1] - ref[1], q[2] - ref[2]
            sig[#sig + 1] = id .. ":" .. dx .. "," .. dy
            parts[#parts + 1] = string.format("%d(%+d,%+d)", id, dx, dy)
          end
        end
        local k = table.concat(sig, " ")
        if k ~= last then
          print(string.format("   step %d: %s  | %s", i, table.concat(parts, " "), tostring(fr.label):sub(1, 90)))
          last = k
        end
      end
    end
  end
end
-- TRACK=<id,id,...> : print every step frame in which one of the listed rooms moves (needs stepDebug)
if os.getenv("TRACK") then
  local want = {}
  for id in os.getenv("TRACK"):gmatch("%d+") do want[tonumber(id)] = true end
  local last = {}
  for i, fr in ipairs(elro._stepTimeLog or {}) do
    if fr.flat then
      local moved = {}
      for j = 1, #fr.flat, 3 do
        local id = fr.flat[j]
        if want[id] then
          local x, y = fr.flat[j + 1], fr.flat[j + 2]
          local l = last[id]
          if not l or l[1] ~= x or l[2] ~= y then
            moved[#moved + 1] = string.format("%d:(%s,%s)->(%d,%d)", id, l and l[1] or "-", l and l[2] or "-", x, y)
            last[id] = { x, y }
          end
        end
      end
      if #moved > 0 then print(string.format("   step %d: %s  | %s", i, table.concat(moved, " "), tostring(fr.label):sub(1, 110))) end
    end
  end
end
-- STEPGREP=<pattern> : print the index and label of every step frame whose label matches
if os.getenv("STEPGREP") then
  for i, fr in ipairs(elro._stepTimeLog or {}) do
    if fr.label and tostring(fr.label):find(os.getenv("STEPGREP")) then print(string.format("   step %d: %s", i, fr.label)) end
  end
end
if os.getenv("RENDERSTEP") then
  elro.dump_step("step " .. os.getenv("RENDERSTEP"))
end

-- ⭐⭐⭐ TRACECHECK=1 : render EVERY step frame, so a broken string.format in the trace machinery
-- fails HERE instead of in the user's background relayout.
-- ⛔ THIS EXISTS BECAUSE I SHIPPED EXACTLY THAT. A `query_eq_2d_levers` trace line lost four of its
-- format arguments; the format string is built ONLY under stepDebug, and every canary/corpus run
-- verifies at DEFAULTS -- so 31 dumps, the canary and test_noyield all passed while the in-game
-- background relayout died with "bad argument #6 to 'format'". A diagnostic path that only the user
-- can execute is a diagnostic path that only the user can break.
if os.getenv("TRACECHECK") then
  local n, bad = 0, 0
  for _, log in ipairs({ elro._stepLog or {}, elro._stepTimeLog or {} }) do
    for i = 1, #log do
      n = n + 1
      local ok, err = pcall(elro.dump_step, "step " .. i)
      if not ok then bad = bad + 1 ; print("  TRACE ERROR at step " .. i .. ": " .. tostring(err)) end
    end
  end
  print(string.format("TRACECHECK: rendered %d frame(s), %d error(s)", n, bad))
  if bad > 0 then os.exit(1) end
end

-- COORDS=<file> : dump every room's final coordinate, sorted, for a CROSS-PROCESS coordinate diff
-- against another tree (the identity check a fold needs, since two trees cannot share a process).
if os.getenv("COORDS") then
  local f = assert(io.open(os.getenv("COORDS"), "w"))
  local ids = {}
  for id in pairs(M.rooms) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local x, y = getRoomCoordinates(id)
    f:write(string.format("%d %d %d\n", id, x, y))
  end
  f:close()
end
