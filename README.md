# Robocopy Migration Tool

A PowerShell-based wrapper for Robocopy that provides structured migration workflows with progress tracking, email notifications, and detailed reporting.

## Features

- **Structured Migration Workflow**
  - SEED: Initial copy with existing files skipped
  - SYNC: Update changed files while preserving existing
  - RECONCILE: Back-sync newer files from destination to source
  - MIRROR: Full synchronization (with safeguards)

- **Advanced Features**
  - Real-time progress tracking
  - Detailed logging
  - Email notifications
  - Backup mode support
  - Multi-threaded operations
  - VSS fallback for locked files
  - Bandwidth throttling
  - ACL preservation options

- **Safety Features**
  - Dry-run preview mode
  - Mirror mode safeguards
  - Write access verification
  - Administrator privilege detection
  - Watchdog for stalled operations

## Requirements

- Windows OS (Windows 7/Server 2008 R2 or later)
- PowerShell 5.1 or later
- Administrator rights (recommended)

## Usage

### Basic Commands

```powershell
# Initial copy (dry run)
.\Robocopy_v6.ps1 -Mode SEED -Preview

# Perform initial copy
.\Robocopy_v6.ps1 -Mode SEED

# Sync changes
.\Robocopy_v6.ps1 -Mode SYNC

# Back-sync newer files from destination
.\Robocopy_v6.ps1 -Mode RECONCILE

# Mirror source to destination (requires confirmation)
.\Robocopy_v6.ps1 -Mode MIRROR -Confirm
```

### Common Options

- `-Preview`: Dry-run mode (no changes made)
- `-PrintCommand`: Display the constructed Robocopy command
- `-ForceBackup`: Use backup mode (/B) instead of restart mode (/Z)
- `-AppendLogs`: Append to existing log files instead of creating new ones
- `-VssFallback`: Try VSS snapshot if files are locked
- `-Confirm`: Required for MIRROR mode execution

### Configuration

Edit the `$Config` hashtable in the script to set:

```powershell
$Config = @{
    Source              = 'C:\RC-Source'              # Source path
    Destination         = 'C:\RC-Destination'         # Destination path
    LogRoot            = 'C:\Logs\RC_Test'           # Log directory
    Threads            = 32                          # Number of threads
    PreserveACL        = $true                      # Copy security settings
    BandwidthThrottle  = 0                          # Milliseconds between packets
    
    # Exclude patterns
    ExcludeDirs        = @()                        # e.g., @('Temp', '~snapshot')
    ExcludeFiles       = @()                        # e.g., @('*.tmp', '*.bak')
    
    # Email notifications
    SendEmail          = $false
    SmtpServer         = 'smtp.company.com'
    EmailFrom          = 'migrations@company.com'
    EmailTo            = @('admin@company.com')
    SmtpPort          = 25
    SmtpUseSsl        = $false
    
    # Watchdog settings
    WatchdogEnabled    = $true
    WatchdogTimeoutMin = 15                         # Minutes before timeout
}
```

## Migration Workflow

1. **SEED Mode**
   - Initial copy operation
   - Skips existing files at destination
   - Use `-Preview` first to see what will be copied

2. **SYNC Mode**
   - Updates changed files
   - Preserves existing files at destination
   - Good for incremental updates

3. **RECONCILE Mode**
   - Copies newer files from destination back to source
   - Prevents data loss before mirror
   - Required before MIRROR mode

4. **MIRROR Mode**
   - Full synchronization
   - Deletes files at destination not in source
   - Requires `-Confirm` flag
   - Recommended to run RECONCILE first

## Logging and Monitoring

- Logs are stored in the configured `LogRoot` directory
- Each operation creates a timestamped subfolder
- Detailed statistics are displayed after each run
- Email notifications can be configured for success/failure

## Advanced Usage

### Backup Mode

```powershell
# Force backup mode
.\Robocopy_v6.ps1 -Mode SYNC -ForceBackup

# Use VSS fallback for locked files
.\Robocopy_v6.ps1 -Mode SYNC -VssFallback
```

### Log Management

```powershell
# Append to existing logs
.\Robocopy_v6.ps1 -Mode SYNC -AppendLogs
```

### Command Preview

```powershell
# See the exact Robocopy command that will be used
.\Robocopy_v6.ps1 -Mode SEED -Preview -PrintCommand
```

## Error Handling

- Exit codes follow Robocopy conventions:
  - 0: No changes needed
  - 1: Files copied successfully
  - 2: Extra files/directories detected
  - 3: Files copied, extras detected
  - 4-7: Mismatches present
  - ≥8: At least one failure occurred

## Best Practices

1. Always run with `-Preview` first
2. Use RECONCILE before MIRROR
3. Monitor logs for unexpected behaviors
4. Configure email notifications for unattended operations
5. Run with administrator rights when copying system files
6. Set appropriate thread count for your environment

## Troubleshooting

- Check log files for detailed error information
- Verify write permissions on destination
- Ensure network connectivity for remote paths
- Monitor system resources during large transfers
- Use `-PrintCommand` to verify Robocopy parameters

## Safety Features

The script includes several safety measures:

- Prevents MIRROR without confirmation
- Validates paths before copying
- Tests write access before operations
- Detects stalled operations
- Verifies administrator status