# Win-Cleaner

A conservative PowerShell maintenance tool for Windows 10/11. It is designed to run from **Task Scheduler at system startup**, but it does not make destructive changes unless you explicitly enable them.

## What it does

- Cleans temporary files for the system and local user profiles.
- Empties the Recycle Bin when requested.
- Removes common Windows Update and Delivery Optimization caches when requested.
- Optionally removes Microsoft Edge using Microsoft's installed uninstaller (opt-in).
- Optionally disables only the services you explicitly list (opt-in).
- Optionally creates an advanced, disabled-by-default SYSTEM command prompt task.
- Writes a timestamped log and supports `-WhatIf` dry runs.

> **Important:** Removing Edge, disabling services, and providing a SYSTEM shell can break Windows features or compromise the machine if misused. The defaults are intentionally safe. Review `config.json`, test with `-WhatIf`, and create a restore point or backup before enabling destructive options.

## Quick start (Administrator PowerShell)

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Win-Cleaner.ps1 -WhatIf
.\Win-Cleaner.ps1 -InstallTask
```

`-InstallTask` creates an elevated task named `Win-Cleaner` that runs at boot and waits for Windows services to settle. The scheduled task invokes the script with the settings in `config.json`.

To run a cleanup manually:

```powershell
.\Win-Cleaner.ps1
```

To enable optional actions, edit `config.json`, validate with `-WhatIf`, then run the script as Administrator. For example:

```json
{
  "CleanTemp": true,
  "CleanRecycleBin": false,
  "CleanUpdateCaches": false,
  "RemoveEdge": false,
  "DisableServices": [],
  "OpenSystemCommandPrompt": false,
  "SystemCommandPromptDelaySeconds": 120
}
```

Use an explicit service list, for example `"DisableServices": ["DiagTrack"]`, only after checking what the service does in your environment. The script refuses to disable protected/core services and logs every requested change.

### SYSTEM command prompt

When `OpenSystemCommandPrompt` is `true`, installation also creates a separate task named `Win-Cleaner - SYSTEM Command Prompt`. It starts `cmd.exe /k` as `NT AUTHORITY\\SYSTEM` 120 seconds after startup (the delay is configurable). Because Windows isolates services and boot tasks from desktops, the prompt is configured as interactive and will appear only after an interactive user has logged on; it cannot be displayed on the secure logon screen. Close the prompt when finished. This feature is intentionally off by default.

## Removing the scheduled tasks

```powershell
.\Win-Cleaner.ps1 -UninstallTask
```

## Files

- `Win-Cleaner.ps1` — cleanup engine and Task Scheduler installer.
- `config.json` — safe defaults and explicit opt-in switches.

Run this repository only on Windows, from an elevated PowerShell session for system-wide cleanup.
