#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "${BASH_SOURCE[0]}: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR
#SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


###############################################################################
# Functions
###############################################################################
[[ "${VERBOSE:-0}" =~ ^[0-9]+$ ]] && VERBOSE="${VERBOSE:-0}" || VERBOSE=1
trace () {
    [[ "$VERBOSE" -lt 2 ]] || echo >&2 -e "🔬 \033[36m$*\033[0m"
}
debug () {
    [[ "$VERBOSE" -lt 1 ]] || echo >&2 -e "🔍 \033[36m$*\033[0m"
}
info () {
    echo >&2 -e "ℹ️ \033[36m$*\033[0m"
}
warn () {
    echo >&2 -e "⚠️ \033[33m$*\033[0m"
}
error () {
    echo >&2 -e "❌ \033[31m$*\033[0m"
}
abort () {
    error "$*"
    exit 1
}


###############################################################################
# Preconditions
###############################################################################
if [[ $OSTYPE != 'darwin'* ]]; then
    abort "ERROR: this script is for Mac OSX"
fi


###############################################################################
# Rename the computer
###############################################################################
sudo scutil --set ComputerName "clodpod-xcode"
sudo scutil --set LocalHostName "clodpod-xcode"
sudo scutil --set HostName "clodpod-xcode"


###############################################################################
# Configure admin user home
###############################################################################
debug "Configure admin user home..."

# Copy files to home directory
DIST_DIR="/Volumes/My Shared Files/__install"
sudo cp -rf "$DIST_DIR/home/." "/Users/admin/"

# Fix ownership on copied payload only (not entire home — admin owns Library/ etc.)
while IFS= read -r -d '' entry; do
    entry="${entry#./}"
    sudo chown -R "admin:staff" "/Users/admin/$entry"
done < <(cd "$DIST_DIR/home" && find . -mindepth 1 -maxdepth 1 -print0)

# Fixup SSH permissions
sudo chmod 755 "/Users/admin"
sudo chmod 700 "/Users/admin/.ssh"
if [[ -f "/Users/admin/.ssh/authorized_keys" ]]; then
    sudo chmod 600 "/Users/admin/.ssh/authorized_keys"
fi
if [[ -f "/Users/admin/.ssh/known_hosts" ]]; then
    sudo chmod 600 "/Users/admin/.ssh/known_hosts"
fi
if [[ -f "/Users/admin/.ssh/id_ed25519" ]]; then
    sudo chmod 600 "/Users/admin/.ssh/id_ed25519"
fi
if [[ -f "/Users/admin/.ssh/id_ed25519.pub" ]]; then
    sudo chmod 644 "/Users/admin/.ssh/id_ed25519.pub"
fi


###############################################################################
# Allow admin user to update homebrew
###############################################################################
debug "Enable admin to update brew files"
sudo chown -R "admin:staff" "$(brew --prefix)"


###############################################################################
# Finalize sudo configuration
# configure.sh is the final authority on sudo state per-instance.
# This handles base->instance inheritance: a base built with ALLOW_SUDO=true
# bakes /etc/sudoers.d/clodpod, but an instance created with ALLOW_SUDO=false
# must remove it.
###############################################################################
ALLOW_SUDO="${ALLOW_SUDO:-false}"
if [[ "$ALLOW_SUDO" == "true" ]]; then
    debug "Ensuring passwordless sudo for admin..."
    echo "admin ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/clodpod >/dev/null
    sudo chmod 440 /etc/sudoers.d/clodpod
else
    debug "Removing clodpod-managed NOPASSWD rules..."
    # Remove our own sudoers file and the known OCI-provided one
    sudo rm -f /etc/sudoers.d/clodpod /etc/sudoers.d/admin-nopasswd
fi
