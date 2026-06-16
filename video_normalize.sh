#!/usr/bin/env bash

set -o nounset

SOURCE_DIR="."
VERBOSE=0
MATCH_PATTERN='.+\.(bdmv|vob)'
POSITIONAL_ARGS=()
WORK_DIR=""
VMAF_THRESHOLD="93.00"
SSIM_THRESHOLD="0.98"

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
    local VIDEO_FILE VIDEO_FILE_NAME DIMENSIONS DURATION VMAF_LOG VMAF_SCORE
    local FILM_GRAIN=0
    local CRF=28
    local PRESET=4
    local PIX_FMT=yuv420p10le
    local SVT_AV1_TUNE=1
    VIDEO_FILE="$1"
    DIMENSIONS="$2"
    DURATION="$3"
    WORK_DIR="$(mktemp --directory)"

    VIDEO_FILE_NAME="$(basename "$VIDEO_FILE").mkv"
    # extract a one minute reference clip from the full video, decode it fully lossless without audio first
    mkdir "$WORK_DIR/reference" || exit 1
    ffmpeg -hide_banner -loglevel error -stats -ss 00:02:00 -i "$VIDEO_FILE" -t 00:01:00 -c:v libx264 -crf 0 -preset ultrafast -an "$WORK_DIR/reference/$VIDEO_FILE_NAME"
    # encode the test clip to libsvtav1
    SVT_LOG=1 ffmpeg -nostdin -hide_banner -loglevel error -stats -y -i "$WORK_DIR/reference/$VIDEO_FILE_NAME" -c:v libsvtav1 -crf "$CRF" -preset "$PRESET" -pix_fmt "$PIX_FMT" -svtav1-params tune=$SVT_AV1_TUNE:film-grain="$FILM_GRAIN" -fps_mode passthrough -an "$WORK_DIR/candidate.mkv"
    # calculate the number of frames in each file
    SRC_FRAMES=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of default=nokey=1:noprint_wrappers=1 "$WORK_DIR/reference/$VIDEO_FILE_NAME")
    CND_FRAMES=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of default=nokey=1:noprint_wrappers=1 "$WORK_DIR/candidate.mkv")
    if [[ $SRC_FRAMES != "$CND_FRAMES" ]]; then
        printf "ERROR: Difference number of frames (%s vs %s)" "$SRC_FRAMES" "$CND_FRAMES" >&2
        exit 1
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
    ssim_is_valid=$(echo "$VMAF_SCORE >= $SSIM_THRESHOLD" | bc --mathlib)
    if [[ $ssim_is_valid -eq 1 ]] && [[ $vmaf_is_valid -eq 1 ]]; then
        printf "Stream is valid with VMAF score of %s and a SSIM score of %s\n" "$VMAF_SCORE" "$SSIM_SCORE"
    else
        printf "WARNING: Could not establish proper baseline for %s" "$VIDEO_FILE" >&2
        return 1
    fi
}

get_video_info() {
    local VIDEO_FILE VIDEO_INFO DIMENSIONS CODEC DURATION
    VIDEO_FILE="$1"
    VIDEO_INFO="$(ffprobe -loglevel error -select_streams v:0 -output_format json -show_entries stream "$VIDEO_FILE" | jq '.streams')"
    DIMENSIONS="$(jq --raw-output '.[] | (.width | tostring) + "x" + (.height | tostring)'<<< "$VIDEO_INFO")"
    CODEC="$(jq --raw-output '.[].codec_name'<<< "$VIDEO_INFO")"
    DURATION="$(jq --raw-output '.[].duration'<<< "$VIDEO_INFO")"
    printf "%s (%s) (%s s)\n" "$CODEC" "$DIMENSIONS" "$DURATION"
    if ! reencode_video "$VIDEO_FILE" "$DIMENSIONS" "$DURATION"; then
        printf "Could not reliably convert video\n"
    fi
    exit 0
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
