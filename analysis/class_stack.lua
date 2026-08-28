-- Does each axis-a EQUALITY CLASS really have ONE a-coordinate?  (grid-chord design premise)
-- Pass 1 unions rooms joined by an edge axial ACROSS axis a (de[a]==0); such an edge asserts the
-- two rooms share that coordinate. If that holds, classes are TOTALLY ORDERED along a and a "cut"
-- is a coordinate threshold -- which is the whole basis of the grid chord.
local D = { north={0,1}, south={0,-1}, east={1,0}, west={-1,0},
            northeast={1,1}, northwest={-1,1}, southeast={1,-1}, southwest={-1,-1} }
local file = arg[1] or "world_new.txt"
local coord, adj, ids = {}, {}, {}
for line in io.lines(file) do
  local id,x,y = line:match("^%s*(%d+)%s+%(?(-?%d+),?%s*(-?%d+)")
  if id then coord[id]={tonumber(x),tonumber(y)} ; adj[id]={} ; ids[#ids+1]=id
    for d,t in line:gmatch("(%a+)%s*%->%s*(%d+)") do if D[d] then adj[id][d]=t end end end
end
for a = 1, 2 do
  local par = {}
  local function find(r) local x=par[r] ; if x==nil then par[r]=r ; return r end
    while par[x]~=x do par[x]=par[par[x]] ; x=par[x] end ; par[r]=x ; return x end
  local function uni(r,x) local A,B=find(r),find(x) ; if A~=B then par[A]=B end end
  for _,r in ipairs(ids) do for d,w in pairs(adj[r]) do
    local de=D[d] ; if de and coord[w] and de[a]==0 then uni(r,w) end end end
  local vals, ncls, nbad, worst = {}, 0, 0, 0
  for _,r in ipairs(ids) do
    local c=find(r) ; local t=vals[c]
    if not t then t={} ; vals[c]=t ; ncls=ncls+1 end
    t[coord[r][a]] = (t[coord[r][a]] or 0) + 1
  end
  for c,t in pairs(vals) do
    local n=0 ; for _ in pairs(t) do n=n+1 end
    if n>1 then nbad=nbad+1 ; if n>worst then worst=n end end
  end
  print(("axis %d: %d classes, %d with MORE THAN ONE coordinate (worst %d distinct)")
    :format(a, ncls, nbad, worst))
end
