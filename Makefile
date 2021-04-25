ifneq (,$(findstring mac,$(os)))
	install := brew install
	nvim_deps := fd
	os_name := darwin
	setup_script := echo "Run installer for macOs"
else
	install := sudo apt-get install
	nvim_deps := fd-find
	os_name := linux
	setup_script := echo "Run installer for linux" && sudo apt-get update
endif

go_version := 1.16.2

workspace: setup nvim-install nvim-config tmux-install tmux-config bash-config cleanup
go: setup go-install cleanup
setup:
	test -d ./tmp || mkdir -p ./tmp
	@$(setup_script)

cleanup:
	test -d ./tmp && rm -rf ./tmp

nvim-install:
	@$(install) neovim
	@$(install) $(nvim_deps)
	@$(install) ripgrep
	pip3 install pynvim
	curl -fLo ~/.local/share/nvim/site/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

nvim-config:
	test -d ~/.config/nvim || mkdir -p ~/.config/nvim
	cp -r ./nvim/. ~/.config/nvim/
	nvim +PlugInstall +qall
	nvim -c 'CocInstall -sync|q'
	nvim +PlugClean +qall

tmux-install:
	@$(install) tmux
	tmux new -d
	test -d ~/.tmux/plugins/tpm || git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

tmux-config:
	cp ./tmux/.tmux.conf ~/.tmux.conf
	tmux source ~/.tmux.conf
	~/.tmux/plugins/tpm/scripts/install_plugins.sh

bash-config:
	chmod +x ./statusline.sh
	./statusline.sh

nodejs:
	curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.37.2/install.sh | bash
	nvm install 14
	nvm use 14

go-install:
	curl https://dl.google.com/go/go$(go_version).$(os_name)-amd64.tar.gz > ./tmp/go.tar.gz
	sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf ./tmp/go.tar.gz
	chmod +x ./go.sh
	./go.sh

coc:
	nvim -c 'GoUpdateBinaries'
