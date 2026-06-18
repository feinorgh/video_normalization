#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="."
VERBOSE=0
POSITIONAL_ARGS=()
WORK_DIR=""
VMAF_THRESHOLD="93.00"
SSIM_THRESHOLD="0.98"
SIZE_RATIO_THRESHOLD="0.80"
HWACCEL_DEVICE="/dev/dri/renderD128"
HWACCEL_AVAILABLE=0

cleanup() {
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        rm --recursive "$WORK_DIR"
    fi
}

trap cleanup TERM EXIT

print_verbose() {
    if [ "$VERBOSE" -eq 0 ]; then
        return
    fi
    printf "%s\n" "$*"
}

parse_options() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            --*|-*)
                printf "ERROR: Unknown option '%s'\n" "$1" >&2
                exit 1
                ;;
            *)
                POSITIONAL_ARGS+=("$1")
                shift
                ;;
        esac
    done
    set -- "${POSITIONAL_ARGS[@]:-}"
}

check_hardware_acceleration() {
    # 1. Verify that the FFmpeg binary itself was built with vaapi support enabled
    if ffmpeg -hide_banner -hwaccels 2>/dev/null | grep -q "vaapi"; then
        # 2. Dry-run hardware context using an internal 1-frame canvas loopback
        if ffmpeg -loglevel error -init_hw_device vaapi=intel:"$HWACCEL_DEVICE" -f lavfi -i color=c=black:s=64x64 -frames:v 1 -f null - 2>/dev/null; then
            print_verbose "SUCCESS: Hardware acceleration via VA-API detected and verified on DRM node."
            HWACCEL_AVAILABLE=1
            return 0
        fi
    fi
    print_verbose "INFO: VA-API hardware acceleration unavailable. Defaulting to software pipelines."
    HWACCEL_AVAILABLE=0
}

