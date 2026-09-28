#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/config"
export PYTHONPYCACHEPREFIX="$TMP/pycache"
export FAKE_REMOTE_HOME="$TMP/remote-home"
export FAKE_LOG="$TMP/actions.log"
export LOCAL_ROOT="$TMP/local-root"
export REMOTE_ROOT="$FAKE_REMOTE_HOME/example-workspace"
export FAKE_LOGIN_SHELL="$TMP/fakebin/login-shell"
FAKEBIN="$TMP/fakebin"
REMOTE_BIN="$TMP/remote-bin"
export REMOTE_BIN
mkdir -p "$HOME" "$FAKE_REMOTE_HOME" "$LOCAL_ROOT/repo/sub" "$REMOTE_ROOT" "$FAKEBIN" "$REMOTE_BIN"

printf 'package example\n' > "$LOCAL_ROOT/repo/example.go"
printf 'module example.com/repository\n\ngo 1.22\n' > "$LOCAL_ROOT/repo/go.mod"
printf 'snapshot-source\n' > "$LOCAL_ROOT/repo/source.txt"
git -C "$LOCAL_ROOT/repo" init -q
git -C "$LOCAL_ROOT/repo" config user.email test@example.invalid
git -C "$LOCAL_ROOT/repo" config user.name test
git -C "$LOCAL_ROOT/repo" add .
git -C "$LOCAL_ROOT/repo" commit -qm initial
cp -a "$LOCAL_ROOT/." "$REMOTE_ROOT/"

cat > "$FAKEBIN/wsync" <<'SH'
#!/bin/sh
set -eu
printf 'wsync:%s\n' "$*" >> "$FAKE_LOG"
case "$1" in
    resolve)
        if [ "${FAKE_RESOLVE_FAIL:-}" = 1 ]; then
            printf 'fake resolve unavailable\n' >&2
            exit 3
        fi
        if [ "${FAKE_RESOLVE_FAIL:-}" = 2 ]; then
            printf 'fake configured route unavailable\n' >&2
            exit 4
        fi
        python3 - "$LOCAL_ROOT" "$REMOTE_ROOT" <<'PY'
import json
import sys

local_root, remote_root = sys.argv[1:]
print(json.dumps({
    "version": 1,
    "name": "example",
    "host": "testbox",
    "local_root": local_root,
    "resolved_remote_root": remote_root,
    "remote_path": remote_root + "/repo/sub",
}))
PY
        ;;
    push)
        [ "${FAKE_PUSH_FAIL:-}" != 1 ] || exit 33
        mkdir -p "$REMOTE_ROOT"
        rm -rf "$REMOTE_ROOT/repo"
        cp -a "$LOCAL_ROOT/repo" "$REMOTE_ROOT/"
        if [ "${FAKE_SNAPSHOT_SOURCE_MISSING:-}" = 1 ]; then
            rm -rf "$REMOTE_ROOT/repo"
        fi
        ;;
    pause|resume) ;;
    *) exit 90 ;;
esac
SH
chmod +x "$FAKEBIN/wsync"

cat > "$FAKEBIN/ssh" <<'SH'
#!/bin/sh
set -eu
while [ "${1:-}" = -o ]; do
    shift 2
done
host=$1
shift
[ "$host" = testbox ] || exit 90
[ "${GO_REMOTE_ENV_VALUE_CGO_ENABLED+x}" != x ] || exit 93
[ "${GO_REMOTE_ENV_VALUE_EXAMPLE_EMPTY+x}" != x ] || exit 93
[ "${GO_REMOTE_ENV_VALUE_EXAMPLE_MODE+x}" != x ] || exit 93
if [ "${FAKE_SSH_FAIL:-}" = 1 ]; then
    printf 'fake SSH unavailable\n' >&2
    exit 91
fi
if [ "${FAKE_RUN_SSH_FAIL:-}" = 1 ]; then
    case "$1" in
        *go-remote-test-result-*)
            printf 'fake final SSH unavailable\n' >&2
            exit 255
            ;;
    esac
