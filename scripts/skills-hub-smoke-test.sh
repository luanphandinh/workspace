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

assert_not_exists() {
	if [ -e "$1" ]; then
		printf 'unexpected path exists: %s\n' "$1" >&2
		exit 1
	fi
}

assert_symlink_target() {
	if [ ! -L "$1" ]; then
		printf 'expected symlink: %s\n' "$1" >&2
		exit 1
	fi
	target=$(readlink "$1")
	if [ "$target" != "$2" ]; then
		printf 'expected %s to link to %s, got %s\n' "$1" "$2" "$target" >&2
		exit 1
	fi
}

assert_contains() {
	grep -F "$2" "$1" >/dev/null || {
		printf 'expected %s to contain: %s\n' "$1" "$2" >&2
		printf '%s contents:\n' "$1" >&2
		cat "$1" >&2
		exit 1
	}
}

assert_not_contains() {
	if grep -F "$2" "$1" >/dev/null; then
		printf 'expected %s to not contain: %s\n' "$1" "$2" >&2
		printf '%s contents:\n' "$1" >&2
		cat "$1" >&2
		exit 1
	fi
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
HOME="$TMP/home"
LOG="$TMP/run.log"
INSTALLER="$TMP/install-skill"
PROJECT="$TMP/project"
FAKEBIN="$TMP/bin"
FZF_INPUT="$TMP/fzf-input"
LINK_ICON=""
LOCAL_ICON=""
GLOBAL_ICON=""
export HOME
mkdir -p "$HOME"

cat > "$INSTALLER" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$PWD" >> "$SKILLS_HUB_SMOKE_LOG"
mkdir -p ".agents/skills/$1"
printf '# %s\n' "$1" > ".agents/skills/$1/SKILL.md"
SH
chmod +x "$INSTALLER"

SKILLS_HUB_HOME="$HUB" SKILLS_HUB_SMOKE_LOG="$LOG" \
	python3 "$ROOT/bin/skills-hub" add "$INSTALLER example-skill" >/dev/null

assert_exists "$HUB/.agents/skills/example-skill/SKILL.md"
assert_exists "$HUB/execute_plugins"
assert_exists "$HUB/package.json"
assert_contains "$HUB/execute_plugins" "$INSTALLER example-skill"
assert_line_count "$HUB/execute_plugins" 1
assert_contains "$LOG" "$HUB"

rm -rf "$HUB/.agents/skills/example-skill"
SKILLS_HUB_HOME="$HUB" SKILLS_HUB_SMOKE_LOG="$LOG" \
	python3 "$ROOT/bin/skills-hub" pull >/dev/null

assert_exists "$HUB/.agents/skills/example-skill/SKILL.md"
assert_line_count "$HUB/execute_plugins" 1
assert_line_count "$LOG" 2
assert_contains "$HUB/package.json" '"private": true'

mkdir -p "$HUB/.claude/skills/other-skill" "$PROJECT" "$FAKEBIN"
printf '# other\n' > "$HUB/.claude/skills/other-skill/SKILL.md"
mkdir -p "$HUB/.claude/skills/available-claude-skill"
printf '# available claude\n' > "$HUB/.claude/skills/available-claude-skill/SKILL.md"
mkdir -p "$HOME/.claude/skills/global-claude-skill"
printf '# global claude\n' > "$HOME/.claude/skills/global-claude-skill/SKILL.md"
mkdir -p "$TMP/global-claude-linked-target"
printf '# linked global claude\n' > "$TMP/global-claude-linked-target/SKILL.md"
ln -s "$TMP/global-claude-linked-target" "$HOME/.claude/skills/global-linked-claude-skill"
ln -s "$TMP/missing-global-claude-target" "$HOME/.claude/skills/global-dangling-claude-skill"
mkdir -p "$HUB/.agents/skills/available-skill"
printf '# available\n' > "$HUB/.agents/skills/available-skill/SKILL.md"
mkdir -p "$HUB/.agents/skills/codex-skill"
printf '# codex\n' > "$HUB/.agents/skills/codex-skill/SKILL.md"
mkdir -p "$HUB/.agents/skills/cursor-skill"
printf '# cursor\n' > "$HUB/.agents/skills/cursor-skill/SKILL.md"
mkdir -p "$HOME/.agents/skills/global-skill"
printf '# global\n' > "$HOME/.agents/skills/global-skill/SKILL.md"
mkdir -p "$PROJECT/../.agents/skills/parent-only-skill"
printf '# parent\n' > "$PROJECT/../.agents/skills/parent-only-skill/SKILL.md"
mkdir -p "$HUB/.agents/skills/parent-only-skill"
printf '# hub parent\n' > "$HUB/.agents/skills/parent-only-skill/SKILL.md"
cat > "$FAKEBIN/fzf" <<'SH'
#!/bin/sh
set -eu
cat > "$SKILLS_HUB_FZF_INPUT"
printf '%s\n' "$SKILLS_HUB_FZF_OUTPUT"
SH
chmod +x "$FAKEBIN/fzf"

(
	cd "$PROJECT"
	PATH="$FAKEBIN:$PATH" SKILLS_HUB_HOME="$HUB" SKILLS_HUB_FZF_INPUT="$FZF_INPUT" \
		SKILLS_HUB_FZF_OUTPUT=".agents/skills/example-skill
.claude/skills/other-skill" \
		python3 "$ROOT/bin/skills-hub" pick >/dev/null
)

assert_contains "$FZF_INPUT" ".agents/skills/example-skill"
assert_contains "$FZF_INPUT" ".claude/skills/other-skill"
assert_symlink_target "$PROJECT/.agents/skills/example-skill" "$HUB/.agents/skills/example-skill"
assert_symlink_target "$PROJECT/.claude/skills/other-skill" "$HUB/.claude/skills/other-skill"
assert_exists "$PROJECT/.agents/skills/example-skill/SKILL.md"
assert_exists "$PROJECT/.claude/skills/other-skill/SKILL.md"
assert_not_exists "$PROJECT/.agent"
printf '# updated example\n' > "$HUB/.agents/skills/example-skill/SKILL.md"
assert_contains "$PROJECT/.agents/skills/example-skill/SKILL.md" "updated example"

(
	cd "$PROJECT"
	COLUMNS=80 SKILLS_HUB_HOME="$HUB" python3 "$ROOT/bin/skills-hub" list > "$TMP/list.out"
)
assert_contains "$TMP/list.out" "agent"
assert_contains "$TMP/list.out" "  active"
assert_contains "$TMP/list.out" "example-skill $LINK_ICON $LOCAL_ICON"
assert_contains "$TMP/list.out" "global-skill $GLOBAL_ICON"
assert_contains "$TMP/list.out" "  available"
assert_contains "$TMP/list.out" "available-skill"
assert_contains "$TMP/list.out" "codex-skill"
assert_contains "$TMP/list.out" "parent-only-skill"
assert_contains "$TMP/list.out" "claude"
assert_contains "$TMP/list.out" "  active"
assert_contains "$TMP/list.out" "global-claude-skill $GLOBAL_ICON"
assert_contains "$TMP/list.out" "global-dangling-claude-skill $LINK_ICON $GLOBAL_ICON"
assert_contains "$TMP/list.out" "global-linked-claude-skill $LINK_ICON $GLOBAL_ICON"
assert_contains "$TMP/list.out" "other-skill $LINK_ICON $LOCAL_ICON"
assert_contains "$TMP/list.out" "available-claude-skill"
python3 - "$TMP/list.out" <<'PY'
import sys
text = open(sys.argv[1]).read()
active = text.index("  active")
available = text.index("  available")
parent_only = text.index("parent-only-skill")
if not available < parent_only:
    raise SystemExit("parent-only-skill should be available, not active")
if active < parent_only < available:
    raise SystemExit("parent-only-skill leaked into active")
PY

(
	cd "$PROJECT"
	COLUMNS=80 SKILLS_HUB_HOME="$HUB" python3 "$ROOT/bin/skills-hub" list agent > "$TMP/list-agents.out"
)
assert_contains "$TMP/list-agents.out" "agent"
assert_contains "$TMP/list-agents.out" "  active"
assert_contains "$TMP/list-agents.out" "example-skill $LINK_ICON $LOCAL_ICON"
assert_contains "$TMP/list-agents.out" "global-skill $GLOBAL_ICON"
assert_contains "$TMP/list-agents.out" "  available"
assert_contains "$TMP/list-agents.out" "available-skill"
assert_not_contains "$TMP/list-agents.out" "other-skill"

(
	cd "$PROJECT"
	env -u NO_COLOR COLUMNS=80 FORCE_COLOR=1 SKILLS_HUB_HOME="$HUB" python3 "$ROOT/bin/skills-hub" list agent > "$TMP/list-color.out"
)
assert_contains "$TMP/list-color.out" "$(printf '\033[32m  active\033[0m')"
assert_contains "$TMP/list-color.out" "$(printf '\033[32m    example-skill %s %s' "$LINK_ICON" "$LOCAL_ICON")"

mkdir -p "$HUB/.agents/skills/third-skill" "$TMP/group-project"
printf '# third\n' > "$HUB/.agents/skills/third-skill/SKILL.md"

PATH="$FAKEBIN:$PATH" SKILLS_HUB_HOME="$HUB" SKILLS_HUB_FZF_INPUT="$FZF_INPUT" \
	SKILLS_HUB_FZF_OUTPUT=".agents/skills/example-skill
.claude/skills/other-skill" \
	python3 "$ROOT/bin/skills-hub" group create useful >/dev/null

assert_exists "$HUB/groups/useful"
assert_contains "$HUB/groups/useful" ".agents/skills/example-skill"
assert_contains "$HUB/groups/useful" ".claude/skills/other-skill"

PATH="$FAKEBIN:$PATH" SKILLS_HUB_HOME="$HUB" SKILLS_HUB_FZF_INPUT="$FZF_INPUT" \
	SKILLS_HUB_FZF_OUTPUT="+ .agents/skills/third-skill
- .claude/skills/other-skill" \
	python3 "$ROOT/bin/skills-hub" group update useful >/dev/null

assert_contains "$HUB/groups/useful" ".agents/skills/example-skill"
assert_contains "$HUB/groups/useful" ".agents/skills/third-skill"
assert_not_contains "$HUB/groups/useful" ".claude/skills/other-skill"

(
	cd "$TMP/group-project"
	PATH="$FAKEBIN:$PATH" SKILLS_HUB_HOME="$HUB" SKILLS_HUB_FZF_INPUT="$FZF_INPUT" \
		SKILLS_HUB_FZF_OUTPUT="useful" \
		python3 "$ROOT/bin/skills-hub" group pick >/dev/null
)

assert_symlink_target "$TMP/group-project/.agents/skills/example-skill" "$HUB/.agents/skills/example-skill"
assert_symlink_target "$TMP/group-project/.agents/skills/third-skill" "$HUB/.agents/skills/third-skill"

where_path=$(SKILLS_HUB_HOME="$HUB" python3 "$ROOT/bin/skills-hub" where)
if [ "$where_path" != "$HUB" ]; then
	printf 'expected skills-hub where to print %s, got %s\n' "$HUB" "$where_path" >&2
	exit 1
fi

sh -c ". '$ROOT/shell/workspace.sh'"

echo "PASS skills-hub smoke test"
