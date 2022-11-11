source ~/.config/nvim/plugins.vim
source ~/.config/nvim/editor.vim
source ~/.config/nvim/airline.vim
source ~/.config/nvim/coc.vim
source ~/.config/nvim/spector.vim

let $FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git || fdfind --type f --hidden --exclude .git' " Use fd as default search
let NERDTreeShowHidden=1
let g:NERDTreeWinSize=40
let NERDTreeIgnore=['\.DS_Store$', '\.git$'] " ignore files in nerd tree
let NERDSpaceDelims=1 " NerdComenter will have extra space after comment sign

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
" Go to the vertercal pane
map <C-h> <C-W>h
map <C-l> <C-W>l
" Preview window
command! -bang -nargs=? -complete=dir Files
    \ call fzf#vim#files(<q-args>, fzf#vim#with_preview({'options': ['--layout=reverse','--info=inline']}), <bang>0)

command! -bang -nargs=* Ag
  \ call fzf#vim#grep(
  \   'rg --column --line-number --no-heading --color=always --smart-case -- '.shellescape(<q-args>), 1,
  \   fzf#vim#with_preview(), <bang>0)

" hightlight current line
set cursorline

syntax on
colorscheme gruvbox
set nu " line numbers
set mouse=a
set shell=sh
