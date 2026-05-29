UNAME := $(shell uname)
ARCH := $(shell uname -m)
export PATH := $(HOME)/.local/bin:$(HOME)/bin:$(PATH)
ifeq ($(ARCH),arm64)
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
	deps := fd-find python3-pip nodejs npm curl
	os_name := linux
	fonts_install := sudo apt install fonts-firacode
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
	fonts_install := brew install --cask font-fira-code
	mac_apps_install := brew install --cask alfred maccy
endif

go_version := 1.25.9
go_archive := go$(go_version).$(os_name)-$(go_arch).tar.gz
export PATH := /usr/local/go/bin:$(HOME)/go/bin:$(PATH)

.PHONY: help workspace workspace-config setup nvim nvim-install nvim-config nvim-test agent-clis verify-agent-clis tmux tmux-install tmux-config alacritty alacritty-install alacritty-config mac-apps go go-install gopls-install aws-cli aws-cli-install scripts skills-sync install-workspace cleanup
help:
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/\\$$//' | sed -e 's/##/\n\t/'

workspace:  ## Install nvim, tmux, alacritty, and terminal agent CLIs.
workspace: setup agent-clis nvim tmux alacritty mac-apps cleanup

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
	@nvim --version | head -n 1

nvim-config: ## Install neovim configuration, theme + exentsion + plugins, ...
	test -d ~/.config/nvim || mkdir -p ~/.config/nvim
	rm -rf ~/.config/nvim/*
	cp -r ./nvim/. ~/.config/nvim/
	NVIM_INSTALL_TREESITTER=1 nvim --headless "+Lazy! sync" +qa

nvim-test: verify-agent-clis ## Run headless Neovim smoke tests
	GOWORK=off nvim --headless "+luafile scripts/nvim-smoke-test.lua" +qa

agent-clis: ## Install terminal agent CLIs used by Neovim
	chmod +x ./scripts/install-agent-clis.sh
	./scripts/install-agent-clis.sh install

verify-agent-clis: ## Verify terminal agent CLIs used by Neovim
	chmod +x ./scripts/install-agent-clis.sh
	./scripts/install-agent-clis.sh verify

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

mac-apps: ## Install macOS workspace GUI apps
	@$(mac_apps_install)

go: ## Install Go with version from go_version, currently $(go_version), plus gopls
go: setup go-install gopls-install cleanup
go-install:
	curl -fsSL https://dl.google.com/go/$(go_archive) -o ./tmp/go.tar.gz
	sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf ./tmp/go.tar.gz
	chmod +x ./go.sh
	./go.sh
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

aws-cli: ## Install aws-cli
aws-cli: setup aws-cli-install cleanup
aws-cli-install:
	cd tmp && curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
	cd tmp && unzip awscliv2.zip
	cd tmp && sudo ./aws/install

scripts: ## chmod +x for all scripts
	chmod -R +x ./scripts

skills-sync: ## Copy ./skills to ~/.claude/skills, ~/.cursor/skills, ~/.agents/skills (Codex CLI), ~/.hermes/skills
	chmod +x ./scripts/sync-skills.sh
	./scripts/sync-skills.sh

install-workspace: ## Install ./bin scripts to ~/bin and ensure ~/bin is on PATH in ~/.zshrc
	test -d ~/bin || mkdir -p ~/bin
	cp -r ./bin/. ~/bin/
	chmod +x ~/bin/*
	@touch ~/.zshrc
	@grep -qxF 'export PATH="$$HOME/bin:$$PATH"' ~/.zshrc || \
		(echo 'export PATH="$$HOME/bin:$$PATH"' >> ~/.zshrc && echo "added PATH export to ~/.zshrc")
	@alias_line="alias mcodex='codex -c '\''notify=[\"$$HOME/bin/codex-turn-ended-notify\"]'\'''" ; \
		if ! grep -qxF "$$alias_line" ~/.zshrc; then \
			tmp_file="$$(mktemp)" ; \
			grep -v '^alias mcodex=' ~/.zshrc > "$$tmp_file" || true ; \
			printf '%s\n' "$$alias_line" >> "$$tmp_file" ; \
			cat "$$tmp_file" > ~/.zshrc ; \
			rm -f "$$tmp_file" ; \
			echo "installed mcodex alias in ~/.zshrc" ; \
		fi

cleanup: ## Clean up ./tmp folder
	test -d ./tmp && rm -rf ./tmp
