#!/usr/bin/env bash
# A -> B port forwarding helper.
# Run this script on machine A.

set -Eeuo pipefail

trap 'echo "错误: 第 ${LINENO} 行执行失败；请查看本次审计日志。" >&2' ERR
umask 077

TAG="a2b-forward"
CHAIN_PRE="A2B_PREROUTING"
CHAIN_POST="A2B_POSTROUTING"
CHAIN_FWD="A2B_FORWARD"
CHAIN_INPUT="A2B_INPUT"
SYSCTL_V4_FILE="/etc/sysctl.d/99-a2b-forward-ipv4.conf"
SYSCTL_V6_FILE="/etc/sysctl.d/99-a2b-forward-ipv6.conf"
SYSCTL_PERF_FILE="/etc/sysctl.d/99-a2b-forward-performance.conf"
PROXY_DIR="/etc/a2b-forward"
PROXY_CONF_DIR="${PROXY_DIR}/conf.d"
PROXY_CONF="${PROXY_DIR}/nginx.conf"
PROXY_SERVICE="/etc/systemd/system/a2b-forward-proxy.service"
PROXY_LOG_DIR="/var/log/a2b-forward"
PROXY_PID="/run/a2b-forward-nginx.pid"
NGINX_STREAM_MODULE="/usr/lib/nginx/modules/ngx_stream_module.so"
NGINX_WORKERS=auto
WG_DIR="/etc/wireguard"
WG_EXPORT_DIR="/root/a2b-forward-wireguard"
RULES_V4_FILE="/etc/iptables/a2b-rules.v4"
RULES_V6_FILE="/etc/iptables/a2b-rules.v6"
RULES_RESTORE_SERVICE="/etc/systemd/system/a2b-forward-rules.service"
INSTALLED_SCRIPT="/usr/local/lib/a2b-forward/iptables_Forward.sh"
ENTRY_NODE_LABEL="A"
TARGET_NODE_LABEL="B"

die() {
    echo "错误: $*" >&2
    exit 1
}

info() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请在 A 机器上使用 root 运行，例如: sudo bash $0"
    fi
}

install_base_dependencies() {
    local missing=0

    local cmd
    for cmd in ip iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore python3 flock; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing=1
        fi
    done

    if (( missing == 0 )); then
        info "基础依赖已就绪: iproute2, iptables"
        return
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        die "缺少必要命令，且当前系统没有 apt-get。请手动安装 iproute2 和 iptables。"
    fi

    info "正在安装基础依赖: iproute2 iptables"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-remove iproute2 iptables python3 util-linux
}

validate_network_value() {
    python3 - "$@" <<'PY'
import ipaddress
import re
import sys

kind, value, *extra = sys.argv[1:]
try:
    if kind == "ip":
        address = ipaddress.ip_address(value)
        if "%" in value:
            raise ValueError("不接受带作用域的地址")
        print(address.version)
    elif kind == "cidr":
        address = ipaddress.ip_interface(value)
        if address.version != int(extra[0]) or "%" in value:
            raise ValueError("CIDR 协议族不匹配")
    elif kind == "interface":
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}", value):
            raise ValueError("接口名应为 1-15 个字母、数字、下划线、点或短横线")
    elif kind == "endpoint":
        try:
            ipaddress.ip_address(value)
        except ValueError:
            if len(value) > 253 or not all(re.fullmatch(
                r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", part
            ) for part in value.rstrip(".").split(".")):
                raise ValueError("Endpoint 应为 IP 或域名，不含端口或配置指令")
        if "%" in value:
            raise ValueError("不接受带作用域的地址")
    elif kind == "nat64":
        network = ipaddress.IPv6Network(value, strict=True)
        if network.prefixlen != 96:
            raise ValueError("当前仅支持 /96 NAT64 前缀")
        print(ipaddress.IPv6Address(int(network.network_address) |
                                   int(ipaddress.IPv4Address(extra[0]))))
    else:
        raise ValueError("未知校验类型")
except ValueError as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)
PY
}

install_proxy_dependencies() {
    if command -v nginx >/dev/null 2>&1; then
        if [[ ! -f "$NGINX_STREAM_MODULE" ]] && command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y libnginx-mod-stream || warn "libnginx-mod-stream 安装失败；如果 nginx 已内置 stream 模块，可忽略。"
        fi
        info "Nginx 已安装，将使用独立 stream 配置做跨 IPv4/IPv6 代理。"
        return
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        die "跨 IPv4/IPv6 代理需要 Nginx stream。当前系统没有 apt-get，请手动安装 nginx 和 stream 模块。"
    fi

    info "正在安装跨协议族代理依赖: nginx libnginx-mod-stream"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y nginx
    apt-get install -y libnginx-mod-stream || warn "libnginx-mod-stream 安装失败；如果 nginx 已内置 stream 模块，可忽略。"
}

install_wireguard_dependencies() {
    if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; then
        info "WireGuard 依赖已就绪: wg, wg-quick"
        return
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        die "WireGuard 模式需要 wg 和 wg-quick。当前系统没有 apt-get，请手动安装 wireguard-tools。"
    fi

    info "正在安装 WireGuard 依赖: wireguard-tools"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard-tools
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
}

prompt_port() {
    local prompt="$1"
    local default="${2:-}"
    local value

    while true; do
        if [[ -n "$default" ]]; then
            read -r -p "$prompt [$default]: " value || die "输入结束，已取消。"
            value="${value:-$default}"
        else
            read -r -p "$prompt: " value || die "输入结束，已取消。"
        fi

        if validate_port "$value"; then
            echo "$((10#$value))"
            return
        fi

        echo "端口必须是 1-65535 之间的数字。" >&2
    done
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local value

    read -r -p "$prompt [$default]: " value || die "输入结束，已取消。"
    echo "${value:-$default}"
}

normalize_ip() {
    local ip="$1"
    ip="${ip#\[}"
    ip="${ip%\]}"
    echo "$ip"
}

detect_ip_family() {
    local ip

    ip="$(normalize_ip "$1")"
    validate_network_value ip "$ip"
}

nat64_addr_from_prefix() {
    validate_network_value nat64 "$1" "$2"
}

strip_cidr() {
    local value="$1"
    value="${value%%/*}"
    echo "$value"
}

cidr_prefix() {
    local value="$1"
    local default_prefix="$2"

    if [[ "$value" == */* ]]; then
        echo "${value##*/}"
    else
        echo "$default_prefix"
    fi
}

endpoint_host_for_wg() {
    local host

    host="$(normalize_ip "$1")"
    if [[ "$host" == *:* ]]; then
        echo "[${host}]"
    else
        echo "$host"
    fi
}

confirm_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local answer

    read -r -p "$prompt [$default]: " answer || die "输入结束，已取消。"
    answer="${answer:-$default}"

    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        n|N|no|NO) return 1 ;;
        *) die "无效选择: $answer" ;;
    esac
}

get_default_interface() {
    local family="$1"
    ip "-$family" route show default 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }'
}

get_first_up_interface() {
    ip -o link show up | awk -F': ' '$2 != "lo" {print $2; exit}'
}

get_route_line() {
    local family="$1"
    local target_ip="$2"

    ip "-$family" route get "$target_ip" 2>/dev/null
}

get_iface_address() {
    local family="$1"
    local iface="$2"

    ip "-$family" -o addr show dev "$iface" scope global 2>/dev/null | awk '
        {
            split($4, addr, "/")
            print addr[1]
            exit
        }'
}

backup_rules() {
    local backup_dir
    backup_dir="$(mktemp -d "/root/${TAG}-backup-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
    local file

    mkdir -p "$backup_dir"
    iptables-save > "${backup_dir}/rules.v4"
    ip6tables-save > "${backup_dir}/rules.v6"
    export_managed_rules iptables > "${backup_dir}/managed.v4"
    export_managed_rules ip6tables > "${backup_dir}/managed.v6"
    if [[ -d "$PROXY_DIR" ]]; then
        cp -a "$PROXY_DIR" "${backup_dir}/proxy-config"
    fi
    if [[ -d "$WG_EXPORT_DIR" ]]; then
        cp -a "$WG_EXPORT_DIR" "${backup_dir}/wireguard-export"
    fi
    for file in "$PROXY_SERVICE" "$RULES_RESTORE_SERVICE" "$SYSCTL_V4_FILE" "$SYSCTL_V6_FILE" "$SYSCTL_PERF_FILE"; do
        [[ ! -f "$file" ]] || cp -p "$file" "$backup_dir/"
    done
    if [[ -d "$WG_EXPORT_DIR" ]]; then
        for file in "$WG_EXPORT_DIR"/*-B.conf; do
            [[ -f "$file" ]] || continue
            file="${file##*/}"
            file="${WG_DIR}/${file%-B.conf}.conf"
            [[ ! -f "$file" ]] || cp -p "$file" "$backup_dir/"
        done
    fi
    info "已备份当前规则和代理配置到: $backup_dir"
}

write_sysctl_file() {
    local file="$1"
    shift

    mkdir -p "${file%/*}"
    {
        echo "# Managed by ${TAG}. Edit this file only if you know what you are changing."
        printf '%s\n' "$@"
    } > "$file"
}

