#!/usr/bin/env sh
set -eu

root_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

fake_bin="$tmp_dir/fake-bin"
home_dir="$tmp_dir/home"
install_dir="$tmp_dir/install-bin"
agent_browser_log="$tmp_dir/agent-browser.log"
mkdir -p "$fake_bin" "$home_dir" "$install_dir"

for cmd in claude cursor-agent; do
  printf '%s\n' '#!/usr/bin/env sh' 'exit 0' > "$fake_bin/$cmd"
  chmod +x "$fake_bin/$cmd"
done
cat > "$fake_bin/agent-browser" <<'SH'
#!/usr/bin/env sh
set -eu
printf '%s\n' "$*" >> "$AGENT_BROWSER_SMOKE_LOG"
SH
chmod +x "$fake_bin/agent-browser"
printf '%s\n' '#!/usr/bin/env sh' 'exit 22' > "$fake_bin/curl"
chmod +x "$fake_bin/curl"
printf '%s\n' '#!/usr/bin/env sh' 'echo "${FAKE_UNAME:-Darwin}"' > "$fake_bin/uname"
chmod +x "$fake_bin/uname"

run_script() {
  ci_flag="$1"
  action="$2"
  fake_uname="${3:-Darwin}"
  HOME="$home_dir" \
    CODEX_INSTALL_DIR="$install_dir" \
    FAKE_UNAME="$fake_uname" \
    AGENT_BROWSER_SMOKE_LOG="$agent_browser_log" \
    IS_CI_WORKSPACE="$ci_flag" \
    PATH="$fake_bin:/usr/bin:/bin" \
    sh "$root_dir/scripts/install-agent-clis.sh" "$action"
}

run_script 1 install >/dev/null 2>&1
run_script 1 verify >/dev/null 2>&1
grep -Fx -- 'install' "$agent_browser_log" >/dev/null
grep -Fx -- '--version' "$agent_browser_log" >/dev/null

if run_script 0 install >/dev/null 2>&1; then
  echo "local install unexpectedly ignored a Codex failure" >&2
  exit 1
fi

if run_script 0 verify >/dev/null 2>&1; then
  echo "local verification unexpectedly ignored a missing Codex CLI" >&2
  exit 1
fi

if run_script 1 install Linux >/dev/null 2>&1; then
  echo "Linux install unexpectedly ignored a Codex failure" >&2
  exit 1
fi

if run_script 1 verify Linux >/dev/null 2>&1; then
  echo "Linux verification unexpectedly ignored a missing Codex CLI" >&2
  exit 1
fi

echo "install-agent-clis smoke test passed"
