#!/bin/sh
set -eu

if [ "$(uname)" != "Linux" ]; then
	exit 0
fi

if ! command -v zsh >/dev/null 2>&1; then
	echo "zsh is required before configuring the default shell" >&2
	exit 1
fi

zsh_path="$(command -v zsh)"
shells_file="${WORKSPACE_SHELLS_FILE:-/etc/shells}"
target_user="${SUDO_USER:-${USER:-}}"
if [ -z "$target_user" ]; then
	target_user="$(id -un)"
fi

current_shell="$(getent passwd "$target_user" 2>/dev/null | awk -F: '{print $7}' || :)"
if [ "$current_shell" = "$zsh_path" ]; then
	printf 'default-shell: %s already uses %s\n' "$target_user" "$zsh_path"
	exit 0
fi

if [ -f "$shells_file" ] && ! grep -Fxq "$zsh_path" "$shells_file"; then
	if [ "$(id -u)" -eq 0 ]; then
		printf '%s\n' "$zsh_path" >> "$shells_file"
	elif command -v sudo >/dev/null 2>&1; then
		printf '%s\n' "$zsh_path" | sudo tee -a "$shells_file" >/dev/null
	else
		echo "default-shell: $zsh_path is not listed in $shells_file and sudo is unavailable" >&2
		exit 1
	fi
fi

if [ "$(id -u)" -eq 0 ]; then
	chsh -s "$zsh_path" "$target_user"
elif chsh -s "$zsh_path" "$target_user" 2>/dev/null; then
	:
elif command -v sudo >/dev/null 2>&1; then
	sudo chsh -s "$zsh_path" "$target_user"
else
	echo "default-shell: failed to set $target_user shell to $zsh_path" >&2
	exit 1
fi

printf 'default-shell: updated %s to %s\n' "$target_user" "$zsh_path"
