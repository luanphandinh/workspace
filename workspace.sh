#!/bin/bash

function addGitignore() {
  path=$1
  added=$(grep $path ~/.gitignore | wc -l)
  if [ $added -eq 0 ]; then
    echo "adding $path to ~/.gitignore"
    echo $path >> ~/.gitignore
    echo "added $path to ~/.gitignore"
  fi
}

touch ~/.gitignore
git config --global core.excludesfile ~/.gitignore
addGitignore .vimspector.json
addGitignore node_modules
