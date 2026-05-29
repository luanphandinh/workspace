#!/bin/bash

function addPath() {
  profile=$1
  line=$2
  if [ -f "$profile" ]; then
    echo "found ${profile}"
    exported=$(grep -xF "$line" "$profile" | wc -l)
    if [ "$exported" -eq 0 ]; then
      echo "$line to $profile"
      echo "$line" >> "$profile"
    fi
  fi
}

function addGoPaths() {
  profile=$1
  addPath "$profile" 'export PATH=$PATH:/usr/local/go/bin'
  addPath "$profile" 'export PATH=$PATH:$HOME/go/bin'
}

addGoPaths ~/.zshrc
addGoPaths ~/.profile
addGoPaths ~/.bashrc
addGoPaths ~/.bash_profile
