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
grep -q -- '-ignoreDnD' "$TMP/terminal-notifier.log"
grep -q -- '-group agent-notify-Example Agent' "$TMP/terminal-notifier.log"
status_file="$(find "$TMP/home/.local/state/nvim/workspace-agent-status" -type f | head -1)"
[ -n "$status_file" ]
[ "$(cat "$status_file")" = "idle" ]

cat >"$TMP/fakebin/chained-notify" <<'SH'
#!/bin/sh
sleep 5
SH
chmod +x "$TMP/fakebin/chained-notify"
mkdir -p "$TMP/home/.codex"
printf 'notify = ["%s"]\n' "$TMP/fakebin/chained-notify" > "$TMP/home/.codex/config.toml"
: > "$TMP/terminal-notifier.log"
TERMINAL_NOTIFIER_LOG="$TMP/terminal-notifier.log" \
	PATH="$TMP/fakebin:$PATH" \
	HOME="$TMP/home" \
	sh "$ROOT/bin/codex-turn-ended-notify" '{"type":"agent-turn-complete"}' &
notify_pid=$!
sleep 1
if ! grep -q -- '-title Codex' "$TMP/terminal-notifier.log"; then
	children="$(pgrep -P "$notify_pid" 2>/dev/null || :)"
	[ -z "$children" ] || kill $children 2>/dev/null || :
	kill "$notify_pid" 2>/dev/null || :
	wait "$notify_pid" 2>/dev/null || :
	printf 'expected terminal notification even when chained notifier blocks\n' >&2
	exit 1
fi
grep -q -- '-ignoreDnD' "$TMP/terminal-notifier.log"
grep -q -- '-group agent-notify-Codex' "$TMP/terminal-notifier.log"
wait "$notify_pid"

cat >"$TMP/fakebin/tmux" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_FAKE_LOG"

if [ "$1" = "display-message" ] && [ "${2:-}" = "-p" ]; then
	target=""
	format=""
	shift 2
	while [ "$#" -gt 0 ]; do
		case "$1" in
			-t)
				target="${2:-}"
				shift 2
				;;
			*)
				format="$1"
				shift
				;;
		esac
	done

	case "$target:$format" in
		%stale:*)
			case "$format" in
				'#{session_name}:#{window_index}.#{pane_index}') printf '%s\n' ':.' ;;
				'#{session_name}:#{window_index}') printf '%s\n' ':' ;;
				'#{session_name}') printf '%s\n' '' ;;
				'#{session_id}') printf '%s\n' '' ;;
				'#{pane_id}') printf '%s\n' '' ;;
				'#{pane_tty}') printf '%s\n' '' ;;
				*) printf '%s\n' '' ;;
			esac
			;;
		%cwd:*)
			case "$format" in
				'#{session_name}:#{window_index}.#{pane_index}') printf '%s\n' 'project:4.2' ;;
				'#{session_name}:#{window_index}') printf '%s\n' 'project:4' ;;
				'#{session_name}') printf '%s\n' 'project' ;;
				'#{session_id}') printf '%s\n' '$2' ;;
				'#{pane_id}') printf '%s\n' '%cwd' ;;
				'#{pane_tty}') printf '%s\n' '' ;;
				*) printf '%s\n' '' ;;
			esac
			;;
		*:*)
			case "$format" in
				'#{session_name}:#{window_index}.#{pane_index}') printf '%s\n' 'workspace:3.2' ;;
				'#{session_name}:#{window_index}') printf '%s\n' 'workspace:3' ;;
				'#{session_name}') printf '%s\n' 'workspace' ;;
				'#{session_id}') printf '%s\n' '$1' ;;
				'#{pane_id}') printf '%s\n' '%current' ;;
				'#{pane_tty}') printf '%s\n' '' ;;
				*) printf '%s\n' '' ;;
			esac
			;;
	esac
	exit 0
fi

if [ "$1" = "list-panes" ]; then
	printf '%%current\t/tmp/other\t1\t1\t1\n'
	printf '%%cwd\t%s\t1\t1\t1\n' "$TMUX_FAKE_CWD"
	exit 0
fi

