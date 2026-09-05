#!/usr/bin/env bash
# Requires root on a disposable Linux test machine. No public test ports are opened.
set -Eeuo pipefail
export A2B_REPO
A2B_REPO="$(cd "$(dirname "$0")/.." && pwd)"
export A2B_TEST_ROOT
A2B_TEST_ROOT="$(mktemp -d /tmp/a2b-integration-XXXXXX)"
prefix="a2bt-$$"
passed=0
real_units=0

cleanup() {
    local node pid
    if (( real_units )); then
        systemctl disable --now a2b-forward-proxy.service a2b-forward-rules.service || true
        rm -f /etc/systemd/system/a2b-forward-{proxy,rules}.service
        rm -rf /etc/systemd/system/a2b-forward-{proxy,rules}.service.d
        rm -f /etc/iptables/a2b-rules.v4 /etc/iptables/a2b-rules.v6 /usr/local/lib/a2b-forward/iptables_Forward.sh
        systemctl daemon-reload
    fi
    for node in u c a b w only4 only6; do
        for pid in $(ip netns pids "$prefix-$node" 2>/dev/null); do
            kill "$pid" 2>/dev/null || true
        done
        ip netns del "$prefix-$node" 2>/dev/null || true
    done
    rm -rf -- "$A2B_TEST_ROOT"
}
trap cleanup EXIT
trap 'printf "FAIL integration line %s\n" "$LINENO" >&2' ERR

run() {
    local node="$1"
    shift
    # shellcheck disable=SC2016 # Variables are expanded by the namespace's child Bash.
    ip netns exec "$prefix-$node" env NODE="$node" bash -c 'source "$A2B_REPO/tests/namespace-lib.sh"; eval "$1"' bash "$*"
}
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$*"; }
get() { ip netns exec "$prefix-u" curl --noproxy '*' -fsS --max-time 5 "$@"; }
expect() { [[ "$1" == *"$2"* ]]; }
udp() {
    ip netns exec "$prefix-u" python3 - "$1" "$2" <<'PY'
import socket, sys
family = socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET
with socket.socket(family, socket.SOCK_DGRAM) as s:
    s.settimeout(3)
    for i in range(3):
        payload = f"packet-{i}".encode()
        s.sendto(payload, (sys.argv[1], int(sys.argv[2])))
        data, _ = s.recvfrom(1000)
        assert data == b"B:" + payload, data
PY
}
link() {
    local n1="$1" n2="$2" dev1="$3" dev2="$4" subnet="$5"
    ip link add "v${$}x" type veth peer name "v${$}y"
    ip link set "v${$}x" netns "$prefix-$n1"
    ip link set "v${$}y" netns "$prefix-$n2"
    ip -n "$prefix-$n1" link set "v${$}x" name "$dev1"
    ip -n "$prefix-$n2" link set "v${$}y" name "$dev2"
    ip -n "$prefix-$n1" addr add "10.203.$subnet.1/24" dev "$dev1"
    ip -n "$prefix-$n2" addr add "10.203.$subnet.2/24" dev "$dev2"
    ip -n "$prefix-$n1" -6 addr add "fd00:a2b:$subnet::1/64" dev "$dev1" nodad
    ip -n "$prefix-$n2" -6 addr add "fd00:a2b:$subnet::2/64" dev "$dev2" nodad
    ip -n "$prefix-$n1" link set "$dev1" up
    ip -n "$prefix-$n2" link set "$dev2" up
}

[[ "$EUID" == 0 ]] || { echo 'Run as root on an isolated Linux test machine.' >&2; exit 1; }
for node in u c a b w only4 only6; do
    ip netns add "$prefix-$node"
    ip -n "$prefix-$node" link set lo up
done
link c u cu uc 0
link c a ca ac 1
link a b ab ba 2
link b w bw wb 3
ip -n "$prefix-u" route add default via 10.203.0.1
ip -n "$prefix-u" -6 route add default via fd00:a2b:0::1
ip -n "$prefix-a" route add 10.203.0.0/24 via 10.203.1.1
ip -n "$prefix-a" -6 route add fd00:a2b:0::/64 via fd00:a2b:1::1
ip -n "$prefix-c" route add 10.203.2.0/24 via 10.203.1.2
ip -n "$prefix-c" -6 route add fd00:a2b:2::/64 via fd00:a2b:1::2
ip -n "$prefix-b" route add default via 10.203.2.1
ip -n "$prefix-b" -6 route add default via fd00:a2b:2::1
ip -n "$prefix-w" route add default via 10.203.3.1
for node in c a; do
    run "$node" 'sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1'
