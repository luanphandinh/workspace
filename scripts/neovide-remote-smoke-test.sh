#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/neovide-remote-test.XXXXXX")
fakebin=$test_tmp_dir/bin
mkdir -p "$fakebin"

cleanup() {
	if [ -f "$test_tmp_dir/ssh-listener.pid" ]; then
		kill "$(cat "$test_tmp_dir/ssh-listener.pid")" 2>/dev/null || true
	fi
	rm -rf "$test_tmp_dir"
}
trap cleanup EXIT INT TERM HUP

remote_port=$($repo_root/bin/.tunnel-bridge allocate --count 1)
preview_port=$((remote_port + 1))

WORKSPACE_REMOTE_TUNNEL=1 nvim --headless --clean \
	--cmd "set runtimepath^=$repo_root/nvim" \
	'+lua require("luanphan.remote_tunnel").setup()' \
	'+lua assert(require("luanphan.remote_tunnel").enabled())' \
	'+lua assert(vim.fn.exists("*WorkspaceRemoteTunnelOpen") == 1)' \
	+qa

cat > "$fakebin/nvim" <<'SH'
#!/bin/sh
printf '%s\n' "$NEOVIDE_MARKDOWN_PREVIEW_PORT" "$WORKSPACE_REMOTE_TUNNEL" "$*" > "$NEOVIDE_TEST_NVIM_LOG"
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
	*" ~/bin/tunnel _ping-incoming "*)
		exit "$NEOVIDE_TEST_TUNNEL_STATUS"
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
if [ -n "$local_port" ]; then
	python3 "$NEOVIDE_TEST_SSH_LISTENER" "$local_port" &
	printf '%s\n' "$!" > "$NEOVIDE_TEST_SSH_PID"
fi
SH

cat > "$fakebin/neovide" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$NEOVIDE_TEST_NEOVIDE_LOG"
SH

chmod +x "$fakebin/nvim" "$fakebin/ssh" "$fakebin/neovide"

"$repo_root/bin/neovide-server" --help > "$test_tmp_dir/server-help.log"
"$repo_root/bin/neovide-client" --help > "$test_tmp_dir/client-help.log"

NEOVIDE_TEST_NVIM_LOG=$test_tmp_dir/nvim.log \
	PATH="$fakebin:/usr/bin:/bin" \
	"$repo_root/bin/neovide-server" --port "$remote_port" example.md \
	2> "$test_tmp_dir/server.log"
test "$(sed -n '1p' "$test_tmp_dir/nvim.log")" = "$preview_port"
test "$(sed -n '2p' "$test_tmp_dir/nvim.log")" = 1
test "$(sed -n '3p' "$test_tmp_dir/nvim.log")" = "--headless --listen 127.0.0.1:$remote_port example.md"

run_client_test() {
	tunnel_status=$1
	: > "$test_tmp_dir/ssh.log"
	rm -f "$test_tmp_dir/ssh-listener.pid"

	NEOVIDE_TEST_SSH_LOG=$test_tmp_dir/ssh.log \
	NEOVIDE_TEST_SSH_PID=$test_tmp_dir/ssh-listener.pid \
	NEOVIDE_TEST_SSH_LISTENER=$test_tmp_dir/ssh-listener.py \
	NEOVIDE_TEST_NEOVIDE_LOG=$test_tmp_dir/neovide.log \
	NEOVIDE_TEST_TUNNEL_STATUS=$tunnel_status \
	PATH="$fakebin:/usr/bin:/bin" \
	"$repo_root/bin/neovide-client" --port "$remote_port" example-host --frame buttonless \
	2> "$test_tmp_dir/client.log"

	local_nvim_port=$(sed -n 's/.*-L 127\.0\.0\.1:\([0-9][0-9]*\):127\.0\.0\.1:.*/\1/p' "$test_tmp_dir/ssh.log" | sed -n '1p')
	test -n "$local_nvim_port"
	test "$(cat "$test_tmp_dir/neovide.log")" = "--no-fork --server 127.0.0.1:$local_nvim_port --frame buttonless"
	grep -F -- "-L 127.0.0.1:$local_nvim_port:127.0.0.1:$remote_port" "$test_tmp_dir/ssh.log" >/dev/null
	if [ "$tunnel_status" -eq 0 ]; then
		grep -F '[Success] neovide-client: workspace tunnel is available for URLs and images' "$test_tmp_dir/client.log" >/dev/null
	else
		grep -F "[Warning] neovide-client: workspace tunnel is unavailable; run 'tunnel connect example-host' locally" "$test_tmp_dir/client.log" >/dev/null
	fi
}

run_client_test 0
run_client_test 1

printf 'PASS remote Neovide smoke test\n'
