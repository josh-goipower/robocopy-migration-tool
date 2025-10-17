#requires -Version 5.1
<#
.SYNOPSIS
    Robocopy Migration Tool with Progress Tracking
.DESCRIPTION
    Structured migration workflow: SEED -> SYNC -> RECONCILE -> MIRROR
    Features progress bars, email notifications, and detailed reporting
.PARAMETER Mode
    Migration phase: SEED, SYNC, RECONCILE, or MIRROR
.PARAMETER Preview
    Run in dry-run mode (list only, no changes)
.PARAMETER Confirm
    Required for MIRROR execution
.NOTES
    Retry Configuration:
    The script automatically adjusts retry settings based on whether paths are local or network (UNC):

    Local Paths (C:\, D:\, etc.):
    - RetryCount: Default 5 retries
    - RetryWaitSec: Default 5 seconds between retries
    
    Network Paths (\\server\share):
    - NetworkRetries: Default 1000 retries
    - NetworkWaitSec: Default 30 seconds between retries

    These values can be adjusted in the $Config hashtable:
    $Config.RetryCount = 10        # Increase local path retries
    $Config.RetryWaitSec = 10      # Increase local path wait time
    $Config.NetworkRetries = 500    # Adjust network retries
    $Config.NetworkWaitSec = 15     # Adjust network wait time

    Recommended Values:
    - Local paths: 5-10 retries, 5-15 seconds wait
    - Network paths: 100-1000 retries, 15-30 seconds wait
    - High-latency networks may benefit from longer wait times
    - Critical transfers may warrant higher retry counts
.EXAMPLE
    .\Migrate.ps1 -Mode SEED
    .\Migrate.ps1 -Mode SYNC -Preview
    .\Migrate.ps1 -Mode MIRROR -Confirm
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('SEED','SYNC','RECONCILE','MIRROR')]
    [string]$Mode,
    
    [switch]$Preview,
    [switch]$Confirm,
    [switch]$PrintCommand,
    [switch]$ForceBackup,
    [switch]$AppendLogs,
    [switch]$VssFallback
)

# =========================================
# CONFIGURATION
# =========================================
$Config = @{
    Source              = '\\fs\Quickbooks\iPower Test'
    Destination         = '\\KF-DC\Quickbooks\iPower Test'
    LogRoot            = 'C:\Logs\iPower Test'
    Threads            = 32
    PreserveACL         = $true
    BandwidthThrottle   = 0    # Milliseconds between packets (0 = no throttle)
    
    # Retry settings for different path types
    RetryCount         = 7     # Number of retries for failed copies (local paths)
    RetryWaitSec      = 10    # Seconds to wait between retries (local paths)
    NetworkRetries    = 500    # Higher retry count for network paths
    NetworkWaitSec    = 20     # Longer wait time for network paths
    
    # Retry Limits (used for validation)
    MaxRetryCount     = 100    # Maximum retries for local paths
    MaxRetryWaitSec   = 30     # Maximum wait time for local paths
    MaxNetworkRetries = 5000   # Maximum retries for network paths
    MaxNetworkWaitSec = 120    # Maximum wait time for network paths
    
    # Excludes (leave empty arrays if none)
    ExcludeDirs         = @()  # e.g., @('Temp', '~snapshot', '.recycle')
    ExcludeFiles        = @()  # e.g., @('*.tmp', '*.bak')
    
    # Email notifications (set SendEmail = $true to enable)
    SendEmail           = $false
    SmtpServer          = 'smtp.company.com'
    EmailFrom           = 'migrations@company.com'
    EmailTo             = @('admin@company.com')
    
    # Optional SMTP settings
    SmtpPort            = 25
    SmtpUseSsl          = $false
    SmtpCredential      = $null  # e.g., Get-Credential
    SmtpUser            = $null  # Alternative to SmtpCredential
    SmtpPassword        = $null  # Alternative to SmtpCredential
    EmailOnSuccess      = $true
    EmailOnFailure      = $true
    
    # Logging and copy behavior
    AppendLogs          = $false  # if true, use /LOG+: to append to a single log file
    ForceBackup         = $false  # if true, use /B (backup mode) instead of /ZB
    
    # Watchdog settings
    WatchdogEnabled     = $true
    WatchdogTimeoutMin  = 15     # Minutes before timeout
}

