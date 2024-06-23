UNAME := $(shell uname)
ifneq (,$(findstring Linux,$(UNAME)))
	install := yes Y | sudo apt install
	deps := fd-find python3-pip nodejs npm
	os_name := linux
	setup_script := echo "Run installer for linux" && sudo apt-get update \
									&& yes Y | sudo apt install software-properties-common -y \
									&& yes Y | sudo add-apt-repository ppa:neovim-ppa/unstable -y \
									&& yes Y | sudo add-apt-repository ppa:aslatter/ppa -y \
									&& yes Y | sudo apt update -y
else
	install := brew install
	deps := fd python3 node
	os_name := darwin
	setup_script := echo "Run installer for macOs"
endif

go_version := 1.20.4

.PHONY: help nvim tmux go scripts
help: ## Please use os=mac if you using mac
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/\\$$//' | sed -e 's/##/\n\t\t/'

workspace:  ## Install nvim + tmux with configuration respectively.
workspace: setup nvim tmux alacritty cleanup

workspace-config: ## install config for workspace
workspace-config:
	chmod +x workspace.sh
	./workspace.sh

setup: ## Depend on the os params, os=mac will use brew, default is ubuntu apt-get
	test -d ./tmp || mkdir -p ./tmp
	@$(setup_script)
	@yes Y | $(install) $(deps)

cleanup: ## Clean up ./tmp folder
	test -d ./tmp && rm -rf ./tmp

nvim: ## Install neovim + all plugins
nvim: setup nvim-install nvim-config nvim-plug cleanup
nvim-install: ## Install neovim
	@$(install) neovim
	@$(install) ripgrep
	pip3 install pynvim
	curl -fLo ~/.local/share/nvim/site/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

nvim-config: ## Install neovim configuration, theme + exentsion + plugins, ...
	test -d ~/.config/nvim || mkdir -p ~/.config/nvim
	cp -r ./nvim/. ~/.config/nvim/

nvim-plug: ## Install neovim plugins
	nvim +PlugInstall +qall
	nvim -c 'CocInstall -sync|q'
	nvim --headless +VimspectorInstall +qall
	nvim +PlugClean +qall

tmux: ## Install tmux + configurations + plugins
tmux: setup tmux-install tmux-config cleanup
tmux-install: ## Install tmux
	@$(install) tmux
	tmux new -d
	test -d ~/.tmux/plugins/tpm || git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

tmux-config: ## Install tmux-config
	cp ./tmux/.tmux.conf ~/.tmux.conf
	tmux source ~/.tmux.conf
	~/.tmux/plugins/tpm/scripts/install_plugins.sh

go: ## Install go with version from go_verion, currently $(go_verion)
go: setup go-install cleanup
go-install:
	curl https://dl.google.com/go/go$(go_version).$(os_name)-amd64.tar.gz > ./tmp/go.tar.gz
	sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf ./tmp/go.tar.gz
	chmod +x ./go.sh
	./go.sh

aws-cli: ## Install aws-cli
aws-cli: setup aws-cli-install cleanup
aws-cli-install:
	cd tmp && curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
	cd tmp && unzip awscliv2.zip
	cd tmp && sudo ./aws/install

coc:
	nvim -c 'GoUpdateBinaries'

scripts: ## chmod +x for all scripts
	chmod -R +x ./scripts

alacritty: ## install alacritty and all config
alacritty: alacritty-install alacritty-config

alacritty-install: ## install alacritty
	@$(install) alacritty

alacritty-config: ## install alacritty
	test -d ~/.config/alacritty || mkdir -p ~/.config/alacritty
	cp -r ./alacritty/. ~/.config/alacritty/
