#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/bin" "$TMP/workspace"
cat > "$TMP/bin/fake-cursor" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time
with open(os.environ["CURSOR_LOG"], "a") as log:
    log.write(json.dumps({"argv": sys.argv[1:], "tmux": os.environ.get("TMUX")}) + "\n")
args = sys.argv[1:]
if args[:2] == ["persist", "list"]:
    print("No Cursor-managed persistent sessions.")
elif args[:2] == ["persist", "attach"]:
    print("native attach", args[2], flush=True)
elif args[:2] == ["persist", "stop"]:
    print("native stop", args[2], flush=True)
else:
    print("native start", flush=True)
PY
chmod +x "$TMP/bin/fake-cursor"
export MCURSOR_CURSOR="$TMP/bin/fake-cursor" MCURSOR_STATE_DIR="$TMP/state" CURSOR_LOG="$TMP/cursor.log" TMUX="/tmp/tmux-parent"
$ROOT/bin/mcursor start --cwd "$TMP/workspace" --mode read --model example-model --prompt "example" > "$TMP/start.out"
grep -q 'native start' "$TMP/start.out"
grep -q '"tmux": null' "$TMP/cursor.log"
grep -q '"persist", "example"' "$TMP/cursor.log"
$ROOT/bin/mcursor > "$TMP/bare.out"
grep -q 'native start' "$TMP/bare.out"
grep -q '"persist"' "$TMP/cursor.log"
$ROOT/bin/mcursor start --cwd "$TMP/workspace" > "$TMP/start-empty.out"
grep -q 'native start' "$TMP/start-empty.out"
$ROOT/bin/mcursor attach native-session > "$TMP/attach.out"
grep -q 'native attach native-session' "$TMP/attach.out"
$ROOT/bin/mcursor resume cursor-chat-id > "$TMP/resume.out"
grep -q 'native attach cursor-chat-id' "$TMP/resume.out"
grep -q '"persist", "attach", "cursor-chat-id"' "$TMP/cursor.log"
$ROOT/bin/mcursor stop native-session > "$TMP/stop.out"
grep -q 'native stop native-session' "$TMP/stop.out"
$ROOT/bin/mcursor list > "$TMP/list.out"
grep -q 'No Cursor-managed persistent sessions' "$TMP/list.out"
if $ROOT/bin/mcursor status native-session >/dev/null 2>&1; then exit 1; fi
if $ROOT/bin/mcursor start --name ignored --prompt example >/dev/null 2>&1; then exit 1; fi
echo "PASS mcursor native persist smoke test"
