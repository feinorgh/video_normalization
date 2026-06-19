#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="."
VERBOSE=0
POSITIONAL_ARGS=()

# Tunables (defaults)
VMAF_THRESHOLD="93.0"
SSIM_THRESHOLD="0.98"
SIZE_RATIO_THRESHOLD="0.80"
CLIP_LENGTH="30"
START_CRF=32
MIN_CRF=18
START_PRESET=4

# Fixed encode params
FILM_GRAIN=0
SVT_AV1_TUNE=0
PIX_FMT="yuv420p10le"

# Modes
DRY_RUN=0
REPORT_PATH=""

# Diagnostics
DIAGNOSTICS_DUMPED=0
CURRENT_LOG_FILE=""
CURRENT_WORK_DIR=""

show_help() {
    cat <<'EOF'
Usage:
    ./video_normalize.sh [options] [SOURCE_DIR]

Options:
    -h, --help                      Show this help and exit
    -v, --verbose                   Enable verbose output
    --dry-run                       Analyze but do not write final outputs
    --report <path>                 Write CSV report to file
    --vmaf-threshold <float>        Default: 93.0
    --ssim-threshold <float>        Default: 0.98
    --size-ratio-threshold <float>  Default: 0.80
    --clip-length <seconds>         Default: 30
    --start-crf <int>               Default: 32
    --min-crf <int>                 Default: 18
    --preset <int>                  Default: 4
EOF
}

print_verbose() {
    if [ "$VERBOSE" -eq 1 ]; then
        printf "%s\n" "$*"
    fi
}

require_command() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            printf "ERROR: Required command not found: %s\n" "$cmd" >&2
            exit 1
        fi
    done
}

is_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

