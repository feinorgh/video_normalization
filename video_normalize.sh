#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="."
VERBOSE=0
MATCH_PATTERN='.+\.(bdmv|vob)'
POSITIONAL_ARGS=()
WORK_DIR=""
VMAF_THRESHOLD="93.00"
SSIM_THRESHOLD="0.98"
SIZE_RATIO_THRESHOLD="0.80"

cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
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
                printf "ERROR: Unknown option '%s'" "$1" >&2
                exit 1
                ;;
            *)
                POSITIONAL_ARGS+=("$1")
                shift
                ;;
        esac
    done

    set -- "${POSITIONAL_ARGS[@]}"
}

extract_top_directory_for() {
    local _DIR_NAME _PARENT_DIR
    _DIR_NAME="$1"
    while true; do
        _PARENT_DIR="$(dirname "$_DIR_NAME")"
        if [[ "$(basename "$_PARENT_DIR")" == "VIDEO_TS" ]]; then
            break
        fi
        if [[ "$(basename "$_PARENT_DIR")" == "BDMV" ]]; then
            break
        fi
        if [[ "$_PARENT_DIR" == "/" ]]; then
            break
        fi
        _DIR_NAME="$_PARENT_DIR"
    done
    printf "%s" "$_PARENT_DIR"
}

find_dvd_and_bluray_directories() {
    local -A DVD_DIRECTORIES BLURAY_DIRECTORIES
    local CANDIDATE
    parse_options "$@"
    if [ -n "${1-}" ]; then
        SOURCE_DIR="${POSITIONAL_ARGS[0]}"
    fi
    print_verbose "Finding '$MATCH_PATTERN' in '$SOURCE_DIR'"
    shopt -s nocasematch
    while IFS= read -r -d "" SRC_FILE; do
        if [[ ! "$SRC_FILE" =~ $MATCH_PATTERN ]]; then
            continue
        fi
        if [[ "$SRC_FILE" =~ [.]vob$ ]]; then
            CANDIDATE="$(extract_top_directory_for "$SRC_FILE")"
            if [[ ! -v DVD_DIRECTORIES["$CANDIDATE"] ]]; then
                DVD_DIRECTORIES["$CANDIDATE"]=1
            fi
            continue
        fi
        if [[ "$SRC_FILE" =~ [.]bdmv$ ]]; then
            CANDIDATE="$(extract_top_directory_for "$SRC_FILE")"
            if [[ ! -v BLURAY_DIRECTORIES["$CANDIDATE"] ]]; then
                BLURAY_DIRECTORIES["$CANDIDATE"]=1
            fi
            continue
        fi
        printf "%s\n" "$SRC_FILE"
    done < <(find "$SOURCE_DIR" -type f -print0)
    for DIR in "${!DVD_DIRECTORIES[@]}"; do
        printf "%s\n" "$DIR"
    done
    for DIR in "${!BLURAY_DIRECTORIES[@]}"; do
        printf "%s\n" "$DIR"
    done
}

