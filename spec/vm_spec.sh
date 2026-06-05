# shellcheck shell=bash

Describe 'lib/vm.sh'
    Include lib/common.sh
    Include lib/vm.sh

    Describe 'parse_dir_spec'
        It 'parses name:path'
            When call parse_dir_spec "code:/Users/me/src"
            The output should eq "code|/Users/me/src"
        End

        It 'preserves : in path'
            When call parse_dir_spec "code:/foo:bar/baz"
            The output should eq "code|/foo:bar/baz"
        End

        It 'rejects missing colon'
            When call parse_dir_spec "noslash"
            The status should be failure
        End

        It 'rejects empty input'
            When call parse_dir_spec ""
            The status should be failure
        End

        It 'rejects missing name'
            When call parse_dir_spec ":/path"
            The status should be failure
        End

        It 'rejects missing path'
            When call parse_dir_spec "name:"
            The status should be failure
        End
    End
End
