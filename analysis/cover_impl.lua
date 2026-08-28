-- LINE-COVERAGE COLLECTOR -- the body of `analysis/cover.lua`; see that file for the invocation and
-- for why the loader is a one-liner.
--
-- Collects, for ONE dump and ONE knob spec, the exact set of source lines the engine executed, and
-- writes it to `<out.cov>` as `layout <n>` / `core <n>` lines. Everything downstream (union,
-- per-knob delta, the dead-line report) is set algebra over those files -- see `cover_sweep.sh`
-- and `cover_report.lua`.
--
-- ⛔ ONE SPEC PER PROCESS, and that is the OPPOSITE of `test_dump_layout.lua`'s rule. The census
-- harness insists on one process for many specs because LuaJIT's per-process string hash seed makes
-- a cross-process A/B void ([[reference_luajit_hash_seed]]). Coverage does not compare LAYOUTS, it
-- compares WHICH LINES RAN, and it is a union over a corpus -- a different hash seed reorders
-- `pairs()` and so perturbs the layout, which if anything covers MORE lines, never fewer. What it
-- must not do is let spec A's coverage leak into spec B's file, and the cheapest guarantee of that
-- is a fresh process. (It also keeps peak memory to one `cov` table.)

-- file -> leading blank lines, so every chunk owns a disjoint band of 100k lines. Bands start
-- at 300000: analysis/test_dump_layout.lua is loaded at +40000 and this file at +50000.
local OFFSETS, BAND, TAGS = {}, {}, {}
for i, m in ipairs(dofile("lua/modules.lua")) do
  if m ~= "geom.lua" and m ~= "keys.lua" then
    local tag, off = m:gsub("%.lua$", ""), 100000 * i
    OFFSETS["lua/" .. m] = off ; BAND[tag] = { off + 1, off + 99999 } ; TAGS[#TAGS + 1] = tag
  end
end
-- ⚠ `lua/geom.lua` IS DELIBERATELY NOT INSTRUMENTED, and that means it is INVISIBLE to the
-- coverage sweep -- so `analysis/PRUNE.md` and cover_report will never list its lines, and an
-- absence there must NOT be read as "dead" (the same trap the KNOBS registry note describes for
-- unregistered flags). Giving it a band would mean a third tag in the .cov format and a matching
-- edit to cover_report / cover_show / cover_delta, which is not worth it for six leaf functions
-- with no branches to miss: every one of them is on the corpus path by construction, since
-- removing any breaks the load. Revisit if geom.lua ever grows a conditional.

local outPath = assert(arg[1], "usage: cover.lua <out.cov> <dump> [knobspec ...]")
local dumpPath = assert(arg[2], "usage: cover.lua <out.cov> <dump> [knobspec ...]")

-- ---------------------------------------------------------------- offset loader
local function load_offset(path, off)
  local f = assert(io.open(path), "cannot open " .. path)
  local src = f:read("*a")
  f:close()
  return assert(loadstring(((off > 0) and ("\n"):rep(off) or "") .. src, "@" .. path))
end

local realdofile = dofile
dofile = function(p)                                    -- luacheck: ignore
  local off = OFFSETS[p]
  if not off then return realdofile(p) end
  return load_offset(p, off)()
end

-- ⚠ THE ENGINE INSTALLS ITS OWN HOOK. `elro.wd_hook_arm` (core.lua, the walk watchdog) calls
-- `debug.sethook(wd_hook, "", 1000000)`, and a second sethook REPLACES the first -- there is one
-- hook slot per coroutine in 5.1. Offline `test_dump_layout.lua` never calls `wd_start`, but a
-- silent, total loss of coverage is not a thing to leave to luck, so the setter is frozen after we
-- arm. The engine's arm/stop lines still EXECUTE (and so are still counted as covered); they just
-- do not take effect.
local cov = {}
local function hook(_, line) cov[line] = true end
debug.sethook(hook, "l")
debug.sethook = function() end                          -- luacheck: ignore
debug.gethook = function() return hook, "l", 0 end      -- luacheck: ignore

-- ---------------------------------------------------------------- run the real harness
-- test_dump_layout.lua carries the fake Mudlet, the dump reader, the knob-spec parser and the
-- census. Reusing it (rather than a second copy of all that) is the whole point -- a coverage tool
-- that drives a DIFFERENT loader would report a different program.
local hargs = { dumpPath }
for i = 3, #arg do hargs[#hargs + 1] = arg[i] end
if #hargs == 1 then hargs[2] = "-" end
arg = hargs                                             -- luacheck: ignore

local chunk = load_offset("analysis/test_dump_layout.lua", 40000)
local ok, err = pcall(chunk)

-- ---------------------------------------------------------------- dump
debug.sethook = nil                                     -- luacheck: ignore
local lines = {}
for l in pairs(cov) do lines[#lines + 1] = l end
table.sort(lines)

local out = assert(io.open(outPath, "w"))
out:write("# cover ", dumpPath, " [", table.concat(hargs, " ", 2), "]", ok and "" or "  INCOMPLETE", "\n")
local count = {}
for _, l in ipairs(lines) do
  for _, tag in ipairs(TAGS) do
    local b = BAND[tag]
    if l >= b[1] and l <= b[2] then
      out:write(tag, " ", l - (b[1] - 1), "\n") ; count[tag] = (count[tag] or 0) + 1
      break
    end
  end
end
out:close()
local parts = {}
for _, tag in ipairs(TAGS) do parts[#parts + 1] = ("%s %d"):format(tag, count[tag] or 0) end
io.write(("[cover] %s: %s line(s)%s\n")
  :format(outPath, table.concat(parts, ", "), ok and "" or (" -- RUN FAILED: " .. tostring(err))))
if not ok then os.exit(1) end
