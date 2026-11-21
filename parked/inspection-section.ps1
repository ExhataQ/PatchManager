# ---------------------------------------------------------------- inspection mode
# Inspection mode records what you change between "start" and "stop" and turns it into one patch.
# It works inside git only: your index, branches and files are never touched by recording.
#   start : the whole working tree (tracked and new files, not ignored ones) is saved as a baseline commit that no branch points to
#           (refs/patch-inspect/<session>/base). What already differed from the last commit is part of the baseline,
#           so it never ends up in the session patch.
#   during: the tree is scanned again whenever files change (the drop window watches the folder; in the text menu the scan runs when
#           you look) and the files that changed are appended to events.jsonl. File events only say "look again": the scan is the truth.
#   stop  : one last scan; the patch is the NET difference between the baseline and now (not the list of edits), saved as a normal
#           entry in the patch history, so menu 3 (Undo) can take it back like any other patch.
# Pause keeps edits made while paused out of the patch (they are merged into the baseline when you resume).
# Everything about a session lives in .dev-data\patch-manager\inspections\<session>\ : metadata.json, events.jsonl, the patch, and a
# private git index (so scans after the first one only read the files that changed).

$script:InspectDir = $null                      # set in Test-Repository: .dev-data\patch-manager\inspections
$script:InspectRefRoot = 'refs/patch-inspect'   # not under refs/patch-manager/, so the "newest 30 snapshots" cleanup never touches it
$script:InspectActiveId = $null
$script:InspectCounts = $null
$script:InspectDirty = $false
$script:InspectDirtyAt = [datetime]::MinValue
$script:InspectLastScan = [datetime]::MinValue
$script:InspectWatcher = $null
$script:InspectTickBusy = $false
$script:GuiPauseButton = $null
$script:GuiRepoText = ''

function Get-InspectPath([string]$Id, [string]$Leaf = '') {
    $p = Join-Path $script:InspectDir $Id
    if ($Leaf -ne '') { $p = Join-Path $p $Leaf }
    return $p
}

function Format-InspectTime($Value, [string]$Format = 'HH:mm') {
    if ($null -eq $Value -or [string]$Value -eq '') { return '' }
    try { return ([datetime]$Value).ToString($Format) } catch { return [string]$Value }
}

function ConvertTo-InspectName([string]$Text) {
    $t = (([string]$Text).Trim() -replace '[^A-Za-z0-9._-]+', '-')
    $t = $t.Trim('-', '.')
    if ($t.Length -gt 40) { $t = $t.Substring(0, 40).Trim('-', '.') }
    return $t
}

function Get-CurrentBranchName {
    $b = Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')
    if ($b.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($b.Out)) { return $b.Out.Trim() }
    return '(no commits yet)'
}

# ---- session files

function Read-InspectMeta([string]$Id) {
    $p = Get-InspectPath $Id 'metadata.json'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    try { return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($p))) } catch { return $null }
}

# Written to a temporary file first and then moved over the old one, so a crash cannot leave half a file.
function Save-InspectMeta($Meta) {
    $dir = Get-InspectPath ([string]$Meta.id)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $final = Join-Path $dir 'metadata.json'
    $tmp = $final + '.tmp'
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Meta -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $final -Force
}

