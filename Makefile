UNAME := $(shell uname)
ARCH := $(shell uname -m)
export PATH := $(HOME)/.local/bin:$(HOME)/bin:$(PATH)
ifeq ($(UNAME),Darwin)
	go_arch := amd64
else ifeq ($(ARCH),arm64)
	go_arch := arm64
else ifeq ($(ARCH),aarch64)
	go_arch := arm64
else
	go_arch := amd64
endif
ifneq (,$(findstring Linux,$(UNAME)))
	install := sudo apt install
	nvim_linux_name := nvim-linux-x86_64
	install_nvim := curl -fsSL https://github.com/neovim/neovim/releases/download/stable/$(nvim_linux_name).tar.gz -o ./tmp/$(nvim_linux_name).tar.gz \
		&& sudo rm -rf /opt/$(nvim_linux_name) \
		&& sudo tar -C /opt -xzf ./tmp/$(nvim_linux_name).tar.gz \
		&& sudo ln -sf /opt/$(nvim_linux_name)/bin/nvim /usr/local/bin/nvim
	deps := fd-find python3-pip nodejs npm curl unzip fontconfig
	os_name := linux
	fonts_install := test -f "$(HOME)/.local/share/fonts/FiraCodeNerdFont-Regular.ttf" || (mkdir -p "$(HOME)/.local/share/fonts" ./tmp \
		&& curl -fsSL https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip -o ./tmp/FiraCode.zip \
		&& unzip -o -q ./tmp/FiraCode.zip "FiraCodeNerdFont*.ttf" -d "$(HOME)/.local/share/fonts" \
		&& fc-cache -f "$(HOME)/.local/share/fonts")
	mac_apps_install := true
	setup_script := echo "Run installer for linux" && sudo apt-get update \
									&& sudo apt install software-properties-common -y \
									&& sudo add-apt-repository ppa:aslatter/ppa -y \
									&& sudo apt update -y
else
	install := brew install
	install_nvim := brew install neovim --HEAD
	deps := fd python3 node glow terminal-notifier
	os_name := darwin
	setup_script := echo "Run installer for macOs"
	fonts_install := brew install --cask font-fira-code-nerd-font
	mac_apps_install := brew install --cask alfred arc maccy
endif

go_version := 1.25.9
go_archive := go$(go_version).$(os_name)-$(go_arch).tar.gz
export PATH := /usr/local/go/bin:$(HOME)/go/bin:$(PATH)
MODE ?= locked
ifeq ($(MODE),latest)
	lazy_command := sync
else ifeq ($(MODE),locked)
	lazy_command := restore
else
$(error MODE must be locked or latest)
endif

.PHONY: help setup update setup-deps nvim nvim-install nvim-config nvim-lock nvim-test agent-clis verify-agent-clis tmux tmux-install tmux-config alacritty alacritty-install alacritty-config mac-apps go go-install gopls-install scripts skills-sync workspace-bin cleanup
help:
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/\\$$//' | sed -e 's/##/\n\t/'

setup:  ## Install all workspace tools, configs, and terminal agent CLIs.
setup: setup-deps go-install gopls-install workspace-bin agent-clis nvim-install nvim-config tmux-install tmux-config alacritty-install alacritty-config mac-apps cleanup

update: ## Install all workspace tools while updating Neovim plugins to latest.
	$(MAKE) MODE=latest setup

setup-deps: ## Setup deps
	test -d ./tmp || mkdir -p ./tmp
	@$(setup_script)
	@yes Y | $(install) $(deps)

nvim: ## Install neovim + all plugins
nvim: setup-deps nvim-install nvim-config cleanup
nvim-install: ## Install neovim only, no config
	@$(install_nvim)
	@$(install) ripgrep
	@nvim --version | head -n 1

nvim-config: ## Install neovim configuration, theme + exentsion + plugins, ...
	test -d ~/.config/nvim || mkdir -p ~/.config/nvim
	rm -rf ~/.config/nvim/*
	cp -r ./nvim/. ~/.config/nvim/
	NVIM_INSTALL_TREESITTER=1 nvim --headless "+Lazy! $(lazy_command)" +qa

nvim-lock: ## Refresh nvim/lazy-lock.json from the installed Neovim config.
	cp ~/.config/nvim/lazy-lock.json ./nvim/lazy-lock.json

nvim-test: verify-agent-clis ## Run headless Neovim smoke tests
	GOWORK=off nvim --headless "+luafile scripts/nvim-smoke-test.lua" +qa

agent-clis: ## Install terminal agent CLIs used by Neovim
	chmod +x ./scripts/install-agent-clis.sh
	./scripts/install-agent-clis.sh install

verify-agent-clis: ## Verify terminal agent CLIs used by Neovim
	chmod +x ./scripts/install-agent-clis.sh
	./scripts/install-agent-clis.sh verify

tmux: ## Install tmux + configurations + plugins
tmux: setup-deps tmux-install tmux-config cleanup
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

mac-apps: ## Install macOS workspace GUI apps
	@$(mac_apps_install)

go: ## Install Go with version from go_version, currently $(go_version), plus gopls
go: setup-deps go-install gopls-install cleanup
go-install:
	curl -fsSL https://dl.google.com/go/$(go_archive) -o ./tmp/go.tar.gz
	sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf ./tmp/go.tar.gz
	@if [ -n "$${GITHUB_PATH:-}" ]; then \
		printf '%s\n' "/usr/local/go/bin" "$(HOME)/go/bin" >> "$$GITHUB_PATH" ; \
	fi

gopls-install:
	@if command -v gopls >/dev/null 2>&1; then \
		gopls version | head -n 1 ; \
	else \
		GOWORK=off go install golang.org/x/tools/gopls@latest ; \
		gopls version | head -n 1 ; \
	fi

scripts: ## chmod +x for all scripts
	chmod -R +x ./scripts

skills-sync: ## Install ./skills to all supported local AI agents via npx skills
	chmod +x ./scripts/sync-skills.sh
	./scripts/sync-skills.sh

workspace-bin: ## Install ./bin scripts and workspace shell setup
	test -d ~/bin || mkdir -p ~/bin
	cp -r ./bin/. ~/bin/
	chmod +x ~/bin/*
	@for profile in "$$HOME/.zshrc" "$$HOME/.bashrc" "$$HOME/.profile"; do \
		touch "$$profile" ; \
		while IFS= read -r line || [ -n "$$line" ]; do \
			[ -n "$$line" ] || continue ; \
			grep -qxF "$$line" "$$profile" || { printf '%s\n' "$$line" >> "$$profile" ; echo "added to $$profile: $$line" ; } ; \
		done < ./shell/workspace.sh ; \
	done

cleanup: ## Clean up ./tmp folder
	test -d ./tmp && rm -rf ./tmp
