#!/bin/bash
CONFS=(
  'export PS1="\e[1;32m\W \$ \e[0m"'
  'bind "set bell-style none"'
  'export PS1="\n$PS1"'
)

for CONF in "${CONFS[@]}"; do
  if [ -f ~/.profile ]; then
    grep -F "$CONF" ~/.profile 2>/dev/null || echo "$CONF" >> ~/.profile
  fi

  if [ -f ~/.bashrc ]; then
    grep -F "$CONF" ~/.bashrc 2>/dev/null || echo "$CONF" >> ~/.bashrc
  fi

  if [ -f ~/.bash_profile ]; then
    grep -F "$CONF" ~/.bash_profile 2>/dev/null || echo "$CONF" >> ~/.bash_profile
  fi
done
