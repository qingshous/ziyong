# Slib 自用 VPS 脚本合集

自用 VPS 一键安装管理脚本。单脚本、SSH 可视化菜单，主菜单选择服务，子菜单管理安装/更新/启停/卸载/日志。

## 一键使用

```bash
# 海外 VPS 直连
bash <(curl -fsSL https://raw.githubusercontent.com/qingshous/ziyong/main/ziyong.sh)
```

```bash
# 国内 VPS 连不上 GitHub raw 时，套一层加速
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/qingshous/ziyong/main/ziyong.sh)
```

## 脚本特性

- **端口默认随机 + 双重校验**：安装时端口直接回车 = 自动分配 20000-59999 之间的随机空闲端口；手动输入会校验合法性和**占用情况**，被占用/非法端口要求重输（重装时自动放行服务自己正在用的旧端口）
- **NAT 网络自动检测**：检测到 NAT 网络（公网 IP ≠ 本机 IP）时，安装会提醒填写服务商分配的映射端口——NAT 机上随机端口外网无法访问
- **回车即确认**：所有 y/n 交互默认 Y（如卸载确认），回车就是确认，输 `n` 取消；误触空格等无效输入会重新询问，不会误确认
- **slib 快捷命令**：首次运行脚本后自动创建，以后在任意位置输入 `slib` 直接打开管理菜单（脚本更新时重跑一次即可刷新缓存）
- **脚本自更新/自卸载**：主菜单选 8 从 GitHub 拉取最新版（对比版本号、语法校验后更新）；选 9 清理 slib 和缓存
- **配置持久化 + 权限收紧**：安装信息保存在 `/etc/ziyong/`（目录 700、文件 600），frps token 配置文件 600 仅 root 可读
- **init 系统全兼容**：systemd → OpenRC（Alpine 等，自动生成 `/etc/init.d/frps` 原生托管）→ nohup + pidfile 三级降级，低配 NAT 机也能跑
- **状态判定真实可靠**：运行状态以端口真实响应为准（纯 bash 探测），不依赖 pgrep/ss/curl，低配最小化系统不误报
- **防火墙自动放行**：检测到 ufw / firewalld 开启时自动放行所需端口，iperf3 额外放行 UDP（云厂商安全组仍需手动放行）
- **iperf3 测速服务端**：直接装发行版软件包（Debian/CentOS/Alpine 全适配），支持"测完一键停用"防止带宽被滥用，服务定义按系统类型生成、不改包自带文件
- **状态一目了然**：主菜单和子菜单实时显示每个服务的 `[运行中]` / `[已停止]` / `[未安装]` 状态

## 包含的服务

