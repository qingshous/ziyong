#!/bin/bash

# =========================================================
# Realm 一键安装与管理脚本 (全系统兼容重构版)
# 功能: 安装 Realm、转发规则增删查、服务管理
# 适配: Debian / Ubuntu / CentOS / Alpine
#       systemd / OpenRC / 无init(nohup) 三级服务托管
# 快捷指令: 安装后输入 realm 即可打开菜单
# =========================================================

VERSION="2.0.1"

# 脚本的 Raw 链接 (用于安装快捷命令及自更新)
SCRIPT_URL="https://raw.githubusercontent.com/qingshous/realm-installer/main/install.sh"

# === 关键路径定义 ===
CONFIG_FILE="/etc/realm/config.toml"
BIN_PATH="/usr/local/bin/realm-bin"      # 核心程序 (改名避免与快捷命令冲突)
MENU_PATH="/usr/local/bin/realm"         # 快捷管理命令
SERVICE_FILE="/etc/systemd/system/realm.service"
OPENRC_FILE="/etc/init.d/realm"
PID_FILE="/run/realm.pid"
LOG_FILE="/var/log/realm.log"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

info() { echo -e "${GREEN}[信息]${PLAIN} $1"; }
warn() { echo -e "${YELLOW}[注意]${PLAIN} $1"; }
err()  { echo -e "${RED}[错误]${PLAIN} $1"; }
line() { echo "────────────────────────────────────────────"; }

# ============================================================
#  基础工具
# ============================================================

# init 系统检测
has_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }
has_openrc()  { command -v rc-service >/dev/null 2>&1 && [ -d /run/openrc ]; }

# ask_yn "提示" -> 回车=是, n=否, 其他重输
ask_yn() {
    local prompt="$1" ans
    while :; do
        read -rp "${prompt} [回车=是, n=否]: " ans
        case "$ans" in
            "")            return 0 ;;
            n|N|no|NO|No)  return 1 ;;
            y|Y|yes|YES)   return 0 ;;
            *) echo -e "${YELLOW}请输入 y 或 n (直接回车=是)${PLAIN}" ;;
        esac
    done
}

# 下载: 直连失败自动走加速回退, curl/wget 双工具
download() {
    local url="$1" out="$2"
    curl -fsSL --connect-timeout 10 --max-time 180 "$url" -o "$out" 2>/dev/null && [ -s "$out" ] && return 0
    curl -fsSL --connect-timeout 10 --max-time 180 "https://ghproxy.net/$url" -o "$out" 2>/dev/null && [ -s "$out" ] && return 0
    curl -fsSL --connect-timeout 10 --max-time 180 "https://gh-proxy.com/$url" -o "$out" 2>/dev/null && [ -s "$out" ] && return 0
    wget -qO "$out" "$url" 2>/dev/null && [ -s "$out" ] && return 0
    return 1
}

# 按需安装缺失依赖 (不全量装, 不装无关包)
ensure_deps() {
    local missing=""
    command -v bash >/dev/null 2>&1 || missing="$missing bash"
    command -v curl >/dev/null 2>&1 || missing="$missing curl"
    command -v tar  >/dev/null 2>&1 || missing="$missing tar"
    [ -z "$missing" ] && return 0
    info "安装缺失依赖:$missing ..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y $missing
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $missing
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $missing
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache $missing
    else
        err "无法识别包管理器, 请手动安装:$missing"
        return 1
    fi
}