done
# shellcheck disable=SC2016 # Evaluate sysctl inside A, not on the host.
run a 'configure_sysctl 6; configure_sysctl 6; test "$(sysctl -n net.ipv6.conf.ac.accept_ra)" = 2; grep -q "net/ipv6/conf/ac/accept_ra=2" "$SYSCTL_V6_FILE"'
pass 'IPv6 forwarding retains RA reception across repeated configuration'
run a 'iptables -P FORWARD DROP; ip6tables -P FORWARD DROP; iptables -A INPUT -p tcp --dport 49999 -m comment --comment sentinel -j ACCEPT'

for host in 0.0.0.0 ::; do
    ip netns exec "$prefix-b" python3 "$A2B_REPO/tests/endpoint.py" "$host" 18081 B &
done
ip netns exec "$prefix-b" python3 "$A2B_REPO/tests/endpoint.py" 0.0.0.0 18082 UPDATED &
ip netns exec "$prefix-w" python3 "$A2B_REPO/tests/endpoint.py" 0.0.0.0 18083 WEBSITE &
sleep 0.3

map4='LISTEN_IF=ac; LISTEN_ADDR=10.203.1.2; LOCAL_PORT=18080; TARGET_IP=10.203.2.2; TARGET_PORT=18081; EGRESS_IF=ab; SNAT_SOURCE=10.203.2.1; ALLOWED_SOURCE=10.203.0.2/32'
map6='LISTEN_IF=ac; LISTEN_ADDR=fd00:a2b:1::2; LOCAL_PORT=18080; TARGET_IP=fd00:a2b:2::2; TARGET_PORT=18081; EGRESS_IF=ab; SNAT_SOURCE=fd00:a2b:2::1; ALLOWED_SOURCE=fd00:a2b:0::2/128'
run a "$map4; add_nat_rules 4 iptables 'tcp udp'"
run a "$map6; add_nat_rules 6 ip6tables 'tcp udp'"
expect "$(get http://10.203.1.2:18080)" '10.203.2.1'
expect "$(get 'http://[fd00:a2b:1::2]:18080')" 'fd00:a2b:2::1'
udp 10.203.1.2 18080
udp fd00:a2b:1::2 18080
pass 'NAT44/NAT66 TCP and multi-datagram UDP with return-path SNAT'

# 从主菜单走完新手路径，包含默认网卡选择、目标 socket 解析、探测和最终确认。
printf '%s\n' 1 1 y 1 1 3 1 18086 10.203.2.2:18081 '' '' '' '' 10.203.0.2/32 y |
    run a 'prepare_changes() { :; }; main_menu'
expect "$(get http://10.203.1.2:18086)" B
pass 'complete beginner menu to a working mapping using detected interface/address defaults'

if get --interface 10.203.0.1 http://10.203.1.2:18080 >/dev/null 2>&1; then exit 1; fi
ip -n "$prefix-u" addr add 10.203.0.3/24 dev uc
if get --interface 10.203.0.3 --max-time 1 http://10.203.1.2:18080 >/dev/null 2>&1; then exit 1; fi
pass 'unauthorized source cannot access NAT entry'

run a "$map4; add_nat_rules 4 iptables 'tcp udp'; save_rules; restore_saved_rules; restore_saved_rules"
[[ "$(run a "iptables -t nat -S A2B_PREROUTING | grep -c -- '--dport 18080'")" == 2 ]]
run a 'iptables -C INPUT -p tcp --dport 49999 -m comment --comment sentinel -j ACCEPT'
if grep -q sentinel "$A2B_TEST_ROOT/a/rules.v4"; then exit 1; fi
pass 'idempotent save/restore retains unrelated rules and avoids snapshotting them'

run a "$map4; remove_mapping_rules iptables 4 tcp; TARGET_PORT=18082; add_nat_rules 4 iptables tcp"
expect "$(get http://10.203.1.2:18080)" UPDATED
udp 10.203.1.2 18080
pass 'TCP mapping update replaces old target while preserving UDP'
run a "$map4; remove_mapping_rules iptables 4 tcp; add_nat_rules 4 iptables tcp"

