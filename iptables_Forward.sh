#!/usr/bin/env bash
# A -> B port forwarding helper.
# Run this script on machine A.

set -Eeuo pipefail

trap 'echo "ERROR: failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

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
WG_DIR="/etc/wireguard"
WG_EXPORT_DIR="/root/a2b-forward-wireguard"
RULES_V4_FILE="/etc/iptables/a2b-rules.v4"
RULES_V6_FILE="/etc/iptables/a2b-rules.v6"
RULES_RESTORE_SERVICE="/etc/systemd/system/a2b-forward-rules.service"
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

    for cmd in ip iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing=1
        fi
    done

    if (( missing == 0 )); then
        info "基础依赖已就绪: iproute2, iptables"
        ensure_persistent_helper
        return
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        die "缺少必要命令，且当前系统没有 apt-get。请手动安装 iproute2 和 iptables。"
    fi

    info "正在安装基础依赖: iproute2 iptables"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y iproute2 iptables
    ensure_persistent_helper
}

ensure_persistent_helper() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        return
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        warn "未安装 netfilter-persistent。脚本会改用 a2b-forward-rules.service 保存并开机恢复规则。"
        return
    fi

    if dpkg-query -W -f='${Status}' ufw 2>/dev/null | grep -q "install ok installed"; then
        warn "检测到 ufw 已安装，跳过 iptables-persistent，避免移除 ufw；脚本会改用 a2b-forward-rules.service 开机恢复规则。"
        return
    fi

    info "尝试安装 iptables-persistent；若会移除 ufw/其它包则自动放弃。"
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y --no-remove iptables-persistent; then
        warn "iptables-persistent 安装被跳过，避免移除现有防火墙组件；脚本会改用 a2b-forward-rules.service 开机恢复规则。"
    fi
}

