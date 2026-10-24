#!/bin/sh
set -eu

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)"
TMP="${TMPDIR:-/tmp}/agent-status-hooks-smoke.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/bin" "$TMP/project"
cp "$ROOT/bin/agent-turn-ended-status" "$TMP/home/bin/"

python3 - "$TMP/home" <<'PY'
import json
import pathlib
import sys

home = pathlib.Path(sys.argv[1])
old = str(home / "bin" / "codex-turn-ended-notify")
fixtures = {
    home / ".claude" / "settings.json": {
        "agentPushNotifEnabled": True,
        "hooks": {"Stop": [{"hooks": [
            {"type": "command", "command": old},
            {"type": "command", "command": "custom-claude-hook"},
        ]}]},
    },
    home / ".cursor" / "hooks.json": {
        "version": 1,
        "hooks": {"stop": [
            {"command": old},
            {"command": "custom-cursor-hook"},
        ]},
    },
    home / ".codex" / "hooks.json": {
        "hooks": {"Stop": [{"hooks": [
            {"type": "command", "command": old},
            {"type": "command", "command": "custom-codex-hook"},
        ]}]},
    },
}
for path, data in fixtures.items():
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")
(home / ".codex" / "config.toml").write_text(
    f'model = "example-model"\nnotify = ["{old}"]\n\n[features]\nmulti_agent = true\n',
    encoding="utf-8",
)
PY

HOME="$TMP/home" python3 "$ROOT/bin/sync-agent-status-hooks"
HOME="$TMP/home" python3 "$ROOT/bin/sync-agent-status-hooks"

python3 - "$TMP/home" <<'PY'
import json
import pathlib
import sys

home = pathlib.Path(sys.argv[1])
status = str(home / "bin" / "agent-turn-ended-status")

claude = json.loads((home / ".claude" / "settings.json").read_text())
assert claude["agentPushNotifEnabled"] is False
claude_commands = [hook["command"] for group in claude["hooks"]["Stop"] for hook in group["hooks"]]
assert claude_commands.count("custom-claude-hook") == 1
assert sum(status in value and value.endswith(" claude") for value in claude_commands) == 1

cursor = json.loads((home / ".cursor" / "hooks.json").read_text())
cursor_commands = [hook["command"] for hook in cursor["hooks"]["stop"]]
assert cursor_commands.count("custom-cursor-hook") == 1
assert sum(status in value and value.endswith(" cursor") for value in cursor_commands) == 1

codex = json.loads((home / ".codex" / "hooks.json").read_text())
codex_commands = [hook["command"] for group in codex["hooks"]["Stop"] for hook in group["hooks"]]
assert codex_commands.count("custom-codex-hook") == 1
assert sum(status in value and value.endswith(" codex") for value in codex_commands) == 1

for commands in (claude_commands, cursor_commands, codex_commands):
    assert all("codex-turn-ended-notify" not in value for value in commands)

config = (home / ".codex" / "config.toml").read_text()
assert "notify =" not in config
assert 'model = "example-model"' in config
assert "multi_agent = true" in config
PY

(
	cd "$TMP/project"
	HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" sh "$ROOT/bin/agent-turn-ended-status" example-agent
)
project="$(CDPATH= cd "$TMP/project" && pwd -P)"
if command -v sha256sum >/dev/null 2>&1; then
	status_key="$(printf '%s\n%s' example-agent "$project" | sha256sum | awk '{ print $1 }')"
else
	status_key="$(printf '%s\n%s' example-agent "$project" | shasum -a 256 | awk '{ print $1 }')"
fi
[ "$(cat "$TMP/state/nvim/workspace-agent-status/$status_key")" = "idle" ]

printf 'agent status hooks smoke test passed\n'
