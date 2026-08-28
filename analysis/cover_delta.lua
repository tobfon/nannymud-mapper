-- PER-KNOB ATTRIBUTION over the `cover_knobs.sh` sweep.  Run from area/map_helper/client:
--
--   luajit analysis/cover_delta.lua                       # every tag in analysis/cov
--   MIN=1 luajit analysis/cover_delta.lua faceFit_on      # the blocks, for one tag
--
-- `base.cov` is the reference. For every other tag it answers two questions:
--
--   +N  lines the flipped knob ENABLES  (covered under the tag, never under base)
--   -N  lines the flipped knob DISABLES (covered under base, never under the tag)
--
-- and then the one that decides a deletion:
--
--   EXCL  lines covered by THIS TAG AND NO OTHER, base included.
--
-- ⭐ EXCL, not `+`, IS THE KNOB'S OWN CODE. A `+` line may be shared -- turn `dragTight` off and the
-- fallback path it exposes is the same path `seamNoTight` walks -- so `+` counts double-attribute
-- wildly, while an EXCL line is reached in exactly one of the 67 configurations we ship. Deleting a
-- knob means deleting its EXCL lines and nothing else; a knob with EXCL 0 guards no code of its own
-- and is a rename of an existing path.
--
-- ⚠ AND `EXCL 0` IS NOT "SAFE TO DELETE". It says the branch body is shared, not that the branch is
-- pointless: `eqClsMemo=false` re-runs a function instead of reading a cache, and every line of the
-- slow path is also on the cold-miss path. Read it as "no unique code hangs off this flag".
local DIR = os.getenv("COVDIR") or "analysis/cov"
local MIN = tonumber(os.getenv("MIN") or "1")
local WANT = arg[1]

-- ---------------------------------------------------------------- load every tag
-- ⚠ NO `io.popen("ls ...")`. luajit on Windows hands popen to cmd.exe, which has no `ls`, and the
-- tool then reports "no .cov files" on a directory full of them. `cover_knobs.sh` writes the tag
-- list it actually ran to `_tags.txt`; read that -- it is also the only record of which tags were
-- SKIPPED via TAGS=, which a directory listing cannot tell you.
local function listtags()
  local t = {}
  local fh = assert(io.open(DIR .. "/_tags.txt"),
    DIR .. "/_tags.txt missing -- run analysis/cover_knobs.sh first")
  for line in fh:lines() do
    local tag = line:match("^([%w_]+)\t")
    if tag then t[#t + 1] = { tag = tag, path = DIR .. "/" .. tag .. ".cov" } end
  end
  fh:close()
  table.sort(t, function(a, b) return a.tag < b.tag end)
  return t
end

local TAGS = listtags()
if #TAGS == 0 then error("no .cov files in " .. DIR .. " -- run analysis/cover_knobs.sh first") end

local SET = {}                     -- tag -> { ["layout 123"] = true }
for _, e in ipairs(TAGS) do
  local s = {}
  local fh = assert(io.open(e.path))
  for line in fh:lines() do if line:match("^%a+ %d+$") then s[line] = true end end
  fh:close()
  SET[e.tag] = s
end
local base = SET.base or error("analysis/cov/base.cov missing -- it is the reference")

-- ---------------------------------------------------------------- how many tags reach each line
local nseen = {}
for _, e in ipairs(TAGS) do
  for k in pairs(SET[e.tag]) do nseen[k] = (nseen[k] or 0) + 1 end
end

-- ---------------------------------------------------------------- source, for the block headers
local SRC = {}
local FILES = {}
for _, m in ipairs(dofile("lua/modules.lua")) do FILES[(m:gsub("%.lua$", ""))] = "lua/" .. m end
for tag, path in pairs(FILES) do
  local fh = assert(io.open(path), "run me from area/map_helper/client")
  local t = {}
  for l in (fh:read("*a") .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
  fh:close()
  SRC[tag] = t
end
local function keysort(a, b)
  local fa, na = a:match("^(%a+) (%d+)$") ; local fb, nb = b:match("^(%a+) (%d+)$")
  if fa ~= fb then return fa < fb end
  return tonumber(na) < tonumber(nb)
end
-- one line per RUN of consecutive-ish lines: a gap of more than 4 source rows starts a new block,
-- which keeps a 300-line function from printing as 300 findings without merging two real branches.
local function blocks(keys)
  table.sort(keys, keysort)
  local out = {}
  for _, k in ipairs(keys) do
    local f, n = k:match("^(%a+) (%d+)$") ; n = tonumber(n)
    local last = out[#out]
    if last and last.f == f and n - last.to <= 4 then last.to, last.n = n, last.n + 1
    else out[#out + 1] = { f = f, from = n, to = n, n = 1 } end
  end
  table.sort(out, function(a, b) return a.n > b.n end)
  return out
end
local function show(label, keys, cap)
  if #keys == 0 then return end
  print(("    %s (%d line(s))"):format(label, #keys))
  local bs = blocks(keys)
  for i = 1, math.min(#bs, cap) do
    local b = bs[i]
    local head = (SRC[b.f][b.from] or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #head > 92 then head = head:sub(1, 89) .. "..." end
    print(("      %-6s %5d-%-5d %4d  %s"):format(b.f, b.from, b.to, b.n, head))
  end
  if #bs > cap then print(("      ... and %d more block(s)"):format(#bs - cap)) end
end

-- ---------------------------------------------------------------- report
if not WANT then
  print(("%-24s %6s %6s %6s   (%d tag(s), base = %d line(s))")
    :format("TAG", "+ENABL", "-DISAB", "EXCL", #TAGS, (function()
      local n = 0 ; for _ in pairs(base) do n = n + 1 end ; return n end)()))
end
local rows = {}
for _, e in ipairs(TAGS) do
  if e.tag ~= "base" and (not WANT or e.tag == WANT) then
    local s = SET[e.tag]
    local plus, minus, excl = {}, {}, {}
    for k in pairs(s) do
      if not base[k] then plus[#plus + 1] = k end
      if nseen[k] == 1 then excl[#excl + 1] = k end
    end
    for k in pairs(base) do if not s[k] then minus[#minus + 1] = k end end
    rows[#rows + 1] = { tag = e.tag, plus = plus, minus = minus, excl = excl }
  end
end
table.sort(rows, function(a, b)
  if #a.excl ~= #b.excl then return #a.excl > #b.excl end
  return (#a.plus + #a.minus) > (#b.plus + #b.minus)
end)
for _, r in ipairs(rows) do
  if WANT then
    print(("== %s   +%d enabled  -%d disabled  %d exclusive"):format(r.tag, #r.plus, #r.minus, #r.excl))
    show("ENABLED", r.plus, 40) ; show("DISABLED", r.minus, 40) ; show("EXCLUSIVE", r.excl, 40)
  elseif #r.plus + #r.minus + #r.excl >= MIN then
    print(("%-24s %6d %6d %6d"):format(r.tag, #r.plus, #r.minus, #r.excl))
  end
end

if not WANT then
  local zero = {}
  for _, r in ipairs(rows) do
    if #r.plus + #r.minus + #r.excl == 0 then zero[#zero + 1] = r.tag end
  end
  if #zero > 0 then
    print(("\nNO COVERAGE EFFECT AT ALL on this corpus (%d): %s"):format(#zero, table.concat(zero, " ")))
    print("  -- the flip changed WHICH lines ran: not at all. Either the branch is unreachable on")
    print("     these 13 areas, or the knob is read only where both sides are one line.")
  end
end
