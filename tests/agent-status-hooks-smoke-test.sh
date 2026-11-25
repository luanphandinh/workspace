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
status = str(home / "bin" / "agent-turn-ended-status")
fixtures = {
    home / ".claude" / "settings.json": {
        "agentPushNotifEnabled": True,
        "hooks": {"Stop": [{"hooks": [
            {"type": "command", "command": f"{status} claude"},
            {"type": "command", "command": "custom-claude-hook"},
        ]}]},
    },
    home / ".cursor" / "hooks.json": {
        "version": 1,
        "hooks": {"stop": [
            {"command": f"{status} cursor"},
            {"command": "custom-cursor-hook"},
        ]},
    },
    home / ".codex" / "hooks.json": {
        "hooks": {
            "Stop": [
                {"hooks": [
                    {"type": "command", "command": "custom-codex-hook"},
                    {"type": "command", "command": f"echo {status} codex"},
                ]},
                {"hooks": [{"type": "command", "command": f"{status} codex"}]},
            ],
            "SessionStart": [{"hooks": [{"type": "command", "command": "custom-session-hook"}]}],
        },
    },
}
for path, data in fixtures.items():
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")
(home / ".codex" / "config.toml").write_text(
    'model = "example-model"\nnotify = ["custom-notify"]\n\n[features]\nmulti_agent = true\n',
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
assert codex_commands == ["custom-codex-hook", f"echo {status} codex"]
assert len(codex["hooks"]["Stop"]) == 1
assert codex["hooks"]["SessionStart"] == [{"hooks": [{"type": "command", "command": "custom-session-hook"}]}]

config = (home / ".codex" / "config.toml").read_text()
assert config == 'model = "example-model"\nnotify = ["custom-notify"]\n\n[features]\nmulti_agent = true\n'
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
[ "$(cat "$TMP/state/nvim/workspace-agent-status/$status_key")" = "done" ]

(
	cd "$TMP/project"
	HOME="$TMP/home" XDG_STATE_HOME="$TMP/retired-state" sh "$ROOT/bin/agent-turn-ended-status" codex
)
[ ! -e "$TMP/retired-state" ]

printf 'agent status hooks smoke test passed\n'
