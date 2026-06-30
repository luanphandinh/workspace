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
mkdir -p "$HOME"

mkws() {
	python3 "$ROOT/bin/mkws" "$@"
}

mkwst() {
	python3 "$ROOT/bin/mkwst" "$@"
}

mkwsts() {
	python3 "$ROOT/bin/mkwsts" "$@"
}

meta_sync() {
	python3 "$ROOT/bin/meta-sync" "$@"
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

test_mkws() {
	root="$TMP/mkws-root"
	mkdir -p "$root"
	init_repo "$root/repo-a"
	init_repo "$root/repo-b"
	init_repo "$root/repo-c"

	mkws --help >/dev/null
	EXPECT='`mkws index` moved to `mkwst index`' expect_fail_contains mkws index
	EXPECT='`mkws setup` moved to `mkwst setup`' expect_fail_contains mkws setup

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

test_mkwsts() {
	root="$TMP/mkwsts-root"
	mkdir -p "$root/ws-a" "$root/ws-b" "$root/group-c/ws-c" "$root/.hidden/ws-hidden" "$root/local_workspaces/ignored"
	cat > "$root/workstation.yml" <<EOF
version: v1
name: root-ws
repos:
EOF
	cat > "$root/ws-a/workstation.yml" <<EOF
version: v1
name: ws-a
repos:
EOF
	cat > "$root/ws-b/workstation.yml" <<EOF
version: v1
name: ws-b
repos:
EOF
	cat > "$root/group-c/ws-c/workstation.yml" <<EOF
version: v1
name: ws-c
repos:
EOF
	cat > "$root/.hidden/ws-hidden/workstation.yml" <<EOF
version: v1
name: hidden
repos:
EOF
	cat > "$root/local_workspaces/ignored/workstation.yml" <<EOF
version: v1
name: ignored
repos:
EOF

	(
		cd "$root"
		mkwsts index >/dev/null
	)
	assert_exists "$root/workstations.yml"
	assert_contains "$root/workstations.yml" "root: \".\""
	assert_contains "$root/workstations.yml" "root: \"ws-a\""
	assert_contains "$root/workstations.yml" "root: \"ws-b\""
	assert_not_contains "$root/workstations.yml" "ws-c"
	assert_not_contains "$root/workstations.yml" "hidden"
	assert_not_contains "$root/workstations.yml" "ignored"

	pass "mkwsts"
}

test_meta_sync() {
	root="$TMP/meta-sync-root"
	mkdir -p "$root/station-a"
	root=$(cd "$root" && pwd -P)
	init_repo "$root/station-a/repo-a"
	git config --global user.name "Example User"
	git config --global user.email "user@example.com"

	cat > "$root/station-a/workstation.yml" <<EOF
version: v1
name: "station-a"
repos:
EOF
	(
		cd "$root/station-a"
		mkws --name feature-a --branch feature/a --add repo-a >/dev/null
	)

	meta_seed="$TMP/meta-sync-seed"
	meta_remote="$TMP/metadata.git"
	init_repo "$meta_seed"
	git clone -q --bare "$meta_seed" "$meta_remote"

	meta_sync -f "$root" -r "$meta_remote" >/dev/null
	registry="$HOME/.meta-sync/registry.yml"
	clone="$HOME/.meta-sync/metadata"
	assert_exists "$registry"
	assert_exists "$clone/.git"
	assert_contains "$registry" "root: \"$root\""
	assert_contains "$registry" "repo: \"$meta_remote\""

	meta_sync sync >/dev/null
	assert_exists "$clone/workstations.yml"
	assert_exists "$clone/station-a/workstation.yml"
	assert_exists "$clone/station-a/local_workspaces/feature-a/workspace.yml"
	assert_not_exists "$clone/station-a/local_workspaces/feature-a/repo-a/README.md"
	assert_contains "$clone/station-a/workstation.yml" "name: \"repo-a\""

	msg=$(git -C "$clone" log -1 --format=%s)
	case "$msg" in
		sync\ from\ *@*) ;;
		*)
			printf 'unexpected meta-sync commit message: %s\n' "$msg" >&2
			exit 1
			;;
	esac

	meta_sync push >/dev/null

	other="$TMP/meta-sync-other"
	git clone -q "$meta_remote" "$other"
	git -C "$other" config user.name "Example User"
	git -C "$other" config user.email "user@example.com"
	cat >> "$other/workstations.yml" <<EOF
  - name: "station-remote"
    root: "station-remote"
    manifest: "station-remote/workstation.yml"
EOF
	git -C "$other" add workstations.yml
	git -C "$other" commit -q -m "remote metadata"
	git -C "$other" push -q origin main

	cat >> "$clone/workstations.yml" <<EOF
  - name: "station-local"
    root: "station-local"
    manifest: "station-local/workstation.yml"
EOF
	git -C "$clone" add workstations.yml
	git -C "$clone" commit -q -m "local metadata"

	meta_sync pull >/dev/null
	assert_contains "$clone/workstations.yml" "station-local/workstation.yml"
	assert_contains "$clone/workstations.yml" "station-remote/workstation.yml"
	assert_not_contains "$clone/workstations.yml" "<<<<<<<"

	empty_root="$TMP/meta-sync-empty-root"
	mkdir -p "$empty_root/station-b"
	empty_root=$(cd "$empty_root" && pwd -P)
	init_repo "$empty_root/station-b/repo-b"
	cat > "$empty_root/station-b/workstation.yml" <<EOF
version: v1
name: "station-b"
repos:
EOF
	empty_remote="$TMP/empty-metadata.git"
	git init -q --bare "$empty_remote"

	meta_sync -f "$empty_root" -r "$empty_remote" >/dev/null
	meta_sync sync >/dev/null
	git -C "$HOME/.meta-sync/empty-metadata" config push.default matching
	meta_sync push >/dev/null
	if ! git -C "$empty_remote" show-ref --verify --quiet refs/heads/main &&
		! git -C "$empty_remote" show-ref --verify --quiet refs/heads/master; then
		printf 'expected meta-sync push to create main or master in empty remote\n' >&2
		exit 1
	fi

	pass "meta-sync"
}

test_mkws
test_mkwst
test_mkwsts
test_meta_sync

pass "all"
