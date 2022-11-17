let g:vimspector_enable_mappings = 'HUMAN'
nmap <leader>vl :call vimspector#Launch()<CR>
nmap <leader>vd :call spector#DebugCurrentGoTest()<CR>
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

func spector#DebugCurrentGoTest() abort
  let $TEST_CASE = spector#GetDebugTestName()
  call vimspector#LaunchWithConfigurations({
    \    'go-debug': {
    \      'adapter': 'delve',
    \      'filetypes': [ 'go' ],
    \      'configuration': {
    \        'request': 'launch',
    \        'program': '${fileDirname}',
    \        'mode': 'test',
    \        'args': [
    \                '-test.v',
    \                '-test.run',
    \                $TEST_CASE,
    \         ],
    \         'showLog': 'true',
    \         'dlvToolPath': '$GOPATH/bin/dlv'
    \       }
    \    }
    \ })
endfunction

function spector#GetDebugTestName() abort
  " search flags legend (used only)
  " 'b' search backward instead of forward
  " 'c' accept a match at the cursor position
  " 'n' do Not move the cursor
  " 'W' don't wrap around the end of the file
  "
  " for the full list
  " :help search
  let l:line = search('func \(Test\|Example\)', "bcnW")

  if l:line == 0
    return ''
  endif

  let l:decl = getline(l:line)
  return split(split(l:decl, " ")[1], "(")[0]
endfunction

