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

case "$(uname)" in
	Linux)
		if [ "$(id -u)" -eq 0 ]; then
			echo "nix-install: run workspace setup as your normal user, not root" >&2
			exit 1
		fi
		if [ ! -d /nix ] || [ ! -w /nix ]; then
			echo "nix-install: single-user Nix needs /nix to exist and be writable by your user" >&2
			echo "nix-install: ask an administrator to prepare /nix; setup will not invoke sudo" >&2
			exit 1
		fi
		set -- --no-daemon --yes
		;;
	Darwin)
		if ! sudo -n true >/dev/null 2>&1 && [ ! -t 0 ]; then
			echo "Nix installation on macOS needs interactive sudo. Run make setup from a terminal." >&2
			exit 1
		fi
		set -- --daemon --yes
		;;
	*)
		echo "nix-install: unsupported platform" >&2
		exit 1
		;;
esac

installer=$(mktemp "${TMPDIR:-/tmp}/workspace-nix-install.XXXXXX")
trap 'rm -f "$installer"' EXIT
trap 'exit 1' HUP INT TERM
curl -fL --output "$installer" https://nixos.org/nix/install
sh "$installer" "$@"

. ./scripts/nix-profile.sh
nix --version
