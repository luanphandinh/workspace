#!/usr/bin/env sh
set -eu

bin_dir="${CODEX_INSTALL_DIR:-$HOME/.local/bin}"
npm_prefix="${HOME}/.local"
codex_standalone="${CODEX_HOME:-$HOME/.codex}/packages/standalone/current/codex"

export PATH="${bin_dir}:${npm_prefix}/bin:${HOME}/bin:${PATH}"

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ignore_codex_failure() {
  message="$1"

  if [ "${IS_CI_WORKSPACE:-0}" = "1" ] && [ "$(uname -s)" = "Darwin" ]; then
    echo "WARNING: $message; continuing because IS_CI_WORKSPACE=1 on macOS" >&2
    return 0
  fi

  echo "$message" >&2
  return 1
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

install_codex_cli() {
  if has_cmd codex && [ -x "$codex_standalone" ]; then
    return
  fi

  need_cmd curl
  mkdir -p "$bin_dir"
  installer="$(mktemp "${TMPDIR:-/tmp}/codex-install.XXXXXX")"
  if ! curl -fsSL https://chatgpt.com/codex/install.sh -o "$installer"; then
    rm -f "$installer"
    ignore_codex_failure "codex installation download failed"
    return $?
  fi
  if ! CODEX_NON_INTERACTIVE=true sh "$installer"; then
    rm -f "$installer"
    ignore_codex_failure "codex installation failed"
    return $?
  fi
  rm -f "$installer"
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

verify_codex_cli() {
  if ! has_cmd codex; then
    ignore_codex_failure "codex is not installed or not on PATH"
    return $?
  fi
  if ! codex --version >/dev/null 2>&1; then
    ignore_codex_failure "codex --version failed"
    return $?
  fi
  codex_path="$(command -v codex)"
  if [ "$codex_path" != "$bin_dir/codex" ]; then
    ignore_codex_failure "codex resolves to $codex_path, expected $bin_dir/codex"
    return $?
  fi
  if [ ! -x "$codex_standalone" ]; then
    ignore_codex_failure "standalone codex is not installed at $codex_standalone"
    return $?
  fi
}

install_all() {
  install_npm_cli claude @anthropic-ai/claude-code
  install_codex_cli
  install_cursor_cli
}

verify_all() {
  verify_cli claude
  verify_codex_cli
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
