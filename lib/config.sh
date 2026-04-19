# shellcheck shell=bash
# Configuration: validation, version, names, paths

VALID_MACOS_VERSIONS="tahoe sequoia sonoma ventura monterey"
VALID_MACOS_FLAVORS="vanilla base xcode"

is_valid_version() {
    case " $VALID_MACOS_VERSIONS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

is_valid_flavor() {
    case " $VALID_MACOS_FLAVORS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve database location: new XDG path, legacy install path, or fresh install
resolve_db_file() {
    if [[ -f "$DATA_DIR/clodpod.sqlite" ]]; then
        printf '%s' "$DATA_DIR/clodpod.sqlite"
    elif [[ -f "$OLD_DB_FILE" ]]; then
        info "Database found at $OLD_DB_FILE"
        info "Run 'clod migrate' to move it to $DATA_DIR/"
        info "If you have multiple clodpod checkouts, migrate from only one."
        printf '%s' "$OLD_DB_FILE"
    else
        mkdir -p "$DATA_DIR"
        printf '%s' "$DATA_DIR/clodpod.sqlite"
    fi
}

validate_platform() {
    if [[ $OSTYPE != 'darwin'* ]]; then
        abort "ERROR: this script is for Mac OSX"
    fi
}

validate_config() {
    MACOS_VERSION=$(echo "$MACOS_VERSION" | tr '[:upper:]' '[:lower:]')
    MACOS_FLAVOR=$(echo "$MACOS_FLAVOR" | tr '[:upper:]' '[:lower:]')

    if ! is_valid_version "$MACOS_VERSION"; then
        abort "Unknown MACOS_VERSION $MACOS_VERSION; try $VALID_MACOS_VERSIONS"
    fi
    if ! is_valid_flavor "$MACOS_FLAVOR"; then
        abort "Unknown MACOS_FLAVOR $MACOS_FLAVOR; try $VALID_MACOS_FLAVORS"
    fi
}

# shellcheck disable=SC2034,SC2154 # variables used/set by clod and other modules
init_config() {
    VERSION="1.0.21"
    OCI_VM_NAME="clodpod-oci-${MACOS_VERSION}-${MACOS_FLAVOR}"
    BASE_VM_NAME="clodpod-base-default"
    DST_VM_NAME="clodpod-xcode"
    DATA_DIR="$HOME/.local/share/clodpod"
    OLD_DB_FILE="$WORKSPACE/.clodpod.sqlite"
    DB_FILE="$(resolve_db_file)"
    SSH_DIR="$HOME/.ssh"
    SSH_KEYFILE_PRIV="$SSH_DIR/id_ed25519_clodpod"
    SSH_KEYFILE_PUB="$SSH_KEYFILE_PRIV.pub"
    SSH_KEY_CREATED=false
    MACOS_IMAGE="ghcr.io/cirruslabs/macos-$MACOS_VERSION-$MACOS_FLAVOR:latest"
    debug "MacOS image: $MACOS_IMAGE"
}

# Rename legacy VM names to new scheme (one-time, idempotent)
migrate_vm_names() {
    local old new
    # OCI cache: clodpod-oci-base → clodpod-oci-<version>-<flavor>
    old="clodpod-oci-base"
    new="$OCI_VM_NAME"
    if [[ "$old" != "$new" ]] && tart list --quiet 2>/dev/null | grep -q "^${old}$"; then
        if ! tart list --quiet 2>/dev/null | grep -q "^${new}$"; then
            info "Renaming VM $old → $new"
            tart rename "$old" "$new"
        fi
    fi

    # Base: clodpod-xcode-base → clodpod-base-default
    old="clodpod-xcode-base"
    new="$BASE_VM_NAME"
    if [[ "$old" != "$new" ]] && tart list --quiet 2>/dev/null | grep -q "^${old}$"; then
        if ! tart list --quiet 2>/dev/null | grep -q "^${new}$"; then
            info "Renaming VM $old → $new"
            tart rename "$old" "$new"
        fi
    fi

    # Register existing base in DB if not tracked yet
    if tart list --quiet 2>/dev/null | grep -q "^${BASE_VM_NAME}$"; then
        if ! base_exists "default"; then
            local oci_source="${MACOS_VERSION}-${MACOS_FLAVOR}"
            base_register "default" "$BASE_VM_NAME" "$oci_source"
            debug "Registered existing base in database"
        fi
    fi
}
