#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/tunnel-test.XXXXXX")
fakebin=$test_tmp_dir/bin
fakehome=$test_tmp_dir/home
mkdir -p "$fakebin" "$fakehome/bin"
clipboard_path_file=$test_tmp_dir/clipboard-path
: > "$clipboard_path_file"

cleanup() {
	if [ -n "${connect_pid:-}" ]; then
		kill "$connect_pid" 2>/dev/null || true
		wait "$connect_pid" 2>/dev/null || true
	fi
	if [ -n "${bridge_pid:-}" ]; then
		kill "$bridge_pid" 2>/dev/null || true
		wait "$bridge_pid" 2>/dev/null || true
	fi
	rm -rf "$test_tmp_dir"
}
trap cleanup EXIT INT TERM HUP

cat > "$fakebin/swift" <<'SH'
#!/bin/sh
case "${2:-}" in
	*urlReadingFileURLsOnly*)
		[ -s "$TUNNEL_TEST_CLIPBOARD_PATH_FILE" ] || exit 2
		path=$(sed -n '1p' "$TUNNEL_TEST_CLIPBOARD_PATH_FILE")
		printf '%s\0' "$path"
		;;
	*) printf '\211PNG\r\n\032\nclipboard-image' ;;
esac
SH

cat > "$fakebin/open" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >> "$TUNNEL_TEST_OPEN_LOG"
SH
ln -s open "$fakebin/xdg-open"

cat > "$fakebin/ssh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TUNNEL_TEST_SSH_LOG"
SH

chmod +x "$fakebin/swift" "$fakebin/open" "$fakebin/ssh"
cp "$repo_root/bin/tunnel" "$fakehome/bin/tunnel"
cp "$repo_root/bin/.tunnel-bridge" "$fakehome/bin/.tunnel-bridge"
chmod +x "$fakehome/bin/tunnel" "$fakehome/bin/.tunnel-bridge"

port=$($repo_root/bin/.tunnel-bridge allocate --count 1)
token=$($repo_root/bin/.tunnel-bridge token)
: > "$test_tmp_dir/open.log"
: > "$test_tmp_dir/ssh.log"

TUNNEL_TEST_OPEN_LOG=$test_tmp_dir/open.log \
TUNNEL_TEST_SSH_LOG=$test_tmp_dir/ssh.log \
TUNNEL_TEST_CLIPBOARD_PATH_FILE=$clipboard_path_file \
PATH="$fakebin:/usr/bin:/bin" \
"$repo_root/bin/.tunnel-bridge" serve \
	--listen-port "$port" \
	--token "$token" \
	--opener open \
	--control-socket "$test_tmp_dir/control" \
	--ssh-host example-host \
	--clipboard-backend macos \
	2> "$test_tmp_dir/bridge.log" &
bridge_pid=$!
"$repo_root/bin/.tunnel-bridge" wait --port "$port" --timeout 3

printf '%s %s %s\n' "$port" "$token" example-client | HOME="$fakehome" "$fakehome/bin/tunnel" _register
HOME="$fakehome" "$fakehome/bin/tunnel" status > "$test_tmp_dir/status.log"
grep -Fx 'Incoming connection:' "$test_tmp_dir/status.log" >/dev/null
grep -Fx "  example-client: active on 127.0.0.1:$port" "$test_tmp_dir/status.log" >/dev/null
HOME="$fakehome" "$fakehome/bin/tunnel" open https://example.com/docs
HOME="$fakehome" "$fakehome/bin/tunnel" https://example.com/guide
HOME="$fakehome" "$fakehome/bin/tunnel" open http://127.0.0.1:4321/page/7

source_root="$test_tmp_dir/source items"
source_file="$source_root/example file.txt"
source_dir="$source_root/example directory"
mkdir -p "$source_dir/nested"
printf '%s\n' 'clipboard file' > "$source_file"
printf '%s\n' 'nested clipboard file' > "$source_dir/nested/item.txt"
ln -s nested/item.txt "$source_dir/item-link.txt"
chmod +x "$source_file"

