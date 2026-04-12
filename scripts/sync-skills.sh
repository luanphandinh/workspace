#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS="$ROOT/skills"

if [[ ! -d "$SKILLS" ]]; then
  echo "sync-skills: missing directory: $SKILLS" >&2
  exit 1
fi

# Cursor / Claude: ~/.cursor/skills, ~/.claude/skills
# Codex CLI (user scope): ~/.agents/skills — see https://developers.openai.com/codex/skills
DESTS=(
  "${HOME}/.claude/skills"
  "${HOME}/.cursor/skills"
  "${HOME}/.agents/skills"
)

for d in "${DESTS[@]}"; do
  mkdir -p "$d"
  cp -a "${SKILLS}/." "$d/"
done

echo "sync-skills: copied to ${DESTS[*]}"
