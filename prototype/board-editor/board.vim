" PROTOTYPE - loaded by prototype/board-editor/run when the editor is vim or nvim.
" Enter, gf and gx on a line open what it names: a board file (cards/, pages/ or reports/) in a new
" tab, a web address through the opener ($TUI_BOARD_OPENER, else xdg-open), and a report path
" (data/<task>/report.md) as the report's copy under reports/<home>/ in a new tab.
let s:board = getcwd()
let s:file = '\%(cards\|pages\|reports\)/[^ )\]`]\+\.\%(md\|txt\)'
let s:url = 'https\?://[^ 	<>"`]\+'
let s:data = '\%(/[[:alnum:]_.-]\+\)*/\?data/[[:alnum:]_.-]\+\%(/[[:alnum:]_.-]\+\)*\.\%(md\|txt\)'

" Every match of a pattern on a line, as [start, end, text] (end exclusive, 0-based).
function! s:Matches(line, pat) abort
  let l:out = []
  let l:at = 0
  while 1
    let [l:text, l:start, l:end] = matchstrpos(a:line, a:pat, l:at)
    if l:start < 0
      return l:out
    endif
    call add(l:out, [l:start, l:end, l:text])
    let l:at = l:end > l:start ? l:end : l:start + 1
  endwhile
endfunction

" The thing to open on the current line: the match under the cursor, else the first one,
" with a board file before a web address before a report path.
function! s:Target() abort
  let l:line = getline('.')
  let l:col = col('.') - 1
  let l:all = []
  for [l:kind, l:pat] in [['file', s:file], ['url', s:url], ['data', s:data]]
    for l:m in s:Matches(l:line, l:pat)
      if l:kind ==# 'data' && l:m[0] > 0 && l:line[l:m[0] - 1] =~# '[[:alnum:]_/.~-]'
        continue
      endif
      if l:kind ==# 'data' && !empty(filter(copy(l:all), 'v:val[1][0] <= l:m[0] && l:m[0] < v:val[1][1]'))
        continue  " the data/ part of a board file or web address
      endif
      call add(l:all, [l:kind, l:m])
    endfor
  endfor
  for l:t in l:all
    if l:t[1][0] <= l:col && l:col < l:t[1][1]
      return [l:t[0], l:t[1][2]]
    endif
  endfor
  return empty(l:all) ? ['', ''] : [l:all[0][0], l:all[0][1][2]]
endfunction

function! s:OpenUrl(url) abort
  let l:url = substitute(a:url, '[.,;:)\]]\+$', '', '')
  let l:opener = empty($TUI_BOARD_OPENER) ? 'xdg-open' : $TUI_BOARD_OPENER
  call system(l:opener . ' ' . shellescape(l:url) . ' >/dev/null 2>&1')
  echo 'Opened ' . l:url
endfunction

" The board copy of a report path: the reports/<home>/ copy this buffer links, then the one in
" this report's own home, then the only copy in any home.
function! s:Report(path) abort
  let l:rel = a:path =~# '^/' ? matchstr(a:path, 'data/.*$') : a:path
  let l:named = matchstr(join(getline(1, '$'), "\n"), 'reports/[^/ ]\+/' . escape(l:rel, '.\[]*~'))
  if l:named !=# '' && filereadable(s:board . '/' . l:named)
    return l:named
  endif
  let l:here = matchstr(expand('%:p'), '^' . escape(s:board, '.\[]*~') . '/\zsreports/[^/]\+/')
  if l:here !=# '' && filereadable(s:board . '/' . l:here . l:rel)
    return l:here . l:rel
  endif
  let l:copies = glob(s:board . '/reports/*/' . l:rel, 0, 1)
  return len(l:copies) == 1 ? l:copies[0][len(s:board) + 1:] : ''
endfunction

function! s:Open(key) abort
  let [l:kind, l:text] = s:Target()
  if l:kind ==# 'url'
    call s:OpenUrl(l:text)
  elseif l:kind ==# 'file'
    execute 'tabedit' fnameescape(s:board . '/' . l:text)
  elseif l:kind ==# 'data'
    let l:copy = s:Report(l:text)
    if l:copy ==# ''
      echo 'No copy of ' . l:text . ' on the board: run the board again to copy cited reports.'
    else
      execute 'tabedit' fnameescape(s:board . '/' . l:copy)
    endif
  elseif a:key ==# 'gx'
    echo 'No web address on this line.'
  else
    execute 'normal!' (a:key ==# 'gf' ? 'gf' : "\<CR>")
  endif
endfunction

function! s:Map() abort
  nnoremap <buffer> <silent> gf <Cmd>call <SID>Open('gf')<CR>
  nnoremap <buffer> <silent> gx <Cmd>call <SID>Open('gx')<CR>
  nnoremap <buffer> <silent> <CR> <Cmd>call <SID>Open('cr')<CR>
endfunction
augroup fm_board_prototype
  autocmd!
  autocmd BufEnter *.md call s:Map()
augroup END
call s:Map()
