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

# Run the configured status line command the way Claude Code does: in a shell, with session JSON on stdin.
status_home="$TMP/status-home"
mkdir -p "$status_home/bin" "$status_home/.claude/sessions"
cp "$ROOT/bin/claude-code-statusline" "$status_home/bin/"
# Claude Code writes one state file per process; bridgeSessionId is set while Remote Control is connected.
printf '%s' '{"pid":101,"sessionId":"connected-session","bridgeSessionId":"session_example"}' > "$status_home/.claude/sessions/101.json"
printf '%s' '{"pid":102,"sessionId":"local-session","bridgeSessionId":null}' > "$status_home/.claude/sessions/102.json"
status_command=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["statusLine"]["command"])' "$new_base")
green=$(printf '\033[32m') red=$(printf '\033[31m') reset=$(printf '\033[0m')
status_line=$(printf '%s' '{"session_id":"connected-session","model":{"id":"claude-opus-5-5","display_name":"Opus"},"effort":{"level":"high"},"context_window":{"context_window_size":200000,"used_percentage":10}}' |
	HOME="$status_home" sh -c "$status_command")
if [ "$status_line" != "Opus · high │ ctx 20.0k/200.0k (10%) │ ${green}rc${reset}" ]; then
	printf 'status line is not model, effort, context, and a green rc: %s\n' "$status_line" >&2
	exit 1
fi
status_line=$(printf '%s' '{"session_id":"local-session","model":{"id":"example-model","display_name":"Example"}}' | HOME="$status_home" sh -c "$status_command")
if [ "$status_line" != "Example │ ctx 0/? (0%) │ ${red}rc off${reset}" ]; then
	printf 'status line showed an effort the model does not report or a missing Remote Control: %s\n' "$status_line" >&2
	exit 1
fi

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
