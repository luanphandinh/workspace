if [ -r /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
elif [ -r "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
export PATH="$HOME/.local/bin:$HOME/bin:$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
export PATH="$PATH:/usr/local/go/bin"
export PATH="$PATH:$HOME/go/bin"
hash -r 2>/dev/null || true
export COLORTERM=truecolor
export FORCE_COLOR=1
export CODEX_NOTIFY_ACTIVATE_APP=kitty
if [ -n "${ZSH_VERSION:-}" ]; then
  HISTFILE=${HISTFILE:-"$HOME/.zsh_history"}
  HISTSIZE=2000
  SAVEHIST=1000
  setopt APPEND_HISTORY
  setopt HIST_EXPIRE_DUPS_FIRST
  setopt HIST_FIND_NO_DUPS
  setopt HIST_IGNORE_ALL_DUPS
  setopt HIST_SAVE_NO_DUPS
  PROMPT='%1~ %# '
fi
if [ -n "${ZSH_VERSION:-}" ] && command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh --cmd z)"
elif [ -n "${BASH_VERSION:-}" ] && [ -z "${POSIXLY_CORRECT:-}" ] && command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init bash --cmd z)"
fi
unalias mcodex 2>/dev/null || true
unset -f mcodex 2>/dev/null || true
