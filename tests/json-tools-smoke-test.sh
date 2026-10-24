#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/json-tools-smoke-test.$$
fakebin="$tmp/bin"
mkdir -p "$fakebin"
trap 'rm -rf "$tmp"' EXIT

assert_json() {
	expected="$1"
	actual="$2"
	[ "$(printf '%s' "$expected" | jq -Sc .)" = "$(printf '%s' "$actual" | jq -Sc .)" ]
}

actual=$("$repo_root/bin/jsondecode" '{"name":"example","count":3}')
assert_json '{"name":"example","count":3}' "$actual"

actual=$("$repo_root/bin/jsondecode" '"{\"name\":\"example\",\"count\":3}"')
assert_json '{"name":"example","count":3}' "$actual"

actual=$("$repo_root/bin/jsondecode" '"plain text"')
assert_json '"plain text"' "$actual"

if "$repo_root/bin/jsondecode" 'not json' >/dev/null 2>&1; then
	printf 'jsondecode accepted invalid JSON\n' >&2
	exit 1
fi

actual=$("$repo_root/bin/jsonencode" '{"name":"example","count":3}')
assert_json '"{\"name\":\"example\",\"count\":3}"' "$actual"

encoded='"{\"name\":\"example\"}"'
actual=$("$repo_root/bin/jsonencode" "$encoded")
assert_json "$encoded" "$actual"

actual=$("$repo_root/bin/jsonencode" 'plain text')
assert_json '"plain text"' "$actual"

cat > "$fakebin/pbpaste" <<'EOF'
#!/bin/sh
printf '%s' '"{\"clipboard\":true}"'
EOF
chmod +x "$fakebin/pbpaste"
actual=$(PATH="$fakebin:$PATH" "$repo_root/bin/jsondecode")
assert_json '{"clipboard":true}' "$actual"

cat > "$fakebin/pbpaste" <<'EOF'
#!/bin/sh
printf '%s' '{"clipboard":true}'
EOF
chmod +x "$fakebin/pbpaste"
actual=$(PATH="$fakebin:$PATH" "$repo_root/bin/jsonencode")
assert_json '"{\"clipboard\":true}"' "$actual"

printf 'json tools smoke test: ok\n'
