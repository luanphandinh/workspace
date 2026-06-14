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

test -f kitty/kitty.conf
test -f kitty/kitty.app.png
test -f kitty/LICENSE.kitty-icon
old_terminal_name=$(printf 'ghost%s' 'ty')
test ! -e "$old_terminal_name"
if grep -R -i "$old_terminal_name" Makefile AGENTS.md CLAUDE.md scripts >/dev/null 2>&1; then
	printf 'found stale %s setup reference\n' "$old_terminal_name" >&2
	exit 1
fi
file kitty/kitty.app.png | grep -q 'PNG image data'
grep -q 'MIT License' kitty/LICENSE.kitty-icon
grep -qx 'font_family FiraCode Nerd Font Mono' kitty/kitty.conf
grep -qx 'font_size 12.0' kitty/kitty.conf
grep -qx 'italic_font FiraCode Nerd Font Mono' kitty/kitty.conf
grep -qx 'bold_italic_font FiraCode Nerd Font Mono' kitty/kitty.conf
grep -qx 'scrollback_lines 100' kitty/kitty.conf
grep -qx 'enabled_layouts stack' kitty/kitty.conf
grep -qx 'window_border_width 0' kitty/kitty.conf
grep -qx 'include current-theme.conf' kitty/kitty.conf
! grep -Eq '^(background|foreground|selection_background|selection_foreground|cursor|cursor_text_color|color[0-9]+)[[:space:]]' kitty/kitty.conf
grep -qx 'placement_strategy top-left' kitty/kitty.conf
grep -qx 'resize_in_steps yes' kitty/kitty.conf
grep -qx 'hide_window_decorations titlebar-and-corners' kitty/kitty.conf
grep -qx 'macos_titlebar_color background' kitty/kitty.conf
grep -qx 'macos_show_window_title_in none' kitty/kitty.conf
grep -qx 'shell_integration disabled' kitty/kitty.conf
grep -qx 'enable_audio_bell no' kitty/kitty.conf
grep -qx 'confirm_os_window_close 0' kitty/kitty.conf
grep -qx 'sync_to_monitor yes' kitty/kitty.conf
grep -qx 'cursor_trail 4' kitty/kitty.conf
grep -qx 'cursor_trail_decay 0.08 0.25' kitty/kitty.conf
grep -qx 'cursor_trail_start_threshold 3' kitty/kitty.conf
grep -qx 'cursor_trail_color none' kitty/kitty.conf
grep -qx 'map cmd+w discard_event' kitty/kitty.conf
grep -qx 'map cmd+opt+up send_text all \\e\[25~' kitty/kitty.conf
grep -qx 'map cmd+opt+down send_text all \\e\[26~' kitty/kitty.conf
grep -qx 'map ctrl+shift+up send_text all \\e\[25~' kitty/kitty.conf
grep -qx 'map ctrl+shift+down send_text all \\e\[26~' kitty/kitty.conf
grep -qx 'map ctrl+shift+k send_text all \\e\[25~' kitty/kitty.conf
grep -qx 'map ctrl+shift+j send_text all \\e\[26~' kitty/kitty.conf
grep -qx 'map cmd+opt+left send_text all \\e\[28~' kitty/kitty.conf
grep -qx 'map cmd+opt+right send_text all \\e\[29~' kitty/kitty.conf
grep -qx 'map ctrl+shift+left send_text all \\e\[28~' kitty/kitty.conf
grep -qx 'map ctrl+shift+right send_text all \\e\[29~' kitty/kitty.conf
grep -qx 'map ctrl+shift+h send_text all \\e\[28~' kitty/kitty.conf
grep -qx 'map ctrl+shift+l send_text all \\e\[29~' kitty/kitty.conf
for n in 1 2 3 4 5 6 7 8 9; do
	seq=$((30 + n))
	grep -qx "map cmd+$n send_text all \\\\e\\[$seq~" kitty/kitty.conf
	grep -qx "map alt+$n send_text all \\\\e\\[$seq~" kitty/kitty.conf
done

if command -v kitty >/dev/null 2>&1; then
	:
elif [ -x /Applications/kitty.app/Contents/MacOS/kitty ]; then
	:
else
	echo "skip kitty binary validation"
fi

linux_plan=$(make -n --no-print-directory UNAME=Linux is_wsl=0 kitty)
printf '%s\n' "$linux_plan" | grep -q 'https://sw.kovidgoyal.net/kitty/installer.sh'
printf '%s\n' "$linux_plan" | grep -q 'ln -sf "$HOME/.local/kitty.app/bin/kitty"'
printf '%s\n' "$linux_plan" | grep -q 'cp -r ./kitty/.'

darwin_plan=$(make -n --no-print-directory UNAME=Darwin kitty)
printf '%s\n' "$darwin_plan" | grep -q 'brew install --cask kitty'
printf '%s\n' "$darwin_plan" | grep -q 'cp -r ./kitty/.'

setup_plan=$(make -n --no-print-directory setup)
printf '%s\n' "$setup_plan" | grep -q 'cp -r ./kitty/.'
printf '%s\n' "$setup_plan" | grep -Eq 'font-fira-code-nerd-font|FiraCode.zip|install-windows-firacode-nerd-font'

kitty_config_plan=$(make -n --no-print-directory kitty-config)
printf '%s\n' "$kitty_config_plan" | grep -q "kitten themes --dump-theme 'Gruvbox Dark'"
printf '%s\n' "$kitty_config_plan" | grep -q 'current-theme.conf'
assert_no_font_install "$kitty_config_plan" "kitty-config"

assert_no_font_install "$linux_plan" "kitty"
assert_no_font_install "$darwin_plan" "kitty"

echo "PASS kitty smoke test"
