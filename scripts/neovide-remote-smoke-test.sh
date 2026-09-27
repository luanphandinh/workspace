#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/neovide-remote-test.XXXXXX")
fakebin="$test_tmp_dir/bin"
mkdir -p "$fakebin"

cleanup() {
	if [ -f "$test_tmp_dir/ssh-listener.pid" ]; then
		kill "$(cat "$test_tmp_dir/ssh-listener.pid")" 2>/dev/null || true
	fi
	rm -rf "$test_tmp_dir"
}
trap cleanup EXIT INT TERM HUP

base_port=$(python3 - <<'PY'
import socket

for base in range(41000, 65000, 3):
    sockets = []
    try:
        for port in range(base, base + 3):
            current = socket.socket()
            current.bind(("127.0.0.1", port))
            sockets.append(current)
    except OSError:
        pass
    else:
        print(base)
        break
    finally:
        for current in sockets:
            current.close()
else:
    raise SystemExit("no free test ports")
PY
)
preview_port=$((base_port + 1))
open_port=$((base_port + 2))

cat > "$fakebin/nvim" <<'SH'
#!/bin/sh
printf '%s\n' "$NEOVIDE_MARKDOWN_PREVIEW_PORT" "$NEOVIDE_REMOTE_OPEN_PORT" "$*" > "$NEOVIDE_TEST_NVIM_LOG"
SH

cat > "$fakebin/open" <<'SH'
#!/bin/sh
printf 'open %s\n' "$1" > "$NEOVIDE_TEST_OPEN_LOG"
SH

cat > "$fakebin/xdg-open" <<'SH'
#!/bin/sh
printf 'xdg-open %s\n' "$1" > "$NEOVIDE_TEST_OPEN_LOG"
SH

cat > "$fakebin/uname" <<'SH'
#!/bin/sh
printf '%s\n' "$NEOVIDE_TEST_UNAME"
SH

cat > "$test_tmp_dir/ssh-listener.py" <<'PY'
import socket
import sys

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", int(sys.argv[1])))
server.listen()
while True:
    connection, _ = server.accept()
    connection.close()
PY

cat > "$fakebin/ssh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$NEOVIDE_TEST_SSH_LOG"
case " $* " in
	*" -O exit "*)
		if [ -f "$NEOVIDE_TEST_SSH_PID" ]; then
			kill "$(cat "$NEOVIDE_TEST_SSH_PID")" 2>/dev/null || true
		fi
		exit 0
		;;
esac

local_port=
while [ "$#" -gt 0 ]; do
	if [ "$1" = "-L" ]; then
		shift
		local_port=${1#127.0.0.1:}
		local_port=${local_port%%:*}
		break
	fi
	shift
done
python3 "$NEOVIDE_TEST_SSH_LISTENER" "$local_port" &
printf '%s\n' "$!" > "$NEOVIDE_TEST_SSH_PID"
SH

cat > "$fakebin/neovide" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$NEOVIDE_TEST_NEOVIDE_LOG"
python3 - "$NEOVIDE_TEST_SSH_LOG" "$NEOVIDE_TEST_PREVIEW_PORT" "$NEOVIDE_TEST_PORT_MAP" <<'PY'
import re
import socket
import sys
import time

log = open(sys.argv[1], encoding="utf-8").read()
local_forwards = re.findall(r"-L 127\.0\.0\.1:(\d+):127\.0\.0\.1:\d+", log)
reverse = re.search(r"-R 127\.0\.0\.1:\d+:127\.0\.0\.1:(\d+)", log)
if len(local_forwards) != 2 or reverse is None:
    raise SystemExit("missing SSH forwards")
local_nvim_port, local_preview_port = map(int, local_forwards)
local_open_port = int(reverse.group(1))
with open(sys.argv[3], "w", encoding="utf-8") as output:
    output.write(f"{local_nvim_port} {local_preview_port} {local_open_port}\n")

url = f"http://localhost:{sys.argv[2]}/page/42"
deadline = time.monotonic() + 3
while True:
    try:
        with socket.create_connection(("127.0.0.1", local_open_port), timeout=0.2) as connection:
            connection.sendall((url + "\n").encode())
        break
    except OSError:
        if time.monotonic() >= deadline:
            raise
        time.sleep(0.05)
PY

attempt=0
while [ ! -s "$NEOVIDE_TEST_OPEN_LOG" ] && [ "$attempt" -lt 60 ]; do
	sleep 0.05
	attempt=$((attempt + 1))
done
test -s "$NEOVIDE_TEST_OPEN_LOG"
SH

chmod +x "$fakebin/nvim" "$fakebin/open" "$fakebin/xdg-open" "$fakebin/uname" "$fakebin/ssh" "$fakebin/neovide"

NEOVIDE_TEST_NVIM_LOG="$test_tmp_dir/nvim.log" \
	PATH="$fakebin:/usr/bin:/bin" \
	"$repo_root/bin/neovide-server" "$base_port" example.md
test "$(sed -n '1p' "$test_tmp_dir/nvim.log")" = "$preview_port"
test "$(sed -n '2p' "$test_tmp_dir/nvim.log")" = "$open_port"
test "$(sed -n '3p' "$test_tmp_dir/nvim.log")" = "--headless --listen 127.0.0.1:$base_port example.md"

run_client_test() {
	operating_system=$1
	expected_opener=$2
	: > "$test_tmp_dir/ssh.log"
	rm -f "$test_tmp_dir/open.log" "$test_tmp_dir/neovide.log" "$test_tmp_dir/ssh-listener.pid"

	NEOVIDE_TEST_SSH_LOG="$test_tmp_dir/ssh.log" \
	NEOVIDE_TEST_SSH_PID="$test_tmp_dir/ssh-listener.pid" \
	NEOVIDE_TEST_SSH_LISTENER="$test_tmp_dir/ssh-listener.py" \
	NEOVIDE_TEST_NEOVIDE_LOG="$test_tmp_dir/neovide.log" \
	NEOVIDE_TEST_OPEN_LOG="$test_tmp_dir/open.log" \
	NEOVIDE_TEST_PREVIEW_PORT="$preview_port" \
	NEOVIDE_TEST_PORT_MAP="$test_tmp_dir/port-map" \
	NEOVIDE_TEST_UNAME="$operating_system" \
	PATH="$fakebin:/usr/bin:/bin" \
	"$repo_root/bin/neovide-client" "example-host:$base_port" --frame buttonless

	read -r local_nvim_port local_preview_port local_open_port < "$test_tmp_dir/port-map"
	test "$(cat "$test_tmp_dir/open.log")" = "$expected_opener http://127.0.0.1:$local_preview_port/page/42"
	test "$(cat "$test_tmp_dir/neovide.log")" = "--no-fork --server 127.0.0.1:$local_nvim_port --frame buttonless"
	grep -F -- "-L 127.0.0.1:$local_nvim_port:127.0.0.1:$base_port" "$test_tmp_dir/ssh.log" >/dev/null
	grep -F -- "-L 127.0.0.1:$local_preview_port:127.0.0.1:$preview_port" "$test_tmp_dir/ssh.log" >/dev/null
	grep -F -- "-R 127.0.0.1:$open_port:127.0.0.1:$local_open_port" "$test_tmp_dir/ssh.log" >/dev/null
}

run_client_test Darwin open
run_client_test Linux xdg-open

printf 'PASS remote Neovide bridge smoke test\n'
