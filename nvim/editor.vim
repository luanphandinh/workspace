" Most of the time using space for indent
set smarttab
set tabstop=2
set shiftwidth=2
set expandtab

" specific filetypes
" autocmd FileType javascript setlocal expandtab! shiftwidth=4 tabstop=4
" autocmd FileType typescript setlocal expandtab! shiftwidth=4 tabstop=4
autocmd FileType graphql setlocal expandtab! shiftwidth=4 tabstop=4

autocmd FileType php setlocal expandtab! shiftwidth=4 tabstop=4

" GO code will indent with tab size 8
autocmd FileType go setlocal expandtab! shiftwidth=8 tabstop=8

autocmd FileType yml setlocal expandtab shiftwidth=2 tabstop=2

" Trim trailing whitespace.
autocmd BufWritePre * %s/\s\+$//e

" coc-prettier
" command! -nargs=0 Prettier :CocCommand prettier.formatFile

" fold
nmap <leader>fa :setlocal foldmethod=indent<CR>

" vim-go
" test current go func
nmap <leader>gt :GoTestFunc<CR>
set splitright
let g:go_term_enabled = 1
let g:go_term_mode = "vsplit"
let g:go_term_close_on_exit = 0
" end vim-go

" Open, hide the nerd tree
nmap <leader>n :NERDTreeToggle<CR>
nmap <leader>m :NERDTreeFind<CR>
" copy and paste to clipboard
" set clipboard=unnamed,unnamedplus
nmap <C-s> :w <CR>

" Open files search
nmap <C-p> :Telescope find_files<CR>
nmap <C-f> :Telescope live_grep<CR>

" Delete buffer
nmap <leader>qq :bdelete<CR>
nnoremap <leader>qa :%bd<CR>

" Go to the next buffer
nmap <C-k> :bn<CR>
" Go the previous buffer
nmap <C-j> :bp<CR>

nmap <F5> :Format<CR>
" Go to the vertercal/horizontal pane
map <C-h> <C-W>h
map <C-l> <C-W>l
map <C-Left> <C-W>j
map <C-Right> <C-W>k

" hightlight current line
set cursorline
" auto central after jump definition
" nnoremap <cmd>lua vim.lsp.buf.definition()<CR>zz

syntax on
colorscheme gruvbox
set nu " line numbers
set mouse=a
set shell=sh

let $FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git || fdfind --type f --hidden --exclude .git' " Use fd as default search
let NERDTreeShowHidden=1
let g:NERDTreeWinSize=40
let NERDTreeIgnore=['\.DS_Store$', '\.git$'] " ignore files in nerd tree
let NERDSpaceDelims=1 " NerdComenter will have extra space after comment sign
