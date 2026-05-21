# shellcheck shell=bash

Describe 'lib/firewall.sh'
    Include lib/common.sh
    Include lib/firewall.sh

    Describe '_domains_to_filter'
        It 'converts exact domain to anchored regex'
            local input="$TEST_TMPDIR/domains.txt"
            local output="$TEST_TMPDIR/filter.txt"
            echo "example.com" > "$input"
            When call _domains_to_filter "$input" "$output"
            The contents of file "$output" should eq "^example\.com$"
        End

        It 'converts leading-dot domain to subdomain regex'
            local input="$TEST_TMPDIR/domains.txt"
            local output="$TEST_TMPDIR/filter.txt"
            echo ".github.com" > "$input"
            When call _domains_to_filter "$input" "$output"
            The contents of file "$output" should eq '(^|\.)github\.com$'
        End

        It 'handles multiple domains'
            local input="$TEST_TMPDIR/domains.txt"
            local output="$TEST_TMPDIR/filter.txt"
            printf "%s\n" ".github.com" "exact.io" ".anthropic.com" > "$input"
            When call _domains_to_filter "$input" "$output"
            The line 1 of contents of file "$output" should eq '(^|\.)github\.com$'
            The line 2 of contents of file "$output" should eq '^exact\.io$'
            The line 3 of contents of file "$output" should eq '(^|\.)anthropic\.com$'
        End

        It 'skips blank lines'
            local input="$TEST_TMPDIR/domains.txt"
            local output="$TEST_TMPDIR/filter.txt"
            printf "%s\n" "" "example.com" "" > "$input"
            When call _domains_to_filter "$input" "$output"
            The contents of file "$output" should eq "^example\.com$"
        End

        It 'strips leading/trailing whitespace'
            local input="$TEST_TMPDIR/domains.txt"
            local output="$TEST_TMPDIR/filter.txt"
            printf "  example.com  \n" > "$input"
            When call _domains_to_filter "$input" "$output"
            The contents of file "$output" should eq "^example\.com$"
        End
    End

    Describe 'firewall_detect_gateway'
        It 'returns softnet default when bridge100 is down'
            # Mock ifconfig to return nothing for bridge100
            ifconfig() { return 1; }
            When call firewall_detect_gateway
            The output should eq "192.168.2.1"
        End

        It 'parses IP from bridge100 when available'
            ifconfig() {
                cat <<'MOCK'
bridge100: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	options=3<RXCSUM,TXCSUM>
	ether 36:63:c4:5d:72:64
	inet 192.168.2.1 netmask 0xffffff00 broadcast 192.168.2.255
	Configuration:
MOCK
            }
            When call firewall_detect_gateway
            The output should eq "192.168.2.1"
        End

        It 'handles non-default softnet subnet'
            ifconfig() {
                cat <<'MOCK'
bridge100: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 10.0.0.1 netmask 0xffffff00 broadcast 10.0.0.255
MOCK
            }
            When call firewall_detect_gateway
            The output should eq "10.0.0.1"
        End
    End

    Describe 'firewall_proxy_url'
        It 'returns correct URL with detected gateway'
            ifconfig() {
                echo "bridge100: flags=8863<UP>"
                echo "	inet 192.168.2.1 netmask 0xffffff00"
            }
            When call firewall_proxy_url
            The output should eq "http://192.168.2.1:3128"
        End

        It 'respects custom FIREWALL_PORT'
            FIREWALL_PORT=8080
            ifconfig() {
                echo "bridge100: flags=8863<UP>"
                echo "	inet 192.168.2.1 netmask 0xffffff00"
            }
            When call firewall_proxy_url
            The output should eq "http://192.168.2.1:8080"
            FIREWALL_PORT=3128
        End
    End

    Describe 'firewall_softnet_args'
        It 'outputs block-all and allow-gateway flags'
            When call firewall_softnet_args
            The line 1 should eq "--net-softnet-block=0.0.0.0/0"
            The line 2 should eq "--net-softnet-allow=192.168.2.1/32"
        End
    End

    Describe 'firewall_start'
        It 'aborts on missing domains file'
            When run firewall_start "/nonexistent/path.txt"
            The status should be failure
            The stderr should include "not found"
        End

        It 'aborts on empty domains file (after stripping comments)'
            local domains="$TEST_TMPDIR/empty.txt"
            printf "# just a comment\n\n" > "$domains"
            When run firewall_start "$domains"
            The status should be failure
            The stderr should include "empty"
        End
    End
End
