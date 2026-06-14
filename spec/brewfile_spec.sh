# shellcheck shell=bash
# shellcheck disable=SC2154 # TEST_TMPDIR set by spec_helper.sh

Describe 'guest/home/lib/brewfile.sh'
    Include guest/home/lib/brewfile.sh

    setup_brew_mock() {
        export BREW_LOG="$TEST_TMPDIR/brew.log"
        export BREW_CHECK_EXIT=0
        export BREW_INSTALL_EXIT=0
        : > "$BREW_LOG"
    }
    BeforeEach 'setup_brew_mock'

    # Mock 'brew' as a shell function. Records invocations to BREW_LOG and
    # returns a configurable exit code per subcommand. Function definitions
    # shadow PATH lookups, so the lib's 'brew ...' calls hit this instead.
    brew() {
        echo "brew $*" >> "$BREW_LOG"
        if [[ "$1" == "bundle" && "$2" == "check" ]]; then
            return "$BREW_CHECK_EXIT"
        fi
        if [[ "$1" == "bundle" && "$2" == "install" ]]; then
            return "$BREW_INSTALL_EXIT"
        fi
        return 0
    }

    make_project() {
        local dir="$1"
        mkdir -p "$dir"
        if [[ $# -ge 2 ]]; then
            printf '%s\n' "$2" > "$dir/Brewfile"
        fi
    }

    Describe 'apply_brewfile_if_present'
        It 'no-ops when no Brewfile present'
            make_project "$TEST_TMPDIR/proj"
            When call apply_brewfile_if_present "$TEST_TMPDIR/proj"
            The status should be success
            The contents of file "$BREW_LOG" should equal ""
        End

        It 'runs install when check reports drift'
            make_project "$TEST_TMPDIR/proj" 'brew "jq"'
            BREW_CHECK_EXIT=1
            When call apply_brewfile_if_present "$TEST_TMPDIR/proj"
            The status should be success
            The contents of file "$BREW_LOG" should include "bundle check"
            The contents of file "$BREW_LOG" should include "bundle install"
            The contents of file "$BREW_LOG" should include "--no-upgrade"
            The contents of file "$BREW_LOG" should include "$TEST_TMPDIR/proj/Brewfile"
            The stderr should include "applying"
        End

        It 'skips install when check passes'
            make_project "$TEST_TMPDIR/proj" 'brew "jq"'
            BREW_CHECK_EXIT=0
            When call apply_brewfile_if_present "$TEST_TMPDIR/proj"
            The status should be success
            The contents of file "$BREW_LOG" should include "bundle check"
            The contents of file "$BREW_LOG" should not include "bundle install"
        End

        It 'honors HOMEBREW_BUNDLE_FILE override'
            make_project "$TEST_TMPDIR/proj"   # no Brewfile in project
            mkdir -p "$TEST_TMPDIR/elsewhere"
            printf '%s\n' 'brew "jq"' > "$TEST_TMPDIR/elsewhere/Custom.brewfile"
            export HOMEBREW_BUNDLE_FILE="$TEST_TMPDIR/elsewhere/Custom.brewfile"
            BREW_CHECK_EXIT=1
            When call apply_brewfile_if_present "$TEST_TMPDIR/proj"
            The status should be success
            The contents of file "$BREW_LOG" should include "$TEST_TMPDIR/elsewhere/Custom.brewfile"
            The contents of file "$BREW_LOG" should not include "$TEST_TMPDIR/proj/Brewfile"
            The stderr should include "applying"
        End

        It 'warns loudly but returns 0 when install fails'
            make_project "$TEST_TMPDIR/proj" 'brew "jq"'
            BREW_CHECK_EXIT=1
            BREW_INSTALL_EXIT=1
            When call apply_brewfile_if_present "$TEST_TMPDIR/proj"
            The status should be success
            The stderr should include "WARNING"
            The stderr should include "$TEST_TMPDIR/proj/Brewfile"
        End

        It 'returns 0 with a warning when brew is missing'
            make_project "$TEST_TMPDIR/proj" 'brew "jq"'
            unset -f brew
            PATH="/usr/bin:/bin"
            When call apply_brewfile_if_present "$TEST_TMPDIR/proj"
            The status should be success
            The stderr should include "WARNING"
            The stderr should include "brew"
        End
    End

    Describe 'apply_all_project_brewfiles'
        It 'iterates each project subdir with a Brewfile'
            mkdir -p "$TEST_TMPDIR/projects"
            make_project "$TEST_TMPDIR/projects/alpha" 'brew "jq"'
            make_project "$TEST_TMPDIR/projects/beta"   # no Brewfile
            make_project "$TEST_TMPDIR/projects/gamma" 'brew "rg"'
            BREW_CHECK_EXIT=1
            When call apply_all_project_brewfiles "$TEST_TMPDIR/projects"
            The status should be success
            The contents of file "$BREW_LOG" should include "alpha/Brewfile"
            The contents of file "$BREW_LOG" should include "gamma/Brewfile"
            The contents of file "$BREW_LOG" should not include "beta/Brewfile"
            The stderr should include "applying"
        End

        It 'continues to remaining projects after one fails'
            mkdir -p "$TEST_TMPDIR/projects"
            make_project "$TEST_TMPDIR/projects/alpha" 'brew "jq"'
            make_project "$TEST_TMPDIR/projects/beta"  'brew "rg"'
            BREW_CHECK_EXIT=1
            BREW_INSTALL_EXIT=1
            When call apply_all_project_brewfiles "$TEST_TMPDIR/projects"
            The status should be success
            The contents of file "$BREW_LOG" should include "alpha/Brewfile"
            The contents of file "$BREW_LOG" should include "beta/Brewfile"
            The stderr should include "WARNING"
        End

        It 'handles empty projects root gracefully'
            mkdir -p "$TEST_TMPDIR/projects"
            When call apply_all_project_brewfiles "$TEST_TMPDIR/projects"
            The status should be success
            The contents of file "$BREW_LOG" should equal ""
        End

        It 'ignores non-directory entries in projects root'
            mkdir -p "$TEST_TMPDIR/projects"
            make_project "$TEST_TMPDIR/projects/alpha" 'brew "jq"'
            : > "$TEST_TMPDIR/projects/stray-file"
            BREW_CHECK_EXIT=1
            When call apply_all_project_brewfiles "$TEST_TMPDIR/projects"
            The status should be success
            The contents of file "$BREW_LOG" should include "alpha/Brewfile"
            The contents of file "$BREW_LOG" should not include "stray-file"
            The stderr should include "applying"
        End

        It 'skips the __install reserved mount'
            mkdir -p "$TEST_TMPDIR/projects"
            make_project "$TEST_TMPDIR/projects/alpha"    'brew "jq"'
            make_project "$TEST_TMPDIR/projects/__install" 'brew "rg"'
            BREW_CHECK_EXIT=1
            When call apply_all_project_brewfiles "$TEST_TMPDIR/projects"
            The status should be success
            The contents of file "$BREW_LOG" should include "alpha/Brewfile"
            The contents of file "$BREW_LOG" should not include "__install/Brewfile"
            The stderr should include "applying"
        End

        It 'handles missing projects root gracefully'
            When call apply_all_project_brewfiles "$TEST_TMPDIR/does-not-exist"
            The status should be success
            The contents of file "$BREW_LOG" should equal ""
        End
    End
End
