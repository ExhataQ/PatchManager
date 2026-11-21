# Patch Manager   (one global tool: it works on whichever git project you open)
#
# Applies patches to any git project, safely: checks first, a safety snapshot, apply, history, undo. Inspection mode records what you
# change during a task and turns it into one patch. It can also push what you have committed.
# It never forces a patch, never force-pushes, never resets the repository and never overwrites a file that does not match the patch.
#
# Install:   keep this file anywhere, for example C:\Tools\PatchManager\PatchManager.ps1. Nothing is added to your projects.
# Project:   it works on ONE git repository at a time: -Project <folder>, else the folder you start it from (when that is inside a
#            repository), else the project you used last. If none is known it asks. The drop window has a Project... button; the text
#            menu has O. Each project keeps its own data in a ".patch-manager" folder, which is excluded through .git\info\exclude
#            (a local file), so no tracked file of yours changes and none of it can land in a commit.
# Start it:  FIRST TIME ONLY: right-click this file > Run with PowerShell. It offers a Desktop shortcut.
#            After that, double-click "Patch Manager" on the Desktop: the drop window opens. Drop .patch files in it.
#            (A shortcut is used because Windows opens .ps1 files in Notepad on double-click, and changing that for every
#            .ps1 file on the computer would be unsafe. The shortcut is made again any time with -CreateShortcut or menu S.)
# Windows:   the drop window is the default for the shortcut (-Gui). Running the script by hand gives the text menu (add -Gui for
#            the window, or press W in the menu).
# Menu:      choose 1, then drag a patch file into the window and press Enter. Or drop a patch straight onto the menu.
# Review:    choose 2 (or -Review) and drag a patch in: it says whether that patch is already applied, and can show the changes in colors
# Direct:    powershell -ExecutionPolicy Bypass -File PatchManager.ps1 -Project "C:\work\myrepo" "C:\path\fix.patch"
# Inspect:   menu 5 (or -Inspect start|stop|...) records what you change during a task and turns it into one patch, kept in the
#            same history as every other patch (so Undo works on it). Pause, checkpoints and recovery are included.
# Help:      ... -Help     (also the ? choice in the menu)
#
# Safety:    before a patch is applied (or undone) a snapshot of the files it touches is saved inside git (refs/patch-manager/...).
#            It takes a moment, needs no zip, and menu R puts the files back. The newest 30 snapshots are kept.
# Push:      menu 6 pushes every commit you already made to origin, after a guard checks them for private files and secrets.
# Colors:    set the NO_COLOR environment variable to turn them off (text menu only).
#
# What it keeps, per project: .patch-manager\history.json, a copy of every applied patch, and the inspection sessions.
# Which projects you used: %LOCALAPPDATA%\PatchManager\settings.json
#
# This file is plain ASCII on purpose: Windows PowerShell 5.1 reads a file without a byte-order mark as ANSI, so any other
# character would come out garbled. Box-drawing characters below are built from their code numbers for that reason.

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Patch,
    [string]$Project,          # the git project to work on (default: the folder you start from, else the one used last)
    [switch]$Help,
    [switch]$Review,
    [switch]$Close,
    [switch]$Undo,
    [switch]$History,
    [switch]$DryRun,
    [switch]$CreateShortcut,
    [switch]$Gui,              # the drop window
    [string]$Inspect,          # inspection mode: start, stop, status, pause, resume, checkpoint, cancel, recover, list, export
    [string]$InspectName       # with -Inspect: the session name (start), the patch name (stop) or the note (checkpoint)
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ScriptPath = Join-Path $ScriptDir 'PatchManager.ps1'
if ($PSCommandPath) { $script:ScriptPath = $PSCommandPath }
$script:Repo = $null          # the project being worked on (see Open-Project)
$script:StartDir = $null      # the folder the tool was started from
$script:Store = $null
$script:PatchStore = $null
$script:HistoryFile = $null
$script:LogBox = $null        # set while the drop window is open: all output goes there
$script:Form = $null
$Interactive = -not ($Patch -or $Undo -or $History -or $Review -or $Help -or $CreateShortcut -or $Gui -or $Inspect)

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
    # git writes file names as UTF-8: read them that way (Windows PowerShell 5.1 would use the OEM code page), then put the setting back
    $oldEnc = $null
    try { $oldEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = (New-Object System.Text.UTF8Encoding($false)) } catch { $oldEnc = $null }
    try {
        $lines = @(& $Exe @ArgList 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $old
        if ($null -ne $oldEnc) { try { [Console]::OutputEncoding = $oldEnc } catch { } }
    }
    return [pscustomobject]@{ Code = $code; Lines = $lines; Out = ($lines -join "`n") }
}

# Same, but every line is handed to a script block as it arrives (for long runs). Returns the exit code.
function Invoke-Streaming([string]$Exe, [string[]]$ArgList, [scriptblock]$OnLine) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $code = 1
    try {
        & $Exe @ArgList 2>&1 | ForEach-Object { $null = & $OnLine ([string]$_) }
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    return $code
}

function Invoke-Git([string[]]$ArgList) { return (Invoke-Native 'git' $ArgList) }

