#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

rm -rf ./tmp
make --no-print-directory cleanup
test ! -e ./tmp

if command -v nix >/dev/null 2>&1 && git ls-files --error-unmatch flake.nix >/dev/null 2>&1; then
	nix --extra-experimental-features 'nix-command flakes' flake check --no-build
else
	echo "skip nix flake check: nix unavailable or flake.nix not tracked"
fi

echo "PASS nix smoke test"
