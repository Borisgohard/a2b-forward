#!/usr/bin/env bash
# A -> B port forwarding helper.
# Run this script on machine A.

set -Eeuo pipefail

trap 'echo "ERROR: failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

TAG="a2b-forward"
CHAIN_PRE="A2B_PREROUTING"
CHAIN_POST="A2B_POSTROUTING"
CHAIN_FWD="A2B_FORWARD"
SYSCTL_V4_FILE="/etc/sysctl.d/99-a2b-forward-ipv4.conf"
SYSCTL_V6_FILE="/etc/sysctl.d/99-a2b-forward-ipv6.conf"
SYSCTL_PERF_FILE="/etc/sysctl.d/99-a2b-forward-performance.conf"
PROXY_DIR="/etc/a2b-forward"
PROXY_CONF_DIR="${PROXY_DIR}/conf.d"
PROXY_CONF="${PROXY_DIR}/nginx.conf"
PROXY_SERVICE="/etc/systemd/system/a2b-forward-proxy.service"
PROXY_LOG_DIR="/var/log/a2b-forward"
PROXY_PID="/run/a2b-forward-nginx.pid"

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

    for cmd in ip iptables ip6tables iptables-save ip6tables-save; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing=1
        fi
    done

    if ! command -v netfilter-persistent >/dev/null 2>&1; then
        missing=1
    fi

    if (( missing == 0 )); then
        info "基础依赖已就绪: iproute2, iptables, iptables-persistent"
        return
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        die "缺少必要命令，且当前系统没有 apt-get。请手动安装 iproute2、iptables、iptables-persistent。"
    fi

    info "正在安装基础依赖: iproute2 iptables iptables-persistent"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y iproute2 iptables iptables-persistent
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

    "$cmd" -w -t nat -F "$CHAIN_PRE" 2>/dev/null || true
    "$cmd" -w -t nat -F "$CHAIN_POST" 2>/dev/null || true
    "$cmd" -w -F "$CHAIN_FWD" 2>/dev/null || true

    "$cmd" -w -t nat -X "$CHAIN_PRE" 2>/dev/null || true
    "$cmd" -w -t nat -X "$CHAIN_POST" 2>/dev/null || true
    "$cmd" -w -X "$CHAIN_FWD" 2>/dev/null || true
}

