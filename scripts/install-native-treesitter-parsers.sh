#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache_dir="${NVIM_NATIVE_TREESITTER_CACHE_DIR:-${repo_root}/tmp/native-treesitter-parsers}"
site_dir="${NVIM_NATIVE_TREESITTER_SITE_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/nvim/site}"
parser_dir="${site_dir}/parser"
queries_dir="${site_dir}/queries"

export PATH="${HOME}/.local/bin:${HOME}/bin:${PATH}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required to install native Neovim treesitter parsers" >&2
    exit 1
  fi
}

prepare_repo() {
  lang="$1"
  repo="$2"
  ref="$3"
  target="${cache_dir}/${lang}"

  if [ ! -d "${target}/.git" ]; then
    rm -rf "$target"
    mkdir -p "$target"
    git -C "$target" -c init.templateDir= init -q
    git -C "$target" remote add origin "$repo"
  fi

  git -C "$target" fetch --depth 1 origin "$ref" -q
  git -C "$target" checkout --detach FETCH_HEAD -q
  printf '%s\n' "$target"
}

copy_queries() {
  lang="$1"
  source_dir="$2"
  target_dir="${queries_dir}/${lang}"

  if [ ! -d "${source_dir}/queries" ]; then
    return
  fi

  rm -rf "$target_dir"
  mkdir -p "$target_dir"

  found=0
  for query in "${source_dir}"/queries/*.scm; do
    if [ -f "$query" ]; then
      cp "$query" "$target_dir/"
      found=1
    fi
  done

  if [ "$found" -eq 0 ]; then
    rmdir "$target_dir"
  fi
}

install_parser() {
  lang="$1"
  repo="$2"
  ref="$3"

  source_dir=$(prepare_repo "$lang" "$repo" "$ref")
  tmp_output="${parser_dir}/${lang}.so.tmp.$$"
  output="${parser_dir}/${lang}.so"

  tree-sitter build "$source_dir" -o "$tmp_output"
  mv "$tmp_output" "$output"
  copy_queries "$lang" "$source_dir"
  echo "installed treesitter parser: ${lang}"
}

need_cmd git
need_cmd tree-sitter
need_cmd cc

mkdir -p "$cache_dir" "$parser_dir" "$queries_dir"

install_parser go https://github.com/tree-sitter/tree-sitter-go.git 2346a3ab1bb3857b48b29d779a1ef9799a248cd7
install_parser json https://github.com/tree-sitter/tree-sitter-json.git 001c28d7a29832b06b0e831ec77845553c89b56d
install_parser bash https://github.com/tree-sitter/tree-sitter-bash.git a06c2e4415e9bc0346c6b86d401879ffb44058f7
install_parser yaml https://github.com/tree-sitter-grammars/tree-sitter-yaml.git a1c4812a73ec5e089de8e441fdea3a921e8d5079
