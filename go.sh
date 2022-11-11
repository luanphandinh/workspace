#!/bin/bash

function addPath() {
  path=$1
  if [ -f $path ];then
    echo "found ${path}"
    exported=$(grep 'export PATH=$PATH:/usr/local/go/bin' $path | wc -l)
    if [ $exported -eq 0 ]; then
      echo "export PATH=$PATH:/usr/local/go/bin to $path"
      echo 'export PATH=$PATH:/usr/local/go/bin' >> $path
    fi
  fi
}

addPath ~/.zshrc
addPath ~/.profile
addPath ~/.bashrc
addPath ~/.bash_profile
