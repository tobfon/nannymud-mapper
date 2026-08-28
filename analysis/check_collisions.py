#!/usr/bin/env python3
"""Fail if two modules define the same `function elro.X`.

They all write into one shared table in a fixed load order, so a duplicate name is silent:
the later module wins and the earlier one's callers get the wrong arity at runtime.

Run from the client dir:  python analysis/check_collisions.py
"""
import io
import os
import re
import sys

base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
mods = io.open(os.path.join(base, 'lua', 'modules.lua'), encoding='utf-8').read()
order = re.findall(r'"([a-z_]+\.lua)"', mods)
if not order:
    print('check_collisions: could not read the module list from lua/modules.lua')
    sys.exit(2)

seen = {}
dupes = []
for fname in order:
    path = os.path.join(base, 'lua', fname)
    src = io.open(path, encoding='utf-8', errors='replace').read()
    for m in re.finditer(r'^function\s+elro\.([A-Za-z_0-9]+)\s*\(', src, re.M):
        name = m.group(1)
        line = src.count('\n', 0, m.start()) + 1
        if name in seen:
            dupes.append((name, seen[name], (fname, line)))
        else:
            seen[name] = (fname, line)

print('%d module(s), %d elro.* function(s)' % (len(order), len(seen)))
for name, first, second in dupes:
    print('COLLISION  elro.%s' % name)
    print('    defined %s:%d' % first)
    print('    ...and  %s:%d   <-- this one wins, silently' % second)
if not dupes:
    print('check_collisions: OK -- no elro.* function is defined by two modules')
sys.exit(1 if dupes else 0)
