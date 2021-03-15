#!/bin/bash
grep -q 'export PATH=$PATH:/usr/local/go/bin' ~/.profile 2>/dev/null || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
grep -q 'export PATH=$PATH:/usr/local/go/bin' ~/.bashrc 2>/dev/null || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
grep -q 'export PATH=$PATH:/usr/local/go/bin' ~/.bashrc 2>/dev/null || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bash_profile
source ~/.bash_profile
GO111MODULE=on go get golang.org/x/tools/gopls@latest
go version
