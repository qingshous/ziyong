# Realm 一键安装与管理脚本（全系统兼容重构版）

基于 playfulsoul/realm-installer 重构的 realm 端口转发一键管理脚本，修复原版兼容性与健壮性问题。

## 相比原版的改进

- **全系统兼容**：Debian / Ubuntu（apt）、CentOS（dnf/yum）、Alpine（apk）自动识别，按需安装缺失依赖
- **三级服务托管**：systemd → OpenRC → nohup + pidfile 自动降级，无 systemd 的 NAT 机/LXC 容器也能跑（OpenRC 原生自启，nohup 模式尽力 crontab @reboot）
- **musl libc 支持**：自动检测 glibc/musl，Alpine 直接下载官方 musl 构建，无需 gcompat（原版下的 gnu 版在 Alpine 根本跑不了）
- **菜单循环**：原版选完一项就退出，现改为循环菜单
- **修复服务文件冲突**：删除原版 `User=root` + `DynamicUser=true` 的矛盾组合
- **下载校验 + 加速回退**：内核和自更新下载带 shebang/`bash -n` 校验，失败自动走 ghproxy.net / gh-proxy.com，不会写坏 `realm` 命令
- **规则管理**：规则编号列表 + 按编号删除（原版只能追加不能删）
- **输入校验**：端口 1-65535 校验、监听端口查重、落地地址格式校验、IPv6 自动加括号、可选双栈 `[::]` 监听
- **卸载二次确认**；防火墙检测到啥用啥（ufw/firewalld），都没有则提示而非强装 ufw
- **下载到临时目录**，不污染当前目录；操作后真实验证服务存活

## 使用

### 一键安装/进入菜单

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/qingshous/realm-installer/main/install.sh)
```

国内 VPS 连不上 GitHub raw 时：

```bash
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/qingshous/realm-installer/main/install.sh)
```

安装后随时输入 `realm` 唤出菜单。

### 菜单

```
1. 安装 Realm
2. 添加转发规则
3. 删除转发规则
4. 查看规则列表
5. 查看运行状态 / 配置
6. 更新 Realm 内核
7. 更新本脚本
8. 卸载 Realm
0. 退出
```

## 文件位置

| 项 | 路径 |
|----|------|
| 内核 | `/usr/local/bin/realm-bin` |
| 快捷命令 | `/usr/local/bin/realm` |
| 配置 | `/etc/realm/config.toml`（600） |
| 服务 | systemd `realm.service` / OpenRC `/etc/init.d/realm` / nohup（日志 `/var/log/realm.log`） |

## 说明

- realm 上游（zhboner/realm）已归档停更，「更新内核」实际为重装 latest 版，可用于修复损坏
- 支持 TCP + UDP 双协议转发
- **realm 不允许空配置运行**（TOML 必须至少一条 `[[endpoints]]`）：安装后服务暂不启动，添加第一条规则时自动启动并设置自启；删除到最后一条规则时服务自动停止
- 删除规则不会自动回收防火墙已放行的端口，如有需要请手动关闭
