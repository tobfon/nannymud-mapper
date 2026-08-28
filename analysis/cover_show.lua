-- ANNOTATE A SOURCE RANGE WITH COVERAGE -- the read-the-code half of the dead-code pass.
--
--   luajit analysis/cover_show.lua layout 1262 1320                 # union of every tag in cov/
--   COV=analysis/cov/base.cov luajit analysis/cover_show.lua layout 1262 1320
--   TAGS=1 luajit analysis/cover_show.lua layout 15360 15380        # WHICH tags reach each line
--
-- Marks: `.` never executed under any configuration in the sweep
--        `+` executed
--        ` ` not executable at all (comment, blank, `end`, a continuation row) -- per the VM, via
--            jit.util, not a guess; see the header of cover_report.lua.
--
-- ⭐ THE `.` COLUMN IS WHAT YOU DELETE AND THE BLANK COLUMN IS WHAT YOU MUST NOT READ AS DEAD. Two
-- thirds of the rows in a typical block of this codebase are comment, and a tool that marked them
-- uncovered would make every function look half-dead.
local u = require("jit.util")

local file = arg[1] or error("usage: cover_show.lua <module tag, e.g. walk|core> <from> <to>")
local from = tonumber(arg[2]) or error("need a start line")
local to = tonumber(arg[3]) or (from + 40)
local PATH
for _, m in ipairs(dofile("lua/modules.lua")) do if m == file .. ".lua" then PATH = "lua/" .. m end end
PATH = PATH or error("unknown module tag " .. file .. " (see lua/modules.lua)")
local WANTTAGS = os.getenv("TAGS")

local fh = assert(io.open(PATH), "run me from area/map_helper/client")
local src = fh:read("*a") ; fh:close()
local SRC = {}
for l in (src .. "\n"):gmatch("([^\n]*)\n") do SRC[#SRC + 1] = l end

local EXEC = {}
local function protowalk(p)
  local i = u.funcinfo(p)
  for pc = 1, i.bytecodes or 0 do
    local fi = u.funcinfo(p, pc)
    if fi and fi.currentline then EXEC[fi.currentline] = true end
  end
  local k = 0
  while true do
    k = k + 1
    local ok, c = pcall(u.funck, p, -k)
    if not ok or c == nil then break end
    if type(c) == "proto" then protowalk(c) end
  end
end
protowalk(assert(loadstring(src, "@" .. file)))

-- which tags to union: one file if COV=, else every tag cover_knobs.sh recorded
local paths = {}
if os.getenv("COV") then
  paths[1] = { tag = "COV", path = os.getenv("COV") }
else
  local tf = assert(io.open("analysis/cov/_tags.txt"), "run analysis/cover_knobs.sh first")
  for line in tf:lines() do
    local t = line:match("^([%w_]+)\t")
    if t then paths[#paths + 1] = { tag = t, path = "analysis/cov/" .. t .. ".cov" } end
  end
  tf:close()
end

local COV, BY = {}, {}
for _, e in ipairs(paths) do
  local f = io.open(e.path)
  if f then
    for line in f:lines() do
      local tg, n = line:match("^(%a+) (%d+)$")
      if tg == file then
        n = tonumber(n) ; COV[n] = true
        if WANTTAGS then BY[n] = BY[n] or {} ; BY[n][#BY[n] + 1] = e.tag end
      end
    end
    f:close()
  end
end

for l = from, math.min(to, #SRC) do
  local mark = EXEC[l] and (COV[l] and "+" or ".") or " "
  local extra = ""
  if WANTTAGS and EXEC[l] and BY[l] and #BY[l] < #paths then
    extra = "   <<< " .. table.concat(BY[l], " ")
  end
  print(("%s %6d  %s%s"):format(mark, l, SRC[l] or "", extra))
end
