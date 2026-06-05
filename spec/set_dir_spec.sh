# shellcheck shell=bash
# shellcheck disable=SC2154 # TEST_TMPDIR set by spec_helper.sh

Describe 'clod set --dir / --dir-remove'
    Include lib/common.sh
    Include lib/db.sh
    Include lib/vm.sh
    Include lib/instance.sh

    setup_db() {
        DB_FILE="$TEST_TMPDIR/test.sqlite"
        init_db
        sqlite3 "$DB_FILE" "INSERT INTO instances (name, vm_name) VALUES ('dev', 'clodpod-dev');"
        sqlite3 "$DB_FILE" "INSERT INTO instance_dirs (instance_name, dir_name, dir_path, is_primary) VALUES ('dev', 'project', '/tmp', 1);"

        mkdir -p "$TEST_TMPDIR/srcdir"
        RESOLVED_TMPDIR="$(cd -P "$TEST_TMPDIR" && pwd -P)"
    }
    BeforeEach 'setup_db'

    vm_get_instance_vm_name() { echo "clodpod-$1"; }
    get_vm_state() { echo "stopped"; }

    Describe 'add new directory'
        It 'inserts new mount'
            When call vm_set --dir "code:$TEST_TMPDIR/srcdir" dev
            row=$(sqlite3 "$DB_FILE" "SELECT dir_path, is_primary FROM instance_dirs WHERE instance_name='dev' AND dir_name='code';")
            The status should be success
            The variable row should not be blank
            The stderr should include "Set --dir code"
        End

        It 'rejects __install reserved name'
            When run vm_set --dir "__install:$TEST_TMPDIR/srcdir" dev
            The status should be failure
            The stderr should include "reserved"
        End

        It 'rejects nonexistent directory'
            When run vm_set --dir "code:/this/does/not/exist" dev
            The status should be failure
            The stderr should include "directory not found"
        End

        It 'rejects nonexistent instance'
            When run vm_set --dir "code:$TEST_TMPDIR/srcdir" ghost
            The status should be failure
            The stderr should include "instance not found"
        End
    End

    Describe 'replace existing directory'
        It 'updates path of existing mount'
            mkdir -p "$TEST_TMPDIR/newpath"
            vm_set --dir "project:$TEST_TMPDIR/newpath" dev 2>/dev/null
            path=$(sqlite3 "$DB_FILE" "SELECT dir_path FROM instance_dirs WHERE instance_name='dev' AND dir_name='project';")
            When call echo "$path"
            The output should eq "$RESOLVED_TMPDIR/newpath"
        End

        It 'preserves is_primary on replace'
            mkdir -p "$TEST_TMPDIR/newpath"
            vm_set --dir "project:$TEST_TMPDIR/newpath" dev 2>/dev/null
            primary=$(sqlite3 "$DB_FILE" "SELECT is_primary FROM instance_dirs WHERE instance_name='dev' AND dir_name='project';")
            When call echo "$primary"
            The output should eq "1"
        End

        It 'prints (replaced) suffix'
            When call vm_set --dir "project:$TEST_TMPDIR/srcdir" dev
            The stderr should include "(replaced)"
        End
    End

    Describe '--dir-remove'
        setup_secondary() {
            sqlite3 "$DB_FILE" "INSERT INTO instance_dirs (instance_name, dir_name, dir_path, is_primary) VALUES ('dev', 'extra', '/tmp', 0);"
        }
        Before 'setup_secondary'

        It 'removes non-primary directory'
            vm_set --dir-remove extra dev 2>/dev/null
            count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM instance_dirs WHERE instance_name='dev' AND dir_name='extra';")
            When call echo "$count"
            The output should eq "0"
        End

        It 'prints Removed info'
            When call vm_set --dir-remove extra dev
            The stderr should include "Removed --dir extra"
        End

        It 'rejects removing primary'
            When run vm_set --dir-remove project dev
            The status should be failure
            The stderr should include "Cannot remove primary"
        End

        It 'rejects nonexistent mount name'
            When run vm_set --dir-remove nonexistent dev
            The status should be failure
            The stderr should include "not found"
        End

        It 'rejects nonexistent instance'
            When run vm_set --dir-remove extra ghost
            The status should be failure
            The stderr should include "instance not found"
        End
    End

    Describe 'multi-flag rejection'
        It 'rejects two --dir flags'
            When run vm_set --dir "a:$TEST_TMPDIR/srcdir" dev --dir "b:$TEST_TMPDIR/srcdir" dev
            The status should be failure
            The stderr should include "only one --dir operation"
        End

        It 'rejects --dir mixed with --dir-remove'
            When run vm_set --dir "a:$TEST_TMPDIR/srcdir" dev --dir-remove b dev
            The status should be failure
            The stderr should include "only one --dir operation"
        End
    End
End