printf '%s\n' "$source_file" > "$clipboard_path_file"
clipboard_result=$(HOME="$fakehome" "$fakehome/bin/tunnel" paste)
tab=$(printf '\t')
test "${clipboard_result%%"$tab"*}" = file
remote_file=${clipboard_result#*"$tab"}
cmp "$source_file" "$remote_file"
test -x "$remote_file"

printf '%s\n' "$source_dir" > "$clipboard_path_file"
clipboard_result=$(HOME="$fakehome" "$fakehome/bin/tunnel" paste)
test "${clipboard_result%%"$tab"*}" = directory
remote_dir=${clipboard_result#*"$tab"}
test -d "$remote_dir"
cmp "$source_dir/nested/item.txt" "$remote_dir/nested/item.txt"
test "$(readlink "$remote_dir/item-link.txt")" = nested/item.txt

: > "$clipboard_path_file"
clipboard_result=$(HOME="$fakehome" "$fakehome/bin/tunnel" paste)
test "${clipboard_result%%"$tab"*}" = image
clipboard_image_path=${clipboard_result#*"$tab"}
test -f "$clipboard_image_path"
python3 - "$clipboard_image_path" <<'PY'
import pathlib
import sys

assert pathlib.Path(sys.argv[1]).read_bytes() == b"\x89PNG\r\n\x1a\nclipboard-image"
PY

attempt=0
while [ "$(wc -l < "$test_tmp_dir/open.log")" -lt 3 ] && [ "$attempt" -lt 40 ]; do
	sleep 0.05
	attempt=$((attempt + 1))
done
grep -Fx 'https://example.com/docs' "$test_tmp_dir/open.log" >/dev/null
grep -Fx 'https://example.com/guide' "$test_tmp_dir/open.log" >/dev/null
grep -E '^http://127\.0\.0\.1:[0-9]+/page/7$' "$test_tmp_dir/open.log" >/dev/null
grep -F -- '-O forward -L 127.0.0.1:' "$test_tmp_dir/ssh.log" >/dev/null
grep -F -- ':127.0.0.1:4321 example-host' "$test_tmp_dir/ssh.log" >/dev/null

python3 - "$port" <<'PY'
import socket
import sys

with socket.create_connection(("127.0.0.1", int(sys.argv[1]))) as connection:
    connection.sendall(b"AUTH wrong-token ping\n")
    response = connection.makefile("rb").readline()
assert response.startswith(b"ERROR authentication failed")
PY

mkdir -p "$fakehome/.cache/workspace-tunnel/outgoing"
printf '%s\n%s\n%s\n%s\n%s\n' \
	"$$" example-host "$port" 42001 "$test_tmp_dir/control" \
	> "$fakehome/.cache/workspace-tunnel/outgoing/$$"
HOME="$fakehome" TUNNEL_TEST_SSH_LOG=$test_tmp_dir/ssh.log PATH="$fakebin:/usr/bin:/bin" \
	"$fakehome/bin/tunnel" status > "$test_tmp_dir/status.log"
grep -Fx 'Outgoing connections:' "$test_tmp_dir/status.log" >/dev/null
grep -Fx "  example-host: active (PID $$, local 127.0.0.1:$port -> remote 127.0.0.1:42001)" "$test_tmp_dir/status.log" >/dev/null

printf '%s\n' "$token" | HOME="$fakehome" "$fakehome/bin/tunnel" _unregister
rm -f "$fakehome/.cache/workspace-tunnel/outgoing/$$"
if HOME="$fakehome" "$fakehome/bin/tunnel" status >/dev/null 2>&1; then
	exit 1
fi

kill "$bridge_pid"
wait "$bridge_pid" 2>/dev/null || true
bridge_pid=

cat > "$fakebin/wl-paste" <<'SH'
#!/bin/sh
case "$1" in
	--list-types)
		[ ! -s "$TUNNEL_TEST_CLIPBOARD_PATH_FILE" ] || printf '%s\n' 'x-special/gnome-copied-files'
		printf '%s\n' 'image/png'
		;;
	--no-newline)
		case "$3" in
			x-special/gnome-copied-files)
				[ -s "$TUNNEL_TEST_CLIPBOARD_PATH_FILE" ] || exit 2
				python3 - "$(sed -n '1p' "$TUNNEL_TEST_CLIPBOARD_PATH_FILE")" <<'PY'