# 检测 CPU架构+libc -> realm release 目标三元组
# realm 官方同时发布 gnu 和 musl 构建, Alpine 直接下 musl 版, 无需 gcompat
detect_target() {
    local arch libc
    case "$(uname -m)" in
        x86_64)        arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        armv7l)        arch="armv7" ;;
        armv6l)        arch="arm" ;;
        *) return 1 ;;
    esac
    if [ -f /etc/alpine-release ] || ls /lib/ld-musl-*.so.1 >/dev/null 2>&1 || ldd --version 2>&1 | grep -qi musl; then
        libc="musl"
    else
        libc="gnu"
    fi
    case "${arch}-${libc}" in
        x86_64-gnu)   echo "x86_64-unknown-linux-gnu" ;;
        x86_64-musl)  echo "x86_64-unknown-linux-musl" ;;
        aarch64-gnu)  echo "aarch64-unknown-linux-gnu" ;;
        aarch64-musl) echo "aarch64-unknown-linux-musl" ;;
        armv7-gnu)    echo "armv7-unknown-linux-gnueabihf" ;;
        armv7-musl)   echo "armv7-unknown-linux-musleabihf" ;;
        arm-gnu)      echo "arm-unknown-linux-gnueabi" ;;
        arm-musl)     echo "arm-unknown-linux-musleabi" ;;
        *) return 1 ;;
    esac
}

# 端口/IP 校验
valid_port() { echo "$1" | grep -qE '^[0-9]+$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_remote_addr() { echo "$1" | grep -qE '^[0-9a-fA-F.:]+$|^[A-Za-z0-9._-]+\.[A-Za-z]{2,}$'; }

# ============================================================
#  服务管理 (systemd / OpenRC / nohup 三级)
# ============================================================

realm_proc_alive() {
    local p
    for p in /proc/[0-9]*/comm; do
        [ "$(cat "$p" 2>/dev/null)" = "realm-bin" ] && return 0
    done
    return 1
}

realm_running() {
    if has_systemd; then
        systemctl is-active --quiet realm 2>/dev/null && return 0
    elif has_openrc; then
        rc-service realm status >/dev/null 2>&1 && return 0
    fi
    realm_proc_alive
}

realm_ctl() {
    local action="$1"
    if has_systemd; then
        case "$action" in
            enable)  systemctl enable --now realm ;;
            disable) systemctl disable --now realm ;;
            *)       systemctl "$action" realm ;;
        esac
        return
    fi
    if has_openrc; then
        case "$action" in
            enable)  rc-update add realm default >/dev/null 2>&1; rc-service realm restart >/dev/null 2>&1 || rc-service realm start ;;
            disable) rc-service realm stop >/dev/null 2>&1; rc-update del realm default >/dev/null 2>&1 ;;
            *)       rc-service realm "$action" ;;
        esac
        return
    fi
    # nohup 兜底 (无 init 系统)
    case "$action" in
        enable|start)
            realm_proc_alive && return 0
            nohup "$BIN_PATH" -c "$CONFIG_FILE" >>"$LOG_FILE" 2>&1 &
            echo $! > "$PID_FILE"
            sleep 1
            realm_proc_alive
            ;;
        stop)
            if [ -f "$PID_FILE" ]; then kill "$(cat "$PID_FILE")" 2>/dev/null; rm -f "$PID_FILE"; fi
            local p
            for p in /proc/[0-9]*/comm; do
                [ "$(cat "$p" 2>/dev/null)" = "realm-bin" ] && kill "${p%/comm}" 2>/dev/null
            done
            return 0
            ;;
        restart)
            realm_ctl stop; sleep 1; realm_ctl start
            ;;
        disable)
            realm_ctl stop
            ;;
    esac
}

# nohup 模式下尽力用 crontab 设置开机自启
setup_autostart_nohup() {
    has_systemd || has_openrc && return 0
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v 'realm-installer'; echo "@reboot ${BIN_PATH} -c ${CONFIG_FILE} >>${LOG_FILE} 2>&1 &  # realm-installer" ) | crontab - \
            && info "已通过 crontab @reboot 设置开机自启"
    else
        warn "无 init 系统且未找到 crontab, 机器重启后需手动执行: realm"
    fi
}

remove_autostart_nohup() {
    command -v crontab >/dev/null 2>&1 && ( crontab -l 2>/dev/null | grep -v 'realm-installer' ) | crontab - 2>/dev/null
    return 0
}

# 防火墙放行 (检测到啥用啥, 都没有就跳过提示)
firewall_open() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow "${port}/tcp" >/dev/null && ufw allow "${port}/udp" >/dev/null
        info "ufw 已放行端口 ${port} (tcp+udp)"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null && firewall-cmd --permanent --add-port="${port}/udp" >/dev/null && firewall-cmd --reload >/dev/null
        info "firewalld 已放行端口 ${port} (tcp+udp)"
    else
        warn "未检测到活跃防火墙 (ufw/firewalld), 跳过放行; 如有安全组/iptables 请自行放行 ${port}"
    fi
}

