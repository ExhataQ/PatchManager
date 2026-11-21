# Patch Manager   (one file: put it anywhere inside a git project, or start it from one)
#
# Applies .patch files to the git project it finds, safely: checks first, a safety snapshot, apply, history, undo.
# It never forces a patch, never resets the repository and never overwrites a file that does not match the patch.
#
# Start it:  right-click this file > Run with PowerShell, then drag a patch into the window.
#            Or: powershell -ExecutionPolicy Bypass -File PatchManager.ps1 "C:\path\fix.patch"
# Project:   the git repository that contains this script (else the folder you started it from). Nothing is configured.
# Menu:      1 apply, 2 review (is it applied? the changes in colors), 3 undo, 4 history, R restore a snapshot, D show a patch's changes.
# Safety:    before a patch is applied (or undone) a snapshot of the files it touches is saved inside git (refs/patch-manager/...).
#            Menu R puts the files back. The newest 30 snapshots are kept.
# What it keeps, per project: .patch-manager\history.json and a copy of every applied patch. That folder is excluded through
# .git\info\exclude (a local file), so no tracked file changes and none of it can land in a commit.
# Colors:    set the NO_COLOR environment variable to turn them off.
#
# This file is plain ASCII on purpose: Windows PowerShell 5.1 reads a file without a byte-order mark as ANSI.

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Patch,
    [switch]$Help,
    [switch]$Review,
    [switch]$Close,
    [switch]$Undo,
    [switch]$History,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Repo = $null          # found in Test-Repository
$script:StartDir = $null      # the folder the tool was started from
$script:Store = $null
$script:PatchStore = $null
$script:HistoryFile = $null
$script:LogBox = $null        # set while the drop window is open: all output goes there
$script:Form = $null
$Interactive = -not ($Patch -or $Undo -or $History -or $Review -or $Help)

# ---------------------------------------------------------------- look and feel
# Plain Write-Host colors: they work the same in Windows PowerShell 5.1 and PowerShell 7, in the old console and in Windows Terminal,
# with no escape codes. The colors mean one thing each:  Cyan = headings and steps, Green = good, Yellow = look at this,
# Red = problem, DarkGray = detail, White = the thing the line is about. The drop window uses the same names.

$script:UseColor = [string]::IsNullOrEmpty($env:NO_COLOR)
$script:Width = 60
$script:Hr = ([string][char]0x2500) * ($script:Width - 2)

$script:GuiPalette = @{
    Gray = @(200, 200, 200); DarkGray = @(125, 130, 140); White = @(245, 245, 245); Cyan = @(80, 210, 225); Green = @(105, 210, 115)
    Yellow = @(240, 200, 80); Red = @(245, 105, 105); Black = @(20, 20, 20); Magenta = @(210, 130, 225); DarkCyan = @(0, 150, 170)
}
$script:GuiColors = @{}

function Get-GuiColor([string]$Name) {
    if (-not $script:GuiColors.ContainsKey($Name)) {
        $rgb = $script:GuiPalette['Gray']
        if ($script:GuiPalette.ContainsKey($Name)) { $rgb = $script:GuiPalette[$Name] }
        $script:GuiColors[$Name] = [System.Drawing.Color]::FromArgb($rgb[0], $rgb[1], $rgb[2])
    }
    return $script:GuiColors[$Name]
}

# The one place text leaves the tool: the console, or the log box of the drop window.
function Emit([string]$Text, [string]$Fore = 'Gray', [string]$Back = '', [bool]$NewLine = $true) {
    if ($script:LogBox) {
        $box = $script:LogBox
        $box.SelectionStart = $box.TextLength
        $box.SelectionLength = 0
        $box.SelectionColor = (Get-GuiColor $Fore)
        if ($Back -ne '') { $box.SelectionBackColor = (Get-GuiColor $Back) } else { $box.SelectionBackColor = $box.BackColor }
        $box.AppendText(($Text -replace "`r", ''))
        if ($NewLine) { $box.AppendText("`n") }
        $box.SelectionStart = $box.TextLength
        $box.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
        return
    }
    $a = @{ Object = $Text; NoNewline = (-not $NewLine) }
    if ($script:UseColor) {
        $a.ForegroundColor = $Fore
        if ($Back -ne '') { $a.BackgroundColor = $Back }
    }
    Write-Host @a
}

function Say([string]$Text = '', [string]$Color = 'Gray') { Emit $Text $Color '' $true }

# a piece of a line (no line break), so one line can have several colors
function Part([string]$Text, [string]$Color = 'Gray') { Emit $Text $Color '' $false }

# a small colored label: [ OK ] [FAIL] [WARN] [SKIP] [INFO]
function Write-Badge([string]$Label, [string]$Back, [string]$Fore = 'Black') {
    if ($script:LogBox -or $script:UseColor) { Emit (' ' + $Label.PadRight(4) + ' ') $Fore $Back $false }
    else { Emit ('[' + $Label.PadRight(4) + ']') 'Gray' '' $false }
    Emit ' ' 'Gray' '' $false
}
function Write-Ok([string]$Text) { Write-Badge 'OK' 'Green'; Say $Text 'Green' }
function Write-Fail([string]$Text) { Write-Badge 'FAIL' 'Red' 'White'; Say $Text 'Red' }
function Write-Warn([string]$Text) { Write-Badge 'WARN' 'Yellow'; Say $Text 'Yellow' }
function Write-Skip([string]$Text) { Write-Badge 'SKIP' 'DarkGray' 'White'; Say $Text 'Gray' }
function Write-Info([string]$Text) { Write-Badge 'INFO' 'Cyan'; Say $Text 'Gray' }
function Write-Step([string]$Text) { Part '  > ' 'Cyan'; Say $Text 'White' }

function Write-Heading([string]$Text) {
    Say ''
    Say ('  ' + $Text) 'Cyan'
    Say ('  ' + $script:Hr) 'DarkGray'
}

function Show-Banner([string]$Title = 'PATCH MANAGER') {
    Say ''
    $line = ('  ' + $Title).PadRight($script:Width)
    if ($script:UseColor) { Write-Host $line -ForegroundColor Black -BackgroundColor Cyan } else { Write-Host $line }
}

function Set-WindowTitle([string]$Title) {
    try { $Host.UI.RawUI.WindowTitle = $Title } catch { }
}

