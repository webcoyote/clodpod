#!/usr/bin/env bash
set -euo pipefail
trap 'echo "$0: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[@]}")" && pwd)"


###############################################################################
# Functions
###############################################################################
trace () {
    [[ "${VERBOSE_LEVEL:-0}" -lt 2 ]] || echo >&2 -e "🔬 \033[36m$*\033[0m"
}
debug () {
    [[ "${VERBOSE_LEVEL:-0}" -lt 1 ]] || echo >&2 -e "🔍 \033[36m$*\033[0m"
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
# Hide output of brew if VERBOSE_LEVEL is <3
QUIET=("--quiet")
[[ "${VERBOSE_LEVEL:-0}" -lt 3 ]] || QUIET=()

if ! command -v brew &> /dev/null ; then
    debug "Installing brew..."
    /usr/bin/env bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

debug "Updating brew..."
brew update "${QUIET[@]}" && brew upgrade "${QUIET[@]}"

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
BrewApps+=(pnpm)                # NodeJS package manager (faster than npm)
BrewApps+=(python)              # Python language
BrewApps+=(rg)                  # better grep
BrewApps+=(sd)                  # better sed
BrewApps+=(shellcheck)          # lint for bash
BrewApps+=(uv)                  # python package manager
BrewApps+=(wget)                # curl with different defaults

debug "Installing ${BrewApps[*]}..."
brew install "${QUIET[@]}" "${BrewApps[@]}"


###############################################################################
# Install claude
###############################################################################
debug "Installing nmp..."
npm install -g npm@latest >/dev/null

debug "Installing claude..."
#npm install -g @anthropic-ai/claude-code >/dev/null
warn "Installing outdated claude@1.0.67 to fix login problem"
warn "- https://github.com/anthropics/claude-code/issues/5118"
npm install -g @anthropic-ai/claude-code@1.0.67 >/dev/null


###############################################################################
# Create clodpod user and group
###############################################################################
CLODPOD_HOME="/Users/clodpod"
debug "Setting up clodpod user and group..."

# Check if group exists, create if needed
if ! dscl . -read /Groups/clodpod &>/dev/null 2>&1; then
    debug "Creating clodpod group..."

    # Find next available UID/GID starting from 501
    NEXT_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)
    NEXT_UID=$((NEXT_UID + 1))

    # Create group
    sudo dscl . -create /Groups/clodpod
    GROUP_ID=$NEXT_UID
else
    debug "Group clodpod already exists"
    GROUP_ID=$(dscl . -read /Groups/clodpod PrimaryGroupID 2>/dev/null | awk '{print $2}')
fi

# Ensure group has all required properties (idempotent)
debug "Configuring clodpod group properties..."
if [[ -z "${GROUP_ID:-}" ]]; then
    # Group exists but has no PrimaryGroupID, find next available
    NEXT_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)
    GROUP_ID=$((NEXT_UID + 1))
fi
sudo dscl . -create /Groups/clodpod PrimaryGroupID "$GROUP_ID"
sudo dscl . -create /Groups/clodpod RealName "clodpod Group"

# Check if user exists, create if needed
if ! dscl . -read /Users/clodpod &>/dev/null 2>&1; then
    debug "Creating clodpod user..."

    # Find next available UID
    NEXT_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)
    NEXT_UID=$((NEXT_UID + 1))

    # Create user
    sudo dscl . -create /Users/clodpod
    USER_ID=$NEXT_UID
else
    debug "User clodpod already exists"
    USER_ID=$(dscl . -read /Users/clodpod UniqueID 2>/dev/null | awk '{print $2}')
fi

# Ensure user has all required properties (idempotent)
debug "Configuring clodpod user properties..."
if [[ -z "${USER_ID:-}" ]]; then
    # User exists but has no UniqueID, find next available
    NEXT_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)
    USER_ID=$((NEXT_UID + 1))
fi
sudo dscl . -create /Users/clodpod UniqueID "$USER_ID"
sudo dscl . -create /Users/clodpod PrimaryGroupID "$GROUP_ID"
sudo dscl . -create /Users/clodpod RealName "clodpod User"
sudo dscl . -create /Users/clodpod NFSHomeDirectory "$CLODPOD_HOME"
sudo dscl . -create /Users/clodpod UserShell "/bin/zsh"

# Set a random password for the user (password required for SSH on macOS)
# We'll use key-based auth so the password won't actually be used.
RANDOM_PASS=$(openssl rand -base64 32)
sudo dscl . -passwd /Users/clodpod "$RANDOM_PASS"
sudo dscl . -create /Users/clodpod IsHidden 1  # Hide from login window

# Let's allow the user to login as this user if they want
#sudo dscl . -create /Users/clodpod IsHidden 0
#sudo dscl . -passwd /Users/clodpod "clodpod"

# Now add only to the SSH access group (required for SSH login)
# do not use sudo dscl; it creates duplicate entries when run more than once
sudo dseditgroup -o edit -a clodpod -t user com.apple.access_ssh


###############################################################################
# Allow clodpod user to update homebrew
###############################################################################
debug "Enable clodpod to update brew files"
sudo chown -R "clodpod:clodpod" "$(brew --prefix)"


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

