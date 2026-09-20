# Win-Cleaner

A conservative Windows maintenance tool intended for Windows 10/11 and advanced administrators.

## Security model

The cleaner deliberately does **not** create a persistent SYSTEM command prompt and does **not** remove Microsoft Edge. Those operations are outside the scope of routine cleanup and can create security, compatibility, and supportability problems.

The scheduled task runs only the cleanup operations selected in `config.json`. Install the repository under a protected directory such as `C:\Program Files\Win-Cleaner` and restrict write access to administrators. The installer protects the state and log directories for SYSTEM and local administrators.

## Supported operations

- Clean system and user temporary files.
- Optionally clean Windows Update and Delivery Optimization download caches.
- Optionally empty Recycle Bin (irreversible).
- Optionally disable an explicitly configured list of services.
- Record each service's previous startup mode and status in `C:\ProgramData\Win-Cleaner\state.json`.
- Restore recorded service settings with `-Restore`.
- Install or uninstall an elevated startup task.
- Use PowerShell's built-in `-WhatIf` and `-Confirm` support.

Service changes are reversible only when the state file remains available. Uninstalling the task does not restore system changes; run `-Restore` explicitly.

## Configuration

`config.json` contains a schema version and safe defaults:

```json
{
  "ConfigVersion": 1,
  "CleanTemp": true,
  "CleanRecycleBin": false,
  "CleanUpdateCaches": false,
  "DisableServices": [],
  "LogDirectory": "C:\\ProgramData\\Win-Cleaner\\Logs"
}
```

The service list is intentionally explicit. Do not add a service until you understand its role on the target machine.

## Usage (elevated PowerShell)

Run a dry run first:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Win-Cleaner.ps1 -WhatIf
```

Install the startup task using the selected configuration:

```powershell
.\Win-Cleaner.ps1 -InstallTask
```

The task stores the absolute script and configuration paths, runs as SYSTEM at startup, and is configured not to overlap with another run.

Run manually:

```powershell
.\Win-Cleaner.ps1
```

Remove only the scheduled task:

```powershell
.\Win-Cleaner.ps1 -UninstallTask
```

Restore service changes recorded by the cleaner:

```powershell
.\Win-Cleaner.ps1 -Restore
```

`-UninstallTask` and `-Restore` are separate by design. Cleanup of files, caches, and the Recycle Bin is not reversible by this tool.

## Operational notes

- Critical setup and state-management failures stop execution and return a non-zero exit code.
- Individual locked temp files are logged and skipped; one locked file does not abort the entire cleanup.
- Logs are written under the configured directory. Keep that directory administrator/SYSTEM-writable only.
- The script does not include Edge removal. If Edge must be removed, treat that as a separate, OS-version-specific change-management task and validate the signed Microsoft installer before use.
