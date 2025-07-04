UNAME := $(shell uname)
ifneq (,$(findstring Linux,$(UNAME)))
	install := sudo apt install
	install_nvim := sudo apt install neovim
	deps := fd-find python3-pip nodejs npm
	os_name := linux
	fonts_install := sudo apt install fonts-firacode
	setup_script := echo "Run installer for linux" && sudo apt-get update \
									&& sudo apt install software-properties-common -y \
									&& sudo add-apt-repository ppa:neovim-ppa/stable -y \
									&& sudo add-apt-repository ppa:aslatter/ppa -y \
									&& sudo apt update -y
else
	install := brew install
	install_nvim := brew install neovim --HEAD
	deps := fd python3 node
	os_name := darwin
	setup_script := echo "Run installer for macOs"
	fonts_install := brew install --cask font-fira-code
endif

go_version := 1.20.4

.PHONY: help nvim tmux go scripts
help:
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/\\$$//' | sed -e 's/##/\n\t/'

workspace:  ## Install nvim + tmux + alacritty with configuration respectively.
workspace: setup nvim tmux alacritty cleanup

workspace-config: ## Install config for workspace
workspace-config:
	chmod +x workspace.sh
	./workspace.sh

setup: ## Setup deps
	test -d ./tmp || mkdir -p ./tmp
	@$(setup_script)
	@yes Y | $(install) $(deps)

nvim: ## Install neovim + all plugins
nvim: setup nvim-install nvim-config cleanup
nvim-install: ## Install neovim only, no config
	@$(install_nvim)
	@$(install) ripgrep

nvim-config: ## Install neovim configuration, theme + exentsion + plugins, ...
	test -d ~/.config/nvim || mkdir -p ~/.config/nvim
	rm -rf ~/.config/nvim/*
	cp -r ./nvim/. ~/.config/nvim/
	nvim --headless +"autocmd User PackerComplete quitall" +PackerSync
	# nvim --headless +"autocmd User PackerComplete quitall" +PackerClean

tmux: ## Install tmux + configurations + plugins
tmux: setup tmux-install tmux-config cleanup
tmux-install: ## Install tmux only, no config nor plugins
	@$(install) tmux
	tmux new -d
	test -d ~/.tmux/plugins/tpm || git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

tmux-config: ## Install tmux-config
	cp ./tmux/.tmux.conf ~/.tmux.conf
	tmux source ~/.tmux.conf
	~/.tmux/plugins/tpm/scripts/install_plugins.sh

alacritty: ## install alacritty and all config
alacritty: alacritty-install alacritty-config

alacritty-install: ## Install alacritty only, now config
	@$(install) alacritty

alacritty-config: ## Install alacritty + config + theme
	test -d ~/.config/alacritty || mkdir -p ~/.config/alacritty
	cp -r ./alacritty/. ~/.config/alacritty/
	@$(fonts_install)

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

scripts: ## chmod +x for all scripts
	chmod -R +x ./scripts

cleanup: ## Clean up ./tmp folder
	test -d ./tmp && rm -rf ./tmp

