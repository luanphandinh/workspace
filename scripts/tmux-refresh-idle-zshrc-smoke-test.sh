#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)

cleanup() {
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

fakebin="$TMP/bin"
log="$TMP/tmux.log"
mkdir -p "$fakebin"

cat > "$fakebin/tmux" <<'SH'
#!/bin/sh
set -eu

case "$1" in
list-panes)
	printf '%%1\t123\tzsh\t0\t0\t0\n'
	;;
send-keys)
	shift
	printf '%s\n' "$*" >> "$TMUX_REFRESH_SMOKE_LOG"
	;;
*)
	exit 1
	;;
esac
SH
chmod +x "$fakebin/tmux"

cat > "$fakebin/pgrep" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$fakebin/pgrep"

PATH="$fakebin:$PATH" TMUX_REFRESH_SMOKE_LOG="$log" \
	sh "$ROOT/bin/tmux-refresh-idle-zshrc" >/dev/null

grep -F -- '-t %1  setopt HIST_IGNORE_SPACE' "$log" >/dev/null || {
	printf 'expected refresh command to begin with leading-space HIST_IGNORE_SPACE\n' >&2
	cat "$log" >&2
	exit 1
}

grep -F 'source "$HOME/.zshrc"' "$log" >/dev/null || {
	printf 'expected refresh command to source ~/.zshrc\n' >&2
	cat "$log" >&2
	exit 1
}

echo "PASS tmux refresh idle zshrc smoke test"