install_proxy_dependencies() {
    if command -v nginx >/dev/null 2>&1; then
        if [[ ! -f /usr/lib/nginx/modules/ngx_stream_module.so ]] && command -v apt-get >/dev/null 2>&1; then
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
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

prompt_port() {
    local prompt="$1"
    local default="${2:-}"
    local value

    while true; do
        if [[ -n "$default" ]]; then
            read -r -p "$prompt [$default]: " value # 交互: 输入端口；留空时使用默认端口。
            value="${value:-$default}"
        else
            read -r -p "$prompt: " value # 交互: 输入必须由用户指定的端口。
        fi

        if validate_port "$value"; then
            echo "$value"
            return
        fi

        echo "端口必须是 1-65535 之间的数字。" >&2
    done
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local value

    read -r -p "$prompt [$default]: " value # 交互: 输入可覆盖自动检测值；留空使用默认值。
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
    if [[ "$ip" == *:* ]]; then
        echo "6"
        return
    fi
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "4"
        return
    fi

    return 1
}

ipv4_to_nat64_tail() {
    local ipv4="$1"
    local a b c d octet n
    local parts

    IFS=. read -r a b c d <<< "$ipv4"
    parts=("$a" "$b" "$c" "$d")

    for octet in "${parts[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        n=$((10#$octet))
        (( n >= 0 && n <= 255 )) || return 1
    done

    printf '%02x%02x:%02x%02x\n' "$((10#$a))" "$((10#$b))" "$((10#$c))" "$((10#$d))"
}

nat64_addr_from_prefix() {
    local prefix="$1"
    local ipv4="$2"
    local base
    local tail

    tail="$(ipv4_to_nat64_tail "$ipv4")" || return 1
    base="${prefix%%/*}"
    base="${base#\[}"
    base="${base%\]}"

    if [[ "$base" == *: ]]; then
        echo "${base}${tail}"
    else
        echo "${base}:${tail}"
    fi
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

    read -r -p "$prompt [$default]: " answer # 交互: 二次确认会改动系统配置或继续执行关键步骤。
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
    local backup_dir="/root/${TAG}-backup-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "$backup_dir"
    iptables-save > "${backup_dir}/rules.v4"
    ip6tables-save > "${backup_dir}/rules.v6"
    if [[ -d "$PROXY_DIR" ]]; then
        cp -a "$PROXY_DIR" "${backup_dir}/proxy-config"
    fi
    if [[ -d "$WG_EXPORT_DIR" ]]; then
        cp -a "$WG_EXPORT_DIR" "${backup_dir}/wireguard-export"
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
            "net.ipv4.ip_forward=1" \
            "net.ipv4.conf.all.rp_filter=0" \
            "net.ipv4.conf.default.rp_filter=0"
        apply_sysctl_file "$SYSCTL_V4_FILE"
        info "已开启 IPv4 转发，并关闭 rp_filter 以避免非对称路径误丢包。"
    else
        write_sysctl_file "$SYSCTL_V6_FILE" \
            "net.ipv6.conf.all.forwarding=1"
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

    if [[ -r /proc/sys/net/core/somaxconn ]]; then
        settings+=("net.core.somaxconn=65535")
    fi

    if [[ -r /proc/sys/net/core/rmem_max ]]; then
        settings+=("net.core.rmem_max=134217728")
    fi

    if [[ -r /proc/sys/net/core/wmem_max ]]; then
        settings+=("net.core.wmem_max=134217728")
    fi

    if [[ -r /proc/sys/net/ipv4/tcp_fin_timeout ]]; then
        settings+=("net.ipv4.tcp_fin_timeout=15")
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
    cat > "$RULES_RESTORE_SERVICE" <<EOF
[Unit]
Description=A2B forwarding firewall rules restore
After=local-fs.target ufw.service netfilter-persistent.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'test -s ${RULES_V4_FILE} && iptables-restore < ${RULES_V4_FILE} || true; test -s ${RULES_V6_FILE} && ip6tables-restore < ${RULES_V6_FILE} || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$service_name" >/dev/null 2>&1 || warn "无法启用 ${service_name}，请手动检查 systemd 状态。"
}

save_rules() {
    mkdir -p /etc/iptables

    iptables-save > "$RULES_V4_FILE"
    ip6tables-save > "$RULES_V6_FILE"
    cp "$RULES_V4_FILE" /etc/iptables/rules.v4
    cp "$RULES_V6_FILE" /etc/iptables/rules.v6
    chmod 600 "$RULES_V4_FILE" "$RULES_V6_FILE" /etc/iptables/rules.v4 /etc/iptables/rules.v6 2>/dev/null || true

    if command -v netfilter-persistent >/dev/null 2>&1; then
        if ! netfilter-persistent save >/dev/null 2>&1; then
            warn "netfilter-persistent save 失败，已保留脚本自己的规则文件和 systemd 恢复服务。"
        fi
    fi

    write_rules_restore_service
    systemctl enable netfilter-persistent >/dev/null 2>&1 || true
    info "NAT/放行规则已保存，并通过 a2b-forward-rules.service 配置为开机自动恢复。"
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
        LISTEN_ADDR="$(prompt_default "${ENTRY_NODE_LABEL} 监听 IP，输入 * 表示该网卡所有 IPv${listen_family} 地址" "$default_listen_addr")" # 交互: 限定当前入口机器的监听地址；* 表示所有本机地址。
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

    ensure_chain "$cmd"

    if [[ "$family" == "6" ]]; then
        dnat_target="[${TARGET_IP}]:${TARGET_PORT}"
    else
        dnat_target="${TARGET_IP}:${TARGET_PORT}"
    fi

    for proto in $protocols; do
        comment="${TAG} ${proto} ${LOCAL_PORT}->${TARGET_IP}:${TARGET_PORT}"

        pre_args=(-i "$LISTEN_IF")
        [[ -n "$ALLOWED_SOURCE" ]] && pre_args+=(-s "$ALLOWED_SOURCE")
        [[ -n "$LISTEN_ADDR" ]] && pre_args+=(-d "$LISTEN_ADDR")
        pre_args+=(-p "$proto" --dport "$LOCAL_PORT" -m comment --comment "$comment" -j DNAT --to-destination "$dnat_target")
        ensure_rule_append "$cmd" nat "$CHAIN_PRE" "${pre_args[@]}"

        post_args=(-o "$EGRESS_IF")
        [[ -n "$ALLOWED_SOURCE" ]] && post_args+=(-s "$ALLOWED_SOURCE")
        post_args+=(-p "$proto" -d "$TARGET_IP" --dport "$TARGET_PORT" -m comment --comment "$comment" -j SNAT --to-source "$SNAT_SOURCE")
        ensure_rule_append "$cmd" nat "$CHAIN_POST" "${post_args[@]}"

        fwd_new_args=(-i "$LISTEN_IF" -o "$EGRESS_IF")
        [[ -n "$ALLOWED_SOURCE" ]] && fwd_new_args+=(-s "$ALLOWED_SOURCE")
        fwd_new_args+=(-p "$proto" -d "$TARGET_IP" --dport "$TARGET_PORT" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -m comment --comment "$comment" -j ACCEPT)
        ensure_rule_append "$cmd" filter "$CHAIN_FWD" "${fwd_new_args[@]}"

        fwd_reply_args=(-i "$EGRESS_IF" -o "$LISTEN_IF" -p "$proto" -s "$TARGET_IP" --sport "$TARGET_PORT" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$comment" -j ACCEPT)
        ensure_rule_append "$cmd" filter "$CHAIN_FWD" "${fwd_reply_args[@]}"
    done
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
        if [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]]; then
            echo "load_module /usr/lib/nginx/modules/ngx_stream_module.so;"
            echo
        fi
        cat <<EOF
worker_processes auto;
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

    install_proxy_dependencies
    write_proxy_master_config
    write_proxy_service

    listen_socket="$(nginx_addr_port "$listen_family" "$LISTEN_ADDR" "$LOCAL_PORT")"
    target_socket="$(nginx_proxy_pass_target "$target_family" "$TARGET_IP" "$TARGET_PORT")"

    for proto in $protocols; do
        name="$(proxy_config_name "$listen_family" "$target_family" "$proto")"
        conf_file="${PROXY_CONF_DIR}/${name}.conf"

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
            echo "    proxy_timeout 1h;"
            echo "    access_log off;"
            echo "}"
        } > "$conf_file"
    done

    if ! nginx -t -c "$PROXY_CONF"; then
        die "Nginx stream 配置测试失败。请确认 nginx 已安装 stream 模块，且监听端口未被其它程序占用。"
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        die "跨协议族代理需要 systemd 托管高可用服务，但当前系统没有 systemctl。"
    fi

    systemctl daemon-reload
    if systemctl is-active --quiet a2b-forward-proxy.service; then
        systemctl reload a2b-forward-proxy.service || systemctl restart a2b-forward-proxy.service
    else
        systemctl enable --now a2b-forward-proxy.service
    fi
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

    find "$WG_EXPORT_DIR" -type f -delete 2>/dev/null || true
    rmdir "$WG_EXPORT_DIR" 2>/dev/null || true
    info "已停用并删除本脚本生成的 WireGuard 配置。"
}

