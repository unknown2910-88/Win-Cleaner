[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [switch]$InstallTask,

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$UninstallTask,

    [Parameter(ParameterSetName = 'Restore')]
    [switch]$Restore,

    [Parameter(ParameterSetName = 'Run')]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),

    [Parameter(ParameterSetName = 'Install')]
    [string]$InstallConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$TaskName = 'Win-Cleaner'
$ScriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$StateDirectory = Join-Path $env:ProgramData 'Win-Cleaner'
$StatePath = Join-Path $StateDirectory 'state.json'
$DefaultLogDirectory = Join-Path $StateDirectory 'Logs'
$script:FailedOperations = 0
$script:LogFile = $null

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $line
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-RestrictedAcl {
    param([Parameter(Mandatory)][string]$Path, [switch]$Directory)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
        $inheritance = if ($Directory) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
        $propagation = [Security.AccessControl.PropagationFlags]::None
        foreach ($account in @('SYSTEM', 'BUILTIN\Administrators')) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($account, 'FullControl', $inheritance, $propagation, 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        throw "Could not secure '$Path': $($_.Exception.Message)"
    }
}

function Initialize-SupportDirectories {
    New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
    Set-RestrictedAcl -Path $StateDirectory -Directory
    Set-RestrictedAcl -Path $script:LogDirectory -Directory
}

function Get-Settings {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: $Path" }
    try { $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { throw "Invalid JSON configuration: $($_.Exception.Message)" }
    if ([int]$settings.ConfigVersion -ne 1) { throw 'ConfigVersion must be 1.' }
    foreach ($name in @('CleanTemp','CleanRecycleBin','CleanUpdateCaches','DisableServices','LogDirectory')) {
        if ($null -eq $settings.$name) { throw "Missing configuration value: $name" }
    }
    foreach ($name in @('CleanTemp','CleanRecycleBin','CleanUpdateCaches')) {
        if ($settings.$name -isnot [bool]) { throw "$name must be a Boolean." }
    }
    if ($settings.DisableServices -isnot [array]) { throw 'DisableServices must be an array of service-name strings.' }
    foreach ($name in @($settings.DisableServices)) { if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) { throw 'DisableServices contains an invalid value.' } }
    if ($settings.LogDirectory -isnot [string] -or [string]::IsNullOrWhiteSpace($settings.LogDirectory)) { throw 'LogDirectory must be a non-empty path.' }
    return $settings
}

