#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/bin" "$TMP/workspace"
cat > "$TMP/bin/fake-codex" <<'PY'
#!/usr/bin/env python3
import base64, hashlib, json, os, struct, sys, time
args = sys.argv[1:]
sid = os.environ.get("FAKE_CODEX_SESSION", "codex-session")
with open(os.environ["CODEX_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
if args == ["remote-control", "start", "--json"]:
    sys.exit(0)
if args != ["app-server", "proxy"]:
    sys.exit(2)

request = bytearray()
while b"\r\n\r\n" not in request:
    value = sys.stdin.buffer.read(1)
    if not value:
        sys.exit(3)
    request.extend(value)
headers = request.decode("latin1").split("\r\n")
key = next(line.split(":", 1)[1].strip() for line in headers if line.lower().startswith("sec-websocket-key:"))
accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
response = f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
sys.stdout.buffer.write(response.encode())
sys.stdout.buffer.flush()

def read_exact(size):
    value = bytearray()
    while len(value) < size:
        value.extend(sys.stdin.buffer.read(size - len(value)))
    return bytes(value)

def read_message():
    first, second = read_exact(2)
    size = second & 0x7f
    if size == 126:
        size = struct.unpack("!H", read_exact(2))[0]
    elif size == 127:
        size = struct.unpack("!Q", read_exact(8))[0]
    mask = read_exact(4) if second & 0x80 else None
    payload = read_exact(size)
    if mask:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return json.loads(payload)

def send_message(value):
    payload = json.dumps(value, separators=(",", ":")).encode()
    if len(payload) < 126:
        header = bytes((0x81, len(payload)))
    elif len(payload) < 65536:
        header = bytes((0x81, 126)) + struct.pack("!H", len(payload))
    else:
        header = bytes((0x81, 127)) + struct.pack("!Q", len(payload))
    sys.stdout.buffer.write(header + payload)
    sys.stdout.buffer.flush()

while True:
    m=read_message(); i=m.get("id"); method=m.get("method")
    if method == "thread/start": result={"thread":{"id":sid}}
    elif method == "turn/start": result={"turn":{}}
    else: result={}
    if i is not None: send_message({"id":i,"result":result})
    if method == "turn/start":
        if os.environ.get("CODEX_PAUSE"):
            open(os.environ["CODEX_STARTED"], "w").close()
            time.sleep(30)
        item={"type":"agentMessage","text":"codex result"}
        send_message({"method":"item/completed","params":{"threadId":sid,"item":item}})
        send_message({"method":"turn/completed","params":{"threadId":sid,"turn":{"status":"completed","items":[item]}}})
PY
chmod +x "$TMP/bin/fake-codex"
cat > "$TMP/bin/fake-acp" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time
sid="00000000-0000-4000-8000-000000000001"
for line in sys.stdin:
    m=json.loads(line); i=m.get("id"); method=m.get("method")
    with open(os.environ["ACP_LOG"], "a") as log: log.write(json.dumps(m)+"\n")
    if method == "session/new": result={"sessionId":sid,"configOptions":[{"id":"mode","currentValue":"agent","options":[{"value":"agent"},{"value":"plan"},{"value":"ask"}]},{"id":"model","currentValue":"example-model","options":[{"value":"example-model"}]}]}
    elif method == "session/load": result={"sessionId":sid,"configOptions":[{"id":"mode","currentValue":"agent","options":[{"value":"agent"},{"value":"plan"},{"value":"ask"}]},{"id":"model","currentValue":"example-model","options":[{"value":"example-model"}]}]}
    elif method == "session/set_config_option": result={"configOptions":[{"id":"mode","currentValue":m["params"]["value"] if m["params"]["configId"] == "mode" else "plan","options":[{"value":"agent"},{"value":"plan"},{"value":"ask"}]},{"id":"model","currentValue":m["params"]["value"] if m["params"]["configId"] == "model" else "example-model","options":[{"value":"example-model"}]}]}
    elif method == "session/prompt":
        print(json.dumps({"id":99,"method":"session/request_permission","params":{"options":[{"optionId":"allow-once","kind":"allow_once"},{"optionId":"reject-once","kind":"reject_once"}]}}),flush=True)
        for text in ("buffered ","live "):
            time.sleep(.1); print(json.dumps({"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}}}}),flush=True)
        if os.environ.get("ACP_INTERRUPT"):
            time.sleep(30)
        if os.environ.get("ACP_FAIL"):
            print(json.dumps({"id":i,"error":{"code":-1,"message":"example failure"}}),flush=True)
            continue
        result={"stopReason":"end_turn"}
    else: result={}
    if i is not None: print(json.dumps({"id":i,"result":result}),flush=True)
PY
chmod +x "$TMP/bin/fake-acp"
export AGENT_SESSION_CODEX="$TMP/bin/fake-codex" AGENT_SESSION_CURSOR="$TMP/bin/fake-acp" AGENT_SESSION_MCURSOR="$ROOT/bin/mcursor" MCURSOR_STATE_DIR="$TMP/state" ACP_LOG="$TMP/acp.log" CODEX_LOG="$TMP/codex.log"
export CODEX_THREAD_ID="main-agent-one"
if "$ROOT/bin/agent-session" --help | grep -q -- "--timeout"; then exit 1; fi
if "$ROOT/bin/agent-session" --agent cursor --timeout 1 --cwd "$TMP/workspace" --prompt example >/dev/null 2>&1; then exit 1; fi
if "$ROOT/bin/agent-session" --agent codex --config "bad/name" --cwd "$TMP/workspace" --prompt example >/dev/null 2>"$TMP/config-error"; then exit 1; fi
grep -q 'config must contain' "$TMP/config-error"
"$ROOT/bin/agent-session" --agent codex --mode write --model example-model --config example --cwd "$TMP/workspace" --prompt "example" > "$TMP/codex.json"
grep -q '"remote-control", "start", "--json"' "$TMP/codex.log"
grep -q '"app-server", "proxy"' "$TMP/codex.log"
if grep -q '"app-server", "--stdio"' "$TMP/codex.log"; then exit 1; fi
CODEX_PAUSE=1 CODEX_STARTED="$TMP/codex-started" \
    "$ROOT/bin/agent-session" --agent codex --mode write --model example-model \
    --config running --cwd "$TMP/workspace" --prompt "example" \
    > "$TMP/running.json" 2> "$TMP/running.err" &
running_pid=$!
attempt=0
while [ ! -e "$TMP/codex-started" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.05
    attempt=$((attempt + 1))
done
test -e "$TMP/codex-started"
python3 - "$TMP/workspace/luanphan_agents/running.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1])); main=value["main_agents"]
assert value["version"] == 2
assert len(main) == 1
assert main[0]["session_id"] == "main-agent-one"
entries=main[0]["sub_agents"]
assert len(entries) == 1
assert entries[0]["agent"] == "codex"
assert entries[0]["session_id"] == "codex-session"
assert entries[0]["status"] == "running"
PY
kill -TERM "$running_pid"
if wait "$running_pid"; then exit 1; fi
python3 - "$TMP/workspace/luanphan_agents/running.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1])); entries=value["main_agents"][0]["sub_agents"]
assert entries[0]["status"] == "interrupted"
PY
"$ROOT/bin/agent-session" --agent cursor --mode read --model example-model --config example --name "[Review] example" --cwd "$TMP/workspace" --prompt "example" > "$TMP/cursor.json"
python3 - "$TMP/acp.log" "$TMP/cursor.json" <<'PY'
import json, sys
messages=[json.loads(line) for line in open(sys.argv[1])]
configs=[m for m in messages if m.get("method") == "session/set_config_option"]
assert {m["params"]["configId"] for m in configs} == {"mode", "model"}
assert any(m["params"]["configId"] == "mode" and m["params"]["value"] == "plan" for m in configs)
assert json.load(open(sys.argv[2]))["permission_choices"] == ["reject-once"]
PY
CODEX_THREAD_ID="main-agent-two" FAKE_CODEX_SESSION="codex-session-two" \
    "$ROOT/bin/agent-session" --agent codex --mode write --model example-model \
    --config example --main-agent-name "Main two" --cwd "$TMP/workspace" \
    --prompt "example" > "$TMP/main-two.json"
python3 - "$TMP/workspace/luanphan_agents/example.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1])); main=value["main_agents"]
assert value["version"] == 2
assert [entry["session_id"] for entry in main] == ["main-agent-one", "main-agent-two"]
assert main[1]["name"] == "Main two"
assert {entry["agent"] for entry in main[0]["sub_agents"]} == {"codex", "cursor"}
assert [entry["session_id"] for entry in main[1]["sub_agents"]] == ["codex-session-two"]
assert all(
    "prompt" not in entry and "secret" not in json.dumps(entry).lower()
    for parent in main
    for entry in parent["sub_agents"]
)
PY
export ACP_INTERRUPT=1
"$ROOT/bin/agent-session" --agent cursor --mode read --model example-model --config example --cwd "$TMP/workspace" --prompt "example" > "$TMP/interrupted.json" 2>"$TMP/interrupted-error" &
pid=$!
sleep .5
kill -TERM "$pid"
wait "$pid" || test "$?" -eq 1
python3 - "$TMP/interrupted.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1]))
assert value["status"] == "interrupted"
assert value["session_id"] == "00000000-0000-4000-8000-000000000001"
assert value["result"] == "buffered live "
PY
unset ACP_INTERRUPT
if ACP_FAIL=1 "$ROOT/bin/agent-session" --agent cursor --mode read \
    --model example-model --config example --cwd "$TMP/workspace" \
    --prompt "example" > "$TMP/failed.json" 2> "$TMP/failed-error"; then
    exit 1
fi
python3 - "$TMP/failed.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1]))
assert value["status"] == "failed"
assert value["session_id"] == "00000000-0000-4000-8000-000000000001"
assert value["result"] == "buffered live "
PY
cat > "$TMP/workspace/luanphan_agents/legacy.json" <<'JSON'
{
  "version": 1,
  "workspace": "example",
  "sessions": [
    {
      "agent": "cursor",
      "session_id": "00000000-0000-4000-8000-000000000001",
      "name": "Legacy worker",
      "status": "completed",
      "role": "review"
    }
  ]
}
JSON
"$ROOT/bin/agent-session" --agent cursor --session 00000000-0000-4000-8000-000000000001 \
    --mode read --model example-model --config legacy --main-agent-name "Main one" \
    --cwd "$TMP/workspace" --prompt "example" > "$TMP/legacy.json"
python3 - "$TMP/workspace/luanphan_agents/legacy.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1])); main=value["main_agents"]
assert value["version"] == 2
assert len(main) == 2
unassigned=next(entry for entry in main if entry["session_id"] is None)
assigned=next(entry for entry in main if entry["session_id"] == "main-agent-one")
assert unassigned["sub_agents"] == []
assert assigned["name"] == "Main one"
assert assigned["sub_agents"][0]["role"] == "review"
PY
printf '{malformed' > "$TMP/workspace/luanphan_agents/example.json"
if "$ROOT/bin/agent-session" --agent codex --mode write --config example --cwd "$TMP/workspace" --prompt "example" > "$TMP/malformed.json" 2>"$TMP/malformed-error"; then
    exit 1
fi
python3 - "$TMP/malformed.json" "$TMP/malformed-error" <<'PY'
import json, sys
value=json.load(open(sys.argv[1]))
assert value["session_id"] == "codex-session"
assert value["result"] == "codex result"
assert "invalid agent registry" in value["registry_error"]
assert "invalid agent registry" in open(sys.argv[2]).read()
PY
echo "PASS agent-session smoke test"
