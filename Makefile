ifneq (,$(findstring mac,$(OS)))
	install := brew install
	setup_script := echo "Run installer for macOs"
else
	install := sudo apt-get install
	setup_script := echo "Run installer for linux" && sudo apt-get update
endif

workspace: setup nvim-install nvim-config tmux-install tmux-config
setup:
	@$(setup_script)

nvim-install:
	@$(install) neovim
	@$(install) fd || @$(install) fd-find
	@$(install) ripgrep
	curl -fLo ~/.local/share/nvim/site/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

nvim-config:
	test -d ~/.config/nvim || mkdir -p ~/.config/nvim
	cp -r ./nvim/. ~/.config/nvim/
	nvim +PlugInstall +qall
	nvim -c 'CocInstall -sync|q'

tmux-install:
	@$(install) install tmux
	tmux new -d
	git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
tmux-config:
	cp ./tmux/.tmux.conf ~/.tmux.conf
	tmux source ~/.tmux.conf
	~/.tmux/plugins/tpm/scripts/install_plugins.sh

nodejs:
	curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.37.2/install.sh | bash
	nvm install 14
	nvm use 14
