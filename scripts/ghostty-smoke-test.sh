#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

assert_no_font_install() {
	plan=$1
	target=$2
	if printf '%s\n' "$plan" | grep -Eq 'font-fira-code-nerd-font|FiraCode.zip|install-windows-firacode-nerd-font'; then
		printf '%s should not install fonts\n' "$target" >&2
		exit 1
	fi
}

test -f ghostty/config.ghostty
grep -qx 'font-family = "FiraCode Nerd Font Mono"' ghostty/config.ghostty
grep -qx 'font-style-italic = false' ghostty/config.ghostty
grep -qx 'font-style-bold-italic = false' ghostty/config.ghostty
grep -qx 'macos-window-shadow = false' ghostty/config.ghostty
grep -qx 'macos-icon = retro' ghostty/config.ghostty
grep -qx 'window-vsync = true' ghostty/config.ghostty
grep -qx 'theme = Gruvbox Dark Hard' ghostty/config.ghostty
grep -qx 'desktop-notifications = false' ghostty/config.ghostty
grep -qx 'progress-style = false' ghostty/config.ghostty
grep -qx 'shell-integration = none' ghostty/config.ghostty
grep -qx 'cursor-click-to-move = false' ghostty/config.ghostty
grep -qx 'link-url = false' ghostty/config.ghostty
grep -qx 'link-previews = false' ghostty/config.ghostty
for n in 1 2 3 4 5 6 7 8 9; do
	seq=$((30 + n))
	grep -qx "keybind = cmd+digit_$n=csi:${seq}~" ghostty/config.ghostty
	! grep -qx "keybind = cmd+$n=csi:${seq}~" ghostty/config.ghostty
done

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

setup_plan=$(make -n --no-print-directory setup)
printf '%s\n' "$setup_plan" | grep -Eq 'font-fira-code-nerd-font|FiraCode.zip|install-windows-firacode-nerd-font'

alacritty_config_plan=$(make -n --no-print-directory alacritty-config)
assert_no_font_install "$alacritty_config_plan" "alacritty-config"

ghostty_config_plan=$(make -n --no-print-directory ghostty-config)
assert_no_font_install "$ghostty_config_plan" "ghostty-config"

assert_no_font_install "$linux_plan" "ghostty"
assert_no_font_install "$darwin_plan" "ghostty"

echo "PASS ghostty smoke test"
