# a2b-forward

中文交互式 Linux 端口转发工具。运行在入口服务器 A，把连接送到已运行代理服务的 B。

```text
浏览器/应用 -> 本机代理客户端 -> A 的入口端口 -> B 的代理端口 -> 目标网站
```

A/B 可以对应你的中转机/落地机。脚本负责转发，不安装 B 上的 sing-box、Xray、SOCKS5 或 HTTP 代理，也不生成本地客户端的 UUID、Reality 密钥或 DNS 分流规则。

## 开始前准备

适用环境：Debian/Ubuntu、Bash、root 权限和 systemd。安装缺失依赖使用 apt；其他发行版需要自行提供依赖，尚未纳入自动验收。

准备以下信息。示例 IP 是文档保留地址，必须换成你自己的值。

| 信息 | 示例 | 用途 |
| --- | --- | --- |
| A 的公网地址 | `192.0.2.10` | 本地客户端连接的位置 |
| A 的入口端口 | `26385` | A 接收代理连接；不能占用 SSH 等已有服务端口 |
| B 的可达地址 | `198.51.100.20` | A 能够访问的公网或隧道 IP |
| B 的代理端口 | `46385` | 必须与 B 上代理配置一致 |
| 传输协议 | `tcp` | VLESS + Reality 通常选 TCP；按实际协议选择 |
| 允许来源 | 你的公网 IP 加 `/32` | IPv6 单地址用 `/128`；留空允许所有来源 |

先在 B 上确认代理运行：

```bash
sudo systemctl status sing-box --no-pager
sudo ss -lntup
```

服务名以实际安装方式为准。B 服务应监听 A 可达的地址，不能仅监听 `127.0.0.1`。云平台安全组也要放行 A 的入口端口，以及 B 接收 A 连接的端口；本脚本不能修改云平台安全组。

## 第一次运行

在 **A 的 SSH 终端**中逐条运行：

```bash
sudo apt-get update
sudo apt-get install -y curl
curl --fail --location --retry 3 https://raw.githubusercontent.com/Borisgohard/a2b-forward/main/iptables_Forward.sh -o iptables_Forward.sh
bash -n iptables_Forward.sh
sudo bash iptables_Forward.sh
```

下载失败时不要运行不完整文件。`bash -n` 成功时一般没有输出。重新下载不会自动修改当前转发，只有完成配置向导并确认才会应用新映射。

最常见的“IPv4 A -> IPv4 B，复用现有线路”按下面填写：

1. 主菜单选 `1`，添加/更新配置。
2. 配置目标选 `1`，B 上运行代理、A 做入口。
3. 如实确认 B 的代理已运行；协议选 `tcp`，入口选 IPv4。
4. A-B 传输方式选 `3`，直接使用现有路由。这也是默认选项。
5. B 地址类型选 IPv4。
6. A 入口端口填 `26385`；B 目标填 `198.51.100.20:46385`，替换成实际值。
7. 网卡、监听地址、出口网卡、SNAT 地址先检查自动检测结果，正确就回车。云 VPS 可能显示内网 IP，这是正常的，不要把不存在于网卡上的公网映射地址强行填进去。
8. 填允许来源 CIDR，核对最后的配置摘要，然后确认写入。
9. 可选高并发参数默认选 `N`。完成后还要做下一节的客户端验收。

输入错误会报出原因。主菜单 `0` 退出；`Ctrl+C` 可终止向导。新建 WireGuard 是单独的写入阶段，会单独确认；隧道建好后取消端口配置，不会自动删除已创建的隧道。

## 客户端怎么填

本地代理客户端中，节点的服务器地址填 **A 的公网地址**，节点端口填 **A 的入口端口**。协议、UUID、密码、Reality 公钥、short ID、SNI 等继续与 **B 的代理服务**一致。

以 VLESS + Reality 为例，浏览器不能直接把 `A:26385` 当 HTTP 代理。先启动本地 sing-box，再让浏览器连接 sing-box 的本机 HTTP/SOCKS 监听端口。本机监听端口、A 入口端口、B 代理端口是三个独立值。

本仓库不改本地系统代理、不接管客户端 DNS。普通 HTTP/SOCKS 代理只能覆盖遵循代理设置的应用；需要全局 DNS 接管时，应另行配置并验证 TUN。命令行 SOCKS 请求使用 `socks5h://` 可把该请求的域名解析交给代理端。

