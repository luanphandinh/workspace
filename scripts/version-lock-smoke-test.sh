#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lock_file="${repo_root}/version-lock.json"
tmp_dir="${TMPDIR:-/tmp}/version-lock-smoke-test.$$"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required for version-lock smoke test" >&2
    exit 1
  fi
}

need_cmd git
need_cmd make
need_cmd python3

python3 "$repo_root/scripts/version_lock.py" validate "$lock_file"

mkdir -p "$tmp_dir/bin" "$tmp_dir/site"
cat > "$tmp_dir/bin/tree-sitter" <<'SH'
#!/usr/bin/env sh
set -eu

if [ "${1:-}" != "build" ]; then
  echo "unexpected tree-sitter command: $*" >&2
  exit 1
fi

output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    shift
    output="$1"
  fi
  shift
done

test -n "$output"
lock_dir="${TREE_SITTER_SMOKE_LOCK_DIR:-}"
if [ -n "$lock_dir" ]; then
  mkdir -p "$lock_dir"
  token="$lock_dir/$$"
  : > "$token"
  count=$(find "$lock_dir" -type f | wc -l | tr -d ' ')
  max_file="${TREE_SITTER_SMOKE_MAX_FILE:-}"
  if [ -n "$max_file" ]; then
    current_max=0
    [ -f "$max_file" ] && current_max=$(cat "$max_file")
    if [ "$count" -gt "$current_max" ]; then
      printf '%s\n' "$count" > "$max_file"
    fi
  fi
  sleep 0.2
fi
printf 'parser\n' > "$output"
[ -n "${token:-}" ] && rm -f "$token"
SH
chmod +x "$tmp_dir/bin/tree-sitter"

for lang in testlang1 testlang2 testlang3 testlang4 testlang5; do
  mkdir -p "$tmp_dir/$lang/queries"
  printf '(source_file) @test\n' > "$tmp_dir/$lang/queries/highlights.scm"
  git -C "$tmp_dir/$lang" -c init.templateDir= init -q
  git -C "$tmp_dir/$lang" config user.email test@example.invalid
  git -C "$tmp_dir/$lang" config user.name test
  git -C "$tmp_dir/$lang" add queries/highlights.scm
  git -C "$tmp_dir/$lang" commit -q -m initial
done

ref1=$(git -C "$tmp_dir/testlang1" rev-parse HEAD)
ref2=$(git -C "$tmp_dir/testlang2" rev-parse HEAD)
ref3=$(git -C "$tmp_dir/testlang3" rev-parse HEAD)
ref4=$(git -C "$tmp_dir/testlang4" rev-parse HEAD)

cat > "$tmp_dir/version-lock.json" <<EOF
{
  "go": {
    "version": "1.25.9"
  },
  "tree_sitter_cli": {
    "version": "0.26.9"
  },
  "treesitter": {
    "parsers": [
      {
        "language": "testlang1",
        "repo": "$tmp_dir/testlang1",
        "lock_version": "$ref1"
      },
      {
        "language": "testlang2",
        "repo": "$tmp_dir/testlang2",
        "lock_version": "$ref2"
      },
      {
        "language": "testlang3",
        "repo": "$tmp_dir/testlang3",
        "lock_version": "$ref3"
      },
      {
        "language": "testlang4",
        "repo": "$tmp_dir/testlang4",
        "lock_version": "$ref4"
      },
      {
        "language": "testlang5",
        "repo": "$tmp_dir/testlang5"
      }
    ]
  }
}
EOF

PATH="$tmp_dir/bin:$PATH" \
VERSION_LOCK_FILE="$tmp_dir/version-lock.json" \
NVIM_NATIVE_TREESITTER_CACHE_DIR="$tmp_dir/cache" \
NVIM_NATIVE_TREESITTER_SITE_DIR="$tmp_dir/site" \
TREE_SITTER_SMOKE_LOCK_DIR="$tmp_dir/build-locks" \
TREE_SITTER_SMOKE_MAX_FILE="$tmp_dir/max-builds" \
  sh "$repo_root/scripts/install-native-treesitter-parsers.sh"

for lang in testlang1 testlang2 testlang3 testlang4 testlang5; do
  test -f "$tmp_dir/site/parser/$lang.so"
  test -f "$tmp_dir/site/queries/$lang/highlights.scm"
done

max_builds=$(cat "$tmp_dir/max-builds")
if [ "$max_builds" -lt 2 ]; then
  echo "expected parser builds to run in parallel" >&2
  exit 1
fi
if [ "$max_builds" -gt 4 ]; then
  echo "expected parser builds to be capped at 4 jobs, saw $max_builds" >&2
  exit 1
fi

mkdir -p "$tmp_dir/update-bin"
cat > "$tmp_dir/update-bin/npm" <<'SH'
#!/usr/bin/env sh
set -eu

if [ "$*" = "view tree-sitter-cli version" ]; then
  printf '9.9.9\n'
  exit 0
fi

echo "unexpected npm command: $*" >&2
exit 1
SH
chmod +x "$tmp_dir/update-bin/npm"

cat > "$tmp_dir/update-bin/git" <<'SH'
#!/usr/bin/env sh
set -eu

if [ "${1:-}" = "ls-remote" ]; then
  printf '0123456789abcdef0123456789abcdef01234567\tHEAD\n'
  exit 0
fi

echo "unexpected git command: $*" >&2
exit 1
SH
chmod +x "$tmp_dir/update-bin/git"

cp "$tmp_dir/version-lock.json" "$tmp_dir/update-lock.json"
PATH="$tmp_dir/update-bin:$PATH" python3 "$repo_root/scripts/update-version-lock.py" "$tmp_dir/update-lock.json" >/dev/null
python3 - "$tmp_dir/update-lock.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as lock_file:
    lock = json.load(lock_file)

if lock["tree_sitter_cli"]["version"] != "9.9.9":
    raise SystemExit("tree_sitter_cli version was not updated")
for parser in lock["treesitter"]["parsers"]:
    if parser["lock_version"] != "0123456789abcdef0123456789abcdef01234567":
        raise SystemExit("parser lock_version was not updated")
    if "ref" in parser:
        raise SystemExit("legacy parser ref was not removed")
PY

echo "PASS version-lock smoke test"