apply_sysctl_file() {
    local file="$1"
    local key
    local value

    while IFS='=' read -r key value; do
        [[ -z "${key// }" || "$key" =~ ^[[:space:]]*# ]] && continue
        key="${key// /}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if ! sysctl -w "${key}=${value}" >/dev/null 2>&1; then
            warn "无法应用 sysctl: ${key}=${value}"
        fi
    done < "$file"
}

configure_sysctl() {
    local family="$1"

    if [[ "$family" == "4" ]]; then
        write_sysctl_file "$SYSCTL_V4_FILE" \
            "net.ipv4.ip_forward=1"
        apply_sysctl_file "$SYSCTL_V4_FILE"
        info "已开启 IPv4 转发；保留现有 rp_filter 策略。"
    else
        local path iface
        local settings=()
        # Preserve SLAAC/RA routes on interfaces that already accept advertisements.
        for path in /proc/sys/net/ipv6/conf/*/accept_ra; do
            [[ -r "$path" ]] || continue
            iface="${path%/accept_ra}"
            iface="${iface##*/}"
            [[ "$iface" != all && "$iface" != lo ]] || continue
            if [[ "$(cat "$path")" != 0 ]]; then
                settings+=("net/ipv6/conf/${iface}/accept_ra=2")
            fi
        done
        settings+=("net.ipv6.conf.all.forwarding=1")
        write_sysctl_file "$SYSCTL_V6_FILE" "${settings[@]}"
        apply_sysctl_file "$SYSCTL_V6_FILE"
        info "已开启 IPv6 转发。"
    fi
}

configure_performance_tuning() {
    local settings=()
    local current
    local target

    modprobe nf_conntrack >/dev/null 2>&1 || true

    if [[ -r /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        current="$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
        target="$current"
        if [[ "$target" =~ ^[0-9]+$ ]] && (( target < 262144 )); then
            target=262144
        fi
        settings+=("net.netfilter.nf_conntrack_max=${target}")
    fi

    if [[ -r /proc/sys/net/core/somaxconn ]] && (( $(cat /proc/sys/net/core/somaxconn) < 65535 )); then
        settings+=("net.core.somaxconn=65535")
    fi

    if (( ${#settings[@]} == 0 )); then
        warn "未找到可优化的内核参数，跳过性能优化。"
        return
    fi

    write_sysctl_file "$SYSCTL_PERF_FILE" "${settings[@]}"
    apply_sysctl_file "$SYSCTL_PERF_FILE"
    info "已写入转发/代理性能参数: $SYSCTL_PERF_FILE"
}

ensure_chain() {
    local cmd="$1"

    "$cmd" -w -t nat -N "$CHAIN_PRE" 2>/dev/null || true
    "$cmd" -w -t nat -N "$CHAIN_POST" 2>/dev/null || true
    "$cmd" -w -N "$CHAIN_FWD" 2>/dev/null || true

    if ! "$cmd" -w -t nat -C PREROUTING -j "$CHAIN_PRE" 2>/dev/null; then
        "$cmd" -w -t nat -I PREROUTING 1 -j "$CHAIN_PRE"
    fi

    if ! "$cmd" -w -t nat -C POSTROUTING -j "$CHAIN_POST" 2>/dev/null; then
        "$cmd" -w -t nat -I POSTROUTING 1 -j "$CHAIN_POST"
    fi

    if ! "$cmd" -w -C FORWARD -j "$CHAIN_FWD" 2>/dev/null; then
        "$cmd" -w -I FORWARD 1 -j "$CHAIN_FWD"
    fi
}

ensure_input_chain() {
    local cmd="$1"

    "$cmd" -w -N "$CHAIN_INPUT" 2>/dev/null || true

    if ! "$cmd" -w -C INPUT -j "$CHAIN_INPUT" 2>/dev/null; then
        "$cmd" -w -I INPUT 1 -j "$CHAIN_INPUT"
    fi
}

ensure_rule_append() {
    local cmd="$1"
    local table="$2"
    local chain="$3"
    shift 3

    if [[ -n "${RULE_STAGE:-}" ]]; then
        python3 - "$RULE_STAGE" "$table" "$chain" "$@" <<'PY'
import json
import sys
path, table, chain, *args = sys.argv[1:]
with open(path, "a", encoding="utf-8") as out:
    out.write(table + "\t-A " + chain + " " + " ".join(json.dumps(x) for x in args) + "\n")
PY
        return
    fi

    if [[ "$table" == "filter" ]]; then
        if ! "$cmd" -w -C "$chain" "$@" 2>/dev/null; then
            "$cmd" -w -A "$chain" "$@"
        fi
    else
        if ! "$cmd" -w -t "$table" -C "$chain" "$@" 2>/dev/null; then
            "$cmd" -w -t "$table" -A "$chain" "$@"
        fi
    fi
}

remove_managed_rules_for_cmd() {
    local cmd="$1"

    while "$cmd" -w -t nat -D PREROUTING -j "$CHAIN_PRE" 2>/dev/null; do :; done
    while "$cmd" -w -t nat -D POSTROUTING -j "$CHAIN_POST" 2>/dev/null; do :; done
    while "$cmd" -w -D FORWARD -j "$CHAIN_FWD" 2>/dev/null; do :; done
    while "$cmd" -w -D INPUT -j "$CHAIN_INPUT" 2>/dev/null; do :; done

    "$cmd" -w -t nat -F "$CHAIN_PRE" 2>/dev/null || true
    "$cmd" -w -t nat -F "$CHAIN_POST" 2>/dev/null || true
    "$cmd" -w -F "$CHAIN_FWD" 2>/dev/null || true
    "$cmd" -w -F "$CHAIN_INPUT" 2>/dev/null || true

    "$cmd" -w -t nat -X "$CHAIN_PRE" 2>/dev/null || true
    "$cmd" -w -t nat -X "$CHAIN_POST" 2>/dev/null || true
    "$cmd" -w -X "$CHAIN_FWD" 2>/dev/null || true
    "$cmd" -w -X "$CHAIN_INPUT" 2>/dev/null || true
}

allow_wireguard_input() {
    local port="$1"

    ensure_input_chain iptables
    ensure_input_chain ip6tables
    ensure_rule_append iptables filter "$CHAIN_INPUT" -p udp --dport "$port" -m comment --comment "${TAG} wireguard listen ${port}" -j ACCEPT
    ensure_rule_append ip6tables filter "$CHAIN_INPUT" -p udp --dport "$port" -m comment --comment "${TAG} wireguard listen ${port}" -j ACCEPT
}

allow_proxy_input() {
    local listen_family="$1"
    local protocols="$2"
    local cmd="iptables"
    local proto
    local args

    [[ "$listen_family" == "6" ]] && cmd="ip6tables"
    ensure_input_chain "$cmd"

    for proto in $protocols; do
        args=(-i "$LISTEN_IF")
        [[ -n "$ALLOWED_SOURCE" ]] && args+=(-s "$ALLOWED_SOURCE")
        [[ -n "$LISTEN_ADDR" ]] && args+=(-d "$LISTEN_ADDR")
        args+=(-p "$proto" --dport "$LOCAL_PORT" -m comment --comment "${TAG} proxy listen ${proto} ${LOCAL_PORT}" -j ACCEPT)
        ensure_rule_append "$cmd" filter "$CHAIN_INPUT" "${args[@]}"
    done
}

write_rules_restore_service() {
    local service_name

    if ! command -v systemctl >/dev/null 2>&1; then
        warn "当前系统没有 systemctl，已保存规则文件，但无法创建开机自动恢复服务。"
        return
    fi

    service_name="$(basename "$RULES_RESTORE_SERVICE")"
    mkdir -p "${INSTALLED_SCRIPT%/*}"
    if [[ "$(readlink -f "${BASH_SOURCE[0]}")" != "$INSTALLED_SCRIPT" ]]; then
        install -m 700 "${BASH_SOURCE[0]}" "$INSTALLED_SCRIPT"
    fi
    cat > "$RULES_RESTORE_SERVICE" <<EOF
[Unit]
Description=A2B forwarding firewall rules restore
After=network-online.target ufw.service netfilter-persistent.service docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${INSTALLED_SCRIPT} --restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$service_name" >/dev/null 2>&1 || warn "无法启用 ${service_name}，请手动检查 systemd 状态。"
}

export_managed_rules() {
    "$1-save" | awk '
        /^\*/ { table=$0; next }
        /^-A A2B_(PREROUTING|POSTROUTING|FORWARD|INPUT) / { rules[table]=rules[table] $0 "\n" }
        END {
            print "*nat\n:A2B_PREROUTING - [0:0]\n:A2B_POSTROUTING - [0:0]"
            printf "%s", rules["*nat"]
            print "COMMIT\n*filter\n:A2B_FORWARD - [0:0]\n:A2B_INPUT - [0:0]"
            printf "%s", rules["*filter"]
            print "COMMIT"
        }'
}

restore_managed_rules() {
    local cmd file
    for cmd in iptables ip6tables; do
        file="$RULES_V4_FILE"
        [[ "$cmd" != ip6tables ]] || file="$RULES_V6_FILE"
        [[ -s "$file" ]] || continue
        "$cmd-restore" --wait 10 --noflush --test < "$file"
        "$cmd-restore" --wait 10 --noflush < "$file"
        ensure_chain "$cmd"
        ensure_input_chain "$cmd"
    done
}

clean_legacy_persistence() {
    local file
    for file in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
        [[ -f "$file" ]] || continue
        if grep -qE '^:A2B_(PREROUTING|POSTROUTING|FORWARD|INPUT) ' "$file"; then
            cp -p "$file" "${file}.before-a2b-$(date +%Y%m%d-%H%M%S).bak"
            awk '
                /^:A2B_(PREROUTING|POSTROUTING|FORWARD|INPUT) / { next }
                /^-A A2B_(PREROUTING|POSTROUTING|FORWARD|INPUT) / { next }
                / -j A2B_(PREROUTING|POSTROUTING|FORWARD|INPUT)$/ { next }
                { print }
            ' "$file" > "${file}.tmp"
            mv "${file}.tmp" "$file"
            info "已从旧持久化文件迁出 A2B 链，保留其它规则: $file"
        fi
    done
}

save_rules() {
    mkdir -p "${RULES_V4_FILE%/*}"
    export_managed_rules iptables > "${RULES_V4_FILE}.tmp"
    export_managed_rules ip6tables > "${RULES_V6_FILE}.tmp"
    mv "${RULES_V4_FILE}.tmp" "$RULES_V4_FILE"
    mv "${RULES_V6_FILE}.tmp" "$RULES_V6_FILE"
    clean_legacy_persistence
    write_rules_restore_service
    info "仅 A2B 链已保存；开机恢复使用 --noflush，保留其它防火墙规则和默认策略。"
}

show_chain() {
    local cmd="$1"
    local table="$2"
    local chain="$3"

    if [[ "$table" == "filter" ]]; then
        "$cmd" -S "$chain" 2>/dev/null || echo "(no ${cmd} ${chain})"
    else
        "$cmd" -t "$table" -S "$chain" 2>/dev/null || echo "(no ${cmd} ${table}/${chain})"
    fi
}

show_managed_rules() {
    echo "== IPv4 NAT managed rules =="
    show_chain iptables filter "$CHAIN_INPUT"
    show_chain iptables nat "$CHAIN_PRE"
    show_chain iptables nat "$CHAIN_POST"
    show_chain iptables filter "$CHAIN_FWD"

    echo
    echo "== IPv6 NAT managed rules =="
    show_chain ip6tables filter "$CHAIN_INPUT"
    show_chain ip6tables nat "$CHAIN_PRE"
    show_chain ip6tables nat "$CHAIN_POST"
    show_chain ip6tables filter "$CHAIN_FWD"

    echo
    echo "== Cross-family proxy managed configs =="
    if [[ -d "$PROXY_CONF_DIR" ]] && compgen -G "${PROXY_CONF_DIR}/*.conf" >/dev/null; then
        for file in "${PROXY_CONF_DIR}"/*.conf; do
            echo "--- $file"
            sed 's/^/    /' "$file"
        done
    else
        echo "(no proxy config)"
    fi

    if command -v systemctl >/dev/null 2>&1 && [[ -f "$PROXY_SERVICE" ]]; then
        echo
        echo "Proxy service: $(systemctl is-active a2b-forward-proxy.service 2>/dev/null || true)"
    fi

    if command -v systemctl >/dev/null 2>&1 && [[ -f "$RULES_RESTORE_SERVICE" ]]; then
        echo
        echo "Firewall restore service: $(systemctl is-enabled a2b-forward-rules.service 2>/dev/null || true) / $(systemctl is-active a2b-forward-rules.service 2>/dev/null || true)"
    fi

    echo
    echo "== WireGuard configs generated by this script =="
    if [[ -d "$WG_EXPORT_DIR" ]] && compgen -G "${WG_EXPORT_DIR}/*-B.conf" >/dev/null; then
        for file in "${WG_EXPORT_DIR}"/*-B.conf; do
            echo "--- B config: $file"
        done
    else
        echo "(no WireGuard export config)"
    fi
}

choose_forwarding_mode() {
    local choice

    echo "请选择转发类型:" >&2
    echo "1. IPv4 -> IPv4  同协议族，使用 iptables 内核 NAT，性能最佳。" >&2
    echo "2. IPv6 -> IPv6  同协议族，使用 ip6tables 内核 NAT，性能最佳。" >&2
    echo "3. IPv6 -> IPv4  跨协议族，使用 Nginx stream L4 代理；A 必须能用 IPv4 连到 B。" >&2
    echo "4. IPv4 -> IPv6  跨协议族，使用 Nginx stream L4 代理；A 必须能用 IPv6 连到 B。" >&2
    echo "提示: 如果 A 真的是纯 IPv6 且完全没有 IPv4/464XLAT/隧道，它无法直接连接 IPv4-only 的 B；反向同理。" >&2
    read -r -p "请输入选项 [1]: " choice # 交互: 选择同协议族 NAT 或跨协议族代理方案。

    case "${choice:-1}" in
        1) echo "nat4" ;;
        2) echo "nat6" ;;
        3) echo "proxy64" ;;
        4) echo "proxy46" ;;
        *) die "无效选择: $choice" ;;
    esac
}

choose_protocols() {
    local choice

    echo "请选择端口协议:" >&2
    echo "1. tcp   适合 HTTP/HTTPS/SSH/大多数网站访问代理。" >&2
    echo "2. udp   适合 QUIC/游戏/特定 UDP 服务。" >&2
    echo "3. both  同一端口同时配置 TCP 和 UDP。" >&2
    read -r -p "请输入协议 [tcp]: " choice # 交互: 选择要转发的传输层协议。
    choice="${choice:-tcp}"

    case "$choice" in
        1|tcp|TCP) echo "tcp" ;;
        2|udp|UDP) echo "udp" ;;
        3|both|all|BOTH|ALL) echo "tcp udp" ;;
        *) die "无效协议: $choice" ;;
    esac
}

mode_listen_family() {
    case "$1" in
        nat4|proxy46) echo "4" ;;
        nat6|proxy64) echo "6" ;;
        *) die "未知模式: $1" ;;
    esac
}

mode_target_family() {
    case "$1" in
        nat4|proxy64) echo "4" ;;
        nat6|proxy46) echo "6" ;;
        *) die "未知模式: $1" ;;
    esac
}

mode_engine() {
    case "$1" in
        nat4|nat6) echo "nat" ;;
        proxy64|proxy46) echo "proxy" ;;
        *) die "未知模式: $1" ;;
    esac
}

parse_target_input() {
    local family="$1"
    local input="$2"

    TARGET_IP=""
    TARGET_PORT=""

    if [[ "$family" == "6" && "$input" =~ ^\[([0-9a-fA-F:.]+)\]:([0-9]+)$ ]]; then
        TARGET_IP="${BASH_REMATCH[1]}"
        TARGET_PORT="${BASH_REMATCH[2]}"
        return
    fi

    if [[ "$family" == "4" && "$input" =~ ^([0-9.]+):([0-9]+)$ ]]; then
        TARGET_IP="${BASH_REMATCH[1]}"
        TARGET_PORT="${BASH_REMATCH[2]}"
        return
    fi

    TARGET_IP="$(normalize_ip "$input")"
}

collect_common_config() {
    local listen_family="$1"
    local target_family="$2"
    local engine="$3"
    local target_input
    local default_listen_if
    local default_listen_addr
    local route_line
    local route_egress_if
    local route_source_ip

    LOCAL_PORT="$(prompt_port "${ENTRY_NODE_LABEL} 机器对外监听端口，也就是上一跳要连接的 ${ENTRY_NODE_LABEL} 端口")" # 交互: 设置当前入口机器暴露给上一跳访问的入口端口。

    if [[ -n "${PRESET_TARGET_IP:-}" && -n "${PRESET_TARGET_PORT:-}" ]]; then
        TARGET_IP="$(normalize_ip "$PRESET_TARGET_IP")"
        TARGET_PORT="$PRESET_TARGET_PORT"
        info "已使用向导确定的 ${TARGET_NODE_LABEL} 目标: ${TARGET_IP}:${TARGET_PORT}"
    else
        if [[ "$target_family" == "6" ]]; then
            read -r -p "${TARGET_NODE_LABEL} 机器目标地址，可填 IPv6 或 [IPv6]:端口: " target_input # 交互: 输入下一跳机器的 IPv6 目标地址，可顺带写端口。
        else
            read -r -p "${TARGET_NODE_LABEL} 机器目标地址，可填 IPv4 或 IPv4:端口: " target_input # 交互: 输入下一跳机器的 IPv4 目标地址，可顺带写端口。
        fi

        parse_target_input "$target_family" "$target_input"
    fi
    [[ -n "$TARGET_IP" ]] || die "目标 IP 不能为空。"
    if [[ "$(detect_ip_family "$TARGET_IP" 2>/dev/null || true)" != "$target_family" ]]; then
        die "目标地址 ${TARGET_IP} 不是 IPv${target_family} 地址，请重新选择转发类型或填写正确地址。"
    fi

    if [[ -n "$TARGET_PORT" ]]; then
        validate_port "$TARGET_PORT" || die "目标端口无效: $TARGET_PORT"
    else
        TARGET_PORT="$(prompt_port "${TARGET_NODE_LABEL} 机器目标服务端口，也就是本跳最终访问 ${TARGET_NODE_LABEL} 的端口")" # 交互: 设置本跳转发最终落到下一跳机器的端口。
    fi

    if ! route_line="$(get_route_line "$target_family" "$TARGET_IP")"; then
        if [[ "$engine" == "proxy" ]]; then
            die "${ENTRY_NODE_LABEL} 当前无法用 IPv${target_family} 到达 ${TARGET_NODE_LABEL} (${TARGET_IP})。跨 IPv4/IPv6 代理要求 ${ENTRY_NODE_LABEL} 具备目标协议族出口；否则需要 NAT64/464XLAT、VPN、隧道，或换一台双栈中转机。"
        fi
        die "${ENTRY_NODE_LABEL} 机器没有到 ${TARGET_NODE_LABEL} (${TARGET_IP}) 的 IPv${target_family} 路由。"
    fi

    route_egress_if="$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$route_line")"
    route_source_ip="$(awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' <<< "$route_line")"

    default_listen_if="$(get_default_interface "$listen_family")"
    if [[ -z "$default_listen_if" ]]; then
        default_listen_if="$(get_first_up_interface)"
    fi
    [[ -n "$default_listen_if" ]] || die "未找到可用的监听网卡。"

    LISTEN_IF="$(prompt_default "${ENTRY_NODE_LABEL} 接收上一跳连接的网卡" "$default_listen_if")" # 交互: 选择入口网卡，上一跳流量会从这里进入当前入口机器。
    ip link show dev "$LISTEN_IF" >/dev/null 2>&1 || die "网卡不存在: $LISTEN_IF"

    default_listen_addr="$(get_iface_address "$listen_family" "$LISTEN_IF")"
    if [[ -n "$default_listen_addr" ]]; then
        LISTEN_ADDR="$(prompt_default "${ENTRY_NODE_LABEL} 监听 IP，输入 * 表示所有本机 IPv${listen_family} 地址" "$default_listen_addr")" # 交互: NAT 还匹配入口网卡；Nginx 按监听地址绑定。
        [[ "$LISTEN_ADDR" == "*" ]] && LISTEN_ADDR=""
        LISTEN_ADDR="$(normalize_ip "$LISTEN_ADDR")"
    else
        read -r -p "${ENTRY_NODE_LABEL} 监听 IP，留空表示该网卡所有 IPv${listen_family} 地址: " LISTEN_ADDR # 交互: 无法自动识别监听 IP 时手动填写。
        LISTEN_ADDR="$(normalize_ip "$LISTEN_ADDR")"
    fi

    EGRESS_IF="$route_egress_if"
    SNAT_SOURCE="$route_source_ip"
    if [[ "$engine" == "nat" ]]; then
        EGRESS_IF="$(prompt_default "${ENTRY_NODE_LABEL} 连接 ${TARGET_NODE_LABEL} 的出口网卡" "$route_egress_if")" # 交互: 选择当前入口机器发往下一跳机器的出口网卡。
        ip link show dev "$EGRESS_IF" >/dev/null 2>&1 || die "网卡不存在: $EGRESS_IF"

        if [[ -z "$SNAT_SOURCE" ]]; then
            SNAT_SOURCE="$(get_iface_address "$target_family" "$EGRESS_IF")"
        fi
        [[ -n "$SNAT_SOURCE" ]] || die "无法自动获取 ${ENTRY_NODE_LABEL} 连接 ${TARGET_NODE_LABEL} 时使用的源 IP。请检查 ${EGRESS_IF} 的地址配置。"

        SNAT_SOURCE="$(prompt_default "${ENTRY_NODE_LABEL} 转发到 ${TARGET_NODE_LABEL} 时使用的源 IP(SNAT，高性能推荐默认值)" "$SNAT_SOURCE")" # 交互: 设置 SNAT 源地址，保证下一跳机器回包回到当前入口机器。
        SNAT_SOURCE="$(normalize_ip "$SNAT_SOURCE")"
    fi

    read -r -p "允许访问 ${ENTRY_NODE_LABEL}:${LOCAL_PORT} 的来源 CIDR，留空表示所有来源: " ALLOWED_SOURCE # 交互: 限制谁能访问当前入口机器的入口端口，建议填上一跳公网 IP/32 或 IPv6/128。
    ALLOWED_SOURCE="$(normalize_ip "$ALLOWED_SOURCE")"
    [[ -z "$LISTEN_ADDR" || "$(detect_ip_family "$LISTEN_ADDR")" == "$listen_family" ]] || die "监听 IP 协议族不匹配。"
    [[ -z "$ALLOWED_SOURCE" ]] || validate_network_value cidr "$ALLOWED_SOURCE" "$listen_family" || die "允许来源 CIDR 无效。"
    if [[ "$engine" == nat ]]; then
        [[ "$(detect_ip_family "$SNAT_SOURCE")" == "$target_family" ]] || die "SNAT 地址无效。"
    fi
    validate_network_value interface "$LISTEN_IF" || die "入口网卡名无效。"
    [[ -z "$EGRESS_IF" ]] || validate_network_value interface "$EGRESS_IF" || die "出口网卡名无效。"
    TARGET_PORT="$((10#$TARGET_PORT))"
}

confirm_config() {
    local mode="$1"
    local protocols="$2"
    local listen_family="$3"
    local target_family="$4"
    local engine="$5"
    local shown_listen_addr="${LISTEN_ADDR:-所有本机 IPv${listen_family} 地址}"
    local shown_source="${ALLOWED_SOURCE:-所有来源}"
    local answer

    echo
    echo "即将配置如下转发:"
    echo "  运行位置: ${ENTRY_NODE_LABEL} 机器"
    echo "  流量方向: 上一跳 -> ${ENTRY_NODE_LABEL}:${LOCAL_PORT} -> ${TARGET_NODE_LABEL}:${TARGET_IP}:${TARGET_PORT} -> ${ENTRY_NODE_LABEL} -> 上一跳"
    echo "  转发类型: ${mode}，入口 IPv${listen_family}，目标 IPv${target_family}"
    echo "  实现方式: $([[ "$engine" == "nat" ]] && echo "iptables/ip6tables 内核 NAT" || echo "Nginx stream 跨协议族 L4 代理")"
    echo "  转发协议: ${protocols}"
    echo "  ${ENTRY_NODE_LABEL} 监听网卡/IP: ${LISTEN_IF} / ${shown_listen_addr}"
    if [[ "$engine" == "nat" ]]; then
        echo "  ${ENTRY_NODE_LABEL} 到 ${TARGET_NODE_LABEL} 出口网卡/SNAT源IP: ${EGRESS_IF} / ${SNAT_SOURCE}"
    else
        echo "  ${ENTRY_NODE_LABEL} 到 ${TARGET_NODE_LABEL} 出口协议族: IPv${target_family}，由系统路由表决定出口"
    fi
    echo "  允许来源: ${shown_source}"
    echo "  同协议族、同传输协议、同入口端口的旧 A2B NAT 映射会被替换；已建立连接须重连。"
    echo
    if [[ "$engine" == "proxy" ]]; then
        echo "跨协议族说明:"
        echo "  这不是 iptables NAT，而是 L4 代理。${TARGET_NODE_LABEL} 看到的来源会是 ${ENTRY_NODE_LABEL}，不会保留你的原始客户端 IP。"
        echo "  如果 ${ENTRY_NODE_LABEL} 没有目标协议族出口，例如纯 IPv6 ${ENTRY_NODE_LABEL} 直连 IPv4-only ${TARGET_NODE_LABEL}，此配置无法凭空变出 IPv4，需要 NAT64/464XLAT/VPN/隧道。"
        echo
    fi

    read -r -p "确认写入配置? [Y/n]: " answer # 交互: 最终确认，避免误写防火墙或代理配置。
    case "${answer:-Y}" in
        y|Y|yes|YES) return ;;
        *) die "已取消。" ;;
    esac
}

add_nat_rules() {
    local family="$1"
    local cmd="$2"
    local protocols="$3"
    local proto
    local dnat_target
    local comment
    local pre_args
    local post_args
    local fwd_new_args
    local fwd_reply_args
    local stage before candidate
    stage="$(mktemp -d)"
    before="$stage/before"
    candidate="$stage/candidate"
    local RULE_STAGE="$stage/new"
    : > "$RULE_STAGE"
    export_managed_rules "$cmd" > "$before"

    if [[ "$family" == "6" ]]; then
        dnat_target="[${TARGET_IP}]:${TARGET_PORT}"
    else
        dnat_target="${TARGET_IP}:${TARGET_PORT}"
    fi

    for proto in $protocols; do
        comment="${TAG} ${proto} ${LOCAL_PORT}->${TARGET_IP}:${TARGET_PORT}"

        pre_args=(-i "$LISTEN_IF")
        pre_args+=(-m addrtype --dst-type LOCAL)
        [[ -n "$ALLOWED_SOURCE" ]] && pre_args+=(-s "$ALLOWED_SOURCE")
        [[ -n "$LISTEN_ADDR" ]] && pre_args+=(-d "$LISTEN_ADDR")
        pre_args+=(-p "$proto" --dport "$LOCAL_PORT" -m comment --comment "$comment" -j DNAT --to-destination "$dnat_target")
        ensure_rule_append "$cmd" nat "$CHAIN_PRE" "${pre_args[@]}"

        post_args=(-o "$EGRESS_IF")
        [[ -n "$ALLOWED_SOURCE" ]] && post_args+=(-s "$ALLOWED_SOURCE")
        post_args+=(-p "$proto" -d "$TARGET_IP" --dport "$TARGET_PORT" -m conntrack --ctstate DNAT --ctorigdstport "$LOCAL_PORT" -m comment --comment "$comment" -j SNAT --to-source "$SNAT_SOURCE")
        ensure_rule_append "$cmd" nat "$CHAIN_POST" "${post_args[@]}"

        fwd_new_args=(-i "$LISTEN_IF" -o "$EGRESS_IF")
        [[ -n "$ALLOWED_SOURCE" ]] && fwd_new_args+=(-s "$ALLOWED_SOURCE")
        fwd_new_args+=(-p "$proto" -d "$TARGET_IP" --dport "$TARGET_PORT" -m conntrack --ctstate DNAT --ctorigdstport "$LOCAL_PORT" -m comment --comment "$comment" -j ACCEPT)
        ensure_rule_append "$cmd" filter "$CHAIN_FWD" "${fwd_new_args[@]}"

        fwd_reply_args=(-i "$EGRESS_IF" -o "$LISTEN_IF" -p "$proto" -s "$TARGET_IP" --sport "$TARGET_PORT" -m conntrack --ctstate DNAT --ctdir REPLY --ctorigdstport "$LOCAL_PORT" -m comment --comment "$comment" -j ACCEPT)
        ensure_rule_append "$cmd" filter "$CHAIN_FWD" "${fwd_reply_args[@]}"
    done
    python3 - "$before" "$RULE_STAGE" "$LOCAL_PORT" "$protocols" > "$candidate" <<'PY'
import pathlib
import shlex
import sys
before, additions, port, protocols = sys.argv[1:]
prefixes = tuple("a2b-forward " + p + " " + port + "->" for p in protocols.split())
new = {"nat": [], "filter": []}
for line in pathlib.Path(additions).read_text().splitlines():
    table, rule = line.split("\t", 1)
    new[table].append(rule)
table = None
for line in pathlib.Path(before).read_text().splitlines():
    if line.startswith("*"):
        table = line[1:]
    if line.startswith("-A "):
        args = shlex.split(line)
        if "--comment" in args and args[args.index("--comment") + 1].startswith(prefixes):
            continue
    if line == "COMMIT":
        for rule in new[table]:
            print(rule)
    print(line)
PY
    if ! "$cmd-restore" --wait 10 --noflush --test < "$candidate"; then
        rm -r "$stage"
        die "NAT 候选规则校验失败，原规则未改动。"
    fi
    if ! "$cmd-restore" --wait 10 --noflush < "$candidate"; then
        "$cmd-restore" --wait 10 --noflush < "$before" || warn "自动恢复失败，请使用审计备份。"
        rm -r "$stage"
        die "NAT 写入失败，已尝试恢复原 A2B 规则。"
    fi
    unset RULE_STAGE
    ensure_chain "$cmd"
    rm -r "$stage"
}

nginx_addr_port() {
    local family="$1"
    local address="$2"
    local port="$3"

    if [[ -z "$address" ]]; then
        if [[ "$family" == "6" ]]; then
            echo "[::]:${port}"
        else
            echo "0.0.0.0:${port}"
        fi
        return
    fi

    if [[ "$family" == "6" ]]; then
        echo "[${address}]:${port}"
    else
        echo "${address}:${port}"
    fi
}

nginx_proxy_pass_target() {
    local family="$1"
    local address="$2"
    local port="$3"

    if [[ "$family" == "6" ]]; then
        echo "[${address}]:${port}"
    else
        echo "${address}:${port}"
    fi
}

proxy_config_name() {
    local listen_family="$1"
    local target_family="$2"
    local proto="$3"
    local raw

    raw="${listen_family}-${target_family}-${proto}-${LISTEN_ADDR:-all}-${LOCAL_PORT}"
    printf '%s' "$raw" | tr -c 'A-Za-z0-9_.-' '_'
}

write_proxy_master_config() {
    mkdir -p "$PROXY_DIR" "$PROXY_CONF_DIR" "$PROXY_LOG_DIR"

    {
        if [[ -f "$NGINX_STREAM_MODULE" ]]; then
            echo "load_module ${NGINX_STREAM_MODULE};"
            echo
        fi
        cat <<EOF
worker_processes ${NGINX_WORKERS};
worker_rlimit_nofile 1048576;
pid ${PROXY_PID};
error_log ${PROXY_LOG_DIR}/error.log warn;

events {
    worker_connections 65535;
    multi_accept on;
}

stream {
    include ${PROXY_CONF_DIR}/*.conf;
}
EOF
    } > "$PROXY_CONF"
}

write_proxy_service() {
    local nginx_bin

    nginx_bin="$(command -v nginx || echo /usr/sbin/nginx)"
    cat > "$PROXY_SERVICE" <<EOF
[Unit]
Description=A2B cross-family stream proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${nginx_bin} -c ${PROXY_CONF} -g 'daemon off;'
ExecReload=${nginx_bin} -c ${PROXY_CONF} -s reload
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_proxy_mapping() {
    local listen_family="$1"
    local target_family="$2"
    local protocols="$3"
    local proto
    local listen_socket
    local target_socket
    local name
    local conf_file
    local listen_line
    local live_dir="$PROXY_CONF_DIR" live_master="$PROXY_CONF" stage file
    local changed=() was_active=false

    install_proxy_dependencies
    mkdir -p "$PROXY_DIR"
    stage="$(mktemp -d "${PROXY_DIR}/.candidate.XXXXXX")"
    mkdir -p "$stage/conf.d" "$stage/old"
    if [[ -d "$live_dir" ]]; then
        cp -a "$live_dir/." "$stage/conf.d/"
        cp -a "$live_dir/." "$stage/old/"
    fi
    [[ ! -f "$live_master" ]] || cp -p "$live_master" "$stage/old-master"
    [[ ! -f "$PROXY_SERVICE" ]] || cp -p "$PROXY_SERVICE" "$stage/old-service"
    local PROXY_CONF_DIR="$stage/conf.d" PROXY_CONF="$stage/nginx.conf"
    write_proxy_master_config

    listen_socket="$(nginx_addr_port "$listen_family" "$LISTEN_ADDR" "$LOCAL_PORT")"
    target_socket="$(nginx_proxy_pass_target "$target_family" "$TARGET_IP" "$TARGET_PORT")"

    for proto in $protocols; do
        name="$(proxy_config_name "$listen_family" "$target_family" "$proto")"
        conf_file="${PROXY_CONF_DIR}/${name}.conf"
        changed+=("${name}.conf")

        if [[ "$proto" == "udp" ]]; then
            listen_line="listen ${listen_socket} udp reuseport"
        else
            listen_line="listen ${listen_socket}"
        fi
        if [[ "$listen_family" == "6" ]]; then
            listen_line="${listen_line} ipv6only=on"
        fi

        {
            echo "# Managed by ${TAG}: IPv${listen_family} ${proto} A:${LOCAL_PORT} -> IPv${target_family} B:${TARGET_IP}:${TARGET_PORT}"
            echo "server {"
            echo "    ${listen_line};"
            if [[ -n "$ALLOWED_SOURCE" ]]; then
                echo "    allow ${ALLOWED_SOURCE};"
                echo "    deny all;"
            fi
            echo "    proxy_pass ${target_socket};"
            echo "    proxy_connect_timeout 5s;"
            if [[ "$proto" == udp ]]; then
                echo "    proxy_timeout 5m;"
            else
                echo "    proxy_timeout 1h;"
                echo "    proxy_socket_keepalive on;"
            fi
            echo "    access_log off;"
            echo "}"
        } > "$conf_file"
    done

    if ! nginx -t -c "$PROXY_CONF"; then
        rm -r "$stage"
        die "Nginx 候选配置校验失败，现有配置和进程保持不变。"
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        rm -r "$stage"
        die "跨协议族代理需要 systemd 托管高可用服务，但当前系统没有 systemctl。"
    fi

    PROXY_CONF_DIR="$live_dir"
    PROXY_CONF="$live_master"
    mkdir -p "$live_dir"
    for file in "${changed[@]}"; do
        install -m 600 "$stage/conf.d/$file" "$live_dir/$file"
    done
    write_proxy_master_config
    write_proxy_service
    systemctl daemon-reload
    if systemctl is-active --quiet a2b-forward-proxy.service; then
        was_active=true
    fi
    local applied=false
    if [[ "$was_active" == true ]]; then
        if systemctl reload a2b-forward-proxy.service; then applied=true; fi
    else
        if systemctl enable --now a2b-forward-proxy.service; then applied=true; fi
    fi
    if [[ "$applied" != true ]]; then
        for file in "${changed[@]}"; do
            if [[ -f "$stage/old/$file" ]]; then
                cp -p "$stage/old/$file" "$live_dir/$file"
            else
                rm -f "$live_dir/$file"
            fi
        done
        if [[ -f "$stage/old-master" ]]; then cp -p "$stage/old-master" "$live_master"; else rm -f "$live_master"; fi
        if [[ -f "$stage/old-service" ]]; then cp -p "$stage/old-service" "$PROXY_SERVICE"; else rm -f "$PROXY_SERVICE"; fi
        if [[ "$was_active" != true ]]; then
            systemctl disable --now a2b-forward-proxy.service || true
        fi
        systemctl daemon-reload
        rm -r "$stage"
        die "Nginx 服务应用失败，已恢复旧配置；未强制重启原服务。"
    fi
    systemctl enable a2b-forward-proxy.service >/dev/null
    rm -r "$stage"
    info "跨协议族代理服务已启用: a2b-forward-proxy.service"
}

remove_proxy_config() {
    if command -v systemctl >/dev/null 2>&1 && [[ -f "$PROXY_SERVICE" ]]; then
        systemctl disable --now a2b-forward-proxy.service >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if [[ -d "$PROXY_CONF_DIR" ]]; then
        find "$PROXY_CONF_DIR" -type f -name '*.conf' -delete
    fi
    rm -f "$PROXY_CONF" "$PROXY_SERVICE"
    info "已删除本脚本管理的跨协议族代理配置。"
}

remove_rules_restore_service() {
    if command -v systemctl >/dev/null 2>&1 && [[ -f "$RULES_RESTORE_SERVICE" ]]; then
        systemctl disable --now a2b-forward-rules.service >/dev/null 2>&1 || true
        rm -f "$RULES_RESTORE_SERVICE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    rm -f "$RULES_V4_FILE" "$RULES_V6_FILE"
    info "已删除本脚本管理的防火墙规则恢复服务。"
}

remove_wireguard_config() {
    local file
    local base
    local iface

    if [[ ! -d "$WG_EXPORT_DIR" ]] || ! compgen -G "${WG_EXPORT_DIR}/*-B.conf" >/dev/null; then
        return
    fi

    if ! confirm_yes_no "是否同时停用并删除本脚本生成的 WireGuard A/B 配置" "N"; then
        info "保留 WireGuard 配置。"
        return
    fi

    for file in "${WG_EXPORT_DIR}"/*-B.conf; do
        base="$(basename "$file")"
        iface="${base%-B.conf}"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable --now "wg-quick@${iface}.service" >/dev/null 2>&1 || true
        else
            wg-quick down "$iface" >/dev/null 2>&1 || true
        fi
        rm -f "${WG_DIR}/${iface}.conf" "$file"
    done

    rmdir "$WG_EXPORT_DIR" 2>/dev/null || true
    info "已停用并删除本脚本生成的 WireGuard 配置。"
}

remove_managed_rules() {
    local file iface port retained=false
    confirm_yes_no "确认删除所有 A2B 入口转发及跨族代理（现有连接可能中断）" "N" || return 0
    backup_rules
    remove_wireguard_config
    remove_managed_rules_for_cmd iptables
    remove_managed_rules_for_cmd ip6tables
    clean_legacy_persistence
    remove_rules_restore_service
    remove_proxy_config
    for file in "$WG_EXPORT_DIR"/*-B.conf; do
        [[ -f "$file" ]] || continue
        iface="${file##*/}"
        iface="${iface%-B.conf}"
        [[ -f "$WG_DIR/$iface.conf" ]] || continue
        port="$(awk -F= '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$WG_DIR/$iface.conf")"
        if validate_port "$port"; then
            allow_wireguard_input "$port"
            retained=true
        fi
    done
    if [[ "$retained" == true ]]; then
        save_rules
        info "已保留 WireGuard UDP 放行规则及其开机恢复服务。"
    fi
    rm -f "$SYSCTL_V4_FILE" "$SYSCTL_V6_FILE" "$SYSCTL_PERF_FILE"
    warn "已移除本项目 sysctl 文件；运行中的共享内核参数未强制回退，请按备份核对。"
    info "已删除本脚本管理的 NAT 规则和代理配置。"
}

prompt_required() {
    local prompt="$1"
    local value

    while true; do
        read -r -p "$prompt: " value || die "输入结束，已取消。"
        if [[ -n "$value" ]]; then
            echo "$value"
            return
        fi
        echo "此项不能为空。" >&2
    done
}

choose_primary_workflow() {
    local choice

    echo "请选择配置目标:" >&2
    echo "1. 推荐: B 上运行代理，A 做公网入口，按现有网络选择直连或隧道。" >&2
    echo "2. 高级: 只配置 A 到 B 任意端口转发，不额外处理 WireGuard。" >&2
    echo "3. 只创建/刷新 A-B WireGuard 隧道配置，不添加入口端口转发。" >&2
    echo "4. 链式代理: 本地 -> C -> A -> B，分步骤配置 C->A 和 A->B。" >&2
    read -r -p "请输入选项 [1]: " choice # 交互: 选择整体工作流，推荐选 1 以保证最终由 B 访问目标网站。

    case "${choice:-1}" in
        1) echo "b_proxy" ;;
        2) echo "advanced_forward" ;;
        3) echo "wireguard_only" ;;
        4) echo "chain_proxy" ;;
        *) die "无效选择: $choice" ;;
    esac
}

