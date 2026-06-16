#!/bin/sh
set -eu

version=${CSVLENS_VERSION:-0.15.1}
arch=$(uname -m)

case "$arch" in
	arm64 | aarch64)
		target_arch=aarch64
		;;
	x86_64 | amd64)
		target_arch=x86_64
		;;
	*)
		printf 'unsupported csvlens architecture: %s\n' "$arch" >&2
		exit 1
		;;
esac

if command -v csvlens >/dev/null 2>&1; then
	printf 'csvlens already installed: %s\n' "$(command -v csvlens)"
	csvlens --version | head -n 1
	exit 0
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$HOME/bin"
archive="$tmp_dir/csvlens.tar.xz"
url="https://github.com/YS-L/csvlens/releases/download/v${version}/csvlens-${target_arch}-unknown-linux-gnu.tar.xz"

curl -fsSL "$url" -o "$archive"
tar -xJf "$archive" -C "$tmp_dir"

csvlens_bin=$(find "$tmp_dir" -type f -name csvlens -perm -111 | head -n 1)
test -n "$csvlens_bin"
install -m 0755 "$csvlens_bin" "$HOME/bin/csvlens"
"$HOME/bin/csvlens" --version | head -n 1