# A git command whose own messages (push progress) should be seen live. Returns the exit code.
function Invoke-GitLive([string[]]$ArgList) {
    if ($script:LogBox) {
        $r = Invoke-Git $ArgList
        foreach ($l in $r.Lines) { Say ('  ' + $l) 'DarkGray' }
        return $r.Code
    }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # not captured: git shows its own live progress, and its messages land in this window
        & git @ArgList | Out-Host
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    return $code
}

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
function Get-HostExe {
    try {
        $p = (Get-Process -Id $PID).Path
        if ($p) { return $p }
    }
    catch { }
    if ($PSVersionTable.PSEdition -eq 'Core') { return (Join-Path $PSHOME 'pwsh.exe') }
    return (Join-Path $PSHOME 'powershell.exe')
}

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
    Say '  Applies a .patch file to a git project: checks it, saves a safety snapshot, applies it, and remembers it so it can be undone.' 'Gray'
    Say '  Inspection mode records what you change during a task and turns it into one patch.' 'Gray'
    Say '  It never forces a patch, never force-pushes, and never overwrites a file that does not match the patch.' 'Gray'

    Write-Heading 'Which project'
    Say '  It works on one git repository at a time: -Project <folder>, else the folder you start it from, else the one used last.' 'Gray'
    Say '  Switch any time: the Project... button, or menu O. Each project keeps its data in .patch-manager (excluded through .git\info\exclude).' 'Gray'

    Write-Heading 'Starting it with a double-click'
    Say '  First time only: right-click PatchManager.ps1 > Run with PowerShell. It offers a Desktop shortcut.' 'Gray'
    Say '  After that, double-click "Patch Manager" on the Desktop. The drop window opens: drop .patch files in it.' 'Gray'
    Say '  (Make the shortcut again any time: menu S, or the -CreateShortcut option.)' 'DarkGray'

    Write-Heading 'Three ways to give it a patch (the file can be anywhere)'
    Say '  1. Drop the .patch file in the drop window (or on the Desktop shortcut). Several files are applied in order.' 'Gray'
    Say '  2. In the text menu choose 1, drag the file into the window, press Enter. (Dropping it straight onto the menu works too.)' 'Gray'
    Say '  3. From a terminal:  .\PatchManager.ps1 -Project "C:\work\repo" "C:\path\to\fix.patch"' 'Gray'

    Write-Heading 'Menu'
    Show-HelpLine '1' 'Apply a patch'
    Show-HelpLine '2' 'Review a patch: is it applied? Then see the changes in colors.'
    Show-HelpLine '3' 'Undo an applied patch (only if the files still match)'
    Show-HelpLine '4' 'Show the history (patches and inspection sessions)'
    Show-HelpLine '5 or I' 'Inspection mode: record what you change during a task, get one patch'
    Show-HelpLine '6' 'Push everything you already committed to GitHub (origin), after the guard'
    Show-HelpLine 'D' 'Show the changes of a patch in colors, file by file'
    Show-HelpLine 'R' 'Restore a safety snapshot (puts the files a patch touched back)'
    Show-HelpLine 'O' 'Open another project'
    Show-HelpLine 'W' 'Open the drop window'
    Show-HelpLine 'S' 'Put a "Patch Manager" shortcut on the Desktop'
    Show-HelpLine '7' 'Exit'

    Write-Heading 'What happens to each patch'
    Say '  1. It is read, and refused if it touches anything outside the project or inside .git.' 'Gray'
    Say '  2. A summary is shown: size, SHA256, the files, lines added and removed.' 'Gray'
    Say '  3. It is checked against your files. Already applied: skipped. Conflict: stopped, nothing changed.' 'Gray'
    Say '  4. A safety snapshot of the files it touches is saved inside git (a moment, no zip).' 'Gray'
    Say '  5. It is applied, checked once more, and written to the history with a copy of the patch.' 'Gray'

    Write-Heading 'When a patch conflicts'
    Say '  You are asked whether to apply the parts that fit. The parts that do not fit are written next to the file as .rej files' 'Gray'
    Say '  (fix them by hand, then delete them). The snapshot lets you go back with R.' 'Gray'

    Write-Heading 'Push (menu 6)'
    Say '  Lists the commits that are not on origin yet, warns about uncommitted files (they are NOT pushed), runs the guard, asks once, pushes.' 'Gray'
    Say '  The guard looks for .env files, keys, files over 5 MB and secrets in the new lines.' 'Gray'

    Write-Heading 'Inspection mode (menu 5, or the Inspect buttons of the drop window)'
    Say '  Start it before a task. Everything you change after that is recorded; Stop turns the NET change into one patch.' 'Gray'
    Say '  - Files that already differed from the last commit are in the baseline: they do not end up in the patch.' 'Gray'
    Say '  - Pause: edits made while paused stay out of the patch. Checkpoint: save a state. Recover: go back to a checkpoint or the start.' 'Gray'
    Say '  - The patch goes into the normal history (menu 4), so Undo (menu 3) can take it back. Cancel discards only the recording.' 'Gray'
    Say '  - The drop window watches the folder and shows the numbers live; the text menu scans when you look.' 'Gray'
    Say '  - A session survives closing this window. Records: .patch-manager\inspections\<session>\ in the project.' 'Gray'

    Write-Heading 'Options (terminal or shortcut)'
    Show-HelpLine '-Project <dir>' 'the git project to work on'
    Show-HelpLine '-Gui' 'open the drop window'
    Show-HelpLine '-DryRun' 'check only, change nothing'
    Show-HelpLine '-Undo' 'undo an applied patch'
    Show-HelpLine '-History' 'show what was applied'
    Show-HelpLine '-Review' 'is this patch applied? (no changes)'
    Show-HelpLine '-Inspect <what>' 'start, stop, status, pause, resume, checkpoint, cancel, recover, list, export'
    Show-HelpLine '-InspectName' 'with -Inspect: the session name, patch name or checkpoint note'
    Show-HelpLine '-CreateShortcut' 'make the Desktop shortcut'
    Show-HelpLine '-Close' 'close the window when done instead of going to the menu'
    Show-HelpLine '-Help' 'this text'

    Write-Heading 'Good to know'
    Say '  - Patches that depend on each other go in order. If one fails, the ones before it stay applied and the rest are untouched.' 'Gray'
    Say '  - Undo works only if the files still match: newer patches that changed the same files must be undone first.' 'Gray'
    Say '  - History and patch copies: .patch-manager\ in the project (never committed).' 'Gray'
    Say '  - No colors wanted in the text menu? Set the NO_COLOR environment variable.' 'Gray'
}

# ---------------------------------------------------------------- the Desktop shortcut (the double-click)

function Get-ShortcutPath {
    $desk = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrEmpty($desk)) { return $null }
    return (Join-Path $desk 'Patch Manager.lnk')
}

# A shortcut starts PowerShell with this script and lets it run for this session only (-ExecutionPolicy Bypass, nothing is changed
# on the computer). It opens the drop window (the console behind it is hidden) on the project used last.
function New-AppShortcut {
    try {
        $path = Get-ShortcutPath
        if (-not $path) { Write-Fail 'This account has no Desktop folder to put the shortcut in.'; return $false }
        $exe = Get-HostExe
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($path)
        $lnk.TargetPath = $exe
        $lnk.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script:ScriptPath + '" -Gui'
        $lnk.WorkingDirectory = $(if ($env:USERPROFILE) { $env:USERPROFILE } else { $ScriptDir })
        $lnk.IconLocation = $exe + ',0'
        $lnk.Description = 'Apply patches to any git project, record a task as one patch, push commits'
        $lnk.WindowStyle = 7
        $lnk.Save()
        Write-Ok 'Shortcut created on your Desktop:'
        Say ('       ' + $path) 'White'
        Say '       Double-click it: the drop window opens. A black window may flash for a moment; that is normal.' 'DarkGray'
        return $true
    }
    catch {
        Write-Fail ('Could not create the shortcut: ' + $_.Exception.Message)
        Write-ErrorLog 'creating the shortcut' $_
        return $false
    }
}

