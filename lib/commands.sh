# shellcheck shell=bash
# shellcheck disable=SC2154 # globals set by config.sh and other modules
# UI commands: list, help, version, status, OCI provenance

list_bases() {
    local result
    result="$(base_list)"
    [[ -n "$result" ]] || return 1

    echo "BASES"
    printf "%-20s %-15s %s\n" "NAME" "OCI SOURCE" "CREATED"

    local name _vm_name oci_source created_at
    while IFS='|' read -r name _vm_name oci_source created_at; do
        printf "%-20s %-15s %s\n" "$name" "$oci_source" "$created_at"
    done <<< "$result"
}

list_all() {
    local budget_mb
    budget_mb="$(get_memory_budget_mb)"
    local host_ram_mb
    host_ram_mb="$(( $(sysctl -n hw.memsize) / 1048576 ))"
    local vm_count
    vm_count="$(get_setting "vm_count" "1")"
    [[ "$vm_count" =~ ^[0-9]+$ ]] && [[ "$vm_count" -ge 1 ]] || vm_count=1
    local per_vm_mb=$((budget_mb / vm_count))
    echo "Memory budget: ${budget_mb} MB (of ${host_ram_mb} MB), ${vm_count} VM(s) x ${per_vm_mb} MB"
    echo ""

    if list_bases; then
        echo ""
    fi

    if vm_list; then
        echo ""
        echo "PROJECTS"
        list_projects
    else
        list_projects
    fi
}

show_version() {
    echo "clod version $VERSION"
    exit 0
}

show_help() {
    echo "Usage: clod [options] command [args...] [-- command-args...]"
    echo ""
    echo "Options:"
    echo "  --graphics           Run virtual machine with graphics (default)"
    echo "  --no-graphics        Run virtual machine without graphics"
    echo "  --rebuild-oci        Force rebuild of Layer 0 from the OCI image"
    echo "                        Prunes ALL Tart caches after Layer 0 is created"
    echo "  --rebuild-base       Force rebuild of the base image from Layer 0 (brew update)"
    echo "  --rebuild-dst        Force rebuild of the final image (update \$HOME)"
    echo "  --allow-sudo         Allow passwordless sudo for clodpod user (rebuilds if setting changed)"
    echo "  --no-allow-sudo      Disallow sudo for clodpod user (rebuilds if setting changed)"
    echo "  --ram SIZE           Set RAM for this shell session (e.g. 8G, 8192M). Named VMs only"
    echo "  -n|--no-select       Disable interactive project selection"
    echo "  -v, --verbose        Enable verbose output (repeat for more verbosity)"
    echo "  -vv                  Set verbosity level 2"
    echo "  -vvv                 Set verbosity level 3"
    echo "  -h, --help           Show this help message"
    echo "  --version            Show version information"
    echo ""
    echo "Commands:"
    echo "  cl, claude [PATH] [NAME]  Run Claude Code"
    echo "  co, codex  [PATH] [NAME]  Run OpenAI Codex"
    echo "  cu, cursor [PATH] [NAME]  Run Cursor Agent"
    echo "  g,  gemini [PATH] [NAME]  Run Google Gemini"
    echo "      build-base [--profile NAME] [--install-script PATH]"
    echo "                           Build a base image with optional profile and interactive session"
    echo "  cr, create NAME [--ram SIZE] [--dir name:path ...]"
    echo "                           Create a named VM from the base image"
    echo "  s,  shell  [NAME|PATH] [NAME]"
    echo "                           Run zsh shell for a named VM or legacy project"
    echo "  a,  add PATH [NAME]       Add a new project"
    echo "  rm, remove <identifier>   Remove project by name or path"
    echo "  ls, list                  List named instances and projects"
    echo "  st, status                Show sudo, Layer 0/base/dst state, and image provenance"
    echo "      start                 Start virtual machine"
    echo "      stop [NAME]           Stop a named VM or all clodpod VMs"
    echo "      destroy NAME          Delete a named VM"
    echo "      destroy --all         Delete all named VMs"
    echo "      set --ram SIZE NAME   Set per-instance RAM (use 'default' to reset)"
    echo "      set --max-memory SIZE Set workspace memory budget (use 'default' to reset)"
    echo "      set --vm-count N      Split budget across N VMs (use 'default' to reset to 1)"
    echo "      migrate               Move database to ~/.local/share/clodpod/"
    echo ""
    echo "Examples:"
    echo "  clod create dev --ram 8G --dir project:/Users/me/src/app"
    echo "  clod shell dev"
    echo "  clod shell --ram 6G dev"
    echo "  clod set --ram 10G dev"
    echo "  clod set --max-memory 16G"
    echo "  clod set --vm-count 2"
    echo "  clod shell /Users/me/src/app"
    echo "  clod stop dev"
    echo "  clod destroy --all"
    echo ""
    echo "Arguments after -- are passed to the command (claude, codex, cursor, gemini, shell)"
}

show_status() {
    local allow_sudo="${1:-false}"
    local oci_vm_state
    local base_vm_state
    local dst_vm_state
    local stored_image

    oci_vm_state="$(get_vm_state "$OCI_VM_NAME")"
    base_vm_state="$(get_vm_state "$BASE_VM_NAME")"
    dst_vm_state="$(get_vm_state "$DST_VM_NAME")"
    stored_image="$(get_setting "oci_base_image" "")"

    [[ -n "$oci_vm_state" ]] || oci_vm_state="not created"
    [[ -n "$base_vm_state" ]] || base_vm_state="not created"
    [[ -n "$dst_vm_state" ]] || dst_vm_state="not created"
    [[ -n "$stored_image" ]] || stored_image="not recorded"

    echo "sudo: $allow_sudo"
    echo "layer0 vm: $oci_vm_state"
    echo "base vm: $base_vm_state"
    echo "dst vm: $dst_vm_state"
    echo "stored image: $stored_image"
    echo "current image: $MACOS_IMAGE"
}

check_oci_provenance() {
    local check_only="${1:-false}"

    if [[ "${REBUILD_OCI:-}" != "" ]]; then
        return 0
    fi

    local stored_image
    stored_image="$(get_setting "oci_base_image" "")"

    if [[ -z "$stored_image" ]]; then
        return 0
    fi

    if [[ "$stored_image" != "$MACOS_IMAGE" ]]; then
        if [[ "$check_only" == "true" ]]; then
            warn "Image mismatch: built from $stored_image, current is $MACOS_IMAGE. Use --rebuild-oci to rebuild."
        else
            abort "Image mismatch: built from $stored_image, current is $MACOS_IMAGE. Use --rebuild-oci to rebuild."
        fi
    fi
}

ensure_oci_base() {
    if get_vm_exists "$OCI_VM_NAME"; then
        return 0
    fi

    debug "Creating $OCI_VM_NAME from $MACOS_IMAGE..."
    debug "Downloading image..."
    tart pull "$MACOS_IMAGE"

    TMP_OCI_VM_NAME="clodpod-oci-tmp-$(openssl rand -hex 4)"
    tart clone "$MACOS_IMAGE" "$TMP_OCI_VM_NAME"
    tart rename "$TMP_OCI_VM_NAME" "$OCI_VM_NAME"
    set_setting "oci_base_image" "$MACOS_IMAGE"
    tart prune --space-budget=0 2>/dev/null || true
    debug "$OCI_VM_NAME created"
}
