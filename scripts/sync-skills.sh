#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS="$ROOT/skills"

if [[ ! -d "$SKILLS" ]]; then
  echo "sync-skills: missing directory: $SKILLS" >&2
  exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "sync-skills: npx is required" >&2
  exit 1
fi

if [[ -e "$HOME/.agents/skills/local-writing" || -e "$HOME/.agents/skills/local-technical-writing" ]]; then
  npx --yes skills remove local-writing local-technical-writing -g -y
fi

npx --yes skills add "$ROOT" -g --skill '*' --agent claude-code codex cursor --full-depth -y
npx --yes skills add multica-ai/andrej-karpathy-skills -g --skill karpathy-guidelines --agent claude-code codex cursor --full-depth -y
npx --yes skills add vercel-labs/agent-browser -g --skill agent-browser --agent claude-code codex cursor --full-depth -y

echo "sync-skills: installed local and external skills for claude-code, codex, cursor via npx skills"