save_rules() {
    mkdir -p /etc/iptables

    if command -v netfilter-persistent >/dev/null 2>&1; then
        if ! netfilter-persistent save >/dev/null 2>&1; then
            warn "netfilter-persistent save 失败，改用 iptables-save 直接写入规则文件。"
            iptables-save > /etc/iptables/rules.v4
            ip6tables-save > /etc/iptables/rules.v6
        fi
    else
        iptables-save > /etc/iptables/rules.v4
        ip6tables-save > /etc/iptables/rules.v6
    fi

    systemctl enable netfilter-persistent >/dev/null 2>&1 || true
    info "NAT 规则已保存到 /etc/iptables/rules.v4 和 /etc/iptables/rules.v6"
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
    show_chain iptables nat "$CHAIN_PRE"
    show_chain iptables nat "$CHAIN_POST"
    show_chain iptables filter "$CHAIN_FWD"

    echo
    echo "== IPv6 NAT managed rules =="
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

    LOCAL_PORT="$(prompt_port "A 机器对外监听端口，也就是你本地要连接的 A 端口")" # 交互: 设置 A 暴露给本地访问的入口端口。

    if [[ "$target_family" == "6" ]]; then
        read -r -p "B 机器目标地址，可填 IPv6 或 [IPv6]:端口: " target_input # 交互: 输入 B 的 IPv6 目标地址，可顺带写端口。
    else
        read -r -p "B 机器目标地址，可填 IPv4 或 IPv4:端口: " target_input # 交互: 输入 B 的 IPv4 目标地址，可顺带写端口。
    fi

    parse_target_input "$target_family" "$target_input"
    [[ -n "$TARGET_IP" ]] || die "目标 IP 不能为空。"

    if [[ -n "$TARGET_PORT" ]]; then
        validate_port "$TARGET_PORT" || die "目标端口无效: $TARGET_PORT"
    else
        TARGET_PORT="$(prompt_port "B 机器目标服务端口，也就是最终访问 B 的端口")" # 交互: 设置转发最终落到 B 的端口。
    fi

    if ! route_line="$(get_route_line "$target_family" "$TARGET_IP")"; then
        if [[ "$engine" == "proxy" ]]; then
            die "A 当前无法用 IPv${target_family} 到达 B (${TARGET_IP})。跨 IPv4/IPv6 代理要求 A 具备目标协议族出口；否则需要 NAT64/464XLAT、VPN、隧道，或换一台双栈中转机。"
        fi
        die "A 机器没有到 B (${TARGET_IP}) 的 IPv${target_family} 路由。"
    fi

    route_egress_if="$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$route_line")"
    route_source_ip="$(awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' <<< "$route_line")"

    default_listen_if="$(get_default_interface "$listen_family")"
    if [[ -z "$default_listen_if" ]]; then
        default_listen_if="$(get_first_up_interface)"
    fi
    [[ -n "$default_listen_if" ]] || die "未找到可用的监听网卡。"

    LISTEN_IF="$(prompt_default "A 接收你本地连接的网卡" "$default_listen_if")" # 交互: 选择入口网卡，本地流量会从这里进入 A。
    ip link show dev "$LISTEN_IF" >/dev/null 2>&1 || die "网卡不存在: $LISTEN_IF"

    default_listen_addr="$(get_iface_address "$listen_family" "$LISTEN_IF")"
    if [[ -n "$default_listen_addr" ]]; then
        LISTEN_ADDR="$(prompt_default "A 监听 IP，输入 * 表示该网卡所有 IPv${listen_family} 地址" "$default_listen_addr")" # 交互: 限定 A 的监听地址；* 表示所有本机地址。
        [[ "$LISTEN_ADDR" == "*" ]] && LISTEN_ADDR=""
        LISTEN_ADDR="$(normalize_ip "$LISTEN_ADDR")"
    else
        read -r -p "A 监听 IP，留空表示该网卡所有 IPv${listen_family} 地址: " LISTEN_ADDR # 交互: 无法自动识别监听 IP 时手动填写。
        LISTEN_ADDR="$(normalize_ip "$LISTEN_ADDR")"
    fi

    EGRESS_IF="$route_egress_if"
    SNAT_SOURCE="$route_source_ip"
    if [[ "$engine" == "nat" ]]; then
        EGRESS_IF="$(prompt_default "A 连接 B 的出口网卡" "$route_egress_if")" # 交互: 选择 A 发往 B 的出口网卡。
        ip link show dev "$EGRESS_IF" >/dev/null 2>&1 || die "网卡不存在: $EGRESS_IF"

        if [[ -z "$SNAT_SOURCE" ]]; then
            SNAT_SOURCE="$(get_iface_address "$target_family" "$EGRESS_IF")"
        fi
        [[ -n "$SNAT_SOURCE" ]] || die "无法自动获取 A 连接 B 时使用的源 IP。请检查 ${EGRESS_IF} 的地址配置。"

        SNAT_SOURCE="$(prompt_default "A 转发到 B 时使用的源 IP(SNAT，高性能推荐默认值)" "$SNAT_SOURCE")" # 交互: 设置 SNAT 源地址，保证 B 回包回到 A。
        SNAT_SOURCE="$(normalize_ip "$SNAT_SOURCE")"
    fi

    read -r -p "允许访问 A:${LOCAL_PORT} 的来源 CIDR，留空表示所有来源: " ALLOWED_SOURCE # 交互: 限制谁能访问 A 的入口端口，建议填你的本地公网 IP/32 或 IPv6/128。
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
    echo "  运行位置: A 机器"
    echo "  流量方向: 你(本地) -> A:${LOCAL_PORT} -> B:${TARGET_IP}:${TARGET_PORT} -> A -> 你"
    echo "  转发类型: ${mode}，入口 IPv${listen_family}，目标 IPv${target_family}"
    echo "  实现方式: $([[ "$engine" == "nat" ]] && echo "iptables/ip6tables 内核 NAT" || echo "Nginx stream 跨协议族 L4 代理")"
    echo "  转发协议: ${protocols}"
    echo "  A 监听网卡/IP: ${LISTEN_IF} / ${shown_listen_addr}"
    if [[ "$engine" == "nat" ]]; then
        echo "  A 到 B 出口网卡/SNAT源IP: ${EGRESS_IF} / ${SNAT_SOURCE}"
    else
        echo "  A 到 B 出口协议族: IPv${target_family}，由系统路由表决定出口"
    fi
    echo "  允许来源: ${shown_source}"
    echo
    if [[ "$engine" == "proxy" ]]; then
        echo "跨协议族说明:"
        echo "  这不是 iptables NAT，而是 L4 代理。B 看到的来源会是 A，不会保留你的原始客户端 IP。"
        echo "  如果 A 没有目标协议族出口，例如纯 IPv6 A 直连 IPv4-only B，此配置无法凭空变出 IPv4，需要 NAT64/464XLAT/VPN/隧道。"
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
    cat > "$PROXY_SERVICE" <<EOF
[Unit]
Description=A2B cross-family stream proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/nginx -c ${PROXY_CONF} -g 'daemon off;'
ExecReload=/usr/sbin/nginx -c ${PROXY_CONF} -s reload
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

remove_managed_rules() {
    backup_rules
    remove_managed_rules_for_cmd iptables
    remove_managed_rules_for_cmd ip6tables
    save_rules
    remove_proxy_config
    info "已删除本脚本管理的全部 NAT 规则和代理配置。"
}

add_mapping() {
    local mode
    local engine
    local listen_family
    local target_family
    local cmd
    local protocols

    mode="$(choose_forwarding_mode)"
    engine="$(mode_engine "$mode")"
    listen_family="$(mode_listen_family "$mode")"
    target_family="$(mode_target_family "$mode")"
    protocols="$(choose_protocols)"

    collect_common_config "$listen_family" "$target_family" "$engine"
    confirm_config "$mode" "$protocols" "$listen_family" "$target_family" "$engine"

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
    fi

    echo
    echo "配置完成。你现在可以从本地连接: A:${LOCAL_PORT}"
    echo "实际转发目标: B:${TARGET_IP}:${TARGET_PORT}"
}

main_menu() {
    local action

    echo "A -> B 端口转发配置脚本"
    echo "1. 添加/更新转发规则"
    echo "2. 查看本脚本管理的 NAT 规则和跨族代理配置"
    echo "3. 删除本脚本管理的全部 NAT 规则和跨族代理配置"
    read -r -p "请选择操作 [1]: " action # 交互: 选择新增、查看或删除本脚本管理的配置。

    case "${action:-1}" in
        1) add_mapping ;;
        2) show_managed_rules ;;
        3) remove_managed_rules ;;
        *) die "无效选择: $action" ;;
    esac
}

need_root
install_base_dependencies
main_menu
