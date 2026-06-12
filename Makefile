UNAME := $(shell uname)
ARCH := $(shell uname -m)
version_lock := ./version-lock.json
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
	newsboat_config := ./newsboat/config.linux
	nvim_linux_name := nvim-linux-x86_64
	install_nvim := curl -fsSL https://github.com/neovim/neovim/releases/download/stable/$(nvim_linux_name).tar.gz -o ./tmp/$(nvim_linux_name).tar.gz \
		&& sudo rm -rf /opt/$(nvim_linux_name) \
		&& sudo tar -C /opt -xzf ./tmp/$(nvim_linux_name).tar.gz \
		&& sudo ln -sf /opt/$(nvim_linux_name)/bin/nvim /usr/local/bin/nvim
	deps := fd-find python3-pip nodejs npm curl unzip fontconfig git build-essential
	optional_deps := jq btop
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
	newsboat_config := ./newsboat/config.darwin
	install_nvim := brew install neovim --HEAD
	deps := fd python3 node terminal-notifier
	optional_deps := jq btop newsboat
	os_name := darwin
	setup_script := echo "Run installer for macOs"
	fonts_install := brew install --cask font-fira-code-nerd-font
	mac_apps_install := brew install --cask alfred arc maccy
endif

is_wsl := $(shell test -r /proc/sys/kernel/osrelease && grep -qi microsoft /proc/sys/kernel/osrelease && echo 1 || echo 0)
alacritty_config_dir := $(HOME)/.config/alacritty
ifeq ($(is_wsl),1)
windows_appdata := $(shell cmd.exe /C echo %APPDATA% 2>/dev/null | tr -d '\r')
alacritty_config_dir := $(shell wslpath -u '$(windows_appdata)')/alacritty
fonts_install := sh ./scripts/install-windows-firacode-nerd-font.sh
endif

go_version = $(shell python3 ./scripts/version_lock.py get $(version_lock) go.version)
go_archive = go$(go_version).$(os_name)-$(go_arch).tar.gz
tree_sitter_cli_version = $(shell python3 ./scripts/version_lock.py get $(version_lock) tree_sitter_cli.version)
export PATH := /usr/local/go/bin:$(HOME)/go/bin:$(PATH)
MODE ?= locked
ifeq ($(MODE),latest)
	lazy_command := sync
else ifeq ($(MODE),locked)
	lazy_command := restore
else
$(error MODE must be locked or latest)
endif

.PHONY: help setup update version-lock-update setup-deps optional-deps newsboat-config nvim nvim-install nvim-config tree-sitter-cli-install nvim-native-treesitter-parsers-install nvim-lock nvim-test agent-clis verify-agent-clis tmux tmux-install tmux-config alacritty alacritty-install alacritty-config mac-apps go go-install gopls-install scripts skills-sync workspace-bin test version-lock-test mkws-test tmux-sidebar-test cleanup
help:
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/\\$$//' | sed -e 's/##/\n\t/'

setup:  ## Install all workspace tools, configs, and terminal agent CLIs.
setup: setup-deps go-install gopls-install workspace-bin agent-clis nvim-install nvim-config tmux-install tmux-config alacritty-install alacritty-config optional-deps newsboat-config mac-apps cleanup

update: setup-deps version-lock-update ## Install all workspace tools while updating Neovim plugins and native treesitter locks to latest.
	$(MAKE) MODE=latest setup

version-lock-update: ## Update native treesitter versions in version-lock.json
	python3 ./scripts/update-version-lock.py $(version_lock)

setup-deps: ## Setup deps
	test -d ./tmp || mkdir -p ./tmp
	@$(setup_script)
	@yes Y | $(install) $(deps)

optional-deps: ## Setup optional CLI deps
	@yes Y | $(install) $(optional_deps)

newsboat-config: ## Install Newsboat feed URLs from newsboat/urls.local
	test -d ./newsboat || mkdir -p ./newsboat
	test -f ./newsboat/urls.local
	test -f $(newsboat_config)
	test -d ~/.newsboat || mkdir -p ~/.newsboat
	cp $(newsboat_config) ~/.newsboat/config
	cp ./newsboat/urls.local ~/.newsboat/urls

nvim: ## Install neovim + all plugins
nvim: setup-deps nvim-install nvim-config cleanup
nvim-install: ## Install neovim only, no config
	@$(install_nvim)
	@$(install) ripgrep
	@nvim --version | head -n 1

nvim-config: ## Install neovim configuration, theme + exentsion + plugins, ...
nvim-config: tree-sitter-cli-install nvim-native-treesitter-parsers-install
	test -d ~/.config/nvim || mkdir -p ~/.config/nvim
	rm -rf ~/.config/nvim/*
	cp -r ./nvim/. ~/.config/nvim/
	nvim --headless "+Lazy! $(lazy_command)" +qa

tree-sitter-cli-install: ## Install tree-sitter CLI for native parser builds
	@if command -v tree-sitter >/dev/null 2>&1; then \
		version=$$(tree-sitter --version | awk '{print $$2}'); \
		if [ "$$version" = "$(tree_sitter_cli_version)" ]; then \
			tree-sitter --version; \
			exit 0; \
		fi; \
	fi; \
	npm install --global --prefix "$(HOME)/.local" tree-sitter-cli@$(tree_sitter_cli_version); \
	tree-sitter --version

nvim-native-treesitter-parsers-install: ## Build native Neovim treesitter parsers
	chmod +x ./scripts/install-native-treesitter-parsers.sh
	./scripts/install-native-treesitter-parsers.sh

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

tmux-config: workspace-bin ## Install tmux-config
	cp ./tmux/.tmux.conf ~/.tmux.conf
	tmux source ~/.tmux.conf
	~/bin/tmux-session-sidebar/reload
	~/.tmux/plugins/tpm/scripts/install_plugins.sh

alacritty: ## install alacritty and all config
alacritty: alacritty-install alacritty-config

alacritty-install: ## Install alacritty only, now config
	@$(install) alacritty

alacritty-config: ## Install alacritty + config + theme
	test -d "$(alacritty_config_dir)" || mkdir -p "$(alacritty_config_dir)"
	cp -r ./alacritty/. "$(alacritty_config_dir)/"
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
	find ~/bin -mindepth 1 -maxdepth 1 -exec rm -rf {} +
	cp -r ./bin/. ~/bin/
	find ~/bin -type f -exec chmod +x {} +
	@sh ./bin/workspace-shell-sync ./shell/workspace.sh
	@sh ./bin/tmux-refresh-idle-zshrc

test: version-lock-test mkws-test tmux-sidebar-test ## Run smoke tests

version-lock-test: ## Run version-lock smoke tests
	sh ./scripts/version-lock-smoke-test.sh

mkws-test: ## Run mkws/mkwst/mkwsts smoke tests
	sh ./scripts/mkws-smoke-test.sh

tmux-sidebar-test: ## Run tmux sidebar smoke tests
	sh ./scripts/tmux-sidebar-smoke-test.sh

cleanup: ## Clean up ./tmp folder
	test -d ./tmp && rm -rf ./tmp