# ============================================================
#  规则解析 (config.toml 由本脚本生成, 格式固定)
# ============================================================

# 输出 "编号|listen|remote" 每行一条
parse_rules() {
    awk '
        /^\[\[endpoints\]\]/ { n++ }
        /^[[:space:]]*listen[[:space:]]*=/ { if (n>0) { split($0,a,"\""); L[n]=a[2] } }
        /^[[:space:]]*remote[[:space:]]*=/ { if (n>0) { split($0,a,"\""); R[n]=a[2] } }
        END { for (i=1; i<=n; i++) printf "%d|%s|%s\n", i, L[i], R[i] }
    ' "$CONFIG_FILE" 2>/dev/null
}

rule_count() { parse_rules | grep -c . ; }

print_rules() {
    local n=0 idx l r
    while IFS='|' read -r idx l r; do
        [ -n "$idx" ] || continue
        printf "  ${CYAN}%s${PLAIN}) 本机 %s  -->  %s\n" "$idx" "$l" "$r"
        n=$((n+1))
    done <<< "$(parse_rules)"
    [ "$n" -eq 0 ] && echo "  (暂无规则)"
    return 0
}

# 删除第 N 个 [[endpoints]] 块
delete_rule_block() {
    local del="$1" tmp
    tmp=$(mktemp) || return 1
    awk -v del="$del" '
        /^\[\[endpoints\]\]/ { n++; skip = (n==del) ? 1 : 0; if (skip) next }
        /^\[/ && !/^\[\[endpoints\]\]/ { skip=0 }
        skip==0 { print }
    ' "$CONFIG_FILE" > "$tmp" && cat "$tmp" > "$CONFIG_FILE" && rm -f "$tmp"
}

# ============================================================
#  1. 安装 Realm
# ============================================================
install_realm() {
    if [ -f "$BIN_PATH" ]; then
        warn "检测到已安装 Realm ($("$BIN_PATH" --version 2>/dev/null | head -1)), 将重装内核 (配置保留)"
        ask_yn "确认重装?" || { info "已取消"; return 1; }
    fi

    ensure_deps || return 1

    local target
    target=$(detect_target) || { err "不支持的架构/libc: $(uname -m)"; return 1; }
    info "目标平台: ${target}"

    # 下载到临时目录, 不污染当前目录
    local tmp_dir
    tmp_dir=$(mktemp -d) || { err "创建临时目录失败"; return 1; }
    info "下载 realm (${target}) ..."
    if ! download "https://github.com/zhboner/realm/releases/latest/download/realm-${target}.tar.gz" "${tmp_dir}/realm.tar.gz"; then
        err "下载失败 (已尝试直连/ghproxy/gh-proxy), 请检查网络"
        rm -rf "$tmp_dir"; return 1
    fi
    tar -xzf "${tmp_dir}/realm.tar.gz" -C "$tmp_dir" || { err "解压失败"; rm -rf "$tmp_dir"; return 1; }
    [ -f "${tmp_dir}/realm" ] || { err "解压后未找到 realm 二进制"; rm -rf "$tmp_dir"; return 1; }
    chmod +x "${tmp_dir}/realm"
    realm_ctl stop >/dev/null 2>&1
    mv -f "${tmp_dir}/realm" "$BIN_PATH"
    rm -rf "$tmp_dir"
    info "内核已安装: $("$BIN_PATH" --version 2>/dev/null | head -1)"

    # 安装快捷命令 (下载自身, 带校验)
    info "配置快捷管理命令 realm ..."
    local tmp_script
    tmp_script=$(mktemp) || return 1
    if download "$SCRIPT_URL" "$tmp_script" && head -n 1 "$tmp_script" | grep -q '^#!/bin/bash' && bash -n "$tmp_script" 2>/dev/null; then
        chmod +x "$tmp_script"
        mv -f "$tmp_script" "$MENU_PATH"
    else
        rm -f "$tmp_script"
        warn "快捷命令安装失败 (网络问题), 可稍后菜单选 7 重试"
    fi

    # 初始化配置
    mkdir -p /etc/realm
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
[network]
no_tcp = false
use_udp = true
EOF
    fi
    chmod 600 "$CONFIG_FILE"

    # 按 init 系统写服务
    if has_systemd; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=realm port relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    elif has_openrc; then
        cat > "$OPENRC_FILE" <<EOF
#!/sbin/openrc-run
name="realm"
description="realm port relay"
command="${BIN_PATH}"
command_args="-c ${CONFIG_FILE}"
command_background=true
pidfile="${PID_FILE}"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
depend() { need net; }
EOF
        chmod +x "$OPENRC_FILE"
    else
        warn "未检测到 systemd/OpenRC, 使用 nohup 后台模式 (日志: ${LOG_FILE})"
    fi

    # realm 的 TOML 必须至少有一条 [[endpoints]], 空配置启动会 panic
    # 所以: 有规则才启动+自启, 无规则只写好服务文件, 等首条规则添加时启动
    if [ "$(rule_count)" -gt 0 ]; then
        realm_ctl enable || { err "服务启动失败, 请查看: ${LOG_FILE}"; return 1; }
        setup_autostart_nohup
        sleep 1
        if ! realm_running; then
            err "服务启动后未存活, 请检查: ${LOG_FILE}"
            return 1
        fi
    else
        warn "暂无转发规则, 服务暂不启动 (realm 不允许空配置运行)"
    fi

    echo ""
    line
    info "Realm 安装成功!"
    [ -f "$MENU_PATH" ] && info "以后输入 ${YELLOW}realm${GREEN} 即可打开本菜单"
    info "下一步: 菜单选 2 添加第一条转发规则 (添加后服务自动启动)"
    line
}

# ============================================================
#  2. 添加转发规则
# ============================================================
add_rule() {
    if [ ! -f "$BIN_PATH" ]; then
        err "请先安装 Realm (菜单选 1)"
        return 1
    fi

    echo -e "${GREEN}=== 添加新的转发规则 ===${PLAIN}"

    # 监听地址
    local listen_addr="0.0.0.0" addr_choice
    read -rp "监听地址 [回车=仅IPv4(0.0.0.0), 6=双栈([::])]: " addr_choice
    case "$addr_choice" in
        6) listen_addr="[::]" ;;
        "") : ;;
        *) warn "无效输入, 使用默认 0.0.0.0" ;;
    esac

    # 监听端口 (校验 + 查重)
    local listen_port
    while :; do
        read -rp "本机监听端口 (例如 6666): " listen_port
        if ! valid_port "$listen_port"; then
            warn "端口无效: ${listen_port} (应为 1-65535 的数字)"; continue
        fi
        if parse_rules | awk -F'|' -v p=":${listen_port}" '$2 ~ p"$" {found=1} END{exit !found}'; then
            warn "端口 ${listen_port} 已被现有规则占用, 请换一个"; continue
        fi
        break
    done

    # 落地地址 (校验, IPv6 自动加括号)
    local remote_ip
    while :; do
        read -rp "落地机 IP / 域名: " remote_ip
        if valid_remote_addr "$remote_ip"; then break; fi
        warn "地址格式无效: ${remote_ip}"
    done
    case "$remote_ip" in
        *:*) case "$remote_ip" in \[*) ;; *) remote_ip="[${remote_ip}]" ;; esac ;;
    esac

    # 落地端口
    local remote_port
    while :; do
        read -rp "落地机端口: " remote_port
        if valid_port "$remote_port"; then break; fi
        warn "端口无效: ${remote_port} (应为 1-65535 的数字)"
    done

    # 写入配置
    cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
