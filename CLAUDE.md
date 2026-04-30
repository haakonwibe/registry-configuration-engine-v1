# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Registry Configuration Engine for Microsoft Intune - a PowerShell-based tool that manages Windows registry settings using declarative JSON configuration files. Designed for enterprise deployment through Intune Remediations.

## Commands

### Testing Locally
```powershell
# Validate configuration syntax
.\Invoke-RegistryConfigEngine.ps1 -ConfigPath ".\Configs\01-corporate-branding.json" -Mode Validate

# Check compliance (detection)
.\Invoke-RegistryConfigEngine.ps1 -ConfigPath ".\Configs\01-corporate-branding.json" -Mode Detect

# Preview changes without applying
.\Invoke-RegistryConfigEngine.ps1 -ConfigPath ".\Configs\01-corporate-branding.json" -Mode Remediate -WhatIf

# Apply changes
.\Invoke-RegistryConfigEngine.ps1 -ConfigPath ".\Configs\01-corporate-branding.json" -Mode Remediate

# Verbose output for debugging
.\Invoke-RegistryConfigEngine.ps1 -ConfigPath ".\Configs\01-corporate-branding.json" -Mode Detect -Verbose
```

### Packaging for Intune
```powershell
# Generate detection and remediation scripts (outputs to current directory by default)
.\New-IntunePackage.ps1 -ConfigPath ".\Configs\01-corporate-branding.json"

# Custom output location and prefix
.\New-IntunePackage.ps1 -ConfigPath ".\Configs\config.json" -OutputPath ".\Packages" -Prefix "CompanySettings"

# Inject $VerbosePreference = 'Continue' into the generated scripts
.\New-IntunePackage.ps1 -ConfigPath ".\Configs\config.json" -VerboseLogging
```

### Running tests
```powershell
# One-time setup
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck

# Run Pester
Invoke-Pester -Path .\tests

# Run analyzer
Invoke-ScriptAnalyzer -Path .\Invoke-RegistryConfigEngine.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
```

### Creating Configurations from Registry Exports
```powershell
# Export settings from a test machine
regedit /e "C:\temp\settings.reg" "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge"

# Convert .reg file to JSON configuration
.\ConvertFrom-RegistryExport.ps1 -Path ".\settings.reg"

# Custom output path
.\ConvertFrom-RegistryExport.ps1 -Path ".\settings.reg" -OutputPath ".\edge-config.json"

# Force all settings to a specific scope
.\ConvertFrom-RegistryExport.ps1 -Path ".\user-prefs.reg" -Scope User
```

## Architecture

### Core Scripts

**Invoke-RegistryConfigEngine.ps1**: Main engine with four modes:
- `Detect` - Check compliance, returns exit code 0 (compliant) or 1 (non-compliant)
- `Remediate` - Apply registry changes with transaction logging
- `Validate` - Parse and validate JSON without registry access
- `Rollback` - Restore previous values from transaction log

**New-IntunePackage.ps1**: Reads the sibling `Invoke-RegistryConfigEngine.ps1` and produces two self-contained scripts (`<Prefix>-Detect.ps1`, `<Prefix>-Remediate.ps1`) by replacing the engine's `INJECTION_POINT` region with the embedded config (here-string), `$script:__ForcedMode`, and `$script:__ForcedEventLog = $true`. The engine is the single source of truth — there is no separate template. Generated scripts pin to the engine version they were built against. `-VerboseLogging` injects `$VerbosePreference = 'Continue'` (standard PS mechanism, not a custom flag).

**ConvertFrom-RegistryExport.ps1**: Converts Windows Registry export (.reg) files to JSON configuration format. Supports all registry value types and automatically maps HKLM→Machine, HKCU→User scopes.

### Registry Scopes

| Scope | Target | Registry Location |
|-------|--------|-------------------|
| `Machine` | Machine-wide | HKLM:\ |
| `User` | All profiles in `HKLM\...\ProfileList` (S-1-5-21-* and S-1-12-1-* SIDs). Already-mounted hives are used as-is; signed-out profiles have their `NTUSER.DAT` `reg.exe load`ed into a temp key for the duration of the run. | HKU\<SID> (signed in) or HKU\RegEngineTemp_<PID>_<rand> (mounted by engine) |
| `DefaultUser` | New user template | C:\Users\Default\NTUSER.DAT (loaded temporarily) |

### JSON Configuration Structure

```json
{
  "version": "1.0",
  "settings": [
    {
      "scope": "Machine|User|DefaultUser",
      "path": "SOFTWARE\\Path\\To\\Key",
      "action": "Set|Delete|DeleteKey",
      "rebootRequired": false,
      "values": [
        { "name": "ValueName", "type": "String|DWord|...", "data": "value", "comparison": "Equals", "skipDetection": false }
      ]
    }
  ]
}
```

Setting options:
- `rebootRequired` (optional, default: false) - When true, shows a toast notification to the user after remediation indicating a reboot is needed.

Value options:
- `skipDetection` (optional, default: false) - When true, the value is written during remediation but not checked during detection. Useful for timestamp values like `{{DATETIME}}` that change on each run.
- `comparison` (optional, default: "Equals") - Comparison operator for detection. Remediation always sets the `data` value (except `NotExists` which deletes).
- `caseSensitive` (optional, default: false) - When true, string-typed comparisons (`Equals`, `NotEquals`, `Contains`, `StartsWith`, `EndsWith`) use ordinal case-sensitive matching. Applies to `String`, `ExpandString`, and `MultiString`.

### Comparison Operators

