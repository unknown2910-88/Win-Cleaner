[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$InstallTask,
    [switch]$UninstallTask,
    [switch]$WhatIf,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$TaskName = 'Win-Cleaner'
$ScriptPath = $MyInvocation.MyCommand.Path

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $line
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Settings {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration file not found: $ConfigPath"
    }
    $settings = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    foreach ($name in @('CleanTemp','CleanRecycleBin','CleanUpdateCaches','RemoveEdge','DisableServices','LogDirectory')) {
        if ($null -eq $settings.$name) { throw "Missing configuration value: $name" }
    }
    return $settings
}

function Remove-FilesSafely {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($WhatIf) { Write-Log "WHATIF: would remove $($_.FullName)"; return }
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Log "Could not remove $($_.FullName): $($_.Exception.Message)" 'WARN'
            }
        }
    } catch {
        Write-Log "Could not enumerate $Path`: $($_.Exception.Message)" 'WARN'
    }
}

function Clean-Temp {
    Write-Log 'Cleaning temporary files.'
    $paths = @($env:TEMP, $env:TMP, "$env:windir\Temp")
    if (Test-Path 'C:\Users') {
        Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $paths += (Join-Path $_.FullName 'AppData\Local\Temp')
        }
    }
    $paths | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { Remove-FilesSafely $_ }
}

function Clean-UpdateCaches {
    Write-Log 'Cleaning optional Windows update caches.'
    if (-not $WhatIf) {
        Stop-Service -Name wuauserv,bits,dosvc -Force -ErrorAction SilentlyContinue
    }
    Remove-FilesSafely "$env:windir\SoftwareDistribution\Download"
    Remove-FilesSafely "$env:ProgramData\Microsoft\Windows\DeliveryOptimization\Cache"
    if (-not $WhatIf) {
        Start-Service -Name bits,wuauserv,dosvc -ErrorAction SilentlyContinue
    }
}

function Clear-RecycleBinSafely {
    Write-Log 'Emptying Recycle Bin.'
    if ($WhatIf) { Write-Log 'WHATIF: would empty all Recycle Bins.'; return }
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
}

function Remove-EdgeSafely {
    Write-Log 'Microsoft Edge removal was explicitly enabled.' 'WARN'
    $setup = Get-ChildItem "$env:ProgramFiles(x86)\Microsoft\Edge\Application\*\Installer\setup.exe", "$env:ProgramFiles\Microsoft\Edge\Application\*\Installer\setup.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $setup) {
        Write-Log 'Edge installer was not found; no removal performed.' 'WARN'
        return
    }
    $arguments = '--uninstall --system-level --force-uninstall'
    if ($WhatIf) { Write-Log "WHATIF: would run $($setup.FullName) $arguments"; return }
    Start-Process -FilePath $setup.FullName -ArgumentList $arguments -Wait -WindowStyle Hidden
    Write-Log 'Edge uninstall command completed. Some Windows versions may restore Edge through updates.' 'WARN'
}

function Disable-ConfiguredServices {
    $protected = @('RpcSs','DcomLaunch','RpcEptMapper','SamSs','Winmgmt','EventLog','PlugPlay','Schedule','ProfSvc','UserManager','wuauserv','BITS','TrustedInstaller')
    foreach ($name in @($Settings.DisableServices)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($protected -contains $name) {
            Write-Log "Refusing to disable protected service: $name" 'WARN'
            continue
        }
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $service) { Write-Log "Service not found: $name" 'WARN'; continue }
        if ($WhatIf) { Write-Log "WHATIF: would stop and disable service $name"; continue }
        try {
            if ($service.Status -eq 'Running') { Stop-Service -Name $name -Force -ErrorAction Stop }
            Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
            Write-Log "Disabled service: $name"
        } catch { Write-Log "Could not disable $name`: $($_.Exception.Message)" 'WARN' }
    }
}

function Install-CleanupTask {
    if (-not (Test-Administrator)) { throw 'Run -InstallTask from an elevated PowerShell window.' }
    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Installed elevated startup task '$TaskName'."
}

function Uninstall-CleanupTask {
    if (-not (Test-Administrator)) { throw 'Run -UninstallTask from an elevated PowerShell window.' }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Removed scheduled task '$TaskName'."
}

if ($WhatIf) { $WhatIfPreference = $true }
if ($InstallTask) { Install-CleanupTask; return }
if ($UninstallTask) { Uninstall-CleanupTask; return }
if (-not (Test-Administrator)) { throw 'Win-Cleaner must run as Administrator.' }

$Settings = Get-Settings
$logDirectory = [Environment]::ExpandEnvironmentVariables([string]$Settings.LogDirectory)
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$script:LogFile = Join-Path $logDirectory ("cleanup-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
Write-Log 'Win-Cleaner started.'
if ($Settings.CleanTemp) { Clean-Temp }
if ($Settings.CleanRecycleBin) { Clear-RecycleBinSafely }
if ($Settings.CleanUpdateCaches) { Clean-UpdateCaches }
if ($Settings.RemoveEdge) { Remove-EdgeSafely }
Disable-ConfiguredServices
Write-Log 'Win-Cleaner finished.'
