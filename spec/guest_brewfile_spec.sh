# shellcheck shell=bash
#
# Guards the base-image Brewfile against regression.
#
# guest/Brewfile replaces the hand-rolled BrewApps array that used to live in
# guest/install.sh. Because the base image is expensive to rebuild, a package
# silently dropped from this file would not surface until someone rebuilt and
# found a missing tool. These examples pin the full inventory instead.

Describe 'guest/Brewfile'
    BREWFILE="${SHELLSPEC_PROJECT_ROOT}/guest/Brewfile"

    # Match a 'brew "name"' or 'cask "name"' entry, tolerating trailing
    # options (e.g. ', start_service: true') and any leading indentation.
    declares() {
        local kind="$1" name="$2"
        grep -Eq "^[[:space:]]*${kind}[[:space:]]+\"${name}\"([[:space:],]|\$)" "$BREWFILE"
    }

    # Every meaningful line must be a Brewfile DSL entry. Catches a stray
    # shell-ism left behind by the port from install.sh.
    non_dsl_lines() {
        grep -vE '^[[:space:]]*(#|$)' "$BREWFILE" \
            | grep -vE '^[[:space:]]*(brew|cask|tap|mas|vscode|whalebrew)[[:space:]]+"' \
            || true
    }

    It 'exists'
        The path "$BREWFILE" should be exist
    End

    Describe 'command-line tools'
        Parameters
            bash            # replaces the ancient OSX bash 3.2
            bat             # better cat
            coreutils       # GNU replacements for BSD tools
            eza             # better ls
            fd              # better find
            findutils       # gxargs with '-r'
            git
            git-delta       # pager for git diff
            git-lfs
            gnu-getopt      # OSX getopt is ancient
            jq
            mas             # Apple Store CLI
            node
            python
            rg              # alias for ripgrep; brew bundle resolves aliases
            sd              # better sed
            shellcheck
            uv
            wget
        End

        It "declares $1"
            When call declares brew "$1"
            The status should be success
        End
    End

    Describe 'AI agent casks'
        Parameters
            claude-code
            codex
        End

        It "declares $1"
            When call declares cask "$1"
            The status should be success
        End
    End

    It 'contains only Brewfile DSL entries'
        When call non_dsl_lines
        The output should equal ""
    End
End

Describe 'guest/install.sh'
    INSTALL_SH="${SHELLSPEC_PROJECT_ROOT}/guest/install.sh"

    # The Brewfile must be the single source of truth for base packages.
    # A second inventory inside install.sh is how the two drift apart.
    ad_hoc_brew_installs() {
        grep -nE '^[[:space:]]*brew (install|upgrade)' "$INSTALL_SH" \
            | grep -vE 'brew (install|upgrade) *$' \
            || true
    }

    It 'installs base packages via brew bundle'
        When call grep -qE 'brew bundle install .*--file=' "$INSTALL_SH"
        The status should be success
    End

    It 'no longer carries its own package inventory'
        When call grep -q 'BrewApps' "$INSTALL_SH"
        The status should be failure
    End

    It 'has no ad-hoc brew install lines outside the Brewfile'
        When call ad_hoc_brew_installs
        The output should equal ""
    End
End