run a "$map4; LOCAL_PORT=18084; TARGET_IP=fd00:a2b:2::2; apply_current_mapping proxy 4 6 'tcp udp'"
run a "$map6; LOCAL_PORT=18084; TARGET_IP=10.203.2.2; apply_current_mapping proxy 6 4 'tcp udp'"
sleep 0.3
expect "$(get http://10.203.1.2:18084)" B
expect "$(get 'http://[fd00:a2b:1::2]:18084')" B
udp 10.203.1.2 18084
udp fd00:a2b:1::2 18084
if get --interface 10.203.0.3 --max-time 1 http://10.203.1.2:18084 >/dev/null 2>&1; then exit 1; fi
pass 'Nginx46/Nginx64 TCP/UDP and source ACL with INPUT policy ACCEPT'

before="$(sha256sum "$A2B_TEST_ROOT/a/proxy/conf.d/4-6-tcp-10.203.1.2-18084.conf")"
if run a "$map4; LOCAL_PORT=18084; TARGET_IP=fd00:a2b:2::2; trap on_exit EXIT; nginx() { return 1; }; apply_current_mapping proxy 4 6 tcp"; then
    echo 'Injected nginx failure unexpectedly succeeded' >&2; exit 1
fi
[[ "$before" == "$(sha256sum "$A2B_TEST_ROOT/a/proxy/conf.d/4-6-tcp-10.203.1.2-18084.conf")" ]]
expect "$(get http://10.203.1.2:18084)" B
run a 'iptables -C INPUT -p tcp --dport 49999 -m comment --comment sentinel -j ACCEPT'
pass 'injected config failure rolls back files/firewall and restores working proxy'

run a "$map4; LOCAL_PORT=18084; preflight_mapping 4 tcp nat; apply_current_mapping nat 4 4 tcp"
expect "$(get http://10.203.1.2:18084)" 10.203.2.1
udp 10.203.1.2 18084
run a "$map4; LOCAL_PORT=18084; TARGET_IP=fd00:a2b:2::2; preflight_mapping 4 tcp proxy; apply_current_mapping proxy 4 6 tcp"
expect "$(get http://10.203.1.2:18084)" B
pass 'same-port Nginx -> NAT -> Nginx transitions keep unselected UDP working'

run c 'LISTEN_IF=cu; LISTEN_ADDR=10.203.0.1; LOCAL_PORT=18085; TARGET_IP=10.203.1.2; TARGET_PORT=18080; EGRESS_IF=ca; SNAT_SOURCE=10.203.1.1; ALLOWED_SOURCE=10.203.0.2/32; add_nat_rules 4 iptables tcp'
run a "$map4; remove_mapping_rules iptables 4 tcp; ALLOWED_SOURCE=10.203.1.1/32; add_nat_rules 4 iptables tcp"
expect "$(get http://10.203.0.1:18085)" B
pass 'client -> C -> A -> B two-hop NAT with upstream CIDR'

# 真实 B 代理与只能由 B 访问的独立网站；匿名认证仅存在于隔离命名空间。
{
    printf 'logoutput: stderr\ninternal: 0.0.0.0 port = 19080\ninternal: :: port = 19080\nexternal: bw\nuser.privileged: root\nuser.unprivileged: nobody\nsocksmethod: none\nclientmethod: none\n'
    for src in 0.0.0.0/0 ::/0; do
        for dst in 0.0.0.0/0 ::/0; do
            printf 'client pass { from: %s to: %s }\nsocks pass { from: %s to: %s command: connect }\n' "$src" "$dst" "$src" "$dst"
        done
    done
} > "$A2B_TEST_ROOT/danted.conf"
ip netns exec "$prefix-b" danted -f "$A2B_TEST_ROOT/danted.conf" > "$A2B_TEST_ROOT/danted.log" 2>&1 &
sleep 0.3
run a "$map4; LOCAL_PORT=19081; TARGET_PORT=19080; ALLOWED_SOURCE=10.203.1.1/32; add_nat_rules 4 iptables tcp"
run c 'LISTEN_IF=cu; LISTEN_ADDR=10.203.0.1; LOCAL_PORT=19082; TARGET_IP=10.203.1.2; TARGET_PORT=19081; EGRESS_IF=ca; SNAT_SOURCE=10.203.1.1; ALLOWED_SOURCE=10.203.0.2/32; add_nat_rules 4 iptables tcp'
result="$(ip netns exec "$prefix-u" curl --noproxy '' -fsS --max-time 5 --socks5-hostname 10.203.0.1:19082 http://10.203.3.2:18083)"
expect "$result" WEBSITE
expect "$result" 10.203.3.1
pass 'real SOCKS5 client -> C -> A -> B -> isolated website, observed egress is B'
run a "$map4; LOCAL_PORT=19083; TARGET_IP=fd00:a2b:2::2; TARGET_PORT=19080; apply_current_mapping proxy 4 6 tcp"
result="$(ip netns exec "$prefix-u" curl --noproxy '' -fsS --max-time 5 --socks5-hostname 10.203.1.2:19083 http://10.203.3.2:18083)"
expect "$result" 10.203.3.1
pass 'IPv4 entry -> IPv6 B SOCKS5 -> IPv4 website, exit remains B'