listen = "${listen_addr}:${listen_port}"
remote = "${remote_ip}:${remote_port}"
EOF

    firewall_open "$listen_port"

    # 重启 + 真实验证 (首条规则: 启动并设置开机自启)
    if realm_running; then
        realm_ctl restart >/dev/null 2>&1
    else
        realm_ctl enable >/dev/null 2>&1
        setup_autostart_nohup
    fi
    sleep 1
    if realm_running; then
        info "规则添加成功: 本机 ${listen_addr}:${listen_port} --> ${remote_ip}:${remote_port}"
    else
        err "启动后服务未存活, 请检查配置和日志: ${LOG_FILE}"
        return 1
    fi
}

# ============================================================
#  3. 删除转发规则
# ============================================================
del_rule() {
    if [ ! -f "$CONFIG_FILE" ]; then
        err "配置文件不存在"
        return 1
    fi
    local total
    total=$(rule_count)
    if [ "$total" -eq 0 ]; then
        warn "暂无规则可删"
        return 0
    fi

    echo -e "${GREEN}=== 删除转发规则 ===${PLAIN}"
    print_rules
    local num
    while :; do
        read -rp "请输入要删除的规则编号 [1-${total}, 回车取消]: " num
        [ -z "$num" ] && { info "已取消"; return 0; }
        if echo "$num" | grep -qE '^[0-9]+$' && [ "$num" -ge 1 ] && [ "$num" -le "$total" ]; then break; fi
        warn "编号无效: ${num}"
    done

    local target_line
    target_line=$(parse_rules | awk -F'|' -v n="$num" '$1==n {print $2" --> "$3}')
    if ask_yn "确认删除规则 ${num} (${target_line})?"; then
        delete_rule_block "$num" || { err "删除失败"; return 1; }
        if [ "$(rule_count)" -eq 0 ]; then
            # 最后一条规则删除后 realm 无法运行 (空配置 panic), 停止并取消自启
            realm_ctl disable >/dev/null 2>&1
            remove_autostart_nohup
            info "规则 ${num} 已删除, 已无剩余规则, 服务已停止 (防火墙已放行的端口请按需手动关闭)"
        else
            realm_ctl restart >/dev/null 2>&1
            sleep 1
            if realm_running; then
                info "规则 ${num} 已删除 (防火墙已放行的端口不会自动回收, 如需要请手动关闭)"
            else
                err "重启后服务未存活, 请检查: ${LOG_FILE}"
                return 1
            fi
        fi
    else
        info "已取消"
    fi
}

