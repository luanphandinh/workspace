#!/bin/sh
set -eu

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)"
TMP="${TMPDIR:-/tmp}/agent-notification-hooks-smoke.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/fakebin"

cat >"$TMP/fakebin/terminal-notifier" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TERMINAL_NOTIFIER_LOG"
SH
chmod +x "$TMP/fakebin/terminal-notifier"

TERMINAL_NOTIFIER_LOG="$TMP/terminal-notifier.log" \
	PATH="$TMP/fakebin:$PATH" \
	HOME="$TMP/home" \
	AGENT_NOTIFY_TITLE="Example Agent" \
	AGENT_NOTIFY_ACTIVATE_APP="" \
	sh "$ROOT/bin/codex-turn-ended-notify"

grep -q -- '-title Example Agent' "$TMP/terminal-notifier.log"

HOME="$TMP/home" python3 "$ROOT/bin/sync-agent-notification-hooks"
HOME="$TMP/home" python3 "$ROOT/bin/sync-agent-notification-hooks"

python3 - "$TMP/home" <<'PY'
import json
import pathlib
import sys

home = pathlib.Path(sys.argv[1])
notify = str(home / "bin" / "codex-turn-ended-notify")

claude = json.loads((home / ".claude" / "settings.json").read_text())
claude_stop = [
    hook["command"]
    for group in claude["hooks"]["Stop"]
    for hook in group["hooks"]
    if hook.get("type") == "command"
]
assert len([cmd for cmd in claude_stop if notify in cmd]) == 1, claude_stop
assert any("AGENT_NOTIFY_TITLE=Claude" in cmd for cmd in claude_stop), claude_stop

cursor = json.loads((home / ".cursor" / "hooks.json").read_text())
cursor_stop = [hook["command"] for hook in cursor["hooks"]["stop"]]
assert len([cmd for cmd in cursor_stop if notify in cmd]) == 1, cursor_stop
assert any("AGENT_NOTIFY_TITLE=Cursor" in cmd for cmd in cursor_stop), cursor_stop
PY
