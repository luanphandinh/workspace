export PATH="$HOME/bin:$PATH"
export PATH="$PATH:/usr/local/go/bin"
export PATH="$PATH:$HOME/go/bin"
export COLORTERM=truecolor
export FORCE_COLOR=1
mcodex() { codex -c "notify=[\"$HOME/bin/codex-turn-ended-notify\"]" "$@"; }