# ============================================================
#  4/5. 查看
# ============================================================
list_rules_view() {
    echo -e "${GREEN}=== 当前转发规则 ($(rule_count) 条) ===${PLAIN}"
    print_rules
}

check_status() {
    if [ ! -f "$BIN_PATH" ]; then
        err "Realm 未安装"
        return 1
    fi
    echo -e "${GREEN}=== Realm 运行状态 ===${PLAIN}"
    info "版本: $("$BIN_PATH" --version 2>/dev/null | head -1)"
    if realm_running; then
        info "状态: ${GREEN}运行中${PLAIN}"
    else
        warn "状态: ${RED}已停止${PLAIN}"
    fi
    echo ""
    list_rules_view
    echo ""
    if command -v ss >/dev/null 2>&1; then
        warn "监听中的端口:"
        ss -tlnp 2>/dev/null | grep realm-bin || echo "  (无)"
    fi
}

# ============================================================
#  6. 更新内核
# ============================================================
update_realm() {
    if [ ! -f "$BIN_PATH" ]; then
        err "请先安装 Realm (菜单选 1)"
        return 1
    fi
    info "当前版本: $("$BIN_PATH" --version 2>/dev/null | head -1)"
    warn "realm 官方仓库已归档停更, 此操作重装 latest 版 (配置保留), 也可用于修复损坏的内核"
    if ask_yn "确认重新下载内核?"; then
        install_realm
    else
        info "已取消"
    fi
}

