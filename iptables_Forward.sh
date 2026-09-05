#!/usr/bin/env bash
# A -> B port forwarding helper.
# Run this script on machine A.

set -Eeuo pipefail
shopt -s inherit_errexit

TAG="a2b-forward"
SCRIPT_VERSION="0.2.0"
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
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
INSTALLED_SCRIPT="/usr/local/lib/a2b-forward/iptables_Forward.sh"
STATE_DIR="/var/lib/a2b-forward"
TRANSACTION_DIR=""
UDP_TIMEOUT=60

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

    for cmd in ip ss python3 flock iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore; do
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

need_systemd() {
    if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
        die "需要正在运行的 systemd。请在 Debian/Ubuntu VPS 上运行，不支持普通 Docker 容器或 Windows。"
    fi
}

install_proxy_dependencies() {
    local install_status=0
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

    info "正在安装跨协议族代理依赖。新安装的默认 nginx.service 将保持停用，只运行 A2B 的独立服务。"
    export DEBIAN_FRONTEND=noninteractive
    # 包安装默认会启动 HTTP :80；临时 mask 仅用于此前不存在的发行版服务。
    if systemctl cat nginx.service >/dev/null 2>&1 || [[ -e /run/systemd/system/nginx.service || -L /run/systemd/system/nginx.service || -e /etc/systemd/system/nginx.service || -L /etc/systemd/system/nginx.service ]]; then
        die "nginx 命令缺失，但已存在 nginx.service 定义/屏蔽。请先修复现有 Nginx 安装，再运行向导。"
    fi
    (
        systemctl mask --runtime nginx.service
        trap 'install_status=$?; systemctl unmask --runtime nginx.service; exit "$install_status"' EXIT
        apt-get update
        apt-get install -y --no-remove nginx libnginx-mod-stream
        systemctl disable nginx.service
    )
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

# read 在命令替换中遇到 EOF 也必须退出，不能默默采用默认选项。
read_input() {
    local prompt="$1" name="$2"
    printf '%s' "$prompt" >&2
    IFS= read -r "${name?}" || die "输入已结束，操作取消。请下载脚本后用 sudo bash 运行，勿把脚本管道直接接入 bash。"
}

prompt_choice() {
    local prompt="$1" default="$2" choices="$3" value
    while true; do
        read_input "$prompt [$default]: " value # 交互: 反复校验菜单选项；回车采用默认值，输入结束则取消。
        value="${value:-$default}"
        if [[ " $choices " == *" $value "* ]]; then
            printf '%s\n' "$value"
            return
        fi
        echo "无效选择，请填写: $choices" >&2
    done
}

# 使用标准库完整解析地址，避免无效 IP、CIDR 或配置注入进入 iptables/nginx/WireGuard。
ip_value() {
    python3 - "$@" <<'PY'
import ipaddress
import re
import sys

kind, value, *args = sys.argv[1:]
try:
    if kind == "endpoint":
        if not re.fullmatch(r"[A-Za-z0-9.:-]+", value):
            raise ValueError("invalid endpoint")
        try:
            addr = ipaddress.ip_address(value)
        except ValueError:
            if ":" in value or re.fullmatch(r"[0-9.]+", value):
                raise ValueError("invalid IP")
            labels = value.rstrip(".").split(".")
            if len(value) > 253 or any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", s) for s in labels):
                raise ValueError("invalid hostname")
        print(value)
    elif kind == "nat64":
        net = ipaddress.IPv6Network(value, strict=True)
        if net.prefixlen != 96:
            raise ValueError("only /96 is supported")
        print(ipaddress.IPv6Address(int(net.network_address) | int(ipaddress.IPv4Address(args[0]))))
    else:
        if "%" in value or any(c.isspace() for c in value):
            raise ValueError("scoped addresses/whitespace unsupported")
        if kind == "network":
            addr = ipaddress.ip_network(value, strict=False)
        elif kind == "interface":
            if "/" not in value:
                raise ValueError("CIDR required")
            addr = ipaddress.ip_interface(value)
        else:
            addr = ipaddress.ip_address(value)
        if args and addr.version != int(args[0]):
            raise ValueError("wrong IP family")
        if kind in ("address", "interface"):
            host = addr.ip if kind == "interface" else addr
            if host.is_unspecified or host.is_multicast or host.is_loopback or host.is_link_local:
                raise ValueError("use a routable unicast address")
        print(addr.version if kind == "family" else addr)
except ValueError:
    sys.exit(1)
PY
}

prompt_ip() {
    local prompt="$1" kind="$2" family="$3" default="${4:-}" value
    while true; do
        value="$(prompt_default "$prompt" "$default")"
        if ip_value "$kind" "$(normalize_ip "$value")" "$family"; then
            return
        fi
        echo "请输入有效的 IPv${family} ${kind}，不支持域名、回环或链路本地目标。" >&2
    done
}

prompt_port() {
    local prompt="$1"
    local default="${2:-}"
    local value

    while true; do
        if [[ -n "$default" ]]; then
            read_input "$prompt [$default]: " value # 交互: 输入端口；留空时使用默认端口。
            value="${value:-$default}"
        else
            read_input "$prompt: " value # 交互: 输入必须由用户指定的端口。
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

    read_input "$prompt [$default]: " value # 交互: 输入可覆盖自动检测值；留空使用默认值。
    echo "${value:-$default}"
}

normalize_ip() {
    local ip="$1"
    ip="${ip#\[}"
    ip="${ip%\]}"
    echo "$ip"
}

detect_ip_family() {
    ip_value family "$(normalize_ip "$1")"
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
    ip_value nat64 "$1" "$2"
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

    answer="$(prompt_choice "$prompt" "$default" "y Y yes YES n N no NO")" # 交互: 二次确认会改动系统配置或继续执行关键步骤。

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
    ip -o link show up | awk -F': ' '{split($2, name, "@"); if (name[1] != "lo") {print name[1]; exit}}'
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
    local path index=0 unit
    [[ -z "$TRANSACTION_DIR" ]] || die "已有未完成的配置事务。"
    mkdir -p "$STATE_DIR/backups"
    chmod 700 "$STATE_DIR" "$STATE_DIR/backups"
    TRANSACTION_DIR="$(mktemp -d "$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)-XXXXXX")"
    export_managed_rules iptables > "$TRANSACTION_DIR/live.v4"
    export_managed_rules ip6tables > "$TRANSACTION_DIR/live.v6"
    for path in "$PROXY_DIR" "$PROXY_SERVICE" "$RULES_RESTORE_SERVICE" \
        "$RULES_V4_FILE" "$RULES_V6_FILE" "$INSTALLED_SCRIPT" \
        /etc/iptables/rules.v4 /etc/iptables/rules.v6 \
        "$SYSCTL_V4_FILE" "$SYSCTL_V6_FILE" "$SYSCTL_PERF_FILE" "$@"; do
        printf '%s\t%s\n' "$index" "$path" >> "$TRANSACTION_DIR/files.tsv"
        [[ ! -e "$path" ]] || cp -a -- "$path" "$TRANSACTION_DIR/$index"
        index=$((index + 1))
    done
    sysctl -a 2>/dev/null | awk '/^net\.(ipv4|ipv6)\./ && /\.(ip_forward|forwarding|accept_ra|rp_filter) = /' > "$TRANSACTION_DIR/sysctl" || true
    for unit in a2b-forward-proxy.service a2b-forward-rules.service ${TRANSACTION_WG_UNIT:-}; do
        printf '%s\t%s\t%s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)" \
            "$(systemctl is-enabled "$unit" 2>/dev/null || true)" >> "$TRANSACTION_DIR/services.tsv"
    done
    # 快照完整落盘后才允许回滚，避免备份失败时误删尚未保存的文件。
    touch "$TRANSACTION_DIR/ready"
    info "本次改动的备份: $TRANSACTION_DIR"
}

