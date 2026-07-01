#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)

cleanup() {
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

export HOME="$TMP/home"
export PYTHONPYCACHEPREFIX="$TMP/pycache"
FAKEBIN="$TMP/fakebin"
FZF_INPUT="$TMP/fzf-input"
export FZF_INPUT
mkdir -p "$HOME" "$FAKEBIN"
export PATH="$FAKEBIN:$PATH"

cat > "$FAKEBIN/fzf" <<'SH'
#!/bin/sh
cat > "$FZF_INPUT"
if [ -n "${FZF_SELECT:-}" ]; then
	grep -F "$FZF_SELECT" "$FZF_INPUT" | head -n 1
else
	sed -n '1p' "$FZF_INPUT"
fi
SH
chmod +x "$FAKEBIN/fzf"

mkws() {
	python3 "$ROOT/bin/mkws" "$@"
}

mkwst() {
	python3 "$ROOT/bin/mkwst" "$@"
}

meta_hub() {
	python3 "$ROOT/bin/meta-hub" "$@"
}

pass() {
	printf 'ok %s\n' "$1"
}

assert_exists() {
	test -e "$1" || {
		printf 'missing expected path: %s\n' "$1" >&2
		exit 1
	}
}

assert_not_exists() {
	test ! -e "$1" || {
		printf 'unexpected path exists: %s\n' "$1" >&2
		exit 1
	}
}

assert_symlink_target() {
	test -L "$1" || {
		printf 'expected symlink: %s\n' "$1" >&2
		exit 1
	}
	python3 - "$1" "$2" <<'PY'
from pathlib import Path
import sys

link = Path(sys.argv[1])
target = Path(sys.argv[2])
if link.resolve() != target.resolve():
    print(f"expected {link} to point at {target}, got {link.resolve()}", file=sys.stderr)
    raise SystemExit(1)
PY
}

assert_git_repo() {
	git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
		printf 'expected git repo: %s\n' "$1" >&2
		exit 1
	}
	assert_exists "$1/.git"
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
		printf 'expected %s not to contain: %s\n' "$1" "$2" >&2
		printf '%s contents:\n' "$1" >&2
		cat "$1" >&2
		exit 1
	fi
}

assert_remote_branch_exists() {
	repo=$1
	branch=$2
	git -C "$repo" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 || {
		printf 'missing expected remote branch: %s\n' "$branch" >&2
		exit 1
	}
}

assert_remote_branch_not_exists() {
	repo=$1
	branch=$2
	if git -C "$repo" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
		printf 'unexpected remote branch exists: %s\n' "$branch" >&2
		exit 1
	fi
}

assert_eq() {
	if [ "$1" != "$2" ]; then
		printf 'expected [%s], got [%s]\n' "$1" "$2" >&2
		exit 1
	fi
}

expect_fail_contains() {
	out=$("$@" 2>&1) && {
		printf 'expected command to fail: %s\n' "$*" >&2
		exit 1
	}
	printf '%s\n' "$out" | grep -F "$EXPECT" >/dev/null || {
		printf 'expected failure output to contain: %s\nactual output:\n%s\n' "$EXPECT" "$out" >&2
		exit 1
	}
}

init_repo() {
	dir=$1
	mkdir -p "$dir"
	git init -q "$dir"
	git -C "$dir" config user.name "Example User"
	git -C "$dir" config user.email "user@example.com"
	git -C "$dir" checkout -q -b main
	printf 'content\n' > "$dir/README.md"
	git -C "$dir" add README.md
	git -C "$dir" commit -q -m "initial commit"
}

add_origin_remote() {
	repo=$1
	remote=$2
	git clone -q --bare "$repo" "$remote"
	git -C "$repo" remote add origin "$remote"
	git -C "$repo" push -q -u origin main
}

