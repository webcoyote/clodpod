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
        abort "Cannot connect to $vm_name at $ipaddr:22"
    fi

    echo "$ipaddr"
}

# Escape a value for safe transmission as an SSH env var.
# Wraps in single quotes, escaping any embedded single quotes.
ssh_quote_env() { printf "%s='%s'" "$1" "${2//\'/\'\\\'\'}"; }

# Configure macOS system proxy via networksetup over SSH. NSURLSession-backed
# tools (xcodebuild's SwiftPM, system frameworks, anything via CFNetwork) read
# proxy settings from CFNetworkCopySystemProxySettings(), NOT from HTTP_PROXY
# env vars. Without this, those tools bypass tinyproxy entirely and either hit
# the softnet block (timeouts) or fail to reach allowed hosts.
#
# Sets system web/secure-web proxy when $proxy_url is non-empty; disables both
# when empty (so a no-firewall session after a firewall session doesn't inherit
# stale settings).
#
# Requires NOPASSWD sudo for `networksetup` on the VM — provided by
# ALLOW_SUDO=true at build-base time.
vm_apply_system_proxy() {
    local ssh_user="$1"
    local ipaddr="$2"
    local proxy_url="$3"
    local host="" port=""

    if [[ -n "$proxy_url" ]]; then
        host="${proxy_url#http://}"
        port="${host##*:}"
        host="${host%:*}"
    fi

    local proxy_output
    if ! proxy_output=$(ssh -q \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes \
        -i "$SSH_KEYFILE_PRIV" \
        "$ssh_user@$ipaddr" \
        "PROXY_HOST='$host' PROXY_PORT='$port' bash -s" <<'REMOTE' 2>&1
set -e
# Pick the network service whose Device matches the default-route interface.
# A plain "first non-disabled service" picks up virtual ports (e.g.
# com.redhat.spice.0 from SPICE virtio) that don't carry VM traffic, so the
# proxy gets set on an interface NSURLSession never uses.
default_dev=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
if [ -z "$default_dev" ]; then
    echo "ERROR: no default route — VM networking is down" >&2
    exit 1
fi
svc=$(networksetup -listnetworkserviceorder 2>/dev/null | awk -v dev="$default_dev" '
    /^\([0-9]+\)/ { name=$0; sub(/^\([0-9]+\) /, "", name); next }
    /Device:/ && index($0, "Device: " dev ")") { print name; exit }
')
if [ -z "$svc" ]; then
    echo "ERROR: no networksetup service maps to default-route device $default_dev" >&2
    networksetup -listnetworkserviceorder >&2 || true
    exit 1
fi
echo "system proxy: service=$svc (device=$default_dev)"
if [ -n "$PROXY_HOST" ]; then
    sudo -n networksetup -setwebproxy           "$svc" "$PROXY_HOST" "$PROXY_PORT"
    sudo -n networksetup -setsecurewebproxy     "$svc" "$PROXY_HOST" "$PROXY_PORT"
    sudo -n networksetup -setproxybypassdomains "$svc" localhost 127.0.0.1 '*.local'
    echo "system proxy: HTTPS=$(networksetup -getsecurewebproxy "$svc" | tr '\n' ' ')"
else
    sudo -n networksetup -setwebproxystate       "$svc" off || true
    sudo -n networksetup -setsecurewebproxystate "$svc" off || true
fi
REMOTE
    ); then
        warn "system proxy: networksetup call failed — NSURLSession-backed tools (xcodebuild/SwiftPM) will bypass the firewall and time out"
        if [[ -n "$proxy_output" ]]; then
            printf '%s\n' "$proxy_output" | sed 's/^/  | /' >&2
        fi
        return
    fi
    if [[ -n "$proxy_output" ]] && [[ "$VERBOSE" -ge 2 ]]; then
        printf '%s\n' "$proxy_output" | sed 's/^/  | /' >&2
    fi
}

ssh_into_vm() {
    local vm_name="$1"
    local ssh_user="${2:-admin}"
    local project_name="${3:-}"
    local initial_dir="${4:-}"
    local ipaddr
    local command_args_b64

    ipaddr="$(get_vm_ip_or_abort "$vm_name")"
    debug "Connect to $vm_name (ssh $ssh_user@$ipaddr)"

    command_args_b64="$(encode_command_args)"

    local forward_args=()
    local port
    if [[ "${#FORWARD_PORTS[@]}" -gt 0 ]]; then
        for port in "${FORWARD_PORTS[@]}"; do
            forward_args+=("-R" "${port}:127.0.0.1:${port}")
        done
    fi
    if [[ -n "${CLOD_FORWARD_PORTS:-}" ]]; then
        local _env_ports
        IFS=',' read -ra _env_ports <<< "$CLOD_FORWARD_PORTS"
        for port in "${_env_ports[@]}"; do
            if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
                abort "Error: CLOD_FORWARD_PORTS contains invalid port ('$port'); must be 1-65535"
            fi
            forward_args+=("-R" "${port}:127.0.0.1:${port}")
        done
    fi

    # Build proxy env vars when firewall is active.
    # Detect gateway now — bridge100 is up after VM boot.
    local proxy_env=()
    local proxy_url=""
    if [[ -n "${CLODPOD_FIREWALL:-}" ]]; then
        proxy_url="$(firewall_proxy_url)"
        debug "firewall: proxy_url=$proxy_url (gateway=$(firewall_detect_gateway))"
        proxy_env+=(
            "HTTP_PROXY=$proxy_url"
            "HTTPS_PROXY=$proxy_url"
            "http_proxy=$proxy_url"
            "https_proxy=$proxy_url"
            "NO_PROXY=localhost,127.0.0.1,.local"
            "no_proxy=localhost,127.0.0.1,.local"
        )
    fi

    # Apply (or clear) macOS system proxy. Required for NSURLSession-backed
    # tools — see vm_apply_system_proxy for details. Empty $proxy_url disables.
    vm_apply_system_proxy "$ssh_user" "$ipaddr" "$proxy_url"

    ssh \
        -q \
        -tt \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes \
        -i "$SSH_KEYFILE_PRIV" \
        ${forward_args[@]+"${forward_args[@]}"} \
        "$ssh_user@$ipaddr" \
        /usr/bin/env \
            "TERM=xterm-256color" \
            ${COLORTERM:+"COLORTERM=$COLORTERM"} \
            "$(ssh_quote_env PROJECT "$project_name")" \
            "$(ssh_quote_env INITIAL_DIR "$initial_dir")" \
            "$(ssh_quote_env COMMAND "${COMMAND:-}")" \
            "COMMAND_ARGS_B64=$command_args_b64" \
            ${proxy_env[@]+"${proxy_env[@]}"} \
            zsh --login
}

vm_sync_authorized_key() {
    local vm_name="$1"
    local ssh_user="${2:-admin}"
    local pub_key_b64

    pub_key_b64="$(base64 < "$SSH_KEYFILE_PUB" | tr -d '\n')"
    # shellcheck disable=SC2016 #  Expressions don't expand in single quotes, use double quotes for that.
    if [[ "$ssh_user" == "admin" ]]; then
        # No sudo needed — tart exec runs as admin, admin owns .ssh
        tart exec "$vm_name" \
            "/usr/bin/env" "PUB_KEY_B64=$pub_key_b64" \
            bash -lc '
                install -d -m 700 /Users/admin/.ssh
                printf "%s" "$PUB_KEY_B64" | /usr/bin/base64 -D > /Users/admin/.ssh/authorized_keys
                chmod 600 /Users/admin/.ssh/authorized_keys
            '
    else
        # Legacy: clodpod user needs sudo
        tart exec "$vm_name" \
            "/usr/bin/env" "PUB_KEY_B64=$pub_key_b64" \
            bash -lc '
                sudo install -d -m 700 -o clodpod -g clodpod /Users/clodpod/.ssh
                printf "%s" "$PUB_KEY_B64" | /usr/bin/base64 -D | sudo tee /Users/clodpod/.ssh/authorized_keys >/dev/null
                sudo chown clodpod:clodpod /Users/clodpod/.ssh/authorized_keys
                sudo chmod 600 /Users/clodpod/.ssh/authorized_keys
            '
    fi
}

vm_list() {
    local result
    result=$(sqlite3 -separator '|' "$DB_FILE" <<EOF || return 1
SELECT name, vm_name, ram_mb, COALESCE(base_name, '-'), COALESCE(ssh_user, 'clodpod') FROM instances ORDER BY created_at DESC, name ASC;
EOF
)

    [[ -n "$result" ]] || return 1

    echo "INSTANCES"
    printf "%-20s %-10s %-10s %-8s %-12s %-15s %s\n" "NAME" "BASE" "RAM (MB)" "USER" "STATE" "IP" "DIRS"

    local instance_name
    local vm_name
    local stored_ram
    local base_name
    local ssh_user
    while IFS='|' read -r instance_name vm_name stored_ram base_name ssh_user; do
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

        printf "%-20s %-10s %-10s %-8s %-12s %-15s %s\n" "$instance_name" "$base_name" "$ram_display" "$ssh_user" "$state" "$ipaddr" "$dirs"
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

    # Firewall: add softnet flags to isolate VM networking
    if [[ -n "${CLODPOD_FIREWALL:-}" ]]; then
        while IFS= read -r flag; do
            dir_args+=("$flag")
        done < <(firewall_softnet_args)
    fi

    if [[ "$(get_vm_state "$vm_name")" == "running" ]]; then
        # VM already running — warn if --ram override given, then reconnect
        if [[ -n "${SHELL_RAM_OVERRIDE:-}" ]]; then
            local current_ram
            current_ram="$(tart get "$vm_name" --format json | jq '.Memory' 2>/dev/null || echo "?")"
            warn "$instance_name is already running with ${current_ram} MB RAM. --ram override ignored for running VM."
        fi
        # xcode reads dirs from the projects table; new projects need a restart
        # to be mounted. Mirrors the legacy `check_projects_active` UX.
        if [[ "$instance_name" == "xcode" ]] && ! check_projects_active; then
            warn "New project directory added; virtual machine restart required"
            read -p "$vm_name is running; restart it? (y/N)" -n 1 -r response
            echo
            if [[ "$response" =~ ^[Yy]$ ]]; then
                stop_vm "$vm_name"
                vm_run "$vm_name" "$effective_ram" "$vm_name" ${dir_args[@]+"${dir_args[@]}"} || true
                [[ "$instance_name" == "xcode" ]] && sqlite3 "$DB_FILE" "UPDATE projects SET active = 1;"
            fi
        fi
        if [[ -n "${CLODPOD_FIREWALL:-}" ]]; then
            warn "$instance_name is already running — softnet isolation requires restart. Run: clod stop $instance_name"
        fi
    else
        vm_run "$vm_name" "$effective_ram" "$vm_name" ${dir_args[@]+"${dir_args[@]}"} || true
        [[ "$instance_name" == "xcode" ]] && sqlite3 "$DB_FILE" "UPDATE projects SET active = 1;"
    fi

    local ssh_user
    ssh_user="$(vm_get_ssh_user "$instance_name")"
    if [[ "$ssh_user" == "clodpod" ]]; then
        info "Instance $instance_name uses legacy clodpod user."
        info "Recreate to use admin: clod destroy $instance_name && clod create $instance_name --dir ..."
    fi

    if [[ "${SSH_KEY_CREATED:-false}" == "true" ]]; then
        vm_sync_authorized_key "$vm_name" "$ssh_user"
    fi

    local initial_dir=""
    if [[ -n "$primary_path" ]]; then
        initial_dir="$(get_relative_directory_from_root "$primary_path" 2>/dev/null || true)"
        debug "initial directory: ${initial_dir:-}"
    fi

    ssh_into_vm "$vm_name" "$ssh_user" "$primary_name" "$initial_dir"
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

# Boot a named instance without connecting. Mounts the same --dir arguments
# vm_shell does so a later `clod shell <name>` reconnects to a VM that already
# has the project dirs mapped; reusing a no-dir start would force a restart.
vm_start_instance() {
    local instance_name="$1"
    local vm_name
    local effective_ram

    vm_name="$(vm_get_instance_vm_name "$instance_name")"
    [[ -n "$vm_name" ]] || abort "Error: instance not found ($instance_name)"

    if ! get_vm_exists "$vm_name"; then
        abort "Error: VM missing for instance $instance_name ($vm_name). Destroy and recreate it."
    fi

    if [[ "$(get_vm_state "$vm_name")" == "running" ]]; then
        info "Instance $instance_name is already running"
        return 0
    fi

    effective_ram="$(vm_get_instance_ram_mb "$instance_name")"
    [[ "$effective_ram" =~ ^[0-9]+$ ]] || effective_ram=0

    local dir_args=()
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
        done <<< "$dir_rows"
    fi

    # Firewall: add softnet flags to isolate VM networking
    if [[ -n "${CLODPOD_FIREWALL:-}" ]]; then
        while IFS= read -r flag; do
            dir_args+=("$flag")
        done < <(firewall_softnet_args)
    fi

    info "Starting instance $instance_name ($vm_name)"
    vm_run "$vm_name" "$effective_ram" "$vm_name" ${dir_args[@]+"${dir_args[@]}"} || true
    [[ "$instance_name" == "xcode" ]] && sqlite3 "$DB_FILE" "UPDATE projects SET active = 1;"
}

# Auto-select target by name, by sole instance, or abort. Mirrors the policy
# used by `clod destroy` and `clod shell` so `clod start [name]` behaves the
# same way users already expect from other named-instance commands.
vm_start_dispatch() {
    local target="${1:-}"

    if [[ -n "$target" ]]; then
        if ! vm_instance_exists "$target"; then
            if base_exists "$target"; then
                abort "'$target' is a base, not an instance. Create an instance first: clod create <name> --dir name:path"
            fi
            abort "No instance named '$target'"
        fi
        vm_start_instance "$target"
        return 0
    fi

    local instance_count
    instance_count="$(vm_get_instance_count 2>/dev/null || echo 0)"
    if [[ "${instance_count:-0}" -eq 1 ]]; then
        local only_name
        only_name="$(vm_get_only_instance_name)"
        vm_start_instance "$only_name"
        return 0
    elif [[ "${instance_count:-0}" -gt 1 ]]; then
        vm_list
        abort "Multiple instances exist. Specify name: clod start <name>"
    fi

    # No named instances — fall through so caller can run legacy start.
    return 1
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

    [[ $# -le 1 ]] || abort "Error: destroy accepts exactly one instance name"

    local target="${1:-}"

    # If a name was given but doesn't exist, don't auto-select a different instance
    if [[ -n "$target" ]] && ! vm_instance_exists "$target"; then
        if base_exists "$target"; then
            abort "'$target' is a base, not an instance. Create an instance first: clod create <name> --dir name:path"
        fi
        abort "No instance named '$target'"
    fi

    # Auto-select when no name given
    if [[ -z "$target" ]]; then
        local instance_count
        instance_count="$(vm_get_instance_count 2>/dev/null || echo 0)"
        if [[ "${instance_count:-0}" -eq 1 ]]; then
            local only_name
            only_name="$(vm_get_only_instance_name)"
            vm_destroy_instance "$only_name"
            return 0
        elif [[ "${instance_count:-0}" -gt 1 ]]; then
            vm_list
            abort "Multiple instances exist. Specify name: clod destroy <name>"
        else
            abort "No instances to destroy"
        fi
    fi

    vm_destroy_instance "$target"
}

vm_set() {
    local ram_value=""
    local ram_name=""
    local max_memory_value=""
    local vm_count_value=""
    local dir_value=""
    local dir_name_target=""
    local dir_remove_value=""
    local dir_remove_target=""

    local _instance_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ram)
                [[ $# -ge 2 ]] || abort "Usage: clod set --ram <size|default> <name>"
                ram_value="$2"
                shift 2
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
            --dir)
                [[ -z "$dir_value" && -z "$dir_remove_value" ]] || abort "Error: only one --dir operation allowed per command"
                [[ $# -ge 2 ]] || abort "Usage: clod set --dir name:path <name>"
                dir_value="$2"
                shift 2
                ;;
            --dir-remove)
                [[ -z "$dir_value" && -z "$dir_remove_value" ]] || abort "Error: only one --dir operation allowed per command"
                [[ $# -ge 2 ]] || abort "Usage: clod set --dir-remove <dir_name> <name>"
                dir_remove_value="$2"
                shift 2
                ;;
            -*)
                abort "Error: unknown set option ($1)"
                ;;
            *)
                [[ -z "$_instance_name" ]] || abort "Error: multiple instance names ($1 vs $_instance_name)"
                _instance_name="$1"
                shift
                ;;
        esac
    done

    if [[ -n "$ram_value" ]] || [[ -n "$dir_value" ]] || [[ -n "$dir_remove_value" ]]; then
        [[ -n "$_instance_name" ]] || abort "Error: instance name required"
        ram_name="$_instance_name"
        dir_name_target="$_instance_name"
        dir_remove_target="$_instance_name"
    fi

    if [[ -n "$dir_value" ]]; then
        vm_instance_exists "$dir_name_target" || abort "Error: instance not found ($dir_name_target)"

        local parsed
        parsed="$(parse_dir_spec "$dir_value")" || abort "Error: invalid --dir value ($dir_value)"

        local dir_name="${parsed%%|*}"
        local dir_path_spec="${parsed#*|}"

        [[ "$dir_name" != "__install" ]] || abort "Error: reserved directory name (__install)"

        local dir_path
        dir_path="$(resolve_physical_path "$dir_path_spec" 2>/dev/null || true)"
        [[ -d "$dir_path" ]] || abort "Error: directory not found ($dir_path_spec)"

        local existing_primary
        existing_primary="$(sqlite3 "$DB_FILE" "SELECT is_primary FROM instance_dirs WHERE instance_name = '$(sql_escape "$dir_name_target")' AND dir_name = '$(sql_escape "$dir_name")';")"
        local is_primary="${existing_primary:-0}"
        local existed=""
        [[ -n "$existing_primary" ]] && existed="(replaced)"

        sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO instance_dirs (instance_name, dir_name, dir_path, is_primary) VALUES ('$(sql_escape "$dir_name_target")', '$(sql_escape "$dir_name")', '$(sql_escape "$dir_path")', $is_primary);" || abort "Error: failed to write mount to database"
        info "Set --dir ${dir_name} for ${dir_name_target}${existed:+ $existed}"

        local vm_name
        vm_name="$(vm_get_instance_vm_name "$dir_name_target")"
        if [[ -n "$vm_name" ]] && [[ "$(get_vm_state "$vm_name")" == "running" ]]; then
            warn "Instance $dir_name_target is running — change takes effect on next launch"
        fi
    fi

    if [[ -n "$dir_remove_value" ]]; then
        vm_instance_exists "$dir_remove_target" || abort "Error: instance not found ($dir_remove_target)"

        local row_primary
        row_primary="$(sqlite3 "$DB_FILE" "SELECT is_primary FROM instance_dirs WHERE instance_name = '$(sql_escape "$dir_remove_target")' AND dir_name = '$(sql_escape "$dir_remove_value")';")"

        if [[ -z "$row_primary" ]]; then
            abort "Error: directory '$dir_remove_value' not found on $dir_remove_target"
        else
            if [[ "$row_primary" -eq 1 ]]; then
                abort "Cannot remove primary directory '$dir_remove_value' from $dir_remove_target. Destroy and recreate the instance instead."
            fi
            sqlite3 "$DB_FILE" "DELETE FROM instance_dirs WHERE instance_name = '$(sql_escape "$dir_remove_target")' AND dir_name = '$(sql_escape "$dir_remove_value")';" || abort "Error: failed to remove mount from database"
            info "Removed --dir ${dir_remove_value} from ${dir_remove_target}"

            local vm_name
            vm_name="$(vm_get_instance_vm_name "$dir_remove_target")"
            if [[ -n "$vm_name" ]] && [[ "$(get_vm_state "$vm_name")" == "running" ]]; then
                warn "Instance $dir_remove_target is running — change takes effect on next launch"
            fi
        fi
    fi

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

    if [[ -z "$ram_value" ]] && [[ -z "$max_memory_value" ]] && [[ -z "$vm_count_value" ]] && [[ -z "$dir_value" ]] && [[ -z "$dir_remove_value" ]]; then
        abort "Usage: clod set [options] [NAME]. Run 'clod help set' for details."
    fi
}

# Build the 'xcode' default instance from the default base. Mounts the
# projects table during configure so post-install scripts see them, then
# registers the instance row. Runs the base build first if needed.
_vm_build_xcode_from_base() {
    local final_vm_name="clodpod-xcode"

    if get_vm_exists "$final_vm_name"; then
        abort "Error: tart VM already exists outside the database ($final_vm_name)"
    fi

    local base_vm
    base_vm="$(base_get_vm_name "default")"
    if [[ -z "$base_vm" ]] || ! get_vm_exists "$base_vm"; then
        abort "Error: default base missing. Run 'clod build-base' first."
    fi

    ALLOW_SUDO="${ALLOW_SUDO:-$(get_setting "allow_sudo" "false")}"

    ensure_ssh_key
    refresh_guest_home

    TMP_VM_NAME="clodpod-tmp-$(openssl rand -hex 8)"
    trap cleanup_tmp_vm EXIT

    clone_vm "$base_vm" "$TMP_VM_NAME"

    # Mount projects (so configure.sh sees them) plus __install for the script
    local run_args=()
    while IFS= read -r -d '' arg; do
        run_args+=("$arg")
    done < <(get_map_directories)
    vm_run "$TMP_VM_NAME" 0 "" "${run_args[@]}"

    trace "Running configure.sh..."
    if ! tart exec -it "$TMP_VM_NAME" \
        "/usr/bin/env" "VERBOSE=$VERBOSE" "ALLOW_SUDO=${ALLOW_SUDO:-false}" bash \
        "/Volumes/My Shared Files/__install/configure.sh"; then
        abort "configure.sh failed — xcode VM will not be saved"
    fi

    trace "Stopping $TMP_VM_NAME to flush directory service writes..."
    stop_vm "$TMP_VM_NAME"

    trace "Renaming $TMP_VM_NAME to $final_vm_name"
    tart rename "$TMP_VM_NAME" "$final_vm_name"
    TMP_VM_NAME=""

    if ! sqlite3 "$DB_FILE" <<EOF
INSERT INTO instances (name, vm_name, ram_mb, base_name, ssh_user, created_at)
VALUES ('xcode', '$final_vm_name', NULL, 'default', 'admin', datetime('now'));
EOF
    then
        warn "DB insert failed — removing VM $final_vm_name"
        tart delete "$final_vm_name" 2>/dev/null || true
        abort "Failed to record xcode instance"
    fi

    # Mark all projects as active after build
    sqlite3 "$DB_FILE" "UPDATE projects SET active = 1;"

    info "Built xcode instance"
}

# Ensure the 'xcode' default instance exists, building base + VM as needed.
vm_ensure_xcode_instance() {
    if vm_instance_exists "xcode"; then
        return 0
    fi

    # Build the base if it doesn't exist (one-time, matches legacy first-run UX)
    if ! get_vm_exists "$BASE_VM_NAME"; then
        REBUILD_BASE=true
        prepare_rebuilds
        build_base_vm
    fi

    _vm_build_xcode_from_base
}

vm_create() {
    local instance_name="${1:-}"
    shift || true

    [[ -n "$instance_name" ]] || abort "Usage: clod create <name> [--dir name:path]..."

    # 'xcode' is the auto-managed default instance. Mounts come from the
    # projects table, not --dir. Create it implicitly via bare `clod`.
    # This check beats vm_validate_name's generic 'reserved' message.
    if [[ "$instance_name" == "xcode" ]]; then
        abort "Error: 'xcode' is the default instance and is managed automatically. Use bare 'clod' or 'clod claude /path' to mount directories."
    fi

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
    local create_base="default"
    local dir_names=()
    local dir_paths=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base)
                [[ $# -ge 2 ]] || abort "Error: --base requires a profile name"
                create_base="$2"
                shift 2
                ;;
            --ram)
                [[ $# -ge 2 ]] || abort "Error: --ram requires a size value (e.g. 8G)"
                create_ram_mb="$(parse_ram_size "$2")"
                shift 2
                ;;
            --dir)
                [[ $# -ge 2 ]] || abort "Error: --dir requires name:path"

                local parsed
                parsed="$(parse_dir_spec "$2")" || abort "Error: invalid --dir value ($2)"
                shift 2

                local dir_name="${parsed%%|*}"
                local dir_path_spec="${parsed#*|}"
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

    # Validate base/profile name (prevent path traversal)
    if [[ ! "$create_base" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
        abort "Error: invalid base name ($create_base)"
    fi

    local base_vm
    base_vm="$(base_get_vm_name "$create_base")"
    if [[ -z "$base_vm" ]]; then
        abort "Error: base '$create_base' not found. Run 'clod build-base --profile $create_base' first."
    fi
    if ! get_vm_exists "$base_vm"; then
        abort "Error: base VM missing ($base_vm). Run 'clod build-base --profile $create_base' to rebuild."
    fi

    # Resolve ALLOW_SUDO from stored setting for configure.sh passthrough
    ALLOW_SUDO="${ALLOW_SUDO:-$(get_setting "allow_sudo" "false")}"

    ensure_ssh_key
    refresh_guest_home

    TMP_VM_NAME="clodpod-tmp-$(openssl rand -hex 8)"
    trap cleanup_tmp_vm EXIT

    clone_vm "$base_vm" "$TMP_VM_NAME"

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
        "/usr/bin/env" "VERBOSE=$VERBOSE" "ALLOW_SUDO=${ALLOW_SUDO:-false}" bash \
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
INSERT INTO instances (name, vm_name, ram_mb, base_name, ssh_user, created_at)
VALUES ('$(sql_escape "$instance_name")', '$(sql_escape "$final_vm_name")', $ram_sql, '$(sql_escape "$create_base")', 'admin', datetime('now'));"

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
