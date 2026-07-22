#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/workspace-shell-smoke-test.$$
fakebin="$tmp/bin"
log="$tmp/zoxide.log"
fzf_log="$tmp/fzf.log"
codex_log="$tmp/codex.log"
daemon_file="$tmp/daemon-running"
mkdir -p "$fakebin"
trap 'rm -rf "$tmp"' EXIT

cat > "$fakebin/zoxide" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$log"
if [ "\${1:-}" = "init" ]; then
  printf 'export ZOXIDE_INIT_SHELL=%s\n' "\${2:-}"
fi
SH
chmod +x "$fakebin/zoxide"

cat > "$fakebin/fzf" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$fzf_log"
case "\${1:-}" in
  --zsh)
    printf 'export FZF_INIT_SHELL=zsh\n'
    ;;
  --bash)
    printf 'export FZF_INIT_SHELL=bash\n'
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$fakebin/fzf"

cat > "$fakebin/codex" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$codex_log"
case "\${1:-} \${2:-} \${3:-}" in
  "remote-control start --json")
    : > "$daemon_file"
    printf '{"status":"started","managedCodexVersion":"0.142.1","cliVersion":"0.142.1","appServerVersion":"0.142.1"}\n'
    exit 0
    ;;
  "app-server daemon version")
    if [ -f "$daemon_file" ]; then
      printf '{"status":"running","managedCodexVersion":"0.142.1","cliVersion":"0.142.1","appServerVersion":"0.142.1"}\n'
      exit 0
    fi
    if [ -n "\${CODEX_FAKE_STALE_DAEMON:-}" ]; then
      printf '{"status":"running","managedCodexVersion":"0.142.0","cliVersion":"0.142.1","appServerVersion":"0.142.0"}\n'
      exit 0
    fi
    exit 1
    ;;
  "--remote unix:// "*)
    exit 0
    ;;
  "resume --remote unix://")
    exit 0
    ;;
  "--version  ")
    exit 0
    ;;
esac
exit 1
SH
chmod +x "$fakebin/codex"

project_jump="$tmp/project-jump"
repo_jump="$tmp/repo-jump"
mkdir -p "$project_jump" "$repo_jump"
project_jump=$(CDPATH= cd -- "$project_jump" && pwd -P)
repo_jump=$(CDPATH= cd -- "$repo_jump" && pwd -P)
cat > "$fakebin/meta-hub" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/meta-hub.log"
case "\${1:-}" in
  project|p)
    printf '%s\n' "$project_jump"
    ;;
  repo|r)
    printf '%s\n' "$repo_jump"
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "$fakebin/meta-hub"

cat > "$fakebin/uname" <<'SH'
#!/bin/sh
echo Linux
SH
cat > "$fakebin/zsh" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$fakebin/getent" <<SH
#!/bin/sh
printf '%s:x:1000:1000::/home/%s:/bin/bash\n' "\$2" "\$2"
SH
cat > "$fakebin/chsh" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/chsh.log"
exit 0
SH
cat > "$fakebin/sudo" <<SH
#!/bin/sh
printf 'sudo %s\n' "\$*" >> "$tmp/chsh.log"
"\$@"
SH
chmod +x "$fakebin/uname" "$fakebin/zsh" "$fakebin/getent" "$fakebin/chsh" "$fakebin/sudo"
printf '%s\n' "$fakebin/zsh" > "$tmp/shells"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" USER=example-user WORKSPACE_SHELLS_FILE="$tmp/shells" \
	sh "$repo_root/scripts/configure-default-zsh.sh"
grep -qx -- 'sudo chsh -s '"$fakebin"'/zsh example-user' "$tmp/chsh.log"
grep -qx -- '-s '"$fakebin"'/zsh example-user' "$tmp/chsh.log"
rm -f "$fakebin/uname" "$fakebin/zsh" "$fakebin/getent" "$fakebin/chsh" "$fakebin/sudo"

PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" NO_COLOR=1 sh -c ". '$repo_root/bin/shell/workspace.sh'; test -z \"\${NO_COLOR+x}\"; test \"\$FORCE_COLOR\" = 1; test \"\$GOPATH\" = \"\$HOME/go\"; case \"\$PATH\" in \"\$HOME/.local/bin:\$HOME/bin:/usr/local/bin:\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\"*) ;; *) exit 1 ;; esac; case \":\$PATH:\" in *\":\$GOPATH/bin:\"*) ;; *) exit 1 ;; esac"

PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh "$repo_root/bin/mcodex"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh "$repo_root/bin/mcodex" prompt
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh "$repo_root/bin/mcodex" next
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh "$repo_root/bin/mcodex" -C "$tmp/other" explicit
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh "$repo_root/bin/mcodex" resume --last
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh "$repo_root/bin/mcodex" resume -C "$tmp/resume-other" explicit
test "$(grep -Fxc 'remote-control start --json' "$codex_log")" = 1
grep -Fxq 'app-server daemon version' "$codex_log"
grep -Fxq -- 'resume --remote unix:// -C '"$repo_root" "$codex_log"
grep -Fxq -- '--remote unix:// -C '"$repo_root"' prompt' "$codex_log"
grep -Fxq -- '--remote unix:// -C '"$repo_root"' next' "$codex_log"
grep -Fxq -- '--remote unix:// -C '"$tmp/other"' explicit' "$codex_log"
grep -Fxq -- 'resume --remote unix:// -C '"$repo_root"' --last' "$codex_log"
grep -Fxq -- 'resume --remote unix:// -C '"$tmp/resume-other"' explicit' "$codex_log"

stale_home="$tmp/stale-codex-home"
mkdir -p "$stale_home/app-server-control" "$stale_home/app-server-daemon"
: > "$stale_home/app-server-control/mcodex-remote-control-started"
: > "$stale_home/app-server-control/app-server-control.sock"
printf '{"pid":999999}\n' > "$stale_home/app-server-daemon/app-server.pid"
printf '{"pid":999998}\n' > "$stale_home/app-server-daemon/app-server-updater.pid"
: > "$codex_log"
rm -f "$daemon_file"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" CODEX_HOME="$stale_home" CODEX_FAKE_STALE_DAEMON=1 \
	sh "$repo_root/bin/mcodex" stale-prompt
grep -Fxq 'app-server daemon version' "$codex_log"
grep -Fxq 'remote-control start --json' "$codex_log"
grep -Fxq -- '--remote unix:// -C '"$repo_root"' stale-prompt' "$codex_log"
test ! -e "$stale_home/app-server-control/app-server-control.sock"
test ! -e "$stale_home/app-server-daemon/app-server.pid"
test ! -e "$stale_home/app-server-daemon/app-server-updater.pid"

PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh -c ". '$repo_root/bin/shell/workspace.sh'; ! command -v mcodex >/dev/null 2>&1"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" bash -c ". '$repo_root/bin/shell/workspace.sh'; meta-hub project; test \"\$PWD\" = '$project_jump'"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" bash -c ". '$repo_root/bin/shell/workspace.sh'; meta-hub repo; test \"\$PWD\" = '$repo_jump'"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" bash -c ". '$repo_root/bin/shell/workspace.sh'; meta-hub p; test \"\$PWD\" = '$project_jump'"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" bash -c ". '$repo_root/bin/shell/workspace.sh'; meta-hub r; test \"\$PWD\" = '$repo_jump'"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" bash -c ". '$repo_root/bin/shell/workspace.sh'; before=\$PWD; meta-hub sync; test \"\$PWD\" = \"\$before\""
grep -Fxq 'project' "$tmp/meta-hub.log"
grep -Fxq 'repo' "$tmp/meta-hub.log"
grep -Fxq 'p' "$tmp/meta-hub.log"
grep -Fxq 'r' "$tmp/meta-hub.log"
grep -Fxq 'sync' "$tmp/meta-hub.log"

zsh_bin=$(command -v zsh || true)
if [ -n "$zsh_bin" ]; then
  PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" "$zsh_bin" -fc ". '$repo_root/bin/shell/workspace.sh'; test \"\$ZOXIDE_INIT_SHELL\" = zsh"
  PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" "$zsh_bin" -fc ". '$repo_root/bin/shell/workspace.sh'; test \"\$FZF_INIT_SHELL\" = zsh"
  PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" "$zsh_bin" -fc ". '$repo_root/bin/shell/workspace.sh'; test \"\$PROMPT\" = '%1~ %# '"
  PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" "$zsh_bin" -fc ". '$repo_root/bin/shell/workspace.sh'; test \"\$HISTSIZE\" = 2000; test \"\$SAVEHIST\" = 1000; test \"\$options[histexpiredupsfirst]\" = on; test \"\$options[histfindnodups]\" = on; test \"\$options[histignorealldups]\" = on; test \"\$options[histsavenodups]\" = on"
  WORKSPACE_SHELL="$repo_root/bin/shell/workspace.sh" PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" \
    "$zsh_bin" -fic '. "$WORKSPACE_SHELL"; bindkey "$(printf "\033[1;3D")"; bindkey "$(printf "\033[1;3C")"' \
    > "$tmp/zsh-option-arrow-bindings"
  grep -Fq 'backward-word' "$tmp/zsh-option-arrow-bindings"
  grep -Fq 'forward-word' "$tmp/zsh-option-arrow-bindings"
  grep -qx 'init zsh --cmd z' "$log"
  grep -qx -- '--zsh' "$fzf_log"
fi