test_mkws() {
	root="$TMP/mkws-root"
	mkdir -p "$root"
	init_repo "$root/repo-a"
	init_repo "$root/repo-b"
	init_repo "$root/repo-c"

	mkws --help >/dev/null
	EXPECT='`mkws index` moved to `mkwst index`' expect_fail_contains mkws index
	EXPECT='`mkws setup` moved to `mkwst setup`' expect_fail_contains mkws setup
	EXPECT='`mkws sync_tech_doc` moved to `meta-hub sync_tech_doc`' expect_fail_contains mkws sync_tech_doc

	(
		cd "$root"
		EXPECT='`mkws master` was removed' expect_fail_contains mkws master
		EXPECT='`mkws rebase` was removed' expect_fail_contains mkws rebase
	)

	(
		cd "$root"
		mkws --name feature-a --branch feature/a --add repo-a repo-b >/dev/null
	)

	workspace="$root/local_workspaces/feature-a"
	assert_exists "$workspace/workspace.yml"
	assert_exists "$workspace/repo-a/.git"
	assert_exists "$workspace/repo-b/.git"
	assert_exists "$workspace/tech_doc"
	assert_git_repo "$workspace/tech_doc"
	assert_contains "$workspace/workspace.yml" "branch_name: feature/a"
	assert_eq "feature/a" "$(git -C "$workspace/repo-a" branch --show-current)"

	(
		cd "$workspace"
		mkws --add ../../repo-c --branch feature/c >/dev/null
	)
	assert_exists "$workspace/repo-c/.git"
	assert_contains "$workspace/workspace.yml" "name: repo-c"
	assert_contains "$workspace/workspace.yml" "branch_name: feature/c"
	assert_eq "feature/c" "$(git -C "$workspace/repo-c" branch --show-current)"
	assert_eq "feature/a" "$(python3 - "$workspace/workspace.yml" <<'PY'
from pathlib import Path
for line in Path(__import__("sys").argv[1]).read_text().splitlines():
    if line.startswith("branch_name:"):
        print(line.split(":", 1)[1].strip())
        break
PY
)"

	mkdir -p "$workspace/skills/shared-skill"
	cat > "$workspace/skills/shared-skill/SKILL.md" <<EOF
---
name: shared-skill
description: Shared fixture skill.
---

# Shared fixture skill
EOF
	(
		cd "$workspace"
		mkws skill-sync >/dev/null
	)
	for repo in repo-a repo-b; do
		assert_exists "$workspace/$repo/.agent/skills/shared-skill/SKILL.md"
		assert_exists "$workspace/$repo/.claude/skills/shared-skill/SKILL.md"
		assert_exists "$workspace/$repo/.cursor/skills/shared-skill/SKILL.md"
	done

	mkdir -p "$workspace/skills/repo-only-skill" "$workspace/repo-a/internal"
	cat > "$workspace/skills/repo-only-skill/SKILL.md" <<EOF
---
name: repo-only-skill
description: Repo-scoped fixture skill.
---

