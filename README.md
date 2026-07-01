# a2b-forward

交互式 Linux 转发脚本，用于搭建稳定的：

```text
本地客户端 -> A -> B -> 目标网站
```

也支持链式：

```text
本地客户端 -> C -> A -> B -> 目标网站
```

核心原则很简单：**代理程序放在 B 上**，这样目标网站看到的出口就是 B；A 和 C 只负责入口和转发。

## 适合谁

- 本地直连 B 很差，但 A 到本地、A 到 B 都很稳。
- 想把 A 当入口，把流量转到 B 上的 SOCKS5/HTTP/sing-box/Xray/Squid 等代理。
- 需要 IPv4-only、IPv6-only、双栈机器之间做可验证的转发。
- 希望转发配置可以开机自动恢复，而不是临时命令。

## 功能

- 交互式向导，新手按提示填写即可。
- IPv4 -> IPv4：iptables 内核 NAT。
- IPv6 -> IPv6：ip6tables 内核 NAT。
- IPv4 <-> IPv6：Nginx stream L4 跨协议族代理。
- A-B WireGuard 隧道生成与现有 WireGuard 隧道接入。
- NAT64/464XLAT 辅助模式：适用于 IPv6-only A 访问 IPv4-only B，前提是网络已提供 NAT64/CLAT。
- 本地 -> C -> A -> B 链式代理向导。
- systemd 持久化：
  - `a2b-forward-rules.service` 恢复防火墙规则。
  - `a2b-forward-proxy.service` 托管跨协议族代理。
  - `wg-quick@接口名` 托管 WireGuard。
- 性能参数优化：连接跟踪、队列、缓冲区、TCP 回收相关 sysctl。
- 不会为了安装 `iptables-persistent` 强行移除 UFW；检测到 UFW 时会使用脚本自己的 systemd 恢复服务。

## 快速开始

在 A 机器上运行：

```bash
sudo bash iptables_Forward.sh
```

选择：

```text
1. 添加/更新配置
1. 推荐: B 上运行代理，A 做公网入口，A-B 优先使用 WireGuard 隧道
```

然后按提示填写：

- 本地连接 A 使用 IPv4 还是 IPv6。
- A-B 之间使用新建 WireGuard、已有 WireGuard、直接路由、NAT64/464XLAT，还是双栈中转。
- A 对外监听端口。
- B 的代理 IP 和端口。
- 是否限制允许访问 A 的来源 CIDR。

完成后，本地客户端代理地址填写：

```text
A 的公网地址:A 的入口端口
```

## 链式代理：本地 -> C -> A -> B

链式代理要分两跳配置：

```text
第一跳：A -> B
第二跳：C -> A
```

推荐顺序：

1. 在 B 上安装并启动代理程序。
2. 在 A 上运行脚本，选择“推荐: B 上运行代理”，完成 A -> B。
3. 记住 A 的入口端口。
4. 在 C 上运行脚本，选择“链式代理”，再选择“当前机器是 C”，完成 C -> A。
5. 本地客户端只连接 C 的入口地址和端口。

最终路径：

```text
本地客户端 -> C入口端口 -> A入口端口 -> B代理端口 -> 目标网站
```

## IPv4 / IPv6 原则

脚本不能违反网络基本规则：当前机器必须能访问下一跳的目标协议族。

例如：

- IPv4-only A 无法直接访问 IPv6-only B。
- IPv6-only A 无法直接访问 IPv4-only B。
- 如果有 NAT64/464XLAT，可以让 IPv6-only A 通过 NAT64 合成地址访问 IPv4-only B。
- 如果没有 NAT64/CLAT，就需要 WireGuard、双栈中转、其它 VPN/隧道，或者换一台能同时访问两边的机器。

最高性能建议：

- 同协议族转发优先，因为可以走内核 NAT。
- A-B 长期使用优先 WireGuard。
- 跨 IPv4/IPv6 转发会使用 Nginx stream，兼容性好，但性能通常低于内核 NAT。

## 管理

查看当前配置：

```bash
sudo bash iptables_Forward.sh
# 选择 2
```

删除脚本管理的规则和服务：

```bash
sudo bash iptables_Forward.sh
# 选择 3
```

## 安全提醒

- 只在你拥有或被授权管理的机器上使用。
- 强烈建议在“允许来源 CIDR”里填写你的本地公网 IP、C 的 IP，或上一跳机器 IP。
- 不要把服务器密码、WireGuard 私钥、代理密钥提交到 GitHub。