choose_entry_family() {
    local choice

    echo "请选择你本地连接 ${ENTRY_NODE_LABEL} 使用的入口协议:" >&2
    echo "1. IPv4  本地客户端访问 ${ENTRY_NODE_LABEL} 的 IPv4 地址。" >&2
    echo "2. IPv6  本地客户端访问 ${ENTRY_NODE_LABEL} 的 IPv6 地址。" >&2
    echo "提示: 想要最高性能，请让入口协议族和 ${TARGET_NODE_LABEL} 的目标地址协议族一致，这样可走内核 NAT。" >&2
    read -r -p "请输入选项 [1]: " choice # 交互: 选择当前入口机器对外暴露入口时使用 IPv4 还是 IPv6。

    case "${choice:-1}" in
        1|4) echo "4" ;;
        2|6) echo "6" ;;
        *) die "无效选择: $choice" ;;
    esac
}

choose_direct_target_family() {
    local choice

    echo "请选择 ${ENTRY_NODE_LABEL} 连接 ${TARGET_NODE_LABEL} 服务使用的地址类型:" >&2
    echo "1. IPv4  ${TARGET_NODE_LABEL} 的目标端口通过 IPv4 地址可达。" >&2
    echo "2. IPv6  ${TARGET_NODE_LABEL} 的目标端口通过 IPv6 地址可达。" >&2
    read -r -p "请输入选项 [1]: " choice # 交互: 选择当前入口机器到下一跳机器的目标地址协议族。

    case "${choice:-1}" in
        1|4) echo "4" ;;
        2|6) echo "6" ;;
        *) die "无效选择: $choice" ;;
    esac
}

