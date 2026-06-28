#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
DATE=$(date +%Y%m%d)

cleanup() {
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

assert_contains() {
	grep -F "$2" "$1" >/dev/null || {
		printf 'expected %s to contain: %s\n' "$1" "$2" >&2
		cat "$1" >&2
		exit 1
	}
}

assert_not_contains() {
	if grep -F "$2" "$1" >/dev/null; then
		printf 'expected %s to not contain: %s\n' "$1" "$2" >&2
		cat "$1" >&2
		exit 1
	fi
}

assert_exists() {
	test -e "$1" || {
		printf 'missing expected path: %s\n' "$1" >&2
		exit 1
	}
}

assert_not_exists() {
	if [ -e "$1" ]; then
		printf 'expected path to not exist: %s\n' "$1" >&2
		exit 1
	fi
}

base="$TMP/config.toml"
overlay="$TMP/codex.toml"

cat > "$base" <<'TOML'
model = "old-model"

[features]
js_repl = false
multi_agent = false
other_feature = true

[tui]
theme = "old-theme"
status_line_use_colors = true
TOML

cat > "$overlay" <<'TOML'
model = "workspace-model"

[features]
multi_agent = true
new_feature = true

[tui]
theme = "workspace-theme"

[new_section]
enabled = true
TOML

python3 "$ROOT/bin/merge_toml" "$base" "$overlay"
assert_exists "${base}_${DATE}_0"
assert_contains "$base" 'model = "workspace-model"'
assert_not_contains "$base" 'model = "old-model"'
assert_contains "$base" "js_repl = false"
assert_contains "$base" "other_feature = true"
assert_contains "$base" "new_feature = true"
assert_contains "$base" 'theme = "workspace-theme"'
assert_not_contains "$base" 'theme = "old-theme"'
assert_contains "$base" "status_line_use_colors = true"
assert_contains "$base" "[new_section]"
assert_contains "$base" "enabled = true"

python3 - "$base" <<'PY'
import sys
text = open(sys.argv[1]).read()
features = text.index("[features]")
multi_agent = text.index("multi_agent = true")
new_feature = text.index("new_feature = true")
js_repl = text.index("js_repl = false")
tui = text.index("[tui]")
if not features < multi_agent < new_feature < js_repl < tui:
    raise SystemExit("overlay keys were not placed first in [features] order")
PY

python3 "$ROOT/bin/merge_toml" "$base" "$overlay"
assert_not_exists "${base}_${DATE}_1"

second="$TMP/second.toml"
cat > "$second" <<'TOML'
[features]
js_repl = true
TOML
python3 "$ROOT/bin/merge_toml" "$base" "$second"
assert_exists "${base}_${DATE}_1"
assert_contains "$base" "js_repl = true"
assert_not_contains "$base" "js_repl = false"

new_base="$TMP/new-config.toml"
python3 "$ROOT/bin/merge_toml" "$new_base" "$ROOT/codex/config.toml"
assert_contains "$new_base" "[features]"
assert_contains "$new_base" "multi_agent = true"
assert_not_exists "${new_base}_${DATE}_0"

backup_file="$TMP/backup-target"
printf 'backup me\n' > "$backup_file"
backup_path=$(python3 "$ROOT/bin/backup" "$backup_file")
assert_exists "${backup_file}_${DATE}_0"
if [ "$backup_path" != "${backup_file}_${DATE}_0" ]; then
	printf 'expected backup path %s, got %s\n' "${backup_file}_${DATE}_0" "$backup_path" >&2
	exit 1
fi
same_backup_path=$(python3 "$ROOT/bin/backup" "$backup_file")
if [ "$same_backup_path" != "${backup_file}_${DATE}_0" ]; then
	printf 'expected unchanged backup path %s, got %s\n' "${backup_file}_${DATE}_0" "$same_backup_path" >&2
	exit 1
fi
assert_not_exists "${backup_file}_${DATE}_1"
printf 'backup me again\n' > "$backup_file"
python3 "$ROOT/bin/backup" "$backup_file" >/dev/null
assert_exists "${backup_file}_${DATE}_1"

echo "PASS codex config smoke test"
