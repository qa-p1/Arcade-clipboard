# CI only, not a real desktop: use the ephemeral runner account for shortcuts
# and Apps & features, with receipts, manifests and PATH under isolated ARCADE_HOME.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Version)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT' -or -not $env:RUNNER_TEMP) {
    throw 'Run this only on the Windows GitHub Actions runner.'
}

$installer = Get-Item -LiteralPath (Join-Path $PSScriptRoot "../dist/packages/Arcade-Clipboard_${Version}_windows_x64-setup.exe")
$root = Join-Path $env:RUNNER_TEMP ('clipboard-install-' + [guid]::NewGuid().ToString('N'))
$env:ARCADE_HOME = Join-Path $root 'arcade'
$env:ARCADE_DATA_DIR = Join-Path $root 'profile'
$env:ARCADE_NO_INSTALL_PROMPT = '1'
$receiptFile = Join-Path $env:ARCADE_HOME 'installs/arcade.clipboard.json'
$manifestFile = Join-Path $env:ARCADE_HOME 'apps/arcade.clipboard.json'
$shim = Join-Path $env:ARCADE_HOME 'bin/arcade-clipboard.cmd'
$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Arcade Clipboard.lnk'
$launcher = Join-Path ([Environment]::GetFolderPath('Programs')) 'Arcade Clipboard\Arcade Clipboard.lnk'
$desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Arcade Clipboard.lnk'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\arcade.clipboard'
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$destinations = @()
$passed = $false