fi
if [ "${FAKE_RUN_SETUP_FAIL:-}" = 1 ]; then
    case "$1" in
        *go-remote-test-result-*)
            printf 'fake remote setup failed\n' >&2
            exit 54
            ;;
    esac
fi
unset CGO_ENABLED EXAMPLE_EMPTY EXAMPLE_MODE
HOME=$FAKE_REMOTE_HOME SHELL=$FAKE_LOGIN_SHELL PATH="$REMOTE_BIN:$PATH" sh -c "$1"
SH
chmod +x "$FAKEBIN/ssh"

cat > "$FAKE_LOGIN_SHELL" <<'SH'
#!/bin/sh
set -eu
[ "$1" = -lic ]
shift
if [ "${FAKE_REMOTE_GO_UNAVAILABLE:-}" = 1 ]; then
    case "$1" in
        *go-remote-test-result-*)
            PATH=/nonexistent exec /bin/sh -c "$1"
            ;;
    esac
fi
exec /bin/sh -c "$1"
SH
chmod +x "$FAKE_LOGIN_SHELL"

cat > "$REMOTE_BIN/go" <<'SH'
#!/bin/sh
set -eu
printf 'remote-pwd:%s\n' "$PWD" >> "$FAKE_LOG"
for argument in "$@"; do
    printf 'remote-arg:<%s>\n' "$argument" >> "$FAKE_LOG"
done
if [ "${1:-}" = --no-remote ]; then
    shift
fi
if [ "${1:-}" = version ]; then
    exit 0
fi
[ "${1:-}" = test ] || exit 92
[ "$(cat ../source.txt)" = snapshot-source ]
printf 'remote-toolchain:<%s>\n' "${GOTOOLCHAIN-unset}" >> "$FAKE_LOG"
if [ "${FAKE_REQUIRE_REMOTE_ENV:-}" = 1 ]; then
    [ "${CGO_ENABLED:-}" = 0 ]
    [ "${EXAMPLE_MODE:-}" = 'value with spaces $HOME;*' ]
    [ "${EXAMPLE_EMPTY+x}" = x ]
    [ -z "$EXAMPLE_EMPTY" ]
    printf 'remote-env-overrides:ok\n' >> "$FAKE_LOG"
fi
exit "${FAKE_REMOTE_GO_STATUS:-0}"
SH
chmod +x "$REMOTE_BIN/go"

cat > "$FAKEBIN/local-go" <<'SH'
#!/bin/sh
set -eu
printf 'local-pwd:%s\n' "$PWD" >> "$FAKE_LOG"
for argument in "$@"; do
    printf 'local-arg:<%s>\n' "$argument" >> "$FAKE_LOG"
done
exit "${FAKE_LOCAL_GO_STATUS:-0}"
SH
chmod +x "$FAKEBIN/local-go"

export PATH="$FAKEBIN:$ROOT/bin:$PATH"
export LOCAL_REAL_GO="$FAKEBIN/local-go"
export LOCAL_GO_PATCHER=
export LOCAL_GO_GCFLAGS=

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

assert_text_contains() {
    printf '%s\n' "$1" | grep -F -- "$2" >/dev/null || fail "expected output to contain: $2"
}

: > "$FAKE_LOG"
status=0
output=$(
    GO_REMOTE_ENV_VALUE_EXAMPLE_MODE=hidden \
        "$ROOT/bin/go-remote-test" \
        run --remote-env-name 9INVALID "$LOCAL_ROOT/repo" -- ./... 2>&1
) || status=$?
[ "$status" = 2 ] || fail "expected helper environment validation exit 2, got $status"
assert_text_contains "$output" 'usage: go-remote-test'
if printf '%s\n' "$output" | grep -F 'hidden' >/dev/null; then
    fail 'helper environment validation leaked a value'
fi

: > "$FAKE_LOG"
output=$(
    cd "$LOCAL_ROOT/repo/sub"
    FAKE_RESOLVE_FAIL=1 "$ROOT/bin/go" test ./... 2>&1
)
assert_text_contains "$output" '[Error] go remote test: remote unavailable; using local: fake resolve unavailable'
assert_contains "$FAKE_LOG" 'local-arg:<test>'
assert_not_contains "$FAKE_LOG" 'remote-arg:<test>'