choose_ab_transport() {
    local choice

    echo "请选择 A 和 B 之间的传输方式:" >&2
    echo "1. 已有 WireGuard 隧道：最快落地，继续用现有 B 隧道 IP。" >&2
    echo "2. 新建 WireGuard 隧道：适合需要私网互通或额外加密的链路，会增加封装开销。" >&2
    echo "3. 不用 WireGuard：直接走现有公网/内网路由，适合已加密的 Reality/TLS 服务。" >&2
    echo "4. NAT64/464XLAT：A 是 IPv6-only、B 是 IPv4-only，且 A 所在网络已有 NAT64/CLAT 能力。" >&2
    echo "5. 双栈中转/其它隧道：把双栈机器作为 A，或先建好隧道后按现有路由填写 B 地址。" >&2
    read -r -p "请输入选项 [3]: " choice # 交互: 默认复用当前链路，不自动新建隧道。

    case "${choice:-3}" in
        1) echo "existing_wg" ;;
        2) echo "new_wg" ;;
        3) echo "direct_route" ;;
        4) echo "nat64_464xlat" ;;
        5)
            warn "双栈中转的正确用法是：在双栈中转机上运行本脚本，把这台机器当作 A；若已有其它隧道，则按现有路由继续填写 B 的隧道地址。"
            echo "direct_route"
            ;;
        *) die "无效选择: $choice" ;;
    esac
}