# Repo-scoped fixture skill
EOF
	(
		cd "$workspace/repo-a/internal"
		mkws skill-sync >/dev/null
	)
	assert_exists "$workspace/repo-a/.agent/skills/repo-only-skill/SKILL.md"
	assert_not_exists "$workspace/repo-b/.agent/skills/repo-only-skill/SKILL.md"

	(
		cd "$root"
		mkws --name design-only >/dev/null
	)
	empty_workspace="$root/local_workspaces/design-only"
	assert_exists "$empty_workspace/workspace.yml"
	assert_git_repo "$empty_workspace/tech_doc"

	(
		cd "$root"
		mkws --name feature-a --link design-doc https://example.com/design >/dev/null
		mkws open --name feature-a > "$TMP/mkws-open.out"
	)
	assert_contains "$TMP/mkws-open.out" "design-doc"
	assert_contains "$TMP/mkws-open.out" "https://example.com/design"

	(
		cd "$root"
		mkws clean local_workspaces/feature-a >/dev/null
	)
	assert_not_exists "$workspace/repo-a"
	assert_not_exists "$workspace/repo-b"
	assert_git_repo "$workspace/tech_doc"
	assert_contains "$workspace/workspace.yml" "branch_name:"
	assert_exists "$root/repo-a/.git"
	assert_exists "$root/repo-b/.git"

	sync_root="$TMP/mkws-sync-root"
	sync_source="$TMP/mkws-sync-source"
	sync_remote="$TMP/mkws-sync-remote.git"
	mkdir -p "$sync_root"
	init_repo "$sync_source"
	git clone -q --bare "$sync_source" "$sync_remote"
	git clone -q "$sync_remote" "$sync_root/repo-sync"
	git -C "$sync_root/repo-sync" config user.name "Example User"
	git -C "$sync_root/repo-sync" config user.email "user@example.com"

	(
		cd "$sync_root"
		mkws --name feature-sync --branch feature/sync --add repo-sync >/dev/null
	)
	sync_workspace="$sync_root/local_workspaces/feature-sync"
	printf 'local sync\n' > "$sync_workspace/repo-sync/sync.txt"
	git -C "$sync_workspace/repo-sync" add sync.txt
	git -C "$sync_workspace/repo-sync" commit -q -m "local sync"
	(
		cd "$sync_workspace"
		mkws sync repo-sync >/dev/null
	)
	assert_remote_branch_not_exists "$sync_root/repo-sync" "feature/sync"
	(
		cd "$sync_workspace"
		mkws sync --push repo-sync >/dev/null
	)
	assert_remote_branch_exists "$sync_root/repo-sync" "feature/sync"

	pull_seed="$TMP/mkws-pull-seed"
	pull_remote="$TMP/mkws-pull-remote.git"
	pull_updater="$TMP/mkws-pull-updater"
	pull_root="$TMP/mkws-pull-root"
	init_repo "$pull_seed"
	git clone -q --bare "$pull_seed" "$pull_remote"
	mkdir -p "$pull_root/_external"
	git clone -q "$pull_remote" "$pull_root/repo-pull"
	git clone -q "$pull_remote" "$pull_root/_external/external-pull"
	git clone -q "$pull_remote" "$pull_updater"
	git -C "$pull_updater" config user.name "Example User"
	git -C "$pull_updater" config user.email "user@example.com"
	printf 'remote update\n' > "$pull_updater/remote.txt"
	git -C "$pull_updater" add remote.txt
	git -C "$pull_updater" commit -q -m "remote update"
	git -C "$pull_updater" push -q origin main
	(
		cd "$pull_root"
		mkws pull > "$TMP/mkws-pull.out"
	)
	assert_exists "$pull_root/repo-pull/remote.txt"
	assert_exists "$pull_root/_external/external-pull/remote.txt"
	assert_contains "$TMP/mkws-pull.out" "pulling 2 repo(s) in parallel (1 regular, 1 external)"
	assert_contains "$TMP/mkws-pull.out" "_external/external-pull"
	assert_contains "$TMP/mkws-pull.out" "external: pulled 1, skipped: 0, failed: 0"

	pass "mkws"
}

test_mkwst() {
	root="$TMP/mkwst-root"
	mkdir -p "$root"
	init_repo "$root/repo-a"
	init_repo "$root/repo-b"

	(
		cd "$root"
		mkwst index >/dev/null
	)
	assert_exists "$root/workstation.yml"
	assert_contains "$root/workstation.yml" "name: \"repo-a\""
	assert_contains "$root/workstation.yml" "name: \"repo-b\""

	rm -rf "$root/repo-b"
	(
		cd "$root"
		mkwst clean >/dev/null
	)
	assert_not_contains "$root/workstation.yml" "name: \"repo-b\""

	source="$TMP/setup-source/source-repo"
	remote="$TMP/setup-source/source-repo.git"
	setup_root="$TMP/mkwst-setup-root"
	init_repo "$source"
	git clone -q --bare "$source" "$remote"
	mkdir -p "$setup_root"
	cat > "$setup_root/workstation.yml" <<EOF
version: v1
name: "setup-root"
repos:
  - name: "repo-a"
    path: "repo-a"
    remote: ""
    remote_url: "$remote"
    upstream: ""
    branch: "main"
EOF
	(
		cd "$setup_root"
		mkwst setup >/dev/null
	)
	assert_exists "$setup_root/repo-a/.git"
	assert_eq "main" "$(git -C "$setup_root/repo-a" branch --show-current)"

	pass "mkwst"
}

