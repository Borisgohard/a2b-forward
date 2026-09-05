# 操作审计与复核记录

## 2026-09-06 复核

基线：`d6ddacd`。工作目录：`Y:\Forward`。本次授权范围：重新 code review、修复并验证、完善交互和新手文档、推送 `Borisgohard/a2b-forward`。使用临时分支 `codex/review-reliability` 执行 Linux CI；发布前同步并合并远端改动，不强推。GitHub 网络访问使用命令级 `127.0.0.1:42343` 代理。

### 同期远端改动的合并

发布前发现远端新增 `d68b94f`、`245ce68`。已保留其提交历史、[原始资源事件审计](docs/REVIEW-20260906.md)、敏感文件忽略规则和回归断言；将原网络测试另存为 `tests/regression-network.sh`，与本轮完整套件一起在同一个双系统 CI 工作流运行，避免重复工作流遗漏依赖。该历史审计中的 VPS/OOM/coturn 操作属于另一轮记录，本轮没有连接这些 VPS。

合并候选 NAT/Nginx 预检、失败重载保留原服务、可覆盖的测试模块路径/单 worker 参数、Docker 启动顺序、私有变更日志。可选连接容量调优保留为默认关闭，补充低内存保护与事务 sysctl 快照；不恢复旧版无条件大缓冲区调优。接口/CIDR 测试改用合并后统一的标准库校验入口。WireGuard 新建确认默认取消。

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

- 本地 Git Bash 语法检查、ShellCheck 0.11.0 通过；目前 `unit.sh` 66 项、`test_core.sh` 32 项通过，包含低内存跳过/只提高过低容量/保留较高现值三个新用例。两个套件有重叠断言，数量不代表互不重复的功能数。
- 合并后的运行逻辑在 [CI 33999030575](https://github.com/Borisgohard/a2b-forward/actions/runs/33999030575) 通过 Ubuntu 22.04 与 24.04：当时为 63 项单元检查、32 项核心检查、12 组候选更新回归、18 组完整集成测试；随后补的三项容量断言只增加测试，不改变调优实现。
- 最终候选 `fb15749` 在 [CI 33999185705](https://github.com/Borisgohard/a2b-forward/actions/runs/33999185705) 两个系统的全部步骤均成功：各 66 项单元检查、32 项核心检查、12 组候选回归、18 组完整集成检查。最终发布只在其后补充本审计记录，运行脚本及测试代码与该候选一致。
- 真实路径覆盖：NAT44/NAT66 TCP 与多报文 UDP、Nginx46/64、来源限制及更新、TCP 更新保留 UDP、Nginx/NAT 来回切换、完整中文向导、两跳 SOCKS5 的 B 出口、sing-box 1.14.0 加密代理模板、生成的 WireGuard 双栈隧道与 B 出口、保留隧道的卸载、无目标族路由拒绝、规则恢复和真实 systemd 进程故障恢复。
- 配置故障注入检查旧文件/旧规则与原流量；候选 NAT 无效时不动旧链，Nginx 重载失败时保留旧服务。发行版默认 HTTP Nginx 服务在安装转发依赖后保持 inactive。
- 早期测试发现并修正了测试替身的服务状态输出、Ubuntu 22.04 的 `systemctl --kill-who` 参数兼容、Nginx 优雅退出 worker 暂持监听的冲突判定。失败运行未作为通过证据。
- 发布前/后分别检查 Git 敏感文件边界、私钥/令牌模式及匿名下载一致性。模式扫描不是不存在所有形式秘密的数学证明；历史 VPS 验证不替代本次版本测试。
- 候选版匿名下载的脚本、README、审计、新手指南、加密代理模板与 Git blob 字节一致；16 个跟踪文件不含本地工具/私有导出，六个私有路径匿名请求为 404。发布使用正常快进并保留同期主分支提交；主分支最终状态可由 [Verify 工作流](https://github.com/Borisgohard/a2b-forward/actions/workflows/verify.yml) 查询。

### 有限吞吐样本

以下取自合并后同一次 CI 的完整日志，单位 Mbps。iperf3 每项请求 2 秒，P 是并行流数；环境是同一 VM 的 veth，不是公网测试，也不是新旧版本对比。

| CI 环境 | 直连 P1 | NAT P1 | 直连 P4 | NAT P4 |
| --- | ---: | ---: | ---: | ---: |
| Ubuntu 22.04 | 23488.0 | 3768.4 | 25134.4 | 24406.5 |
| Ubuntu 24.04 | 25314.1 | 26363.9 | 62946.7 | 60330.0 |

Ubuntu 22.04 的 NAT P1 墙钟约 12 秒，结果明显波动，不能据此承诺性能不退化，更不能把单项较快解释为优化收益。测试仅要求能够持续传输并记录结果；真实线路仍需要多轮长时、丢包、CPU 与内存对照测试。

### 影响与边界

- 未连接或改动历史 VPS；本次真实网络实验使用一次性 CI VM 中的隔离命名空间，不开放公网测试代理。
- 包管理器安装的依赖不在配置回滚范围内；回滚恢复本次保存的配置、运行规则及相关 sysctl。
- 正常错误、INT/TERM 可触发回滚；SIGKILL、断电、磁盘损坏不保证即时回滚。
- 更新保留已有 conntrack 连接；新连接才使用新目标与来源规则。
- 未部署公网 NAT64/464XLAT 网关，地址合成通过不代表运营商具有转换能力。
- CI 吞吐只反映同机虚拟网络的短时结果；公网带宽、时延、丢包、MTU、云安全组和长期稳定性需部署后测量。
- 本地 `.local/`、`.tools/` 已忽略，Git 凭据仅经系统凭据助手在内存中使用，不写入公开文件。
- 测试网络命名空间不提供内存隔离。完整测试要求一次性 CI/VM 与至少 1 GiB 可用内存；候选回归要求至少 256 MiB。Nginx 测试固定单 worker，CI 分别限制 180/480 秒并在退出/信号时清理。生产部署的 Nginx 仍按 CPU 自动创建 worker，需要按 VPS 资源做容量规划。

### 复现

```bash
bash tests/unit.sh
bash tests/test_core.sh
shellcheck -x iptables_Forward.sh tests/*.sh
# 仅在可丢弃的 Linux 测试机执行，需安装 workflow 中的依赖：
sudo env A2B_TEST_DISPOSABLE=yes timeout 180 bash tests/regression-network.sh
sudo env A2B_TEST_DISPOSABLE=yes timeout 480 bash tests/integration.sh
```

真实 systemd 生命周期部分仅在一次性 CI VM (`CI=true`) 运行；普通手动运行会明确跳过该项。不能在业务机器上设置 `CI=true` 来强行开启它。

### 设计依据

- [Linux IP sysctl](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html)：IPv6 RA 与转发开关的关系；区分本机 TCP 和路由转发。
- [iptables-restore](https://man7.org/linux/man-pages/man8/iptables-restore.8.html)：`--noflush` 仅重建声明的用户链，`--test` 不提交。
- [Nginx stream proxy](https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html)：UDP/TCP、空闲超时、socket keepalive。
- [WireGuard Quick Start](https://www.wireguard.com/quickstart/)：Endpoint、AllowedIPs 和 PersistentKeepalive。