if [ "$1" = "list-clients" ]; then
	case "${3:-}" in
		'#{client_name}')
			printf 'client-target\n'
			printf 'client-cwd\n'
			printf 'client-newest\n'
			;;
		*)
			printf '100\tclient-target\t111\t$3\n'
			printf '150\tclient-cwd\t333\t$2\n'
			printf '200\tclient-newest\t222\t$9\n'
			;;
	esac
	exit 0
fi

exit 0
SH
chmod +x "$TMP/fakebin/tmux"

cat >"$TMP/fakebin/ps" <<'SH'
#!/bin/sh
case "$*" in
	*" 111 "*) printf 'tmux KITTY_WINDOW_ID=41 KITTY_LISTEN_ON=unix:/tmp/kitty-test\n' ;;
	*" 333 "*) printf 'tmux KITTY_WINDOW_ID=43 KITTY_LISTEN_ON=unix:/tmp/kitty-test\n' ;;
	*) printf 'tmux\n' ;;
esac
SH
chmod +x "$TMP/fakebin/ps"

cat >"$TMP/fakebin/kitten" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$KITTEN_FAKE_LOG"
SH
chmod +x "$TMP/fakebin/kitten"

mkdir -p "$TMP/home/.config/tmux"
printf 'code\ttarget\t$1\ncode\tsibling\t$3\ndefault\tother\t$9\n' >"$TMP/home/.config/tmux/pinned-sessions"

: > "$TMP/terminal-notifier.log"
: > "$TMP/tmux.log"
: > "$TMP/kitten.log"
TERMINAL_NOTIFIER_LOG="$TMP/terminal-notifier.log" \
	TMUX_FAKE_LOG="$TMP/tmux.log" \
	KITTEN_FAKE_LOG="$TMP/kitten.log" \
	PATH="$TMP/fakebin:$PATH" \
	HOME="$TMP/home" \
	TMUX="/tmp/tmux-test/default,1,0" \
	TMUX_PANE="%stale" \
	sh "$ROOT/bin/codex-turn-ended-notify" '{"type":"agent-turn-complete"}'
grep -q -- "--jump-tmux '%current'" "$TMP/terminal-notifier.log"
grep -q -- "--tmux-client 'client-target'" "$TMP/terminal-notifier.log"
grep -q -- "--kitty-window '41'" "$TMP/terminal-notifier.log"
grep -q -- "--kitty-listen-on 'unix:/tmp/kitty-test'" "$TMP/terminal-notifier.log"
grep -q -- '-subtitle tmux workspace:3.2' "$TMP/terminal-notifier.log"
grep -q -- '-group agent-notify-Codex-_current' "$TMP/terminal-notifier.log"
if grep -q -- "--jump-tmux '%stale'" "$TMP/terminal-notifier.log"; then
	printf 'expected stale TMUX_PANE to be ignored\n' >&2
	exit 1
fi

mkdir -p "$TMP/project"
: > "$TMP/terminal-notifier.log"
: > "$TMP/tmux.log"
project_cwd="$(CDPATH= cd "$TMP/project" && pwd -P)"
cd "$TMP/project"
TERMINAL_NOTIFIER_LOG="$TMP/terminal-notifier.log" \
	TMUX_FAKE_LOG="$TMP/tmux.log" \
	KITTEN_FAKE_LOG="$TMP/kitten.log" \
	TMUX_FAKE_CWD="$project_cwd" \
	PATH="$TMP/fakebin:$PATH" \
	HOME="$TMP/home" \
	TMUX="/tmp/tmux-test/default,1,0" \
	TMUX_PANE="%current" \
	sh "$ROOT/bin/codex-turn-ended-notify" '{"type":"agent-turn-complete"}'
cd "$ROOT"
grep -q -- "--jump-tmux '%cwd'" "$TMP/terminal-notifier.log"
grep -q -- "--tmux-client 'client-cwd'" "$TMP/terminal-notifier.log"
grep -q -- "--kitty-window '43'" "$TMP/terminal-notifier.log"
grep -q -- '-subtitle tmux project:4.2' "$TMP/terminal-notifier.log"
if grep -q -- "--jump-tmux '%current'" "$TMP/terminal-notifier.log"; then
	printf 'expected cwd-matched pane to override inherited TMUX_PANE\n' >&2
	exit 1
fi

