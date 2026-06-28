#!/bin/sh
set -eu

tmp_file=${TMPDIR:-/tmp}/workspace-nix-fonts.$$
trap 'rm -f "$tmp_file" "$tmp_file.sorted"' EXIT INT TERM
: > "$tmp_file"

for dir in "$HOME/.nix-profile/share/fonts" "/etc/profiles/per-user/${USER:-}/share/fonts" /run/current-system/sw/share/fonts; do
	[ -d "$dir" ] || continue
	find -L "$dir" -type f \( -iname 'FiraCodeNerdFont*.ttf' -o -iname 'FiraCodeNerdFont*.otf' \) >> "$tmp_file"
done

if [ ! -s "$tmp_file" ]; then
	echo "Nix profile FiraCode Nerd Font files not found; run make setup-deps first" >&2
	exit 1
fi

sort -u "$tmp_file" > "$tmp_file.sorted"
mv "$tmp_file.sorted" "$tmp_file"

link_fonts() {
	font_dest=$1
	mkdir -p "$font_dest"
	while IFS= read -r font_file; do
		ln -sf "$font_file" "$font_dest/$(basename "$font_file")"
	done < "$tmp_file"
}

copy_fonts() {
	font_dest=$1
	mkdir -p "$font_dest"
	while IFS= read -r font_file; do
		cp -f "$font_file" "$font_dest/"
	done < "$tmp_file"
}

refresh_fontconfig() {
	font_dest=$1
	if command -v fc-cache >/dev/null 2>&1; then
		fc-cache -f "$font_dest"
	fi
}

is_wsl() {
	test -r /proc/sys/kernel/osrelease && grep -qi microsoft /proc/sys/kernel/osrelease
}

install_windows_fonts_from_wsl() {
	for cmd in cmd.exe powershell.exe wslpath; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			printf '%s not found; Windows font registration requires WSL interop\n' "$cmd" >&2
			exit 1
		fi
	done

	windows_local_appdata=$(cmd.exe /C echo %LOCALAPPDATA% 2>/dev/null | tr -d '\r')
	if [ -z "$windows_local_appdata" ]; then
		printf 'failed to resolve Windows %%LOCALAPPDATA%%\n' >&2
		exit 1
	fi

	windows_font_dir="$windows_local_appdata\\Microsoft\\Windows\\Fonts"
	font_dir=$(wslpath -u "$windows_font_dir")
	copy_fonts "$font_dir"

	powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
$ErrorActionPreference = "Stop"
$fontDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
Get-ChildItem $fontDir -Filter "FiraCodeNerdFont*.ttf" | ForEach-Object {
  New-ItemProperty `
    -Path "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts" `
    -Name "$($_.BaseName) (TrueType)" `
    -Value $_.FullName `
    -PropertyType String `
    -Force | Out-Null
}
'
}

case "$(uname)" in
	Darwin)
		link_fonts "$HOME/Library/Fonts"
		;;
	*)
		linux_font_dir="$HOME/.local/share/fonts"
		link_fonts "$linux_font_dir"
		refresh_fontconfig "$linux_font_dir"
		if is_wsl; then
			install_windows_fonts_from_wsl
		fi
		;;
esac
