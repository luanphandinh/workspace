#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

old_use_nix=$(printf 'USE_%s' NIX)
old_csvlens_installer=$(printf 'install-%s' csvlens)

grep -q 'csvlens' flake.nix

default_setup_plan=$(make -n --no-print-directory setup)
printf '%s\n' "$default_setup_plan" | grep -q 'nix .*profile add --no-update-lock-file "path:.*#workspace-deps"'
! printf '%s\n' "$default_setup_plan" | grep -q "$old_use_nix"

runtime_setup_plan=$(make -n --no-print-directory setup-runtime)
! printf '%s\n' "$runtime_setup_plan" | grep -q "$old_csvlens_installer.sh"
! printf '%s\n' "$runtime_setup_plan" | grep -q 'csvlens --version'

test ! -e "scripts/$old_csvlens_installer.sh"

if command -v csvlens >/dev/null 2>&1; then
	csvlens --version | grep -qi '^csvlens'
else
	echo "skip csvlens binary validation"
fi

echo "PASS csvlens smoke test"
