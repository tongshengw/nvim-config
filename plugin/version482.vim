" 
" Keep versions of files in EECS 482 github repos
"

" return relative time
function version482#RelTime()
    return(reltimestr(reltime())->substitute('\.\(...\).*', '\1', '') / 1000)
endfunction

let $TZ='America/Detroit'
let $SSH_ASKPASS='echo'
let $SSH_ASKPASS_REQUIRE='force'
let s:startTimeAbs = localtime()
let s:startTimeRel = version482#RelTime()

" return absolute time
function version482#Time()
    return(s:startTimeAbs + (version482#RelTime() - s:startTimeRel))
endfunction

let s:version = 'vim-20251228'
let s:minTimeVersion = 10       " minimum time between versions
let s:minTimePush = 60          " minimum time between pushes
let s:minTimeCheck = 600        " minimum time between checking version482 repo
let s:username = substitute($USER, "[^a-zA-Z0-9]", "", "g")

let s:versionTime = {}          " last time each file was written
let s:pushTime = {}             " last time each repo was pushed
let s:checkTime = 0             " last time version482 repo was checked

let s:timerStarted = 0
let s:pushTimerStarted = 0

let s:versionDir = {}     " .version482 directory name for each source file directory

autocmd BufReadPost * call version482#NewBuffer()
autocmd BufWritePre * call version482#Save()
autocmd TextChanged,TextChangedI * call version482#TextChanged()

" See if directory is in an EECS 482 git repo.
" Store .version482 directory name in s:versionDir, and make sure the
" .version482 directory exists and is properly configured.  If the directory
" isn't in a git repo, then set the versionDir entry to the empty string.
function version482#InitVersionDir(dirname)
    if has_key(s:versionDir, a:dirname)
        return
    endif

    let s:versionDir[a:dirname] = ''

    " Get top level of working tree
    let l:top = systemlist('cd "' . a:dirname . '" ; git rev-parse --show-toplevel')[0]
    if v:shell_error
        " not in a git repository
        return
    endif

    " Get name of main repo and make sure it's not a version482 repo
    let l:out = trim(system('cd "' . a:dirname . '" ; git remote -v | grep "eecs482.*(push)" | tail -n 1'))
    if stridx(l:out, 'version482') >= 0
        " in a version482 repo
        return
    endif
    let l:matches = matchlist(l:out, '\(eecs482/[a-z.]*\)\.\(\d\d*\)')
    if (empty(l:matches))
        " not in an eecs482 repo
        return
    endif
    let l:repo = l:matches[1] . '.' . l:matches[2]
    " echo 'l:repo=' . l:repo

    let s:versionDir[a:dirname] = fnamemodify(l:top, ':p') . '.version482'

    " clone version482 repo if needed
    if ! isdirectory(s:versionDir[a:dirname])
	call system('cd "' . l:top . '" ; git clone git@github.com:' . l:repo . '.version482 .version482')
    endif

    if ! isdirectory(s:versionDir[a:dirname])
	" couldn't clone version482 repo
	let s:versionDir[a:dirname] = ''
	return
    endif

    " Make sure .version482 is its own repo
    let l:version482_top = systemlist('cd "' . s:versionDir[a:dirname] . '" ; git rev-parse --show-toplevel')[0]
    if v:shell_error
	" .version482 is not a git repository
	let s:versionDir[a:dirname] = ''
	return
    endif
    if l:version482_top == l:top
	" .version482 is part of the main project repository
	let s:versionDir[a:dirname] = ''
	return
    endif

    " Make sure origin for version482 is consistent with origin for main repo
    " (in case repos were renamed, or the repo somehow loses its origin
    " definition).
    let l:url = trim(system('cd "' . s:versionDir[a:dirname] . '" ; git remote get-url origin'))
    if v:shell_error
	" Somehow the repo lost its definition of origin.  Add it back.
	call system('cd "' . s:versionDir[a:dirname] . '" ; git remote add origin git@github.com:' . l:repo . '.version482')
    elseif l:url != 'git@github.com:' . l:repo . '.version482'
	call system('cd "' . s:versionDir[a:dirname] . '" ; git remote set-url origin git@github.com:' . l:repo . '.version482')
    endif

    " compute correct branch for this local repo
    let l:branch = s:username . trim(system('uname -s'))
    if filereadable('/etc/os-release')
	let l:branch .= systemlist('cat /etc/os-release | grep "^ID=" | sed "s/^.*=//"')[0]
    endif
    let l:branch .= l:top
    let l:branch = substitute(l:branch, "[^a-zA-Z0-9]", "", "g")

    " Make sure the version482 repo is on the correct branch
    let l:branch1 = trim(system('cd "' . s:versionDir[a:dirname] . '"; git branch --show-current'))
    if l:branch1 != l:branch
	" Try to checkout branch, in case this branch already exists
	call system('cd "' . s:versionDir[a:dirname] . '"; git checkout ' . l:branch)
	if v:shell_error
	    " Branch didn't exist (this is the common case).  Try to create the
	    " branch (set up tracking below).
	    call system('cd "' . s:versionDir[a:dirname] . '"; git checkout -b ' . l:branch . ' --no-track')
	    if v:shell_error
		" Can't create branch for this version482 repo
		let s:versionDir[a:dirname] = ''
		return
	    endif
	endif
    endif

    " Make sure the version482 repo's upstream is set to the corresponding
    " branch on github
    let l:remote = trim(system('cd "' . s:versionDir[a:dirname] . '" ; git rev-parse --abbrev-ref "@{upstream}"'))
    if v:shell_error || l:remote != "origin/" . l:branch
	" Try to pull from github, in case branch already exists on github
	call system('cd "' . s:versionDir[a:dirname] . '"; git pull origin ' . l:branch)

	" Set upstream to github, and create branch on github if needed
	call system('cd "' . s:versionDir[a:dirname] . '"; git push --set-upstream origin ' . l:branch)
	if v:shell_error
	    " can't add upstream reference to remote version482 repo
	    let s:versionDir[a:dirname] = ''
	    return
	endif
    endif

endfunction

function version482#NewBuffer()
    if ! has('nvim')
        " helps remove display glitches on startup
        sleep 100m
    endif
    call version482#InitVersionDir(fnamemodify(expand('%'), ':p:h'))
endfunction

function version482#TextChanged(...)
    let l:now = version482#Time()
    let l:filename = fnamemodify(expand('%'), ':p')

    " Limit the rate of versioning events.  Also log events where time has
    " gone backward by more than minTimeVersion.
    if has_key(s:versionTime, l:filename) && abs(l:now - s:versionTime[l:filename]) < s:minTimeVersion

        " make sure this version is eventually saved
        " replace any pending timer event, so these don't pile up
        if s:timerStarted
            call timer_stop(s:timer)
        endif
        let s:timerStarted = 1
        let s:timer = timer_start((s:minTimeVersion - (l:now - s:versionTime[l:filename]))*1000, 'version482#TextChanged')
        return
    endif

    let l:dirname = fnamemodify(l:filename, ':h')

    call version482#InitVersionDir(l:dirname)

    " make sure file is in an EECS 482 git repo
    if s:versionDir[l:dirname] == ''
        return
    endif

    " make sure file is a program source file, i.e., has extension {cpp,cc,h,hpp,py}
    let l:ext = fnamemodify(l:filename, ':e')
    if l:ext != 'cpp' && l:ext != 'cc' && l:ext != 'h' && l:ext != 'hpp' && l:ext != 'py'
        return
    endif

    let l:versionDirname = s:versionDir[l:dirname]

    " create/update file
    let l:basename = fnamemodify(l:filename, ':t')
    call writefile(getline(1, '$'), fnamemodify(l:versionDirname, ':p') . l:basename)

    " commit changes
    call system('cd "' . l:versionDirname . '"; git add -f "' . l:basename . '"; git commit --allow-empty -m "'. s:version . '"')

    let s:versionTime[l:filename] = l:now

    if ! has('nvim')
        " Redraw screen to fix glitches.  Unfortunately, this has the
        " side effect of blanking the entire screen when changing a range
        " of text (e.g., change word).  nvim doesn't have these problems.
        mode
    endif

endfunction

" called when a file is saved
function version482#Save(...)
    let l:now = version482#Time()
    let l:filename = fnamemodify(expand('%'), ':p')
    let l:dirname = fnamemodify(l:filename, ':h')

    " Clear s:versionDir every so often, so the version482 repo gets re-checked.
    if l:now - s:checkTime >= s:minTimeCheck
        let s:versionDir = {}
	let s:checkTime = l:now
    endif

    call version482#InitVersionDir(l:dirname)

    " make sure file is in an EECS 482 git repo
    if s:versionDir[l:dirname] == ''
        return
    endif
    let l:versionDirname = s:versionDir[l:dirname]

    " limit the rate of pushing
    if has_key(s:pushTime, l:versionDirname) && l:now - s:pushTime[l:versionDirname] < s:minTimePush

        " make sure this event is eventually pushed
        " replace any pending timer event, so these don't pile up
        if s:pushTimerStarted
            call timer_stop(s:pushTimer)
        endif
        let s:pushTimerStarted = 1
        let s:pushTimer = timer_start((s:minTimePush - (l:now - s:pushTime[l:versionDirname]))*1000, 'version482#Save')
        return
    endif

    " add version482 entry, so it's as new as the saved file
    call version482#TextChanged()

    call system('cd "' . l:versionDirname . '"; git push --quiet')
    let s:pushTime[l:versionDirname] = l:now

endfunction
