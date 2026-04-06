#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "${BASH_SOURCE[0]}: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR
#SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

BrewApps=()
BrewApps+=(bash)                # replace OSX bash 3.2 with something modern
BrewApps+=(bat)                 # better cat
BrewApps+=(coreutils)           # replace old BSD command-line tools with GNU
BrewApps+=(eza)                 # better ls
BrewApps+=(fd)                  # better than unix `find`
BrewApps+=(findutils)           # includes gxargs with the '-r' option
BrewApps+=(git)                 # yeah, it's the best
BrewApps+=(git-delta)           # better pager for git diff
BrewApps+=(git-lfs)             # big files
BrewApps+=(gnu-getopt)          # because OSX getopt is ancient
BrewApps+=(jq)                  # mangle JSON from the command line
BrewApps+=(mas)                 # Apple Store command line
BrewApps+=(node)                # NodeJS
BrewApps+=(python)              # Python language
BrewApps+=(rg)                  # better grep
BrewApps+=(sd)                  # better sed
BrewApps+=(shellcheck)          # lint for bash
BrewApps+=(uv)                  # python package manager
BrewApps+=(wget)                # curl with different defaults

debug "Installing ${BrewApps[*]}..."
if [[ "$VERBOSE" -lt 3 ]]; then
    brew install --quiet "${BrewApps[@]}"
else
    brew install "${BrewApps[@]}"
fi


###############################################################################
# Install AI developer tools
###############################################################################
debug "Installing AI developer tools..."

# Claude Code (brew cask)
if [[ "$VERBOSE" -lt 3 ]]; then
    brew install --quiet --cask claude-code 2>/dev/null || brew upgrade --quiet --cask claude-code 2>/dev/null || true
else
    brew install --cask claude-code 2>/dev/null || brew upgrade --cask claude-code 2>/dev/null || true
fi

# Codex (brew cask)
if [[ "$VERBOSE" -lt 3 ]]; then
    brew install --quiet --cask codex 2>/dev/null || brew upgrade --quiet --cask codex 2>/dev/null || true
else
    brew install --cask codex 2>/dev/null || brew upgrade --cask codex 2>/dev/null || true
fi

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
