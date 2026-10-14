#!/usr/bin/env bash
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
npm_command=$(command -v npm)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/home/bin/shell" "$test_dir/package"
cp "$repo_root/bin/shell/workspace.sh" "$test_dir/home/bin/shell/workspace.sh"
cat > "$test_dir/package/package.json" <<'JSON'
{"name":"workspace-npm-fixture","version":"1.0.0","bin":{"workspace-npm-fixture":"cli.js"}}
JSON
printf '#!/usr/bin/env node\nconsole.log("fixture works");\n' > "$test_dir/package/cli.js"

# Use the real npm and a local package; no registry or install scripts needed.
(
  unset NPM_CONFIG_PREFIX npm_config_prefix
  export HOME="$test_dir/home"
  export NPM_CONFIG_USERCONFIG="$HOME/.npmrc"
  sh "$repo_root/bin/workspace-shell-sync" >/dev/null
  test "$("$npm_command" config get prefix)" = "$HOME/.local"
  . "$repo_root/bin/shell/workspace.sh"
  "$npm_command" install -g "$test_dir/package" --offline --ignore-scripts --no-audit --no-fund >/dev/null
  test "$(command -v workspace-npm-fixture)" = "$HOME/.local/bin/workspace-npm-fixture"
  test "$(workspace-npm-fixture)" = 'fixture works'
  export NPM_CONFIG_PREFIX="$test_dir/custom"
  . "$repo_root/bin/shell/workspace.sh"
  "$npm_command" install -g "$test_dir/package" --offline --ignore-scripts --no-audit --no-fund >/dev/null
  test "$(command -v workspace-npm-fixture)" = "$test_dir/custom/bin/workspace-npm-fixture"
)
printf 'PASS npm global smoke test\n'