: > "$TMP/tmux.log"
TMUX_FAKE_LOG="$TMP/tmux.log" \
	KITTEN_FAKE_LOG="$TMP/kitten.log" \
	PATH="$TMP/fakebin:$PATH" \
	HOME="$TMP/home" \
	AGENT_NOTIFY_ACTIVATE_APP="kitty" \
	sh "$ROOT/bin/codex-turn-ended-notify" --jump-tmux "%current" \
		--tmux-client "client-target" \
		--kitty-window "41" \
		--kitty-listen-on "unix:/tmp/kitty-test"
grep -q -- 'switch-client -c client-target -t %current' "$TMP/tmux.log"
if grep -q -- 'switch-client -c client-newest -t %current' "$TMP/tmux.log"; then
	printf 'notification click switched the globally newest tmux client\n' >&2
	exit 1
fi
grep -q -- '@ --to unix:/tmp/kitty-test focus-window --match id:41' "$TMP/kitten.log"

cat >"$TMP/home/.codex/config.toml" <<TOML
model = "example-model"
notify = ["$TMP/home/bin/codex-turn-ended-notify", "--no-implicit-tmux-pane"]

[features]
multi_agent = true
TOML

python3 - "$TMP/home" <<'PY'
import json
import pathlib
import sys

home = pathlib.Path(sys.argv[1])
notify = str(home / "bin" / "codex-turn-ended-notify")

fixtures = {
    home / ".claude" / "settings.json": {
        "hooks": {
            "UserPromptSubmit": [{"hooks": [
                {"type": "command", "command": f"{notify} --status running"},
                {"type": "command", "command": "custom-claude-prompt-hook"},
            ]}],
            "SessionStart": [{"hooks": [
                {"type": "command", "command": f"{notify} --status idle"},
            ]}],
        },
    },
    home / ".cursor" / "hooks.json": {
        "version": 1,
        "hooks": {
            "beforeSubmitPrompt": [
                {"command": f"{notify} --status running"},
                {"command": "custom-cursor-prompt-hook"},
            ],
            "sessionStart": [{"command": f"{notify} --status idle"}],
        },
    },
    home / ".codex" / "hooks.json": {
        "hooks": {
            "UserPromptSubmit": [{"hooks": [
                {"type": "command", "command": f"{notify} --status running"},
                {"type": "command", "command": "custom-codex-prompt-hook"},
            ]}],
            "SessionStart": [{"hooks": [
                {"type": "command", "command": f"{notify} --status idle"},
            ]}],
        },
    },
}

for path, data in fixtures.items():
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")
PY

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
assert "SessionStart" not in claude["hooks"], claude
assert [
    hook["command"]
    for group in claude["hooks"]["UserPromptSubmit"]
    for hook in group["hooks"]
] == ["custom-claude-prompt-hook"], claude

cursor = json.loads((home / ".cursor" / "hooks.json").read_text())
cursor_stop = [hook["command"] for hook in cursor["hooks"]["stop"]]
assert len([cmd for cmd in cursor_stop if notify in cmd]) == 1, cursor_stop
assert any("AGENT_NOTIFY_TITLE=Cursor" in cmd for cmd in cursor_stop), cursor_stop
assert "sessionStart" not in cursor["hooks"], cursor
assert [hook["command"] for hook in cursor["hooks"]["beforeSubmitPrompt"]] == [
    "custom-cursor-prompt-hook"
], cursor

codex = json.loads((home / ".codex" / "hooks.json").read_text())
codex_stop = [
    hook["command"]
    for group in codex["hooks"]["Stop"]
    for hook in group["hooks"]
    if hook.get("type") == "command"
]
assert len([cmd for cmd in codex_stop if notify in cmd]) == 1, codex_stop
assert any("AGENT_NOTIFY_TITLE=Codex" in cmd for cmd in codex_stop), codex_stop
assert "SessionStart" not in codex["hooks"], codex
assert [
    hook["command"]
    for group in codex["hooks"]["UserPromptSubmit"]
    for hook in group["hooks"]
] == ["custom-codex-prompt-hook"], codex

config = (home / ".codex" / "config.toml").read_text()
assert "notify =" not in config, config
assert 'model = "example-model"' in config, config
assert "multi_agent = true" in config, config
PY
