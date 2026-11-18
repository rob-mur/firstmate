" PROTOTYPE - throwaway. Loaded by prototype/board-editor/run with -S, from the board folder.
" In every markdown buffer of this session, gf and Enter on a line that names cards/<key>.md
" or pages/<id>.md open that file in a NEW TAB (:q closes it and returns). On any other line
" both keys do what they always do.

let s:board = getcwd()

function! s:Open(key) abort
  let l:target = matchstr(getline('.'), '\%(cards\|pages\)/[^ )\]]\+\.md')
  if l:target ==# ''
    execute 'normal!' (a:key ==# 'gf' ? 'gf' : "\<CR>")
    return
  endif
  execute 'tabedit' fnameescape(s:board . '/' . l:target)
endfunction

function! s:Map() abort
  nnoremap <buffer> <silent> gf <Cmd>call <SID>Open('gf')<CR>
  nnoremap <buffer> <silent> <CR> <Cmd>call <SID>Open('cr')<CR>
endfunction

augroup fm_board_prototype
  autocmd!
  autocmd BufEnter *.md call s:Map()
augroup END
call s:Map()
