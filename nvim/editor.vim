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

" Trim trailing whitespace.
autocmd BufWritePre * %s/\s\+$//e

" coc-prettier
command! -nargs=0 Prettier :CocCommand prettier.formatFile

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
nmap <C-n> :NERDTreeToggle<CR>
nmap <leader>m :NERDTreeFind<CR>
" copy and paste to clipboard
" set clipboard=unnamed,unnamedplus
nmap <C-s> :w <CR>

" Open files search
nmap <C-p> :Files <CR>
nmap <C-f> :Ag <CR>

" Delete buffer
nmap <leader>qq :bdelete<CR>
nmap <leader>qa :bufdo bd<CR>

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

" Preview window
command! -bang -nargs=? -complete=dir Files
    \ call fzf#vim#files(<q-args>, fzf#vim#with_preview({'options': ['--layout=reverse','--info=inline']}), <bang>0)

command! -bang -nargs=* Ag
  \ call fzf#vim#grep(
  \   'rg --column --line-number --no-heading --color=always --smart-case -- '.shellescape(<q-args>), 1,
  \   fzf#vim#with_preview(), <bang>0)

" hightlight current line
" set cursorline

syntax on
colorscheme gruvbox
set nu " line numbers
set mouse=a
set shell=sh