import sys
from urllib.parse import quote

print("copy")
print("file://" + quote(sys.argv[1]))
PY
				;;
			image/png) printf '\211PNG\r\n\032\nclipboard-image' ;;
			*) exit 2 ;;
		esac
		;;
	*) exit 2 ;;
esac
SH
chmod +x "$fakebin/wl-paste"

linux_port=$($repo_root/bin/.tunnel-bridge allocate --count 1)
linux_token=$($repo_root/bin/.tunnel-bridge token)
TUNNEL_TEST_CLIPBOARD_PATH_FILE=$clipboard_path_file \
PATH="$fakebin:/usr/bin:/bin" \
"$repo_root/bin/.tunnel-bridge" serve \
	--listen-port "$linux_port" \
	--token "$linux_token" \
	--opener open \
	--control-socket "$test_tmp_dir/control" \
	--ssh-host example-host \
	--clipboard-backend wayland \
	2> "$test_tmp_dir/linux-bridge.log" &
bridge_pid=$!
"$repo_root/bin/.tunnel-bridge" wait --port "$linux_port" --timeout 3
printf '%s %s %s\n' "$linux_port" "$linux_token" example-client \
	| HOME="$fakehome" "$fakehome/bin/tunnel" _register
printf '%s\n' "$source_file" > "$clipboard_path_file"
clipboard_result=$(HOME="$fakehome" "$fakehome/bin/tunnel" paste)
test "${clipboard_result%%"$tab"*}" = file
linux_remote_file=${clipboard_result#*"$tab"}
cmp "$source_file" "$linux_remote_file"
printf '%s\n' "$linux_token" | HOME="$fakehome" "$fakehome/bin/tunnel" _unregister
kill "$bridge_pid"
wait "$bridge_pid" 2>/dev/null || true
bridge_pid=

connect_home=$test_tmp_dir/connect-home
remote_home=$test_tmp_dir/remote-home
mkdir -p "$connect_home/bin" "$remote_home/bin"
cp "$repo_root/bin/tunnel" "$connect_home/bin/tunnel"
cp "$repo_root/bin/.tunnel-bridge" "$connect_home/bin/.tunnel-bridge"
cp "$repo_root/bin/tunnel" "$remote_home/bin/tunnel"
cp "$repo_root/bin/.tunnel-bridge" "$remote_home/bin/.tunnel-bridge"
chmod +x \
	"$connect_home/bin/tunnel" \
	"$connect_home/bin/.tunnel-bridge" \
	"$remote_home/bin/tunnel" \
	"$remote_home/bin/.tunnel-bridge"
cat > "$fakebin/ssh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TUNNEL_TEST_SSH_LOG"
case " $* " in
	*" _register "*)
		HOME="$TUNNEL_TEST_REMOTE_HOME" "$TUNNEL_TEST_REMOTE_HOME/bin/tunnel" _register
		;;
	*" _unregister "*)
		HOME="$TUNNEL_TEST_REMOTE_HOME" "$TUNNEL_TEST_REMOTE_HOME/bin/tunnel" _unregister
		;;
	*" -O forward "*)
		printf '%s\n' 43001
		;;
	*" -O check "*)
		test -f "$TUNNEL_TEST_KEEPALIVE"
		;;
	*)
		exit 0
		;;
