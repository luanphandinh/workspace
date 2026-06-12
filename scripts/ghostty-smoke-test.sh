#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

test -f ghostty/config.ghostty
grep -qx 'font-family = "FiraCode Nerd Font Mono"' ghostty/config.ghostty
grep -qx 'font-thicken = true' ghostty/config.ghostty
grep -qx 'font-thicken-strength = 180' ghostty/config.ghostty
grep -qx 'font-style-italic = false' ghostty/config.ghostty
grep -qx 'font-style-bold-italic = false' ghostty/config.ghostty
grep -qx 'theme = Gruvbox Dark Hard' ghostty/config.ghostty

if command -v ghostty >/dev/null 2>&1; then
	ghostty +validate-config --config-file="$repo_root/ghostty/config.ghostty"
elif [ -x /Applications/Ghostty.app/Contents/MacOS/ghostty ]; then
	/Applications/Ghostty.app/Contents/MacOS/ghostty +validate-config --config-file="$repo_root/ghostty/config.ghostty"
else
	echo "skip ghostty binary validation"
fi

linux_plan=$(make -n --no-print-directory UNAME=Linux is_wsl=0 ghostty)
printf '%s\n' "$linux_plan" | grep -q 'apt-cache show ghostty'
printf '%s\n' "$linux_plan" | grep -q 'sudo apt install -y ghostty'
printf '%s\n' "$linux_plan" | grep -q 'cp -r ./ghostty/.'

darwin_plan=$(make -n --no-print-directory UNAME=Darwin ghostty)
printf '%s\n' "$darwin_plan" | grep -q 'brew install --cask ghostty'
printf '%s\n' "$darwin_plan" | grep -q 'cp -r ./ghostty/.'

echo "PASS ghostty smoke test"
