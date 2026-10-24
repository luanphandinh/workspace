#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/base64-tools-smoke-test.$$
fakebin="$tmp/bin"
mkdir -p "$fakebin"
trap 'rm -rf "$tmp"' EXIT

actual=$("$repo_root/bin/base64encode" 'hello world')
[ "$actual" = 'aGVsbG8gd29ybGQ=' ]

actual=$("$repo_root/bin/base64decode" 'aGVsbG8gd29ybGQ=')
[ "$actual" = 'hello world' ]

actual=$("$repo_root/bin/base64encode" 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789')
case "$actual" in
	*'
'*)
		printf 'base64encode wrapped its output\n' >&2
		exit 1
		;;
esac

if "$repo_root/bin/base64decode" 'not-base64!' >/dev/null 2>&1; then
	printf 'base64decode accepted invalid input\n' >&2
	exit 1
fi

cat > "$fakebin/pbpaste" <<'EOF'
#!/bin/sh
printf '%s' 'clipboard value'
EOF
chmod +x "$fakebin/pbpaste"
actual=$(PATH="$fakebin:$PATH" "$repo_root/bin/base64encode")
[ "$actual" = 'Y2xpcGJvYXJkIHZhbHVl' ]

cat > "$fakebin/pbpaste" <<'EOF'
#!/bin/sh
printf '%s' 'Y2xpcGJvYXJkIHZhbHVl'
EOF
chmod +x "$fakebin/pbpaste"
actual=$(PATH="$fakebin:$PATH" "$repo_root/bin/base64decode")
[ "$actual" = 'clipboard value' ]

printf 'base64 tools smoke test: ok\n'
