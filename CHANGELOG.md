# Changelog

All notable changes to the Robocopy Migration Tool will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2025-10-16

### Added
- Configurable retry settings for network paths
- Separate retry configurations for local and network paths
- Validation system for retry settings
- Maximum limits for retry values
- Comprehensive documentation for retry configuration

### Changed
- Improved network path handling
- Adjusted default retry values for better reliability
- Enhanced path validation for UNC paths
- Updated script documentation with retry settings guidance

### Security
- Added maximum limits to prevent excessive retries
- Improved network path validation

## [1.0.0] - 2025-10-16

### Added
- Initial release of Robocopy Migration Tool
- Structured migration workflow (SEED, SYNC, RECONCILE, MIRROR)
- Real-time progress tracking
- Email notifications
- VSS fallback support
- Bandwidth throttling
- Multi-threaded operations
- ACL preservation options
- Detailed logging
- Preview mode
- Watchdog for stalled operations

### Security
- Administrator privilege detection
- Write access verification
- Mirror mode safeguards

## [Unreleased]
### Planned Features
- Enhanced error reporting
- Parallel processing improvements
- Network resilience enhancements
- Additional notification options
- Performance optimization