| Operator | Applicable Types | Description |
|----------|------------------|-------------|
| `Equals` | All | Exact match (default) |
| `NotEquals` | All | Value differs from specified |
| `GreaterThan` | DWord, QWord | Value > specified |
| `GreaterThanOrEqual` | DWord, QWord | Value >= specified |
| `LessThan` | DWord, QWord | Value < specified |
| `LessThanOrEqual` | DWord, QWord | Value <= specified |
| `Contains` | String | String contains substring |
| `StartsWith` | String | String starts with prefix |
| `EndsWith` | String | String ends with suffix |
| `Exists` | All | Value exists (any data) |
| `NotExists` | All | Value must not exist (remediation deletes) |

### Dynamic Variables

Variables expanded at runtime in string values: `{{DATE}}`, `{{DATETIME}}`, `{{COMPUTERNAME}}`, `{{USERNAME}}`, `{{DOMAIN}}`, `{{OSVERSION}}`, `{{ENGINEVERSION}}`

### Transaction Logging & Rollback

Changes are logged to `C:\ProgramData\RegistryConfigEngine\Transactions\Transaction_yyyyMMdd_HHmmss_fff_<PID>.json`. The millisecond+PID suffix prevents filename collisions when runs overlap (parallel CI, rapid iteration).

For `DeleteKey` actions, the engine writes a `.reg` export under `KeyBackups\` before deletion and records the path in the transaction (`BackupFile` plus `BackupKind` of `Machine`, `MountedUser`, or `TempMount`). Rollback for `Type=Key`:
- `Machine` → `reg.exe import` restores the key.
- `MountedUser` → import restores the key if the same user is mounted at rollback time (otherwise the import has no durable target).
- `TempMount` (DefaultUser, or a User profile the engine mounted itself) → not auto-restored. The backup file is retained for manual recovery.

**Note:** Rollback is designed for **local development and testing**, not production use. Use it to:
- Test configurations before deploying to Intune
- Quickly undo changes during development iteration
- Validate settings on a test machine

For **production rollback**, create a reverse configuration (using `Delete` action or setting values back to defaults) and deploy it as a new Intune remediation.

```powershell
# List transaction logs
Get-ChildItem "$env:ProgramData\RegistryConfigEngine\Transactions\*.json"

# Rollback a specific remediation (local testing only)
.\Invoke-RegistryConfigEngine.ps1 -ConfigPath "C:\ProgramData\...\Transaction_20260129_193834.json" -Mode Rollback
```

### Exit Codes (Intune)

- `0` - Compliant / Remediation successful
- `1` - Non-compliant / Remediation failed
- `2` - Validation error
- `3` - Configuration error

## Key Implementation Details

- User profiles enumerated from `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`, supporting both AD SIDs (S-1-5-21-*) and Entra ID SIDs (S-1-12-1-*). Already-mounted hives in HKU are used as-is; signed-out profiles have NTUSER.DAT loaded into a temp key (`HKU\RegEngineTemp_<PID>_<rand>`) and unloaded after iteration.
- DefaultUser and engine-mounted user hives use the same temp prefix and same `Mount-UserHive` / `Dismount-RegistryHive` helpers, with garbage collection before unload to release handles.
- At startup (Detect/Remediate modes), `Remove-OrphanedTempHives` scans HKU for `DefaultUserTemp_*` and `RegEngineTemp_*` keys whose owner PID is no longer running and unloads them. Mounts whose owner PID is still alive are left alone to avoid clobbering concurrent runs.
- URL configs are restricted to `https://`, downloaded with a 30-second timeout, zero redirects, and may be verified against an expected SHA-256 via the `-ConfigSha256` parameter (mismatch aborts the run).
- Binary values accept comma-separated hex (`"3C,00,00,00"`), continuous hex string with even length (`"3C000000"`), or array (`[60, 0, 0, 0]`). The parser branches on comma presence first, then falls through to hex-string handling.
- String / ExpandString / MultiString comparisons default to ordinal case-insensitive. Set `caseSensitive: true` on the value to switch to ordinal case-sensitive (uses `[string]::Equals(..., 'Ordinal')` and `String.Contains/StartsWith/EndsWith`).
- `Expand-ConfigVariables` walks arrays of strings (so MultiString elements get variable expansion) but leaves non-string arrays (binary as `byte[]`) untouched.
- Scripts designed to run as SYSTEM through Intune (no logged-on user dependency)
- All scripts require PowerShell 5.1+ (compatible with Intune Remediations which use Windows PowerShell)
- Packaged scripts auto-relaunch in 64-bit PowerShell if started in 32-bit (via `$env:SystemRoot\SysNative`)
- Logging is always on in packaged scripts: Windows Event Log (Application/RegistryConfigEngine) + file log with 30-day retention
- `NotExists` comparison: detection checks value is absent; remediation deletes the value (instead of trying to set it)
- All engine features — `skipDetection`, comparison operators, `caseSensitive`, ProfileList enumeration, URL hardening (irrelevant to packaged scripts since their config is embedded), `DeleteKey` reg-export backup — are automatically present in generated packages because the generator inlines the engine itself. There is no template drift to manage.
- The engine is dot-source-safe: a guard around the Main Execution block (`if ($MyInvocation.InvocationName -ne '.')`) lets Pester load the engine and test its functions without triggering execution. Tests live in `tests/Engine.Tests.ps1` and run on CI alongside PSScriptAnalyzer.
- Reboot toast (`Show-RebootToast`) registers a scheduled task running as the local Users group. Reliable for single-user laptops; on multi-session hosts (RDS, AVD pooled, Windows 365 multi-session) it runs for whichever Users-group member the scheduler picks — treat as best-effort there.