# ============================================================
#  7. 更新脚本 (带校验, 失败不破坏现有命令)
# ============================================================
update_script() {
    info "当前版本: v${VERSION}, 正在检查更新..."
    local tmp_script new_ver
    tmp_script=$(mktemp) || return 1
    if ! download "$SCRIPT_URL" "$tmp_script"; then
        err "下载失败 (已尝试直连/ghproxy/gh-proxy)"; rm -f "$tmp_script"; return 1
    fi
    if ! head -n 1 "$tmp_script" | grep -q '^#!/bin/bash' || ! bash -n "$tmp_script" 2>/dev/null; then
        err "下载内容校验失败, 已取消 (现有 realm 命令不受影响)"; rm -f "$tmp_script"; return 1
    fi
    new_ver=$(grep -m1 '^VERSION=' "$tmp_script" | cut -d'"' -f2)
    if [ "$new_ver" = "$VERSION" ]; then
        info "已是最新版本 v${VERSION}"; rm -f "$tmp_script"; return 0
    fi
    chmod +x "$tmp_script"
    cp -f "$tmp_script" "$MENU_PATH" 2>/dev/null
    # 文件方式运行时同时覆盖本体
    [ -f "${BASH_SOURCE[0]}" ] && [ "${BASH_SOURCE[0]}" != "$MENU_PATH" ] && cp -f "$tmp_script" "${BASH_SOURCE[0]}" 2>/dev/null
    rm -f "$tmp_script"
    info "更新完成: v${VERSION} -> v${new_ver}, 请重新运行 realm"
    exit 0
}

# ============================================================
#  8. 卸载 (二次确认)
# ============================================================
uninstall_realm() {
    warn "将删除: realm 内核, 快捷命令, 服务, 全部转发配置 (/etc/realm)"
    if ask_yn "确认彻底卸载 Realm?"; then
        realm_ctl disable >/dev/null 2>&1
        realm_ctl stop >/dev/null 2>&1
        remove_autostart_nohup
        rm -f "$SERVICE_FILE" "$OPENRC_FILE" "$BIN_PATH" "$MENU_PATH" "$PID_FILE"
        rm -rf /etc/realm
        has_systemd && systemctl daemon-reload 2>/dev/null
        info "Realm 已彻底卸载, 再见!"
        exit 0
    fi
    info "已取消"
}

# ============================================================
#  主菜单 (循环)
# ============================================================
show_menu() {
    local tag="  ${RED}[未安装]${PLAIN}"
    if realm_running; then
        tag="  ${GREEN}[运行中 · $(rule_count) 条规则]${PLAIN}"
    elif [ -f "$BIN_PATH" ]; then
        tag="  ${YELLOW}[已停止]${PLAIN}"
    fi
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════╗"
    echo -e "║       Realm 端口转发 一键管理脚本          ║"
    echo -e "╚════════════════════════════════════════════╝${PLAIN}"
    echo -e "  快捷命令: realm    版本: v${VERSION}${tag}"
    echo ""
    echo -e "  ${GREEN}1${PLAIN}. 安装 Realm"
    echo -e "  ${GREEN}2${PLAIN}. 添加转发规则"
    echo -e "  ${GREEN}3${PLAIN}. 删除转发规则"
    echo -e "  ${GREEN}4${PLAIN}. 查看规则列表"
    echo -e "  ${GREEN}5${PLAIN}. 查看运行状态 / 配置"
    echo -e "  ${GREEN}6${PLAIN}. 更新 Realm 内核"
    echo -e "  ${GREEN}7${PLAIN}. 更新本脚本"
    echo -e "  ${GREEN}8${PLAIN}. 卸载 Realm"
    echo -e "  ${RED}0${PLAIN}. 退出"
    echo ""
    line
    read -rp "请输入数字 [0-8]: " num
}

main() {
    [ "$EUID" -ne 0 ] && { err "必须使用 root 用户运行此脚本!"; exit 1; }
    while true; do
        show_menu
        case "$num" in
            1) install_realm ;;
            2) add_rule ;;
            3) del_rule ;;
            4) list_rules_view ;;
            5) check_status ;;
            6) update_realm ;;
            7) update_script ;;
            8) uninstall_realm ;;
            0) info "再见!"; exit 0 ;;
            *) warn "请输入正确的数字!"; sleep 1; continue ;;
        esac
        echo ""
        read -rp "按回车返回菜单..." _
    done
}

main "$@"
