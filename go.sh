#!/bin/bash
if [ -f ~/.profile ]; then
  grep -q 'export PATH=$PATH:/usr/local/go/bin' ~/.profile 2>/dev/null || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
  source ~/.profile
fi

if [ -f ~/.bashrc ]; then
  grep -q 'export PATH=$PATH:/usr/local/go/bin' ~/.bashrc 2>/dev/null || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
  source ~/.bashrc
fi

if [ -f ~/.bash_profile ]; then
  grep -q 'export PATH=$PATH:/usr/local/go/bin' ~/.bash_profile 2>/dev/null || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bash_profile
  source ~/.bash_profile
fi

if [ -f ~/.zshrc ]; then
  grep -q 'export PATH=$PATH:/usr/local/go/bin' ~/.zshrc 2>/dev/null || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.zshrc
  source ~/.zshrc
fi
