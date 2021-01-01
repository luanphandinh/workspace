" Most of the time using space for indent
set smarttab
set tabstop=2
set shiftwidth=2
set expandtab

" specific filetypes
autocmd FileType javascript setlocal expandtab! shiftwidth=4 tabstop=4
autocmd FileType typescript setlocal expandtab! shiftwidth=4 tabstop=4
autocmd FileType graphql setlocal expandtab! shiftwidth=4 tabstop=4

autocmd FileType php setlocal expandtab! shiftwidth=4 tabstop=4

" GO code will indent with tab size 8
autocmd FileType go setlocal expandtab! shiftwidth=8 tabstop=8

" Trim trailing whitespace.
autocmd BufWritePre * %s/\s\+$//e

" coc-prettier
command! -nargs=0 Prettier :CocCommand prettier.formatFile

