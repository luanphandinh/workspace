UNAME := $(shell uname)
export PATH := $(HOME)/.local/bin:$(HOME)/bin:$(HOME)/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$(HOME)/go/bin:$(PATH)
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

lazy_command ?= restore

.PHONY: help setup setup-runtime nix-install update upgrade-deps setup-deps apps default-shell fonts-install newsboat-config nvim nvim-config nvim-lock agent-clis codex-config tmux tmux-config alacritty alacritty-config kitty kitty-config scripts skills-sync workspace-bin cleanup
help:
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/\\$$//' | sed -e 's/##/\n\t/'

setup:  ## Install all workspace tools, configs, and terminal agent CLIs using Nix.
setup: setup-deps
	$(MAKE) setup-runtime

setup-runtime: ## Install workspace configs and terminal agent CLIs after deps are available
setup-runtime: default-shell fonts-install workspace-bin codex-config nvim-config tmux-config alacritty-config kitty-config newsboat-config cleanup agent-clis

nix-install: ## Install Nix if missing
	sh ./scripts/install-nix.sh

update: upgrade-deps ## Update Nix dependencies, workspace runtime, and Neovim plugin lockfile.
	$(MAKE) lazy_command=sync setup-runtime
	$(MAKE) nvim-lock

upgrade-deps: nix-install ## Update Nix dependency lockfile and install the updated dependency profile.
	. ./scripts/nix-profile.sh && nix --extra-experimental-features 'nix-command flakes' flake update
	$(MAKE) setup-deps

setup-deps: ## Setup deps
setup-deps: nix-install
	test -f flake.lock
	. ./scripts/nix-profile.sh && \
		if nix --extra-experimental-features 'nix-command flakes' profile list | awk '/^Name:.*workspace-deps/ { found = 1 } END { exit !found }'; then \
			nix --extra-experimental-features 'nix-command flakes' profile upgrade --no-update-lock-file workspace-deps; \
		else \
			nix --extra-experimental-features 'nix-command flakes' profile add --no-update-lock-file "path:$(CURDIR)#workspace-deps"; \
		fi

apps: ## Install macOS GUI apps via Homebrew cask
ifeq ($(UNAME),Darwin)
	@if ! command -v brew >/dev/null 2>&1; then \
		echo "apps: Homebrew is required on macOS" >&2; \
		exit 1; \
	fi
	@for app in maccy alfred arc; do brew install --cask "$$app" || true; done
else
	@echo "apps: skipped; macOS-only"
endif

default-shell: ## Use zsh as the default login shell on Linux
	@$(default_shell_install)

fonts-install: ## Register Nix-installed terminal fonts with the OS
	sh ./scripts/install-nix-fonts.sh

newsboat-config: ## Install Newsboat feed URLs from newsboat/urls.local
	test -d ./newsboat || mkdir -p ./newsboat
	test -f ./newsboat/urls.local
	test -f $(newsboat_config)
	test -d ~/.newsboat || mkdir -p ~/.newsboat
	cp $(newsboat_config) ~/.newsboat/config
	cp ./newsboat/urls.local ~/.newsboat/urls

nvim: ## Install neovim + all plugins
nvim: setup-deps nvim-config cleanup

nvim-config: ## Install neovim configuration, theme + exentsion + plugins, ...
	test -d ~/.config/nvim || mkdir -p ~/.config/nvim
	rm -rf ~/.config/nvim/*
	cp -r ./nvim/. ~/.config/nvim/
	nvim --headless "+Lazy! $(lazy_command)" +qa

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
tmux: setup-deps tmux-config cleanup

tmux-config: workspace-bin ## Install tmux-config
	@if ! tmux has-session 2>/dev/null; then \
		env -u NO_COLOR tmux new-session -d -x 80 -y 24; \
	fi
	test -d ~/.tmux/plugins/tpm || git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
	cp ./tmux/.tmux.conf ~/.tmux.conf
	tmux source ~/.tmux.conf
	~/bin/tmux-session-sidebar/reload
	~/.tmux/plugins/tpm/scripts/install_plugins.sh

alacritty: ## install alacritty and all config
alacritty: alacritty-config

alacritty-config: ## Install alacritty + config + theme
	test -d "$(alacritty_config_dir)" || mkdir -p "$(alacritty_config_dir)"
	cp -r ./alacritty/. "$(alacritty_config_dir)/"

kitty: ## Install kitty and config
kitty: kitty-config

kitty-config: ## Install kitty config
	test -d "$(kitty_config_dir)" || mkdir -p "$(kitty_config_dir)"
	cp -r ./kitty/. "$(kitty_config_dir)/"
	kitten themes --dump-theme 'Gruvbox Dark' > "$(kitty_config_dir)/current-theme.conf"

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
	@sh ./bin/workspace-shell-sync
	@sh ./bin/tmux-refresh-idle-zshrc

test: mkws-test skills-hub-test cmds-hub-test codex-config-test agent-notification-hooks-test workspace-shell-test nix-test tmux-sidebar-test ## Run smoke tests

mkws-test: ## Run mkws/meta-hub smoke tests
	sh ./scripts/mkws-smoke-test.sh

skills-hub-test: ## Run skills-hub smoke tests
	sh ./scripts/skills-hub-smoke-test.sh

cmds-hub-test: ## Run cmds-hub smoke tests
	sh ./scripts/cmds-hub-smoke-test.sh

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

cleanup: ## Clean up ./tmp folder
	rm -rf ./tmp
