# shellcheck shell=bash
# shellcheck disable=SC2154 # globals set by config.sh and other modules
# VM lifecycle: state, run, stop, clone, delete, memory budget, naming

vm_name_to_vm_name() {
    printf 'clodpod-%s\n' "$1"
}

vm_name_reserved() {
    case "$1" in
        xcode|oci-base|xcode-base|tmp*|oci-tmp*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

vm_validate_name() {
    local name="$1"

    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
        abort "Error: invalid instance name ($name)"
    fi
    if vm_name_reserved "$name"; then
        abort "Error: reserved instance name ($name)"
    fi
}

parse_ram_size() {
    local input="${1:-}"
    local value
    local unit
    local ram_mb

    if [[ ! "$input" =~ ^([0-9]+)([GgMm]?)$ ]]; then
        abort "Invalid RAM size '$input'. Use values like 8G, 8192M, or 8192."
    fi

    value="${BASH_REMATCH[1]}"
    unit="$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')"

    if [[ "$value" -le 0 ]]; then
        abort "RAM size must be positive (got '$input')"
    fi

    case "$unit" in
        g)
            ram_mb=$((value * 1024))
            ;;
        m|"")
            ram_mb="$value"
            ;;
        *)
            abort "Invalid RAM size '$input'. Use values like 8G, 8192M, or 8192."
            ;;
    esac

    if [[ "$ram_mb" -lt 2048 ]]; then
        abort "RAM size must be at least 2048 MB (got ${ram_mb} MB)"
    fi

    echo "$ram_mb"
}

get_memory_budget_mb() {
    local configured_budget_mb
    configured_budget_mb="$(get_setting "max_memory_mb" "")"

    if [[ -n "$configured_budget_mb" ]]; then
        if [[ ! "$configured_budget_mb" =~ ^[0-9]+$ ]]; then
            abort "Invalid max_memory_mb setting: $configured_budget_mb"
        fi
        echo "$configured_budget_mb"
        return 0
    fi

    local host_ram_bytes
    host_ram_bytes="$(sysctl -n hw.memsize)" || abort "Failed to read host RAM"
    echo "$(( host_ram_bytes * 5 / 8 / 1048576 ))"
}

get_running_vms_ram_mb() {
    local exclude_vm="${1:-}"
    local running_vms
    local total_mb=0
    local vm_name

    if ! running_vms="$(tart list --format json | jq -r '.[] | select(.State == "running") | .Name')"; then
        abort "Failed to list running VMs"
    fi

    while IFS= read -r vm_name; do
        [[ -n "$vm_name" ]] || continue
        [[ "$vm_name" == clodpod-* ]] || continue
        [[ "$vm_name" != "$exclude_vm" ]] || continue

        local vm_ram_mb
        if ! vm_ram_mb="$(tart get "$vm_name" --format json | jq '.Memory')"; then
            abort "Failed to read memory for VM $vm_name"
        fi

        if [[ ! "$vm_ram_mb" =~ ^[0-9]+$ ]]; then
            abort "Invalid memory reported for VM $vm_name: $vm_ram_mb"
        fi

        total_mb=$((total_mb + vm_ram_mb))
    done <<< "$running_vms"

    echo "$total_mb"
}

