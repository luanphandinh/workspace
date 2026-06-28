#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

old_use_nix=$(printf 'USE_%s' NIX)
old_setup_legacy=$(printf 'setup-%s' legacy)
old_apt_install=$(printf 'apt %s' install)
old_brew_install=$(printf 'brew %s' install)
old_snap_installer=$(printf 'install-linux-%s' snaps)
old_csvlens_installer=$(printf 'install-%s' csvlens)
old_setup_nix=$(printf 'setup-%s' nix)
old_nix_deps=$(printf 'nix-%s' deps)
legacy_setup_pattern="$old_use_nix|$old_setup_legacy|$old_apt_install|$old_brew_install|$old_snap_installer|$old_csvlens_installer"
redundant_target_pattern="^($old_setup_nix|$old_nix_deps|go|nvim-install|tmux-install|alacritty-install|kitty-install|csvlens-install|go-install|gopls-install):"

test -f flake.nix
test -f flake.lock
test -f .github/workflows/tests.yaml
test -f .github/workflows/workspace.yaml
test -f scripts/install-nix.sh
test -f scripts/install-nix-fonts.sh
test -f scripts/nix-profile.sh
grep -q 'nixos-unstable' flake.nix
grep -q 'buildEnv' flake.nix
grep -q 'workspace-deps' flake.nix
grep -q 'x86_64-darwin' flake.nix
grep -q 'x86DarwinPkgs.go_1_25' flake.nix
grep -q 'devShells' flake.nix
grep -q 'https://nixos.org/nix/install' scripts/install-nix.sh
grep -q -- '--daemon --yes' scripts/install-nix.sh
grep -q 'interactive sudo' scripts/install-nix.sh
grep -q 'FiraCode' scripts/install-nix-fonts.sh
grep -q 'nix-daemon.sh' scripts/nix-profile.sh
grep -q 'cachix/install-nix-action@v31' .github/workflows/tests.yaml
grep -q 'cachix/install-nix-action@v31' .github/workflows/workspace.yaml
grep -q 'make setup-deps' .github/workflows/tests.yaml
grep -q 'make setup-deps' .github/workflows/workspace.yaml
grep -q 'make setup-runtime' .github/workflows/workspace.yaml
! grep -q 'make setup$' .github/workflows/workspace.yaml
! grep -Eq "$old_apt_install|$old_brew_install" .github/workflows/tests.yaml .github/workflows/workspace.yaml

for package in zsh zoxide fzf fd ripgrep git git-lfs tmux neovim nodejs python3 go gopls tree-sitter yazi newsboat csvlens alacritty kitty nerd-fonts.fira-code; do
	grep -q "$package" flake.nix
done

setup_plan=$(make -n --no-print-directory setup)
printf '%s\n' "$setup_plan" | grep -q 'sh ./scripts/install-nix.sh'
printf '%s\n' "$setup_plan" | grep -q 'test -f flake.lock'
printf '%s\n' "$setup_plan" | grep -q 'nix .*profile list'
printf '%s\n' "$setup_plan" | grep -q 'nix .*profile upgrade --no-update-lock-file workspace-deps'
printf '%s\n' "$setup_plan" | grep -q 'nix .*profile add --no-update-lock-file "path:.*#workspace-deps"'
! printf '%s\n' "$setup_plan" | grep -q 'profile remove workspace-deps'
! printf '%s\n' "$setup_plan" | grep -q 'flake update'
printf '%s\n' "$setup_plan" | grep -q 'make setup-runtime'
! printf '%s\n' "$setup_plan" | grep -q "$old_use_nix"

setup_deps_plan=$(make -n --no-print-directory setup-deps)
printf '%s\n' "$setup_deps_plan" | grep -q 'test -f flake.lock'
printf '%s\n' "$setup_deps_plan" | grep -q 'nix .*profile list'
printf '%s\n' "$setup_deps_plan" | grep -q 'nix .*profile upgrade --no-update-lock-file workspace-deps'
printf '%s\n' "$setup_deps_plan" | grep -q 'nix .*profile add --no-update-lock-file "path:.*#workspace-deps"'
! printf '%s\n' "$setup_deps_plan" | grep -q 'profile remove workspace-deps'
! printf '%s\n' "$setup_deps_plan" | grep -q 'flake update'
! printf '%s\n' "$setup_deps_plan" | grep -Eq "$old_apt_install|$old_brew_install|$old_snap_installer|$old_csvlens_installer"

upgrade_deps_plan=$(make -n --no-print-directory upgrade-deps)
printf '%s\n' "$upgrade_deps_plan" | grep -q 'nix .*flake update'
printf '%s\n' "$upgrade_deps_plan" | grep -q 'make setup-deps'

runtime_plan=$(make -n --no-print-directory setup-runtime)
for command in 'sh ./scripts/install-nix-fonts.sh' 'cp -r ./nvim/.' './scripts/install-agent-clis.sh install' 'cp -r ./alacritty/.' 'cp -r ./kitty/.'; do
	printf '%s\n' "$runtime_plan" | grep -q "$command"
done
! printf '%s\n' "$runtime_plan" | grep -Eq 'nvim --version|tmux -V|alacritty --version|kitty --version|csvlens --version|go version|gopls version'

nix_install_plan=$(make -n --no-print-directory nix-install)
printf '%s\n' "$nix_install_plan" | grep -q 'sh ./scripts/install-nix.sh'

if grep -Eq "$legacy_setup_pattern" Makefile; then
	echo "legacy package-manager setup code should not exist in Makefile" >&2
	exit 1
fi
if grep -Eq "$redundant_target_pattern" Makefile; then
	echo "redundant installer aliases should not exist in Makefile" >&2
	exit 1
fi

test ! -e "scripts/$old_snap_installer.sh"
test ! -e "scripts/$old_csvlens_installer.sh"

if command -v nix >/dev/null 2>&1 && git ls-files --error-unmatch flake.nix >/dev/null 2>&1; then
	nix --extra-experimental-features 'nix-command flakes' flake check --no-build
else
	echo "skip nix flake check: nix unavailable or flake.nix not tracked"
fi

echo "PASS nix smoke test"