## 怎么确认成功

在 A 上查看本脚本规则与状态：

```bash
sudo bash iptables_Forward.sh
# 选择 2，只查看，不安装依赖、不修改转发规则。
sudo systemctl is-enabled a2b-forward-rules.service
sudo iptables -t nat -nvL A2B_PREROUTING
```

IPv6 NAT 使用 `ip6tables`。NAT 是内核规则，`ss` 看不到入口端口的监听进程，这是正常现象。`a2b-forward-rules.service` 刚创建时可能显示 inactive，表示尚未执行开机恢复；应先检查是否 enabled，再核对当前内核规则。

从 **本地客户端**实际访问。例如本机 sing-box 的监听端口是 `42685`：

```powershell
curl.exe --proxy http://127.0.0.1:42685 https://api.ipify.org
curl.exe --proxy socks5h://127.0.0.1:42685 https://api.ipify.org
curl.exe --proxy http://127.0.0.1:42685 -I https://www.google.com/generate_204
```

预期看到 B 的出口 IP，并且目标网站可用。若本地分流把测试域名设为直连，应换成明确走代理的目标。只显示“配置完成”、TCP 端口可连或存在一条路由，都不代表代理握手、UDP、DNS或最终出口已经通过。

不要只在 A 上连接 A 自己的公网入口来验收 NAT：这种本机连接走 OUTPUT，不是本脚本的 PREROUTING 入站路径。应从本地或另一台机器测试。

## 更新与持久化

更新映射时重新运行同一向导。同一地址族、同一 TCP/UDP 协议、同一入口端口的旧 A2B NAT 映射会被替换，不再把新规则追加在旧规则后面。一个地址族内，同一协议/端口视为一个映射，不支持把这个组合拆成多个按来源选择不同目标的映射。

已有连接保留旧 conntrack 状态，新连接使用新目标。更新后应重新建立客户端连接；脚本不会清空全机连接跟踪表。

规则仅保存 A2B 自有链，通过 `--noflush` 开机恢复，保留其他链及默认策略。旧版写入 `/etc/iptables/rules.v4`、`rules.v6` 的 A2B 部分会先备份再迁出，其他规则保持原样。不会安装或启用 iptables-persistent，不会卸载 UFW。

UFW、Docker 或其他工具随后重载防火墙，可能移除 A2B 的跳转。先检查，再按需执行：

```bash
sudo systemctl restart a2b-forward-rules.service
sudo journalctl -u a2b-forward-rules.service -n 50 --no-pager
```

恢复失败会以失败状态报告，不再用 `|| true` 隐藏。恢复是每张表的操作，不是整个主机网络的全局事务。

## 其他拓扑

| 场景 | 选择与限制 |
| --- | --- |
| IPv4 -> IPv4、IPv6 -> IPv6 | 内核 NAT；当前机器必须有到 B 的相应地址族路由 |
| IPv4 -> IPv6、IPv6 -> IPv4 | 独立 Nginx stream 服务；A 必须有 B 所用地址族的出口 |
| 已有 WireGuard | 选择已有隧道，填写 B 隧道 IP；不覆盖现有密钥 |
| 新建 WireGuard | 使用未占用的接口名；生成 A/B 配置并启动 A，B 仍需部署 |
| NAT64 | 仅接受有效 `/96` 前缀；上游必须真实提供 NAT64，脚本不部署转换网关 |
| 本地 -> C -> A -> B | 先在 A 完成 A -> B，再在 C 选择链式向导完成 C -> A；本地只连 C |

WireGuard 给 A/B 提供加密隧道和私网互通，但它不能让两个完全没有共同可达地址族的节点自动建立连接。对于已经加密且稳定的 Reality/TLS 链路，额外封装不保证更快。

新建 WireGuard 后，A 端配置位于 `/etc/wireguard/接口名.conf`，B 端导出位于 `/root/a2b-forward-wireguard/接口名-B.conf`。通过你自己的 SSH/SFTP 工具把 B 文件传到 B 的 `/etc/wireguard/接口名.conf`，在 B 安装 `wireguard-tools`、设置文件权限 `600`，然后运行：

```bash
sudo systemctl enable --now wg-quick@a2b0
sudo wg show a2b0
```

