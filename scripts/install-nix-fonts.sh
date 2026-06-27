#!/bin/sh
set -eu

font_source=
for dir in "$HOME/.nix-profile/share/fonts" /run/current-system/sw/share/fonts; do
	if [ -d "$dir" ]; then
		font_source=$dir
		break
	fi
done

if [ -z "$font_source" ]; then
	echo "Nix profile font directory not found" >&2
	exit 1
fi

case "$(uname)" in
	Darwin)
		font_dest="$HOME/Library/Fonts"
		;;
	*)
		font_dest="$HOME/.local/share/fonts"
		;;
esac

mkdir -p "$font_dest"
find "$font_source" -type f \( -iname '*FiraCode*Nerd*Font*.ttf' -o -iname '*FiraCode*Nerd*Font*.otf' \) -exec cp -f {} "$font_dest/" \;

if command -v fc-cache >/dev/null 2>&1; then
	fc-cache -f "$font_dest"
fi