commit_transaction() {
    printf '%s\tcommitted\t%s\n' "$(date -Is)" "$TRANSACTION_DIR" >> "$STATE_DIR/audit.tsv"
    TRANSACTION_DIR=""
    unset TRANSACTION_WG_UNIT
}

rollback_transaction() {
    local index path unit active enabled key value failed=0
    [[ -n "$TRANSACTION_DIR" && -f "$TRANSACTION_DIR/ready" ]] || return 0
    warn "应用未完成，正在恢复本次操作前的配置。"
    while IFS=$'\t' read -r unit active enabled; do
        [[ "$active" == active ]] || systemctl stop "$unit" >/dev/null 2>&1 || true
        [[ "$enabled" == enabled ]] || systemctl disable "$unit" >/dev/null 2>&1 || true
    done < "$TRANSACTION_DIR/services.tsv"
    while IFS=$'\t' read -r index path; do
        rm -rf -- "$path" || failed=1
        if [[ -e "$TRANSACTION_DIR/$index" ]]; then
            mkdir -p -- "${path%/*}"
            cp -a -- "$TRANSACTION_DIR/$index" "$path" || failed=1
        fi
    done < "$TRANSACTION_DIR/files.tsv"
    # ip_forward 改变可能重置其它 IPv4 设置，先还原它再还原接口值。
    value="$(awk '$1 == "net.ipv4.ip_forward" {print $3}' "$TRANSACTION_DIR/sysctl")"
    [[ -z "$value" ]] || sysctl -w "net.ipv4.ip_forward=$value" >/dev/null || failed=1
    while read -r key _ value; do
        sysctl -w "$key=$value" >/dev/null 2>&1 || failed=1
    done < "$TRANSACTION_DIR/sysctl"
    restore_family_rules iptables "$TRANSACTION_DIR/live.v4" || failed=1
    restore_family_rules ip6tables "$TRANSACTION_DIR/live.v6" || failed=1
    systemctl daemon-reload || failed=1
    while IFS=$'\t' read -r unit active enabled; do
        [[ "$enabled" != enabled ]] || systemctl enable "$unit" >/dev/null 2>&1 || failed=1
        if [[ "$active" == active && "$unit" != a2b-forward-rules.service ]]; then
            systemctl restart "$unit" || failed=1
        fi
    done < "$TRANSACTION_DIR/services.tsv"
    printf '%s\trollback=%s\t%s\n' "$(date -Is)" "$failed" "$TRANSACTION_DIR" >> "$STATE_DIR/audit.tsv"
    if (( failed )); then
        warn "回滚有失败项。请保留 SSH 会话，检查备份 $TRANSACTION_DIR 和 systemctl 状态。"
    else
        info "已恢复本次操作前的规则和配置。备份仍保留在 $TRANSACTION_DIR"
    fi
    TRANSACTION_DIR=""
    return "$failed"
}

