# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # globals set/used by config.sh and other modules
# SSH key management and guest home provisioning

ensure_ssh_key() {
    SSH_KEY_CREATED=false
    if [[ ! -f "$SSH_KEYFILE_PRIV" ]] || [[ ! -f "$SSH_KEYFILE_PUB" ]]; then
        # shellcheck disable=SC2174 # When used with -p, -m only applies to the deepest directory. # Yup, that's fine
        mkdir -m 700 -p "$SSH_DIR"
        ssh-keygen -t ed25519 \
            -f "$SSH_KEYFILE_PRIV" \
            -N "" \
            -q \
            -C "clodpod-${USER}@${HOSTNAME}"
        SSH_KEY_CREATED=true
        REBUILD_DST=true
        # Sync new key to all existing named VMs
        sync_ssh_key_to_all_instances
    fi
}

# Push updated authorized_keys to all named instances that exist as tart VMs.
# Temporarily starts stopped VMs, pushes key, stops them again.
sync_ssh_key_to_all_instances() {
    local instance_rows
    instance_rows="$(sqlite3 -separator '|' "$DB_FILE" "SELECT vm_name, COALESCE(ram_mb, 0), COALESCE(ssh_user, 'clodpod') FROM instances;" 2>/dev/null)" || true

    # Also sync to legacy clodpod-xcode if it exists
    if get_vm_exists "$DST_VM_NAME" && ! printf '%s\n' "$instance_rows" | grep -q "^${DST_VM_NAME}|"; then
        local dst_ssh_user
        dst_ssh_user="$(get_setting "dst_ssh_user" "clodpod")"
        instance_rows="${instance_rows:+$instance_rows
}${DST_VM_NAME}|0|${dst_ssh_user}"
    fi

    [[ -n "$instance_rows" ]] || return 0

    local vm ram_mb ssh_user
    while IFS='|' read -r vm ram_mb ssh_user; do
        if ! get_vm_exists "$vm"; then
            continue
        fi
        local was_stopped=false
        if [[ "$(get_vm_state "$vm")" != "running" ]]; then
            was_stopped=true
            (vm_run "$vm" "$ram_mb" "") || true
            if [[ "$(get_vm_state "$vm")" != "running" ]]; then
                warn "Could not start $vm for SSH key sync — skipping"
                continue
            fi
        fi
        debug "Syncing SSH key to $vm ($ssh_user)..."
        vm_sync_authorized_key "$vm" "$ssh_user" 2>/dev/null || warn "SSH key sync failed for $vm — skipping"
        if [[ "$was_stopped" == "true" ]]; then
            tart stop "$vm" 2>/dev/null || true
        fi
    done <<< "$instance_rows"
}

refresh_guest_home() {
    debug "Syncing guest directory..."
    local guest_dir="$DATA_DIR/guest"
    mkdir -p "$guest_dir"
    /usr/bin/rsync -a --delete --exclude '.gitconfig' --exclude '.ssh/' "$WORKSPACE/guest/" "$guest_dir/"

    debug "Configuring credentials..."
    local git_user_name
    local git_user_email
    git_user_name="$(git config --global --get user.name 2>/dev/null || echo "")"
    git_user_email="$(git config --global --get user.email 2>/dev/null || echo "")"
    git config set -f "$guest_dir/home/.gitconfig" user.name "$git_user_name"
    git config set -f "$guest_dir/home/.gitconfig" user.email "$git_user_email"

    local guest_authorized_keys="$guest_dir/home/.ssh/authorized_keys"
    # shellcheck disable=SC2174 # When used with -p, -m only applies to the deepest directory. # Yup, that's fine
    mkdir -m 700 -p "$(dirname "$guest_authorized_keys")"
    cp "$SSH_KEYFILE_PUB" "$guest_authorized_keys"
    chmod 600 "$guest_authorized_keys"

    local guest_known_hosts="$guest_dir/home/.ssh/known_hosts"
    # shellcheck disable=SC2174 # When used with -p, -m only applies to the deepest directory. # Yup, that's fine
    mkdir -m 700 -p "$(dirname "$guest_known_hosts")"
    ssh-keyscan github.com > "$guest_known_hosts"
    chmod 600 "$guest_known_hosts"

    touch "$guest_dir/.populated"
}

# Idempotent guard: refresh guest home only if it has not been fully populated.
ensure_guest_home() {
    if [[ ! -f "$DATA_DIR/guest/.populated" ]]; then
        info "Guest home incomplete at $DATA_DIR/guest, populating..."
        refresh_guest_home
    fi
}
