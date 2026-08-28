-- STAGE 0 CENSUS for [[plan_family_shearfree]]: the DIAGONAL FAMILY table over a dump's bounded
-- face rings.
--
--   luajit analysis/test_families.lua analysis/dagoth.txt
--   luajit analysis/test_families.lua analysis/rand.txt --diag-only
--
-- Drives `elro.facefit(rooms, adj, topoOnly)` and `elro.face_families` -- the ENGINE's own face
-- enumeration and the engine's own family rule -- rather than re-implementing either. A harness
-- that models the input differently from the engine is not a proxy for it (the lesson `walk_adj`
-- taught test_face_cost: 61 bounded faces in game against 60 offline, and every number low).
--
-- ⭐ THE PRE-REGISTERED PREDICTIONS this exists to test:
--     rand    the rhombus            -> 2 same-family pairs, 0 mixed-adjacent
--     dagoth  face 8766/8781         -> 2 same-family pairs, 0 mixed-adjacent
--     nib     face 1892-1906-1951... -> 0 same-family pairs, 1 mixed-adjacent (the apex 1951)
-- If those do not come out, the family model is wrong and the plan stops at stage 0.
dofile("analysis/engine_load.lua")
local dumpPath = arg[1] or error("usage: test_families.lua <dump> [--diag-only]")
local diagOnly = false
for i = 2, #arg do if arg[i] == "--diag-only" then diagOnly = true end end

local DELTA = { east = {1,0}, northeast = {1,1}, north = {0,1}, northwest = {-1,1},
                west = {-1,0}, southwest = {-1,-1}, south = {0,-1}, southeast = {1,-1} }
local ADJ, ORDER = {}, {}
for ln in io.lines(dumpPath) do
  local id, ex = ln:match("^%s*(%d+) %([^)]*%) area=%S+ %[(.*)%]%s*$")
  if id then
    id = tonumber(id) ; ORDER[#ORDER + 1] = id ; ADJ[id] = ADJ[id] or {}
    for d, t in ex:gmatch("(%a+)%->(%d+)") do if DELTA[d] then ADJ[id][d] = tonumber(t) end end
  end
end
ADJ = elro.walk_adj(ADJ)                 -- the engine's own input shaping, not a hand-rolled one

local _, rep = elro.facefit(ORDER, ADJ, true)
if not rep or not rep.rings or #rep.rings == 0 then
  print(("%s: no bounded face(s) (%d rooms, core %d)"):format(dumpPath, #ORDER, (rep and rep.core) or 0))
  os.exit(0)
end
local F = elro.face_families(rep.rings, rep.dirOf)

local nSame, nMixed, nDiagRing = 0, 0, 0
local rows = {}
for k, g in ipairs(rep.rings) do
  local R = F.rings[k]
  if #R.diag > 0 then
    nDiagRing = nDiagRing + 1
    nSame = nSame + #R.same ; nMixed = nMixed + #R.mixed
    local fam = {}
    for i = 1, R.n do fam[i] = R.fam[i] or "-" end
    local same = {}
    for _, p in ipairs(R.same) do same[#same + 1] = R.key[p[1]] .. "/" .. R.key[p[2]] end
    local mixed = {}
    for _, p in ipairs(R.mixed) do mixed[#mixed + 1] = R.key[p[1]] .. "^" .. p[3] .. "^" .. R.key[p[2]] end
    rows[#rows + 1] = { k = k, n = R.n, nd = #R.diag, ns = #R.same, nm = #R.mixed,
                        fam = table.concat(fam), ring = table.concat(g, "-"),
                        same = table.concat(same, " "), mixed = table.concat(mixed, " ") }
  end
end
table.sort(rows, function(a, b)
  if a.ns ~= b.ns then return a.ns > b.ns end
  if a.nm ~= b.nm then return a.nm > b.nm end
  return a.k < b.k
end)
print(("%s: %d rooms, %d bounded face(s), %d with diagonal walls -- %d same-family pair(s),"
  .. " %d mixed-ADJACENT corner(s)"):format(dumpPath, #ORDER, #rep.rings, nDiagRing, nSame, nMixed))
print(("%-5s %5s %5s %5s %5s  %s"):format("face", "edges", "diag", "same", "mixed", "families / ring"))
for _, r in ipairs(rows) do
  if not diagOnly or r.ns > 0 or r.nm > 0 then
    local ring = (#r.ring > 58) and (r.ring:sub(1, 55) .. "...") or r.ring
    print(("%-5d %5d %5d %5d %5d  %-14s %s"):format(r.k, r.n, r.nd, r.ns, r.nm, r.fam, ring))
    if r.same ~= "" then print(("        same-family cut(s): %s"):format(r.same)) end
    if r.mixed ~= "" then print(("        mixed corner(s):    %s"):format(r.mixed)) end
  end
end