on_exit() {
    local status="$?"
    trap - EXIT ERR
    set +e
    if [[ -n "$TRANSACTION_DIR" ]]; then
        rollback_transaction
        (( status != 0 )) || status=1
    fi
    exit "$status"
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
    local path iface value
    local settings=()

    if [[ "$family" == "4" ]]; then
        write_sysctl_file "$SYSCTL_V4_FILE" \
            "net.ipv4.ip_forward=1"
        apply_sysctl_file "$SYSCTL_V4_FILE"
        [[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]] || die "无法开启 IPv4 转发。"
        info "已开启 IPv4 转发；保持现有 rp_filter 策略。"
    else
        # IPv6 VPS 常依赖 RA 获取默认路由；forwarding=1 后 accept_ra=1 会停止续租。
        for path in /proc/sys/net/ipv6/conf/*/accept_ra; do
            [[ -r "$path" ]] || continue
            read -r value < "$path"
            iface="${path%/accept_ra}"
            iface="${iface##*/}"
            if [[ "$value" == 1 ]]; then
                settings+=("net/ipv6/conf/${iface}/accept_ra=2")
            fi
        done
        # 保留上一轮保存的 RA 设置，以便重复配置后仍可在重启时恢复。
        if [[ -f "$SYSCTL_V6_FILE" ]]; then
            while IFS= read -r value; do
                [[ "$value" != net/ipv6/conf/*/accept_ra=2 ]] || settings+=("$value")
            done < "$SYSCTL_V6_FILE"
        fi
        write_sysctl_file "$SYSCTL_V6_FILE" "${settings[@]}" "net.ipv6.conf.all.forwarding=1"
        apply_sysctl_file "$SYSCTL_V6_FILE"
        [[ "$(sysctl -n net.ipv6.conf.all.forwarding)" == 1 ]] || die "无法开启 IPv6 转发。"
        info "已开启 IPv6 转发。"
    fi
}

ensure_chain() {
    local cmd="$1"

    "$cmd" -w -t nat -S "$CHAIN_PRE" >/dev/null 2>&1 || "$cmd" -w -t nat -N "$CHAIN_PRE"
    "$cmd" -w -t nat -S "$CHAIN_POST" >/dev/null 2>&1 || "$cmd" -w -t nat -N "$CHAIN_POST"
    "$cmd" -w -S "$CHAIN_FWD" >/dev/null 2>&1 || "$cmd" -w -N "$CHAIN_FWD"

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

    "$cmd" -w -S "$CHAIN_INPUT" >/dev/null 2>&1 || "$cmd" -w -N "$CHAIN_INPUT"

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
        args+=(-p "$proto" --dport "$LOCAL_PORT" -m comment --comment "${TAG} map-${listen_family}-${proto}-${LOCAL_PORT}" -j ACCEPT)
        ensure_rule_append "$cmd" filter "$CHAIN_INPUT" "${args[@]}"
        # Nginx 的通配监听不绑定网卡；兜底拒绝避免其它 INPUT 放行规则绕过入口网卡限制。
        args=()
        [[ -n "$LISTEN_ADDR" ]] && args+=(-d "$LISTEN_ADDR")
        args+=(-p "$proto" --dport "$LOCAL_PORT" -m comment --comment "${TAG} map-${listen_family}-${proto}-${LOCAL_PORT}" -j DROP)
        ensure_rule_append "$cmd" filter "$CHAIN_INPUT" "${args[@]}"
    done
}

# 只导出拥有的四个链；--noflush 重建这些链时保留 UFW/Docker/管理员规则。
export_managed_rules() {
    local cmd="$1" rules
    rules="$("${cmd}-save")" || return 1
    printf '%s\n' "$rules" | awk '
        /^\*/ {table=substr($0,2)}
        $1 == "-A" && $2 ~ /^A2B_(INPUT|FORWARD|PREROUTING|POSTROUTING)$/ {body[table]=body[table] $0 "\n"}
        END {
            print "*filter\n:A2B_INPUT - [0:0]\n:A2B_FORWARD - [0:0]"
            printf "%s", body["filter"]
            print "COMMIT\n*nat\n:A2B_PREROUTING - [0:0]\n:A2B_POSTROUTING - [0:0]"
            printf "%s", body["nat"]
            print "COMMIT"
        }'
}

restore_family_rules() {
    local cmd="$1" file="$2"
    "${cmd}-restore" --wait 10 --noflush --test < "$file" || return 1
    "${cmd}-restore" --wait 10 --noflush < "$file" || return 1
    ensure_chain "$cmd" || return 1
    ensure_input_chain "$cmd"
}

restore_saved_rules() {
    [[ ! -s "$RULES_V4_FILE" ]] || restore_family_rules iptables "$RULES_V4_FILE"
    [[ ! -s "$RULES_V6_FILE" ]] || restore_family_rules ip6tables "$RULES_V6_FILE"
}

migrate_legacy_rules() {
    local file tmp
    for file in "$@"; do
        [[ -f "$file" ]] || continue
        if grep -Eq '^:A2B_|^-A A2B_|-j A2B_' "$file"; then
            tmp="$(mktemp "${file}.XXXXXX")"
            python3 - "$file" > "$tmp" <<'PY'
import shlex, sys
owned = {"A2B_INPUT", "A2B_FORWARD", "A2B_PREROUTING", "A2B_POSTROUTING"}
with open(sys.argv[1]) as source:
    for line in source:
        words = shlex.split(line)
        remove = bool(words and words[0].startswith(":") and words[0][1:] in owned)
        if words and words[0] == "-A":
            remove = remove or words[1] in owned
            if "-j" in words:
                remove = remove or words[words.index("-j") + 1] in owned
        if not remove:
            print(line, end="")
PY
            chmod --reference="$file" "$tmp"
            mv -f -- "$tmp" "$file"
            info "已从旧快照移除 A2B 条目，保留其它规则: $file"
        fi
    done
}

write_rules_restore_service() {
    mkdir -p "${INSTALLED_SCRIPT%/*}"
    if [[ "$SCRIPT_PATH" != "$INSTALLED_SCRIPT" ]]; then
        install -m 700 "$SCRIPT_PATH" "$INSTALLED_SCRIPT"
    fi
    cat > "$RULES_RESTORE_SERVICE" <<EOF
[Unit]
Description=A2B forwarding firewall rules restore
After=network-online.target ufw.service netfilter-persistent.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${INSTALLED_SCRIPT} --restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable a2b-forward-rules.service
}

save_rules() {
    local cmd file tmp
    mkdir -p /etc/iptables
    for cmd in iptables ip6tables; do
        file="$RULES_V4_FILE"
        [[ "$cmd" != ip6tables ]] || file="$RULES_V6_FILE"
        tmp="$(mktemp "${file}.XXXXXX")"
        export_managed_rules "$cmd" > "$tmp"
        "${cmd}-restore" --wait 10 --noflush --test < "$tmp"
        chmod 600 "$tmp"
        mv -f -- "$tmp" "$file"
    done
    migrate_legacy_rules /etc/iptables/rules.v4 /etc/iptables/rules.v6
    write_rules_restore_service
    info "A2B 规则已保存并启用开机恢复。当前内核规则已生效，恢复服务首次运行可在重启后显示 active (exited)。"
}

remove_mapping_rules() {
    local cmd="$1" family="$2" protocols="$3" tmp
    tmp="$(mktemp)"
    export_managed_rules "$cmd" > "$tmp"
    python3 - "$tmp" "$family" "$LOCAL_PORT" "$protocols" <<'PY'
import pathlib
import shlex
import sys

path, family, port, protocols = sys.argv[1:]
file = pathlib.Path(path)
result = []
for line in file.read_text().splitlines():
    words = shlex.split(line)
    comment = words[words.index("--comment") + 1] if "--comment" in words else ""
    remove = any(comment == f"a2b-forward map-{family}-{proto}-{port}"
                 or comment.startswith(f"a2b-forward {proto} {port}->")
                 or comment == f"a2b-forward proxy listen {proto} {port}"
                 for proto in protocols.split())
    if not remove:
        result.append(line)
file.write_text("\n".join(result) + "\n")
PY
    restore_family_rules "$cmd" "$tmp"
    rm -f "$tmp"
}

remove_mapping_proxy_files() {
    local family="$1" protocols="$2" proto file name
    [[ -d "$PROXY_CONF_DIR" ]] || return 0
    for proto in $protocols; do
        for file in "$PROXY_CONF_DIR"/*.conf; do
            name="${file##*/}"
            if [[ "$name" == "$family-4-$proto-"*"-$LOCAL_PORT.conf" || "$name" == "$family-6-$proto-"*"-$LOCAL_PORT.conf" ]]; then
                rm -f -- "$file"
            fi
        done
    done
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
    choice="$(prompt_choice "请输入选项" 1 "1 2 3 4")" # 交互: 选择同协议族 NAT 或跨协议族代理方案。

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
    echo "提示: SOCKS5 UDP ASSOCIATE 可能使用另一个动态端口；只转发 SOCKS5 TCP 端口不会自动支持 UDP。" >&2
    choice="$(prompt_choice "请输入协议" tcp "1 2 3 tcp TCP udp UDP both all BOTH ALL")" # 交互: 选择要转发的传输层协议。
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
    local ssh_connection="${SSH_CONNECTION:-}"

    LOCAL_PORT="$(prompt_port "${ENTRY_NODE_LABEL} 机器对外监听端口，也就是上一跳要连接的 ${ENTRY_NODE_LABEL} 端口")" # 交互: 设置当前入口机器暴露给上一跳访问的入口端口。
    [[ "$LOCAL_PORT" != "${ssh_connection##* }" ]] || die "入口端口与当前 SSH 端口相同，请换一个端口。"

    if [[ -n "${PRESET_TARGET_IP:-}" && -n "${PRESET_TARGET_PORT:-}" ]]; then
        TARGET_IP="$(normalize_ip "$PRESET_TARGET_IP")"
        TARGET_PORT="$PRESET_TARGET_PORT"
        info "已使用向导确定的 ${TARGET_NODE_LABEL} 目标: ${TARGET_IP}:${TARGET_PORT}"
    else
        if [[ "$target_family" == "6" ]]; then
            read_input "${TARGET_NODE_LABEL} 机器目标地址，可填 IPv6 或 [IPv6]:端口: " target_input # 交互: 输入下一跳机器的 IPv6 目标地址，可顺带写端口。
        else
            read_input "${TARGET_NODE_LABEL} 机器目标地址，可填 IPv4 或 IPv4:端口: " target_input # 交互: 输入下一跳机器的 IPv4 目标地址，可顺带写端口。
        fi

        parse_target_input "$target_family" "$target_input"
    fi
    [[ -n "$TARGET_IP" ]] || die "目标 IP 不能为空。"
    TARGET_IP="$(ip_value address "$TARGET_IP" "$target_family")" ||
        TARGET_IP="$(prompt_ip "目标地址无效，请重新输入 ${TARGET_NODE_LABEL} 的 IPv${target_family} 地址" address "$target_family")"

    if [[ -n "$TARGET_PORT" ]]; then
        if validate_port "$TARGET_PORT"; then
            TARGET_PORT="$((10#$TARGET_PORT))"
        else
            TARGET_PORT="$(prompt_port "目标端口无效，请重新输入 ${TARGET_NODE_LABEL} 端口")"
        fi
    else
        TARGET_PORT="$(prompt_port "${TARGET_NODE_LABEL} 机器目标服务端口，也就是本跳最终访问 ${TARGET_NODE_LABEL} 的端口")" # 交互: 设置本跳转发最终落到下一跳机器的端口。
    fi

    if ! route_line="$(get_route_line "$target_family" "$TARGET_IP")"; then
        if [[ "$engine" == "proxy" ]]; then
            die "${ENTRY_NODE_LABEL} 当前无法用 IPv${target_family} 到达 ${TARGET_NODE_LABEL} (${TARGET_IP})。跨 IPv4/IPv6 代理要求 ${ENTRY_NODE_LABEL} 具备目标协议族出口；否则需要 NAT64/464XLAT、VPN、隧道，或换一台双栈中转机。"
        fi
        die "${ENTRY_NODE_LABEL} 机器没有到 ${TARGET_NODE_LABEL} (${TARGET_IP}) 的 IPv${target_family} 路由。"
    fi
    [[ "$route_line" != local\ * ]] || die "目标地址属于本机；请填写下一跳地址，避免回环转发。"

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
            read_input "${ENTRY_NODE_LABEL} 监听 IP，留空表示该网卡所有 IPv${listen_family} 地址: " LISTEN_ADDR # 交互: 无法自动识别监听 IP 时手动填写。
        LISTEN_ADDR="$(normalize_ip "$LISTEN_ADDR")"
    fi
    if [[ -n "$LISTEN_ADDR" ]]; then
        LISTEN_ADDR="$(ip_value address "$LISTEN_ADDR" "$listen_family")" || die "监听地址无效。"
        iface_has_address "$listen_family" "$LISTEN_IF" "$LISTEN_ADDR" ||
            die "监听 IP 不在 $LISTEN_IF 上。云平台映射公网 IPv4 时，请填写机器实际网卡的内网 IP。"
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
        SNAT_SOURCE="$(ip_value address "$SNAT_SOURCE" "$target_family")" || die "SNAT 地址无效。"
        iface_has_address "$target_family" "$EGRESS_IF" "$SNAT_SOURCE" || die "SNAT 地址不属于所选出口网卡。"
    fi

    while true; do
        read_input "允许访问 ${ENTRY_NODE_LABEL}:${LOCAL_PORT} 的上一跳 IP/CIDR，留空允许所有来源（代理须已启用认证）: " ALLOWED_SOURCE # 交互: 只允许本地公网 IP 或上一跳机器 IP；CIDR 支持 /32、/128。
        [[ -n "$ALLOWED_SOURCE" ]] || break
        if ALLOWED_SOURCE="$(ip_value network "$ALLOWED_SOURCE" "$listen_family")"; then
            break
        fi
        warn "来源 IP/CIDR 无效或协议族不匹配，请重新填写。"
    done
}

