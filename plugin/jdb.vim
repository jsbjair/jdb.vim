function! FocusMyConsole(winOp, bufName)
    let bn = bufwinnr(a:bufName)
    if bn == -1
        execute "silent ".a:winOp." new ".a:bufName
        setlocal enc=utf-8
        setlocal buftype=nofile
        setlocal nobuflisted
        setlocal noswapfile
        setlocal noreadonly
        setlocal ff=unix
        setlocal nolist
        map <buffer> q :q<CR>
        map <buffer> <CR> :call ch_sendraw(t:jdb_ch, getline(".")."\n")<CR>
    else
        execute bn."wincmd w"
    endif
endfunction

function! s:GetBreakPointHit(str)
    let ff = matchlist(a:str, '\(Step completed\|Breakpoint hit\): "thread=\(\S\+\)", \(\S\+\)\.\(\S\+\)(), line=\(\d\+\) bci=\(\d\+\)')
    if len(ff) > 0
        if has_key(t:mapClassFile, ff[3])
            let t:bpFile = t:mapClassFile[ff[3]]
        else
            let t:bpFile = substitute(ff[3], '\.', '/', 'g').".java"
        endif
        let t:bpLine = ff[5]
        return 1
    endif
    return 0
endfunction

function! s:HitBreakPoint(str)
    if !exists("t:bpFile")
        return 0
    endif
    for dir in t:sourcepaths
        if filereadable(dir.t:bpFile)
            let fl = readfile(dir.t:bpFile)
            if len(fl) > t:bpLine && stridx(a:str, fl[t:bpLine - 1]) > 0
                let t:bpFile = dir.t:bpFile
                silent exec "sign unplace ".t:cursign
                silent exec "edit ".t:bpFile
                silent exec 'sign place '.t:cursign.' name=current line='.t:bpLine.' file='.t:bpFile
                exec t:bpLine
                redraw!
                return 1
            endif
        end
    endfor
    return 0
endfunction

function! s:NothingSuspended(str)
    if a:str == "> Nothing suspended."
        silent exec "sign unplace ".t:cursign
        call <SID>PlaceBreakSigns()
        return 1
    endif
    return 0
endfunction

function! JdbErrHandler(channel, msg)
    echo a:msg
endfunction

function! JdbExitHandler(channel, msg)
    call OnQuitJDB()
endfunction

function! JdbOutHandler(channel, msg)
    if !<SID>GetBreakPointHit(a:msg) && !<SID>HitBreakPoint(a:msg) && !<SID>NothingSuspended(a:msg)
        echo a:msg
    endif
endfunction

let t:sourcepaths = [""]
let t:mapClassFile = {}
function! s:GetClassNameFromFile(fn, ln)
    let lines = readfile(a:fn)
    let lpack = 0
    let packageName = ""

    let l:ln = len(lines) - 1

    while packageName == "" && lpack < l:ln
        let ff = matchlist(lines[lpack], '^package\s\+\(\S\+\);\r*$')
        if len(ff) > 1
            let packageName = ff[1]
        endif
        let lpack = lpack + 1
    endwhile

    let lclass = lpack
    let mainClassName = ""
    while mainClassName == "" && l:ln > lclass
        let ff = matchlist(lines[lclass],  '^\%(public\s\+\)\?\%(abstract\s\+\)\?class\s\+\(\w\+\)')
        if len(ff) > 1
            let mainClassName = ff[1]
        endif
        let lclass = lclass + 1
    endwhile

    if len(packageName) > 1
        let mainClassName = packageName.".".mainClassName
    endif
    let pn = substitute(mainClassName, '\.', '/', "g").".java"
    let t:mapClassFile[mainClassName] = a:fn
    let srcRoot = substitute(a:fn, pn, "", "")
    if index(t:sourcepaths, srcRoot) == -1
        call add(t:sourcepaths, srcRoot)
    endif

    let lclass = a:ln
    let className = ""
    while className == "" && lpack < lclass
        let ff = matchlist(lines[lclass],  '^\%(public\s\+\)\?\%(abstract\s\+\)\?class\s\+\(\w\+\)')
        if len(ff) > 1
            let className = ff[1]
        endif
        let lclass = lclass - 1
    endwhile

    if len(packageName) > 1
        let className = packageName.".".className
    endif
    let t:mapClassFile[className] = a:fn
    return className
endfunction

if !exists('g:jdbExecutable')
    let g:jdbExecutable = 'jdb'
endif

let t:breakpoints = {}
let t:nextBreakPointId = 10000

