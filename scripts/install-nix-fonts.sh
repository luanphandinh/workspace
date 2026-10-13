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
		font_target="$font_dest/$(basename "$font_file")"
		rm -f "$font_target"
		cp "$font_file" "$font_target"
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
$fontKey = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
$registered = Get-ItemProperty $fontKey
$registered.PSObject.Properties |
  Where-Object { $_.Name -like "FiraCodeNerdFont* (TrueType)" } |
  ForEach-Object {
    Remove-ItemProperty -Path $fontKey -Name $_.Name -ErrorAction SilentlyContinue
  }
$fonts = @{
  "FiraCodeNerdFont-Regular.ttf" = "FiraCode Nerd Font (TrueType)"
  "FiraCodeNerdFont-Bold.ttf" = "FiraCode Nerd Font Bold (TrueType)"
  "FiraCodeNerdFont-Light.ttf" = "FiraCode Nerd Font Light (TrueType)"
  "FiraCodeNerdFont-Medium.ttf" = "FiraCode Nerd Font Medium (TrueType)"
  "FiraCodeNerdFont-Retina.ttf" = "FiraCode Nerd Font Retina (TrueType)"
  "FiraCodeNerdFont-SemiBold.ttf" = "FiraCode Nerd Font SemiBold (TrueType)"
  "FiraCodeNerdFontMono-Regular.ttf" = "FiraCode Nerd Font Mono (TrueType)"
  "FiraCodeNerdFontMono-Bold.ttf" = "FiraCode Nerd Font Mono Bold (TrueType)"
  "FiraCodeNerdFontMono-Light.ttf" = "FiraCode Nerd Font Mono Light (TrueType)"
  "FiraCodeNerdFontMono-Medium.ttf" = "FiraCode Nerd Font Mono Medium (TrueType)"
  "FiraCodeNerdFontMono-Retina.ttf" = "FiraCode Nerd Font Mono Retina (TrueType)"
  "FiraCodeNerdFontMono-SemiBold.ttf" = "FiraCode Nerd Font Mono SemiBold (TrueType)"
  "FiraCodeNerdFontPropo-Regular.ttf" = "FiraCode Nerd Font Propo (TrueType)"
  "FiraCodeNerdFontPropo-Bold.ttf" = "FiraCode Nerd Font Propo Bold (TrueType)"
  "FiraCodeNerdFontPropo-Light.ttf" = "FiraCode Nerd Font Propo Light (TrueType)"
  "FiraCodeNerdFontPropo-Medium.ttf" = "FiraCode Nerd Font Propo Medium (TrueType)"
  "FiraCodeNerdFontPropo-Retina.ttf" = "FiraCode Nerd Font Propo Retina (TrueType)"
  "FiraCodeNerdFontPropo-SemiBold.ttf" = "FiraCode Nerd Font Propo SemiBold (TrueType)"
}
$fonts.GetEnumerator() | ForEach-Object {
  $fontPath = Join-Path $fontDir $_.Key
  if (!(Test-Path $fontPath)) {
    return
  }
  New-ItemProperty `
    -Path $fontKey `
    -Name $_.Value `
    -Value $fontPath `
    -PropertyType String `
    -Force | Out-Null
}
'
}

case "$(uname)" in
	Darwin)
		copy_fonts "$HOME/Library/Fonts"
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
