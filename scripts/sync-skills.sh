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

npx --yes skills add "$ROOT" -g --all --full-depth

echo "sync-skills: installed all skills via npx skills"
