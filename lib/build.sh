# shellcheck shell=bash
# shellcheck disable=SC2154 # globals set by config.sh and other modules
# Build operations: rebuild OCI, base, and dst VMs; DHCP configuration

determine_rebuilds() {
    if [[ "${REBUILD_OCI:-}" != "" ]]; then
        REBUILD_BASE=true
    fi

    if ! get_vm_exists "$BASE_VM_NAME" ; then
        REBUILD_BASE=true
    elif ! get_vm_exists "$DST_VM_NAME" ; then
        REBUILD_DST=true
    fi

    if [[ "${REBUILD_BASE:-}" != "" ]]; then
        REBUILD_DST=true
    fi
}

prepare_rebuilds() {
    if [[ "${REBUILD_DST:-}" != "" ]]; then
        if [[ "$(get_vm_state "$DST_VM_NAME")" == "running" ]]; then
            read -p "$DST_VM_NAME is running; delete it? (y/N)" -n 1 -r response
            echo
            [[ "$response" =~ ^[Yy]$ ]] || exit 0
        fi
        delete_vm "$DST_VM_NAME"
    fi

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
    [[ "${REBUILD_BASE:-}" != "" ]] || return 0

    debug "Building $BASE_VM_NAME..."

    # Move existing base aside instead of deleting — allows rollback on failure
    OLD_BASE_VM_NAME=""
    if tart list --quiet | grep "^${BASE_VM_NAME}$" >/dev/null 2>&1; then
        OLD_BASE_VM_NAME="${BASE_VM_NAME}-old-$(openssl rand -hex 4)"
        trace "Renaming $BASE_VM_NAME to $OLD_BASE_VM_NAME (backup)"
        tart rename "$BASE_VM_NAME" "$OLD_BASE_VM_NAME"
    fi

    trace "Cloning $OCI_VM_NAME to $TMP_VM_NAME..."
    clone_vm "$OCI_VM_NAME" "$TMP_VM_NAME"
    run_vm "$TMP_VM_NAME" 0

    trace "Running install.sh..."
    INSTALL_ENV=( "/usr/bin/env" "VERBOSE=$VERBOSE" "ALLOW_SUDO=$ALLOW_SUDO" )
    if [[ -n "${CLODPOD_PASSWORD:-}" ]]; then
        INSTALL_ENV+=( "CLODPOD_PASSWORD=$CLODPOD_PASSWORD" )
    fi

    if ! tart exec -it "$TMP_VM_NAME" \
        "${INSTALL_ENV[@]}" bash \
        "/Volumes/My Shared Files/__install/install.sh"; then
        abort "install.sh failed — base VM will not be saved"
    fi

    trace "Stopping $TMP_VM_NAME to flush directory service writes..."
    stop_vm "$TMP_VM_NAME"

    trace "Renaming $TMP_VM_NAME to $BASE_VM_NAME"
    tart rename "$TMP_VM_NAME" "$BASE_VM_NAME"
    set_setting "allow_sudo" "$ALLOW_SUDO"
    set_setting "oci_base_image" "$MACOS_IMAGE"
    base_register "default" "$BASE_VM_NAME" "${MACOS_VERSION}-${MACOS_FLAVOR}"

    # New base built successfully — remove old base
    if [[ -n "$OLD_BASE_VM_NAME" ]]; then
        trace "Deleting old base $OLD_BASE_VM_NAME"
        delete_vm "$OLD_BASE_VM_NAME"
        OLD_BASE_VM_NAME=""
    fi

    debug "Building $BASE_VM_NAME successful"

    # Prune OCI cache — base VM is built, cache is no longer needed
    debug "Pruning OCI cache..."
    tart prune --space-budget=0 2>/dev/null || true
}

build_dst_vm() {
    [[ "${REBUILD_DST:-}" != "" ]] || return 0

    debug "Building $DST_VM_NAME..."

    # If the base image is already running then do some jiggery-pokery
    # to rename it so we can avoid stopping the VM and starting another.
    if [[ "$(get_vm_state "$BASE_VM_NAME")" == "running" ]]; then
        tart rename "$BASE_VM_NAME" "$TMP_VM_NAME"
        clone_vm "$TMP_VM_NAME" "$BASE_VM_NAME"
    else
        clone_vm "$BASE_VM_NAME" "$TMP_VM_NAME"
        run_vm "$TMP_VM_NAME" 0
    fi

    trace "Running configure.sh..."
    if ! tart exec -it "$TMP_VM_NAME" \
        "/usr/bin/env" "VERBOSE=$VERBOSE" bash \
        "/Volumes/My Shared Files/__install/configure.sh"; then
        abort "configure.sh failed — dst VM will not be saved"
    fi

    trace "Renaming $TMP_VM_NAME to $DST_VM_NAME"
    tart rename "$TMP_VM_NAME" "$DST_VM_NAME"

    debug "Building $DST_VM_NAME successful"
}

# Legacy SSH flow for the single-VM (DST_VM_NAME) path
legacy_start_and_connect() {
    if [[ "$(get_vm_state "$DST_VM_NAME")" != "running" ]]; then
        run_vm "$DST_VM_NAME" 0 || true
    elif ! check_projects_active ; then
        warn "New project directory added; virtual machine restart required"
        read -p "$DST_VM_NAME is running; restart it? (y/N)" -n 1 -r response
        echo
        [[ "$response" =~ ^[Yy]$ ]] || exit 0
        stop_vm "$DST_VM_NAME"
        run_vm "$DST_VM_NAME" 0 || true
    fi

    if [[ "${COMMAND:-}" == "start" ]]; then
        info "clodpod VM running"
        exit 0
    fi

    debug "Checking $DST_VM_NAME IP connectivity"
    local ipaddr
    ipaddr="$(tart ip --wait 20 "$DST_VM_NAME")"
    if ! nc -z "$ipaddr" 22 ; then
        error "$(get_local_network_error "$DST_VM_NAME")"
        read -n 1 -s -r -p "Press any key to open System Settings"
        open "/System/Library/PreferencePanes/Security.prefPane"
    fi

    debug "Connect to $DST_VM_NAME (ssh clodpod@$ipaddr)"

    local command_args_b64=""
    if [[ ${#COMMAND_ARGS[@]} -gt 0 ]]; then
        command_args_b64="$(printf '%s\0' "${COMMAND_ARGS[@]}" | base64 | tr -d '\n')"
    fi

    # Check if current directory is inside existing project
    local initial_dir=""
    if initial_dir=$(get_relative_project_directory "$PROJECT_NAME"); then
        debug "initial directory: ${initial_dir:-}"
    fi

    exec ssh \
        -q \
        -tt \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes \
        -i "$SSH_KEYFILE_PRIV" \
        "clodpod@$ipaddr" \
        /usr/bin/env \
            "TERM=xterm-256color" \
            "$(ssh_quote_env PROJECT "$PROJECT_NAME")" \
            "$(ssh_quote_env INITIAL_DIR "$initial_dir")" \
            "$(ssh_quote_env COMMAND "${COMMAND:-}")" \
            "COMMAND_ARGS_B64=$command_args_b64" \
            zsh --login || true
}