# One line of JSON per event (started, changed, checkpoint, paused, resumed, restored, stopped...). Never allowed to cause an error.
function Add-InspectEvent([string]$Id, [string]$Type, $Data = $null) {
    try {
        $o = [ordered]@{ t = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); type = $Type }
        if ($null -ne $Data) { foreach ($k in $Data.Keys) { $o[$k] = $Data[$k] } }
        $line = ConvertTo-Json -InputObject $o -Compress -Depth 5
        [IO.File]::AppendAllText((Get-InspectPath $Id 'events.jsonl'), $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Get-InspectionSessions {
    if (-not $script:InspectDir -or -not (Test-Path -LiteralPath $script:InspectDir -PathType Container)) { return @() }
    $out = @()
    $dirs = @(Get-ChildItem -LiteralPath $script:InspectDir -Directory | Where-Object { $_.Name -match '^session-\d+$' } | Sort-Object { [int]($_.Name -replace '\D', '') })
    foreach ($d in $dirs) {
        $m = Read-InspectMeta $d.Name
        if ($null -ne $m) { $out += $m }
    }
    return @($out)
}

# The running (or paused) session, or $null. Only one at a time, so no change can belong to two sessions.
function Get-ActiveInspection {
    $a = @(Get-InspectionSessions | Where-Object { $_.status -eq 'active' -or $_.status -eq 'paused' })
    if ($a.Count -eq 0) { return $null }
    return $a[$a.Count - 1]
}

function New-InspectId {
    $max = 0
    if (Test-Path -LiteralPath $script:InspectDir -PathType Container) {
        foreach ($d in (Get-ChildItem -LiteralPath $script:InspectDir -Directory)) {
            if ($d.Name -match '^session-(\d+)$' -and [int]$Matches[1] -gt $max) { $max = [int]$Matches[1] }
        }
    }
    return ('session-{0:D3}' -f ($max + 1))
}

# ---- git: scanning the working tree without touching your index

function Invoke-WithIndex([string]$IndexFile, [scriptblock]$Block) {
    $old = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $IndexFile
        return (& $Block)
    }
    finally {
        if ($null -eq $old) { Remove-Item -LiteralPath Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue } else { $env:GIT_INDEX_FILE = $old }
    }
}

# The whole working tree (tracked and new files, not ignored ones, and never .dev-data) as a git tree. Uses the session's own index, which
# keeps git's file cache, so after the first scan only files that changed are read again. Returns the tree id; throws when it cannot.
function Get-InspectTree([string]$Id, [bool]$Temporary = $false) {
    $idx = Get-InspectPath $Id 'index'
    if ($Temporary) { $idx = Join-Path ([IO.Path]::GetTempPath()) ('xp-iscan-' + [guid]::NewGuid().ToString('N')) }
    $dir = Get-InspectPath $Id
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tree = $null
    try {
    $tree = Invoke-WithIndex $idx {
        if (-not (Test-Path -LiteralPath $idx)) {
            $head = Invoke-Git @('rev-parse', '--verify', '--quiet', 'HEAD')
            if ($head.Code -eq 0) {
                $rt = Invoke-Git @('read-tree', 'HEAD')
                if ($rt.Code -ne 0) { throw ('git read-tree failed: ' + $rt.Out) }
            }
        }
        $add = Invoke-Git @('add', '-A', '--', '.', ':(exclude).dev-data')
        if ($add.Code -ne 0) { throw ('git add failed: ' + $add.Out) }
        $wt = Invoke-Git @('write-tree')
        if ($wt.Code -ne 0) { throw ('git write-tree failed: ' + $wt.Out) }
        return $wt.Out.Trim()
    }
    }
    finally { if ($Temporary) { Remove-Item -LiteralPath $idx -Force -ErrorAction SilentlyContinue } }
    if ([string]$tree -notmatch '^[0-9a-f]{40,64}$') { throw 'The scan did not give a tree id.' }
    return [string]$tree
}

# A commit object holding a tree, so a ref can keep it (a ref cannot point at a bare tree safely). Returns the commit id or $null.
function New-InspectCommit([string]$Tree, [string]$Message) {
    $msgFile = Join-Path ([IO.Path]::GetTempPath()) ('xp-imsg-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        [IO.File]::WriteAllText($msgFile, ($Message + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $ct = @('-c', 'user.name=Xplayer Patch Manager', '-c', 'user.email=patch-manager@localhost', 'commit-tree', $Tree)
        $head = Invoke-Git @('rev-parse', '--verify', '--quiet', 'HEAD')
        if ($head.Code -eq 0) { $ct += @('-p', $head.Out.Trim()) }
        $ct += @('-F', $msgFile)
        $c = Invoke-Git $ct
        if ($c.Code -ne 0 -or $c.Out.Trim() -notmatch '^[0-9a-f]{40,64}$') { return $null }
        return $c.Out.Trim()
    }
    finally { Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue }
}

function Set-InspectRef([string]$Id, [string]$Leaf, [string]$Commit) {
    $r = Invoke-Git @('update-ref', ($script:InspectRefRoot + '/' + $Id + '/' + $Leaf), $Commit)
    return ($r.Code -eq 0)
}

function Remove-InspectRef([string]$Id, [string]$Leaf) {
    [void](Invoke-Git @('update-ref', '-d', ($script:InspectRefRoot + '/' + $Id + '/' + $Leaf)))
}

function Remove-InspectRefs([string]$Id) {
    $rows = @((Invoke-Git @('for-each-ref', '--format=%(refname)', ($script:InspectRefRoot + '/' + $Id + '/'))).Lines | Where-Object { $_ -match '^refs/' })
    foreach ($r in $rows) { [void](Invoke-Git @('update-ref', '-d', $r)) }
}

# "git diff --name-status" lines as objects: Status A (new), M (changed), D (deleted), T (type changed), R (renamed: From and Path)
function ConvertFrom-NameStatus($Lines) {
    $list = New-Object System.Collections.ArrayList
    foreach ($l in @($Lines)) {
        if ($l -match '^R\d*\t(.+)\t(.+)$') { [void]$list.Add([pscustomobject]@{ Status = 'R'; Path = $Matches[2]; From = $Matches[1] }) }
        elseif ($l -match '^([ADMT])\t(.+)$') { [void]$list.Add([pscustomobject]@{ Status = $Matches[1]; Path = $Matches[2]; From = '' }) }
    }
    return @($list)
}

# What differs between the session's baseline and a tree: the changed files, and (WithCounts) the lines added and removed.
function Get-InspectSummary($Meta, [string]$Tree, [bool]$WithCounts = $false) {
    $r = Invoke-Git @('-c', 'core.quotepath=false', 'diff', '--name-status', '-M', '--no-color', '--no-ext-diff', [string]$Meta.effCommit, $Tree)
    if ($r.Code -ne 0) { throw ('Could not compare with the baseline: ' + $r.Out) }
    $entries = @(ConvertFrom-NameStatus $r.Lines)
    $added = 0; $removed = 0; $binary = 0
    if ($WithCounts -and $entries.Count -gt 0) {
        $n = Invoke-Git @('-c', 'core.quotepath=false', 'diff', '--numstat', '-M', '--no-color', '--no-ext-diff', [string]$Meta.effCommit, $Tree)
        foreach ($l in $n.Lines) {
            if ($l -match '^(\d+|-)\t(\d+|-)\t') {
                if ($Matches[1] -ne '-') { $added += [int]$Matches[1] } else { $binary++ }
                if ($Matches[2] -ne '-') { $removed += [int]$Matches[2] }
            }
        }
    }
    return [pscustomobject]@{
        Tree = $Tree; Entries = $entries
        Modified = @($entries | Where-Object { $_.Status -eq 'M' -or $_.Status -eq 'T' }).Count
        Created = @($entries | Where-Object { $_.Status -eq 'A' }).Count
        Deleted = @($entries | Where-Object { $_.Status -eq 'D' }).Count
        Renamed = @($entries | Where-Object { $_.Status -eq 'R' }).Count
        Added = $added; Removed = $removed; Binary = $binary
    }
}

# Scan now. While the session is active, files that changed since the previous scan are written to events.jsonl (the file-level history).
# Changes $Meta in place and saves it. Returns the tree id and what changed since the last scan.
function Update-InspectionScan($Meta) {
    $tree = Get-InspectTree ([string]$Meta.id)
    $res = [pscustomobject]@{ Tree = $tree; Changed = $false; Delta = @() }
    if ($Meta.status -eq 'active' -and $tree -ne [string]$Meta.lastTree) {
        $d = Invoke-Git @('-c', 'core.quotepath=false', 'diff', '--name-status', '--no-renames', '--no-color', '--no-ext-diff', [string]$Meta.lastTree, $tree)
        $delta = @(ConvertFrom-NameStatus $d.Lines)
        $files = @($delta | Select-Object -First 100 | ForEach-Object { @{ s = $_.Status; p = $_.Path } })
        Add-InspectEvent ([string]$Meta.id) 'changed' @{ count = $delta.Count; files = $files }
        $Meta.lastTree = $tree
        $Meta.lastChangeAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Save-InspectMeta $Meta
        $res.Changed = $true
        $res.Delta = $delta
        $script:InspectCounts = $null
    }
    if ($Meta.status -eq 'active' -and $null -eq $script:InspectCounts) { $script:InspectCounts = Get-InspectSummary $Meta $tree $false }
    return $res
}

# What the status screens show: a fresh scan while recording, the state at the moment of pausing while paused
function Get-InspectLiveSummary($Meta) {
    $tree = [string]$Meta.lastTree
    if ($Meta.status -eq 'active') { $r = Update-InspectionScan $Meta; $tree = $r.Tree }
    return (Get-InspectSummary $Meta $tree $true)
}

# ---- showing it

function Show-InspectionStatus($Meta, $Sum) {
    $paused = ($Meta.status -eq 'paused')
    Say ''
    if ($paused) { Say '  INSPECTION PAUSED' 'Yellow' } else { Say '  INSPECTION ACTIVE' 'Green' }
    Say ''
    Part '  Session   ' 'DarkGray'
    Part ([string]$Meta.id) 'White'
    if ($Meta.name) { Part ('  ' + [string]$Meta.name) 'Cyan' }
    Say ''
    Part '  Started   ' 'DarkGray'
    Say ('{0}   branch {1}' -f (Format-InspectTime $Meta.startedAt 'yyyy-MM-dd HH:mm'), $Meta.branch) 'Gray'
    $pre = $Meta.preexisting
    if ($null -ne $pre -and ([int]$pre.staged + [int]$pre.unstaged + [int]$pre.untracked) -gt 0) {
        Say ('  Before    {0} staged, {1} unstaged, {2} new file(s) already existed: they are in the baseline, not in the patch' -f $pre.staged, $pre.unstaged, $pre.untracked) 'DarkGray'
    }
    Say ''
    Say ('  Modified files   {0}' -f $Sum.Modified) 'Gray'
    Say ('  Created files    {0}' -f $Sum.Created) 'Gray'
    Say ('  Deleted files    {0}' -f $Sum.Deleted) 'Gray'
    if ($Sum.Renamed -gt 0) { Say ('  Renamed files    {0}' -f $Sum.Renamed) 'Gray' }
    Part '  Lines            ' 'Gray'
    Part ('+{0} ' -f $Sum.Added) 'Green'
    Say ('-{0}' -f $Sum.Removed) 'Red'
    Say ''
    $lc = Format-InspectTime $Meta.lastChangeAt
    if ($lc) { Say ('  Last detected change: {0}' -f $lc) 'Gray' } else { Say '  No change detected yet.' 'Gray' }
    Say ('  Checkpoints: {0}' -f @($Meta.checkpoints).Count) 'Gray'
    if ($paused) { Say '  Paused: edits made now are left out of the patch. Resume to go on recording.' 'Yellow' }

    $cur = Get-CurrentBranchName
    if ($cur -ne [string]$Meta.branch) { Write-Warn ('The branch changed: this session started on {0}, you are on {1} now. The patch would contain the switch.' -f $Meta.branch, $cur) }
    elseif ($Meta.startCommit) {
        $n = Invoke-Git @('rev-list', '--count', ([string]$Meta.startCommit + '..HEAD'))
        if ($n.Code -eq 0 -and $n.Out.Trim() -match '^[1-9]\d*$') { Say ('  {0} commit(s) were made since the start. The patch still holds the net file changes.' -f $n.Out.Trim()) 'DarkGray' }
    }
}

function Show-InspectionNow {
    Write-Heading 'Inspection status'
    $meta = Get-ActiveInspection
    if ($null -eq $meta) {
        Say '  No inspection is running.' 'Yellow'
        Say '  Start one before a task: everything you change after that goes into one patch.' 'DarkGray'
        return $true
    }
    Show-InspectionStatus $meta (Get-InspectLiveSummary $meta)
    return $true
}

# $Diff: also show the colored changes (the window always does; the text menu asks)
function Show-InspectionChanges([bool]$Diff = $false) {
    Write-Heading 'Changes in this inspection'
    $meta = Get-ActiveInspection
    if ($null -eq $meta) { Say '  No inspection is running.' 'Yellow'; return $false }
    $sum = Get-InspectLiveSummary $meta
    Show-InspectionStatus $meta $sum
    if ($sum.Entries.Count -eq 0) { Say ''; Say '  Nothing has changed since the baseline.' 'Yellow'; return $true }
    Say ''
    foreach ($e in ($sum.Entries | Select-Object -First 60)) {
        if ($e.Status -eq 'A') { Part '    created   ' 'Green'; Say $e.Path 'White' }
        elseif ($e.Status -eq 'D') { Part '    deleted   ' 'Red'; Say $e.Path 'White' }
        elseif ($e.Status -eq 'R') { Part '    renamed   ' 'Magenta'; Say ($e.From + '  =>  ' + $e.Path) 'White' }
        else { Part '    modified  ' 'Cyan'; Say $e.Path 'White' }
    }
    if ($sum.Entries.Count -gt 60) { Say ('    ... and {0} more' -f ($sum.Entries.Count - 60)) 'DarkGray' }
    if (-not $Diff -and -not $script:LogBox) { $Diff = (Ask-YesNo 'Show the changes in colors?' $false) }
    if ($Diff) {
        $tmp = Get-InspectPath ([string]$meta.id) 'current.diff'
        $r = Invoke-Git @('-c', 'core.quotepath=false', 'diff', '-M', '--no-color', '--no-ext-diff', ('--output=' + $tmp), [string]$meta.effCommit, $sum.Tree)
        if ($r.Code -eq 0 -and (Test-Path -LiteralPath $tmp -PathType Leaf)) { Show-PatchDiff (Get-Item -LiteralPath $tmp) $true }
    }
    return $true
}

function Show-InspectionSessions([bool]$OnlyIfAny = $false) {
    $all = @(Get-InspectionSessions)
    if ($OnlyIfAny -and $all.Count -eq 0) { return }
    Write-Heading 'Inspection sessions (oldest first)'
    if ($all.Count -eq 0) { Say '  None yet.' 'Yellow'; return }
    foreach ($s in $all) {
        $color = switch ([string]$s.status) { 'active' { 'Green' } 'paused' { 'Yellow' } default { 'DarkGray' } }
        Part ('  {0}  ' -f $s.id) 'Cyan'
        Part ('{0}  ' -f (Format-InspectTime $s.startedAt 'yyyy-MM-dd HH:mm')) 'DarkGray'
        Part ('{0,-8} ' -f $s.status) $color
        Part ('{0,-22} ' -f $s.name) 'White'
        if ($s.patchFile) {
            Part ('{0,3} files  ' -f $s.files) 'Gray'
            Part ('+{0} ' -f $s.added) 'Green'
            Part ('-{0}  ' -f $s.removed) 'Red'
            if ($s.historyId) { Part ('history #{0}' -f $s.historyId) 'DarkGray' }
        }
        Say ''
    }
}

# ---- the controls: start, pause, resume, checkpoint, stop, cancel, recover

function Start-Inspection([string]$Name = '') {
    Write-Heading 'Start inspection'
    $active = Get-ActiveInspection
    if ($null -ne $active) {
        Write-Fail ('An inspection is already running: {0}. Stop or cancel it first (one session at a time, so no change belongs to two sessions).' -f $active.id)
        return $false
    }
    if ($DryRun) { Write-Skip 'Dry run: no inspection was started.'; return $true }
    $branch = Get-CurrentBranchName
    $hd = Invoke-Git @('rev-parse', '--verify', '--quiet', 'HEAD')
    $startCommit = if ($hd.Code -eq 0) { $hd.Out.Trim() } else { '' }

    $id = New-InspectId
    $dir = Get-InspectPath $id
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        Write-Step 'Saving the baseline: every file as it is right now...'
        $tree = Get-InspectTree $id
        $baseCommit = New-InspectCommit $tree ('inspection baseline: ' + $id)
        if (-not $baseCommit) { throw 'The baseline commit could not be made.' }
        if (-not (Set-InspectRef $id 'base' $baseCommit) -or -not (Set-InspectRef $id 'eff' $baseCommit)) { throw 'The baseline reference could not be saved.' }
    }
    catch {
        $why = $_.Exception.Message
        Remove-InspectRefs $id
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Fail ('Could not start the inspection: ' + $why)
        return $false
    }

    # what was already different before the start: it is in the baseline, so it will not be in the patch
    $skip = '^(warning|error|fatal):|^\.dev-data/'
    $staged = @((Invoke-Git @('-c', 'core.quotepath=false', 'diff', '--cached', '--name-only')).Lines | Where-Object { $_ -match '\S' -and $_ -notmatch $skip })
    $unstaged = @((Invoke-Git @('-c', 'core.quotepath=false', 'diff', '--name-only')).Lines | Where-Object { $_ -match '\S' -and $_ -notmatch $skip })
    $untracked = @((Invoke-Git @('-c', 'core.quotepath=false', 'ls-files', '--others', '--exclude-standard')).Lines | Where-Object { $_ -match '\S' -and $_ -notmatch $skip })

    $meta = [pscustomobject]@{
        version = 1; id = $id; name = (ConvertTo-InspectName $Name); status = 'active'
        branch = $branch; startCommit = $startCommit
        startedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); stoppedAt = ''
        baseCommit = $baseCommit; effCommit = $baseCommit; lastTree = $tree
        pauseCommit = ''; pausedAt = ''; lastChangeAt = ''
        preexisting = [pscustomobject]@{ staged = $staged.Count; unstaged = $unstaged.Count; untracked = $untracked.Count }
        checkpoints = @(); warnings = @()
        patchFile = ''; patchSha256 = ''; files = 0; added = 0; removed = 0; historyId = 0
    }
    Save-InspectMeta $meta
    Add-InspectEvent $id 'started' @{ branch = $branch; startCommit = $startCommit; baseline = $baseCommit }
    $script:InspectActiveId = $id
    $script:InspectCounts = $null
    $script:InspectDirty = $false
    $script:InspectLastScan = Get-Date

    Write-Ok ('Inspection started: {0}{1}  (baseline saved in {2})' -f $id, $(if ($meta.name) { '  ' + $meta.name } else { '' }), (Format-Elapsed $clock.Elapsed))
    Say ('       Branch {0}, starting commit {1}' -f $branch, $(if ($startCommit) { $startCommit.Substring(0, 7) } else { '(none yet)' })) 'DarkGray'
    $pre = $staged.Count + $unstaged.Count + $untracked.Count
    if ($pre -gt 0) { Say ('       {0} changed file(s) already existed. They are in the baseline and will NOT be in the patch.' -f $pre) 'DarkGray' }
    if ($script:LogBox) { Say '       Now do your work. This window watches the folder and keeps the numbers above up to date.' 'DarkGray' }
    else { Say '       Now do your work. Come back to Inspection mode (menu I) to look, checkpoint, or stop.' 'DarkGray' }
    return $true
}