wg_make_keypair() {
    local private
    local public

    private="$(wg genkey)"
    public="$(printf '%s' "$private" | wg pubkey)"
    printf '%s\n%s\n' "$private" "$public"
}

create_wireguard_tunnel() {
    local iface
    local listen_port
    local a_ipv4_cidr
    local b_ipv4_cidr
    local a_ipv6_cidr
    local b_ipv6_cidr
    local a_ipv4
    local b_ipv4
    local a_ipv6
    local b_ipv6
    local a_endpoint
    local mtu
    local a_private
    local a_public
    local b_private
    local b_public
    local keypair
    local a_conf
    local b_conf
    local endpoint
    local old_umask

    install_wireguard_dependencies

    iface="$(prompt_default "WireGuard 接口名" "a2b0")" # 交互: 设置 A/B 两端 WireGuard 接口名。
    validate_network_value interface "$iface" || die "WireGuard 接口名无效。"
    listen_port="$(prompt_port "A WireGuard UDP 监听端口，B 会连接这个端口" "51820")" # 交互: 设置 A 上 WireGuard 握手端口。
    a_ipv4_cidr="$(prompt_default "A WireGuard IPv4 内网地址/CIDR" "10.66.66.1/24")" # 交互: 设置 A 的隧道 IPv4 地址。
    b_ipv4_cidr="$(prompt_default "B WireGuard IPv4 内网地址/CIDR" "10.66.66.2/24")" # 交互: 设置 B 的隧道 IPv4 地址。
    a_ipv6_cidr="$(prompt_default "A WireGuard IPv6 内网地址/CIDR" "fd66:66:66::1/64")" # 交互: 设置 A 的隧道 IPv6 地址。
    b_ipv6_cidr="$(prompt_default "B WireGuard IPv6 内网地址/CIDR" "fd66:66:66::2/64")" # 交互: 设置 B 的隧道 IPv6 地址。
    mtu="$(prompt_default "WireGuard MTU，常见公网/VPS 推荐 1420" "1420")" # 交互: 设置 WireGuard MTU，路径不稳定时可降低到 1380。
    [[ "$mtu" =~ ^[0-9]{4}$ ]] && (( 10#$mtu >= 1280 && 10#$mtu <= 9000 )) || die "双栈 WireGuard MTU 必须在 1280-9000。"
    echo "提示: B 必须能访问你接下来填写的 A 公网地址；IPv4-only 的 B 不能直连只有 IPv6 的 A，反之亦然。"
    a_endpoint="$(prompt_required "B 连接 A 使用的公网地址/IP/DDNS，不要带端口")" # 交互: 设置写入 B 配置的 A 公网 Endpoint。
    a_endpoint="$(normalize_ip "$a_endpoint")"
    validate_network_value endpoint "$a_endpoint" || die "WireGuard Endpoint 无效。"
    validate_network_value cidr "$a_ipv4_cidr" 4 || die "A IPv4 CIDR 无效。"
    validate_network_value cidr "$b_ipv4_cidr" 4 || die "B IPv4 CIDR 无效。"
    validate_network_value cidr "$a_ipv6_cidr" 6 || die "A IPv6 CIDR 无效。"
    validate_network_value cidr "$b_ipv6_cidr" 6 || die "B IPv6 CIDR 无效。"

    a_ipv4="$(strip_cidr "$a_ipv4_cidr")"
    b_ipv4="$(strip_cidr "$b_ipv4_cidr")"
    a_ipv6="$(strip_cidr "$a_ipv6_cidr")"
    b_ipv6="$(strip_cidr "$b_ipv6_cidr")"

    [[ "$(detect_ip_family "$a_ipv4")" == "4" ]] || die "A WireGuard IPv4 地址无效: $a_ipv4"
    [[ "$(detect_ip_family "$b_ipv4")" == "4" ]] || die "B WireGuard IPv4 地址无效: $b_ipv4"
    [[ "$(detect_ip_family "$a_ipv6")" == "6" ]] || die "A WireGuard IPv6 地址无效: $a_ipv6"
    [[ "$(detect_ip_family "$b_ipv6")" == "6" ]] || die "B WireGuard IPv6 地址无效: $b_ipv6"
    [[ "$a_ipv4" != "$b_ipv4" && "$a_ipv6" != "$b_ipv6" ]] || die "A/B 隧道地址不能相同。"

    a_conf="${WG_DIR}/${iface}.conf"
    b_conf="${WG_EXPORT_DIR}/${iface}-B.conf"
    [[ ! -e "$a_conf" && ! -e "$b_conf" ]] || die "接口已有配置；请使用已有隧道，或为新隧道换一个接口名，避免轮换密钥中断连接。"
    if ip link show dev "$iface" >/dev/null 2>&1; then die "同名网络接口已存在，请使用已有隧道或换一个名字。"; fi
    confirm_yes_no "确认生成密钥、写入 A/B 配置并启动 A 端 WireGuard" "N" || die "已取消。"
    backup_rules

    keypair="$(wg_make_keypair)"
    a_private="$(sed -n '1p' <<< "$keypair")"
    a_public="$(sed -n '2p' <<< "$keypair")"
    keypair="$(wg_make_keypair)"
    b_private="$(sed -n '1p' <<< "$keypair")"
    b_public="$(sed -n '2p' <<< "$keypair")"

    mkdir -p "$WG_DIR" "$WG_EXPORT_DIR"
    endpoint="$(endpoint_host_for_wg "$a_endpoint"):${listen_port}"

    old_umask="$(umask)"
    umask 077
    cat > "$a_conf" <<EOF
[Interface]
Address = ${a_ipv4_cidr}, ${a_ipv6_cidr}
ListenPort = ${listen_port}
PrivateKey = ${a_private}
MTU = ${mtu}

[Peer]
PublicKey = ${b_public}
AllowedIPs = ${b_ipv4}/32, ${b_ipv6}/128
EOF

    cat > "$b_conf" <<EOF
[Interface]
Address = ${b_ipv4_cidr}, ${b_ipv6_cidr}
PrivateKey = ${b_private}
MTU = ${mtu}

[Peer]
PublicKey = ${a_public}
Endpoint = ${endpoint}
AllowedIPs = ${a_ipv4}/32, ${a_ipv6}/128
PersistentKeepalive = 25
EOF
    umask "$old_umask"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        if systemctl is-active --quiet "wg-quick@${iface}.service"; then
            systemctl restart "wg-quick@${iface}.service"
        else
            systemctl enable --now "wg-quick@${iface}.service"
        fi
    else
        wg-quick down "$iface" >/dev/null 2>&1 || true
        wg-quick up "$a_conf"
    fi

    allow_wireguard_input "$listen_port"
    save_rules

    # Keep optional results available to callers sourcing this script.
    # shellcheck disable=SC2034
    WG_IFACE="$iface"
    WG_B_IPV4="$b_ipv4"
    WG_B_IPV6="$b_ipv6"
    # shellcheck disable=SC2034
    WG_B_CONFIG="$b_conf"

    echo
    echo "WireGuard A 端已配置并尝试启动: ${a_conf}"
    echo "B 端配置已生成: ${b_conf}"
    echo "请把 B 端配置放到 B 的 /etc/wireguard/${iface}.conf，然后在 B 上执行:"
    echo "  sudo systemctl enable --now wg-quick@${iface}"
    echo "B 上代理程序建议监听 ${b_ipv4}:${TARGET_PORT:-代理端口} 或 ${b_ipv6}:${TARGET_PORT:-代理端口}，也可以监听 0.0.0.0/::。不要只监听 127.0.0.1。"
    echo
}

choose_b_proxy_target_from_existing_wg() {
    local target_ip

    target_ip="$(prompt_required "请输入 B 的 WireGuard 内网 IP，例如 10.66.66.2 或 fd66:66:66::2")" # 交互: 指定 A 通过隧道访问 B 代理时使用的 B 内网地址。
    target_ip="$(normalize_ip "$target_ip")"
    TARGET_FAMILY="$(detect_ip_family "$target_ip")" || die "无法判断 B WireGuard 地址协议族: $target_ip"
    PRESET_TARGET_IP="$target_ip"
    PRESET_TARGET_PORT="$(prompt_port "B 上代理程序监听端口")" # 交互: 指定 B 代理程序端口，最终由 B 用自己的网络访问目标网站。
}

choose_b_proxy_target_from_new_wg() {
    local listen_family="$1"

    create_wireguard_tunnel
    if [[ "$listen_family" == "6" ]]; then
        PRESET_TARGET_IP="$WG_B_IPV6"
        TARGET_FAMILY="6"
    else
        PRESET_TARGET_IP="$WG_B_IPV4"
        TARGET_FAMILY="4"
    fi
    PRESET_TARGET_PORT="$(prompt_port "B 上代理程序监听端口")" # 交互: 指定 B 代理程序端口，最终由 B 用自己的网络访问目标网站。
}

choose_b_proxy_target_via_nat64() {
    local b_ipv4
    local prefix
    local nat64_ip

    echo
    echo "NAT64/464XLAT 模式说明:"
    echo "  适用场景: A 是 IPv6-only，但 A 所在网络提供 NAT64，或你已经部署 Jool/Tayga/其它 NAT64 网关。"
    echo "  效果: 脚本把 B 的 IPv4 地址转换成 NAT64 IPv6 地址，A 用 IPv6 去访问这个合成地址。"
    echo "  注意: 脚本会验证 A 到合成 IPv6 地址的路由；如果网络没有 NAT64/CLAT，此模式不会生效。"
    echo

    b_ipv4="$(prompt_required "请输入 B 的 IPv4 地址，不要带端口")" # 交互: 指定 IPv4-only 的 B 地址，用于生成 NAT64 合成 IPv6 地址。
    b_ipv4="$(normalize_ip "$b_ipv4")"
    [[ "$(detect_ip_family "$b_ipv4" 2>/dev/null || true)" == "4" ]] || die "B 地址不是有效 IPv4: $b_ipv4"

    prefix="$(prompt_default "NAT64 /96 前缀，常见公网前缀是 64:ff9b::/96" "64:ff9b::/96")" # 交互: 指定上游 NAT64 前缀；不同运营商或自建网关可能不同。
    nat64_ip="$(nat64_addr_from_prefix "$prefix" "$b_ipv4")" || die "无法根据 ${prefix} 和 ${b_ipv4} 生成 NAT64 地址。"
    PRESET_TARGET_IP="$nat64_ip"
    PRESET_TARGET_PORT="$(prompt_port "B 上代理程序监听端口")" # 交互: 指定 B 代理服务端口，A 将通过 NAT64 合成 IPv6 地址访问它。
    TARGET_FAMILY="6"

    echo "已生成 NAT64 目标地址: ${b_ipv4} -> ${nat64_ip}"
}

apply_current_mapping() {
    local engine="$1"
    local listen_family="$2"
    local target_family="$3"
    local protocols="$4"
    local cmd

    check_listener_conflicts "$engine" "$listen_family" "$protocols"
    backup_rules
    if confirm_yes_no "是否应用可选高并发参数（普通转发保留现值即可）" "N"; then
        configure_performance_tuning
    fi

    if [[ "$engine" == "nat" ]]; then
        cmd="iptables"
        [[ "$target_family" == "6" ]] && cmd="ip6tables"
        configure_sysctl "$target_family"
        add_nat_rules "$target_family" "$cmd" "$protocols"
        save_rules
    else
        write_proxy_mapping "$listen_family" "$target_family" "$protocols"
        allow_proxy_input "$listen_family" "$protocols"
        save_rules
    fi

    echo
    echo "配置完成。上一跳现在可以连接: ${ENTRY_NODE_LABEL}:${LOCAL_PORT}"
    echo "实际转发目标: ${TARGET_NODE_LABEL}:${TARGET_IP}:${TARGET_PORT}"
    echo "持久化: 防火墙规则由 a2b-forward-rules.service 开机恢复；跨协议族代理由 a2b-forward-proxy.service 常驻；WireGuard 由 wg-quick@接口名托管。"
}

check_listener_conflicts() {
    local engine="$1" family="$2" protocols="$3" proto sockets pid=""
    [[ ! -s "$PROXY_PID" ]] || read -r pid < "$PROXY_PID"
    for proto in $protocols; do
        if [[ "$proto" == tcp ]]; then
            sockets="$(ss "-$family" -H -lntp "sport = :$LOCAL_PORT")"
        else
            sockets="$(ss "-$family" -H -lnup "sport = :$LOCAL_PORT")"
        fi
        [[ -n "$sockets" ]] || continue
        if [[ "$engine" == proxy && "$pid" =~ ^[0-9]+$ && "$sockets" == *"pid=$pid,"* ]]; then
            continue
        fi
        die "IPv${family} ${proto} 端口 ${LOCAL_PORT} 已由本机服务监听，请换一个入口端口，避免影响 SSH/现有服务。"
    done
}

add_advanced_mapping() {
    local mode
    local engine
    local listen_family
    local target_family
    local protocols

    mode="$(choose_forwarding_mode)"
    engine="$(mode_engine "$mode")"
    listen_family="$(mode_listen_family "$mode")"
    target_family="$(mode_target_family "$mode")"
    protocols="$(choose_protocols)"

    unset PRESET_TARGET_IP PRESET_TARGET_PORT
    collect_common_config "$listen_family" "$target_family" "$engine"
    confirm_config "$mode" "$protocols" "$listen_family" "$target_family" "$engine"
    apply_current_mapping "$engine" "$listen_family" "$target_family" "$protocols"
}

add_b_proxy_workflow() {
    local protocols
    local listen_family
    local transport
    local target_family
    local engine

    echo
    echo "推荐拓扑:"
    echo "  你本地客户端 -> A 的入口端口 -> A-B 传输链路 -> B 上的代理程序 -> 目标网站"
    echo "关键原则:"
    echo "  1. 代理程序必须放在 B 上，这样目标网站看到的出口才是 B。"
    echo "  2. A 最好只做入口和转发，不承担访问目标网站的代理角色。"
    echo "  3. 同协议族现有路由可走内核 NAT；WireGuard 按加密/私网需求选择，性能需实测。"
    echo "  4. 双栈中转就是把双栈机器作为 A；NAT64/464XLAT 只在网络已提供转换能力时适用。"
    echo

    if ! confirm_yes_no "B 上的代理程序是否已经安装并监听端口" "Y"; then
        warn "脚本运行在 A 上，无法直接安装 B 的代理程序。请先在 B 上安装 SOCKS5/HTTP/sing-box/Xray/Squid 等代理，并让它监听 WireGuard 内网 IP 或 0.0.0.0/::。"
        if ! confirm_yes_no "是否仍继续生成 A 侧转发/隧道配置" "N"; then
            die "已取消。"
        fi
    fi

    protocols="$(choose_protocols)"
    listen_family="$(choose_entry_family)"
    transport="$(choose_ab_transport)"
    unset PRESET_TARGET_IP PRESET_TARGET_PORT TARGET_FAMILY

    case "$transport" in
        existing_wg)
            choose_b_proxy_target_from_existing_wg
            target_family="$TARGET_FAMILY"
            ;;
        new_wg)
            choose_b_proxy_target_from_new_wg "$listen_family"
            target_family="$TARGET_FAMILY"
            ;;
        nat64_464xlat)
            choose_b_proxy_target_via_nat64
            target_family="$TARGET_FAMILY"
            ;;
        direct_route)
            target_family="$(choose_direct_target_family)"
            ;;
        *)
            die "未知 A-B 传输方式: $transport"
            ;;
    esac

    if [[ "$listen_family" == "$target_family" ]]; then
        engine="nat"
    else
        engine="proxy"
        warn "入口 IPv${listen_family} 到 B 目标 IPv${target_family} 属于跨协议族，无法使用内核 DNAT，将使用 Nginx stream L4 代理。若追求最高性能，建议给 WireGuard 同时配置与入口一致的 B 隧道地址。"
    fi

    collect_common_config "$listen_family" "$target_family" "$engine"
    confirm_config "b-proxy-${transport}" "$protocols" "$listen_family" "$target_family" "$engine"
    apply_current_mapping "$engine" "$listen_family" "$target_family" "$protocols"

    echo
    echo "B 侧代理检查建议:"
    echo "  B 代理应监听 ${TARGET_IP}:${TARGET_PORT} 或 0.0.0.0/::，不要只监听 127.0.0.1。"
    echo "  你的客户端代理地址应填写 A 的入口地址和端口，即 A:${LOCAL_PORT}。"
}

