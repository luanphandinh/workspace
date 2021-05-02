#!/bin/bash
STATUS_LINE='export PS1="\e[1;32m\W \$ \e[0m"'
STOP_BELL='bind "set bell-style none"'
if [ -f ~/.profile ]; then
  grep -F "$STATUS_LINE" ~/.profile 2>/dev/null || echo "$STATUS_LINE" >> ~/.profile
  grep -F "$STOP_BELL" ~/.profile 2>/dev/null || echo "$STOP_BELL" >> ~/.profile
fi

if [ -f ~/.bashrc ]; then
  grep -F "$STATUS_LINE" ~/.bashrc 2>/dev/null || echo "$STATUS_LINE" >> ~/.bashrc
  grep -F "$STOP_BELL" ~/.bashrc 2>/dev/null || echo "$STOP_BELL" >> ~/.bashrc
fi

if [ -f ~/.bash_profile ]; then
  grep -F "$STATUS_LINE" ~/.bash_profile 2>/dev/null || echo "$STATUS_LINE" >> ~/.bash_profile
  grep -F "$STOP_BELL" ~/.bash_profile 2>/dev/null || echo "$STOP_BELL" >> ~/.bash_profile
fi