# Once, the first time the menu opens: offer the shortcut. Answering no is remembered, so it does not ask again.
function Offer-Shortcut {
    try {
        $path = Get-ShortcutPath
        if (-not $path -or (Test-Path -LiteralPath $path)) { return }
        $marker = Join-Path (Split-Path -Parent (Get-SettingsPath)) 'no-shortcut'
        if (Test-Path -LiteralPath $marker) { return }
        Say ''
        Write-Info 'Tip: a Desktop shortcut lets you start this with a double-click (it opens the drop window).'
        if (Ask-YesNo 'Create it now?' $true) { [void](New-AppShortcut) }
        else {
            $d = Split-Path -Parent $marker
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            [IO.File]::WriteAllText($marker, 'The shortcut offer was declined. Menu S makes it any time.')
            Say '       Fine. Menu S makes it whenever you want.' 'DarkGray'
        }
    }
    catch { }   # an offer is a convenience: never let it get in the way
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
    if ($hist.Count -eq 0) { Say '  Nothing applied through this tool yet.' 'Yellow' }
    foreach ($h in $hist) {
        $undone = [bool]$h.undone
        $color = if ($undone) { 'DarkGray' } else { 'Gray' }
        Part ('  {0,3}  ' -f $h.id) 'Cyan'
        Part ('{0}  ' -f $h.appliedAt) 'DarkGray'
        Part ('{0,-40} ' -f $h.name) $(if ($undone) { 'DarkGray' } else { 'White' })
        Part ('{0,3} files  ' -f $h.files) $color
        if ($h.source -eq 'inspection') { Part ('inspection {0}  ' -f $h.session) 'Magenta' }
        if ($undone) { Say 'undone' 'DarkGray' }
        elseif ($h.partial) { Say 'partly applied' 'Yellow' }
        else { Say 'applied' 'Green' }
    }
    Show-InspectionSessions $true
}

# A new history entry for a patch that was just applied. Returns its number.
function Add-HistoryEntry($File, [string]$Hash, $Info, [string]$Snapshot, [bool]$Partial, $Extra = $null) {
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
    # extra fields (an inspection session adds source, session, branch and startCommit)
    if ($null -ne $Extra) { foreach ($k in $Extra.Keys) { Add-Member -InputObject $entry -NotePropertyName $k -NotePropertyValue $Extra[$k] -Force } }
    $hist += $entry
    Save-PatchHistory $hist
    return $id
}

# ---------------------------------------------------------------- repository

# ---- which project the tool works on

function Get-SettingsPath {
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrEmpty($base)) { $base = $env:APPDATA }
    if ([string]::IsNullOrEmpty($base)) { $base = $ScriptDir }
    return (Join-Path (Join-Path $base 'PatchManager') 'settings.json')
}

function Read-Settings {
    $p = Get-SettingsPath
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        try { return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($p))) } catch { }
    }
    return [pscustomobject]@{ recent = @() }
}

# The projects used before that still exist, newest first
function Get-RecentProjects {
    $s = Read-Settings
    $out = @()
    foreach ($r in @($s.recent)) {
        if ($r -and (Test-Path -LiteralPath ([string]$r) -PathType Container)) { $out += [string]$r }
    }
    return @($out)
}

function Add-RecentProject([string]$Path) {
    try {
        $list = @((@($Path) + @(Get-RecentProjects | Where-Object { $_ -ne $Path })) | Select-Object -First 8)
        $p = Get-SettingsPath
        $dir = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $o = [pscustomobject]@{ recent = $list }
        [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $o -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }   # remembering the projects is a convenience: never let it get in the way
}

# The top folder of the git repository that contains $Dir, or $null
function Get-RepoRoot([string]$Dir) {
    if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }
    $top = Invoke-Git @('-C', $Dir, 'rev-parse', '--show-toplevel')
    if ($top.Code -ne 0 -or [string]::IsNullOrWhiteSpace($top.Out)) { return $null }
    return [IO.Path]::GetFullPath($top.Out.Trim())
}

# Keeps the tool's data folder out of git without touching any tracked file: .git\info\exclude is local to this clone
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

# Makes $Dir's repository the current project. Returns $false when $Dir is not inside a git repository.
function Open-Project([string]$Dir) {
    $root = Get-RepoRoot $Dir
    if (-not $root) { return $false }
    Stop-InspectionWatcher
    $script:Repo = $root
    Set-Location -LiteralPath $root
    $script:Store = Join-Path $root '.patch-manager'
    $script:PatchStore = Join-Path $script:Store 'patches'
    $script:HistoryFile = Join-Path $script:Store 'history.json'
    $script:InspectDir = Join-Path $script:Store 'inspections'
    $script:InspectActiveId = $null
    $script:InspectCounts = $null
    $script:InspectDirty = $false
    Add-StoreToExclude
    Add-RecentProject $root
    $title = 'Patch Manager - ' + (Split-Path -Leaf $root)
    Set-WindowTitle $title
    if ($script:LogBox -and $script:Form) { try { $script:Form.Text = $title } catch { } }
    return $true
}

# Which project? A folder dialog in the window, a list of recent projects or a typed (or dragged-in) path in the console.
# Returns a folder path or $null.
function Select-ProjectFolder([bool]$Startup = $false) {
    if ($script:LogBox -or ($Gui -and $Startup)) {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Choose the project folder (a git repository)'
        if ($script:Repo) { $dlg.SelectedPath = $script:Repo }
        if ($script:LogBox -and $script:Form) { $r = $dlg.ShowDialog($script:Form) } else { $r = $dlg.ShowDialog() }
        if ($r -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
        return $null
    }
    $recent = @(Get-RecentProjects)
    Say ''
    $i = 0
    foreach ($r in $recent) { $i++; Part ('  {0,3}  ' -f $i) 'Cyan'; Say $r 'White' }
    $answer = Read-Line 'Number, or the project folder (drag it in here; Enter cancels)'
    if ($answer -eq '') { return $null }
    $n = 0
    if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $recent.Count) { return $recent[$n - 1] }
    return (Remove-OuterQuotes $answer)
}

function Invoke-ChooseProject {
    Write-Heading 'Open a project'
    $p = Select-ProjectFolder $false
    if (-not $p) { Say '  Cancelled.' 'Yellow'; return $false }
    if (-not (Open-Project $p)) { Write-Fail ('That folder is not inside a git repository: ' + $p); return $false }
    Write-Ok ('Now working on ' + $script:Repo)
    $im = Get-ActiveInspection
    if ($null -ne $im) { Write-Info ('An inspection session is running in this project: {0}.' -f $im.id) }
    return $true
}

