#!/bin/bash
grep -q 'export PATH=$PATH:/usr/local/go/bin' ~/.profile 2>/dev/null || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
grep -q 'export PATH=$PATH:/usr/local/go/bin' ~/.bashrc 2>/dev/null || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
go version
