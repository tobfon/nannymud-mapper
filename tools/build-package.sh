#!/bin/sh
# Build ElrohirMapper.mpackage -- the installable Mudlet package.
#
# A .mpackage is a zip holding config.lua, the package XML and any extra files.
# Mudlet unpacks it into <profile>/<mpackage>/, so the lua/ directory ships inside
# and the bootstrap finds it at getMudletHomeDir().."/ElrohirMapper/lua".
#
#   usage: sh tools/build-package.sh [outfile]
# Refuses to build if the gate is red -- shipping a client that fails its own
# tests is the one thing this script exists to prevent.

set -e
cd "$(dirname "$0")/.." || exit 1
OUT="${1:-$PWD/ElrohirMapper.mpackage}"

if ! sh tools/run-gate.sh full; then
  echo "" >&2
  echo "build-package: the regression gate failed -- not packaging." >&2
  exit 1
fi

python - "$OUT" <<'PYEOF'
import os, re, sys, zipfile

out = sys.argv[1]
root = os.getcwd()

# What ships. analysis/ and tools/ deliberately do not: they are the dev harness,
# they are large, and a user has no way to run them.
files = ['config.lua', 'map_helper.xml']
# modules.lua puts several entries on one line, so scan the whole file, not line-wise
mods = re.findall(r'"([A-Za-z_0-9]+\.lua)"',
                  open(os.path.join(root, 'lua', 'modules.lua'), encoding='utf-8').read())
seen = set()
order = []
for m in mods:
    if m not in seen:
        seen.add(m)
        order.append(m)
files += [os.path.join('lua', m) for m in order]
files.append(os.path.join('lua', 'modules.lua'))

# config.lua's version is what a user sees; elro.VERSION is what the client reports
# to the server in its handshake. If they drift, the server names the wrong version.
cfg = re.search(r'version\s*=\s*"([^"]+)"',
                open(os.path.join(root, 'config.lua'), encoding='utf-8').read())
run = re.search(r'elro\.VERSION\s*=\s*"([^"]+)"',
                open(os.path.join(root, 'lua', 'core.lua'), encoding='utf-8').read())
if not cfg or not run or cfg.group(1) != run.group(1):
    print('build-package: version mismatch -- config.lua %s vs elro.VERSION %s'
          % (cfg and cfg.group(1), run and run.group(1)))
    sys.exit(1)

missing = [f for f in files if not os.path.isfile(os.path.join(root, f))]
if missing:
    print('build-package: missing ' + ', '.join(missing))
    sys.exit(1)

if os.path.exists(out):
    os.remove(out)
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for f in files:
        z.write(os.path.join(root, f), f.replace(os.sep, '/'))

# Read the archive back and prove every listed module is in it. The line-wise parse
# this replaced silently shipped 2 of 14 modules and still produced a valid zip.
with zipfile.ZipFile(out) as z:
    inzip = set(z.namelist())
shipped = set('lua/' + m for m in order)
gone = sorted(shipped - inzip)
if gone or 'config.lua' not in inzip or 'map_helper.xml' not in inzip:
    print('build-package: archive is incomplete: ' + ', '.join(gone or ['config/xml']))
    sys.exit(1)

n = len(files)
size = os.path.getsize(out)
print('build-package: %s  (%d files, %.0f kB)' % (out, n, size / 1024.0))
print('  modules: %d' % len(order))
PYEOF