test_mkwsts_removed() {
	if PATH="$ROOT/bin:/usr/bin:/bin" command -v mkwsts >/dev/null 2>&1; then
		printf 'expected mkwsts to be removed from repo bin\n' >&2
		exit 1
	fi
	pass "mkwsts removed"
}

test_meta_hub() {
	root="$TMP/meta-hub-root"
	mkdir -p "$root/station-a" "$root/station-b"
	root=$(cd "$root" && pwd -P)
	init_repo "$root/station-a/repo-a"
	init_repo "$root/station-b/repo-b"
	add_origin_remote "$root/station-a/repo-a" "$TMP/repo-a.git"
	add_origin_remote "$root/station-b/repo-b" "$TMP/repo-b.git"
	git config --global user.name "Example User"
	git config --global user.email "user@example.com"

	(
		cd "$root/station-a"
		mkws --name feature-a --branch feature/a --add repo-a >/dev/null
	)
	(
		cd "$root/station-b"
		mkws --name feature-b --branch feature/b --add repo-b >/dev/null
	)
	mkdir -p "$HOME/.skills-hub" "$HOME/.cmds-hub"
	printf 'plugin-base\n' > "$HOME/.skills-hub/execute_plugins"
	printf 'cmd-base\n' > "$HOME/.cmds-hub/cmd_history"

	meta_seed="$TMP/meta-hub-seed"
	meta_remote="$TMP/metadata.git"
	init_repo "$meta_seed"
	git clone -q --bare "$meta_seed" "$meta_remote"

	meta_hub -f "$root" -r "$meta_remote" >/dev/null
	info_yml="$HOME/.meta-hub/info.yml"
	clone="$HOME/.meta-hub/metadata"
	assert_exists "$info_yml"
	assert_not_exists "$HOME/.meta-hub/registry.yml"
	assert_exists "$clone/.git"
	assert_contains "$info_yml" "version: v3"
	assert_contains "$info_yml" "path: \"$root\""
	assert_contains "$info_yml" "clone: \"$clone\""
	assert_not_contains "$info_yml" "remote:"

	mkdir -p "$TMP/outside-station"
	EXPECT='not under a registered root' expect_fail_contains meta_hub index -p "$TMP/outside-station"

	meta_hub index -p "$root/station-a" > "$TMP/meta-index-a.out"
	assert_contains "$TMP/meta-index-a.out" "=== workstation index ==="
	assert_contains "$TMP/meta-index-a.out" "repo-a"
	assert_contains "$TMP/meta-index-a.out" "=== summary ==="
	meta_hub index -p "$root/station-b" > "$TMP/meta-index-b.out"
	init_repo "$root/station-b/repo-b2"
	add_origin_remote "$root/station-b/repo-b2" "$TMP/repo-b2.git"
	meta_hub index > "$TMP/meta-index-all.out"
	assert_contains "$TMP/meta-index-all.out" "repo-b: already indexed"
	assert_contains "$TMP/meta-index-all.out" "repo-b2"
	assert_contains "$TMP/meta-index-all.out" "=== summary ==="
	assert_exists "$clone/registry.yml"
	assert_not_exists "$clone/workstations.yml"
	assert_not_exists "$root/workstations.yml"
	assert_not_exists "$root/station-a/workstation.yml"
	assert_not_exists "$root/station-b/workstation.yml"
	assert_contains "$clone/registry.yml" "station-a/workstation.yml"
	assert_contains "$clone/registry.yml" "station-b/workstation.yml"
	assert_exists "$clone/station-a/workstation.yml"
	assert_exists "$clone/station-b/workstation.yml"
	assert_exists "$clone/station-a/local_workspaces/feature-a/workspace.yml"
	assert_exists "$clone/station-b/local_workspaces/feature-b/workspace.yml"
	assert_exists "$clone/.skills-hub/execute_plugins"
	assert_exists "$clone/.cmds-hub/cmd_history"
	assert_not_exists "$clone/station-a/local_workspaces/feature-a/repo-a/README.md"
	assert_contains "$clone/station-a/workstation.yml" "name: \"repo-a\""
	assert_contains "$clone/station-b/workstation.yml" "name: \"repo-b2\""
	assert_contains "$clone/.skills-hub/execute_plugins" "plugin-base"
	assert_contains "$clone/.cmds-hub/cmd_history" "cmd-base"

	cat > "$clone/workstations.yml" <<EOF
version: v1
name: "legacy"
workstations: []
EOF
	git -C "$clone" add workstations.yml
	git -C "$clone" commit -q -m "legacy workstations"
	meta_hub index -p "$root/station-a" >/dev/null
	assert_not_exists "$clone/workstations.yml"

	project_path=$(FZF_SELECT="feature-b" meta_hub project)
	assert_eq "$root/station-b/local_workspaces/feature-b" "$project_path"
	assert_contains "$FZF_INPUT" "$root/station-a/local_workspaces/feature-a"
	assert_contains "$FZF_INPUT" "$root/station-b/local_workspaces/feature-b"
	project_path=$(FZF_SELECT="feature-b" meta_hub p)
	assert_eq "$root/station-b/local_workspaces/feature-b" "$project_path"

	mkdir -p "$root/station-c"
	init_repo "$root/station-c/repo-c"
	add_origin_remote "$root/station-c/repo-c" "$TMP/repo-c.git"
	(
		cd "$root/station-c"
		mkws --name feature-c --branch feature/c --add repo-c >/dev/null
	)
	FZF_SELECT="feature-b" meta_hub project >/dev/null
	assert_not_contains "$FZF_INPUT" "$root/station-c/local_workspaces/feature-c"
	meta_hub index -p "$root/station-c" >/dev/null
	assert_contains "$clone/registry.yml" "station-c/workstation.yml"
	project_path=$(FZF_SELECT="feature-c" meta_hub project)
	assert_eq "$root/station-c/local_workspaces/feature-c" "$project_path"

	repo_path=$(FZF_SELECT="$root/station-b/local_workspaces/feature-b/repo-b" meta_hub repo)
	assert_eq "$root/station-b/local_workspaces/feature-b/repo-b" "$repo_path"
	assert_contains "$FZF_INPUT" "$root/station-a/repo-a"
	assert_contains "$FZF_INPUT" "$root/station-b/local_workspaces/feature-b/repo-b"
	repo_path=$(FZF_SELECT="$root/station-b/local_workspaces/feature-b/repo-b" meta_hub r)
	assert_eq "$root/station-b/local_workspaces/feature-b/repo-b" "$repo_path"

	(
		cd "$TMP"
		meta_hub sync_tech_doc >/dev/null
	)
	assert_symlink_target \
		"$root/station-a/tech_doc/feature-a/tech_doc" \
		"$root/station-a/local_workspaces/feature-a/tech_doc"
	assert_symlink_target \
		"$root/station-b/tech_doc/feature-b/tech_doc" \
		"$root/station-b/local_workspaces/feature-b/tech_doc"
	rm -rf "$root/station-a/local_workspaces/feature-a/tech_doc"
	(
		cd "$TMP"
		meta_hub sync_tech_doc >/dev/null
	)
	assert_not_exists "$root/station-a/tech_doc/feature-a/tech_doc"
	assert_symlink_target \
		"$root/station-b/tech_doc/feature-b/tech_doc" \
		"$root/station-b/local_workspaces/feature-b/tech_doc"

	msg=$(git -C "$clone" log -1 --format=%s)
	case "$msg" in
		sync\ from\ *@*) ;;
		*)
			printf 'unexpected meta-hub commit message: %s\n' "$msg" >&2
			exit 1
			;;
	esac

	meta_hub push >/dev/null
	restore_home="$TMP/meta-hub-restore-home"
	restore_root="$TMP/meta-hub-restore-root"
	mkdir -p "$restore_home" "$restore_root"
	HOME="$restore_home" meta_hub -f "$restore_root" -r "$meta_remote" >/dev/null
	HOME="$restore_home" meta_hub sync >/dev/null
	assert_exists "$restore_root/station-a/repo-a/.git"
	assert_exists "$restore_root/station-b/repo-b/.git"
	assert_not_exists "$restore_root/station-a/workstation.yml"
	assert_not_exists "$restore_root/station-b/workstation.yml"
	assert_exists "$restore_root/station-a/local_workspaces/feature-a"
	assert_not_exists "$restore_root/station-a/local_workspaces/feature-a/workspace.yml"

	if meta_hub pull >"$TMP/meta-hub-pull.out" 2>&1; then
		printf 'expected meta-hub pull to be removed\n' >&2
		exit 1
	fi
	assert_contains "$TMP/meta-hub-pull.out" "pull"

	other="$TMP/meta-hub-other"
	git clone -q "$meta_remote" "$other"
	git -C "$other" config user.name "Example User"
	git -C "$other" config user.email "user@example.com"
	cat >> "$other/registry.yml" <<EOF
  - name: "station-remote"
    root: "station-remote"
    manifest: "station-remote/workstation.yml"
