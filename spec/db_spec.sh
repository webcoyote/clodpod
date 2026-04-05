# shellcheck shell=bash

Describe 'lib/db.sh'
    Include lib/common.sh
    Include lib/db.sh

    Describe 'sql_escape'
        It 'escapes single quotes'
            When call sql_escape "it's a test"
            The output should eq "it''s a test"
        End

        It 'passes plain strings through'
            When call sql_escape "hello"
            The output should eq "hello"
        End

        It 'handles empty string'
            When call sql_escape ""
            The output should eq ""
        End
    End

    Describe 'init_db'
        It 'creates all tables'
            DB_FILE="$TEST_TMPDIR/test.sqlite"
            When call init_db
            The status should be success
            The path "$DB_FILE" should be file
        End

        It 'is idempotent'
            DB_FILE="$TEST_TMPDIR/test.sqlite"
            init_db
            When call init_db
            The status should be success
        End
    End

    Describe 'instance operations'
        setup_db() {
            DB_FILE="$TEST_TMPDIR/test.sqlite"
            init_db
        }

        BeforeEach 'setup_db'

        Describe 'vm_instance_exists'
            It 'returns false for missing instance'
                When call vm_instance_exists "nonexistent"
                The status should be failure
            End

            It 'returns true for existing instance'
                sqlite3 "$DB_FILE" "INSERT INTO instances (name, vm_name) VALUES ('test', 'clodpod-test');"
                When call vm_instance_exists "test"
                The status should be success
            End
        End

        Describe 'vm_get_instance_vm_name'
            It 'returns vm_name for instance'
                sqlite3 "$DB_FILE" "INSERT INTO instances (name, vm_name) VALUES ('dev', 'clodpod-dev');"
                When call vm_get_instance_vm_name "dev"
                The output should eq "clodpod-dev"
            End
        End

        Describe 'vm_get_instance_count'
            It 'returns 0 for empty table'
                When call vm_get_instance_count
                The output should eq "0"
            End

            It 'returns correct count'
                sqlite3 "$DB_FILE" "INSERT INTO instances (name, vm_name) VALUES ('a', 'clodpod-a');"
                sqlite3 "$DB_FILE" "INSERT INTO instances (name, vm_name) VALUES ('b', 'clodpod-b');"
                When call vm_get_instance_count
                The output should eq "2"
            End
        End

        Describe 'get_setting and set_setting'
            It 'returns default when not set'
                When call get_setting "missing_key" "fallback"
                The output should eq "fallback"
            End

            It 'returns stored value'
                set_setting "my_key" "my_value"
                When call get_setting "my_key" "fallback"
                The output should eq "my_value"
            End

            It 'overwrites existing value'
                set_setting "key" "old"
                set_setting "key" "new"
                When call get_setting "key" ""
                The output should eq "new"
            End
        End
    End
End
