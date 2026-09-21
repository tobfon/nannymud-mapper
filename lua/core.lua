-- ElrohirMapper: standalone client mapper driven by the server !MAP protocol.
-- Mudlet's room database is the graph store: the feeder creates rooms/areas/exits,
-- the layout engine reads the graph back per area, computes coordinates, and
-- writes them with setRoomCoordinates. Speedwalk is native getPath.

elro = elro or {}
elro.current = elro.current or nil
elro.dirty = elro.dirty or {}     -- areaID -> true: needs relayout
elro.ns_cap = elro.ns_cap or 5000  -- max rooms for the O(V^2 E) NS engine; above -> flood
-- Reported to the server by the handshake in onRoom. Kept in step with config.lua's
-- `version` by tools/build-package.sh, which refuses to build if the two differ.
elro.VERSION = "1.3.0"

elro.relayout_timer = elro.relayout_timer or nil
-- min internally-connected cluster size for a server-area to keep its own tab;
-- smaller/fragmented areas (lone connectors, island domains like ingis) fold
-- into "world".
elro.area_min = elro.area_min or 2   -- default; overridden by persisted load_areamin()
-- coordinate multiplier applied at write time: 1 = packed, 2 = a gap cell
-- between every room (less compact). Geometry/collision are unaffected.
elro.spacing = elro.spacing or 2
-- block-pull airyness: extra cells beyond the minimum shift a pull needs to clear a
-- collision (place.lua's one reader). 0 = tightest fit. `mapmargin` and its map-user-data
-- persistence were removed 2026-08-28 -- a stored value silently overrode this default and
-- was invisible to mapknobs. Set it by hand (`lua elro.pull_margin = n`) to experiment.
elro.pull_margin = elro.pull_margin or 0
-- debug tracing (toggle with "mapdebug on|off"); elro.tr() is a no-op when off
elro.debug = elro.debug or false
-- wall-clock milliseconds (getEpoch is a double w/ sub-second precision; fall back to
-- os.clock, seconds since process start, if this build lacks it).
function elro.now_ms()
  if type(getEpoch) == "function" then
    local ok, v = pcall(getEpoch) ; if ok and type(v) == "number" then return v * 1000 end
  end
  return os.clock() * 1000
end
-- Wall-clock ms spent NOT running the solver, for the current background run.
-- Timers subtract the change in this so readings that straddle a yield measure
-- engine time, not parked frames. Zero outside a background run.
function elro.bg_idle_ms()
  local bg = elro._bg
  return bg and (bg.idleT or 0) or 0
end

-- Busy clock for diagnostic timers: os.clock() minus the bg driver's idle time, so a timer
-- bracketing a coroutine yield is not charged the parked frames. Wall-clock budgets that
-- protect the client from freezing must keep raw os.clock().
function elro.clk() return os.clock() - elro.bg_idle_ms() * 0.001 end

function elro.tr(msg)
  -- Record the phase label for the background driver (deliberately BEFORE the
  -- debug early-out: the label is wanted even when tracing is off).
  local bg = elro._bg ; if bg and bg.live then bg.phase = msg end
  -- Watchdog's copy must not depend on a background run being live.
  elro._wdPhase = msg
  if not elro.debug then return end
  local now = elro.now_ms()
  local idle = elro.bg_idle_ms()
  -- subtract the time we were yielded, or every phase that spans a frame
  -- boundary is charged for Mudlet's timer gap (see bg_step's idle accounting)
  local d = elro._trLast and (now - elro._trLast - (idle - (elro._trIdle or 0))) or 0
  elro._trLast, elro._trIdle = now, idle
  cecho(string.format("\n<yellow>[trace %10.1f +%7.1fms] <reset>%s", now, d, msg))
end
-- Auto-relayout when the graph changes: immediately if onRoom's guess put a room
-- on top of another one, otherwise debounced on idle (see elro.markDirty).
-- Toggle with "mapauto on|off"; tune the idle wait with "mapauto idle N".
if elro.autoflush == nil then elro.autoflush = true end
-- seconds the player must stand still before an auto relayout fires
elro.autoIdle = elro.autoIdle or 3
-- moves after which to relayout even if the player is still moving. 0 = never.
elro.autoMax = elro.autoMax or 0
-- Graph-change counter: makes the relayout loop level-triggered. onRoom bumps it
-- when it adds a room/edge; a relayout re-runs if the number moved while it ran.
-- Deliberately NOT `next(elro.dirty)`: recompute_areas can add dirty on its own,
-- so a dirty-check loop would relaunch forever. The counter only moves when the
-- player changed something.
elro.gchg = elro.gchg or 0
-- inside-out branch-frame walk for branch placement; false falls back to flood
if elro.frame_walk == nil then elro.frame_walk = true end
-- whether dead-end leaves overflow to the "world 2" area on collision.
-- Toggle with "mapoverflow on|off".
if elro.overflow == nil then elro.overflow = true end
-- fixed neighbour iteration order so the flood is deterministic (no jitter
-- between relayouts from Lua hash ordering)
elro.dir_order = { "north", "south", "east", "west",
                   "northeast", "northwest", "southeast", "southwest" }

-- Deterministic exit iteration: `for d, v in elro.exits(adj[r]) do`. pairs() is hash order
-- and LuaJIT seeds its string hash per process. adj/radj hold only the eight compass keys;
-- anything else would be silently dropped by this iterator. Allocation-free.
local DIR_NEXT = {}
for i = 1, #elro.dir_order - 1 do DIR_NEXT[elro.dir_order[i]] = elro.dir_order[i + 1] end
local DIR_FIRST = elro.dir_order[1]
local NO_EXITS = {}

-- An adjacency row is NOT always compass-only: vert_rigid injects honoured
-- vertical links under synthetic keys (`radj[a]["^" .. b] = b`) so compass-
-- filtering loops skip them while the rigidity graph still sees them. Rows may
-- register such extra keys, iterated after the eight in sorted order. Cost is one
-- failed lookup per loop (extra_after is consulted only when DIR_NEXT runs out).
local EXTRA = setmetatable({}, { __mode = "k" })   -- adjacency row -> { first = k, next = { k -> k } }

-- Register non-compass edges on ONE adjacency row. Sorted, so the order is total and stable.
function elro.exits_extra(row, keys)
  if not row or #keys == 0 then return end
  table.sort(keys)
  local nxt = {}
  for i = 1, #keys - 1 do nxt[keys[i]] = keys[i + 1] end
  EXTRA[row] = { first = keys[1], next = nxt }
end

