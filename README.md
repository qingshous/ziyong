# ziyong - 自用 VPS 脚本合集

自用 VPS 一键安装管理脚本合集。所有脚本均为 SSH 交互式可视化菜单，上传 GitHub 后任意 VPS 上一条命令即可使用。

## 脚本列表

| 脚本 | 用途 |
|------|------|
| [wxchat.sh](wxchat.sh) | WxChat 微信通知转发代理（Docker 版）一键安装与管理 |

---

## wxchat.sh - WxChat 微信通知代理

**WxChat**（镜像 `ddsderek/wxchat:latest`）是配合企业微信应用实现微信通知推送的转发代理，NAS 无公网 IP 时，需要在有公网 IPv4 的 VPS 上部署它作为中转。带宽要求极低，1Mbps 便宜 VPS 即可。

### 一键使用

```bash
# 海外 VPS 直连
bash <(curl -fsSL https://raw.githubusercontent.com/qingshous/ziyong/main/wxchat.sh)

# 国内 VPS 连不上 GitHub raw 时，套一层加速
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/qingshous/ziyong/main/wxchat.sh)
```

### 菜单功能

```
1. 安装 WxChat        自动安装 Docker -> 自定义端口 -> 启动 -> 打印公网IP
2. 更新 WxChat        拉取最新镜像并重建容器
3. 重启 WxChat
4. 停止 WxChat
5. 卸载 WxChat        删除容器和镜像（二次确认）
6. 查看状态/公网IP    容器状态 + 本机健康探测 + 当前公网IP
7. 查看实时日志
0. 退出
```

### 安装后必做

> **企业微信后台 → 应用 → 可信 IP**，填入这台 VPS 的公网 IP（脚本安装完成后和菜单选项 6 都会打印出来），否则通知发不出去。

### 默认配置

| 项 | 默认值 | 说明 |
|----|--------|------|
| 镜像 | `ddsderek/wxchat:latest` | 官方镜像 |
| 宿主机端口 | `15680` | 安装时可交互修改 |
| 容器端口 | `80` | 不用改 |
| 重启策略 | `--restart=always` | 开机自启、异常自动拉起 |

安装完成后访问 `http://VPS公网IP:端口` 即为 WxChat 管理页，同时它也是微信通知代理地址。

### 常见问题

- **脚本提示需要 root**：用 `sudo bash wxchat.sh` 运行，或 `su -` 切 root 后再跑。
- **Docker 没装**：脚本会自动安装（官方源 `get.docker.com`，不可达时自动切换国内镜像源）。
- **端口被占用**：安装时输入其他端口即可，或菜单 5 卸载后重装换端口。
- **通知收不到**：先检查企业微信可信 IP 是否已填 VPS 公网 IP；VPS 换了 IP（如更换机器）要同步更新可信 IP。

---

## 本地运行

下载脚本后直接执行：

```bash
git clone https://github.com/qingshous/ziyong.git
cd ziyong
sudo bash wxchat.sh
```

## 说明

- 脚本仅供自用，环境为常见 Debian / Ubuntu / CentOS x86_64 VPS。
- 脚本会执行 `docker pull / run` 等操作，运行前请确认你在自己的机器上有 root 权限。
