# shellcheck shell=bash
# shellcheck disable=SC2154 # globals set by config.sh and other modules
# Instance operations: create, shell, stop, destroy, set, list, SSH

get_local_network_error() {
    local vm_name="$1"
    local term_program="${TERM_PROGRAM:-e.g. ghostty, kitty, iTerm, WezTerm}"

    cat <<EOF

ERROR: unable to connect to $vm_name.

Your terminal app ($term_program)
has not been granted "Local Network" access rights,
which are required to SSH to the Virtual Machine.

- Open "System Settings.app"
- Navigate to "Privacy & Security"
- Select "Local Network"
- Grant access to your terminal application

EOF
}

encode_command_args() {
    local command_args_b64=""
    if [[ ${#COMMAND_ARGS[@]} -gt 0 ]]; then
        command_args_b64="$(printf '%s\0' "${COMMAND_ARGS[@]}" | base64 | tr -d '\n')"
    fi
    echo "$command_args_b64"
}

get_vm_ip_or_abort() {
    local vm_name="$1"

    debug "Checking $vm_name IP connectivity"
    local ipaddr
    ipaddr="$(tart ip --wait 20 "$vm_name")"
    if ! nc -z "$ipaddr" 22 ; then
        error "$(get_local_network_error "$vm_name")"
        read -n 1 -s -r -p "Press any key to open System Settings"
        open "/System/Library/PreferencePanes/Security.prefPane"
    fi

    echo "$ipaddr"
}

ssh_into_vm() {
    local vm_name="$1"
    local project_name="${2:-}"
    local initial_dir="${3:-}"
    local ipaddr
    local command_args_b64

    ipaddr="$(get_vm_ip_or_abort "$vm_name")"
    debug "Connect to $vm_name (ssh clodpod@$ipaddr)"

    command_args_b64="$(encode_command_args)"

    exec ssh \
        -q \
        -tt \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$SSH_KEYFILE_PRIV" \
        "clodpod@$ipaddr" \
        /usr/bin/env \
            "TERM=xterm-256color" \
            "PROJECT=$project_name" \
            "INITIAL_DIR=$initial_dir" \
            "COMMAND=${COMMAND:-}" \
            "COMMAND_ARGS_B64=$command_args_b64" \
            zsh --login || true
}

vm_sync_authorized_key() {
    local vm_name="$1"
    local pub_key_b64

    pub_key_b64="$(base64 < "$SSH_KEYFILE_PUB" | tr -d '\n')"
    # shellcheck disable=SC2016 #  Expressions don't expand in single quotes, use double quotes for that.
    tart exec -it "$vm_name" \
        "/usr/bin/env" "PUB_KEY_B64=$pub_key_b64" \
        bash -lc '
            sudo install -d -m 700 -o clodpod -g clodpod /Users/clodpod/.ssh
            printf "%s" "$PUB_KEY_B64" | /usr/bin/base64 -D | sudo tee /Users/clodpod/.ssh/authorized_keys >/dev/null
            sudo chown clodpod:clodpod /Users/clodpod/.ssh/authorized_keys
            sudo chmod 600 /Users/clodpod/.ssh/authorized_keys
        '
}

vm_list() {
    local result
    result=$(sqlite3 -separator '|' "$DB_FILE" <<EOF || return 1
SELECT name, vm_name, ram_mb FROM instances ORDER BY created_at DESC, name ASC;
EOF
)

    [[ -n "$result" ]] || return 1

    echo "INSTANCES"
    printf "%-20s %-10s %-12s %-15s %s\n" "NAME" "RAM (MB)" "STATE" "IP" "DIRS"

    local instance_name
    local vm_name
    local stored_ram
    while IFS='|' read -r instance_name vm_name stored_ram; do
        local state
        local ipaddr="-"
        local ram_display
        local dir_rows
        local dirs=""

        state="$(get_vm_state "$vm_name")"
        [[ -n "$state" ]] || state="not created"

        # RAM display: running → actual from tart get; stopped → stored or (budget)
        if [[ "$state" == "running" ]]; then
            ipaddr="$(tart ip "$vm_name" 2>/dev/null || echo "-")"
            [[ -n "$ipaddr" ]] || ipaddr="-"
            ram_display="$(tart get "$vm_name" --format json | jq '.Memory' 2>/dev/null || echo "?")"
        elif [[ -n "$stored_ram" ]] && [[ "$stored_ram" != "0" ]]; then
            ram_display="$stored_ram"
        else
            ram_display="(budget)"
        fi

        dir_rows="$(vm_get_instance_dirs "$instance_name")"
        if [[ -n "$dir_rows" ]]; then
            local dir_name
            local dir_path
            local is_primary
            while IFS='|' read -r dir_name dir_path is_primary; do
                local entry="${dir_name}:${dir_path}"
                if [[ "$is_primary" -eq 1 ]]; then
                    entry="$entry (primary)"
                fi
                if [[ -n "$dirs" ]]; then
                    dirs="$dirs, "
                fi
                dirs="${dirs}${entry}"
            done <<< "$dir_rows"
        fi
        [[ -n "$dirs" ]] || dirs="-"

        printf "%-20s %-10s %-12s %-15s %s\n" "$instance_name" "$ram_display" "$state" "$ipaddr" "$dirs"
    done <<< "$result"
}

vm_shell() {
    local instance_name="$1"
    local vm_name
    local effective_ram

    vm_name="$(vm_get_instance_vm_name "$instance_name")"
    [[ -n "$vm_name" ]] || abort "Error: instance not found ($instance_name)"

    # RAM priority: --ram override > stored ram_mb > 0 (dynamic/remaining budget)
    if [[ -n "${SHELL_RAM_OVERRIDE:-}" ]]; then
        effective_ram="$SHELL_RAM_OVERRIDE"
    else
        effective_ram="$(vm_get_instance_ram_mb "$instance_name")"
        [[ "$effective_ram" =~ ^[0-9]+$ ]] || effective_ram=0
    fi

    if ! get_vm_exists "$vm_name"; then
        abort "Error: VM missing for instance $instance_name ($vm_name). Destroy and recreate it."
    fi

    ensure_ssh_key

    local dir_args=()
    local primary_name=""
    local primary_path=""
    local dir_rows
    dir_rows="$(vm_get_instance_dirs "$instance_name")"
    if [[ -n "$dir_rows" ]]; then
        local dir_name
        local dir_path
        local is_primary
        while IFS='|' read -r dir_name dir_path is_primary; do
            if [[ ! -d "$dir_path" ]]; then
                warn "Instance directory missing on host: $dir_name ($dir_path)"
                continue
            fi

            dir_args+=("--dir" "${dir_name}:${dir_path}")
            if [[ "$is_primary" -eq 1 ]] && [[ -z "$primary_name" ]]; then
                primary_name="$dir_name"
                primary_path="$dir_path"
            fi
        done <<< "$dir_rows"
    fi

    if [[ "$(get_vm_state "$vm_name")" == "running" ]]; then
        # VM already running — warn if --ram override given, then reconnect
        if [[ -n "${SHELL_RAM_OVERRIDE:-}" ]]; then
            local current_ram
            current_ram="$(tart get "$vm_name" --format json | jq '.Memory' 2>/dev/null || echo "?")"
            warn "$instance_name is already running with ${current_ram} MB RAM. --ram override ignored for running VM."
        fi
    else
        vm_run "$vm_name" "$effective_ram" "$vm_name" ${dir_args[@]+"${dir_args[@]}"} || true
    fi

    if [[ "${SSH_KEY_CREATED:-false}" == "true" ]]; then
        vm_sync_authorized_key "$vm_name"
    fi

    local initial_dir=""
    if [[ -n "$primary_path" ]]; then
        initial_dir="$(get_relative_directory_from_root "$primary_path" 2>/dev/null || true)"
        debug "initial directory: ${initial_dir:-}"
    fi

    ssh_into_vm "$vm_name" "$primary_name" "$initial_dir"
}

vm_stop_instance() {
    local instance_name="$1"
    local vm_name

    vm_name="$(vm_get_instance_vm_name "$instance_name")"
    [[ -n "$vm_name" ]] || abort "Error: instance not found ($instance_name)"

    if ! get_vm_exists "$vm_name"; then
        return 0
    fi

    stop_vm "$vm_name"
}

vm_delete_instance_records() {
    local instance_name="$1"

    sqlite3 "$DB_FILE" <<EOF
BEGIN IMMEDIATE;
DELETE FROM instance_dirs WHERE instance_name = '$(sql_escape "$instance_name")';
DELETE FROM instances WHERE name = '$(sql_escape "$instance_name")';
COMMIT;
EOF
}

vm_destroy_instance() {
    local instance_name="$1"
    local vm_name

    vm_name="$(vm_get_instance_vm_name "$instance_name")"
    [[ -n "$vm_name" ]] || abort "Error: instance not found ($instance_name)"

    if get_vm_exists "$vm_name"; then
        stop_vm "$vm_name"
        tart delete "$vm_name" 2>/dev/null || true
        if get_vm_exists "$vm_name"; then
            abort "Failed to delete VM $vm_name — DB records kept so destroy can be retried"
        fi
    fi

    vm_delete_instance_records "$instance_name"
}

vm_destroy() {
    [[ $# -gt 0 ]] || abort "Usage: clod destroy <name> | --all"

    if [[ "${1:-}" == "--all" ]]; then
        [[ $# -eq 1 ]] || abort "Error: destroy --all does not accept additional arguments"

        local instance_names
        instance_names="$(vm_get_instance_names)"
        if [[ -n "$instance_names" ]]; then
            local instance_name
            while IFS= read -r instance_name; do
                [[ -n "$instance_name" ]] || continue
                vm_destroy_instance "$instance_name"
            done <<< "$instance_names"
        fi
        return 0
    fi

    [[ $# -eq 1 ]] || abort "Error: destroy accepts exactly one instance name"
    vm_destroy_instance "$1"
}

vm_set() {
    local ram_value=""
    local ram_name=""
    local max_memory_value=""
    local vm_count_value=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ram)
                [[ $# -ge 2 ]] || abort "Usage: clod set --ram <size|default> <name>"
                ram_value="$2"
                shift 2
                if [[ $# -ge 1 ]] && [[ "$1" != -* ]]; then
                    ram_name="$1"
                    shift
                else
                    abort "Usage: clod set --ram <size|default> <name>"
                fi
                ;;
            --max-memory)
                [[ $# -ge 2 ]] || abort "Usage: clod set --max-memory <size|default>"
                max_memory_value="$2"
                shift 2
                ;;
            --vm-count)
                [[ $# -ge 2 ]] || abort "Usage: clod set --vm-count <N|default>"
                vm_count_value="$2"
                shift 2
                ;;
            *)
                abort "Error: unknown set option ($1)"
                ;;
        esac
    done

    if [[ -n "$ram_value" ]]; then
        [[ -n "$ram_name" ]] || abort "Usage: clod set --ram <size|default> <name>"
        if ! vm_instance_exists "$ram_name"; then
            abort "Error: instance not found ($ram_name)"
        fi

        if [[ "$ram_value" == "default" ]]; then
            sqlite3 "$DB_FILE" "UPDATE instances SET ram_mb = NULL WHERE name = '$(sql_escape "$ram_name")';"
            info "Reset RAM for $ram_name to dynamic (budget)"
        else
            local ram_mb
            ram_mb="$(parse_ram_size "$ram_value")"
            sqlite3 "$DB_FILE" "UPDATE instances SET ram_mb = $ram_mb WHERE name = '$(sql_escape "$ram_name")';"
            info "Set RAM for $ram_name to ${ram_mb} MB"
        fi

        # Warn if instance is running
        local vm_name
        vm_name="$(vm_get_instance_vm_name "$ram_name")"
        if [[ -n "$vm_name" ]] && [[ "$(get_vm_state "$vm_name")" == "running" ]]; then
            warn "Instance $ram_name is running — change takes effect on next launch"
        fi
    fi

    if [[ -n "$max_memory_value" ]]; then
        if [[ "$max_memory_value" == "default" ]]; then
            sqlite3 "$DB_FILE" "DELETE FROM settings WHERE key = 'max_memory_mb';"
            info "Reset memory budget to default (5/8 of host RAM)"
        else
            local budget_mb
            budget_mb="$(parse_ram_size "$max_memory_value")"

            # Validate against host RAM
            local host_ram_mb
            host_ram_mb="$(( $(sysctl -n hw.memsize) / 1048576 ))"
            if [[ "$budget_mb" -gt "$host_ram_mb" ]]; then
                abort "Budget (${budget_mb} MB) exceeds host RAM (${host_ram_mb} MB)"
            fi

            set_setting "max_memory_mb" "$budget_mb"
            info "Set memory budget to ${budget_mb} MB"

            # Warn if current usage exceeds new budget
            local used_mb
            used_mb="$(get_running_vms_ram_mb "")"
            if [[ "$used_mb" -gt "$budget_mb" ]]; then
                warn "Current usage (${used_mb} MB) exceeds new budget (${budget_mb} MB). No running VMs affected — budget enforced on next launch."
            fi
        fi
    fi

    if [[ -n "$vm_count_value" ]]; then
        if [[ "$vm_count_value" == "default" ]]; then
            sqlite3 "$DB_FILE" "DELETE FROM settings WHERE key = 'vm_count';"
            info "Reset VM count to default (1)"
        else
            if [[ ! "$vm_count_value" =~ ^[0-9]+$ ]] || [[ "$vm_count_value" -lt 1 ]]; then
                abort "VM count must be a positive integer (got '$vm_count_value')"
            fi
            set_setting "vm_count" "$vm_count_value"
            local per_vm_mb
            per_vm_mb="$(( $(get_memory_budget_mb) / vm_count_value ))"
            info "Set VM count to ${vm_count_value} (${per_vm_mb} MB per VM)"
            if [[ "$per_vm_mb" -lt 2048 ]]; then
                warn "Per-VM share (${per_vm_mb} MB) is below minimum 2048 MB. Dynamic launches will fail."
            fi
        fi
    fi

    if [[ -z "$ram_value" ]] && [[ -z "$max_memory_value" ]] && [[ -z "$vm_count_value" ]]; then
        abort "Usage: clod set [--ram <size|default> <name>] [--max-memory <size|default>] [--vm-count <N|default>]"
    fi
}

vm_create() {
    local instance_name="${1:-}"
    shift || true

    [[ -n "$instance_name" ]] || abort "Usage: clod create <name> [--dir name:path]..."
    vm_validate_name "$instance_name"

    if vm_instance_exists "$instance_name"; then
        abort "Error: instance already exists ($instance_name)"
    fi

    local final_vm_name
    final_vm_name="$(vm_name_to_vm_name "$instance_name")"
    if get_vm_exists "$final_vm_name"; then
        abort "Error: tart VM already exists outside the database ($final_vm_name)"
    fi

    local create_ram_mb=""
    local dir_names=()
    local dir_paths=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ram)
                [[ $# -ge 2 ]] || abort "Error: --ram requires a size value (e.g. 8G)"
                create_ram_mb="$(parse_ram_size "$2")"
                shift 2
                ;;
            --dir)
                [[ $# -ge 2 ]] || abort "Error: --dir requires name:path"

                local dir_spec="$2"
                shift 2

                [[ "$dir_spec" == *:* ]] || abort "Error: invalid --dir value ($dir_spec)"
                local dir_name="${dir_spec%%:*}"
                local dir_path_spec="${dir_spec#*:}"
                [[ -n "$dir_name" ]] || abort "Error: missing directory name in --dir"
                [[ -n "$dir_path_spec" ]] || abort "Error: missing directory path in --dir"
                [[ "$dir_name" != "__install" ]] || abort "Error: reserved directory name (__install)"
                if array_contains "$dir_name" ${dir_names[@]+"${dir_names[@]}"}; then
                    abort "Error: duplicate --dir name ($dir_name)"
                fi

                local dir_path
                dir_path="$(resolve_physical_path "$dir_path_spec" 2>/dev/null || true)"
                if [[ ! -d "$dir_path" ]]; then
                    abort "Error: directory not found ($dir_path_spec)"
                fi

                dir_names+=("$dir_name")
                dir_paths+=("$dir_path")
                ;;
            *)
                abort "Error: unknown create option ($1)"
                ;;
        esac
    done

    if ! get_vm_exists "$BASE_VM_NAME"; then
        abort "Error: base VM missing. Run 'clod shell' first to bootstrap it."
    fi

    ensure_ssh_key
    refresh_guest_home

    TMP_VM_NAME="clodpod-tmp-$(openssl rand -hex 8)"
    trap cleanup_tmp_vm EXIT

    clone_vm "$BASE_VM_NAME" "$TMP_VM_NAME"

    local vm_args=()
    local i=0
    while [[ "$i" -lt "${#dir_names[@]}" ]]; do
        vm_args+=("--dir" "${dir_names[$i]}:${dir_paths[$i]}")
        i=$((i + 1))
    done
    vm_args+=("--dir" "__install:$DATA_DIR/guest")
    vm_run "$TMP_VM_NAME" 0 "" "${vm_args[@]}"

    trace "Running configure.sh..."
    if ! tart exec -it "$TMP_VM_NAME" \
        "/usr/bin/env" "VERBOSE=$VERBOSE" bash \
        "/Volumes/My Shared Files/__install/configure.sh"; then
        abort "configure.sh failed — named VM will not be saved"
    fi

    trace "Stopping $TMP_VM_NAME to flush directory service writes..."
    stop_vm "$TMP_VM_NAME"

    trace "Renaming $TMP_VM_NAME to $final_vm_name"
    tart rename "$TMP_VM_NAME" "$final_vm_name"
    TMP_VM_NAME=""

    local sql
    local ram_sql="NULL"
    if [[ -n "$create_ram_mb" ]]; then
        ram_sql="$create_ram_mb"
    fi
    sql="BEGIN IMMEDIATE;
INSERT INTO instances (name, vm_name, ram_mb, created_at)
VALUES ('$(sql_escape "$instance_name")', '$(sql_escape "$final_vm_name")', $ram_sql, datetime('now'));"

    i=0
    while [[ "$i" -lt "${#dir_names[@]}" ]]; do
        local is_primary=0
        if [[ "$i" -eq 0 ]]; then
            is_primary=1
        fi
        sql="${sql}
INSERT INTO instance_dirs (instance_name, dir_name, dir_path, is_primary)
VALUES ('$(sql_escape "$instance_name")', '$(sql_escape "${dir_names[$i]}")', '$(sql_escape "${dir_paths[$i]}")', $is_primary);"
        i=$((i + 1))
    done
    sql="${sql}
COMMIT;"

    if ! printf '%s\n' "$sql" | sqlite3 "$DB_FILE"; then
        warn "DB insert failed — removing VM $final_vm_name"
        tart delete "$final_vm_name" 2>/dev/null || true
        if get_vm_exists "$final_vm_name"; then
            abort "Failed to record instance AND failed to delete VM $final_vm_name — orphan VM left behind"
        fi
        abort "Failed to record instance $instance_name"
    fi

    info "Created instance $instance_name"
}
