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
- **脚本自更新/自卸载**：主菜单选 4 从 GitHub 拉取最新版（对比版本号、语法校验后更新）；选 5 清理 slib 和缓存
- **配置持久化 + 权限收紧**：安装信息保存在 `/etc/ziyong/`（目录 700、文件 600），frps token 配置文件 600 仅 root 可读
- **init 系统全兼容**：systemd → OpenRC（Alpine 等，自动生成 `/etc/init.d/frps` 原生托管）→ nohup + pidfile 三级降级，低配 NAT 机也能跑
- **状态判定真实可靠**：运行状态以端口真实响应为准（纯 bash 探测），不依赖 pgrep/ss/curl，低配最小化系统不误报
- **防火墙自动放行**：检测到 ufw / firewalld 开启时自动放行所需端口（云厂商安全组仍需手动放行）
- **状态一目了然**：主菜单和子菜单实时显示每个服务的 `[运行中]` / `[已停止]` / `[未安装]` 状态

## 包含的服务

| 服务 | 用途 |
|------|------|
| **1. WxChat（Docker 版）** | 微信通知转发代理，官方镜像 `ddsderek/wxchat` 一键部署 |
| **2. WxChat（nginx 版）** | 同等功能的 nginx 原生实现，**无需 Docker**，低配 NAT 机也能跑 |
| **3. frps** | frp 服务端（fatedier/frp 官方二进制），内网穿透，装完直接打印 frpc 客户端配置示例 |

两个版本的 WxChat 功能完全等价（都是反代企业微信 API），可任选其一安装，也可共存（不同端口）。

```
╔════════════════════════════════════════════╗
║         Slib 自用 VPS 服务管理脚本         ║
╚════════════════════════════════════════════╝
  快捷命令: slib    版本: v1.3.2

  1. WxChat 微信通知转发代理 (Docker 版)
  2. WxChat 微信通知转发代理 (nginx 版)
  3. frps 服务端 (frp 内网穿透)
  4. 更新脚本自身
  5. 卸载脚本自身 (slib/缓存)
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

## 常见问题

- **提示需要 root**：用 `sudo bash ziyong.sh` 运行。
- **NAT 机没有 Docker**：不影响，WxChat 是 nginx 原生实现，frps 是官方二进制，全程不需要 Docker。
- **frpc 连不上 frps**：先查安全组/防火墙是否放行 7000 端口，再核对 token 是否一致。
- **WxChat 通知收不到**：检查企业微信可信 IP 是否填了 VPS 公网 IP；VPS 换 IP 后要同步更新。
- **改了 frps 配置不生效**：子菜单 10 编辑后按提示重启，或 `systemctl restart frps`。

## 本地运行

```bash
git clone https://github.com/qingshous/ziyong.git
cd ziyong
sudo bash ziyong.sh
```

## 说明

- 脚本仅供自用，环境为常见 Debian / Ubuntu / CentOS x86_64（frps 另支持 arm64/arm）VPS。
- 脚本会执行安装/删除容器、systemd 服务等操作，请确认在 root 权限下运行。