: > "$FAKE_LOG"
status=0
output=$(
    cd "$LOCAL_ROOT/repo/sub"
    FAKE_SSH_FAIL=1 "$ROOT/bin/go" test ./... 2>&1
) || status=$?
[ "$status" = 2 ] || fail "expected unavailable remote exit 2, got $status"
assert_text_contains "$output" '[Error] go remote test: If agent reading this, there are some issue with remote execution, DO NOT ATTEMPT to run test on local, instead ask user to confirm then run with --no-remote instead, error: fake SSH unavailable'
assert_not_contains "$FAKE_LOG" 'local-arg:<test>'

: > "$FAKE_LOG"
status=0
output=$(
    cd "$LOCAL_ROOT/repo/sub"
    FAKE_RESOLVE_FAIL=2 "$ROOT/bin/go" test ./... 2>&1
) || status=$?
[ "$status" = 2 ] || fail "expected unhealthy configured route exit 2, got $status"
assert_text_contains "$output" 'DO NOT ATTEMPT to run test on local, instead ask user to confirm then run with --no-remote instead, error: fake configured route unavailable'
assert_not_contains "$FAKE_LOG" 'local-arg:<test>'

: > "$FAKE_LOG"
(
    cd "$LOCAL_ROOT/repo/sub"
    "$ROOT/bin/go" --no-remote test './literal package'
)
assert_contains "$FAKE_LOG" 'local-arg:<test>'
assert_contains "$FAKE_LOG" 'local-arg:<./literal package>'
assert_not_contains "$FAKE_LOG" 'wsync:resolve'

: > "$FAKE_LOG"
output=$(
    cd "$LOCAL_ROOT/repo/sub"
    "$ROOT/bin/go" test './...' -run 'Test name' 2>&1
)
assert_text_contains "$output" "[Info] go remote test: synchronized session 'example' to testbox:$REMOTE_ROOT"
assert_contains "$FAKE_LOG" 'wsync:push example'
assert_contains "$FAKE_LOG" 'wsync:pause example'
assert_contains "$FAKE_LOG" 'wsync:resume example'
assert_contains "$FAKE_LOG" 'remote-arg:<--no-remote>'
assert_contains "$FAKE_LOG" 'remote-arg:<test>'
assert_contains "$FAKE_LOG" 'remote-arg:<-mod=readonly>'
assert_contains "$FAKE_LOG" 'remote-arg:<./...>'
assert_contains "$FAKE_LOG" 'remote-arg:<Test name>'
assert_not_contains "$FAKE_LOG" 'local-arg:<env>'
if find "$FAKE_REMOTE_HOME/.cache/wsync-go/example/jobs" -mindepth 1 -print -quit | grep . >/dev/null; then
    fail 'successful remote test left a snapshot behind'
fi

: > "$FAKE_LOG"
remote_value='value with spaces $HOME;*'
output=$(
    cd "$LOCAL_ROOT/repo/sub"
    GOTOOLCHAIN=go9.9.9 \
        FAKE_REQUIRE_REMOTE_ENV=1 \
        "$ROOT/bin/go" \
        --remote-env CGO_ENABLED=0 \
        --remote-env EXAMPLE_MODE=first \
        --remote-env "EXAMPLE_MODE=$remote_value" \
        --remote-env EXAMPLE_EMPTY= \
        test -short '-gcflags=all=-N -l' '-toolexec=/tmp/example tool' './literal package' 2>&1
)
assert_contains "$FAKE_LOG" 'remote-env-overrides:ok'
assert_contains "$FAKE_LOG" 'remote-toolchain:<unset>'
assert_contains "$FAKE_LOG" 'remote-arg:<-short>'
assert_contains "$FAKE_LOG" 'remote-arg:<-gcflags=all=-N -l>'
assert_contains "$FAKE_LOG" 'remote-arg:<-toolexec=/tmp/example tool>'
assert_contains "$FAKE_LOG" 'remote-arg:<./literal package>'
assert_not_contains "$FAKE_LOG" "$remote_value"
if printf '%s\n' "$output" | grep -F -- "$remote_value" >/dev/null; then
    fail 'remote environment value leaked into command output'