# Call only while holding the host-global launch lock.
resolve_and_check_memory_budget() {
    local requested_mb="${1:-}"
    local exclude_vm="${2:-}"
    local budget_mb
    local used_mb
    local remaining_mb
    local resolved_mb

    if [[ ! "$requested_mb" =~ ^[0-9]+$ ]]; then
        abort "Invalid requested RAM: $requested_mb"
    fi

    budget_mb="$(get_memory_budget_mb)"
    used_mb="$(get_running_vms_ram_mb "$exclude_vm")"
    remaining_mb=$((budget_mb - used_mb))

    if [[ "$requested_mb" -eq 0 ]]; then
        local vm_count
        vm_count="$(get_setting "vm_count" "1")"
        [[ "$vm_count" =~ ^[0-9]+$ ]] && [[ "$vm_count" -ge 1 ]] || vm_count=1
        resolved_mb=$((budget_mb / vm_count))
    else
        resolved_mb="$requested_mb"
    fi

    if [[ "$resolved_mb" -lt 2048 ]]; then
        if [[ "$requested_mb" -eq 0 ]]; then
            abort "Only ${remaining_mb} MB remain in the memory budget (${used_mb} MB used of ${budget_mb} MB); minimum launch RAM is 2048 MB."
        fi
        abort "Requested RAM must be at least 2048 MB (got ${resolved_mb} MB)"
    fi

    if [[ "$resolved_mb" -gt "$remaining_mb" ]]; then
        abort "Requested ${resolved_mb} MB exceeds remaining memory budget (${remaining_mb} MB available, ${used_mb} MB used of ${budget_mb} MB)."
    fi

    echo "$resolved_mb"
}

# shellcheck disable=SC2329 # function is called dynamically
with_launch_lock() {
    local lock_dir="$HOME/.clodpod.launch.lock"
    local max_wait=30
    local elapsed=0

    while ! mkdir "$lock_dir" 2>/dev/null; do
        elapsed=$((elapsed + 1))
        if [[ "$elapsed" -ge "$max_wait" ]]; then
            abort "Launch lock timeout — another clod instance may be launching. Remove $lock_dir if stale."
        fi
        sleep 1
    done

    (
        trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
        "$@"
    )
}

install_tools () {
    # Install brew
    if ! command -v brew &> /dev/null ; then
        debug "Installing brew..."
        /usr/bin/env bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi

    debug "Installing tools..."
    local TOOLS=()
    TOOLS+=("cirruslabs/cli/tart")      # macOS and Linux VMs on Apple Silicon
    TOOLS+=("jq")                       # JSON processing tool
    TOOLS+=("netcat")                   # test connectivity to guest VM
    TOOLS+=("rush")                     # Restricted User SHell
    TOOLS+=("sqlite3")                  # database for projects

    for tool in "${TOOLS[@]}"; do
        if ! command -v "$(basename "$tool")" &>/dev/null ; then
            trace "Installing $tool..."
            if [[ "$VERBOSE" -lt 3 ]]; then
                brew install --quiet "$tool"
            else
                brew install "$tool"
            fi
        fi
    done
}

get_vm_state () {
    local vm_name="$1"
    local vm_source="${2:-local}"
    tart list --source "$vm_source" --format json \
        | jq -r ".[] | select(.Name == \"$vm_name\") | .State" 2>/dev/null \
        || echo ""
}

get_vm_state_strict () {
    local vm_name="$1"
    local vm_source="${2:-local}"
    local state

    if ! state="$(tart list --source "$vm_source" --format json \
        | jq -r --arg vm_name "$vm_name" 'first(.[] | select(.Name == $vm_name) | .State) // ""')"; then
        abort "Failed to query state for VM $vm_name"
    fi

    echo "$state"
}

get_vm_exists () {
    local vm_name="$1"
    local vm_source="${2:-local}"
    [[ "$(get_vm_state "$vm_name" "$vm_source")" != "" ]]
}

wait_vm_state () {
    local vm_name="$1"
    local desired_state="$2"
    local timeout=20
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local state
        state="$(get_vm_state "$vm_name")"
        if [[ "$state" == "$desired_state" ]]; then
            debug "VM $vm_name is $desired_state"
            return 0
        fi
        trace "⏳ Waiting for $vm_name to be $desired_state... ($elapsed/$timeout seconds)"
        sleep 1
        ((elapsed++)) || true
    done
    abort "VM $vm_name failed to be $desired_state within $timeout seconds"
}

wait_vm_running () {
    wait_vm_state "$1" "running"
}