function Format-Elapsed([TimeSpan]$Span) {
    if ($Span.TotalSeconds -lt 10) { return ('{0:N1}s' -f $Span.TotalSeconds) }
    if ($Span.TotalMinutes -lt 1) { return ('{0:N0}s' -f $Span.TotalSeconds) }
    return ('{0}m {1:D2}s' -f [int][math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

# ---------------------------------------------------------------- asking (console or window)

# One line of text from the person. In the console: Enter ends it (a file dragged in types its path). In the drop window: a small input box.
function Read-Line([string]$Prompt) {
    if ($script:LogBox) {
        return ([Microsoft.VisualBasic.Interaction]::InputBox($Prompt, 'Patch Manager', '')).Trim()
    }
    Part ('  ' + $Prompt + ' > ') 'Cyan'
    return ([string](Read-Host)).Trim()
}

# Asked with a line of text plus Enter on purpose (not a single key): a file dragged into the window types its path, and a
# path that happens to contain a "y" must never answer a question. Anything but y/yes counts as no.
function Ask-YesNo([string]$Question, [bool]$Default = $false) {
    if ($script:LogBox) {
        $btn = if ($Default) { [System.Windows.Forms.MessageBoxDefaultButton]::Button1 } else { [System.Windows.Forms.MessageBoxDefaultButton]::Button2 }
        $r = [System.Windows.Forms.MessageBox]::Show($script:Form, $Question, 'Patch Manager', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question, $btn)
        return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
    }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    Part ('  ? ' + $Question + ' ') 'Yellow'
    Part ($hint + ' ') 'DarkGray'
    $a = ([string](Read-Host)).Trim()
    if ($a -eq '') { return $Default }
    return ($a -match '^(y|yes)$')
}

function Wait-AnyKey([string]$Text = 'Press any key to close this window...') {
    Say ''
    Say ('  ' + $Text) 'DarkGray'
    try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    catch { [void](Read-Host) }
}

# ---------------------------------------------------------------- small helpers

# Run a program and capture its output and exit code. Native programs that write to stderr must not stop the script
# (Windows PowerShell 5.1 turns redirected stderr into errors), so errors are relaxed for the call.
function Invoke-Native([string]$Exe, [string[]]$ArgList) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $Exe @ArgList 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    return [pscustomobject]@{ Code = $code; Lines = $lines; Out = ($lines -join "`n") }
}

# Same, but every line is handed to a script block as it arrives (for long runs). Returns the exit code.
function Invoke-Git([string[]]$ArgList) { return (Invoke-Native 'git' $ArgList) }

# A git command whose own messages (push progress) should be seen live. Returns the exit code.
# Every unexpected error is also written to .patch-manager\errors.log (when the project folder is known), so it can be looked at later.
function Write-ErrorLog([string]$Where, $ErrorRecord) {
    try {
        if (-not $script:Store) { return }
        if (-not (Test-Path -LiteralPath $script:Store)) { New-Item -ItemType Directory -Path $script:Store -Force | Out-Null }
        $text = ('{0}  {1}: {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Where, $ErrorRecord.Exception.Message) + "`n" + [string]$ErrorRecord.ScriptStackTrace + "`n`n"
        [IO.File]::AppendAllText((Join-Path $script:Store 'errors.log'), $text)
    }
    catch { }   # the log is a convenience: never let it cause a second error
}

# Show an error in plain words and keep going. Returns $false when the block failed.
function Invoke-Safe([string]$What, [scriptblock]$Block) {
    try { & $Block; return $true }
    catch {
        Say ''
        Write-Fail ('Problem while {0}: {1}' -f $What, $_.Exception.Message)
        Say '       (details are in .patch-manager\errors.log)' 'DarkGray'
        Write-ErrorLog $What $_
        return $false
    }
}

# The PowerShell that is running this script (so a shortcut or a new window uses the same one)
function Remove-OuterQuotes([string]$Text) {
    $p = $Text.Trim()
    if ($p.Length -ge 2 -and (($p.StartsWith('"') -and $p.EndsWith('"')) -or ($p.StartsWith("'") -and $p.EndsWith("'")))) { $p = $p.Substring(1, $p.Length - 2) }
    return $p
}

# ---------------------------------------------------------------- help

function Show-HelpLine([string]$Key, [string]$Text) {
    Part ('  ' + $Key.PadRight(17)) 'Cyan'
    Say $Text 'Gray'
}

function Show-Help {
    if (-not $script:LogBox) { Show-Banner 'PATCH MANAGER - HELP' }
    Say ''
    Say '  Applies a .patch file to the git project it sits in: checks it, saves a safety snapshot, applies it, and remembers it so it can be undone.' 'Gray'
    Say '  It never forces a patch and never overwrites a file that does not match the patch.' 'Gray'

    Write-Heading 'Giving it a patch (the file can be anywhere)'
    Say '  1. In the text menu choose 1, drag the file into the window, press Enter. (Dropping it straight onto the menu works too.)' 'Gray'
    Say '  2. From a terminal:  .\PatchManager.ps1 "C:\path\to\fix.patch"   (several files are applied in order)' 'Gray'

    Write-Heading 'Menu'
    Show-HelpLine '1' 'Apply a patch'
    Show-HelpLine '2' 'Review a patch: is it applied? Then see the changes in colors.'
    Show-HelpLine '3' 'Undo an applied patch (only if the files still match)'
    Show-HelpLine '4' 'Show the history'
    Show-HelpLine 'D' 'Show the changes of a patch in colors, file by file'
    Show-HelpLine 'R' 'Restore a safety snapshot (puts the files a patch touched back)'
    Show-HelpLine '5' 'Exit'

    Write-Heading 'What happens to each patch'
    Say '  1. It is read, and refused if it touches anything outside the project or inside .git.' 'Gray'
    Say '  2. A summary is shown: size, SHA256, the files, lines added and removed.' 'Gray'
    Say '  3. It is checked against your files. Already applied: skipped. Conflict: stopped, nothing changed.' 'Gray'
    Say '  4. A safety snapshot of the files it touches is saved inside git (a moment, no zip).' 'Gray'
    Say '  5. It is applied, checked once more, and written to the history with a copy of the patch.' 'Gray'

    Write-Heading 'When a patch conflicts'
    Say '  You are asked whether to apply the parts that fit. The parts that do not fit are written next to the file as .rej files' 'Gray'
    Say '  (fix them by hand, then delete them). The snapshot lets you go back with R.' 'Gray'

    Write-Heading 'Options (terminal)'
    Show-HelpLine '-DryRun' 'check only, change nothing'
    Show-HelpLine '-Undo' 'undo an applied patch'
    Show-HelpLine '-History' 'show what was applied'
    Show-HelpLine '-Review' 'is this patch applied? (no changes)'
    Show-HelpLine '-Close' 'close the window when done instead of going to the menu'
    Show-HelpLine '-Help' 'this text'

    Write-Heading 'Good to know'
    Say '  - Patches that depend on each other go in order. If one fails, the ones before it stay applied and the rest are untouched.' 'Gray'
    Say '  - Undo works only if the files still match: newer patches that changed the same files must be undone first.' 'Gray'
    Say '  - History and patch copies: .patch-manager\ in the project (excluded through .git\info\exclude, never committed).' 'Gray'
}

# ---------------------------------------------------------------- history

# A list that may hold lists (an old history file written by the 5.1 quirk): the entries only, one flat list
function Expand-Flat($Items) {
    foreach ($i in @($Items)) {
        if ($i -is [System.Array]) { Expand-Flat $i } else { $i }
    }
}

function Read-PatchHistory {
    if (-not (Test-Path -LiteralPath $script:HistoryFile)) { return @() }
    $raw = [IO.File]::ReadAllText($script:HistoryFile)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    try { $null = ConvertFrom-Json -InputObject $raw -ErrorAction Stop }
    catch {
        # The history file cannot be read (edited by hand, or cut off). Keep it under another name, start a new one, and say so.
        $kept = Join-Path $script:Store ('history.damaged-{0}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
        try { Move-Item -LiteralPath $script:HistoryFile -Destination $kept -Force } catch { }
        Write-Warn ('The history file could not be read, so it was kept as ' + (Split-Path -Leaf $kept) + ' and a new history was started.')
        return @()
    }
    # Windows PowerShell 5.1 hands a JSON array back as ONE object, and piping it to ConvertFrom-Json then wrapping it in @() leaves a list inside a list
    # once there are two or more entries. Read it with -InputObject and unroll it by hand, so both versions give a flat list.
    $items = ConvertFrom-Json -InputObject $raw
    return @(Expand-Flat $items)
}

function Save-PatchHistory($Items) {
    if (-not (Test-Path -LiteralPath $script:Store)) { New-Item -ItemType Directory -Path $script:Store -Force | Out-Null }
    $json = ConvertTo-Json -InputObject @($Items) -Depth 6
    [IO.File]::WriteAllText($script:HistoryFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Show-PatchHistory {
    $hist = @(Read-PatchHistory)
    Write-Heading 'Patch history (newest last)'
    if ($hist.Count -eq 0) { Say '  Nothing applied through this tool yet.' 'Yellow'; return }
    foreach ($h in $hist) {
        $undone = [bool]$h.undone
        $color = if ($undone) { 'DarkGray' } else { 'Gray' }
        Part ('  {0,3}  ' -f $h.id) 'Cyan'
        Part ('{0}  ' -f $h.appliedAt) 'DarkGray'
        Part ('{0,-40} ' -f $h.name) $(if ($undone) { 'DarkGray' } else { 'White' })
        Part ('{0,3} files  ' -f $h.files) $color
        if ($undone) { Say 'undone' 'DarkGray' }
        elseif ($h.partial) { Say 'partly applied' 'Yellow' }
        else { Say 'applied' 'Green' }
    }
}

# A new history entry for a patch that was just applied. Returns its number.
function Add-HistoryEntry($File, [string]$Hash, $Info, [string]$Snapshot, [bool]$Partial) {
    $hist = @(Read-PatchHistory)
    $id = 1
    $known = @()
    foreach ($h in $hist) { foreach ($v in @($h.id)) { $n = 0; if ([int]::TryParse([string]$v, [ref]$n)) { $known += $n } } }
    if ($known.Count -gt 0) { $id = ([int]($known | Measure-Object -Maximum).Maximum) + 1 }
    if (-not (Test-Path -LiteralPath $script:PatchStore)) { New-Item -ItemType Directory -Path $script:PatchStore -Force | Out-Null }
    $stored = ('{0:D3}-{1}' -f $id, $File.Name)
    Copy-Item -LiteralPath $File.FullName -Destination (Join-Path $script:PatchStore $stored) -Force
    $entry = [pscustomobject]@{
        id = $id; name = $File.Name; sha256 = $Hash; appliedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        files = $Info.Files.Count; added = $Info.Added; removed = $Info.Removed; stored = $stored; undone = $false; undoneAt = ''
        snapshot = $Snapshot; partial = $Partial
    }
    $hist += $entry
    Save-PatchHistory $hist
    return $id
}

# ---------------------------------------------------------------- repository

# Add the tool's data folder to .git\info\exclude (local to this clone), so no tracked file changes and nothing lands in a commit
function Add-StoreToExclude {
    try {
        $g = Invoke-Git @('rev-parse', '--git-path', 'info/exclude')
        if ($g.Code -ne 0 -or [string]::IsNullOrWhiteSpace($g.Out)) { return }
        $path = $g.Out.Trim()
        if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $script:Repo $path }
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $have = ''
        if (Test-Path -LiteralPath $path -PathType Leaf) { $have = [IO.File]::ReadAllText($path) }
        if ($have -notmatch '(?m)^/?\.patch-manager/?\s*$') {
            $lead = ''
            if ($have -ne '' -and -not $have.EndsWith("`n")) { $lead = "`n" }
            [IO.File]::AppendAllText($path, $lead + "# Patch Manager keeps its own data here`n.patch-manager/`n")
        }
    }
    catch { }
}

# The project is the git repository that contains this script; if the script is not inside one, the folder it was started from.
function Test-Repository {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Fail 'git was not found. Install Git for Windows first.'; return $false }
    $script:StartDir = (Get-Location).Path
    $top = $null
    foreach ($dir in @($ScriptDir, $script:StartDir)) {
        $t = Invoke-Git @('-C', $dir, 'rev-parse', '--show-toplevel')
        if ($t.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($t.Out)) { $top = $t.Out.Trim(); break }
    }
    if (-not $top) { Write-Fail 'No git project found. Keep this script inside a git project, or start it from one.'; return $false }
    $script:Repo = [IO.Path]::GetFullPath($top)
    Set-Location -LiteralPath $script:Repo
    $script:Store = Join-Path $script:Repo '.patch-manager'
    $script:PatchStore = Join-Path $script:Store 'patches'
    $script:HistoryFile = Join-Path $script:Store 'history.json'
    Add-StoreToExclude
    return $true
}

# Where things stand: branch, uncommitted files, commits not pushed yet
function Show-Status {
    $branch = Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')
    $b = if ($branch.Code -eq 0) { $branch.Out.Trim() } else { '(no commits yet)' }
    $dirty = @((Invoke-Git @('status', '--porcelain')).Lines | Where-Object { $_ -match '\S' }).Count
    Say ''
    Part '  Project   ' 'DarkGray'; Say $script:Repo 'Gray'
    Part '  Branch    ' 'DarkGray'; Part $b 'White'
    Part '     uncommitted: ' 'DarkGray'
    if ($dirty -eq 0) { Say 'none' 'Green' } else { Say ('{0} file(s)' -f $dirty) 'Yellow' }
}

# ---------------------------------------------------------------- safety snapshots (inside git, no zip)

# Saves the whole working tree (tracked and new files, not ignored ones) as a commit that no branch points to, named refs/patch-manager/<time>.
# It uses a temporary index, so your staged changes, branches and files are not touched at all. The first line of the message says what it is
# for; the lines after a blank line are the files a restore will put back. Returns the ref name, or $null when it could not be made.
function New-Snapshot([string]$Label, [string[]]$Paths) {
    $tmpIndex = Join-Path ([IO.Path]::GetTempPath()) ('xp-index-' + [guid]::NewGuid().ToString('N'))
    $msgFile = Join-Path ([IO.Path]::GetTempPath()) ('xp-msg-' + [guid]::NewGuid().ToString('N') + '.txt')
    $oldIndex = $env:GIT_INDEX_FILE
    $tree = $null
    try {
        $env:GIT_INDEX_FILE = $tmpIndex
        $head = Invoke-Git @('rev-parse', '--verify', '--quiet', 'HEAD')
        if ($head.Code -eq 0) {
            $rt = Invoke-Git @('read-tree', 'HEAD')
            if ($rt.Code -ne 0) { return $null }
        }
        $add = Invoke-Git @('add', '-A')
        if ($add.Code -ne 0) { return $null }
        $wt = Invoke-Git @('write-tree')
        if ($wt.Code -ne 0) { return $null }
        $tree = $wt.Out.Trim()
    }
    finally {
        if ($null -eq $oldIndex) { Remove-Item -LiteralPath Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue } else { $env:GIT_INDEX_FILE = $oldIndex }
        Remove-Item -LiteralPath $tmpIndex -Force -ErrorAction SilentlyContinue
    }
    try {
        $text = 'patch-manager snapshot: ' + $Label + "`n`n" + (@($Paths) -join "`n") + "`n"
        [IO.File]::WriteAllText($msgFile, $text, (New-Object System.Text.UTF8Encoding($false)))
        $ct = @('-c', 'user.name=Patch Manager', '-c', 'user.email=patch-manager@localhost', 'commit-tree', $tree)
        $head2 = Invoke-Git @('rev-parse', '--verify', '--quiet', 'HEAD')
        if ($head2.Code -eq 0) { $ct += @('-p', $head2.Out.Trim()) }
        $ct += @('-F', $msgFile)
        $c = Invoke-Git $ct
        if ($c.Code -ne 0 -or $c.Out.Trim() -notmatch '^[0-9a-f]{40,64}$') { return $null }
        $ref = 'refs/patch-manager/' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
        $u = Invoke-Git @('update-ref', $ref, $c.Out.Trim())
        if ($u.Code -ne 0) { return $null }
        Remove-OldSnapshots 30
        return $ref
    }
    catch { return $null }
    finally { Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue }
}

function Remove-OldSnapshots([int]$Keep) {
    $all = @((Invoke-Git @('for-each-ref', '--sort=refname', '--format=%(refname)', 'refs/patch-manager/')).Lines | Where-Object { $_ -match '^refs/' })
    if ($all.Count -le $Keep) { return }
    foreach ($r in ($all | Select-Object -First ($all.Count - $Keep))) { [void](Invoke-Git @('update-ref', '-d', $r)) }
}

# The files of a patch, written out: a rename shown as "old => new" (or "dir/{old => new}/x") becomes both paths
function Get-PatchPaths($Files) {
    $out = New-Object System.Collections.ArrayList
    foreach ($f in @($Files)) {
        $p = [string]$f
        if ($p -match '^(.*)\{(.*) => (.*)\}(.*)$') {
            $a = $Matches[1]; $b = $Matches[2]; $c = $Matches[3]; $d = $Matches[4]
            [void]$out.Add(($a + $b + $d) -replace '//', '/')
            [void]$out.Add(($a + $c + $d) -replace '//', '/')
        }
        elseif ($p -match '^(.*) => (.*)$') { [void]$out.Add($Matches[1]); [void]$out.Add($Matches[2]) }
        else { [void]$out.Add($p) }
    }
    return @($out | Select-Object -Unique)
}

# Menu R: put the files of a snapshot back the way they were.
function Invoke-RestoreSnapshot {
    Write-Heading 'Restore a safety snapshot'
    $rows = @((Invoke-Git @('for-each-ref', '--sort=-refname', '--format=%(refname)%09%(subject)', 'refs/patch-manager/')).Lines | Where-Object { $_ -match '^refs/' } | Select-Object -First 15)
    if ($rows.Count -eq 0) { Say '  No snapshots yet. One is saved before every patch is applied or undone.' 'Yellow'; return $false }
    $i = 0
    foreach ($row in $rows) {
        $i++
        $parts = $row -split "`t", 2
        $leaf = $parts[0].Substring($parts[0].LastIndexOf('/') + 1)
        $when = $leaf
        if ($leaf -match '^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})') { $when = ('{0}-{1}-{2} {3}:{4}:{5}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5], $Matches[6]) }
        $what = if ($parts.Count -gt 1) { $parts[1] -replace '^patch-manager snapshot: ', '' } else { '' }
        Part ('  {0,3}  ' -f $i) 'Cyan'
        Part ($when + '  ') 'DarkGray'
        Say $what 'White'
    }
    Say '  A snapshot holds the files that patch touched, as they were just before. Newer work in those files is replaced.' 'DarkGray'
    $answer = Read-Line 'Snapshot number (Enter = the newest)'
    $pick = 1
    if ($answer -ne '') {
        if (-not [int]::TryParse($answer, [ref]$pick) -or $pick -lt 1 -or $pick -gt $rows.Count) { Write-Fail 'No such number.'; return $false }
    }
    $ref = ($rows[$pick - 1] -split "`t", 2)[0]
    $paths = @((Invoke-Git @('log', '-1', '--format=%b', $ref)).Lines | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() })
    if ($paths.Count -eq 0) { Write-Fail 'That snapshot lists no files.'; return $false }

    Say ''
    Say ('  {0} file(s) will be put back:' -f $paths.Count) 'Gray'
    foreach ($p in ($paths | Select-Object -First 15)) {
        $there = ((Invoke-Git @('cat-file', '-e', ($ref + ':' + $p))).Code -eq 0)
        if ($there) { Say ('         restore  ' + $p) 'Gray' } else { Say ('         remove   ' + $p + '  (it was not there before)') 'Yellow' }
    }
    if ($paths.Count -gt 15) { Say ('         ... and {0} more' -f ($paths.Count - 15)) 'DarkGray' }
    if ($DryRun) { Write-Skip 'Dry run: nothing restored.'; return $true }
    if (-not (Ask-YesNo 'Restore these files now? (a snapshot of how they are now is saved first)' $false)) { Say '  Cancelled.' 'Yellow'; return $false }

    $now = New-Snapshot 'before restoring a snapshot' $paths
    if (-not $now) {
        Write-Warn 'Could not save a snapshot of the current state first.'
        if (-not (Ask-YesNo 'Restore anyway?' $false)) { return $false }
    }
    foreach ($p in $paths) {
        $there = ((Invoke-Git @('cat-file', '-e', ($ref + ':' + $p))).Code -eq 0)
        if ($there) {
            $r = Invoke-Git @('restore', ('--source=' + $ref), '--worktree', '--', (':(literal)' + $p))
            if ($r.Code -ne 0) { Write-Fail ('Could not restore ' + $p); Say ('         ' + $r.Out) 'DarkGray' }
        }
        else {
            foreach ($suffix in '', '.rej', '.orig') {
                $full = Join-Path $script:Repo (($p + $suffix) -replace '/', '\')
                $inSnap = ((Invoke-Git @('cat-file', '-e', ($ref + ':' + $p + $suffix))).Code -eq 0)
                if (-not $inSnap -and (Test-Path -LiteralPath $full -PathType Leaf)) { Remove-Item -LiteralPath $full -Force }
            }
        }
    }
    Write-Ok ('Restored {0} file(s).' -f $paths.Count)
    if ($now) { Say '       The state from just before the restore is also saved: restore it the same way to undo this.' 'DarkGray' }
    return $true
}

# ---------------------------------------------------------------- reading a patch

function Get-PatchInfo([string]$Path) {
    $r = Invoke-Git @('apply', '--numstat', $Path)
    if ($r.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Message = $r.Out; Files = @(); Added = 0; Removed = 0 } }
    $files = @(); $added = 0; $removed = 0
    foreach ($line in $r.Lines) {
        if ($line -match '^(\d+|-)\t(\d+|-)\t(.+)$') {
            if ($Matches[1] -ne '-') { $added += [int]$Matches[1] }
            if ($Matches[2] -ne '-') { $removed += [int]$Matches[2] }
            $files += $Matches[3]
        }
    }
    return [pscustomobject]@{ Ok = $true; Message = ''; Files = $files; Added = $added; Removed = $removed }
}

# A patch may only touch files inside the repository, and never inside .git
function Get-UnsafePaths($Files) {
    return @($Files | Where-Object { $_ -match '(^|[\\/])\.\.([\\/]|$)' -or $_ -match '^([A-Za-z]:|[\\/])' -or $_ -match '(^|[\\/])\.git([\\/]|$)' })
}

function Get-PatchState([string]$Path) {
    $fwd = Invoke-Git @('apply', '--check', '--whitespace=nowarn', $Path)
    if ($fwd.Code -eq 0) { return [pscustomobject]@{ State = 'Clean'; Message = '' } }
    $rev = Invoke-Git @('apply', '--check', '--reverse', '--whitespace=nowarn', $Path)
    if ($rev.Code -eq 0) { return [pscustomobject]@{ State = 'AlreadyApplied'; Message = '' } }
    return [pscustomobject]@{ State = 'Conflict'; Message = $fwd.Out }
}

function Show-PatchSummary($File, $Info, [string]$Hash) {
    $kb = [math]::Round($File.Length / 1KB, 1)
    Say ('  Path   ' + $File.FullName) 'DarkGray'
    Say ('  Size   {0} KB     SHA256 {1}...' -f $kb, $Hash.Substring(0, 12)) 'DarkGray'
    Part '  Files  ' 'DarkGray'
    Part ('{0} changed  ' -f $Info.Files.Count) 'Gray'
    Part ('+{0} ' -f $Info.Added) 'Green'
    Say ('-{0}' -f $Info.Removed) 'Red'
    $shown = 0
    foreach ($f in $Info.Files) {
        if ($shown -ge 25) { Say ('         ... and {0} more' -f ($Info.Files.Count - 25)) 'DarkGray'; break }
        Say ('         ' + $f) 'Gray'
        $shown++
    }
    $watch = @($Info.Files | Where-Object { $_ -match '^(package(-lock)?\.json|\.github/)' })
    if ($watch.Count -gt 0) { Write-Warn ('Look at this one: it changes ' + ($watch -join ', ')) }
}

# ---------------------------------------------------------------- colored changes of a patch

# One line of a patch, in color: + green, - red, @@ magenta, file headers cyan, the rest grey
function Write-DiffLine([string]$Line) {
    if ($Line.StartsWith('+++') -or $Line.StartsWith('---')) { Say ('  ' + $Line) 'DarkGray' }
    elseif ($Line.StartsWith('+')) { Say ('  ' + $Line) 'Green' }
    elseif ($Line.StartsWith('-')) { Say ('  ' + $Line) 'Red' }
    elseif ($Line.StartsWith('@@')) { Say ('  ' + $Line) 'Magenta' }
    elseif ($Line.StartsWith('diff --git') -or $Line.StartsWith('index ') -or $Line.StartsWith('new file') -or $Line.StartsWith('deleted file') -or $Line.StartsWith('rename ') -or $Line.StartsWith('similarity ') -or $Line.StartsWith('old mode') -or $Line.StartsWith('new mode')) { Say ('  ' + $Line) 'DarkGray' }
    else { Say ('  ' + $Line) 'Gray' }
}

# The patch cut into one section per file
function Get-PatchSections([string]$Path) {
    $lines = [IO.File]::ReadAllLines($Path)
    $sections = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($l in $lines) {
        if ($l.StartsWith('diff --git ')) {
            $name = $l
            if ($l -match '^diff --git a/(.*) b/(.*)$') { $name = $Matches[2] }
            $cur = [pscustomobject]@{ Name = $name; Lines = (New-Object System.Collections.ArrayList); Added = 0; Removed = 0 }
            [void]$sections.Add($cur)
        }
        if ($null -eq $cur) {
            # a patch with no "diff --git" header: one section for everything
            $cur = [pscustomobject]@{ Name = '(patch)'; Lines = (New-Object System.Collections.ArrayList); Added = 0; Removed = 0 }
            [void]$sections.Add($cur)
        }
        [void]$cur.Lines.Add($l)
        if ($l.StartsWith('+') -and -not $l.StartsWith('+++')) { $cur.Added++ }
        elseif ($l.StartsWith('-') -and -not $l.StartsWith('---')) { $cur.Removed++ }
    }
    return @($sections)
}

# The changes of a patch, file by file. In the console, 70 lines at a time with a question; in the window, everything (it scrolls).
function Show-PatchDiff($File, [bool]$Pager = $true) {
    Write-Heading ('Changes: ' + $File.Name)
    $sections = @(Get-PatchSections $File.FullName)
    if ($sections.Count -eq 0) { Say '  The patch is empty.' 'Yellow'; return }
    $page = 70
    $showAll = (-not $Pager) -or [bool]$script:LogBox
    for ($i = 0; $i -lt $sections.Count; $i++) {
        $s = $sections[$i]
        Say ''
        Part ('  [{0}/{1}] ' -f ($i + 1), $sections.Count) 'DarkGray'
        Part ($s.Name + '   ') 'Cyan'
        Part ('+{0} ' -f $s.Added) 'Green'
        Say ('-{0}' -f $s.Removed) 'Red'
        $total = $s.Lines.Count
        $limit = if ($showAll) { 3000 } else { $page }
        $shown = 0
        while ($shown -lt $total) {
            $upto = [math]::Min($total, $shown + $limit)
            for ($k = $shown; $k -lt $upto; $k++) { Write-DiffLine ([string]$s.Lines[$k]) }
            $shown = $upto
            if ($shown -ge $total) { break }
            if ($showAll) { Say ('  ... {0} more line(s) not shown' -f ($total - $shown)) 'DarkGray'; break }
            $a = (Read-Line ('{0} more line(s) in this file. Enter = more, n = next file, a = show all, q = stop' -f ($total - $shown))).ToLower()
            if ($a -eq 'q') { return }
            if ($a -eq 'n') { break }
            if ($a -eq 'a') { $showAll = $true; $limit = 100000 }
        }
        if (-not $showAll -and $i -lt ($sections.Count - 1)) {
            $a = (Read-Line 'Enter = next file, a = show all the rest, q = stop').ToLower()
            if ($a -eq 'q') { return }
            if ($a -eq 'a') { $showAll = $true }
        }
    }
    Say ''
}

# ---------------------------------------------------------------- apply

# The parts of a conflicting patch that fit are applied; the parts that do not fit go to .rej files next to the files.
# Returns 'partial' (stops a stack of patches, like a failure) or 'failed'.
function Invoke-PartialApply($File, [string]$Path, $Info, [string]$Hash) {
    $paths = @(Get-PatchPaths $Info.Files)
    $snap = New-Snapshot ('before partly applying ' + $File.Name) $paths
    if (-not $snap) { Write-Fail 'Could not save the safety snapshot, so nothing was applied.'; return 'failed' }
    Write-Ok 'Safety snapshot saved (menu R restores it).'
    Write-Step 'Applying the parts that fit...'
    $r = Invoke-Git @('apply', '--reject', '--whitespace=nowarn', $Path)
    $rejects = @()
    foreach ($p in $paths) {
        $rp = Join-Path $script:Repo (($p + '.rej') -replace '/', '\')
        if (Test-Path -LiteralPath $rp -PathType Leaf) { $rejects += $rp }
    }
    if ($r.Code -ne 0 -and $rejects.Count -eq 0) {
        Write-Fail 'Nothing could be applied. The files were not changed.'
        Say $r.Out 'DarkGray'
        return 'failed'
    }
    Write-Warn ('Applied the parts that fit. {0} file(s) have parts that did NOT fit:' -f $rejects.Count)
    foreach ($rp in $rejects) {
        $n = @(Get-Content -LiteralPath $rp | Where-Object { $_ -like '@@*' }).Count
        Say ('         {0}   ({1} part(s) left over)' -f $rp.Substring($script:Repo.Length + 1), $n) 'Yellow'
    }
    Say '       The leftovers are in the .rej files next to them. Fix those by hand, then delete the .rej files.' 'Yellow'
    Say '       To go back to how things were: menu R (restore a snapshot).' 'Yellow'
    try {
        $id = Add-HistoryEntry $File $Hash $Info $snap $true
        Say ('       Recorded in the history as #{0} (partly applied).' -f $id) 'DarkGray'
    }
    catch { Write-ErrorLog 'writing the history' $_ }
    return 'partial'
}

# returns 'applied', 'partial', 'skipped' or 'failed'
function Invoke-ApplyPatch($File) {
    $path = $File.FullName
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Write-Heading $File.Name

    $info = Get-PatchInfo $path
    if (-not $info.Ok) {
        Write-Fail 'Cannot read this file as a patch. Nothing applied.'
        Say $info.Message 'DarkGray'
        return 'failed'
    }
    $unsafe = Get-UnsafePaths $info.Files
    if ($unsafe.Count -gt 0) {
        Write-Fail 'This patch touches paths outside the project or inside .git. Refused.'
        $unsafe | ForEach-Object { Say ('         ' + $_) 'Red' }
        return 'failed'
    }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower()
    Show-PatchSummary $File $info $hash
    Say ''

    $hist = @(Read-PatchHistory)
    $sameName = @($hist | Where-Object { $_.name -eq $File.Name -and $_.sha256 -ne $hash -and -not $_.undone })
    if ($sameName.Count -gt 0) { Write-Info 'A different patch with this name was applied before (this is a newer version of the file).' }

    $state = Get-PatchState $path
    if ($state.State -eq 'AlreadyApplied') {
        Write-Skip 'Already applied: the changes are already in the files. Skipped.'
        return 'skipped'
    }
    if ($state.State -eq 'Conflict') {
        Write-Fail 'CONFLICT. Nothing applied.'
        $state.Message -split "`n" | Select-Object -First 8 | ForEach-Object { Say ('         ' + $_) 'DarkGray' }
        Say '       Usual causes: an earlier patch in the stack is not applied yet, or one of these files was edited after the patch was made.' 'Yellow'
        if (-not $DryRun -and (Ask-YesNo 'Apply the parts that fit, and leave the rest in .rej files?' $false)) {
            return (Invoke-PartialApply $File $path $info $hash)
        }
        return 'failed'
    }
    Write-Ok 'No conflicts.'

    if ($DryRun) { Write-Skip 'Dry run: not applied.'; return 'skipped' }

    # The safety net: a snapshot of the files this patch touches, saved inside git. A moment, no zip.
    $snap = New-Snapshot ('before applying ' + $File.Name) @(Get-PatchPaths $info.Files)
    if ($snap) { Write-Ok 'Safety snapshot saved (menu R restores it).' }
    else {
        Write-Warn 'Could not save the safety snapshot.'
        if (-not (Ask-YesNo 'Apply the patch anyway?' $false)) { Write-Skip 'Not applied.'; return 'failed' }
    }

    Write-Step 'Applying...'
    $r = Invoke-Git @('apply', '--whitespace=nowarn', $path)
    if ($r.Code -ne 0) {
        Write-Fail 'Applying failed. The files were not changed (git applies a patch completely or not at all).'
        Say $r.Out 'DarkGray'
        return 'failed'
    }
    # proof that it landed: the reverse of the patch must now apply
    $proof = Invoke-Git @('apply', '--check', '--reverse', '--whitespace=nowarn', $path)
    if ($proof.Code -ne 0) { Write-Warn 'The patch applied, but the check afterwards did not agree. Run git status and look.' }

    try {
        $id = Add-HistoryEntry $File $hash $info $snap $false
        Write-Ok ('Applied (history #{0}) in {1}.' -f $id, (Format-Elapsed $clock.Elapsed))
    }
    catch {
        Write-Warn 'The patch IS applied, but writing it to the history failed, so it cannot be undone from this tool:'
        Say ('       ' + $_.Exception.Message) 'Yellow'
        Write-ErrorLog 'writing the history' $_
    }
    return 'applied'
}

# ---------------------------------------------------------------- choosing patches (by path)

# One path: quotes removed, must be an existing file. Returns a list of files (a comma list becomes several), or $null
function Resolve-PatchPath([string]$Text, [bool]$Quiet = $false) {
    $p = Remove-OuterQuotes $Text
    if ($p -eq '') { return $null }
    if ($script:StartDir -and -not [IO.Path]::IsPathRooted($p) -and (Test-Path -LiteralPath (Join-Path $script:StartDir $p) -PathType Leaf)) { $p = Join-Path $script:StartDir $p }
    if (Test-Path -LiteralPath $p -PathType Leaf) { return @(Get-Item -LiteralPath $p) }
    if ($p.Contains(',')) {
        # "a.patch,b.patch" arrives as one string through powershell -File
        $all = @()
        foreach ($part in ($p -split ',')) {
            $f = Resolve-PatchPath $part $Quiet
            if ($null -eq $f) { return $null }
            $all += $f
        }
        return $all
    }
    if (-not $Quiet) {
        Write-Fail "Cannot find a file at: $p"
        Say '       Drag the patch file into this window, or paste its full path.' 'Yellow'
    }
    return $null
}

# What Read-Host returns after files were dragged in: each file is a quoted path, separated by spaces
function Resolve-DroppedText([string]$Text) {
    $t = $Text.Trim()
    if ($t.StartsWith('& ')) { $t = $t.Substring(2).Trim() }
    if ($t -eq '') { return @() }
    $whole = Resolve-PatchPath $t $true
    if ($null -ne $whole -and @($whole).Count -eq 1) { return @($whole) }
    $files = @()
    foreach ($m in [regex]::Matches($t, '"([^"]*)"|''([^'']*)''|(\S+)')) {
        $piece = if ($m.Groups[1].Success) { $m.Groups[1].Value } elseif ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value }
        $f = Resolve-PatchPath $piece
        if ($null -eq $f) { return @() }
        $files += $f
    }
    return $files
}

function Read-DroppedPatches([string]$PromptLine = 'Drag the patch file (or several) into this window, then press Enter.') {
    Say ''
    Write-Step $PromptLine
    Say '    Several files are handled in the order they appear in the line. Enter alone goes back.' 'DarkGray'
    return @(Resolve-DroppedText (Read-Line 'Patch'))
}

# ---------------------------------------------------------------- review: is this patch applied?

# For one file of the patch: 'applied' (its changes are in), 'open' (it would apply), 'conflict' (neither)
function Get-FileState([string]$Path, [string]$FileName) {
    $fwd = Invoke-Git @('apply', '--check', '--whitespace=nowarn', "--include=$FileName", $Path)
    if ($fwd.Code -eq 0) { return 'open' }
    $rev = Invoke-Git @('apply', '--check', '--reverse', '--whitespace=nowarn', "--include=$FileName", $Path)
    if ($rev.Code -eq 0) { return 'applied' }
    return 'conflict'
}

function Show-PatchReview($File) {
    $path = $File.FullName
    Write-Heading ('Review: ' + $File.Name)
    $info = Get-PatchInfo $path
    if (-not $info.Ok) {
        Write-Fail 'Cannot read this file as a patch.'
        Say $info.Message 'DarkGray'
        return
    }
    $unsafe = Get-UnsafePaths $info.Files
    if ($unsafe.Count -gt 0) {
        Write-Fail 'This patch touches paths outside the project or inside .git. It would be refused.'
        $unsafe | ForEach-Object { Say ('         ' + $_) 'Red' }
        return
    }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower()
    Show-PatchSummary $File $info $hash

    $state = Get-PatchState $path
    $perFile = @()
    if ($state.State -eq 'Conflict') {
        foreach ($f in $info.Files) { $perFile += [pscustomobject]@{ File = $f; State = (Get-FileState $path $f) } }
    }
    Say ''
    if ($state.State -eq 'AlreadyApplied') {
        Write-Ok 'APPLIED: every change of this patch is already in your files.'
    }
    elseif ($state.State -eq 'Clean') {
        Write-Warn 'NOT APPLIED: none of it is in your files yet, and it would apply cleanly.'
    }
    else {
        $applied = @($perFile | Where-Object { $_.State -eq 'applied' }).Count
        $open = @($perFile | Where-Object { $_.State -eq 'open' }).Count
        $bad = @($perFile | Where-Object { $_.State -eq 'conflict' }).Count
        if ($applied -gt 0 -and $bad -eq 0) { Write-Warn ('PARTLY APPLIED: {0} of {1} files are in, {2} are not yet.' -f $applied, $perFile.Count, $open) }
        elseif ($applied -gt 0) { Write-Warn ('PARTLY APPLIED, AND CHANGED SINCE: {0} files are in, {1} do not match, {2} are not yet.' -f $applied, $bad, $open) }
        else { Write-Fail 'CANNOT APPLY: the files do not match this patch (an earlier patch is missing, or they were edited since it was made).' }
        foreach ($p in $perFile) {
            $label = switch ($p.State) { 'applied' { 'in      ' } 'open' { 'not yet ' } default { 'DIFFERS ' } }
            $color = switch ($p.State) { 'applied' { 'Green' } 'open' { 'Yellow' } default { 'Red' } }
            Say ('         ' + $label + $p.File) $color
        }
    }

    # what this tool remembers about it
    $hist = @(Read-PatchHistory)
    $mine = @($hist | Where-Object { $_.sha256 -eq $hash })
    if ($mine.Count -eq 0) {
        $named = @($hist | Where-Object { $_.name -eq $File.Name })
        if ($named.Count -gt 0) { Say '  History: a patch with this name was applied before, but this file is a different version of it.' 'DarkGray' }
        else { Say '  History: this tool has not applied it (it may have been applied some other way, or not at all).' 'DarkGray' }
    }
    else {
        $last = $mine | Sort-Object { [int]$_.id } | Select-Object -Last 1
        if ($last.undone) { Say ('  History: applied as #{0} on {1}, undone on {2}.' -f $last.id, $last.appliedAt, $last.undoneAt) 'DarkGray' }
        else { Say ('  History: applied by this tool as #{0} on {1}.' -f $last.id, $last.appliedAt) 'DarkGray' }
        if (-not $last.undone -and $state.State -eq 'Clean') { Write-Warn 'The history says it is applied, but your files no longer have it (reverted by hand, or the files were replaced).' }
        if ($last.undone -and $state.State -eq 'AlreadyApplied') { Write-Warn 'The history says it was undone, but your files have it (applied again some other way).' }
    }
}

# $OfferChanges: after the reviews, ask whether to show the changes in colors (the text menu does; the window has its own button)
function Invoke-ReviewMany($Files, [bool]$OfferChanges = $false) {
    foreach ($f in $Files) { Show-PatchReview $f }
    Say ''
    if ($OfferChanges -and (Ask-YesNo 'Show the changes in colors?' $false)) {
        foreach ($f in $Files) { Show-PatchDiff $f $true }
    }
}

# ---------------------------------------------------------------- many, undo

function Invoke-ApplyMany($Files) {
    $applied = 0; $skipped = 0; $stopped = $false
    $rows = @()
    $all = @($Files)
    for ($i = 0; $i -lt $all.Count; $i++) {
        $f = $all[$i]
        try { $result = Invoke-ApplyPatch $f }
        catch {
            Say ''
            Write-Fail ('Unexpected error with ' + $f.Name + ': ' + $_.Exception.Message)
            Say '       Git applies a patch completely or not at all, but run git status to see where things stand.' 'Yellow'
            Write-ErrorLog ('applying ' + $f.Name) $_
            $result = 'failed'
        }
        $rows += [pscustomobject]@{ Name = $f.Name; Result = $result }
        if ($result -eq 'applied') { $applied++ }
        elseif ($result -eq 'skipped') { $skipped++ }
        else {
            $stopped = $true
            for ($j = $i + 1; $j -lt $all.Count; $j++) { $rows += [pscustomobject]@{ Name = $all[$j].Name; Result = 'untouched' } }
            break
        }
    }

    Write-Heading 'Result'
    foreach ($r in $rows) {
        if ($r.Result -eq 'applied') { Write-Ok ($r.Name + '  applied') }
        elseif ($r.Result -eq 'skipped') { Write-Skip ($r.Name + $(if ($DryRun) { '  checked, not applied' } else { '  already applied' })) }
        elseif ($r.Result -eq 'untouched') { Write-Skip ($r.Name + '  not touched') }
        elseif ($r.Result -eq 'partial') { Write-Warn ($r.Name + '  partly applied (see the .rej files)') }
        else { Write-Fail ($r.Name + '  failed') }
    }
    Say ''
    if ($stopped) { Say '  STOPPED at the first problem. Patches before it stay applied (see the history); the ones after it were not touched.' 'Red' }
    elseif ($DryRun) { Say '  Dry run finished. Nothing was changed.' 'Yellow' }
    else { Say ('  Done: {0} applied, {1} skipped.' -f $applied, $skipped) 'Green' }

    return (-not $stopped)
}

function Invoke-UndoPatch {
    $hist = @(Read-PatchHistory)
    $open = @($hist | Where-Object { -not $_.undone } | Sort-Object { [int]$_.id } -Descending)
    Write-Heading 'Undo an applied patch'
    if ($open.Count -eq 0) { Say '  Nothing to undo.' 'Yellow'; return $false }
    $shown = @($open | Select-Object -First 10)
    foreach ($h in $shown) {
        Part ('  {0,3}  ' -f $h.id) 'Cyan'
        Part ('{0}  ' -f $h.appliedAt) 'DarkGray'
        Say $h.name 'White'
    }
    Say '  Enter = the newest one. A newer patch that changed the same files must be undone first.' 'DarkGray'
    $answer = Read-Line 'History number (Enter = the newest)'
    $entry = $shown[0]
    if ($answer -ne '') {
        $entry = $open | Where-Object { [string]$_.id -eq $answer } | Select-Object -First 1
        if ($null -eq $entry) { Write-Fail 'No such number.'; return $false }
    }
    $stored = Join-Path $script:PatchStore $entry.stored
    if (-not (Test-Path -LiteralPath $stored)) { Write-Fail 'The stored copy of that patch is missing, so it cannot be undone from here.'; return $false }
    $chk = Invoke-Git @('apply', '--check', '--reverse', '--whitespace=nowarn', $stored)
    if ($chk.Code -ne 0) {
        Write-Fail 'Cannot undo it cleanly: the files changed after this patch (a newer patch or your own edits). Nothing changed.'
        $chk.Lines | Select-Object -First 6 | ForEach-Object { Say ('         ' + $_) 'DarkGray' }
        Say '       A snapshot from before it was applied may exist: menu R (it replaces newer work in those files).' 'Yellow'
        return $false
    }
    if ($DryRun) { Write-Skip 'Dry run: it can be undone cleanly.'; return $true }
    if (-not (Ask-YesNo ('Undo #{0} {1}?' -f $entry.id, $entry.name) $false)) { Say '  Cancelled.' 'Yellow'; return $false }
    $info = Get-PatchInfo $stored
    $snap = New-Snapshot ('before undoing ' + $entry.name) @(Get-PatchPaths $info.Files)
    if ($snap) { Write-Ok 'Safety snapshot saved (menu R restores it).' }
    else {
        Write-Warn 'Could not save the safety snapshot.'
        if (-not (Ask-YesNo 'Undo anyway?' $false)) { return $false }
    }
    $r = Invoke-Git @('apply', '--reverse', '--whitespace=nowarn', $stored)
    if ($r.Code -ne 0) { Write-Fail 'Undo failed. The files were not changed.'; Say $r.Out 'DarkGray'; return $false }
    $entry.undone = $true
    $entry.undoneAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    Save-PatchHistory $hist
    Write-Ok ('Undone: {0}' -f $entry.name)
    return $true
}

# ---------------------------------------------------------------- menu

function Write-MenuItem([string]$Key, [string]$Label, [string]$Hint = '') {
    Part ('   ' + $Key + '  ') 'Cyan'
    Part $Label.PadRight(26) 'White'
    Say $Hint 'DarkGray'
}

function Show-Menu {
    Set-WindowTitle 'Patch Manager'
    while ($true) {
        Show-Status
        Say ''
        Write-MenuItem '1' 'Apply a patch' 'drag the file in'
        Write-MenuItem '2' 'Review a patch' 'is it applied? then the changes in colors'
        Write-MenuItem '3' 'Undo an applied patch'
        Write-MenuItem '4' 'Show the history'
        Write-MenuItem 'D' 'Changes of a patch' 'colored, file by file'
        Write-MenuItem 'R' 'Restore a snapshot' 'puts the files of a patch back'
        Write-MenuItem '?' 'Help'
        Write-MenuItem '5' 'Exit'
        Say '   Tip: drop a .patch file here and press Enter to apply it.' 'DarkGray'
        Say ''
        $choice = Read-Line 'Choose'
        $key = $choice.ToLower()
        if ($choice -eq '1') {
            [void](Invoke-Safe 'applying' {
                $files = @(Read-DroppedPatches)
                if ($files.Count -gt 0) { [void](Invoke-ApplyMany $files) }
            })
        }
        elseif ($choice -eq '2') {
            [void](Invoke-Safe 'reviewing' {
                $files = @(Read-DroppedPatches 'Drag the patch file (or several) you want to check into this window, then press Enter.')
                if ($files.Count -gt 0) { Invoke-ReviewMany $files $true }
            })
        }
        elseif ($choice -eq '3') { [void](Invoke-Safe 'undoing' { [void](Invoke-UndoPatch) }) }
        elseif ($choice -eq '4') { [void](Invoke-Safe 'reading the history' { Show-PatchHistory }) }
        elseif ($key -eq 'd') {
            [void](Invoke-Safe 'showing the changes' {
                $files = @(Read-DroppedPatches 'Drag the patch file (or several) whose changes you want to see into this window, then press Enter.')
                foreach ($f in $files) { Show-PatchDiff $f $true }
            })
        }
        elseif ($key -eq 'r') { [void](Invoke-Safe 'restoring' { [void](Invoke-RestoreSnapshot) }) }
        elseif ($choice -eq '?' -or $key -eq 'h' -or $key -eq 'help') { Show-Help }
        elseif ($choice -eq '5' -or $key -eq 'q' -or $key -eq 'exit') { break }
        elseif ($choice -match '[\\/]' -or $choice -match '\.(patch|diff)"?\s*$') {
            # A patch file was dropped straight onto the menu: treat it as "apply this"
            [void](Invoke-Safe 'applying' {
                $files = @(Resolve-DroppedText $choice)
                if ($files.Count -gt 0) { [void](Invoke-ApplyMany $files) }
            })
        }
        Say ''
        Say ('  ' + $script:Hr) 'DarkGray'
    }
}

# ---------------------------------------------------------------- main

$ok = $true
try {
    if ($Help) { Show-Help; exit 0 }
    Set-WindowTitle 'Patch Manager'
    if ($Interactive) { Clear-Host }
    Show-Banner

    if (-not (Test-Repository)) { $ok = $false }
    else {
        if ($History) { Show-PatchHistory }
        elseif ($Undo) { $ok = Invoke-UndoPatch }
        elseif ($Patch -or $Review) {
            $files = @()
            foreach ($n in $Patch) {
                $f = Resolve-PatchPath $n
                if ($null -eq $f) { $ok = $false; break }
                $files += $f
            }
            if ($ok -and $files.Count -gt 0) {
                if ($Review) { Invoke-ReviewMany $files $true }
                else { $ok = Invoke-ApplyMany $files }
            }
            elseif ($ok -and $Review) { $files = @(Read-DroppedPatches 'Drag the patch file (or several) you want to check into this window, then press Enter.'); if ($files.Count -gt 0) { Invoke-ReviewMany $files $true } }
        }

        # Started with a patch or a switch: do not close the window. Go on to the menu, where the next patch, a review or an undo is one choice away.
        if ($Interactive) { Show-Menu }
        elseif (-not $Close) {
            Say ''
            Say '  Finished. The window stays open: you can go on here.' 'DarkGray'
            Show-Menu
        }
    }
}
catch {
    $ok = $false
    Say ''
    Write-Fail ('The tool stopped because of an error: ' + $_.Exception.Message)
    Say ([string]$_.ScriptStackTrace) 'DarkGray'
    Write-ErrorLog 'the tool' $_
}
if (-not $ok -and -not $Close -and [Environment]::UserInteractive) {
    Say ''
    Wait-AnyKey 'Something went wrong (see above). Press any key to close...'
}
