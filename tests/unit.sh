#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=iptables_Forward.sh
source ./iptables_Forward.sh

passed=0
check() {
    local name="$1"
    shift
    if "$@"; then
        printf 'PASS %s\n' "$name"
        passed=$((passed + 1))
    else
        printf 'FAIL %s\n' "$name" >&2
        exit 1
    fi
}
reject() { ! "$@" >/dev/null 2>&1; }
equal() { [[ "$1" == "$2" ]]; }

check 'port 1' validate_port 1
check 'port 65535' validate_port 65535
check 'leading zero interpreted as decimal' validate_port 08
for value in 0 65536 -1 999999999999999999999999999999999 1+2 '1;id' ''; do
    check "reject port <$value>" reject validate_port "$value"
done
check 'port canonicalization' equal "$(prompt_port port <<< 00080)" 80
check 'invalid port retries' equal "$(prompt_port port <<< $'oops\n0080')" 80
check 'IPv4 family' equal "$(detect_ip_family 192.0.2.1)" 4
check 'IPv6 family' equal "$(detect_ip_family '[2001:db8::1]')" 6
for value in 999.1.1.1 192.168.01.2 '1:2' '2001:db8:::1' '::1;include' 'fe80::1%eth0'; do
    check "reject malformed IP <$value>" reject detect_ip_family "$value"
done
for value in 127.0.0.1 0.0.0.0 ::1 :: ff02::1 fe80::1; do
    check "reject unusable target <$value>" reject ip_value address "$value"
done
check 'CIDR normalization' equal "$(ip_value network 192.0.2.5/24 4)" 192.0.2.0/24
check 'IPv6 CIDR normalization' equal "$(ip_value network 2001:db8::5/64 6)" 2001:db8::/64
check 'wrong source family' reject ip_value network 2001:db8::/64 4
check 'CIDR injection' reject ip_value network '0.0.0.0/0; allow all;' 4
check 'invalid CIDR prefix' reject ip_value interface 10.0.0.1/999 4
check 'standard NAT64' equal "$(nat64_addr_from_prefix 64:ff9b::/96 192.0.2.1)" 64:ff9b::c000:201
check 'expanded NAT64 prefix' equal "$(nat64_addr_from_prefix 2001:db8:0:1:0:0::/96 192.0.2.1)" 2001:db8:0:1::c000:201
check 'reject unsupported NAT64 prefix length' reject nat64_addr_from_prefix 64:ff9b::/64 192.0.2.1
check 'reject nonzero NAT64 host bits' reject nat64_addr_from_prefix 64:ff9b::1/96 192.0.2.1
check 'hostname endpoint' equal "$(ip_value endpoint vpn.example.com)" vpn.example.com
check 'endpoint newline injection' reject ip_value endpoint $'example.com\nPostUp=id'
check 'endpoint bad IPv4' reject ip_value endpoint 999.1.1.1
check 'menu invalid choice retries' equal "$(prompt_choice choose 1 '1 2' <<< $'invalid\n2')" 2
check 'empty menu selects default' equal "$(prompt_choice choose 2 '1 2' <<< '')" 2
check 'port EOF cancels' reject bash -c 'source ./iptables_Forward.sh; prompt_port port </dev/null'
check 'default EOF cancels' reject bash -c 'source ./iptables_Forward.sh; prompt_default value 1 </dev/null'
check 'menu EOF cancels' reject bash -c 'source ./iptables_Forward.sh; prompt_choice choose 1 "1 2" </dev/null'
check 'required EOF cancels' reject bash -c 'source ./iptables_Forward.sh; prompt_required value </dev/null'
check 'no secret-bearing ERR command dump' reject grep -q BASH_COMMAND iptables_Forward.sh

temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
cat > "$temp/legacy" <<'EOF'
*filter
:INPUT ACCEPT [0:0]
:A2B_INPUT - [0:0]
:A2B_OTHER - [0:0]
-A INPUT -j A2B_INPUT
-A A2B_INPUT -p tcp --dport 80 -j ACCEPT
-A INPUT -m comment --comment "text -j A2B_INPUT" -j ACCEPT
-A INPUT -j A2B_OTHER
COMMIT
EOF
migrate_legacy_rules "$temp/legacy"
check 'migration removes owned chain declaration' reject grep -q '^:A2B_INPUT ' "$temp/legacy"
check 'migration keeps unrelated A2B prefix' grep -q '^:A2B_OTHER ' "$temp/legacy"
check 'migration keeps a comment mentioning an owned jump' grep -q 'text -j A2B_INPUT' "$temp/legacy"

parse_target_input 6 '[2001:db8::1]:0080'
check 'IPv6 socket parse address' equal "$TARGET_IP" 2001:db8::1
check 'IPv6 socket parse port' equal "$TARGET_PORT" 0080
for spec in 'nat4 4 4 nat' 'nat6 6 6 nat' 'proxy46 4 6 proxy' 'proxy64 6 4 proxy'; do
    read -r mode listen target engine <<< "$spec"
    check "$mode listener" equal "$(mode_listen_family "$mode")" "$listen"
    check "$mode target" equal "$(mode_target_family "$mode")" "$target"
    check "$mode engine" equal "$(mode_engine "$mode")" "$engine"
done
printf 'Unit checks: %s passed\n' "$passed"