function Suspend-Inspection {
    Write-Heading 'Pause inspection'
    $meta = Get-ActiveInspection
    if ($null -eq $meta) { Say '  No inspection is running.' 'Yellow'; return $false }
    if ($meta.status -eq 'paused') { Say '  It is already paused. Choose Resume to go on.' 'Yellow'; return $false }
    if ($DryRun) { Write-Skip 'Dry run: not paused.'; return $true }
    [void](Update-InspectionScan $meta)    # record everything up to now first
    $pc = New-InspectCommit ([string]$meta.lastTree) ('inspection pause point: ' + $meta.id)
    if (-not $pc -or -not (Set-InspectRef ([string]$meta.id) 'pause' $pc)) { Write-Fail 'Could not save the pause point. Still recording.'; return $false }
    $meta.pauseCommit = $pc
    $meta.pausedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $meta.status = 'paused'
    Save-InspectMeta $meta
    Add-InspectEvent ([string]$meta.id) 'paused' $null
    Write-Ok 'Paused. Edits you make now are left out of the patch.'
    return $true
}

# Edits made while paused are merged into the baseline, so they are not part of the session patch. When an edit made while paused
# overlaps one made before the pause, git cannot separate them: then they stay in the patch, and that is said out loud.
function Resume-Inspection($Meta = $null) {
    Write-Heading 'Resume inspection'
    $meta = $Meta
    if ($null -eq $meta) { $meta = Get-ActiveInspection }
    if ($null -eq $meta) { Say '  No inspection is running.' 'Yellow'; return $false }
    if ($meta.status -ne 'paused') { Say '  It is not paused.' 'Yellow'; return $false }
    if ($DryRun) { Write-Skip 'Dry run: not resumed.'; return $true }
    $id = [string]$meta.id
    $tree = Get-InspectTree $id
    $left = 0
    $keepLast = $false
    if ($tree -ne [string]$meta.lastTree) {
        $d = Invoke-Git @('-c', 'core.quotepath=false', 'diff', '--name-status', '--no-renames', '--no-color', '--no-ext-diff', [string]$meta.lastTree, $tree)
        $left = @(ConvertFrom-NameStatus $d.Lines).Count
        $nc = New-InspectCommit $tree ('inspection resume point: ' + $id)
        $ok = $false
        $why = ''
        if ($nc) {
            $mt = Invoke-Git @('merge-tree', '--write-tree', ('--merge-base=' + [string]$meta.pauseCommit), [string]$meta.effCommit, $nc)
            $first = [string]($mt.Lines | Select-Object -First 1)
            if ($mt.Code -eq 0 -and $first -match '^[0-9a-f]{40,64}$') {
                $ec = New-InspectCommit $first ('inspection baseline with the paused edits: ' + $id)
                if ($ec -and (Set-InspectRef $id 'eff' $ec)) { $meta.effCommit = $ec; $ok = $true }
                else { $why = 'the new baseline could not be saved' }
            }
            elseif ($mt.Code -eq 1) { $why = 'some of them overlap with edits made before the pause' }
            else { $why = 'git merge-tree failed (it needs git 2.38 or newer)' }
        }
        else { $why = 'the resume point could not be saved' }
        if ($ok) { Say ('       {0} file(s) edited while paused are left out of the patch.' -f $left) 'DarkGray' }
        else {
            $keepLast = $true
            Write-Warn ('{0} file(s) were edited while paused and could NOT be left out: {1}. They will be part of the patch.' -f $left, $why)
            $meta.warnings = @($meta.warnings) + ('{0}: {1} file(s) edited while paused stayed in the patch ({2})' -f (Get-Date).ToString('yyyy-MM-dd HH:mm'), $left, $why)
        }
    }
    if (-not $keepLast) { $meta.lastTree = $tree }
    $meta.status = 'active'
    $meta.pauseCommit = ''
    $meta.pausedAt = ''
    Save-InspectMeta $meta
    Remove-InspectRef $id 'pause'
    Add-InspectEvent $id 'resumed' @{ pausedEdits = $left; leftOut = (-not $keepLast -and $left -gt 0) }
    $script:InspectCounts = $null
    Write-Ok 'Resumed. Recording again.'
    return $true
}