# At startup: -Project, else the folder it was started from, else the project used last, else ask.
function Test-Repository {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Fail 'git was not found. Install Git for Windows first.'; return $false }
    $script:StartDir = (Get-Location).Path
    if (-not [string]::IsNullOrWhiteSpace($Project)) {
        if (Open-Project (Remove-OuterQuotes $Project)) { return $true }
        Write-Fail ('"{0}" is not inside a git repository.' -f $Project)
        return $false
    }
    $self = Get-RepoRoot $ScriptDir      # the folder this tool itself lives in is not a project to work on by accident
    $here = Get-RepoRoot $script:StartDir
    if ($here -and $here -ne $self -and (Open-Project $here)) { return $true }
    foreach ($r in @(Get-RecentProjects)) { if (Open-Project $r) { return $true } }
    $picked = Select-ProjectFolder $true
    if ($picked -and (Open-Project $picked)) { return $true }
    Write-Fail 'No project was chosen. Start the tool inside a git repository, or use -Project <folder>.'
    return $false
}

# Where things stand: branch, uncommitted files, commits not pushed yet
function Get-RepoStatus {
    $branch = Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')
    $b = if ($branch.Code -eq 0) { $branch.Out.Trim() } else { '(no commits yet)' }
    $dirty = @((Invoke-Git @('status', '--porcelain')).Lines | Where-Object { $_ -match '\S' }).Count
    $ahead = -1
    $remote = Invoke-Git @('remote', 'get-url', 'origin')
    if ($remote.Code -eq 0 -and $branch.Code -eq 0) {
        $a = Invoke-Git @('rev-list', '--count', 'HEAD', '--not', '--remotes=origin')
        if ($a.Code -eq 0 -and $a.Out.Trim() -match '^\d+$') { $ahead = [int]$a.Out.Trim() }
    }
    return [pscustomobject]@{ Branch = $b; Dirty = $dirty; Ahead = $ahead }
}

function Show-Status {
    $s = Get-RepoStatus
    Say ''
    Part '  Project   ' 'DarkGray'; Say $script:Repo 'Gray'
    Part '  Branch    ' 'DarkGray'; Part $s.Branch 'White'
    Part '     uncommitted: ' 'DarkGray'
    if ($s.Dirty -eq 0) { Part 'none' 'Green' } else { Part ('{0} file(s)' -f $s.Dirty) 'Yellow' }
    Part '     to push: ' 'DarkGray'
    if ($s.Ahead -lt 0) { Part 'n/a' 'DarkGray' } elseif ($s.Ahead -eq 0) { Part 'nothing' 'Green' } else { Part ('{0} commit(s)' -f $s.Ahead) 'Yellow' }
    Say ''
    $im = $null
    try { $im = Get-ActiveInspection } catch { }
    if ($null -ne $im) {
        Part '  Inspect   ' 'DarkGray'
        Part ('{0} {1}' -f $(if ($im.status -eq 'paused') { 'PAUSED' } else { 'ACTIVE' }), $im.id) 'Yellow'
        Say ('   since {0}   (menu I)' -f (Format-InspectTime $im.startedAt)) 'DarkGray'
    }
    $ign = Invoke-Git @('check-ignore', '-q', '.patch-manager/history.json')
    if ($ign.Code -ne 0) { Write-Warn '.patch-manager is not git-ignored here; the patch history would show up in git status.' }
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

# ---------------------------------------------------------------- push: the guard, then what is already committed

# Looks at the commits that origin does not have yet (and only those) for things that should not leave this computer.
# 'block' = private development files, env files, keys, secrets with a known shape; 'warn' = big files, logs, build output, generic "password = ..." lines.
# It never prints a secret itself: only which commit, which file, and what kind.
function Get-PushGuardFindings {
    $found = New-Object System.Collections.ArrayList
    $names = Invoke-Git @('-c', 'core.quotepath=false', 'log', '--format=', '--name-status', '--no-renames', 'HEAD', '--not', '--remotes=origin')
    $paths = @{}
    foreach ($l in $names.Lines) { if ($l -match '^[AMTC]\t(.+)$') { $paths[$Matches[1]] = $true } }

    $blockPaths = @(
        @('^\.patch-manager(/|$)', 'local tool data'),
        @('(^|/)\.env(\.(?!example|sample)[^/]*)?$', 'environment file (may hold secrets)'),
        @('\.(pem|key|pfx|p12)$', 'key or certificate file'),
        @('(^|/)id_(rsa|dsa|ecdsa|ed25519)$', 'SSH private key')
    )
    $warnPaths = @(
        @('\.(log|zip|7z|exe|msi)$', 'log, archive or program file'),
        @('(^|/)node_modules/', 'node_modules'),
        @('^dist/', 'build output')
    )
    foreach ($p in $paths.Keys) {
        foreach ($r in $blockPaths) { if ($p -imatch $r[0]) { [void]$found.Add([pscustomobject]@{ Level = 'block'; Text = ($p + '   ' + $r[1]) }) } }
        foreach ($r in $warnPaths) { if ($p -imatch $r[0]) { [void]$found.Add([pscustomobject]@{ Level = 'warn'; Text = ($p + '   ' + $r[1]) }) } }
    }

    # big files (over 5 MB), from one listing of the tree
    $tree = Invoke-Git @('-c', 'core.quotepath=false', 'ls-tree', '-r', '-l', 'HEAD')
    foreach ($l in $tree.Lines) {
        if ($l -match '^\d+\s+blob\s+[0-9a-f]+\s+(\d+)\t(.+)$') {
            $size = [long]$Matches[1]; $name = $Matches[2]
            if ($size -gt 5MB -and $paths.ContainsKey($name)) { [void]$found.Add([pscustomobject]@{ Level = 'warn'; Text = ('{0}   {1:N1} MB' -f $name, ($size / 1MB)) }) }
        }
    }

    # secrets in the added lines
    $count = @((Invoke-Git @('rev-list', 'HEAD', '--not', '--remotes=origin')).Lines | Where-Object { $_ -match '\S' }).Count
    if ($count -gt 200) {
        [void]$found.Add([pscustomobject]@{ Level = 'warn'; Text = ('{0} commits are new: too many to scan line by line, only file names were checked' -f $count) })
        return $found
    }
    $rules = @(
        @('-----BEGIN [A-Z ]*PRIVATE KEY-----', 'private key', 'block'),
        @('\bAKIA[0-9A-Z]{16}\b', 'AWS access key', 'block'),
        @('\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}', 'GitHub token', 'block'),
        @('\bgithub_pat_[A-Za-z0-9_]{40,}', 'GitHub token', 'block'),
        @('\bxox[baprs]-[A-Za-z0-9-]{10,}', 'Slack token', 'block'),
        @('\bsk-[A-Za-z0-9_-]{20,}', 'API key (sk-...)', 'block'),
        @('\bAIza[0-9A-Za-z_-]{35}\b', 'Google API key', 'block'),
        @('(?i)\b(api[_-]?key|secret|passw(or)?d|token)\b[''"]?\s*[:=]\s*[''"][A-Za-z0-9_\-/+=]{16,}[''"]', 'a "secret = value" line', 'warn')
    )
    $log = Invoke-Git @('-c', 'core.quotepath=false', 'log', '-p', '-U0', '--no-color', '--format=commit:%h', 'HEAD', '--not', '--remotes=origin')
    $commit = ''; $file = ''; $n = 0; $seen = @{}
    foreach ($l in $log.Lines) {
        $n++
        if ($n -gt 300000) { [void]$found.Add([pscustomobject]@{ Level = 'warn'; Text = 'the new lines are too many to scan all of them (stopped after 300000)' }); break }
        if ($l.StartsWith('commit:')) { $commit = $l.Substring(7); continue }
        if ($l.StartsWith('+++ ')) { $file = ($l.Substring(4) -replace '^b/', ''); continue }
        if (-not $l.StartsWith('+')) { continue }
        if ($file -match 'package-lock\.json$|\.min\.js$|\.map$|THIRD-PARTY') { continue }
        $text = $l.Substring(1)
        if ($text.Length -gt 4000) { $text = $text.Substring(0, 4000) }
        foreach ($r in $rules) {
            if ($text -match $r[0]) {
                $key = $commit + '|' + $file + '|' + $r[1]
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    [void]$found.Add([pscustomobject]@{ Level = $r[2]; Text = ('{0}   {1} in commit {2}' -f $file, $r[1], $commit) })
                }
                break
            }
        }
    }
    return $found
}

