# 操作审计与复核记录

## 2026-09-06 复核

基线：`d6ddacd`。工作目录：`Y:\Forward`。本次授权范围：重新 code review、修复并验证、完善交互和新手文档、推送 `Borisgohard/a2b-forward`。使用临时分支 `codex/review-reliability` 执行 Linux CI，完成验收后快进主分支。GitHub 网络访问使用命令级 `127.0.0.1:42343` 代理。

### 确认的问题与处理

| 严重性 | 基线问题 | 修复与验收方向 |
| --- | --- | --- |
| P1 | 整份 iptables 快照开机覆盖其它服务规则，恢复失败被 `true` 隐藏 | 仅保存 A2B 链；`--noflush --test` 预检；恢复失败让 systemd 显示失败；验证无关规则保留 |
| P1 | 同端口更新只追加 DNAT，旧目标优先匹配 | 用入口族/协议/端口识别映射，替换相关 NAT、放行与 Nginx 配置；验证 TCP 更新不删除 UDP |
| P1 | IP/CIDR/Endpoint 校验不完整，错误值可进入 Nginx/WireGuard 配置；接口名可影响文件路径 | Python 标准库解析 IP/CIDR；域名/接口名白名单；检查本机地址和端口冲突 |
| P1 | 写入或服务启动失败后留下半成品，无自动恢复 | 私有事务快照、失败/中断回滚、单写者锁；注入 Nginx 失败并复测旧流量 |
| P1 | IPv6 开启转发后 `accept_ra=1` 停止接收 RA，默认路由可能过期 | 保留 RA 接收，并持久化 `accept_ra=2` |
| P1 | 删除规则但保留 WireGuard 时，UDP 握手入口也被删除 | 保留隧道时同时重建对应放行规则及持久化 |
| P2 | SNAT/FORWARD 范围过宽，可能匹配非本次 DNAT 的转发流量 | 匹配 DNAT 连接及原始入口端口；PREROUTING 限定本机目的地址 |
| P2 | 查看状态安装依赖；菜单输入错误直接退出；EOF 处理不一致 | 查看/诊断只读；菜单和端口重试；EOF 明确取消 |
| P2 | WireGuard 覆盖会轮换密钥且 B 未同步；宽子网可能覆盖现有路由 | 阻止覆盖现有接口；默认 /32、/128；说明 B 部署及握手验证 |
| P2 | NAT64 字符串拼接不支持合法展开写法；非 /96 仍继续 | 标准库按位合成，严格限制 /96 且主机位为零 |
| P2 | 跨族 UDP 空闲超时一小时，无用会话长期占用资源 | 默认 60 秒，可交互调整；持续传输会刷新超时 |
| P2 | 通用大缓冲区、缩短 TCP 回收时间被当作无条件提速 | 停止这些全局参数改写；保留内核 NAT 和 Nginx 事件驱动路径；用有限吞吐测试记录结果 |
| P2 | WireGuard 被描述为自动跨族/改善网络质量；双栈中转步骤不完整 | 说明底层可达前提；支持保留 A 并经 R 转发；区分服务常驻与多机故障切换 |

### 验证记录

- 本地 Git Bash 语法检查、ShellCheck 0.11.0、59 项输入与逻辑检查通过。
- 已添加 Ubuntu 22.04 / 24.04 CI：内核 NAT、Nginx 跨族 TCP/UDP、两跳、实际 SOCKS5 出口、WireGuard、持久化、故障恢复、有限吞吐对照。
- Linux CI 的最终结果在本次发布完成前补录。不能将历史 VPS 测试视为本次版本验证。

### 影响与边界

- 未连接或改动历史 VPS；本次真实网络实验使用一次性 CI VM 中的隔离命名空间，不开放公网测试代理。
- 包管理器安装的依赖不在配置回滚范围内；回滚恢复本次保存的配置、运行规则及相关 sysctl。
- 正常错误、INT/TERM 可触发回滚；SIGKILL、断电、磁盘损坏不保证即时回滚。
- 更新保留已有 conntrack 连接；新连接才使用新目标与来源规则。
- 未部署公网 NAT64/464XLAT 网关，地址合成通过不代表运营商具有转换能力。
- CI 吞吐只反映同机虚拟网络的短时结果；公网带宽、时延、丢包、MTU、云安全组和长期稳定性需部署后测量。
- 本地 `.local/`、`.tools/` 已忽略，Git 凭据仅经系统凭据助手在内存中使用，不写入公开文件。

### 复现

```bash
bash tests/unit.sh
shellcheck -x iptables_Forward.sh tests/*.sh
# 仅在可丢弃的 Linux 测试机执行，需安装 workflow 中的依赖：
sudo bash tests/integration.sh
```

### 设计依据

- [Linux IP sysctl](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html)：IPv6 RA 与转发开关的关系；区分本机 TCP 和路由转发。
- [iptables-restore](https://man7.org/linux/man-pages/man8/iptables-restore.8.html)：`--noflush` 仅重建声明的用户链，`--test` 不提交。
- [Nginx stream proxy](https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html)：UDP/TCP、空闲超时、socket keepalive。
- [WireGuard Quick Start](https://www.wireguard.com/quickstart/)：Endpoint、AllowedIPs 和 PersistentKeepalive。
