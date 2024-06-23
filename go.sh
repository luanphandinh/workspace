#!/bin/bash

function addPathToFile() {
  path=$1
  file=$2
  if [ -f $file ];then
    echo "try to find ${path} in $file"
    if grep -q "$path" "$file"; then
      echo "Pattern found in file. Do nothing"
    else
      echo "$path not found in $file. Insert"
      echo "$path" >> $file
    fi
  fi
}

addPathToFile 'export PATH=$PATH:/usr/local/go/bin' ~/.zshrc
addPathToFile 'export PATH=$PATH:/usr/local/go/bin' ~/.profile
addPathToFile 'export PATH=$PATH:/usr/local/go/bin' ~/.bashrc
addPathToFile 'export PATH=$PATH:/usr/local/go/bin' ~/.bash_profile

addPathToFile 'export PATH=$PATH:$HOME/go/bin' ~/.zshrc
addPathToFile 'export PATH=$PATH:$HOME/go/bin' ~/.profile
addPathToFile 'export PATH=$PATH:$HOME/go/bin' ~/.bashrc
addPathToFile 'export PATH=$PATH:$HOME/go/bin' ~/.bash_profile
