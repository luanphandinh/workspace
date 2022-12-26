#!/bin/bash

function log_info() {
    echo -e "\033[0;32m[INFO]\033[0m $1"
}

function clean_up() {
  patterns=( "$@" )
  length=$((${#patterns[@]}-1))
  pattern=""
  for (( j=0; j<=${length}; j++ ));
  do
    if [[ $j -eq ${length} ]]; then
      pattern+="${patterns[$j]}"
    else
      pattern+="${patterns[$j]}|"
    fi
  done

  echo "$pattern"
  log_info "Stop all containers with $pattern..."
  docker ps -a | grep -E "$pattern" | awk -F" " '{print $1}' | xargs docker container stop || true
  log_info "Remove all containers with $pattern..."
  docker ps -a | grep -E "$pattern" | awk -F" " '{print $1}' | xargs docker container rm || true
  for p in "$@"; do
    log_info "Remove all images with $p..."
    docker image ls | grep "$p" | awk -F" " '{print $3}' | xargs docker image rm || true
  done
  log_info "Prune all volumes..."
  echo y | docker volume prune || true
}

log_info "executing command $@"
"$@"