reencode_video() {
    local VIDEO_FILE VIDEO_FILE_NAME DIMENSIONS DURATION ORIGINAL_SIZE ENCODED_SIZE SIZE_RATIO
    VIDEO_FILE="$1"
    DIMENSIONS="$2"
    DURATION="$3"

    # Core loop variables initialization
    local CRF=32
    local PRESET=4
    local FILM_GRAIN=0
    local SVT_AV1_TUNE=0
    local PIX_FMT="yuv420p10le"
    local CLIP_LENGTH="30.0"

    # FIXED: Combined flags syntax to prevent positional parsing shifts
    local -a FFMPEG_ARGS
    FFMPEG_ARGS=(-hide_banner -loglevel error -stats -fflags +genpts+igndts+discardcorrupt -err_detect ignore_err)

    WORK_DIR="$(mktemp --directory)"
    VIDEO_FILE_NAME="$(basename "$VIDEO_FILE").mkv"

    mkdir "$WORK_DIR/reference" || exit 1
    mkdir "$WORK_DIR/original" || exit 1

    # Temporal Midpoint Calculation
    if [ "$(echo "$DURATION <= 60.0" | bc --mathlib)" -eq 1 ]; then
        print_verbose "INFO: Duration <= 60s, processing whole timeline for sample."
    else
        local MIDDLE_POINT CLIP_START
        MIDDLE_POINT="$(echo "scale=2; $DURATION / 2.0" | bc --mathlib)"
        CLIP_START="$(echo "scale=2; $MIDDLE_POINT - ($CLIP_LENGTH / 2.0)" | bc --mathlib)"
        # Force a leading zero if bc outputs a raw decimal dot (e.g., .50 -> 0.50)
        if [[ "$CLIP_START" =~ ^\. ]]; then
            CLIP_START="0${CLIP_START}"
        fi
        FFMPEG_ARGS+=(-ss "$CLIP_START" -t "$CLIP_LENGTH")
    fi

    # Reference extractions
    if ! ffmpeg "${FFMPEG_ARGS[@]}" -i "$VIDEO_FILE" -c:v libx264 -crf 0 -preset ultrafast -an "$WORK_DIR/reference/$VIDEO_FILE_NAME"; then
        printf "ERROR: Could not extract reference clip\n" >&2
        cleanup && return 1
    fi

    if ! ffmpeg "${FFMPEG_ARGS[@]}" -i "$VIDEO_FILE" -c:v copy -an "$WORK_DIR/original/$VIDEO_FILE_NAME"; then
        printf "ERROR: Could not extract baseline clip\n" >&2
        cleanup && return 1
    fi
    ORIGINAL_SIZE=$(stat --format "%s" "$WORK_DIR/original/$VIDEO_FILE_NAME")

    local SRC_FRAMES
    SRC_FRAMES=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of default=nokey=1:noprint_wrappers=1 "$WORK_DIR/reference/$VIDEO_FILE_NAME")

    # --- START PARAMETER TUNING ENGINE LOOP ---
    local OPTIMIZED=false
    while [[ "$OPTIMIZED" == "false" ]]; do
        print_verbose "Testing Profiles -> CRF: $CRF | Preset: $PRESET | Film-Grain: $FILM_GRAIN"

        if ! SVT_LOG=1 ffmpeg -nostdin -hide_banner -loglevel error -stats -y -i "$WORK_DIR/reference/$VIDEO_FILE_NAME" \
            -c:v libsvtav1 -crf "$CRF" -preset "$PRESET" -pix_fmt "$PIX_FMT" \
            -svtav1-params tune=$SVT_AV1_TUNE:film-grain="$FILM_GRAIN" \
            -fps_mode passthrough -an "$WORK_DIR/candidate.mkv" < /dev/null; then
                printf "ERROR: Optimization pass encoding failed.\n" >&2
                cleanup && return 1
        fi

        local CND_FRAMES
        CND_FRAMES=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of default=nokey=1:noprint_wrappers=1 "$WORK_DIR/candidate.mkv")
        if [[ "$SRC_FRAMES" != "$CND_FRAMES" ]]; then
            printf "WARNING: Jitter detected. Normalizing timeline structures.\n" >&2
        fi

        # Evaluate Metrics
        local SSIM_LOG SSIM_SCORE VMAF_LOG VMAF_SCORE

        if [[ "$HWACCEL_AVAILABLE" -eq 1 ]]; then
            # Optimized Hardware-Accelerated Pathway
            SSIM_LOG="$(ffmpeg -nostdin -hide_banner -hwaccel vaapi=dri:"$HWACCEL_DEVICE" -hwaccel_output_format vaapi -i "$WORK_DIR/candidate.mkv" \
                -hwaccel vaapi -hwaccel_output_format vaapi -i "$WORK_DIR/reference/$VIDEO_FILE_NAME" \
                -filter_complex "[0:v]hwupload[cnd];[1:v]hwupload[ref];[cnd][ref]ssim" -f null - 2>&1 | grep -oE "All:[0-9.]+" || true)"
            VMAF_LOG="$(ffmpeg -nostdin -hide_banner -hwaccel vaapi=dri:"$HWACCEL_DEVICE" -hwaccel_output_format vaapi -i "$WORK_DIR/candidate.mkv" \
                -hwaccel vaapi -hwaccel_output_format vaapi -i "$WORK_DIR/reference/$VIDEO_FILE_NAME" \
                -filter_complex "[0:v]hwupload[cnd];[1:v]hwupload[ref];[cnd][ref]libvmaf=model=version=vmaf_v0.6.1" -f null - 2>&1)"
        else
            # Standard Software Fallback Pathway
            SSIM_LOG="$(ffmpeg -nostdin -hide_banner -i "$WORK_DIR/candidate.mkv" -i "$WORK_DIR/reference/$VIDEO_FILE_NAME" \
                -filter_complex "[0:v]setpts=N,setsar=1,format=yuv420p10le[distorted];[1:v]setpts=N,setsar=1,format=yuv420p10le[reference];[distorted][reference]ssim" -f null - 2>&1 | grep -oE "All:[0-9.]+" || true)"
            VMAF_LOG="$(ffmpeg -nostdin -hide_banner -i "$WORK_DIR/candidate.mkv" -i "$WORK_DIR/reference/$VIDEO_FILE_NAME" \
                -filter_complex "[0:v]setpts=N,setsar=1,format=yuv420p10le[distorted];[1:v]setpts=N,setsar=1,format=yuv420p10le[reference];[distorted][reference]libvmaf=model=version=vmaf_v0.6.1" -f null - 2>&1)"
        fi

        SSIM_SCORE=$(echo "$SSIM_LOG" | cut -d':' -f2)
        VMAF_SCORE=$(echo "$VMAF_LOG" | grep -oE "VMAF score: [0-9.]+" | awk '{print $3}' || true)

        local ssim_passes vmaf_passes
        ssim_passes=$(echo "$SSIM_SCORE >= $SSIM_THRESHOLD" | bc --mathlib)
        vmaf_passes=$(echo "$VMAF_SCORE >= $VMAF_THRESHOLD" | bc --mathlib)

        if [[ $ssim_passes -eq 1 ]] && [[ $vmaf_passes -eq 1 ]]; then
            if [[ "$(echo "$VMAF_SCORE > 96.5" | bc --mathlib)" -eq 1 && "$PRESET" -eq 4 ]]; then
                print_verbose "High metric headroom detected. Upgrading to Preset 5 for performance optimization."
                PRESET=5
                continue
            fi
            OPTIMIZED=true
        else
            if [[ "$CRF" -le 18 ]]; then
                printf "WARNING: Hit minimum quality boundary limit (CRF 18). Proceeding with forced configuration.\n" >&2
                OPTIMIZED=true
            else
                CRF=$((CRF - 2))
                PRESET=4
            fi
        fi
    done
    # --- END PARAMETER TUNING ENGINE LOOP ---

    ENCODED_SIZE=$(stat --format "%s" "$WORK_DIR/candidate.mkv")
    SIZE_RATIO="$(echo "scale=2; $ENCODED_SIZE / $ORIGINAL_SIZE" | bc --mathlib)"

    printf "Result Metrics -> VMAF: %s | SSIM: %s | Compression Ratio: %s\n" "$VMAF_SCORE" "$SSIM_SCORE" "$SIZE_RATIO"

    local size_passes
    size_passes=$(echo "$SIZE_RATIO <= $SIZE_RATIO_THRESHOLD" | bc --mathlib)

    if [[ $size_passes -eq 1 ]]; then
        local FINAL_OUTPUT="${VIDEO_FILE%.*}.mkv"
        printf "PROCEEDING TO MASTER FILE PROCESSING -> Target: %s (CRF: %d | Preset: %d)\n" "$FINAL_OUTPUT" "$CRF" "$PRESET"

        if ! SVT_LOG=1 ffmpeg -nostdin -hide_banner -loglevel error -stats -y \
            -fflags +genpts+igndts+discardcorrupt -err_detect ignore_err \
            -i "$VIDEO_FILE" \
            -c:v libsvtav1 -crf "$CRF" -preset "$PRESET" -pix_fmt "$PIX_FMT" \
            -svtav1-params tune=$SVT_AV1_TUNE:film-grain="$FILM_GRAIN" \
            -fps_mode passthrough \
            -c:a libopus -b:a 128k -vbr on -af aresample=async=1 \
            "$FINAL_OUTPUT"; then
                printf "CRITICAL ERROR: Processing failed on complete asset execution for %s\n" "$VIDEO_FILE" >&2
                cleanup && return 1
        fi

        # FIXED: Fast container-level metadata integrity check instead of full file decode pass
        if ffprobe -v error -show_entries format=duration "$FINAL_OUTPUT" > /dev/null; then
            local ORIGINAL_FULL_SIZE FINAL_ENCODED_SIZE FINAL_SIZE_RATIO
            ORIGINAL_FULL_SIZE="$(stat --format "%s" "$VIDEO_FILE")"
            FINAL_ENCODED_SIZE="$(stat --format "%s" "$FINAL_OUTPUT")"
            FINAL_SIZE_RATIO="$(echo "scale=2; $FINAL_ENCODED_SIZE / $ORIGINAL_FULL_SIZE" | bc --mathlib)"
            printf "SUCCESS: Asset deployment complete. Ratio achieved: %s\n" "$FINAL_SIZE_RATIO"
        else
            printf "WARNING: The final encoded file '%s' structural integrity verification failed.\n" "$FINAL_OUTPUT" >&2
        fi
    else
        printf "ABORT: Data optimization bounds not met (%s > %s). Original preserved.\n" "$SIZE_RATIO" "$SIZE_RATIO_THRESHOLD"
    fi

    cleanup
}

