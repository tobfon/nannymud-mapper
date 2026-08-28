-- ⭐ Y-FORM PROTOTYPE -- class variable is the TARGET COORDINATE, not a displacement.
--
-- Today `eqw_field_shift` gives each equality class ONE displacement `u[a][c]`, and every member
-- gets that same delta. That is only valid when the class is already FLAT (all members share the
-- coordinate the equality asserts). Where it is not -- an equality asserted through unplaced
-- CONDUITS, or a lying placed edge -- one displacement can never flatten it, and the build voids.
--
-- Y-form: the variable is the row/column's final coordinate `Y[c]`; member delta = Y[c] - coord[r].
-- ⭐ EXACT WHERE FLAT:  g + u_x - u_r  ==  (coord[x]+u_x) - (coord[r]+u_r)  ==  Y_x - Y_r
--   so it differs from today's model ONLY on non-flat classes, which is where today's model is wrong.
--
-- usage: luajit yform.lua <placed-dump> <full-graph-dump> <axis> <startRoom> <anchorRoom>
--   e.g. luajit yform.lua mael_step84.txt maelstorm_new.txt 2 4241 4240
local D = { north={0,1}, south={0,-1}, east={1,0}, west={-1,0},
            northeast={1,1}, northwest={-1,1}, southeast={1,-1}, southwest={-1,-1} }
local placedF, fullF = arg[1], arg[2]
local AX     = tonumber(arg[3] or 2)
local START, ANCHOR = arg[4], arg[5]
local ANCHORR = ANCHOR

