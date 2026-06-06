#!/bin/sh
set -eu

for cmd in cmd.exe powershell.exe wslpath curl unzip; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		printf '%s not found; Windows font install requires WSL interop plus curl/unzip\n' "$cmd" >&2
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
marker="$font_dir/FiraCodeNerdFont-Regular.ttf"
tmp_dir=${TMPDIR:-/tmp}/firacode-nerd-font.$$
zip_file="$tmp_dir/FiraCode.zip"
extract_dir="$tmp_dir/extract"

cleanup() {
	rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

mkdir -p "$font_dir"

if [ ! -f "$marker" ]; then
	mkdir -p "$extract_dir"
	printf 'Downloading FiraCode Nerd Font...\n'
	curl -fL --connect-timeout 20 --max-time 300 \
		-o "$zip_file" \
		https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip
	printf 'Installing FiraCode Nerd Font files to Windows...\n'
	unzip -oq "$zip_file" '*.ttf' -d "$extract_dir"
	find "$extract_dir" -type f -name '*.ttf' -exec cp {} "$font_dir"/ \;
	if [ ! -f "$marker" ]; then
		printf 'expected font file was not installed: %s\n' "$marker" >&2
		exit 1
	fi
else
	printf 'FiraCode Nerd Font files already exist in Windows fonts folder; refreshing registry entries...\n'
fi

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
$ErrorActionPreference = "Stop"
$fontDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
Get-ChildItem $fontDir -Filter "FiraCode*.ttf" | ForEach-Object {
  New-ItemProperty `
    -Path "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts" `
    -Name "$($_.BaseName) (TrueType)" `
    -Value $_.FullName `
    -PropertyType String `
    -Force | Out-Null
}
'
