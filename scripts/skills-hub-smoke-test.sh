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

assert_contains() {
	grep -F "$2" "$1" >/dev/null || {
		printf 'expected %s to contain: %s\n' "$1" "$2" >&2
		printf '%s contents:\n' "$1" >&2
		cat "$1" >&2
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

HUB="$TMP/hub"
LOG="$TMP/run.log"
INSTALLER="$TMP/install-skill"

cat > "$INSTALLER" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$PWD" >> "$SKILLS_HUB_SMOKE_LOG"
mkdir -p ".agent/skills/$1"
printf '# %s\n' "$1" > ".agent/skills/$1/SKILL.md"
SH
chmod +x "$INSTALLER"

SKILLS_HUB_HOME="$HUB" SKILLS_HUB_SMOKE_LOG="$LOG" \
	python3 "$ROOT/bin/skills-hub" add "$INSTALLER example-skill" >/dev/null

assert_exists "$HUB/.agent/skills/example-skill/SKILL.md"
assert_exists "$HUB/execute_plugins"
assert_exists "$HUB/package.json"
assert_contains "$HUB/execute_plugins" "$INSTALLER example-skill"
assert_line_count "$HUB/execute_plugins" 1
assert_contains "$LOG" "$HUB"

rm -rf "$HUB/.agent/skills/example-skill"
SKILLS_HUB_HOME="$HUB" SKILLS_HUB_SMOKE_LOG="$LOG" \
	python3 "$ROOT/bin/skills-hub" pull >/dev/null

assert_exists "$HUB/.agent/skills/example-skill/SKILL.md"
assert_line_count "$HUB/execute_plugins" 1
assert_line_count "$LOG" 2
assert_contains "$HUB/package.json" '"private": true'

where_path=$(SKILLS_HUB_HOME="$HUB" python3 "$ROOT/bin/skills-hub" where)
if [ "$where_path" != "$HUB" ]; then
	printf 'expected skills-hub where to print %s, got %s\n' "$HUB" "$where_path" >&2
	exit 1
fi

sh -c ". '$ROOT/shell/workspace.sh'"

echo "PASS skills-hub smoke test"
