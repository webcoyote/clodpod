# shellcheck shell=bash

# Source help functions for direct testing
# SHELLSPEC_PROJECT_ROOT points to the repo root
setup_help() {
    # shellcheck source=lib/common.sh
    . "${SHELLSPEC_PROJECT_ROOT}/lib/common.sh"
    # shellcheck source=lib/commands.sh
    . "${SHELLSPEC_PROJECT_ROOT}/lib/commands.sh"
    VERSION="1.0.test"
}

Describe 'top-level help'
    setup() { setup_help; }
    Before 'setup'

    It 'includes version'
        When call show_help
        The output should include "clodpod v1.0.test"
    End

    It 'lists commands'
        When call show_help
        The output should include "create, cr"
        The output should include "build-base"
        The output should include "shell, sh, s"
        The output should include "help, h"
    End

    It 'shows VM layers'
        When call show_help
        The output should include "Layer 0 (OCI)"
        The output should include "Layer 1 (base)"
        The output should include "Layer 2 (instance)"
    End

    It 'shows --no-select option'
        When call show_help
        The output should include "--no-select"
    End
End

Describe 'per-command help'
    setup() { setup_help; }
    Before 'setup'

    It 'show_help_create shows create usage'
        When call show_help_create
        The output should include "clod create <name>"
        The output should include "--base"
        The output should include "--dir"
        The output should include "--ram"
    End

    It 'show_help_build_base shows layers'
        When call show_help_build_base
        The output should include "Layer 0"
        The output should include "--rebuild-oci"
        The output should include "--profile"
        The output should include "ALLOW_SUDO"
    End

    It 'show_help_set shows all set options'
        When call show_help_set
        The output should include "--ram SIZE NAME"
        The output should include "--max-memory"
        The output should include "--vm-count"
    End

    It 'show_help_shell shows -- passthrough'
        When call show_help_shell
        The output should include "-- command..."
        The output should include "--ram SIZE"
    End

    It 'show_help_destroy shows --all'
        When call show_help_destroy
        The output should include "--all"
    End

    It 'show_help_stop shows optional NAME'
        When call show_help_stop
        The output should include "stop [NAME]"
    End
End

Describe 'dispatch_help'
    setup() { setup_help; }
    Before 'setup'

    It 'dispatches create'
        When call dispatch_help "create"
        The output should include "clod create <name>"
    End

    It 'dispatches cr alias'
        When call dispatch_help "cr"
        The output should include "clod create <name>"
    End

    It 'dispatches build-base'
        When call dispatch_help "build-base"
        The output should include "clod build-base"
    End

    It 'dispatches shell aliases'
        When call dispatch_help "sh"
        The output should include "clod shell"
    End

    It 'dispatches simple commands'
        When call dispatch_help "claude"
        The output should include "Claude Code"
    End

    It 'dispatches cl alias'
        When call dispatch_help "cl"
        The output should include "Claude Code"
    End

    It 'falls back to top-level for unknown'
        When call dispatch_help "nonexistent"
        The output should include "clodpod v1.0.test"
    End

    It 'falls back to top-level for empty'
        When call dispatch_help ""
        The output should include "clodpod v1.0.test"
    End
End
