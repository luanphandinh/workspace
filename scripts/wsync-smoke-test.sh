#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Keep the daemon's Unix socket path within macOS limits.
TMP=$(mktemp -d /tmp/wsync-test.XXXXXX)
TMP=$(CDPATH= cd -- "$TMP" && pwd -P)
REAL_MUTAGEN=$(command -v mutagen)
REAL_MUTAGEN_DATA="$TMP/real-mutagen-data"

cleanup() {
	MUTAGEN_DATA_DIRECTORY="$REAL_MUTAGEN_DATA" "$REAL_MUTAGEN" daemon stop >/dev/null 2>&1 || true
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/config"
export PYTHONPYCACHEPREFIX="$TMP/pycache"
export FAKE_REMOTE_HOME="$TMP/remote-home"
export MUTAGEN_LOG="$TMP/mutagen.log"
FAKEBIN="$TMP/fakebin"
mkdir -p "$HOME" "$FAKE_REMOTE_HOME" "$FAKEBIN"
export PATH="$FAKEBIN:$PATH"

cat > "$FAKEBIN/ssh" <<'SH'
#!/bin/sh
set -eu
host=$1
shift
[ "$host" = testbox ] || {
	printf 'unexpected SSH host: %s\n' "$host" >&2
	exit 90
}
HOME=$FAKE_REMOTE_HOME sh -c "$1"
SH
chmod +x "$FAKEBIN/ssh"

if [ "$(uname -s)" = Darwin ]; then
	cat > "$FAKEBIN/realpath" <<'PY'
#!/usr/bin/env python3
import os
import sys

assert sys.argv[1:3] == ["-m", "--"] and len(sys.argv) == 4
print(os.path.realpath(sys.argv[3]))
PY
	chmod +x "$FAKEBIN/realpath"
fi

cat > "$FAKEBIN/mutagen" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$MUTAGEN_LOG"
operation=$2
if [ "${FAKE_MUTAGEN_FAIL:-}" = "$operation" ]; then
	exit 42
fi
if [ "${FAKE_MUTAGEN_FAIL_ONCE:-}" = "$operation" ] && [ ! -e "$FAKE_MUTAGEN_FAIL_MARKER" ]; then
	: > "$FAKE_MUTAGEN_FAIL_MARKER"
	exit 42
fi
if [ "$1" = sync ] && [ "$operation" = list ]; then
	python3 - "$XDG_CONFIG_HOME/wsync/$3/session.json" "${FAKE_MUTAGEN_PAUSED:-false}" <<'PY'
import json
from pathlib import Path
import sys

metadata = json.loads(Path(sys.argv[1]).read_text())
paused = sys.argv[2] == "true"
print(json.dumps([{
    "name": metadata["name"],
    "paused": paused,
    "status": "watching",
    "alpha": {
        "protocol": "local",
        "path": metadata["local_root"],
        "connected": True,
        "scanned": True,
    },
    "beta": {
        "protocol": "ssh",
        "host": metadata["host"],
        "path": metadata["remote_root"],
        "connected": True,
        "scanned": True,
    },
}]))
PY
elif [ "$operation" = list ]; then
	printf 'fake project status\n'
fi
SH
chmod +x "$FAKEBIN/mutagen"

wsync() {
	python3 "$ROOT/bin/wsync" "$@"
}

fail() {
	printf 'FAIL %s\n' "$1" >&2
	exit 1
}

assert_contains() {
	grep -F -- "$2" "$1" >/dev/null || fail "expected $1 to contain: $2"
}

expect_fail_contains() {
	expected=$1
	shift
	output=$("$@" 2>&1) && fail "expected command to fail: $*"
	printf '%s\n' "$output" | grep -F -- "$expected" >/dev/null || {
		printf 'unexpected failure output:\n%s\n' "$output" >&2
		fail "expected failure to contain: $expected"
	}
}

mkdir -p "$HOME/source/.cache" "$HOME/source/.review"
printf 'source\n' > "$HOME/source/file.txt"
printf 'secret\n' > "$HOME/source/.env"
printf 'cache\n' > "$HOME/source/.cache/value"
printf 'tracked\n' > "$HOME/source/.review/config.yml"
git -C "$HOME/source" init -q
git -C "$HOME/source" -c user.name=Test -c user.email=test@example.com add file.txt .review/config.yml
git -C "$HOME/source" -c user.name=Test -c user.email=test@example.com commit -qm initial
printf 'hook\n' > "$HOME/source/.git/hooks/pre-commit"
printf 'lock\n' > "$HOME/source/.git/index.lock"

expect_fail_contains "refusing dangerous local root" wsync create unsafe "$HOME" 'testbox:~/unsafe' --yes

FAKE_MUTAGEN_FAIL=start expect_fail_contains 'mutagen project start failed' wsync create retry "$HOME/source" 'testbox:~/retry' --yes
[ ! -e "$XDG_CONFIG_HOME/wsync/retry" ] || fail "failed create left local session config"
wsync create retry "$HOME/source" 'testbox:~/retry' --yes >/dev/null
wsync remove retry >/dev/null

wsync create example "$HOME/source" 'testbox:~/mirror' --yes > "$TMP/create.out"
[ -f "$XDG_CONFIG_HOME/wsync/example/mutagen.yml" ] || fail "missing project file"
[ -f "$XDG_CONFIG_HOME/wsync/example/session.json" ] || fail "missing session metadata"
[ -f "$FAKE_REMOTE_HOME/mirror/.wsync-managed" ] || fail "missing remote marker"
[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$XDG_CONFIG_HOME/wsync/example/mutagen.yml")" = 0o600 ] || fail "project file is not private"

PROJECT="$XDG_CONFIG_HOME/wsync/example/mutagen.yml"
assert_contains "$PROJECT" 'mode: one-way-replica'
assert_contains "$PROJECT" 'mode: portable'
assert_contains "$PROJECT" 'scanMode: accelerated'
assert_contains "$PROJECT" 'vcs: true'
assert_contains "$PROJECT" 'maxEntryCount: 500000'
assert_contains "$PROJECT" 'beta: "testbox:~/mirror"'
assert_contains "$MUTAGEN_LOG" 'project start --project-file'

expect_fail_contains 'no configuration change requested; pass --include-git' wsync reconfigure example --yes
expect_fail_contains 'confirmation required; rerun interactively or pass --yes' wsync reconfigure example --include-git
wsync reconfigure example --include-git --yes > "$TMP/reconfigure.out"
assert_contains "$TMP/reconfigure.out" 'wsync session reconfigured to include Git metadata: example'
assert_contains "$PROJECT" 'vcs: false'
assert_contains "$PROJECT" '- "!.git"'
assert_contains "$PROJECT" '- "**/.git/hooks/"'
assert_contains "$PROJECT" '- "**/.git/logs/"'
assert_contains "$PROJECT" '- "**/.git/**/*.lock"'
assert_contains "$PROJECT" '- "!/.review/"'
python3 - "$XDG_CONFIG_HOME/wsync/example/session.json" <<'PY'
import json
from pathlib import Path
import sys

metadata = json.loads(Path(sys.argv[1]).read_text())
assert metadata["include_git"] is True, metadata
PY
tail -n 3 "$MUTAGEN_LOG" > "$TMP/reconfigure-mutagen.log"
assert_contains "$TMP/reconfigure-mutagen.log" 'project flush --project-file'
assert_contains "$TMP/reconfigure-mutagen.log" 'project terminate --project-file'
assert_contains "$TMP/reconfigure-mutagen.log" 'project start --project-file'
before_idempotent=$(grep -c 'project start --project-file' "$MUTAGEN_LOG")
wsync reconfigure example --include-git --yes > "$TMP/reconfigure-idempotent.out"
after_idempotent=$(grep -c 'project start --project-file' "$MUTAGEN_LOG")
[ "$before_idempotent" = "$after_idempotent" ] || fail "idempotent reconfigure restarted Mutagen"
assert_contains "$TMP/reconfigure-idempotent.out" 'wsync session already includes current Git metadata: example'

mkdir -p "$HOME/pointer-source/.git/worktrees/review" "$HOME/pointer-source/worktree"
printf 'gitdir: %s\n' "$HOME/pointer-source/.git/worktrees/review" > "$HOME/pointer-source/worktree/.git"
wsync create pointer "$HOME/pointer-source" 'testbox:~/pointer-mirror' --yes >/dev/null
expect_fail_contains 'absolute Git worktree pointers require identical local and remote root paths' \
	wsync reconfigure pointer --include-git --yes
assert_contains "$XDG_CONFIG_HOME/wsync/pointer/mutagen.yml" 'vcs: true'
wsync remove pointer >/dev/null

mkdir -p "$HOME/rollback-source/.git"
printf 'index\n' > "$HOME/rollback-source/.git/index"
wsync create rollback "$HOME/rollback-source" 'testbox:~/rollback-mirror' --yes >/dev/null
cp "$XDG_CONFIG_HOME/wsync/rollback/mutagen.yml" "$TMP/rollback-project.before"
FAKE_MUTAGEN_FAIL_ONCE=start FAKE_MUTAGEN_FAIL_MARKER="$TMP/reconfigure-start-failed" \
	expect_fail_contains 'mutagen project start failed' wsync reconfigure rollback --include-git --yes
cmp "$TMP/rollback-project.before" "$XDG_CONFIG_HOME/wsync/rollback/mutagen.yml" >/dev/null \
	|| fail "failed reconfigure did not restore the project file"
python3 - "$XDG_CONFIG_HOME/wsync/rollback/session.json" <<'PY'
import json
from pathlib import Path
import sys

metadata = json.loads(Path(sys.argv[1]).read_text())
assert metadata.get("include_git") is not True, metadata
PY
wsync remove rollback >/dev/null

mkdir -p "$HOME/source/pkg" "$HOME/source/.hidden"
ROUTE=$(wsync resolve --path "$HOME/source/pkg" --json)
python3 - "$ROUTE" "$FAKE_REMOTE_HOME/mirror/pkg" <<'PY'
import json
import sys

route = json.loads(sys.argv[1])
assert route["name"] == "example", route
assert route["relative_path"] == "pkg", route
assert route["remote_path"] == sys.argv[2], route
PY
expect_fail_contains 'ignored by the wsync dot-entry rule' wsync resolve --path "$HOME/source/.hidden" --json
FAKE_MUTAGEN_PAUSED=true expect_fail_contains 'Mutagen session is not ready' wsync resolve --path "$HOME/source/pkg" --json

printf 'nested\n' > "$HOME/source/pkg/nested.txt"
wsync create nested "$HOME/source/pkg" 'testbox:~/nested-mirror' --yes >/dev/null
NESTED_ROUTE=$(wsync resolve --path "$HOME/source/pkg" --json)
python3 - "$NESTED_ROUTE" <<'PY'
import json
import sys

route = json.loads(sys.argv[1])
assert route["name"] == "nested", route
assert route["relative_path"] == ".", route
PY
wsync remove nested >/dev/null

REAL_PROJECT="$TMP/real-mutagen.yml"
REAL_BETA="$TMP/real-beta"
mkdir -p "$REAL_BETA"
sed "s#beta: \"testbox:~/mirror\"#beta: \"$REAL_BETA\"#" "$PROJECT" > "$REAL_PROJECT"
MUTAGEN_DATA_DIRECTORY="$REAL_MUTAGEN_DATA" "$REAL_MUTAGEN" project start --project-file "$REAL_PROJECT" --no-global-configuration >/dev/null
MUTAGEN_DATA_DIRECTORY="$REAL_MUTAGEN_DATA" "$REAL_MUTAGEN" project flush --project-file "$REAL_PROJECT" >/dev/null
[ -f "$REAL_BETA/file.txt" ] || fail "visible file was not synchronized"
[ ! -e "$REAL_BETA/.env" ] || fail ".env was synchronized"
[ ! -e "$REAL_BETA/.cache" ] || fail "dot-directory was synchronized"
[ -f "$REAL_BETA/.review/config.yml" ] || fail "tracked dot-directory was not synchronized"
[ -f "$REAL_BETA/.git/index" ] || fail "Git index was not synchronized"
[ -n "$(find "$REAL_BETA/.git/objects" -type f -print -quit)" ] || fail "Git objects were not synchronized"
[ ! -e "$REAL_BETA/.git/hooks" ] || fail "Git hooks were synchronized"
[ ! -e "$REAL_BETA/.git/logs" ] || fail "Git reflogs were synchronized"
[ ! -e "$REAL_BETA/.git/index.lock" ] || fail "Git lock file was synchronized"
MUTAGEN_DATA_DIRECTORY="$REAL_MUTAGEN_DATA" "$REAL_MUTAGEN" project terminate --project-file "$REAL_PROJECT" >/dev/null
MUTAGEN_DATA_DIRECTORY="$REAL_MUTAGEN_DATA" "$REAL_MUTAGEN" daemon stop >/dev/null

wsync push example
assert_contains "$MUTAGEN_LOG" 'project flush --project-file'

FAKE_MUTAGEN_FAIL=flush expect_fail_contains 'mutagen project flush failed' wsync push example

printf 'wrong-marker\n' > "$FAKE_REMOTE_HOME/mirror/.wsync-managed"
expect_fail_contains 'remote management marker does not match' wsync push example
python3 - "$XDG_CONFIG_HOME/wsync/example/session.json" "$FAKE_REMOTE_HOME/mirror/.wsync-managed" <<'PY'
import json
from pathlib import Path
import sys

metadata = json.loads(Path(sys.argv[1]).read_text())
Path(sys.argv[2]).write_text(metadata["marker"] + "\n")
PY

mkdir -p "$FAKE_REMOTE_HOME/occupied"
printf 'keep\n' > "$FAKE_REMOTE_HOME/occupied/existing.txt"
expect_fail_contains 'remote target is non-empty and unmanaged' wsync create occupied "$HOME/source" 'testbox:~/occupied' --yes
[ ! -e "$XDG_CONFIG_HOME/wsync/occupied" ] || fail "unsafe session config was written"
[ -f "$FAKE_REMOTE_HOME/occupied/existing.txt" ] || fail "remote preflight modified existing content"

wsync pause example
wsync status example > "$TMP/status.out"
assert_contains "$TMP/status.out" 'fake project status'
wsync resume example
printf 'remote content\n' > "$FAKE_REMOTE_HOME/mirror/remote.txt"
wsync remove example
[ ! -e "$XDG_CONFIG_HOME/wsync/example" ] || fail "session config was not removed"
[ -f "$FAKE_REMOTE_HOME/mirror/remote.txt" ] || fail "remove deleted remote content"
[ -f "$FAKE_REMOTE_HOME/mirror/.wsync-managed" ] || fail "remove deleted remote marker"
assert_contains "$MUTAGEN_LOG" 'project terminate --project-file'

wsync status > "$TMP/empty-status.out"
assert_contains "$TMP/empty-status.out" 'No wsync sessions.'

printf 'PASS wsync smoke test\n'
