# shellcheck shell=bash
#
# herdr is the agent multiplexer: one VM session hosting many agents in panes,
# rather than one terminal window per 'clod claude'. These examples pin the
# three places that wiring lives — the Brewfile entry, the launcher shim, and
# the clod dispatch arm — since none of them is exercised without a VM.

Describe 'herdr integration'

    Describe 'guest/Brewfile'
        BREWFILE="${SHELLSPEC_PROJECT_ROOT}/guest/Brewfile"

        It 'declares herdr'
            When call grep -qE '^[[:space:]]*brew "herdr"' "$BREWFILE"
            The status should be success
        End

        # herdr runs a background server that owns the panes. Without
        # start_service the daemon dies with the shell that spawned it.
        It 'starts the herdr server as a service'
            When call grep -qE '^[[:space:]]*brew "herdr".*start_service:[[:space:]]*true' "$BREWFILE"
            The status should be success
        End
    End

    Describe 'guest/home/bin/herdr shim'
        SHIM="${SHELLSPEC_PROJECT_ROOT}/guest/home/bin/herdr"

        It 'exists'
            The path "$SHIM" should be exist
        End

        It 'is executable'
            The path "$SHIM" should be executable
        End

        # Pass-through is what makes 'clod herdr . -- --session other' work:
        # .zshrc execs COMMAND with COMMAND_ARGS appended.
        # Pass-through with nothing spliced in between. The agent shims force
        # an auto-approve flag; herdr is a multiplexer, not an agent, and an
        # injected flag would shadow its subcommands.
        It 'execs the real binary with arguments verbatim'
            When call grep -qF 'exec "$APP" "$@"' "$SHIM"
            The status should be success
        End

        It 'injects no auto-approve flag'
            When call grep -qE 'dangerously|--yolo' "$SHIM"
            The status should be failure
        End
    End

    Describe 'clod dispatch'
        CLOD="${SHELLSPEC_PROJECT_ROOT}/clod"

        It 'accepts the herdr command and hd alias'
            When call grep -qE '^[[:space:]]*herdr\|hd\)' "$CLOD"
            The status should be success
        End

        It 'runs herdr as the guest command'
            When call grep -qE '^[[:space:]]*COMMAND=herdr' "$CLOD"
            The status should be success
        End
    End

    Describe 'guest/configure.sh'
        CONFIGURE="${SHELLSPEC_PROJECT_ROOT}/guest/configure.sh"

        # Without an installed integration herdr falls back to heuristic
        # detection, and the working/blocked/done sidebar becomes decorative.
        It 'installs herdr integrations for the preinstalled agents'
            When call grep -qE 'herdr integration install' "$CONFIGURE"
            The status should be success
        End
    End
End
