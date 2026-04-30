<#
.SYNOPSIS
    Registry Configuration Engine for Microsoft Intune
    A flexible, enterprise-ready solution for managing Windows registry settings.

.DESCRIPTION
    This script provides a declarative approach to registry management using JSON configuration files.
    It supports both machine (HKLM) and user (HKCU) registry scopes, including the Default User profile
    for new user provisioning.

    Key Features:
    - JSON-based configuration (version-controllable, auditable)
    - Transaction logging with rollback capability
    - Default User profile support (applies to new users)
    - Built-in validation/WhatIf mode
    - Windows Event Log integration
    - Supports all registry value types
    - Works as Intune Remediation, Platform Script, or standalone

.PARAMETER ConfigPath
    Path to the JSON configuration file. Can be a local path, UNC path, or URL.
    If not specified, looks for 'config.json' in the script directory.

.PARAMETER Mode
    Execution mode:
    - Detect    : Check compliance without making changes (default for Intune detection)
    - Remediate : Apply configuration changes (default for Intune remediation)
    - Validate  : Parse and validate configuration without any registry access
    - Rollback  : Restore previous values from transaction log

.PARAMETER TransactionLogPath
    Path where transaction logs are stored for rollback capability.
    Default: C:\ProgramData\RegistryConfigEngine\Transactions

.PARAMETER CreateEventLog
    If specified, creates entries in Windows Event Log (Application log, source: RegistryConfigEngine)

.PARAMETER WhatIf
    Shows what changes would be made without actually applying them.

.PARAMETER Verbose
    Provides detailed output during execution.

.EXAMPLE
    .\Invoke-RegistryConfigEngine.ps1 -ConfigPath ".\corporate-settings.json" -Mode Detect
    Checks if the device is compliant with the configuration.

.EXAMPLE
    .\Invoke-RegistryConfigEngine.ps1 -ConfigPath ".\corporate-settings.json" -Mode Remediate
    Applies the configuration to the device.

.EXAMPLE
    .\Invoke-RegistryConfigEngine.ps1 -Mode Rollback -TransactionLogPath "C:\Logs\registry-backup.json"
    Rolls back changes from a previous remediation.

.NOTES
    Author:         Haakon Wibe
    Blog:           https://alttabtowork.com
    Version:        1.1.0
    Creation Date:  2026-01-28
    
    Inspired by the community's work on registry management, particularly Martin Bengtsson's
    approach at imab.dk. This implementation takes a different architectural approach using
    external JSON configuration for better maintainability and enterprise deployment.

.LINK
    https://alttabtowork.com
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [string]$ConfigPath,

    [Parameter(Position = 1)]
    [ValidateSet('Detect', 'Remediate', 'Validate', 'Rollback')]
    [string]$Mode = 'Detect',

    [Parameter()]
    [string]$TransactionLogPath = "$env:ProgramData\RegistryConfigEngine\Transactions",

    [Parameter()]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ConfigSha256,

    [Parameter()]
    [switch]$CreateEventLog
)

#region INJECTION_POINT
# Replaced by New-IntunePackage.ps1 during generation. Leave as-is for standalone use.
$script:__EmbeddedConfig = $null
$script:__ForcedMode     = $null
$script:__ForcedEventLog = $false
#endregion

#region Script Configuration
$script:EngineVersion = "1.1.0"
$script:EventLogSource = "RegistryConfigEngine"
$script:EventLogName = "Application"
$script:LogPrefix = "[REGENGINE]"
# Identifier of the active configuration. Populated in Main after config load
# from the file/URL filename or the embedded config description. Used by
# Write-Log to tag every emitted line so concurrent deployments are
# distinguishable in Event Viewer (which has one shared source).
$script:ConfigIdentifier = "unknown"
# File log destination. Always-on, non-elevated runs may fail to write — that's
# logged as Verbose and otherwise ignored. Hardcoded; matches existing docs and
# the old packaged-template behavior.
$script:LogFilePath = "$env:ProgramData\RegistryConfigEngine\Logs\RegistryConfigEngine.log"

# Prefix for temp-mounted hives. Encodes our PID so concurrent runs don't unload
# each other's mounts during orphan cleanup.
$script:TempHivePrefix = "RegEngineTemp_${PID}_"

# Exit codes for Intune Remediations
$script:ExitCodes = @{
    Compliant       = 0
    NonCompliant    = 1
    RemediationOK   = 0
    RemediationFail = 1
    ValidationError = 2
    ConfigError     = 3
}
#endregion

#region Helper Functions