# $true = go ahead with the push
function Confirm-PushGuard {
    Write-Step 'Push guard: looking at the new commits for private files, big files and secrets...'
    $f = @(Get-PushGuardFindings)
    if ($f.Count -eq 0) { Write-Ok 'Push guard: nothing suspicious.'; return $true }
    $block = @($f | Where-Object { $_.Level -eq 'block' })
    foreach ($x in ($f | Select-Object -First 15)) {
        if ($x.Level -eq 'block') { Write-Fail $x.Text } else { Write-Warn $x.Text }
    }
    if ($f.Count -gt 15) { Say ('       ... and {0} more' -f ($f.Count - 15)) 'DarkGray' }
    Say ''
    if ($block.Count -gt 0) {
        Say '  These should not leave your computer. Remove them from the commits first (or add them to .gitignore).' 'Red'
        $a = Read-Line 'Type PUSH (capitals) to push anyway, anything else cancels'
        return ($a -ceq 'PUSH')
    }
    return (Ask-YesNo 'The guard has warnings. Push anyway?' $false)
}

# Pushes the commits you already made to origin, and nothing else: it does not stage, commit, reset or touch any file.
# It shows what will go up, warns about uncommitted files (they stay behind), runs the guard, asks once, and never forces.
function Invoke-PushCommits {
    Write-Heading 'Push committed work to GitHub'

    $branch = Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')
    if ($branch.Code -ne 0) { Write-Fail 'There are no commits yet, so there is nothing to push.'; return $false }
    $name = $branch.Out.Trim()
    if ($name -eq 'HEAD') { Write-Fail 'Git is not on a branch (detached HEAD). Switch to a branch first. Nothing was pushed.'; return $false }
    $remote = Invoke-Git @('remote', 'get-url', 'origin')
    if ($remote.Code -ne 0 -or [string]::IsNullOrWhiteSpace($remote.Out)) { Write-Fail 'No "origin" remote was found, so there is nowhere to push. Nothing was pushed.'; return $false }
    $url = $remote.Out.Trim()

    Write-Step 'Checking what origin already has...'
    $fetch = Invoke-Git @('fetch', '--quiet', 'origin')
    if ($fetch.Code -ne 0) { Write-Warn 'Could not reach origin (offline, or a sign-in is needed). Going on with what is known on this computer.' }

    # Is origin ahead of us? Only possible to say when the branch already has an upstream.
    $behind = 0
    $up = Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    if ($up.Code -eq 0) {
        $lr = Invoke-Git @('rev-list', '--left-right', '--count', ($up.Out.Trim() + '...HEAD'))
        if ($lr.Code -eq 0 -and $lr.Out.Trim() -match '^(\d+)\s+(\d+)$') { $behind = [int]$Matches[1] }
    }
    $onRemote = ((Invoke-Git @('rev-parse', '--verify', '--quiet', ('refs/remotes/origin/' + $name))).Code -eq 0)

    # Commits that origin does not have yet: reachable from HEAD, but not from any branch of origin
    $list = Invoke-Git @('log', '--format=%h%x09%s', 'HEAD', '--not', '--remotes=origin')
    $commits = @($list.Lines | Where-Object { $_ -match '\S' })

    # Uncommitted files stay behind: say so, so nobody thinks they went up
    $dirty = @((Invoke-Git @('status', '--porcelain')).Lines | Where-Object { $_ -match '\S' })
    if ($dirty.Count -gt 0) {
        Write-Warn ('{0} file(s) have uncommitted changes. They will NOT be pushed (only finished commits go up):' -f $dirty.Count)
        $dirty | Select-Object -First 8 | ForEach-Object { Say ('         ' + $_) 'DarkGray' }
        if ($dirty.Count -gt 8) { Say ('         ... and {0} more' -f ($dirty.Count - 8)) 'DarkGray' }
    }

    if ($behind -gt 0 -and $commits.Count -gt 0) {
        Write-Fail ('origin has {0} commit(s) that you do not have, so a push would be rejected.' -f $behind)
        Say '       Bring them in first (for example: git pull --rebase), then choose 6 again. Nothing was pushed, and nothing is ever forced.' 'Yellow'
        return $false
    }
    if ($commits.Count -eq 0 -and $onRemote) {
        if ($behind -gt 0) { Write-Info ('Nothing to push. origin is ahead of you by {0} commit(s); git pull brings them in.' -f $behind) }
        else { Write-Ok 'Nothing to push: everything you committed is already on origin.' }
        return $true
    }

    if ($commits.Count -gt 0) {
        Write-Info ('{0} commit(s) on branch {1} are not on origin yet:' -f $commits.Count, $name)
        Say ''
        foreach ($c in ($commits | Select-Object -First 15)) {
            $parts = $c -split "`t", 2
            Part ('    ' + $parts[0] + '  ') 'Yellow'
            Say $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) 'White'
        }
        if ($commits.Count -gt 15) { Say ('    ... and {0} more' -f ($commits.Count - 15)) 'DarkGray' }
        Say ''
        if (-not (Confirm-PushGuard)) { Say '  Cancelled. Nothing was pushed.' 'Yellow'; return $false }
    }
    else {
        Write-Info ('Branch {0} is not on origin yet; it will be created there.' -f $name)
    }
    Say ''
    Say ('  Destination: ' + $url) 'DarkGray'
    if (-not (Ask-YesNo 'Push to origin now?' $true)) { Say '  Cancelled. Nothing was pushed.' 'Yellow'; return $false }

    Write-Step 'Pushing...'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-GitLive @('push', '-u', 'origin', 'HEAD')
    Say ''
    if ($code -ne 0) {
        Write-Fail 'The push failed. Your commits are safe on this computer. Read the git message above, fix it, then choose 6 again.'
        return $false
    }
    Write-Ok ('Pushed {0} to {1} in {2}.' -f $name, $url, (Format-Elapsed $clock.Elapsed))
    return $true
}

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
# Everything about a session lives in .patch-manager\inspections\<session>\ : metadata.json, events.jsonl, the patch, and a
# private git index (so scans after the first one only read the files that changed).

