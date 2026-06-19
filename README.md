# Video Encoding Optimizer with Preserved Perceptual Quality

Re-encodes videos to [SVT-AV1](https://gitlab.com/AOMediaCodec/SVT-AV1) while preserving perceptual quality (SSIM + VMAF gates) and avoiding pointless re-encodes when compression gains are too small.

## Features

- Recursively scans a source directory for video files
- Skips files already encoded with modern codecs (`av1`, `hevc`, `vp9`)
- Samples a clip (default: 30s from middle, full timeline if duration <= 60s)
- Tunes CRF/preset to meet perceptual targets:
  - SSIM threshold (default `0.98`)
  - VMAF threshold (default `93.0`)
- Requires sample compression ratio to beat threshold (default `0.80`)
- Encodes full output to MKV + Opus audio if sample passes
- Preserves original file in place
- Supports dry-run mode
- Optional CSV reporting

## Requirements

Required commands:

- `bash` (4+ recommended)
- `ffmpeg`
- `ffprobe`
- `jq`
- `bc`
- `file`
- `mktemp`
- `find`
- GNU `stat` (`--format` support)

### FFmpeg capability requirements

Your ffmpeg build must include:

- `libsvtav1` encoder
- `libvmaf` filter
- `libopus` audio encoder

Quick checks:

```bash
ffmpeg -hide_banner -encoders | grep -E 'libsvtav1|libopus'
ffmpeg -hide_banner -filters  | grep libvmaf
```

## Quick Start

```bash
chmod +x ./video_normalize.sh
./video_normalize.sh --verbose /path/to/videos
```

## Usage

```text
./video_normalize.sh [options] [SOURCE_DIR]
```

If `SOURCE_DIR` is omitted, defaults to current directory (`.`).

### Options

- `-h, --help`  
  Show help and exit.
- `-v, --verbose`  
  Enable verbose logging.
- `--dry-run`  
  Scan and analyze, but do not write encoded output files.
- `--report <path>`  
  Write CSV report to file.
- `--vmaf-threshold <float>`  
  Minimum acceptable VMAF score. Default: `93.0`
- `--ssim-threshold <float>`  
  Minimum acceptable SSIM score. Default: `0.98`
- `--size-ratio-threshold <float>`  
  Maximum sample encoded/original size ratio. Default: `0.80`
- `--clip-length <seconds>`  
  Sample clip duration for optimization. Default: `30`
- `--start-crf <int>`  
  Initial CRF for search. Default: `32`
- `--min-crf <int>`  
  Lower CRF floor for search. Default: `18`
- `--preset <int>`  
  Initial SVT-AV1 preset. Default: `4`

## How It Works

1. Discover files recursively under source directory.
2. Keep only files with `video/*` MIME and a valid video stream.
3. Skip if output `*.mkv` already exists (for non-MKV sources).
4. Skip if source codec is already efficient (`av1`, `hevc`, `vp9`).
5. Extract reference and baseline sample clips.
6. Encode sample with AV1 and iterate CRF/preset until quality gates pass (or CRF floor reached).
7. Check sample compression ratio threshold.
8. If passed, encode full source to MKV (AV1 video + Opus audio).
9. Record status/metrics to CSV report (if enabled).

## Output Behavior

- Output file path: same directory, same basename, `.mkv` extension.
- Originals are never deleted.
- Existing target `.mkv` causes skip (except when source itself is `.mkv`, which is evaluated).

## CSV Report Format

When `--report` is provided, script writes:

```text
source_file,codec,duration,action,status,crf,preset,vmaf,ssim,sample_ratio,final_ratio,message
```

Status values include:

- `skipped_nonvideo`
- `skipped_no_video_stream`
- `skipped_existing_output`
- `skipped_modern_codec`
- `dry_run`
- `aborted_ratio`
- `encoded`
- `error`

## Troubleshooting

- `Required command not found`: install the missing dependency.
- `Parsed metrics are not numeric` / `Metric extraction failed`:
  - verify ffmpeg has `libvmaf`
  - test filters manually on a known-good short clip
- `Optimization pass encoding failed`:
  - verify ffmpeg has `libsvtav1`
  - reduce preset aggressiveness (`--preset 4` or lower number)
- Script works on Linux but not macOS:
  - install GNU coreutils and ensure GNU `stat` is used.

## Platform Compatibility

This script is written for Linux/GNU userland assumptions.  
On macOS/BSD, compatibility adjustments may be needed (especially `stat` flags).

## Safety Notice

This software is provided without warranty.  
Always keep backups and verify encoded results before deleting originals.
