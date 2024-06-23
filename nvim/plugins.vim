" Specify a directory for plugins
call plug#begin('~/.vim/plugged')

" Code server
" Plug 'neoclide/coc.nvim', {'branch': 'release'}
Plug 'neovim/nvim-lspconfig'

" Autocompletion plugin
Plug 'hrsh7th/cmp-nvim-lsp'
Plug 'hrsh7th/cmp-buffer'
Plug 'hrsh7th/cmp-path'
Plug 'hrsh7th/cmp-cmdline'
Plug 'hrsh7th/nvim-cmp'

" For vsnip users.
Plug 'hrsh7th/cmp-vsnip'
Plug 'hrsh7th/vim-vsnip'

" Useful for search
Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-telescope/telescope.nvim'

" Tree view
Plug 'scrooloose/nerdtree'
Plug 'airblade/vim-gitgutter'

Plug 'vim-airline/vim-airline'

" Theme
" Using iterm2 should also import gruvbox-dark.itermcolors from /theme
Plug 'morhetz/gruvbox'

" Vim surround
Plug 'windwp/nvim-autopairs'
Plug 'tpope/vim-commentary'

" Vim go
Plug 'fatih/vim-go'

" For debugging code
Plug 'puremourning/vimspector'

" Initialize plugin system
call plug#end()
