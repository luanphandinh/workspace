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

for base in range(41000, 65000, 4):
    sockets = []
    try:
        for port in range(base, base + 4):
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
image_port=$((base_port + 3))

cat > "$fakebin/nvim" <<'SH'
#!/bin/sh
printf '%s\n' "$NEOVIDE_MARKDOWN_PREVIEW_PORT" "$NEOVIDE_REMOTE_OPEN_PORT" "$NEOVIDE_REMOTE_IMAGE_PORT" "$*" > "$NEOVIDE_TEST_NVIM_LOG"
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

cat > "$fakebin/swift" <<'SH'
#!/bin/sh
printf '\211PNG\r\n\032\nclipboard-image'
SH

cat > "$fakebin/wl-paste" <<'SH'
#!/bin/sh
printf '\211PNG\r\n\032\nclipboard-image'
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
set -eu
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

read -r local_nvim_port local_preview_port local_open_port < "$NEOVIDE_TEST_PORT_MAP"
image_path=$(
	NEOVIDE_REMOTE_IMAGE_PORT="$local_open_port" \
	XDG_CACHE_HOME="$NEOVIDE_TEST_IMAGE_CACHE" \
	"$NEOVIDE_TEST_PASTE_IMAGE"
)
printf '%s\n' "$image_path" > "$NEOVIDE_TEST_IMAGE_LOG"

attempt=0
while [ ! -s "$NEOVIDE_TEST_OPEN_LOG" ] && [ "$attempt" -lt 60 ]; do
	sleep 0.05
	attempt=$((attempt + 1))
done
test -s "$NEOVIDE_TEST_OPEN_LOG"
SH

chmod +x "$fakebin/nvim" "$fakebin/open" "$fakebin/xdg-open" "$fakebin/uname" "$fakebin/swift" "$fakebin/wl-paste" "$fakebin/ssh" "$fakebin/neovide"

"$repo_root/bin/neovide-server" --help > "$test_tmp_dir/server-help.log"
grep -F -- '--port PORT' "$test_tmp_dir/server-help.log" >/dev/null
grep -F -- '--trace' "$test_tmp_dir/server-help.log" >/dev/null

"$repo_root/bin/neovide-client" --help > "$test_tmp_dir/client-help.log"
grep -F -- '--port PORT' "$test_tmp_dir/client-help.log" >/dev/null
grep -F -- '--trace' "$test_tmp_dir/client-help.log" >/dev/null
grep -F -- '--ssh-verbose' "$test_tmp_dir/client-help.log" >/dev/null

if "$repo_root/bin/neovide-server" --port invalid > /dev/null 2> "$test_tmp_dir/server-error.log"; then
	exit 1
fi
grep -F '[Error] neovide-server: port must be numeric' "$test_tmp_dir/server-error.log" >/dev/null

if "$repo_root/bin/neovide-client" --port invalid example-host > /dev/null 2> "$test_tmp_dir/client-error.log"; then
	exit 1
fi
grep -F '[Error] neovide-client: port must be numeric' "$test_tmp_dir/client-error.log" >/dev/null

NEOVIDE_TEST_NVIM_LOG="$test_tmp_dir/nvim.log" \
	PATH="$fakebin:/usr/bin:/bin" \
	"$repo_root/bin/neovide-server" --port "$base_port" example.md \
	2> "$test_tmp_dir/server.log"
test "$(sed -n '1p' "$test_tmp_dir/nvim.log")" = "$preview_port"
test "$(sed -n '2p' "$test_tmp_dir/nvim.log")" = "$open_port"
test "$(sed -n '3p' "$test_tmp_dir/nvim.log")" = "$image_port"
test "$(sed -n '4p' "$test_tmp_dir/nvim.log")" = "--headless --listen 127.0.0.1:$base_port example.md"
grep -F "[Info] neovide-server: Neovim RPC listening on 127.0.0.1:$base_port" "$test_tmp_dir/server.log" >/dev/null
grep -F "[Info] neovide-server: Markdown preview will use 127.0.0.1:$preview_port" "$test_tmp_dir/server.log" >/dev/null
grep -F "[Info] neovide-server: browser callback will use 127.0.0.1:$open_port" "$test_tmp_dir/server.log" >/dev/null
grep -F "[Info] neovide-server: clipboard-image callback will use 127.0.0.1:$image_port" "$test_tmp_dir/server.log" >/dev/null
grep -F "[Command] neovide-server: nvim --headless --listen 127.0.0.1:$base_port" "$test_tmp_dir/server.log" >/dev/null
grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] \[Info\] neovide-server:' "$test_tmp_dir/server.log" >/dev/null

