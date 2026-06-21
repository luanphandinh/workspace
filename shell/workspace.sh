export PATH="$HOME/bin:$PATH"
export PATH="$PATH:/usr/local/go/bin"
export PATH="$PATH:$HOME/go/bin"
export COLORTERM=truecolor
export FORCE_COLOR=1
export CODEX_NOTIFY_ACTIVATE_APP=kitty
if [ -n "${ZSH_VERSION:-}" ] && command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh --cmd z)"
elif [ -n "${BASH_VERSION:-}" ] && command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init bash --cmd z)"
fi
unalias mcodex 2>/dev/null || true
mcodex() { codex -c "notify=[\"$HOME/bin/codex-turn-ended-notify\"]" "$@"; }