get_video_info() {
    local VIDEO_FILE VIDEO_INFO DIMENSIONS CODEC DURATION
    VIDEO_FILE="$1"

    if ! VIDEO_INFO="$(ffprobe -loglevel error -select_streams v:0 -output_format json -show_entries stream "$VIDEO_FILE")"; then
        printf "ERROR: Failed to query stream mappings for %s\n" "$VIDEO_FILE" >&2
        return 1
    fi

    DIMENSIONS="$(echo "$VIDEO_INFO" | jq --raw-output '.streams[] | (.width | tostring) + "x" + (.height | tostring)' || true)"
    CODEC="$(echo "$VIDEO_INFO" | jq --raw-output '.streams[].codec_name' || true)"
    DURATION="$(echo "$VIDEO_INFO" | jq --raw-output '.streams[].duration' || true)"

    if [[ -z "$DURATION" || "$DURATION" == "null" ]]; then
        DURATION="$(ffprobe -loglevel error -show_entries format=duration -output_format json "$VIDEO_FILE" | jq --raw-output '.format.duration' || true)"
    fi

    if [[ -z "$CODEC" || -z "$DIMENSIONS" || -z "$DURATION" || "$DURATION" == "null" ]]; then
        printf "ERROR: Incomplete structural stream descriptors on file %s\n" "$VIDEO_FILE" >&2
        return 1
    fi

    case "${CODEC,,}" in
        av1|hevc|vp9)
            printf "SKIP: '%s' is already utilizing a highly efficient modern codec (%s).\n" "$VIDEO_FILE" "$CODEC"
            return 0
            ;;
        *)
            print_verbose "Codec '$CODEC' requires modernization processing."
            ;;
    esac

    printf "\nProcessing File: %s\nCodec Profile: %s (%s) | Track Duration: %s seconds\n" "$VIDEO_FILE" "$CODEC" "$DIMENSIONS" "$DURATION"
    reencode_video "$VIDEO_FILE" "$DIMENSIONS" "$DURATION"
}

main() {
    local mime_type
    parse_options "$@"
    check_hardware_acceleration
    if [ -n "${1-}" ]; then
        SOURCE_DIR="${POSITIONAL_ARGS[0]}"
    fi

    while IFS= read -r -d '' SRC_FILE; do
        local TARGET_MKV="${SRC_FILE%.*}.mkv"

        if [[ -f "$TARGET_MKV" ]]; then
            if [[ "$SRC_FILE" == "$TARGET_MKV" ]]; then
                print_verbose "Evaluating existing Matroska container: '$SRC_FILE'"
            else
                printf "SKIP: Target master asset '%s' already exists. Assuming prior processing.\n" "$TARGET_MKV"
                continue
            fi
        fi

        mime_type=$(file --brief --mime-type "$SRC_FILE")
        if [[ ! "$mime_type" == video/* ]]; then
            continue
        fi
        if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of default=noprint_wrappers=1 "$SRC_FILE" | grep --quiet "video"; then
            continue
        fi

        get_video_info "$SRC_FILE"
    done < <(find "$SOURCE_DIR" -type f -print0)
}

main "$@"
