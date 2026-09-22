#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

before=$(date +%s)
actual=$("$repo_root/bin/toepoch")
after=$(date +%s)
case "$actual" in
	''|*[!0-9]*)
		printf 'toepoch returned a non-integer: %s\n' "$actual" >&2
		exit 1
		;;
esac
[ "$actual" -ge "$before" ] && [ "$actual" -le "$after" ]

actual=$(TZ=UTC "$repo_root/bin/fromepoch" 0)
[ "$actual" = '1970-01-01 00:00:00 +0000' ]

if "$repo_root/bin/fromepoch" invalid >/dev/null 2>&1; then
	printf 'fromepoch accepted invalid input\n' >&2
	exit 1
fi

if "$repo_root/bin/toepoch" unexpected >/dev/null 2>&1; then
	printf 'toepoch accepted an argument\n' >&2
	exit 1
fi

printf 'epoch tools smoke test: ok\n'