| 服务 | 用途 |
|------|------|
| **1. WxChat（Docker 版）** | 微信通知转发代理，官方镜像 `ddsderek/wxchat` 一键部署 |
| **2. WxChat（nginx 版）** | 同等功能的 nginx 原生实现，**无需 Docker**，低配 NAT 机也能跑 |
| **3. frps** | frp 服务端（fatedier/frp 官方二进制），内网穿透，装完直接打印 frpc 客户端配置示例 |
| **4. sing-box 节点管理** | 调度入口，本体在 [qingshous/sing-box-sh](https://github.com/qingshous/sing-box-sh) 仓库独立维护（VLESS-REALITY / Hysteria2 / TUIC / AnyTLS / VLESS-Argo / Shadowsocks） |
| **5. realm 端口转发管理** | 调度入口，本体在 [qingshous/realm-xwPF](https://github.com/qingshous/realm-xwPF) 仓库独立维护（realm 中转规则可视化管理、端口流量狗、链路测试） |
| **6. 轻量版 realm** | 调度入口，本体在 [qingshous/realm-installer](https://github.com/qingshous/realm-installer) 仓库独立维护（精简转发管理：规则增删查、全系统兼容，低配机首选），快捷命令 `rl` |
| **7. iperf3 测速服务端** | 原生软件包安装（无需 Docker/第三方仓库），带宽测速服务端，**测完可一键停用**防止被他人占用带宽，全系统兼容 |

两个版本的 WxChat 功能完全等价（都是反代企业微信 API），可任选其一安装，也可共存（不同端口）。

```
╔════════════════════════════════════════════╗
║         Slib 自用 VPS 服务管理脚本         ║
╚════════════════════════════════════════════╝
  快捷命令: slib    版本: v1.8.0

  1. WxChat 微信通知转发代理 (Docker 版)
  2. WxChat 微信通知转发代理 (nginx 版)
  3. frps 服务端 (frp 内网穿透)
  4. sing-box 节点管理 (VLESS-REALITY/Hy2/TUIC等)
  5. realm 转发管理 xwPF版 (流量狗/链路测试)
  6. 轻量版 realm (realm-installer: 精简)
  7. iperf3 测速服务端 (带宽测速)
  8. 更新脚本自身
  9. 卸载脚本自身 (slib/缓存)
  0. 退出
```

---

## 1. WxChat 微信通知代理（Docker 版）

一键部署官方镜像 `ddsderek/wxchat:latest`，Docker 未安装时脚本自动安装（官方源失败自动切国内镜像源）。

**子菜单**：安装 / 更新 / 重启 / 停止 / 卸载 / 状态+公网IP / 实时日志

| 项 | 默认值 | 说明 |
|----|--------|------|
| 镜像 | `ddsderek/wxchat:latest` | 官方镜像 |
| 宿主机端口 | 随机空闲端口 | 安装时可手动指定 |
| 重启策略 | `--restart=always` | 开机自启、异常拉起 |

---

## 2. WxChat 微信通知代理（nginx 原生版）

官方镜像 `ddsderek/wxchat` 的本质就是 nginx 反代企业微信 API，本脚本直接以 **nginx 原生方式**实现同等功能——**无需 Docker**，纯 nginx 进程内存占用仅几 MB，兼容无法跑 Docker 的低配 NAT 机。

**子菜单**：安装 / 更换端口 / 重启 / 停止 / 卸载 / 状态+公网IP / 实时日志 / 卸载 nginx 本体

**兼容性**：

| 项 | 支持范围 |
|----|----------|
| 系统 | Debian / Ubuntu / CentOS / Alpine（自动识别包管理器） |
| 服务管理 | systemd 优先，无 systemd 自动用 service / 裸进程兜底 |
| nginx 配置目录 | 自动适配 `/etc/nginx/conf.d`（Debian/CentOS）和 `/etc/nginx/http.d`（Alpine） |
| IPv6 | 自动检测，NAT 老内核无 IPv6 时只监听 IPv4 |
| 旧版迁移 | 检测到 Docker 版 wxchat 容器时提示一键迁移 |

生成的配置与官方镜像完全一致（5 条 API 反代 + `client_max_body_size 20m` + 欢迎页）。

**安装完成后必做**：企业微信后台 → 应用 → **可信 IP**，填入 VPS 公网 IP（安装完成时和菜单"查看状态"都会打印）。

访问 `http://VPS公网IP:端口` 出现"微信通知转发代理搭建成功"页即为正常，同时它也是微信通知代理地址。

---

## 3. frps 服务端（frp 内网穿透）

从 GitHub 下载 [fatedier/frp](https://github.com/fatedier/frp) 官方二进制安装。下载失败自动走 ghproxy.net / gh-proxy.com 加速回退。**兼容无 systemd 的 NAT 机**：有 systemd 走 service 托管（开机自启、异常 5 秒自动拉起）；无 systemd 自动切 nohup + pidfile 后台模式，并尽力用 crontab @reboot 设置开机自启。运行状态以 bindPort 真实可连接为准（纯 bash 探测，不依赖 pgrep/ss/curl）。

**子菜单**：安装 / 更新 / 重启 / 启动 / 停止 / 卸载 / 状态+配置+公网IP / 日志 / 查看 token / 编辑配置

**安装时交互项**：

| 项 | 默认值 | 说明 |
|----|--------|------|
| frp 通信端口 | `7000` | frpc 的 `serverPort` |
| 面板端口 | `7500`（0 = 不开） | 账号 admin，密码随机生成 |
| http 穿透端口 | `8080`（0 = 不启用） | `vhostHTTPPort` |
| https 穿透端口 | `8443`（0 = 不启用） | `vhostHTTPSPort` |

token 随机生成（hex 32位），安装完成时打印，菜单"查看 token"随时可看。

**frpc 客户端配置要点**：`serverAddr = VPS公网IP`、`serverPort = 7000`、`auth.token = 安装时打印的 token`。防火墙和安全组记得放行端口（TCP）。

部署位置：二进制 `/usr/local/frp/frps`、配置 `/etc/frp/frps.toml`、服务 `frps.service`。

---

## 4. sing-box 节点管理（调度入口）

主菜单选 4 进入 sing-box 节点管理。采用**调度模式**：管理本体在 [qingshous/sing-box-sh](https://github.com/qingshous/sing-box-sh) 仓库独立维护，本脚本只做入口转发，两边更新互不影响。

- **本机已装过**：直接调用本机的 `sb` 面板（平时也可以不经过本脚本，直接输 `sb` 进入）
- **本机未装**：自动从 sing-box-sh 仓库拉取 `install.sh`（直连失败走 ghproxy.net / gh-proxy.com 回退），下载后先 `bash -n` 语法校验再执行；首次运行会自动安装 `sb` 快捷命令并进入面板
- 退出 sing-box 面板后自动返回本脚本主菜单

支持协议：VLESS-REALITY / Hysteria2 / TUIC / AnyTLS / VLESS-Argo / Shadowsocks，含证书管理、Argo 隧道、节点增删改查等完整功能（详见 sing-box-sh 仓库）。

> 注意：sing-box-sh 的 `install.sh` 内部自更新地址指向上游源仓库（edxgj/sing-box-sh），如需改为你自己的仓库，请在你的仓库里修改 `fetch_script()` 中的 URL。

---

## 5. realm 端口转发管理（调度入口）

主菜单选 5 进入 realm 端口转发管理。同样采用**调度模式**：管理本体在 [qingshous/realm-xwPF](https://github.com/qingshous/realm-xwPF) 仓库独立维护，本脚本只做入口转发。

- **本机已装过**：直接调用本机入口（平时也可以不经过本脚本，直接输 `pf` 进入）
- **本机未装**：自动从 realm-xwPF 仓库拉取引导脚本 `xwPF.sh`（直连失败走 ghproxy.net / gh-proxy.com 回退），`bash -n` 校验后带 `install` 参数执行——自动下载全部功能模块（转发规则、流量狗、链路测试）并创建 `pf` 快捷命令
- 退出面板后自动返回本脚本主菜单

功能：realm 中转规则可视化增删改、端口流量统计（流量狗）、中转链路网络测试（nexttrace/iperf3/hping3）、故障转移等（详见 realm-xwPF 仓库）。

> 注意：realm-xwPF 的 `xwPF.sh` 内部模块下载地址指向上游源仓库（zywe03/realm-xwPF），上游更新会自动跟上；如需改为你自己的仓库，请在你的仓库里修改 `REPO_RAW_URL`。

---

## 6. 轻量版 realm（调度入口）

主菜单选 6 进入轻量版 realm 转发管理。调度模式，本体在 [qingshous/realm-installer](https://github.com/qingshous/realm-installer) 仓库独立维护（基于 playfulsoul 版全系统兼容重构）。

- **本机已装过**：直接调用本机 `rl` 菜单（平时也可直接输 `rl` 进入；旧版的 `realm` 快捷命令会自动迁移清理）
- **本机未装**：自动拉取 `install.sh`（ghproxy 回退 + 校验），进入其菜单选 1 安装，装完自动生成 `rl` 快捷命令
- 退出菜单后自动返回本脚本主菜单

与菜单 5（realm-xwPF）的区别：xwPF 功能全（流量狗/链路测试/故障转移），轻量版只做规则增删查，胜在小巧、全系统兼容（Alpine/musl、无 systemd 的 NAT 机），低配机首选。

**两套互斥提醒**：两者服务名（`realm.service`）和配置路径（`/etc/realm/config.toml`）完全相同，同时运行会互相接管，请只保留一套。为便于区分：

| | 内核 | 快捷命令 | 进程名 |
|---|---|---|---|
| 菜单 5（xwPF） | `/usr/local/bin/realm` | `pf` | `realm` |
| 菜单 6（轻量版） | `/usr/local/bin/realm-bin` | `rl` | `realm-bin` |

主菜单状态标签按各自特征独立判断，不会互相误报。

---

## 7. iperf3 测速服务端

主菜单选 7 进入 iperf3 带宽测速服务端管理。**直接装发行版官方软件包**（apt / dnf / yum / apk），不下载第三方二进制、不需要 Docker、不依赖任何外部仓库。

**子菜单**：

| 项 | 说明 |
|----|------|
| 1. 安装 / 启动 | 装包并配置服务；已装过则跳过装包直接配置/修复 |
| 2. 一键停用 | **停止服务 + 关闭开机自启**（最常用：测速是偶发需求，平时关掉避免被扫描滥用、占用带宽） |
| 3. 恢复启动 + 开机自启 | 撤销 [2] |
| 4. 更换端口 | 默认 5201，可改；自动写服务覆盖，不动包自带文件 |
| 5. 查看状态 / 测速命令 | 版本 / 运行 / 自启 / 端口 / 服务定义 + 现成的客户端命令 |
| 6. 查看日志 | journalctl（systemd）/ 日志文件（OpenRC/nohup） |
| 7. 卸载 | 移除服务配置，可选是否连软件包一起删 |

**装完直接打印客户端命令**（复制到你的电脑或另一台机器执行）：

```bash
iperf3 -c <服务器IP> -p <端口>            # 上行测速
iperf3 -c <服务器IP> -p <端口> -R         # 下行（测下载）
iperf3 -c <服务器IP> -p <端口> -u -b 100M # UDP
iperf3 -c <服务器IP> -p <端口> -P 4 -t 30 # 4 线程 / 30 秒
```

**全系统兼容**（自动适配，无需手动处理）：

| 系统 | 安装 | 服务托管 | 改端口方式 |
|------|------|---------|-----------|
| Debian / Ubuntu | `apt install iperf3` | 用包自带 `iperf3.service` | systemd drop-in 覆盖（不动包文件） |
| CentOS / Rocky | `dnf/yum install iperf3`（7 自动补 EPEL） | **自建** unit（包不带 unit） | 自建 unit 内嵌端口 |
| Alpine | `apk add iperf3 iperf3-openrc` | 包自带 OpenRC init（`iperf3-openrc` 子包） | 写 `/etc/conf.d/iperf3` 的 `command_args` |
| 无 init 系统 | — | nohup + pidfile 兜底 | 启动命令直接带端口 |

- 运行状态以**端口真实可连接**为准，不依赖 `pgrep`/`ss`，低配最小化系统不误报
- 防火墙自动放行 **TCP + UDP** 端口（UDP 供 `-u` 使用），云厂商安全组仍需手动放行
- 支持 NAT 机：安装时会提醒填服务商的映射端口

> 与市面上常见的 iperf3 管理脚本不同，本脚本**不使用固定 5201 端口**，也不要求服务文件预先存在——它自己按系统类型生成/覆盖服务定义，包自带的文件一个都不改。

---

## 常见问题

- **提示需要 root**：用 `sudo bash ziyong.sh` 运行。
- **NAT 机没有 Docker**：不影响，WxChat 是 nginx 原生实现，frps 是官方二进制，全程不需要 Docker。
- **frpc 连不上 frps**：先查安全组/防火墙是否放行 7000 端口，再核对 token 是否一致。
- **WxChat 通知收不到**：检查企业微信可信 IP 是否填了 VPS 公网 IP；VPS 换 IP 后要同步更新。
- **改了 frps 配置不生效**：子菜单 10 编辑后按提示重启，或 `systemctl restart frps`。
- **iperf3 装完客户端连不上**：先确认安全组/防火墙放行了端口（UDP 测速要放 UDP），NAT 机还要确认填的是服务商映射端口。
- **iperf3 显示已停止**：多半是[一键停用]过，选 3 恢复即可；测速属偶发需求，平时停用更安全。
- **iperf3 会被别人用吗**：服务端无鉴权，知道 IP:端口的人都能压测。**测完请选 2 一键停用**，或改用非默认端口降低被扫概率。

## 本地运行

```bash
git clone https://github.com/qingshous/ziyong.git
cd ziyong
sudo bash ziyong.sh
```

## 说明

- 脚本仅供自用，环境为常见 Debian / Ubuntu / CentOS x86_64（frps 另支持 arm64/arm）VPS。
- iperf3 模块另兼容 Alpine（OpenRC）等无 systemd 环境，直接用发行版包管理器安装。
- 脚本会执行安装/删除容器、systemd 服务等操作，请确认在 root 权限下运行。
