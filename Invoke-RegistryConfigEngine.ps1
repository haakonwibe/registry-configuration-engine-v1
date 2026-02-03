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
    Version:        1.0.0
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
    [switch]$CreateEventLog
)

#region Script Configuration
$script:EngineVersion = "1.0.0"
$script:EventLogSource = "RegistryConfigEngine"
$script:EventLogName = "Application"
$script:LogPrefix = "[REGENGINE]"

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
    
    $logMessage = "$timestamp $script:LogPrefix $prefix $Message"
    
    switch ($Level) {
        'Error'   { Write-Error $logMessage }
        'Warning' { Write-Warning $logMessage }
        'Debug'   { Write-Verbose $logMessage }
        default   { Write-Output $logMessage }
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
                -EventId $EventId -EntryType $entryType -Message $Message
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

function Get-UserProfileSIDs {
    <#
    .SYNOPSIS
        Gets all user profile SIDs from the registry, supporting both AD and Entra ID joined devices.
    #>
    [CmdletBinding()]
    param()
    
    $userSIDs = @()
    
    try {
        # Get all SIDs from HKU (mounted user hives)
        $hkuKeys = Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue | 
            Where-Object { $_.PSChildName -match '^S-1-5-21-|^S-1-12-1-' } |
            Where-Object { $_.PSChildName -notmatch '_Classes$' }
        
        foreach ($key in $hkuKeys) {
            $sid = $key.PSChildName
            
            # Try to get the username for logging purposes
            try {
                $objSID = New-Object System.Security.Principal.SecurityIdentifier($sid)
                $objUser = $objSID.Translate([System.Security.Principal.NTAccount])
                $username = $objUser.Value
            }
            catch {
                $username = "Unknown"
            }
            
            $userSIDs += [PSCustomObject]@{
                SID      = $sid
                Username = $username
                HivePath = "Registry::HKEY_USERS\$sid"
            }
        }
        
        Write-Log "Found $($userSIDs.Count) user profile(s) in HKU" -Level Debug
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
    
    $defaultUserPath = "$env:SystemDrive\Users\Default\NTUSER.DAT"
    $tempHiveKey = "HKU\DefaultUserTemp_$(Get-Random)"
    
    if (-not (Test-Path $defaultUserPath)) {
        Write-Log "Default user hive not found at: $defaultUserPath" -Level Warning
        return $null
    }
    
    try {
        # Load the hive
        $regLoad = & reg.exe load $tempHiveKey $defaultUserPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Failed to load default user hive: $regLoad" -Level Error
            return $null
        }
        
        Write-Log "Loaded Default User hive to: $tempHiveKey" -Level Debug
        
        return [PSCustomObject]@{
            HivePath    = "Registry::$tempHiveKey"
            TempKey     = $tempHiveKey
            NeedsUnload = $true
        }
    }
    catch {
        Write-Log "Exception loading default user hive: $_" -Level Error
        return $null
    }
}

function Dismount-DefaultUserHive {
    <#
    .SYNOPSIS
        Dismounts a previously loaded Default User hive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TempKey
    )
    
    try {
        # Force garbage collection to release any handles
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 500
        
        $regUnload = & reg.exe unload $TempKey 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Warning: Could not dismount hive (may still be in use): $regUnload" -Level Warning
        }
        else {
            Write-Log "Dismounted Default User hive: $TempKey" -Level Debug
        }
    }
    catch {
        Write-Log "Exception dismounting hive: $_" -Level Warning
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
            elseif ($Value -match '^[0-9A-Fa-f,\s]+$') {
                # Comma-separated or space-separated hex values
                $cleanValue = $Value -replace '\s+', ',' -replace ',+', ','
                return [byte[]]($cleanValue -split ',' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_.Trim(), 16) })
            }
            elseif ($Value -match '^(0x)?[0-9A-Fa-f]+$') {
                # Single hex string
                $hexString = $Value -replace '^0x', ''
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
            if ($Value -is [array]) {
                return [string[]]$Value
            }
            else {
                return [string[]]@($Value)
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
        [string]$Comparison = 'Equals'
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

        switch ($Comparison) {
            'Equals' {
                # Handle binary comparison
                if ($Type.ToLower() -eq 'binary') {
                    $match = $null -ne $actualValue -and
                             $actualValue.Length -eq $convertedExpected.Length -and
                             -not (Compare-Object $actualValue $convertedExpected)
                }
                # Handle multi-string comparison
                elseif ($Type.ToLower() -eq 'multistring') {
                    $match = $null -ne $actualValue -and
                             -not (Compare-Object $actualValue $convertedExpected)
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
                    $match = $null -eq $actualValue -or
                             (Compare-Object $actualValue $convertedExpected)
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
                $match = $actualValue -like "*$convertedExpected*"
                $reason = if ($match) { "Value contains '$convertedExpected'" } else { "Value does not contain '$convertedExpected'" }
            }
            'StartsWith' {
                $match = $actualValue -like "$convertedExpected*"
                $reason = if ($match) { "Value starts with '$convertedExpected'" } else { "Value does not start with '$convertedExpected'" }
            }
            'EndsWith' {
                $match = $actualValue -like "*$convertedExpected"
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
        
        $logFile = Join-Path $LogPath "Transaction_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        
        $logData = @{
            EngineVersion = $script:EngineVersion
            ComputerName  = $env:COMPUTERNAME
            Timestamp     = (Get-Date).ToString("o")
            Transactions  = $Transactions
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
        Loads and validates the JSON configuration file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    Write-Log "Loading configuration from: $Path" -Level Info
    
    try {
        # Handle URL-based configs
        if ($Path -match '^https?://') {
            Write-Log "Downloading configuration from URL..." -Level Debug
            $configContent = (Invoke-WebRequest -Uri $Path -UseBasicParsing).Content
        }
        elseif (Test-Path $Path) {
            $configContent = Get-Content -Path $Path -Raw -Encoding UTF8
        }
        else {
            throw "Configuration file not found: $Path"
        }
        
        $config = $configContent | ConvertFrom-Json
        
        # Validate required properties
        if (-not $config.settings -or $config.settings.Count -eq 0) {
            throw "Configuration must contain at least one setting in the 'settings' array"
        }
        
        # Validate each setting
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
                    $registryPaths += @{
                        Path     = "$($userProfile.HivePath)\$basePath"
                        Context  = "User: $($userProfile.Username)"
                    }
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
                        $comparison = Compare-RegistryValue -Path $fullPath -Name $value.name `
                            -Type $value.type -ExpectedValue $expandedValue -Comparison $comparisonOperator

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
                Dismount-DefaultUserHive -TempKey $regPath.HiveInfo.TempKey
            }
        }
    }
    
    if ($compliant) {
        Write-Log "COMPLIANT - All settings match the desired configuration" -Level Success -EventId 1001
        return @{
            Compliant = $true
            ExitCode  = $script:ExitCodes.Compliant
            Message   = "$script:LogPrefix COMPLIANT - All settings are correct"
        }
    }
    else {
        Write-Log "NON-COMPLIANT - $($nonCompliantItems.Count) setting(s) need remediation" -Level Warning -EventId 1002
        return @{
            Compliant        = $false
            ExitCode         = $script:ExitCodes.NonCompliant
            NonCompliantItems = $nonCompliantItems
            Message          = "$script:LogPrefix NON-COMPLIANT - $($nonCompliantItems.Count) setting(s) need remediation"
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
                    $registryPaths += @{
                        Path     = "$($userProfile.HivePath)\$basePath"
                        Context  = "User: $($userProfile.Username)"
                    }
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
                            # For key deletion, we backup the entire key structure
                            $transactions += @{
                                Path      = $fullPath
                                Name      = "(Key)"
                                Timestamp = (Get-Date).ToString("o")
                                Existed   = $true
                                Type      = "Key"
                                Value     = "(Key structure not backed up for rollback)"
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
                    Dismount-DefaultUserHive -TempKey $regPath.HiveInfo.TempKey
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
            Message        = "$script:LogPrefix SUCCESS - $changesApplied change(s) applied"
        }
    }
    else {
        Write-Log "REMEDIATION FAILED - Errors occurred during remediation" -Level Error -EventId 2002
        return @{
            Success  = $false
            ExitCode = $script:ExitCodes.RemediationFail
            Errors   = $errors
            Message  = "$script:LogPrefix FAILED - Errors: $($errors -join '; ')"
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
    
    Write-Log "Starting rollback from: $TransactionFile" -Level Info
    
    if (-not (Test-Path $TransactionFile)) {
        Write-Log "Transaction file not found: $TransactionFile" -Level Error
        return @{
            Success  = $false
            ExitCode = $script:ExitCodes.ConfigError
            Message  = "$script:LogPrefix ROLLBACK FAILED - Transaction file not found"
        }
    }
    
    try {
        $logData = Get-Content -Path $TransactionFile -Raw | ConvertFrom-Json
        $rolledBack = 0
        
        foreach ($tx in $logData.Transactions) {
            if ($tx.Type -eq "Key") {
                Write-Log "Cannot rollback key deletion: $($tx.Path)" -Level Warning
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
            Message  = "$script:LogPrefix ROLLBACK SUCCESS - $rolledBack change(s) reverted"
        }
    }
    catch {
        Write-Log "Rollback failed: $_" -Level Error
        return @{
            Success  = $false
            ExitCode = $script:ExitCodes.RemediationFail
            Message  = "$script:LogPrefix ROLLBACK FAILED - $_"
        }
    }
}

#endregion

#region Main Execution

try {
    Write-Log "Registry Configuration Engine v$script:EngineVersion" -Level Info
    Write-Log "Mode: $Mode | Computer: $env:COMPUTERNAME | User: $env:USERNAME" -Level Debug
    
    # Determine config path
    if ([string]::IsNullOrEmpty($ConfigPath)) {
        $ConfigPath = Join-Path $PSScriptRoot "config.json"
    }
    
    # Handle rollback mode separately
    if ($Mode -eq 'Rollback') {
        $result = Invoke-RollbackMode -TransactionFile $ConfigPath
        Write-Output $result.Message
        exit $result.ExitCode
    }
    
    # Load configuration
    $config = Get-Configuration -Path $ConfigPath
    
    # Validation mode - just parse and validate
    if ($Mode -eq 'Validate') {
        Write-Log "Configuration validation successful" -Level Success
        Write-Output "$script:LogPrefix VALIDATION OK - Configuration is valid ($($config.settings.Count) setting groups)"
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
    $errorMessage = "$script:LogPrefix ERROR - $_"
    Write-Log $errorMessage -Level Error -EventId 9999
    Write-Output $errorMessage
    exit $script:ExitCodes.ConfigError
}

#endregion
