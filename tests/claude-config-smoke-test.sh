#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
DATE=$(date +%Y%m%d)

cleanup() {
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

assert_exists() {
	test -e "$1" || {
		printf 'missing expected path: %s\n' "$1" >&2
		exit 1
	}
}

assert_not_exists() {
	if [ -e "$1" ]; then
		printf 'expected path to not exist: %s\n' "$1" >&2
		exit 1
	fi
}

assert_json() {
	python3 - "$@" <<'PY'
import json
import sys

path, expression = sys.argv[1], sys.argv[2]
settings = json.load(open(path))
if not eval(expression, {"settings": settings}):
    raise SystemExit(f"{path} does not satisfy: {expression}\n{json.dumps(settings, indent=2)}")
PY
}

base="$TMP/settings.json"
cat > "$base" <<'JSON'
{
  "model": "old-model",
  "env": { "EXISTING_VAR": "keep", "SHARED_VAR": "old" },
  "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "existing-hook" }] }] },
  "permissions": { "allow": ["Read"], "deny": ["Write"] }
}
JSON
overlay="$TMP/overlay.json"
cat > "$overlay" <<'JSON'
{
  "env": { "SHARED_VAR": "new", "NEW_VAR": "added" },
  "permissions": { "allow": ["Bash"] },
  "remoteControlAtStartup": true
}
JSON

python3 "$ROOT/bin/merge_json" "$base" "$overlay"
assert_exists "${base}_${DATE}_0"
assert_json "$base" 'settings["model"] == "old-model"'
assert_json "$base" 'settings["env"] == {"EXISTING_VAR": "keep", "SHARED_VAR": "new", "NEW_VAR": "added"}'
assert_json "$base" 'settings["hooks"]["Stop"][0]["hooks"][0]["command"] == "existing-hook"'
assert_json "$base" 'settings["permissions"] == {"allow": ["Bash"], "deny": ["Write"]}'
assert_json "$base" 'settings["remoteControlAtStartup"] is True'

cp "$base" "$TMP/after-first-merge.json"
python3 "$ROOT/bin/merge_json" "$base" "$overlay"
assert_not_exists "${base}_${DATE}_1"
cmp -s "$base" "$TMP/after-first-merge.json" || {
	printf 'expected idempotent merge to leave %s unchanged\n' "$base" >&2
	exit 1
}

new_base="$TMP/new/settings.json"
python3 "$ROOT/bin/merge_json" "$new_base" "$ROOT/claude/settings.json"
assert_not_exists "${new_base}_${DATE}_0"
assert_json "$new_base" 'settings["remoteControlAtStartup"] is True'

invalid="$TMP/invalid.json"
printf '{ not json\n' > "$invalid"
if python3 "$ROOT/bin/merge_json" "$invalid" "$overlay" 2>"$TMP/invalid.err"; then
	printf 'expected invalid JSON to fail\n' >&2
	exit 1
fi
grep -F 'not valid JSON' "$TMP/invalid.err" >/dev/null
[ "$(cat "$invalid")" = "{ not json" ] || {
	printf 'invalid JSON file was rewritten\n' >&2
	exit 1
}

printf 'claude-config smoke test passed\n'