EOF
	git -C "$other" add registry.yml
	git -C "$other" commit -q -m "remote metadata"
	git -C "$other" push -q origin main

	cat >> "$clone/registry.yml" <<EOF
  - name: "station-local"
    root: "station-local"
    manifest: "station-local/workstation.yml"
EOF
	git -C "$clone" add registry.yml
	git -C "$clone" commit -q -m "local metadata"

	meta_hub sync >/dev/null
	assert_contains "$clone/registry.yml" "station-local/workstation.yml"
	assert_contains "$clone/registry.yml" "station-remote/workstation.yml"
	assert_not_contains "$clone/registry.yml" "<<<<<<<"

	meta_hub push >/dev/null
	git -C "$other" pull -q --ff-only
	printf 'plugin-remote\n' >> "$other/.skills-hub/execute_plugins"
	printf 'cmd-remote\n' >> "$other/.cmds-hub/cmd_history"
	git -C "$other" add .skills-hub/execute_plugins .cmds-hub/cmd_history
	git -C "$other" commit -q -m "remote extra metadata"
	git -C "$other" push -q origin main

	printf 'plugin-local\n' >> "$clone/.skills-hub/execute_plugins"
	printf 'cmd-local\n' >> "$clone/.cmds-hub/cmd_history"
	git -C "$clone" add .skills-hub/execute_plugins .cmds-hub/cmd_history
	git -C "$clone" commit -q -m "local extra metadata"

	meta_hub sync >/dev/null
	assert_contains "$clone/.skills-hub/execute_plugins" "plugin-local"
	assert_contains "$clone/.skills-hub/execute_plugins" "plugin-remote"
	assert_contains "$clone/.cmds-hub/cmd_history" "cmd-local"
	assert_contains "$clone/.cmds-hub/cmd_history" "cmd-remote"
	assert_not_contains "$clone/.skills-hub/execute_plugins" "<<<<<<<"
	assert_not_contains "$clone/.cmds-hub/cmd_history" "<<<<<<<"

	empty_root="$TMP/meta-hub-empty-root"
	mkdir -p "$empty_root/station-b"
	empty_root=$(cd "$empty_root" && pwd -P)
	init_repo "$empty_root/station-b/repo-b"
	empty_remote="$TMP/empty-metadata.git"
	git init -q --bare "$empty_remote"

	meta_hub -f "$empty_root" -r "$empty_remote" >/dev/null
	meta_hub index -p "$empty_root/station-b" >/dev/null
	git -C "$HOME/.meta-hub/empty-metadata" config push.default matching
	meta_hub push >/dev/null
	if ! git -C "$empty_remote" show-ref --verify --quiet refs/heads/main &&
		! git -C "$empty_remote" show-ref --verify --quiet refs/heads/master; then
		printf 'expected meta-hub push to create main or master in empty remote\n' >&2
		exit 1
	fi

	rm -rf "$HOME/.meta-hub" "$HOME/.meta-sync"
	old_root="$TMP/meta-hub-old-root"
	mkdir -p "$old_root/station-old"
	old_root=$(cd "$old_root" && pwd -P)
	init_repo "$old_root/station-old/repo-old"
	cat > "$old_root/station-old/workstation.yml" <<EOF
