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
				'#{pane_id}') printf '%s\n' '' ;;
				'#{pane_tty}') printf '%s\n' '' ;;
				*) printf '%s\n' '' ;;
			esac
			;;
		*:*)
			case "$format" in
				'#{session_name}:#{window_index}.#{pane_index}') printf '%s\n' 'workspace:3.2' ;;
				'#{session_name}:#{window_index}') printf '%s\n' 'workspace:3' ;;
				'#{session_name}') printf '%s\n' 'workspace' ;;
				'#{pane_id}') printf '%s\n' '%current' ;;
				'#{pane_tty}') printf '%s\n' '' ;;
				*) printf '%s\n' '' ;;
			esac
			;;
	esac
	exit 0
fi

exit 0
SH
chmod +x "$TMP/fakebin/tmux"
: > "$TMP/terminal-notifier.log"
: > "$TMP/tmux.log"
TERMINAL_NOTIFIER_LOG="$TMP/terminal-notifier.log" \
	TMUX_FAKE_LOG="$TMP/tmux.log" \
	PATH="$TMP/fakebin:$PATH" \
	HOME="$TMP/home" \
	TMUX="/tmp/tmux-test/default,1,0" \
	TMUX_PANE="%stale" \
	sh "$ROOT/bin/codex-turn-ended-notify" '{"type":"agent-turn-complete"}'
grep -q -- "--jump-tmux '%current'" "$TMP/terminal-notifier.log"
grep -q -- '-subtitle tmux workspace:3.2' "$TMP/terminal-notifier.log"
grep -q -- '-group agent-notify-Codex-_current' "$TMP/terminal-notifier.log"
if grep -q -- "--jump-tmux '%stale'" "$TMP/terminal-notifier.log"; then
	printf 'expected stale TMUX_PANE to be ignored\n' >&2
	exit 1
fi

cat >"$TMP/home/.codex/config.toml" <<TOML
model = "example-model"
notify = ["$TMP/home/bin/codex-turn-ended-notify", "--no-implicit-tmux-pane"]

[features]
multi_agent = true
TOML

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

codex = json.loads((home / ".codex" / "hooks.json").read_text())
codex_stop = [
    hook["command"]
    for group in codex["hooks"]["Stop"]
    for hook in group["hooks"]
    if hook.get("type") == "command"
]
assert len([cmd for cmd in codex_stop if notify in cmd]) == 1, codex_stop
assert any("AGENT_NOTIFY_TITLE=Codex" in cmd for cmd in codex_stop), codex_stop

config = (home / ".codex" / "config.toml").read_text()
assert "notify =" not in config, config
assert 'model = "example-model"' in config, config
assert "multi_agent = true" in config, config
PY
