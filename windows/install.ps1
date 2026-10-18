param([switch]$Startup, [switch]$NoCursorHooks)
$ErrorActionPreference = 'Stop'
$basePython = (Get-Command python.exe -ErrorAction Stop).Source
& $basePython -c "assert __import__('sys').version_info >= (3,10)"
if ($LASTEXITCODE -ne 0) { throw 'Install Python 3.10+ first.' }
$python = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    & $basePython -m venv (Join-Path $PSScriptRoot '.venv')
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the app environment.' }
}
& $python -c "import PySide6.QtWidgets,psutil"
if ($LASTEXITCODE -ne 0) {
    & $python -m pip install -r (Join-Path $PSScriptRoot 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Could not install the Windows UI dependencies.' }
}
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
    $shortcut.Description = 'Agent HUD Open'
    $shortcut.Save()
}
Get-CimInstance Win32_Process -Filter "name='pythonw.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine.Contains($script)
} | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
Start-Process -FilePath $pythonw -ArgumentList ('"' + $script + '"') -WorkingDirectory $PSScriptRoot -WindowStyle Hidden
Write-Output 'Agent HUD started. Desktop shortcut created. Cursor observers apply to new turns.'
