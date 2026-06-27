# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.2] - 2026-06-27

### Fixed

- Interrupt signal not caught by the `find` process. Now the script can kill all started processes.
- Improve ffmpeg decoder/encoder detection.

## [1.0.1] - 2026-06-27

### Fixed

- Potential security vulnerability fixed
- Better input validation for safety

## [1.0.0] - 2026-06-27

### Added

- Comprehensive test suite with smoke tests covering CLI validation, report generation, and safety features
- Version string and `--version` flag to display version information
- Atomic file encoding pattern: encode to temporary file in output directory, then atomically move to final location
- Symlink detection and rejection at final output path (security hardening)
- Extended cleanup trap to remove orphaned temporary files on script interruption
- Better error handling for non-existent source directories with early validation

### Fixed

- **Critical Security Issue:** TOCTOU (Time-of-check-Time-of-use) race condition eliminated. Previously, an attacker with local filesystem access could create a symlink between the existence check and the encode write, causing arbitrary file overwrite. Now uses atomic rename (`mv -n`) with pre-move symlink validation.
- **Critical Reliability Issue:** Corrupted or partial output files from failed encodes now trigger cleanup instead of blocking future retries. Added integrity validation before skipping existing outputs.
- **High Reliability Issue:** Silent failures on invalid source directories now properly reported. Added upfront directory existence check and explicit error handling for `find` failures.
- Typos in README documentation (noticy → notice, in to → into, avaiable → available, vmafi → vmaf, suppport → support)
- Grammar issues in README (is → are for plural subjects)
- Awkward phrasing in CPU requirement documentation

### Changed

- Full video encoding now uses secure two-stage process: temporary file creation in output directory, then atomic move (prevents TOCTOU attacks and disk space issues on RAM-backed tmpfs)
- Improved error messages for encoding failures
- Better cleanup on partial encode failures

### Security

- Eliminated TOCTOU race condition on final output path
- Added explicit symlink detection and rejection
- Temporary files properly tracked and cleaned up on interrupt/error
- All file operations use proper quoting for paths with spaces

### Documentation

- Expanded README with detailed dependency information for each tool
- Added documentation of known limitations (2x disk space requirement, audio reencoding, CPU requirements)
- Added system requirements and testing information
- Clarified exit codes

## Pre-1.0 Development

### Initial Development
- Initial project structure and core video normalization functionality
- VMAF and SSIM quality metric integration
- SVT-AV1 codec support with quality preservation
- Matroska (MKV) container format output
- Sample clip testing for optimization
- Size ratio threshold for determining encoding viability
- Codec detection to skip already-efficient formats (H.265/HEVC, VP9, AV1)

### Robustness & Portability
- Robustness and portability fixes for shell compatibility
- Filename handling improvements for special characters
- Work directory cleanup between iterations
- Iterative codec optimization with dynamic parameter tuning
- CRF (Constant Rate Factor) adjustment logic
- CLIP_START and CLIP_LENGTH calculation improvements
- Audio reencoding to Opus codec
- CSV report generation with formula-injection protection
- Proper error handling and exit codes
- Edge case handling for various video formats
- Hardware acceleration experimentation and removal (determined unusable)

