#!/bin/sh
# Install the mapper client git hooks into this repo's .git/hooks.
# Run once from anywhere in the repo: sh area/map_helper/client/tools/install-hooks.sh
# Re-run after editing tools/pre-commit or tools/run-gate.sh -- the hook is a COPY,
# so an edit here does nothing until this runs again.
set -e
root=$(git rev-parse --show-toplevel)
src="$root/area/map_helper/client/tools/pre-commit"
dst="$root/.git/hooks/pre-commit"
cp "$src" "$dst"
chmod +x "$dst"
echo "installed pre-commit hook -> $dst"