# Match Lens's check of the shared helper's isolated registry keys. ARCADE_HOME
# deliberately does not add a disposable folder to the real HKCU Environment.
function Get-PathEntryCount {
    $keys = 'HKCU:\Software\ArcadeLink\Isolated'
    if (-not (Test-Path -LiteralPath $keys)) { return 0 }
    $count = 0
    $bin = (Join-Path $env:ARCADE_HOME 'bin').TrimEnd('\', '/')
    foreach ($key in Get-ChildItem -LiteralPath $keys) {
        $path = (Get-ItemProperty -LiteralPath $key.PSPath -Name Path -ErrorAction SilentlyContinue).Path
        $count += @($path -split ';' | Where-Object { $_.Trim().Trim('"').TrimEnd('\', '/') -ieq $bin }).Count
    }
    return $count
}

function Invoke-ClipboardCli([string]$Executable, [string]$Arguments) {
    $output = Join-Path $root ([guid]::NewGuid().ToString('N') + '.stdout')
    $errors = $output + '.stderr'
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -PassThru `
        -RedirectStandardOutput $output -RedirectStandardError $errors
    if (-not $process.WaitForExit(30000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "Clipboard CLI timed out: $Arguments"
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "Clipboard CLI failed ($($process.ExitCode)): $Arguments`n$(Get-Content -Raw -LiteralPath $errors)"
    }
    return [string](Get-Content -Raw -LiteralPath $output -Encoding utf8)
}

function Install-Clipboard([string]$Destination, [string]$Mode, [bool]$Startup, [bool]$Tools = $false) {
    $task = if ($Startup) { 'arcade_startup' } else { '!arcade_startup' }
    $arguments = @($Mode, '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', "/MERGETASKS=$task", "/DIR=`"$Destination`"")
    if ($Tools) { $arguments += '/ARCADEMANAGEDBY=tools', '/ARCADECHANNEL=nightly' }
    $process = Start-Process -FilePath $installer.FullName -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        $log = Join-Path $Destination 'arcade-integration-error.log'
        $detail = if (Test-Path -LiteralPath $log) { Get-Content -Raw -LiteralPath $log } else { '' }
        throw "Inno install exited $($process.ExitCode).`n$detail"
    }
}

function Assert-Installed([string]$Destination, [bool]$Startup, [bool]$Tools = $false) {
    $receipt = Get-Content -Raw -LiteralPath $receiptFile -Encoding utf8 | ConvertFrom-Json
    $executable = Join-Path $Destination 'clipboard.exe'
    $owner = if ($Tools) { 'tools' } else { 'self' }
    $channel = if ($Tools) { 'nightly' } else { 'stable' }
    if ($receipt.schema -ne 1 -or $receipt.id -ne 'arcade.clipboard' -or $receipt.method -ne 'windows-installer' -or
        $receipt.version -ne $Version -or $receipt.path -ine $executable -or $receipt.managedBy -ne $owner -or $receipt.channel -ne $channel) {
        throw 'Installer receipt has unexpected identity, version, path or ownership.'
    }
    if ($receipt.integration.cli -ine $shim -or $receipt.integration.desktopEntry -ine $launcher -or
        $receipt.integration.uninstaller -ine (Join-Path $Destination 'unins000.exe')) { throw 'Wrong receipt integration paths.' }
    if (-not (Test-Path -LiteralPath $shim) -or -not (Test-Path -LiteralPath $launcher)) { throw 'CLI shim or Start menu launcher is missing.' }
    if ($receipt.integration.desktopShortcut -or (Test-Path -LiteralPath $desktop)) { throw 'Unchecked desktop task created a shortcut.' }
    if ($Startup) {
        if ($receipt.integration.autostart -ine $startupShortcut -or -not (Test-Path -LiteralPath $startupShortcut)) { throw 'Selected startup task was not honored.' }
    } elseif ($receipt.integration.autostart -or (Test-Path -LiteralPath $startupShortcut)) { throw 'Deselected startup task created a shortcut.' }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcuts = @($launcher)
        if ($Startup) { $shortcuts += $startupShortcut }
        foreach ($path in $shortcuts) {
            $shortcut = $shell.CreateShortcut($path)
            try {
                if ($shortcut.TargetPath -ine $executable) { throw 'Shortcut targets another installation.' }
                if ($path -eq $startupShortcut -and $shortcut.Arguments -ne '--background') { throw 'Startup shortcut is not a background launch.' }
            } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null }
        }
    } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    $metadata = Get-ItemProperty -LiteralPath $uninstallKey
    if ($metadata.DisplayName -ne 'Arcade Clipboard' -or $metadata.DisplayVersion -ne $Version -or $metadata.Publisher -ne 'qa-p1' -or
        $metadata.InstallLocation -ine $Destination -or $metadata.UninstallString -ne ('"' + $receipt.integration.uninstaller + '"') -or
        $metadata.QuietUninstallString -notlike '*/VERYSILENT /SUPPRESSMSGBOXES /NORESTART') { throw 'Apps & features metadata is incorrect.' }
    if ((Get-PathEntryCount) -ne 1) { throw 'Isolated PATH must contain the Arcade bin exactly once.' }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $originalUserPath) { throw 'Installer changed the real user PATH.' }
    if ((Invoke-ClipboardCli $executable '--version').Trim() -ne "Arcade Clipboard $Version") { throw 'Installed executable reported the wrong version.' }
    $status = Invoke-ClipboardCli $executable '--integration-status' | ConvertFrom-Json
    if ($status.receipt.path -ine $executable -or @($status.entries).Count -eq 0 -or
        @($status.entries | Where-Object { -not $_.exists }).Count -gt 0) { throw 'Installed integration status contains missing entries.' }
    $shimVersion = Invoke-ClipboardCli $env:ComSpec ('/d /s /c ""' + $shim + '" --version"')
    if ($shimVersion.Trim() -ne "Arcade Clipboard $Version") { throw 'CLI shim did not forward --version.' }
    # No resident is started by the test. --quit must still succeed before uninstall.
    Invoke-ClipboardCli $executable '--quit' | Out-Null
    if (Get-Process -Name clipboard -ErrorAction SilentlyContinue) { throw 'Silent setup or a CLI command left Clipboard running.' }
    return $receipt
}

function Write-ManifestFixture([string]$Executable) {
    # A normal resident publishes this file. Save the installed CLI's manifest
    # to exercise cleanup without claiming a real desktop/Link session ran.
    $text = Invoke-ClipboardCli $Executable '--arcade-manifest'
    $manifest = $text | ConvertFrom-Json
    if ($manifest.id -ne 'arcade.clipboard' -or $manifest.version -ne $Version) { throw 'Installed manifest has the wrong identity.' }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifestFile) | Out-Null
    [IO.File]::WriteAllText($manifestFile, $text)
}

