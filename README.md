# Patch Manager

Apply `.patch` / `.diff` files to a git project **safely**, with one PowerShell file.

It checks for conflicts first, saves a safety snapshot, applies the patch, remembers it in a history,
and can undo it. It never forces a patch and never overwrites files that don't match.

## Quick start

1. **[Download PatchManager.ps1](https://github.com/ExhataQ/PatchManager/releases/latest/download/PatchManager.ps1)**
2. **Put it inside your project**, anywhere (for example in a `tools` folder). Nothing else to install or configure.
3. **Right-click it > Run with PowerShell.** It recognises the git project it sits in by itself.
4. Choose `1`, drag your `.patch` file into the window, press Enter.

Prefer the command line? From your project folder:

```powershell
Invoke-WebRequest https://github.com/ExhataQ/PatchManager/releases/latest/download/PatchManager.ps1 -OutFile tools\PatchManager.ps1
```

The same command updates it later. Requires Windows, PowerShell 5.1 or newer, and [git](https://git-scm.com/).

> Early version: try it on a throwaway branch first, and please report problems under **Issues**.

## What you can do

| Menu | |
|---|---|
| `1` | **Apply** a patch: checks first, saves a safety snapshot, applies, records it in the history |
| `2` | **Review**: is the patch already applied? Shows the changes in colors |
| `3` | **Undo** an applied patch (only if the files still match) |
| `4` | **History** of what was applied and when |
| `D` | Show a patch's changes, file by file |
| `R` | **Restore** a safety snapshot |

Several patches can be dropped at once; they are applied in order. From a terminal:
`powershell -ExecutionPolicy Bypass -File PatchManager.ps1 "C:\path\fix.patch"` (add `-DryRun` to only check).
`-Help` shows everything.

## How it finds your project

The project is the git repository that contains the script. If the script is not inside one, it uses the
folder you started it from. Each project gets a `.patch-manager\` folder (history and copies of applied patches).
That folder is added to `.git\info\exclude`, which is local to your clone, so **no tracked file changes and
nothing lands in a commit**. Snapshots live inside git under `refs/patch-manager/`.

## Safety

- Refuses patches that touch anything outside the project or inside `.git`.
- Reports "already applied" instead of applying twice.
- On a conflict it stops and leaves your files alone, unless you choose to apply the parts that fit
  (the rest goes into `.rej` files).
- A snapshot of the files a patch touches is saved before every apply and undo; the newest 30 are kept.
