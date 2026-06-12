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

tree_sitter_cli_version=$(python3 "$repo_root/scripts/version_lock.py" get "$lock_file" tree_sitter_cli.version)
make -n -C "$repo_root" tree-sitter-cli-install | grep "tree-sitter-cli@${tree_sitter_cli_version}" >/dev/null

mkdir -p "$tmp_dir/bin" "$tmp_dir/grammar/queries" "$tmp_dir/site"
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
printf 'parser\n' > "$output"
SH
chmod +x "$tmp_dir/bin/tree-sitter"

printf '(source_file) @test\n' > "$tmp_dir/grammar/queries/highlights.scm"
git -C "$tmp_dir/grammar" -c init.templateDir= init -q
git -C "$tmp_dir/grammar" config user.email test@example.invalid
git -C "$tmp_dir/grammar" config user.name test
git -C "$tmp_dir/grammar" add queries/highlights.scm
git -C "$tmp_dir/grammar" commit -q -m initial
grammar_ref=$(git -C "$tmp_dir/grammar" rev-parse HEAD)

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
        "language": "testlang",
        "repo": "$tmp_dir/grammar",
        "ref": "$grammar_ref"
      }
    ]
  }
}
EOF

PATH="$tmp_dir/bin:$PATH" \
VERSION_LOCK_FILE="$tmp_dir/version-lock.json" \
NVIM_NATIVE_TREESITTER_CACHE_DIR="$tmp_dir/cache" \
NVIM_NATIVE_TREESITTER_SITE_DIR="$tmp_dir/site" \
  sh "$repo_root/scripts/install-native-treesitter-parsers.sh"

test -f "$tmp_dir/site/parser/testlang.so"
test -f "$tmp_dir/site/queries/testlang/highlights.scm"

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
if lock["treesitter"]["parsers"][0]["ref"] != "0123456789abcdef0123456789abcdef01234567":
    raise SystemExit("parser ref was not updated")
PY

echo "PASS version-lock smoke test"
