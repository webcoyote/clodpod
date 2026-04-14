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
EOF

    # Migration: add ram_mb column to existing instances tables
    local has_ram_mb
    has_ram_mb=$(sqlite3 "$DB_FILE" "PRAGMA table_info(instances);" | grep -c 'ram_mb') || true
    if [[ "$has_ram_mb" -eq 0 ]]; then
        sqlite3 "$DB_FILE" "ALTER TABLE instances ADD COLUMN ram_mb INTEGER;"
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