iface_has_address() {
    local family="$1" iface="$2" address="$3"
    ip "-$family" -j addr show dev "$iface" | python3 -c '
import ipaddress, json, sys
target = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if any(ipaddress.ip_address(a["local"]) == target for i in json.load(sys.stdin) for a in i["addr_info"]) else 1)
' "$address"
}

probe_tcp() {
    python3 - "$1" "$2" <<'PY'
import socket
import sys
try:
    with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5):
        print("TCP 连接成功。此结果仅验证下一跳端口，不代表代理认证或网站访问成功。")
except OSError as exc:
    print(f"TCP 连接失败: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

preflight_mapping() {
    local family="$1" protocols="$2" engine="$3" proto sockets pid=0
    [[ ! -r "$PROXY_PID" ]] || read -r pid < "$PROXY_PID"
    for proto in $protocols; do
        sockets="$(ss "-$family" -H -lnp"${proto:0:1}" "sport = :$LOCAL_PORT")"
        if [[ -n "$sockets" ]]; then
            if ! printf '%s\n' "$sockets" | python3 -c '
import ipaddress, pathlib, re, sys
address, pid = sys.argv[1:]
def owned(candidate):
    if candidate == pid:
        return True
    try:
        # Nginx 优雅重载时旧 worker 可能暂时独自持有监听 socket。
        fields = pathlib.Path(f"/proc/{candidate}/stat").read_text().rsplit(")", 1)[1].split()
        return fields[1] == pid
    except (OSError, IndexError):
        return False
for line in sys.stdin:
    fields = line.split()
    local = fields[3].rsplit(":", 1)[0].strip("[]")
    relevant = not address or local in ("*", "0.0.0.0", "::") or ipaddress.ip_address(local) == ipaddress.ip_address(address)
    if relevant and not any(owned(p) for p in re.findall(r"pid=(\d+),", line)):
        sys.exit(1)
' "$LISTEN_ADDR" "$pid"; then
                die "$LOCAL_PORT/$proto 的监听地址已被其它本机服务占用，请换入口端口或地址。"
            fi
        fi
    done
    if [[ " $protocols " == *" tcp "* ]]; then
        if ! probe_tcp "$TARGET_IP" "$TARGET_PORT"; then
            confirm_yes_no "下一跳未连接成功。是否仍仅保存转发配置，稍后修复 B/安全组/隧道" N || die "已取消，请先确认下一跳服务。" # 交互: 连接失败默认停止，显式确认才允许保存待部署配置。
        fi
    else
        info "UDP 无通用握手，本次不会把路由可达当成 UDP 服务已通过。请用实际客户端验证。"
    fi
    if [[ "$engine" == proxy && " $protocols " == *" udp "* ]]; then
        while true; do
            UDP_TIMEOUT="$(prompt_default "UDP 空闲会话超时（秒），游戏长会话可用 300；持续传输不受影响" 60)" # 交互: 释放空闲 UDP 会话，避免一小时占用连接与内存。
            [[ "$UDP_TIMEOUT" =~ ^[0-9]{1,4}$ ]] && (( 10#$UDP_TIMEOUT >= 10 && 10#$UDP_TIMEOUT <= 3600 )) && break
            warn "请填写 10 到 3600 秒。"
        done
        UDP_TIMEOUT="$((10#$UDP_TIMEOUT))"
    fi
}

wait_proxy_ready() {
    local family="$1" protocols="$2" proto pid=0 attempt ready
    for ((attempt = 0; attempt < 30; attempt++)); do
        ready=1
        [[ ! -r "$PROXY_PID" ]] || read -r pid < "$PROXY_PID"
        for proto in $protocols; do
            if ! ss "-$family" -H -lnp"${proto:0:1}" "sport = :$LOCAL_PORT" | grep -F "pid=$pid," >/dev/null; then
                ready=0
            fi
        done
        (( ready )) && return 0
        sleep 0.1
    done
    die "Nginx 未能建立预期监听，请检查 $PROXY_LOG_DIR/error.log。"
}

confirm_config() {
    local mode="$1"
    local protocols="$2"
    local listen_family="$3"
    local target_family="$4"
    local engine="$5"
    local shown_listen_addr="${LISTEN_ADDR:-所有本机 IPv${listen_family} 地址}"
    local shown_source="${ALLOWED_SOURCE:-所有来源}"

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

    echo "同入口协议族、端口和 TCP/UDP 的已有映射会被替换；未选择的协议保持原样。已有 NAT 连接沿用旧 conntrack；跨引擎切换可能中断旧代理连接，请重连客户端。"
    confirm_yes_no "确认写入配置" Y || die "已取消。" # 交互: 展示完整参数和更新范围后才写入。
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
        comment="${TAG} map-${family}-${proto}-${LOCAL_PORT}"

        pre_args=(-i "$LISTEN_IF" -m addrtype --dst-type LOCAL)
        [[ -n "$ALLOWED_SOURCE" ]] && pre_args+=(-s "$ALLOWED_SOURCE")
        [[ -n "$LISTEN_ADDR" ]] && pre_args+=(-d "$LISTEN_ADDR")
        pre_args+=(-p "$proto" --dport "$LOCAL_PORT" -m comment --comment "$comment" -j DNAT --to-destination "$dnat_target")
        ensure_rule_append "$cmd" nat "$CHAIN_PRE" "${pre_args[@]}"

        post_args=(-o "$EGRESS_IF")
        [[ -n "$ALLOWED_SOURCE" ]] && post_args+=(-s "$ALLOWED_SOURCE")
        post_args+=(-p "$proto" -d "$TARGET_IP" --dport "$TARGET_PORT" -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigdstport "$LOCAL_PORT" -m comment --comment "$comment" -j SNAT --to-source "$SNAT_SOURCE")
        ensure_rule_append "$cmd" nat "$CHAIN_POST" "${post_args[@]}"

        fwd_new_args=(-i "$LISTEN_IF" -o "$EGRESS_IF")
        [[ -n "$ALLOWED_SOURCE" ]] && fwd_new_args+=(-s "$ALLOWED_SOURCE")
        fwd_new_args+=(-p "$proto" -d "$TARGET_IP" --dport "$TARGET_PORT" -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigdstport "$LOCAL_PORT" -m comment --comment "$comment" -j ACCEPT)
        ensure_rule_append "$cmd" filter "$CHAIN_FWD" "${fwd_new_args[@]}"

        fwd_reply_args=(-i "$EGRESS_IF" -o "$LISTEN_IF" -p "$proto" -s "$TARGET_IP" --sport "$TARGET_PORT" -m conntrack --ctstate DNAT --ctdir REPLY --ctorigdstport "$LOCAL_PORT" -m comment --comment "$comment" -j ACCEPT)
        ensure_rule_append "$cmd" filter "$CHAIN_FWD" "${fwd_reply_args[@]}"
        # 允许属于本映射的 ICMP 错误回包，让路径 MTU 发现可以工作。
        ensure_rule_append "$cmd" filter "$CHAIN_FWD" -p "$([[ "$family" == 4 ]] && echo icmp || echo ipv6-icmp)" \
            -m conntrack --ctstate RELATED --ctorigdstport "$LOCAL_PORT" \
            -m comment --comment "$comment" -j ACCEPT
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
After=network-online.target a2b-forward-rules.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${nginx_bin} -c ${PROXY_CONF} -g 'daemon off;'
ExecReload=${nginx_bin} -c ${PROXY_CONF} -s reload
KillSignal=SIGQUIT
TimeoutStopSec=15
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
            if [[ "$proto" == udp ]]; then
                echo "    proxy_timeout ${UDP_TIMEOUT}s;"
            else
                echo "    proxy_timeout 1h;"
                echo "    proxy_socket_keepalive on;"
            fi
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
        systemctl reload a2b-forward-proxy.service
    else
        systemctl enable --now a2b-forward-proxy.service
    fi
    systemctl is-active --quiet a2b-forward-proxy.service || die "代理服务未运行。"
    wait_proxy_ready "$listen_family" "$protocols"
    info "跨协议族代理服务已启用: a2b-forward-proxy.service"
}

remove_proxy_config() {
    if command -v systemctl >/dev/null 2>&1 && [[ -f "$PROXY_SERVICE" ]]; then
        systemctl disable --now a2b-forward-proxy.service >/dev/null 2>&1 || true
    fi

    if [[ -d "$PROXY_CONF_DIR" ]]; then
        find "$PROXY_CONF_DIR" -type f -name '*.conf' -delete
    fi
    rm -f "$PROXY_CONF" "$PROXY_SERVICE"
    systemctl daemon-reload
    info "已删除本脚本管理的跨协议族代理配置。"
}

remove_rules_restore_service() {
    if command -v systemctl >/dev/null 2>&1 && [[ -f "$RULES_RESTORE_SERVICE" ]]; then
        systemctl disable --now a2b-forward-rules.service >/dev/null 2>&1 || true
        rm -f "$RULES_RESTORE_SERVICE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    rm -f "$RULES_V4_FILE" "$RULES_V6_FILE" "$INSTALLED_SCRIPT"
    info "已删除本脚本管理的防火墙规则恢复服务。"
}

remove_wireguard_config() {
    local file
    local base
    local iface

    if [[ ! -d "$WG_EXPORT_DIR" ]] || ! compgen -G "${WG_EXPORT_DIR}/*-B.conf" >/dev/null; then
        return
    fi

    for file in "${WG_EXPORT_DIR}"/*-B.conf; do
        base="$(basename "$file")"
        iface="${base%-B.conf}"
        [[ "$iface" =~ ^[A-Za-z][A-Za-z0-9_-]{0,14}$ ]] || die "异常接口名，停止删除: $iface"
        TRANSACTION_WG_UNIT="wg-quick@${iface}.service"
        backup_rules "${WG_DIR}/${iface}.conf" "$file"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable --now "wg-quick@${iface}.service" >/dev/null 2>&1 || true
        else
            wg-quick down "$iface" >/dev/null 2>&1 || true
        fi
        rm -f "${WG_DIR}/${iface}.conf" "$file"
        commit_transaction
    done

    rmdir "$WG_EXPORT_DIR" 2>/dev/null || true
    info "已停用并删除本脚本生成的 WireGuard 配置。"
}

remove_managed_rules() {
    local keep_wg=0 port file
    confirm_yes_no "删除所有 A2B 端口映射和跨族代理？将中断这些转发连接" N || return 0 # 交互: 删除前说明连接影响，默认保留。
    if [[ -d "$WG_EXPORT_DIR" ]] && compgen -G "$WG_EXPORT_DIR/*-B.conf" >/dev/null; then
        confirm_yes_no "保留本脚本生成的 WireGuard 隧道及其握手端口" Y && keep_wg=1 # 交互: 保留隧道时同步保留 UDP 防火墙入口和持久化。
    fi
    backup_rules
    remove_managed_rules_for_cmd iptables
    remove_managed_rules_for_cmd ip6tables
    migrate_legacy_rules /etc/iptables/rules.v4 /etc/iptables/rules.v6
    remove_proxy_config
    rm -f "$SYSCTL_V4_FILE" "$SYSCTL_V6_FILE" "$SYSCTL_PERF_FILE"
    if (( keep_wg )); then
        for file in "$WG_EXPORT_DIR"/*-B.conf; do
            file="${WG_DIR}/${file##*/}"
            file="${file%-B.conf}.conf"
            port="$(awk '$1 == "ListenPort" {print $3}' "$file")"
            validate_port "$port" || die "无法读取保留隧道的监听端口。"
            allow_wireguard_input "$port"
        done
        save_rules
    else
        remove_rules_restore_service
    fi
    commit_transaction
    if (( keep_wg == 0 )); then
        remove_wireguard_config
    fi
    info "已删除本脚本管理的 NAT 规则和代理配置。"
    info "已删除本脚本 sysctl 持久化文件；当前转发开关保持不变，以免中断其它路由服务。备份保留于 $STATE_DIR/backups。"
}

prompt_required() {
    local prompt="$1"
    local value

    while true; do
        read_input "$prompt: " value # 交互: 输入必填值，空值会导致后续配置无法生成。
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
    echo "1. 新手向导: B 已有代理，A 做入口；自动按协议族选择转发引擎。" >&2
    echo "2. 高级: 只配置 A 到 B 任意端口转发，不额外处理 WireGuard。" >&2
    echo "3. 只创建 A-B WireGuard 隧道配置，不添加入口端口转发。" >&2
    echo "4. 链式代理: 本地 -> C -> A -> B，分步骤配置 C->A 和 A->B。" >&2
    choice="$(prompt_choice "请输入选项" 1 "1 2 3 4")" # 交互: 选择整体工作流，推荐选 1 以保证最终由 B 访问目标网站。

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
    choice="$(prompt_choice "请输入选项" 1 "1 2 4 6")" # 交互: 选择当前入口机器对外暴露入口时使用 IPv4 还是 IPv6。

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
    choice="$(prompt_choice "请输入选项" 1 "1 2 4 6")" # 交互: 选择当前入口机器到下一跳机器的目标地址协议族。

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
    echo "2. 新建 WireGuard：加密 A-B 链路；需要你在 B 部署导出的配置，底层 UDP 必须可达。" >&2
    echo "3. 直接路由（首次建议）：B 已有加密代理时最易上手，无额外隧道开销。" >&2
    echo "4. 已有 NAT64：生成 /96 合成 IPv6 地址；不安装 NAT64/CLAT 网关。" >&2
    echo "5. 双栈中转：本机 -> 中转 R -> B，先在 R 配好 R->B 再填写 R 的入口。" >&2
    echo "提示: WireGuard 不提供中继，不能让无共同可达底层的 v4-only/v6-only 两端直接互通。已有 CLAT 请选 3 填 B 的 IPv4。" >&2
    choice="$(prompt_choice "请输入选项" 3 "1 2 3 4 5")" # 交互: 首次默认直接路由，已确认加密需求与 UDP 可达时选择 WireGuard。

    case "${choice:-3}" in
        1) echo "existing_wg" ;;
        2) echo "new_wg" ;;
        3) echo "direct_route" ;;
        4) echo "nat64_464xlat" ;;
        5)
            echo "relay"
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
    [[ "$iface" =~ ^[A-Za-z][A-Za-z0-9_-]{0,14}$ ]] || die "接口名须以字母开头，最多 15 个字母/数字/下划线/短横线。"
    [[ ! -e "$WG_DIR/$iface.conf" && ! -e "$WG_EXPORT_DIR/$iface-B.conf" ]] ||
        die "接口配置已存在。请使用已有 WireGuard 模式，或输入新接口名；覆盖密钥会断开 B。"
    if ip link show dev "$iface" >/dev/null 2>&1; then
        die "接口已存在，请使用新名称。"
    fi
    listen_port="$(prompt_port "A WireGuard UDP 监听端口，B 会连接这个端口" "51820")" # 交互: 设置 A 上 WireGuard 握手端口。
    [[ -z "$(ss -H -lnu "sport = :$listen_port")" ]] || die "WireGuard UDP 端口已占用，请换端口。"
    a_ipv4_cidr="$(prompt_ip "A WireGuard IPv4 地址/CIDR" interface 4 "10.66.66.1/32")" # 交互: /32 避免抢占整段现有内网路由。
    b_ipv4_cidr="$(prompt_ip "B WireGuard IPv4 地址/CIDR" interface 4 "10.66.66.2/32")" # 交互: 对端仅路由本隧道地址。
    a_ipv6_cidr="$(prompt_ip "A WireGuard IPv6 地址/CIDR" interface 6 "fd66:66:66::1/128")" # 交互: /128 避免抢占已有 ULA 子网。
    b_ipv6_cidr="$(prompt_ip "B WireGuard IPv6 地址/CIDR" interface 6 "fd66:66:66::2/128")" # 交互: 入口 IPv6 时可直接 NAT 到 B 的 IPv6 隧道地址。
    mtu="$(prompt_default "WireGuard MTU，常见公网/VPS 推荐 1420" "1420")" # 交互: 设置 WireGuard MTU，路径不稳定时可降低到 1380。
    if [[ ! "$mtu" =~ ^[0-9]{4}$ ]] || (( 10#$mtu < 1280 || 10#$mtu > 9000 )); then
        die "双栈 WireGuard MTU 必须在 1280 到 9000 之间。"
    fi
    mtu="$((10#$mtu))"
    echo "提示: B 必须能访问你接下来填写的 A 公网地址；IPv4-only 的 B 不能直连只有 IPv6 的 A，反之亦然。"
    a_endpoint="$(prompt_required "B 连接 A 使用的公网地址/IP/DDNS，不要带端口")" # 交互: 设置写入 B 配置的 A 公网 Endpoint。
    a_endpoint="$(ip_value endpoint "$(normalize_ip "$a_endpoint")")" || die "Endpoint 必须为有效 IP 或域名，不要带端口或配置文本。"

    a_ipv4="$(strip_cidr "$a_ipv4_cidr")"
    b_ipv4="$(strip_cidr "$b_ipv4_cidr")"
    a_ipv6="$(strip_cidr "$a_ipv6_cidr")"
    b_ipv6="$(strip_cidr "$b_ipv6_cidr")"
    [[ "$a_ipv4" != "$b_ipv4" && "$a_ipv6" != "$b_ipv6" ]] || die "A 和 B 的隧道地址不能相同。"
    for endpoint in "$a_ipv4" "$b_ipv4" "$a_ipv6" "$b_ipv6"; do
        if [[ "$(ip route get "$endpoint" 2>/dev/null || true)" == local\ * ]]; then
            die "隧道地址 $endpoint 已属于本机，请换一组隧道地址。"
        fi
    done

    [[ "$(detect_ip_family "$a_ipv4")" == "4" ]] || die "A WireGuard IPv4 地址无效: $a_ipv4"
    [[ "$(detect_ip_family "$b_ipv4")" == "4" ]] || die "B WireGuard IPv4 地址无效: $b_ipv4"
    [[ "$(detect_ip_family "$a_ipv6")" == "6" ]] || die "A WireGuard IPv6 地址无效: $a_ipv6"
    [[ "$(detect_ip_family "$b_ipv6")" == "6" ]] || die "B WireGuard IPv6 地址无效: $b_ipv6"

    a_conf="${WG_DIR}/${iface}.conf"
    b_conf="${WG_EXPORT_DIR}/${iface}-B.conf"
    echo "将新建 $iface，A 监听 UDP $listen_port；B 必须能访问 $a_endpoint。"
    echo "A 隧道: $a_ipv4_cidr / $a_ipv6_cidr；B 隧道: $b_ipv4_cidr / $b_ipv6_cidr；MTU: $mtu"
    confirm_yes_no "确认生成密钥、写入并启动 A 端 WireGuard" Y || die "已取消。" # 交互: 所有参数显示后才创建接口。
    TRANSACTION_WG_UNIT="wg-quick@${iface}.service"
    backup_rules "$a_conf" "$b_conf"

    keypair="$(wg_make_keypair)"
    a_private="$(sed -n '1p' <<< "$keypair")"
    a_public="$(sed -n '2p' <<< "$keypair")"
    keypair="$(wg_make_keypair)"
    b_private="$(sed -n '1p' <<< "$keypair")"
    b_public="$(sed -n '2p' <<< "$keypair")"

    mkdir -p "$WG_DIR" "$WG_EXPORT_DIR"
    chmod 700 "$WG_EXPORT_DIR"
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
    commit_transaction

    WG_B_IPV4="$b_ipv4"
    WG_B_IPV6="$b_ipv6"

    echo
    echo "WireGuard A 端已配置并尝试启动: ${a_conf}"
    echo "B 端配置已生成: ${b_conf}"
    echo "A 端启动不代表隧道已经连通。请完成以下 B 端操作后再验证:"
    echo "  1. 在 B 安装: sudo apt-get update && sudo apt-get install -y wireguard-tools"
    echo "  2. 用 scp/SFTP 传送 ${b_conf}，放到 B 的 /etc/wireguard/${iface}.conf（文件含私钥，不要公开）"
    echo "  3. 在 B 执行: sudo chmod 600 /etc/wireguard/${iface}.conf"
    echo "  sudo systemctl enable --now wg-quick@${iface}"
    echo "  4. 云安全组和 A 本机防火墙需允许 UDP ${listen_port}；B 执行 sudo wg show ${iface} 确认 latest handshake。"
    echo "  隧道只路由两端内网地址，B 访问网站仍使用 B 原有出口。"
    echo "B 上代理程序建议监听 ${b_ipv4}:${TARGET_PORT:-代理端口} 或 ${b_ipv6}:${TARGET_PORT:-代理端口}，也可以监听 0.0.0.0/::。不要只监听 127.0.0.1。"
    echo
}

choose_b_proxy_target_from_existing_wg() {
    local target_ip

    target_ip="$(prompt_required "请输入 B 的 WireGuard 内网 IP，例如 10.66.66.2 或 fd66:66:66::2")" # 交互: 指定 A 通过隧道访问 B 代理时使用的 B 内网地址。
    target_ip="$(normalize_ip "$target_ip")"
    TARGET_FAMILY="$(detect_ip_family "$target_ip")" || die "无法判断 B WireGuard 地址协议族: $target_ip"
    local route iface
    route="$(get_route_line "$TARGET_FAMILY" "$target_ip")" || die "B 隧道地址没有路由。"
    iface="$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1);exit}}' <<< "$route")"
    if ! command -v wg >/dev/null 2>&1 || ! wg show "$iface" >/dev/null 2>&1; then
        die "B 地址的出口不是 WireGuard 接口 ($iface)。请检查隧道路由，或选择直接路由模式。"
    fi
    info "已确认通过 WireGuard 接口 $iface 路由到 B；握手和代理端口还需检查。"
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
    echo "  注意: 有 IPv6 默认路由不等于有 NAT64。后续 TCP 探测只验证端口；UDP 要用实际应用测试。"
    echo

    b_ipv4="$(prompt_required "请输入 B 的 IPv4 地址，不要带端口")" # 交互: 指定 IPv4-only 的 B 地址，用于生成 NAT64 合成 IPv6 地址。
    b_ipv4="$(normalize_ip "$b_ipv4")"
    [[ "$(detect_ip_family "$b_ipv4" 2>/dev/null || true)" == "4" ]] || die "B 地址不是有效 IPv4: $b_ipv4"

    prefix="$(prompt_default "NAT64 /96 前缀，常见公网前缀是 64:ff9b::/96" "64:ff9b::/96")" # 交互: 指定上游 NAT64 前缀；不同运营商或自建网关可能不同。
    nat64_ip="$(nat64_addr_from_prefix "$prefix" "$b_ipv4")" || die "需要有效且主机位为零的 IPv6 /96 前缀。其它长度不受支持。"
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

    [[ "$engine" != proxy ]] || install_proxy_dependencies
    backup_rules
    cmd="iptables"
    [[ "$listen_family" != 6 ]] || cmd="ip6tables"
    remove_mapping_rules "$cmd" "$listen_family" "$protocols"
    remove_mapping_proxy_files "$listen_family" "$protocols"
    # 停止重写全局缓冲区/连接回收值；旧版文件移除，运行值不臆测复原。
    if [[ -f "$SYSCTL_PERF_FILE" ]]; then
        rm -f "$SYSCTL_PERF_FILE"
        info "已移除旧版通用性能 sysctl 文件；当前运行值保留，避免覆盖其它调优。"
    fi

    if [[ "$engine" == "nat" ]]; then
        cmd="iptables"
        [[ "$target_family" == "6" ]] && cmd="ip6tables"
        configure_sysctl "$target_family"
        add_nat_rules "$target_family" "$cmd" "$protocols"
        if [[ -f "$PROXY_CONF" ]]; then
            if compgen -G "$PROXY_CONF_DIR/*.conf" >/dev/null; then
                nginx -t -c "$PROXY_CONF"
                if systemctl is-active --quiet a2b-forward-proxy.service; then
                    systemctl reload a2b-forward-proxy.service
                fi
            else
                remove_proxy_config
            fi
        fi
        save_rules
    else
        write_proxy_mapping "$listen_family" "$target_family" "$protocols"
        allow_proxy_input "$listen_family" "$protocols"
        save_rules
    fi
    commit_transaction

    echo
    echo "转发配置已应用。上一跳入口: ${ENTRY_NODE_LABEL}:${LOCAL_PORT}"
    echo "实际转发目标: ${TARGET_NODE_LABEL}:${TARGET_IP}:${TARGET_PORT}"
    echo "持久化: 防火墙规则由 a2b-forward-rules.service 开机恢复；跨协议族代理由 a2b-forward-proxy.service 常驻；WireGuard 由 wg-quick@接口名托管。"
    echo "请在上一跳/本地客户端验证，不能用本机连接自己的 NAT 入口代替测试（本脚本不改 OUTPUT）。"
    echo "客户端仅替换服务器地址和端口，协议、密码、TLS SNI/证书域名保留 B 的配置。"
    echo "云安全组须开放入口 $LOCAL_PORT/$protocols；最终是否成功请以真实代理访问及出口地址为准。"
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
    preflight_mapping "$listen_family" "$protocols" "$engine"
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
    echo "  3. B 已有加密代理时可直接转发；需保护 A-B 明文流量时可选 WireGuard（底层 UDP 必须可达）。"
    echo "  4. 无共同地址族时需双栈中转；NAT64/CLAT 只在网络已提供转换能力时适用。"
    echo

    if ! confirm_yes_no "B 上的代理程序是否已经安装并监听端口" "Y"; then # 交互: 检查 B 侧准备条件，避免把端口转发误当成安装代理。
        warn "脚本运行在 A 上，无法直接安装 B 的代理程序。请先在 B 上安装 SOCKS5/HTTP/sing-box/Xray/Squid 等代理，并让它监听 WireGuard 内网 IP 或 0.0.0.0/::。"
        if ! confirm_yes_no "是否仍继续生成 A 侧转发/隧道配置" "N"; then # 交互: B 未就绪时默认取消，可显式准备 A 的配置。
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
        relay)
            show_relay_guide
            confirm_yes_no "中转 R 到 B 已经配置并测试完成" N || die "请先在 R 配置到 B 的转发，再回到本机。" # 交互: 确认下游链路先完成，当前目标随后填写 R 的入口。
            TARGET_NODE_LABEL="中转R"
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
    preflight_mapping "$listen_family" "$protocols" "$engine"
    confirm_config "b-proxy-${transport}" "$protocols" "$listen_family" "$target_family" "$engine"
    apply_current_mapping "$engine" "$listen_family" "$target_family" "$protocols"

    echo
    echo "B 侧代理检查建议:"
    echo "  最终 B 的代理应监听可被上一跳访问的地址，且启用认证；只监听 127.0.0.1 无法从远端转发。"
    echo "  你的客户端代理地址应填写 A 的入口地址和端口，即 A:${LOCAL_PORT}。"
}

