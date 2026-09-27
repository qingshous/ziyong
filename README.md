# ziyong - 自用 VPS 脚本合集

自用 VPS 一键安装管理脚本。单脚本、SSH 可视化菜单，主菜单选择服务，子菜单管理安装/更新/启停/卸载/日志。

## 一键使用

```bash
# 海外 VPS 直连
bash <(curl -fsSL https://raw.githubusercontent.com/qingshous/ziyong/main/ziyong.sh)

# 国内 VPS 连不上 GitHub raw 时，套一层加速
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/qingshous/ziyong/main/ziyong.sh)
```

## 包含的服务

| 服务 | 用途 |
|------|------|
| **1. WxChat** | 微信通知转发代理（Docker 版），NAS 无公网 IP 时配合企业微信推送通知 |
| **2. frps** | frp 服务端（fatedier/frp 官方二进制 + systemd），内网穿透 |

```
╔════════════════════════════════════════════╗
║      ziyong 自用 VPS 服务 一键管理脚本      ║
╚════════════════════════════════════════════╝

  1. WxChat 微信通知转发代理 (Docker)
  2. frps 服务端 (frp 内网穿透)
  0. 退出
```

---

## 1. WxChat 微信通知代理

基于 Docker 部署 `ddsderek/wxchat:latest`。Docker 未安装时脚本会自动安装（官方源失败自动切国内镜像源）。

**子菜单**：安装 / 更新 / 重启 / 停止 / 卸载 / 状态+公网IP / 实时日志

| 项 | 默认值 | 说明 |
|----|--------|------|
| 镜像 | `ddsderek/wxchat:latest` | 官方镜像 |
| 宿主机端口 | `15680` | 安装时交互修改 |
| 重启策略 | `--restart=always` | 开机自启、异常拉起 |

**安装完成后必做**：企业微信后台 → 应用 → **可信 IP**，填入 VPS 公网 IP（安装完成时和菜单"查看状态"都会打印）。

访问 `http://VPS公网IP:端口` 即为 WxChat 管理页，同时也是微信通知代理地址。

---

## 2. frps 服务端（frp 内网穿透）

从 GitHub 下载 [fatedier/frp](https://github.com/fatedier/frp) 官方二进制安装，systemd 托管（开机自启、异常 5 秒自动拉起）。下载失败自动走 ghproxy.net / gh-proxy.com 加速回退。

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
