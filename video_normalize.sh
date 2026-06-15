#!/usr/bin/env bash

set -o nounset

SOURCE_DIR="."
VERBOSE=0
MATCH_PATTERN='.+\.(bdmv|vob)'
POSITIONAL_ARGS=()

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

main() {
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

main "$@"
