# a2b-forward

[![Linux verification](https://github.com/Borisgohard/a2b-forward/actions/workflows/verify.yml/badge.svg?branch=main)](https://github.com/Borisgohard/a2b-forward/actions/workflows/verify.yml)

中文交互式 Linux 端口转发工具。你连接 A，由 A 把流量送到 **B 上已有的代理程序**，最后由 B 访问网站。

```text
本地客户端 -> A 入口端口 -> B 代理端口 -> 目标网站
```

支持 IPv4/IPv6、WireGuard、双栈中转，以及 `本地 -> C -> A -> B`。TCP/UDP 端口均由你输入，没有固定的 555、444。

**先记住三件事：代理程序装在 B；脚本运行在 A 或 C 等转发节点；本地客户端连接最前面的入口。** 本脚本不自动安装 sing-box/Xray 等最终代理，也不会更改 B 的网站出口。

## 从这里开始

| 你的情况 | 下一步 |
| --- | --- |
| B 已有可用代理，只想借 A 改善线路 | 按下面的「五步跑通」操作 |
| B 还没有代理，想从零开始 | 按 [从零搭建加密代理，可选 WireGuard](docs/BEGINNER.md) 操作 |
| A 和 B 分别只有公网 IPv4、IPv6 | 先看「跨 IPv4 / IPv6」，准备双栈中转 R |
| 还要再加一个入口 C | 先完成 A -> B，再看「增加 C」 |

支持有 **systemd、Bash、Linux netfilter** 的 Debian/Ubuntu VPS。自动安装依赖使用 `apt-get`；CI 实测环境为 Ubuntu 22.04 和 24.04。Windows、普通 Docker 容器和无网络管理权限的受限容器不属于部署目标。

## 五步跑通

### 1. 准备好这些信息

| 填写项 | 是什么意思 | 仅供理解的例子 |
| --- | --- | --- |
| A 的地址 | 本地能连接的入口机器地址 | A 的公网 IPv4 |
| A 的入口端口 | 本地客户端将连接这个端口，自行选空闲端口 | `18080` |
| B 的地址 | **A 能访问到的** B 地址，可以是公网或隧道 IP | B 的公网 IPv4 |
| B 的代理端口 | B 上的代理程序真正监听的端口 | `1080` |
| 代理类型和认证 | 沿用 B 的 SOCKS5/HTTP/sing-box/Xray 等配置 | SOCKS5 用户名、密码 |
| 允许来源 | 谁能访问 A，通常填本地公网 IP 或 C 的 IP | 单个 IPv4 用 `/32`，IPv6 用 `/128` |

B 的服务应监听 A 可访问的地址，不能只监听 `127.0.0.1`。在 B 执行 `sudo ss -lntup` 可以检查。B 的防火墙和云安全组也要允许 A 访问代理端口。公网链路应使用带加密的代理协议，或先建立 WireGuard；SOCKS5 用户名/密码本身不加密流量。

### 2. 登录 A 并下载脚本

用你的 SSH 软件登录 **A**，然后执行：

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -fL --retry 3 https://raw.githubusercontent.com/Borisgohard/a2b-forward/main/iptables_Forward.sh -o iptables_Forward.sh
sudo bash iptables_Forward.sh
```

这是交互式脚本，必须先下载再运行。不要使用 `curl ... | bash`，否则标准输入被脚本内容占用，菜单无法正常输入。以后直接执行最后一行即可再次管理。

### 3. 按这个顺序选择

以下路径适用于 **B 已有加密代理，A 能直接访问 B**：

```text
主菜单：1  添加/更新
配置目标：1  新手向导
B 代理已安装并监听：Y
端口协议：1  TCP（先查看你的代理协议要求；QUIC 等需要 UDP）
入口协议族：本地连接 A 用 IPv4 选 1，用 IPv6 选 2
A-B 传输：3  直接路由
B 地址类型：B 的可达地址是 IPv4 选 1，IPv6 选 2
```

然后填写 A 的入口端口、B 地址与代理端口。网卡、监听 IP 和 SNAT 源 IP 都会给出自动检测值；普通单网卡 VPS 通常直接回车即可。填完来源 IP/CIDR 后，脚本探测 B 的 TCP 端口，再显示完整配置让你确认。

云平台通过 NAT 映射公网 IPv4 时，网卡可能只有内网 IPv4。**监听/SNAT 填本机网卡真实地址，本地客户端仍填云平台的公网入口地址。**

提示“没有目标协议族路由”时，先按下面的跨族方案解决连通条件。TCP 失败时可以明确选择仅保存配置，但这不算通过验收。

### 4. 开放 A 的入口，并填写本地客户端

在云厂商控制台的防火墙/安全组中，允许本地 IP 访问 A 的入口端口和所选 TCP/UDP 协议。脚本无法代替你修改云厂商控制台。

| 客户端字段 | 填写内容 |
| --- | --- |
| 服务器地址 | A 的公网 IP/域名 |
| 服务器端口 | 你刚填写的 A 入口端口 |
| 代理协议、用户、密码、UUID 等 | 保留 B 原来的值 |
| TLS SNI、证书域名、WebSocket Host/路径 | 保留 B 协议要求的值；转发脚本不会签发或替换证书 |

### 5. 从本地验证

先用实际客户端访问网站。若使用带用户名的 SOCKS5，也可在**本地终端**执行下面的命令，按实际值替换 `A_IP`、`A_PORT`、`YOUR_USER`；curl 会提示输入密码，不必把密码写进命令历史：

```bash
curl --noproxy "" --proxy socks5h://A_IP:A_PORT --proxy-user YOUR_USER --connect-timeout 8 --max-time 20 https://api64.ipify.org
```

Windows PowerShell 请把 `curl` 写成 `curl.exe`。IPv6 代理地址写成 `socks5h://[A_IPV6]:A_PORT`。HTTP 代理把 `socks5h://` 换成 `http://`；sing-box/Xray 等协议请使用对应客户端。

返回值应与 **B 自己访问相同目标、相同地址族时的出口**一致。B 可能有 NAT、多个 IP 或自己的上游代理，因此不一定等于 SSH 登录地址。再测试下载和实际应用，验证认证、DNS、TLS 均正常。

不要在 A 上访问 A 自己的 NAT 入口来替代外部测试，本脚本处理外部进入的 PREROUTING 流量，不修改 OUTPUT。

## 跨 IPv4 / IPv6

这里的类型由「实际可路由能力」决定。拥有 `100.64.0.0/10` 范围内的共享内网 IPv4，不代表拥有公网 IPv4。

| 本地到 A 的入口 | A 能访问的 B 地址 | 使用的引擎 |
| --- | --- | --- |
| IPv4 | IPv4 | iptables 内核 NAT |
| IPv6 | IPv6 | ip6tables 内核 NAT |
| IPv4 | IPv6 | Nginx stream |
| IPv6 | IPv4 | Nginx stream |

**Nginx 可以接收一种地址族、连接另一种地址族，前提是 A 确实具备另一种地址族的路由。WireGuard 也需要两端之间有可达的 UDP 底层路径。**

### A 与 B 完全没有共同可达的地址族

准备一台能访问两边的双栈 R，保留原来的 A：

```text
本地 -> IPv4-only A -> R 的 IPv4入口 -> R -> IPv6-only B -> 网站
```

1. 先在 **R** 下载运行脚本，配置 R 的 IPv4 入口端口 -> B 的 IPv6 代理端口。R 在这一次操作中承担脚本所称的 A 角色。
2. 再在原来的 **A** 运行新手向导，传输方式选 `5 双栈中转`。确认 R -> B 已完成，填写 **R 的 IPv4 和 R 的入口端口**。
3. 本地仍连接 A，最终代理仍在 B。R 的允许来源填 A，A 的允许来源填本地。

反向也是一样：IPv6-only A 连接 R 的 IPv6，R 再连接 IPv4-only B。可以用 WireGuard 加密有可达底层的各段；脚本不会自动创建跨族中继或凭空生成新出口。

### 网络已经提供 NAT64 或 CLAT

- 已有 NAT64：传输方式选 `4`，填写 B IPv4 和上游的 `/96` 前缀。默认 `64:ff9b::/96` 只是常见值，不表示你的网络一定提供该服务。
- 已有 CLAT，系统可路由 IPv4：选 `3 直接路由`，填写 B IPv4。
- 本脚本不安装 NAT64/CLAT 网关，不支持非 `/96` 地址合成。存在 IPv6 默认路由不能证明 NAT64 服务存在。

**如果最终 B 本身只有 IPv6 网站出口，A 的跨族转发也不能让 B 自动访问 IPv4-only 网站。** 需要另行解决 B 的出站 NAT64/CLAT/上游路由，并重新检查实际出口。

## 增加 C：本地 -> C -> A -> B

先完成并测试 A -> B，再登录 **C** 运行脚本：

```text
主菜单 1 -> 配置目标 4（链式代理）-> 当前机器是 C，选 2
目标地址：C 能访问的 A 地址
目标端口：A 的入口端口，不是 B 的代理端口
```

本地客户端只改成 **C 地址:C 入口端口**，B 的代理认证及 TLS 配置保持不变。A 的允许来源改为 C 的出站 IP，C 的允许来源填本地公网 IP。如果 C -> A 使用已有隧道，填写 A 的隧道地址，并确认自动检测的入口/出口网卡。

每增加一跳，都从靠近 B 的节点开始配置。各跳必须有路由，协议必须一致，多一跳会增加时延和故障点。

## 长期运行、更新与删除

SSH 退出后会继续运行，配置会在开机时恢复：

| 内容 | 管理方式 |
| --- | --- |
| 同族 NAT | Linux 内核规则，无需常驻转发进程 |
| 开机恢复规则 | `a2b-forward-rules.service`，只恢复 A2B 专属链 |
| 跨族转发 | `a2b-forward-proxy.service`，进程异常自动重启 |
| WireGuard | `wg-quick@接口名`，例如 `wg-quick@a2b0` |

查看和诊断：

```bash
sudo bash iptables_Forward.sh --status
sudo bash iptables_Forward.sh --diagnose
sudo systemctl status a2b-forward-rules a2b-forward-proxy --no-pager
sudo journalctl -u a2b-forward-rules -u a2b-forward-proxy -n 60 --no-pager
```

纯 NAT 没有 Nginx 服务属于正常。规则恢复服务是 oneshot，执行后显示 `active (exited)` 属于正常；首次配置后尚未运行恢复服务时可显示 inactive，当前内核规则已经生效。

跨族代理错误日志交给 journald，由系统日志保留策略管理，不再新建持续增长的独立 error.log。旧版日志文件保留，不会自动删除。

更新时重新运行向导，填写相同的 **入口协议族 + 端口 + TCP/UDP**，对应映射会被替换。该标识不区分入口网卡/IP；脚本不支持在同一地址族用同一个 TCP/UDP 端口配置多个独立目标。未选择的协议不变。已有 NAT 连接不会被强制清空，需要客户端重新连接才能使用新目标或新的来源限制。Nginx 与 NAT 之间可以切换；跨引擎切换可能中断旧代理连接。

删除选择主菜单 `3`，默认需要确认，可保留 WireGuard。保留隧道时，其 UDP 放行规则和开机恢复也会保留。删除不卸载依赖包，不清空其它防火墙规则；当前转发开关不强制关闭，避免影响其它路由服务。

每次写入会保存权限受限的备份至 `/var/lib/a2b-forward/backups/`，记录至 `/var/lib/a2b-forward/audit.tsv`。正常应用错误、输入中断会触发本次操作的自动回滚。包安装、断电、SIGKILL 和磁盘损坏不在即时回滚保证范围内。备份可能含 WireGuard 私钥，勿公开。

旧版整份防火墙持久化会迁移为专属链，并从旧 `rules.v4/v6` 文件去除 A2B 条目，保留其它规则。建议升级后主动运行一次恢复验证，再选择维护窗口重启实机确认。

## 连不上时，按顺序检查

| 现象 | 检查方法 |
| --- | --- |
| 本地连 A 超时 | A 公网地址、入口端口、TCP/UDP、云安全组、来源 CIDR 是否填对 |
| 脚本提示 B TCP 不通 | 在 A 运行诊断，检查 B 监听地址、端口和防火墙；WireGuard 模式还要查握手 |
| TCP 连通但不能访问网站 | 检查 B 代理认证、TLS SNI、DNS 和 B 自己的网站出口 |
| WireGuard 接口已启动但没流量 | 两端 `sudo wg show` 查看握手；检查 B 配置是否部署、A UDP 安全组、Endpoint 地址族 |
| 小网页能开，大流量卡住 | 保留 ICMP/ICMPv6 的路径 MTU 错误报文；隧道检查 MTU，可在两端把 1420 降至 1380 再测 |
| UFW/firewalld 重载后不通 | 先检查规则，再执行 `sudo systemctl restart a2b-forward-rules`；防火墙管理器重载可移除跳转 |
| UDP 应用不通 | 核对应用实际 UDP 端口；SOCKS5 UDP ASSOCIATE 的动态端口不会因为转发 TCP 端口而自动可用 |
| 用域名填写 B 被拒绝 | 转发目标使用确定的 IP。WireGuard Endpoint 支持域名，但 DNS 变化后可能需要重启对应隧道 |

## 性能和可用性边界

- 同族转发使用内核 NAT；跨族使用独立的 Nginx stream，不解密代理协议。Nginx UDP 会话默认空闲 60 秒，可在向导中调整；持续传输会刷新超时。
- B 已有加密代理时，直接转发少一层封装。需要 A-B 加密或私有地址时使用 WireGuard；它有封装开销，不能保证提高网速、降低丢包或降低时延。
- 不再无条件放大全局缓冲区、缩短 TCP 回收时间或修改拥塞控制。这些参数并不等于 NAT 端口转发提速。调优应根据 CPU、连接跟踪占用、RTT、丢包和真实吞吐判断。
- systemd 常驻和进程恢复不等于多机高可用。本版本没有多个 B 的自动故障切换、负载均衡或掉线后的会话迁移。
- 自动测试覆盖 Ubuntu 22.04/24.04 的地址解析、交互、真实 TCP/UDP、NAT、Nginx、链式 SOCKS5 出口、WireGuard、规则恢复和服务故障恢复。CI 不替代你所在公网线路的长期压测和实机重启验证。

完整复核发现、测试边界和操作留痕见 [AUDIT.md](AUDIT.md)。