show_chain_deploy_guide() {
    echo
    echo "链式代理部署顺序:"
    echo "  目标拓扑: 本地客户端 -> C -> A -> B -> 目标网站"
    echo "  第 1 步: 在 B 上安装并启动代理程序，让 B 用自己的网络访问目标网站。"
    echo "  第 2 步: 在 A 上运行本脚本，选择 [推荐: B 上运行代理]，完成 A -> B。"
    echo "  第 3 步: 记住 A 的入口端口；在 C 上选择 [链式代理] 和 [当前机器是 C]，完成 C -> A。"
    echo "  第 4 步: 本地客户端只需要连接 C 的入口地址和端口。"
    echo
    echo "性能建议:"
    echo "  1. 优先复用稳定的现有路由；需要私网或加密时再选择 WireGuard。"
    echo "  2. 每一跳尽量使用同协议族地址，这样脚本会使用内核 NAT，性能最好。"
    echo "  3. 跨 IPv4/IPv6 的一跳会自动使用 Nginx stream L4 代理；这更通用，但性能略低于内核 NAT。"
    echo "  4. 每一跳都建议限制来源 CIDR，例如 A 只允许 C，C 只允许你的本地公网 IP。"
    echo
}

add_chain_c_to_a_workflow() {
    local protocols
    local listen_family
    local target_family
    local engine

    ENTRY_NODE_LABEL="C"
    TARGET_NODE_LABEL="A"

    echo
    echo "当前模式: 配置 C -> A。"
    echo "请先确认 A -> B 已经配置完成，并且 A 的入口端口可以从 C 访问。"
    echo "接下来，脚本会让 C 监听一个入口端口，并把流量转发到 A 的入口端口。"
    echo

    protocols="$(choose_protocols)"
    listen_family="$(choose_entry_family)"
    target_family="$(choose_direct_target_family)"
    unset PRESET_TARGET_IP PRESET_TARGET_PORT TARGET_FAMILY

    if [[ "$listen_family" == "$target_family" ]]; then
        engine="nat"
    else
        engine="proxy"
        warn "入口 IPv${listen_family} 到 A 目标 IPv${target_family} 属于跨协议族，将使用 Nginx stream L4 代理。"
    fi

    collect_common_config "$listen_family" "$target_family" "$engine"
    confirm_config "chain-c-to-a" "$protocols" "$listen_family" "$target_family" "$engine"
    apply_current_mapping "$engine" "$listen_family" "$target_family" "$protocols"

    echo
    echo "链式配置完成:"
    echo "  本地客户端 -> C:${LOCAL_PORT} -> A:${TARGET_IP}:${TARGET_PORT} -> B 侧代理 -> 目标网站"
    echo "  你的客户端代理地址应填写 C 的入口地址和端口，即 C:${LOCAL_PORT}。"
}