function! StartJDB(port)
    let t:cursign = 10000 - tabpagenr()
    let t:jdb_buf = "[JDB] ".a:port.">"
    call <SID>GetClassNameFromFile(expand("%:p"), line("."))
    let cw = bufwinnr('%')
    let jdb_cmd = g:jdbExecutable.' -sourcepath '.join(t:sourcepaths, ":").' -attach '.a:port
    call FocusMyConsole("botri 10", t:jdb_buf)
    call append(".", jdb_cmd)
    execute cw."wincmd w"
    let t:jdb_job = job_start(jdb_cmd, {"out_cb": "JdbOutHandler", "err_cb": "JdbErrHandler", "exit_cb": "JdbExitHandler", "out_io": "buffer", "out_name": t:jdb_buf})
    let t:jdb_ch = job_getchannel(t:jdb_job)
    call <SID>PlaceBreakSigns()
endfunction

function! s:PlaceBreakSigns()
    for pos in keys(t:breakpoints)
        if t:breakpoints[pos][1]
            let bno = t:breakpoints[pos][0]
            let ff = matchlist(pos, '\([^:]\+\):\(\d\+\)')
            let fn = ff[1]
            let ln = ff[2]
            silent exec "sign place ".bno." name=breakpt line=".ln." file=".fn
            call ch_sendraw(t:jdb_ch, "stop at ".<SID>GetClassNameFromFile(fn, ln - 1).":".ln."\n")
        endif
    endfor
endfunction

function! OnQuitJDB()
    silent exec "sign unplace ".t:cursign
    if exists("t:jdb_buf")
        call FocusMyConsole("botri 10", t:jdb_buf)
        q
        unlet t:jdb_buf
    endif
endfunction

function! QuitJDB()
    if exists("t:jdb_ch")
        call ch_sendraw(t:jdb_ch, "exit\n")
        call ch_close(t:jdb_ch)
        call OnQuitJDB()
        unlet t:jdb_ch
    endif
endfunction

function! IsAttached()
    return exists("t:jdb_ch") && ch_status(t:jdb_ch) == "open"
endfunction

function! SendJDBCmd(cmd)
    if IsAttached()
        call ch_sendraw(t:jdb_ch, a:cmd."\n")
    endif
endfunction

if !exists('g:jdb_port')
    let g:jdb_port = "6789"
endif

function! Run()
    if IsAttached()
        call ch_sendraw(t:jdb_ch, "run\n")
    else
        call StartJDB(g:jdb_port)
    endif
endfunction

function! StepOver()
    call ch_sendraw(t:jdb_ch, "next\n")
endfunction

function! StepInto()
    call ch_sendraw(t:jdb_ch, "step\n")
endfunction

function! StepUp()
    call ch_sendraw(t:jdb_ch, "step up\n")
endfunction

function! GetBreakPointId(pos)
    if has_key(t:breakpoints, a:pos)
        return t:breakpoints[a:pos]
    else
        let t:breakpoints[a:pos] = t:nextBreakPointId
        let t:nextBreakPointId = t:nextBreakPointId + 1
        return [t:breakpoints[a:pos], 0]
    endif
endfunction

function! GetVisualSelection()
  let [lnum1, col1] = getpos("'<")[1:2]
  let [lnum2, col2] = getpos("'>")[1:2]
  let lines = getline(lnum1, lnum2)
  let lines[-1] = lines[-1][: col2 - (&selection == 'inclusive' ? 1 : 2)]
  let lines[0] = lines[0][col1 - 1:]
  return join(lines, "\n")
endfunction

function! ToggleBreakPoint()
    let ln = line('.')
    let fn = expand('%:p')
    let pos = fn.":".ln
    let [bno, enabled] = GetBreakPointId(pos)
    if enabled
        silent exec "sign unplace ".bno." file=".fn
        call SendJDBCmd("clear ".<SID>GetClassNameFromFile(fn, ln - 1).":".ln)
        let t:breakpoints[pos] = [bno, 0]
    else
        silent exec "sign place ".bno." name=breakpt line=".ln." file=".fn
        call SendJDBCmd("stop at ".<SID>GetClassNameFromFile(fn, ln - 1).":".ln)
        let t:breakpoints[pos] = [bno, 1]
    endif
endfunction

if !hlexists('DbgCurrent')
  hi DbgCurrent term=reverse ctermfg=White ctermbg=Red gui=reverse
endif
if !hlexists('DbgBreakPt')
  hi DbgBreakPt term=reverse ctermfg=White ctermbg=Green gui=reverse
endif
sign define current text=->  texthl=DbgCurrent linehl=DbgCurrent
sign define breakpt text=B>  texthl=DbgBreakPt linehl=DbgBreakPt