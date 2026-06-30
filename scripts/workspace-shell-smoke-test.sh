#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/workspace-shell-smoke-test.$$
fakebin="$tmp/bin"
log="$tmp/zoxide.log"
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

PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh -c ". '$repo_root/shell/workspace.sh'; case \"\$PATH\" in \"\$HOME/.local/bin:\$HOME/bin:\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\"*) ;; *) exit 1 ;; esac"

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

PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh -c ". '$repo_root/shell/workspace.sh'; ! command -v mcodex >/dev/null 2>&1"

zsh_bin=$(command -v zsh || true)
if [ -n "$zsh_bin" ]; then
  PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" "$zsh_bin" -fc ". '$repo_root/shell/workspace.sh'; test \"\$ZOXIDE_INIT_SHELL\" = zsh"
  PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" "$zsh_bin" -fc ". '$repo_root/shell/workspace.sh'; test \"\$PROMPT\" = '%1~ %# '"
  grep -qx 'init zsh --cmd z' "$log"
fi

: > "$log"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh -c ". '$repo_root/shell/workspace.sh'; test \"\${ZOXIDE_INIT_SHELL:-}\" = \"\""
! grep -q '^init ' "$log"

: > "$log"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" bash -c ". '$repo_root/shell/workspace.sh'; test \"\$ZOXIDE_INIT_SHELL\" = bash"
grep -qx 'init bash --cmd z' "$log"

echo "PASS workspace shell smoke test"
