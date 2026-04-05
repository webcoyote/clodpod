# shellcheck shell=bash
# Logging and utility functions

[[ "${VERBOSE:-0}" =~ ^[0-9]+$ ]] && VERBOSE="${VERBOSE:-0}" || VERBOSE=1
trace () {
    [[ "$VERBOSE" -lt 2 ]] || echo >&2 -e "🔬 \033[90m$*\033[0m"
}
debug () {
    [[ "$VERBOSE" -lt 1 ]] || echo >&2 -e "🔍 \033[36m$*\033[0m"
}
info () {
    echo >&2 -e "ℹ️ \033[36m$*\033[0m"
}
warn () {
    echo >&2 -e "⚠️ \033[33m$*\033[0m"
}
error () {
    echo >&2 -e "❌ \033[31m$*\033[0m"
}
abort () {
    error "$*"
    exit 1
}

# heredoc MESSAGE << EOF
#    your favorite text here
# EOF
heredoc(){ IFS=$'\n' read -r -d '' "${1}" || true; }

resolve_physical_path() {
    local input="${1:-}"
    local path
    local dir
    local base
    local target

    [[ -n "$input" ]] || return 1

    # Convert to absolute path first
    if [[ "$input" = /* ]]; then
        path="$input"
    else
        path="$PWD/$input"
    fi

    # Resolve parent directory to physical path
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    dir="$(builtin cd -P "$dir" 2>/dev/null && pwd -P)" || return 1
    path="$dir/$base"

    # Resolve symlink chain for the leaf path without `readlink -f`,
    # which is only supported by OSX's BSD tools (only GNU)
    while [[ -L "$path" ]]; do
        target="$(readlink "$path" 2>/dev/null)" || return 1
        if [[ "$target" = /* ]]; then
            path="$target"
        else
            path="$(dirname "$path")/$target"
        fi
        dir="$(dirname "$path")"
        base="$(basename "$path")"
        dir="$(builtin cd -P "$dir" 2>/dev/null && pwd -P)" || return 1
        path="$dir/$base"
    done

    [[ -e "$path" ]] || return 1
    if [[ -d "$path" ]]; then
        builtin cd -P "$path" 2>/dev/null && pwd -P
    else
        dir="$(builtin cd -P "$(dirname "$path")" 2>/dev/null && pwd -P)" || return 1
        echo "$dir/$(basename "$path")"
    fi
}

array_contains() {
    local needle="$1"
    shift || true

    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}
