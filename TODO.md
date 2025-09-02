# TODO.md

- Download SDKS in base image?

    mkdir "$HOME/Downloads"
    xcodebuild -downloadPlatform ios

- Support for running claude in git worktree

    git worktree list

- Setup local machine shell that accepts a limited set of commands
     - tasks notifications from claude hooks
     - running the ios simulator

- Install updates
    # Check for available updates
    debug "Checking for available updates..."
    UPDATES=$(sudo softwareupdate --list 2>&1)
    if echo "$UPDATES" | grep -q "No new software available"; then
        exit 0
    fi

    # Install all available updates
    debug "Installing updates..."
    sudo softwareupdate --install --all --verbose --agree-to-licence --force

    # Count updates that require restart
    RESTART_REQUIRED=$(echo "$UPDATES" | grep -c "restart" || true)
    SHUTDOWN_REQUIRED=$(echo "$UPDATES" | grep -c "shutdown" || true)
    if [[ $RESTART_REQUIRED -gt 0 ]]; then
        debug "$RESTART_REQUIRED update(s) will require a restart"
    fi
    if [[ $SHUTDOWN_REQUIRED -gt 0 ]]; then
        debug "$SHUTDOWN_REQUIRED update(s) will require a shutdown"
    fi

    # Check if reboot is needed
    REBOOT_NEEDED=false

    # Method 1: Check if any installed updates had the restart flag
    if [[ $RESTART_REQUIRED -gt 0 ]] || [[ $SHUTDOWN_REQUIRED -gt 0 ]]; then
        REBOOT_NEEDED=true
    fi

    # Method 2: Check system indicator file (macOS creates this when reboot is needed)
    if [[ -f /private/var/db/.SoftwareUpdateAtLogout ]]; then
        REBOOT_NEEDED=true
    fi

    if [[ "$REBOOT_NEEDED" == true ]]; then
        debug "A system restart is required to complete the installation"
        sudo /sbin/shutdown -r now & disown
    else
        debug "Updates installed successfully"
    fi
