#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

FAKEBIN="$TMP/fakebin"
LOG="$TMP/go.log"
mkdir -p "$FAKEBIN" "$TMP/modules/old/sub" "$TMP/modules/current" "$TMP/modules/preferred" "$TMP/modules/future" "$TMP/outside"

cat > "$FAKEBIN/real-go" <<'SH'
#!/bin/sh
set -eu
printf 'toolchain=<%s>\n' "${GOTOOLCHAIN-unset}" >> "$GO_WRAPPER_LOG"
for argument in "$@"; do
    printf 'argument=<%s>\n' "$argument" >> "$GO_WRAPPER_LOG"
done
SH
chmod +x "$FAKEBIN/real-go"

cat > "$FAKEBIN/go-remote-test" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$FAKEBIN/go-remote-test"

printf 'module example.com/old\n\ngo 1.22\n' > "$TMP/modules/old/go.mod"
printf 'module example.com/current\n\ngo 1.24\n' > "$TMP/modules/current/go.mod"
printf 'module example.com/preferred\n\ngo 1.24\n\ntoolchain go1.25.3\n' > "$TMP/modules/preferred/go.mod"
printf 'module example.com/future\n\ngo 1.27.1\n' > "$TMP/modules/future/go.mod"

export GO_WRAPPER_LOG="$LOG"
export LOCAL_REAL_GO="$FAKEBIN/real-go"
export LOCAL_GO_PATCHER=
export LOCAL_GO_GCFLAGS=
export PATH="$FAKEBIN:$PATH"
unset GOTOOLCHAIN

fail() {
    printf 'FAIL %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    grep -F -- "$2" "$1" >/dev/null || fail "expected $1 to contain: $2"
}

: > "$LOG"
(
    cd "$TMP/modules/old/sub"
    "$ROOT/bin/go" mod tidy
)
assert_contains "$LOG" 'toolchain=<go1.23.12+auto>'
assert_contains "$LOG" 'argument=<mod>'
assert_contains "$LOG" 'argument=<tidy>'

: > "$LOG"
(
    cd "$TMP/outside"
    "$ROOT/bin/go" version
)
assert_contains "$LOG" 'toolchain=<unset>'

: > "$LOG"
(
    cd "$TMP/modules/current"
    "$ROOT/bin/go" build ./...
)
assert_contains "$LOG" 'toolchain=<go1.24.13+auto>'
assert_contains "$LOG" 'argument=<build>'

: > "$LOG"
(
    cd "$TMP/modules/preferred"
    "$ROOT/bin/go" build ./...
)
assert_contains "$LOG" 'toolchain=<go1.25.12+auto>'
assert_contains "$LOG" 'argument=<build>'

: > "$LOG"
(
    cd "$TMP/modules/future"
    "$ROOT/bin/go" vet ./...
)
assert_contains "$LOG" 'toolchain=<go1.26.4+auto>'

: > "$LOG"
(
    cd "$TMP/outside"
    "$ROOT/bin/go" -C "$TMP/modules/old" generate ./...
)
assert_contains "$LOG" 'toolchain=<go1.23.12+auto>'
assert_contains "$LOG" 'argument=<-C>'

: > "$LOG"
(
    cd "$TMP/modules/old"
    GOTOOLCHAIN=go1.24.13 "$ROOT/bin/go" version
)
assert_contains "$LOG" 'toolchain=<go1.24.13>'

: > "$LOG"
(
    cd "$TMP/modules/old"
    LOCAL_GO_TOOLCHAINS='go1.24.13 go1.26.4' "$ROOT/bin/go" --no-remote test ./...
)
assert_contains "$LOG" 'toolchain=<go1.24.13+auto>'
assert_contains "$LOG" 'argument=<test>'

printf 'PASS go wrapper smoke test\n'
