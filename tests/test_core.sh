#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../iptables_Forward.sh
source ./iptables_Forward.sh
passed=0
ok() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
reject() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "FAIL: accepted $label" >&2
        exit 1
    fi
    ok "$label"
}
validate_port 00080
[[ "$(prompt_port port <<< 00080)" == 80 ]]
ok decimal-port
for port in 0 65536 -1 1.5 '80;id' 999999999999999999999999; do
    reject "invalid-port:$port" validate_port "$port"
done
[[ "$(detect_ip_family '[2001:db8::1]')" == 6 ]]
[[ "$(detect_ip_family 192.0.2.1)" == 4 ]]
ok ip-families
for ip in 999.2.3.4 1.2.3 01.2.3.4 'not:an:ip' '2001:db8::1;id' 'fe80::1%eth0'; do
    reject "invalid-ip:$ip" detect_ip_family "$ip"
done
ip_value network 192.0.2.4/24 4
ip_value network 2001:db8::2/64 6
reject wrong-cidr-family ip_value network 2001:db8::/64 4
reject invalid-cidr-prefix ip_value network 192.0.2.0/33 4
reject config-injection ip_value network '192.0.2.0/24; deny all;' 4
validate_interface_name a2b0
for name in ../wg0 'wg 0' 1234567890123456 'wg0;id'; do
    reject "invalid-interface:$name" validate_interface_name "$name"
done
ip_value endpoint vpn.example.org
ip_value endpoint 2001:db8::1
reject endpoint-port ip_value endpoint vpn.example.org:51820
reject endpoint-injection ip_value endpoint $'vpn.example.org\nPostUp = id'
[[ "$(nat64_addr_from_prefix 64:ff9b::/96 192.0.2.1)" == 64:ff9b::c000:201 ]]
[[ "$(nat64_addr_from_prefix 2001:db8:1:2:3:4::/96 192.0.2.1)" == 2001:db8:1:2:3:4:c000:201 ]]
ok nat64-canonical
reject nat64-unsupported-prefix nat64_addr_from_prefix 64:ff9b::/64 192.0.2.1
reject nat64-host-bits nat64_addr_from_prefix 64:ff9b::1/96 192.0.2.1
reject eof-required bash -c 'source ./iptables_Forward.sh; prompt_required value' </dev/null
reject eof-default bash -c 'source ./iptables_Forward.sh; prompt_default value default' </dev/null
reject eof-port bash -c 'source ./iptables_Forward.sh; prompt_port value 80' </dev/null
parse_target_input 6 '[2001:db8::2]:443'
[[ "$TARGET_IP" == 2001:db8::2 && "$TARGET_PORT" == 443 ]]
ok ipv6-target-with-port
install_base_dependencies() { echo 'unexpected installation' >&2; exit 1; }
show_managed_rules() { echo 'read-only view'; }
main_menu <<< 2
main_menu <<< 0
ok read-only-menu-and-exit
backup_rules() { echo 'unexpected change after cancellation' >&2; exit 1; }
remove_managed_rules <<< n
ok delete-cancellation
printf '%s core checks passed.\n' "$passed"
