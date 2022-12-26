" Specify a directory for plugins
call plug#begin('~/.vim/plugged')

" Code server
Plug 'neoclide/coc.nvim', {'branch': 'release'}

" Useful for search
Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --all' }
Plug 'junegunn/fzf.vim'

" Tree view
Plug 'scrooloose/nerdtree'
Plug 'airblade/vim-gitgutter'

Plug 'vim-airline/vim-airline'

" Theme
" Using iterm2 should also import gruvbox-dark.itermcolors from /theme
Plug 'morhetz/gruvbox'

" Vim surround
Plug 'tpope/vim-surround'
Plug 'tpope/vim-commentary'

" Vim go
Plug 'fatih/vim-go'

" For debugging code
Plug 'puremourning/vimspector'

" Initialize plugin system
call plug#end()