local function load(f, into)
  local coord, adj, ids = {}, {}, {}
  for line in io.lines(f) do
    local id,x,y = line:match("^%s*(%d+)%s+%(?(-?%d+),?%s*(-?%d+)")
    if id then
      coord[id] = { tonumber(x), tonumber(y) } ; adj[id] = {} ; ids[#ids+1] = id
      for d,t in line:gmatch("(%a+)%s*%->%s*(%d+)") do if D[d] then adj[id][d] = t end end
    end
  end
  return coord, adj, ids
end
local pcoord, padj, pids = load(placedF)
local _,     fadj, fids = load(fullF)
-- full adjacency = the walk's `adj` (every KNOWN room, placed or not)
local adj = {}
for _,r in ipairs(fids) do adj[r] = fadj[r] end
for _,r in ipairs(pids) do adj[r] = adj[r] or padj[r] end
local placed = {} ; for _,r in ipairs(pids) do placed[r] = true end

-- ---------- the equality partition, INCLUDING unplaced conduits (what eqw_classes carries) ------
local par = {}
local function find(r) local x=par[r] ; if x==nil then par[r]=r return r end
  while par[x]~=x do par[x]=par[par[x]] ; x=par[x] end ; par[r]=x return x end
local function uni(a,b) local A,B=find(a),find(b) ; if A~=B then par[A]=B end end
local nUni = 0
for r,ex in pairs(adj) do
  for d,w in pairs(ex) do
    local de = D[d]
    -- ⚠ the CLOSURE EDGE is excluded -- it is the target of the repair
    local isClosure = (r==START and w==ANCHOR) or (r==ANCHOR and w==START)
    if de and adj[w] and not isClosure and de[AX]==0 then uni(r,w) ; nUni = nUni + 1 end
  end
end
local mem = {}
for _,r in ipairs(pids) do local c=find(r) ; mem[c]=mem[c] or {} ; table.insert(mem[c], r) end
for c,l in pairs(mem) do table.sort(l, function(a,b) return tonumber(a)<tonumber(b) end) end

print(("== %s : %d placed, axis %d, closure %s-%s (excluded from the partition) =="):format(
  placedF, #pids, AX, tostring(START), tostring(ANCHOR)))
print("-- NON-FLAT CLASSES (placed members disagreeing on the coordinate the equality asserts) --")
local nflat, nnon = 0, 0
for c,l in pairs(mem) do
  local vs, n = {}, 0
  for _,r in ipairs(l) do local v=pcoord[r][AX] ; if not vs[v] then vs[v]=true ; n=n+1 end end
  if n > 1 then
    nnon = nnon + 1
    local s = {}
    for _,r in ipairs(l) do s[#s+1] = ("%s@%d"):format(r, pcoord[r][AX]) end
    print(("   class %-6s %d member(s), %d distinct coord(s): %s"):format(c, #l, n, table.concat(s," ")))
  else nflat = nflat + 1 end
end
print(("   => %d flat, %d NON-FLAT"):format(nflat, nnon))

-- ---------- constraints: for each placed along-axis edge, sg*(Y[cx]-Y[cr]) >= m ----------
local cons = {}
for _,r in ipairs(pids) do
  for d,w in pairs(padj[r]) do
    local de = D[d]
    if de and placed[w] and de[AX] ~= 0 then
      local cr, cx = find(r), find(w)
      if cr ~= cx then cons[#cons+1] = { cr=cr, cx=cx, sg=de[AX], m=1, r=r, w=w, d=d } end
    end
  end
end

local function solve(pinC, pinV, label)
  local Y, pinned = {}, {}
  for c,l in pairs(mem) do
    local lo = math.huge
    for _,r in ipairs(l) do lo = math.min(lo, pcoord[r][AX]) end
    Y[c] = lo                                   -- unforced classes stay where they are
  end
  Y[pinC] = pinV ; pinned[pinC] = true
  local LIM, bad = 4000, nil
  for _ = 1, LIM do
    local ch = false
    for _,k in ipairs(cons) do
      -- sg>0: Y[cx] >= Y[cr]+m ; sg<0: Y[cr] >= Y[cx]+m
      local a,b = k.cr, k.cx
      if k.sg < 0 then a,b = k.cx, k.cr end
      if Y[b] < Y[a] + k.m then
        if pinned[b] then bad = ("infeasible: %s-%s(%s) needs %s at %d, PINNED at %d")
            :format(k.r,k.w,k.d,b,Y[a]+k.m,Y[b]) ; break end
        Y[b] = Y[a] + k.m ; ch = true
      end
    end
    if bad or not ch then break end
  end
  print(("\n-- %s : pin class of %s to %s=%d --"):format(label, pinC, AX==1 and "x" or "y", pinV))
  if bad then print("   "..bad.."\n   => VOID") return end
  local moved, tot, nonuni = {}, 0, 0
  for c,l in pairs(mem) do
    local ds = {}
    for _,r in ipairs(l) do
      local dl = Y[c] - pcoord[r][AX]
      if dl ~= 0 then moved[#moved+1] = { r, dl } ; tot = tot + math.abs(dl) end
      ds[dl] = true
    end
    local n=0 ; for _ in pairs(ds) do n=n+1 end
    if n>1 then nonuni = nonuni + 1 end
  end
  table.sort(moved, function(a,b) return tonumber(a[1])<tonumber(b[1]) end)
  local s = {}
  for _,e in ipairs(moved) do s[#s+1] = ("%s%+d"):format(e[1], e[2]) end
  print(("   FEASIBLE. %d room(s) move, sum|delta|=%d, %d class(es) take NON-UNIFORM deltas")
    :format(#moved, tot, nonuni))
  print("   "..table.concat(s, " "))
  local sY, aY = Y[find(START)], Y[find(ANCHOR)]
  print(("   closure: Y[row(%s)]=%d  Y[row(%s)]=%d  -> %s"):format(
    START, sY, ANCHOR, aY, (sY==aY) and "SAME ROW -- edge truthful on this axis" or "STILL APART"))
end

-- ---------- the CURRENT model, for contrast: ONE DISPLACEMENT per class ----------
-- `u[c]` uniform over the class; constraint sg*(g + u[cx] - u[cr]) >= m with g read PER EDGE from
-- the two rooms' own coordinates. Identical to Y-form on a flat class; the difference is that a
-- non-flat class cannot be flattened, only translated.
local function solve_u(pinC, pinV, label)
  local u, pinned = {}, {}
  for c in pairs(mem) do u[c] = 0 end
  u[pinC] = pinV ; pinned[pinC] = true
  -- ⚠ THE ANCHOR IS PINNED AT 0 -- a plate is defined only up to a translation
  u[find(ANCHORR)] = 0 ; pinned[find(ANCHORR)] = true
  local bad
  for _ = 1, 4000 do
    local ch = false
    for _,k in ipairs(cons) do
      local g = pcoord[k.w][AX] - pcoord[k.r][AX]
      if k.sg * g >= k.m then                     -- only a currently-legal edge constrains
        if k.sg > 0 then
          local need = u[k.cr] + k.m - g
          if u[k.cx] < need then
            if pinned[k.cx] then bad = ("lock@%s-%s: needs u[%s]=%d, PINNED at %d"):format(k.r,k.w,k.cx,need,u[k.cx]) break end
            u[k.cx] = need ; ch = true
          end
        else
          local need = u[k.cx] + g + k.m
          if u[k.cr] < need then
            if pinned[k.cr] then bad = ("lock@%s-%s: needs u[%s]=%d, PINNED at %d"):format(k.r,k.w,k.cr,need,u[k.cr]) break end
            u[k.cr] = need ; ch = true
          end
        end
      end
    end
    if bad or not ch then break end
  end
  print("")
  print(("-- [current model] %s --"):format(label))
  if bad then print("   "..bad) print("   => VOID") return end
  local cell, coll = {}, nil
  for _,r in ipairs(pids) do
    local ny = pcoord[r][AX] + u[find(r)]
    local nx = pcoord[r][3-AX]
    local k = nx*100000 + ny
    if cell[k] then coll = ("sep@%s-%s (both moved, same cell)"):format(cell[k], r) break end
    cell[k] = r
  end
  if coll then print("   "..coll) print("   => VOID") return end
  local moved, tot = {}, 0
  for c,l in pairs(mem) do
    for _,r in ipairs(l) do
      if u[c] ~= 0 then moved[#moved+1] = ("%s%+d"):format(r, u[c]) ; tot = tot + math.abs(u[c]) end
    end
  end
  table.sort(moved)
  print(("   FEASIBLE. %d room(s) move, sum|delta|=%d  (every class UNIFORM by construction)")
    :format(#moved, tot))
  print("   "..table.concat(moved, " "))
end
solve_u(find(START),  6, ("A) shift %s's class by +6"):format(START))
solve_u(find(ANCHOR), -6, ("B) shift %s's class by -6"):format(ANCHOR))

solve(find(START), pcoord[ANCHOR][AX], ("A) pin %s's row to %s's coordinate"):format(START, ANCHOR))
solve(find(ANCHOR), pcoord[START][AX],  ("B) pin %s's row to %s's coordinate"):format(ANCHOR, START))

-- ================= MODE C: the user's formulation =================
-- Do NOT pin a side and do NOT choose an A/B. Just ASSERT THE EQUALITY the new edge states --
-- union the closure edge into the partition -- and solve for target coordinates, letting nothing
-- move unless a constraint forces it. Pass 1 refuses this today ("unioning it makes every repair
-- impossible by construction"), which is true of a DISPLACEMENT model and false of a target one.
local parC = {}
local function findC(r) local x=parC[r] ; if x==nil then parC[r]=r return r end
  while parC[x]~=x do parC[x]=parC[parC[x]] ; x=parC[x] end ; parC[r]=x return x end
local function uniC(a,b) local A,B=findC(a),findC(b) ; if A~=B then parC[A]=B end end
for r,ex in pairs(adj) do
  for d,w in pairs(ex) do
    local de = D[d]
    if de and adj[w] and de[AX]==0 then uniC(r,w) end        -- <-- closure edge INCLUDED
  end
end
-- ⭐ PER AXIS THE NEW EDGE IS **EITHER** AN EQUALITY **OR** AN INEQUALITY, NEVER BOTH.
-- `4241 -west-> 4240` asserts `y(4241) == y(4240)` (union on axis 2) and `x(4240) <= x(4241)-1`
-- (a constraint on axis 1). Unioning it on the axis it does NOT equate merges two classes that
-- should only be ORDERED, and the ordering constraint is then skipped as intra-class -- which
-- silently moved 10 rooms on an axis that owed nothing.
local closDir
for d,w in pairs(adj[START] or {}) do if w == ANCHOR then closDir = d end end
if closDir and D[closDir] and D[closDir][AX] == 0 then
  uniC(START, ANCHOR)                                        -- the equality the edge asserts
end
local memC = {}
for _,r in ipairs(pids) do local c=findC(r) ; memC[c]=memC[c] or {} ; table.insert(memC[c], r) end
local consC = {}
for _,r in ipairs(pids) do
  for d,w in pairs(padj[r]) do
    local de = D[d]
    if de and placed[w] and de[AX] ~= 0 then
      local cr, cx = findC(r), findC(w)
      if cr ~= cx then consC[#consC+1] = { cr=cr, cx=cx, sg=de[AX], m=1, r=r, w=w, d=d } end
    end
  end
end
local YC = {}
for c,l in pairs(memC) do
  local lo = math.huge
  for _,r in ipairs(l) do lo = math.min(lo, pcoord[r][AX]) end
  YC[c] = lo                                                 -- least solution >= where things are
end
local badC
for _ = 1, 4000 do
  local ch = false
  for _,k in ipairs(consC) do
    local a,b = k.cr, k.cx
    if k.sg < 0 then a,b = k.cx, k.cr end
    if YC[b] < YC[a] + k.m then YC[b] = YC[a] + k.m ; ch = true end
  end
  if not ch then break end
end
print("")
print(("-- C) ASSERT THE EQUALITY (union the closure edge), solve for targets, axis %d --"):format(AX))
local moved, tot, nonuni = {}, 0, 0
for c,l in pairs(memC) do
  local ds = {}
  for _,r in ipairs(l) do
    local dl = YC[c] - pcoord[r][AX]
    if dl ~= 0 then moved[#moved+1] = ("%s%+d"):format(r, dl) ; tot = tot + math.abs(dl) end
    ds[dl] = true
  end
  local n=0 ; for _ in pairs(ds) do n=n+1 end
  if n>1 then nonuni = nonuni + 1 end
end
table.sort(moved)
print(("   %d room(s) move, sum|delta|=%d, %d class(es) NON-UNIFORM"):format(#moved, tot, nonuni))
print("   "..table.concat(moved, " "))
print(("   closure: Y[%s]=%d  Y[%s]=%d -> %s"):format(START, YC[findC(START)], ANCHOR,
  YC[findC(ANCHOR)], (findC(START)==findC(ANCHOR)) and "ONE CLASS by construction" or "??"))
