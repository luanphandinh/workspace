#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

test -f alacritty/alacritty.toml
grep -A2 '^\[font.italic\]$' alacritty/alacritty.toml | grep -Fx 'style = "Regular"' >/dev/null
grep -A2 '^\[font.bold_italic\]$' alacritty/alacritty.toml | grep -Fx 'style = "Bold"' >/dev/null
! grep -Eq 'style = ".*Italic' alacritty/alacritty.toml

for n in 1 2 3 4 5 6 7 8 9; do
	seq=$((30 + n))
	grep -Fx "  { key = \"$n\", mods = \"Command\", chars = \"\\u001b[$seq~\" }," alacritty/alacritty.toml >/dev/null
	grep -Fx "  { key = \"$n\", mods = \"Alt\", chars = \"\\u001b[$seq~\" }," alacritty/alacritty.toml >/dev/null
done

echo "PASS alacritty smoke test"