function New-InspectionCheckpoint([string]$Note = '') {
    Write-Heading 'Checkpoint'
    $meta = Get-ActiveInspection
    if ($null -eq $meta) { Say '  No inspection is running.' 'Yellow'; return $false }
    if ($meta.status -eq 'paused') { Write-Warn 'It is paused. Resume first: a checkpoint saves the files as they are, and paused edits are not part of the session.'; return $false }
    if ($DryRun) { Write-Skip 'Dry run: no checkpoint saved.'; return $true }
    $res = Update-InspectionScan $meta
    $n = @($meta.checkpoints).Count + 1
    $leaf = 'cp-{0:D3}' -f $n
    $c = New-InspectCommit $res.Tree ('inspection checkpoint {0}: {1}' -f $n, $meta.id)
    if (-not $c -or -not (Set-InspectRef ([string]$meta.id) $leaf $c)) { Write-Fail 'Could not save the checkpoint.'; return $false }
    $sum = Get-InspectSummary $meta $res.Tree $false
    $meta.checkpoints = @($meta.checkpoints) + [pscustomobject]@{ n = $n; ref = $leaf; commit = $c; at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); note = $Note; files = $sum.Entries.Count }
    Save-InspectMeta $meta
    Add-InspectEvent ([string]$meta.id) 'checkpoint' @{ n = $n; note = $Note; files = $sum.Entries.Count; commit = $c }
    Write-Ok ('Checkpoint {0} saved: {1} file(s) changed so far. Recover brings the files back to this state.' -f $n, $sum.Entries.Count)
    return $true
}

