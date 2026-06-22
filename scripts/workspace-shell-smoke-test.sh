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
    exit 0
    ;;
  "app-server daemon version")
    test -f "$daemon_file"
    exit $?
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

linux_setup_plan=$(make -n -C "$repo_root" --no-print-directory UNAME=Linux is_wsl=0 setup)
printf '%s\n' "$linux_setup_plan" | grep -Eq 'apt install .*zoxide'

darwin_setup_plan=$(make -n -C "$repo_root" --no-print-directory UNAME=Darwin is_wsl=0 setup)
printf '%s\n' "$darwin_setup_plan" | grep -Eq 'brew install .*zoxide'

PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh -c ". '$repo_root/shell/workspace.sh'; case \"\$PATH\" in \"\$HOME/.local/bin:\$HOME/bin:\"*) ;; *) exit 1 ;; esac"

PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh "$repo_root/bin/mcodex"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh "$repo_root/bin/mcodex" prompt
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh "$repo_root/bin/mcodex" next
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh "$repo_root/bin/mcodex" -C "$tmp/other" explicit
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh "$repo_root/bin/mcodex" resume --last
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh "$repo_root/bin/mcodex" resume -C "$tmp/resume-other" explicit
test "$(grep -Fxc 'remote-control start --json' "$codex_log")" = 1
grep -Fxq 'app-server daemon version' "$codex_log"
grep -Fxq -- 'resume --remote unix:// -C '"$repo_root"' -c notify=["'"$tmp/home"'/bin/codex-turn-ended-notify"]' "$codex_log"
grep -Fxq -- '--remote unix:// -C '"$repo_root"' -c notify=["'"$tmp/home"'/bin/codex-turn-ended-notify"] prompt' "$codex_log"
grep -Fxq -- '--remote unix:// -C '"$repo_root"' -c notify=["'"$tmp/home"'/bin/codex-turn-ended-notify"] next' "$codex_log"
grep -Fxq -- '--remote unix:// -c notify=["'"$tmp/home"'/bin/codex-turn-ended-notify"] -C '"$tmp/other"' explicit' "$codex_log"
grep -Fxq -- 'resume --remote unix:// -C '"$repo_root"' -c notify=["'"$tmp/home"'/bin/codex-turn-ended-notify"] --last' "$codex_log"
grep -Fxq -- 'resume --remote unix:// -c notify=["'"$tmp/home"'/bin/codex-turn-ended-notify"] -C '"$tmp/resume-other"' explicit' "$codex_log"

PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh -c ". '$repo_root/shell/workspace.sh'; ! command -v mcodex >/dev/null 2>&1"

if command -v zsh >/dev/null 2>&1; then
  PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" zsh -fc ". '$repo_root/shell/workspace.sh'; test \"\$ZOXIDE_INIT_SHELL\" = zsh"
  grep -qx 'init zsh --cmd z' "$log"
fi

: > "$log"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" sh -c ". '$repo_root/shell/workspace.sh'; test \"\${ZOXIDE_INIT_SHELL:-}\" = \"\""
! grep -q '^init ' "$log"

: > "$log"
PATH="$fakebin:/usr/bin:/bin" HOME="$tmp/home" bash -c ". '$repo_root/shell/workspace.sh'; test \"\$ZOXIDE_INIT_SHELL\" = bash"
grep -qx 'init bash --cmd z' "$log"

echo "PASS workspace shell smoke test"
