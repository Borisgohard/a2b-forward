# B 还没有代理：从零开始

下面使用 sing-box 的 Shadowsocks 2022 加密代理。**代理只安装在 B，客户端到 B 的流量保持加密，A/C 只转发。** 没有域名和 TLS 证书也能使用；不是伪装成 HTTPS 的协议。配置格式依据 [官方 Shadowsocks 入站文档](https://sing-box.sagernet.org/configuration/inbound/shadowsocks/)，本仓库在 CI 中使用 sing-box 1.14.0 检查并实际跑流量。

先完成最短路径：B 加密代理 -> A 直接转发 -> 本地验证。需要额外 A-B 隧道时再按文末添加 WireGuard。所有 IP、端口和密码使用你自己的值。

## 1. 在 B 安装 sing-box

仅在没有现有 sing-box 配置的新机器上按本教程创建配置。已有用户应继续使用原配置，避免覆盖正在运行的代理。

登录 **B**，按 [官方 APT 安装方法](https://sing-box.sagernet.org/installation/package-manager/) 添加软件源并安装稳定版：

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates nano
sudo install -d -m 755 /etc/apt/keyrings
sudo curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
sudo chmod 644 /etc/apt/keyrings/sagernet.asc
sudo tee /etc/apt/sources.list.d/sagernet.sources >/dev/null <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
sudo apt-get update
sudo apt-get install -y sing-box
sing-box version
```

软件源将安装执行时的稳定版本。与本仓库验证版本不同时，尤其需要完成下面的 `check` 和实际访问测试。

## 2. 在 B 设置端口和密钥

生成随机密钥：

```bash
sing-box generate rand --base64 16
```

把输出保存在自己的密码管理器中，稍后服务器和客户端都要填写。不要公开这段密钥。这个算法要求 16 字节随机值的 Base64 编码，不能随意改成普通短密码。

下载示例到临时文件，再编辑：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/Borisgohard/a2b-forward/main/examples/sing-box-server.json -o a2b-server.json
nano a2b-server.json
```

只需要按实际情况调整这三项：

| 字段 | 填什么 |
| --- | --- |
| `listen` | 双栈/IPv6 通常保持 `::`；内核禁用 IPv6 时用 `0.0.0.0`；只允许隧道访问时填 B 的隧道地址 |
| `listen_port` | B 的代理端口，示例 `8833`，可自行修改 |
| `password` | 把 `REPLACE_WITH_BASE64_KEY` 替换为刚生成的密钥 |

Nano 保存按 Ctrl+O、回车，退出按 Ctrl+X。执行检查，必须无错误才安装配置：

```bash
sing-box check -c a2b-server.json
sudo install -d -m 750 /etc/sing-box
sudo install -m 640 a2b-server.json /etc/sing-box/config.json
sudo systemctl enable --now sing-box
sudo systemctl restart sing-box
sudo systemctl status sing-box --no-pager
sudo ss -lntup
```

若发行版服务以专用用户运行，确认 `/etc/sing-box/config.json` 的属组允许该服务读取；可用 `systemctl cat sing-box` 查看。启动失败先读 `sudo journalctl -u sing-box -n 50 --no-pager`，不要继续配置 A。

在 B 的云安全组及本机防火墙中允许 **A 的出站 IP** 访问所选 B 代理端口。想用 TCP+UDP 就放行两者，不能只开放 TCP 后假设 UDP 也可用。

## 3. 在 A 配置转发

回到 [README 的五步跑通](../README.md#五步跑通)，下载并运行脚本，选择新手向导、直接路由。填写 B 的可达地址和上一步设置的 B 代理端口。

协议选择 `3 both` 可转发 Shadowsocks 的 TCP 和 UDP。先只验证网站访问也可以选 TCP，之后用相同入口再添加 UDP。A 的入口端口可以与 B 不同。

## 4. 在本地添加客户端节点

使用支持 Shadowsocks 2022 的客户端。字段如下：

| 字段 | 内容 |
| --- | --- |
| 协议 | Shadowsocks |
| 地址 | A 的公网 IP；加入 C 后填 C |
| 端口 | A 的入口端口；加入 C 后填 C 的入口端口 |
| 加密方法 | `2022-blake3-aes-128-gcm` |
| 密钥/密码 | B 上第 2 步生成的密钥 |
| 插件、TLS | 本示例不启用，不要额外勾选 |

不能直接把服务器地址当作普通 SOCKS5 填到浏览器。先启动 Shadowsocks 客户端，再让浏览器/系统使用客户端提供的本地代理。

若本地客户端提供 `127.0.0.1:1080` SOCKS5 入口，可验证：

```bash
curl --noproxy "" --proxy socks5h://127.0.0.1:1080 --max-time 20 https://api64.ipify.org
```

端口要换成本地客户端实际监听值；Windows 用 `curl.exe`。结果应与 B 访问同一目标的实际出口一致。B 只有 IPv6 出口时，不能访问 IPv4-only 网站，需要单独解决 B 的出站能力。

## 5. 可选：再加 A-B WireGuard

加密代理已经保护流量，WireGuard 是可选项。它提供私有地址和链路加密，但不承诺提速。

1. 在 **A** 运行脚本，主菜单 `1` -> 配置目标 `3`。接口名可用 `a2b0`，按提示选择 UDP 端口、两端隧道地址、MTU，以及 B 能访问的 A 公网 Endpoint。保留默认地址时为 `10.66.66.1/32`、`10.66.66.2/32` 和对应 IPv6 ULA。
2. 在 **B** 执行 `sudo apt-get install -y wireguard-tools`，创建目录 `sudo install -d -m 700 /etc/wireguard`。
3. 通过 SSH 软件的 SFTP，把 A 生成的 `/root/a2b-forward-wireguard/a2b0-B.conf` 传到 B 的 `/etc/wireguard/a2b0.conf`。文件含私钥，不要公开。
4. 在 B 执行 `sudo chmod 600 /etc/wireguard/a2b0.conf` 和 `sudo systemctl enable --now wg-quick@a2b0`。A 的云安全组应放行所选 UDP 握手端口。
5. 两端执行 `sudo wg show` 检查近期握手，A 执行 `ping -c 3 10.66.66.2`。**接口已创建不等于握手已成功**。
6. 在 **A** 再次运行新手向导，传输选 `1 已有 WireGuard`，B 目标填 `10.66.66.2` 和 B 原代理端口；入口端口保持原值，确认更新。
7. 从本地重新连接并验证。成功后可在 B 限制代理端口只允许 A 隧道地址；本机防火墙需要允许 `a2b0` 上的代理流量。

若将 sing-box 改为只监听特定隧道地址，要让它在隧道启动后启动。在 B 执行 `sudo systemctl edit sing-box`，加入：

```ini
[Unit]
Requires=wg-quick@a2b0.service
After=wg-quick@a2b0.service
```

然后 `sudo systemctl daemon-reload`、`sudo systemctl restart sing-box`，再次验证。A/B 完全没有共同可达地址族时，先搭双栈中转；WireGuard 不自带跨族中继。

最后在维护窗口重启 A、B，验证隧道、代理监听和本地访问均恢复。CI 的服务恢复测试不能代替真实 VPS 的重启验收。
