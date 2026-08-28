-- FROZEN REFERENCE COPY of elro.count_defects as it stood BEFORE the 2026-07-29 optimisation
-- pass (git 3f4f886). Byte-for-byte the old body, only re-shaped into a returned function and
-- with the elro.bg_tick call dropped (the harness has no coroutine).
--
-- ⚠ DO NOT "fix" or re-sync this file. It exists for exactly two jobs:
--   1. a second independent oracle beside the harness's brute force, and
--   2. the BEFORE side of the benchmark, so old and new are timed in one process on one input.
-- If it ever disagrees with the brute force, the OLD engine had a bug; say so, do not edit this.
return function(coord, placed, pedges, B)
  local function key(x, y) return x .. ":" .. y end
  local function ori(ax, ay, bx, by, cx, cy) return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax) end
  local floor = math.floor
  B = B or 4
  local cnt, cellOf = 0, {}
  local nOv, nRoe, nX = 0, 0, 0
  for rr in pairs(placed) do
    local p = coord[rr]
    if p then local k = key(p[1], p[2])
      if cellOf[k] then cnt = cnt + 1 ; nOv = nOv + 1 else cellOf[k] = rr end end
  end
  local roomIdx = {}
  for rr in pairs(placed) do local p = coord[rr]
    if p then local k = floor(p[1] / B) * 1000003 + floor(p[2] / B) ; roomIdx[k] = roomIdx[k] or {} ; roomIdx[k][#roomIdx[k] + 1] = rr end
  end
  local edgeIdx = {}
  for i = 1, #pedges do local e = pedges[i] ; local a, b = coord[e.u], coord[e.v]
    if a and b then
      for bx = floor((a[1] < b[1] and a[1] or b[1]) / B), floor((a[1] > b[1] and a[1] or b[1]) / B) do
        for by = floor((a[2] < b[2] and a[2] or b[2]) / B), floor((a[2] > b[2] and a[2] or b[2]) / B) do
          local k = bx * 1000003 + by ; edgeIdx[k] = edgeIdx[k] or {} ; edgeIdx[k][#edgeIdx[k] + 1] = i
        end
      end
    end
  end
  for _, e in ipairs(pedges) do              -- room-on-edge: each edge vs NEARBY rooms
    local c, d = coord[e.u], coord[e.v]
    if c and d then
      local xlo, xhi = (c[1] < d[1]) and c[1] or d[1], (c[1] > d[1]) and c[1] or d[1]
      local ylo, yhi = (c[2] < d[2]) and c[2] or d[2], (c[2] > d[2]) and c[2] or d[2]
      local seen = {}
      for bx = floor(xlo / B), floor(xhi / B) do
        for by = floor(ylo / B), floor(yhi / B) do
          local bk = roomIdx[bx * 1000003 + by]
          if bk then for _, rr in ipairs(bk) do if not seen[rr] then seen[rr] = true
            if rr ~= e.u and rr ~= e.v then local p = coord[rr]
              if p[1] >= xlo and p[1] <= xhi and p[2] >= ylo and p[2] <= yhi
                 and ori(c[1], c[2], d[1], d[2], p[1], p[2]) == 0 then cnt = cnt + 1 ; nRoe = nRoe + 1 end
            end
          end end end
        end
      end
    end
  end
  for i = 1, #pedges do                       -- edge-crossing: each edge vs NEARBY edges (j>i dedup)
    local e1 = pedges[i] ; local a, b = coord[e1.u], coord[e1.v]
    if a and b then
      local seen = {}
      for bx = floor((a[1] < b[1] and a[1] or b[1]) / B), floor((a[1] > b[1] and a[1] or b[1]) / B) do
        for by = floor((a[2] < b[2] and a[2] or b[2]) / B), floor((a[2] > b[2] and a[2] or b[2]) / B) do
          local bk = edgeIdx[bx * 1000003 + by]
          if bk then for _, j in ipairs(bk) do if j > i and not seen[j] then seen[j] = true
            local e2 = pedges[j]
            if e1.u ~= e2.u and e1.u ~= e2.v and e1.v ~= e2.u and e1.v ~= e2.v then
              local c, d = coord[e2.u], coord[e2.v]
              if c and d then
                local d1 = ori(c[1], c[2], d[1], d[2], a[1], a[2]) ; local d2 = ori(c[1], c[2], d[1], d[2], b[1], b[2])
                local d3 = ori(a[1], a[2], b[1], b[2], c[1], c[2]) ; local d4 = ori(a[1], a[2], b[1], b[2], d[1], d[2])
                if ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0)) then cnt = cnt + 1 ; nX = nX + 1 end
              end
            end
          end end end
        end
      end
    end
  end
  return cnt, nOv, nRoe, nX
end
