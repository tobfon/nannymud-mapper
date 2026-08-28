#!/bin/sh
# List `function elro.X` definitions with NO remaining reference outside their own
# definition line, across lua/*.lua + map_helper.xml.
#
# ⚠ COMMENTS ARE STRIPPED FIRST. A previous sweep missed `pendants_of` and `classify_map`
# because each is NAMED IN A COMMENT elsewhere, which counted as a caller.
# ⚠ elro.fakepurge has NO CALLER BY DESIGN (hand-invoked from the Mudlet command line).
cd c:/mud/onserver/area/map_helper/client || exit 1
TMP=$(mktemp -d)
for f in lua/*.lua; do
  sed 's/--.*$//' "$f" > "$TMP/$(basename $f)"
done
sed 's/--.*$//' map_helper.xml > "$TMP/xml"
cat "$TMP"/* > "$TMP/all"
grep -ho "^function elro\.[A-Za-z_][A-Za-z0-9_]*" "$TMP"/*.lua \
  | sed 's/^function elro\.//' | sort -u | while read fn; do
  n=$(grep -c "elro\.$fn\b" "$TMP/all")
  d=$(grep -c "^function elro\.$fn\b" "$TMP/all")
  [ "$n" -le "$d" ] && echo "$fn"
done
rm -rf "$TMP"
