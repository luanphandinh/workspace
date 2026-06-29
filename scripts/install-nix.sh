#!/bin/sh
set -eu

if command -v nix >/dev/null 2>&1; then
	nix --version
	exit 0
fi

if [ -r /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
	. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
	if command -v nix >/dev/null 2>&1; then
		nix --version
		exit 0
	fi
fi

if [ -r "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
	. "$HOME/.nix-profile/etc/profile.d/nix.sh"
	if command -v nix >/dev/null 2>&1; then
		nix --version
		exit 0
	fi
fi

if ! command -v curl >/dev/null 2>&1; then
	echo "curl is required to install Nix" >&2
	exit 1
fi

if [ "$(uname)" = "Darwin" ] && ! sudo -n true >/dev/null 2>&1 && [ ! -t 0 ]; then
	echo "Nix installation on macOS needs interactive sudo. Run make setup from a terminal." >&2
	exit 1
fi

curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes

. ./scripts/nix-profile.sh
nix --version