show_chain_deploy_guide() {
    echo
    echo "链式代理部署顺序:"
    echo "  目标拓扑: 本地客户端 -> C -> A -> B -> 目标网站"
    echo "  第 1 步: 在 B 上安装并启动代理程序，让 B 用自己的网络访问目标网站。"
    echo "  第 2 步: 在 A 上运行本脚本，选择新手向导，完成 A -> B。"
    echo "  第 3 步: 记住 A 的入口端口；在 C 上运行本脚本，选择链式代理，再选择当前机器是 C，完成 C -> A。"
    echo "  第 4 步: 本地客户端只需要连接 C 的入口地址和端口。"
    echo
    echo "性能建议:"
    echo "  1. WireGuard 提供加密但不保证改善丢包或带宽；已有加密协议可直接转发。"
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
    preflight_mapping "$listen_family" "$protocols" "$engine"
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
    role="$(prompt_choice "请输入选项" 1 "1 2 3")" # 交互: 选择链式代理中当前机器的角色，避免把 C->A 和 A->B 配反。

    case "${role:-1}" in
        1)
            prepare_changes
            ENTRY_NODE_LABEL="A"
            TARGET_NODE_LABEL="B"
            add_b_proxy_workflow
            ;;
        2)
            prepare_changes
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
        b_proxy) prepare_changes; add_b_proxy_workflow ;;
        advanced_forward) prepare_changes; add_advanced_mapping ;;
        wireguard_only) prepare_changes; setup_wireguard_only ;;
        chain_proxy) add_chain_workflow ;;
        *) die "未知工作流: $workflow" ;;
    esac
}

