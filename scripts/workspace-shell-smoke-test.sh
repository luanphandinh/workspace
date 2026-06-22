#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/workspace-shell-smoke-test.$$
fakebin="$tmp/bin"
log="$tmp/zoxide.log"
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

linux_setup_plan=$(make -n -C "$repo_root" --no-print-directory UNAME=Linux is_wsl=0 setup)
printf '%s\n' "$linux_setup_plan" | grep -Eq 'apt install .*zoxide'

darwin_setup_plan=$(make -n -C "$repo_root" --no-print-directory UNAME=Darwin is_wsl=0 setup)
printf '%s\n' "$darwin_setup_plan" | grep -Eq 'brew install .*zoxide'

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
