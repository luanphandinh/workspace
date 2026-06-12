#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lock_file="${VERSION_LOCK_FILE:-${repo_root}/version-lock.json}"
cache_dir="${NVIM_NATIVE_TREESITTER_CACHE_DIR:-${repo_root}/tmp/native-treesitter-parsers}"
site_dir="${NVIM_NATIVE_TREESITTER_SITE_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/nvim/site}"
parser_dir="${site_dir}/parser"
queries_dir="${site_dir}/queries"

export PATH="${PATH}:${HOME}/.local/bin:${HOME}/bin"

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
need_cmd python3
need_cmd tree-sitter
need_cmd cc

mkdir -p "$cache_dir" "$parser_dir" "$queries_dir"

python3 "$repo_root/scripts/version_lock.py" validate "$lock_file"

python3 "$repo_root/scripts/version_lock.py" parsers "$lock_file" | while IFS='	' read -r lang repo ref; do
  install_parser "$lang" "$repo" "$ref"
done
