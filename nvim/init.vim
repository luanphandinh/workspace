source ~/.config/nvim/plugins.vim
source ~/.config/nvim/editor.vim
source ~/.config/nvim/airline.vim
source ~/.config/nvim/coc.vim

let $FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git || fdfind --type f --hidden --exclude .git' " Use fd as default search
let NERDTreeShowHidden=1
let g:NERDTreeWinSize=40
let g:NERDTreeIgnore=['\.DS_Store$', '\.git$', 'node_modules$'] " ignore files in nerd tree
let NERDSpaceDelims=1 " NerdComenter will have extra space after comment sign

nmap <C-n> :NERDTreeToggle<CR>
nmap <C-m> :NERDTreeFind<CR>
" copy and paste to clipboard
" set clipboard=unnamed,unnamedplus
nmap <C-s> :w <CR>
" Open files search
nmap <C-p> :Files <CR>
nmap <C-f> :Ag <CR>
" Delete buffer
nmap <C-w> :bdelete<CR>
" Preview window
command! -bang -nargs=? -complete=dir Files
    \ call fzf#vim#files(<q-args>, fzf#vim#with_preview({'options': ['--layout=reverse','--info=inline']}), <bang>0)

command! -bang -nargs=* Ag
  \ call fzf#vim#grep(
  \   'rg --column --line-number --no-heading --color=always --smart-case -- '.shellescape(<q-args>), 1,
  \   fzf#vim#with_preview(), <bang>0)

" hightlight current line
set cursorline

" Toggle comments
vmap ++ <plug>NERDCommenterToggle
nmap ++ <plug>NERDCommenterToggle

syntax on
colorscheme gruvbox
set nu " line numbers
set mouse=a
set shell=sh
