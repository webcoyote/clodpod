# shellcheck shell=bash

spec_helper_precheck() {
    : minimum_version "0.28.1"
}

spec_helper_loaded() {
    :
}

spec_helper_configure() {
    before_each 'setup_test_env'
    after_each 'cleanup_test_env'
}

setup_test_env() {
    export TEST_TMPDIR="${SHELLSPEC_TMPBASE}/test-$$-${SHELLSPEC_EXAMPLE_COUNT:-0}"
    export HOME="$TEST_TMPDIR/home"
    export WORKSPACE="$TEST_TMPDIR/workspace"
    export DATA_DIR="$HOME/.local/share/clodpod"
    export VERBOSE=0
    mkdir -p "$DATA_DIR" "$WORKSPACE"
}

cleanup_test_env() {
    rm -rf "${TEST_TMPDIR:?}"
}