# =========================================
# INITIALIZATION
# =========================================
$ErrorActionPreference = 'Stop'
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# Ensure log paths are properly formatted
$Config.LogRoot = $Config.LogRoot.TrimEnd('\')
$LogDir = Join-Path $Config.LogRoot $Timestamp
$StateFile = Join-Path $Config.LogRoot 'migration_state.json'

Write-Status "Initializing with log directory: $LogDir" -Level Info

# Ensure script runs only on Windows (robocopy and Windows ACLs are Windows-specific)
if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    Write-Host "This script must be run on Windows. Detected platform: $($PSVersionTable.Platform)" -ForegroundColor Red
    exit 2
}

# Create log directory structure
try {
    if (-not (Test-Path $Config.LogRoot)) {
        New-Item -ItemType Directory -Path $Config.LogRoot -Force | Out-Null
        Write-Status "Created log root directory: $($Config.LogRoot)" -Level Info
    }
    
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null
        Write-Status "Created log directory: $LogDir" -Level Info
    }
}
catch {
    Write-Status "Failed to create log directory structure: $_" -Level Error
    throw "Cannot create required log directories. Ensure you have write permissions to $($Config.LogRoot)"
}

# =========================================
# FUNCTIONS
# =========================================

function Write-Header {
    param([string]$Text)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error')]
        [string]$Level = 'Info'
    )
    
    $colors = @{
        Info    = 'White'
        Success = 'Green'
        Warning = 'Yellow'
        Error   = 'Red'
    }
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] " -NoNewline -ForegroundColor Gray
    Write-Host $Message -ForegroundColor $colors[$Level]
}

function Test-RetrySettings {
    # Validate and adjust retry settings if needed
    if ($Config.RetryCount -lt 1) {
        Write-Status "RetryCount adjusted to minimum value of 1" -Level Warning
        $Config.RetryCount = 1
    }
    elseif ($Config.RetryCount -gt $Config.MaxRetryCount) {
        Write-Status "RetryCount reduced to maximum allowed value of $($Config.MaxRetryCount)" -Level Warning
        $Config.RetryCount = $Config.MaxRetryCount
    }

    if ($Config.RetryWaitSec -lt 1) {
        Write-Status "RetryWaitSec adjusted to minimum value of 1" -Level Warning
        $Config.RetryWaitSec = 1
    }
    elseif ($Config.RetryWaitSec -gt $Config.MaxRetryWaitSec) {
        Write-Status "RetryWaitSec reduced to maximum allowed value of $($Config.MaxRetryWaitSec)" -Level Warning
        $Config.RetryWaitSec = $Config.MaxRetryWaitSec
    }

    if ($Config.NetworkRetries -lt $Config.RetryCount) {
        Write-Status "NetworkRetries adjusted to match RetryCount minimum" -Level Warning
        $Config.NetworkRetries = $Config.RetryCount
    }
    elseif ($Config.NetworkRetries -gt $Config.MaxNetworkRetries) {
        Write-Status "NetworkRetries reduced to maximum allowed value of $($Config.MaxNetworkRetries)" -Level Warning
        $Config.NetworkRetries = $Config.MaxNetworkRetries
    }

    if ($Config.NetworkWaitSec -lt $Config.RetryWaitSec) {
        Write-Status "NetworkWaitSec adjusted to match RetryWaitSec minimum" -Level Warning
        $Config.NetworkWaitSec = $Config.RetryWaitSec
    }
    elseif ($Config.NetworkWaitSec -gt $Config.MaxNetworkWaitSec) {
        Write-Status "NetworkWaitSec reduced to maximum allowed value of $($Config.MaxNetworkWaitSec)" -Level Warning
        $Config.NetworkWaitSec = $Config.MaxNetworkWaitSec
    }
}