show_relay_guide() {
    echo
    echo "双栈中转步骤（支持保留原来的 A）:"
    echo "  路径: 本地 -> A -> 双栈 R -> B -> 网站；也可前置 C，逐跳配置。"
    echo "  1. 先在 R 运行脚本，配置 R 的入口端口 -> B 的代理地址和端口。"
    echo "  2. 在 A 运行脚本，目标填写 A 能访问的 R 地址，以及步骤 1 的 R 入口端口。"
    echo "  3. A 是 v4-only 时填写 R 的 IPv4，B 是 v6-only 时 R 到 B 选择 IPv6；反向同理。"
    echo "  4. R 限制来源为 A，A 限制来源为本地或 C；B 继续运行最终代理。"
    echo "  内层 WireGuard 可以通过这样的 UDP 中转传输，但要先验证整条 UDP 路径与 MTU。"
    echo
}

acquire_lock() {
    exec 9>/run/lock/a2b-forward.lock
    flock -n 9 || die "另一份 A2B 配置/恢复操作正在运行，请稍后重试。"
}

prepare_changes() {
    need_systemd
    acquire_lock
    install_base_dependencies
}

diagnose() {
    local family address port action
    echo "只读诊断（不会安装依赖或修改配置）"
    for action in ip iptables ip6tables nginx wg python3; do
        if command -v "$action" >/dev/null 2>&1; then
            echo "  $action: 已安装"
        else
            echo "  $action: 未安装（nginx 仅跨族需要，wg 仅隧道需要）"
        fi
    done
    if command -v ip >/dev/null 2>&1; then
        ip -br address
        ip -4 route show default
        ip -6 route show default
    fi
    for action in net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max; do
        sysctl "$action" 2>/dev/null || true
    done
    if command -v wg >/dev/null 2>&1; then
        wg show all latest-handshakes
        wg show all transfer
    fi
    show_managed_rules
    echo "UFW/firewalld/容器防火墙重载后，专属链的跳转可能需要恢复: sudo systemctl restart a2b-forward-rules"
    echo "0 表示尚无 WireGuard 握手；路由、TCP 可达与代理成功是三种不同检查。"
    action="$(prompt_choice "是否额外探测一个目标 TCP 端口？1=探测，0=结束" 0 "0 1")" # 交互: 诊断默认不发网络探测；可单独验证下一跳端口。
    if [[ "$action" == 1 ]]; then
        command -v python3 >/dev/null 2>&1 || die "TCP 诊断需要 python3。"
        family="$(choose_direct_target_family)"
        address="$(prompt_ip "目标 IP" address "$family")"
        port="$(prompt_port "目标 TCP 端口")"
        probe_tcp "$address" "$port"
    fi
}

