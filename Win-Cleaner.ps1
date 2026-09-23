[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$InstallTask,
    [switch]$UninstallTask,
    [switch]$Restore,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$TaskName = 'Win-Cleaner'
$SystemPromptTaskName = 'Win-Cleaner - SYSTEM Command Prompt'
$ScriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$StateDirectory = Join-Path $env:ProgramData 'Win-Cleaner'
$StatePath = Join-Path $StateDirectory 'state.json'
$script:FailedOperations = 0
$script:LogFile = $null
$script:LogDirectory = $null
$script:Settings = $null

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $line
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop }
}

function Add-Failure { param([string]$Message, [string]$Level = 'ERROR'); $script:FailedOperations++; Write-Log $Message $Level }

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FullPath { param([Parameter(Mandatory)][string]$Path); return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)) }

function Test-UnderDirectory {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Directory)
    $root = (Get-FullPath $Directory).TrimEnd('\') + '\'
    return ((Get-FullPath $Path) + '\').StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

function Set-RestrictedAcl {
    param([Parameter(Mandatory)][string]$Path, [switch]$Directory)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    $inheritance = if ($Directory) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
    foreach ($account in @('SYSTEM', 'BUILTIN\Administrators')) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($account, 'FullControl', $inheritance, [Security.AccessControl.PropagationFlags]::None, 'Allow')
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Initialize-SupportDirectories {
    New-Item -ItemType Directory -Path $StateDirectory -Force -ErrorAction Stop | Out-Null
    Set-RestrictedAcl -Path $StateDirectory -Directory
    New-Item -ItemType Directory -Path $script:LogDirectory -Force -ErrorAction Stop | Out-Null
    Set-RestrictedAcl -Path $script:LogDirectory -Directory
}

function Get-Settings {
    param([Parameter(Mandatory)][string]$Path)
    $Path = Get-FullPath $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: $Path" }
    try { $settings = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { throw "Invalid JSON configuration: $($_.Exception.Message)" }
    if ($null -eq $settings -or [int]$settings.ConfigVersion -ne 1) { throw 'ConfigVersion must be 1.' }
    foreach ($name in @('CleanTemp','CleanRecycleBin','CleanUpdateCaches','RemoveEdge','OpenSystemCommandPrompt','SystemCommandPromptDelaySeconds','DisableServices','LogDirectory')) { if ($null -eq $settings.$name) { throw "Missing configuration value: $name" } }
    foreach ($name in @('CleanTemp','CleanRecycleBin','CleanUpdateCaches','RemoveEdge','OpenSystemCommandPrompt')) { if ($settings.$name -isnot [bool]) { throw "$name must be a Boolean." } }
    if ($settings.SystemCommandPromptDelaySeconds -isnot [int] -and $settings.SystemCommandPromptDelaySeconds -isnot [long]) { throw 'SystemCommandPromptDelaySeconds must be an integer.' }
    if ([long]$settings.SystemCommandPromptDelaySeconds -lt 0 -or [long]$settings.SystemCommandPromptDelaySeconds -gt 86400) { throw 'SystemCommandPromptDelaySeconds must be between 0 and 86400.' }
    if ($settings.DisableServices -isnot [array]) { throw 'DisableServices must be an array of service-name strings.' }
    foreach ($name in @($settings.DisableServices)) { if ($name -isnot [string] -or $name -notmatch '^[A-Za-z0-9_.-]{1,256}$') { throw "Invalid service name: $name" } }
    if ($settings.LogDirectory -isnot [string] -or [string]::IsNullOrWhiteSpace($settings.LogDirectory)) { throw 'LogDirectory must be a non-empty path.' }
    $logPath = Get-FullPath $settings.LogDirectory
    if (-not (Test-UnderDirectory $logPath $StateDirectory)) { throw "LogDirectory must be inside $StateDirectory; arbitrary ACL targets are not allowed." }
    $settings | Add-Member -NotePropertyName ResolvedLogDirectory -NotePropertyValue $logPath -Force
    return $settings
}

function Initialize-Logging {
    param([Parameter(Mandatory)]$Settings)
    $script:LogDirectory = [string]$Settings.ResolvedLogDirectory
    Initialize-SupportDirectories
    $script:LogFile = Join-Path $script:LogDirectory ("cleanup-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

function Remove-FilesSafely {
    [CmdletBinding(SupportsShouldProcess)] param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    try {
        foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
            try { if ($PSCmdlet.ShouldProcess($item.FullName, 'Remove')) { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop } }
            catch { Add-Failure "Could not remove $($item.FullName): $($_.Exception.Message)" 'WARN' }
        }
    } catch { Add-Failure "Could not enumerate $Path`: $($_.Exception.Message)" 'WARN' }
}

function Clean-Temp {
    Write-Log 'Cleaning temporary files.'
    $paths = @($env:TEMP, $env:TMP, "$env:windir\Temp")
    if (Test-Path 'C:\Users' -PathType Container) { foreach ($user in @(Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue)) { $paths += Join-Path $user.FullName 'AppData\Local\Temp' } }
    foreach ($path in @($paths | Where-Object { $_ } | Select-Object -Unique)) { Remove-FilesSafely $path }
}

function Clean-UpdateCaches {
    [CmdletBinding(SupportsShouldProcess)] param()
    Write-Log 'Cleaning optional Windows update caches.'
    $names = @('wuauserv','BITS','DoSvc')
    $before = @{}
    foreach ($name in $names) { try { $before[$name] = (Get-Service -Name $name -ErrorAction Stop).Status } catch { Add-Failure "Could not query service $name: $($_.Exception.Message)" 'WARN' } }
    try {
        if ($PSCmdlet.ShouldProcess(($names -join ', '), 'Stop temporarily')) { foreach ($name in $names) { if ($before.ContainsKey($name) -and $before[$name] -eq 'Running') { Stop-Service -Name $name -Force -ErrorAction Stop } } }
        Remove-FilesSafely "$env:windir\SoftwareDistribution\Download"
        Remove-FilesSafely "$env:ProgramData\Microsoft\Windows\DeliveryOptimization\Cache"
    } catch { Add-Failure "Update-cache cleanup failed: $($_.Exception.Message)" 'ERROR' }
    finally {
        foreach ($name in $names) { try { if ($before.ContainsKey($name) -and $before[$name] -eq 'Running' -and $PSCmdlet.ShouldProcess($name, 'Restore running state')) { Start-Service -Name $name -ErrorAction Stop } } catch { Add-Failure "Could not restore service $name: $($_.Exception.Message)" 'ERROR' } }
    }
}

function Clear-RecycleBinSafely {
    [CmdletBinding(SupportsShouldProcess)] param()
    if ($PSCmdlet.ShouldProcess('the current execution identity''s Recycle Bin', 'Empty')) {
        try { Clear-RecycleBin -Force -ErrorAction Stop; Write-Log 'Recycle Bin cleanup completed for the current execution identity. It does not guarantee removal of every user''s Recycle Bin.' 'WARN' }
        catch { Add-Failure "Recycle Bin cleanup failed: $($_.Exception.Message)" 'WARN' }
    }
}

function Get-ServiceSnapshot {
    param([Parameter(Mandatory)][string]$Name)
    $service = Get-CimInstance Win32_Service -Filter "Name='$($Name.Replace("'", "''"))'" -ErrorAction Stop
    if ($null -eq $service) { throw "Service not found: $Name" }
    if ([string]$service.StartMode -notin @('Auto','Manual','Disabled','Boot','System')) { throw "Unsupported startup mode '$($service.StartMode)' for $Name; refusing to change it." }
    [pscustomobject]@{ ServiceName = $Name; PreviousStartupType = [string]$service.StartMode; PreviousStatus = [string]$service.State }
}

function Write-State {
    param([Parameter(Mandatory)]$Document)
    New-Item -ItemType Directory -Path $StateDirectory -Force -ErrorAction Stop | Out-Null
    Set-RestrictedAcl -Path $StateDirectory -Directory
    $temp = Join-Path $StateDirectory ("state.$PID.$([guid]::NewGuid().ToString('N')).tmp")
    try {
        $Document | ConvertTo-Json -Depth 6 -ErrorAction Stop | Set-Content -LiteralPath $temp -Encoding UTF8 -ErrorAction Stop
        Set-RestrictedAcl -Path $temp
        Move-Item -LiteralPath $temp -Destination $StatePath -Force -ErrorAction Stop
        Set-RestrictedAcl -Path $StatePath
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function Save-ServiceSnapshot {
    param([Parameter(Mandatory)]$Snapshot)
    $existing = @()
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $state = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $state.Services) { $existing = @($state.Services) }
    }
    if (-not ($existing | Where-Object { $_.ServiceName -eq $Snapshot.ServiceName })) { $existing += $Snapshot }
    Write-State ([pscustomobject]@{ StateVersion = 1; UpdatedAt = (Get-Date).ToString('o'); Services = @($existing) })
}

function Set-ServiceStartupType {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$StartupType)
    switch ($StartupType) {
        'Auto' { Set-Service -Name $Name -StartupType Automatic -ErrorAction Stop }
        'Manual' { Set-Service -Name $Name -StartupType Manual -ErrorAction Stop }
        'Disabled' { Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop }
        'Boot' { $p = Start-Process -FilePath "$env:windir\System32\sc.exe" -ArgumentList @('config',$Name,'start=','boot') -Wait -PassThru -WindowStyle Hidden; if ($p.ExitCode -ne 0) { throw "sc.exe returned $($p.ExitCode)" } }
        'System' { $p = Start-Process -FilePath "$env:windir\System32\sc.exe" -ArgumentList @('config',$Name,'start=','system') -Wait -PassThru -WindowStyle Hidden; if ($p.ExitCode -ne 0) { throw "sc.exe returned $($p.ExitCode)" } }
        default { throw "Unsupported startup mode '$StartupType'." }
    }
}

function Disable-ConfiguredServices {
    $protected = @('RpcSs','DcomLaunch','RpcEptMapper','SamSs','Winmgmt','EventLog','PlugPlay','Schedule','ProfSvc','UserManager','wuauserv','BITS','TrustedInstaller')
    foreach ($name in @($script:Settings.DisableServices)) {
        if ($protected -contains $name) { Write-Log "Refusing to disable protected service: $name" 'WARN'; continue }
        try {
            $snapshot = Get-ServiceSnapshot $name
            if ($PSCmdlet.ShouldProcess($name, 'Record state and disable service')) {
                Save-ServiceSnapshot $snapshot
                $service = Get-Service -Name $name -ErrorAction Stop
                if ($service.Status -eq 'Running') { Stop-Service -Name $name -Force -ErrorAction Stop }
                Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
                Write-Log "Disabled service: $name"
            }
        } catch { Add-Failure "Could not disable $name`: $($_.Exception.Message)" 'ERROR' }
    }
}

function Restore-ServiceChanges {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { Write-Log 'No service state file exists; nothing to restore.' 'WARN'; return }
    $state = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $state.Services) { throw 'State file does not contain a Services collection.' }
    $remaining = @()
    foreach ($entry in @($state.Services)) {
        try {
            if ($PSCmdlet.ShouldProcess($entry.ServiceName, 'Restore service startup type and status')) {
                Get-Service -Name $entry.ServiceName -ErrorAction Stop | Out-Null
                Set-ServiceStartupType -Name $entry.ServiceName -StartupType ([string]$entry.PreviousStartupType)
                if ([string]$entry.PreviousStatus -eq 'Running') { Start-Service -Name $entry.ServiceName -ErrorAction Stop }
                elseif ([string]$entry.PreviousStatus -eq 'Stopped') { Stop-Service -Name $entry.ServiceName -Force -ErrorAction Stop }
                Write-Log "Restored service: $($entry.ServiceName)"
            } else { $remaining += $entry }
        } catch { $remaining += $entry; Add-Failure "Could not restore $($entry.ServiceName): $($_.Exception.Message)" 'ERROR' }
    }
    if ($remaining.Count -eq 0 -and -not $WhatIfPreference) {
        if ($PSCmdlet.ShouldProcess($StatePath, 'Remove fully restored service state')) { Remove-Item -LiteralPath $StatePath -Force -ErrorAction Stop; Write-Log 'All recorded service changes were restored; state file removed.' }
    } elseif (-not $WhatIfPreference) { Write-State ([pscustomobject]@{ StateVersion = 1; UpdatedAt = (Get-Date).ToString('o'); Services = @($remaining) }); Write-Log "$($remaining.Count) service state record(s) remain due to partial restore." 'WARN' }
}

function Test-SignedMicrosoftExecutable {
    param([Parameter(Mandatory)][string]$Path)
    $signature = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
    return ($signature.Status -eq 'Valid' -and $null -ne $signature.SignerCertificate -and $signature.SignerCertificate.Subject -match 'Microsoft')
}

function Remove-EdgeSafely {
    [CmdletBinding(SupportsShouldProcess)] param()
    Write-Log 'Microsoft Edge removal was explicitly enabled.' 'WARN'
    $candidates = @(Get-ChildItem "$env:ProgramFiles(x86)\Microsoft\Edge\Application\*\Installer\setup.exe", "$env:ProgramFiles\Microsoft\Edge\Application\*\Installer\setup.exe" -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
    $setup = $candidates | Where-Object { Test-SignedMicrosoftExecutable $_.FullName } | Select-Object -First 1
    if ($null -eq $setup) { Add-Failure 'No valid Microsoft-signed Edge setup executable was found.' 'WARN'; return }
    $arguments = @('--uninstall','--system-level','--force-uninstall')
    if ($PSCmdlet.ShouldProcess($setup.FullName, 'Uninstall Microsoft Edge')) {
        $process = Start-Process -FilePath $setup.FullName -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($process.ExitCode -ne 0) { Add-Failure "Edge uninstall failed with exit code $($process.ExitCode)." 'ERROR' }
        else { Write-Log 'Edge uninstall process exited successfully. Windows updates may restore Edge later.' 'WARN' }
    }
}

function Install-SystemPromptTask {
    if (-not $script:Settings.OpenSystemCommandPrompt) { return }
    $delayIso = 'PT{0}S' -f ([int]$script:Settings.SystemCommandPromptDelaySeconds)
    # SYSTEM plus InteractiveToken is invalid for this boot-triggered task. Use ServiceAccount.
    # Windows Session 0 isolation means this command prompt runs non-interactively in Session 0;
    # Task Scheduler cannot reliably display it on the logged-on user's desktop.
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Experimental SYSTEM command prompt; runs in isolated Session 0.</Description></RegistrationInfo>
  <Triggers><BootTrigger><Enabled>true</Enabled><Delay>$delayIso</Delay></BootTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><LogonType>ServiceAccount</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Enabled>true</Enabled></Settings>
  <Actions Context="Author"><Exec><Command>$env:windir\System32\cmd.exe</Command><Arguments>/k title Win-Cleaner SYSTEM Command Prompt</Arguments></Exec></Actions>
</Task>
"@
    if ($PSCmdlet.ShouldProcess($SystemPromptTaskName, 'Install SYSTEM command prompt task')) { Register-ScheduledTask -TaskName $SystemPromptTaskName -Xml $xml -Force -ErrorAction Stop | Out-Null; Write-Log "Installed SYSTEM command prompt task with $([int]$script:Settings.SystemCommandPromptDelaySeconds) second delay. It will run in isolated Session 0 and is not expected to be visible on the user desktop." 'WARN' }
}

function Install-CleanupTask {
    if (-not (Test-Administrator)) { throw 'Run task management from an elevated PowerShell window.' }
    $absoluteConfig = Get-FullPath $ConfigPath
    $null = Get-Settings $absoluteConfig
    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $ScriptPath, $absoluteConfig)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    if ($PSCmdlet.ShouldProcess($TaskName, 'Register SYSTEM startup task')) { Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null; Install-SystemPromptTask }
    Write-Host "Installed '$TaskName' using '$absoluteConfig'."
}

function Uninstall-CleanupTask {
    if (-not (Test-Administrator)) { throw 'Run task management from an elevated PowerShell window.' }
    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop }
    if ($PSCmdlet.ShouldProcess($SystemPromptTaskName, 'Unregister SYSTEM prompt task')) { Unregister-ScheduledTask -TaskName $SystemPromptTaskName -Confirm:$false -ErrorAction Stop }
    Write-Host 'Removed startup tasks. This does not restore service or Edge changes; use -Restore for service state.'
}

if (-not (Test-Administrator)) { throw 'Win-Cleaner must run as Administrator.' }
$selected = @($InstallTask, $UninstallTask, $Restore | Where-Object { $_ }).Count
if ($selected -gt 1) { throw '-InstallTask, -UninstallTask and -Restore are mutually exclusive.' }

if ($InstallTask) { $script:Settings = Get-Settings $ConfigPath; Initialize-Logging $script:Settings; Install-CleanupTask; exit 0 }
if ($UninstallTask) { Uninstall-CleanupTask; exit 0 }
if ($Restore) { $script:Settings = [pscustomobject]@{ ResolvedLogDirectory = (Join-Path $StateDirectory 'Logs') }; Initialize-Logging $script:Settings; Write-Log 'Restoring recorded service state.'; Restore-ServiceChanges; if ($script:FailedOperations -gt 0) { exit 1 }; exit 0 }

$script:Settings = Get-Settings $ConfigPath
Initialize-Logging $script:Settings
Write-Log 'Win-Cleaner started.'
try {
    if ($script:Settings.CleanTemp) { Clean-Temp }
    if ($script:Settings.CleanRecycleBin) { Clear-RecycleBinSafely }
    if ($script:Settings.CleanUpdateCaches) { Clean-UpdateCaches }
    if ($script:Settings.RemoveEdge) { Remove-EdgeSafely }
    Disable-ConfiguredServices
    Write-Log "Win-Cleaner finished with $script:FailedOperations failed operation(s)."
} catch { Add-Failure "Critical failure: $($_.Exception.Message)" 'ERROR' }
if ($script:FailedOperations -gt 0) { exit 1 }
exit 0
