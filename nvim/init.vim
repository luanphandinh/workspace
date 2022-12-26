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
" let g:go_gopls_options = ['-remote=auto']
