# shellcheck shell=bash
#
# Apply project Brewfiles via 'brew bundle'.
#
# Two entry points:
#   apply_brewfile_if_present <project_dir>
#       Resolve the active Brewfile (HOMEBREW_BUNDLE_FILE override, else
#       <project_dir>/Brewfile) and reconcile. Intended for per-shell entry.
#
#   apply_all_project_brewfiles <projects_root>
#       Walk each project subdir and reconcile its own Brewfile. The env
#       override is intentionally ignored here — it cannot mean anything
#       sensible across multiple projects. Intended for instance creation.
#
# Reconciliation is `brew bundle check` first; `install --no-upgrade` only
# runs on drift. Failures emit a loud warning to stderr but never abort —
# a broken Brewfile must not block the shell or instance from coming up.

# Reconcile a single resolved Brewfile path. Private helper.
_reconcile_brewfile() {
    local brewfile="$1"

    if ! command -v brew >/dev/null 2>&1; then
        printf 'WARNING: brew not found on PATH; skipping %s\n' "$brewfile" >&2
        return 0
    fi

    if brew bundle check --no-upgrade --file="$brewfile" >/dev/null 2>&1; then
        return 0
    fi

    printf 'clodpod: applying %s\n' "$brewfile" >&2
    if ! brew bundle install --no-upgrade --file="$brewfile"; then
        printf 'WARNING: brew bundle install failed for %s — continuing\n' "$brewfile" >&2
    fi
    return 0
}

apply_brewfile_if_present() {
    local project_dir="$1"
    local brewfile="${HOMEBREW_BUNDLE_FILE:-$project_dir/Brewfile}"

    [[ -f "$brewfile" ]] || return 0
    _reconcile_brewfile "$brewfile"
}

apply_all_project_brewfiles() {
    local projects_root="$1"

    [[ -d "$projects_root" ]] || return 0

    local project_dir brewfile
    for project_dir in "$projects_root"/*; do
        [[ -d "$project_dir" ]] || continue
        # __install is the clodpod payload mount, not a project.
        [[ "$(basename "$project_dir")" == "__install" ]] && continue
        brewfile="$project_dir/Brewfile"
        [[ -f "$brewfile" ]] || continue
        _reconcile_brewfile "$brewfile"
    done
    return 0
}
