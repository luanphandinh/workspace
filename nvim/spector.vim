let g:vimspector_enable_mappings = 'HUMAN'
let g:vimspector_configurations = {
\    'go-debug': {
\      'adapter': 'delve',
\      'configuration': {
\        'request': 'launch',
\        'program': '${fileDirname}',
\        'mode': 'test',
\         'args': [
\                '-test.v',
\                '-test.run',
\                '$TEST_CASE'
\            ],
\            'showLog': 'true',
\        'dlvToolPath': '$GOPATH/bin/dlv'     }
\    }
\ }

nmap <leader>vl :call vimspector#Launch()<CR>
nmap <leader>vd :call vimspector#LaunchWithSettings( #{ configuration: 'go-debug' } )<CR>
nmap <leader>vr :VimspectorReset<CR>
nmap <leader>ve :VimspectorEval
nmap <leader>vw :VimspectorWatch
nmap <leader>vo :VimspectorShowOutput
nmap <leader>vi <Plug>VimspectorBalloonEval
xmap <leader>vi <Plug>VimspectorBalloonEval

" for normal mode - the word under the cursor
nmap <Leader>di <Plug>VimspectorBalloonEval
" for visual mode, the visually selected text
xmap <Leader>di <Plug>VimspectorBalloonEval

let g:vimspector_install_gadgets = ['delve']
