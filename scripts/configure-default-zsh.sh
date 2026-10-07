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

if [ "$(id -u)" -ne 0 ]; then
	printf 'default-shell: keeping the current login shell; changing it requires an administrator\n'
	printf 'default-shell: run exec zsh -l to use the installed shell now\n'
	exit 0
fi

if [ -f "$shells_file" ] && ! grep -Fxq "$zsh_path" "$shells_file"; then
	printf '%s\n' "$zsh_path" >> "$shells_file"
fi

chsh -s "$zsh_path" "$target_user"

printf 'default-shell: updated %s to %s\n' "$target_user" "$zsh_path"