`a2b0` 替换为所选接口名。在两端确认握手和收发数据后，再测试 B 隧道地址和代理端口。已有接口或配置文件会被拒绝覆盖；需要换密钥时应单独规划两端切换。

跨族 Nginx 使用独立配置和 PID，不改系统网站配置。TCP 开启上游 socket keepalive；UDP 空闲会话为 5 分钟，TCP 为 1 小时。UDP 的应用语义不等于 TCP，游戏、QUIC、长时间静默业务仍应按实际应用测试。

## 性能与回退

默认保留现有缓冲区、TCP 回收和反向路径检查参数。选择可选高并发设置后，只提高过低的 conntrack 容量与监听队列，不降低已有较高值。它可能提高容量上限，不代表带宽、延迟一定改善。

纯 NAT 中转不终止 TCP，A 上的 BBR 不会改变穿过 A 的客户端 TCP 拥塞控制。先测真实吞吐、丢包、CPU、conntrack 使用量和各跳 RTT，再决定是否调参或增加隧道。

每次变更前会在 `/root/a2b-forward-backup-日期-随机值/` 保存规则与配置；每次运行的日志在 `/var/log/a2b-forward/operation-*.log`。备份/日志限制为 root 访问，备份可能包含密钥，不能上传公开仓库。

主菜单 `3` 会先确认再删除 A2B 转发。选择保留 WireGuard 时，也保留其 UDP 放行和恢复服务。删除操作会移除本项目的 sysctl 文件，但不强行改变正在使用的共享内核参数；按备份核对后再调整。B 的代理服务、本地客户端和云安全组不受删除操作管理。

备份中的 `managed.v4`、`managed.v6` 只含本项目规则。若需要回退 NAT，可先检查文件，再用对应 `iptables-restore --noflush --test` 验证后恢复。完整 `rules.v4/v6` 是审计快照，直接恢复整张表会覆盖其他防火墙配置，不应拿来做日常回退。删除后需要恢复跳转时，建议使用向导重建原映射并重新保存。

## 常见问题

| 现象 | 先检查 |
| --- | --- |
| 提示端口已被占用 | `sudo ss -lntup`；换入口端口，不要停 SSH 来腾位置 |
| A 可连，代理握手失败 | B 服务状态、协议/UUID/密钥/SNI、B 端口及安全组 |
| 规则有了但计数不增长 | 是否从其他机器连接 A；公网 IP、入口端口、协议和云安全组是否正确 |
| 有路由但连接超时 | 路由只说明下一跳；继续检查 A-B 防火墙、服务监听和实际 TCP/UDP |
| 更新后仍是旧出口 | 关闭旧代理连接后重试，核对分流是否直连 |
| IPv6 开启转发后不通 | 本工具会保留原本接收 RA 的接口能力；仍需检查运营商 RA、路由有效期与防火墙 |
| 跨族模式 Nginx 报错 | 查看独立日志 `/var/log/a2b-forward/error.log` 与 `journalctl -u a2b-forward-proxy.service` |
| 重启后失效 | 检查恢复服务状态和其他防火墙管理器的重载顺序 |
| DNS 测试显示本地解析器 | 检查客户端是否自行解析、是否使用 socks5h/TUN；服务端口转发本身不接管本地 DNS |

## 验证与审计

改动依据、缺陷等级、验证结果及未覆盖项见 [中文操作审计](docs/REVIEW-20260906.md)。回归测试保留真实数据收发，不仅检查生成的字符串：

```bash
bash -n iptables_Forward.sh
shellcheck -x -S warning iptables_Forward.sh tests/*.sh
bash tests/test_core.sh
sudo bash tests/integration.sh
```

集成测试应在测试机或 CI 运行，需要至少 256 MiB 可用内存、root、iproute2、iptables/ip6tables、Python 3、Nginx stream 和 util-linux。它在新建网络命名空间运行，临时网络与子进程由测试负责清理，不应用生产转发配置；网络命名空间仍共享宿主机内存，不能当作资源隔离。

技术依据：[Netfilter 的选择性恢复行为](https://git.netfilter.org/iptables/tree/iptables-restore.c)、[Linux IPv6 RA 与转发设置](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html)、[Nginx stream 代理参数](https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html)。
