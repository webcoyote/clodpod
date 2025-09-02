#!/usr/bin/env bash
set -euo pipefail
trap 'echo "$0: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR
#SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[@]}")" && pwd)"


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
sudo scutil --set ComputerName "clodpod-xcode"
sudo scutil --set LocalHostName "clodpod-xcode"
sudo scutil --set HostName "clodpod-xcode"


###############################################################################
# Configure clodpod user
###############################################################################
debug "Configure clodpod user..."

# Copy files to home directory
DIST_DIR="/Volumes/My Shared Files/__install"
sudo mkdir -p "/Users/clodpod"
sudo cp -rf "$DIST_DIR/home/." "/Users/clodpod/"

# Make clodpod the owner of the files
sudo chown -R "clodpod:clodpod" "/Users/clodpod"

# Fixup file permissions
sudo chmod 755 "/Users/clodpod"
sudo chmod 700 "/Users/clodpod/.ssh"
if [[ -f "/Users/clodpod/authorized_keys" ]]; then
    sudo chmod 600 "/Users/clodpod/authorized_keys"
fi
if [[ -f "/Users/clodpod/.ssh/id_ed25519" ]]; then
    sudo chmod 600 "/Users/clodpod/.ssh/id_ed25519"
fi
if [[ -f "/Users/clodpod/.ssh/id_ed25519.pub" ]]; then
    sudo chmod 644 "/Users/clodpod/.ssh/id_ed25519.pub"
fi
