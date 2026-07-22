if [ -r /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
elif [ -r "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
export GOPATH="${GOPATH:-$HOME/go}"
export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
export PATH="$PATH:/usr/local/go/bin:$GOPATH/bin"
hash -r 2>/dev/null || true
export COLORTERM=truecolor
unset NO_COLOR
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
case $- in
  *i*)
    if [ -n "${ZSH_VERSION:-}" ]; then
      bindkey "$(printf '\033[1;3D')" backward-word
      bindkey "$(printf '\033[1;3C')" forward-word
    elif [ -n "${BASH_VERSION:-}" ]; then
      bind '"\e[1;3D": backward-word'
      bind '"\e[1;3C": forward-word'
    fi
    ;;
esac
if command -v fzf >/dev/null 2>&1; then
  if [ -n "${ZSH_VERSION:-}" ]; then
    eval "$(fzf --zsh)"
  elif [ -n "${BASH_VERSION:-}" ]; then
    eval "$(fzf --bash)"
  fi
fi
if [ -n "${ZSH_VERSION:-}" ] && command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh --cmd z)"
elif [ -n "${BASH_VERSION:-}" ] && [ -z "${POSIXLY_CORRECT:-}" ] && command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init bash --cmd z)"
fi
case "${BASH:-}" in
  */bash|bash) _meta_hub_is_bash=1 ;;
  *) _meta_hub_is_bash=0 ;;
esac
if [ -n "${ZSH_VERSION:-}" ] || [ "$_meta_hub_is_bash" = 1 ]; then
  eval '
meta-hub() {
  case "${1:-}" in
    project|p|repo|r)
      if [ "$#" -ne 1 ]; then
        command meta-hub "$@"
        return $?
      fi
      _meta_hub_target=$(command meta-hub "$@") || return $?
      if [ -z "$_meta_hub_target" ]; then
        unset _meta_hub_target
        return 1
      fi
      cd "$_meta_hub_target"
      _meta_hub_status=$?
      unset _meta_hub_target
      return $_meta_hub_status
      ;;
    *)
      command meta-hub "$@"
      ;;
  esac
}
'
fi
unset _meta_hub_is_bash
unalias mcodex 2>/dev/null || true
unset -f mcodex 2>/dev/null || true