remove_managed_rules() {
    backup_rules
    remove_managed_rules_for_cmd iptables
    remove_managed_rules_for_cmd ip6tables
    save_rules
    remove_rules_restore_service
    remove_proxy_config
    remove_wireguard_config
    info "已删除本脚本管理的 NAT 规则和代理配置。"
}

prompt_required() {
    local prompt="$1"
    local value

    while true; do
        read -r -p "$prompt: " value # 交互: 输入必填值，空值会导致后续配置无法生成。
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
    echo "1. 推荐: B 上运行代理，A 做公网入口，A-B 优先使用 WireGuard 隧道。" >&2
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
    echo "2. 新建 WireGuard 隧道：推荐，高性能、低延迟、加密，适合长期使用。" >&2
    echo "3. 不用 WireGuard：直接走 A 到 B 现有公网/内网路由，简单但安全性和稳定性较弱。" >&2
    echo "4. NAT64/464XLAT：A 是 IPv6-only、B 是 IPv4-only，且 A 所在网络已有 NAT64/CLAT 能力。" >&2
    echo "5. 双栈中转/其它隧道：把双栈机器作为 A，或先建好隧道后按现有路由填写 B 地址。" >&2
    read -r -p "请输入选项 [2]: " choice # 交互: 选择 A-B 承载链路，推荐 WireGuard。

    case "${choice:-2}" in
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
    listen_port="$(prompt_port "A WireGuard UDP 监听端口，B 会连接这个端口" "51820")" # 交互: 设置 A 上 WireGuard 握手端口。
    a_ipv4_cidr="$(prompt_default "A WireGuard IPv4 内网地址/CIDR" "10.66.66.1/24")" # 交互: 设置 A 的隧道 IPv4 地址。
    b_ipv4_cidr="$(prompt_default "B WireGuard IPv4 内网地址/CIDR" "10.66.66.2/24")" # 交互: 设置 B 的隧道 IPv4 地址。
    a_ipv6_cidr="$(prompt_default "A WireGuard IPv6 内网地址/CIDR" "fd66:66:66::1/64")" # 交互: 设置 A 的隧道 IPv6 地址。
    b_ipv6_cidr="$(prompt_default "B WireGuard IPv6 内网地址/CIDR" "fd66:66:66::2/64")" # 交互: 设置 B 的隧道 IPv6 地址。
    mtu="$(prompt_default "WireGuard MTU，常见公网/VPS 推荐 1420" "1420")" # 交互: 设置 WireGuard MTU，路径不稳定时可降低到 1380。
    [[ "$mtu" =~ ^[0-9]+$ ]] || die "MTU 必须是数字。"
    echo "提示: B 必须能访问你接下来填写的 A 公网地址；IPv4-only 的 B 不能直连只有 IPv6 的 A，反之亦然。"
    a_endpoint="$(prompt_required "B 连接 A 使用的公网地址/IP/DDNS，不要带端口")" # 交互: 设置写入 B 配置的 A 公网 Endpoint。

    a_ipv4="$(strip_cidr "$a_ipv4_cidr")"
    b_ipv4="$(strip_cidr "$b_ipv4_cidr")"
    a_ipv6="$(strip_cidr "$a_ipv6_cidr")"
    b_ipv6="$(strip_cidr "$b_ipv6_cidr")"

    [[ "$(detect_ip_family "$a_ipv4")" == "4" ]] || die "A WireGuard IPv4 地址无效: $a_ipv4"
    [[ "$(detect_ip_family "$b_ipv4")" == "4" ]] || die "B WireGuard IPv4 地址无效: $b_ipv4"
    [[ "$(detect_ip_family "$a_ipv6")" == "6" ]] || die "A WireGuard IPv6 地址无效: $a_ipv6"
    [[ "$(detect_ip_family "$b_ipv6")" == "6" ]] || die "B WireGuard IPv6 地址无效: $b_ipv6"

    a_conf="${WG_DIR}/${iface}.conf"
    b_conf="${WG_EXPORT_DIR}/${iface}-B.conf"
    if [[ -f "$a_conf" ]] && ! confirm_yes_no "A 上已存在 ${a_conf}，是否覆盖" "N"; then
        die "已取消覆盖 WireGuard 配置。"
    fi
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

    WG_IFACE="$iface"
    WG_B_IPV4="$b_ipv4"
    WG_B_IPV6="$b_ipv6"
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
    if [[ "$prefix" != */96 ]]; then
        warn "当前脚本只按 /96 NAT64 前缀生成地址；你输入的不是 /96，若网络不是 /96 前缀请改用隧道/WireGuard/双栈中转。"
    fi

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

    backup_rules
    configure_performance_tuning

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
    echo "  3. A-B 之间优先使用 WireGuard；同协议族入口到同协议族隧道地址时，可走内核 NAT，性能最好。"
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
    echo "  第 2 步: 在 A 上运行本脚本，选择“推荐: B 上运行代理”，完成 A -> B。"
    echo "  第 3 步: 记住 A 的入口端口；在 C 上运行本脚本，选择“链式代理”，再选择“当前机器是 C”，完成 C -> A。"
    echo "  第 4 步: 本地客户端只需要连接 C 的入口地址和端口。"
    echo
    echo "性能建议:"
    echo "  1. A->B 优先 WireGuard；C->A 如果也不稳定，也建议先建 WireGuard。"
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
    read -r -p "请选择操作 [1]: " action # 交互: 选择新增、查看或删除本脚本管理的配置。

    case "${action:-1}" in
        1) add_mapping ;;
        2) install_base_dependencies; show_managed_rules ;;
        3) install_base_dependencies; remove_managed_rules ;;
        *) die "无效选择: $action" ;;
    esac
}

need_root
main_menu