$script:InspectDir = $null                      # set in Test-Repository: .patch-manager\inspections
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

# The whole working tree (tracked and new files, not ignored ones, and never .patch-manager) as a git tree. Uses the session's own index, which
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
        $add = Invoke-Git @('add', '-A', '--', '.', ':(exclude).patch-manager')
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
        $ct = @('-c', 'user.name=Patch Manager', '-c', 'user.email=patch-manager@localhost', 'commit-tree', $Tree)
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
    $skip = '^(warning|error|fatal):|^\.patch-manager/'
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
    Say ('  The patch is kept in .patch-manager\inspections\{0}\ . "Export" copies it elsewhere.' -f $id) 'DarkGray'
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
    Set-WindowTitle 'Patch Manager - Inspection mode'
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
    Set-WindowTitle 'Patch Manager'
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

# File events only mark "something changed"; the scan decides what really did. Events from .git, .patch-manager and node_modules are ignored.
function Register-InspectTouch([string]$Full) {
    if ([string]::IsNullOrEmpty($Full)) { return }
    $rel = $Full
    if ($Full.StartsWith($script:Repo, [StringComparison]::OrdinalIgnoreCase)) { $rel = $Full.Substring($script:Repo.Length).TrimStart('\', '/') }
    if ($rel -match '(^|[\\/])(\.git|\.patch-manager|node_modules)([\\/]|$)') { return }
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

# ---------------------------------------------------------------- the drop window

$script:Queue = New-Object System.Collections.ArrayList
$script:GuiButtons = New-Object System.Collections.ArrayList
$script:GuiBusy = $false
$script:GuiList = $null
$script:GuiStatus = $null

function Update-GuiStatus {
    if ($null -eq $script:GuiStatus) { return }
    try {
        $s = Get-RepoStatus
        $push = if ($s.Ahead -lt 0) { 'n/a' } elseif ($s.Ahead -eq 0) { 'nothing' } else { ('{0} commit(s)' -f $s.Ahead) }
        $dirty = if ($s.Dirty -eq 0) { 'none' } else { ('{0} file(s)' -f $s.Dirty) }
        $script:GuiRepoText = ('Branch {0}      uncommitted: {1}      to push: {2}      {3}' -f $s.Branch, $dirty, $push, $script:Repo)
        Set-GuiStatusText
    }
    catch { }
}

# Files and folders dropped (or chosen) go into the list, in natural name order (patch-2 before patch-10). A folder adds its .patch and .diff files.
function Add-GuiPatches([string[]]$Paths) {
    $found = @()
    foreach ($raw in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $p = Remove-OuterQuotes $raw
        if (Test-Path -LiteralPath $p -PathType Container) { $found += @(Get-ChildItem -LiteralPath $p -File | Where-Object { $_.Extension -match '^\.(patch|diff)$' }) }
        elseif (Test-Path -LiteralPath $p -PathType Leaf) { $found += @(Get-Item -LiteralPath $p) }
    }
    $found = @($found | Sort-Object { [regex]::Replace($_.Name, '\d+', { param($m) $m.Value.PadLeft(10, '0') }) })
    $added = 0
    foreach ($f in $found) {
        $dup = $false
        foreach ($q in $script:Queue) { if ($q.FullName -eq $f.FullName) { $dup = $true } }
        if ($dup) { continue }
        [void]$script:Queue.Add($f)
        [void]$script:GuiList.Items.Add($f.Name)
        $added++
    }
    if ($added -gt 0) { Write-Info ('{0} patch file(s) added to the list. Apply runs them from the top, in this order.' -f $added) }
    elseif (@($Paths).Count -gt 0) { Write-Warn 'Nothing new was added (no patch files found, or they are already in the list).' }
}

function Invoke-GuiAction([string]$Name) {
    if ($script:GuiBusy) { return }
    $script:GuiBusy = $true
    foreach ($b in $script:GuiButtons) { $b.Enabled = $false }
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $files = @($script:Queue)
        if ($Name -eq 'browse') {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = 'Choose patch files'
            $dlg.Multiselect = $true
            $dlg.Filter = 'Patch files (*.patch;*.diff)|*.patch;*.diff|All files (*.*)|*.*'
            if ($dlg.ShowDialog($script:Form) -eq [System.Windows.Forms.DialogResult]::OK) { Add-GuiPatches @($dlg.FileNames) }
        }
        elseif ($Name -eq 'clear') { $script:Queue.Clear(); $script:GuiList.Items.Clear() }
        elseif ($Name -eq 'remove') {
            $idx = @($script:GuiList.SelectedIndices | ForEach-Object { [int]$_ } | Sort-Object -Descending)
            foreach ($k in $idx) { $script:Queue.RemoveAt($k); $script:GuiList.Items.RemoveAt($k) }
        }
        elseif ($Name -eq 'apply') {
            if ($files.Count -eq 0) { Write-Warn 'The list is empty. Drop patch files in the window first.' }
            else {
                $ok = Invoke-ApplyMany $files
                if ($ok -and -not $DryRun) { $script:Queue.Clear(); $script:GuiList.Items.Clear() }
            }
        }
        elseif ($Name -eq 'review') {
            if ($files.Count -eq 0) { Write-Warn 'The list is empty. Drop patch files in the window first.' } else { Invoke-ReviewMany $files $false }
        }
        elseif ($Name -eq 'preview') {
            if ($files.Count -eq 0) { Write-Warn 'The list is empty. Drop patch files in the window first.' } else { foreach ($f in $files) { Show-PatchDiff $f $false } }
        }
        elseif ($Name -eq 'undo') { [void](Invoke-UndoPatch) }
        elseif ($Name -eq 'restore') { [void](Invoke-RestoreSnapshot) }
        elseif ($Name -eq 'history') { Show-PatchHistory }
        elseif ($Name -eq 'push') { [void](Invoke-PushCommits) }
        elseif ($Name -eq 'project') { [void](Invoke-ChooseProject) }
        elseif ($Name -eq 'istart') { [void](Start-Inspection (Read-Line 'Name for this session (optional)')) }
        elseif ($Name -eq 'ipause') {
            $im = Get-ActiveInspection
            if ($null -ne $im -and $im.status -eq 'paused') { [void](Resume-Inspection $im) } else { [void](Suspend-Inspection) }
        }
        elseif ($Name -eq 'icheck') { [void](New-InspectionCheckpoint (Read-Line 'Note for the checkpoint (optional)')) }
        elseif ($Name -eq 'iview') { [void](Show-InspectionChanges $true) }
        elseif ($Name -eq 'istop') { [void](Stop-Inspection) }
        elseif ($Name -eq 'icancel') { [void](Remove-Inspection) }
        elseif ($Name -eq 'irecover') { [void](Invoke-InspectionRecover) }
        elseif ($Name -eq 'isessions') { Show-InspectionSessions }
        elseif ($Name -eq 'help') { Show-Help }
    }
    catch {
        Say ''
        Write-Fail ('Problem: ' + $_.Exception.Message)
        Write-ErrorLog ('the window action ' + $Name) $_
    }
    finally {
        foreach ($b in $script:GuiButtons) { $b.Enabled = $true }
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
        Sync-InspectionState
        Update-GuiStatus
        $script:GuiBusy = $false
    }
}

function New-GuiButton([string]$Text, [string]$Tag, [bool]$Primary = $false, [int]$Width = 112) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Tag = $Tag
    $b.Size = New-Object System.Drawing.Size($Width, 34)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $(if ($Primary) { [System.Drawing.Color]::FromArgb(0, 150, 170) } else { [System.Drawing.Color]::FromArgb(52, 56, 64) })
    $b.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Add_Click({ param($sender, $e) Invoke-GuiAction ([string]$sender.Tag) })
    [void]$script:GuiButtons.Add($b)
    return $b
}

# The drop window: a list that patch files are dropped into, buttons for everything the menu does, and a colored log.
# All questions in it are small dialogs (Ask-YesNo and Read-Line know the difference), so nothing waits in the hidden console.
function Show-DropWindow([string[]]$Initial) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName Microsoft.VisualBasic
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $bg = [System.Drawing.Color]::FromArgb(24, 26, 30)
    $panel = [System.Drawing.Color]::FromArgb(36, 39, 45)
    $fg = [System.Drawing.Color]::FromArgb(225, 225, 225)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Patch Manager'
    $form.Size = New-Object System.Drawing.Size(1080, 800)
    $form.MinimumSize = New-Object System.Drawing.Size(860, 540)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = $bg
    $form.ForeColor = $fg
    $form.AllowDrop = $true
    try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-HostExe)) } catch { }
    $script:Form = $form

    # layout: status line on top, [drop zone + list + buttons | log] in the middle, the other buttons at the bottom
    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = [System.Windows.Forms.DockStyle]::Fill
    $root.ColumnCount = 2
    $root.RowCount = 3
    $root.Padding = New-Object System.Windows.Forms.Padding(12)
    [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 350)))
    [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 52)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 140)))

    $status = New-Object System.Windows.Forms.Label
    $status.Dock = [System.Windows.Forms.DockStyle]::Fill
    $status.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $status.ForeColor = [System.Drawing.Color]::FromArgb(140, 146, 158)
    $status.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $root.Controls.Add($status, 0, 0)
    $root.SetColumnSpan($status, 2)
    $script:GuiStatus = $status

    # left column
    $left = New-Object System.Windows.Forms.TableLayoutPanel
    $left.Dock = [System.Windows.Forms.DockStyle]::Fill
    $left.ColumnCount = 1
    $left.RowCount = 3
    $left.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 90)))

    $drop = New-Object System.Windows.Forms.Label
    $drop.Text = "Drop .patch files here`r`n(or a folder of them)`r`n`r`nor click to choose"
    $drop.Dock = [System.Windows.Forms.DockStyle]::Fill
    $drop.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $drop.BackColor = $panel
    $drop.ForeColor = [System.Drawing.Color]::FromArgb(150, 160, 175)
    $drop.Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
    $drop.Cursor = [System.Windows.Forms.Cursors]::Hand
    $drop.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $drop.AllowDrop = $true
    $drop.Add_Click({ Invoke-GuiAction 'browse' })
    $drop.Add_Paint({
            param($sender, $e)
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(0, 150, 170), 2)
            $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
            $rect = New-Object System.Drawing.Rectangle(6, 6, ($sender.Width - 12), ($sender.Height - 12))
            $e.Graphics.DrawRectangle($pen, $rect)
            $pen.Dispose()
        })
    $left.Controls.Add($drop, 0, 0)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Dock = [System.Windows.Forms.DockStyle]::Fill
    $list.BackColor = $panel
    $list.ForeColor = $fg
    $list.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $list.Font = New-Object System.Drawing.Font('Consolas', 10)
    $list.SelectionMode = [System.Windows.Forms.SelectionMode]::MultiExtended
    $list.IntegralHeight = $false
    $list.AllowDrop = $true
    $left.Controls.Add($list, 0, 1)
    $script:GuiList = $list

    $leftButtons = New-Object System.Windows.Forms.FlowLayoutPanel
    $leftButtons.Dock = [System.Windows.Forms.DockStyle]::Fill
    $leftButtons.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    $leftButtons.Controls.Add((New-GuiButton 'Apply' 'apply' $true 108))
    $leftButtons.Controls.Add((New-GuiButton 'Review' 'review' $false 108))
    $leftButtons.Controls.Add((New-GuiButton 'Changes' 'preview' $false 108))
    $leftButtons.Controls.Add((New-GuiButton 'Remove' 'remove' $false 108))
    $leftButtons.Controls.Add((New-GuiButton 'Clear list' 'clear' $false 108))
    $left.Controls.Add($leftButtons, 0, 2)
    $root.Controls.Add($left, 0, 1)

    # the log
    $log = New-Object System.Windows.Forms.RichTextBox
    $log.Dock = [System.Windows.Forms.DockStyle]::Fill
    $log.BackColor = [System.Drawing.Color]::FromArgb(17, 19, 22)
    $log.ForeColor = (Get-GuiColor 'Gray')
    $log.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $log.Font = New-Object System.Drawing.Font('Consolas', 10)
    $log.ReadOnly = $true
    $log.DetectUrls = $false
    $log.AllowDrop = $true
    $root.Controls.Add($log, 1, 1)

    # the bottom buttons
    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel
    $bottom.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bottom.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    foreach ($spec in @(
            @('Undo last', 'undo'), @('Restore snapshot', 'restore'), @('History', 'history'),
            @('Push to GitHub', 'push'), @('Project...', 'project'), @('Help', 'help'))) {
        $w = if ($spec[1] -eq 'restore' -or $spec[1] -eq 'push') { 140 } else { 112 }
        $bottom.Controls.Add((New-GuiButton $spec[0] $spec[1] $false $w))
    }
    # inspection mode: the controls of menu I
    foreach ($spec in @(
            @('Start inspect', 'istart'), @('Pause', 'ipause'), @('Checkpoint', 'icheck'), @('Session changes', 'iview'),
            @('Stop + patch', 'istop'), @('Cancel session', 'icancel'), @('Recover', 'irecover'), @('Sessions', 'isessions'))) {
        $iw = if ($spec[1] -eq 'iview' -or $spec[1] -eq 'icancel') { 132 } else { 112 }
        $ibtn = New-GuiButton $spec[0] $spec[1] ($spec[1] -eq 'istart') $iw
        if ($spec[1] -eq 'ipause') { $script:GuiPauseButton = $ibtn }
        $bottom.Controls.Add($ibtn)
    }
    $root.Controls.Add($bottom, 0, 2)
    $root.SetColumnSpan($bottom, 2)
    $form.Controls.Add($root)

    # dropping works on every part of the window
    $enter = { param($sender, $e) if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy } }
    $dropped = { param($sender, $e) Add-GuiPatches @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)) }
    foreach ($c in @($form, $drop, $list, $log)) {
        $c.Add_DragEnter($enter)
        $c.Add_DragDrop($dropped)
    }

    # live monitoring of an inspection: a timer (the watcher itself is started by Sync-InspectionState)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1500
    $timer.Add_Tick({ Invoke-InspectTick })

    $script:LogBox = $log
    try {
        Write-Info ('Project: ' + $script:Repo + '   (the Project... button switches)')
        Write-Info 'Drop patch files in this window (or click the dashed box). Then press Apply.'
        Say '       Review says if a patch is already applied. Changes shows what it changes, in colors.' 'DarkGray'
        Say '       Before every apply a safety snapshot is saved: Restore snapshot puts the files back.' 'DarkGray'
        Say '       Inspect: press Start inspect before a task and Stop + patch after it: what you changed becomes one patch.' 'DarkGray'
        if ($DryRun) { Write-Warn 'Dry run: nothing will be changed.' }
        $paths = @()
        foreach ($n in @($Initial)) {
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            $r = Resolve-PatchPath $n $true
            if ($null -ne $r) { foreach ($x in @($r)) { $paths += $x.FullName } } else { $paths += $n }
        }
        if ($paths.Count -gt 0) { Add-GuiPatches $paths }
        Update-GuiStatus
        Sync-InspectionState
        if ($script:InspectActiveId) { Write-Info ('An inspection session is still running: {0}. Stop + patch finishes it.' -f $script:InspectActiveId) }
        Set-GuiStatusText
        $timer.Start()
        [void]$form.ShowDialog()
    }
    finally {
        try { $timer.Stop(); $timer.Dispose() } catch { }
        Stop-InspectionWatcher
        $script:GuiPauseButton = $null
        $script:LogBox = $null
        $script:GuiStatus = $null
    }
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
        Write-MenuItem '5' 'Inspection mode' 'record a task, get one patch'
        Write-MenuItem '6' 'Push to GitHub' 'what is already committed, after the guard'
        Say ''
        Write-MenuItem 'D' 'Changes of a patch' 'colored, file by file'
        Write-MenuItem 'R' 'Restore a snapshot' 'puts the files of a patch back'
        Write-MenuItem 'O' 'Open another project' 'switch to a different git repository'
        Write-MenuItem 'W' 'Drop window' 'drop patches into a window'
        Write-MenuItem 'S' 'Desktop shortcut' 'start with a double-click'
        Write-MenuItem '?' 'Help'
        Write-MenuItem '7' 'Exit'
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
        elseif ($choice -eq '5' -or $key -eq 'i') { [void](Invoke-Safe 'inspecting' { Show-InspectionMenu }) }
        elseif ($choice -eq '6') { [void](Invoke-Safe 'pushing' { [void](Invoke-PushCommits) }) }
        elseif ($key -eq 'd') {
            [void](Invoke-Safe 'showing the changes' {
                $files = @(Read-DroppedPatches 'Drag the patch file (or several) whose changes you want to see into this window, then press Enter.')
                foreach ($f in $files) { Show-PatchDiff $f $true }
            })
        }
        elseif ($key -eq 'r') { [void](Invoke-Safe 'restoring' { [void](Invoke-RestoreSnapshot) }) }
        elseif ($key -eq 'o') { [void](Invoke-Safe 'opening the project' { [void](Invoke-ChooseProject) }) }
        elseif ($key -eq 'w') { [void](Invoke-Safe 'opening the window' { Show-DropWindow @() }) }
        elseif ($key -eq 's') { [void](Invoke-Safe 'making the shortcut' { [void](New-AppShortcut) }) }
        elseif ($choice -eq '?' -or $key -eq 'h' -or $key -eq 'help') { Show-Help }
        elseif ($choice -eq '7' -or $key -eq 'q' -or $key -eq 'exit') { break }
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
    if (-not $Gui) { Show-Banner }

    if (-not (Test-Repository)) {
        $ok = $false
        if ($Gui) {
            # the console is hidden in this mode, so say it in a box
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show('Patch Manager could not start: git was not found, or no project folder was chosen.', 'Patch Manager')
        }
    }
    else {
        if ($Gui) { Show-DropWindow @($Patch) }
        elseif ($History) { Show-PatchHistory }
        elseif ($CreateShortcut) { $ok = New-AppShortcut }
        elseif ($Undo) { $ok = Invoke-UndoPatch }
        elseif ($Inspect) { $ok = Invoke-InspectCli $Inspect }
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
        if ($Gui) { }
        elseif (-not $Interactive -and -not $Close) {
            Say ''
            Say '  Finished. The window stays open: you can go on here.' 'DarkGray'
            Show-Menu
        }
        elseif ($Interactive) {
            Offer-Shortcut
            Show-Menu
        }
    }
}
catch {
    $ok = $false
    if ($Gui) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show(('The tool stopped because of an error: ' + $_.Exception.Message), 'Patch Manager')
        }
        catch { }
    }
    else {
        Say ''
        Write-Fail ('The tool stopped because of an error: ' + $_.Exception.Message)
        Say ([string]$_.ScriptStackTrace) 'DarkGray'
    }
    Write-ErrorLog 'the tool' $_
}
if (-not $ok -and -not $Close -and -not $Gui -and [Environment]::UserInteractive) {
    Say ''
    Wait-AnyKey 'Something went wrong (see above). Press any key to close...'
}
