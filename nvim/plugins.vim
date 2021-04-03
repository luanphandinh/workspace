" Specify a directory for plugins
call plug#begin('~/.vim/plugged')

" Code server
Plug 'neoclide/coc.nvim', {'branch': 'release'}

" Useful for search
Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --all' }
Plug 'junegunn/fzf.vim'

" Tree view
Plug 'scrooloose/nerdtree'
Plug 'Xuyuanp/nerdtree-git-plugin'
Plug 'airblade/vim-gitgutter'
Plug 'tiagofumo/vim-nerdtree-syntax-highlight'

Plug 'fatih/vim-go', { 'do': ':GoUpdateBinaries' }

" Able to use Ctrl + h/j/k/l to move beteen panel
Plug 'christoomey/vim-tmux-navigator'

" Indent line plugin
Plug 'Yggdroot/indentLine'
Plug 'vim-airline/vim-airline'

" Icons
" Need to install 'font-firacode-nerd-font-mono'
Plug 'ryanoasis/vim-devicons'

" Theme
" Using iterm2 should also import gruvbox-dark.itermcolors from /theme
Plug 'morhetz/gruvbox'

" Commenter
Plug 'scrooloose/nerdcommenter'

" TS syntax
Plug 'HerringtonDarkholme/yats.vim'
Plug 'autozimu/LanguageClient-neovim', {
      \ 'branch': 'next',
      \ 'do': 'bash install.sh',
      \ }

" Initialize plugin system
call plug#end()
