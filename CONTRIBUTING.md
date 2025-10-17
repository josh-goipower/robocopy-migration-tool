# Contributing to Robocopy Migration Tool

Thank you for considering contributing to the Robocopy Migration Tool! This document provides guidelines and information for contributors.

## Development Setup

1. Clone the repository:
   ```powershell
   git clone https://github.com/josh-goipower/robocopy-migration-tool.git
   cd robocopy-migration-tool
   ```

2. Create a feature branch:
   ```powershell
   git checkout -b feature/your-feature-name
   ```

## Coding Standards

- Follow PowerShell best practices and style guidelines
- Use clear, descriptive variable and function names
- Include comments for complex logic
- Add error handling for robustness
- Update documentation when adding features

## Testing

Before submitting changes:

1. Test with `-Preview` mode first
2. Test all migration modes: SEED, SYNC, RECONCILE, MIRROR
3. Verify error handling
4. Check log file generation
5. Test with various parameter combinations

## Pull Request Process

1. Update documentation to reflect changes
2. Add your changes to CHANGELOG.md
3. Ensure all tests pass
4. Submit PR against the `main` branch
5. Include clear description of changes

## Feature Requests

Open an issue with:
- Clear description of the feature
- Use case/motivation
- Any potential implementation details

## Bug Reports

Include:
- PowerShell version (`$PSVersionTable`)
- Windows version
- Script version
- Steps to reproduce
- Expected vs actual behavior
- Log files if applicable

## Code Review Process

All submissions require review. We use GitHub pull requests for this purpose.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.