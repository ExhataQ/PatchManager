# Patch Manager

One PowerShell file. Put `PatchManager.ps1` anywhere inside a git project (for example a `tools` folder) and run it:
it finds the git project by itself and applies `.patch` files safely.

## Use

- Right-click `PatchManager.ps1` > **Run with PowerShell**, then choose `1` and drag a patch file into the window.
- Or from a terminal: `powershell -ExecutionPolicy Bypass -File PatchManager.ps1 "C:\path\fix.patch"`
- `-Help` shows everything.

## What it does

| Menu | |
|---|---|
| 1 | Apply a patch: checks first, saves a safety snapshot, applies, records it in the history |
| 2 | Review: is the patch already applied? Shows the changes in colors |
| 3 | Undo an applied patch (only if the files still match) |
| 4 | History |
| D | Show a patch's changes, file by file |
| R | Restore a safety snapshot |

It never forces a patch, never resets the repository, never overwrites a file that does not match.

## Data

Per project, in `.patch-manager\` (history, copies of applied patches). That folder is added to
`.git\info\exclude`, which is local to your clone, so no tracked file changes and nothing lands in a commit.
Snapshots live inside git under `refs/patch-manager/`.

## Requirements

Windows PowerShell 5.1 or newer, and git.

## Next steps (ideas)

`parked/` holds work for later, not part of the tool yet: an inspection mode (record a task as one patch, with
pause/checkpoints/recover), a drop window, and a project picker. The full version there has not been reviewed.
