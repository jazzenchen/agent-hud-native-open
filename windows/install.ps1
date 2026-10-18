param([switch]$Startup, [switch]$NoCursorHooks)
$ErrorActionPreference = 'Stop'
$python = (Get-Command python.exe -ErrorAction Stop).Source
& $python -c "import tkinter,sqlite3; assert __import__('sys').version_info >= (3,10)"
if ($LASTEXITCODE -ne 0) { throw 'Install Python 3.10+ with Tk from python.org first.' }
$pythonw = Join-Path (Split-Path $python) 'pythonw.exe'
if (-not (Test-Path -LiteralPath $pythonw)) { throw 'pythonw.exe is required.' }
$script = Join-Path $PSScriptRoot 'hud.py'
if (-not $NoCursorHooks) {
    & $python (Join-Path $PSScriptRoot 'install_hooks.py')
    if ($LASTEXITCODE -ne 0) { throw 'Cursor hook installation failed; check the existing hooks file.' }
}
$wsh = New-Object -ComObject WScript.Shell
$destinations = @(Join-Path ([Environment]::GetFolderPath('Desktop')) 'Agent HUD Open.lnk')
if ($Startup) { $destinations += Join-Path ([Environment]::GetFolderPath('Startup')) 'Agent HUD Open.lnk' }
foreach ($destination in $destinations) {
    $shortcut = $wsh.CreateShortcut($destination)
    $shortcut.TargetPath = $pythonw
    $shortcut.Arguments = '"' + $script + '"'
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Description = 'Agent HUD Open Windows companion for Codex and Cursor'
    $shortcut.Save()
}
Start-Process -FilePath $pythonw -ArgumentList ('"' + $script + '"') -WorkingDirectory $PSScriptRoot -WindowStyle Hidden
Write-Output 'Agent HUD started. Desktop shortcut created. Cursor observers apply to new turns.'