version: v1
name: "station-old"
repos:
EOF
	old_remote="$TMP/old-metadata.git"
	old_clone="$HOME/.meta-hub/old-metadata"
	mkdir -p "$HOME/.meta-hub"
	git init -q --bare "$old_remote"
	git clone -q "$old_remote" "$old_clone"
	git -C "$old_clone" config user.name "Example User"
	git -C "$old_clone" config user.email "user@example.com"
	cat > "$HOME/.meta-hub/registry.yml" <<EOF
version: v2
remotes:
  - remote: "$old_remote"
    clone: "$old_clone"
    roots:
      - path: "$old_root"
EOF
	meta_hub sync >/dev/null
	assert_exists "$HOME/.meta-hub/info.yml"
	assert_not_exists "$HOME/.meta-hub/registry.yml"
	assert_contains "$HOME/.meta-hub/info.yml" "clone: \"$old_clone\""
	assert_not_contains "$HOME/.meta-hub/info.yml" "remote:"

	rm -rf "$HOME/.meta-hub" "$HOME/.meta-sync"
	legacy_root="$TMP/meta-hub-legacy-root"
	mkdir -p "$legacy_root/station-c"
	legacy_root=$(cd "$legacy_root" && pwd -P)
	init_repo "$legacy_root/station-c/repo-c"
	cat > "$legacy_root/station-c/workstation.yml" <<EOF
version: v1
name: "station-c"
repos:
EOF
	legacy_remote="$TMP/legacy-metadata.git"
	legacy_clone="$HOME/.meta-sync/legacy-metadata"
	mkdir -p "$HOME/.meta-sync"
	git init -q --bare "$legacy_remote"
	git clone -q "$legacy_remote" "$legacy_clone"
	git -C "$legacy_clone" config user.name "Example User"
	git -C "$legacy_clone" config user.email "user@example.com"
	cat > "$HOME/.meta-sync/registry.yml" <<EOF
version: v1
entries:
  - root: "$legacy_root"
    repo: "$legacy_remote"
    clone: "$legacy_clone"
EOF
	meta_hub sync >/dev/null
	assert_exists "$HOME/.meta-hub/info.yml"
	assert_not_exists "$HOME/.meta-hub/registry.yml"
	assert_exists "$HOME/.meta-hub/legacy-metadata/.git"
	assert_contains "$HOME/.meta-hub/info.yml" "clone: \"$HOME/.meta-hub/legacy-metadata\""
	assert_not_contains "$HOME/.meta-hub/info.yml" "remote:"

	pass "meta-hub"
}

test_mkws
test_mkwst
test_mkwsts_removed
test_meta_hub

pass "all"
