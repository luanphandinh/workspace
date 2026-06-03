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

	mkws --help >/dev/null
	EXPECT='`mkws index` moved to `mkwst index`' expect_fail_contains mkws index
	EXPECT='`mkws setup` moved to `mkwst setup`' expect_fail_contains mkws setup

	(
		cd "$root"
		mkws --name feature-a --branch feature/a --add repo-a repo-b >/dev/null
	)

	workspace="$root/local_workspaces/feature-a"
	assert_exists "$workspace/workspace.yml"
	assert_exists "$workspace/repo-a/.git"
	assert_exists "$workspace/repo-b/.git"
	assert_contains "$workspace/workspace.yml" "branch_name: feature/a"
	assert_eq "feature/a" "$(git -C "$workspace/repo-a" branch --show-current)"

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
	assert_contains "$workspace/workspace.yml" "branch_name:"
	assert_exists "$root/repo-a/.git"
	assert_exists "$root/repo-b/.git"

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

test_mkws
test_mkwst
test_mkwsts

pass "all"
