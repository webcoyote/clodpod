#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo >&2 "${BASH_SOURCE[0]}: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ALLOW_SUDO="${ALLOW_SUDO:-false}"


###############################################################################
# Functions
###############################################################################
[[ "${VERBOSE:-0}" =~ ^[0-9]+$ ]] && VERBOSE="${VERBOSE:-0}" || VERBOSE=1
trace () {
    [[ "$VERBOSE" -lt 2 ]] || echo >&2 -e "🔬 \033[90m$*\033[0m"
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
sudo scutil --set ComputerName "clodpod-xcode-base"
sudo scutil --set LocalHostName "clodpod-xcode-base"
sudo scutil --set HostName "clodpod-xcode-base"


###############################################################################
# Install and update brew
###############################################################################
if ! command -v brew &> /dev/null ; then
    debug "Installing brew..."
    /usr/bin/env bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

debug "Updating brew..."
if [[ "$VERBOSE" -lt 3 ]]; then
    brew update --quiet && brew upgrade --quiet
else
    brew update && brew upgrade
fi

###############################################################################
# Install base dependencies from the Brewfile
#
# guest/Brewfile is the single source of truth for what the base image ships —
# formulae and AI agent casks alike. 'brew bundle' is idempotent: it reconciles
# against installed state rather than failing on already-installed packages,
# which is why this needs none of the '|| true' guards it replaces.
###############################################################################
BREWFILE="$SCRIPT_DIR/Brewfile"
[[ -f "$BREWFILE" ]] || abort "Brewfile not found at $BREWFILE"

debug "Installing base dependencies from Brewfile..."
if [[ "$VERBOSE" -lt 3 ]]; then
    brew bundle install --quiet --file="$BREWFILE"
else
    brew bundle install --file="$BREWFILE"
fi


###############################################################################
# Install AI developer tools not available via Homebrew
###############################################################################
# Gemini CLI (npm global)
if command -v npm &>/dev/null; then
    debug "Installing gemini-cli via npm..."
    npm install --global --silent @google/gemini-cli 2>/dev/null || true
fi


###############################################################################
# Configure admin user for SSH access
###############################################################################
debug "Configuring admin user..."

# Configure passwordless sudo — our own sudoers file
if [[ "$ALLOW_SUDO" == "true" ]]; then
    debug "Enabling passwordless sudo for admin..."
    echo "admin ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/clodpod >/dev/null
    sudo chmod 440 /etc/sudoers.d/clodpod
else
    debug "Passwordless sudo will be removed after provisioning..."
    sudo rm -f /etc/sudoers.d/clodpod
fi
# NOTE: Do NOT remove OCI NOPASSWD here — provisioning steps after
# install.sh need non-interactive sudo. Removal deferred to configure.sh.

# Ensure admin is in SSH access group
sudo dseditgroup -o edit -a admin -t user com.apple.access_ssh

# Force opendirectoryd to flush records to disk.
# In Tart VMs, opendirectoryd holds records in memory and only writes stubs
# on shutdown. Killing the daemon forces a clean flush before launchd
# restarts it. This MUST run after every dscl/dseditgroup write above —
# otherwise the changes (notably com.apple.access_ssh membership, which
# PAM's pam_sacl requires for ssh logins) are lost when the VM is snapshotted.
debug "Flushing opendirectoryd to persist user and group records..."
sudo killall opendirectoryd
until dscl . -list /Users &>/dev/null; do
    sleep 0.5
done
sync


###############################################################################
# Eject mounted DMG files
###############################################################################
dmg_volumes=$(hdiutil info | grep "/Volumes/" | grep -E "^/dev/disk[0-9]+s[0-9]+" | awk '{print $1}' || true)
for volume in $dmg_volumes; do
    debug "Ejecting $volume..."
    if ! hdiutil detach "$volume" 2>/dev/null; then
        debug "Unable to eject $volume..."
    fi
done
