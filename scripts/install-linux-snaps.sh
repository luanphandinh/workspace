#!/bin/sh
set -eu

if [ "$(uname)" != "Linux" ]; then
	exit 0
fi

if ! command -v snap >/dev/null 2>&1; then
	echo "skip snap deps: snap command not found"
	exit 0
fi

if ! sudo snap wait system seed.loaded >/dev/null 2>&1; then
	echo "skip snap deps: snapd is not ready"
	exit 0
fi

install_snap() {
	command_name=$1
	shift

	if command -v "$command_name" >/dev/null 2>&1; then
		printf '%s already installed: %s\n' "$command_name" "$(command -v "$command_name")"
		return
	fi

	sudo snap install "$@"
}

install_snap yazi yazi --classic
install_snap newsboat newsboat