# 新手文档中的加密代理示例，同一份模板经检查后实跑，而非只验证 JSON。
if command -v sing-box >/dev/null 2>&1; then
    python3 - "$A2B_REPO/examples/sing-box-server.json" "$A2B_TEST_ROOT" <<'PY'
import base64, json, pathlib, secrets, sys
source, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
server = json.loads(source.read_text())
key = base64.b64encode(secrets.token_bytes(16)).decode()
server["inbounds"][0]["password"] = key
client = {
    "log": {"level": "warn"},
    "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": 19101}],
    "outbounds": [{"type": "shadowsocks", "tag": "encrypted", "server": "10.203.1.2",
                   "server_port": 19100, "method": "2022-blake3-aes-128-gcm", "password": key}],
    "route": {"final": "encrypted"},
}
for name, config in (("ss-server", server), ("ss-client", client)):
    path = root / (name + ".json")
    path.write_text(json.dumps(config))
    path.chmod(0o600)
PY
    sing-box check -c "$A2B_TEST_ROOT/ss-server.json"
    sing-box check -c "$A2B_TEST_ROOT/ss-client.json"
    ip netns exec "$prefix-b" sing-box run -c "$A2B_TEST_ROOT/ss-server.json" > "$A2B_TEST_ROOT/ss-server.log" 2>&1 &
    ip netns exec "$prefix-u" sing-box run -c "$A2B_TEST_ROOT/ss-client.json" > "$A2B_TEST_ROOT/ss-client.log" 2>&1 &
    run a "$map4; LOCAL_PORT=19100; TARGET_IP=fd00:a2b:2::2; TARGET_PORT=8833; apply_current_mapping proxy 4 6 tcp"
    result="$(ip netns exec "$prefix-u" curl --noproxy '' -fsS --max-time 5 --socks5-hostname 127.0.0.1:19101 http://10.203.3.2:18083)"
    expect "$result" 10.203.3.1
    pass 'beginner sing-box Shadowsocks 2022 example: encrypted traffic through A exits via B'
else
    echo 'SKIP encrypted beginner example (install the workflow-pinned sing-box binary)'
fi

# 直接运行交互式 WireGuard 配置生成器，再用真实 wg-quick 激活 B 导出配置。
run a 'create_wireguard_tunnel' <<'INPUT'
a2btest
51829





10.203.2.1
y
INPUT
mkdir -p "$A2B_TEST_ROOT/b/wireguard"
cp "$A2B_TEST_ROOT/a/exports/a2btest-B.conf" "$A2B_TEST_ROOT/b/wireguard/a2btest.conf"
ip netns exec "$prefix-b" wg-quick up "$A2B_TEST_ROOT/b/wireguard/a2btest.conf"
run a 'ping -c 1 -W 3 10.66.66.2'
run a 'ping -6 -c 1 -W 3 fd66:66:66::2'
[[ "$(stat -c %a "$A2B_TEST_ROOT/a/exports/a2btest-B.conf")" == 600 ]]
run a "$map4; LOCAL_PORT=19084; TARGET_IP=10.66.66.2; TARGET_PORT=19080; EGRESS_IF=a2btest; SNAT_SOURCE=10.66.66.1; add_nat_rules 4 iptables tcp"
result="$(ip netns exec "$prefix-u" curl --noproxy '' -fsS --max-time 5 --socks5-hostname 10.203.1.2:19084 http://10.203.3.2:18083)"
expect "$result" 10.203.3.1
pass 'generated WireGuard keys/configs establish IPv4+IPv6 tunnel and proxy exits via B'

