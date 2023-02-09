#!/bin/bash

function addPath() {
  path=$1
  if [ -f $path ];then
    echo "found ${path}"
    exportedPath=$(grep 'export PATH=$PATH:/usr/local/go/bin' $path | wc -l)
    if [ $exportedPath -eq 0 ]; then
      echo "export PATH=$PATH:/usr/local/go/bin to $path"
      echo 'export PATH=$PATH:/usr/local/go/bin' >> $path
    fi
    exportedGoPath=$(grep 'export GOPATH=$HOME/go' $path | wc -l)
    if [ $exportedGoPath -eq 0 ]; then
      echo "export GOPATH=$HOME/go to $path"
      echo 'export GOPATH=$HOME/go' >> $path
    fi
    exportedGoRoot=$(grep 'export GOROOT=/usr/local/go' $path | wc -l)
    if [ $exportedGoRoot -eq 0 ]; then
      echo "export GOROOT=/usr/local/go to $path"
      echo 'export GOROOT=/usr/local/go' >> $path
    fi
  fi
}

function addGoPath() {
  path=$1
  if [ -f $path ];then
    echo "found ${path}"
  fi
}

addPath ~/.zshrc
addPath ~/.profile
addPath ~/.bashrc
addPath ~/.bash_profile