vm_run () {
    local vm_name="$1"
    local ram_mb="${2:-0}"
    local exclude_vm="${3:-}"
    local already_running_status=200
    local launch_status=0
    shift "$(( $# >= 3 ? 3 : $# ))"

    debug "Running $vm_name"

    local run_args=("$@")
    [[ "${NO_GRAPHICS:-}" == "" ]] || run_args+=("--no-graphics")

    # shellcheck disable=SC2329 # function is called dynamically
    _vm_run_locked() {
        local current_state
        current_state="$(get_vm_state_strict "$vm_name")"
        if [[ "$current_state" == "running" ]]; then
            exit "$already_running_status"
        fi

        local resolved_ram
        resolved_ram="$(resolve_and_check_memory_budget "$ram_mb" "$exclude_vm")"
        [[ -n "$resolved_ram" ]] || exit 1
        tart set "$vm_name" --memory "$resolved_ram"
        tart run "${run_args[@]}" "$vm_name" </dev/null &>/dev/null & disown
        wait_vm_running "$vm_name"
    }

    if with_launch_lock _vm_run_locked; then
        launch_status=0
    else
        launch_status=$?
    fi

    if [[ "$launch_status" -eq "$already_running_status" ]]; then
        return 1
    fi
    if [[ "$launch_status" -ne 0 ]]; then
        exit "$launch_status"
    fi

    return 0
}

run_vm () {
    local vm_name="$1"
    local ram_mb="${2:-0}"

    # Get directories to map into the VM
    local run_args=()
    while IFS= read -r -d '' arg; do
        run_args+=("$arg")
    done < <(get_map_directories)

    local status=0
    vm_run "$vm_name" "$ram_mb" "" "${run_args[@]}" || status=$?
    if [[ "$status" -ne 0 ]]; then
        return "$status"
    fi

    # Mark all projects as active after virtual machine starts successfully
    sqlite3 "$DB_FILE" <<EOF
UPDATE projects SET active = 1;
EOF
}

stop_vm () {
    local vm_name="$1"
    if [[ "$(get_vm_state "$vm_name")" != "stopped" ]]; then
        debug "Stopping $vm_name..."
        tart stop "$vm_name"
        wait_vm_state "$vm_name" "stopped"
    fi
}

clone_vm () {
    local src_vm_name="$1"
    local dst_vm_name="$2"
    trace "Cloning $src_vm_name to $dst_vm_name..."
    tart clone "$src_vm_name" "$dst_vm_name"
    tart set "$dst_vm_name" --random-mac --random-serial
    tart set "$dst_vm_name" --cpu "$(sysctl -n hw.ncpu)"
}

stop_all_vms () {
    local running_vms
    running_vms=$(tart list --format json | jq -r '.[] | select(.State == "running") | .Name')

    info "Stopping all clodpod virtual machines"
    if [[ -n "$running_vms" ]]; then
        while IFS= read -r vm_name; do
            if [[ "$vm_name" =~ ^clodpod- ]]; then
                stop_vm "$vm_name"
            fi
            if [[ "$vm_name" =~ ^clodpod-tmp ]]; then
                delete_vm "$vm_name"
            fi
        done <<< "$running_vms"
    fi
}

delete_vm () {
    local vm_name="$1"
    if tart list --quiet | grep "^$vm_name$" >/dev/null ; then
        stop_vm "$vm_name"
        debug "Deleting $vm_name..."
        tart delete "$vm_name" &>/dev/null || true
    fi
}

cleanup_tmp_vm () {
    if [[ -n "${TMP_VM_NAME:-}" ]]; then
        delete_vm "$TMP_VM_NAME"
    fi
    if [[ -n "${TMP_OCI_VM_NAME:-}" ]]; then
        delete_vm "$TMP_OCI_VM_NAME"
    fi
    # Rollback: if old base was renamed aside but new base was never created, restore it
    if [[ -n "${OLD_BASE_VM_NAME:-}" ]]; then
        if ! tart list --quiet | grep "^${BASE_VM_NAME}$" >/dev/null 2>&1; then
            tart rename "$OLD_BASE_VM_NAME" "$BASE_VM_NAME" 2>/dev/null || true
        else
            delete_vm "$OLD_BASE_VM_NAME"
        fi
    fi
}