run only4 '! get_route_line 6 fd00:a2b:2::2'
run only6 '! get_route_line 4 10.203.2.2'
pass 'missing target-family route is rejected instead of claiming automatic translation'

# 有限的同路径吞吐对照，输出供人工比较，不把 CI 的虚拟网卡速度当作公网承诺。
ip netns exec "$prefix-b" iperf3 -s -B 10.203.2.2 -p 19090 > "$A2B_TEST_ROOT/iperf.log" 2>&1 &
run a 'iptables -P FORWARD ACCEPT'
run a "$map4; LOCAL_PORT=19091; TARGET_PORT=19090; add_nat_rules 4 iptables tcp"
sleep 0.2
for parallel in 1 4; do
    for mode in direct nat; do
        host=10.203.2.2 port=19090
        [[ "$mode" != nat ]] || { host=10.203.1.2; port=19091; }
        ip netns exec "$prefix-u" iperf3 -c "$host" -p "$port" -t 2 -P "$parallel" -J > "$A2B_TEST_ROOT/$mode-$parallel.json"
        python3 - "$A2B_TEST_ROOT/$mode-$parallel.json" "$mode" "$parallel" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
bps = r["end"]["sum_received"]["bits_per_second"]
assert bps > 0
print(f"BENCH {sys.argv[2]} P={sys.argv[3]} {bps / 1e6:.1f} Mbps")
PY
    done
done
pass 'bounded single/parallel-stream forwarding throughput measurement'

# 在一次性 CI VM 中验证生成的真实 systemd 单元，网络仍限制在 A namespace。
if [[ "${CI:-}" == true && -d /run/systemd/system ]]; then
    [[ ! -e /etc/systemd/system/a2b-forward-rules.service && ! -e /etc/systemd/system/a2b-forward-proxy.service ]]
    real_units=1
    run a 'systemctl stop a2b-forward-proxy.service'
    mkdir -p /etc/iptables /usr/local/lib/a2b-forward
    cp "$A2B_TEST_ROOT/a/rules.v4" /etc/iptables/a2b-rules.v4
    cp "$A2B_TEST_ROOT/a/rules.v6" /etc/iptables/a2b-rules.v6
    # 恢复服务使用原脚本的正式路径；只以 drop-in 限定 namespace。
    bash -c 'source "$A2B_REPO/iptables_Forward.sh"; write_rules_restore_service'
    cp "$A2B_TEST_ROOT/a/proxy.service" /etc/systemd/system/a2b-forward-proxy.service
    for unit in rules proxy; do
        mkdir -p "/etc/systemd/system/a2b-forward-$unit.service.d"
        printf '[Service]\nNetworkNamespacePath=/run/netns/%s-a\n' "$prefix" > "/etc/systemd/system/a2b-forward-$unit.service.d/test.conf"
    done
    systemctl daemon-reload
    systemd-analyze verify /etc/systemd/system/a2b-forward-{rules,proxy}.service
    run a 'remove_managed_rules_for_cmd iptables; remove_managed_rules_for_cmd ip6tables'
    systemctl start a2b-forward-rules.service a2b-forward-proxy.service
    sleep 0.3
    expect "$(get http://10.203.1.2:18084)" B
    run a 'iptables -C INPUT -p tcp --dport 49999 -m comment --comment sentinel -j ACCEPT'
    old_pid="$(systemctl show -p MainPID --value a2b-forward-proxy.service)"
    systemctl kill --kill-who=main --signal=KILL a2b-forward-proxy.service
    for _ in {1..30}; do
        sleep 0.2
        new_pid="$(systemctl show -p MainPID --value a2b-forward-proxy.service)"
        if [[ "$new_pid" != 0 && "$new_pid" != "$old_pid" ]] && get http://10.203.1.2:18084 >/dev/null 2>&1; then break; fi
    done
    [[ "$new_pid" != 0 && "$new_pid" != "$old_pid" ]]
    expect "$(get http://10.203.1.2:18084)" B
    pass 'real systemd restores lost rules and restarts crashed Nginx with traffic recovery'
else
    echo 'SKIP real systemd unit lifecycle (requires disposable CI VM)'
fi
printf 'Integration groups: %s passed\n' "$passed"
