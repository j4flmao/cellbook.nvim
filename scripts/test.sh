#!/usr/bin/env bash
# Run the mini.test suites.
#   ./scripts/test.sh                 unit + integration
#   ./scripts/test.sh unit|integration|e2e|bench|all
#   ./scripts/test.sh tests/unit/json_spec.lua   (single file)
set -euo pipefail
cd "$(dirname "$0")/.."

suite="${1:-default}"
case "$suite" in
  default) dirs="unit integration" ;;
  all) dirs="unit integration e2e bench" ;;
  unit | integration | e2e | bench) dirs="$suite" ;;
  *) dirs="" ;;
esac

if [ -n "$dirs" ]; then
  files=$(for d in $dirs; do ls tests/"$d"/*_spec.lua 2>/dev/null || true; done | tr '\n' ' ')
else
  files="$suite"
fi

lua_list=$(for f in $files; do printf '"%s",' "$f"; done)
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua MiniTest.run({ collect = { find_files = function() return { ${lua_list} } end }, execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 2 }) } })"
