#!/bin/bash

function log_info() {
    echo -e "\033[0;32m[INFO]\033[0m $1"
}

function add_gitignore() {
  path=$1
  added=$(grep $path ~/.gitignore | wc -l)
  if [ $added -eq 0 ]; then
    echo "adding $path to ~/.gitignore"
    echo $path >> ~/.gitignore
    echo "added $path to ~/.gitignore"
  fi
}

log_info "executing command $@"
"$@"