reencode_video() {
    local VIDEO_FILE VIDEO_FILE_NAME DIMENSIONS DURATION VMAF_LOG VMAF_SCORE ORIGINAL_SIZE ENCODED_SIZE SIZE_RATIO
    local FILM_GRAIN=0
    local CRF=32
    local PRESET=4
    local PIX_FMT=yuv420p10le
    local SVT_AV1_TUNE=1
    local CLIP_START="00:02:00"
    # local CLIP_LENGTH="00:00:30"
    local CLIP_LENGTH="30.0"
    local -a FFMPEG_ARGS
    VIDEO_FILE="$1"
    DIMENSIONS="$2"
    DURATION="$3"
    WORK_DIR="$(mktemp --directory)"

    VIDEO_FILE_NAME="$(basename "$VIDEO_FILE").mkv"
    # extract a reference clip from the full video, decode it fully lossless without audio first
    # also extract a reference clip with the original codec, to compare compression efficiency
    mkdir "$WORK_DIR/reference" || exit 1
    mkdir "$WORK_DIR/original" || exit 1

    FFMPEG_ARGS+=(-hide_banner -loglevel error -stats -fflags +genpts)
    if [ "$(echo "$DURATION <= 60.0" | bc --mathlib)" -eq 1 ]; then
        printf "INFO: Duration is less than 60 seconds, will use whole video.\n" >&2
    else
        # divide the length of the video in two, use that as the middle point, then count N seconds around
        # the middle to get a (hopefully) representative clip
        local MIDDLE_POINT
        MIDDLE_POINT="$(echo "scale=2; $DURATION / 2.0" | bc --mathlib)"
        CLIP_START="$(echo "scale=2; $MIDDLE_POINT - ($CLIP_LENGTH / 2.0)" | bc --mathlib)"
        FFMPEG_ARGS+=(-ss "$CLIP_START" -t "$CLIP_LENGTH")
    fi

    # if ! ffmpeg -hide_banner -loglevel error -stats -ss "$CLIP_START" -i "$VIDEO_FILE" -t "$CLIP_LENGTH" -c:v libx264 -crf 0 -preset ultrafast -an "$WORK_DIR/reference/$VIDEO_FILE_NAME"; then
    if ! ffmpeg "${FFMPEG_ARGS[@]}" -i "$VIDEO_FILE" -c:v libx264 -crf 0 -preset ultrafast -an "$WORK_DIR/reference/$VIDEO_FILE_NAME"; then
        printf "ERROR: Could not extract reference clip\n" >&2
        cleanup
        return 1
    fi
    # if ! ffmpeg -hide_banner -loglevel error -stats -ss "$CLIP_START" -i "$VIDEO_FILE" -t "$CLIP_LENGTH" -c:v copy -c:a copy "$WORK_DIR/original/$VIDEO_FILE_NAME"; then
    if ! ffmpeg "${FFMPEG_ARGS[@]}" -i "$VIDEO_FILE" -c:v copy -an "$WORK_DIR/original/$VIDEO_FILE_NAME"; then
        printf "ERROR: Could not extract baseline clip\n" >&2
        cleanup
        return 1
    fi
    ORIGINAL_SIZE=$(stat --format "%s" "$WORK_DIR/original/$VIDEO_FILE_NAME")

    # encode the test clip to libsvtav1
    if ! SVT_LOG=1 ffmpeg -nostdin -hide_banner -loglevel error -stats -y -i "$WORK_DIR/reference/$VIDEO_FILE_NAME" -c:v libsvtav1 -crf "$CRF" -preset "$PRESET" -pix_fmt "$PIX_FMT" -svtav1-params tune=$SVT_AV1_TUNE:film-grain="$FILM_GRAIN" -fps_mode passthrough -an "$WORK_DIR/candidate.mkv"; then
        printf "ERROR: Could not encode source material to SVT-AV1\n" >&2
        cleanup
        return 1
    fi
    ENCODED_SIZE=$(stat --format "%s" "$WORK_DIR/candidate.mkv")

    # calculate the number of frames in each file
    SRC_FRAMES=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of default=nokey=1:noprint_wrappers=1 "$WORK_DIR/reference/$VIDEO_FILE_NAME")
    CND_FRAMES=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of default=nokey=1:noprint_wrappers=1 "$WORK_DIR/candidate.mkv")
    if [[ $SRC_FRAMES != "$CND_FRAMES" ]]; then
        printf "ERROR: Different number of frames (%s vs %s)\n" "$SRC_FRAMES" "$CND_FRAMES" >&2
        cleanup
        return 1
    fi

    # run a perceptual metric comparison
    printf "Calculating SSIM score... "
    SSIM_LOG="$(ffmpeg -nostdin -hide_banner -i "$WORK_DIR/candidate.mkv" -i "$WORK_DIR/reference/$VIDEO_FILE_NAME" \
        -filter_complex "[0:v]setpts=N,setsar=1,format=yuv420p10le[distorted];[1:v]setpts=N,setsar=1,format=yuv420p10le[reference];[distorted][reference]ssim" -f null - 2>&1 | grep -oE "All:[0-9.]+" || true)"
    SSIM_SCORE=$(echo "$SSIM_LOG" | cut -d':' -f2)
    printf "%s\n" "$SSIM_SCORE"

    # run the normalized VMAF filtergraph
    printf "Calculating VMAF score... "
    VMAF_LOG="$(ffmpeg -nostdin -hide_banner -i "$WORK_DIR/candidate.mkv" -i "$WORK_DIR/reference/$VIDEO_FILE_NAME" \
        -filter_complex "[0:v]setpts=N,setsar=1,format=yuv420p10le[distorted];[1:v]setpts=N,setsar=1,format=yuv420p10le[reference];[distorted][reference]libvmaf=model=version=vmaf_v0.6.1" -f null - 2>&1)"
    VMAF_SCORE=$(echo "$VMAF_LOG" | grep -oE "VMAF score: [0-9.]+" | awk '{print $3}' || true)
    printf "%s\n" "$VMAF_SCORE"

    vmaf_is_valid=$(echo "$VMAF_SCORE >= $VMAF_THRESHOLD" | bc --mathlib)
    ssim_is_valid=$(echo "$SSIM_SCORE >= $SSIM_THRESHOLD" | bc --mathlib)
    if [[ $ssim_is_valid -eq 1 ]] && [[ $vmaf_is_valid -eq 1 ]]; then
        printf "Stream is valid with VMAF score of %s and a SSIM score of %s\n" "$VMAF_SCORE" "$SSIM_SCORE"
    else
        printf "WARNING: Could not establish proper baseline for %s\n" "$VIDEO_FILE" >&2
        cleanup
        return 1
    fi

    SIZE_RATIO="$(echo "scale=2; $ENCODED_SIZE / $ORIGINAL_SIZE" | bc --mathlib)"
    printf "Original size: %s bytes, encoded size: %s bytes; ratio: %s\n" "$ORIGINAL_SIZE" "$ENCODED_SIZE" "$SIZE_RATIO"
    size_is_valid=$(echo "$SIZE_RATIO <= $SIZE_RATIO_THRESHOLD" | bc --mathlib)
    if [[ $size_is_valid -eq 1 ]]; then
        printf "OK, enough size gains found. Will encode the whole file\n"
    else
        printf "NOT OK, original file will be preserved\n"
    fi
    cleanup
}