function Initialize-Logging {
    param([Parameter(Mandatory)]$Settings)
    $script:LogDirectory = [Environment]::ExpandEnvironmentVariables([string]$Settings.LogDirectory)
    Initialize-SupportDirectories
    $script:LogFile = Join-Path $script:LogDirectory ("cleanup-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

function Remove-FilesSafely {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    try {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | ForEach-Object {
            try {
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove')) { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop }
            } catch {
                $script:FailedOperations++
                Write-Log "Could not remove $($_.FullName): $($_.Exception.Message)" 'WARN'
            }
        }
    } catch { $script:FailedOperations++; Write-Log "Could not enumerate $Path`: $($_.Exception.Message)" 'WARN' }
}

function Clean-Temp {
    Write-Log 'Cleaning temporary files.'
    $paths = @($env:TEMP, $env:TMP, "$env:windir\Temp")
    if (Test-Path 'C:\Users') { Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $paths += Join-Path $_.FullName 'AppData\Local\Temp' } }
    $paths | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { Remove-FilesSafely $_ }
}

function Clean-UpdateCaches {
    Write-Log 'Cleaning optional Windows update caches.'
    if ($PSCmdlet.ShouldProcess('Windows Update services', 'Stop temporarily')) { Stop-Service -Name wuauserv,bits,dosvc -Force -ErrorAction SilentlyContinue }
    Remove-FilesSafely "$env:windir\SoftwareDistribution\Download"
    Remove-FilesSafely "$env:ProgramData\Microsoft\Windows\DeliveryOptimization\Cache"
    if ($PSCmdlet.ShouldProcess('Windows Update services', 'Start')) { Start-Service -Name bits,wuauserv,dosvc -ErrorAction SilentlyContinue }
}

function Clear-RecycleBinSafely {
    if ($PSCmdlet.ShouldProcess('all user Recycle Bins', 'Empty')) { Clear-RecycleBin -Force -ErrorAction Stop; Write-Log 'Recycle Bin emptied.' }
}

function Get-ServiceSnapshot {
    param([Parameter(Mandatory)][string]$Name)
    $service = Get-CimInstance Win32_Service -Filter "Name='$($Name.Replace("'", "''"))'" -ErrorAction Stop
    if (-not $service) { throw "Service not found: $Name" }
    [pscustomobject]@{ ServiceName = $Name; PreviousStartupType = [string]$service.StartMode; PreviousStatus = [string]$service.State }
}

function Save-ServiceSnapshot {
    param([Parameter(Mandatory)]$Snapshot)
    $existing = @()
    if (Test-Path -LiteralPath $StatePath) { $existing = @(Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).Services }
    if (-not ($existing | Where-Object ServiceName -eq $Snapshot.ServiceName)) { $existing += $Snapshot }
    $document = [pscustomobject]@{ StateVersion = 1; UpdatedAt = (Get-Date).ToString('o'); Services = @($existing) }
    $temp = "$StatePath.$PID.tmp"
    $document | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $StatePath -Force
    Set-RestrictedAcl -Path $StatePath
}

function Disable-ConfiguredServices {
    $protected = @('RpcSs','DcomLaunch','RpcEptMapper','SamSs','Winmgmt','EventLog','PlugPlay','Schedule','ProfSvc','UserManager','wuauserv','BITS','TrustedInstaller')
    foreach ($name in @($Settings.DisableServices)) {
        if ($protected -contains $name) { Write-Log "Refusing to disable protected service: $name" 'WARN'; continue }
        try {
            $snapshot = Get-ServiceSnapshot $name
            if ($PSCmdlet.ShouldProcess($name, 'Record state and disable service')) {
                Save-ServiceSnapshot $snapshot
                Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
                Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
                Write-Log "Disabled service: $name"
            }
        } catch { $script:FailedOperations++; Write-Log "Could not disable $name`: $($_.Exception.Message)" 'ERROR' }
    }
}

function Restore-ServiceChanges {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { Write-Log 'No service state file exists; nothing to restore.' 'WARN'; return }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    foreach ($entry in @($state.Services)) {
        try {
            if ($PSCmdlet.ShouldProcess($entry.ServiceName, 'Restore service startup type and status')) {
                $startup = switch ($entry.PreviousStartupType) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } 'Disabled' { 'Disabled' } 'Boot' { 'Automatic' } 'System' { 'Automatic' } default { throw "Unknown startup type '$($entry.PreviousStartupType)'" } }
                Set-Service -Name $entry.ServiceName -StartupType $startup -ErrorAction Stop
                if ($entry.PreviousStatus -eq 'Running') { Start-Service -Name $entry.ServiceName -ErrorAction Stop } elseif ($entry.PreviousStatus -eq 'Stopped') { Stop-Service -Name $entry.ServiceName -Force -ErrorAction SilentlyContinue }
                Write-Log "Restored service: $($entry.ServiceName)"
            }
        } catch { $script:FailedOperations++; Write-Log "Could not restore $($entry.ServiceName): $($_.Exception.Message)" 'ERROR' }
    }
}

function Install-CleanupTask {
    if (-not (Test-Administrator)) { throw 'Run task management from an elevated PowerShell window.' }
    $absoluteConfig = [IO.Path]::GetFullPath($InstallConfigPath)
    $null = Get-Settings $absoluteConfig
    $actionArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $ScriptPath, $absoluteConfig
    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument $actionArgs
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    if ($PSCmdlet.ShouldProcess($TaskName, 'Register SYSTEM startup task')) { Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null }
    Write-Host "Installed '$TaskName' using config '$absoluteConfig'."
}

function Uninstall-CleanupTask {
    if (-not (Test-Administrator)) { throw 'Run task management from an elevated PowerShell window.' }
    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop }
    Write-Host "Removed '$TaskName'. System changes were not restored; use -Restore explicitly."
}

if (-not (Test-Administrator)) { throw 'Win-Cleaner must run as Administrator.' }
if ($InstallTask) { Install-CleanupTask; exit 0 }
if ($UninstallTask) { Uninstall-CleanupTask; exit 0 }
if ($Restore) {
    $Settings = [pscustomobject]@{ LogDirectory = $DefaultLogDirectory }
    Initialize-Logging $Settings
    Restore-ServiceChanges
    if ($script:FailedOperations -gt 0) { exit 1 }
    exit 0
}

$Settings = Get-Settings $ConfigPath
Initialize-Logging $Settings
Write-Log 'Win-Cleaner started.'
try {
    if ($Settings.CleanTemp) { Clean-Temp }
    if ($Settings.CleanRecycleBin) { Clear-RecycleBinSafely }
    if ($Settings.CleanUpdateCaches) { Clean-UpdateCaches }
    Disable-ConfiguredServices
    Write-Log "Win-Cleaner finished with $script:FailedOperations failed operation(s)."
} catch {
    $script:FailedOperations++
    Write-Log "Critical failure: $($_.Exception.Message)" 'ERROR'
}
if ($script:FailedOperations -gt 0) { exit 1 }
exit 0