esac
SH
chmod +x "$fakebin/ssh"
: > "$test_tmp_dir/connect-ssh.log"
: > "$test_tmp_dir/connect-open.log"
: > "$test_tmp_dir/keepalive"
HOME="$connect_home" \
TUNNEL_TEST_KEEPALIVE=$test_tmp_dir/keepalive \
TUNNEL_TEST_OPEN_LOG=$test_tmp_dir/connect-open.log \
TUNNEL_TEST_REMOTE_HOME=$remote_home \
TUNNEL_TEST_SSH_LOG=$test_tmp_dir/connect-ssh.log \
PATH="$fakebin:/usr/bin:/bin" \
	"$connect_home/bin/tunnel" connect example-host > "$test_tmp_dir/connect.log" 2>&1 &
connect_pid=$!
attempt=0
while { [ ! -f "$connect_home/.cache/workspace-tunnel/outgoing/$connect_pid" ] \
	|| [ ! -f "$remote_home/.cache/workspace-tunnel/connection" ]; } \
	&& [ "$attempt" -lt 60 ]
do
	sleep 0.05
	attempt=$((attempt + 1))
done
test -f "$connect_home/.cache/workspace-tunnel/outgoing/$connect_pid"
test -f "$remote_home/.cache/workspace-tunnel/connection"
HOME="$connect_home" \
TUNNEL_TEST_KEEPALIVE=$test_tmp_dir/keepalive \
TUNNEL_TEST_REMOTE_HOME=$remote_home \
TUNNEL_TEST_SSH_LOG=$test_tmp_dir/connect-ssh.log \
PATH="$fakebin:/usr/bin:/bin" \
	"$connect_home/bin/tunnel" status > "$test_tmp_dir/connect-status.log"
grep -F "  example-host: active (PID $connect_pid," "$test_tmp_dir/connect-status.log" >/dev/null
finished_connect_pid=$connect_pid
kill -TERM "$connect_pid"
wait "$connect_pid" 2>/dev/null || true
connect_pid=
test ! -e "$connect_home/.cache/workspace-tunnel/outgoing/$finished_connect_pid"
test ! -e "$remote_home/.cache/workspace-tunnel/connection"

cat > "$fakehome/bin/tunnel" <<'SH'
#!/bin/sh
printf 'image\t%s\n' /tmp/clipboard-test.png
SH
cat > "$fakebin/tmux" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TUNNEL_TEST_TMUX_LOG"
SH
chmod +x "$fakehome/bin/tunnel" "$fakebin/tmux"
: > "$test_tmp_dir/tmux.log"
HOME="$fakehome" TUNNEL_TEST_TMUX_LOG=$test_tmp_dir/tmux.log PATH="$fakebin:/usr/bin:/bin" \
	"$repo_root/bin/tmux-paste-clipboard" %7
grep -Fx 'send-keys -l -t %7 [Image: /tmp/clipboard-test.png] ' "$test_tmp_dir/tmux.log" >/dev/null

cat > "$fakehome/bin/tunnel" <<'SH'
#!/bin/sh
printf 'directory\t%s\n' '/tmp/clipboard directory'
SH
chmod +x "$fakehome/bin/tunnel"
: > "$test_tmp_dir/tmux.log"
HOME="$fakehome" TUNNEL_TEST_TMUX_LOG=$test_tmp_dir/tmux.log PATH="$fakebin:/usr/bin:/bin" \
	"$repo_root/bin/tmux-paste-clipboard" %7
grep -Fx 'send-keys -l -t %7 /tmp/clipboard directory ' "$test_tmp_dir/tmux.log" >/dev/null

cat > "$fakehome/bin/tunnel" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$fakehome/bin/tunnel"
: > "$test_tmp_dir/tmux.log"
HOME="$fakehome" TUNNEL_TEST_TMUX_LOG=$test_tmp_dir/tmux.log PATH="$fakebin:/usr/bin:/bin" \
	"$repo_root/bin/tmux-paste-clipboard" %7
grep -Fx 'send-keys -t %7 C-v' "$test_tmp_dir/tmux.log" >/dev/null

printf 'PASS workspace tunnel smoke test\n'