function Write-Log {
    <#
    .SYNOPSIS
        Writes formatted log output and optionally to Event Log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Debug')]
        [string]$Level = 'Info',
        
        [int]$EventId = 1000
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix = switch ($Level) {
        'Info'    { "[INFO]" }
        'Warning' { "[WARN]" }
        'Error'   { "[ERROR]" }
        'Success' { "[OK]" }
        'Debug'   { "[DEBUG]" }
    }

    # Tag every emission with the active config identifier so concurrent
    # deployments are distinguishable in Event Viewer (which uses a single
    # shared source). Done on a local copy so the $Message parameter is untouched.
    $taggedMessage = "[$script:ConfigIdentifier] $Message"
    $logMessage = "$timestamp $script:LogPrefix $prefix $taggedMessage"

    switch ($Level) {
        'Error'   { Write-Error $logMessage }
        'Warning' { Write-Warning $logMessage }
        'Debug'   { Write-Verbose $logMessage }
        default   { Write-Output $logMessage }
    }

    # Always-on file log. ISO-8601 UTC timestamp + level + LogPrefix + tagged message.
    # Failures are non-fatal: a Verbose line is emitted and execution continues.
    try {
        $logDir = Split-Path -Parent $script:LogFilePath
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $utcStamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        $fileLine = "$utcStamp $prefix $script:LogPrefix $taggedMessage"
        Add-Content -Path $script:LogFilePath -Value $fileLine -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Verbose "File log write failed: $_"
    }

    # Write to Event Log if requested and running elevated
    if ($CreateEventLog -and ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        try {
            # Ensure event source exists
            if (-not [System.Diagnostics.EventLog]::SourceExists($script:EventLogSource)) {
                New-EventLog -LogName $script:EventLogName -Source $script:EventLogSource -ErrorAction SilentlyContinue
            }

            $entryType = switch ($Level) {
                'Error'   { 'Error' }
                'Warning' { 'Warning' }
                default   { 'Information' }
            }

            Write-EventLog -LogName $script:EventLogName -Source $script:EventLogSource `
                -EventId $EventId -EntryType $entryType -Message $taggedMessage
        }
        catch {
            Write-Verbose "Could not write to Event Log: $_"
        }
    }
}

function Show-RebootToast {
    <#
    .SYNOPSIS
        Shows a Windows toast notification to inform the user that a reboot is required.
    .DESCRIPTION
        Creates a scheduled task that runs as the logged-on user to display a toast notification.
        This approach works reliably from SYSTEM context (Intune Remediations).
    #>
    [CmdletBinding()]
    param(
        [string]$Title = "System Configuration Updated",
        [string]$Message = "Configuration changes have been applied that require a restart. Please restart your computer at your earliest convenience."
    )

    try {
        # Check if there's a logged-on user with an interactive session
        $explorerProcess = Get-Process -Name explorer -ErrorAction SilentlyContinue
        if (-not $explorerProcess) {
            Write-Log "No interactive user session detected - skipping toast notification" -Level Debug
            return $false
        }

        # PowerShell script to show toast (runs in Windows PowerShell 5.1 for WinRT compatibility)
        # Uses Windows.SystemToast.SecurityAndMaintenance as AppId for professional appearance
        $toastScript = @"
`$ErrorActionPreference = 'Stop'
try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    `$toastXml = @'
<toast duration="long">
    <visual>
        <binding template="ToastGeneric">
            <text>$Title</text>
            <text>$Message</text>
        </binding>
    </visual>
    <audio src="ms-winsoundevent:Notification.Default"/>
</toast>
'@

    `$xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
    `$xmlDoc.LoadXml(`$toastXml)
    `$toast = New-Object Windows.UI.Notifications.ToastNotification(`$xmlDoc)
    `$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Windows.SystemToast.SecurityAndMaintenance')
    `$notifier.Show(`$toast)
}
catch {
    exit 1
}
"@

        # Create a unique task name
        $taskName = "RegistryConfigEngine_RebootToast_$(Get-Random)"

        # Encode the script for the scheduled task
        $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($toastScript))

        # Use conhost.exe --headless to run PowerShell completely hidden (Windows 10 1809+)
        $action = New-ScheduledTaskAction -Execute "conhost.exe" -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $encodedScript"

        # Create principal to run as the logged-on user in interactive context
        $principal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited  # Users group

        # Create task settings
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

        # Register and run the task
        $null = Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force
        Start-ScheduledTask -TaskName $taskName

        # Wait briefly for task to execute, then clean up
        Start-Sleep -Milliseconds 1000
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        Write-Log "Reboot notification displayed to user" -Level Info
        return $true
    }
    catch {
        Write-Log "Could not display toast notification: $_" -Level Debug
        return $false
    }
}

function Mount-UserHive {
    <#
    .SYNOPSIS
        Loads a user's NTUSER.DAT into HKU under a temporary key.
    .DESCRIPTION
        Used for both signed-out user profiles and the Default User template.
        Returns $null if the file is missing or the load fails (e.g., locked).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileImagePath,

        [Parameter()]
        [string]$Username = "Unknown"
    )

    $ntuserPath = Join-Path $ProfileImagePath 'NTUSER.DAT'
    # Some profile paths (other users') deny read access from non-SYSTEM contexts —
    # treat both "missing" and "access denied" as "skip this profile".
    $ntuserExists = $false
    try {
        $ntuserExists = Test-Path -LiteralPath $ntuserPath -ErrorAction Stop
    }
    catch {
        Write-Log "Cannot access $ntuserPath ($Username): $_" -Level Debug
        return $null
    }
    if (-not $ntuserExists) {
        Write-Log "NTUSER.DAT not found at: $ntuserPath" -Level Debug
        return $null
    }

    $rand = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $tempKey = "HKU\$($script:TempHivePrefix)$rand"

    try {
        $regLoad = & reg.exe load $tempKey $ntuserPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            # Most common cause: NTUSER.DAT is locked because the user is signed in
            # but their hive isn't visible in HKU yet (rare timing window), or another
            # process holds it open.
            Write-Log "Could not load hive for ${Username}: $regLoad" -Level Debug
            return $null
        }
        Write-Log "Mounted hive ($Username) at: $tempKey" -Level Debug
        return [PSCustomObject]@{
            HivePath    = "Registry::$tempKey"
            TempKey     = $tempKey
            NeedsUnload = $true
        }
    }
    catch {
        Write-Log "Exception mounting hive ($Username): $_" -Level Debug
        return $null
    }
}

function Get-UserProfileSIDs {
    <#
    .SYNOPSIS
        Returns all user profiles known to Windows, mounting NTUSER.DAT for any
        whose hive is not currently loaded in HKU.
    .DESCRIPTION
        Enumerates HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList
        rather than HKU directly, so signed-out users are included. For each
        profile:
          - If the SID is already mounted in HKU (signed in), use that path with
            HiveInfo=$null so callers do not unload it.
          - Otherwise, attempt reg.exe load of NTUSER.DAT into a temp key. The
            caller is responsible for unloading via Dismount-RegistryHive.
        Supports both AD (S-1-5-21-*) and Entra ID (S-1-12-1-*) SIDs.
    #>
    [CmdletBinding()]
    param()

    $userSIDs = @()

    try {
        # Snapshot SIDs currently mounted in HKU (signed-in users + anything else
        # that already holds the hive open). We must not try to reg.exe load these.
        $loadedSIDs = @{}
        Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^(S-1-5-21-|S-1-12-1-)' -and $_.PSChildName -notmatch '_Classes$' } |
            ForEach-Object { $loadedSIDs[$_.PSChildName] = $true }

        # Enumerate every profile registered with Windows
        $profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
        $profileKeys = Get-ChildItem -Path $profileListPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^(S-1-5-21-|S-1-12-1-)' }

        foreach ($profileKey in $profileKeys) {
            $sid = $profileKey.PSChildName
            $profileImagePath = (Get-ItemProperty -Path $profileKey.PSPath -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath
            if (-not $profileImagePath) { continue }

            try {
                $objSID = New-Object System.Security.Principal.SecurityIdentifier($sid)
                $username = $objSID.Translate([System.Security.Principal.NTAccount]).Value
            }
            catch {
                $username = $sid
            }

            if ($loadedSIDs.ContainsKey($sid)) {
                $userSIDs += [PSCustomObject]@{
                    SID      = $sid
                    Username = $username
                    HivePath = "Registry::HKEY_USERS\$sid"
                    HiveInfo = $null
                }
            }
            else {
                $hive = Mount-UserHive -ProfileImagePath $profileImagePath -Username $username
                if (-not $hive) {
                    Write-Log "Skipped profile $username ($sid): hive could not be mounted" -Level Debug
                    continue
                }
                $userSIDs += [PSCustomObject]@{
                    SID      = $sid
                    Username = $username
                    HivePath = $hive.HivePath
                    HiveInfo = $hive
                }
            }
        }

        Write-Log "Found $($userSIDs.Count) user profile(s) (loaded + on-disk via ProfileList)" -Level Debug
    }
    catch {
        Write-Log "Error enumerating user SIDs: $_" -Level Error
    }

    return $userSIDs
}

function Get-DefaultUserHive {
    <#
    .SYNOPSIS
        Loads the Default User's NTUSER.DAT for applying settings to new user profiles.
    #>
    [CmdletBinding()]
    param()

    $defaultUserDir = "$env:SystemDrive\Users\Default"
    $hive = Mount-UserHive -ProfileImagePath $defaultUserDir -Username 'Default User'
    if (-not $hive) {
        Write-Log "Default user hive not available at: $defaultUserDir" -Level Warning
    }
    return $hive
}

function Dismount-RegistryHive {
    <#
    .SYNOPSIS
        Dismounts a previously loaded user/default hive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TempKey
    )

    try {
        # Force garbage collection to release any handles into the hive
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 500

        $regUnload = & reg.exe unload $TempKey 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Warning: Could not dismount hive (may still be in use): $regUnload" -Level Warning
        }
        else {
            Write-Log "Dismounted hive: $TempKey" -Level Debug
        }
    }
    catch {
        Write-Log "Exception dismounting hive: $_" -Level Warning
    }
}

function Remove-OrphanedTempHives {
    <#
    .SYNOPSIS
        Unloads any temp hives left behind by previous (crashed) runs.
    .DESCRIPTION
        Scans HKU for keys matching the engine's temp-hive prefix (current and
        legacy). Keys belonging to the current PID are skipped. Keys whose
        encoded PID is still alive are left alone (concurrent run). Anything
        else is attempted; reg.exe unload naturally refuses if a hive is in use,
        so attempt-and-ignore is safe.
    #>
    [CmdletBinding()]
    param()

    try {
        $hkuKeys = Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^(DefaultUserTemp_|RegEngineTemp_)' }

        foreach ($key in $hkuKeys) {
            $name = $key.PSChildName

            # Never touch our own active mounts
            if ($name -like "$($script:TempHivePrefix)*") { continue }

            # Respect concurrent runs of this engine
            if ($name -match '^RegEngineTemp_(\d+)_') {
                $ownerPid = [int]$Matches[1]
                if (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue) {
                    Write-Log "Skipping HKU\$name (owner PID $ownerPid still running)" -Level Debug
                    continue
                }
            }

            $null = & reg.exe unload "HKU\$name" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Cleaned up orphan hive: HKU\$name" -Level Info
            }
            else {
                Write-Log "Could not unload orphan HKU\$name (likely in use)" -Level Debug
            }
        }
    }
    catch {
        Write-Log "Orphan hive cleanup error: $_" -Level Debug
    }
}

function Convert-RegistryValue {
    <#
    .SYNOPSIS
        Converts configuration values to the appropriate registry format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Type,
        
        [Parameter()]
        $Value
    )
    
    switch ($Type.ToLower()) {
        'string' {
            return [string]$Value
        }
        'expandstring' {
            return [string]$Value
        }
        'dword' {
            return [int]$Value
        }
        'qword' {
            return [long]$Value
        }
        'binary' {
            # Accept comma-separated hex values, hex string, or array
            if ($Value -is [array]) {
                return [byte[]]$Value
            }
            $stringValue = [string]$Value
            if ($stringValue.Contains(',')) {
                # Comma-separated hex bytes (with optional whitespace)
                if ($stringValue -notmatch '^[0-9A-Fa-f,\s]+$') {
                    throw "Invalid binary value format (comma-separated hex expected): $Value"
                }
                $cleanValue = $stringValue -replace '\s+', ',' -replace ',+', ','
                return [byte[]]($cleanValue -split ',' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_.Trim(), 16) })
            }
            elseif ($stringValue -match '^(0x)?[0-9A-Fa-f]+$') {
                # Single hex string
                $hexString = $stringValue -replace '^0x', ''
                if ($hexString.Length % 2 -ne 0) {
                    throw "Invalid binary hex string (must have even length): $Value"
                }
                $bytes = for ($i = 0; $i -lt $hexString.Length; $i += 2) {
                    [Convert]::ToByte($hexString.Substring($i, 2), 16)
                }
                return [byte[]]$bytes
            }
            else {
                throw "Invalid binary value format: $Value"
            }
        }
        'multistring' {
            # Comma operator wraps the array so the pipeline doesn't enumerate it
            # away — preserves the [string[]] type for the caller.
            if ($Value -is [array]) {
                return ,[string[]]$Value
            }
            else {
                return ,[string[]]@($Value)
            }
        }
        default {
            throw "Unsupported registry type: $Type"
        }
    }
}

function Get-RegistryTypeKind {
    <#
    .SYNOPSIS
        Maps friendly type names to Microsoft.Win32.RegistryValueKind enum.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Type
    )
    
    switch ($Type.ToLower()) {
        'string'       { return [Microsoft.Win32.RegistryValueKind]::String }
        'expandstring' { return [Microsoft.Win32.RegistryValueKind]::ExpandString }
        'dword'        { return [Microsoft.Win32.RegistryValueKind]::DWord }
        'qword'        { return [Microsoft.Win32.RegistryValueKind]::QWord }
        'binary'       { return [Microsoft.Win32.RegistryValueKind]::Binary }
        'multistring'  { return [Microsoft.Win32.RegistryValueKind]::MultiString }
        default        { throw "Unsupported registry type: $Type" }
    }
}

function Expand-ConfigVariables {
    <#
    .SYNOPSIS
        Expands dynamic variables in configuration values.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        $Value
    )
    
    if ($Value -is [string]) {
        $expanded = $Value

        # Built-in variables
        $variables = @{
            '{{DATE}}'         = (Get-Date -Format "yyyy-MM-dd")
            '{{DATETIME}}'     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            '{{COMPUTERNAME}}' = $env:COMPUTERNAME
            '{{USERNAME}}'     = $env:USERNAME
            '{{DOMAIN}}'       = $env:USERDOMAIN
            '{{OSVERSION}}'    = [System.Environment]::OSVersion.Version.ToString()
            '{{ENGINEVERSION}}' = $script:EngineVersion
        }

        foreach ($var in $variables.Keys) {
            $expanded = $expanded -replace [regex]::Escape($var), $variables[$var]
        }

        return $expanded
    }

    # Walk arrays of strings (multistring). Leave non-string arrays (binary as
    # byte[]) alone since variable expansion makes no sense for byte values.
    # Comma operator preserves the array type through the pipeline.
    if ($Value -is [array]) {
        $allStrings = $true
        foreach ($item in $Value) {
            if ($item -isnot [string]) { $allStrings = $false; break }
        }
        if ($allStrings) {
            $expanded = foreach ($item in $Value) { Expand-ConfigVariables -Value $item }
            return ,[string[]]$expanded
        }
        return ,$Value
    }

    return $Value
}

function Compare-RegistryValue {
    <#
    .SYNOPSIS
        Compares a registry value against the expected configuration using the specified comparison operator.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string]$Type,

        [Parameter()]
        $ExpectedValue,

        [Parameter()]
        [ValidateSet('Equals', 'NotEquals', 'GreaterThan', 'GreaterThanOrEqual', 'LessThan', 'LessThanOrEqual', 'Contains', 'StartsWith', 'EndsWith', 'Exists', 'NotExists')]
        [string]$Comparison = 'Equals',

        [Parameter()]
        [bool]$CaseSensitive = $false
    )

    try {
        $keyExists = Test-Path $Path
        $valueExists = $false
        $actualValue = $null

        if ($keyExists) {
            $currentValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
            $valueExists = $null -ne $currentValue -and ($currentValue.PSObject.Properties.Name -contains $Name)
            if ($valueExists) {
                $actualValue = $currentValue.$Name
            }
        }

        # Handle Exists/NotExists comparisons first
        if ($Comparison -eq 'Exists') {
            return @{
                Match   = $valueExists
                Current = $actualValue
                Reason  = if ($valueExists) { "Value exists" } else { "Value does not exist" }
            }
        }

        if ($Comparison -eq 'NotExists') {
            return @{
                Match   = -not $valueExists
                Current = $actualValue
                Reason  = if (-not $valueExists) { "Value does not exist (as expected)" } else { "Value exists (should not)" }
            }
        }

        # For all other comparisons, value must exist
        if (-not $keyExists) {
            return @{
                Match   = $false
                Current = $null
                Reason  = "Key does not exist"
            }
        }

        if (-not $valueExists) {
            return @{
                Match   = $false
                Current = $null
                Reason  = "Value does not exist"
            }
        }

        $convertedExpected = Convert-RegistryValue -Type $Type -Value $ExpectedValue

        # Perform comparison based on operator
        $match = $false
        $reason = ""

        # Helper for string equality honoring CaseSensitive
        $stringsEqual = {
            param($a, $b)
            if ($CaseSensitive) {
                [string]::Equals([string]$a, [string]$b, [System.StringComparison]::Ordinal)
            }
            else {
                [string]::Equals([string]$a, [string]$b, [System.StringComparison]::OrdinalIgnoreCase)
            }
        }

        switch ($Comparison) {
            'Equals' {
                # Handle binary comparison (always byte-exact)
                if ($Type.ToLower() -eq 'binary') {
                    $match = $null -ne $actualValue -and
                             $actualValue.Length -eq $convertedExpected.Length -and
                             -not (Compare-Object $actualValue $convertedExpected)
                }
                # Handle multi-string comparison (per-element equality, honoring CaseSensitive)
                elseif ($Type.ToLower() -eq 'multistring') {
                    if ($null -eq $actualValue -or $actualValue.Length -ne $convertedExpected.Length) {
                        $match = $false
                    }
                    else {
                        $match = $true
                        for ($i = 0; $i -lt $actualValue.Length; $i++) {
                            if (-not (& $stringsEqual $actualValue[$i] $convertedExpected[$i])) {
                                $match = $false; break
                            }
                        }
                    }
                }
                # String/ExpandString
                elseif ($Type.ToLower() -in 'string', 'expandstring') {
                    $match = & $stringsEqual $actualValue $convertedExpected
                }
                else {
                    $match = $actualValue -eq $convertedExpected
                }
                $reason = if ($match) { "Values match" } else { "Values differ" }
            }
            'NotEquals' {
                if ($Type.ToLower() -eq 'binary') {
                    $match = $null -eq $actualValue -or
                             $actualValue.Length -ne $convertedExpected.Length -or
                             (Compare-Object $actualValue $convertedExpected)
                }
                elseif ($Type.ToLower() -eq 'multistring') {
                    if ($null -eq $actualValue -or $actualValue.Length -ne $convertedExpected.Length) {
                        $match = $true
                    }
                    else {
                        $match = $false
                        for ($i = 0; $i -lt $actualValue.Length; $i++) {
                            if (-not (& $stringsEqual $actualValue[$i] $convertedExpected[$i])) {
                                $match = $true; break
                            }
                        }
                    }
                }
                elseif ($Type.ToLower() -in 'string', 'expandstring') {
                    $match = -not (& $stringsEqual $actualValue $convertedExpected)
                }
                else {
                    $match = $actualValue -ne $convertedExpected
                }
                $reason = if ($match) { "Values differ (as expected)" } else { "Values match (should differ)" }
            }
            'GreaterThan' {
                $match = $actualValue -gt $convertedExpected
                $reason = if ($match) { "Value $actualValue > $convertedExpected" } else { "Value $actualValue is not > $convertedExpected" }
            }
            'GreaterThanOrEqual' {
                $match = $actualValue -ge $convertedExpected
                $reason = if ($match) { "Value $actualValue >= $convertedExpected" } else { "Value $actualValue is not >= $convertedExpected" }
            }
            'LessThan' {
                $match = $actualValue -lt $convertedExpected
                $reason = if ($match) { "Value $actualValue < $convertedExpected" } else { "Value $actualValue is not < $convertedExpected" }
            }
            'LessThanOrEqual' {
                $match = $actualValue -le $convertedExpected
                $reason = if ($match) { "Value $actualValue <= $convertedExpected" } else { "Value $actualValue is not <= $convertedExpected" }
            }
            'Contains' {
                if ($CaseSensitive) {
                    $match = ([string]$actualValue).Contains([string]$convertedExpected)
                } else {
                    $match = $actualValue -like "*$convertedExpected*"
                }
                $reason = if ($match) { "Value contains '$convertedExpected'" } else { "Value does not contain '$convertedExpected'" }
            }
            'StartsWith' {
                if ($CaseSensitive) {
                    $match = ([string]$actualValue).StartsWith([string]$convertedExpected, [System.StringComparison]::Ordinal)
                } else {
                    $match = $actualValue -like "$convertedExpected*"
                }
                $reason = if ($match) { "Value starts with '$convertedExpected'" } else { "Value does not start with '$convertedExpected'" }
            }
            'EndsWith' {
                if ($CaseSensitive) {
                    $match = ([string]$actualValue).EndsWith([string]$convertedExpected, [System.StringComparison]::Ordinal)
                } else {
                    $match = $actualValue -like "*$convertedExpected"
                }
                $reason = if ($match) { "Value ends with '$convertedExpected'" } else { "Value does not end with '$convertedExpected'" }
            }
        }

        return @{
            Match   = $match
            Current = $actualValue
            Reason  = $reason
        }
    }
    catch {
        return @{
            Match   = $false
            Current = $null
            Reason  = "Error comparing: $_"
        }
    }
}

function ConvertTo-RegToolPath {
    <#
    .SYNOPSIS
        Converts PowerShell registry paths to reg.exe path syntax.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ($Path -match '^Registry::HKEY_USERS\\(.+)$')         { return "HKU\$($Matches[1])" }
    if ($Path -match '^Registry::HKEY_LOCAL_MACHINE\\(.+)$') { return "HKLM\$($Matches[1])" }
    if ($Path -match '^Registry::HKEY_CURRENT_USER\\(.+)$')  { return "HKCU\$($Matches[1])" }
    if ($Path -match '^Registry::HKEY_CLASSES_ROOT\\(.+)$')  { return "HKCR\$($Matches[1])" }
    if ($Path -match '^HKLM:\\(.+)$')                         { return "HKLM\$($Matches[1])" }
    if ($Path -match '^HKCU:\\(.+)$')                         { return "HKCU\$($Matches[1])" }
    if ($Path -match '^HKU:\\(.+)$')                          { return "HKU\$($Matches[1])" }
    if ($Path -match '^HKCR:\\(.+)$')                         { return "HKCR\$($Matches[1])" }
    return $Path
}

function Backup-RegistryKey {
    <#
    .SYNOPSIS
        Exports a registry key (recursively) to a .reg file for potential rollback.
    .DESCRIPTION
        Used before action=DeleteKey. Returns the absolute path of the .reg file,
        or $null on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BackupRoot
    )

    try {
        if (-not (Test-Path $BackupRoot)) {
            New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null
        }

        $regPath = ConvertTo-RegToolPath -Path $Path
        $rand = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
        $backupFile = Join-Path $BackupRoot "KeyBackup_${stamp}_${PID}_$rand.reg"

        $regOutput = & reg.exe export $regPath $backupFile /y 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Failed to export key for backup: $regOutput" -Level Warning
            return $null
        }
        Write-Log "Backed up key to: $backupFile" -Level Debug
        return $backupFile
    }
    catch {
        Write-Log "Exception backing up key: $_" -Level Warning
        return $null
    }
}

function Backup-RegistryValue {
    <#
    .SYNOPSIS
        Creates a backup of a registry value before modification.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter(Mandatory)]
        [string]$Name
    )
    
    $backup = @{
        Path      = $Path
        Name      = $Name
        Timestamp = (Get-Date).ToString("o")
        Existed   = $false
        Value     = $null
        Type      = $null
    }
    
    try {
        if (Test-Path $Path) {
            $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
            if ($null -ne $item -and ($item.PSObject.Properties.Name -contains $Name)) {
                $backup.Existed = $true
                $backup.Value = $item.$Name
                
                # Get the type
                $key = Get-Item -Path $Path
                $backup.Type = $key.GetValueKind($Name).ToString()
            }
        }
    }
    catch {
        Write-Log "Could not backup value at $Path\$Name : $_" -Level Warning
    }
    
    return $backup
}

function Save-TransactionLog {
    <#
    .SYNOPSIS
        Saves the transaction log for potential rollback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Transactions,
        
        [Parameter(Mandatory)]
        [string]$LogPath
    )
    
    try {
        if (-not (Test-Path $LogPath)) {
            New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
        }
        
        $logFile = Join-Path $LogPath "Transaction_$(Get-Date -Format 'yyyyMMdd_HHmmss_fff')_$PID.json"
        
        $logData = @{
            EngineVersion    = $script:EngineVersion
            ConfigIdentifier = $script:ConfigIdentifier
            ComputerName     = $env:COMPUTERNAME
            Timestamp        = (Get-Date).ToString("o")
            Transactions     = $Transactions
        }
        
        $logData | ConvertTo-Json -Depth 10 | Out-File -FilePath $logFile -Encoding UTF8
        
        Write-Log "Transaction log saved: $logFile" -Level Info
        return $logFile
    }
    catch {
        Write-Log "Failed to save transaction log: $_" -Level Error
        return $null
    }
}

#endregion

#region Configuration Loading

function Get-Configuration {
    <#
    .SYNOPSIS
        Loads and validates the JSON configuration.
    .PARAMETER Path
        Path to the config file (local, UNC, or https URL). Ignored when EmbeddedJson is supplied.
    .PARAMETER Sha256
        Optional SHA-256 hex digest for integrity verification of file/URL content.
        Not applicable when EmbeddedJson is used (the embedded JSON is part of the
        signed/distributed script body itself).
    .PARAMETER EmbeddedJson
        Pre-loaded JSON content (string). When supplied, file/URL loading is skipped.
        Used by packaged Intune scripts via the INJECTION_POINT mechanism.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path,

        [Parameter()]
        [string]$Sha256,

        [Parameter()]
        [string]$EmbeddedJson
    )

    try {
        # Step 1: Acquire raw JSON content
        if ($EmbeddedJson) {
            Write-Log "Loading embedded configuration..." -Level Info
            $configContent = $EmbeddedJson
        }
        elseif ([string]::IsNullOrEmpty($Path)) {
            throw "Configuration source is required: provide -Path or -EmbeddedJson."
        }
        elseif ($Path -match '^http://') {
            throw "HTTP URLs are not supported. Configuration must be loaded over HTTPS."
        }
        elseif ($Path -match '^https://') {
            Write-Log "Loading configuration from: $Path" -Level Info
            Write-Log "Downloading configuration from URL..." -Level Debug
            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                Invoke-WebRequest -Uri $Path -UseBasicParsing -OutFile $tempFile `
                    -TimeoutSec 30 -MaximumRedirection 0 -ErrorAction Stop

                if ($Sha256) {
                    $actualHash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash
                    if (-not [string]::Equals($actualHash, $Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                        throw "SHA-256 mismatch for downloaded configuration. Expected: $Sha256 Actual: $actualHash"
                    }
                    Write-Log "SHA-256 verified for downloaded configuration" -Level Debug
                }

                $configContent = Get-Content -Path $tempFile -Raw -Encoding UTF8
            }
            finally {
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
        elseif (Test-Path $Path) {
            Write-Log "Loading configuration from: $Path" -Level Info
            if ($Sha256) {
                $actualHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
                if (-not [string]::Equals($actualHash, $Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "SHA-256 mismatch for configuration file. Expected: $Sha256 Actual: $actualHash"
                }
                Write-Log "SHA-256 verified for configuration file" -Level Debug
            }
            $configContent = Get-Content -Path $Path -Raw -Encoding UTF8
        }
        else {
            throw "Configuration file not found: $Path"
        }

        # Step 2: Parse + validate (shared between embedded and file paths)
        $config = $configContent | ConvertFrom-Json

        if (-not $config.settings -or $config.settings.Count -eq 0) {
            throw "Configuration must contain at least one setting in the 'settings' array"
        }

        foreach ($setting in $config.settings) {
            if (-not $setting.scope) {
                throw "Each setting must have a 'scope' (Machine, User, or DefaultUser)"
            }
            if (-not $setting.path) {
                throw "Each setting must have a 'path'"
            }
            if (-not $setting.action) {
                # Default action is 'Set'
                $setting | Add-Member -NotePropertyName 'action' -NotePropertyValue 'Set' -Force
            }
        }

        Write-Log "Configuration loaded successfully: $($config.settings.Count) setting group(s)" -Level Success
        return $config
    }
    catch {
        Write-Log "Failed to load configuration: $_" -Level Error
        throw
    }
}

#endregion

#region Core Operations

function Invoke-DetectionMode {
    <#
    .SYNOPSIS
        Checks compliance against the configuration without making changes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Configuration
    )
    
    Write-Log "Starting compliance detection..." -Level Info
    
    $compliant = $true
    $nonCompliantItems = @()
    
    foreach ($settingGroup in $Configuration.settings) {
        $scope = $settingGroup.scope
        $basePath = $settingGroup.path
        $action = $settingGroup.action
        
        Write-Log "Checking: [$scope] $basePath (Action: $action)" -Level Debug
        
        # Determine which registry paths to check
        $registryPaths = @()
        
        switch ($scope.ToLower()) {
            'machine' {
                $registryPaths += @{
                    Path     = "HKLM:\$basePath"
                    Context  = "Machine"
                }
            }
            'user' {
                $userProfiles = Get-UserProfileSIDs
                foreach ($userProfile in $userProfiles) {
                    $entry = @{
                        Path    = "$($userProfile.HivePath)\$basePath"
                        Context = "User: $($userProfile.Username)"
                    }
                    # Newly mounted (signed-out) profile — caller must dismount
                    if ($userProfile.HiveInfo) {
                        $entry.HiveInfo = $userProfile.HiveInfo
                    }
                    $registryPaths += $entry
                }
            }
            'defaultuser' {
                $defaultHive = Get-DefaultUserHive
                if ($defaultHive) {
                    $registryPaths += @{
                        Path        = "$($defaultHive.HivePath)\$basePath"
                        Context     = "Default User"
                        HiveInfo    = $defaultHive
                    }
                }
            }
        }
        
        foreach ($regPath in $registryPaths) {
            $fullPath = $regPath.Path
            
            switch ($action.ToLower()) {
                'set' {
                    foreach ($value in $settingGroup.values) {
                        # Skip detection for values marked with skipDetection (e.g., timestamps)
                        if ($value.skipDetection -eq $true) {
                            Write-Log "SKIPPED: $($regPath.Context) - $($value.name) (skipDetection enabled)" -Level Debug
                            continue
                        }

                        $expandedValue = Expand-ConfigVariables -Value $value.data
                        $comparisonOperator = if ($value.comparison) { $value.comparison } else { 'Equals' }
                        $caseSensitive = [bool]($value.caseSensitive -eq $true)
                        $comparison = Compare-RegistryValue -Path $fullPath -Name $value.name `
                            -Type $value.type -ExpectedValue $expandedValue -Comparison $comparisonOperator `
                            -CaseSensitive $caseSensitive

                        if (-not $comparison.Match) {
                            $compliant = $false
                            $nonCompliantItems += [PSCustomObject]@{
                                Context  = $regPath.Context
                                Path     = $fullPath
                                Name     = $value.name
                                Expected = $expandedValue
                                Current  = $comparison.Current
                                Reason   = $comparison.Reason
                            }
                            Write-Log "NON-COMPLIANT: $($regPath.Context) - $($value.name): $($comparison.Reason)" -Level Warning
                        }
                        else {
                            Write-Log "COMPLIANT: $($regPath.Context) - $($value.name)" -Level Debug
                        }
                    }
                }
                'delete' {
                    foreach ($value in $settingGroup.values) {
                        if (Test-Path $fullPath) {
                            $item = Get-ItemProperty -Path $fullPath -Name $value.name -ErrorAction SilentlyContinue
                            if ($null -ne $item -and ($item.PSObject.Properties.Name -contains $value.name)) {
                                $compliant = $false
                                $nonCompliantItems += [PSCustomObject]@{
                                    Context  = $regPath.Context
                                    Path     = $fullPath
                                    Name     = $value.name
                                    Expected = "(Deleted)"
                                    Current  = $item.$($value.name)
                                    Reason   = "Value exists but should be deleted"
                                }
                                Write-Log "NON-COMPLIANT: $($regPath.Context) - $($value.name) exists (should be deleted)" -Level Warning
                            }
                        }
                    }
                }
                'deletekey' {
                    if (Test-Path $fullPath) {
                        $compliant = $false
                        $nonCompliantItems += [PSCustomObject]@{
                            Context  = $regPath.Context
                            Path     = $fullPath
                            Name     = "(Key)"
                            Expected = "(Key Deleted)"
                            Current  = "(Key Exists)"
                            Reason   = "Key exists but should be deleted"
                        }
                        Write-Log "NON-COMPLIANT: $($regPath.Context) - Key exists (should be deleted)" -Level Warning
                    }
                }
            }
            
            # Dismount default user hive if it was loaded
            if ($regPath.HiveInfo -and $regPath.HiveInfo.NeedsUnload) {
                Dismount-RegistryHive -TempKey $regPath.HiveInfo.TempKey
            }
        }
    }
    
    if ($compliant) {
        Write-Log "COMPLIANT - All settings match the desired configuration" -Level Success -EventId 1001
        return @{
            Compliant = $true
            ExitCode  = $script:ExitCodes.Compliant
            Message   = "$script:LogPrefix [$script:ConfigIdentifier] COMPLIANT - All settings are correct"
        }
    }
    else {
        Write-Log "NON-COMPLIANT - $($nonCompliantItems.Count) setting(s) need remediation" -Level Warning -EventId 1002
        return @{
            Compliant        = $false
            ExitCode         = $script:ExitCodes.NonCompliant
            NonCompliantItems = $nonCompliantItems
            Message          = "$script:LogPrefix [$script:ConfigIdentifier] NON-COMPLIANT - $($nonCompliantItems.Count) setting(s) need remediation"
        }
    }
}

function Invoke-RemediationMode {
    <#
    .SYNOPSIS
        Applies the configuration changes to the registry.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        $Configuration
    )
    
    Write-Log "Starting remediation..." -Level Info

    $transactions = @()
    $success = $true
    $changesApplied = 0
    $errors = @()
    $rebootRequired = $false

    foreach ($settingGroup in $Configuration.settings) {
        $settingRequiresReboot = $settingGroup.rebootRequired -eq $true
        $scope = $settingGroup.scope
        $basePath = $settingGroup.path
        $action = $settingGroup.action
        
        Write-Log "Processing: [$scope] $basePath (Action: $action)" -Level Info
        
        # Determine which registry paths to modify
        $registryPaths = @()
        
        switch ($scope.ToLower()) {
            'machine' {
                $registryPaths += @{
                    Path     = "HKLM:\$basePath"
                    Context  = "Machine"
                }
            }
            'user' {
                $userProfiles = Get-UserProfileSIDs
                foreach ($userProfile in $userProfiles) {
                    $entry = @{
                        Path    = "$($userProfile.HivePath)\$basePath"
                        Context = "User: $($userProfile.Username)"
                    }
                    # Newly mounted (signed-out) profile — caller must dismount
                    if ($userProfile.HiveInfo) {
                        $entry.HiveInfo = $userProfile.HiveInfo
                    }
                    $registryPaths += $entry
                }
            }
            'defaultuser' {
                $defaultHive = Get-DefaultUserHive
                if ($defaultHive) {
                    $registryPaths += @{
                        Path        = "$($defaultHive.HivePath)\$basePath"
                        Context     = "Default User"
                        HiveInfo    = $defaultHive
                    }
                }
            }
        }
        
        foreach ($regPath in $registryPaths) {
            $fullPath = $regPath.Path
            
            try {
                switch ($action.ToLower()) {
                    'set' {
                        # Ensure key exists
                        if (-not (Test-Path $fullPath)) {
                            if ($PSCmdlet.ShouldProcess($fullPath, "Create registry key")) {
                                New-Item -Path $fullPath -Force | Out-Null
                                Write-Log "Created key: $fullPath" -Level Info
                            }
                        }
                        
                        foreach ($value in $settingGroup.values) {
                            # Handle NotExists comparison - delete value instead of setting
                            if ($value.comparison -eq 'NotExists') {
                                if (Test-Path $fullPath) {
                                    $item = Get-ItemProperty -Path $fullPath -Name $value.name -ErrorAction SilentlyContinue
                                    if ($null -ne $item -and ($item.PSObject.Properties.Name -contains $value.name)) {
                                        $backup = Backup-RegistryValue -Path $fullPath -Name $value.name
                                        $transactions += $backup

                                        if ($PSCmdlet.ShouldProcess("$fullPath\$($value.name)", "Delete registry value (NotExists)")) {
                                            Remove-ItemProperty -Path $fullPath -Name $value.name -Force
                                            Write-Log "Deleted (NotExists): $($regPath.Context) - $($value.name)" -Level Success
                                            $changesApplied++
                                            if ($settingRequiresReboot) { $rebootRequired = $true }
                                        }
                                    }
                                }
                                continue
                            }

                            $expandedValue = Expand-ConfigVariables -Value $value.data
                            $convertedValue = Convert-RegistryValue -Type $value.type -Value $expandedValue
                            $valueKind = Get-RegistryTypeKind -Type $value.type

                            # Backup current value
                            $backup = Backup-RegistryValue -Path $fullPath -Name $value.name
                            $transactions += $backup

                            if ($PSCmdlet.ShouldProcess("$fullPath\$($value.name)", "Set registry value")) {
                                Set-ItemProperty -Path $fullPath -Name $value.name -Value $convertedValue -Type $valueKind
                                Write-Log "Set: $($regPath.Context) - $($value.name) = $expandedValue" -Level Success
                                $changesApplied++
                                if ($settingRequiresReboot) { $rebootRequired = $true }
                            }
                        }
                    }
                    'delete' {
                        foreach ($value in $settingGroup.values) {
                            if (Test-Path $fullPath) {
                                $item = Get-ItemProperty -Path $fullPath -Name $value.name -ErrorAction SilentlyContinue
                                if ($null -ne $item -and ($item.PSObject.Properties.Name -contains $value.name)) {
                                    # Backup current value
                                    $backup = Backup-RegistryValue -Path $fullPath -Name $value.name
                                    $transactions += $backup
                                    
                                    if ($PSCmdlet.ShouldProcess("$fullPath\$($value.name)", "Delete registry value")) {
                                        Remove-ItemProperty -Path $fullPath -Name $value.name -Force
                                        Write-Log "Deleted: $($regPath.Context) - $($value.name)" -Level Success
                                        $changesApplied++
                                        if ($settingRequiresReboot) { $rebootRequired = $true }
                                    }
                                }
                            }
                        }
                    }
                    'deletekey' {
                        if (Test-Path $fullPath) {
                            # Determine restorability category before deletion:
                            #   Machine     - reg.exe import at rollback fully restores
                            #   MountedUser - .reg references HKEY_USERS\<sid>; restores
                            #                 if the same user is signed in at rollback time
                            #   TempMount   - DefaultUser, or a user we mounted ourselves;
                            #                 the temp mount won't exist at rollback. Backup
                            #                 file is retained for manual recovery.
                            $backupKind = switch ($scope.ToLower()) {
                                'machine'     { 'Machine' }
                                'defaultuser' { 'TempMount' }
                                'user'        { if ($regPath.HiveInfo) { 'TempMount' } else { 'MountedUser' } }
                                default       { 'Unknown' }
                            }

                            $backupFile = $null
                            if (-not $WhatIfPreference) {
                                $backupRoot = Join-Path $TransactionLogPath 'KeyBackups'
                                $backupFile = Backup-RegistryKey -Path $fullPath -BackupRoot $backupRoot
                            }

                            $transactions += @{
                                Path       = $fullPath
                                Name       = "(Key)"
                                Timestamp  = (Get-Date).ToString("o")
                                Existed    = $true
                                Type       = "Key"
                                Value      = $null
                                BackupFile = $backupFile
                                BackupKind = $backupKind
                            }

                            if ($PSCmdlet.ShouldProcess($fullPath, "Delete registry key")) {
                                Remove-Item -Path $fullPath -Recurse -Force
                                Write-Log "Deleted key: $($regPath.Context) - $fullPath" -Level Success
                                $changesApplied++
                                if ($settingRequiresReboot) { $rebootRequired = $true }
                            }
                        }
                    }
                }
            }
            catch {
                $success = $false
                $errors += "Error processing $($regPath.Context) - $fullPath : $_"
                Write-Log "ERROR: $_" -Level Error
            }
            finally {
                # Dismount default user hive if it was loaded
                if ($regPath.HiveInfo -and $regPath.HiveInfo.NeedsUnload) {
                    Dismount-RegistryHive -TempKey $regPath.HiveInfo.TempKey
                }
            }
        }
    }
    
    # Save transaction log
    if ($transactions.Count -gt 0 -and -not $WhatIfPreference) {
        Save-TransactionLog -Transactions $transactions -LogPath $TransactionLogPath
    }
    
    if ($success) {
        Write-Log "REMEDIATION COMPLETE - $changesApplied change(s) applied successfully" -Level Success -EventId 2001

        # Show reboot notification if any applied settings require a reboot
        if ($rebootRequired -and $changesApplied -gt 0 -and -not $WhatIfPreference) {
            Write-Log "Reboot required for applied changes" -Level Warning
            Show-RebootToast
        }

        return @{
            Success        = $true
            ExitCode       = $script:ExitCodes.RemediationOK
            ChangesCount   = $changesApplied
            RebootRequired = $rebootRequired
            Message        = "$script:LogPrefix [$script:ConfigIdentifier] SUCCESS - $changesApplied change(s) applied"
        }
    }
    else {
        Write-Log "REMEDIATION FAILED - Errors occurred during remediation" -Level Error -EventId 2002
        return @{
            Success  = $false
            ExitCode = $script:ExitCodes.RemediationFail
            Errors   = $errors
            Message  = "$script:LogPrefix [$script:ConfigIdentifier] FAILED - Errors: $($errors -join '; ')"
        }
    }
}

