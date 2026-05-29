# shellcheck shell=bash
# shellcheck disable=SC2154 # globals set by config.sh and other modules
# Build operations: rebuild OCI, base, and dst VMs; DHCP configuration

prepare_rebuilds() {
    if [[ "${REBUILD_OCI:-}" != "" ]]; then
        delete_vm "$OCI_VM_NAME"
        if get_vm_exists "$OCI_VM_NAME"; then
            abort "Failed to delete $OCI_VM_NAME — cannot rebuild Layer 0"
        fi
    fi

    # Install cleanup trap early so ensure_oci_base temp VMs are cleaned up on Ctrl+C
    TMP_VM_NAME=""
    trap cleanup_tmp_vm EXIT

    if [[ "${REBUILD_BASE:-}" != "" ]]; then
        # This is probably the first time install; be more verbose
        [[ "$VERBOSE" -ge 2 ]] || VERBOSE=2
        ensure_oci_base
    fi
}

configure_dhcp_lease() {
    # https://github.com/webcoyote/clodpod/issues/5
    # Starting & stopping many VMs causes a DHCP IP address shortage.
    local dhcp_prefs="/Library/Preferences/SystemConfiguration/com.apple.InternetSharing.default.plist"
    local current_lease
    current_lease=$(/usr/libexec/PlistBuddy -c "Print :bootpd:DHCPLeaseTimeSecs" "$dhcp_prefs" 2>/dev/null || true)
    if [[ "$current_lease" != "600" ]]; then
        sudo -p "Password required to set DHCP lease time for clodpod (600s): " true
        sudo /usr/bin/defaults write "$dhcp_prefs" bootpd -dict DHCPLeaseTimeSecs -int 600
        sudo /bin/launchctl stop com.apple.InternetSharing || true
        sudo /bin/launchctl start com.apple.InternetSharing || true
    fi
}

build_base_vm() {
    local profile="${1:-}"
    local base_vm_name="$BASE_VM_NAME"
    local profile_name="default"

    if [[ -n "$profile" ]]; then
        profile_name="$profile"
        base_vm_name="clodpod-base-${profile}"
    fi

    # When called from legacy flow, skip if not requested
    if [[ -z "$profile" ]] && [[ "${REBUILD_BASE:-}" == "" ]]; then
        return 0
    fi

    debug "Building $base_vm_name (profile: $profile_name)..."

    ensure_oci_base

    # Move existing base aside instead of deleting — allows rollback on failure
    OLD_BASE_VM_NAME=""
    if tart list --quiet | grep "^${base_vm_name}$" >/dev/null 2>&1; then
        OLD_BASE_VM_NAME="${base_vm_name}-old-$(openssl rand -hex 4)"
        trace "Renaming $base_vm_name to $OLD_BASE_VM_NAME (backup)"
        tart rename "$base_vm_name" "$OLD_BASE_VM_NAME"
    fi

    TMP_VM_NAME="clodpod-tmp-$(openssl rand -hex 8)"
    trap cleanup_tmp_vm EXIT

    trace "Cloning $OCI_VM_NAME to $TMP_VM_NAME..."
    clone_vm "$OCI_VM_NAME" "$TMP_VM_NAME"
    run_vm "$TMP_VM_NAME" 0

    if [[ -n "${CLODPOD_PASSWORD:-}" ]]; then
        warn "CLODPOD_PASSWORD is no longer supported (SSH uses admin user). Ignoring."
    fi

    trace "Running install.sh..."
    INSTALL_ENV=( "/usr/bin/env" "VERBOSE=$VERBOSE" "ALLOW_SUDO=${ALLOW_SUDO:-false}" )

    if ! tart exec -it "$TMP_VM_NAME" \
        "${INSTALL_ENV[@]}" bash \
        "/Volumes/My Shared Files/__install/install.sh"; then
        abort "install.sh failed — base VM will not be saved"
    fi

    # Mark install as done so cleanup preserves temp VM if interrupted
    BUILD_INSTALL_DONE=true

    # Run profile install-extra.sh if it exists
    local profile_dir="$HOME/.config/clodpod/profiles/${profile_name}"
    if [[ -f "$profile_dir/install-extra.sh" ]]; then
        trace "Running install-extra.sh for profile $profile_name..."
        # Copy to guest dir so VM can access it
        cp "$profile_dir/install-extra.sh" "$DATA_DIR/guest/install-extra.sh"
        if ! tart exec -it "$TMP_VM_NAME" \
            "${INSTALL_ENV[@]}" bash \
            "/Volumes/My Shared Files/__install/install-extra.sh"; then
            abort "install-extra.sh failed — base VM will not be saved"
        fi
    fi

    # Sync SSH key so interactive session can connect (base always uses admin)
    vm_sync_authorized_key "$TMP_VM_NAME" "admin"

    # Interactive session: let user log in to services
    info "Log in to services and exit when done."
    local ipaddr
    ipaddr="$(tart ip --wait 20 "$TMP_VM_NAME")"
    ssh -q -tt \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes \
        -i "$SSH_KEYFILE_PRIV" \
        "admin@$ipaddr" \
        /usr/bin/env "TERM=xterm-256color" ${COLORTERM:+"COLORTERM=$COLORTERM"} zsh --login || true

    trace "Stopping $TMP_VM_NAME to flush directory service writes..."
    stop_vm "$TMP_VM_NAME"

    trace "Renaming $TMP_VM_NAME to $base_vm_name"
    tart rename "$TMP_VM_NAME" "$base_vm_name"
    TMP_VM_NAME=""
    BUILD_INSTALL_DONE=""
    set_setting "allow_sudo" "${ALLOW_SUDO:-false}"
    set_setting "oci_base_image" "$MACOS_IMAGE"
    base_register "$profile_name" "$base_vm_name" "${MACOS_VERSION}-${MACOS_FLAVOR}"

    # New base built successfully — remove old base
    if [[ -n "$OLD_BASE_VM_NAME" ]]; then
        trace "Deleting old base $OLD_BASE_VM_NAME"
        delete_vm "$OLD_BASE_VM_NAME"
        OLD_BASE_VM_NAME=""
    fi

    debug "Building $base_vm_name successful"

    # Prune OCI cache — base VM is built, cache is no longer needed
    debug "Pruning OCI cache..."
    tart prune --space-budget=0 2>/dev/null || true
}