run_client_test() {
	operating_system=$1
	expected_opener=$2
	expected_clipboard_backend=$3
	: > "$test_tmp_dir/ssh.log"
	rm -f "$test_tmp_dir/open.log" "$test_tmp_dir/neovide.log" "$test_tmp_dir/image.log" "$test_tmp_dir/ssh-listener.pid"
	rm -rf "$test_tmp_dir/image-cache"

	NEOVIDE_TEST_SSH_LOG="$test_tmp_dir/ssh.log" \
	NEOVIDE_TEST_SSH_PID="$test_tmp_dir/ssh-listener.pid" \
	NEOVIDE_TEST_SSH_LISTENER="$test_tmp_dir/ssh-listener.py" \
	NEOVIDE_TEST_NEOVIDE_LOG="$test_tmp_dir/neovide.log" \
	NEOVIDE_TEST_OPEN_LOG="$test_tmp_dir/open.log" \
	NEOVIDE_TEST_IMAGE_LOG="$test_tmp_dir/image.log" \
	NEOVIDE_TEST_IMAGE_CACHE="$test_tmp_dir/image-cache" \
	NEOVIDE_TEST_PASTE_IMAGE="$repo_root/bin/neovide-paste-image" \
	NEOVIDE_TEST_PREVIEW_PORT="$preview_port" \
	NEOVIDE_TEST_PORT_MAP="$test_tmp_dir/port-map" \
	NEOVIDE_TEST_UNAME="$operating_system" \
	PATH="$fakebin:/usr/bin:/bin" \
	sh -c 'if [ "$1" = Darwin ]; then
		"$2" --trace --port "$3" example-host --frame buttonless
	else
		"$2" --ssh-verbose "example-host:$3" --frame buttonless
	fi' sh "$operating_system" "$repo_root/bin/neovide-client" "$base_port" \
	2> "$test_tmp_dir/client-$operating_system.log"

	read -r local_nvim_port local_preview_port local_open_port < "$test_tmp_dir/port-map"
	clipboard_image=$(cat "$test_tmp_dir/image.log")
	test "$(cat "$test_tmp_dir/open.log")" = "$expected_opener http://127.0.0.1:$local_preview_port/page/42"
	test "$(cat "$test_tmp_dir/neovide.log")" = "--no-fork --server 127.0.0.1:$local_nvim_port --frame buttonless"
	test -f "$clipboard_image"
	python3 - "$clipboard_image" <<'PY'
import pathlib
import sys

assert pathlib.Path(sys.argv[1]).read_bytes() == b"\x89PNG\r\n\x1a\nclipboard-image"
PY
	grep -F -- "-L 127.0.0.1:$local_nvim_port:127.0.0.1:$base_port" "$test_tmp_dir/ssh.log" >/dev/null
	grep -F -- "-L 127.0.0.1:$local_preview_port:127.0.0.1:$preview_port" "$test_tmp_dir/ssh.log" >/dev/null
	grep -F -- "-R 127.0.0.1:$open_port:127.0.0.1:$local_open_port" "$test_tmp_dir/ssh.log" >/dev/null
	grep -F -- "-R 127.0.0.1:$image_port:127.0.0.1:$local_open_port" "$test_tmp_dir/ssh.log" >/dev/null
	grep -F "[Success] neovide-client: SSH tunnel established" "$test_tmp_dir/client-$operating_system.log" >/dev/null
	grep -F "[Info] neovide-client: launching Neovide" "$test_tmp_dir/client-$operating_system.log" >/dev/null
	grep -F "[Info] neovide-client: local image clipboard backend: $expected_clipboard_backend" "$test_tmp_dir/client-$operating_system.log" >/dev/null
	grep -F "[Info] neovide bridge: received preview URL: http://localhost:$preview_port/page/42" "$test_tmp_dir/client-$operating_system.log" >/dev/null
	grep -F "[Info] neovide bridge: opening local URL: http://127.0.0.1:$local_preview_port/page/42" "$test_tmp_dir/client-$operating_system.log" >/dev/null
	grep -F "[Command] neovide bridge: $expected_opener http://127.0.0.1:$local_preview_port/page/42" "$test_tmp_dir/client-$operating_system.log" >/dev/null
	grep -F "[Info] neovide bridge: received clipboard image request" "$test_tmp_dir/client-$operating_system.log" >/dev/null
	grep -F "[Success] neovide bridge: sending clipboard image (23 bytes)" "$test_tmp_dir/client-$operating_system.log" >/dev/null
	grep -F "[Success] neovide bridge: saved clipboard image to $clipboard_image" "$test_tmp_dir/client-$operating_system.log" >/dev/null
	grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] \[Info\] neovide-client:' "$test_tmp_dir/client-$operating_system.log" >/dev/null
	grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] \[Info\] neovide bridge: received clipboard image request' "$test_tmp_dir/client-$operating_system.log" >/dev/null
	if [ "$operating_system" = Darwin ]; then
		grep -F '+ uname -s' "$test_tmp_dir/client-$operating_system.log" >/dev/null
	else
		grep -F -- '-v -o ControlPersist=no' "$test_tmp_dir/ssh.log" >/dev/null
	fi
}

run_client_test Darwin open macos
run_client_test Linux xdg-open wayland

printf 'PASS remote Neovide bridge smoke test\n'