append_report_row() {
    if [[ -z "$REPORT_PATH" ]]; then
        return 0
    fi
    local source_file="$1"
    local codec="$2"
    local duration="$3"
    local action="$4"
    local status="$5"
    local crf="$6"
    local preset="$7"
    local vmaf="$8"
    local ssim="$9"
    local sample_ratio="${10}"
    local final_ratio="${11}"
    local message="${12}"

    source_file=${source_file//\"/\"\"}
    message=${message//\"/\"\"}

    printf "\"%s\",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,\"%s\"\n" \
        "$source_file" "$codec" "$duration" "$action" "$status" "$crf" "$preset" \
        "$vmaf" "$ssim" "$sample_ratio" "$final_ratio" "$message" >> "$REPORT_PATH"
}

init_report() {
    if [[ -z "$REPORT_PATH" ]]; then
        return 0
    fi
    mkdir -p "$(dirname "$REPORT_PATH")"
    printf "source_file,codec,duration,action,status,crf,preset,vmaf,ssim,sample_ratio,final_ratio,message\n" > "$REPORT_PATH"
}

cleanup() {
    local exit_code=$?
    if [[ -n "${CURRENT_WORK_DIR:-}" && -d "${CURRENT_WORK_DIR}" ]]; then
        if [[ $exit_code -ne 0 && $DIAGNOSTICS_DUMPED -eq 0 ]]; then
            printf "\n============================================================\n" >&2
            printf "CRITICAL ABORT: Execution failed. Dumping diagnostic logs:\n" >&2
            printf "============================================================\n\n" >&2
            if [[ -n "${CURRENT_LOG_FILE:-}" && -f "${CURRENT_LOG_FILE}" ]]; then
                cat "${CURRENT_LOG_FILE}" >&2
            else
                printf "No execution.log file was generated before the crash.\n" >&2
            fi
            printf "\n============================================================\n" >&2
            DIAGNOSTICS_DUMPED=1
        fi
        rm -rf -- "${CURRENT_WORK_DIR}"
    fi
}

trap cleanup EXIT ERR INT TERM

parse_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --report)
                [[ $# -lt 2 ]] && { printf "ERROR: --report requires a path\n" >&2; exit 1; }
                REPORT_PATH="$2"
                shift 2
                ;;
            --vmaf-threshold)
                [[ $# -lt 2 ]] && { printf "ERROR: --vmaf-threshold requires a value\n" >&2; exit 1; }
                is_number "$2" || { printf "ERROR: Invalid --vmaf-threshold: %s\n" "$2" >&2; exit 1; }
                VMAF_THRESHOLD="$2"
                shift 2
                ;;
            --ssim-threshold)
                [[ $# -lt 2 ]] && { printf "ERROR: --ssim-threshold requires a value\n" >&2; exit 1; }
                is_number "$2" || { printf "ERROR: Invalid --ssim-threshold: %s\n" "$2" >&2; exit 1; }
                SSIM_THRESHOLD="$2"
                shift 2
                ;;
            --size-ratio-threshold)
                [[ $# -lt 2 ]] && { printf "ERROR: --size-ratio-threshold requires a value\n" >&2; exit 1; }
                is_number "$2" || { printf "ERROR: Invalid --size-ratio-threshold: %s\n" "$2" >&2; exit 1; }
                SIZE_RATIO_THRESHOLD="$2"
                shift 2
                ;;
            --clip-length)
                [[ $# -lt 2 ]] && { printf "ERROR: --clip-length requires a value\n" >&2; exit 1; }
                is_number "$2" || { printf "ERROR: Invalid --clip-length: %s\n" "$2" >&2; exit 1; }
                CLIP_LENGTH="$2"
                shift 2
                ;;
            --start-crf)
                [[ $# -lt 2 ]] && { printf "ERROR: --start-crf requires a value\n" >&2; exit 1; }
                is_int "$2" || { printf "ERROR: Invalid --start-crf: %s\n" "$2" >&2; exit 1; }
                START_CRF="$2"
                shift 2
                ;;
            --min-crf)
                [[ $# -lt 2 ]] && { printf "ERROR: --min-crf requires a value\n" >&2; exit 1; }
                is_int "$2" || { printf "ERROR: Invalid --min-crf: %s\n" "$2" >&2; exit 1; }
                MIN_CRF="$2"
                shift 2
                ;;
            --preset)
                [[ $# -lt 2 ]] && { printf "ERROR: --preset requires a value\n" >&2; exit 1; }
                is_int "$2" || { printf "ERROR: Invalid --preset: %s\n" "$2" >&2; exit 1; }
                START_PRESET="$2"
                shift 2
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

    if (( MIN_CRF > START_CRF )); then
        printf "ERROR: --min-crf (%d) cannot be greater than --start-crf (%d)\n" "$MIN_CRF" "$START_CRF" >&2
        exit 1
    fi
}

get_video_info_fields() {
    local video_file="$1"
    local video_info dimensions codec duration

    if ! video_info="$(ffprobe -loglevel error -select_streams v:0 -output_format json -show_entries stream "$video_file")"; then
        return 1
    fi

    dimensions="$(echo "$video_info" | jq --raw-output '.streams[0] | (.width|tostring) + "x" + (.height|tostring)' || true)"
    codec="$(echo "$video_info" | jq --raw-output '.streams[0].codec_name' || true)"
    duration="$(echo "$video_info" | jq --raw-output '.streams[0].duration' || true)"

    if [[ -z "$duration" || "$duration" == "null" ]]; then
        duration="$(ffprobe -loglevel error -show_entries format=duration -output_format json "$video_file" | jq --raw-output '.format.duration' || true)"
    fi

    if [[ -z "$codec" || -z "$dimensions" || -z "$duration" || "$duration" == "null" ]]; then
        return 1
    fi

    printf "%s|%s|%s\n" "$codec" "$dimensions" "$duration"
}

reencode_video() {
    local video_file="$1"
    local dimensions="$2"
    local duration="$3"
    local codec="$4"

    local crf="$START_CRF"
    local preset="$START_PRESET"

    local work_dir
    work_dir="$(mktemp -d)"
    local log_file="$work_dir/execution.log"
    local video_file_name
    video_file_name="$(basename "${video_file%.*}.mkv")"

    CURRENT_WORK_DIR="$work_dir"
    CURRENT_LOG_FILE="$log_file"

    mkdir "$work_dir/reference" "$work_dir/original"

    local -a ffmpeg_args
    ffmpeg_args=(-hide_banner -loglevel verbose -nostats -fflags +genpts+igndts+discardcorrupt -err_detect ignore_err)

    if [[ "$(echo "$duration <= 60.0" | bc --mathlib)" -ne 1 ]]; then
        local middle_point clip_start
        middle_point="$(echo "scale=2; $duration / 2.0" | bc --mathlib)"
        clip_start="$(echo "scale=2; $middle_point - ($CLIP_LENGTH / 2.0)" | bc --mathlib)"
        if [[ "$(echo "$clip_start < 0" | bc --mathlib)" -eq 1 ]]; then clip_start="0"; fi
        if [[ "$clip_start" =~ ^\. ]]; then clip_start="0${clip_start}"; fi
        ffmpeg_args+=(-ss "$clip_start" -t "$CLIP_LENGTH")
    else
        print_verbose "INFO: Duration <= 60s, using full timeline as sample."
    fi

    if ! ffmpeg "${ffmpeg_args[@]}" -i "$video_file" -c:v libx264 -crf 0 -preset ultrafast -an "$work_dir/reference/$video_file_name" >> "$log_file" 2>&1; then
        append_report_row "$video_file" "$codec" "$duration" "sample" "error" "$crf" "$preset" "" "" "" "" "reference clip extraction failed"
        return 1
    fi

    if ! ffmpeg "${ffmpeg_args[@]}" -i "$video_file" -c:v copy -an "$work_dir/original/$video_file_name" >> "$log_file" 2>&1; then
        append_report_row "$video_file" "$codec" "$duration" "sample" "error" "$crf" "$preset" "" "" "" "" "baseline clip extraction failed"
        return 1
    fi

    local original_size encoded_size size_ratio ssim_score vmaf_score
    original_size="$(stat --format "%s" "$work_dir/original/$video_file_name")"

    local optimized=false
    while [[ "$optimized" == "false" ]]; do
        print_verbose "Testing profile -> CRF=$crf preset=$preset"

        if ! SVT_LOG=1 ffmpeg -nostdin -hide_banner -loglevel verbose -nostats -y \
            -i "$work_dir/reference/$video_file_name" \
            -c:v libsvtav1 -crf "$crf" -preset "$preset" -pix_fmt "$PIX_FMT" \
            -svtav1-params tune=$SVT_AV1_TUNE:film-grain="$FILM_GRAIN":lp=0 \
            -fps_mode passthrough -an "$work_dir/candidate.mkv" >> "$log_file" 2>&1 < /dev/null; then
            append_report_row "$video_file" "$codec" "$duration" "sample" "error" "$crf" "$preset" "" "" "" "" "sample encode failed"
            return 1
        fi

        local ssim_log vmaf_log
        ssim_log="$(ffmpeg -nostdin -hide_banner -loglevel verbose -nostats \
            -i "$work_dir/candidate.mkv" -i "$work_dir/reference/$video_file_name" \
            -filter_complex "[0:v]setpts=N,setsar=1,format=${PIX_FMT}[distorted];[1:v]setpts=N,setsar=1,format=${PIX_FMT}[reference];[distorted][reference]ssim" \
            -f null - 2>&1 | tee -a "$log_file")"

        vmaf_log="$(ffmpeg -nostdin -hide_banner -loglevel verbose -nostats \
            -i "$work_dir/candidate.mkv" -i "$work_dir/reference/$video_file_name" \
            -filter_complex "[0:v]setpts=N,setsar=1,format=${PIX_FMT}[distorted];[1:v]setpts=N,setsar=1,format=${PIX_FMT}[reference];[distorted][reference]libvmaf=model=version=vmaf_v0.6.1" \
            -f null - 2>&1 | tee -a "$log_file")"

        ssim_score="$(echo "$ssim_log" | grep -oE 'All:[0-9.]+' | cut -d':' -f2 || true)"
        vmaf_score="$(echo "$vmaf_log" | grep -oE 'VMAF score: [0-9.]+' | awk '{print $3}' || true)"

        if [[ -z "$ssim_score" || -z "$vmaf_score" ]] || \
           ! [[ "$ssim_score" =~ ^[0-9]+([.][0-9]+)?$ && "$vmaf_score" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            append_report_row "$video_file" "$codec" "$duration" "sample" "error" "$crf" "$preset" "$vmaf_score" "$ssim_score" "" "" "metric extraction failed"
            return 1
        fi

        local ssim_passes vmaf_passes
        ssim_passes="$(echo "$ssim_score >= $SSIM_THRESHOLD" | bc --mathlib)"
        vmaf_passes="$(echo "$vmaf_score >= $VMAF_THRESHOLD" | bc --mathlib)"

        if [[ "$ssim_passes" -eq 1 && "$vmaf_passes" -eq 1 ]]; then
            if [[ "$(echo "$vmaf_score > 96.5" | bc --mathlib)" -eq 1 && "$preset" -eq 4 ]]; then
                preset=5
                continue
            fi
            optimized=true
        else
            if (( crf <= MIN_CRF )); then
                printf "WARNING: Hit minimum quality boundary (CRF=%d). Proceeding.\n" "$MIN_CRF" >&2
                optimized=true
            else
                crf=$((crf - 2))
                preset="$START_PRESET"
            fi
        fi
    done

    encoded_size="$(stat --format "%s" "$work_dir/candidate.mkv")"
    size_ratio="$(echo "scale=4; $encoded_size / $original_size" | bc --mathlib)"
    printf "Result Metrics -> VMAF=%s SSIM=%s CompressionRatio=%s\n" "$vmaf_score" "$ssim_score" "$size_ratio"

    if [[ "$(echo "$size_ratio <= $SIZE_RATIO_THRESHOLD" | bc --mathlib)" -ne 1 ]]; then
        printf "ABORT: sample ratio %s exceeds threshold %s\n" "$size_ratio" "$SIZE_RATIO_THRESHOLD"
        append_report_row "$video_file" "$codec" "$duration" "sample" "aborted_ratio" "$crf" "$preset" "$vmaf_score" "$ssim_score" "$size_ratio" "" "sample ratio threshold not met"
        rm -rf -- "$work_dir"
        CURRENT_WORK_DIR=""
        CURRENT_LOG_FILE=""
        return 0
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf "DRY-RUN: would encode full file '%s' (CRF=%d preset=%d)\n" "$video_file" "$crf" "$preset"
        append_report_row "$video_file" "$codec" "$duration" "full" "dry_run" "$crf" "$preset" "$vmaf_score" "$ssim_score" "$size_ratio" "" "full encode skipped by dry-run"
        rm -rf -- "$work_dir"
        CURRENT_WORK_DIR=""
        CURRENT_LOG_FILE=""
        return 0
    fi

    local final_output original_full_size final_encoded_size final_ratio
    final_output="${video_file%.*}.mkv"

    if ! SVT_LOG=1 ffmpeg -nostdin -hide_banner -loglevel verbose -nostats -y \
        -fflags +genpts+igndts+discardcorrupt -err_detect ignore_err \
        -i "$video_file" \
        -c:v libsvtav1 -crf "$crf" -preset "$preset" -pix_fmt "$PIX_FMT" \
        -svtav1-params tune=$SVT_AV1_TUNE:film-grain="$FILM_GRAIN":lp=0 \
        -fps_mode passthrough \
        -c:a libopus -b:a 128k -vbr on -af aresample=async=1 \
        "$final_output" >> "$log_file" 2>&1; then
        append_report_row "$video_file" "$codec" "$duration" "full" "error" "$crf" "$preset" "$vmaf_score" "$ssim_score" "$size_ratio" "" "full encode failed"
        return 1
    fi

    if ffprobe -v error -show_entries format=duration "$final_output" >/dev/null 2>&1; then
        original_full_size="$(stat --format "%s" "$video_file")"
        final_encoded_size="$(stat --format "%s" "$final_output")"
        final_ratio="$(echo "scale=4; $final_encoded_size / $original_full_size" | bc --mathlib)"
        printf "SUCCESS: encoded '%s' ratio=%s\n" "$final_output" "$final_ratio"
        append_report_row "$video_file" "$codec" "$duration" "full" "encoded" "$crf" "$preset" "$vmaf_score" "$ssim_score" "$size_ratio" "$final_ratio" "success"
        rm -rf -- "$work_dir"
        CURRENT_WORK_DIR=""
        CURRENT_LOG_FILE=""
    else
        append_report_row "$video_file" "$codec" "$duration" "full" "error" "$crf" "$preset" "$vmaf_score" "$ssim_score" "$size_ratio" "" "final output integrity check failed"
        return 1
    fi
}

process_file() {
    local src_file="$1"
    local mime_type target_mkv codec dimensions duration fields

    target_mkv="${src_file%.*}.mkv"

    if [[ -f "$target_mkv" && "$src_file" != "$target_mkv" ]]; then
        printf "SKIP: target exists '%s'\n" "$target_mkv"
        append_report_row "$src_file" "" "" "scan" "skipped_existing_output" "" "" "" "" "" "" "target output exists"
        return 0
    fi

    mime_type="$(file --brief --mime-type "$src_file")"
    if [[ ! "$mime_type" == video/* ]]; then
        append_report_row "$src_file" "" "" "scan" "skipped_nonvideo" "" "" "" "" "" "" "mime type not video"
        return 0
    fi

    if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of default=noprint_wrappers=1 "$src_file" | grep -q "video"; then
        append_report_row "$src_file" "" "" "scan" "skipped_no_video_stream" "" "" "" "" "" "" "no video stream"
        return 0
    fi

    if ! fields="$(get_video_info_fields "$src_file")"; then
        printf "ERROR: metadata extraction failed for '%s'\n" "$src_file" >&2
        append_report_row "$src_file" "" "" "scan" "error" "" "" "" "" "" "" "metadata extraction failed"
        return 1
    fi

    codec="${fields%%|*}"
    fields="${fields#*|}"
    dimensions="${fields%%|*}"
    duration="${fields##*|}"

    case "${codec,,}" in
        av1|hevc|vp9)
            printf "SKIP: '%s' already modern codec (%s)\n" "$src_file" "$codec"
            append_report_row "$src_file" "$codec" "$duration" "scan" "skipped_modern_codec" "" "" "" "" "" "" "codec already efficient"
            return 0
            ;;
    esac

    print_verbose "Processing: $src_file | codec=$codec | dim=$dimensions | duration=$duration"
    reencode_video "$src_file" "$dimensions" "$duration" "$codec"
}

main() {
    parse_options "$@"

    if (( ${#POSITIONAL_ARGS[@]} > 0 )); then
        SOURCE_DIR="${POSITIONAL_ARGS[0]}"
    fi

    require_command ffmpeg ffprobe jq bc file stat mktemp find grep awk cut tee basename dirname mkdir cat

    init_report

    while IFS= read -r -d '' src_file; do
        process_file "$src_file"
    done < <(find "$SOURCE_DIR" -type f -print0)
}

main "$@"
