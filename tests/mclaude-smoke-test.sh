#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)

cleanup() {
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

mkdir -p "$TMP/bin"
LOG="$TMP/claude.log"
cat > "$TMP/bin/claude" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$MCLAUDE_TEST_LOG"
case " $* " in
	*" --resume --remote-control "*) exit "${MCLAUDE_TEST_PICKER_STATUS:-0}" ;;
esac
exit 0
SH
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH" MCLAUDE_TEST_LOG="$LOG"

expect_calls() {
	expected="$1"
	shift
	: > "$LOG"
	status=0
	sh "$ROOT/bin/mclaude" "$@" || status="$?"
	actual=$(cat "$LOG")
	if [ "$actual" != "$expected" ]; then
		printf 'mclaude %s\nexpected calls:\n%s\nactual calls:\n%s\n' "$*" "$expected" "$actual" >&2
		exit 1
	fi
	return "$status"
}

expect_calls '--resume --remote-control'

MCLAUDE_TEST_PICKER_STATUS=1 expect_calls '--resume --remote-control
--remote-control'

if MCLAUDE_TEST_PICKER_STATUS=3 expect_calls '--resume --remote-control'; then
	printf 'expected mclaude to return the picker failure status\n' >&2
	exit 1
fi

expect_calls '--resume 01234567-89ab-cdef-0123-456789abcdef --remote-control' resume 01234567-89ab-cdef-0123-456789abcdef
expect_calls 'fix the failing test --remote-control' "fix the failing test"
expect_calls '--model opus --remote-control' --model opus
expect_calls '-p hello' -p hello
expect_calls '--remote-control phone' --remote-control phone
expect_calls '-- --not-an-option' -- --not-an-option
expect_calls '--version' --version
expect_calls 'remote-control --name example' remote-control --name example
expect_calls 'mcp list' mcp list

printf 'mclaude smoke test passed\n'