function Uninstall-Clipboard([string]$Destination) {
    $process = Start-Process -FilePath (Join-Path $Destination 'unins000.exe') `
        -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Inno uninstall exited $($process.ExitCode)." }
    if (Test-Path -LiteralPath (Join-Path $Destination 'clipboard.exe')) { throw 'Uninstaller left the executable behind.' }
}

function Assert-Uninstalled {
    foreach ($path in @($receiptFile, $shim, $manifestFile, $launcher, $startupShortcut, $desktop, $uninstallKey)) {
        if (Test-Path -LiteralPath $path) { throw "Uninstaller left integration behind: $path" }
    }
    if ((Get-PathEntryCount) -ne 0) { throw 'Uninstaller left its isolated PATH entry behind.' }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $originalUserPath) { throw 'Uninstaller changed the real user PATH.' }
}

foreach ($path in @($startupShortcut, $launcher, $desktop, $uninstallKey)) {
    if (Test-Path -LiteralPath $path) { throw "Unexpected pre-existing Clipboard integration: $path" }
}
New-Item -ItemType Directory -Path $root | Out-Null
try {
    # Fresh installs establish /SILENT and /VERYSILENT parity, and the opt-out
    # startup task, without relying on previously selected Inno tasks.
    $scenarios = @(
        @{ Mode = '/SILENT'; Startup = $true },
        @{ Mode = '/VERYSILENT'; Startup = $true },
        @{ Mode = '/VERYSILENT'; Startup = $false }
    )
    foreach ($scenario in $scenarios) {
        $destination = Join-Path $root ("Installed " + $destinations.Count)
        $destinations += $destination
        Install-Clipboard $destination $scenario.Mode $scenario.Startup
        $receipt = Assert-Installed $destination $scenario.Startup
        Write-ManifestFixture $receipt.path
        Uninstall-Clipboard $destination
        Assert-Uninstalled
    }

    # Wheel/Lens ownership pattern: installing a successor in another folder
    # must preserve its shared integration when the old copy is uninstalled.
    $old = Join-Path $root 'Old installation'
    $successor = Join-Path $root 'Successor installation'
    $destinations += $old, $successor
    Install-Clipboard $old '/VERYSILENT' $true
    $receipt = Assert-Installed $old $true
    Write-ManifestFixture $receipt.path
    Install-Clipboard $successor '/VERYSILENT' $true $true
    $receipt = Assert-Installed $successor $true $true
    Write-ManifestFixture $receipt.path
    $savedReceipt = Get-Content -Raw -LiteralPath $receiptFile
    $savedShim = Get-Content -Raw -LiteralPath $shim
    $savedManifest = Get-Content -Raw -LiteralPath $manifestFile
    $powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned `
        -File (Join-Path $old 'arcade-integration.ps1') -Action Uninstall -Id arcade.clipboard `
        -CliName arcade-clipboard -ExePath (Join-Path $old 'clipboard.exe')
    if ($LASTEXITCODE -ne 10) { throw "Old integration helper must exit 10, got $LASTEXITCODE." }
    # Inno maps the helper's ownership refusal to a successful removal of just
    # the old installation. Its own exit code is 0, not the helper's 10.
    Uninstall-Clipboard $old
    if ((Get-Content -Raw -LiteralPath $receiptFile) -cne $savedReceipt -or
        (Get-Content -Raw -LiteralPath $shim) -cne $savedShim -or
        (Get-Content -Raw -LiteralPath $manifestFile) -cne $savedManifest) { throw 'Old uninstall changed successor integration.' }
    Assert-Installed $successor $true $true | Out-Null
    Uninstall-Clipboard $successor
    Assert-Uninstalled
    $passed = $true
    Write-Output 'Windows installer lifecycle passed (CI only, not a real desktop): silent parity, tasks, receipt, CLI, launcher, Apps & features, isolated PATH, successor ownership and cleanup.'
} finally {
    # Only uninstall copies created by this test. On failure retain its files
    # and logs in RUNNER_TEMP for diagnosis; the CI account is disposable.
    for ($i = $destinations.Count - 1; $i -ge 0; $i--) {
        if (Test-Path -LiteralPath (Join-Path $destinations[$i] 'unins000.exe')) {
            try { Uninstall-Clipboard $destinations[$i] } catch { Write-Warning "Installer cleanup failed: $_" }
        }
    }
    if ($passed) { Remove-Item -LiteralPath $root -Recurse -Force }
    else { Write-Output "Installer diagnostics: $root" }
}
