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
    cat <<EOF
clodpod v${VERSION} — macOS VM sandbox for AI agents

Usage: clod [options] <command> [args...] [-- command-args...]

Commands:
  claude, cl, c     Run Claude Code in VM
  codex, co         Run OpenAI Codex in VM
  cursor, cu, ca    Run Cursor Agent in VM
  gemini, gem, g    Run Google Gemini in VM
  shell, sh, s      Open shell in VM
  create, cr        Create a named VM instance
  destroy           Delete a named VM instance
  build-base        Build or rebuild a base image
  start             Start VM without connecting
  stop              Stop VM(s)
  set               Change VM settings
  list, ls, l       List instances, bases, and projects
  status, st        Show system state
  add, a            Add a project directory
  remove, rm        Remove a project
  migrate           Move database to XDG location
  help, h           Show help for a command

VM layers (each builds on the previous):
  Layer 0 (OCI)       Downloaded macOS image, cached locally
  Layer 1 (base)      OCI + brew + AI tools + service logins
  Layer 2 (instance)  Base clone + project dirs + your tool installs

Existing instances keep working after a base rebuild, but won't have
the updated packages. Recreate to pick up changes: clod destroy + create.

Global options:
  --graphics/--no-graphics      VM display mode (default: graphics)
  --rebuild-oci                 Re-download OCI image (Layer 0)
  --rebuild-base                Rebuild base from OCI (Layer 1)
  --rebuild-dst                 Rebuild legacy VM home (Layer 2)
  --allow-sudo/--no-allow-sudo  Passwordless sudo in VM
  -n, --no-select               Skip interactive project selection
  -v/-vv/-vvv                   Verbosity
  -h, --help                    Show help
  --version                     Show version

Run 'clod help <command>' for command-specific help.
EOF
}

show_help_command() {
    local usage="$1" desc="$2"
    echo "Usage: clod $usage"
    echo ""
    echo "$desc"
}

show_help_create() {
    cat <<'EOF'
Usage: clod create <name> [options]

Create a named VM instance by cloning a base image.

Options:
  --base PROFILE    Base image to clone (default: 'default')
  --ram SIZE        Fixed RAM for this instance (e.g. 8G, 4096M, 'default' for budget)
  --dir name:path   Mount host directory into VM (repeatable, first is primary)

Examples:
  clod create dev --dir project:/Users/me/src/app
  clod create dev --ram 8G --base custom --dir work:$(pwd)
  clod create worker --dir repo:$(pwd) --dir data:/Volumes/data
EOF
}

show_help_build_base() {
    cat <<'EOF'
Usage: clod build-base [options]

Build a base image from OCI source. Installs brew packages, AI tools,
and opens an interactive SSH session for manual login (Claude, Codex, etc.).

First run downloads the OCI image (~30 GB) — this takes a while.
Subsequent runs reuse the cached image. Use --rebuild-oci to fetch
a newer version (e.g. after Xcode or macOS updates from Cirrus Labs).

To update brew packages without re-downloading OCI, just run build-base
again — it rebuilds from the cached Layer 0.

Options:
  --profile NAME          Profile name (default: 'default')
  --install-script PATH   Import custom install script into profile

Environment:
  ALLOW_SUDO=true         Enable passwordless sudo in the base

Layers:
  Layer 0 (OCI)      Downloaded image, cached. Refresh: --rebuild-oci
  Layer 1 (base)     OCI + brew + tools + login. This command builds it.
  Layer 2 (instance) Base clone + your tools. Created with 'clod create'.

Note: existing instances keep working after base rebuild but won't
have updated packages. Recreate to pick up changes:
  clod destroy <name> && clod create <name> --dir ...

Examples:
  clod build-base
  clod build-base --profile ml --install-script ./setup-cuda.sh
  ALLOW_SUDO=true clod build-base
  clod --rebuild-oci build-base     # fetch latest OCI image
EOF
}

show_help_set() {
    cat <<'EOF'
Usage: clod set <option> [args]

Change VM and workspace settings.

Options:
  --ram SIZE NAME       Set fixed RAM for an instance (e.g. 8G, 'default' to reset)
  --max-memory SIZE     Set workspace memory budget (e.g. 32G, 'default' for 5/8 host RAM)
  --vm-count N          Split budget across N VMs ('default' to reset to 1)

Examples:
  clod set --ram 10G dev
  clod set --max-memory 32G
  clod set --vm-count 3
EOF
}

show_help_shell() {
    cat <<'EOF'
Usage: clod shell [NAME] [--ram SIZE] [-- command...]

Open a shell in a named VM instance, or use legacy project-based flow.

Arguments:
  NAME                  Instance name (omit for auto-select if only one exists)
  --ram SIZE            Override RAM for this session (e.g. 8G). Named VMs only.
  -- command...         Run command instead of interactive shell

Examples:
  clod shell dev
  clod shell dev --ram 12G
  clod shell dev -- claude --dangerously-skip-permissions
  clod shell                    # auto-selects if one instance exists
EOF
}

show_help_destroy() {
    cat <<'EOF'
Usage: clod destroy [name]
       clod destroy --all

Delete a named VM instance (stops if running, removes VM and DB records).
If only one instance exists, the name can be omitted.

Options:
  --all     Delete all named instances

Examples:
  clod destroy dev
  clod destroy           # auto-selects if one instance exists
  clod destroy --all
EOF
}

show_help_stop() {
    cat <<'EOF'
Usage: clod stop [NAME]

Stop a named VM, or all clodpod VMs if no name given.

Examples:
  clod stop dev
  clod stop
EOF
}

# Dispatch per-command help from 'clod help <command>'
dispatch_help() {
    case "${1:-}" in
        create|cr)          show_help_create ;;
        destroy)            show_help_destroy ;;
        build-base)         show_help_build_base ;;
        set)                show_help_set ;;
        shell|sh|s)         show_help_shell ;;
        stop)               show_help_stop ;;
        claude|cl|c)        show_help_command "claude [PATH] [NAME] [-- args...]" "Run Claude Code in a VM. PATH adds a project directory." ;;
        codex|co)           show_help_command "codex [PATH] [NAME] [-- args...]" "Run OpenAI Codex in a VM." ;;
        cursor|cu|ca)       show_help_command "cursor [PATH] [NAME] [-- args...]" "Run Cursor Agent in a VM." ;;
        gemini|gem|g)       show_help_command "gemini [PATH] [NAME] [-- args...]" "Run Google Gemini in a VM." ;;
        start)              show_help_command "start" "Start the VM without connecting (useful for GUI apps)." ;;
        add|a)              show_help_command "add PATH [NAME]" "Add a project directory. NAME defaults to directory basename." ;;
        remove|rm)          show_help_command "remove <name|path>" "Remove a project by name or path." ;;
        list|ls|l)          show_help_command "list" "List memory budget, bases, instances, and projects." ;;
        status|st)          show_help_command "status" "Show sudo setting, layer states, and OCI image provenance." ;;
        migrate)            show_help_command "migrate" "Move database from legacy location to ~/.local/share/clodpod/" ;;
        help|h)             show_help ;;
        *)                  show_help ;;
    esac
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

    echo "passwordless sudo: $allow_sudo"
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
