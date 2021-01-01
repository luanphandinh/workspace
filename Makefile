mac: nvim-install-mac nvim-config tmux-mac tmux-config
ubuntu: nvim-install-ubuntu nvim-config tmux-ubuntu tmux-config

nvim: nvim-install-mac nvim-config
nvim-ubuntu: nvim-install-ubuntu nvim-config
nvim-install-mac:
	brew install neovim
	brew install fd
	brew install ripgrep
	curl -fLo ~/.local/share/nvim/site/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

nvim-install-ubuntu:
	sudo apt-get install neovim
	sudo apt-get install fd-find
	sudo apt-get install ripgrep
	curl -fLo ~/.local/share/nvim/site/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

nvim-config:
	test -d ~/.config/nvim || mkdir -p ~/.config/nvim
	cp -r ./nvim/. ~/.config/nvim/
	nvim +PlugInstall +qall
	nvim -c 'CocInstall -sync|q'

tmux: tmux-mac tmux-config
tmux-mac:
	brew install tmux
	tmux new -d
	git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
tmux-ubuntu:
	sudo apt-get update
	sudo apt-get install tmux
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
