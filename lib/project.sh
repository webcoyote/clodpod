# shellcheck shell=bash
# shellcheck disable=SC2154 # globals set by config.sh and other modules
# Project management: add, remove, list, select, directory mapping

check_projects_active() {
    # Returns 0 (success) if all projects are active, 1 otherwise
    local inactive_count
    inactive_count=$(sqlite3 "$DB_FILE" <<EOF
SELECT COUNT(*) FROM projects WHERE active = 0;
EOF
)
    trace "Inactive projects: $inactive_count"
    [[ "$inactive_count" -eq 0 ]]
}

add_project () {
    local patharg="${1:-}"
    local name="${2:-}"

    if [[ -z "$patharg" ]]; then
        abort "Error: path is required to add project"
    fi

    local path
    path="$(resolve_physical_path "$patharg" 2>/dev/null || true)"
    if [[ ! -d "$path" ]]; then
        abort "Error: directory not found ($patharg)"
    fi

    # Use basename of path if name not provided
    if [[ -z "$name" ]]; then
        name="$(basename "$path")"
    fi

    sqlite3 "$DB_FILE" <<EOF
INSERT OR IGNORE INTO projects (path, name, date_added) VALUES ('$(sql_escape "$path")', '$(sql_escape "$name")', datetime('now'));
EOF
    sqlite3 "$DB_FILE" <<EOF
UPDATE projects set date_added = datetime('now') where name = '$(sql_escape "$name")';
EOF

    info "Added project $name ($path)"
}

remove_project() {
    local identifier="${1:-}"

    if [[ -z "$identifier" ]]; then
        error "Error: Project name or path required to remove project"
        return 1
    fi
    local path
    path="$(resolve_physical_path "$identifier" 2>/dev/null || echo "")"

    # Try to remove by name first, then by path
    local rows_affected
    rows_affected=$(sqlite3 "$DB_FILE" <<EOF
DELETE FROM projects WHERE name = '$(sql_escape "$identifier")' OR path = '$(sql_escape "$identifier")' OR path = '$(sql_escape "$path")';
SELECT changes();
EOF
)

    if [[ ${rows_affected:-0} -gt 0 ]]; then
        info "Removed project $identifier"
    else
        error "Error: Project not found ($identifier)"
        return 1
    fi
}

list_projects() {
    sqlite3 -column -header "$DB_FILE" <<EOF || return 1
SELECT name, path, CASE WHEN active = 1 THEN 'yes' ELSE 'no' END as active, date_added FROM projects ORDER BY date_added DESC;
EOF
}

get_project_path_by_name() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        return 1
    fi

    sqlite3 "$DB_FILE" <<EOF
SELECT path FROM projects WHERE name = '$(sql_escape "$name")' LIMIT 1;
EOF
}

read_menu_key() {
    local input_fd="$1"
    local esc_seq="$2"
    local key=""
    local ch=""

    IFS= read -r -s -n 1 ch <&"$input_fd"

    if [[ -n "$esc_seq" ]]; then
        esc_seq+="$ch"
        local esc_last
        esc_last="${esc_seq:${#esc_seq}-1:1}"
        case "$esc_last" in
            [A-Za-z~])
                key="$esc_seq"
                esc_seq=""
                ;;
            *)
                MENU_KEY=""
                MENU_ESC_SEQ="$esc_seq"
                return 1
                ;;
        esac
    else
        if [[ "$ch" == $'\x1b' ]]; then
            esc_seq="$ch"
            MENU_KEY=""
            MENU_ESC_SEQ="$esc_seq"
            return 1
        fi
        key="$ch"
    fi

    MENU_KEY="$key"
    MENU_ESC_SEQ="$esc_seq"
    return 0
}