fi

: > "$FAKE_LOG"
status=0
output=$(
    cd "$LOCAL_ROOT/repo/sub"
    FAKE_REMOTE_GO_STATUS=255 "$ROOT/bin/go" test ./... 2>&1
) || status=$?
[ "$status" = 255 ] || fail "expected remote Go exit 255, got $status"
if printf '%s\n' "$output" | grep -F 'DO NOT ATTEMPT' >/dev/null; then
    fail 'remote Go failure was reported as a remote execution failure'
fi
if printf '%s\n' "$output" | grep -F 'go-remote-test-result-' >/dev/null; then
    fail 'remote result marker leaked into command output'
fi
assert_not_contains "$FAKE_LOG" 'local-arg:<test>'

: > "$FAKE_LOG"
status=0
output=$(
    cd "$LOCAL_ROOT/repo/sub"
    FAKE_RUN_SSH_FAIL=1 "$ROOT/bin/go" test ./... 2>&1
) || status=$?
[ "$status" != 0 ] || fail 'final SSH failure returned success'
assert_text_contains "$output" 'DO NOT ATTEMPT to run test on local, instead ask user to confirm then run with --no-remote instead, error: remote Go command did not report a result (SSH exit status 255); last stderr: fake final SSH unavailable'
assert_not_contains "$FAKE_LOG" 'remote-arg:<test>'
assert_not_contains "$FAKE_LOG" 'local-arg:<test>'

: > "$FAKE_LOG"
status=0
output=$(
    cd "$LOCAL_ROOT/repo/sub"
    FAKE_REMOTE_GO_UNAVAILABLE=1 "$ROOT/bin/go" test ./... 2>&1
) || status=$?
[ "$status" != 0 ] || fail 'unavailable remote Go command returned success'
assert_text_contains "$output" 'DO NOT ATTEMPT to run test on local, instead ask user to confirm then run with --no-remote instead, error: remote Go command did not report a result (SSH exit status 127); last stderr: remote go command is unavailable'
assert_not_contains "$FAKE_LOG" 'remote-arg:<test>'
assert_not_contains "$FAKE_LOG" 'local-arg:<test>'

: > "$FAKE_LOG"
status=0
output=$(
    cd "$LOCAL_ROOT/repo/sub"
    FAKE_RUN_SETUP_FAIL=1 "$ROOT/bin/go" test ./... 2>&1
) || status=$?
[ "$status" != 0 ] || fail 'remote setup failure returned success'
assert_text_contains "$output" 'DO NOT ATTEMPT to run test on local, instead ask user to confirm then run with --no-remote instead, error: remote Go command did not report a result (SSH exit status 54); last stderr: fake remote setup failed'
assert_not_contains "$FAKE_LOG" 'remote-arg:<test>'
assert_not_contains "$FAKE_LOG" 'local-arg:<test>'

: > "$FAKE_LOG"
status=0
output=$(
    cd "$LOCAL_ROOT/repo/sub"
    FAKE_PUSH_FAIL=1 "$ROOT/bin/go" test ./... 2>&1
) || status=$?
[ "$status" != 0 ] || fail 'flush failure returned success'
assert_text_contains "$output" 'DO NOT ATTEMPT to run test on local, instead ask user to confirm then run with --no-remote instead, error: wsync flush failed with exit status 33'
assert_not_contains "$FAKE_LOG" 'remote-arg:<test>'
assert_not_contains "$FAKE_LOG" 'local-arg:<test>'

: > "$FAKE_LOG"
status=0
(
    cd "$LOCAL_ROOT/repo/sub"
    FAKE_SNAPSHOT_SOURCE_MISSING=1 "$ROOT/bin/go" test ./...
) || status=$?
[ "$status" != 0 ] || fail 'snapshot failure returned success'
assert_contains "$FAKE_LOG" 'wsync:pause example'
assert_contains "$FAKE_LOG" 'wsync:resume example'
assert_not_contains "$FAKE_LOG" 'remote-arg:<test>'

printf 'PASS go remote test smoke test\n'
