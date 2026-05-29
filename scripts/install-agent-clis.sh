#!/usr/bin/env sh
set -eu

bin_dir="${HOME}/.local/bin"
npm_prefix="${HOME}/.local"

export PATH="${bin_dir}:${HOME}/bin:${PATH}"

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need_cmd() {
  if ! has_cmd "$1"; then
    echo "$1 is required to install agent CLIs" >&2
    exit 1
  fi
}

install_npm_cli() {
  cmd="$1"
  package="$2"

  if has_cmd "$cmd"; then
    return
  fi

  need_cmd npm
  mkdir -p "$bin_dir"
  npm install --global --prefix "$npm_prefix" "$package"
}

install_cursor_cli() {
  if has_cmd cursor-agent; then
    return
  fi

  need_cmd curl
  mkdir -p "$bin_dir"
  curl https://cursor.com/install -fsS | bash
}

verify_cli() {
  cmd="$1"

  if ! has_cmd "$cmd"; then
    echo "$cmd is not installed or not on PATH" >&2
    exit 1
  fi

  if ! "$cmd" --version >/dev/null 2>&1; then
    echo "$cmd --version failed" >&2
    exit 1
  fi
}

install_all() {
  install_npm_cli claude @anthropic-ai/claude-code
  install_npm_cli codex @openai/codex
  install_cursor_cli
}

verify_all() {
  verify_cli claude
  verify_cli codex
  verify_cli cursor-agent
}

case "${1:-install}" in
  install)
    install_all
    verify_all
    ;;
  verify)
    verify_all
    ;;
  *)
    echo "usage: $0 [install|verify]" >&2
    exit 2
    ;;
esac