function Invoke-RollbackMode {
    <#
    .SYNOPSIS
        Rolls back changes using a transaction log.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string]$TransactionFile
    )

    # Resolve the config identifier before any Write-Log fires so every line
    # is tagged correctly. Start from the transaction filename as a fallback,
    # then upgrade from the embedded ConfigIdentifier field once the file is
    # parsed (older transaction files won't have the field).
    $script:ConfigIdentifier = [System.IO.Path]::GetFileNameWithoutExtension($TransactionFile)

    if (-not (Test-Path $TransactionFile)) {
        Write-Log "Transaction file not found: $TransactionFile" -Level Error
        return @{
            Success  = $false
            ExitCode = $script:ExitCodes.ConfigError
            Message  = "$script:LogPrefix [$script:ConfigIdentifier] ROLLBACK FAILED - Transaction file not found"
        }
    }

    try {
        $logData = Get-Content -Path $TransactionFile -Raw | ConvertFrom-Json
        if ($logData.ConfigIdentifier) {
            $script:ConfigIdentifier = $logData.ConfigIdentifier
        }

        # Identifier is now final — emit the engine banner and the start line.
        Write-Log "Registry Configuration Engine v$script:EngineVersion" -Level Info
        Write-Log "Mode: Rollback | Computer: $env:COMPUTERNAME | User: $env:USERNAME" -Level Debug
        Write-Log "Starting rollback from: $TransactionFile" -Level Info

        $rolledBack = 0
        
        foreach ($tx in $logData.Transactions) {
            if ($tx.Type -eq "Key") {
                if (-not $tx.BackupFile -or -not (Test-Path -LiteralPath $tx.BackupFile)) {
                    Write-Log "Cannot rollback key deletion (no backup file): $($tx.Path)" -Level Warning
                    continue
                }
                if ($tx.BackupKind -eq 'TempMount') {
                    Write-Log "Cannot auto-restore key for DefaultUser/unmounted user profile: $($tx.Path). Backup retained at $($tx.BackupFile) for manual recovery." -Level Warning
                    continue
                }

                if ($PSCmdlet.ShouldProcess($tx.Path, "Restore registry key from backup")) {
                    $regImport = & reg.exe import $tx.BackupFile 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "Restored key: $($tx.Path) (from $($tx.BackupFile))" -Level Success
                        $rolledBack++
                    }
                    else {
                        Write-Log "Failed to restore key from $($tx.BackupFile): $regImport" -Level Error
                    }
                }
                continue
            }
            
            if ($tx.Existed) {
                # Restore the original value
                $valueKind = Get-RegistryTypeKind -Type $tx.Type
                
                if ($PSCmdlet.ShouldProcess("$($tx.Path)\$($tx.Name)", "Restore registry value")) {
                    if (-not (Test-Path $tx.Path)) {
                        New-Item -Path $tx.Path -Force | Out-Null
                    }
                    Set-ItemProperty -Path $tx.Path -Name $tx.Name -Value $tx.Value -Type $valueKind
                    Write-Log "Restored: $($tx.Path)\$($tx.Name)" -Level Success
                    $rolledBack++
                }
            }
            else {
                # Value didn't exist before, so delete it
                if ($PSCmdlet.ShouldProcess("$($tx.Path)\$($tx.Name)", "Remove registry value")) {
                    if (Test-Path $tx.Path) {
                        Remove-ItemProperty -Path $tx.Path -Name $tx.Name -Force -ErrorAction SilentlyContinue
                        Write-Log "Removed (was new): $($tx.Path)\$($tx.Name)" -Level Success
                        $rolledBack++
                    }
                }
            }
        }
        
        Write-Log "ROLLBACK COMPLETE - $rolledBack change(s) reverted" -Level Success
        return @{
            Success  = $true
            ExitCode = $script:ExitCodes.Compliant
            Message  = "$script:LogPrefix [$script:ConfigIdentifier] ROLLBACK SUCCESS - $rolledBack change(s) reverted"
        }
    }
    catch {
        Write-Log "Rollback failed: $_" -Level Error
        return @{
            Success  = $false
            ExitCode = $script:ExitCodes.RemediationFail
            Message  = "$script:LogPrefix [$script:ConfigIdentifier] ROLLBACK FAILED - $_"
        }
    }
}

