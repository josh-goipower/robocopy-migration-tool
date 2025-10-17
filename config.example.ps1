# Example configuration for Robocopy Migration Tool
# Copy this file and modify according to your needs

$Config = @{
    Source              = 'C:\Source-Data'              # Source path
    Destination         = 'D:\Destination-Data'         # Destination path
    LogRoot            = 'C:\Logs\Migration'           # Log directory
    Threads            = 16                           # Number of threads (adjust based on system capabilities)
    PreserveACL        = $true                       # Copy security settings
    BandwidthThrottle  = 0                          # Milliseconds between packets (0 = no throttle)
    
    # Exclude patterns - uncomment and modify as needed
    ExcludeDirs        = @(
        # 'Temp'
        # '~snapshot'
        # 'System Volume Information'
    )
    ExcludeFiles       = @(
        # '*.tmp'
        # '*.bak'
        # 'desktop.ini'
    )
    
    # Email notifications - uncomment and configure to enable
    SendEmail          = $false
    SmtpServer         = 'smtp.company.com'
    EmailFrom          = 'migrations@company.com'
    EmailTo            = @('admin@company.com')
    SmtpPort          = 25
    SmtpUseSsl        = $false
    SmtpCredential    = $null  # Use Get-Credential at runtime
    
    # Watchdog settings
    WatchdogEnabled    = $true
    WatchdogTimeoutMin = 15    # Minutes before timeout
}