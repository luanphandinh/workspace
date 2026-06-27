UNAME := $(shell uname)
version_lock := ./version-lock.json
export PATH := $(HOME)/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$(HOME)/.local/bin:$(HOME)/bin:$(PATH)
ifneq (,$(findstring Linux,$(UNAME)))
	newsboat_config := ./newsboat/config.linux
	default_shell_install := sh ./scripts/configure-default-zsh.sh
else
	newsboat_config := ./newsboat/config.darwin
	default_shell_install := true
endif

is_wsl := $(shell test -r /proc/sys/kernel/osrelease && grep -qi microsoft /proc/sys/kernel/osrelease && echo 1 || echo 0)
alacritty_config_dir := $(HOME)/.config/alacritty
kitty_config_dir := $(HOME)/.config/kitty
codex_config_file := $(HOME)/.codex/config.toml
workspace_codex_config_file := ./codex/config.toml
ifeq ($(is_wsl),1)
windows_appdata := $(shell cmd.exe /C echo %APPDATA% 2>/dev/null | tr -d '\r')
alacritty_config_dir := $(shell wslpath -u '$(windows_appdata)')/alacritty
endif

export PATH := $(HOME)/go/bin:$(PATH)
MODE ?= locked
ifeq ($(MODE),latest)
	lazy_command := sync
else ifeq ($(MODE),locked)
	lazy_command := restore
else
$(error MODE must be locked or latest)
endif

.PHONY: help setup setup-nix setup-runtime nix-install update version-lock-update setup-deps nix-deps default-shell fonts-install newsboat-config nvim nvim-install nvim-config tree-sitter-cli-install nvim-native-treesitter-parsers-install nvim-lock nvim-test agent-clis verify-agent-clis codex-config tmux tmux-install tmux-config alacritty alacritty-install alacritty-config kitty kitty-install kitty-config csvlens-install go go-install gopls-install scripts skills-sync workspace-bin test version-lock-test mkws-test skills-hub-test codex-config-test agent-notification-hooks-test workspace-shell-test nix-test tmux-sidebar-test tmux-status-test alacritty-test kitty-test csvlens-test cleanup
help:
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/\\$$//' | sed -e 's/##/\n\t/'

setup:  ## Install all workspace tools, configs, and terminal agent CLIs using Nix.
setup: setup-deps
	$(MAKE) setup-runtime

setup-nix: setup ## Alias for setup

setup-runtime: ## Install workspace configs and terminal agent CLIs after deps are available
setup-runtime: default-shell fonts-install go-install gopls-install workspace-bin agent-clis codex-config nvim-install nvim-config tmux-install tmux-config alacritty-install alacritty-config kitty-install kitty-config csvlens-install newsboat-config cleanup

nix-install: ## Install Nix if missing
	sh ./scripts/install-nix.sh

update: version-lock-update ## Install all workspace tools while updating Neovim plugins and native treesitter locks to latest.
	$(MAKE) MODE=latest setup

version-lock-update: ## Update native treesitter versions in version-lock.json
	python3 ./scripts/update-version-lock.py $(version_lock)

setup-deps: ## Setup deps
setup-deps: nix-install
	. ./scripts/nix-profile.sh && nix --extra-experimental-features 'nix-command flakes' profile install .#workspace-deps

nix-deps: setup-deps ## Install common CLI deps with Nix

default-shell: ## Use zsh as the default login shell on Linux
	@$(default_shell_install)

fonts-install: ## Install terminal fonts
	sh ./scripts/install-nix-fonts.sh

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
	@nvim --version | head -n 1
	@rg --version | head -n 1

nvim-config: ## Install neovim configuration, theme + exentsion + plugins, ...
nvim-config: tree-sitter-cli-install nvim-native-treesitter-parsers-install
	test -d ~/.config/nvim || mkdir -p ~/.config/nvim
	rm -rf ~/.config/nvim/*
	cp -r ./nvim/. ~/.config/nvim/
	nvim --headless "+Lazy! $(lazy_command)" +qa

tree-sitter-cli-install: ## Install tree-sitter CLI for native parser builds
	@tree-sitter --version

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

codex-config: workspace-bin ## Merge workspace Codex config into the real Codex config
	merge_toml "$(codex_config_file)" "$(workspace_codex_config_file)"

tmux: ## Install tmux + configurations + plugins
tmux: setup-deps tmux-install tmux-config cleanup
tmux-install: ## Install tmux only, no config nor plugins
	@tmux -V
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
	@alacritty --version

alacritty-config: ## Install alacritty + config + theme
	test -d "$(alacritty_config_dir)" || mkdir -p "$(alacritty_config_dir)"
	cp -r ./alacritty/. "$(alacritty_config_dir)/"

kitty: ## Install kitty and config
kitty: kitty-install kitty-config

kitty-install: ## Install kitty only, no config
	@kitty --version

kitty-config: ## Install kitty config
	test -d "$(kitty_config_dir)" || mkdir -p "$(kitty_config_dir)"
	cp -r ./kitty/. "$(kitty_config_dir)/"
	kitten themes --dump-theme 'Gruvbox Dark' > "$(kitty_config_dir)/current-theme.conf"

csvlens-install: ## Install csvlens CSV viewer
	@csvlens --version | head -n 1

go: ## Install Go plus gopls
go: setup-deps go-install gopls-install cleanup
go-install:
	@go version

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
	@python3 ./bin/sync-agent-notification-hooks
	@sh ./bin/workspace-shell-sync ./shell/workspace.sh
	@sh ./bin/tmux-refresh-idle-zshrc

test: version-lock-test mkws-test skills-hub-test codex-config-test agent-notification-hooks-test workspace-shell-test nix-test tmux-sidebar-test tmux-status-test alacritty-test kitty-test csvlens-test ## Run smoke tests

version-lock-test: ## Run version-lock smoke tests
	sh ./scripts/version-lock-smoke-test.sh

mkws-test: ## Run mkws/mkwst/mkwsts smoke tests
	sh ./scripts/mkws-smoke-test.sh

skills-hub-test: ## Run skills-hub smoke tests
	sh ./scripts/skills-hub-smoke-test.sh

codex-config-test: ## Run Codex config smoke tests
	sh ./scripts/codex-config-smoke-test.sh

agent-notification-hooks-test: ## Run agent notification hook smoke tests
	sh ./scripts/agent-notification-hooks-smoke-test.sh

workspace-shell-test: ## Run workspace shell smoke tests
	sh ./scripts/workspace-shell-smoke-test.sh

nix-test: ## Run Nix smoke tests
	sh ./scripts/nix-smoke-test.sh

tmux-sidebar-test: ## Run tmux sidebar smoke tests
	sh ./scripts/tmux-sidebar-smoke-test.sh

tmux-status-test: ## Run tmux status smoke tests
	sh ./scripts/tmux-status-smoke-test.sh

alacritty-test: ## Run alacritty config/install smoke tests
	sh ./scripts/alacritty-smoke-test.sh

kitty-test: ## Run kitty config/install smoke tests
	sh ./scripts/kitty-smoke-test.sh

csvlens-test: ## Run csvlens install smoke tests
	sh ./scripts/csvlens-smoke-test.sh

cleanup: ## Clean up ./tmp folder
	test -d ./tmp && rm -rf ./tmp