main_menu() {
    local action

    echo "A -> B 端口转发配置脚本 v${SCRIPT_VERSION}"
    echo "先在 B 准备带认证的代理，再在 A 配置；所有业务端口由你填写。"
    echo "1. 添加/更新配置（推荐向导会把代理放在 B，A 做入口）"
    echo "   也支持链式代理：本地 -> C -> A -> B"
    echo "2. 查看本脚本管理的 NAT、跨族代理、WireGuard 导出配置"
    echo "3. 删除本脚本管理的 NAT/跨族代理配置，并可选择删除 WireGuard"
    echo "4. 只读诊断：服务、路由、WireGuard 握手和可选 TCP 探测"
    echo "5. 查看双栈中转步骤（不修改系统）"
    echo "0. 退出"
    action="$(prompt_choice "请选择操作" 1 "0 1 2 3 4 5")" # 交互: 查看/诊断/说明不会安装依赖；只有添加、删除才修改系统。

    case "${action:-1}" in
        1) add_mapping ;;
        2) show_managed_rules ;;
        3) prepare_changes; remove_managed_rules ;;
        4) diagnose ;;
        5) show_relay_guide ;;
        0) return ;;
        *) die "无效选择: $action" ;;
    esac
}

main() {
    if [[ "${1:-}" == --help ]]; then
        echo "用法: sudo bash iptables_Forward.sh [--status | --diagnose | --restore]"
        echo "无参数进入中文交互向导。仅支持有 systemd 的 Linux；不要 curl | bash。"
        return
    fi
    need_root
    umask 077
    trap 'echo "错误: 第 ${LINENO} 行执行失败（不输出命令内容，避免泄露密钥）。" >&2' ERR
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    case "${1:-}" in
        "") main_menu ;;
        --status) show_managed_rules ;;
        --diagnose) diagnose ;;
        --restore) acquire_lock; restore_saved_rules ;;
        *) die "未知参数，请使用 --help。" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
