#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)

cleanup() {
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

assert_exists() {
	test -e "$1" || {
		printf 'missing expected path: %s\n' "$1" >&2
		exit 1
	}
}

assert_line_count() {
	count=$(wc -l < "$1" | tr -d ' ')
	if [ "$count" != "$2" ]; then
		printf 'expected %s line(s), got %s in %s\n' "$2" "$count" "$1" >&2
		cat "$1" >&2
		exit 1
	fi
}

assert_line() {
	grep -Fx -- "$2" "$1" >/dev/null || {
		printf 'expected %s to contain line: %s\n' "$1" "$2" >&2
		cat "$1" >&2
		exit 1
	}
}

PROJECT="$TMP/project"
FAKEBIN="$TMP/bin"
FZF_INPUT="$TMP/fzf-input"
RUN_LOG="$PROJECT/run.log"
mkdir -p "$PROJECT" "$FAKEBIN"

(
	cd "$PROJECT"
	python3 "$ROOT/bin/cmds-hub" exec 'printf "%s\n" first >> run.log' >/dev/null
	python3 "$ROOT/bin/cmds-hub" exec 'printf "%s\n" second >> run.log' >/dev/null
)

HISTORY="$PROJECT/.cmds-hub/cmd_history"
assert_exists "$HISTORY"
assert_line_count "$HISTORY" 2
assert_line "$HISTORY" 'printf "%s\n" first >> run.log'
assert_line "$HISTORY" 'printf "%s\n" second >> run.log'
assert_line_count "$RUN_LOG" 2

(
	cd "$PROJECT"
	python3 "$ROOT/bin/cmds-hub" replay >/dev/null
)
assert_line_count "$RUN_LOG" 3
test "$(tail -n 1 "$RUN_LOG")" = "second"

: > "$RUN_LOG"
(
	cd "$PROJECT"
	python3 "$ROOT/bin/cmds-hub" replay --all >/dev/null
)
assert_line_count "$RUN_LOG" 2
test "$(sed -n '1p' "$RUN_LOG")" = "first"
test "$(sed -n '2p' "$RUN_LOG")" = "second"
assert_line_count "$HISTORY" 2

cat > "$FAKEBIN/fzf" <<'SH'
#!/bin/sh
set -eu
cat > "$CMDS_HUB_FZF_INPUT"
printf '%s\n' "$CMDS_HUB_FZF_OUTPUT"
SH
chmod +x "$FAKEBIN/fzf"

: > "$RUN_LOG"
(
	cd "$PROJECT"
	PATH="$FAKEBIN:$PATH" \
		CMDS_HUB_FZF_INPUT="$FZF_INPUT" \
		CMDS_HUB_FZF_OUTPUT='printf "%s\n" first >> run.log' \
		python3 "$ROOT/bin/cmds-hub" pick >/dev/null
)
assert_line "$FZF_INPUT" 'printf "%s\n" first >> run.log'
assert_line "$FZF_INPUT" 'printf "%s\n" second >> run.log'
assert_line_count "$RUN_LOG" 1
test "$(cat "$RUN_LOG")" = "first"
assert_line_count "$HISTORY" 2

echo "PASS cmds-hub smoke test"
