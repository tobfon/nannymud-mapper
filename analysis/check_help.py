#!/usr/bin/env python3
"""Compare map_helper.xml's aliases against core.lua's HELP_BASIC / HELP_ADV tables.

An alias with no help row is invisible; a help row with no alias is a lie. A command named
only inside another row's text counts as covered -- the whole help text is searched.

Run from the client dir:  python analysis/check_help.py
"""
import io
import os
import re
import sys

base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
xml = io.open(os.path.join(base, 'map_helper.xml'), encoding='utf-8-sig').read()
core = io.open(os.path.join(base, 'lua', 'core.lua'), encoding='utf-8', errors='replace').read()

aliases = set(re.findall(r'<regex>\^([a-z_]+)', xml))

blocks = []
for tbl in ('HELP_BASIC', 'HELP_ADV'):
    m = re.search(tbl + r'\s*=\s*\{(.*?)\n\}', core, re.S)
    if not m:
        print('check_help: table %s not found in core.lua' % tbl)
        sys.exit(2)
    blocks.append(m.group(1))
help_text = '\n'.join(blocks)

# the command column of each row, plus any command named anywhere in the help text
documented = set(re.findall(r'\{\s*"([a-z]+)', help_text))
mentioned = set(re.findall(r'\b(map[a-z]+)\b', help_text))

missing = sorted(a for a in aliases if a not in documented and a not in mentioned)
extra = sorted(d for d in documented if d not in aliases)

print('aliases %d, documented rows %d' % (len(aliases), len(documented)))
if missing:
    print('ALIAS WITH NO HELP  :', ', '.join(missing))
if extra:
    print('HELP WITH NO ALIAS  :', ', '.join(extra))
if not missing and not extra:
    print('check_help: OK -- every alias is documented and every row has an alias')
sys.exit(1 if (missing or extra) else 0)