local function extra_after(t, d)
  local x = EXTRA[t]
  if not x then return nil end
  if DIR_NEXT[d] == nil and elro.dir_order[#elro.dir_order] == d then return x.first end
  return x.next[d]
end

local function exit_next(t, d)
  while true do
    if d == nil then d = DIR_FIRST
    else d = DIR_NEXT[d] or extra_after(t, d) end
    if d == nil then return nil end
    local v = t[d]
    if v ~= nil then return d, v end
  end
end

function elro.exits(t) return exit_next, t or NO_EXITS, nil end

-- compass/vertical deltas in Mudlet space (north = +y, up = +z)
elro.delta = {
  north = { 0, 1, 0}, south = { 0,-1, 0}, east = { 1, 0, 0}, west = {-1, 0, 0},
  northeast = { 1, 1, 0}, northwest = {-1, 1, 0},
  southeast = { 1,-1, 0}, southwest = {-1,-1, 0},
  up = { 0, 0, 1}, down = { 0, 0,-1},
}
elro.dirNum = {
  north = 1, northeast = 2, northwest = 3, east = 4, west = 5,
  south = 6, southeast = 7, southwest = 8, up = 9, down = 10,
}
elro.reverse = {
  north = "south", south = "north", east = "west", west = "east",
  northeast = "southwest", southwest = "northeast",
  northwest = "southeast", southeast = "northwest", up = "down", down = "up",
}
elro.expand = {
  n = "north", s = "south", e = "east", w = "west", ne = "northeast",
  nw = "northwest", se = "southeast", sw = "southwest", u = "up", d = "down",
}
-- Short form, NOT interchangeable with the long one: addCustomLine files custom
-- lines under the SHORT key while getRoomExits reports the LONG one; passing
-- "north" would leave Mudlet's own exit line drawn beside yours. Do not
-- "simplify" this to the raw getRoomExits key.
elro.shorten = {
  north = "n", south = "s", east = "e", west = "w", northeast = "ne",
  northwest = "nw", southeast = "se", southwest = "sw", up = "u", down = "d",
}
function elro.shortDir(d) return elro.shorten[d] or d end
function elro.norm(dir) return elro.expand[dir] or dir end

-- ---- C-SPACE SNAPSHOT: materialized Mudlet room state ----
-- Avoids per-flush C calls and makes the background coroutine correct: onRoom mutates the
-- live map mid-solve, so the solver reads this snapshot; the only concurrency left is the
-- write (bg_write_ok). Invalidation is per room from onRoom; cs_token(aid) is the staleness.
elro.cs       = elro.cs       or {}   -- roomId -> record (nil = not materialized)
elro.cs_vers  = elro.cs_vers  or {}   -- areaID -> monotone graph version
elro.cs_epoch = elro.cs_epoch or 0    -- bumped by cs_reset (invalidates every token)
elro.cs_hit   = elro.cs_hit   or 0    -- diagnostics (mapcs)
elro.cs_miss  = elro.cs_miss  or 0
local CS_EMPTY = {}                   -- shared read-only stand-in; never mutated

-- Mixed-input detector: a solve's input must be SELF-consistent, not current. A bump after
-- the last snapshot read is committable; a bump followed by a fresh read mixes old and new
-- and is flagged. Detectable exactly here, on a cache miss.
local function guard_fresh_read()
  local g = elro._bgGuard
  if not g then return end
  local bg = elro._bg
  if not bg or not bg.live then return end       -- a FOREGROUND read is not our input
  if elro.cs_epoch ~= g.epoch or (elro.cs_vers[g.aid] or 0) ~= g.vers then
    g.mixed = true
  end
end

-- Materialize one room: exits (compass keys normalized once, here), the
-- assumed-reverse flags, the area, and the userdata fields regionalization
-- reads. Returns nil for a room that does not exist. `assumed_<dir>` is only
-- read for directions that have an exit.
function elro.cs_room(id)
  local rec = elro.cs[id]
  if rec then elro.cs_hit = elro.cs_hit + 1 ; return rec end
  elro.cs_miss = elro.cs_miss + 1
  guard_fresh_read()
  if not roomExists(id) then return nil end
  local ex, asm = {}, nil
  for dn, dest in pairs(getRoomExits(id) or {}) do ex[elro.norm(dn)] = dest end
  for d in pairs(ex) do
    if (getRoomUserData(id, "assumed_" .. d) or "") ~= "" then
      asm = asm or {} ; asm[d] = true
    end
  end
  rec = {
    ex    = ex,
    asm   = asm or CS_EMPTY,
    area  = getRoomArea(id),
    sarea = getRoomUserData(id, "sarea") or "",
    adopt = getRoomUserData(id, "adopt") or "",
    fold  = getRoomUserData(id, "fold")  or "",
    via   = getRoomUserData(id, "via")   or "",
    mh    = getRoomUserData(id, "mh")    or "",
  }
  elro.cs[id] = rec
  return rec
end

-- normalized compass+vertical exits for a room, {} if it does not exist
function elro.cs_exits(id)
  local rec = elro.cs_room(id)
  return rec and rec.ex or CS_EMPTY
end

-- the staleness token for an area. Compared with == only; its internals are
-- private (see bg_write_ok).
function elro.cs_token(aid)
  return elro.cs_epoch .. ":" .. (elro.cs_vers[aid] or 0)
end

function elro.cs_bump(aid)
  if aid then elro.cs_vers[aid] = (elro.cs_vers[aid] or 0) + 1 end
end

-- Forget one room and bump the version of the area(s) it belonged to. `aid` is
-- an optional SECOND area to bump -- a cross-area edge changes the geometry both
-- sides claim, so both layouts go stale.
function elro.cs_dirty(id, aid)
  local rec = elro.cs[id]
  if rec then
    elro.cs_bump(rec.area) ; elro.cs[id] = nil
  else
    -- Not materialized, so we cannot read the area off the snapshot -- but the
    -- change still has to stale SOMETHING or a room materialized after its own
    -- edit would look fresh to an in-flight solve. Ask Mudlet (one C call, rare
    -- path); only if even that fails do we fall back to bumping the epoch, which
    -- stales every area at once.
    local a = roomExists(id) and getRoomArea(id) or nil
    if a then elro.cs_bump(a)
    elseif not aid then elro.cs_epoch = elro.cs_epoch + 1 end
  end
  if aid then elro.cs_bump(aid) end
end

-- membership changed (room added/deleted/moved between areas): the id lists go
function elro.cs_lists_dirty() elro.cs_all = nil ; elro.cs_arooms = nil end

-- the area name table changed (addAreaName / deleteArea)
function elro.cs_areas_dirty() elro.cs_at = nil ; elro.cs_ats = nil end

-- forget EVERYTHING. Always safe; costs a rebuild. Used by every bulk-edit
-- command, so those never have to reason about what they touched.
function elro.cs_reset()
  elro.cs = {}
  elro.cs_epoch = elro.cs_epoch + 1
  elro.cs_lists_dirty()
  elro.cs_areas_dirty()
  elro.cell_drop()
end

-- whole-map room set (id -> name), cached
function elro.cs_all_rooms()
  local t = elro.cs_all
  if not t then guard_fresh_read() ; t = getRooms() or {} ; elro.cs_all = t end
  return t
end

-- one area's room ids as a LIST, cached. Copied out of getAreaRooms so callers
-- may hold it; the cache entry is dropped whenever membership changes.
function elro.cs_area_rooms(aid)
  local m = elro.cs_arooms
  if not m then m = {} ; elro.cs_arooms = m end
  local t = m[aid]
  if not t then
    guard_fresh_read()
    t = {}
    for _, r in pairs(getAreaRooms(aid) or {}) do t[#t + 1] = r end
    m[aid] = t
  end
  return t
end

-- Cell index: "is any room already standing on this cell?" in O(1). Lets the
-- auto-relayout fire on the map being WRONG (overlap from onRoom's guess) rather
-- than merely changed. `x * 1000003 + y` is the injective cell key (integer
-- coords, |y| < 500000; z is always 0). Maintenance contract: onRoom's guess
-- inserts incrementally; a layout commit moves everything, so write_begin drops
-- the area's index; cs_reset and relayout's prologue drop the lot.
elro._cellIx = elro._cellIx or {}     -- areaID -> { [x*1000003+y] = roomId }

local function cell_key(x, y) return x * 1000003 + y end

function elro.cell_index(aid)
  local ix = elro._cellIx[aid]
  if not ix then
    ix = {}
    for _, r in ipairs(elro.cs_area_rooms(aid)) do
      local x, y = getRoomCoordinates(r)
      if x then ix[cell_key(x, y)] = r end
    end
    elro._cellIx[aid] = ix
  end
  return ix
end

-- occupant of (x,y) on this canvas, or nil. The roomExists re-check is cheap and
-- covers an entry left behind by a room deleted without a cs_reset.
function elro.cell_at(aid, x, y)
  local r = elro.cell_index(aid)[cell_key(x, y)]
  if r and roomExists(r) then return r end
  return nil
end

function elro.cell_put(aid, x, y, id)
  elro.cell_index(aid)[cell_key(x, y)] = id
end

function elro.cell_drop(aid)
  if aid then elro._cellIx[aid] = nil else elro._cellIx = {} end
end

-- name -> id and id -> name, cached (getAreaTable is called from areaId, which
-- itself is called per room in recompute_areas)
function elro.cs_areas()
  local t = elro.cs_at
  if not t then t = getAreaTable() or {} ; elro.cs_at = t end
  return t
end

function elro.cs_areas_swap()
  local t = elro.cs_ats
  if not t then t = getAreaTableSwap() or {} ; elro.cs_ats = t end
  return t
end

-- mapcs: snapshot diagnostics -- hit rate is the number that says whether the
-- materialization is actually paying (a low one means something resets it).
function elro.cs_stats()
  local nr, na = 0, 0
  for _ in pairs(elro.cs) do nr = nr + 1 end
  for _ in pairs(elro.cs_vers) do na = na + 1 end
  local tot = elro.cs_hit + elro.cs_miss
  cecho(string.format(
    "\n<cyan>[elro] c-space: %d room(s) materialized, %d area version(s), epoch %d" ..
    "\n  reads %d = %d hit / %d miss (%.1f%% hit)" ..
    "\n  lists: all=%s arooms=%s areaTable=%s<reset>\n",
    nr, na, elro.cs_epoch, tot, elro.cs_hit, elro.cs_miss,
    tot > 0 and (100 * elro.cs_hit / tot) or 0,
    elro.cs_all and "cached" or "stale",
    elro.cs_arooms and "cached" or "stale",
    elro.cs_at and "cached" or "stale"))
end

-- ensure a named area exists; return its id
function elro.areaId(name)
  if name == nil or name == "" then name = "world" end
  local areas = elro.cs_areas()
  if areas[name] then return areas[name] end
  local aid = addAreaName(name)
  elro.cs_areas_dirty()
  return aid
end

-- area name for an area id (nil if unknown)
function elro.areaName(aid)
  return elro.cs_areas_swap()[aid]
end

-- ---- manual edits: persistent area merges ---------------------------------
-- elro.merge[fromArea] = intoArea, a global redirect applied during
-- recompute_areas. Persisted in map user data (survives reloads with the map);
-- in-session only if this Mudlet build lacks get/setMapUserData.
function elro.load_merge()
  elro.merge = {}
  if type(getMapUserData) ~= "function" then return end
  local ok, s = pcall(getMapUserData, "elro.merge")
  if ok and type(s) == "string" and s ~= "" then
    for line in string.gmatch(s, "[^\n]+") do
      local a, b = string.match(line, "^(.-)\t(.+)$")
      if a and b then elro.merge[a] = b end
    end
  end
end

-- persist the merge redirects. Deliberately no saveMap() here: it serialises the
-- whole map to disk (seconds of stall). The redirect rides along on the next
-- saveMap (other setters flush, as does Mudlet's shutdown save).
function elro.save_merge()
  if type(setMapUserData) ~= "function" then return end
  local parts = {}
  for a, b in pairs(elro.merge or {}) do parts[#parts + 1] = a .. "\t" .. b end
  pcall(setMapUserData, "elro.merge", table.concat(parts, "\n"))
end

-- ---- outer-face pick (mapouter, persistent) ----
-- Rooms the user marked as lying ON THE OUTER FACE. `elro.pick_outer_face` prefers the face
-- holding one, and compose_spqr roots the walk on it. Persisted as map user data like the
-- merge redirects; the dump writer carries it in a `-- outer=` header for the offline harness.
function elro.load_outer()
  elro.outerPick = {}
  if type(getMapUserData) ~= "function" then return end
  local ok, s = pcall(getMapUserData, "elro.outer")
  if ok and type(s) == "string" then
    for id in s:gmatch("%d+") do elro.outerPick[tonumber(id)] = true end
  end
end

function elro.save_outer()
  if type(setMapUserData) ~= "function" then return end
  pcall(setMapUserData, "elro.outer", table.concat(elro.outer_list(), ","))
end

function elro.outer_list()
  local ids = {}
  for id in pairs(elro.outerPick or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

-- mapouter                : list the picked rooms
-- mapouter <id,...>       : mark room(s) as on the outer face, relayout
-- mapouter clear [id,...] : unmark (all, or the given rooms), relayout
function elro.outer_pick(arg)
  if elro.outerPick == nil then elro.load_outer() end
  arg = tostring(arg or "")
  local clear = arg:match("^%s*clear")
  local changed = {}                    -- only the rooms this call touched are dirtied
  if clear then
    local any = false
    for tok in arg:gmatch("%d+") do
      any = true
      if elro.outerPick[tonumber(tok)] then elro.outerPick[tonumber(tok)] = nil ; changed[#changed + 1] = tonumber(tok) end
    end
    if not any then for id in pairs(elro.outerPick) do changed[#changed + 1] = id end ; elro.outerPick = {} end
  else
    for tok in arg:gmatch("%d+") do
      local id = tonumber(tok)
      if not roomExists(id) then
        cecho("\n<yellow>[elro]: room " .. id .. " does not exist; skipped.\n<reset>")
      elseif not elro.outerPick[id] then elro.outerPick[id] = true ; changed[#changed + 1] = id end
    end
  end
  local ids = elro.outer_list()
  cecho("\n<cyan>[elro] outer-face pick: " .. ((#ids > 0) and table.concat(ids, ", ") or "(none)") .. "<reset>\n")
  if #changed == 0 then return end
  elro.save_outer()
  for _, id in ipairs(changed) do if roomExists(id) then elro.cs_dirty(id) end end
  elro.flush()
end

-- ---- server merge hints ----------------------------------------------------
-- The server may SUGGEST a canvas for a room: `mha=<area>` for every room of the
-- server area (kept once per map, in elro.hintArea) or `mh=<area>` for this room
-- only (room userdata "mh"). ⛔ A hint is DATA, never an action: the canvas is
-- always computed from it plus the player's say, so re-walking a room cannot
-- undo an unmerge, and rooms explored after an unmerge follow it too. The
-- player's say: elro.hintsOff (follow none) and elro.hintIgnore[sarea].
function elro.kv_load(key)
  local out = {}
  if type(getMapUserData) ~= "function" then return out end
  local ok, s = pcall(getMapUserData, key)
  if ok and type(s) == "string" then
    for line in string.gmatch(s, "[^\n]+") do
      local a, b = string.match(line, "^(.-)\t(.*)$")
      if a and a ~= "" then out[a] = b end
    end
  end
  return out
end

function elro.kv_save(key, t)
  if type(setMapUserData) ~= "function" then return end
  local parts = {}
  for a, b in pairs(t or {}) do parts[#parts + 1] = a .. "\t" .. tostring(b) end
  table.sort(parts)
  pcall(setMapUserData, key, table.concat(parts, "\n"))
end

function elro.load_hints()
  elro.hints_loaded = true
  elro.hintArea = elro.kv_load("elro.hintArea")
  elro.hintIgnore = elro.kv_load("elro.hintIgnore")
  elro.hintsOff = false
  if type(getMapUserData) == "function" then
    local ok, s = pcall(getMapUserData, "elro.hintsOff")
    elro.hintsOff = (ok and s == "1") or false
  end
end

function elro.save_hints()
  elro.kv_save("elro.hintArea", elro.hintArea)
  elro.kv_save("elro.hintIgnore", elro.hintIgnore)
  if type(setMapUserData) == "function" then
    pcall(setMapUserData, "elro.hintsOff", elro.hintsOff and "1" or "")
  end
end

-- The hint in force for a room of server area `sa` whose own hint is `mh`, or nil.
function elro.hint_for(sa, mh)
  if not elro.hints_loaded then elro.load_hints() end
  if elro.hintsOff or elro.hintIgnore[sa] then return nil end
  local h = elro.hintArea[sa]
  if h and h ~= "" then return h end
  if mh and mh ~= "" then return mh end
  return nil
end

-- An unmerged area keeps its own tab whatever its size: without the pin the
-- area_min fold puts a half-explored one straight back, which reads as the
-- unmerge not having worked.
function elro.hint_pinned(sa)
  if not elro.hints_loaded then elro.load_hints() end
  return elro.hintIgnore[sa] ~= nil
end

-- Every server hint the map knows: sarea -> { target, rooms = n or nil }. An
-- area-wide one has no room count; a path-scoped one counts the rooms carrying it.
function elro.hint_table()
  if not elro.hints_loaded then elro.load_hints() end
  local out = {}
  for sa, t in pairs(elro.hintArea) do out[sa] = { target = t } end
  for id in pairs(elro.cs_all_rooms()) do
    local rec = elro.cs_room(id)
    if rec and rec.mh ~= "" and not out[rec.sarea] then
      out[rec.sarea] = { target = rec.mh, rooms = 0 }
    end
    if rec and rec.mh ~= "" and out[rec.sarea].rooms then
      out[rec.sarea].rooms = out[rec.sarea].rooms + 1
    end
  end
  return out
end

-- After a change of the player's say: every room is re-resolved by the relayout's
-- recompute_areas, which also dirties the canvases that gain or lose rooms.
function elro.hints_changed(msg)
  elro.save_hints()
  cecho("\n<green>[elro]: " .. msg .. "\n<reset>")
  elro.flush_dirty()
end

-- mapmerges: the player's own merges and the server's hints, in one list.
function elro.cmd_merges()
  if elro.merge == nil then elro.load_merge() end
  local any = false
  cecho("\n<cyan>[elro] area merges:<reset>")
  for a, b in pairs(elro.merge) do
    cecho("\n<cyan>  " .. a .. " -> " .. b .. "   (yours)<reset>") ; any = true
  end
  for sa, h in pairs(elro.hint_table()) do
    local state = elro.merge[sa] and "overruled by your own merge"
      or (elro.hintsOff and "ignored: maphints is off")
      or (elro.hintIgnore[sa] and "ignored: you unmerged it")
      or "followed"
    cecho(string.format("\n<cyan>  %s -> %s   (server hint%s, %s)<reset>", sa, h.target,
          h.rooms and (", " .. h.rooms .. " room(s)") or "", state))
    any = true
  end
  if not any then cecho("\n<cyan>  (none)<reset>") end
  cecho("\n")
end

-- mapunmerge <area>: undo a merge, whoever made it.
function elro.cmd_unmerge(src)
  if elro.merge == nil then elro.load_merge() end
  src = (src or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if elro.merge[src] then
    local into = elro.merge[src]
    elro.merge[src] = nil
    elro.save_merge()
    local areas = getAreaTable() or {}
    if areas[into] then elro.dirty[areas[into]] = true end
    cecho("\n<green>[elro]: unmerged '" .. src .. "' (marked dirty; run 'maprelayout this' to rebuild).\n<reset>")
    return
  end
  local h = elro.hint_table()[src]
  if h and not elro.hintIgnore[src] then
    elro.hintIgnore[src] = "1"
    elro.hints_changed("'" .. src .. "' keeps its own map from now on; the server's hint (" ..
                  h.target .. ") is ignored. 'maphints on " .. src .. "' follows it again.")
    return
  end
  cecho("\n<red>[elro]: no merge recorded for '" .. src .. "'.\n<reset>")
end

-- maphints                 : list the server's hints
-- maphints on|off          : follow them at all (default on)
-- maphints on|off <area>   : follow or ignore the hint for one area
function elro.cmd_hints(arg)
  if not elro.hints_loaded then elro.load_hints() end
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local sw, area = arg:match("^(o[nf]f?)%s*(.*)$")
  if arg == "" then
    cecho("\n<cyan>[elro]: server merge hints are " ..
          (elro.hintsOff and "OFF (none is followed)" or "ON") .. ".<reset>")
    elro.cmd_merges() ; return
  end
  if sw ~= "on" and sw ~= "off" then
    cecho("\n<yellow>[elro]: usage: maphints [on|off [<area>]]\n<reset>") return
  end
  if area == "" then
    elro.hintsOff = (sw == "off")
    elro.hints_changed("server merge hints are " .. (elro.hintsOff and "OFF: every area keeps the server's own name."
                  or "ON: areas follow the server's suggestions, except those you unmerged."))
  elseif sw == "off" then
    elro.hintIgnore[area] = "1"
    elro.hints_changed("the hint for '" .. area .. "' is ignored; it keeps its own map.")
  else
    elro.hintIgnore[area] = nil
    elro.hints_changed("the hint for '" .. area .. "' is followed again.")
  end
end

-- The canvas name for server area `name`: the player's own merge first, else the
-- server's hint, then merge redirects followed transitively (cycle-guarded).
-- ONE definition, read by onRoom and recompute_areas alike: two that disagree
-- flip a room's tab on every entry.
function elro.resolve_area(name, mh)
  local m = elro.merge or {}
  if not m[name] then
    local h = elro.hint_for(name, mh)
    if h then name = h end
  end
  local seen = {}
  while m[name] and not seen[name] do seen[name] = true ; name = m[name] end
  return name
end

-- ---- area_min knob (persistent) ----
-- Min largest-cluster size for a server area to keep its own tab, else it folds into
-- "world". area_kept reads recompute_areas' verdict; emptiness is the test, not existence.
elro.VIA_NONE = "!"

function elro.area_kept(name)
  if name == "world" then return true end
  local aid = elro.cs_areas()[name]
  return aid ~= nil and next(elro.cs_area_rooms(aid)) ~= nil
end

function elro.load_areamin()
  elro.areamin_loaded = true
  if type(getMapUserData) ~= "function" then return end
  local ok, s = pcall(getMapUserData, "elro.areamin")
  if ok and type(s) == "string" and s ~= "" then
    local n = tonumber(s) ; if n and n >= 1 then elro.area_min = n end
  end
end

function elro.set_areamin(n)
  elro.area_min = n
  if type(setMapUserData) == "function" then
    pcall(setMapUserData, "elro.areamin", tostring(n))
    if type(saveMap) == "function" then pcall(saveMap) end
  end
  cecho(string.format("\n<green>[elro]: area_min = %d (full relayout)\n<reset>", n))
  elro.flush()
end

-- ---- vertPack preference (persistent, global) -----------------------------
-- User choice: planarize vertical exits or not. On, up/down-joined components
-- are grouped and docked at a canonical offset; off, every floor sits alone.
-- Deliberately absent from elro.KNOBS (reset_knobs would forget a persisted
-- preference). Default lives at the read site (`elro.vertPack ~= false`), so
-- "not set" means ON and the persisted value may be absent.
function elro.load_vertpack()
  elro.vertpack_loaded = true
  if type(getMapUserData) ~= "function" then return end
  local ok, s = pcall(getMapUserData, "elro.vertPack")
  if ok and type(s) == "string" and s ~= "" then
    elro.vertPack = (s ~= "off")
  end
end

function elro.set_vertpack(on)
  elro.vertPack = on and true or false
  if type(setMapUserData) == "function" then
    pcall(setMapUserData, "elro.vertPack", on and "on" or "off")
    if type(saveMap) == "function" then pcall(saveMap) end
  end
  cecho(string.format("\n<green>[elro]: vertical packing %s (full relayout)\n<reset>",
    on and "ON -- up/down links group their floors" or "OFF -- every floor packs on its own"))
  elro.flush()
end

-- ---- manual edits: fold a branch into a submap ----------------------------
-- The set of rooms reachable from fromId's dir exit WITHOUT passing back
-- through fromId -- i.e. the branch hanging off that edge. Returns set,dest or
-- nil if there's no such exit. (If the edge isn't an articulation point, the
-- "branch" can include much of the map; that's inherent to the cut.)
function elro.fold_branch(fromId, dir)
  local dest
  for dn, dd in pairs(getRoomExits(fromId) or {}) do
    if elro.norm(dn) == dir then dest = dd end
  end
  if not dest then return nil end
  local set, q, qh = { [dest] = true }, { dest }, 1
  while qh <= #q do
    local u = q[qh] ; qh = qh + 1
    for _, v in pairs(getRoomExits(u) or {}) do
      if v ~= fromId and not set[v] then set[v] = true ; q[#q + 1] = v end
    end
  end
  return set, dest
end

-- stable submap tab name for the edge (fromId, dir)
function elro.fold_name(fromId, dir) return "submap-" .. fromId .. "-" .. dir end

-- ---- per-room steal (mapsteal) --------------------------------------------
-- Move one or more rooms onto the canvas of the area the player is standing in
-- via a per-room "adopt" user-data override (honored in recompute_areas and
-- onRoom). Takes a string of comma/space-separated room ids; tags them all,
-- then relayouts ONCE so a bulk steal isn't a relayout per room.
function elro.steal_rooms(arg)
  local cur = elro.current and getRoomArea(elro.current)
  local into = cur and elro.areaName(cur)
  if not into then
    cecho("\n<red>[elro]: can't tell which area you're in; move once first.\n<reset>")
    return
  end
  local stolen, n = {}, 0
  for tok in string.gmatch(tostring(arg or ""), "%d+") do
    local id = tonumber(tok)
    if not roomExists(id) then
      cecho("\n<yellow>[elro]: room " .. id .. " doesn't exist; skipped.\n<reset>")
    elseif getRoomArea(id) == cur then
      cecho("\n<yellow>[elro]: room " .. id .. " is already in '" .. into .. "'; skipped.\n<reset>")
    else
      local from = elro.areaName(getRoomArea(id)) or "?"
      setRoomUserData(id, "adopt", into)
      elro.cs_dirty(id)
      stolen[#stolen + 1] = id .. " (" .. from .. ")"
      n = n + 1
    end
  end
  if n == 0 then
    cecho("\n<red>[elro]: nothing to steal.\n<reset>")
    return
  end
  cecho("\n<green>[elro]: stole " .. n .. " room(s) into '" .. into .. "': " ..
        table.concat(stolen, ", ") .. "\n<reset>")
  elro.flush()
end

-- clear the "adopt" steal on one or more rooms (comma/space-separated ids),
-- returning them to their own area, then relayout ONCE.
function elro.unsteal_rooms(arg)
  local done, n = {}, 0
  for tok in string.gmatch(tostring(arg or ""), "%d+") do
    local id = tonumber(tok)
    if not roomExists(id) then
      cecho("\n<yellow>[elro]: room " .. id .. " doesn't exist; skipped.\n<reset>")
    elseif (getRoomUserData(id, "adopt") or "") == "" then
      cecho("\n<yellow>[elro]: room " .. id .. " isn't stolen; skipped.\n<reset>")
    else
      setRoomUserData(id, "adopt", "")
      elro.cs_dirty(id)
      done[#done + 1] = id ; n = n + 1
    end
  end
  if n == 0 then
    cecho("\n<red>[elro]: nothing to unsteal.\n<reset>")
    return
  end
  cecho("\n<green>[elro]: returned " .. n .. " room(s) to their own area: " ..
        table.concat(done, ", ") .. "\n<reset>")
  elro.flush()
end

-- ---- forced levers (maplever) ---------------------------------------------
-- Debugging instrument: `maplever <ek>` pins candidate ids to the front of every
-- ranking (elro._rank_cands), above intoEmpty and score; only the pick loop's
-- guards can still reject it. Ids are what mapstep prints (class:/eq:/eq2d:/
-- diageq:/chord:...). Axis 1 is X (column shift), axis 2 is Y (row shift).
-- `<ek>@<room>` forces the lever only while THAT room is being placed (the same label
-- recurs at other steps). Session-only; no argument lists, `maplever off` clears.
elro.forceLever = nil
function elro.map_lever(arg)
  arg = arg and arg:match("^%s*(.-)%s*$") or ""
  if arg == "" then
    local on = {}
    for k, r in pairs(elro.forceLever or {}) do on[#on + 1] = k .. ((r ~= true) and ("@" .. tostring(r)) or "") end
    table.sort(on)
    if #on == 0 then cecho("\n<green>[elro]: no forced levers.\n<reset>")
    else cecho(string.format("\n<yellow>[elro]: %d forced lever(s):\n  %s\n<reset>",
      #on, table.concat(on, "\n  "))) end
    return
  end
  if arg == "off" or arg == "clear" or arg == "none" then
    elro.forceLever = nil
    cecho("\n<green>[elro]: forced levers cleared.\n<reset>")
  else
    local t, n = {}, 0
    for item in arg:gmatch("[^%s,]+") do
      local ek, room = item:match("^(.-)@(%d+)$")
      if ek then t[ek] = tonumber(room) else t[item] = true end
      n = n + 1
    end
    elro.forceLever = t
    cecho(string.format("\n<yellow>[elro]: %d lever(s) forced to the front of every ranking:"
      .. "\n  %s\n<reset>", n, arg))
  end
  if elro.relayout_all then elro.relayout_all() end
end

-- ---- exit locking + mutation counters (maze / untruthful-exit handling) -----
-- Lock the current room's compass exit(s) so onRoom's unreliable server hook can
-- never re-point them (see the manual_<dir> guard in onRoom). With no arg, lock
-- EVERY existing compass exit of the current room; otherwise lock just that dir.
function elro.exit_lock(arg)
  local id = elro.current
  if not id or not roomExists(id) then
    cecho("\n<red>[elro]: no current room.\n<reset>") ; return
  end
  local want = (arg and arg ~= "") and elro.norm(arg) or nil
  local exits = getRoomExits(id) or {}
  local locked = {}
  for dn in pairs(exits) do
    local d = elro.norm(dn)
    if elro.dirNum[d] and (not want or d == want) then
      setRoomUserData(id, "manual_" .. d, "1") ; locked[#locked + 1] = d
    end
  end
  if #locked == 0 then
    cecho("\n<yellow>[elro]: no matching compass exit on room " .. id .. " to lock.\n<reset>")
  else
    cecho("\n<green>[elro]: locked exit(s) on " .. id .. ": " .. table.concat(locked, ", ") ..
          " (server hook can no longer re-point them).\n<reset>")
  end
end

-- Clear the lock on the current room's exit(s) (no arg = all compass dirs).
function elro.exit_unlock(arg)
  local id = elro.current
  if not id or not roomExists(id) then
    cecho("\n<red>[elro]: no current room.\n<reset>") ; return
  end
  local want = (arg and arg ~= "") and elro.norm(arg) or nil
  local cleared = {}
  for d in pairs(elro.dirNum) do
    if (not want or d == want) and (getRoomUserData(id, "manual_" .. d) or "") ~= "" then
      setRoomUserData(id, "manual_" .. d, "") ; cleared[#cleared + 1] = d
    end
  end
  if #cleared == 0 then
    cecho("\n<yellow>[elro]: no locked exit to clear on room " .. id .. ".\n<reset>")
  else
    cecho("\n<green>[elro]: unlocked exit(s) on " .. id .. ": " .. table.concat(cleared, ", ") .. "\n<reset>")
  end
end

-- Report exit-mutation counters. With an arg, inspect that room id; otherwise the
-- current room. Shows per-direction mut count + lock state -- the raw signal the
-- maze auto-detector will threshold on.
function elro.show_mut(arg)
  local id = (arg and arg ~= "") and tonumber(arg) or elro.current
  if not id or not roomExists(id) then
    cecho("\n<red>[elro]: no such room.\n<reset>") ; return
  end
  local rows = {}
  for d in pairs(elro.dirNum) do
    local m = tonumber(getRoomUserData(id, "mut_" .. d)) or 0
    local locked = (getRoomUserData(id, "manual_" .. d) or "") ~= ""
    local dests = getRoomUserData(id, "mutdst_" .. d) or ""
    if m > 0 or locked then
      rows[#rows + 1] = string.format("  %-10s mut=%d%s%s", d, m,
        locked and " [LOCKED]" or "", dests ~= "" and ("  -> " .. dests) or "")
    end
  end
  cecho("\n<cyan>[elro] exit mutations for room " .. id .. " (" .. (getRoomName(id) or "?") .. "):<reset>")
  if #rows == 0 then cecho("\n<cyan>  (none)<reset>")
  else for _, r in ipairs(rows) do cecho("\n<cyan>" .. r .. "<reset>") end end
  cecho("\n")
end

-- clear the mutation counter + destination set on one room (all directions). Leaves
-- assumed_/manual_ flags alone (those track edge state, not the untruthfulness signal).
function elro.mut_clear_room(id)
  local n = 0
  for d in pairs(elro.dirNum) do
    if (getRoomUserData(id, "mut_" .. d) or "") ~= "" then setRoomUserData(id, "mut_" .. d, "") ; n = n + 1 end
    if (getRoomUserData(id, "mutdst_" .. d) or "") ~= "" then setRoomUserData(id, "mutdst_" .. d, "") end
  end
  return n
end

-- mapmutreset [id|area|all]: wipe exit-mutation counters. Needed after the
-- observed/assumed fix, since older counts were inflated by builder-asymmetry
-- corrections that are no longer counted. No arg = current room.
function elro.mut_reset(arg)
  arg = arg and arg:gsub("^%s+", ""):gsub("%s+$", "") or ""
  if arg == "all" then
    local tot = 0
    for id in pairs(elro.cs_all_rooms()) do tot = tot + elro.mut_clear_room(id) end
    cecho("\n<green>[elro]: cleared mutation counters on the whole map (" .. tot .. " exit(s)).\n<reset>")
    return
  end
  if arg == "area" then
    local aid = elro.current and getRoomArea(elro.current)
    if not aid then cecho("\n<red>[elro]: no current area.\n<reset>") ; return end
    local tot = 0
    for _, r in ipairs(elro.cs_area_rooms(aid)) do tot = tot + elro.mut_clear_room(r) end
    cecho("\n<green>[elro]: cleared mutation counters in area '" .. (elro.areaName(aid) or "?") ..
          "' (" .. tot .. " exit(s)).\n<reset>")
    return
  end
  local id = (arg ~= "") and tonumber(arg) or elro.current
  if not id or not roomExists(id) then cecho("\n<red>[elro]: no such room.\n<reset>") ; return end
  local n = elro.mut_clear_room(id)
  cecho("\n<green>[elro]: cleared " .. n .. " mutation counter(s) on room " .. id .. ".\n<reset>")
end

-- ---- maze submap detection + folding ---------------------------------------
-- Untruthful room clusters (mazes) are folded into their own submap tab so the
-- parent map shows only the boundary entrances. Reuses the `fold` userdata:
-- recompute_areas gives fold-tagged rooms their own tab, and onRoom inherits
-- the fold to newly-explored child rooms.

function elro.is_maze_area(name) return type(name) == "string" and name:sub(1, 5) == "maze-" end

-- A room is a maze SEED when any compass exit has mutated >= elro.maze_mut times,
-- OR it is manually tagged maze=1; maze=0 excludes outright (override wins both
-- ways). Default threshold 1: mut=1 already means the exit produced two distinct
-- destinations, and low counts catch sprawling mazes you rarely re-walk.
function elro.maze_seed(id)
  local override = getRoomUserData(id, "maze")
  if override == "0" then return false end
  if override == "1" then return true end
  local thr = elro.maze_mut or 1
  for d in pairs(elro.dirNum) do
    if (tonumber(getRoomUserData(id, "mut_" .. d)) or 0) >= thr then return true end
  end
  return false
end

-- The violet maze marker. Named entry point only: maze state lives in the room's
-- `fold` tag and elro.highlight_paint re-derives the colour from it (so repaints
-- survive a restart). The `off` argument is just a hint; both branches are the
-- same call.
function elro.maze_paint(id, off)
  elro.highlight_paint(id)
end

-- Detect every maze cluster and fold each into its own submap tab. Clustering runs over
-- mutation edges (mutdst_<dir>); a truthful exit to a non-seed is the maze boundary.
-- maze=0 hard-excludes. Tab name reused if any member already has a maze fold.
function elro.detect_mazes(areaFilter)
  local all = elro.cs_all_rooms()
  local af = (areaFilter and areaFilter ~= "") and areaFilter:lower() or nil
  local scope = {}
  if af then
    for id in pairs(all) do
      if (getRoomUserData(id, "sarea") or ""):lower() == af then scope[id] = true end
    end
  else
    for id in pairs(all) do scope[id] = true end
  end
  local seed = {}
  for id in pairs(scope) do if elro.maze_seed(id) then seed[id] = true end end
  -- build the clustering adjacency (symmetric), staying WITHIN scope
  local adj = {}
  local function link(a, b)
    if not a or not b or a == b or not scope[b] then return end
    adj[a] = adj[a] or {} ; adj[a][b] = true
    adj[b] = adj[b] or {} ; adj[b][a] = true
  end
  for id in pairs(scope) do
    for d in pairs(elro.dirNum) do
      local raw = getRoomUserData(id, "mutdst_" .. d)
      if raw and raw ~= "" then
        for tok in raw:gmatch("%d+") do link(id, tonumber(tok)) end   -- mutation edges
      end
    end
    if seed[id] then                                                  -- seed<->seed truthful links
      for _, dest in pairs(getRoomExits(id) or {}) do
        if seed[dest] then link(id, dest) end
      end
    end
  end
  local seen, inMaze, tagged = {}, {}, 0
  for start in pairs(seed) do
    if not seen[start] then
      local comp, q, qh = { start }, { start }, 1
      seen[start] = true
      while qh <= #q do
        local u = q[qh] ; qh = qh + 1
        for v in pairs(adj[u] or {}) do
          if not seen[v] and getRoomUserData(v, "maze") ~= "0" then
            seen[v] = true ; q[#q + 1] = v ; comp[#comp + 1] = v
          end
        end
      end
      -- stable submap name: keep an existing maze fold if the cluster already has one
      local fname
      for _, r in ipairs(comp) do
        local cur = getRoomUserData(r, "fold")
        if elro.is_maze_area(cur) then fname = cur ; break end
      end
      if not fname then
        local minid = comp[1]
        for _, r in ipairs(comp) do if r < minid then minid = r end end
        fname = "maze-" .. minid
      end
      for _, r in ipairs(comp) do
        local cur = getRoomUserData(r, "fold")
        if cur and cur ~= "" and not elro.is_maze_area(cur) then
          -- respect a manual non-maze submap fold: skip
        else
          if cur ~= fname then
            setRoomUserData(r, "fold", fname) ; elro.cs_dirty(r) ; tagged = tagged + 1
          end
          inMaze[r] = true
          elro.maze_paint(r)
        end
      end
    end
  end
  -- RECONCILE: a room still carrying a maze fold but in no detected cluster is
  -- released back to its normal area (detection is bidirectional). maze=1 rooms
  -- are always seeds, so never released here.
  local released = 0
  for id in pairs(scope) do
    local cur = getRoomUserData(id, "fold")
    if elro.is_maze_area(cur) and not inMaze[id] then
      setRoomUserData(id, "fold", "")
      elro.cs_dirty(id)
      elro.maze_paint(id, true)      -- drop the violet highlight
      released = released + 1
    end
  end
  return tagged, released
end

-- mapmaze [auto [<area>|.] | sel]: bare = mark current room maze=1 then detect over the
-- whole map; `sel` marks every selected room; `auto` runs the threshold scan (optionally
-- scoped to a server area, `.` = current). Relayouts once.
function elro.cmd_maze(arg)
  arg = arg and arg:gsub("^%s+", ""):gsub("%s+$", "") or ""
  local first, rest = arg:match("^(%S*)%s*(.-)%s*$")
  local area
  if first == "auto" then
    area = (rest ~= "") and rest or nil
    if area == "." then
      area = elro.current and getRoomUserData(elro.current, "sarea") or nil
      if not area or area == "" then
        cecho("\n<red>[elro]: no current-room server area to scope to.\n<reset>") ; return
      end
    end
  elseif first == "sel" then
    local ids = elro.sel_rooms()
    if not ids then return end
    local marked, already = 0, 0
    for _, id in ipairs(ids) do
      if roomExists(id) then
        if getRoomUserData(id, "maze") == "1" then already = already + 1
        else
          setRoomUserData(id, "maze", "1") ; elro.cs_dirty(id) ; marked = marked + 1
        end
      end
    end
    if marked == 0 and already == 0 then
      cecho("\n<yellow>[elro]: none of the selected rooms exist.\n<reset>") ; return
    end
    cecho(string.format("\n<green>[elro]: marked %d selected room(s) as maze%s.\n<reset>",
          marked, already > 0 and (" (" .. already .. " already marked)") or ""))
  else
    local id = elro.current
    if not id or not roomExists(id) then
      cecho("\n<red>[elro]: no current room to mark.\n<reset>") ; return
    end
    setRoomUserData(id, "maze", "1")
    elro.cs_dirty(id)
  end
  local n, rel = elro.detect_mazes(area)
  cecho("\n<green>[elro]: maze detection" .. (area and (" in '" .. area .. "'") or "") ..
        " tagged " .. n .. " room(s) into submap(s); released " ..
        (rel or 0) .. " no-longer-maze room(s).\n<reset>")
  if area then elro.flush_dirty() else elro.flush() end
end

-- mapunmaze: un-maze the submap the current room belongs to -- clear the maze fold
-- + set maze=0 (override so it won't re-fold) on EVERY member, unhighlight, relayout.
-- Release ONE room from its maze submap: clear the fold so it returns to its own
-- area, and set maze=0 so detection will not pull it back in. The cluster it came
-- from stays. `maze=0` is a hard exclude in detect_mazes, so this survives the
-- reconcile pass that would otherwise re-absorb it on the next `mapmaze auto`.
function elro.unmaze_room(id)
  local fold = getRoomUserData(id, "fold")
  if not elro.is_maze_area(fold) then return nil end
  setRoomUserData(id, "fold", "")
  setRoomUserData(id, "maze", "0")
  elro.cs_dirty(id)
  -- ⛔ AND THE AREA LISTS. Clearing the fold moves the room to a different canvas,
  -- so cs_arooms is now wrong for BOTH -- the maze it left and the area it joins.
  -- Without this the target area solves against a list that does not contain the
  -- room, which is what onRoom does whenever it changes a room's area too.
  elro.cs_lists_dirty()
  elro.maze_paint(id, true)
  return fold
end

-- The canvases a release touches: the submap it left, and wherever it lands --
-- which is decided by recompute_areas, so the areas of its NEIGHBOURS are the
-- honest over-approximation. Used to relayout those instead of the whole map.
function elro.unmaze_scope(ids, folds)
  local dirty = {}
  for name in pairs(folds or {}) do
    local a = elro.areaId and elro.areaId(name)
    if a then dirty[a] = true end
  end
  for _, id in ipairs(ids) do
    if roomExists(id) then
      dirty[getRoomArea(id)] = true
      for _, v in pairs(getRoomExits(id) or {}) do
        if roomExists(v) then dirty[getRoomArea(v)] = true end
      end
    end
  end
  return dirty
end

-- mapunmaze [all | <id|here>,...]: bare releases the WHOLE submap the current
-- room is in; with room ids (or `here`) it releases only those, leaving the rest
-- folded -- for a cluster detection took one room too many into; `all` releases
-- every submap on the map (see the note in the body: it clears the override
-- rather than setting maze=0).
function elro.cmd_unmaze(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  -- `all` CLEARS the maze override; the per-room forms SET maze=0. The mut
  -- counters survive either way -- `mapmutreset all` is the full reset.
  if arg == "all" then
    local freed, folds = {}, {}
    for r in pairs(elro.cs_all_rooms()) do
      local fold = elro.unmaze_room(r)
      if fold then
        setRoomUserData(r, "maze", "")   -- not "0": no permanent exclude
        elro.cs_dirty(r)
        freed[#freed + 1] = r ; folds[fold] = true
      end
    end
    local nf = 0 ; for _ in pairs(folds) do nf = nf + 1 end
    if #freed == 0 then
      cecho("\n<yellow>[elro]: no maze submaps to release.\n<reset>") ; return
    end
    cecho(string.format("\n<green>[elro]: released %d room(s) from %d maze submap(s).\n" ..
          "  The maze override is CLEARED, not set to 0, so detection may find them\n" ..
          "  again -- 'mapmutreset all' if you want the counters gone too.\n<reset>",
          #freed, nf))
    for a in pairs(elro.unmaze_scope(freed, folds)) do elro.dirty[a] = true end
    elro.flush_dirty()
    return
  end
  if arg ~= "" then
    local ids, bad = {}, {}
    for tok in string.gmatch(arg, "[^,%s]+") do
      if tok == "here" or tok == "." then
        if elro.current then ids[#ids + 1] = elro.current end
      else
        local n = tonumber(tok)
        if n then ids[#ids + 1] = n else bad[#bad + 1] = tok end
      end
    end
    if #bad > 0 then
      cecho("\n<red>[elro]: not a room id: " .. table.concat(bad, ", ") .. "\n<reset>") return
    end
    if #ids == 0 then
      cecho("\n<yellow>[elro]: usage: mapunmaze [<id|here>,...]\n<reset>") return
    end
    local freed, skipped, foldsSeen = {}, {}, {}
    for _, id in ipairs(ids) do
      if not roomExists(id) then skipped[#skipped + 1] = id .. " (no such room)"
      else
        local fold = elro.unmaze_room(id)
        if fold then freed[#freed + 1] = id ; foldsSeen[fold] = true
        else skipped[#skipped + 1] = id .. " (not in a maze)" end
      end
    end
    if #freed > 0 then
      cecho(string.format("\n<green>[elro]: released %d room(s) from their maze submap: %s\n" ..
            "  (maze=0, so detection will not take them back).\n<reset>",
            #freed, table.concat(freed, ", ")))
    end
    if #skipped > 0 then
      cecho("<yellow>  skipped: " .. table.concat(skipped, ", ") .. "\n<reset>")
    end
    if #freed > 0 then
      -- ⚠ NOT elro.flush(): that relayouts every map on the map, and a release
      -- touches two canvases -- the submap it left and the one it joins.
      for a in pairs(elro.unmaze_scope(freed, foldsSeen)) do elro.dirty[a] = true end
      elro.flush_dirty()
    end
    return
  end
  local id = elro.current
  if not id or not roomExists(id) then
    cecho("\n<red>[elro]: no current room.\n<reset>") ; return
  end
  local fold = getRoomUserData(id, "fold")
  if not elro.is_maze_area(fold) then
    cecho("\n<yellow>[elro]: current room isn't in a maze submap.\n<reset>") ; return
  end
  local n, all = 0, {}
  for r in pairs(elro.cs_all_rooms()) do
    if getRoomUserData(r, "fold") == fold then
      elro.unmaze_room(r)
      all[#all + 1] = r
      n = n + 1
    end
  end
  cecho("\n<green>[elro]: released " .. n .. " room(s) from submap '" .. fold ..
        "' (maze=0 so they won't re-fold).\n<reset>")
  for a in pairs(elro.unmaze_scope(all, { [fold] = true })) do elro.dirty[a] = true end
  elro.flush_dirty()
end

-- mapmazes: list the maze submaps and their room counts.
function elro.cmd_mazes()
  local counts = {}
  for id in pairs(elro.cs_all_rooms()) do
    local f = getRoomUserData(id, "fold")
    if elro.is_maze_area(f) then counts[f] = (counts[f] or 0) + 1 end
  end
  cecho("\n<cyan>[elro] maze submaps:<reset>")
  local any = false
  for f, c in pairs(counts) do cecho("\n<cyan>  " .. f .. " -- " .. c .. " room(s)<reset>") ; any = true end
  if not any then cecho("\n<cyan>  (none)<reset>") end
  cecho("\n")
end

-- ---- mapmazefit: could this maze be ONE vertex? ---------------------------
-- Step 0 of PLAN-maze.md. Read-only: it reports, it never tags, folds or moves.
--
-- ⛔ IT DELIBERATELY IGNORES WHERE THE ROOMS SIT. The first cut asked whether the
-- door rays MEET at the current coordinates, and priced how far the rooms would
-- have to move. That number was worthless: `area_adjacency` DROPS a boundary
-- room's exit into a folded maze, so nothing has ever tied those rooms together
-- and their positions record the ABSENCE of the constraint, not the difficulty of
-- meeting it. Asking where the solver put them when it was not trying to satisfy
-- anything measures nothing.
--
-- What survives is position-free. The plan contracts a cluster to one vertex
-- carrying a compass edge to each boundary room, so a room with N doors into the
-- maze demands N cells in N different directions from it: **the most doors on any
-- one room is the smallest region the maze can be.** One door each, and a single
-- cell does it wherever the solver ends up putting things.
--
-- Membership comes from the fold tag detection already wrote; the doors are just
-- the rooms outside it holding an exit into it. Nothing here guesses.
--
-- ⛔ A MULTI-CELL VERDICT IS NOT A BLOCKER, and an earlier draft said it was.
-- Several edges from one room to one vertex is an OVER-CONSTRAINED system, and
-- resolving those is what the engine does for every ordinary area: it satisfies
-- one and demotes the rest. So this number SIZES the contradiction, it does not
-- gate anything on removing it.
--
-- The room-name column is an OBSERVATION, not a rule. Door rooms sharing the
-- cluster's name hint that the mutation counter under-detected it, and that held
-- for all three multi-cell clusters on the first live run -- but plenty of mazes
-- have varied names, so nothing keys off it.

-- fold name -> member set, for every maze cluster on the map.
function elro.maze_clusters()
  local out = {}
  for id in pairs(elro.cs_all_rooms()) do
    local f = getRoomUserData(id, "fold")
    if elro.is_maze_area(f) then
      out[f] = out[f] or {}
      out[f][id] = true
    end
  end
  return out
end

-- Trimmed, ANSI-free room name -- stored names predate the strip on the way in.
local function clean_name(id)
  local nm = elro.strip_ansi(getRoomName(id) or "")
  return (nm:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The name most rooms inside the cluster share, and how many share it.
function elro.maze_name(members)
  local count, best, bestN = {}, "", 0
  for id in pairs(members) do
    local nm = clean_name(id)
    if nm ~= "" then
      count[nm] = (count[nm] or 0) + 1
      if count[nm] > bestN then best, bestN = nm, count[nm] end
    end
  end
  return best, bestN
end

-- Every way INTO `members` from outside it: compass doors as {room, dir, area},
-- and a count of the non-compass ones, which constrain no geometry at all.
function elro.maze_doors(members)
  local doors, special = {}, 0
  for id in pairs(elro.cs_all_rooms()) do
    if not members[id] then
      for dn, dest in pairs(getRoomExits(id) or {}) do
        local d = elro.norm(dn)
        local del = elro.delta[d]
        if members[dest] then
          if del and (del[1] ~= 0 or del[2] ~= 0) then
            doors[#doors + 1] = { room = id, dir = d, area = getRoomArea(id) }
          else
            special = special + 1
          end
        end
      end
      if type(getSpecialExits) == "function" then
        local got, t = pcall(getSpecialExits, id)
        if got and type(t) == "table" then
          for k, v in pairs(t) do
            local n1, n2 = tonumber(k), tonumber(v)
            if (n1 and members[n1]) or (n2 and members[n2]) then special = special + 1 end
          end
        end
      end
    end
  end
  table.sort(doors, function(a, b)
    if a.room ~= b.room then return a.room < b.room end
    return a.dir < b.dir
  end)
  return doors, special
end

-- The smallest region this maze can be, from TWO independent lower bounds:
--
--   1. the most doors on any ONE room -- it needs the maze in that many places;
--   2. ⛔ the most ROOMS sharing one door direction, which the first cut missed.
--      Every room entering the maze going south sits in the vertex's column. One
--      can sit adjacent to it; a second has to sit BEHIND the first, and its spoke
--      would cross rooms, so the solver drops that door. Leowon and lyr were both
--      scored 1 cell and both lost exactly one door to this -- and leowon's own
--      pre-fold geometry shows the answer, two maze rooms side by side with one
--      boundary room north of each.
--
-- Returns cells, the room or direction forcing it, and a description. 1 = a single
-- cell serves, whatever the layout turns out to be. Ties go to the lowest room id
-- and then alphabetically, so the report is stable.
function elro.maze_cells(doors)
  local per, dirs, byDir = {}, {}, {}
  for _, d in ipairs(doors) do
    per[d.room] = (per[d.room] or 0) + 1
    dirs[d.room] = dirs[d.room] and (dirs[d.room] .. ", " .. d.dir) or d.dir
    byDir[d.dir] = byDir[d.dir] or {}
    byDir[d.dir][d.room] = true
  end
  local n, who = 1, nil
  for r, c in pairs(per) do
    if c > n or (c == n and who and r < who) then n, who = c, r end
  end
  local dn, dwho = 1, nil
  for d, set in pairs(byDir) do
    local c = 0 ; for _ in pairs(set) do c = c + 1 end
    if c > dn or (c == dn and dwho and d < dwho) then dn, dwho = c, d end
  end
  if dn > n then
    local rs = {}
    for r in pairs(byDir[dwho]) do rs[#rs + 1] = r end
    table.sort(rs)
    return dn, nil, dn .. " rooms enter going " .. dwho .. " (" .. table.concat(rs, ", ") .. ")"
  end
  if n < 2 then return 1 end
  return n, who, "room " .. who .. " faces it " .. n .. " ways (" .. dirs[who] .. ")"
end

-- What the LAST SOLVE actually did with this area's maze doors, on the live map:
-- which reach their cell truthfully (drawn as a spoke), which do not (drawn as the
-- plain stub), and whether the area was vetoed out of the vertex altogether. The
-- offline rig answers this for a dump; only this answers it for what is on screen.
function elro.maze_live(aid)
  local rows, vetoed = {}, (elro._mazeVeto or {})[aid] and true or false
  local doors = (elro._mazeDoor or {})[aid]
  if not doors then return rows, vetoed, 0 end
  local cells = {}
  for _, byDir in pairs(doors) do
    for _, vid in pairs(byDir) do cells[vid] = true end
  end
  local ncell = 0 ; for _ in pairs(cells) do ncell = ncell + 1 end
  for room, byDir in pairs(doors) do
    if roomExists(room) then
      local rx, ry = getRoomCoordinates(room)
      for dir, vid in pairs(byDir) do
        local p = (elro._mazePos or {})[vid]
        local de = elro.delta[dir]
        local okDir = p and rx and de and elro.drawn_direction_ok(de, p[1] - rx, p[2] - ry)
        -- distance from the cell, and how many edges the room has INSIDE the area.
        -- A door room with no in-area edges is held by the maze edge alone, so if
        -- it also sits far from its cell the solver simply put it nowhere in
        -- particular -- which is what "drawn on a random spot" looks like.
        local dist, deg = nil, 0
        if p and rx then
          local dx = (p[1] - rx < 0) and (rx - p[1]) or (p[1] - rx)
          local dy = (p[2] - ry < 0) and (ry - p[2]) or (p[2] - ry)
          dist = (dx > dy) and dx or dy
        end
        for _, v in pairs(elro.cs_exits(room)) do
          if roomExists(v) and getRoomArea(v) == aid then deg = deg + 1 end
        end
        rows[#rows + 1] = { room = room, dir = dir, ok = okDir and true or false,
                            dist = dist, deg = deg,
                            at = p and ("(" .. p[1] .. "," .. p[2] .. ")") or "unplaced" }
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.room ~= b.room then return a.room < b.room end
    return a.dir < b.dir
  end)
  return rows, vetoed, ncell
end

-- mapmazelive [<area>|.]: the live per-door verdict, and the veto state.
function elro.cmd_maze_live(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if arg:match("^clear") then
    elro.maze_veto_clear()
    cecho("\n<green>[elro]: maze vertex vetoes cleared -- the next relayout tries again everywhere.\n<reset>")
    return
  end
  local aid
  if arg == "" or arg == "." then
    aid = elro.current and roomExists(elro.current) and getRoomArea(elro.current) or nil
  else
    aid = elro.find_area(arg)
  end
  if not aid then
    cecho("\n<red>[elro]: no such area (or no current room).\n<reset>") return
  end
  local name = elro.areaName(aid) or tostring(aid)
  if elro.mazeVertex == false then
    cecho("\n<yellow>[elro]: elro.mazeVertex is OFF -- no maze vertices anywhere.\n<reset>")
    return
  end
  local rows, vetoed, ncell = elro.maze_live(aid)
  if #rows == 0 then
    cecho(string.format(
      "\n<yellow>[elro] %s: the last solve built no maze vertex%s.\n<reset>", name,
      vetoed and " -- the area is VETOED (a door was given up AND its room landed on an edge)" or
      " -- no folded maze has a compass door from here"))
    if vetoed then
      cecho("<cyan>  'mapmazelive clear' lifts the veto and the next relayout tries again.\n<reset>")
    end
    return
  end
  cecho(string.format("\n<cyan>[elro] %s: %d maze cell(s), %d door(s)%s<reset>\n",
        name, ncell, #rows, vetoed and "  <red>[VETOED -- next relayout drops it]<reset>" or ""))
  local good = 0
  for _, r in ipairs(rows) do
    if r.ok then good = good + 1 end
    cecho(string.format("    %6d %-10s -> cell %-9s %3s away, %d in-area edge(s)  %s\n",
          r.room, r.dir, r.at, r.dist and tostring(r.dist) or "?", r.deg,
          r.ok and "<green>truthful<reset>"
                or ((r.deg == 0 and (r.dist or 0) > 2)
                    and "<red>ADRIFT -- nothing but the maze holds it<reset>"
                    or "<yellow>bent<reset>")))
  end
  cecho(string.format("<cyan>  %d of %d doors drawn as spokes.%s<reset>\n", good, #rows,
        (good == 0) and "  None -- so this maze looks exactly as it did before the feature." or ""))
end

-- mapmazefit [<area>|.]: the report. Bare = every cluster on the map.
function elro.cmd_maze_fit(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local want
  if arg == "." then
    want = elro.current and getRoomArea(elro.current)
  elseif arg ~= "" then
    want = elro.find_area(arg)
    if not want then
      cecho("\n<red>[elro]: no area matching '" .. arg .. "'.\n<reset>") return
    end
  end
  local nm = elro.cs_areas_swap()
  local clusters = elro.maze_clusters()
  local names = {}
  for f in pairs(clusters) do names[#names + 1] = f end
  table.sort(names)
  if #names == 0 then
    cecho("\n<yellow>[elro]: no maze submaps on the map -- nothing to fit.\n<reset>") return
  end
  cecho(string.format(
    "\n<cyan>[elro] maze fit -- %d cluster(s). How big must each one's layout vertex be?<reset>\n", #names))

  local onecell, region, lookalike = 0, 0, 0
  for _, f in ipairs(names) do
    local members = clusters[f]
    local n = 0 ; for _ in pairs(members) do n = n + 1 end
    local doors, special = elro.maze_doors(members)
    local mname = elro.maze_name(members)
    -- one vertex PER AREA: a cluster with doors in two areas gets a copy on each
    -- canvas, and each canvas is its own coordinate frame.
    local byArea, order = {}, {}
    for _, d in ipairs(doors) do
      if not byArea[d.area] then byArea[d.area] = {} ; order[#order + 1] = d.area end
      table.insert(byArea[d.area], d)
    end
    table.sort(order)
    if not want or byArea[want] then
      cecho(string.format("\n<white>%s<reset>  %d room(s), %d compass door(s)%s%s\n", f, n, #doors,
            special > 0 and string.format(", %d non-compass (constrains nothing)", special) or "",
            mname ~= "" and ("  [inside: \"" .. string.sub(mname, 1, 28) .. "\"]") or ""))
      local same = 0
      for _, aid in ipairs(order) do
        if not want or aid == want then
          local ds = byArea[aid]
          cecho(string.format("  <yellow>%s<reset>\n", nm[aid] or ("area " .. tostring(aid))))
          for _, d in ipairs(ds) do
            local rn = clean_name(d.room)
            local like = (mname ~= "" and rn == mname)
            if like then same = same + 1 end
            cecho(string.format("    %6d %-10s %-30s%s\n", d.room, d.dir, string.sub(rn, 1, 30),
                  like and "  <magenta>= named like the maze<reset>" or ""))
          end
          local cells, _who, why = elro.maze_cells(ds)
          if cells == 1 then
            onecell = onecell + 1
            cecho("    <green>-> ONE CELL: one door per room, and no two share a direction.<reset>\n")
          else
            region = region + 1
            cecho(string.format("    <yellow>-> needs a %d-cell region: %s.<reset>\n", cells, why))
          end
        end
      end
      if same > 0 then
        lookalike = lookalike + 1
        cecho(string.format(
          "    <magenta>** %d door room(s) carry the maze's OWN name -- likely undetected members.<reset>\n",
          same))
      end
    end
  end
  cecho(string.format(
    "\n<cyan>  %d door-group(s): <green>%d need only ONE cell<cyan>, <yellow>%d need a small region<cyan>.<reset>\n",
    onecell + region, onecell, region))
  if lookalike > 0 then
    cecho(string.format(
      "<magenta>  %d cluster(s) have door rooms carrying the maze's OWN name -- a hint that the\n" ..
      "  mutation counter under-detected them. Only a hint: names prove nothing, and a\n" ..
      "  multi-cell verdict is a size the solver can price, not something to fix first.\n<reset>",
      lookalike))
  end
end

-- ---- BACKGROUND RELAYOUT: cooperative coroutine ----
-- The solve runs in a coroutine driven by a tempTimer: compute for elro.bgSlice ms, yield.
-- Mudlet runs stock Lua 5.1, which cannot yield across a C-call boundary: NO pcall,
-- metamethod or C frame may sit between the resume and any bg_tick.
elro.bgSlice = elro.bgSlice or 45      -- ms of solving per frame (client stays responsive)
elro.bgGap   = elro.bgGap   or 0.02    -- seconds of Mudlet event loop between frames
-- bgDropMixed (default off): discard a mixed-input layout instead of drawing and repairing.
-- viewSettle (0.25s): delay of the second centerview after a canvas change.
-- viewUnstick (default on): force the widget to rebuild on a real canvas switch.
elro.bgGC = elro.bgGC or 0
-- Overrun hook: reports which SOURCE LINE was running when the frame budget
-- blew. It cannot yield (stock 5.1 forbids yielding from a hook), so it is a
-- reporter only; the yield must still come from a bg_tick placed there.
-- Value = VM instructions between probes; 0 = off. Diagnostic, not a default.
-- Under LuaJIT the count hook does not fire inside compiled traces (jit.off()
-- first when testing locally); Mudlet's stock 5.1 fires it normally.
-- Not initialised here: bg_step reads it as `elro.bgHook or 0`, so nil IS off, which is
-- what lets it live in PROBES and be cleared by `mapknobs reset`.
if elro.bgLayout == nil then elro.bgLayout = true end
elro._bg = nil                         -- the in-flight run, or nil

function elro.bg_busy() return elro._bg ~= nil end

-- Are we executing ON the background coroutine right now? Distinct from
-- bg_busy: a mapstep redraw or an alias typed while a run is in flight executes
-- on the MAIN thread, must not be treated as background, and may pcall freely.
function elro.bg_inside()
  local bg = elro._bg
  return bg ~= nil and coroutine.running() == bg.co
end

-- The yield point, called from the solver's inner loops; a no-op off the background
-- coroutine. Fast path is two table reads and a test (no coroutine.running, no now_ms).
-- `site` optionally names the tick so elro.tr can say which phase a frame ended in.
local function wd_hook() elro.wd_check("vm-hook") end
function elro.wd_hook_arm()
  if elro._wdHooked then return end
  -- Say so if we cannot arm: a silent no-op is indistinguishable from a watchdog
  -- that simply has not tripped.
  if type(debug) ~= "table" or type(debug.sethook) ~= "function" then
    if not elro._wdNoHook then
      elro._wdNoHook = true
      local nl = string.char(10)
      cecho(nl .. "<yellow>[elro] watchdog: debug.sethook unavailable -- only loops that call"
        .. " bg_tick can be interrupted (a tight loop will still freeze the client).<reset>" .. nl)
    end
    return
  end
  debug.sethook(wd_hook, "", 1000000)
  elro._wdHooked = true
end
function elro.wd_stop()
  elro._wdT0 = nil
  if elro._wdHooked and type(debug) == "table" and debug.sethook then debug.sethook() end
  elro._wdHooked = nil
end
function elro.wd_start()
  elro.wd_stop()
  elro._wdT0, elro._wdIdle0 = elro.now_ms(), elro.bg_idle_ms()
  elro._wdPhase, elro._wdRoom, elro._wdGuard, elro._wdFired, elro._wdN = nil, nil, nil, nil, nil
  elro.wd_hook_arm()
end
function elro.wd_check(site)
  local t0 = elro._wdT0
  if not t0 or elro._wdFired then return end
  local cap = elro.walkWatchdog
  if cap == false then return end
  cap = (cap or 60) * 1000
  if cap <= 0 then return end
  local el = (elro.now_ms() - t0) - (elro.bg_idle_ms() - (elro._wdIdle0 or 0))
  if el < cap then return end
  elro._wdFired = true
  if elro._wdHooked and type(debug) == "table" and debug.sethook then
    debug.sethook() ; elro._wdHooked = nil          -- never report twice, never leave a hook behind
  end
  local msg = string.format(
    "[elro] WATCHDOG: the walk ran %.1fs of engine time (cap %.0fs) and was aborted.\n"
    .. "  last phase : %s\n  last tick  : %s\n  placing    : room %s (walk step %s)\n"
    .. "  guard iter : %s\n"
    -- No angle brackets in a cecho string: Mudlet parses `<...>` as a colour tag.
    .. "  Raise or disable with `mapwd 120` / `mapwd off`.",
    -- ...and the phase is engine-supplied text, so strip markup for the same reason
    el / 1000, cap / 1000, (tostring(elro._wdPhase):gsub("<[^>]*>", "")), tostring(site),
    tostring(elro._wdRoom), tostring(elro._walkN), tostring(elro._wdGuard))
  cecho("\n<red>" .. msg .. "<reset>\n")
  error(msg, 0)
end

function elro.bg_tick(site)
  -- Watchdog countdown, rate-limited and BEFORE the bg.live early-out on
  -- purpose: that is what makes the watchdog work on a foreground relayout too.
  local n = elro._wdN
  if n and n > 1 then elro._wdN = n - 1
  else elro._wdN = 512 ; elro.wd_hook_arm() ; elro.wd_check(site) end
  local bg = elro._bg
  if not bg or not bg.live then return end
  -- No-yield window: stock 5.1 cannot yield across a pcall, so a caller that
  -- pcalls into tick-bearing code declares the window and ticks inside become
  -- harmless no-ops. It suppresses only the yield -- the watchdog check above
  -- deliberately runs first so a hang inside the window is still reported.
  if elro._noYield then return end
  if os.clock() >= bg.deadline then
    bg.yields = bg.yields + 1
    bg.site = site
    coroutine.yield()
  end
end

-- The write boundary. Commits everything, mixed input included, unless bgDropMixed is set.
-- Both staleness verdicts (mixed = read after a bump; moved = area changed under us) commit
-- and leave the area dirty so the queued rebuild repairs them.
function elro.bg_write_ok()
  local g = elro._bgGuard
  if not g then return true end
  if elro.bgDropMixed then return not g.mixed end
  return true
end

-- Did this area change while we solved it? Distinct from g.mixed ("did we READ
-- anything after it changed"). Not optional bookkeeping: relayout_body clears
-- elro.dirty[aid] after the solve, which would wipe a flag onRoom set during
-- it -- the level check in relayout_done would then find nothing dirty to
-- rebuild. The guard knows the version it started from; two table reads.
function elro.bg_guard_moved(g)
  if not g then return false end        -- foreground: synchronous, nothing can change
  return elro.cs_epoch ~= g.epoch or (elro.cs_vers[g.aid] or 0) ~= g.vers
end

-- arm/disarm the guard around one area's solve+write. Stores epoch/vers raw so
-- guard_fresh_read can compare without building a token string per read.
function elro.bg_guard(aid)
  elro._bgGuard = aid and
    { aid = aid, epoch = elro.cs_epoch, vers = elro.cs_vers[aid] or 0 } or nil
  return elro._bgGuard
end

function elro.bg_step()
  local bg = elro._bg
  if not bg then return end
  bg.timer = nil
  bg.frames = bg.frames + 1
  local slice = (elro.bgSlice or 45) / 1000
  -- Idle accounting: track time spent NOT running so engine timers can subtract
  -- the yield gaps; otherwise a cheap step after a yield reads as a whole frame.
  local nowms = elro.now_ms()
  if bg.lastEnd then bg.idleT = (bg.idleT or 0) + (nowms - bg.lastEnd) end
  local t0 = os.clock()
  bg.deadline = t0 + slice
  -- Worst-frame instrumentation: record the longest frame and the phase labels
  -- it started/ended in, so the next run says where the missing tick belongs.
  bg.phaseFrom, bg.siteFrom = bg.phase, bg.site
  -- arm the overrun reporter for this frame (per-coroutine hook, cleared after)
  local hookN = elro.bgHook or 0
  if hookN > 0 and debug and debug.sethook then
    -- PER FRAME, not per run: only the worst frame's probes are kept (snapshotted at the
    -- maxFrame test below). A run-total mixes every over-budget frame together and so can
    -- never name one loop.
    local leaf, call = {}, {}
    bg.overF, bg.overCF, bg.overFN = leaf, call, 0
    debug.sethook(bg.co, function()
      if os.clock() < bg.deadline then return end
      -- level 2 = the function the hook interrupted (level 1 is the hook itself).
      -- level 3 = ITS CALLER, which is what separates a hot leaf called from everywhere
      -- (exit_next, orip) from the loop that actually lacks a tick.
      local i = debug.getinfo(2, "Sl")
      if i then
        local k = tostring(i.short_src) .. ":" .. tostring(i.currentline)
        leaf[k] = (leaf[k] or 0) + 1
        bg.overFN = bg.overFN + 1
        -- Walk past tail-call frames: a tail call REPLACES its caller's frame, so level 3
        -- reads back as "(tail call):-1" and names nothing. Climb until a frame has a real
        -- line, or give up after a few -- a chain of them has no nameable caller left.
        local c
        for lv = 3, 8 do
          local f = debug.getinfo(lv, "Sl")
          if not f then break end
          if f.currentline and f.currentline >= 0 then c = f ; break end
        end
        if c then
          local ck = tostring(c.short_src) .. ":" .. tostring(c.currentline)
          call[ck] = (call[ck] or 0) + 1
        end
      end
    end, "", hookN)
    bg.hooked = true
  end
  bg.live = true
  local ok, err = coroutine.resume(bg.co)
  bg.live = false
  if bg.hooked then debug.sethook(bg.co) ; bg.hooked = false end
  local dt = os.clock() - t0
  bg.busyT = (bg.busyT or 0) + dt
  bg.lastEnd = elro.now_ms()
  -- Collect in the gap, not in the frame; timed separately so it can be judged.
  local gcn = elro.bgGC or 0
  if gcn > 0 then
    local g0 = os.clock()
    collectgarbage("step", gcn)
    bg.gcT = (bg.gcT or 0) + (os.clock() - g0)
    bg.gcN = (bg.gcN or 0) + 1
  end
  if dt > (bg.maxFrame or 0) then
    bg.maxFrame, bg.maxFrom, bg.maxTo = dt, bg.phaseFrom, bg.phase
    bg.maxSite = bg.site          -- the tick that finally ended the frame
    -- keep THIS frame's probes as the reported ones; the previous worst is discarded
    bg.over, bg.overC, bg.overN = bg.overF, bg.overCF, bg.overFN
  end
  -- how often each tick site is the one that ends a frame: a site that never
  -- appears is either never reached or never the bottleneck, and a site missing
  -- from a long frame is the loop that still needs one.
  if bg.site then bg.sites = bg.sites or {} ; bg.sites[bg.site] = (bg.sites[bg.site] or 0) + 1 end
  if dt > slice * 2 then bg.overruns = (bg.overruns or 0) + 1 end
  if not ok then
    -- the coroutine died mid-solve; clear the flags its own cleanup could not
    -- (layout_eqw's pcall is exactly what we gave up to be able to yield)
    elro._bgGuard = nil
    elro._writeArea, elro._writeCleared, elro._writeCo = nil, nil, nil
    elro._bg = nil
    cecho("\n<red>[elro] background relayout ERROR: " .. tostring(err) .. "\n<reset>")
    return
  end
  if coroutine.status(bg.co) == "dead" then
    elro._bgGuard = nil
    elro._bg = nil
    elro._bgLast = bg          -- so `mapbg` can report the worst frame afterwards
    if bg.done then bg.done(bg) end
    return
  end
  bg.timer = tempTimer(elro.bgGap or 0.02, function() elro.bg_step() end)
end

-- Launch `fn` as a background run. Returns false if one is already in flight --
-- callers mark dirty and let the running one pick the work up on its retry.
function elro.bg_start(fn, label, done)
  if elro._bg then return false end
  elro._bg = { co = coroutine.create(fn), label = label or "relayout", done = done,
               frames = 0, yields = 0, t0 = elro.now_ms(), deadline = 0 }
  elro._bg.timer = tempTimer(0, function() elro.bg_step() end)
  return true
end

function elro.bg_cancel(quiet)
  local bg = elro._bg
  if not bg then
    if not quiet then cecho("\n<yellow>[elro]: no background relayout in flight.\n<reset>") end
    return false
  end
  if bg.timer then pcall(killTimer, bg.timer) end
  elro._bgGuard = nil
  elro._writeArea, elro._writeCleared, elro._writeCo = nil, nil, nil
  elro._bg = nil
  if not quiet then cecho("\n<yellow>[elro]: background relayout cancelled.\n<reset>") end
  return true
end

-- mapbg: report / toggle (`on|off`, `cancel`, `slice N`). `busy` = time solving vs wall
-- clock; WORST FRAME is the longest stretch the client was unresponsive.
function elro.bg_profile(bg)
  if not bg then return "" end
  local wall = (elro.now_ms() - bg.t0) / 1000
  local out = string.format("%d frame(s), %d yield(s), %.1fs busy of %.1fs",
                            bg.frames, bg.yields, bg.busyT or 0, wall)
  out = out .. string.format("\n  heap %.1fMB", collectgarbage("count") / 1024)
  if (bg.gcN or 0) > 0 then
    out = out .. string.format(", gc %.0fms over %d step(s) in the gaps",
                               (bg.gcT or 0) * 1000, bg.gcN)
  end
  if (bg.maxFrame or 0) > 0 then
    out = out .. string.format("\n  WORST FRAME %.0fms (%d frame(s) over budget)",
                               (bg.maxFrame or 0) * 1000, bg.overruns or 0)
    if bg.maxFrom or bg.maxTo then
      out = out .. "\n  ...it began after: " .. tostring(bg.maxFrom or "(run start)") ..
            "\n  ...and ended after: " .. tostring(bg.maxTo or "(run end)") ..
            "\n  ...yielded at tick: " .. tostring(bg.maxSite or "(unlabelled)")
    end
    if bg.over and bg.overN and bg.overN > 0 then
      -- Ranked by how much OVER-BUDGET time was spent there: each probe is one hook
      -- firing past the deadline, so the counts are directly comparable. THIS FRAME
      -- ONLY -- the worst one, snapshotted in bg_step.
      -- ⚠ The LEAF list is where the VM was; a leaf called from every phase (exit_next,
      -- orip) tops it without naming anything. The CALLER list is the one that says
      -- which loop is running without a tick, and so where a bg_tick belongs.
      local function rank(t, n, label)
        local ks = {}
        for k in pairs(t) do ks[#ks + 1] = k end
        -- count first, then the key: pairs order must not decide a tie's rank
        table.sort(ks, function(a, b)
          if t[a] ~= t[b] then return t[a] > t[b] end
          return a < b
        end)
        out = out .. "\n  " .. label .. " (" .. n .. " probe(s), worst frame):"
        for i = 1, math.min(#ks, 8) do
          out = out .. string.format("\n    %5.1f%%  %s", 100 * t[ks[i]] / n, ks[i])
        end
      end
      rank(bg.over, bg.overN, "over-budget CALLEE (leaf)")
      if bg.overC then rank(bg.overC, bg.overN, "over-budget CALLER  <- put the tick here") end
    end
    if bg.sites then
      local ks = {}
      for k in pairs(bg.sites) do ks[#ks + 1] = k end
      table.sort(ks, function(a, b) return bg.sites[a] > bg.sites[b] end)
      local parts = {}
      for i = 1, math.min(#ks, 6) do parts[#parts + 1] = ks[i] .. " " .. bg.sites[ks[i]] end
      out = out .. "\n  yields by tick: " .. table.concat(parts, " | ")
    end
  end
  return out
end

function elro.bg_status()
  local bg = elro._bg
  cecho(string.format("\n<cyan>[elro] background relayout: %s  (slice %dms, gap %.0fms)<reset>",
        elro.bgLayout and "on" or "off", elro.bgSlice, (elro.bgGap or 0) * 1000))
  if bg then
    cecho(string.format("\n<cyan>  IN FLIGHT '%s', %d area(s) left: %s<reset>",
          bg.label, bg.left or 0, elro.bg_profile(bg)))
  elseif elro._bgLast then
    cecho(string.format("\n<cyan>  idle; last run: %s<reset>", elro.bg_profile(elro._bgLast)))
  else
    cecho("\n<cyan>  idle<reset>")
  end
  cecho("\n")
end

-- Schedule an auto relayout once the player stops moving (idle-debounced). `urgent` fires
-- immediately: onRoom's guess put a new room on top of an existing one. While a build is in
-- flight this only notes the request.
function elro.markDirty(areaID, urgent)
  if not areaID then return end
  elro.dirty[areaID] = true
  if elro.bg_busy() then return end
  if elro.relayout_timer then killTimer(elro.relayout_timer) ; elro.relayout_timer = nil end
  elro.pending = (elro.pending or 0) + 1
  if urgent or ((elro.autoMax or 0) > 0 and elro.pending >= elro.autoMax) then
    elro.flush_dirty()                        -- overlapping rooms / max-wait: now
  else
    elro.relayout_timer = tempTimer(elro.autoIdle or 3, function()
      elro.relayout_timer = nil
      elro.flush_dirty()
    end)
  end
end

-- ---- off the map -----------------------------------------------------------
-- While the player is somewhere the server will not map, the marker must not
-- sit on the last mapped room: it reads as "you are here" and is wrong. Mudlet
-- has no way to show NO player room, so the view goes to one placeholder room in
-- a canvas of its own. `elro.current` is left alone on purpose: it is the halo's
-- and the walker's anchor, and clearing it would resync every stub on the map at
-- each step off it. The id sits below MAZE_VBASE and above any real room.
elro.OFF_ROOM = 899999
elro.OFF_AREA = "off the map"
-- Two rows, one label each (a label is a single line). A label's position is its
-- top-left corner, and at zoom 30 / 12pt a character is about 0.23 map units
-- wide, so x = -chars * 0.115 centres a row over the room at (0,0). Bump the
-- version when any of this changes and the old labels are replaced.
elro.OFF_LABEL_V = "3"
elro.OFF_LABEL = {
  { "In the dark, or off the map.",        2.4 },
  { "It resumes at the next known room.",  1.7 },
}

function elro.off_room()
  local id = elro.OFF_ROOM
  local made = not roomExists(id)
  local aid
  if made then
    addRoom(id)
    aid = elro.areaId(elro.OFF_AREA)
    setRoomArea(id, aid)
    setRoomCoordinates(id, 0, 0, 0)
    if type(setRoomName) == "function" then pcall(setRoomName, id, "Off the map") end
    -- adopt pins it to its own tab; VIA_NONE keeps a one-room area from folding
    setRoomUserData(id, "sarea", elro.OFF_AREA)
    setRoomUserData(id, "adopt", elro.OFF_AREA)
    setRoomUserData(id, "via", elro.VIA_NONE)
    elro.cs_lists_dirty() ; elro.cs_dirty(id, aid)
  end
  -- The label is versioned, so a reworded one replaces the old on an existing map.
  if getRoomUserData(id, "lblv") ~= elro.OFF_LABEL_V and type(createMapLabel) == "function" then
    aid = aid or getRoomArea(id)
    if type(getMapLabels) == "function" and type(deleteMapLabel) == "function" then
      local ok, ls = pcall(getMapLabels, aid)
      for lid in pairs(ok and type(ls) == "table" and ls or {}) do pcall(deleteMapLabel, aid, lid) end
    end
    for _, row in ipairs(elro.OFF_LABEL) do
      -- scaling WITH the map (noScaling false), or a centred row drifts as you zoom
      pcall(createMapLabel, aid, row[1], -#row[1] * 0.115, row[2], 0,
            200, 200, 200, 0, 0, 0, 30, 12, true, false)
    end
    setRoomUserData(id, "lblv", elro.OFF_LABEL_V)
  end
  return id
end

-- The room the VIEW follows: the placeholder while off the map, else the player's.
function elro.view_room()
  if elro.offmap then return elro.off_room() end
  return elro.current
end

-- Follow the player. updateMap() then centerview(); on a real canvas change re-assert once
-- from a tempTimer(0). A relayout passes `always` and must.
function elro.recenter(always)
  local id = elro.view_room()
  if not id or not roomExists(id) then return end
  centerview(id)
  local aid = getRoomArea(id)
  if aid == elro._viewArea and not always then return end
  -- Did the canvas actually change? Not the same question as `always` (a relayout
  -- passes `always` unconditionally, but only a real tab switch needs the
  -- map-mutation unstick). Latched, not assigned: the attempt that acts on it is
  -- a timer or two later and a second recenter for the same step must not clear it.
  if aid ~= elro._viewArea then elro._viewSwap = true end
  elro._viewArea = aid
  -- Deferred re-assert, twice: one tempTimer(0) can land inside the next build's
  -- write pass with nothing after it to correct the view; the second, later
  -- attempt costs nothing on the walking path (which returned above).
  if elro._viewTimer then killTimer(elro._viewTimer) ; elro._viewTimer = nil end
  if elro._viewTimer2 then killTimer(elro._viewTimer2) ; elro._viewTimer2 = nil end
  elro._viewTimer = tempTimer(0, function()
    elro._viewTimer = nil
    elro.view_assert("tick")
  end)
  elro._viewTimer2 = tempTimer(elro.viewSettle or 0.25, function()
    elro._viewTimer2 = nil
    elro.view_assert("settle")
  end)
end

-- Unstick a cross-canvas view by a map mutation: add a scratch room in the target area on
-- the current cell and delete it again (net change none). Only on a real canvas change and
-- never while a build is in flight.
function elro.view_unstick(cur, aid)
  if type(addRoom) ~= "function" or type(deleteRoom) ~= "function" then return false end
  local id = 999000001
  while roomExists(id) do id = id + 1 end
  local x, y, z = getRoomCoordinates(cur)
  local ok = pcall(function()
    addRoom(id)
    setRoomArea(id, aid)
    if x then setRoomCoordinates(id, x, y, z or 0) end
    deleteRoom(id)
  end)
  if roomExists(id) then pcall(deleteRoom, id) end   -- belt and braces: never leave one behind
  -- our own id caches saw a room appear and vanish; the net is zero but the lists were
  -- momentarily different, so drop them rather than reason about it.
  elro.cs_lists_dirty()
  if elro.debug then
    elro.tr(string.format("view: unstick -- scratch room %d in area %s (%s)", id,
      tostring(aid), ok and "ok" or "FAILED"))
  end
  return ok
end

function elro.view_assert(why)
  local cur = elro.view_room()
  if not (cur and roomExists(cur)) then return end
  -- Tell Mudlet where the player is, FIRST: the widget keeps its own player-room
  -- notion and centerview alone does not necessarily move it. Guarded (not in
  -- every build) and pcall'd.
  if type(setPlayerRoom) == "function" then pcall(setPlayerRoom, cur) end
  -- the map mutation LAST of the pre-steps, so the cheap levers get their chance first
  if elro._viewSwap and elro.viewUnstick ~= false and not elro._bg then
    elro._viewSwap = nil
    elro.view_unstick(cur, getRoomArea(cur))
  end
  if type(updateMap) == "function" then updateMap() end
  centerview(cur)
  -- ...and push it again AFTER, for the area switch (see recenter above).
  if type(updateMap) == "function" then updateMap() end
  if elro.debug then
    -- Trace prints the area's extent and z range too: a room at (0,0) is either
    -- a normal corner or a stray never written by this layout, and only the
    -- extent tells them apart; a room one z level off is invisible on the layer
    -- being shown, which looks like a mis-centred view.
    local x, y, z = getRoomCoordinates(cur)
    local aid = getRoomArea(cur)
    -- cs_area_rooms returns a LIST: walk with ipairs, and say outright whether
    -- the room is in it.
    local n, lox, loy, hix, hiy, mine = 0, nil, nil, nil, nil, false
    local loz, hiz = nil, nil
    for _, r in ipairs(elro.cs_area_rooms(aid) or {}) do
      if r == cur then mine = true end
      local rx, ry, rz = getRoomCoordinates(r)
      if rx then
        n = n + 1 ; rz = rz or 0
        if not lox or rx < lox then lox = rx end ; if not hix or rx > hix then hix = rx end
        if not loy or ry < loy then loy = ry end ; if not hiy or ry > hiy then hiy = ry end
        if not loz or rz < loz then loz = rz end ; if not hiz or rz > hiz then hiz = rz end
      end
    end
    elro.tr(string.format("view: %s -- room %s area %s at (%s,%s,z=%s)%s; canvas %d room(s)"
      .. " spanning (%s,%s)..(%s,%s) z %s..%s  player=%s",
      tostring(why), tostring(cur), tostring(aid),
      tostring(x), tostring(y), tostring(z),
      mine and "" or "  [NOT IN THE AREA'S ROOM LIST]", n,
      tostring(lox), tostring(loy), tostring(hix), tostring(hiy),
      tostring(loz), tostring(hiz),
      (type(getPlayerRoom) == "function") and tostring(select(2, pcall(getPlayerRoom)))
        or "n/a"))
  end
end

-- Room names arrive from the feed and can carry colour. mapreg_d strips it, but onRoom
-- is the client's whole API (another mud wires its own protocol to it), so the name is
-- not assumed clean here either. Matches the full CSI, not anything bracket-shaped: a
-- room called "bracket [north] kept" has to survive.
--
-- ⛔ THE SECOND PATTERN IS FOR A CSI THAT LOST ITS ESC. mapreg_d once stripped the ESC
-- byte alone and left "[38;40;0m" behind as literal text (fixed server-side in 685cac4,
-- but every name written before that is still in the map file). Those names then fail
-- string equality against a clean one -- mapmazefit missed a "a paved road" door room
-- for exactly this reason. Narrower than the real CSI on purpose: digits and semicolons
-- only, and a final "m", so "[north]" and "[2 of 3]" are untouched.
function elro.strip_ansi(s)
  if type(s) ~= "string" then return s end
  return (s:gsub("\27%[[0-9;?]*[ -/]*[@-~]", ""):gsub("\27", ""):gsub("%[[0-9;]+m", ""))
end

-- Rooms that arrived while a build was in flight: the committed layout
-- normalized coordinates, so their unit-step guesses point nowhere. Re-derive
-- the same guess from where the source room actually landed; the queued rebuild
-- places them properly. No collision check on purpose -- a rebuild is already
-- queued regardless of where the re-seed lands.
function elro.guess_pend(id, fromId, dir)
  local t = elro._pendGuess
  if not t then t = {} ; elro._pendGuess = t end
  t[id] = { from = fromId, dir = dir }
end

function elro.guess_reseed()
  local t = elro._pendGuess
  if not t then return end
  elro._pendGuess = nil
  for id, g in pairs(t) do
    local del = elro.delta[g.dir]
    if del and roomExists(id) and roomExists(g.from) then
      local fx, fy, fz = getRoomCoordinates(g.from)
      if fx then
        setRoomCoordinates(id, fx + del[1], fy + del[2], fz)
        elro.cell_drop(getRoomArea(id))
      end
    end
  end
end

-- Drop now-empty area tabs. ONE definition, called from recompute_areas and from the end of
-- a relayout, because the two had drifted apart and each was wrong in its own way: one kept
-- deleting "world 2" (which relayout lays out EVEN WHEN EMPTY -- see the `aid == st.w2` arm,
-- so deleting it out from under the run leaves layout_world2 on a dead area), and the other
-- never cleared `elro.dirty`, leaking a flag for an area that no longer exists.
local function drop_empty_areas()
  local dropped = false
  for name, aid in pairs(elro.cs_areas()) do
    if name ~= "world" and name ~= "world 2" and next(elro.cs_area_rooms(aid)) == nil then
      elro.dirty[aid] = nil        -- never leave a flag on a deleted area
      deleteArea(aid)
      dropped = true
    end
  end
  if dropped then elro.cs_areas_dirty() ; elro.cs_lists_dirty() end
end

-- Regionalization pass: group every room by its server area, and keep a server
-- area as its own Mudlet tab only if its largest internally-connected (compass)
-- cluster has >= area_min rooms. Otherwise fold its rooms into "world". Marks
-- every Mudlet area whose membership changed dirty so flush re-lays it out.
-- Reads the c-space snapshot, not Mudlet: one cs_room per room, materialized on
-- first touch and dropped only for rooms onRoom actually changed.
function elro.recompute_areas()
  if elro.merge == nil then elro.load_merge() end
  if elro.outerPick == nil then elro.load_outer() end
  if not elro.areamin_loaded then elro.load_areamin() end
  if not elro.vertpack_loaded then elro.load_vertpack() end
  if not elro.stubshow_loaded then elro.load_stubshow() end
  if not elro.mapecho_loaded then elro.load_mapecho() end
  if not elro.stubhalo_loaded then elro.load_stubhalo() end
  -- localised: both are read once per room (and `delta` once per EDGE) over the
  -- whole map, and Mudlet runs stock Lua 5.1 with no JIT to hoist the lookups
  local cs_room, delta = elro.cs_room, elro.delta
  local all = elro.cs_all_rooms()          -- id -> name (whole map)
  local invArea = {}                       -- areaID -> name, for backfill
  for nm, aid in pairs(elro.cs_areas()) do invArea[aid] = nm end
  local sarea, groups, forced, recs = {}, {}, {}, {}
  local exempt = {}                        -- server areas the fold may not touch
  for id in pairs(all) do
    local rec = cs_room(id)
    if not rec then rec = { ex = {}, sarea = "", adopt = "", fold = "" } end
    recs[id] = rec
    local sa = rec.sarea
    if sa == nil or sa == "" then
      -- pre-existing room (mapped before sarea was tracked): adopt its current
      -- area name as the server area, and persist it. Update the snapshot in
      -- place rather than invalidating -- we know exactly what it now holds.
      sa = invArea[rec.area] or "world"
      setRoomUserData(id, "sarea", sa)
      rec.sarea = sa
    end
    -- Backfill `via` from the room's current area, so pre-`via` rooms keep
    -- folding where they already are instead of each keeping its own tab.
    if rec.via == nil or rec.via == "" then
      local v = invArea[rec.area] or "world"
      setRoomUserData(id, "via", v)
      rec.via = v
    end
    -- effective area: a per-room "adopt" (single-room steal into an existing
    -- area, set by mapsteal) wins outright; then a manual fold; otherwise apply
    -- any manual merge redirects. All are forced to keep their own tab. Unlike
    -- fold, adopt is NOT inherited by newly-created child rooms in onRoom -- a
    -- stolen room shouldn't drag its future neighbours into the host area.
    local adopt = rec.adopt
    local fold = rec.fold
    local eff
    if adopt and adopt ~= "" then eff = adopt ; forced[eff] = true
    elseif fold and fold ~= "" then eff = fold ; forced[eff] = true
    else
      eff = elro.resolve_area(sa, rec.mh)
      if eff ~= sa then forced[eff] = true
      elseif elro.hint_pinned(sa) then forced[sa] = true end   -- an unmerge keeps its tab
    end
    sarea[id] = eff
    if rec.via == elro.VIA_NONE then exempt[eff] = true end
    groups[eff] = groups[eff] or {}
    groups[eff][#groups[eff] + 1] = id
  end

  -- decide kept vs merged per server area (world is always its own tab)
  local keep = {}
  for sa, ids in pairs(groups) do
    if sa == "world" then
      keep[sa] = true
    else
      local idset = {}
      for _, id in ipairs(ids) do idset[id] = true end
      local seen, largest = {}, 0
      for _, start in ipairs(ids) do
        if not seen[start] and largest < elro.area_min then
          local q, qh, sz = {start}, 1, 0
          seen[start] = true
          while qh <= #q do
            local u = q[qh] ; qh = qh + 1 ; sz = sz + 1
            -- snapshot exits: already normalized, so no per-edge elro.norm here
            local ru = recs[u]
            for d, v in pairs(ru and ru.ex or CS_EMPTY) do
              local del = delta[d]
              if del and (del[1] ~= 0 or del[2] ~= 0) and idset[v] and not seen[v] then
                seen[v] = true ; q[#q + 1] = v
              end
            end
          end
          if sz > largest then largest = sz end
        end
      end
      keep[sa] = largest >= elro.area_min
    end
  end
  -- manual fold submaps / merge targets always keep their own tab
  for name in pairs(forced) do keep[name] = true end
  -- ...and so does an area holding a room with no entry area to be absorbed by:
  -- it survives whole rather than being torn between world and a host.
  for name in pairs(exempt) do keep[name] = true end

  -- assign effective Mudlet areas, marking changed areas dirty. Membership is
  -- the one thing this pass mutates, so correct the snapshot here: patch
  -- rec.area in place and drop the cached id lists once, at the end.
  local moved = false
  for id in pairs(all) do
    -- Fold destination: a kept area keeps its rooms; otherwise the room goes to
    -- the area it was first entered from, falling back to world. `keep[v]` is
    -- populated for every area with rooms in THIS pass, so a via naming an
    -- emptied or itself-folded area lands in world instead of chaining.
    local sa = sarea[id]
    local eff = sa
    if not keep[sa] then
      local v = recs[id].via
      eff = (v ~= "" and v ~= elro.VIA_NONE and keep[v]) and v or "world"
    end
    local aid = elro.areaId(eff)
    local rec = recs[id]
    local old = rec.area
    if old ~= aid then
      setRoomArea(id, aid)
      rec.area = aid
      moved = true
      if old and old > 0 then elro.dirty[old] = true ; elro.cs_bump(old) end
      elro.dirty[aid] = true ; elro.cs_bump(aid)
    end
  end
  if moved then elro.cs_lists_dirty() end

  drop_empty_areas()
end

-- remove every custom line on every room. removeCustomLine in this Mudlet build
-- needs (roomID, direction), so we enumerate each room's lines via getCustomLines
-- and clear them per-direction (single-arg form silently no-ops here).
function elro.clear_lines()
  if type(getCustomLines) ~= "function" or type(removeCustomLine) ~= "function" then
    return
  end
  for id in pairs(elro.cs_all_rooms()) do
    local cl = getCustomLines(id)
    if type(cl) == "table" then
      for dir in pairs(cl) do pcall(removeCustomLine, id, dir) end
    end
  end
end

-- clear custom lines for one area's rooms only (incremental relayout)
function elro.clear_lines_area(aid)
  if type(getCustomLines) ~= "function" or type(removeCustomLine) ~= "function" then
    return
  end
  for _, id in ipairs(elro.cs_area_rooms(aid)) do
    local cl = getCustomLines(id)
    if type(cl) == "table" then
      for dir in pairs(cl) do pcall(removeCustomLine, id, dir) end
    end
  end
end

-- lay out ONE Mudlet area: the closure-equation walk, with two exceptions that
-- fall back to the flood.
function elro.layout_one(aid, allow_overflow)
  local name = elro.areaName(aid) or "world"
  -- Exception 1: maze submaps are untruthful by nature -- just flood them.
  -- Exception 2: ns_cap, a blunt guard on pathological areas; the walk is still
  -- superlinear and the flood near-linear.
  if elro.is_maze_area(name) or #elro.cs_area_rooms(aid) > (elro.ns_cap or 1000) then
    elro.layout_area(aid, allow_overflow)
    return
  end
  elro.layout_eqw(aid)
  -- ...then ask whether the maze vertex earned its place here. A veto changes
  -- nothing on screen now; it latches the area so the NEXT relayout skips it.
  if elro.mazeVertex then elro.maze_check_veto(aid) end
end

-- The write gate: every coordinate write for an area calls this first. It answers
-- "may I commit?" and clears the area's stale custom lines INSIDE the write
-- boundary, so a discarded stale layout has touched nothing on the canvas.
-- `elro._writeArea` is context armed by relayout_body for one area's solve and
-- is per THREAD: a mapstep redraw on the main thread during a background solve
-- must not inherit the coroutine's context (nil context = ungated, no clear).
function elro.write_begin()
  local aid = elro._writeArea
  if not aid or elro._writeCo ~= coroutine.running() then return true end
  if not elro.bg_write_ok() then return false end
  if not elro._writeCleared then
    elro._writeCleared = true
    elro.clear_lines_area(aid)
    -- every room on this canvas is about to move, so every cell key is about to
    -- be wrong. Drop the index and let the next lookup rebuild it.
    elro.cell_drop(aid)
  end
  return true
end

-- Build the ordered area list a relayout will process. `all` = every area (full
-- flush); otherwise just elro.dirty. Sorted so a run is deterministic and so the
-- CURRENT area goes first -- with a background solve the player sees their own
-- surroundings settle before the rest of the map.
local function relayout_todo(all)
  local w2 = elro.areaId("world 2")
  local set = {}
  if all then
    for _, aid in pairs(elro.cs_areas()) do set[aid] = true end
  else
    for aid in pairs(elro.dirty) do set[aid] = true end
  end
  local cur = elro.current and roomExists(elro.current) and getRoomArea(elro.current) or nil
  local order = {}
  for aid in pairs(set) do if aid ~= w2 then order[#order + 1] = aid end end
  table.sort(order, function(a, b)
    if (a == cur) ~= (b == cur) then return a == cur end
    return a < b
  end)
  -- world 2 is the overflow dumping ground: it can only be laid out sensibly
  -- once everything that overflows INTO it has run, so it always goes last.
  if all or set[w2] then order[#order + 1] = w2 end
  return order, w2
end

-- The relayout body, shared by flush/flush_dirty and by the foreground and
-- background paths (bg_tick is a no-op off the coroutine).
local function relayout_body(st)
  local tf = st.tf
  local function ms(a, b) return string.format("%.0fms", (b - a) * 1000) end
  local allow_overflow = elro.overflow
  -- Per-run state that must never outlive a run (a canvas that errors skips its
  -- own resets): the timeGuillo arm flag, the memos keyed on adj TABLE IDENTITY
  -- (mapaudit can change the graph under a reused table), and the gap clock.
  elro._tgOpen = nil
  elro._wbAdjMemo = nil
  elro._topoMemo, elro._wireMemo = nil, nil
  elro._prLast, elro._prLastRoom, elro._prLastPhase = nil, nil, nil
  for _, aid in ipairs(st.order) do
    st.left = st.left - 1
    if type(st.bg) == "table" then st.bg.left = st.left end
    elro.bg_tick()
    if next(elro.cs_area_rooms(aid)) ~= nil or aid == st.w2 then
      elro.tr("relayout: aid=" .. tostring(aid) .. " name=" .. tostring(elro.areaName(aid)))
      local ta = tf and os.clock()
      local g = elro.bg_guard(st.bg and aid or nil)
      elro._writeArea, elro._writeCleared, elro._writeCo = aid, false, coroutine.running()
      if aid == st.w2 then elro.layout_world2(st.w2) else elro.layout_one(aid, allow_overflow) end
      -- end of canvas: report + clear the timeGuillo counters (guarded: a canvas
      -- that never reached walk_branches has not defined them)
      if elro.timeGuillo and elro.tg_report then elro.tg_report() end
      elro._writeArea, elro._writeCleared, elro._writeCo = nil, nil, nil
      elro.bg_guard(nil)
      if g and g.mixed then
        -- Mixed input: committed anyway (see bg_write_ok) and left dirty; recording
        -- it in st.stale makes the redo run regardless of autoflush.
        st.stale[#st.stale + 1] = aid
        elro.dirty[aid] = true
        if not elro.bgDropMixed then st.n = st.n + 1 end
        elro.tr("relayout: aid=" .. tostring(aid)
          .. (elro.bgDropMixed and " DISCARDED (input was mixed)"
                                or " COMMITTED on mixed input -- rebuilding"))
      elseif elro.bg_guard_moved(g) then
        -- committed, but the player changed this area while we were solving it, so
        -- the result does not cover everything. Keep it dirty for the next build.
        elro.dirty[aid] = true
        st.n = st.n + 1
        elro.tr("relayout: aid=" .. tostring(aid) .. " COMMITTED but re-dirtied (you explored)")
      else
        elro.dirty[aid] = nil
        st.n = st.n + 1 ; st.clean = (st.clean or 0) + 1
      end
      if tf then
        cecho(string.format("\n<yellow>[time] layout_one '%s': %s (%d rooms)%s<reset>",
          tostring(elro.areaName(aid)), ms(ta, os.clock()), #elro.cs_area_rooms(aid),
          (g and g.mixed) and (elro.bgDropMixed and "  DISCARDED" or "  MIXED") or "")) end
    else
      elro.dirty[aid] = nil
    end
  end
  drop_empty_areas()
  elro.guess_reseed()          -- rooms that arrived mid-flight: re-derive their guess
  if tf then cecho(string.format("\n<yellow>[time] relayout total: %s<reset>", ms(st.t0c, os.clock()))) end
  -- updateMap first, then recenter (see elro.recenter). The unstick latch is set
  -- on every rewrite, not only on a tab switch: Mudlet caches an area's span and
  -- recomputes it when the room SET changes, not when coordinates do, so a
  -- relayout leaves the widget centring through a stale frame.
  elro._viewSwap = true
  updateMap()
  elro.recenter(true)
  elro.tr("relayout: EXIT n=" .. st.n .. " stale=" .. #st.stale)
end

-- Finish a run. The loop is level-triggered: if anything changed while we ran,
-- run again. The only bound is a spin guard (three consecutive runs with no
-- CLEAN commit), not a retry budget. `moved` is gated on autoflush; a mixed-input
-- redo is a correctness redo and runs either way.
local function relayout_done(st)
  return function(bg)
    elro.wd_stop()          -- the run is over: disarm the watchdog and drop any VM hook it installed
    local secs = (elro.now_ms() - bg.t0) / 1000
    local moved = (elro.gchg or 0) ~= st.gchg0
    local want  = (#st.stale > 0) or (moved and elro.autoflush)
    -- The spin guard resets on CLEAN commits only: a mixed/moved commit is progress
    -- for the picture, not for convergence, and counting it would let a walking
    -- player pin a core indefinitely.
    local spin  = ((st.clean or 0) > 0) and 0 or ((st.spin or 0) + 1)
    if want and spin < 3 then
      if not st.quiet then
        cecho(string.format("\n<yellow>[elro]: relayout %.1fs, %d map(s) committed; %s -- rebuilding.\n<reset>",
              secs, st.n,
              (#st.stale > 0)
                and (#st.stale .. " had mixed input ("
                     .. (elro.bgDropMixed and "not drawn" or "drawn anyway") .. ")")
                or "you explored while it ran"))
      end
      elro.flush_dirty(spin)
    elseif want then
      if not st.quiet then
        cecho(string.format("\n<yellow>[elro]: relayout %.1fs; %d run(s) in a row could not"
              .. " settle (you kept exploring) -- stopping. The map is drawn but may be a"
              .. " little stale; `maprelayout` or your next pause redoes it.\n<reset>",
              secs, spin))
      end
    elseif not st.quiet then
      -- reached only under `mapecho on` (relayout() sets quiet otherwise)
      cecho(string.format("\n<green>[elro]: relayout done -- %d map(s) in %.1fs.\n  %s\n<reset>",
            st.n, secs, elro.bg_profile(bg)))
    end
    -- Final view assert only when no further build is queued; the rebuilding
    -- branch would assert against coordinates about to be replaced.
    if not want or spin >= 3 then elro.view_assert("run end") end
  end
end

-- Common prologue + dispatch for both flush entry points. Returns the number of
-- maps relaid, or -1 when the work was handed to the background coroutine.
local function relayout(all, quiet, spin)
  -- A relayout reports ONLY under `mapecho on`, whoever or whatever started it.
  -- The reports are the solver's own; a command that causes a relayout answers
  -- for itself ("the hint for 'harbour' is followed again"), and that is enough.
  if not elro.mapecho_loaded then elro.load_mapecho() end
  if not elro.mapEcho then quiet = true end
  if type(elro.step_teardown) == "function" then elro.step_teardown() end
  -- A foreground run that errored mid-area may have left the write context armed.
  elro._writeArea, elro._writeCleared, elro._writeCo, elro._bgGuard = nil, nil, nil, nil
  -- mapstep / mapdash write coordinates without touching the cell index; drop it.
  elro.cell_drop()
  -- face-span diagnostics live for one whole relayout (not per compose)
  elro._faceSpans = nil
  elro._faceMinSpans = nil
  elro.wd_start()
  -- Never run two coroutines on the same canvas: a full flush supersedes the
  -- in-flight run (cancel it); an incremental one defers to its retry.
  if elro.bg_busy() then
    if all then
      elro.bg_cancel(true)
    else
      elro.pending = 0            -- ...or markDirty's debounce never re-arms
      elro.tr("relayout: background run already in flight; deferred")
      return -1
    end
  end
  -- restart the trace timeline and the per-step timing log for this run
  elro._trLast, elro._trIdle = nil, nil
  elro._stepTimeLog, elro._stepTimeSeg = {}, 0
  elro.tr("relayout: ENTER all=" .. tostring(all))
  if elro.relayout_timer then killTimer(elro.relayout_timer) ; elro.relayout_timer = nil end
  elro.pending = 0
  -- elro.timeFlush: print recompute_areas vs per-area layout timings
  local tf = elro.timeFlush
  local t0c = tf and os.clock()
  local nd = 0 ; for _ in pairs(elro.dirty) do nd = nd + 1 end
  -- Deliberately in the foreground: detect_mazes and recompute_areas MUTATE the
  -- map, and the solver must see a graph nobody is editing.
  if all and elro.maze_auto then elro.detect_mazes() end
  elro.recompute_areas()                       -- may add membership-change dirty
  if tf then cecho(string.format("\n<yellow>[time] recompute_areas: %s (%d dirty in)<reset>",
        string.format("%.0fms", (os.clock() - t0c) * 1000), nd)) end
  elro.tr("relayout: recompute_areas done")
  local order, w2 = relayout_todo(all)
  elro.tr("relayout: todo=" .. #order)
  local st = { order = order, w2 = w2, n = 0, stale = {}, tf = tf, t0c = t0c,
               left = #order, quiet = quiet, spin = spin or 0, gchg0 = elro.gchg or 0 }
  if elro.bgLayout and #order > 0 then
    st.bg = true
    -- No pcall may wrap this body: stock Lua 5.1 cannot yield across a C call.
    -- bg_start only creates the coroutine; every resume happens from the timer.
    local started = elro.bg_start(function() relayout_body(st) end, "relayout", relayout_done(st))
    if started then
      st.bg = elro._bg
      return -1
    end
    st.bg = nil                                -- lost the race; fall through
  end
  relayout_body(st)
  return st.n
end

-- FULL relayout: every Mudlet area. Used by global setting changes (mode,
-- spacing, shear, overflow, ...).
function elro.flush()
  return relayout(true, false)
end

-- INCREMENTAL relayout: only the maps that changed (elro.dirty), plus any
-- membership changes recompute_areas finds. This is the cheap on-demand path --
-- walking only dirties the current map, so a relayout no longer re-solves the
-- whole multi-thousand-room world. Mode "b" (cosmetic portal lines, global)
-- falls back to a full flush. Returns the number of maps relaid, or -1 when the
-- work was handed to the background coroutine (or a run was already in flight).
function elro.flush_dirty(spin)
  return relayout(false, false, spin)
end

-- `maprelayout this`: force a relayout of the CURRENT canvas. Marks it dirty
-- rather than calling the layout directly, so it takes the normal path.
function elro.relayout_this()
  local cur = elro.current
  if not cur then cecho("\n<red>[elro]: move once first.\n<reset>") return end
  local aid = getRoomArea(cur)
  local name = elro.areaName(aid) or "world"
  elro.dirty[aid] = true
  if elro.flush_dirty() ~= -1 then
    cecho(string.format("\n<green>[elro]: relayout of '%s' done.\n<reset>", name))
  else
    cecho(string.format("\n<cyan>[elro]: relayout of '%s' running in the background -- keep playing.\n<reset>", name))
  end
end

-- diagnostics: dump the current room, its area, and every room's coords/exits
-- shared: dump a specific list of room ids (id, coords, area, exits)
function elro.dump_rooms(ids, label)
  local nm = elro.cs_areas_swap()
  local list = {}
  for _, r in ipairs(ids) do if roomExists(r) then list[#list + 1] = r end end
  table.sort(list)
  cecho("\n<cyan>[elro] " .. (label or "rooms") .. ": " .. #list .. "<reset>\n")
  for _, r in ipairs(list) do
    local x, y, z = getRoomCoordinates(r)
    local ex = {}
    for d, dest in pairs(getRoomExits(r) or {}) do ex[#ex + 1] = d .. "->" .. dest end
    cecho(string.format("<yellow>  %s<reset> (%d,%d,%d) area=%s [%s]\n",
          tostring(r), x, y, z, tostring(nm[getRoomArea(r)]), table.concat(ex, ", ")))
  end
end

-- Knob registry for `mapknobs` / `mapknobs reset`. Every knob is read as
-- `elro.foo or <default>` or `elro.foo ~= false`, so clearing the field restores
-- the default. A field seeded at load time (`elro.foo = elro.foo or N`) whose
-- readers use a different fallback (spacing, ns_cap, area_min, bgSlice, ...)
-- must NOT be listed: clearing it would install the reader's fallback instead.
elro.KNOBS = {
  -- onRoom cost
  "guessOnEdge",       -- default ON. The room-on-edge half of guess_inconsistent, which walks
                       -- EVERY edge in the area on arrival (the rest of that function is
                       -- O(exits of the new room)). Diagnostic knob: `lua elro.guessOnEdge =
                       -- false` keeps the cheap checks and drops only the scan.
  -- maze vertices (PLAN-maze.md)
  "mazeVertex",        -- default OFF. Put ONE synthetic vertex on the parent canvas per folded
                       -- maze cluster and turn each boundary door into a real compass edge to
                       -- it, instead of dropping the door for being out of area. SCAFFOLDING:
                       -- it exists to A/B step 1 and folds out at step 5 -- do not build on it.
  -- vertical (up/down) exits
  "vertOverRoom",      -- default OFF. Let the vertical CONNECTOR cross rooms (never a room of
                       -- the floor on an edge, never a collision). Inert at scale 1.
  "vertNoCrossInFace", -- default ON. Refuse a dock whose connector crosses a placed edge AND
                       -- whose floor landed inside an enclosed face. "Inside" is a flood
                       -- (vert_enclosed) bounded by TUNE.vertFloodCap; it fails open.
  "vertPiston",        -- default ON. After docking, stretch one Tarjan bridge so a near-miss
                       -- vertical (within TUNE.vertPistonL1) draws straight. A bridge cancels
                       -- out of every closure sum, so stretching it breaks nothing; the gate
                       -- (no defect kind worse, target drawable, nothing undrawable) is
                       -- what keeps vertPack monotone and must stay.
  "vertMakeRoom",      -- default OFF (user preference). Before a dock the packer would
                       -- decline, stretch one bridge of the MASS to free the cell and re-run
                       -- the ray search. Gate measured on the mass alone, before the child is
                       -- merged; own trial cap vertRoomTries.

  -- loop closure / total face area
  "eqWalkLazy",        -- default ON. Defer `:t`/`:sf` seam walks until the probe loops are
                       -- done, then walk only the bases tied at the best SHEAR-BLIND score;
                       -- elro._eqWalkAll escalates to walking every base when no clean pick
                       -- results. Heuristic: a variant can score better than its base.
  "tightenSeedScan",   -- default OFF. When the ring tighten's extreme seed is blocked, offer
                       -- the next room inward (ordered by coordinate then id, deduped by
                       -- class, capped by TUNE.tightenSeedCap). Off is seed 1 only.

  -- incremental (onRoom) relayout triggers
  "guessCheck",        -- default ON. A step's loop-closing edges are checked for a lie or an
                       -- edge over a room, and the queued relayout is made urgent if one is
                       -- found. Registered because it has no offline expression -- mapknobs is
                       -- the only way to see it is on. Fold once judged.
}
-- Probes: instruments, not behaviour. Listed separately from KNOBS but shown by
-- `mapknobs` and cleared by `reset_knobs` all the same, since a probe left on can
-- shift allocation-sensitive tie-breaks. A probe read in layout.lua but not
-- listed here cannot be set from a spec.
elro.PROBES = {
  -- detWho: attribute detector calls to the caller line.
  -- crossCost: per-face planarity cost (total excess over unit closure); read via mapfacefit.
  "crossCost", "probeRigid", "probeField", "detWho",
  "timeGuillo", "stepDebug", "stepTime", "stepRanked", "walkWatchdog",
  "probeMove",         -- <roomid> or a list: trace every pull that moves the watched rooms
  "probeChunkFace",    -- chunk_face_first: block-entry density gate lines
  "repelDump", "drawSprings",
  "probeClose",        -- also trace the no-op closures
  "probeSeam",         -- record the whole seam per candidate (seamEdges), not just seam=N
  "fieldWatch",        -- <roomid> or a list: print every narrowing of that room's class in the field solve
  "bgHook",            -- VM instructions between overrun probes; makes mapbg name the SOURCE LINE
                       -- that was running when the frame budget blew. In game only: under LuaJIT
                       -- the count hook does not fire inside compiled traces.
}
-- Iterates KNOBS and PROBES both; a probe missing here is invisible and unresettable.
function elro.knob_list(reset)
  local on = {}
  for _, reg in ipairs({ elro.KNOBS, elro.PROBES }) do
  for _, k in ipairs(reg or {}) do
    if elro[k] ~= nil then
      on[#on + 1] = k .. "=" .. tostring(elro[k])
      if reset then elro[k] = nil end
    end
  end
  end
  if #on == 0 then
    cecho("\n<green>[elro]: all knobs at default.\n<reset>")
  else
    cecho(string.format("\n<yellow>[elro]: %d knob(s) %s:\n  %s\n<reset>",
      #on, reset and "RESET to default" or "overridden", table.concat(on, "\n  ")))
  end
end
function elro.reset_knobs() elro.knob_list(true) end

-- Dump rooms to a file in the format the offline harness loaders parse:
--   lua elro.dump_file("C:/.../analysis/world_live.txt")
-- `ids` = a list, "sel" for the mapper selection, or nil for the current area;
-- `note` is written as a leading `--` line. Exits are sorted so dumps diff cleanly.
function elro.dump_file(path, ids, note)
  if type(path) ~= "string" then
    cecho("\n<red>[elro]: dump_file needs a path.\n<reset>") return
  end
  local cur = elro.current
  if ids == "sel" then
    ids = elro.sel_rooms()
    if not ids then return end          -- sel_rooms already explained why
  end
  if not ids then
    if not cur then cecho("\n<red>[elro]: move once first.\n<reset>") return end
    ids = elro.cs_area_rooms(getRoomArea(cur))
  end
  local nm = elro.cs_areas_swap()
  local list = {}
  for _, r in ipairs(ids) do if roomExists(r) then list[#list + 1] = r end end
  table.sort(list)
  local f, err = io.open(path, "w")
  if not f then
    cecho("\n<red>[elro]: cannot write " .. path .. ": " .. tostring(err) .. "\n<reset>") return
  end
  f:write("-- ", tostring(note or ("dump of " .. #list .. " room(s)")), "\n")
  f:write("-- src=", tostring(elro._srcStamp), "\n")
  do
    local inList, picked = {}, {}
    for _, r in ipairs(list) do inList[r] = true end
    for _, r in ipairs(elro.outer_list()) do if inList[r] then picked[#picked + 1] = r end end
    if #picked > 0 then f:write("-- outer=", table.concat(picked, ","), "\n") end
  end
  for _, r in ipairs(list) do
    local x, y, z = getRoomCoordinates(r)
    local ex = {}
    for d, dest in pairs(getRoomExits(r) or {}) do ex[#ex + 1] = d .. "->" .. dest end
    table.sort(ex)
    f:write(string.format("  %s (%d,%d,%d) area=%s [%s]\n",
            tostring(r), x, y, z, tostring(nm[getRoomArea(r)]), table.concat(ex, ", ")))
  end
  f:close()
  cecho(string.format("\n<green>[elro]: wrote %d room(s) to %s\n<reset>", #list, path))
end

function elro.dump()
  local cur = elro.current
  cecho("\n<cyan>[elro] current=" .. tostring(cur) ..
        " area=" .. tostring(cur and getRoomArea(cur)) .. "<reset>")
  if not cur then return end
  local ids = {}
  for _, r in ipairs(elro.cs_area_rooms(getRoomArea(cur))) do ids[#ids + 1] = r end
  elro.dump_rooms(ids, "current area")
end

-- The rooms currently selected in the 2D mapper (rubber-band / ctrl-click), as
-- a plain list. Returns nil AND explains why when the build has no selection API
-- or nothing is selected. Two shapes exist: a bare id list and { rooms = {...} }.
function elro.sel_rooms()
  if type(getMapSelection) ~= "function" then
    cecho("\n<red>[elro]: getMapSelection() not in this Mudlet build.\n<reset>")
    return nil
  end
  local sel = getMapSelection() or {}
  local ids = sel.rooms or sel
  if type(ids) ~= "table" or next(ids) == nil then
    cecho("\n<red>[elro]: nothing selected. Rubber-band or ctrl-click rooms in the mapper first.\n<reset>")
    return nil
  end
  local out = {}
  for _, id in pairs(ids) do
    if type(id) == "number" then out[#out + 1] = id end
  end
  if #out == 0 then
    cecho("\n<red>[elro]: selection held no room ids.\n<reset>")
    return nil
  end
  table.sort(out)
  return out
end

-- dump only the rooms currently selected in the 2D mapper (rubber-band /
-- ctrl-click). The way to troubleshoot one bad region inside a huge map.
function elro.dumpsel()
  local ids = elro.sel_rooms()
  if not ids then return end
  elro.dump_rooms(ids, "selection")
end


-- diagnostics: every room in the whole map, its area, existence, and coords
function elro.dumpall()
  local nm = elro.cs_areas_swap()
  local rooms = elro.cs_all_rooms()
  local t = {}
  for id in pairs(rooms) do
    local a = getRoomArea(id)
    local x, y, z = getRoomCoordinates(id)
    t[#t + 1] = string.format("  %s  area=%s  (%d,%d,%d)",
                              tostring(id), tostring(nm[a]), x, y, z)
  end
  table.sort(t)
  cecho("\n<cyan>[elro] getRooms() has " .. #t .. " rooms:\n<reset>"
        .. table.concat(t, "\n") .. "\n")
  local c = elro.current
  cecho(string.format("<cyan>current=%s  roomExists=%s  getRoomArea=%s<reset>\n",
        tostring(c), tostring(c and roomExists(c)), tostring(c and getRoomArea(c))))
end

-- Record an exit mutation: bump mut_<dir> and add the destinations to the
-- space-separated set mutdst_<dir> (maze clustering follows every room a
-- shuffling exit has ever led to).
function elro.mut_record(room, dir, ...)
  local mk = "mut_" .. dir
  setRoomUserData(room, mk, tostring((tonumber(getRoomUserData(room, mk)) or 0) + 1))
  local key = "mutdst_" .. dir
  local cur = getRoomUserData(room, key) or ""
  local have = {}
  for tok in cur:gmatch("%d+") do have[tonumber(tok)] = true end
  local out = cur
  for _, dst in ipairs({ ... }) do
    if dst and dst ~= 0 and not have[dst] then
      have[dst] = true
      out = (out == "" and tostring(dst)) or (out .. " " .. dst)
    end
  end
  if out ~= cur then setRoomUserData(room, key, out) end
end

-- does the destination's advertised exit list include direction `dir`? Nil/empty/none
-- means we have no info -> permissive (true), so we never suppress a reverse just
-- because the server didn't send an exit list this time.
function elro.advertises(exits, dir)
  if not exits or exits == "" or exits == "none" then return true end
  for raw in string.gmatch(exits, "[^,]+") do
    if elro.norm(raw) == dir then return true end
  end
  return false
end

-- ---- non-compass exit glyphs ----
-- The server's `exits` field carries non-compass exits too; the engine cannot draw them, so
-- record them on the room (userdata "xspec") and show a one-character glyph.
if elro.glyphs == nil then elro.glyphs = true end
-- also count Mudlet's special exits (source 3 in room_nonstd, built from the
-- unreliable hook dir); `mapglyphs auto off` narrows to advertised + recorded
if elro.glyphAuto == nil then elro.glyphAuto = true end

-- the non-compass entries of an advertised exit list, sorted, deduped
function elro.nonstd_exits(exits)
  local seen, out = {}, {}
  if not exits or exits == "" or exits == "none" then return out end
  for raw in string.gmatch(exits, "[^,]+") do
    local d = string.lower((string.gsub(raw, "^%s*(.-)%s*$", "%1")))
    if d ~= "" and not elro.dirNum[elro.norm(d)] and not seen[d] then
      seen[d] = true ; out[#out + 1] = d
    end
  end
  table.sort(out)
  return out
end

-- one character for a set of non-compass exit names: the shared initial when
-- they agree (enter -> E, out -> O), otherwise "*" for "several kinds".
function elro.glyph_for(names)
  if not names or #names == 0 then return "" end
  local c = string.upper(string.sub(names[1], 1, 1))
  if not string.match(c, "^%a$") then return "*" end
  for i = 2, #names do
    if string.upper(string.sub(names[i], 1, 1)) ~= c then return "*" end
  end
  return c
end

-- paint (or clear) the room char; setRoomCharColor is guarded (newer API).
-- The glyph and the terrain dot are both centred, so a room with both carries
-- the terrain colour ON the glyph and highlight_paint suppresses the dot.
function elro.glyph_paint(id, ch)
  if type(setRoomChar) ~= "function" then return end
  pcall(setRoomChar, id, ch or "")
  if ch and ch ~= "" and type(setRoomCharColor) == "function" then
    local col
    if elro.terrainOn then
      local _, dot = elro.terrain_roles(getRoomUserData(id, "terr"))
      if dot then col = dot.col end
    end
    col = col or (elro.classColours and elro.classColours.glyph) or { 255, 210, 90 }
    pcall(setRoomCharColor, id, col[1], col[2], col[3])
  end
end

-- Does this room currently show a glyph? Read from Mudlet when it can answer (one
-- C call), else recomputed -- which is correct but walks the room's exit sources, so
-- it is the fallback rather than the path.
function elro.has_glyph(id)
  if not elro.glyphs then return false end
  if type(getRoomChar) == "function" then
    local c = getRoomChar(id)
    return c ~= nil and c ~= ""
  end
  return elro.glyph_for(elro.room_nonstd(id)) ~= ""
end

-- Filler words skipped before the real direction ("go north" is a compass move).
-- Only words that are never a movement on their own ("climb" is not one).
elro.filler_verbs = {
  go = true, walk = true, move = true, run = true, head = true, travel = true,
  ["to"] = true, ["the"] = true,
}

-- Whitelist for the auto special exit: the non-compass members of DIR_VERBS in
-- mapreg_d.c (anything else on that path is movement-message prose). KEEP IN
-- SYNC with the server list.
elro.hook_verbs = { enter = true, exit = true, out = true, ["in"] = true }

-- The verb worth showing for a recorded edge command. The stored value may be
-- SEVERAL commands joined by SDELIM ("open gate" ;; "enter gate"); the LAST one
-- is the step that actually moves you, so its verb is the one that counts --
-- the leading commands are just the gate being opened.
function elro.cmd_verb(cmd)
  if type(cmd) ~= "string" then return nil end
  local a = 1
  while true do
    local i = string.find(cmd, elro.SDELIM, a, true)
    if not i then break end
    a = i + #elro.SDELIM
  end
  for w in string.gmatch(string.lower(string.sub(cmd, a)), "%S+") do
    -- prose arrives punctuated ("west," "northwards,"); a typed command does
    -- not, so stripping it costs nothing and lets the compass filter see `west`.
    w = string.gsub(w, "%p+$", "")
    if w ~= "" and not elro.filler_verbs[w] then return w end
  end
  return nil
end

-- roomId -> set of verbs, built from elro.smap (our own build-independent
-- record). Cached; invalidated wherever smap is written.
function elro.smap_index()
  local idx = elro._smapIdx
  if idx then return idx end
  if elro.smap == nil then elro.load_smap() end
  idx = {}
  for k, v in pairs(elro.smap or {}) do
    local from = tonumber(string.match(k, "^(%d+):"))
    local verb = elro.cmd_verb(v)
    if from and verb then
      idx[from] = idx[from] or {}
      idx[from][verb] = true
    end
  end
  elro._smapIdx = idx
  return idx
end

function elro.smap_index_dirty() elro._smapIdx = nil end

-- Every known non-compass way out of a room, unioned from three sources:
--   1. `xspec` (server-advertised list), 2. `elro.smap` (maprecordmove edges),
--   3. Mudlet's special exits (from the unreliable hook dir; gated by glyphAuto).
-- Source 3's table shape is version-dependent (dest->cmd, cmd->dest, or
-- dest->{[cmd]=lockflag}), so every string on either side is a candidate.
-- Returns sorted names and a name -> source letter map ("a"/"r"/"s").
function elro.room_nonstd(id)
  local src, out = {}, {}
  -- must start with a letter: source 3 also yields 4.x's lock flag "0"
  local function add(v, s)
    if v and string.match(v, "^%a") and not src[v] then
      src[v] = s ; out[#out + 1] = v
    end
  end
  for _, d in ipairs(elro.nonstd_exits(getRoomUserData(id, "xspec") or "")) do add(d, "a") end
  for v in pairs(elro.smap_index()[id] or {}) do add(v, "r") end
  if elro.glyphAuto and type(getSpecialExits) == "function" then
    -- only source 3 is whitelisted; sources 1 and 2 take any name
    local function auto(v) if v and elro.hook_verbs[v] then add(v, "s") end end
    local ok, t = pcall(getSpecialExits, id)
    if ok and type(t) == "table" then
      for k, v in pairs(t) do
        if type(k) == "string" then auto(elro.cmd_verb(k)) end
        if type(v) == "string" then auto(elro.cmd_verb(v))
        elseif type(v) == "table" then
          for k2, v2 in pairs(v) do
            if type(k2) == "string" then auto(elro.cmd_verb(k2)) end
            if type(v2) == "string" then auto(elro.cmd_verb(v2)) end
          end
        end
      end
    end
  end
  -- compass filter, last so it covers every source: a hidden `north` is not a portal
  local keep, ksrc = {}, {}
  for _, v in ipairs(out) do
    if not elro.dirNum[elro.norm(v)] then keep[#keep + 1] = v ; ksrc[v] = src[v] end
  end
  table.sort(keep)
  return keep, ksrc
end

-- refresh one room's glyph from what we currently know about it
function elro.glyph_room(id)
  elro.glyph_paint(id, elro.glyph_char(id))
end

-- mapreg_d._clean() caps every !MAP field at 64 chars; the eight compass names
-- alone are 60, so a busy room's exit list arrives with its tail chopped.
elro.EXITS_CAP = 64

-- onRoom hook: store the advertised non-compass exits and repaint. An absent
-- list means "no info", never "no exits". A list at the cap is also no info
-- about its tail: drop the trailing entry and UNION with what is stored.
function elro.note_nonstd(id, exits)
  if not exits or exits == "" or exits == "none" then return end
  local stored = getRoomUserData(id, "xspec") or ""
  local joined
  if #exits >= elro.EXITS_CAP - 1 then
    -- suspect: keep only whole entries, then merge rather than replace
    local head = string.match(exits, "^(.*),[^,]*$") or ""
    local seen, merged = {}, {}
    for _, v in ipairs(elro.nonstd_exits(head)) do
      if not seen[v] then seen[v] = true ; merged[#merged + 1] = v end
    end
    for _, v in ipairs(elro.nonstd_exits(stored)) do
      if not seen[v] then seen[v] = true ; merged[#merged + 1] = v end
    end
    table.sort(merged)
    joined = table.concat(merged, ",")
  else
    joined = table.concat(elro.nonstd_exits(exits), ",")
  end
  if joined ~= stored then setRoomUserData(id, "xspec", joined) end
  -- repaint from the union of all sources, never from `joined` alone
  elro.glyph_room(id)
end

-- mapglyphs list: every glyphed room, its exit names and their sources, least
-- trustworthy source first. Never paints.
function elro.glyph_list()
  local nm = elro.cs_areas_swap()
  local rows, bysrc = {}, { a = 0, r = 0, s = 0 }
  for id in pairs(elro.cs_all_rooms()) do
    local names, src = elro.room_nonstd(id)
    if #names > 0 then
      local parts, worst = {}, "a"
      for _, v in ipairs(names) do
        local s = src[v] or "?"
        parts[#parts + 1] = v .. "(" .. s .. ")"
        bysrc[s] = (bysrc[s] or 0) + 1
        if s == "s" then worst = "s" elseif s == "r" and worst ~= "s" then worst = "r" end
      end
      rows[#rows + 1] = { id = id, ch = elro.glyph_char(id, nil, names), worst = worst,
                          txt = table.concat(parts, ", ") }
    end
  end
  table.sort(rows, function(x, y)
    if x.worst ~= y.worst then return x.worst > y.worst end   -- s, then r, then a
    return x.id < y.id
  end)
  cecho(string.format("\n<cyan>[elro] glyphed rooms (%d) -- source: a=advertised, r=recorded, s=auto special%s<reset>\n",
        #rows, elro.glyphAuto and "" or "  [auto OFF]"))
  for _, r in ipairs(rows) do
    cecho(string.format("  <yellow>%s<reset> %6d  %-28s %s\n", r.ch, r.id,
          string.sub(getRoomName(r.id) or "?", 1, 28), r.txt))
  end
  if #rows == 0 then cecho("  (none)\n") end
  cecho(string.format("<cyan>  exits by source: advertised %d, recorded %d, auto special %d<reset>\n",
        bysrc.a or 0, bysrc.r or 0, bysrc.s or 0))
end

-- mapglyphs [on|off|list|auto on|off]: toggle the glyphs and repaint the whole
-- map either way. A bare call repaints (and reports), which is also the backfill
-- for rooms mapped before xspec existed.
function elro.cmd_glyphs(arg)
  arg = arg and string.lower((string.gsub(arg, "^%s*(.-)%s*$", "%1"))) or ""
  if arg == "list" then elro.glyph_list() ; return end
  if arg == "on" then elro.glyphs = true
  elseif arg == "off" then elro.glyphs = false
  elseif arg == "auto on" then elro.glyphAuto = true
  elseif arg == "auto off" then elro.glyphAuto = false
  elseif arg ~= "" then
    cecho("\n<yellow>[elro]: usage: mapglyphs [on|off|list|auto on|auto off]\n<reset>") ; return
  end
  if type(setRoomChar) ~= "function" then
    cecho("\n<red>[elro]: this Mudlet build has no setRoomChar; glyphs unavailable.\n<reset>")
    return
  end
  local n = 0
  for id in pairs(elro.cs_all_rooms()) do
    local ch = elro.glyph_char(id)
    if ch ~= "" then n = n + 1 end
    elro.glyph_paint(id, ch)
  end
  if type(updateMap) == "function" then pcall(updateMap) end
  cecho(string.format("\n<green>[elro]: glyphs %s (auto special exits %s) -- %d room(s) glyphed.\n<reset>",
        elro.glyphs and "on" or "off", elro.glyphAuto and "on" or "off", n))
end

-- ==== TERRAIN COLOURING ====
-- The server sends the room's terrain properties as the !MAP `terr` field. Stored raw as
-- room user data; every colour is derived from it on repaint.

if elro.terrainOn == nil then elro.terrainOn = true end

-- highlightRoom's alpha order is (rim, centre), contrary to the onEdgeHi* knob
-- names. A two-stop gradient cannot cut a clean hole, so the secondary mark is a
-- small flat dot: equal alphas.
elro.terrainHalo    = elro.terrainHalo    or 0.3    -- radius, room widths
elro.terrainHaloOut = elro.terrainHaloOut or 255    -- rim alpha
elro.terrainHaloIn  = elro.terrainHaloIn  or 255    -- centre alpha (== rim: flat disc)

-- rank: lower wins (tunable). env: Mudlet custom-env id, stable and never
-- reused (it is stored in the map file; renumbering repaints old rooms in the
-- wrong colour). group: the secondary dot is only drawn for a different group.
-- Ladder: aid > travel > sacred > way > water body > landform > built >
-- surface underfoot > water touching the room > maze > indoors/outdoors.
elro.terrain = {
  -- not terrain, but the most useful marks on a map: where you can heal, and
  -- where a shop will BUY the loot you are carrying
  heal          = { rank =  1, env = 935, group = "aid",    col = { 255,  95, 140 } },
  -- lime, NOT gold: `indoors` is a fallback and so never becomes the dot, which
  -- means a shop room paints its whole CELL -- next to the apricot indoors cells
  -- of every other building in the town. Gold was unreadable there.
  shop          = { rank =  2, env = 936, group = "aid",    col = { 150, 245,  60 } },
  -- the transport system. Its own group: a port is often also a road or a
  -- waterside, and that is exactly the pairing worth seeing twice.
  transport     = { rank =  3, env = 937, group = "travel", col = { 195, 110, 255 } },
  port          = { rank =  4, env = 938, group = "travel", col = {  90, 230, 210 } },
  -- sacred: not terrain, but the marker most worth seeing at a glance
  holy          = { rank =  5, env = 901, group = "sacred", col = { 225, 215, 245 } },
  unholy        = { rank =  6, env = 902, group = "sacred", col = { 120,  45,  85 } },
  -- ways: what you navigate BY, so they outrank the ground they cross
  road          = { rank =  7, env = 903, group = "way",    col = { 125,  85,  48 } },
  track         = { rank =  8, env = 904, group = "way",    col = {  92,  64,  38 } },
  bridge        = { rank =  9, env = 905, group = "way",    col = { 150, 118,  88 } },
  -- water bodies: the room IS water
  sea           = { rank = 10, env = 906, group = "water",  col = {  30,  80, 180 } },
  waterfilled   = { rank = 11, env = 907, group = "water",  col = {  35,  95, 190 } },
  lake          = { rank = 12, env = 908, group = "water",  col = {  45, 115, 200 } },
  river         = { rank = 13, env = 909, group = "water",  col = {  55, 135, 215 } },
  -- landform
  cave          = { rank = 14, env = 910, group = "land",   col = {  48,  44,  50 } },
  underground   = { rank = 15, env = 911, group = "land",   col = {  68,  62,  58 } },
  mountain      = { rank = 16, env = 912, group = "land",   col = { 132, 126, 128 } },
  cliffs        = { rank = 17, env = 913, group = "land",   col = { 110, 104, 116 } },
  swamp         = { rank = 18, env = 914, group = "land",   col = {  85, 100,  55 } },
  jungle        = { rank = 19, env = 915, group = "land",   col = {  25,  95,  45 } },
  forest        = { rank = 20, env = 916, group = "land",   col = {  40, 115,  60 } },
  desert        = { rank = 21, env = 917, group = "land",   col = { 215, 190, 120 } },
  hills         = { rank = 22, env = 918, group = "land",   col = { 150, 135,  85 } },
  beach         = { rank = 23, env = 919, group = "land",   col = { 230, 215, 165 } },
  meadow        = { rank = 24, env = 920, group = "land",   col = { 140, 180,  95 } },
  plain         = { rank = 25, env = 921, group = "land",   col = { 165, 190, 110 } },
  -- built + tended
  urban         = { rank = 26, env = 922, group = "built",  col = { 120, 115, 125 } },
  square        = { rank = 27, env = 923, group = "built",  col = { 165, 160, 165 } },
  garden        = { rank = 28, env = 924, group = "built",  col = {  90, 175,  85 } },
  cultivated    = { rank = 29, env = 925, group = "built",  col = { 170, 155,  80 } },
  -- surface underfoot
  ice           = { rank = 30, env = 926, group = "surf",   col = { 190, 225, 240 } },
  snow          = { rank = 31, env = 927, group = "surf",   col = { 235, 240, 245 } },
  mud           = { rank = 32, env = 928, group = "surf",   col = { 115,  92,  70 } },
  sand          = { rank = 33, env = 929, group = "surf",   col = { 225, 205, 145 } },
  grass         = { rank = 34, env = 930, group = "surf",   col = { 120, 165,  80 } },
  -- water touching the room rather than filling it; same group as the bodies
  water         = { rank = 35, env = 931, group = "water",  col = {  70, 140, 210 } },
  waterside     = { rank = 36, env = 932, group = "water",  col = { 100, 170, 215 } },
  -- A server-folded maze, which arrives as `terr=maze` alone; the violet is
  -- elro.classColours.maze. Rank only has to clear the fallbacks.
  maze          = { rank = 37, env = 939, group = "maze",   col = { 150,  40, 200 } },
  -- fallbacks, never a secondary; outdoors is the most common colour on the map
  indoors       = { rank = 38, env = 933, group = "fallback", col = { 245, 165,  85 } },
  outdoors      = { rank = 39, env = 934, group = "fallback", col = { 105, 115, 100 } },
}

-- Sentinel for "reported, no terrain": getRoomUserData returns "" for both
-- never-set and set-empty, and "never heard from" must stay distinguishable.
elro.TERR_NONE = "-"

-- ⭐ THESE TERRAINS TAKE THE DOT AND GIVE UP THE GLYPH. The two are both centred,
-- so a room with both puts the mark's colour ON the glyph and drops the dot (see
-- glyph_paint) -- and every transport room and every port HAS a glyph, because
-- boarding one is always an exit you type. So the whole travel group was reading
-- as faintly tinted E's, the one case where the tint is not enough. A distinct
-- character would have fixed it too, but the anchor renders as tofu in the map
-- font, so the room gives up its exit letter instead and keeps the flat dot,
-- which needs no font at all. The exit letter is the smaller loss: that a port
-- has something to board is the least surprising fact about it.
elro.terrainDotOnly = elro.terrainDotOnly or { transport = true, port = true }

-- Does this `terr` csv carry a terrain that wants the dot rather than the glyph?
-- Any of them is enough -- the point is to clear the room character, whichever of
-- them ends up as the mark.
function elro.terrain_dot_only(csv)
  if not csv or csv == "" or not elro.terrainOn then return false end
  for name in string.gmatch(csv, "[^,]+") do
    if elro.terrainDotOnly[name] then return true end
  end
  return false
end

-- Is this `terr` csv a folded maze?
function elro.is_maze_terr(csv)
  if not csv or csv == "" then return false end
  for name in string.gmatch(csv, "[^,]+") do
    if (elro.terrainAlias[name] or name) == "maze" then return true end
  end
  return false
end

-- The character a room should show: none at all where a terrain wants the dot,
-- else the letter its non-compass exits give it. `csv` and `names` may be passed
-- by a caller that already has them, to save the userdata read / the exit walk.
function elro.glyph_char(id, csv, names)
  if not elro.glyphs then return "" end
  if csv == nil then csv = getRoomUserData(id, "terr") end
  -- A folded maze always shows "?": it arrives with no exits, so glyph_for
  -- has nothing to derive a letter from.
  if elro.is_maze_terr(csv) then return "?" end
  if elro.terrain_dot_only(csv) then return "" end
  return elro.glyph_for(names or elro.room_nonstd(id))
end

-- Terrain names the server used to send, mapped to what it sends now, so rooms
-- stored before the rename keep their colour.
elro.terrainAlias = {
  healing_place = "heal", shop_allows_sell = "shop",
  holy_ground   = "holy", unholy_ground    = "unholy",
}

-- Register the palette with Mudlet. Cheap (one call per terrain) and idempotent,
-- so it runs on every module load rather than being trusted to the map file.
function elro.terrain_env_init()
  if type(setCustomEnvColor) ~= "function" then return end
  for _, t in pairs(elro.terrain) do
    pcall(setCustomEnvColor, t.env, t.col[1], t.col[2], t.col[3], 255)
  end
end

-- The primary and secondary terrain of a `terr` csv, as (entry, entry, name,
-- name). A room that reported nothing colourable is `outdoors`; only a room
-- never heard from (csv unset) is left uncoloured.
function elro.terrain_pick(csv)
  if not csv or csv == "" then return nil, nil end
  local T, A = elro.terrain, elro.terrainAlias
  local best, bname
  for name in string.gmatch(csv, "[^,]+") do
    name = A[name] or name
    local t = T[name]
    if t and (not best or t.rank < best.rank) then best, bname = t, name end
  end
  if not best then return T.outdoors, nil, "outdoors", nil end
  -- a room whose best is only indoors/outdoors has nothing to say twice
  if best.group == "fallback" then return best, nil, bname, nil end
  local sec, sname
  for name in string.gmatch(csv, "[^,]+") do
    name = A[name] or name
    local t = T[name]
    if t and t.group ~= best.group and t.group ~= "fallback"
       and (not sec or t.rank < sec.rank) then sec, sname = t, name end
  end
  return best, sec, bname, sname
end

-- Which entry paints the CELL and which the DOT, as (cell, dot, name, name).
-- Deliberately the higher-priority terrain is the dot (features rank above
-- bodies: a road through a forest is a green cell with a brown mark). A room
-- with one terrain puts it in the cell.
function elro.terrain_roles(csv)
  local pri, sec, pn, sn = elro.terrain_pick(csv)
  if not pri then return nil, nil end
  if not sec then return pri, nil, pn, nil end
  return sec, pri, sn, pn
end

-- The one highlight slot; the only place that may call highlightRoom.
-- Priority: occluded (yellow) > maze (violet) > terrain dot. Each source is
-- read from persistent userdata (occl / fold / terr) so a repaint after a
-- restart reproduces the screen.
function elro.highlight_paint(id)
  if type(highlightRoom) ~= "function" or not roomExists(id) then return end
  -- aOut is the RIM alpha and aIn the CENTRE (highlightRoom's real order). The
  -- occluded and maze values are passed through unchanged on purpose.
  local col, rad, aOut, aIn
  if getRoomUserData(id, "occl") == "1" then
    col = (elro.classColours and elro.classColours.occluded) or { 255, 210, 0 }
    rad = elro.onEdgeHiRadius or 0.6
    aOut, aIn = elro.onEdgeHiFill or 25, elro.onEdgeHiEdge or 255
  elseif elro.is_maze_area(getRoomUserData(id, "fold")) then
    col = (elro.classColours and elro.classColours.maze) or { 150, 40, 200 }
    rad, aOut, aIn = 1, 200, 50
  elseif elro.terrainOn then
    local _, dot = elro.terrain_roles(getRoomUserData(id, "terr"))
    -- not on a glyphed room: the dot would hide the glyph (see glyph_paint)
    if dot and not elro.has_glyph(id) then
      col = dot.col
      rad, aOut, aIn = elro.terrainHalo, elro.terrainHaloOut, elro.terrainHaloIn
    end
  end
  if not col then
    if type(unHighlightRoom) == "function" then pcall(unHighlightRoom, id) end
    return
  end
  pcall(highlightRoom, id, col[1], col[2], col[3], col[1], col[2], col[3], rad, aOut, aIn)
end

-- Paint one room from its stored terrain: env colour for the primary, the shared
-- highlight slot for the secondary. `csv` may be passed by a caller that already
-- has it (onRoom) to save the userdata read.
function elro.terrain_paint(id, csv)
  if not roomExists(id) then return end
  -- A fresh install misses both boot paths (sysLoadEvent has fired, the map is
  -- empty), so the first painted room registers the palette.
  if not elro._envInit then elro._envInit = true ; elro.terrain_env_init() end
  if csv == nil then csv = getRoomUserData(id, "terr") end
  local cell = elro.terrain_roles(csv)
  if type(setRoomEnv) == "function" then
    local want = (elro.terrainOn and cell) and cell.env or 0
    local cur = type(getRoomEnv) == "function" and getRoomEnv(id) or nil
    -- env 0 = Mudlet's default; only written when it changes
    if cur ~= want and (want ~= 0 or cur ~= nil) then pcall(setRoomEnv, id, want) end
  end
  -- The glyph doubles as the mark on rooms that have one, so a terrain change has
  -- to re-tint it; elro.glyph_paint re-reads the mark itself, we only supply the
  -- character it is already showing. A terrain that wants the DOT clears that
  -- character here, which is what lets highlight_paint draw one.
  if type(getRoomChar) == "function" then
    local ch = getRoomChar(id)
    -- The maze "?" is the one glyph this function CREATES rather than
    -- re-tints: note_nonstd never runs for a maze node.
    if elro.is_maze_terr(csv) then
      elro.glyph_paint(id, elro.glyphs and "?" or "")
    elseif ch and ch ~= "" then
      elro.glyph_paint(id, elro.terrain_dot_only(csv) and "" or ch)
    end
  end
  elro.highlight_paint(id)
end

-- Repaint a set of rooms (any table KEYED by room id), or the whole map when
-- given nothing. Returns the number of rooms that carried terrain.
function elro.terrain_repaint(scope)
  local n = 0
  for id in pairs(scope or elro.cs_all_rooms()) do
    if roomExists(id) then
      local csv = getRoomUserData(id, "terr")
      if csv and csv ~= "" then n = n + 1 end
      elro.terrain_paint(id, csv)
    end
  end
  return n
end

-- What the map currently knows, by terrain, most-used first.
function elro.terrain_list()
  local pri, sec, none, known = {}, {}, 0, 0
  for id in pairs(elro.cs_all_rooms()) do
    if roomExists(id) then
      local c, d, cn, dn = elro.terrain_roles(getRoomUserData(id, "terr"))
      if c then
        known = known + 1
        pri[cn] = (pri[cn] or 0) + 1
        if d then sec[dn] = (sec[dn] or 0) + 1 end
      else
        none = none + 1
      end
    end
  end
  local rows = {}
  for name, t in pairs(elro.terrain) do
    if pri[name] or sec[name] then
      rows[#rows + 1] = { name = name, t = t, p = pri[name] or 0, s = sec[name] or 0 }
    end
  end
  table.sort(rows, function(x, y)
    if x.t.rank ~= y.t.rank then return x.t.rank < y.t.rank end
    return x.name < y.name
  end)
  cecho(string.format("\n<cyan>[elro] terrain: %d room(s) coloured, %d with none yet%s<reset>\n",
        known, none, elro.terrainOn and "" or "   [terrain OFF]"))
  cecho("  <white>rank group     terrain           cell  dot<reset>\n")
  for _, r in ipairs(rows) do
    local c = r.t.col
    -- the terrain's own colour as the swatch, so the list doubles as the palette.
    -- decho: cecho knows named colours only and prints a hex tag as text.
    decho(string.format("  %4d %-9s <%d,%d,%d>%-14s<r> %7d %4d\n",
          r.t.rank, r.t.group, c[1], c[2], c[3], r.name, r.p, r.s))
  end
  if #rows == 0 then cecho("  (nothing yet -- walk around, or check the server sends |terr=)\n") end
end

-- maplegend: every terrain in its own colour with what it means, then how to read the rest
-- of the drawing. Rows come from elro.terrain, so the legend cannot drift from the painter;
-- only the wording lives here, and a terrain without wording still shows by name.
-- How wide help may be: the wrap column (Mudlet's default is 100, which the layouts are made
-- for), or the columns the window actually shows if that is fewer, since Mudlet cuts a line
-- off at the window's edge rather than wrapping it there. 80 where Mudlet cannot say.
function elro.help_width()
  local ok, w = pcall(function() return getWindowWrap("main") end)
  if not ok or type(w) ~= "number" or w < 40 then w = 80 end
  local ok2, c = pcall(function() return getColumnCount("main") end)
  if ok2 and type(c) == "number" and c >= 40 and c < w then w = c end
  return w
end

-- Plain text into lines of at most `width`, broken at spaces. A word longer than a line
-- stays whole.
function elro.wrap_text(text, width)
  local lines, cur = {}, ""
  for word in tostring(text):gmatch("%S+") do
    if cur == "" then cur = word
    elseif #cur + 1 + #word <= width then cur = cur .. " " .. word
    else lines[#lines + 1] = cur ; cur = word end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  return lines
end

-- Two columns of groups, set side by side; the split is by hand so the columns end level.
local LEGEND_COLS = {
  { { "aid", "WORTH FINDING" }, { "travel", "TRAVEL" }, { "sacred", "SACRED" },
    { "way", "WAYS" }, { "water", "WATER" }, { "built", "BUILT AND TENDED" } },
  { { "land", "LAND" }, { "surf", "UNDERFOOT" }, { "maze", "MAZES" },
    { "fallback", "EVERYTHING ELSE" } },
}
-- Made for 80 columns, the width NannyMUD itself is written for: two cells of at most 39.
-- So a meaning in LEGEND_TEXT may be 22 characters at most, and 21 in the left column.
local LEGEND_W = 40          -- where the right column starts
local LEGEND_TEXT = {
  heal = "a place to be healed",           shop = "buys and sells",
  transport = "a ship or a coach",         port = "where transport stops",
  holy = "holy ground",                    unholy = "unholy ground",
  road = "a road",  track = "a path or trail",  bridge = "a bridge",
  sea = "open sea",  waterfilled = "a room full of water",  lake = "a lake",  river = "a river",
  cave = "a cave",  underground = "underground",  mountain = "mountain",  cliffs = "cliffs",
  swamp = "swamp",  jungle = "jungle",  forest = "forest",  desert = "desert",  hills = "hills",
  beach = "a beach",  meadow = "meadow",  plain = "open plain",
  urban = "a town or city",  square = "a town square",  garden = "a garden",
  cultivated = "farmland",
  ice = "ice",  snow = "snow",  mud = "mud",  sand = "sand",  grass = "grass",
  water = "water in the room",  waterside = "beside water",
  maze = "a maze, as one spot",
  indoors = "indoors (no detail)",
  outdoors = "outdoors (no detail)",
}
function elro.map_legend()
  cecho("\n<cyan>ElrohirMapper  --  what the colours on the map mean<reset>\n\n")
  -- each column is a list of { markup, visible width }: decho tags take no room on screen
  local cols = {}
  for ci, groups in ipairs(LEGEND_COLS) do
    local lines = {}
    for _, g in ipairs(groups) do
      local rows = {}
      for name, t in pairs(elro.terrain) do
        if t.group == g[1] then rows[#rows + 1] = { name = name, t = t } end
      end
      table.sort(rows, function(x, y) return x.t.rank < y.t.rank end)
      if #rows > 0 then
        if #lines > 0 then lines[#lines + 1] = { "", 0 } end
        lines[#lines + 1] = { "<0,255,255>" .. g[2] .. "<r>", #g[2] }
      end
      for _, r in ipairs(rows) do
        local c, text = r.t.col, LEGEND_TEXT[r.name] or ""
        -- the name sits ON its colour; dark text on a light swatch, light on a dark one
        local fg = (c[1] * 299 + c[2] * 587 + c[3] * 114) / 1000 > 140 and "0,0,0" or "255,255,255"
        lines[#lines + 1] = {
          string.format("  <%s:%d,%d,%d> %-11s <r>  %s", fg, c[1], c[2], c[3], r.name, text),
          2 + 13 + 2 + #text }
      end
    end
    cols[ci] = lines
  end
  local width = elro.help_width()
  if width >= 80 then
    for i = 1, math.max(#cols[1], #cols[2]) do
      local l, r = cols[1][i] or { "", 0 }, cols[2][i]
      decho(l[1] .. (r and (string.rep(" ", math.max(2, LEGEND_W - l[2])) .. r[1]) or "") .. "\n")
    end
  else                                        -- a narrow window: one column, one after the other
    for ci, lines in ipairs(cols) do
      if ci > 1 then decho("\n") end
      for _, l in ipairs(lines) do decho(l[1] .. "\n") end
    end
  end
  local function para(text)
    for _, l in ipairs(elro.wrap_text(text, width - 3)) do cecho("  " .. l .. "\n") end
  end
  cecho("\n<cyan>READING A ROOM<reset>\n")
  para("The room's colour is the most telling thing known about it: a road through a forest "
    .. "is drawn as a road. A dot in the middle is a second thing worth knowing, such as a "
    .. "healer's dot on a town room. A letter is an exit you type instead of a direction "
    .. "(E for enter, * for several kinds); ports and transport show their dot instead.")
  cecho("\n<cyan>READING THE LINES<reset>\n")
  local function line(c, text)
    for i, l in ipairs(elro.wrap_text(text, width - 10)) do
      decho(i == 1 and string.format("  <%d,%d,%d>-----<r>  %s\n", c[1], c[2], c[3], l)
                    or ("         " .. l .. "\n"))
    end
  end
  local cc = elro.classColours or {}
  line({ 80, 160, 255 }, "a short stub: this exit leads onto another map (violet: into a maze)")
  line(cc.vertical or { 0, 210, 190 },  "an up or down exit, drawn slanted between two floors")
  line(cc.demoted  or { 255, 60, 220 }, "an exit the mapper does not believe: the two rooms disagree about it")
  line(cc.residual or { 255, 60, 60 },  "an exit it believes but could not draw in its true direction")
  line(cc.occluded or { 255, 210, 0 },  "a true exit with another room sitting on top of it")
  para("A plain short stub is an exit you have not walked yet.")
  cecho("\n")
  para("'mapterrain off' removes the colours, 'mapglyphs off' the letters.")
  cecho("\n")
end

-- mapterrain halo [<radius> [<rim> [<centre>]]]: set the secondary-terrain ring and
-- repaint in one step; bare `halo` reports the current values. The radius
-- multiplies the room width (0.5 = about one cell across).
function elro.terrain_halo(arg)
  local r, o, i = string.match(arg or "", "^([%d%.]*)%s*(%d*)%s*(%d*)$")
  if r and r ~= "" then elro.terrainHalo    = tonumber(r) or elro.terrainHalo end
  if o and o ~= "" then elro.terrainHaloOut = tonumber(o) or elro.terrainHaloOut end
  if i and i ~= "" then elro.terrainHaloIn  = tonumber(i) or elro.terrainHaloIn end
  if (r == "" or r == nil) and (o == "" or o == nil) and (i == "" or i == nil) then
    cecho(string.format(
      "\n<cyan>[elro] terrain halo:<reset> radius %s  rim alpha %s  centre alpha %s\n" ..
      "  <yellow>mapterrain halo <radius> [rim] [centre]<reset>  e.g. 0.8 255 0\n" ..
      "  radius multiplies the ROOM WIDTH: 0.5 ~ one cell across, 1.0 ~ two cells.\n" ..
      "  rim is where the colour lives; centre is what you see the room through.\n" ..
      "  wider radius = fainter wash over the room, but the ring drifts outward.\n",
      tostring(elro.terrainHalo), tostring(elro.terrainHaloOut),
      tostring(elro.terrainHaloIn)))
    return
  end
  elro.terrain_repaint()
  if type(updateMap) == "function" then pcall(updateMap) end
  cecho(string.format(
    "\n<green>[elro]: terrain halo -- radius %s, rim alpha %s, centre alpha %s. Repainted.\n<reset>",
    tostring(elro.terrainHalo), tostring(elro.terrainHaloOut), tostring(elro.terrainHaloIn)))
end

-- mapterrain here: what the map actually STORED for the room you are standing in,
-- and what that resolved to (separates "server did not send it" from "we did
-- not colour it").
function elro.terrain_here()
  local id = elro.current
  if not id or not roomExists(id) then
    cecho("\n<yellow>[elro]: no current room.\n<reset>") ; return
  end
  local raw = getRoomUserData(id, "terr")
  local cell, dot, cn, dn = elro.terrain_roles(raw)
  cecho(string.format("\n<cyan>[elro] terrain for room %d -- %s<reset>\n",
        id, getRoomName(id) or "?"))
  if not raw or raw == "" then
    cecho("  <yellow>raw:      (nothing stored)<reset> -- this room has not been entered\n" ..
          "            since the server started sending |terr=. Walk into it again.\n")
  elseif raw == elro.TERR_NONE then
    cecho("  raw:      <yellow>(the server reported NO terrain properties)<reset>\n")
  else
    cecho("  raw:      " .. raw .. "\n")
    local un = {}
    for name in string.gmatch(raw, "[^,]+") do
      if not elro.terrain[elro.terrainAlias[name] or name] then un[#un + 1] = name end
    end
    if #un > 0 then
      cecho("  <yellow>not coloured:<reset> " .. table.concat(un, ", ") ..
            "   (arriving, but no entry in elro.terrain)\n")
    end
  end
  local function show(what, t, name)
    if not t then cecho(string.format("  %-9s (none)\n", what .. ":")) return end
    local c = t.col
    decho(string.format("  %-9s <%d,%d,%d>%s<r>   rank %d  group %s  env %d  rgb(%d,%d,%d)\n",
          what .. ":", c[1], c[2], c[3], name, t.rank, t.group, t.env, c[1], c[2], c[3]))
  end
  show("cell", cell, cn)
  show("dot", dot, dn)
  -- ...and who won the single highlight slot
  local why = "the terrain mark"
  if getRoomUserData(id, "occl") == "1" then
    why = "<yellow>the occluded ring<reset> -- outranks terrain"
  elseif elro.is_maze_area(getRoomUserData(id, "fold")) then
    why = "<yellow>the maze marker<reset> -- outranks terrain"
  elseif not elro.terrainOn then
    why = "<yellow>nothing: mapterrain is OFF<reset>"
  elseif not dot then
    why = "nothing (one terrain only -- it is the cell)"
  end
  cecho("  slot:     " .. why .. "\n")
end

-- mapterrain [on|off|list]: bare = repaint everything from stored `terr` (also
-- the backfill after a restart, and after a mapreload). on/off repaint too, so
-- the toggle is immediately visible.
function elro.cmd_terrain(arg)
  arg = arg and string.lower((string.gsub(arg, "^%s*(.-)%s*$", "%1"))) or ""
  if arg == "list" then elro.terrain_list() ; return end
  if arg == "here" then elro.terrain_here() ; return end
  local halo = string.match(arg, "^halo%s*(.*)$")
  if halo then elro.terrain_halo(halo) ; return end
  if arg == "on" then elro.terrainOn = true
  elseif arg == "off" then elro.terrainOn = false
  elseif arg ~= "" then
    cecho("\n<yellow>[elro]: usage: mapterrain [on|off|list|here|halo <radius> [rim] [centre]]\n<reset>") ; return
  end
  if type(setRoomEnv) ~= "function" then
    cecho("\n<red>[elro]: this Mudlet build has no setRoomEnv; terrain colours unavailable.\n<reset>")
    return
  end
  elro.terrain_env_init()
  local n = elro.terrain_repaint()
  if type(updateMap) == "function" then pcall(updateMap) end
  cecho(string.format("\n<green>[elro]: terrain colours %s -- repainted, %d room(s) with known terrain.\n<reset>",
        elro.terrainOn and "on" or "off", n))
end

-- Backfill after a restart: Mudlet loads the map before sysLoadEvent fires. The
-- immediate call below covers `mapreload`; running it twice is free.
function elro.terrain_boot()
  elro.terrain_env_init()
  if type(getRooms) ~= "function" or type(setRoomEnv) ~= "function" then return end
  elro.terrain_repaint()
  if type(updateMap) == "function" then pcall(updateMap) end
end

-- Type-guarded: core.lua is also loaded by the offline harness with a stub set.
if type(registerAnonymousEventHandler) == "function" then
  if elro._terrHandler and type(killAnonymousEventHandler) == "function" then
    pcall(killAnonymousEventHandler, elro._terrHandler)
  end
  elro._terrHandler = registerAnonymousEventHandler("sysLoadEvent",
    function() elro.terrain_boot() end)
end
if type(getRooms) == "function" and next(getRooms() or {}) then elro.terrain_boot() end

-- Is the guess for `id` visibly wrong? Returns "lie" | "over-room", the dir and the other room.
-- `skip` is the edge we placed the room on: that one is truthful by construction, so the edges
-- worth checking are the ones the room turned out to ALSO have -- the loop closures, which are
-- right only by luck. Adds no relayout (one was queued by the graph change); only makes it
-- urgent. edge_truthful is the defect scanner's own predicate, so this cannot drift from it.
-- `only`: judge just the edge id -> only, for an edge walked between two rooms that were both
-- already placed. Nothing moved, so the rest of the room's edges and the on-edge scan are skipped.
function elro.guess_inconsistent(id, aid, skip, only)
  if elro.guessCheck == false then return nil end
  local rec = elro.cs_room(id) ; if not rec then return nil end
  if only and getRoomArea(id) ~= aid then return nil end
  local px, py = getRoomCoordinates(id) ; if not px then return nil end
  for d, x in elro.exits(rec.ex) do
    if x ~= skip and (not only or x == only) and x ~= id and roomExists(x) and getRoomArea(x) == aid then
      local de = elro.delta[d]
      if de and (de[1] ~= 0 or de[2] ~= 0) then
        local qx, qy = getRoomCoordinates(x)
        if qx then
          if not elro.edge_truthful(de, qx - px, qy - py) then return "lie", d, x end
          local hit
          elro.g.seg(px, py, qx, qy, function(cx, cy)
            if hit then return end
            local occ = elro.cell_at(aid, cx, cy)
            if occ and occ ~= id and occ ~= x then hit = occ end
          end)
          if hit then return "over-room", d, x end
        end
      end
    end
  end
  -- ...and the dual defect: this room landing ON an edge that is not its own. seg_hits is the
  -- point query for the same raster, so it agrees with the scanner cell for cell.
  --
  -- ⚠ THIS HALF IS O(rooms x exits) PER ARRIVAL, where everything above it is O(exits of the
  -- new room). It asks "is my cell on anyone's edge?" by walking every edge in the area, which
  -- is the whole cost of guess_inconsistent in a densely connected one. Its own knob so the two
  -- halves can be told apart in game -- `lua elro.guessOnEdge = false` keeps the cheap lie and
  -- over-room checks and drops only this scan. Diagnostic: fold it out once the answer is known,
  -- and the real fix is an edge-by-cell index rather than a re-scan (eqw.edge_index already
  -- builds exactly that shape for the solver).
  if only or elro.guessOnEdge == false then return nil end
  for _, r in ipairs(elro.cs_area_rooms(aid)) do
    local rr = r ~= id and elro.cs_room(r) or nil
    local ax, ay
    if rr then ax, ay = getRoomCoordinates(r) end   -- `and` here would truncate the pair
    if ax then
      for d, x in elro.exits(rr.ex) do
        if x ~= id and x ~= r and roomExists(x) and getRoomArea(x) == aid then
          local de = elro.delta[d]
          if de and (de[1] ~= 0 or de[2] ~= 0) then
            local bx, by = getRoomCoordinates(x)
            if bx and elro.g.seg_hits(ax, ay, bx, by, px, py) then return "on-edge", d, r end
          end
        end
      end
    end
  end
  return nil
end

-- Main entry from the !MAP trigger, and the c-space snapshot's invalidation
-- point. Every write is compared against the snapshot first (elro.cs_room) so
-- walking known territory invalidates nothing; a write that changes something
-- calls elro.cs_dirty, which forgets the record AND bumps the area version.
-- ---- exit stubs ------------------------------------------------------------
-- Mudlet draws a stub for an advertised exit we have not walked yet. Worth having
-- while mapping -- and expensive: T2DMap repaints the whole viewport every frame,
-- and where two linked rooms share ONE line segment, every stub is its own
-- geometry, transform and QPainter call. Measured on a 393-room 8-connected grid:
-- 1067 edges draw smoothly, the 1239 stubs beside them make the canvas sluggish
-- while standing still, and removing them fixes it instantly. Mudlet's own advice
-- is to keep them off except while actively exploring.
--
-- ⛔ SO THEY HAVE TO BE DERIVED DATA, and they were not. An advertised COMPASS
-- exit was stored nowhere -- `xspec` keeps only the non-compass ones -- so the
-- Mudlet stub WAS the record, and clearing stubs destroyed knowledge that only
-- re-walking could restore. `xcomp` now persists the advertised compass list per
-- room, which makes the stubs regenerable and the on/off toggle lossless.

if elro.exitStubs == nil then elro.exitStubs = true end   -- create them at all (knob)

-- direction number -> true, for the stubs a room currently carries.
-- ⚠ getExitStubs' shape is version-dependent like getSpecialExits (a list of
-- direction numbers, or a table keyed by them), so read both halves of every pair
-- and trust neither. Missing entirely -> an empty set.
function elro.stub_set(id)
  local out = {}
  if type(getExitStubs) ~= "function" then return out end
  local got, t = pcall(getExitStubs, id)
  if not got or type(t) ~= "table" then return out end
  for k, v in pairs(t) do
    local n = tonumber(v) or tonumber(k)
    if n and n >= 1 and n <= 12 then out[n] = true end
  end
  return out
end

-- ---- mapecho: do automatic redraws report? ---------------------------------
-- Persisted like stubsShown, and absent from elro.KNOBS for the same reason.
-- Default OFF: the reports are a developer's view of the solver, and a tester's
-- first complaint was that they scroll the game away.
function elro.load_mapecho()
  elro.mapecho_loaded = true
  if type(getMapUserData) ~= "function" then return end
  local ok, s = pcall(getMapUserData, "elro.mapEcho")
  if ok and type(s) == "string" and s ~= "" then elro.mapEcho = (s == "on") end
end

function elro.cmd_mapecho(arg)
  arg = string.lower((string.gsub(arg or "", "^%s*(.-)%s*$", "%1")))
  if arg == "on" or arg == "off" then
    elro.mapEcho = (arg == "on")
    if type(setMapUserData) == "function" then
      pcall(setMapUserData, "elro.mapEcho", arg)
    end
  elseif arg ~= "" then
    cecho("\n<yellow>[elro]: usage: mapecho [on|off]\n<reset>") ; return
  end
  cecho(string.format("\n<green>[elro]: relayouts %s.<reset>\n" ..
    "<cyan>  That goes for every relayout, the ones a command of yours starts too.\n<reset>",
    elro.mapEcho and "REPORT when they finish" or "are SILENT"))
end

-- ---- the persisted preference (global, like vertPack) ----------------------
-- Absent from elro.KNOBS on purpose: reset_knobs would forget a saved preference.
-- Default lives at the read site, so "never set" means ON.
function elro.load_stubshow()
  elro.stubshow_loaded = true
  if type(getMapUserData) ~= "function" then return end
  local ok, s = pcall(getMapUserData, "elro.stubsShown")
  if ok and type(s) == "string" and s ~= "" then elro.stubsShown = (s ~= "off") end
end

function elro.set_stubshow(on)
  elro.stubsShown = on and true or false
  if type(setMapUserData) == "function" then
    pcall(setMapUserData, "elro.stubsShown", on and "on" or "off")
  end
end

-- ---- the record: which compass exits a room ADVERTISES ---------------------
-- Comma-joined normalized names. Written by onRoom; the stubs are derived from it.
function elro.stub_advertised(id)
  local s = getRoomUserData(id, "xcomp") or ""
  local out = {}
  for d in string.gmatch(s, "[^,]+") do out[d] = true end
  return out
end

-- Store what this arrival advertised, if it differs. Returns the set.
function elro.stub_note(id, exits)
  local set, list = {}, {}
  if exits and exits ~= "" and exits ~= "none" then
    for raw in string.gmatch(exits, "[^,]+") do
      local d = elro.norm(raw)
      if elro.dirNum[d] and not set[d] then set[d] = true ; list[#list + 1] = d end
    end
  end
  table.sort(list)
  local joined = table.concat(list, ",")
  if joined ~= (getRoomUserData(id, "xcomp") or "") then
    setRoomUserData(id, "xcomp", joined)
  end
  return set
end

-- ⭐ MIGRATION: a room mapped before xcomp existed has its advertised list only in
-- the stubs themselves. Recover it once, from the stubs plus the real edges, so
-- turning stubs off and on again does not lose it.
function elro.stub_backfill(id)
  if (getRoomUserData(id, "xcomp") or "") ~= "" then return false end
  local list = {}
  for n in pairs(elro.stub_set(id)) do
    local d = elro.dirName and elro.dirName(n)
    if not d then for k, v in pairs(elro.dirNum) do if v == n then d = k break end end end
    if d then list[#list + 1] = d end
  end
  for d in pairs(elro.cs_exits(id)) do
    if elro.dirNum[d] then list[#list + 1] = d end
  end
  if #list == 0 then return false end
  local seen, uniq = {}, {}
  for _, d in ipairs(list) do if not seen[d] then seen[d] = true ; uniq[#uniq + 1] = d end end
  table.sort(uniq)
  setRoomUserData(id, "xcomp", table.concat(uniq, ","))
  return true
end

-- ---- exits that leave the map ----------------------------------------------
-- `xoff`: the compass exits the server said lead into a room it will not map
-- (`!MAP id=0`). Such an exit is not frontier, so it is no stub and does not
-- count toward the halo; it is drawn as the blue half-line of an area border.
function elro.off_set(id)
  local out = {}
  for d in string.gmatch(getRoomUserData(id, "xoff") or "", "[^,]+") do out[d] = true end
  return out
end

function elro.off_store(id, set)
  local list = {}
  for d in pairs(set) do list[#list + 1] = d end
  table.sort(list)
  setRoomUserData(id, "xoff", table.concat(list, ","))
end

-- The marker's handler. Only a compass exit can be drawn or stubbed, so nothing
-- else is recorded.
function elro.off_record(fromId, dir)
  -- `why` is read back by mapoff: where this stopped, in words
  local L = elro._lastOff or {}
  elro._lastOff = L
  if not fromId or fromId == 0 or not roomExists(fromId) then
    L.why = "no known room to record on" return
  end
  -- a wire without dir= leaves the label to the fence, as onRoom does
  if (not dir or dir == "") and elro.fence_take then dir = elro.fence_take(fromId) end
  local d = elro.norm(dir or "")
  if not elro.dirNum[d] then L.why = "not a compass exit: [" .. tostring(d) .. "]" return end
  -- ⛔ A REAL EDGE WINS. An area that was mapped and later closed still sends the
  -- marker for an exit the map already knows; marking it would throw that away.
  local linked = false
  for dn, dest in pairs(getRoomExits(fromId) or {}) do
    if dest and elro.norm(dn) == d then
      if dest ~= elro.OFF_ROOM then
        L.why = "a real edge already leads " .. d .. " to " .. tostring(dest) return
      end
      linked = true
    end
  end
  local set = elro.off_set(fromId)
  if not set[d] then
    set[d] = true
    elro.off_store(fromId, set)
    elro.stub_count_dirty(getRoomArea(fromId))
  end
  -- ⭐ THE EXIT IS REAL, its destination is the placeholder. A custom line on a
  -- direction with no exit does not draw in Mudlet and the stub stays (seen
  -- live). An exit into the placeholder's area is an ordinary cross-area exit:
  -- Mudlet drops the stub and draw_area_stubs draws the blue border half-line,
  -- both by paths that already work. The layout never sees it, since
  -- area_adjacency drops exits that leave the area.
  if not linked then
    local okx = setExit(fromId, elro.off_room(), d)
    elro.cs_dirty(fromId)
    L.why = "recorded; setExit returned " .. tostring(okx) .. ", exit now " ..
            tostring((getRoomExits(fromId) or {})[d])
  else
    L.why = "already linked"
  end
  -- every time, not only the first: cheap, and it repairs what an earlier
  -- version (or a relayout) left wrong
  elro.stub_apply(fromId)
  elro.stub_halo_update()
  if elro.draw_area_stubs then elro.draw_area_stubs({ [fromId] = true }) end
  if type(updateMap) == "function" then pcall(updateMap) end
end

-- Two independent halves, each under pcall: Mudlet abandons a trigger script at
-- its first error, and the view change must not take the record down with it
-- (nor the other way round). Errors are SHOWN, or they would never be found.
function elro.onOff(fromId, dir)
  -- dir is the LAST field of the marker, and the capture took the line ending
  -- with it ("east\n" is no compass exit). Trimmed here as well as in the regex:
  -- this half reaches a player by mapreload, the XML only by a reinstall.
  if type(dir) == "string" then dir = dir:gsub("^%s+", ""):gsub("%s+$", "") end
  -- kept for `mapoff`: what arrived, as it arrived, and what it normalised to
  elro._lastOff = { from = fromId, dir = dir, norm = dir and elro.norm(dir) or nil,
                    known = fromId and fromId ~= 0 and roomExists(fromId) or false }
  local ok, err = pcall(elro.off_record, fromId, dir)
  if not ok then cecho("\n<red>[elro] off-map record ERROR: " .. tostring(err) .. "\n<reset>") end
  -- The view leaves the map with the player, whatever the exit was (from=0 is a
  -- login, a teleport or the dark); onRoom brings it back.
  elro.offmap = fromId or 0
  ok, err = pcall(elro.recenter, true)
  if not ok then cecho("\n<red>[elro] off-map view ERROR: " .. tostring(err) .. "\n<reset>") end
end

-- mapoff [id]: what is recorded for a room (default: the last mapped one), so a
-- missing blue line can be told apart from a missing record.
function elro.cmd_off(arg)
  local id = tonumber(arg or "") or elro.current
  if not id or not roomExists(id) then cecho("\n<red>[elro]: no such room.\n<reset>") return end
  local stubs = {}
  for n in pairs(elro.stub_set(id)) do stubs[#stubs + 1] = tostring(n) end
  local lines = {}
  if type(getCustomLines) == "function" then
    local ok, t = pcall(getCustomLines, id)
    for k in pairs(ok and type(t) == "table" and t or {}) do lines[#lines + 1] = tostring(k) end
  end
  cecho(string.format(
    "\n<cyan>[elro] room %d: off-map exits [%s]  advertised [%s]\n" ..
    "  Mudlet stubs (direction numbers) [%s]  custom lines [%s]  view is %s<reset>\n",
    id, getRoomUserData(id, "xoff") or "", getRoomUserData(id, "xcomp") or "",
    table.concat(stubs, ","), table.concat(lines, ","),
    elro.offmap and "OFF the map" or "on the map"))
  -- which code is answering: a stale copy of this file is the first suspect when
  -- a fix "does nothing"
  cecho("<cyan>  off-map code: build 5 (exit linked to room " .. tostring(elro.OFF_ROOM) .. ")<reset>\n")
  local l = elro._lastOff
  if l then
    cecho(string.format(
      "<cyan>  last marker: from=%s (room known: %s)  dir=[%s]  read as [%s]\n" ..
      "  what the record step did: %s<reset>\n",
      tostring(l.from), tostring(l.known), tostring(l.dir), tostring(l.norm),
      tostring(l.why or "it did not run")))
  else
    cecho("<cyan>  no marker has arrived this session.<reset>\n")
  end
end

-- A real arrival through the exit: the area was opened, the mark is wrong now.
function elro.off_clear(fromId, d)
  if not fromId or fromId == 0 or not d or not roomExists(fromId) then return end
  local set = elro.off_set(fromId)
  if not set[d] then return end
  set[d] = nil
  elro.off_store(fromId, set)
  -- unlink the placeholder, and only the placeholder: a real edge stays
  for dn, dest in pairs(getRoomExits(fromId) or {}) do
    if dest == elro.OFF_ROOM and elro.norm(dn) == d then
      setExit(fromId, -1, d) ; elro.cs_dirty(fromId)
    end
  end
  if type(removeCustomLine) == "function" then pcall(removeCustomLine, fromId, d) end
  elro.stub_count_dirty(getRoomArea(fromId))
end

-- Bring one room's stubs into line with what it advertises, what it already has an
-- edge for, and whether stubs are shown at all. Writes only on a CHANGE: a map
-- mutation is not free even when it changes nothing, and the old code re-stubbed
-- every direction on every arrival.
function elro.stub_apply(id, advertised)
  if type(setExitStub) ~= "function" then return end
  local show = (elro.stubsShown ~= false) and (elro.exitStubs ~= false)
  advertised = advertised or elro.stub_advertised(id)
  -- ⚠ LIVE exits, not elro.cs_room: the snapshot is invalidated at the END of
  -- onRoom, so an edge written by this very move is not in it yet and the room
  -- would shed its now-redundant stub only on a revisit.
  local have, real = {}, {}
  for dn, dest in pairs(getRoomExits(id) or {}) do
    if dest then
      have[elro.norm(dn)] = true
      if dest ~= elro.OFF_ROOM then real[elro.norm(dn)] = true end
    end
  end
  local now = elro.stub_set(id)
  local want = {}
  -- an off-map mark on a direction that has since gained a REAL edge is stale
  -- (the area was opened and the edge learned from the far side): drop it
  local off = elro.off_set(id)
  for d in pairs(off) do
    if real[d] then elro.off_clear(id, d) ; off[d] = nil end
  end
  if show then
    for d in pairs(advertised) do
      if not have[d] and not off[d] then
        local n = elro.dirNum[d] ; if n then want[n] = true end
      end
    end
  end
  for n in pairs(want) do if not now[n] then pcall(setExitStub, id, n, true) end end
  for n in pairs(now) do if not want[n] then pcall(setExitStub, id, n, false) end end
end

-- Re-derive every room's stubs. `scope` is an area id, or nil for the whole map.
function elro.stub_resync(scope)
  local list = {}
  if scope then for _, r in ipairs(elro.cs_area_rooms(scope)) do list[#list + 1] = r end
  else for r in pairs(elro.cs_all_rooms()) do list[#list + 1] = r end end
  table.sort(list)
  local filled = 0
  for _, r in ipairs(list) do
    if roomExists(r) then
      if elro.stub_backfill(r) then filled = filled + 1 end
      elro.stub_apply(r)
    end
  end
  if type(updateMap) == "function" then pcall(updateMap) end
  return #list, filled
end

-- What an area actually puts on screen. The map being sluggish while STANDING
-- STILL is a rendering cost, not a per-move one, so the question is what is drawn
-- and how much -- and it is not guessable: titleist held 1239 of the map's stubs
-- in 3% of its rooms, none of them redundant, against just 9 custom lines.
function elro.draw_census(scope)
  local list = {}
  if scope then for _, r in ipairs(elro.cs_area_rooms(scope)) do list[#list + 1] = r end
  else for r in pairs(elro.cs_all_rooms()) do list[#list + 1] = r end end
  local n = { rooms = 0, stubs = 0, edges = 0, lines = 0, glyphs = 0, hi = 0 }
  for _, r in ipairs(list) do
    if roomExists(r) then
      n.rooms = n.rooms + 1
      for _ in pairs(elro.stub_set(r)) do n.stubs = n.stubs + 1 end
      for _ in pairs(elro.cs_exits(r)) do n.edges = n.edges + 1 end
      if type(getCustomLines) == "function" then
        local got, t = pcall(getCustomLines, r)
        if got and type(t) == "table" then for _ in pairs(t) do n.lines = n.lines + 1 end end
      end
      if type(getRoomChar) == "function" then
        local c = getRoomChar(r) ; if c and c ~= "" then n.glyphs = n.glyphs + 1 end
      end
      if (getRoomUserData(r, "terr") or "") ~= "" then n.hi = n.hi + 1 end
    end
  end
  return n
end

-- ---- the stub halo --------------------------------------------------------
-- ⭐ WHAT MAKES THIS AFFORDABLE: stubs are derived from `xcomp`, so showing a
-- SUBSET of them costs nothing and loses nothing. Only the rooms near you carry
-- stubs; the rest keep their record and get them back as you approach.
--
-- That is also what a stub is FOR -- "where have I not been, from HERE" -- and it
-- is the one policy whose cost does not grow with the map: the visible set is
-- bounded by the radius, not by how much you have explored. Mudlet repaints every
-- stub in the viewport every frame, so bounding the count is the whole game.
--
-- ⚠ ONLY WHERE IT PAYS. Below stubHaloMin stubs in the area the halo is off and
-- everything shows: a small area costs nothing to draw in full, and a map that
-- quietly hides things in a 20-room village would be worse than the problem.
--
-- The scan is over the CELL INDEX, not the room list: (2N+1)^2 O(1) table hits
-- with no Mudlet calls, so a 400-room area and a 4000-room one cost the same.
-- 4 cells is a deliberate default, not a guess at a safe one: the halo has to be
-- small enough to actually bound the draw (a radius of 8 is 289 cells, most of a
-- viewport, so it barely bounds anything in a dense grid) while still covering the
-- rooms you can act on from where you stand. 100 is where an area starts costing
-- enough to be worth thinning at all.
elro.stubHalo = elro.stubHalo or 4         -- cells; 0 = never halo, show them all
elro.stubHaloMin = elro.stubHaloMin or 100 -- stubs in the area before it engages

function elro.load_stubhalo()
  elro.stubhalo_loaded = true
  if type(getMapUserData) ~= "function" then return end
  local ok, s = pcall(getMapUserData, "elro.stubHalo")
  if ok and type(s) == "string" and s ~= "" then elro.stubHalo = tonumber(s) or elro.stubHalo end
  local ok2, s2 = pcall(getMapUserData, "elro.stubHaloMin")
  if ok2 and type(s2) == "string" and s2 ~= "" then elro.stubHaloMin = tonumber(s2) or elro.stubHaloMin end
end

function elro.set_stubhalo(n, minv)
  if n then elro.stubHalo = n end
  if minv then elro.stubHaloMin = minv end
  if type(setMapUserData) == "function" then
    pcall(setMapUserData, "elro.stubHalo", tostring(elro.stubHalo))
    pcall(setMapUserData, "elro.stubHaloMin", tostring(elro.stubHaloMin))
  end
end

-- How many stubs this area WOULD show in full: advertised compass exits with no
-- edge. Cached per area and recomputed when the area's room count moves, which is
-- the only way it grows -- exploring. O(rooms) once, not per move.
function elro.stub_area_count(aid)
  elro._stubCount = elro._stubCount or {}
  local rooms = elro.cs_area_rooms(aid)
  local c = elro._stubCount[aid]
  if c and c.rooms == #rooms then return c.n end
  local n = 0
  for _, r in ipairs(rooms) do
    if roomExists(r) then
      local adv = elro.stub_advertised(r)
      local ex = elro.cs_exits(r)
      local off = elro.off_set(r)
      for d in pairs(adv) do if not ex[d] and not off[d] then n = n + 1 end end
    end
  end
  elro._stubCount[aid] = { n = n, rooms = #rooms }
  return n
end

function elro.stub_count_dirty(aid)
  if not elro._stubCount then return end
  if aid then elro._stubCount[aid] = nil else elro._stubCount = {} end
end

-- The rooms that should carry stubs right now, or nil for "the halo does not
-- apply -- every room qualifies".
function elro.stub_halo_set()
  if (elro.stubsShown == false) or (elro.exitStubs == false) then return {} end
  local n = elro.stubHalo or 0
  if n <= 0 then return nil end
  local cur = elro.current
  if not cur or not roomExists(cur) then return nil end
  local aid = getRoomArea(cur)
  if elro.stub_area_count(aid) < (elro.stubHaloMin or 0) then return nil end
  local px, py = getRoomCoordinates(cur)
  if not px then return nil end
  local set = {}
  for dx = -n, n do
    for dy = -n, n do
      local r = elro.cell_at(aid, px + dx, py + dy)
      if r then set[r] = true end
    end
  end
  return set
end

-- Bring the visible stubs into line with the halo. Only the rooms CROSSING the
-- boundary are written; `elro._stubOn` remembers what is shown, so standing still
-- costs nothing. Turning the halo OFF again (small area, or the setting changed)
-- has to restore what it hid, which is what the _stubHaloActive latch is for.
function elro.stub_halo_update()
  if type(setExitStub) ~= "function" then return 0, 0 end
  local want = elro.stub_halo_set()
  if want == nil then
    if elro._stubHaloActive then          -- it applied before and does not now
      elro._stubHaloActive = nil ; elro._stubOn = nil
      elro.stub_resync(nil)
    end
    return 0, 0
  end
  elro._stubHaloActive = true
  local on = elro._stubOn
  if not on then
    on = {}
    for r in pairs(elro.cs_all_rooms()) do
      if roomExists(r) and next(elro.stub_set(r)) then on[r] = true end
    end
    elro._stubOn = on
  end
  local shown, hidden = 0, 0
  for r in pairs(want) do
    if not on[r] then elro.stub_apply(r) ; on[r] = true ; shown = shown + 1 end
  end
  for r in pairs(on) do
    if not want[r] then
      if roomExists(r) then
        for n2 in pairs(elro.stub_set(r)) do pcall(setExitStub, r, n2, false) end
      end
      on[r] = nil ; hidden = hidden + 1
    end
  end
  return shown, hidden
end

-- mapstubs [on|off] [area|.]: the census, and the show/hide toggle. Turning them
-- off is lossless now -- the advertised list lives in `xcomp`, so `on` rebuilds
-- exactly what was there.
function elro.cmd_stubs(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  -- mapstubs halo [<cells> [<min>]] | halo off
  if arg:match("^halo%s+off") then
    elro.set_stubhalo(0)
    elro._stubOn = nil ; elro._stubHaloActive = nil
    elro.stub_resync(nil)
    cecho("\n<green>[elro]: stub halo off -- every stub shows, everywhere.\n<reset>")
    return
  end
  local h1, h2 = arg:match("^halo%s*(%d*)%s*(%d*)$")
  if h1 then
    if h1 ~= "" then elro.set_stubhalo(tonumber(h1), tonumber(h2)) end
    elro._stubOn = nil ; elro._stubHaloActive = nil
    elro.stub_count_dirty()
    elro.stub_resync(nil) ; elro.stub_halo_update()
    cecho(string.format(
      "\n<green>[elro]: stub halo = %d cell(s), engaging once an area has %d+ stubs.<reset>\n" ..
      "<cyan>  Near you they stay -- that is where you are mapping. Further off they are hidden\n" ..
      "  and come back as you approach; the record is kept either way.<reset>\n",
      elro.stubHalo, elro.stubHaloMin))
    return
  end
  local set
  if arg:match("^on") then set = true ; arg = (arg:gsub("^on%s*", ""))
  elseif arg:match("^off") then set = false ; arg = (arg:gsub("^off%s*", "")) end
  local scope, label
  if arg == "." then
    scope = elro.current and roomExists(elro.current) and getRoomArea(elro.current) or nil
    label = scope and (elro.areaName(scope) or "this area") or nil
  elseif arg ~= "" then
    scope = elro.find_area(arg)
    if not scope then
      cecho("\n<red>[elro]: no area matching '" .. arg .. "'.\n<reset>") return
    end
    label = elro.areaName(scope)
  end
  if set ~= nil then
    elro.set_stubshow(set)
    local nrooms, filled = elro.stub_resync(nil)      -- the preference is global
    cecho(string.format(
      "\n<green>[elro]: exit stubs %s (%d room(s)%s).<reset>\n", set and "SHOWN" or "HIDDEN",
      nrooms, filled > 0 and (", " .. filled .. " backfilled from their old stubs") or ""))
    if not set then
      cecho("<cyan>  Mudlet repaints the whole viewport every frame and every stub is its own\n" ..
            "  draw call, where two linked rooms share one line. 'mapstubs on' brings them\n" ..
            "  back -- the advertised list is stored, so nothing was lost.\n<reset>")
    end
    return
  end
  local n = elro.draw_census(scope)
  cecho(string.format(
    "\n<cyan>[elro] drawn in %s: %d rooms, %d edge(s), %d stub(s), %d custom line(s), %d glyph(s), %d coloured<reset>\n",
    label or "the whole map", n.rooms, n.edges, n.stubs, n.lines, n.glyphs, n.hi))
  local per = (n.rooms > 0) and ((n.edges + n.stubs + n.lines) / n.rooms) or 0
  cecho(string.format("<cyan>  = %.1f line-ish things per room; stubs are %s of them.<reset>\n",
        per, (n.edges + n.stubs + n.lines) > 0
             and string.format("%.0f%%", 100 * n.stubs / (n.edges + n.stubs + n.lines)) or "0%"))
  cecho(string.format("<cyan>  stubs are currently %s.<reset>\n",
        (elro.stubsShown ~= false) and "SHOWN (mapstubs off to hide them)" or "HIDDEN (mapstubs on)"))
  if scope then
    local full = elro.stub_area_count(scope)
    local engaged = (elro.stubHalo or 0) > 0 and full >= (elro.stubHaloMin or 0)
    cecho(string.format(
      "<cyan>  halo %d cell(s), threshold %d; this area would show %d in full -- %s.<reset>\n",
      elro.stubHalo or 0, elro.stubHaloMin or 0, full,
      engaged and "engaged here" or "below the threshold, so all are shown"))
  end
end

-- ---- onRoom profiling (mapprofile) -----------------------------------------
-- ⛔ GUESSING AT WHERE A MOVE'S TIME GOES IS EXACTLY WHAT THE MEASUREMENT RULES
-- FORBID. onRoom does several unrelated jobs and only some of them run on a given
-- move -- guess_inconsistent is behind `changed`, so a plain revisit never reaches
-- it, while terrain and recenter run every single time. This times the phases and
-- names the one that actually cost, instead of leaving it to inference.
--
-- `mapprofile on` then walk; each move over elro.profMin ms prints its breakdown.
-- Off by default and free when off: one `if` per phase.
elro.profMin = elro.profMin or 0        -- ms; only report a move at least this slow

local function pf_now()
  -- getEpoch/os.clock: whichever this build has. Milliseconds either way.
  if type(getEpoch) == "function" then return getEpoch() * 1000 end
  return os.clock() * 1000
end

-- start a phase timer; returns a closer that accumulates into elro._prof
local function pf(name)
  if not elro.profOn then return function() end end
  local t0 = pf_now()
  return function()
    local p = elro._prof ; if not p then p = {} ; elro._prof = p end
    p[name] = (p[name] or 0) + (pf_now() - t0)
  end
end

-- mapprofile [on|off|<ms>]
function elro.cmd_profile(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "off" then
    elro.profOn = false
    cecho("\n<green>[elro]: onRoom profiling off.\n<reset>") return
  end
  local ms = tonumber(arg)
  if ms then elro.profMin = ms end
  elro.profOn = true
  cecho(string.format(
    "\n<green>[elro]: onRoom profiling ON -- reporting moves over %gms.\n" ..
    "  Phases: graph (exits/areas), terr (colour+glyph), guess (the loop-closure and\n" ..
    "  room-on-edge scan, only when the graph CHANGED), dirty (relayout trigger),\n" ..
    "  view (centerview). 'mapprofile off' to stop.\n<reset>", elro.profMin))
end

-- The handshake is owed again whenever the link on the other end can be a new
-- one: this code was (re)loaded, or the connection dropped or came up. The link
-- forgets the client with every login, and sends the off-map markers only to a
-- version it has heard from, so an ack per Mudlet SESSION lost them at a relog.
elro._ackSent = nil
if type(registerAnonymousEventHandler) == "function" then
  for _, ev in ipairs({ "sysConnectionEvent", "sysDisconnectionEvent" }) do
    local key = "_ackH_" .. ev
    if elro[key] and type(killAnonymousEventHandler) == "function" then
      pcall(killAnonymousEventHandler, elro[key])
    end
    elro[key] = registerAnonymousEventHandler(ev, function() elro._ackSent = nil end)
  end
end

-- mapupdate [file]: replace this package with the newest release, in one command.
-- Mudlet refuses to install over an installed package, so the manual route is
-- "remove it in the Package Manager, then install", which nobody should have to
-- do. ⭐ DOWNLOAD FIRST, swap after: if the download fails nothing was removed.
-- The swap runs from a timer, not from the alias: the alias belongs to the
-- package being uninstalled. Functions and timers live in the Lua state, which
-- an uninstall does not clear, so they survive to do the install.
-- With a local file as argument the download is skipped (testing a build).
elro.UPDATE_URL = "https://github.com/tobfon/nannymud-mapper/releases/latest/download/ElrohirMapper.mpackage"

function elro.update_swap(path)
  -- ONE swap at a time. Seen live: the swap ran twice (a second download event,
  -- or the alias present twice), and a second uninstall racing the first
  -- install is how a player ends up with no package.
  if elro._updBusy then return end
  elro._updBusy = true
  -- installPackage can fail without throwing, so the package list is the verdict.
  local function installed()
    if type(getPackages) ~= "function" then return true end
    for _, p in ipairs(getPackages() or {}) do if p == "ElrohirMapper" then return true end end
    return false
  end
  local function try(left)
    local ok, err = pcall(installPackage, path)
    if ok and installed() then
      elro._updBusy = nil
      -- the loader has just printed the version line; this only adds the reassurance
      cecho("<green>[elro]: updated. Your map is untouched.\n<reset>")
    elseif left > 0 then
      tempTimer(2, function() try(left - 1) end)
    else
      elro._updBusy = nil
      cecho("\n<red>[elro]: the install failed" .. (ok and "" or ": " .. tostring(err)) ..
            ".\n  Drag " .. path .. " onto Mudlet to finish by hand. Your map is untouched.\n<reset>")
    end
  end
  tempTimer(0.1, function()
    pcall(uninstallPackage, "ElrohirMapper")
    tempTimer(1, function() try(1) end)
  end)
end

function elro.cmd_update(arg)
  -- Once per half minute. Seen live and never explained: the command ran twice
  -- for one typed line. A second run would start a second download into the same
  -- file, and a second swap. Time-boxed so a download that never reports back
  -- cannot lock the command for the rest of the session.
  local now = os.time()
  if elro._updAt and now - elro._updAt < 30 then return end
  elro._updAt = now
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if type(installPackage) ~= "function" or type(uninstallPackage) ~= "function" then
    cecho("\n<red>[elro]: this Mudlet cannot install packages from a script.\n<reset>") return
  end
  if arg ~= "" then                       -- a local build: no download
    -- Mudlet takes the package name from the text after the last "/"
    arg = arg:gsub("\\", "/")
    local f = io.open(arg, "rb")
    if not f then cecho("\n<red>[elro]: no such file: " .. arg .. "\n<reset>") return end
    f:close()
    elro.update_swap(arg) ; return
  end
  if type(downloadFile) ~= "function" then
    cecho("\n<red>[elro]: this Mudlet cannot download; see 'maplink setup'.\n<reset>") return
  end
  local dir = getMudletHomeDir() .. "/elro_update"
  if lfs and lfs.mkdir then pcall(lfs.mkdir, dir) end
  -- the file name IS the package name to Mudlet, so it keeps its own
  local path = dir .. "/ElrohirMapper.mpackage"
  os.remove(path)
  for _, k in ipairs({ "_updDone", "_updErr" }) do
    if elro[k] then pcall(killAnonymousEventHandler, elro[k]) ; elro[k] = nil end
  end
  -- `_updWant` makes each handler one-shot by itself, whether or not the kill works
  elro._updWant = path
  elro._updDone = registerAnonymousEventHandler("sysDownloadDone", function(_, file)
    if file ~= path or elro._updWant ~= path then return end
    elro._updWant = nil
    pcall(killAnonymousEventHandler, elro._updDone) ; elro._updDone = nil
    elro.update_swap(path)
  end)
  elro._updErr = registerAnonymousEventHandler("sysDownloadError", function(_, why, file)
    if (file and file ~= path) or elro._updWant ~= path then return end
    elro._updWant = nil
    pcall(killAnonymousEventHandler, elro._updErr) ; elro._updErr = nil
    cecho("\n<red>[elro]: the download failed (" .. tostring(why) ..
          "). Nothing was changed.\n<reset>")
  end)
  cecho("\n<cyan>[elro]: downloading the newest package...\n<reset>")
  downloadFile(path, elro.UPDATE_URL)
end

-- mapack: say hello to the link again, now. For a link re-cloned in mid-session,
-- which nothing on this side can notice.
function elro.cmd_ack()
  if type(send) ~= "function" then return end
  elro._ackSent = true
  pcall(send, "maplink ack " .. tostring(elro.VERSION), false)
  pcall(send, "maplink seq auto", false)
  cecho("\n<green>[elro]: told the link this is client " .. tostring(elro.VERSION) .. ".\n<reset>")
end

function elro.onRoom(id, fromId, dir, name, area, exits, terr, mha, mh)
  if not id then return end
  elro.offmap = nil            -- any mapped room ends an excursion off the map
  local _pfTotal
  if elro.profOn then elro._prof = {} ; _pfTotal = pf("total") end
  -- Handshake, once per session. The link streams whether or not anything is
  -- listening, so without this the game cannot tell a player whose client is
  -- missing from one whose client is fine. Sent on the first !MAP line rather
  -- than at load: Mudlet runs its scripts before the connection exists.
  if not elro._ackSent and type(send) == "function" then
    elro._ackSent = true
    pcall(send, "maplink ack " .. tostring(elro.VERSION), false)
    -- and ask for the command fence; an older link prints its usage line once
    pcall(send, "maplink seq auto", false)
  end
  if dir == nil or dir == "" then dir = "none" end
  -- A wire without dir= (the admins' call) leaves the label to the fence: the
  -- command the link captured for this move, if it vouches for it.
  if dir == "none" and fromId and fromId ~= 0 then
    local fcmd = elro.fence_take(fromId)
    if fcmd then dir = fcmd end
  end
  dir = elro.norm(dir)
  -- An old trigger regex (`exits=(.*)$`) leaks later fields into `exits`. A real
  -- exit list never contains '|', so split there.
  if exits then
    local cut = string.find(exits, "|", 1, true)
    if cut then
      if terr == nil then terr = string.match(exits, "|terr=(.*)$") end
      exits = string.sub(exits, 1, cut - 1)
    end
  end
  local aid = elro.areaId(area)
  local changed = false                        -- did the GRAPH actually change?
  local collided = false                       -- ...and did our guess land ON a room?
  local fromUnplaced = false                   -- was `fromId` recreated here, i.e. at (0,0)?
  local touched = {}                           -- roomId -> true: snapshot went stale

  -- 1. ensure the SOURCE room exists. The server only announces a room on
  --    movement, so the player's start room (and any room entered via an
  --    untracked transition) never arrives as a destination -- it first appears
  --    here as `from`. Add it bare (no edges yet); enriched if ever re-entered.
  if fromId and fromId ~= 0 and not roomExists(fromId) then
    addRoom(fromId)
    setRoomArea(fromId, aid)
    setRoomName(fromId, "room " .. fromId)
    setRoomUserData(fromId, "sarea", (area ~= nil and area ~= "") and area or "world")
    changed = true ; touched[fromId] = true
    elro.cs_dirty(fromId) ; elro.cs_lists_dirty()   -- same staleness as the destination
    -- an unplaced room is a collision: it sits wherever addRoom put it
    collided = true
    fromUnplaced = true
  end

  -- 2. add / enrich the DESTINATION room
  local isNew = not roomExists(id)
  -- cs_dirty, not just `touched`: touched is drained at the END of the call,
  -- and cs_room(id) is read a few lines down.
  if isNew then
    addRoom(id) ; changed = true ; touched[id] = true
    elro.smap_restore(id)          -- recorded exits survive a GUI delete; the room did not
    elro.cs_dirty(id) ; elro.cs_lists_dirty()
  end
  setRoomName(id, elro.strip_ansi((name ~= nil and name ~= "") and name or ("room " .. id)))
  local rec = elro.cs_room(id)                 -- nil only if the room vanished under us
  local sa = (area ~= nil and area ~= "") and area or "world"
  if not rec or rec.sarea ~= sa then setRoomUserData(id, "sarea", sa) ; touched[id] = true end
  -- Merge hints: STORED, never applied (see resolve_area). The server is the
  -- authority on what it suggests, so a missing field clears the stored one. An
  -- area-wide hint changing moves every known room of that area, which the
  -- relayout's recompute_areas does; `changed` is what asks for it.
  if not elro.hints_loaded then elro.load_hints() end
  local function tidy(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
  end
  mha, mh = tidy(mha), tidy(mh)
  if elro.hintArea[sa] ~= mha then
    elro.hintArea[sa] = mha ; elro.save_hints() ; changed = true
  end
  if mha then mh = nil end                    -- the wider hint is the one in force
  if ((rec and rec.mh) or "") ~= (mh or "") then
    setRoomUserData(id, "mh", mh or "") ; touched[id] = true ; changed = true
    if rec then rec.mh = mh or "" end
  end
  -- sticky folds: keep an existing fold tag; a NEW room inherits its source
  -- room's fold so an explored branch keeps growing into its submap instead of
  -- leaking back into the server area. Assign the EFFECTIVE area (fold first,
  -- then merge redirects) directly, so it is correct even without a full flush.
  if elro.merge == nil then elro.load_merge() end
  local fold = rec and rec.fold
  if (not fold or fold == "") and isNew and fromId and fromId ~= 0 then
    local frec = elro.cs_room(fromId)
    local pf = frec and frec.fold
    if pf and pf ~= "" then setRoomUserData(id, "fold", pf) ; fold = pf ; touched[id] = true end
  end
  -- `via`: the area we came in from. Recorded once on creation and never
  -- overwritten, so onRoom and recompute_areas read the same host instead of
  -- each deriving one (a disagreement flips the room's tab on every entry). It
  -- propagates: the next room reads its via off this one's effective area.
  local via = rec and rec.via or ""
  if via == "" and isNew then
    local vname
    if fromId and fromId ~= 0 and dir ~= "none" and roomExists(fromId) then
      local vrec = elro.cs_room(fromId)
      vname = vrec and elro.areaName(vrec.area)
    end
    via = (vname and vname ~= "") and vname or elro.VIA_NONE
    setRoomUserData(id, "via", via)
    if rec then rec.via = via end
  end
  -- a per-room "adopt" steal (mapsteal) wins outright, like in recompute_areas,
  -- so re-entering a stolen room doesn't snap it back to its source area.
  local adopt = rec and rec.adopt
  local effName = (adopt and adopt ~= "") and adopt
    or ((fold and fold ~= "") and fold or elro.resolve_area(sa, mh))
  -- The area_min gate, applied only to the plain case (adopt/fold/merge/hint
  -- and an unmerged area are forced-keep in recompute_areas). Must match
  -- recompute_areas exactly or the room flips tabs on every entry.
  if effName == sa and not elro.area_kept(sa) and not elro.hint_pinned(sa) then
    if via ~= "" and via ~= elro.VIA_NONE and elro.area_kept(via) then
      effName = via                          -- absorbed by the area we came in from
    elseif via ~= elro.VIA_NONE then
      effName = "world"                      -- no via recorded at all: as before
    end
    -- VIA_NONE: nothing to be absorbed by; keep its own tab
  end
  local effAid = elro.areaId(effName)
  if not rec or rec.area ~= effAid then
    setRoomArea(id, effAid)
    touched[id] = true ; elro.cs_lists_dirty()
  end

  -- ...and the non-compass ones as a room glyph (cosmetic: no touched/changed)
  elro.note_nonstd(id, exits)

  -- A real arrival through an exit marked off-map (its area was opened): unlink
  -- the placeholder FIRST, or the edge write below reads it as a destination
  -- that changed and counts a maze mutation.
  elro.off_clear(fromId, dir)
  -- 3. edge SOURCE -> DEST (both ways for compass; special exit otherwise)
  if fromId and fromId ~= 0 and dir ~= "none" and roomExists(fromId) then
    if elro.dirNum[dir] then
      local frec = elro.cs_room(fromId) or { ex = {}, asm = {} }
      local old = frec.ex[dir]                        -- current target for this dir (nil if none)
      -- A target change is a maze mutation only if the edge it replaces was
      -- itself observed; overwriting an assumed reverse is just learning the truth.
      local assumedF = frec.asm[dir] and true or false
      if old and old ~= id and not assumedF then
        elro.mut_record(fromId, dir, old, id)   -- count + remember BOTH destinations
      end
      local manual = getRoomUserData(fromId, "manual_" .. dir)
      if manual and manual ~= "" and old and old ~= id then
        -- a locked exit (mapexitlock) is never re-pointed; the mutation was still counted
      else
        -- A room created in THIS call cannot already be something's exit
        -- target, so isNew overrules a snapshot that says it is.
        local had = old == id and not isNew
        if not had then setExit(fromId, id, dir) ; touched[fromId] = true end
        if assumedF then
          setRoomUserData(fromId, "assumed_" .. dir, "") -- forward is now OBSERVED
          touched[fromId] = true
          -- a promotion assumed -> observed is a graph change: the layout reads
          -- provenance (elro.demotion_set), not exits alone
          changed = true
        end
        -- The reverse edge is ASSUMED: never clobber an edge id already has
        -- (first-writer wins), and only add it when id advertises that exit.
        local rev = elro.reverse[dir]
        local rex = rec and rec.ex or (getRoomExits(id) or {})
        if rev and not rex[rev] and elro.advertises(exits, rev) then
          setExit(id, fromId, rev)
          setRoomUserData(id, "assumed_" .. rev, "1")
          touched[id] = true
          -- a new dart is a graph change even when the forward edge existed
          changed = true
        end
        if isNew then
          -- Unit-step guess; an overlap is what makes the relayout urgent. No guess when the
          -- anchor is not real: a resurrected fromId sits at addRoom's (0,0), and stepping
          -- off it drags the new room -- and then its successors -- to the origin. `fx` is
          -- checked, not assumed: a throw here aborts the handler and Mudlet abandons the
          -- trigger, leaving the room half registered. Falling through treats it as a
          -- collision, as the special-exit branch below already does with no guess.
          local fx, fy, fz = getRoomCoordinates(fromId)
          local del = elro.delta[dir]
          if fx and del and not fromUnplaced then
            local gx, gy = fx + del[1], fy + del[2]
            -- effAid, not fromId's area: collide against the canvas this room lands on
            local occ = elro.cell_at(effAid, gx, gy)
            setRoomCoordinates(id, gx, gy, fz)
            elro.cell_put(effAid, gx, gy, id)
            if occ and occ ~= id then collided = true end
            -- a build in flight will commit coordinates that this guess was measured
            -- against, invalidating it; record it so guess_reseed can re-derive it.
            if elro.bg_busy() then elro.guess_pend(id, fromId, dir) end
          else
            collided = true
          end
        end
        if not had then                          -- a genuinely new compass edge
          changed = true
          -- effAid, not aid: the raw server area is not where the room ends up
          local fa = frec.area or getRoomArea(fromId)  -- a cross-area edge dirties both
          if fa and fa > 0 and fa ~= effAid then
            elro.dirty[fa] = true
            elro.cs_bump(fa)                     -- ...and stales both layouts
          end
        end
      end
    else
      -- A non-compass dir is a command the link captured as typed ("climb
      -- mountain"): the server sends nothing else here any more, so it is the
      -- replayable one. It never clobbers a manually recorded edge
      -- (maprecordmove): that is the trusted command, and first-writer wins.
      if elro.smap == nil then elro.load_smap() end
      local recording = elro.rec and elro.rec.from == fromId
      local key = fromId .. ":" .. id
      if not recording then
        if not elro.smap[key] then
          elro.record_edge(fromId, id, { dir })
        elseif not elro.has_special(fromId, id) then
          -- our record survived, Mudlet's copy did not (a rebuilt room, an
          -- older map): put it back quietly, it is the same edge
          pcall(addSpecialExit, fromId, id, elro.smap[key])
        end
      end
      -- a new room behind a special exit has no guess: treat as a collision
      if isNew then collided = true end
      -- the glyph belongs to the room we just left
      elro.glyph_room(fromId)
    end
  elseif isNew then
    -- No edge at all (login, a teleport, from=0): no guess either. The room sits at addRoom's
    -- (0,0), which a relayout normalises TO, so it is usually on top of another room.
    collided = true
  end
  -- finalize an in-progress maprecordmove, but only if this move is the one
  -- that was armed; a move the mapper never saw (move_object) leaves
  -- elro.current stale, so a mismatch abandons the recording loudly.
  if elro.rec then
    if fromId and fromId ~= 0 and elro.rec.from == fromId then
      elro.rec_finish(id)
    else
      local armed = elro.rec.from
      elro.rec_clear()
      cecho("\n<red>[elro]: recording abandoned -- you were armed on room " ..
            tostring(armed) .. " but this move came from " ..
            ((fromId and fromId ~= 0) and tostring(fromId) or "an unknown room") ..
            ".\n<yellow>  Something moved you without telling the mapper " ..
            "(a wizard's move_object emits no !MAP line), so the recorder was " ..
            "pointing at a stale room.  You are in room " .. tostring(id) ..
            " now -- record again from here.\n<reset>")
    end
  end
  -- Advertised compass exits as stubs, so an exit you have not walked yet still
  -- shows. ⛔ THIS USED TO STUB EVERY ADVERTISED DIRECTION ON EVERY ARRIVAL, with
  -- no check for a real link and nothing ever clearing one: the comment claimed
  -- "real links overwrite them", but a stub that is never retracted leaves a fully
  -- explored room carrying a stub AND an edge in every direction, drawn for ever.
  -- That is geometry proportional to how interconnected an area is, and it renders
  -- whether or not you move. Now: stub only what has no edge, and retract the rest.
  -- the advertised compass exits, recorded and then DERIVED into stubs; see the
  -- exit-stub section above for why the record has to exist at all
  local adv = elro.stub_note(id, exits)
  elro.stub_apply(id, adv)
  -- ...and retire the stubs you have walked away from (no-op below the threshold)
  elro.stub_halo_update()
  -- 4. terrain: stored, then painted from the store. Last on purpose, after
  -- the fold inheritance has settled (highlight_paint arbitrates against it).
  -- Not in the c-space snapshot, so no touched/changed. A nil terr is an older
  -- server, never a wipe.
  if terr ~= nil then
    local _pf = pf("terr")
    -- "" is a report of no terrain, not the absence of one
    if terr == "" then terr = elro.TERR_NONE end
    if terr ~= (getRoomUserData(id, "terr") or "") then
      setRoomUserData(id, "terr", terr)
    end
    elro.terrain_paint(id, terr)
    _pf()
  end
  elro.current = id
  -- invalidate the snapshot for exactly the rooms written; a cross-area edge
  -- bumps both sides
  local _pfCs = pf("csdirty")
  for r in pairs(touched) do elro.cs_dirty(r, changed and effAid or nil) end
  _pfCs()
  if changed then
    -- dirty the canvas the room is ON (effAid), not the raw server area
    elro.dirty[effAid] = true
    -- level signal, bumped whether or not autoflush is on
    elro.gchg = (elro.gchg or 0) + 1
    if elro.autoflush then
      local urgent = collided
      if not urgent then
        -- ...and the closures: an edge this room turned out to have that we did not place it on
        -- A room placed by this call has only its placement edge. A walk between two rooms
        -- that were already placed IS the closure, so that one edge is judged, from its source.
        local _pf = pf("guess")
        local why, wd, wx
        local src = id
        if isNew or not fromId or fromId == 0 then
          why, wd, wx = elro.guess_inconsistent(id, effAid, fromId)
        else
          src = fromId
          why, wd, wx = elro.guess_inconsistent(fromId, effAid, nil, id)
        end
        _pf()
        if why then
          urgent = true
          elro.tr(string.format("onRoom: %s on %d -%s-> %s -- relayout now", why, src,
                                tostring(wd), tostring(wx)))
        end
      end
      local _pfD = pf("dirty")
      elro.markDirty(effAid, urgent)
      _pfD()
    end
  end
  local _pfV = pf("view")
  elro.recenter()
  _pfV()
  if _pfTotal then
    _pfTotal()
    local p = elro._prof or {}
    if (p.total or 0) >= (elro.profMin or 0) then
      local parts = {}
      for _, k in ipairs({ "terr", "csdirty", "guess", "dirty", "view" }) do
        if p[k] and p[k] > 0 then parts[#parts + 1] = string.format("%s %.1f", k, p[k]) end
      end
      -- what the phases do NOT account for: the exit/area writing above them
      local acc = 0
      for _, k in ipairs({ "terr", "csdirty", "guess", "dirty", "view" }) do acc = acc + (p[k] or 0) end
      cecho(string.format("\n<cyan>[prof] room %d  total %.1fms  = %s  (graph %.1f)<reset>\n",
            id, p.total or 0, table.concat(parts, ", "), (p.total or 0) - acc))
    end
  end
end

-- ---- the command fence (!MAPSEQ) -------------------------------------------
-- The link prints "!MAPSEQ <n> <command>" before every parsed command, so a
-- !MAP line that arrives before the next fence was produced by that command.
-- The fence remembers the room the client was in when it arrived; a !MAP whose
-- `from` is a different room was not this command's doing (something moved us
-- without a !MAP line, or the fence is stale). A fence older than fenceWindow
-- ms is not trusted either: a follow or a vehicle can move us long after the
-- last thing we typed. Each fence labels at most one move.
if elro.fenceShow == nil then elro.fenceShow = false end     -- keep the lines visible
if elro.fenceWindow == nil then elro.fenceWindow = 4000 end  -- ms

function elro.onSeq(n, cmd)
  cmd = (cmd or ""):gsub("^%s+", ""):gsub("%s+$", "")
  elro.fence = { n = n, cmd = cmd, from = elro.current, at = elro.now_ms() }
end

-- Mudlet's special exits of a room as a list of { to=, cmd= }. The table has
-- three shapes across builds ({cmd->id}, {id->cmd}, {id->{cmd->..}}) and the id
-- half may be a string, so the id is whichever half is a number that names a
-- room. ⛔ Iterating getSpecialExits by an assumed shape throws, and an alias
-- that throws dies silently.
function elro.special_list(id)
  local out = {}
  if type(getSpecialExits) ~= "function" then return out end
  local got, t = pcall(getSpecialExits, id)
  if not got or type(t) ~= "table" then return out end
  local function pair(a, b)
    local n = tonumber(a)
    if n and roomExists(n) then out[#out + 1] = { to = n, cmd = tostring(b) } ; return end
    n = tonumber(b)
    if n and roomExists(n) then out[#out + 1] = { to = n, cmd = tostring(a) } end
  end
  for k, v in pairs(t) do
    if type(v) == "table" then
      for k2 in pairs(v) do pair(k, k2) end
    else
      pair(k, v)
    end
  end
  return out
end

function elro.has_special(from, to)
  for _, e in ipairs(elro.special_list(from)) do if e.to == to then return true end end
  return false
end

-- The typed command behind a move fromId -> here, or nil. Consumes the fence.
function elro.fence_take(fromId)
  local f = elro.fence
  if not f or f.used then return nil end
  f.used = true
  if f.cmd == "" or f.from ~= fromId then return nil end
  if elro.now_ms() - f.at > elro.fenceWindow then return nil end
  return f.cmd
end

-- ---- manual edge recording (maprecordmove) --------------------------------
-- maprecordmove captures the exact command(s) for an exit the hook dir cannot
-- replay and stores them on the from->to edge in elro.smap (source of truth),
-- mirrored into addSpecialExit so native getPath routes through it.
elro.SDELIM = ";;"          -- internal join; never typed by the user, never sent

local function smap_split(s)
  local out, pos = {}, 1
  while true do
    local a = string.find(s, elro.SDELIM, pos, true)
    if not a then out[#out + 1] = string.sub(s, pos) ; break end
    out[#out + 1] = string.sub(s, pos, a - 1)
    pos = a + #elro.SDELIM
  end
  return out
end

function elro.load_smap()
  elro.smap = {}
  elro.smap_index_dirty()
  if type(getMapUserData) ~= "function" then return end
  local ok, s = pcall(getMapUserData, "elro.smap")
  if ok and type(s) == "string" and s ~= "" then
    for line in string.gmatch(s, "[^\n]+") do
      local k, v = string.match(line, "^(.-)\t(.+)$")
      if k and v then elro.smap[k] = v end
    end
  end
end

function elro.save_smap()
  if type(setMapUserData) ~= "function" then return end
  local parts = {}
  for k, v in pairs(elro.smap or {}) do parts[#parts + 1] = k .. "\t" .. v end
  pcall(setMapUserData, "elro.smap", table.concat(parts, "\n"))
  if type(saveMap) == "function" then pcall(saveMap) end
end

-- store cmds (a list) on the from->to edge; warn on overwrite
function elro.record_edge(from, to, cmds)
  if elro.smap == nil then elro.load_smap() end
  local key = from .. ":" .. to
  local joined = table.concat(cmds, elro.SDELIM)
  local prev = elro.smap[key]
  elro.smap[key] = joined
  elro.smap_index_dirty()
  if type(addSpecialExit) == "function" then pcall(addSpecialExit, from, to, joined) end
  elro.save_smap()
  elro.glyph_room(from)     -- the source room now has a known non-compass exit
  local shown = table.concat(cmds, " , ")
  if prev and prev ~= joined then
    cecho("\n<yellow>[elro]: edge " .. from .. "->" .. to .. " changed:<reset> " ..
          table.concat(smap_split(prev), " , ") .. "  =>  " .. shown .. "\n")
  else
    cecho("\n<green>[elro]: recorded edge " .. from .. "->" .. to ..
          " = " .. shown .. "\n<reset>")
  end
end

-- A room created anew (a GUI delete, then re-explored under the same permanent
-- id) has lost Mudlet's special exits but not our record of them, so the glyph
-- showed an exit the map could not route. Put back every recorded edge that
-- touches the room and whose other end exists. mapdelroom clears the record
-- instead, so an explicit delete stays deleted.
function elro.smap_restore(id)
  if elro.smap == nil then elro.load_smap() end
  if type(addSpecialExit) ~= "function" then return end
  for k, v in pairs(elro.smap or {}) do
    local a, b = string.match(k, "^(%d+):(%d+)$")
    a, b = tonumber(a), tonumber(b)
    if a and b and (a == id or b == id) and roomExists(a) and roomExists(b)
       and not elro.has_special(a, b) then
      pcall(addSpecialExit, a, b, v)
      if a ~= id then elro.glyph_room(a) end
    end
  end
end

-- ---- recording session -----------------------------------------------------
function elro.rec_clear()
  if elro.rec then
    if elro.rec.handler then pcall(killAnonymousEventHandler, elro.rec.handler) end
    if elro.rec.timer then pcall(killTimer, elro.rec.timer) end
  end
  elro.rec = nil
end

-- interactive capture: every command sent to the MUD until the move lands.
-- sysDataSendRequest fires AFTER Mudlet has split on the command separator, so
-- each text is one separator-free command -- exactly what we want to replay.
function elro.rec_capture(text)
  if not elro.rec or not elro.rec.interactive then return end
  text = text and text:gsub("^%s+", ""):gsub("%s+$", "") or ""
  if text ~= "" then elro.rec.cmds[#elro.rec.cmds + 1] = text end
end

function elro.rec_finish(to)
  local r = elro.rec
  if not r then return end
  if #r.cmds == 0 then
    elro.rec_clear()
    cecho("\n<red>[elro]: moved but no command captured; nothing recorded.\n<reset>")
    return
  end
  local from = r.from
  elro.rec_clear()
  elro.record_edge(from, to, r.cmds)
end

function elro.rec_start(arg)
  if arg == "cancel" then
    if elro.rec then elro.rec_clear() ; cecho("\n<yellow>[elro]: recording cancelled.\n<reset>")
    else cecho("\n<yellow>[elro]: nothing to cancel.\n<reset>") end
    return
  end
  if not elro.current then
    cecho("\n<red>[elro]: current room unknown; move once first.\n<reset>") return
  end
  elro.rec_clear()
  local from = elro.current
  if arg ~= "" then
    -- single-command form: we know the command, fire it and wait for the move
    elro.rec = { from = from, cmds = { arg } }
    cecho("\n<cyan>[elro]: recording '" .. arg .. "' from room " .. from ..
          " -- waiting for the move...\n<reset>")
    send(arg)
  else
    -- interactive form: capture each command you send until you move
    elro.rec = { from = from, cmds = {}, interactive = true }
    elro.rec.handler = registerAnonymousEventHandler("sysDataSendRequest",
      function(_, text) elro.rec_capture(text) end)
    cecho("\n<cyan>[elro]: recording from room " .. from ..
          " -- type the move command(s) now; captured on arrival." ..
          "  (maprecordmove cancel to abort)\n<reset>")
  end
  local secs = elro.rec_timeout or 12
  elro.rec.timer = tempTimer(secs, function()
    if elro.rec then
      elro.rec_clear()
      cecho("\n<red>[elro]: recording timed out (no move seen).\n<reset>")
    end
  end)
end

-- replay a path step-by-step, expanding recorded multi-command edges inline
function elro.walk_steps(dirs, path)
  if elro.smap == nil then elro.load_smap() end
  local from = elro.current
  for i = 1, #dirs do
    local to = path and path[i]
    local seq = to and elro.smap[from .. ":" .. to]
    if seq then
      for _, cmd in ipairs(smap_split(seq)) do send(cmd) end
    else
      send(dirs[i])
    end
    if to then from = to end
  end
end

-- ---- database manipulation commands ----------------------------------------

-- Delete every selected room through the mapper, so the command store is
-- cleared too. Mudlet's own Delete in the mapper menu leaves it behind (see
-- smap_restore); this is the same action offered beside it, and as
-- "mapdelroom sel".
function elro.delete_selection()
  local ids = elro.sel_rooms()
  if not ids then return end
  for _, id in ipairs(ids) do
    if roomExists(id) then elro.delete_room(id) end
  end
  cecho(string.format("\n<green>[elro]: deleted %d selected room(s) through the mapper.\n<reset>", #ids))
end

-- The mapper's right-click menu entry for it. Mudlet's built-in entries cannot
-- be removed, so ours sits beside them. Re-registered on every load: the
-- handler is anonymous and would otherwise stack.
if type(addMapEvent) == "function" and type(registerAnonymousEventHandler) == "function" then
  pcall(addMapEvent, "elro_delete_selection", "elroMapDeleteSelection", "",
        "Delete rooms (mapper)")
  if elro._mapDelHandler then pcall(killAnonymousEventHandler, elro._mapDelHandler) end
  elro._mapDelHandler = registerAnonymousEventHandler("elroMapDeleteSelection",
    function() elro.delete_selection() end)
end

-- Double-click on a room: Mudlet runs getPath from the player's room to it,
-- leaves the result in the speedWalkDir/speedWalkPath globals, and calls this
-- global. Walking through walk_steps replays recorded commands ("crawl hole")
-- where a bare direction would fail.
function doSpeedWalk()
  if not elro.current or not roomExists(elro.current) then
    cecho("\n<red>[elro]: current room unknown; move once first.\n<reset>") return
  end
  if type(speedWalkDir) ~= "table" or #speedWalkDir == 0 then
    cecho("\n<yellow>[elro]: no path to that room.\n<reset>") return
  end
  cecho(string.format("\n<cyan>[elro]: walking %d step(s).\n<reset>", #speedWalkDir))
  elro.walk_steps(speedWalkDir, speedWalkPath)
end

-- The same from the right-click menu: walk to the one selected room.
if type(addMapEvent) == "function" and type(registerAnonymousEventHandler) == "function" then
  pcall(addMapEvent, "elro_walk_to", "elroMapWalkTo", "", "Walk here (mapper)")
  if elro._mapWalkHandler then pcall(killAnonymousEventHandler, elro._mapWalkHandler) end
  elro._mapWalkHandler = registerAnonymousEventHandler("elroMapWalkTo", function()
    local ids = elro.sel_rooms()
    if not ids then return end
    if #ids ~= 1 then
      cecho("\n<yellow>[elro]: select exactly one room to walk to.\n<reset>") return
    end
    elro.gotoRoom(ids[1])
  end)
end

-- mapavoid: keep speedwalks out of a room. Mudlet's own room lock (the map's right-click
-- "Lock" sets the same flag), which getPath honours, so it holds for mapgoto, mapnear, a
-- double-click and the right-click walk alike. Stored in the map; a relayout leaves it alone.
function elro.cmd_avoid(arg, on)
  if type(lockRoom) ~= "function" or type(roomLocked) ~= "function" then
    cecho("\n<red>[elro]: this Mudlet cannot lock rooms.\n<reset>") return
  end
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "" and on == nil then                       -- bare mapavoids: list
    local rows = {}
    for id in pairs(elro.cs_all_rooms()) do
      if roomExists(id) and roomLocked(id) then rows[#rows + 1] = id end
    end
    table.sort(rows)
    cecho(string.format("\n<cyan>[elro] %d room(s) speedwalks keep out of:<reset>\n", #rows))
    for _, id in ipairs(rows) do
      cecho(string.format("<yellow>  %d<reset>  %s\n", id, getRoomName(id) or "?"))
    end
    if #rows == 0 then cecho("  (none -- 'mapavoid' marks the room you are in, 'mapavoid <id>' another)\n") end
    return
  end
  local ids = {}
  if arg == "" or arg == "here" then
    ids[1] = elro.current
  elseif arg == "sel" then
    ids = elro.sel_rooms() ; if not ids then return end
  else
    for tok in arg:gmatch("[^,%s]+") do ids[#ids + 1] = tonumber(tok) end
  end
  local n = 0
  for _, id in ipairs(ids) do
    if id and roomExists(id) then lockRoom(id, on) ; n = n + 1 end
  end
  if n == 0 then cecho("\n<red>[elro]: no such room. 'mapsearch <text>' finds ids.\n<reset>") return end
  cecho(string.format("\n<green>[elro]: speedwalks %s %d room(s).%s\n<reset>",
        on and "now keep out of" or "may use", n,
        on and " A walk with no other way round will say there is no path." or ""))
end

-- list outgoing and incoming edges for a room (default: current room)
function elro.list_edges(id)
  id = id or elro.current
  if not id or not roomExists(id) then
    cecho("\n<red>[elro]: unknown room " .. tostring(id) .. "\n<reset>") return
  end
  local nm = elro.cs_areas_swap()
  local rvia = getRoomUserData(id, "via") or ""
  cecho(string.format("\n<cyan>[elro] edges for room %d (%s) [area: %s, via: %s]:<reset>\n",
        id, getRoomName(id) or "?", nm[getRoomArea(id)] or "?",
        (rvia == "") and "(none)" or ((rvia == elro.VIA_NONE) and "(no entry room)" or rvia)))

  cecho("<yellow>  OUTGOING:<reset>\n")
  local any = false
  for dir, dest in pairs(getRoomExits(id) or {}) do
    cecho(string.format("    %s -> %d (%s)\n", dir, dest, getRoomName(dest) or "?"))
    any = true
  end
  for _, e in ipairs(elro.special_list(id)) do
    cecho(string.format("    [special '%s'] -> %d (%s)\n", e.cmd, e.to, getRoomName(e.to) or "?"))
    any = true
  end
  if not any then cecho("    (none)\n") end

  cecho("<yellow>  INCOMING:<reset>\n")
  any = false
  for rid in pairs(elro.cs_all_rooms()) do
    for dir, dest in pairs(elro.cs_exits(rid)) do
      if dest == id then
        cecho(string.format("    %d (%s) via %s\n", rid, getRoomName(rid) or "?", dir))
        any = true
      end
    end
    for _, e in ipairs(elro.special_list(rid)) do
      if e.to == id then
        cecho(string.format("    %d (%s) via [special '%s']\n", rid, getRoomName(rid) or "?", e.cmd))
        any = true
      end
    end
  end
  if not any then cecho("    (none)\n") end
end

-- delete the edge from->to (all compass dirs + special exits carrying that destination)
function elro.delete_edge(from, to)
  if not roomExists(from) then
    cecho("\n<red>[elro]: room " .. from .. " doesn't exist.\n<reset>") return
  end
  if not roomExists(to) then
    cecho("\n<red>[elro]: room " .. to .. " doesn't exist.\n<reset>") return
  end
  local removed = 0
  for dir, dest in pairs(getRoomExits(from) or {}) do
    if dest == to then
      setExit(from, -1, dir)
      removed = removed + 1
      cecho(string.format("\n<green>[elro]: removed %d -[%s]-> %d<reset>\n", from, dir, to))
    end
  end
  if type(removeSpecialExit) == "function" then
    for _, e in ipairs(elro.special_list(from)) do
      if e.to == to then
        pcall(removeSpecialExit, from, to)
        removed = removed + 1
        cecho(string.format("\n<green>[elro]: removed %d -[special '%s']-> %d<reset>\n", from, e.cmd, to))
      end
    end
  end
  if elro.smap == nil then elro.load_smap() end
  local key = from .. ":" .. to
  if elro.smap[key] then
    elro.smap[key] = nil
    elro.smap_index_dirty()
    elro.save_smap()
    cecho(string.format("<green>[elro]: cleared smap %s<reset>\n", key))
  end
  elro.glyph_room(from)     -- the source may have lost its last non-compass exit
  if removed == 0 then
    cecho(string.format("\n<yellow>[elro]: no edge %d -> %d found.<reset>\n", from, to))
    return
  end
  local fa = getRoomArea(from)
  if fa then elro.dirty[fa] = true end
  elro.cs_dirty(from) ; elro.cs_dirty(to)
  elro.flush_dirty()
end

-- delete a room and all edges leading to/from it, then relayout
function elro.delete_room(id)
  if not roomExists(id) then
    cecho("\n<red>[elro]: room " .. id .. " doesn't exist.\n<reset>") return
  end
  local rname = getRoomName(id) or "?"
  local aid = getRoomArea(id)
  local dirty = {}
  if aid then dirty[aid] = true end

  -- remove all compass exits pointing TO this room from other rooms
  for rid in pairs(getRooms() or {}) do
    if rid ~= id then
      for dir, dest in pairs(getRoomExits(rid) or {}) do
        if dest == id then
          setExit(rid, -1, dir)
          local ra = getRoomArea(rid)
          if ra then dirty[ra] = true end
        end
      end
      if type(removeSpecialExit) == "function" then
        for _, e in ipairs(elro.special_list(rid)) do
          if e.to == id then
            pcall(removeSpecialExit, rid, id)
            local ra = getRoomArea(rid)
            if ra then dirty[ra] = true end
          end
        end
      end
    end
  end

  -- clean all smap entries involving this room
  if elro.smap == nil then elro.load_smap() end
  local smapChanged = false
  for k in pairs(elro.smap) do
    local a, b = string.match(k, "^(%d+):(%d+)$")
    if tonumber(a) == id or tonumber(b) == id then
      elro.smap[k] = nil ; smapChanged = true
    end
  end
  if smapChanged then elro.smap_index_dirty() ; elro.save_smap() end

  deleteRoom(id)
  -- blunt reset: exits were rewritten on untracked rooms
  elro.cs_reset()
  if elro.current == id then elro.current = nil end

  for da in pairs(dirty) do elro.dirty[da] = true end
  elro.flush_dirty()
  cecho(string.format("\n<green>[elro]: deleted room %d (%s) and all its edges.\n<reset>", id, rname))
end

-- maphelp. Bare `maphelp` is what a player uses while playing and must stay short; everything
-- for hand-shaping, mazes, diagnosis and tuning is under `maphelp advanced`. Lives here, not in
-- the alias, so the text is editable without XML entity escaping -- the alias is one call.
local HELP_BASIC = {
  { "BASICS" },
  { "maphelp [advanced]", "this list; 'advanced' has the commands for shaping the map by hand, mazes, diagnostics and tuning" },
  { "mapupdate",          "replace this package with the newest release. Downloads first, so a failed download changes nothing; your map is untouched" },
  { "mapwin [left|right|lock|unlock|reset]", "open or close the map as a small window pinned over a top corner of the text (it opens by itself the first time). Drag its inner or bottom edge to resize it; size and corner are remembered. 'lock' removes the frame, 'reset' restores the first size and the right corner" },
  { "maplegend",          "what the colours, dots, letters and lines on the map mean" },
  { "mapexport [area] [a4] [plain]", "write one map as a picture (an SVG any browser opens): white, pale terrain tints, every room numbered and listed, as big as the map needs. Bare = the map you are on. 'a4' fits it on one sheet to print instead; 'plain' leaves the tints out. A picture, not a copy of your map" },
  { "maphelp share",      "how to copy your map to another profile, back it up, or give it to someone" },
  { "mapgoto <id|area>", "speedwalk to a room id, or the nearest room of a named area (substring ok). Double-clicking a room on the map walks there too, as does 'Walk here' in its right-click menu" },
  { "mapnear [terrain]",  "walk to the nearest room of a terrain (heal, shop, port...); bare = list the names you can search for" },
  { "mapavoid [id,...|sel]", "keep speedwalks out of a room (bare = the one you are in): a death trap, an aggressive monster. The same as 'Lock' in the map's right-click menu" },
  { "mapunavoid [id,...|sel]", "let speedwalks use it again   (mapavoids = list them)" },
  { "mapsearch <text>",  "find rooms whose name, or whose area's name, contains the text (any case); lists them with the ids 'mapgoto' takes" },

  { "FIXING THE MAP -- changes rooms, exits or areas" },
  { "mapwipe [area] [confirm]", "delete the whole map, or every room the SERVER put in one area; without 'confirm' it only reports what it would delete" },
  { "mapdelroom <id>|sel", "delete a room and every edge to or from it, then relayout; 'sel' = every room selected in the mapper (also in its right-click menu)" },
  { "mapdeledge <f> <t>", "delete all edges from room f to room t (compass + special)" },
  { "maprecordmove [cmd]","record a special or multi-step exit (bare = capture interactively)" },
  { "mapmerge <area>",    "merge that area into the one you are standing in" },
  { "mapunmerge <area>",  "undo a merge, yours or one the game suggested   (mapmerges = list both)" },
  { "maphints [on|off [area]]", "the game may suggest drawing an area on another map (a town built by several wizards). Follow the suggestions or not, for all areas or one; bare = list them" },

  { "APPEARANCE -- changes only how the map is drawn" },
  { "mapterrain [on|off]","colour rooms by terrain ('maplegend' says which colour is what)" },
  { "mapglyphs [on|off]", "a letter on rooms with an exit you type instead of a direction" },
  { "mapstubs [on|off|halo N]","what the canvas draws (rooms/edges/stubs/lines). Mudlet redraws every stub every frame, so a big part-explored area is slow: the HALO shows only stubs within N cells of you once an area has a lot. Lossless -- the record is kept" },
  { "mapvert [on|off]",   "dock up/down exits as separate floors (remembered)" },
  { "mapareamin <n>",     "smallest cluster that keeps its own area off the world map (persistent)" },
}
local HELP_ADV = {
  { "SHAPING THE MAP BY HAND" },
  { "mapcur <id|area>",   "set the current room by hand: an id, or any room of a named area" },
  { "mapfold <dir>",      "fold the branch through that exit into a submap" },
  { "mapunfold <dir>",    "undo a fold   (mapfolds = list them)" },
  { "mapsteal <id,...>",  "steal room(s) into the area you are standing in, in one relayout" },
  { "mapunsteal <id,...>","return stolen room(s) to their own area   (mapsteals = list them)" },
  { "mapouter [clear] [id,...]","mark room(s) as ON THE OUTER FACE, drawn outermost; bare = list, clear = unmark" },

  { "MAZES AND SHIFTING EXITS" },
  { "mapmaze [auto [area|.]]","fold untruthful clusters; bare = current room, auto = whole map, auto <area> = one server area" },
  { "mapmaze sel",        "mark every room selected in the viewer as maze, then fold once -- for mirror mazes, which mutate nothing and so are invisible to 'auto'" },
  { "mapunmaze [all|id,...]", "release the current room's whole maze submap; with room ids (or 'here') release only those, leaving the rest folded; 'all' releases every submap and clears the maze override   (mapmazes = list them)" },
  { "mapmazelive [area|.|clear]","what the last solve DID with this area's maze doors: which are drawn as spokes, which fell back to a stub, and whether the area was vetoed; 'clear' lifts vetoes" },
  { "mapmazefit [area|.]","report whether each maze could be ONE layout vertex: its doors, their directions, and where that vertex would sit (read-only)" },
  { "mapexitlock [<dir>]","lock the current room's compass exit(s) so the server hook cannot re-point them" },
  { "mapexitunlock [<dir>]","clear exit lock(s) on the current room (default: all)" },
  { "mapmutreset [id|area|all]","wipe exit-mutation counters (default: current room)" },

  { "APPEARANCE, IN DETAIL" },
  { "mapterrain list",    "how many rooms of each terrain the map holds, as cell and as dot; bare 'mapterrain' repaints from stored data" },
  { "mapterrain here",    "what the server actually sent for THIS room and what it resolved to -- separates 'not sent' from 'not coloured'" },
  { "mapterrain halo ...","tune the secondary ring: <radius> [rim alpha] [centre alpha]; bare = current values" },
  { "mapglyphs list",     "which rooms are glyphed, their exit names and the source of each (a/r/s)" },
  { "mapglyphs auto on|off","count auto special exits as glyph evidence; off = advertised + recorded only" },
  { "mapvert [area|all]", "up/down census, and what the last pack honoured and drew" },

  { "DIAGNOSTICS -- read the layout, change nothing" },
  { "mapprofile [on|off|ms]","time the phases of each move (graph / terrain / guess / relayout / view) and print the ones over <ms>; for finding what a slow move is actually doing" },
  { "mapecho [on|off]",   "should a relayout report when it finishes (time, frames, the solver's profile)? Off by default, and then no relayout prints anything" },
  { "mapoff [id]",        "what is recorded for a room about exits that leave the map: the record, the stubs, the custom lines" },
  { "mapack",             "tell the game which client this is, again. Needed only if 'maplink' says no client has answered" },
  { "mapaudit [all]",     "exits whose geometry the trustworthy (walked-both-ways) exits refute -- usually mistyped links" },
  { "mapedges [<id>]",    "outgoing and incoming edges for a room (default: current)" },
  { "mapmut [<id>]",      "per-exit mutation counters and lock state (default: current room)" },
  { "mapcrossings",       "every crossing as edge x edge, and who licensed it (cost / proven wire / nobody)" },
  { "mapcaps",            "why each branch CAPed during a render (the blocker from the slide attempt)" },
  { "mapdump [sel|all]",  "dump this area's rooms/coords/exits; 'sel' = viewer selection only, 'all' = every room's area + coords" },

  { "REPLAY -- what the walk did, step by step" },
  { "mapsteps",           "list room placement steps (set 'lua elro.stepDebug=true' before 'maprelayout this')" },
  { "mapstep [back|<id>|step n|off|reset]","no arg = advance; back = one step back; an id = stop just before that room is placed" },
  { "maptop [n]",         "slowest placement steps of the last relayout (set 'lua elro.stepTime=true' first)" },
  { "maplever [<ek>..]",  "force named lever(s) to the front of every ranking; no arg = list, off = clear" },

  { "TUNING, TIMING AND STATE" },
  { "maprelayout [all|this]", "redraw the maps that changed; 'all' = every map, 'this' = the one you are looking at, changed or not. It happens by itself; this is for after a setting change" },
  { "mapauto on|off|idle N", "auto relayout: at once when the drawing is visibly wrong, else N secs after you stop (default ON, 3s)" },
  { "mapknobs [reset]",   "every knob and probe OVERRIDDEN this session; 'reset' clears them. elro survives mapreload and a git checkout, so a knob left set looks exactly like a code change that did nothing -- run this before trusting any measurement" },
  { "mapbg [on|off|cancel|slice N]","background (non-freezing) relayout: state, toggle, abort, or per-frame ms budget" },
  { "mapbg gc N | hook N","collect between frames / report the SOURCE LINES that blew the frame budget" },
  { "mapwd <secs|off>",   "walk watchdog: abort a runaway relayout and say where it was, instead of freezing Mudlet (default 60s)" },
  { "mapcs [reset]",      "c-space snapshot stats; reset forces a full re-read of Mudlet room state" },
  { "mapdebug on|off",    "toggle layout step tracing" },
  { "mapreload",          "re-read lua/modules.lua and every module from disk -- no package reinstall needed; also drops the c-space snapshot, since a reload heals stale CODE and that cache is stale DATA (mapcs reset does it alone)" },
  { "mapsrc [path]",      "show or set the directory those modules are loaded from (persistent)" },
}
-- maphelp share: moving the MAP itself is Mudlet's job, and is what people expect 'mapexport'
-- to do. Everything this package knows is in Mudlet's map file (room and map user data), so
-- Mudlet's own copy carries all of it.
local HELP_SHARE = {
  "'mapexport' makes a picture to print. It does not copy your map. The map itself lives in "
    .. "your Mudlet profile, and Mudlet moves it:",
  "",
  "TO ANOTHER PROFILE OF YOURS|Settings, the Mapper tab, 'Copy map to other profile(s)': pick "
    .. "the profiles and press Copy.",
  "TO A FILE|Settings, the Mapper tab, 'Save map...'. A backup, or something to hand to "
    .. "another player.",
  "FROM A FILE|Settings, the Mapper tab, 'Load map...'. This REPLACES the map in that profile; "
    .. "the two are not merged. Save your own first if you may want it back.",
  "",
  "After a map is loaded or copied into a profile that is open, close and reopen that profile "
    .. "so the mapper reads the new map from the start.",
  "",
  "The file carries everything: rooms, exits, the special exits you recorded, terrain, merges, "
    .. "folds and the rooms speedwalks keep out of. Only the map window's size and corner "
    .. "belong to the profile. The receiving profile needs this package too, and 'maplink on' "
    .. "in the game to keep mapping.",
  "",
  "A map shows where you have been. Handing one over hands over that exploring.",
}

function elro.map_help(arg)
  if (arg or ""):match("^%s*shar") then
    local width = elro.help_width()
    cecho("\n<cyan>ElrohirMapper  --  moving your map<reset>\n\n")
    for _, p in ipairs(HELP_SHARE) do
      local head, body = p:match("^(.-)|(.+)$")
      if head then cecho("<yellow>  " .. head .. "<reset>\n") end
      for _, l in ipairs(elro.wrap_text(body or p, width - (head and 5 or 3))) do
        cecho((head and "    " or "  ") .. l .. "\n")
      end
      if p == "" then cecho("\n") end
    end
    cecho("\n")
    return
  end
  local adv = (arg or ""):match("adv") ~= nil
  -- Wrapped here, with a hanging indent: left to Mudlet a long row breaks back to column 0.
  -- A narrow window gets a narrower command column; a command too long for it takes a line
  -- of its own.
  local width = elro.help_width()
  local col = width >= 90 and 30 or 22
  local function emit(rows)
    for _, row in ipairs(rows) do
      if #row == 1 then
        cecho("\n<cyan>" .. row[1] .. "<reset>\n")
      else
        local lines = elro.wrap_text(row[2], width - col - 1)
        local own = #row[1] + 2 >= col
        if own then cecho("<yellow>  " .. row[1] .. "<reset>\n") end
        for i, l in ipairs(lines) do
          if i == 1 and not own then
            cecho(string.format("<yellow>  %s<reset>%s%s\n", row[1],
                  string.rep(" ", col - 2 - #row[1]), l))
          else
            cecho(string.rep(" ", col) .. l .. "\n")
          end
        end
      end
    end
  end
  cecho("\n<cyan>ElrohirMapper " .. tostring(elro.VERSION) .. "<reset>  --  "
        .. (adv and "advanced commands" or "everyday commands") .. "\n")
  -- two help systems, and a new player cannot tell which is which
  for _, l in ipairs(elro.wrap_text("These commands belong to this Mudlet package and are never "
      .. "sent to the game. The game's own side is 'help maplink' (switching the stream on and "
      .. "off).", width - 3)) do
    cecho("<cyan>  " .. l .. "<reset>\n")
  end
  emit(adv and HELP_ADV or HELP_BASIC)
  if not adv then
    local n = 0
    for _, row in ipairs(HELP_ADV) do if #row > 1 then n = n + 1 end end
    cecho("\n")
    emit({ { "maphelp advanced", string.format(
      "%d more: shaping the map by hand, mazes, diagnostics, tuning", n) } })
  end
  cecho("\n")
end

-- mapwipe: delete the whole map, or every room the SERVER reported in one area.
-- Scoped on `sarea` (room user data, written by onRoom), NOT on the canvas the rooms were
-- laid out into: a canvas tab holds folded, stolen and merged rooms from other server areas,
-- so wiping "the area you can see" would take rooms the server never put there.
-- Nothing is deleted without `confirm`; the bare form reports what it WOULD delete.
function elro.map_wipe(arg)
  local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
  arg = trim(arg or "")
  -- `confirm` is the last word; whatever precedes it is the area name
  local head, tail = arg:match("^(.-)%s*(confirm)$")
  local confirm = tail ~= nil
  local area = trim(confirm and head or arg)
  local af = area ~= "" and area:lower() or nil

  local all = elro.cs_all_rooms()
  local scope, n = {}, 0
  for id in pairs(all) do
    if not af or (getRoomUserData(id, "sarea") or ""):lower() == af then
      scope[id] = true ; n = n + 1
    end
  end

  if af and n == 0 then
    -- name the server areas that DO exist: a typo and an empty area look identical otherwise
    local seen, names = {}, {}
    for id in pairs(all) do
      local sa = getRoomUserData(id, "sarea") or ""
      if sa ~= "" and not seen[sa] then seen[sa] = true ; names[#names + 1] = sa end
    end
    table.sort(names)
    cecho(string.format("\n<red>[elro]: no room has server area '%s'.<reset>\n  known: %s\n",
                        area, #names > 0 and table.concat(names, ", ") or "(none)"))
    return
  end

  if not confirm then
    cecho(string.format("\n<yellow>[elro]: mapwipe would delete %d room(s) -- %s.<reset>"
      .. "\n  Nothing has been deleted. To go ahead: <cyan>mapwipe %sconfirm<reset>\n",
      n, af and ("server area '" .. area .. "'") or "THE WHOLE MAP",
      af and (area .. " ") or ""))
    return
  end

  if not af then
    deleteMap()
    elro.current = nil
    elro.smap = {}
    if type(elro.save_smap) == "function" then elro.save_smap() end
    elro.cs_reset()
    cecho(string.format("\n<green>[elro]: map wiped -- %d room(s) deleted. Walk to rebuild.\n<reset>", n))
    return
  end

  -- Scoped: drop every edge from a SURVIVING room into the scope in one pass, rather than
  -- calling delete_room per room (that rescans the whole map for each one).
  local dirty = {}
  for rid in pairs(all) do
    if not scope[rid] then
      for dir, dest in pairs(getRoomExits(rid) or {}) do
        if scope[dest] then
          setExit(rid, -1, dir)
          local ra = getRoomArea(rid) ; if ra then dirty[ra] = true end
        end
      end
      if type(removeSpecialExit) == "function" then
        for _, e in ipairs(elro.special_list(rid)) do
          if scope[e.to] then
            pcall(removeSpecialExit, rid, e.to)
            local ra = getRoomArea(rid) ; if ra then dirty[ra] = true end
          end
        end
      end
    end
  end
  for id in pairs(scope) do
    local ra = getRoomArea(id) ; if ra then dirty[ra] = true end
    pcall(deleteRoom, id)
  end
  if elro.smap == nil then elro.load_smap() end
  local smapChanged = false
  for k in pairs(elro.smap) do
    local a, b = k:match("^(%d+):(%d+)$")
    if a and (scope[tonumber(a)] or scope[tonumber(b)]) then
      elro.smap[k] = nil ; smapChanged = true
    end
  end
  if smapChanged then elro.smap_index_dirty() ; elro.save_smap() end
  elro.cs_reset()                                  -- exits were rewritten on untracked rooms
  if elro.current and scope[elro.current] then elro.current = nil end
  for da in pairs(dirty) do elro.dirty[da] = true end
  elro.flush_dirty()
  cecho(string.format("\n<green>[elro]: wiped %d room(s) of server area '%s'.\n<reset>", n, area))
end

-- search room names and area names; print matching rooms with IDs
function elro.search_rooms(pat)
  if not pat or pat == "" then
    cecho("\n<red>[elro]: mapsearch <text>, e.g. 'mapsearch church'\n<reset>") return
  end
  local lpat = pat:lower()
  local nm = elro.cs_areas_swap()
  local results = {}
  for id in pairs(elro.cs_all_rooms()) do
    local rname = (getRoomName(id) or ""):lower()
    local aname = (nm[getRoomArea(id)] or ""):lower()
    if rname:find(lpat, 1, true) or aname:find(lpat, 1, true) then
      results[#results + 1] = id
    end
  end
  table.sort(results)
  if #results == 0 then
    cecho(string.format("\n<yellow>[elro]: no rooms matching '%s'.\n<reset>", pat)) return
  end
  cecho(string.format("\n<cyan>[elro] %d room(s) matching '%s':<reset>\n", #results, pat))
  for _, id in ipairs(results) do
    local x, y, z = getRoomCoordinates(id)
    local aname = nm[getRoomArea(id)] or "?"
    cecho(string.format("<yellow>  %d<reset>  %-40s  area=%-15s  (%d,%d,%d)\n",
          id, getRoomName(id) or "?", aname, x, y, z))
  end
end

-- Resolve an area name for lookup (not elro.areaId, which would CREATE one).
-- Exact case-insensitive match wins, else a unique substring.
-- Returns aid, name  |  nil, nil, {names...} when ambiguous  |  nil.
function elro.find_area(name)
  local areas = elro.cs_areas()
  if areas[name] then return areas[name], name end
  local want = name:lower()
  local subs = {}
  for nm, aid in pairs(areas) do
    local l = nm:lower()
    if l == want then return aid, nm end
    if l:find(want, 1, true) then subs[#subs + 1] = { aid = aid, name = nm } end
  end
  table.sort(subs, function(a, b) return a.name < b.name end)
  if #subs == 1 then return subs[1].aid, subs[1].name end
  if #subs > 1 then
    local names = {}
    for _, c in ipairs(subs) do names[#names + 1] = c.name end
    return nil, nil, names
  end
  return nil
end

-- mapgoto <area>: walk to the nearest room of that area. "Nearest" is over the lowest-id
-- rooms only, capped at elro.gotoScan: each candidate costs a whole-map getPath.
function elro.goto_area(name)
  local aid, nm, amb = elro.find_area(name)
  if amb then
    cecho("\n<yellow>[elro]: '" .. name .. "' is ambiguous: " .. table.concat(amb, ", ") .. "\n<reset>")
    return
  end
  if not aid then
    cecho("\n<red>[elro]: no area matching '" .. name .. "'.\n<reset>") return
  end
  if not elro.current then
    cecho("\n<red>[elro]: current room unknown; move once first.\n<reset>") return
  end
  if roomExists(elro.current) and getRoomArea(elro.current) == aid then
    cecho("\n<green>[elro]: already in '" .. nm .. "'.\n<reset>") return
  end
  local rooms = {}
  for _, r in ipairs(elro.cs_area_rooms(aid)) do
    if roomExists(r) then rooms[#rooms + 1] = r end
  end
  if #rooms == 0 then
    cecho("\n<red>[elro]: area '" .. nm .. "' has no rooms.\n<reset>") return
  end
  table.sort(rooms)
  local best, bestLen, tried = nil, math.huge, 0
  for _, r in ipairs(rooms) do
    if tried >= (elro.gotoScan or 30) then break end
    if r ~= elro.current then
      tried = tried + 1
      if getPath(elro.current, r) then
        local n = #(speedWalkPath or {})
        if n < bestLen then best, bestLen = r, n end
      end
    end
  end
  if not best then
    cecho("\n<red>[elro]: no known path into '" .. nm .. "'.\n<reset>") return
  end
  -- Re-run getPath for the winner: speedWalkDir/speedWalkPath are globals left by the LAST
  -- call, not the chosen candidate.
  if getPath(elro.current, best) then
    cecho(string.format("\n<green>[elro]: walking to %s room %d (%d step(s)).\n<reset>", nm, best, bestLen))
    elro.walk_steps(speedWalkDir, speedWalkPath)
  else
    cecho("\n<red>[elro]: no known path into '" .. nm .. "'.\n<reset>")
  end
end

-- mapgoto dispatch: a bare number is a room id, anything else is an area name.
function elro.goto_target(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "" then
    cecho("\n<yellow>[elro]: usage: mapgoto <room id|area name>\n<reset>") return
  end
  if arg:match("^%d+$") then elro.gotoRoom(tonumber(arg)) else elro.goto_area(arg) end
end

function elro.gotoRoom(target)
  if not target or not roomExists(target) then
    cecho("\n<red>[elro]: unknown room id.\n<reset>") return
  end
  if not elro.current then
    cecho("\n<red>[elro]: current room unknown; move once first.\n<reset>") return
  end
  if elro.current == target then return end
  if getPath(elro.current, target) then
    elro.walk_steps(speedWalkDir, speedWalkPath)
  else
    cecho("\n<red>[elro]: no known path to " .. target .. ".\n<reset>")
  end
end

-- ---- mapnear: walk to the nearest room of a given terrain -------------------
-- Distance is HOPS, from ONE breadth-first sweep of the known map, so every
-- terrain is answered by the same pass. goto_area's shape (a whole-map getPath
-- per candidate, capped at gotoScan) cannot be used here: the candidates are not
-- a handful of low ids but every healing room on the map.
-- getPath still decides the actual walk -- the sweep only picks the target.

elro.nearKeep = elro.nearKeep or 5   -- candidates kept per terrain, for the getPath retry

-- Every room reachable in one step: compass exits and special exits, the same
-- pair getPath routes over (maprecordmove mirrors its sequences into
-- addSpecialExit for exactly that reason).
-- ⛔ getSpecialExits' SHAPE IS NOT FIXED ACROSS MUDLET VERSIONS -- it has been
-- {cmd -> id}, {id -> cmd} and {id -> {cmd -> ...}}, which is why room_nonstd
-- pcalls it and inspects BOTH halves of every pair. This assumed one shape, so on
-- the other one it handed a command STRING to roomExists, threw, and took the
-- whole of mapnear down with it -- and silently, because the bare catalogue is
-- the only path that does not sweep. Take a room id from either half, and never
-- trust one unchecked. (A special-exit command that is itself a bare number
-- would be read as an id; roomExists still has to agree, and no such command
-- exists here.)
local function near_succ(id)
  local out = {}
  local function push(v)
    local n = tonumber(v)
    if n and roomExists(n) then out[#out + 1] = n end
  end
  for _, dest in pairs(getRoomExits(id) or {}) do push(dest) end
  if type(getSpecialExits) == "function" then
    local got, t = pcall(getSpecialExits, id)
    if got and type(t) == "table" then
      for k, v in pairs(t) do
        push(k)
        if type(v) == "table" then for k2 in pairs(v) do push(k2) end else push(v) end
      end
    end
  end
  return out
end

-- name -> { {id=, dist=}, ... }, nearest first, for every terrain reachable from
-- `from`, plus how many rooms the sweep reached. BFS order is what makes the
-- lists sorted; nearKeep of them are kept so a target getPath refuses is not a
-- dead end. The room count is what separates "no shop out there" from "the sweep
-- went nowhere", which is the only question a failed mapnear raises.
function elro.near_scan(from)
  local hit, dist, q, qh = {}, { [from] = 0 }, { from }, 1
  while qh <= #q do
    local u = q[qh] ; qh = qh + 1
    local d = dist[u]
    for name in string.gmatch(getRoomUserData(u, "terr") or "", "[^,]+") do
      if elro.terrain[name] then
        local l = hit[name] ; if not l then l = {} ; hit[name] = l end
        if #l < elro.nearKeep then l[#l + 1] = { id = u, dist = d } end
      end
    end
    for _, v in ipairs(near_succ(u)) do          -- near_succ has already vetted these
      if dist[v] == nil then dist[v] = d + 1 ; q[#q + 1] = v end
    end
  end
  return hit, #q
end

-- Terrain names matching `pat`: an exact name wins outright, else every name it
-- occurs in. Sorted, so an ambiguity list reads the same every time.
function elro.near_match(pat)
  pat = (pat or ""):lower()
  if elro.terrain[pat] then return { pat } end
  local out = {}
  for name in pairs(elro.terrain) do
    if name:find(pat, 1, true) then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

local function near_line(name, e)
  return string.format("  <white>%-17s<reset>%s  room %d (%s)\n", name,
        (e.dist == 0) and "    here" or string.format("%4d step%s", e.dist, (e.dist == 1) and "" or "s"),
        e.id, getRoomName(e.id) or "?")
end

-- Walk to the first of `cands` getPath will actually route to.
local function near_walk(name, cands)
  for _, e in ipairs(cands) do
    if e.id == elro.current then
      cecho("\n<green>[elro]: you are standing in a " .. name .. " room.\n<reset>") return
    end
    if getPath(elro.current, e.id) then
      cecho(string.format("\n<green>[elro]: walking to the nearest %s -- room %d (%s), %d step(s).\n<reset>",
            name, e.id, getRoomName(e.id) or "?", #(speedWalkDir or {})))
      elro.walk_steps(speedWalkDir, speedWalkPath)
      return
    end
  end
  cecho("\n<red>[elro]: no known path to a " .. name .. " room.\n<reset>")
end

-- The searchable names, in the palette's own ladder, as { group, {names...} }.
-- Groups are ordered by their best rank, so the catalogue reads in the same
-- priority order as the colours it names.
function elro.near_catalog()
  local byGroup, order = {}, {}
  for name, t in pairs(elro.terrain) do
    local g = byGroup[t.group]
    if not g then
      g = { group = t.group, best = t.rank, names = {} }
      byGroup[t.group] = g ; order[#order + 1] = g
    end
    if t.rank < g.best then g.best = t.rank end
    g.names[#g.names + 1] = { name = name, rank = t.rank }
  end
  table.sort(order, function(a, b) return a.best < b.best end)
  for _, g in ipairs(order) do
    table.sort(g.names, function(a, b) return a.rank < b.rank end)
    local flat = {}
    for _, e in ipairs(g.names) do flat[#flat + 1] = e.name end
    g.names = flat
  end
  return order
end

-- mapnear [terrain]: bare lists every name you can search for; with a name
-- (substring ok) walks to the nearest room carrying it. A pattern matching
-- several terrains lists those with their distances rather than guessing between
-- them, which is also how you narrow down the name you meant.
function elro.map_near(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "" then
    cecho("\n<cyan>[elro] mapnear <terrain> -- walks you to the nearest one. Searchable:<reset>\n")
    for _, g in ipairs(elro.near_catalog()) do
      cecho(string.format("  <yellow>%-9s<reset>%s\n", g.group, table.concat(g.names, "  ")))
    end
    cecho("<yellow>  A substring is enough: 'mapnear heal', 'mapnear shop'.\n<reset>")
    return
  end
  if not elro.current or not roomExists(elro.current) then
    cecho("\n<red>[elro]: current room unknown; move once first.\n<reset>") return
  end
  local names = elro.near_match(arg)
  if #names == 0 then
    cecho("\n<red>[elro]: no terrain called '" .. arg .. "'; bare 'mapnear' lists them.\n<reset>")
    return
  end

  -- ⛔ The sweep touches Mudlet APIs whose shapes vary by build, and a throw in
  -- here is INVISIBLE: an alias that dies prints to Mudlet's error console, not
  -- the main window, so the command simply does nothing. That cost a round trip.
  local got, hit, swept = pcall(elro.near_scan, elro.current)
  if not got then
    cecho("\n<red>[elro]: the map sweep failed: " .. tostring(hit) .. "\n<reset>") return
  end
  if #names == 1 then
    if not hit[names[1]] then
      -- Terrain is only learned when you WALK INTO a room, so a freshly added one
      -- is unknown everywhere until revisited -- by far the likeliest reason for
      -- an empty answer, and invisible without saying it.
      cecho(string.format(
        "\n<yellow>[elro]: no %s room among the %d room(s) reachable from here.\n" ..
        "  Terrain is only learned on entry, so a newly added one shows up as you revisit.\n" ..
        "  'mapterrain list' is what the map actually knows.\n<reset>", names[1], swept))
      return
    end
    near_walk(names[1], hit[names[1]])
    return
  end

  -- Ambiguous: list the matches, reachable ones first, so it doubles as the answer
  -- to "which of these is actually near me".
  table.sort(names, function(a, b)
    local da = hit[a] and hit[a][1].dist or math.huge
    local db = hit[b] and hit[b][1].dist or math.huge
    if da ~= db then return da < db end
    return a < b
  end)
  cecho("\n<cyan>[elro] '" .. arg .. "' matches " .. #names .. " terrains:<reset>\n")
  for _, name in ipairs(names) do
    if hit[name] then cecho(near_line(name, hit[name][1]))
    else cecho(string.format("  <white>%-17s<reset>%8s\n", name, "none yet")) end
  end
  cecho("<yellow>  Name one to walk there.\n<reset>")
end
