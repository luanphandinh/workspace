#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)

cleanup() {
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

assert_eq() {
	expected=$1
	actual=$2
	label=$3
	if [ "$expected" != "$actual" ]; then
		printf 'FAIL %s\nexpected: %s\nactual:   %s\n' "$label" "$expected" "$actual" >&2
		exit 1
	fi
	printf 'ok %s\n' "$label"
}

if command -v sqlite3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
	db="$TMP/state.sqlite"
	rollout="$TMP/rollout.jsonl"
	sqlite3 "$db" 'create table threads (rollout_path text, updated_at integer);'
	sqlite3 "$db" "insert into threads values ('$rollout', 1);"
	cat > "$rollout" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":38,"window_minutes":300,"resets_at":1700000400},"secondary":{"used_percent":29,"window_minutes":10080,"resets_at":1700000000}}}}
EOF
	touch "$rollout"
	assert_eq "codex[38% | 29%][22:20|14-11 22:13]" \
		"$(TZ=UTC HOME="$TMP/home" RATE_LIMITS_CACHE="$TMP/missing.json" CODEX_STATE_DB="$db" sh "$ROOT/bin/tmux-claude-codex-status")" \
		"codex status compact format"
else
	printf 'skip codex status compact format; sqlite3 or jq missing\n'
fi

! grep -q 'tmux-short-path' "$ROOT/tmux/.tmux.conf"
grep -q 'git rev-parse --abbrev-ref HEAD' "$ROOT/tmux/.tmux.conf"
grep -q "set -g status-left ' ~ #(" "$ROOT/tmux/.tmux.conf"
grep -q 'tmux-claude-codex-status' "$ROOT/tmux/.tmux.conf"

echo "PASS tmux status smoke tests"