add_chain_workflow() {
    local role

    show_chain_deploy_guide
    echo "请选择当前正在配置哪一台机器:" >&2
    echo "1. 当前机器是 A：配置 A -> B，这一步决定最终出口是 B。" >&2
    echo "2. 当前机器是 C：配置 C -> A，这一步把本地流量送到 A。" >&2
    echo "3. 只查看链式部署说明，不写入任何配置。" >&2
    read -r -p "请输入选项 [1]: " role # 交互: 选择链式代理中当前机器的角色，避免把 C->A 和 A->B 配反。

    case "${role:-1}" in
        1)
            install_base_dependencies
            ENTRY_NODE_LABEL="A"
            TARGET_NODE_LABEL="B"
            add_b_proxy_workflow
            ;;
        2)
            install_base_dependencies
            add_chain_c_to_a_workflow
            ;;
        3)
            return
            ;;
        *) die "无效选择: $role" ;;
    esac
}

setup_wireguard_only() {
    echo
    echo "仅创建 A-B WireGuard 隧道:"
    echo "  此操作会在 A 上生成并启动 WireGuard 配置，同时导出 B 端配置文件。"
    echo "  它不会添加 A 的公网入口端口转发；之后可重新运行脚本选择推荐工作流。"
    echo
    create_wireguard_tunnel
}

