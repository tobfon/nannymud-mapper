-- Key formats: every string the engine uses to name an edge, a crossing or an
-- incidence, defined once. These strings are a CONTRACT, not an implementation detail:
-- they are index keys, mapstep trace labels read by humans, and _rank_cands' final
-- sort key. Changing a key's TEXT is a layout change and must be A/B'd as one.

elro = elro or {}
local K = {}
elro.k = K

-- Canonical undirected edge key: the two room ids ascending, ":"-joined. Numeric order
-- (ids are numbers), not string order.
function K.edge(a, b)
  return (a < b) and (a .. ":" .. b) or (b .. ":" .. a)
end

-- Same edge as an opaque integer -- SET MEMBERSHIP ONLY, for hot function-local dedup
-- tables. Never let one of these escape to anything printed, parsed, ordered, or
-- composed into a bigger key: a table written with eid and read with edge misses
-- silently. When in doubt use K.edge. Exact and collision-free for ids < 2^26.
local EID_SHIFT = 2 ^ 26
function K.eid(a, b)
  return (a < b) and (a * EID_SHIFT + b) or (b * EID_SHIFT + a)
end

-- An unordered pair of edges (a crossing): both edge keys, "|"-joined, either argument
-- order yielding the same key.
function K.cross(au, av, bu, bv)
  return K.pair(K.edge(au, av), K.edge(bu, bv))
end

-- Same join over two already-built edge keys. String comparison here (both args are
-- strings) -- consistent, but not the same ordering rule as K.edge's numeric one.
function K.pair(k1, k2)
  return (k1 < k2) and (k1 .. "|" .. k2) or (k2 .. "|" .. k1)
end

-- A room-on-edge incidence: "room@u:v", e.g. `488@95:96` in a mapstep trace.
function K.roomedge(r, u, v)
  return r .. "@" .. K.edge(u, v)
end

-- Two readers with two strictnesses, deliberately: roomedge_room answers only "which
-- room" (lenient), roomedge_parse demands the whole r@u:v shape. Neither is a general
-- "looks like r@..." test -- other "@" formats in the engine are parsed at their own sites.
function K.roomedge_room(k)
  return tonumber(tostring(k):match("^(%d+)@"))
end

function K.roomedge_parse(k)
  local r, u, v = tostring(k):match("^(%d+)@(%d+):(%d+)$")
  return r, u, v
end

return K
