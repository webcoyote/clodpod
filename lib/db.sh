# shellcheck shell=bash
# shellcheck disable=SC2154 # globals set by config.sh: DB_FILE, DATA_DIR, OLD_DB_FILE
# Database operations: init, migrate, instance queries, settings

# Escape single quotes for safe SQLite string literals: ' → ''
sql_escape() { printf '%s' "${1//\'/\'\'}"; }

migrate_db() {
    if [[ -f "$DATA_DIR/clodpod.sqlite" ]]; then
        abort "Already migrated: $DATA_DIR/clodpod.sqlite exists"
    fi
    if [[ ! -f "$OLD_DB_FILE" ]]; then
        abort "Nothing to migrate: no database at $OLD_DB_FILE"
    fi
    mkdir -p "$DATA_DIR"
    mv "$OLD_DB_FILE" "$DATA_DIR/clodpod.sqlite"
    DB_FILE="$DATA_DIR/clodpod.sqlite"
    info "Migrated database to $DATA_DIR/clodpod.sqlite"

    ensure_ssh_key
    refresh_guest_home
}

# Check whether a column exists on a table. Uses grep's exit status directly
# to avoid arithmetic-context evaluation of a non-numeric variable (which
# breaks under `set -u` if the value happens to contain bare words).
column_exists() {
    local table="$1"
    local column="$2"
    sqlite3 "$DB_FILE" "PRAGMA table_info($table);" | grep -q "|$column|"
}

init_db() {
    debug "Creating $DB_FILE database..."
    sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS projects (
    path TEXT UNIQUE NOT NULL,
    name TEXT UNIQUE NOT NULL,
    date_added TEXT DEFAULT (datetime('now')),
    active INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS instances (
    name TEXT PRIMARY KEY,
    vm_name TEXT UNIQUE NOT NULL,
    ram_mb INTEGER,
    created_at TEXT DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS instance_dirs (
    instance_name TEXT NOT NULL,
    dir_name TEXT NOT NULL,
    dir_path TEXT NOT NULL,
    is_primary INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (instance_name, dir_name)
);
CREATE TABLE IF NOT EXISTS bases (
    name TEXT PRIMARY KEY,
    vm_name TEXT UNIQUE NOT NULL,
    oci_source TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
);
EOF

    # Migration: add ram_mb column to existing instances tables
    if ! column_exists instances ram_mb; then
        sqlite3 "$DB_FILE" "ALTER TABLE instances ADD COLUMN ram_mb INTEGER;"
    fi

    # Migration: add base_name column to instances table
    if ! column_exists instances base_name; then
        sqlite3 "$DB_FILE" "ALTER TABLE instances ADD COLUMN base_name TEXT;"
    fi

    # Migration: add ssh_user column to instances table
    if ! column_exists instances ssh_user; then
        sqlite3 "$DB_FILE" "ALTER TABLE instances ADD COLUMN ssh_user TEXT;"
    fi
}

vm_instance_exists() {
    local instance_name="$1"
    local count
    count=$(sqlite3 "$DB_FILE" <<EOF 2>/dev/null || echo 0
SELECT COUNT(*) FROM instances WHERE name = '$(sql_escape "$instance_name")';
EOF
)
    [[ "${count:-0}" -gt 0 ]]
}

vm_get_instance_vm_name() {
    local instance_name="$1"
    sqlite3 "$DB_FILE" <<EOF
SELECT vm_name FROM instances WHERE name = '$(sql_escape "$instance_name")' LIMIT 1;
EOF
}

vm_get_instance_ram_mb() {
    local instance_name="$1"
    sqlite3 "$DB_FILE" <<EOF
SELECT COALESCE(ram_mb, 0) FROM instances WHERE name = '$(sql_escape "$instance_name")' LIMIT 1;
EOF
}

vm_get_instance_count() {
    sqlite3 "$DB_FILE" <<EOF
SELECT COUNT(*) FROM instances;
EOF
}

vm_get_instance_names() {
    sqlite3 "$DB_FILE" <<EOF
SELECT name FROM instances ORDER BY created_at DESC, name ASC;
EOF
}

vm_get_only_instance_name() {
    sqlite3 "$DB_FILE" <<EOF
SELECT name FROM instances ORDER BY created_at DESC, name ASC LIMIT 1;
EOF
}

vm_get_ssh_user() {
    local instance_name="$1"
    local user
    user=$(sqlite3 "$DB_FILE" <<EOF
SELECT COALESCE(ssh_user, 'clodpod') FROM instances WHERE name = '$(sql_escape "$instance_name")' LIMIT 1;
EOF
)
    echo "${user:-clodpod}"
}

vm_get_instance_dirs() {
    local instance_name="$1"
    sqlite3 -separator '|' "$DB_FILE" <<EOF
SELECT dir_name, dir_path, is_primary
FROM instance_dirs
WHERE instance_name = '$(sql_escape "$instance_name")'
ORDER BY is_primary DESC, rowid ASC;
EOF
}

get_setting() {
    local key="$1"
    local default_value="${2:-}"
    local value
    value=$(sqlite3 "$DB_FILE" <<EOF
SELECT COALESCE((SELECT value FROM settings WHERE key = '$(sql_escape "$key")' LIMIT 1), '$(sql_escape "$default_value")');
EOF
)
    trace "Setting '$key' resolved to '$value'"
    echo "$value"
}

set_setting() {
    local key="$1"
    local value="$2"
    sqlite3 "$DB_FILE" <<EOF
INSERT OR REPLACE INTO settings (key, value, updated_at)
VALUES ('$(sql_escape "$key")', '$(sql_escape "$value")', datetime('now'));
EOF
}

base_exists() {
    local name="$1"
    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM bases WHERE name = '$(sql_escape "$name")';" 2>/dev/null || echo 0)
    [[ "${count:-0}" -gt 0 ]]
}

base_register() {
    local name="$1"
    local vm_name="$2"
    local oci_source="$3"
    sqlite3 "$DB_FILE" <<EOF
INSERT OR REPLACE INTO bases (name, vm_name, oci_source, created_at)
VALUES ('$(sql_escape "$name")', '$(sql_escape "$vm_name")', '$(sql_escape "$oci_source")', datetime('now'));
EOF
}

base_remove() {
    local name="$1"
    sqlite3 "$DB_FILE" "DELETE FROM bases WHERE name = '$(sql_escape "$name")';"
}

base_get_vm_name() {
    local name="$1"
    sqlite3 "$DB_FILE" "SELECT vm_name FROM bases WHERE name = '$(sql_escape "$name")' LIMIT 1;"
}

base_list() {
    sqlite3 -separator '|' "$DB_FILE" <<EOF
SELECT name, vm_name, oci_source, created_at FROM bases ORDER BY created_at DESC;
EOF
}