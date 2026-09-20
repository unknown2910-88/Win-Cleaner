# Win-Cleaner (Advanced Experimental Branch)

This branch intentionally re-enables advanced and potentially destructive options for experienced Windows administrators. These features are disabled by default and must be enabled deliberately in `config.json`.

## DANGEROUS FEATURE WARNING

The following are intentionally optional and off by default:

- SYSTEM command prompt launched as `NT AUTHORITY\SYSTEM` after boot delay
- Microsoft Edge uninstallation via the installed Edge setup executable
- Explicit service disabling via configuration

Only enable these if you know exactly what they do and you understand the impact on Windows, applications, and system recovery.

## Supported actions

- Clean temp files
- Clean Windows Update and Delivery Optimization cache
- Empty Recycle Bin
- Disable explicitly listed services
- Record service state and restore it later
- Install an advanced startup task
- Optionally start an interactive `cmd.exe` under `NT AUTHORITY\SYSTEM` after a configurable delay
- Optionally uninstall Microsoft Edge using the official Edge setup executable

## Default configuration

```json
{
  "ConfigVersion": 1,
  "CleanTemp": true,
  "CleanRecycleBin": false,
  "CleanUpdateCaches": false,
  "RemoveEdge": false,
  "OpenSystemCommandPrompt": false,
  "SystemCommandPromptDelaySeconds": 120,
  "DisableServices": [],
  "LogDirectory": "C:\\ProgramData\\Win-Cleaner\\Logs"
}
```

To enable the dangerous options, set the following values:

```json
"RemoveEdge": true,
"OpenSystemCommandPrompt": true,
"SystemCommandPromptDelaySeconds": 120,
"DisableServices": ["DiagTrack"]
```

## Usage (administrator PowerShell)

Dry run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Win-Cleaner.ps1 -WhatIf
```

Install startup task:

```powershell
.\Win-Cleaner.ps1 -InstallTask
```

Run manually:

```powershell
.\Win-Cleaner.ps1
```

Restore previously recorded service state:

```powershell
.\Win-Cleaner.ps1 -Restore
```

Remove the task:

```powershell
.\Win-Cleaner.ps1 -UninstallTask
```

## Very important warnings

- `OpenSystemCommandPrompt` creates a scheduled task that launches `cmd.exe` as `SYSTEM` after boot.
- This exposes an elevated interactive shell and is not a safe default.
- `RemoveEdge` is not a temp-cleanup action. It is a destructive application removal decision.
- `DisableServices` can break updates, services, or dependent apps.
- This branch is for advanced users who accept the risk and are responsible for testing and rollback.
- Use `-WhatIf` before enabling destructive options.

This branch is intentionally experimental and should not be treated as a routine consumer utility.