# Explicit build-base command
cmd_build_base() {
    local profile="default"
    local install_script=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                [[ $# -ge 2 ]] || abort "Usage: clod build-base --profile <name>"
                profile="$2"
                shift 2
                ;;
            --install-script)
                [[ $# -ge 2 ]] || abort "Usage: clod build-base --install-script <path>"
                install_script="$2"
                shift 2
                ;;
            *)
                abort "Error: unknown build-base option ($1)"
                ;;
        esac
    done

    # Validate profile name (prevent path traversal)
    if [[ ! "$profile" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
        abort "Error: invalid profile name ($profile)"
    fi

    # Import install script into profile if provided
    if [[ -n "$install_script" ]]; then
        local resolved_script
        resolved_script="$(resolve_physical_path "$install_script" 2>/dev/null || true)"
        [[ -f "$resolved_script" ]] || abort "Error: install script not found ($install_script)"
        local profile_dir="$HOME/.config/clodpod/profiles/${profile}"
        mkdir -p "$profile_dir"
        cp "$resolved_script" "$profile_dir/install-extra.sh"
        info "Imported install script to $profile_dir/install-extra.sh"
    fi

    # Resolve ALLOW_SUDO from stored setting (early-dispatched, no global option parsing)
    ALLOW_SUDO="${ALLOW_SUDO:-$(get_setting "allow_sudo" "false")}"

    [[ "$VERBOSE" -ge 2 ]] || VERBOSE=2
    ensure_ssh_key
    refresh_guest_home
    configure_dhcp_lease
    build_base_vm "$profile"
}

# Clone an existing base profile into a new one via APFS copy-on-write.
# Skips install.sh + interactive logins entirely — the new base inherits
# everything baked into the source. Useful when the desired delta from the
# source is something other than what install.sh provisions: a checkpoint
# before risky changes, hand-edited config, recovery-mode tweaks, or any
# other modification you'd rather hand-roll than re-derive from scratch.
#
# Whatever the user wants to change in the new base they do themselves
# after the clone — this command just produces a bootable, registered
# fork of the source.
cmd_clone_base() {
    local src=""
    local dst=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help_clone_base
                exit 0
                ;;
            -*)
                abort "Error: unknown clone-base option ($1)"
                ;;
            *)
                if [[ -z "$src" ]]; then
                    src="$1"
                elif [[ -z "$dst" ]]; then
                    dst="$1"
                else
                    abort "Usage: clod clone-base <src-profile> <dst-profile>"
                fi
                shift
                ;;
        esac
    done

    [[ -n "$src" && -n "$dst" ]] || abort "Usage: clod clone-base <src-profile> <dst-profile>"

    # Validate names (same rule as --profile in build-base, prevents path
    # traversal in the per-profile install-extra.sh dir and keeps tart VM
    # names sane).
    if [[ ! "$src" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
        abort "Error: invalid source profile name ($src)"
    fi
    if [[ ! "$dst" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
        abort "Error: invalid destination profile name ($dst)"
    fi
    [[ "$src" != "$dst" ]] || abort "Error: source and destination profiles must differ"

    base_exists "$src" || abort "Error: source base profile not found ($src). Try: clod list"
    ! base_exists "$dst" || abort "Error: destination base profile already exists ($dst)"

    local src_vm dst_vm oci_source
    src_vm="$(base_get_vm_name "$src")"
    oci_source="$(base_get_oci_source "$src")"
    dst_vm="clodpod-base-${dst}"

    # Belt-and-braces: the bases row may be stale relative to tart's view
    # (e.g. user manually deleted the VM). Verify the source VM actually
    # exists and the dst VM name isn't already taken.
    get_vm_exists "$src_vm" || abort "Error: source VM missing ($src_vm). Stored in bases but not in tart — clean up with 'sqlite3 \"$DB_FILE\" \"DELETE FROM bases WHERE name = ...\"'."
    ! get_vm_exists "$dst_vm" || abort "Error: a tart VM named $dst_vm already exists"

    # tart clone requires the source to be stopped. Don't auto-stop —
    # could interrupt a session the user has live in the source base.
    local src_state
    src_state="$(get_vm_state "$src_vm")"
    [[ "$src_state" == "stopped" ]] || abort "Error: source VM ($src_vm) must be stopped before cloning (current state: $src_state). Stop it via tart stop $src_vm or by exiting any live session."

    info "Cloning base $src → $dst (APFS CoW; install.sh not re-run)"
    clone_vm "$src_vm" "$dst_vm"
    base_register "$dst" "$dst_vm" "$oci_source"

    info "Base $dst registered."
    info ""
    info "Derive instances from it:"
    info "  clod create <instance> --base $dst --dir ..."
    info ""
    info "To boot the new base directly (e.g. to inspect or modify it):"
    info "  tart run $dst_vm              # normal boot"
    info "  tart run --recovery $dst_vm   # recoveryOS (boot policy, csrutil, …)"
}