function Test-Prerequisites {
    Write-Status "Validating prerequisites..." -Level Info
    
    # Validate retry settings
    Test-RetrySettings
    
    # Check elevation
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Status "Not running as Administrator - backup mode may be limited" -Level Warning
    }
    
    # Check paths and normalize them
    $Config.Source = $Config.Source.TrimEnd('\')
    $Config.Destination = $Config.Destination.TrimEnd('\')
    
    # For UNC paths, ensure network connectivity
    if ($Config.Source -match '^\\\\') {
        try {
            $sourcePath = [System.Uri]::new($Config.Source.Replace('\', '/'))
            $sourceHost = $sourcePath.Host
            if (-not (Test-Connection -ComputerName $sourceHost -Count 1 -Quiet)) {
                throw "Cannot reach source server: $sourceHost"
            }
        }
        catch {
            throw "Invalid source UNC path: $($Config.Source)"
        }
    }
    
    if ($Config.Destination -match '^\\\\') {
        try {
            $destPath = [System.Uri]::new($Config.Destination.Replace('\', '/'))
            $destHost = $destPath.Host
            if (-not (Test-Connection -ComputerName $destHost -Count 1 -Quiet)) {
                throw "Cannot reach destination server: $destHost"
            }
        }
        catch {
            throw "Invalid destination UNC path: $($Config.Destination)"
        }
    }
    
    # Check path accessibility
    if (-not (Test-Path $Config.Source -ErrorAction SilentlyContinue)) {
        throw "Source path not accessible: $($Config.Source)"
    }
    if (-not (Test-Path $Config.Destination -ErrorAction SilentlyContinue)) {
        Write-Status "Destination path does not exist: $($Config.Destination)" -Level Warning
        try {
            New-Item -ItemType Directory -Path $Config.Destination -Force -ErrorAction Stop | Out-Null
            Write-Status "Created destination directory" -Level Success
        }
        catch {
            throw "Cannot create destination path: $($Config.Destination). Error: $_"
        }
    }
    
    # Test write access
    $testFile = Join-Path $Config.Destination "__write_test_$(Get-Random).tmp"
    try {
        [System.IO.File]::WriteAllText($testFile, 'test')
        Remove-Item $testFile -Force
        Write-Status "Write access verified" -Level Success
    }
    catch {
        throw "Cannot write to destination: $($Config.Destination)"
    }
    
    # Check Robocopy
    if (-not (Get-Command robocopy -ErrorAction SilentlyContinue)) {
        throw "Robocopy not found in PATH"
    }
}

# Check whether current user/token has SeBackupPrivilege (best-effort)
function Test-BackupPrivilege {
    try {
        $out = & whoami /priv 2>$null
        if ($out) {
            return [bool]($out -match 'SeBackupPrivilege\s+\S+\s+Enabled')
        }
    }
    catch {
        return $false
    }
    return $false
}

function Build-RobocopyParams {
    param(
        [string]$Source,
        [string]$Dest,
        [string]$CustomOpts = '',
        [bool]$IsDryRun = $false,
        [string]$Mode = '',
        [bool]$ForceBackup = $false
    )
    
    # Handle paths with spaces by adding quotes if needed
    $sourcePath = if ($Source -match '\s') { "`"$Source`"" } else { $Source }
    $destPath = if ($Dest -match '\s') { "`"$Dest`"" } else { $Dest }
    
    # Ensure paths are properly formatted
    $sourcePath = $sourcePath.TrimEnd('\')
    $destPath = $destPath.TrimEnd('\')
    
    # Determine if we're dealing with network paths
    $isNetworkPath = $Source -match '^\\\\' -or $Dest -match '^\\\\' 
    
    # Use appropriate retry settings based on path type
    $retryCount = if ($isNetworkPath) { $Config.NetworkRetries } else { $Config.RetryCount }
    $retryWait = if ($isNetworkPath) { $Config.NetworkWaitSec } else { $Config.RetryWaitSec }
    
    $rcParams = @(
        $sourcePath,
        $destPath,
        '/E',           # Copy subdirectories including empty
        "/R:$retryCount",   # Retry count based on path type
        "/W:$retryWait",    # Wait time based on path type
        '/FFT',         # FAT file time tolerance
    '/FP',          # include full path names
        '/XJ',          # Exclude junction points
        "/MT:$($Config.Threads)",  # Multi-threaded
        '/BYTES',       # Show sizes in bytes
        '/NP',          # No progress per file
        '/V'            # Verbose output for better log parsing
    )
    
    # Copy attributes
    if ($Config.PreserveACL) {
        $rcParams += '/COPY:DATS'   # Data, Attributes, Timestamps, Security
        $rcParams += '/DCOPY:DAT'   # Directory timestamps and attributes
    }
    else {
        $rcParams += '/COPY:DAT'
        $rcParams += '/DCOPY:DAT'
    }

    # Decide restart/backup mode
    if ($ForceBackup -or $Config.ForceBackup) {
        # Use backup mode explicitly
        $rcParams += '/B'
    }
    else {
        if (Test-BackupPrivilege) { $rcParams += '/ZB' } else { $rcParams += '/Z' }
    }
    # Bandwidth throttle
    if ($Config.BandwidthThrottle -gt 0) {
        $rcParams += "/IPG:$($Config.BandwidthThrottle)"
    }
    
    # Excludes
    if ($Config.ExcludeDirs.Count -gt 0) {
        $rcParams += '/XD'
        $rcParams += $Config.ExcludeDirs
    }
    if ($Config.ExcludeFiles.Count -gt 0) {
        $rcParams += '/XF'
        $rcParams += $Config.ExcludeFiles
    }
    
    # Custom options
    if ($CustomOpts) {
        $rcParams += $CustomOpts.Split(' ')
    }
    
    # Dry run
    if ($IsDryRun) {
        $rcParams += '/L'   # List only
        $rcParams += '/V'   # Verbose
    }

    # Mode-specific adjustments
    if ($Mode -eq 'MIRROR') {
        $rcParams += '/MIR'
        # COPYALL is equivalent to COPY:DATSOU; using /COPYALL when mirroring
        $rcParams += '/COPYALL'
    }
    
    return $rcParams
}

 

function Invoke-RobocopyWithProgress {
    param(
        [string]$Name,
        [string]$Source,
        [string]$Dest,
        [string]$CustomOpts = '',
        [bool]$IsDryRun = $false
    )
    
    # Always initialize critical variables early
    $startTime = Get-Date
    $duration = [TimeSpan]::Zero
    $logFile = Join-Path $LogDir "$Name`_$Timestamp.log"
    
    Write-Header "$Name Operation"
    Write-Status "Source:      $Source" -Level Info
    Write-Status "Destination: $Dest" -Level Info
    Write-Status "Log File:    $logFile" -Level Info
    Write-Status "Mode:        $(if($IsDryRun){'DRY-RUN'}else{'EXECUTE'})" -Level $(if($IsDryRun){'Warning'}else{'Info'})
    Write-Host ""
    
    # Apply runtime overrides for ForceBackup and AppendLogs
    if ($ForceBackup.IsPresent) { $runForceBackup = $true } else { $runForceBackup = $Config.ForceBackup }
    if ($AppendLogs.IsPresent) { $runAppendLogs = $true } else { $runAppendLogs = $Config.AppendLogs }

    $rcParams = Build-RobocopyParams -Source $Source -Dest $Dest -CustomOpts $CustomOpts -IsDryRun $IsDryRun -Mode $Name -ForceBackup $runForceBackup
    if ($runAppendLogs) { $rcParams += "/LOG+:$logFile" } else { $rcParams += "/LOG:$logFile" }
    $rcParams += "/TEE"  # Output to console AND log file
    # Progress tracking variables
    $totalDirs = 0
    $totalFiles = 0
    $copiedFiles = 0
    $copiedBytes = '0'
    $skippedFiles = 0
    $failedFiles = 0
    $extraFiles = 0
    $progressActive = $false

    # Handle preview with command printing
    if ($PrintCommand.IsPresent) {
        # Format command for display
        $parts = $rcParams | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
        $cmd = "robocopy " + ($parts -join ' ')
        Write-Host "Robocopy command:" -ForegroundColor Cyan
        Write-Host $cmd -ForegroundColor White
        
        # Return a minimal result with proper ISO 8601 formatted dates
        return @{ 
            Name        = $Name
            ExitCode   = 0 
            Success    = $true
            Source     = $Source
            Destination = $Dest
            StartTime  = $startTime.ToString('o')  # ISO 8601
            Duration   = [TimeSpan]::FromSeconds(0).ToString('c')  # ISO 8601 Duration format
            LogFile    = $logFile
            IsDryRun   = $IsDryRun
            LastRun    = (Get-Date).ToString('o')
            TotalDirs  = $totalDirs
            TotalFiles = $totalFiles
            CopiedFiles = $copiedFiles
            CopiedBytes = $copiedBytes
            SkippedFiles = $skippedFiles
            FailedFiles = $failedFiles
            ExtraFiles  = $extraFiles
        }
    }
    
    # Progress tracking variables - initialize before early returns
    $totalDirs = 0
    $totalFiles = 0
    $copiedFiles = 0
    $copiedBytes = '0'
    $skippedFiles = 0
    $failedFiles = 0
    $extraFiles = 0
    $progressActive = $false
    
    # Always initialize start time to ensure it's available
    $startTime = Get-Date
    $duration = [TimeSpan]::Zero

    # For PrintCommand only, show command and return early with minimal result
    if ($PrintCommand.IsPresent) {
        $parts = $rcParams | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
        $cmd = "robocopy " + ($parts -join ' ')
        Write-Host "Robocopy command:" -ForegroundColor Cyan
        Write-Host $cmd -ForegroundColor White
        # Include start time and duration in preview result to avoid DateTime parsing errors
        $duration = (Get-Date) - $startTime
        return @{ 
            Name        = $Name
            ExitCode   = 0 
            Success    = $true
            Source     = $Source
            Destination = $Dest
            IsDryRun   = $IsDryRun
            StartTime  = $startTime
            Duration   = $duration
        }
    }
    
    # Run robocopy and display live output by tailing the log file
    # Start-Process accepts an array for -ArgumentList. Use the local $rcParams to avoid clobbering automatic $args.
    $process = Start-Process -FilePath 'robocopy.exe' `
                            -ArgumentList $rcParams `
                            -NoNewWindow `
                            -PassThru

    # Start a background job to tail the log file. We'll Receive-Job periodically to stream new lines.
    $tailJob = $null
    if (Test-Path $logFile) {
        # If the log already exists, start tailing it; otherwise start tailing once it's created.
        $tailJob = Start-Job -ScriptBlock { param($f) Get-Content -Path $f -Wait -Tail 0 } -ArgumentList $logFile
    }

    # Monitor progress while process runs and stream tailed log lines
    $checkInterval = 1000  # milliseconds
    $lastLogSize = 0
    $idleStart = $null
    $watchdogTimeout = [TimeSpan]::FromMinutes([double]$Config.WatchdogTimeoutMin)
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds $checkInterval

        # Ensure tail job is started once the log file exists
        if (-not $tailJob -and (Test-Path $logFile)) {
            $tailJob = Start-Job -ScriptBlock { param($f) Get-Content -Path $f -Wait -Tail 0 } -ArgumentList $logFile
        }

        # Stream any new lines from the tail job
        if ($tailJob) {
            $out = Receive-Job -Job $tailJob -Keep
            if ($out) { foreach ($line in $out) { Write-Host $line } }
        }

        # Watchdog: check log file growth as a proxy for progress
        if (Test-Path $logFile) {
            $size = (Get-Item $logFile).Length
            if ($size -gt $lastLogSize) {
                $lastLogSize = $size
                $idleStart = $null
            }
            else {
                if (-not $idleStart) { $idleStart = Get-Date }
                else {
                    $idle = (Get-Date) - $idleStart
                    if ($Config.WatchdogEnabled -and $idle -gt $watchdogTimeout) {
                        Write-Status "No log activity for $($idle.TotalMinutes) minutes — aborting Robocopy" -Level Error
                        try { $process.Kill() } catch {}
                        break
                    }
                }
            }
        }

    # Update status with elapsed time from known timestamps
    $elapsed = (Get-Date) - $startTime
    $status = "Elapsed: $($elapsed.ToString('hh\:mm\:ss')) | Scanning..."
    if (-not $progressActive) { Write-Progress -Activity $Name -Status $status }
    }

    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $duration = (Get-Date) - $startTime  # Calculate final duration

    Write-Progress -Activity $Name -Completed

    # Drain any remaining tailed output
    if ($tailJob) {
        $out = Receive-Job -Job $tailJob -Keep
        if ($out) { foreach ($line in $out) { Write-Host $line } }
        Stop-Job -Job $tailJob -ErrorAction SilentlyContinue
        Remove-Job -Job $tailJob -Force -ErrorAction SilentlyContinue
    }
    
    # Parse the log file for statistics
    if (Test-Path $logFile) {
        $logContent = Get-Content $logFile -Raw
        
        # Extract statistics from log file
        # Format: Total Copied Skipped Mismatch FAILED Extras
        if ($logContent -match 'Dirs\s*:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
            $totalDirs = [int]$matches[1]
        }
        
        # Parse Files line
        # Format: Total Copied Skipped Mismatch FAILED Extras
        #         [1]   [2]    [3]     [4]      [5]    [6]
        if ($logContent -match 'Files\s*:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
            $totalFiles = [int]$matches[1]    # Total
            $copiedFiles = [int]$matches[2]   # Copied
            $skippedFiles = [int]$matches[3]  # Skipped
            # $matches[4] is Mismatch
            $failedFiles = [int]$matches[5]   # FAILED (column 5)
            $extraFiles = [int]$matches[6]    # Extras (column 6)
        }
        
        # Parse Bytes line, safely defaulting if no match
        if ($logContent -match 'Bytes\s*:\s*([\d\.]+(?:\s*[kmgt])?)\s+([\d\.]+(?:\s*[kmgt])?|-)') {
            $copiedBytes = if ($matches[2] -eq '-') { '0' } else { $matches[2].Trim() }
        }

        # Parse Times line but ignore it - we'll use process duration instead
        if ($logContent -match 'Times\s*:\s*([^\r\n]+)') {
            # Times from the log file may contain dashes, so we use our own duration calculation
        }

        # Started/Ended times are already parsed by Get-Date when we started the process
        # No need to parse from log since we track our own start/end times
    }
    

    # If failures occurred and VSS fallback was requested, attempt snapshot and re-run
    if ($failedFiles -gt 0 -and $VssFallback.IsPresent -and -not $IsDryRun) {
        Write-Status "Detected $failedFiles failed files; attempting VSS fallback..." -Level Warning
        $vssResult = Invoke-VssFallbackAndRerun -OriginalSource $Source -Dest $Dest -Name $Name -CustomOpts $CustomOpts -IsDryRun $IsDryRun
        if ($vssResult) { Write-Status "VSS fallback completed with exit code $($vssResult.ExitCode)" -Level Info }
    }
    
    # Build result object
    $result = @{
        Name          = $Name
        ExitCode      = $exitCode
        Success       = ($exitCode -lt 8)
        Source        = $Source
        Destination   = $Dest
        StartTime     = $startTime
        Duration      = $duration
        TotalDirs     = $totalDirs
        TotalFiles    = $totalFiles
        CopiedFiles   = $copiedFiles
        CopiedBytes   = $copiedBytes
        SkippedFiles  = $skippedFiles
        FailedFiles   = $failedFiles
        ExtraFiles    = $extraFiles
        LogFile       = $logFile
        IsDryRun      = $IsDryRun
    }
    
    # Display summary
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " SUMMARY" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Duration:       $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor White
    Write-Host "Total Files:    $totalFiles" -ForegroundColor White
    Write-Host "Copied:         $copiedFiles" -ForegroundColor Green
    Write-Host "Skipped:        $skippedFiles" -ForegroundColor Yellow
    Write-Host "Failed:         $failedFiles" -ForegroundColor $(if($failedFiles -gt 0){'Red'}else{'Green'})
    Write-Host "Extras:         $extraFiles" -ForegroundColor $(if($extraFiles -gt 0){'Cyan'}else{'White'})
    Write-Host "Data Copied:    $copiedBytes" -ForegroundColor White
    Write-Host "Exit Code:      $exitCode" -ForegroundColor $(if($exitCode -lt 8){'Green'}else{'Red'})
    Write-Host "Status:         $(Get-RobocopyStatus $exitCode)" -ForegroundColor $(if($exitCode -lt 8){'Green'}else{'Red'})
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    return $result
}

# Helper to attempt VSS fallback when failed files are detected
function Invoke-VssFallbackAndRerun {
    param(
        [string]$OriginalSource,
        [string]$Dest,
        [string]$Name,
        [string]$CustomOpts,
        [bool]$IsDryRun
    )

    Write-Status "Attempting VSS fallback: creating snapshot of source volume" -Level Info
    $vol = (Get-Item $OriginalSource).PSDrive.Root
    $shadow = New-ShadowCopy -Volume $vol
    if (-not $shadow) {
        Write-Status "VSS snapshot creation failed" -Level Error
        return $null
    }

    try {
        # Map OriginalSource into shadow path. This is a simplification; ensure paths line up.
        $relative = $OriginalSource.Substring($vol.Length).TrimStart('\')
        $shadowSource = Join-Path $shadow $relative

        Write-Status "Re-running Robocopy against shadow path: $shadowSource" -Level Info
        $shadowLog = Join-Path $LogDir "$Name`_shadow_$Timestamp.log"
        $rcParams2 = Build-RobocopyParams -Source $shadowSource -Dest $Dest -CustomOpts $CustomOpts -IsDryRun $IsDryRun -Mode $Name -ForceBackup $Config.ForceBackup
        if ($Config.AppendLogs -or $AppendLogs.IsPresent) { $rcParams2 += "/LOG+:$shadowLog" } else { $rcParams2 += "/LOG:$shadowLog" }
        $rcParams2 += "/TEE"

        $process2 = Start-Process -FilePath 'robocopy.exe' -ArgumentList $rcParams2 -NoNewWindow -PassThru
        $process2.WaitForExit()
        $exit2 = $process2.ExitCode

        Write-Status "VSS re-run exit code: $exit2" -Level Info

        return @{ ExitCode = $exit2 }
    }
    finally {
        Remove-ShadowCopy
    }
}

function Get-RobocopyStatus {
    param([int]$ExitCode)
    
    switch ($ExitCode) {
        0 { return "No changes needed" }
        1 { return "Files copied successfully" }
        2 { return "Extra files/dirs detected" }
        3 { return "Files copied, extras detected" }
        {$_ -ge 4 -and $_ -le 7} { return "Mismatches/retries - review log" }
        {$_ -ge 8} { return "FAILURES OCCURRED" }
        default { return "Unknown status" }
    }
}

function Save-State {
    param([hashtable]$Result)
    
    $state = @{
        LastRun     = Get-Date -Format 'o'
        LastMode    = $Result.Name
        LastSuccess = $Result.Success
        History     = @()
    }
    
    # Load existing state
    if (Test-Path $StateFile) {
        $existing = Get-Content $StateFile -Raw | ConvertFrom-Json
        $state.History = @($existing.History) + @($Result)
    }
    else {
        $state.History = @($Result)
    }
    
    $state | ConvertTo-Json -Depth 10 | Set-Content $StateFile
}

function Send-EmailNotification {
    param([hashtable]$Result)
    
    if (-not $Config.SendEmail) { return }
    if ($Result.Success -and -not $Config.EmailOnSuccess) { return }
    if (-not $Result.Success -and -not $Config.EmailOnFailure) { return }
    
    $subject = "Robocopy Migration - $($Result.Name) - $(if($Result.Success){'SUCCESS'}else{'FAILED'})"
    
    $body = @"
<html>
<body style='font-family: Arial, sans-serif;'>
<h2 style='color: $(if($Result.Success){'green'}else{'red'});'>$($Result.Name) - $(if($Result.Success){'SUCCESS'}else{'FAILED'})</h2>
<table border='1' cellpadding='5' cellspacing='0' style='border-collapse: collapse;'>
<tr><td><b>Source:</b></td><td>$($Result.Source)</td></tr>
<tr><td><b>Destination:</b></td><td>$($Result.Destination)</td></tr>
<tr><td><b>Start Time:</b></td><td>$($Result.StartTime)</td></tr>
<tr><td><b>Duration:</b></td><td>$($Result.Duration.ToString('hh\:mm\:ss'))</td></tr>
<tr><td><b>Files Copied:</b></td><td style='color: green;'>$($Result.CopiedFiles)</td></tr>
<tr><td><b>Files Skipped:</b></td><td style='color: orange;'>$($Result.SkippedFiles)</td></tr>
<tr><td><b>Files Failed:</b></td><td style='color: red;'>$($Result.FailedFiles)</td></tr>
<tr><td><b>Extra Files:</b></td><td style='color: blue;'>$($Result.ExtraFiles)</td></tr>
<tr><td><b>Exit Code:</b></td><td>$($Result.ExitCode)</td></tr>
<tr><td><b>Log File:</b></td><td>$($Result.LogFile)</td></tr>
</table>
</body>
</html>
"@
    
    try {
        # Build System.Net.Mail objects (works in .NET Framework used by PS5.1 and in .NET on PS7 on Windows)
        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = $Config.EmailFrom
        foreach ($recipient in $Config.EmailTo) { $mail.To.Add($recipient) }
        $mail.Subject = $subject
        $mail.Body = $body
        $mail.IsBodyHtml = $true

        $smtp = New-Object System.Net.Mail.SmtpClient($Config.SmtpServer, [int]$Config.SmtpPort)
        $smtp.EnableSsl = [bool]$Config.SmtpUseSsl

        # Credentials: prefer PSCredential, fall back to explicit user/password
        if ($Config.SmtpCredential -and $Config.SmtpCredential -is [System.Management.Automation.PSCredential]) {
            $smtp.Credentials = $Config.SmtpCredential.GetNetworkCredential()
        }
        elseif ($Config.SmtpUser -and $Config.SmtpPassword) {
            $smtp.Credentials = New-Object System.Net.NetworkCredential($Config.SmtpUser, $Config.SmtpPassword)
        }

        $smtp.Send($mail)

        Write-Status "Email notification sent" -Level Success
    }
    catch {
        Write-Status "Failed to send email: $($_.Exception.Message)" -Level Warning
    }
}

function Test-ReconcileRun {
    if (-not (Test-Path $StateFile)) {
        return $false
    }
    
    $state = Get-Content $StateFile -Raw | ConvertFrom-Json
    return ($state.History | Where-Object { $_.Name -eq 'RECONCILE' }).Count -gt 0
}

# =========================================
# MAIN EXECUTION
# =========================================

try {
    Write-Header "Robocopy Migration Tool - $Mode"
    
    # Prerequisites
    Test-Prerequisites
    
    $isDryRun = $Preview.IsPresent
    $result = $null
    
    switch ($Mode) {
        'SEED' {
            $result = Invoke-RobocopyWithProgress -Name 'SEED' `
                                                   -Source $Config.Source `
                                                   -Dest $Config.Destination `
                                                   -CustomOpts '/XO' `
                                                   -IsDryRun $isDryRun
        }
        
        'SYNC' {
            $result = Invoke-RobocopyWithProgress -Name 'SYNC' `
                                                   -Source $Config.Source `
                                                   -Dest $Config.Destination `
                                                   -CustomOpts '/XO' `
                                                   -IsDryRun $isDryRun
        }
        
        'RECONCILE' {
            Write-Status "RECONCILE copies newer/extra files from DEST -> SOURCE" -Level Warning
            Write-Status "This prevents data loss but requires SOURCE to be writable" -Level Warning
            
            if (-not $isDryRun) {
                $response = Read-Host "`nContinue? (y/n)"
                if ($response -ne 'y') {
                    Write-Status "Operation cancelled by user" -Level Warning
                    exit 0
                }
            }
            
            $result = Invoke-RobocopyWithProgress -Name 'RECONCILE' `
                                                   -Source $Config.Destination `
                                                   -Dest $Config.Source `
                                                   -CustomOpts '/XO' `
                                                   -IsDryRun $isDryRun
        }
        
        'MIRROR' {
            # Safety check
            if (-not (Test-ReconcileRun)) {
                Write-Status "WARNING: RECONCILE has not been run!" -Level Error
                Write-Status "Run RECONCILE first to prevent data loss" -Level Error
                
                $response = Read-Host "`nContinue anyway? (y/n)"
                if ($response -ne 'y') {
                    Write-Status "Operation cancelled" -Level Warning
                    exit 0
                }
            }
            
            if (-not $Confirm -and -not $isDryRun) {
                Write-Status "ERROR: MIRROR requires -Confirm flag" -Level Error
                Write-Status "Run with -Preview first to see changes" -Level Info
                Write-Status "Then run with -Confirm to execute" -Level Info
                exit 1
            }
            
            Write-Status "MIRROR will DELETE files at destination not in source!" -Level Warning
            
            $result = Invoke-RobocopyWithProgress -Name 'MIRROR' `
                                                   -Source $Config.Source `
                                                   -Dest $Config.Destination `
                                                   -CustomOpts '/MIR' `
                                                   -IsDryRun $isDryRun
        }
    }
    
    # Save state and notify
    if ($result -and -not $isDryRun) {
        Save-State -Result $result
        Send-EmailNotification -Result $result
    }
    
    # Exit with appropriate code
    if ($result.Success) {
        Write-Status "Operation completed successfully" -Level Success
        exit 0
    }
    else {
        Write-Status "Operation completed with errors - review log" -Level Error
        exit $result.ExitCode
    }
}
catch {
    Write-Status "FATAL ERROR: $_" -Level Error
    Write-Status $_.ScriptStackTrace -Level Error
    exit 99
}
finally {
    # Cleanup
    Get-EventSubscriber | Unregister-Event -Force -ErrorAction SilentlyContinue
}

# VSS helpers using DiskShadow.exe
function New-ShadowCopy {
    param([string]$Volume)
    # Returns the shadow copy device name, e.g. \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1
    $script = @"
SET CONTEXT PERSISTENT
ADD VOLUME $Volume ALIAS MyShadow
CREATE
EXPOSE %MyShadow% Z:
"@

    $tmp = [IO.Path]::GetTempFileName()
    $tmpScript = "$tmp.txt"
    $script | Set-Content -Path $tmpScript -NoNewline

    try {
        & diskshadow.exe /s $tmpScript 2>&1 | Out-Null
        # Read output to find the shadow device
        $out = & diskshadow.exe /s $tmpScript
        # Parse exposed device mapping from output
        if ($out -match "EXPOSE:.*(HarddiskVolumeShadowCopy\d+)") {
            $copy = $matches[1]
            # Build GLOBALROOT path
            $gpath = "\\?\\GLOBALROOT\\Device\\$copy"
            return $gpath
        }
        return $null
    }
    finally {
        Remove-Item $tmpScript -ErrorAction SilentlyContinue
    }
}

function Remove-ShadowCopy {
    param([string]$AliasName = 'MyShadow')
    $script = "DELETE SHADOWS ALL"
    $tmpScript = [IO.Path]::GetTempFileName() + '.txt'
    $script | Set-Content -Path $tmpScript -NoNewline
    try { & diskshadow.exe /s $tmpScript | Out-Null }
    finally { Remove-Item $tmpScript -ErrorAction SilentlyContinue }
}



