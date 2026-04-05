# shellcheck shell=bash

Describe 'shellspec setup'
    It 'creates test environment'
        When call true
        The variable HOME should be defined
        The variable WORKSPACE should be defined
        The path "$DATA_DIR" should be directory
    End
End