# $Name: the patch name (the text menu and the window ask when it is empty)
function Stop-Inspection([string]$Name = '') {
    Write-Heading 'Stop inspection'
    $meta = Get-ActiveInspection
    if ($null -eq $meta) { Say '  No inspection is running.' 'Yellow'; return $false }
    $id = [string]$meta.id
    if ($DryRun) {
        $dryTree = if ($meta.status -eq 'active') { Get-InspectTree $id } else { [string]$meta.lastTree }
        $sum = Get-InspectSummary $meta $dryTree $true
        Write-Skip ('Dry run: the patch would hold {0} changed file(s) (+{1} -{2}). Nothing was stopped.' -f $sum.Entries.Count, $sum.Added, $sum.Removed)
        return $true
    }
    if ($meta.status -eq 'paused') {
        if (-not (Resume-Inspection $meta)) { return $false }
        $meta = Read-InspectMeta $id
    }

    Write-Step 'Scanning the project one last time...'
    $res = Update-InspectionScan $meta
    $sum = Get-InspectSummary $meta $res.Tree $true

    # if the branch changed, the files of the other branch would be in the patch: do not hand that over silently
    $cur = Get-CurrentBranchName
    if ($cur -ne [string]$meta.branch) {
        Write-Warn ('The branch changed during the inspection: it started on {0}, you are on {1}.' -f $meta.branch, $cur)
        Say '       Switching branch changes files you did not edit, so the patch would contain them and be misleading.' 'Yellow'
        if (-not (Ask-YesNo 'Make the patch anyway?' $false)) {
            Say '  Not stopped. Switch back to the starting branch and stop again, or cancel the session.' 'Yellow'
            return $false
        }
        $meta.warnings = @($meta.warnings) + ('The branch changed from {0} to {1}; the patch may contain the switch.' -f $meta.branch, $cur)
    }

    if ($sum.Entries.Count -eq 0) {
        $meta.status = 'stopped'
        $meta.stoppedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Save-InspectMeta $meta
        Add-InspectEvent $id 'stopped' @{ files = 0 }
        Remove-Item -LiteralPath (Get-InspectPath $id 'index') -Force -ErrorAction SilentlyContinue
        $script:InspectActiveId = $null
        $script:InspectCounts = $null
        Write-Ok 'Inspection stopped. Nothing changed since the baseline, so there is no patch.'
        return $true
    }

    # the name of the patch
    $newName = ConvertTo-InspectName $Name
    if ($newName -eq '') {
        $keep = if ($meta.name) { [string]$meta.name } else { 'no name' }
        $newName = ConvertTo-InspectName (Read-Line ('Name for the patch (Enter keeps: {0})' -f $keep))
    }
    if ($newName -ne '') { $meta.name = $newName }
    $patchName = if ($meta.name) { '{0}-{1}.patch' -f $id, $meta.name } else { '{0}.patch' -f $id }
    $patchPath = Get-InspectPath $id $patchName

    # the net difference, written by git itself so no line ending or byte is changed on the way
    $r = Invoke-Git @('-c', 'core.quotepath=false', 'diff', '--binary', '--full-index', '-M', '--no-color', '--no-ext-diff', ('--output=' + $patchPath), [string]$meta.effCommit, $res.Tree)
    if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $patchPath -PathType Leaf) -or (Get-Item -LiteralPath $patchPath).Length -eq 0) {
        Write-Fail 'The patch could not be written. The inspection is still running; nothing was lost.'
        Say $r.Out 'DarkGray'
        return $false
    }
    $file = Get-Item -LiteralPath $patchPath
    $info = Get-PatchInfo $patchPath
    if (-not $info.Ok) {
        Write-Fail 'The patch was written but git cannot read it back. The inspection is still running.'
        Say $info.Message 'DarkGray'
        return $false
    }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $patchPath).Hash.ToLower()
    $proof = Invoke-Git @('apply', '--check', '--reverse', '--whitespace=nowarn', $patchPath)
    if ($proof.Code -ne 0) { Write-Warn 'The patch was made, but the check against your files did not agree (they may have changed again just now). Run Review on it.' }
    if ($sum.Binary -gt 0) { Write-Info ('{0} binary file(s) are inside the patch (git binary format), which makes it bigger.' -f $sum.Binary) }
    if ($file.Length -gt 20MB) { Write-Warn ('The patch is {0:N1} MB. Check that no build output or large file got in.' -f ($file.Length / 1MB)) }

    # the same history as every other patch: Undo (menu 3) can take it back
    $histId = 0
    try {
        $extra = @{ source = 'inspection'; session = $id; branch = [string]$meta.branch; startCommit = [string]$meta.startCommit }
        $histId = Add-HistoryEntry $file $hash $info ($script:InspectRefRoot + '/' + $id + '/base') $false $extra
    }
    catch {
        Write-Warn 'The patch is saved with the session, but writing it to the patch history failed:'
        Say ('       ' + $_.Exception.Message) 'Yellow'
        Write-ErrorLog 'writing the history for an inspection' $_
    }

    $meta.status = 'stopped'
    $meta.stoppedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $meta.patchFile = $patchName
    $meta.patchSha256 = $hash
    $meta.files = $info.Files.Count
    $meta.added = $info.Added
    $meta.removed = $info.Removed
    $meta.historyId = $histId
    Save-InspectMeta $meta
    Add-InspectEvent $id 'stopped' @{ files = $info.Files.Count; added = $info.Added; removed = $info.Removed; patch = $patchName; sha256 = $hash; history = $histId }
    Remove-Item -LiteralPath (Get-InspectPath $id 'index') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Get-InspectPath $id 'current.diff') -Force -ErrorAction SilentlyContinue
    $script:InspectActiveId = $null
    $script:InspectCounts = $null

    Say ''
    Write-Ok ('Inspection stopped. Patch {0}' -f $patchName)
    Show-PatchSummary $file $info $hash
    Say ''
    if ($histId -gt 0) { Say ('  Recorded in the history as #{0}. The changes are already in your files: menu 3 (Undo) takes them back.' -f $histId) 'DarkGray' }
    Say ('  The patch is kept in .dev-data\patch-manager\inspections\{0}\ . "Export" copies it elsewhere.' -f $id) 'DarkGray'
    if (-not $script:LogBox -and (Ask-YesNo 'Show the changes in colors?' $false)) { Show-PatchDiff $file $true }
    return $true
}

