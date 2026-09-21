#!/bin/sh
set -eu

if [ "$(uname)" != "Darwin" ]; then
	echo "Ueli installation is supported only on macOS" >&2
	exit 1
fi

for command in curl jq shasum ditto plutil xattr; do
	if ! command -v "$command" >/dev/null 2>&1; then
		echo "$command is required to install Ueli" >&2
		exit 1
	fi
done

release_url=https://api.github.com/repos/oliverschwendener/ueli/releases/latest
release_json=$(curl -fsSL "$release_url")
version=$(printf '%s' "$release_json" | jq -er '.tag_name | ltrimstr("v")')

case "$(uname -m)" in
	arm64)
		asset_name="Ueli-${version}-arm64-mac.zip"
		;;
	x86_64)
		asset_name="Ueli-${version}-mac.zip"
		;;
	*)
		echo "Unsupported macOS architecture: $(uname -m)" >&2
		exit 1
		;;
esac

asset=$(printf '%s' "$release_json" | jq -er --arg name "$asset_name" '.assets[] | select(.name == $name)')
download_url=$(printf '%s' "$asset" | jq -er '.browser_download_url')
expected_digest=$(printf '%s' "$asset" | jq -er '.digest | select(startswith("sha256:")) | ltrimstr("sha256:")')
destination=/Applications/ueli.app

if [ -d "$destination" ]; then
	installed_version=$(plutil -extract CFBundleShortVersionString raw -o - "$destination/Contents/Info.plist" 2>/dev/null || true)
	if [ "$installed_version" = "$version" ]; then
		xattr -dr com.apple.quarantine "$destination"
		echo "Ueli $version is already installed"
		exit 0
	fi
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ueli-install.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT INT TERM
archive="$tmp_dir/$asset_name"
unpacked="$tmp_dir/unpacked"

curl -fL --retry 3 "$download_url" -o "$archive"
actual_digest=$(shasum -a 256 "$archive" | awk '{print $1}')
if [ "$actual_digest" != "$expected_digest" ]; then
	echo "Ueli archive checksum mismatch" >&2
	exit 1
fi

mkdir -p "$unpacked"
ditto -x -k "$archive" "$unpacked"
source_app=$(find "$unpacked" -maxdepth 3 -type d -iname 'ueli.app' -print -quit)
if [ -z "$source_app" ]; then
	echo "Ueli application bundle was not found in $asset_name" >&2
	exit 1
fi

rm -rf "$destination"
ditto "$source_app" "$destination"
xattr -dr com.apple.quarantine "$destination"
echo "Installed Ueli $version at $destination"
