#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if [[ "${A2B_TEST_ISOLATED:-}" != yes ]]; then
    available_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    if (( available_kb < 262144 )); then
        echo 'Integration tests need at least 256 MiB available RAM; use CI or a test VM.' >&2
        exit 1
    fi
    exec unshare -n -- env A2B_TEST_ISOLATED=yes bash tests/integration.sh
fi
[[ "$EUID" == 0 && -z "$(ip route show default)" ]]
[[ "$(ip -o link show | wc -l)" == 1 ]] || { echo 'Expected a fresh network namespace'; exit 1; }
# shellcheck source=../iptables_Forward.sh
source ./iptables_Forward.sh
root="$(pwd)"
scratch="$(mktemp -d)"
pids=()
cleanup() {
    local code=$?
    trap - EXIT
    if [[ -s "$scratch/nginx.pid" ]]; then nginx -c "$scratch/proxy/nginx.conf" -s stop || true; fi
    for child in "${pids[@]}"; do kill "$child" 2>/dev/null || true; done
    wait || true
    rm -rf "$scratch"
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
unshare -n -- sleep 300 & cp_pid=$!; pids+=("$cp_pid")
unshare -n -- sleep 300 & bp_pid=$!; pids+=("$bp_pid")
sleep 0.1
ip link set lo up
ip link add a-in type veth peer name c-in
ip link add a-out type veth peer name b-in
ip link set c-in netns "$cp_pid"
ip link set b-in netns "$bp_pid"
ip addr add 192.0.2.1/24 dev a-in
ip addr add 198.51.100.1/24 dev a-out
ip -6 addr add 2001:db8:1::1/64 dev a-in nodad
ip -6 addr add 2001:db8:2::1/64 dev a-out nodad
ip link set a-in up
ip link set a-out up
for spec in "$cp_pid c-in 192.0.2.2 2001:db8:1::2 192.0.2.1 2001:db8:1::1" "$bp_pid b-in 198.51.100.2 2001:db8:2::2 198.51.100.1 2001:db8:2::1"; do
    read -r pid iface v4 v6 gw4 gw6 <<< "$spec"
    nsenter -t "$pid" -n ip link set lo up
    nsenter -t "$pid" -n ip addr add "$v4/24" dev "$iface"
    nsenter -t "$pid" -n ip -6 addr add "$v6/64" dev "$iface" nodad
    nsenter -t "$pid" -n ip link set "$iface" up
    nsenter -t "$pid" -n ip route add default via "$gw4"
    nsenter -t "$pid" -n ip -6 route add default via "$gw6"
done
SYSCTL_V4_FILE="$scratch/ipv4.conf"
SYSCTL_V6_FILE="$scratch/ipv6.conf"
configure_sysctl 4
configure_sysctl 6
[[ "$(sysctl -n net.ipv6.conf.a-in.accept_ra)" == 2 ]]
echo 'PASS IPv6 accept_ra preserved when enabling forwarding'
for cmd in iptables ip6tables; do
    "$cmd" -P FORWARD DROP
    "$cmd" -N FOREIGN
    "$cmd" -A FOREIGN -m comment --comment unrelated-owner -j RETURN
    "$cmd" -A OUTPUT -j FOREIGN
done
for host in 198.51.100.2 2001:db8:2::2; do
    nsenter -t "$bp_pid" -n python3 "$root/tests/echo_peer.py" serve "$host" 18080 old & pids+=("$!")
    nsenter -t "$bp_pid" -n python3 "$root/tests/echo_peer.py" serve "$host" 18081 new & pids+=("$!")
done
sleep 0.3
LISTEN_IF=a-in EGRESS_IF=a-out LOCAL_PORT=26385 LISTEN_ADDR='' ALLOWED_SOURCE=''
TARGET_IP=198.51.100.2 TARGET_PORT=18080 SNAT_SOURCE=198.51.100.1
add_nat_rules 4 iptables 'tcp udp'
request() { nsenter -t "$cp_pid" -n python3 "$root/tests/echo_peer.py" "$@"; }
request tcp 192.0.2.1 26385 old
request udp 192.0.2.1 26385 old
echo 'PASS IPv4 TCP/UDP NAT end to end'
TARGET_PORT=18081
add_nat_rules 4 iptables 'tcp udp'
request tcp 192.0.2.1 26385 new
request udp 192.0.2.1 26385 new
! iptables-save | grep -- '26385->198.51.100.2:18080'
echo 'PASS existing port update replaces old target'
TARGET_IP=2001:db8:2::2 TARGET_PORT=18080 SNAT_SOURCE=2001:db8:2::1
add_nat_rules 6 ip6tables 'tcp udp'
request tcp 2001:db8:1::1 26385 old
request udp 2001:db8:1::1 26385 old
echo 'PASS IPv6 TCP/UDP NAT end to end'
RULES_V4_FILE="$scratch/rules.v4" RULES_V6_FILE="$scratch/rules.v6"
export_managed_rules iptables > "$RULES_V4_FILE"
export_managed_rules ip6tables > "$RULES_V6_FILE"
! grep -q FOREIGN "$RULES_V4_FILE"
restore_managed_rules
restore_managed_rules
for cmd in iptables ip6tables; do
    "$cmd" -C OUTPUT -j FOREIGN
    "$cmd" -C FOREIGN -m comment --comment unrelated-owner -j RETURN
    "$cmd" -S FORWARD | grep -q -- '-P FORWARD DROP'
    [[ "$("$cmd" -S FORWARD | grep -c -- '-j A2B_FORWARD')" == 1 ]]
done
request tcp 192.0.2.1 26385 new
request udp 2001:db8:1::1 26385 old
echo 'PASS selective restore preserves unrelated chains, DROP policy and single jumps'
TARGET_IP=198.51.100.2 TARGET_PORT=18081 SNAT_SOURCE=198.51.100.1 ALLOWED_SOURCE=192.0.2.3/32
add_nat_rules 4 iptables tcp
if request tcp 192.0.2.1 26385 new 2>/dev/null; then echo 'ACL failed'; exit 1; fi
ALLOWED_SOURCE=192.0.2.2/32
add_nat_rules 4 iptables tcp
request tcp 192.0.2.1 26385 new
echo 'PASS source CIDR enforcement and update'
export_managed_rules iptables > "$scratch/pre-invalid"
SNAT_SOURCE=invalid
if (add_nat_rules 4 iptables tcp) 2>/dev/null; then echo 'Invalid NAT accepted'; exit 1; fi
export_managed_rules iptables > "$scratch/post-invalid"
cmp "$scratch/pre-invalid" "$scratch/post-invalid"
echo 'PASS invalid candidate leaves old NAT rules intact'
if ! command -v nginx >/dev/null; then echo 'NGINX REQUIRED for complete integration suite'; exit 1; fi
PROXY_DIR="$scratch/proxy" PROXY_CONF_DIR="$scratch/proxy/conf.d" PROXY_CONF="$scratch/proxy/nginx.conf"
PROXY_SERVICE="$scratch/proxy.service" PROXY_LOG_DIR="$scratch/log" PROXY_PID="$scratch/nginx.pid"
NGINX_STREAM_MODULE="${A2B_TEST_NGINX_MODULE:-$NGINX_STREAM_MODULE}"
NGINX_WORKERS=1
systemctl() {
    case "$1" in
        daemon-reload) return 0 ;;
        is-active) [[ -s "$PROXY_PID" ]] && kill -0 "$(cat "$PROXY_PID")" 2>/dev/null ;;
        enable) if [[ "${2:-}" == --now ]]; then nginx -c "$PROXY_CONF"; fi ;;
        reload) [[ "${FAIL_RELOAD:-0}" == 0 ]] && nginx -c "$PROXY_CONF" -s reload ;;
        disable) return 0 ;;
        *) echo "Unexpected service command: $*" >&2; return 1 ;;
    esac
}
LOCAL_PORT=26446 LISTEN_ADDR=192.0.2.1 ALLOWED_SOURCE=192.0.2.2/32 TARGET_IP=2001:db8:2::2 TARGET_PORT=18080
write_proxy_mapping 4 6 'tcp udp'
sleep 0.2
request tcp 192.0.2.1 26446 old
request udp 192.0.2.1 26446 old
echo 'PASS real Nginx IPv4-to-IPv6 TCP/UDP'
LOCAL_PORT=26464 LISTEN_ADDR=2001:db8:1::1 ALLOWED_SOURCE=2001:db8:1::2/128 TARGET_IP=198.51.100.2
write_proxy_mapping 6 4 'tcp udp'
sleep 0.3
request tcp 2001:db8:1::1 26464 old
request udp 2001:db8:1::1 26464 old
echo 'PASS real Nginx IPv6-to-IPv4 TCP/UDP'
cp "$PROXY_CONF_DIR/6-4-tcp-2001_db8_1__1-26464.conf" "$scratch/proxy-before"
FAIL_RELOAD=1 TARGET_PORT=18081
if (write_proxy_mapping 6 4 tcp); then echo 'Reload failure was ignored'; exit 1; fi
cmp "$PROXY_CONF_DIR/6-4-tcp-2001_db8_1__1-26464.conf" "$scratch/proxy-before"
request tcp 2001:db8:1::1 26464 old
echo 'PASS failed Nginx reload restores files and preserves running service'
FAIL_RELOAD=0 TARGET_PORT=18081
write_proxy_mapping 6 4 tcp
sleep 0.3
request tcp 2001:db8:1::1 26464 new
echo 'PASS successful Nginx update reaches new target'
LOCAL_PORT=26446
if (check_listener_conflicts nat 4 tcp); then echo 'NAT would hijack a listener'; exit 1; fi
echo 'PASS existing service port protected'
echo 'ALL NETWORK INTEGRATION CHECKS PASSED'
