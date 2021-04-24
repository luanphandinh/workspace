#!/bin/bash
STATUS_LINE='export PS1="\e[1;32m\W \$ \e[0m"'
if [ -f ~/.profile ]; then
  grep -F "$STATUS_LINE" ~/.profile 2>/dev/null || echo "$STATUS_LINE" >> ~/.profile
fi

if [ -f ~/.bashrc ]; then
  grep -F "$STATUS_LINE" ~/.bashrc 2>/dev/null || echo "$STATUS_LINE" >> ~/.bashrc
fi

if [ -f ~/.bash_profile ]; then
  grep -F "$STATUS_LINE" ~/.bash_profile 2>/dev/null || echo "$STATUS_LINE" >> ~/.bash_profile
fi
