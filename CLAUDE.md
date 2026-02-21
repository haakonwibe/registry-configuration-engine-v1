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

# Enable detailed per-value logging in generated scripts
.\New-IntunePackage.ps1 -ConfigPath ".\Configs\config.json" -VerboseLogging
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

**New-IntunePackage.ps1**: Packages JSON config into self-contained Intune scripts by embedding both the configuration and a minified engine. Generated scripts always log to Windows Event Log and file log (`C:\ProgramData\RegistryConfigEngine\Logs\RegistryConfigEngine.log` with 30-day retention). Use `-VerboseLogging` for per-value detail. Scripts auto-detect 32-bit PowerShell and relaunch via SysNative for 64-bit registry access.

**ConvertFrom-RegistryExport.ps1**: Converts Windows Registry export (.reg) files to JSON configuration format. Supports all registry value types and automatically maps HKLM→Machine, HKCU→User scopes.

### Registry Scopes

| Scope | Target | Registry Location |
|-------|--------|-------------------|
| `Machine` | Machine-wide | HKLM:\ |
| `User` | All existing users | HKU enumeration (S-1-5-21-* and S-1-12-1-* SIDs) |
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

Changes are logged to `C:\ProgramData\RegistryConfigEngine\Transactions\` for rollback capability.

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

- User profiles enumerated from HKU support both AD SIDs (S-1-5-21-*) and Entra ID SIDs (S-1-12-1-*)
- DefaultUser hive loaded via `reg.exe load` with garbage collection before unload to release handles
- Binary values accept comma-separated hex (`"3C,00,00,00"`), hex string (`"3C000000"`), or array (`[60, 0, 0, 0]`)
- Scripts designed to run as SYSTEM through Intune (no logged-on user dependency)
- All scripts require PowerShell 5.1+ (compatible with Intune Remediations which use Windows PowerShell)
- Packaged scripts auto-relaunch in 64-bit PowerShell if started in 32-bit (via `$env:SystemRoot\SysNative`)
- Logging is always on in packaged scripts: Windows Event Log (Application/RegistryConfigEngine) + file log with 30-day retention
- `NotExists` comparison: detection checks value is absent; remediation deletes the value (instead of trying to set it)
- `skipDetection` and all comparison operators are fully supported in the packaged template (not just the main engine)
