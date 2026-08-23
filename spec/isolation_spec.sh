# shellcheck shell=bash
# shellcheck disable=SC2154 # TEST_TMPDIR set by spec_helper.sh
# shellcheck disable=SC2329 # stub functions are invoked indirectly by vm_shell

Describe 'project isolation'
    Include lib/common.sh
    Include lib/db.sh
    Include lib/vm.sh
    Include lib/project.sh
    Include lib/instance.sh

    setup_db() {
        DB_FILE="$TEST_TMPDIR/test.sqlite"
        init_db
        mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta"
        sqlite3 "$DB_FILE" "INSERT INTO projects (path, name, date_added) VALUES ('$TEST_TMPDIR/alpha', 'alpha', '2026-01-01 00:00:00');"
        sqlite3 "$DB_FILE" "INSERT INTO projects (path, name, date_added) VALUES ('$TEST_TMPDIR/beta', 'beta', '2026-01-02 00:00:00');"
    }
    BeforeEach 'setup_db'

    get_vm_state() { echo "stopped"; }
    count_active() { sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM projects WHERE active = 1;"; }
    active_names() { sqlite3 "$DB_FILE" "SELECT name FROM projects WHERE active = 1;"; }
    isolation_setting() { sqlite3 "$DB_FILE" "SELECT value FROM settings WHERE key = 'isolate_projects';"; }
    map_dirs() { get_map_directories | tr '\0' '\n'; }

    Describe 'vm_get_instance_dirs xcode'
        It 'returns all projects when isolation is off'
            When call vm_get_instance_dirs "xcode"
            The line 1 of output should eq "beta|$TEST_TMPDIR/beta|1"
            The line 2 of output should eq "alpha|$TEST_TMPDIR/alpha|0"
        End

        It 'returns only the primary project when isolation is on'
            set_setting "isolate_projects" "true"
            When call vm_get_instance_dirs "xcode"
            The output should eq "beta|$TEST_TMPDIR/beta|1"
        End
    End

    Describe 'get_map_directories'
        It 'maps all projects when isolation is off'
            When call map_dirs
            The output should include "alpha:$TEST_TMPDIR/alpha"
            The output should include "beta:$TEST_TMPDIR/beta"
        End

        It 'maps only the primary project when isolation is on'
            set_setting "isolate_projects" "true"
            When call map_dirs
            The output should include "beta:$TEST_TMPDIR/beta"
            The output should not include "alpha:$TEST_TMPDIR/alpha"
        End
    End

    Describe 'mark_projects_active'
        It 'marks all projects active when isolation is off'
            When call mark_projects_active
            The result of function count_active should eq "2"
        End

        It 'marks only the primary project active when isolation is on'
            set_setting "isolate_projects" "true"
            When call mark_projects_active
            The result of function count_active should eq "1"
            The result of function active_names should eq "beta"
        End
    End

    Describe 'check_projects_active'
        It 'fails when a project is inactive and isolation is off'
            sqlite3 "$DB_FILE" "UPDATE projects SET active = 1 WHERE name = 'beta';"
            When call check_projects_active
            The status should be failure
        End

        It 'succeeds when only the primary is active and isolation is on'
            set_setting "isolate_projects" "true"
            sqlite3 "$DB_FILE" "UPDATE projects SET active = 1 WHERE name = 'beta';"
            When call check_projects_active
            The status should be success
        End

        It 'fails when a non-primary project is still active and isolation is on'
            set_setting "isolate_projects" "true"
            sqlite3 "$DB_FILE" "UPDATE projects SET active = 1;"
            When call check_projects_active
            The status should be failure
        End

        It 'fails when the primary project changed and isolation is on'
            set_setting "isolate_projects" "true"
            sqlite3 "$DB_FILE" "UPDATE projects SET active = 1 WHERE name = 'beta';"
            sqlite3 "$DB_FILE" "UPDATE projects SET date_added = '2026-01-03 00:00:00' WHERE name = 'alpha';"
            When call check_projects_active
            The status should be failure
        End
    End

    # Declining the restart prompt must not connect to a VM whose mounts are
    # stale. Without isolation the older projects are still mounted, so
    # reconnecting is merely incomplete; under isolation the active project is
    # the only mount, so connecting would land the user in a VM without it.
    Describe 'vm_shell declining the restart prompt'
        shell_running_with_stale_mounts() {
            get_vm_state() { echo "running"; }
            get_vm_exists() { return 0; }
            ensure_ssh_key() { :; }
            vm_get_instance_vm_name() { echo "clodpod-xcode"; }
            vm_get_instance_ram_mb() { echo 0; }
            vm_get_ssh_user() { echo "admin"; }
            stop_vm() { echo "stop_vm called"; }
            vm_run() { echo "vm_run called"; }
            ssh_into_vm() { echo "ssh_into_vm called"; }
            # Decline the "restart it? (y/N)" prompt
            vm_shell "xcode" </dev/null
        }

        It 'connects anyway when isolation is off'
            # beta active, alpha not -> check_projects_active fails
            sqlite3 "$DB_FILE" "UPDATE projects SET active = 1 WHERE name = 'beta';"
            When run shell_running_with_stale_mounts
            The status should be success
            The output should include "ssh_into_vm called"
            The output should not include "vm_run called"
            The stderr should include "restart required"
        End

        It 'aborts instead of connecting when isolation is on'
            set_setting "isolate_projects" "true"
            # alpha active but beta is primary -> mounts are stale under isolation
            sqlite3 "$DB_FILE" "UPDATE projects SET active = 1 WHERE name = 'alpha';"
            When run shell_running_with_stale_mounts
            The status should be failure
            The output should not include "ssh_into_vm called"
            The stderr should include "not mounted in the running VM"
        End
    End

    Describe 'clod set --isolation'
        It 'enables isolation with on'
            When call vm_set --isolation on
            The status should be success
            The stderr should include "isolation enabled"
            The result of function isolation_setting should eq "true"
        End

        It 'disables isolation with off'
            set_setting "isolate_projects" "true"
            When call vm_set --isolation off
            The status should be success
            The stderr should include "isolation disabled"
            The result of function isolation_setting should eq ""
        End

        It 'rejects invalid values'
            When run vm_set --isolation sideways
            The status should be failure
            The stderr should include "Invalid --isolation value"
        End
    End
End
