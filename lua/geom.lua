-- Geometry prelude: shared pure (x,y) primitives. No knowledge of rooms, exits, or
-- defect policy belongs here. Consumers bind these to file-scope locals (hot loops).

elro = elro or {}
local G = {}
elro.g = G

-- Twice the signed area of triangle (a, b, c): > 0 = c left of a->b, < 0 = right, 0 = collinear.
-- Integer coordinates throughout, so the zero test is exact.
function G.ori(ax, ay, bx, by, cx, cy)
  return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
end

-- Same determinant in point-table form ({x, y}); separate entry point so the hot
-- polygon loops don't pay an unpack per call.
function G.orip(p, q, r)
  return (q[1] - p[1]) * (r[2] - p[2]) - (q[2] - p[2]) * (r[1] - p[1])
end

-- Is r inside the bounding box of p-q? Only meaningful with orip(p,q,r) == 0:
-- collinear + in-bbox = on the closed segment.
function G.within(p, q, r)
  return math.min(p[1], q[1]) <= r[1] and r[1] <= math.max(p[1], q[1])
     and math.min(p[2], q[2]) <= r[2] and r[2] <= math.max(p[2], q[2])
end

-- Edge raster. Axial and 45-degree edges expand to every cell they pass through; a
-- stretched diagonal yields ONLY its two endpoints (there is no honest cell list for a
-- line the grid cannot draw). Callers depend on that: widening the last branch would
-- change what counts as a room-on-edge defect engine-wide.
function G.seg(x1, y1, x2, y2, f)
  if y1 == y2 then for x = math.min(x1, x2), math.max(x1, x2) do f(x, y1) end
  elseif x1 == x2 then for y = math.min(y1, y2), math.max(y1, y2) do f(x1, y) end
  elseif math.abs(x2 - x1) == math.abs(y2 - y1) then
    local sx = (x2 > x1) and 1 or -1 ; local sy = (y2 > y1) and 1 or -1
    for i = 0, math.abs(x2 - x1) do f(x1 + sx * i, y1 + sy * i) end
  else f(x1, y1) ; f(x2, y2) end
end

-- Allocation-free point query: does the seg() raster cover (px, py)? Same branches in
-- the same order as seg, so the answer is identical by construction.
function G.seg_hits(x1, y1, x2, y2, px, py)
  if y1 == y2 then
    return py == y1 and px >= math.min(x1, x2) and px <= math.max(x1, x2)
  elseif x1 == x2 then
    return px == x1 and py >= math.min(y1, y2) and py <= math.max(y1, y2)
  elseif math.abs(x2 - x1) == math.abs(y2 - y1) then
    local dx, dy = px - x1, py - y1
    local sx = (x2 > x1) and 1 or -1 ; local sy = (y2 > y1) and 1 or -1
    if dx * sx < 0 or dx * sx > math.abs(x2 - x1) then return false end
    return dx * sy == dy * sx                      -- same step index on both axes
  end
  return (px == x1 and py == y1) or (px == x2 and py == y2)
end

-- STRICT crossing: proper interior intersection only -- an endpoint lying on the other
-- segment is not a crossing here. The walk's crossing test disagrees on exactly the zero
-- case (it counts a collinear touch, then handles it via proper/touch): two deliberate
-- predicates, do not unify them.
function G.seg_cross_strict(px, py, qx, qy, ax, ay, bx, by)
  local ori = G.ori
  local d1 = ori(ax, ay, bx, by, px, py)
  local d2 = ori(ax, ay, bx, by, qx, qy)
  local d3 = ori(px, py, qx, qy, ax, ay)
  local d4 = ori(px, py, qx, qy, bx, by)
  return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0))
     and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0))
end

return G
