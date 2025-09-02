#!/usr/bin/env bash
set -euo pipefail
trap 'echo "$0: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"


###############################################################################
# Preconditions
###############################################################################
if [[ $OSTYPE != 'darwin'* ]]; then
    echo >&2 "ERROR: this script is for Mac OSX"
    exit 1
fi


###############################################################################
# Functions
###############################################################################
info () {
  echo >&2 -e "\033[36m$*\033[0m"
}
warn () {
  echo >&2 -e "\033[33m$*\033[0m"
}
error () {
  echo >&2 -e "\033[31m$*\033[0m"
}
abort () {
  error "$@"
  exit 1
}


###############################################################################
# Configure clodpod user
###############################################################################
info "🔨 Configure clodpod user..."

# Copy files to home directory
DIST_DIR="/Volumes/My Shared Files/__install"
sudo mkdir -p "/Users/clodpod"
sudo cp -rf "$DIST_DIR/home/." "/Users/clodpod/"

# Create symbolic links for all the projects
sudo mkdir -p "/Users/clodpod/projects"
fd -t d --max-depth 1 . "/Volumes/My Shared Files" -0 | while IFS= read -r -d '' dir; do
    [[ "$(basename "$dir")" == "__install" ]] && continue
    sudo ln -sf "$dir" "/Users/clodpod/projects/$(basename "$dir")"
done

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