add_mapping() {
    local workflow

    workflow="$(choose_primary_workflow)"
    case "$workflow" in
        b_proxy) install_base_dependencies; add_b_proxy_workflow ;;
        advanced_forward) install_base_dependencies; add_advanced_mapping ;;
        wireguard_only) install_base_dependencies; setup_wireguard_only ;;
        chain_proxy) add_chain_workflow ;;
        *) die "未知工作流: $workflow" ;;
    esac
}

main_menu() {
    local action

    echo "A -> B 端口转发配置脚本"
    echo "1. 添加/更新配置（推荐向导会把代理放在 B，A 做入口）"
    echo "   也支持链式代理：本地 -> C -> A -> B"
    echo "2. 查看本脚本管理的 NAT、跨族代理、WireGuard 导出配置"
    echo "3. 删除本脚本管理的 NAT/跨族代理配置，并可选择删除 WireGuard"
    echo "0. 退出"
    read -r -p "请选择操作 [1]: " action # 交互: 选择新增、查看或删除本脚本管理的配置。

    case "${action:-1}" in
        1) add_mapping ;;
        0) return ;;
        2) show_managed_rules ;;
        3) install_base_dependencies; remove_managed_rules ;;
        *) die "无效选择: $action" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    need_root
    mkdir -p /var/log/a2b-forward
    AUDIT_LOG="/var/log/a2b-forward/operation-$(date +%Y%m%d-%H%M%S)-$$.log"
    exec > >(tee -a "$AUDIT_LOG") 2>&1
    info "操作日志: $AUDIT_LOG（权限 600；不记录密码或 WireGuard 私钥）"
    command -v flock >/dev/null 2>&1 || die "缺少 flock，请先安装 util-linux。"
    exec 9>/run/lock/a2b-forward.lock
    flock -n 9 || die "另一个 a2b-forward 正在运行，请等待其结束。"
    case "${1:-}" in
        --restore) restore_managed_rules ;;
        "") main_menu ;;
        *) die "用法: bash $0 [--restore]" ;;
    esac
fi