get_video_info() {
    local VIDEO_FILE VIDEO_INFO DIMENSIONS CODEC DURATION
    VIDEO_FILE="$1"
    VIDEO_INFO="$(ffprobe -loglevel error -select_streams v:0 -output_format json -show_entries stream "$VIDEO_FILE" | jq '.streams')"
    DIMENSIONS="$(jq --raw-output '.[] | (.width | tostring) + "x" + (.height | tostring)'<<< "$VIDEO_INFO")"
    CODEC="$(jq --raw-output '.[].codec_name'<<< "$VIDEO_INFO")"
    DURATION="$(jq --raw-output '.[].duration'<<< "$VIDEO_INFO")"
    printf "%s: %s (%s) (%s s)\n" "$VIDEO_FILE" "$CODEC" "$DIMENSIONS" "$DURATION"
    if ! reencode_video "$VIDEO_FILE" "$DIMENSIONS" "$DURATION"; then
        printf "Could not reliably convert video\n"
    fi
}

main() {
    local mime_type
    parse_options "$@"
    if [ -n "${1-}" ]; then
        SOURCE_DIR="${POSITIONAL_ARGS[0]}"
    fi
    while IFS= read -r -d '' SRC_FILE; do
        mime_type=$(file --brief --mime-type "$SRC_FILE")
        if [[ ! "$mime_type" == video/* ]]; then
            continue
        fi
        # check that we have a valid video stream
        if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of default=noprint_wrappers=1 "$SRC_FILE" | grep --quiet "video"; then
            continue
        fi
        echo "Video file with stream: '$SRC_FILE' ($mime_type)"
        get_video_info "$SRC_FILE"
    done < <(find "$SOURCE_DIR" -type f -print0)
}

main "$@"