: > "$log"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh -c ". '$repo_root/bin/shell/workspace.sh'; test \"\${ZOXIDE_INIT_SHELL:-}\" = \"\""
! grep -q '^init ' "$log"

: > "$log"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" bash -c ". '$repo_root/bin/shell/workspace.sh'; test \"\$ZOXIDE_INIT_SHELL\" = bash"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" bash -c ". '$repo_root/bin/shell/workspace.sh'; test \"\$FZF_INIT_SHELL\" = bash"
WORKSPACE_SHELL="$repo_root/bin/shell/workspace.sh" PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" \
  bash --noprofile --norc -ic '. "$WORKSPACE_SHELL"; bind -P' > "$tmp/bash-option-arrow-bindings" 2>/dev/null
grep -Fq '"\e[1;3D"' "$tmp/bash-option-arrow-bindings"
grep -Fq '"\e[1;3C"' "$tmp/bash-option-arrow-bindings"
grep -qx 'init bash --cmd z' "$log"
grep -qx -- '--bash' "$fzf_log"

mkdir -p "$tmp/sync-home"
mkdir -p "$tmp/sync-home/bin/shell"
cp "$repo_root/bin/shell/workspace.sh" "$tmp/sync-home/bin/shell/workspace.sh"
cat > "$tmp/sync-home/.zshrc" <<SH
# >>> workspace-bin
old managed block
# <<< workspace-bin
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
export PATH=\$PATH:/usr/local/go/bin
export PATH=\$PATH:~/go/bin
export GOPATH=~/go
export PATH="\$HOME/.local/bin:\$PATH"
export PATH=$tmp/sync-home/.local/bin:\$PATH
export PATH="/usr/local/bin:\$PATH"
export PATH="\$HOME/bin:/opt/homebrew/bin:\$PATH"
keep-zsh
SH
printf '[ -f ~/.fzf.bash ] && source ~/.fzf.bash\nexport PATH=$PATH:/usr/local/go/bin\nexport PATH=$PATH:~/go/bin\nexport GOPATH=~/go\nkeep-bash\n' > "$tmp/sync-home/.bashrc"
printf 'keep-profile\n' > "$tmp/sync-home/.profile"
HOME="$tmp/sync-home" sh "$repo_root/bin/workspace-shell-sync" >/dev/null
source_line='[ -f "$HOME/bin/shell/workspace.sh" ] && . "$HOME/bin/shell/workspace.sh"'
grep -Fxq "$source_line" "$tmp/sync-home/.zshrc"
grep -Fxq "$source_line" "$tmp/sync-home/.bashrc"
grep -Fxq "$source_line" "$tmp/sync-home/.profile"
test "$(grep -Fxc "$source_line" "$tmp/sync-home/.zshrc")" = 1
! grep -Fq '# >>> workspace-bin' "$tmp/sync-home/.zshrc"
! grep -Fq 'old managed block' "$tmp/sync-home/.zshrc"
! grep -Fq 'source ~/.fzf.zsh' "$tmp/sync-home/.zshrc"
! grep -Fq 'source ~/.fzf.bash' "$tmp/sync-home/.bashrc"
! grep -Fq 'export PATH=$PATH:/usr/local/go/bin' "$tmp/sync-home/.zshrc"
! grep -Fq 'export PATH=$PATH:~/go/bin' "$tmp/sync-home/.zshrc"
! grep -Fq 'export GOPATH=~/go' "$tmp/sync-home/.zshrc"
! grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' "$tmp/sync-home/.zshrc"
! grep -Fq 'export PATH='"$tmp/sync-home"'/.local/bin:$PATH' "$tmp/sync-home/.zshrc"
! grep -Fq 'export PATH="/usr/local/bin:$PATH"' "$tmp/sync-home/.zshrc"
! grep -Fq 'export PATH="$HOME/bin:/opt/homebrew/bin:$PATH"' "$tmp/sync-home/.zshrc"
! grep -Fq 'export PATH=$PATH:/usr/local/go/bin' "$tmp/sync-home/.bashrc"
! grep -Fq 'export PATH=$PATH:~/go/bin' "$tmp/sync-home/.bashrc"
! grep -Fq 'export GOPATH=~/go' "$tmp/sync-home/.bashrc"
grep -Fxq 'keep-zsh' "$tmp/sync-home/.zshrc"
grep -Fxq 'keep-bash' "$tmp/sync-home/.bashrc"
grep -Fxq 'keep-profile' "$tmp/sync-home/.profile"
cp "$tmp/sync-home/.zshrc" "$tmp/sync-home/.zshrc.after-first-sync"
HOME="$tmp/sync-home" sh "$repo_root/bin/workspace-shell-sync" >/dev/null
cmp -s "$tmp/sync-home/.zshrc" "$tmp/sync-home/.zshrc.after-first-sync"

echo "PASS workspace shell smoke test"