# Throws the recording away. Never touches your files.
function Remove-Inspection {
    Write-Heading 'Cancel inspection'
    $meta = Get-ActiveInspection
    if ($null -eq $meta) { Say '  No inspection is running.' 'Yellow'; return $false }
    $id = [string]$meta.id
    Say ('  This throws away the recording of {0}: its baseline, checkpoints and event history.' -f $id) 'Gray'
    Say '  Your files are NOT touched and nothing is undone. No patch is made.' 'Gray'
    if ($DryRun) { Write-Skip 'Dry run: nothing was cancelled.'; return $true }
    if (-not (Ask-YesNo ('Cancel and discard {0}?' -f $id) $false)) { Say '  Not cancelled. The session goes on.' 'Yellow'; return $false }
    Remove-InspectRefs $id
    $dir = Get-InspectPath $id
    if ($id -match '^session-\d+$' -and (Test-Path -LiteralPath $dir -PathType Container)) { Remove-Item -LiteralPath $dir -Recurse -Force }
    $script:InspectActiveId = $null
    $script:InspectCounts = $null
    Write-Ok ('Session {0} discarded. Your files were not changed.' -f $id)
    return $true
}

# Puts the files back to a saved state (a checkpoint, or the start of a session). Shows exactly what will change, saves a normal
# safety snapshot of the current files first (menu R brings it back), and asks once.
function Restore-WorkTreeTo($Meta, [string]$Commit, [string]$Label) {
    $tree = Get-InspectTree ([string]$Meta.id) ($Meta.status -ne 'active')
    $d = Invoke-Git @('-c', 'core.quotepath=false', 'diff', '--name-status', '--no-renames', '--no-color', '--no-ext-diff', $Commit, $tree)
    if ($d.Code -ne 0) { Write-Fail 'Could not compare the files with that state.'; Say $d.Out 'DarkGray'; return $false }
    $entries = @(ConvertFrom-NameStatus $d.Lines)
    if ($entries.Count -eq 0) { Write-Ok 'The files already are exactly in that state. Nothing to restore.'; return $true }
    Say ''
    Say ('  Going back to {0} changes {1} file(s):' -f $Label, $entries.Count) 'Gray'
    foreach ($e in ($entries | Select-Object -First 20)) {
        if ($e.Status -eq 'A') { Say ('         remove      ' + $e.Path + '   (created after that state)') 'Yellow' }
        elseif ($e.Status -eq 'D') { Say ('         bring back  ' + $e.Path) 'Gray' }
        else { Say ('         restore     ' + $e.Path) 'Gray' }
    }
    if ($entries.Count -gt 20) { Say ('         ... and {0} more' -f ($entries.Count - 20)) 'DarkGray' }
    Say '  Edits made after that state are replaced. A safety snapshot of the current files is saved first (menu R brings it back).' 'DarkGray'
    if ($DryRun) { Write-Skip 'Dry run: nothing restored.'; return $true }
    if (-not (Ask-YesNo 'Restore these files now?' $false)) { Say '  Cancelled.' 'Yellow'; return $false }

    $paths = @($entries | ForEach-Object { $_.Path })
    $snap = New-Snapshot ('before going back to ' + $Label) $paths
    if ($snap) { Write-Ok 'Safety snapshot saved (menu R restores it).' }
    else {
        Write-Warn 'Could not save a safety snapshot of the current files.'
        if (-not (Ask-YesNo 'Restore anyway?' $false)) { return $false }
    }
    $failed = 0
    foreach ($e in $entries) {
        if ($e.Status -eq 'A') {
            $full = Join-Path $script:Repo ($e.Path -replace '/', '\')
            if (Test-Path -LiteralPath $full -PathType Leaf) { Remove-Item -LiteralPath $full -Force }
            else { $failed++; Write-Fail ('Could not find ' + $e.Path + ' to remove it.') }
        }
        else {
            $r = Invoke-Git @('restore', ('--source=' + $Commit), '--worktree', '--', (':(literal)' + $e.Path))
            if ($r.Code -ne 0) { $failed++; Write-Fail ('Could not restore ' + $e.Path); Say ('         ' + $r.Out) 'DarkGray' }
        }
    }
    Add-InspectEvent ([string]$Meta.id) 'restored' @{ to = $Label; files = $entries.Count; failed = $failed }
    $script:InspectCounts = $null
    if ($failed -eq 0) { Write-Ok ('Restored {0} file(s) to {1}.' -f $entries.Count, $Label) }
    else { Write-Warn ('Restored {0} of {1} file(s). See the messages above.' -f ($entries.Count - $failed), $entries.Count) }
    return ($failed -eq 0)
}

function Invoke-InspectionRecover {
    Write-Heading 'Recover: back to a checkpoint or to the start of a session'
    $sessions = @(Get-InspectionSessions)
    if ($sessions.Count -eq 0) { Say '  No inspection sessions yet.' 'Yellow'; return $false }
    $meta = Get-ActiveInspection
    if ($null -ne $meta) {
        if ($meta.status -eq 'paused') { Write-Warn 'It is paused. Resume first: files restored while paused would be left out of the patch, hiding the restore.'; return $false }
        Say ('  Session {0} is running.' -f $meta.id) 'Gray'
    }
    else {
        $shown = @($sessions | Sort-Object { [int](([string]$_.id) -replace '\D', '') } -Descending | Select-Object -First 10)
        foreach ($s in $shown) {
            Part ('  {0}  ' -f $s.id) 'Cyan'
            Part ('{0}  ' -f (Format-InspectTime $s.startedAt 'yyyy-MM-dd HH:mm')) 'DarkGray'
            Say ([string]$s.name) 'White'
        }
        $answer = Read-Line 'Session (Enter = the newest)'
        $meta = $shown[0]
        if ($answer -ne '') {
            $want = $answer
            if ($want -match '^\d+$') { $want = 'session-' + $want.PadLeft(3, '0') }
            $meta = $sessions | Where-Object { [string]$_.id -eq $want } | Select-Object -First 1
            if ($null -eq $meta) { Write-Fail 'No such session.'; return $false }
        }
    }
    $targets = @([pscustomobject]@{ Label = ('the start of ' + [string]$meta.id); Commit = [string]$meta.baseCommit })
    foreach ($c in @($meta.checkpoints)) {
        $targets += [pscustomobject]@{ Label = ('checkpoint {0} of {1}' -f $c.n, $meta.id); Commit = [string]$c.commit; At = $c.at; Note = [string]$c.note }
    }
    Say ''
    $i = 0
    foreach ($t in $targets) {
        $i++
        Part ('  {0,3}  ' -f $i) 'Cyan'
        Part ([string]$t.Label) 'White'
        if ($t.At) { Part ('   ' + (Format-InspectTime $t.At) + '  ' + $t.Note) 'DarkGray' }
        Say ''
    }
    $answer = Read-Line 'Number to go back to (Enter cancels)'
    if ($answer -eq '') { Say '  Cancelled.' 'Yellow'; return $false }
    $pick = 0
    if (-not [int]::TryParse($answer, [ref]$pick) -or $pick -lt 1 -or $pick -gt $targets.Count) { Write-Fail 'No such number.'; return $false }
    $t = $targets[$pick - 1]
    return (Restore-WorkTreeTo $meta ([string]$t.Commit) ([string]$t.Label))
}

# Copies a session patch (and its metadata) to a folder of your choice
function Export-InspectionPatch {
    Write-Heading 'Export a session patch'
    $list = @(Get-InspectionSessions | Where-Object { $_.patchFile } | Sort-Object { [int](([string]$_.id) -replace '\D', '') } -Descending | Select-Object -First 15)
    if ($list.Count -eq 0) { Say '  No session has made a patch yet.' 'Yellow'; return $false }
    foreach ($s in $list) {
        Part ('  {0}  ' -f $s.id) 'Cyan'
        Part ('{0}  ' -f (Format-InspectTime $s.startedAt 'yyyy-MM-dd HH:mm')) 'DarkGray'
        Say ([string]$s.patchFile) 'White'
    }
    $answer = Read-Line 'Session (Enter = the newest)'
    $s = $list[0]
    if ($answer -ne '') {
        $want = $answer
        if ($want -match '^\d+$') { $want = 'session-' + $want.PadLeft(3, '0') }
        $s = $list | Where-Object { [string]$_.id -eq $want } | Select-Object -First 1
        if ($null -eq $s) { Write-Fail 'No such session.'; return $false }
    }
    $src = Get-InspectPath ([string]$s.id) ([string]$s.patchFile)
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { Write-Fail 'The patch file of that session is missing.'; return $false }
    $dest = Remove-OuterQuotes (Read-Line 'Folder to copy it to (Enter cancels)')
    if ($dest -eq '') { Say '  Cancelled.' 'Yellow'; return $false }
    if (-not (Test-Path -LiteralPath $dest -PathType Container)) {
        if (-not (Ask-YesNo ('The folder does not exist. Create ' + $dest + '?') $false)) { Say '  Cancelled.' 'Yellow'; return $false }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
    }
    Copy-Item -LiteralPath $src -Destination (Join-Path $dest ([string]$s.patchFile)) -Force
    $metaSrc = Get-InspectPath ([string]$s.id) 'metadata.json'
    if (Test-Path -LiteralPath $metaSrc -PathType Leaf) { Copy-Item -LiteralPath $metaSrc -Destination (Join-Path $dest (([string]$s.patchFile) + '.metadata.json')) -Force }
    Write-Ok ('Copied {0} to {1}' -f $s.patchFile, $dest)
    return $true
}

# ---- text menu and command line

function Show-InspectionMenu {
    Set-WindowTitle 'Xplayer Patch Manager - Inspection mode'
    while ($true) {
        [void](Invoke-Safe 'reading the status' { [void](Show-InspectionNow) })
        Say ''
        Write-MenuItem '1' 'Start inspection' 'record from now on'
        Write-MenuItem '2' 'View changes' 'what changed so far'
        Write-MenuItem '3' 'Pause / Resume' 'paused edits stay out of the patch'
        Write-MenuItem '4' 'Checkpoint' 'save an intermediate state'
        Write-MenuItem '5' 'Stop, make the patch' 'goes into the history'
        Write-MenuItem '6' 'Cancel the session' 'files stay as they are'
        Write-MenuItem '7' 'Recover' 'back to a checkpoint or the start'
        Write-MenuItem '8' 'Sessions' 'the list'
        Write-MenuItem '9' 'Export a session patch' 'copy it to a folder'
        Write-MenuItem 'B' 'Back to the main menu'
        Say ''
        $c = (Read-Line 'Inspection').ToLower()
        if ($c -eq '1') { [void](Invoke-Safe 'starting' { [void](Start-Inspection (Read-Line 'Name for this session (optional, Enter = none)')) }) }
        elseif ($c -eq '2') { [void](Invoke-Safe 'viewing' { [void](Show-InspectionChanges $false) }) }
        elseif ($c -eq '3') {
            [void](Invoke-Safe 'pausing' {
                $m = Get-ActiveInspection
                if ($null -ne $m -and $m.status -eq 'paused') { [void](Resume-Inspection $m) } else { [void](Suspend-Inspection) }
            })
        }
        elseif ($c -eq '4') { [void](Invoke-Safe 'saving the checkpoint' { [void](New-InspectionCheckpoint (Read-Line 'Note for the checkpoint (optional)')) }) }
        elseif ($c -eq '5') { [void](Invoke-Safe 'stopping' { [void](Stop-Inspection) }) }
        elseif ($c -eq '6') { [void](Invoke-Safe 'cancelling' { [void](Remove-Inspection) }) }
        elseif ($c -eq '7') { [void](Invoke-Safe 'recovering' { [void](Invoke-InspectionRecover) }) }
        elseif ($c -eq '8') { [void](Invoke-Safe 'listing' { Show-InspectionSessions }) }
        elseif ($c -eq '9') { [void](Invoke-Safe 'exporting' { [void](Export-InspectionPatch) }) }
        elseif ($c -eq 'b' -or $c -eq 'q' -or $c -eq '0' -or $c -eq '') { break }
        Say ''
        Say ('  ' + $script:Hr) 'DarkGray'
    }
    Set-WindowTitle 'Xplayer Patch Manager'
}

# -Inspect start|stop|status|pause|resume|checkpoint|cancel|recover|list|export   (-InspectName: the session name, the patch name, or the checkpoint note)
function Invoke-InspectCli([string]$Action) {
    switch ($Action.ToLower()) {
        'start' { return (Start-Inspection $InspectName) }
        'stop' { return (Stop-Inspection $InspectName) }
        'status' { return (Show-InspectionNow) }
        'pause' { return (Suspend-Inspection) }
        'resume' { return (Resume-Inspection) }
        'checkpoint' { return (New-InspectionCheckpoint $InspectName) }
        'cancel' { return (Remove-Inspection) }
        'recover' { return (Invoke-InspectionRecover) }
        'list' { Show-InspectionSessions; return $true }
        'export' { return (Export-InspectionPatch) }
        default {
            Write-Fail ('Unknown -Inspect action "{0}". Use: start, stop, status, pause, resume, checkpoint, cancel, recover, list, export.' -f $Action)
            return $false
        }
    }
}

# ---- the drop window: live monitoring

function Get-InspectStatusLine {
    if (-not $script:InspectActiveId) { return 'Inspection: not running' }
    $m = Read-InspectMeta $script:InspectActiveId
    if ($null -eq $m) { return 'Inspection: not running' }
    $state = if ($m.status -eq 'paused') { 'PAUSED' } else { 'ACTIVE' }
    $nm = if ($m.name) { ' ' + [string]$m.name } else { '' }
    $txt = 'INSPECTION {0}   {1}{2}   started {3}' -f $state, $m.id, $nm, (Format-InspectTime $m.startedAt)
    $c = $script:InspectCounts
    if ($null -ne $c) { $txt += ('   modified {0}   created {1}   deleted {2}' -f $c.Modified, $c.Created, $c.Deleted) }
    $lc = Format-InspectTime $m.lastChangeAt
    if ($lc) { $txt += ('   last change {0}' -f $lc) } else { $txt += '   no change yet' }
    return $txt
}

function Set-GuiStatusText {
    if ($null -eq $script:GuiStatus) { return }
    $script:GuiStatus.Text = ([string]$script:GuiRepoText) + "`r`n" + (Get-InspectStatusLine)
    $m = $null
    if ($script:InspectActiveId) { $m = Read-InspectMeta $script:InspectActiveId }
    if ($null -eq $m) { $script:GuiStatus.ForeColor = [System.Drawing.Color]::FromArgb(140, 146, 158) }
    elseif ($m.status -eq 'paused') { $script:GuiStatus.ForeColor = (Get-GuiColor 'Yellow') }
    else { $script:GuiStatus.ForeColor = (Get-GuiColor 'Green') }
}

# File events only mark "something changed"; the scan decides what really did. Events from .git, .dev-data and node_modules are ignored.
function Register-InspectTouch([string]$Full) {
    if ([string]::IsNullOrEmpty($Full)) { return }
    $rel = $Full
    if ($Full.StartsWith($script:Repo, [StringComparison]::OrdinalIgnoreCase)) { $rel = $Full.Substring($script:Repo.Length).TrimStart('\', '/') }
    if ($rel -match '(^|[\\/])(\.git|\.dev-data|node_modules)([\\/]|$)') { return }
    $script:InspectDirty = $true
    $script:InspectDirtyAt = Get-Date
}

function Start-InspectionWatcher {
    if ($null -ne $script:InspectWatcher) { return }
    try {
        $w = New-Object System.IO.FileSystemWatcher
        $w.Path = $script:Repo
        $w.IncludeSubdirectories = $true
        $w.NotifyFilter = [System.IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size'
        $w.InternalBufferSize = 65536
        [void]$script:Form.Handle                  # the window must have its handle, or events would not reach its thread
        $w.SynchronizingObject = $script:Form      # events arrive on the window's own thread, where scripts can run
        $touch = { param($sender, $e) Register-InspectTouch $e.FullPath }
        $w.Add_Changed($touch)
        $w.Add_Created($touch)
        $w.Add_Deleted($touch)
        $w.Add_Renamed({ param($sender, $e) Register-InspectTouch $e.FullPath; Register-InspectTouch $e.OldFullPath })
        $w.EnableRaisingEvents = $true
        $script:InspectWatcher = $w
    }
    catch { $script:InspectWatcher = $null }       # no watcher: the timer scans every few seconds instead
}

function Stop-InspectionWatcher {
    $w = $script:InspectWatcher
    $script:InspectWatcher = $null
    if ($null -eq $w) { return }
    try { $w.EnableRaisingEvents = $false; $w.Dispose() } catch { }
}

# After every action in the window: find out which session runs, start or stop the watcher, set the Pause/Resume button text
function Sync-InspectionState {
    try {
        $m = Get-ActiveInspection
        if ($null -ne $m) { $script:InspectActiveId = [string]$m.id }
        else { $script:InspectActiveId = $null; $script:InspectCounts = $null }
        if ($null -ne $m -and $m.status -eq 'active') { Start-InspectionWatcher } else { Stop-InspectionWatcher }
        if ($null -ne $script:GuiPauseButton) { $script:GuiPauseButton.Text = $(if ($null -ne $m -and $m.status -eq 'paused') { 'Resume' } else { 'Pause' }) }
        if ($null -ne $m -and $m.status -eq 'active' -and $null -eq $script:InspectCounts) { [void](Update-InspectionScan $m) }
    }
    catch { }
}

# Every 1.5 seconds. Scans when files changed and have been quiet for a moment, and every 45 seconds anyway (events can be missed).
function Invoke-InspectTick {
    if ($script:GuiBusy -or $script:InspectTickBusy -or -not $script:InspectActiveId) { return }
    $script:InspectTickBusy = $true
    try {
        $m = Read-InspectMeta $script:InspectActiveId
        if ($null -eq $m -or ($m.status -ne 'active' -and $m.status -ne 'paused')) { Sync-InspectionState; Set-GuiStatusText; return }
        if ($m.status -ne 'active') { return }
        $now = Get-Date
        $quiet = ($script:InspectDirty -and (($now - $script:InspectDirtyAt).TotalMilliseconds -ge 1200))
        $periodic = (($now - $script:InspectLastScan).TotalSeconds -ge 45)
        $polling = (($null -eq $script:InspectWatcher) -and (($now - $script:InspectLastScan).TotalSeconds -ge 8))
        if ($quiet -or $periodic -or $polling) {
            $script:InspectDirty = $false
            $script:InspectLastScan = $now
            $res = Update-InspectionScan $m
            if ($res.Changed) {
                $first = @($res.Delta | Select-Object -First 4 | ForEach-Object { $_.Status + ' ' + $_.Path })
                Write-Info ('Change detected: {0} file(s)   {1}{2}' -f $res.Delta.Count, ($first -join ',  '), $(if ($res.Delta.Count -gt 4) { ' ...' } else { '' }))
            }
            Set-GuiStatusText
        }
    }
    catch { }
    finally { $script:InspectTickBusy = $false }
}

