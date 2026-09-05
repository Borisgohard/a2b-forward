#!/usr/bin/env bash
# 这些路径和生命周期替身仅供 network namespace 集成测试使用。
# 内核/Nginx/WireGuard 仍运行真实程序；真实 systemd 验证见 integration.sh 最后一段。
set -Eeuo pipefail
# shellcheck source=iptables_Forward.sh
source "$A2B_REPO/iptables_Forward.sh"
PROXY_DIR="$A2B_TEST_ROOT/$NODE/proxy"
PROXY_CONF_DIR="$PROXY_DIR/conf.d"
PROXY_CONF="$PROXY_DIR/nginx.conf"
PROXY_SERVICE="$A2B_TEST_ROOT/$NODE/proxy.service"
PROXY_LOG_DIR="$A2B_TEST_ROOT/$NODE/log"
PROXY_PID="$A2B_TEST_ROOT/$NODE/nginx.pid"
STATE_DIR="$A2B_TEST_ROOT/$NODE/state"
RULES_V4_FILE="$A2B_TEST_ROOT/$NODE/rules.v4"
RULES_V6_FILE="$A2B_TEST_ROOT/$NODE/rules.v6"
RULES_RESTORE_SERVICE="$A2B_TEST_ROOT/$NODE/rules.service"
INSTALLED_SCRIPT="$A2B_TEST_ROOT/$NODE/installed.sh"
SYSCTL_V4_FILE="$A2B_TEST_ROOT/$NODE/sysctl4"
SYSCTL_V6_FILE="$A2B_TEST_ROOT/$NODE/sysctl6"
SYSCTL_PERF_FILE="$A2B_TEST_ROOT/$NODE/performance"
WG_DIR="$A2B_TEST_ROOT/$NODE/wireguard"
WG_EXPORT_DIR="$A2B_TEST_ROOT/$NODE/exports"
mkdir -p "$A2B_TEST_ROOT/$NODE"

install_proxy_dependencies() { command -v nginx >/dev/null; }
install_wireguard_dependencies() { command -v wg >/dev/null; }
migrate_legacy_rules() { :; }

systemctl() {
    local action="$1" unit="${*: -1}" iface pid
    case "$action" in
        daemon-reload) return 0 ;;
        is-enabled) echo disabled; return 1 ;;
        is-active)
            if [[ "$unit" == a2b-forward-proxy.service && -f "$PROXY_PID" ]]; then
                read -r pid < "$PROXY_PID"
                if kill -0 "$pid" 2>/dev/null; then
                    [[ " $* " == *" --quiet "* ]] || echo active
                    return 0
                fi
            fi
            [[ " $* " == *" --quiet "* ]] || echo inactive
            return 1 ;;
        enable)
            if [[ " $* " == *" --now "* ]]; then
                if [[ "$unit" == wg-quick@* ]]; then
                    iface="${unit#wg-quick@}"
                    wg-quick up "$WG_DIR/${iface%.service}.conf"
                else
                    command nginx -c "$PROXY_CONF"
                fi
            fi ;;
        reload) command nginx -c "$PROXY_CONF" -s reload ;;
        restart)
            if [[ "$unit" == a2b-forward-proxy.service ]]; then
                command nginx -c "$PROXY_CONF" -s stop || true
                sleep 0.2
                command nginx -c "$PROXY_CONF"
            fi ;;
        stop|disable)
            if [[ "$unit" == a2b-forward-proxy.service && -f "$PROXY_PID" ]]; then
                command nginx -c "$PROXY_CONF" -s stop
            fi ;;
        *) printf 'Unsupported systemctl fixture action: %s\n' "$*" >&2; return 1 ;;
    esac
}