#endregion

#region Main Execution

# Dot-source guard: when this file is dot-sourced (e.g., by Pester), do not
# execute the main flow — only define functions for testing. $MyInvocation
# .InvocationName is '.' for dot-source; anything else (script path, '&', etc.)
# means normal execution.
if ($MyInvocation.InvocationName -ne '.') {

try {
    # Apply injection-time overrides for packaged Intune scripts. No-op for
    # standalone (the variables default to $null/$false in the INJECTION_POINT
    # region above).
    if ($script:__ForcedMode)     { $Mode = $script:__ForcedMode }
    if ($script:__ForcedEventLog) { $CreateEventLog = $true }

    # Engine banner is emitted AFTER the config identifier is resolved, so the
    # log lines tag correctly. For Detect/Remediate/Validate that's right after
    # Get-Configuration; for Rollback it's inside Invoke-RollbackMode after the
    # transaction file is parsed.

    # Clean up any temp hives left behind by previously crashed runs.
    # Skipped for Validate (no registry access expected) and Rollback (which
    # restores values, not mount state).
    if ($Mode -in 'Detect', 'Remediate') {
        Remove-OrphanedTempHives
    }

    # Handle rollback mode separately (always reads from a transaction file path)
    if ($Mode -eq 'Rollback') {
        if ([string]::IsNullOrEmpty($ConfigPath)) {
            throw "Rollback mode requires -ConfigPath pointing to a transaction file."
        }
        $result = Invoke-RollbackMode -TransactionFile $ConfigPath
        Write-Output $result.Message
        exit $result.ExitCode
    }

    # Default ConfigPath when running standalone with no explicit path
    # (so the provisional identifier derivation below has something to work with).
    if (-not $script:__EmbeddedConfig -and [string]::IsNullOrEmpty($ConfigPath)) {
        $ConfigPath = Join-Path $PSScriptRoot "config.json"
    }

    # Provisional identifier from path so config-load log lines tag correctly.
    # Refined after load if the config has a description field (embedded case).
    if ($ConfigPath -and $ConfigPath -notmatch '^https?://') {
        $script:ConfigIdentifier = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
    }
    elseif ($ConfigPath -match '^https?://') {
        $script:ConfigIdentifier = [System.IO.Path]::GetFileNameWithoutExtension(([Uri]$ConfigPath).Segments[-1])
    }

    # Load configuration: embedded (packaged scripts) takes precedence over file/URL
    if ($script:__EmbeddedConfig) {
        $config = Get-Configuration -EmbeddedJson $script:__EmbeddedConfig
    }
    else {
        $config = Get-Configuration -Path $ConfigPath -Sha256 $ConfigSha256
    }

    # Derive the config identifier from whichever source we just loaded.
    # File path → filename without extension; URL → last URL segment without extension;
    # embedded → sanitised description if present, else "embedded-config".
    if ($ConfigPath -and $ConfigPath -notmatch '^https?://') {
        $script:ConfigIdentifier = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
    }
    elseif ($ConfigPath -match '^https?://') {
        $script:ConfigIdentifier = [System.IO.Path]::GetFileNameWithoutExtension(([Uri]$ConfigPath).Segments[-1])
    }
    elseif ($script:__EmbeddedConfig) {
        $script:ConfigIdentifier = if ($config.description) {
            ($config.description -replace '[^\w\-]', '_').Substring(0, [Math]::Min(50, $config.description.Length))
        } else {
            "embedded-config"
        }
    }

    # Identifier is now resolved — emit the engine banner so every line tags
    # correctly (Rollback emits its banner inside Invoke-RollbackMode after
    # reading the transaction file).
    Write-Log "Registry Configuration Engine v$script:EngineVersion" -Level Info
    Write-Log "Mode: $Mode | Computer: $env:COMPUTERNAME | User: $env:USERNAME" -Level Debug

    # Validation mode - just parse and validate
    if ($Mode -eq 'Validate') {
        Write-Log "Configuration validation successful" -Level Success
        Write-Output "$script:LogPrefix [$script:ConfigIdentifier] VALIDATION OK - Configuration is valid ($($config.settings.Count) setting groups)"
        exit $script:ExitCodes.Compliant
    }
    
    # Detection mode
    if ($Mode -eq 'Detect') {
        $result = Invoke-DetectionMode -Configuration $config
        Write-Output $result.Message
        exit $result.ExitCode
    }
    
    # Remediation mode
    if ($Mode -eq 'Remediate') {
        $result = Invoke-RemediationMode -Configuration $config
        Write-Output $result.Message
        exit $result.ExitCode
    }
}
catch {
    $errorMessage = "$script:LogPrefix [$script:ConfigIdentifier] ERROR - $_"
    Write-Log $errorMessage -Level Error -EventId 9999
    Write-Output $errorMessage
    exit $script:ExitCodes.ConfigError
}

} # end dot-source guard

#endregion
