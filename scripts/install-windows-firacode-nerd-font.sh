#!/bin/sh
set -eu

if ! command -v powershell.exe >/dev/null 2>&1; then
	printf 'powershell.exe not found; Windows font install requires WSL interop\n' >&2
	exit 1
fi

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
$ErrorActionPreference = "Stop"
$zip = Join-Path $env:TEMP "FiraCode.zip"
$extractDir = Join-Path $env:TEMP "FiraCodeNerdFont"
$fontDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"

New-Item -ItemType Directory -Force -Path $extractDir, $fontDir | Out-Null
Invoke-WebRequest "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip" -OutFile $zip
Expand-Archive -Force $zip $extractDir

Get-ChildItem $extractDir -Filter "*.ttf" -Recurse | ForEach-Object {
  $target = Join-Path $fontDir $_.Name
  Copy-Item $_.FullName $target -Force
  New-ItemProperty `
    -Path "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts" `
    -Name "$($_.BaseName) (TrueType)" `
    -Value $target `
    -PropertyType String `
    -Force | Out-Null
}
'
