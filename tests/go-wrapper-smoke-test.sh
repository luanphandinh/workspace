#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

FAKEBIN="$TMP/fakebin"
LOG="$TMP/go.log"
mkdir -p \
    "$FAKEBIN" \
    "$TMP/modules/legacy" \
    "$TMP/modules/old/sub" \
    "$TMP/modules/current" \
    "$TMP/modules/preferred" \
    "$TMP/modules/bundled" \
    "$TMP/modules/future" \
    "$TMP/outside"

cat > "$FAKEBIN/real-go" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" = env ]; then
    shift
    for name in "$@"; do
        case "$name" in
            GOMODCACHE) printf '%s\n' "$FAKE_GOMODCACHE" ;;
            GOHOSTOS) printf '%s\n' linux ;;
            GOHOSTARCH) printf '%s\n' amd64 ;;
            GOVERSION) printf '%s\n' go1.26.4 ;;
            *) exit 91 ;;
        esac
    done
    exit 0
fi
[ "${FAKE_REQUIRE_LOCAL_ENV_CLEAN:-}" != 1 ] || {
    [ "${EXAMPLE_MODE+x}" != x ]
    [ "${GO_REMOTE_ENV_VALUE_EXAMPLE_MODE+x}" != x ]
}
printf 'toolchain=<%s>\n' "${GOTOOLCHAIN-unset}" >> "$GO_WRAPPER_LOG"
for argument in "$@"; do
    printf 'argument=<%s>\n' "$argument" >> "$GO_WRAPPER_LOG"
done
SH
chmod +x "$FAKEBIN/real-go"

cat > "$FAKEBIN/go-remote-test" <<'SH'
#!/bin/sh
[ "${FAKE_REMOTE_HELPER_CRASH:-}" != 1 ] || exit 9
: > "$GO_REMOTE_ERROR_FILE"
exit 1
SH
chmod +x "$FAKEBIN/go-remote-test"

printf 'module example.com/legacy\n\ngo 1.20\n' > "$TMP/modules/legacy/go.mod"
printf 'module example.com/old\n\ngo 1.22\n' > "$TMP/modules/old/go.mod"
printf 'module example.com/current\n\ngo 1.24\n' > "$TMP/modules/current/go.mod"
printf 'module example.com/preferred\n\ngo 1.24\n\ntoolchain go1.25.3\n' > "$TMP/modules/preferred/go.mod"
printf 'module example.com/bundled\n\ngo 1.26\n' > "$TMP/modules/bundled/go.mod"
printf 'module example.com/future\n\ngo 1.27.1\n' > "$TMP/modules/future/go.mod"

export FAKE_GOMODCACHE="$TMP/modcache"
mkdir -p \
    "$FAKE_GOMODCACHE/golang.org/toolchain@v0.0.1-go1.22.4.linux-amd64/bin" \
    "$FAKE_GOMODCACHE/golang.org/toolchain@v0.0.1-go1.22.12.linux-amd64/bin" \
    "$FAKE_GOMODCACHE/golang.org/toolchain@v0.0.1-go1.25.2.linux-amd64/bin" \
    "$FAKE_GOMODCACHE/golang.org/toolchain@v0.0.1-go1.25.12.linux-amd64/bin"
for cached_toolchain in "$FAKE_GOMODCACHE"/golang.org/toolchain@*; do
    : > "$cached_toolchain/bin/go"
    chmod +x "$cached_toolchain/bin/go"
done

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

assert_not_contains() {
    if grep -F -- "$2" "$1" >/dev/null; then
        fail "expected $1 not to contain: $2"
    fi
}

: > "$LOG"
(
    cd "$TMP/modules/old/sub"
    "$ROOT/bin/go" mod tidy
)
assert_contains "$LOG" 'toolchain=<go1.22.12+auto>'
assert_contains "$LOG" 'argument=<mod>'
assert_contains "$LOG" 'argument=<tidy>'

: > "$LOG"
(
    cd "$TMP/modules/legacy"
    "$ROOT/bin/go" build ./...
)
assert_contains "$LOG" 'toolchain=<go1.20+auto>'

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
assert_contains "$LOG" 'toolchain=<go1.24.0+auto>'
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
    cd "$TMP/modules/bundled"
    "$ROOT/bin/go" build ./...
)
assert_contains "$LOG" 'toolchain=<go1.26.4+auto>'

: > "$LOG"
(
    cd "$TMP/modules/future"
    "$ROOT/bin/go" vet ./...
)
assert_contains "$LOG" 'toolchain=<go1.27.1+auto>'

: > "$LOG"
(
    cd "$TMP/outside"
    "$ROOT/bin/go" -C "$TMP/modules/old" generate ./...
)
assert_contains "$LOG" 'toolchain=<go1.22.12+auto>'
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
    FAKE_REQUIRE_LOCAL_ENV_CLEAN=1 \
        "$ROOT/bin/go" \
        --no-remote \
        --remote-env 'EXAMPLE_MODE=value with spaces $HOME;*' \
        test ./...
)
assert_contains "$LOG" 'toolchain=<go1.22.12+auto>'
assert_contains "$LOG" 'argument=<test>'
assert_not_contains "$LOG" 'argument=<--remote-env>'
assert_not_contains "$LOG" 'value with spaces'

: > "$LOG"
status=0
output=$(
    cd "$TMP/modules/old"
    "$ROOT/bin/go" --remote-env '9INVALID=hidden' version 2>&1
) || status=$?
[ "$status" = 2 ] || fail "expected invalid remote environment exit 2, got $status"
printf '%s\n' "$output" | grep -F 'invalid --remote-env name' >/dev/null ||
    fail 'invalid remote environment name was accepted'
if printf '%s\n' "$output" | grep -F 'hidden' >/dev/null; then
    fail 'invalid remote environment value leaked into command output'
fi
assert_not_contains "$LOG" 'hidden'

: > "$LOG"
status=0
output=$(
    cd "$TMP/modules/old"
    PATH=/usr/bin:/bin "$ROOT/bin/go" test ./... 2>&1
) || status=$?
[ "$status" = 2 ] || fail "expected missing remote helper exit 2, got $status"
printf '%s\n' "$output" | grep -F 'DO NOT ATTEMPT to run test on local' >/dev/null ||
    fail 'missing remote helper did not print the remote execution warning'
if [ -s "$LOG" ]; then
    fail 'missing remote helper fell back to local Go'
fi

: > "$LOG"
status=0
output=$(
    cd "$TMP/modules/old"
    FAKE_REMOTE_HELPER_CRASH=1 "$ROOT/bin/go" test ./... 2>&1
) || status=$?
[ "$status" = 2 ] || fail "expected crashed remote helper exit 2, got $status"
printf '%s\n' "$output" | grep -F 'error: go-remote-test terminated without reporting an outcome' >/dev/null ||
    fail 'crashed remote helper did not print the remote execution warning'
if [ -s "$LOG" ]; then
    fail 'crashed remote helper fell back to local Go'
fi

printf 'PASS go wrapper smoke test\n'
