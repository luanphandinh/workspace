#!/usr/bin/env sh
set -eu

root_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

fake_bin="$tmp_dir/bin"
log="$tmp_dir/npx.log"
mkdir -p "$fake_bin"

cat > "$fake_bin/npx" <<'SH'
#!/usr/bin/env sh
set -eu
printf '%s\n' "$*" >> "$SYNC_SKILLS_SMOKE_LOG"
SH
chmod +x "$fake_bin/npx"

PATH="$fake_bin:/usr/bin:/bin" SYNC_SKILLS_SMOKE_LOG="$log" \
  bash "$root_dir/scripts/sync-skills.sh" >/dev/null

grep -Fx -- "--yes skills add $root_dir -g --skill * --agent claude-code codex cursor --full-depth -y" "$log" >/dev/null
grep -Fx -- '--yes skills add multica-ai/andrej-karpathy-skills -g --skill karpathy-guidelines --agent claude-code codex cursor --full-depth -y' "$log" >/dev/null
grep -Fx -- '--yes skills add vercel-labs/agent-browser -g --skill agent-browser --agent claude-code codex cursor --full-depth -y' "$log" >/dev/null
test "$(wc -l < "$log" | tr -d ' ')" = 3

echo "sync-skills smoke test passed"
