#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/workspace-nix-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
trap 'exit 1' HUP INT TERM
test_bash=$(command -v bash)
mkdir -p "$test_dir/bin"

cat > "$test_dir/bin/uname" <<'SH'
#!/bin/sh
printf '%s\n' "$TEST_PLATFORM"
SH
cat > "$test_dir/bin/id" <<'SH'
#!/bin/sh
printf '%s\n' "$TEST_UID"
SH
cat > "$test_dir/bin/sudo" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG/sudo"
exit 0
SH
cat > "$test_dir/nix" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG/nix"
printf '%s\n' 'nix (fixture)'
SH
cat > "$test_dir/installer" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$TEST_LOG/installer"
if [ "$TEST_INSTALL_FAIL" = 1 ]; then
  exit 9
fi
cp "$TEST_FIXTURES/nix" "$TEST_BIN/nix"
mkdir -p "$HOME/.nix-profile/etc/profile.d"
printf 'export PATH="%s:$PATH"\n' "$TEST_BIN" > "$HOME/.nix-profile/etc/profile.d/nix.sh"
SH
cat > "$test_dir/bin/curl" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$TEST_LOG/curl"
if [ "$TEST_CURL_FAIL" = 1 ]; then
  exit 22
fi
test "$1" = -fL
test "$2" = --output
cp "$TEST_FIXTURES/installer" "$3"
SH
chmod +x "$test_dir/bin/"* "$test_dir/nix"

# Mock the host's Nix paths so no installed profile or store is touched.
cat > "$test_dir/run.bash" <<'BASH'
function [ {
  if builtin [ "${1:-}" = '!' ]; then
    shift
    if [ "$@"; then return 1; else return 0; fi
  fi
  case "${1:-}:${2:-}" in
    -r:/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh) return 1 ;;
    -d:/nix) builtin [ "$TEST_STORE" != missing ]; return ;;
    -w:/nix) builtin [ "$TEST_STORE" = writable ]; return ;;
  esac
  builtin [ "$@"
}
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = nix ]; then
    if [ -x "$TEST_BIN/nix" ]; then
      printf '%s\n' "$TEST_BIN/nix"
      return 0
    fi
    return 1
  fi
  builtin command "$@"
}
. "$TEST_SCRIPT"
BASH

run_case() {
  case_name=$1
  case_dir="$test_dir/$case_name"
  mkdir -p "$case_dir/home" "$case_dir/log" "$case_dir/tmp" "$case_dir/bin"
  if [ "$case_name" = existing ]; then
    cp "$test_dir/nix" "$case_dir/bin/nix"
  fi
  case_status=0
  env PATH="$case_dir/bin:$test_dir/bin:/usr/bin:/bin" HOME="$case_dir/home" \
    TMPDIR="$case_dir/tmp" TEST_BIN="$case_dir/bin" TEST_LOG="$case_dir/log" \
    TEST_FIXTURES="$test_dir" TEST_SCRIPT="$repo_root/scripts/install-nix.sh" \
    TEST_PLATFORM="$2" TEST_UID="$3" TEST_STORE="$4" \
    TEST_CURL_FAIL="${5:-0}" TEST_INSTALL_FAIL="${6:-0}" \
    "$test_bash" "$test_dir/run.bash" > "$case_dir/output" 2>&1 || case_status=$?
  if [ "$case_status" -ne 0 ]; then
    cat "$case_dir/output" >&2
  fi
  test -z "$(ls -A "$case_dir/tmp")"
}

run_case linux Linux 1000 writable
test "$case_status" -eq 0
test ! -e "$case_dir/log/sudo"
test "$(cat "$case_dir/log/installer")" = '--no-daemon --yes'
test "$(cat "$case_dir/log/nix")" = '--version'

run_case missing Linux 1000 missing
test "$case_status" -eq 1
test ! -e "$case_dir/log/curl"
test ! -e "$case_dir/log/sudo"
grep -q 'single-user Nix needs /nix' "$case_dir/output"

run_case readonly Linux 1000 readonly
test "$case_status" -eq 1
test ! -e "$case_dir/log/curl"
test ! -e "$case_dir/log/sudo"

run_case root Linux 0 writable
test "$case_status" -eq 1
test ! -e "$case_dir/log/curl"
test ! -e "$case_dir/log/sudo"

run_case existing Linux 1000 readonly
test "$case_status" -eq 0
test "$(cat "$case_dir/log/nix")" = '--version'
test ! -e "$case_dir/log/curl"
test ! -e "$case_dir/log/sudo"

run_case macos Darwin 1000 missing
test "$case_status" -eq 0
test "$(cat "$case_dir/log/installer")" = '--daemon --yes'

run_case download_failure Linux 1000 writable 1
test "$case_status" -eq 22
test ! -e "$case_dir/log/installer"
test ! -e "$case_dir/log/nix"

run_case install_failure Linux 1000 writable 0 1
test "$case_status" -eq 9
test ! -e "$case_dir/log/nix"

printf '%s\n' 'PASS Nix installer smoke test'
