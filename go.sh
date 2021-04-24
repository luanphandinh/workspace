#!/bin/bash
if [ -f ~/.profile ]; then
  grep -q 'export PATH=$PATH:/usr/local/go/bin' ~/.profile 2>/dev/null || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
fi

if [ -f ~/.bashrc ]; then
  grep -q 'export PATH=$PATH:/usr/local/go/bin' ~/.bashrc 2>/dev/null || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
fi

if [ -f ~/.bash_profile ]; then
  grep -q 'export PATH=$PATH:/usr/local/go/bin' ~/.bash_profile 2>/dev/null || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bash_profile
fi
source ~/.bash_profile