select_project() {
    local result
    result=$(sqlite3 -separator '|' "$DB_FILE" <<EOF || return 1
SELECT name, path, CASE WHEN active = 1 THEN 'yes' ELSE 'no' END as active
FROM projects
ORDER BY date_added DESC;
EOF
)

    if [[ -z "$result" ]]; then
        error "Error: No projects available"
        return 2
    fi

    local names=()
    local paths=()
    local states=()
    while IFS='|' read -r name path active; do
        names+=("$name")
        paths+=("$path")
        states+=("$active")
    done <<< "$result"

    local count="${#names[@]}"
    if [[ "$count" -eq 1 ]]; then
        echo "${names[0]}|${paths[0]}"
        return 0
    fi

    local input_fd=3
    local output_fd=3
    local tty_fd_open=0
    if exec 3<>/dev/tty 2>/dev/null; then
        tty_fd_open=1
    else
        error "Error: Interactive project selection requires a terminal"
        return 2
    fi

    local term_cols=120
    if command -v tput &>/dev/null; then
        local detected_cols
        detected_cols="$(tput cols 2>/dev/null || true)"
        if [[ "${detected_cols:-}" =~ ^[0-9]+$ ]] && [[ "$detected_cols" -gt 20 ]]; then
            term_cols="$detected_cols"
        fi
    fi

    local i=0
    local selected=0
    while [[ "$i" -lt "$count" ]]; do
        if [[ "${states[$i]}" == "yes" ]]; then
            selected="$i"
            break
        fi
        i=$((i + 1))
    done

    local rendered_lines=0
    render_menu() {
        local up=0
        while [[ "$up" -lt "$rendered_lines" ]]; do
            printf >&"$output_fd" "\033[1A"
            up=$((up + 1))
        done
        if [[ "$rendered_lines" -gt 0 ]]; then
            printf >&"$output_fd" "\033[J"
        fi

        printf >&"$output_fd" "Select active project:\n\n"
        rendered_lines=2

        local idx=0
        while [[ "$idx" -lt "$count" ]]; do
            local marker=" "
            if [[ "$idx" -eq "$selected" ]]; then
                marker=">"
            fi
            local status=""
            if [[ "${states[$idx]}" != "yes" ]]; then
                status=" [inactive]"
            fi
            local line
            line=$(printf "%s %-20s %s%s" "$marker" "${names[$idx]}" "${paths[$idx]}" "$status")
            if [[ "${#line}" -gt "$term_cols" ]]; then
                if [[ "$term_cols" -gt 4 ]]; then
                    line="${line:0:$((term_cols - 3))}..."
                else
                    line="${line:0:$term_cols}"
                fi
            fi
            printf >&"$output_fd" "%s\n" "$line"
            rendered_lines=$((rendered_lines + 1))
            idx=$((idx + 1))
        done
        printf >&"$output_fd" "\nUse up/down to select, Enter to select, q to cancel\n"
        rendered_lines=$((rendered_lines + 2))
    }

    local esc_seq=""
    render_menu
    while true; do

        local key=""
        local old_selected="$selected"
        if ! read_menu_key "$input_fd" "$esc_seq"; then
            esc_seq="$MENU_ESC_SEQ"
            continue
        fi
        key="$MENU_KEY"
        esc_seq="$MENU_ESC_SEQ"

        local key_last=""
        if [[ -n "$key" ]]; then
            key_last="${key:${#key}-1:1}"
        fi

        if [[ "$key" == "k" ]] || [[ "$key" == "K" ]] || \
           [[ "$key" == "w" ]] || [[ "$key" == "W" ]] || \
           [[ "$key" == *"[A" ]] || [[ "$key" == *"OA" ]] || \
           { [[ "$key" == $'\x1b'* ]] && [[ "$key_last" == "A" ]]; }; then
                if [[ "$selected" -gt 0 ]]; then
                    selected=$((selected - 1))
                fi
        elif [[ "$key" == "j" ]] || [[ "$key" == "J" ]] || \
             [[ "$key" == "s" ]] || [[ "$key" == "S" ]] || \
             [[ "$key" == *"[B" ]] || [[ "$key" == *"OB" ]] || \
             { [[ "$key" == $'\x1b'* ]] && [[ "$key_last" == "B" ]]; }; then
                if [[ "$selected" -lt "$((count - 1))" ]]; then
                    selected=$((selected + 1))
                fi
        else
            case "$key" in
            ""|$'\n'|$'\r')
                printf >&"$output_fd" "\n"
                if [[ "$tty_fd_open" -eq 1 ]]; then
                    exec 3<&-
                    exec 3>&-
                fi
                echo "${names[$selected]}|${paths[$selected]}"
                return 0
                ;;
            q|Q)
                printf >&"$output_fd" "\n"
                if [[ "$tty_fd_open" -eq 1 ]]; then
                    exec 3<&-
                    exec 3>&-
                fi
                return 1
                ;;
            *)
                # Ignore any unrecognized key input and keep selection unchanged.
                ;;
            esac
        fi

        if [[ "$selected" -ne "$old_selected" ]]; then
            render_menu
        fi
    done
}

set_active_project() {
    local name="$1"
    local path="$2"

    if ! sqlite3 "$DB_FILE" <<EOF
UPDATE projects
SET date_added = datetime('now')
WHERE name = '$(sql_escape "$name")' AND path = '$(sql_escape "$path")';
EOF
    then
        abort "Failed to persist selected project ordering for: $name ($path)"
    fi
}

# Get all projects as NUL-delimited --dir arguments
# Usage: while IFS= read -r -d '' arg; do args+=("$arg"); done < <(get_map_directories)
# Outputs NUL-delimited entries like: "--dir" NUL "name:path" NUL
get_map_directories() {
    local result
    result=$(sqlite3 -separator '|' "$DB_FILE" <<EOF || return 1
SELECT name, path FROM projects ORDER BY date_added DESC;
EOF
)

    # Always map the guest directory into the VM as "__install"
    # so install/configure scripts are available during build
    printf '%s\0' "--dir" "__install:$DATA_DIR/guest"

    if [[ -n "$result" ]]; then
        while IFS='|' read -r name path; do
            if [[ ! -d "$path" ]]; then
                abort "Directory '$path' does not exist\nTry: clod remove '$name'"
            fi
            printf '%s\0' "--dir" "${name}:${path}"
        done <<< "$result"
    fi
}

get_relative_directory_from_root() {
    local root_path="$1"
    local current_dir
    local resolved_root

    current_dir="$(resolve_physical_path "$PWD" 2>/dev/null || return 1)"
    resolved_root="$(resolve_physical_path "$root_path" 2>/dev/null || return 1)"

    if [[ "$current_dir" == "$resolved_root" ]] || [[ "$current_dir" == "$resolved_root"/* ]]; then
        local relative_path="${current_dir#"$resolved_root"}"
        relative_path="${relative_path#/}"
        echo "$relative_path"
        return 0
    fi

    return 1
}

# Check if current working directory is inside active project and returns RELATIVE_PATH
# Returns 0 if inside the project, 1 otherwise
get_relative_project_directory() {
    local project_name
    project_name="$1"
    local path
    path=$(sqlite3 "$DB_FILE" <<EOF || return 1
SELECT path FROM projects WHERE name = '$(sql_escape "$project_name")' AND active > 0 LIMIT 1;
EOF
)

    [[ -n "$path" ]] || return 1
    get_relative_directory_from_root "$path"
}
