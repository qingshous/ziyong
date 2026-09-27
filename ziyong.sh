#!/usr/bin/env bash
# ============================================================
#  ziyong.sh - 自用 VPS 服务合集 一键脚本 (SSH 可视化菜单)
#  作者: nono哥
#  用法:
#    本地执行:   bash ziyong.sh
#    一键远程:   bash <(curl -fsSL https://raw.githubusercontent.com/qingshous/ziyong/main/ziyong.sh)
#  当前包含:
#    1. WxChat   微信通知转发代理 (Docker)
#    2. frps     frp 服务端 (官方二进制 + systemd)
#  特性:
#    - 端口默认随机分配(自动避开占用), 回车即可
#    - y/n 交互默认 Y, 回车或空格=是
#    - 安装信息持久化 (/etc/ziyong/), 重跑脚本不丢配置
#    - 自动检测 ufw/firewalld 并放行端口
#    - 快捷命令: 首次运行后任意位置输入 slib 打开本脚本
# ============================================================

set -o pipefail

# ================= 通用基础 =================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

ZIYONG_DIR="/etc/ziyong"
WX_CONF="${ZIYONG_DIR}/wxchat.conf"

line() { echo -e "${CYAN}────────────────────────────────────────────${PLAIN}"; }
info() { echo -e "${GREEN}[信息]${PLAIN} $*"; }
warn() { echo -e "${YELLOW}[注意]${PLAIN} $*"; }
err()  { echo -e "${RED}[错误]${PLAIN} $*"; }

pause_back() { read -rp "按回车返回菜单..." _; }

# ask_yn "提示文字" [默认Y|N]  -> 返回0=是
# 默认Y时: 回车或空格都=是, 只有输入 n 才是否
ask_yn() {
    local prompt="$1" def="${2:-Y}" ans
    if [ "$def" = "Y" ]; then
        read -rp "${prompt} [回车/空格=是, n=否]: " ans
        case "$(echo "$ans" | tr -d ' \t')" in
            n|N|no|NO|No|nO) return 1 ;;
            *) return 0 ;;
        esac
    else
        read -rp "${prompt} [y=是, 回车/空格=否]: " ans
        case "$(echo "$ans" | tr -d ' \t')" in
            y|Y|yes|YES|Yes|yEs|yES|YeS|yeS) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 root 用户运行: sudo bash $0"
        exit 1
    fi
}

get_pub_ip() {
    local ip=""
    ip=$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -4 -fsSL --max-time 5 https://ip.sb 2>/dev/null) \
        || ip=$(curl -4 -fsSL --max-time 5 http://members.3322.org/dyndns/getip 2>/dev/null) \
        || ip="获取失败"
    echo "$ip"
}

gen_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32
    fi
}

# 随机取一个 20000-59999 的空闲 TCP 端口 (避开系统保留/常用段)
random_free_port() {
    local port
    while :; do
        port=$(( (RANDOM * 32768 + RANDOM) % 40000 + 20000 ))
        if ! (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | grep -q ":${port} "; then
            echo "$port"; return
        fi
    done
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "arm" ;;
        *)       err "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

# 取 frp 最新版本号, 失败回退固定版本
get_latest_version() {
    local ver=""
    ver=$(curl -fsSL --max-time 10 "https://api.github.com/repos/fatedier/frp/releases/latest" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
    [ -n "$ver" ] && echo "$ver" || echo "0.61.1"
}

# download <url> <输出文件>  (GitHub 直连失败自动走加速)
download() {
    local url="$1" out="$2"
    if curl -fL --max-time 120 --connect-timeout 10 "$url" -o "$out" 2>/dev/null; then
        return 0
    fi
    curl -fL --max-time 120 --connect-timeout 10 "https://ghproxy.net/${url}" -o "$out" 2>/dev/null \
        || curl -fL --max-time 120 --connect-timeout 10 "https://gh-proxy.com/${url}" -o "$out" 2>/dev/null \
        || return 1
}

# 防火墙自动放行 TCP 端口 (检测到才操作)
open_firewall_ports() {
    local p
    for p in "$@"; do
        [ "$p" = "0" ] && continue
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw allow "${p}/tcp" >/dev/null 2>&1 && info "ufw 已放行 ${p}/tcp"
        fi
        if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 \
                && firewall-cmd --reload >/dev/null 2>&1 \
                && info "firewalld 已放行 ${p}/tcp"
        fi
    done
    warn "云服务器请自行确认厂商安全组已放行端口"
}

# 自动安装 Docker (wxchat 用)
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        info "Docker 已安装: $(docker -v)"
        return 0
    fi
    warn "未检测到 Docker, 开始自动安装..."
    if curl -fsSL --max-time 20 https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
        sh /tmp/get-docker.sh && rm -f /tmp/get-docker.sh
    else
        warn "官方源不可达, 尝试国内镜像源..."
        curl -fsSL --max-time 20 https://get.daocloud.io/docker -o /tmp/get-docker.sh \
            && sh /tmp/get-docker.sh && rm -f /tmp/get-docker.sh
    fi
    command -v docker >/dev/null 2>&1 || { err "Docker 安装失败, 请手动安装后重试"; return 1; }
    systemctl enable --now docker >/dev/null 2>&1
    info "Docker 安装完成: $(docker -v)"
}

# WxChat 安装信息持久化
save_wx_conf() { mkdir -p "$ZIYONG_DIR"; echo "WX_PORT=${WX_PORT}" > "$WX_CONF"; }
load_wx_conf() {
    WX_PORT="15680"
    [ -f "$WX_CONF" ] && . "$WX_CONF"
}

# slib 快捷命令: 任意位置输入 slib 打开本脚本
SHORTCUT="/usr/local/bin/slib"
CACHE_SCRIPT="${ZIYONG_DIR}/ziyong.sh"

setup_shortcut() {
    # 非 root 直接跳过 (无权限写 /usr/local/bin)
    [ "$(id -u)" -eq 0 ] || return 0
    # 缓存脚本自身 (bash 文件方式运行时)
    if [ -f "${BASH_SOURCE[0]}" ]; then
        mkdir -p "$ZIYONG_DIR"
        cp -f "${BASH_SOURCE[0]}" "$CACHE_SCRIPT" 2>/dev/null
    fi
    # 创建快捷命令 (已存在则只更新缓存)
    if [ ! -f "$SHORTCUT" ]; then
        if [ -f "$CACHE_SCRIPT" ]; then
            printf '#!/usr/bin/env bash\nbash %s "$@"\n' "$CACHE_SCRIPT" > "$SHORTCUT"
        else
            # curl | bash 场景: 快捷命令走在线拉取 (带加速回退)
            cat > "$SHORTCUT" <<'EOF'
#!/usr/bin/env bash
if curl -fsSL --max-time 15 https://raw.githubusercontent.com/qingshous/ziyong/main/ziyong.sh -o /tmp/ziyong.sh 2>/dev/null \
   || curl -fsSL --max-time 15 https://ghproxy.net/https://raw.githubusercontent.com/qingshous/ziyong/main/ziyong.sh -o /tmp/ziyong.sh 2>/dev/null; then
    bash /tmp/ziyong.sh
else
    echo "[错误] 脚本下载失败, 请检查网络"
fi
EOF
        fi
        chmod +x "$SHORTCUT"
        info "已创建快捷命令: 任意位置输入 ${YELLOW}slib${PLAIN} 即可打开本脚本"
    fi
}

# ============================================================
#  第一部分: WxChat 微信通知转发代理
# ============================================================

WX_IMAGE="ddsderek/wxchat:latest"
WX_NAME="wxchat"

wx_installed() { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$WX_NAME"; }
wx_running()   { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$WX_NAME"; }

wx_install() {
    check_root
    load_wx_conf
    install_docker || return 1
    local random_port
    random_port=$(random_free_port)
    echo ""
    if wx_installed; then
        warn "检测到已安装 WxChat (端口 ${WX_PORT}), 重装会删除旧容器, 端口沿用原值"
    fi
    read -rp "请输入宿主机端口 [直接回车=随机空闲端口 ${random_port}]: " input_port
    if [ -n "$input_port" ]; then
        WX_PORT="$input_port"
    elif ! wx_installed; then
        WX_PORT="$random_port"
    fi

    if wx_installed; then
        warn "删除旧容器..."
        docker rm -f "$WX_NAME" >/dev/null 2>&1
    fi

    info "拉取镜像 ${WX_IMAGE} ..."
    docker pull "$WX_IMAGE" || { err "镜像拉取失败, 请检查网络后重试"; return 1; }

    info "启动容器 (端口 ${WX_PORT} -> 80) ..."
    docker run -d \
        --name "$WX_NAME" \
        --restart=always \
        -p "${WX_PORT}:80" \
        "$WX_IMAGE" || { err "容器启动失败"; return 1; }

    save_wx_conf
    open_firewall_ports "$WX_PORT"

    local pub_ip
    pub_ip=$(get_pub_ip)
    echo ""
    line
    info "WxChat 安装完成!"
    echo -e "  ${BOLD}访问地址:${PLAIN} http://${pub_ip}:${WX_PORT}"
    echo -e "  ${BOLD}通知代理:${PLAIN} http://${pub_ip}:${WX_PORT} (同地址)"
    echo ""
    warn "重要: 请到 企业微信后台 -> 应用 -> 可信IP, 填入: ${YELLOW}${BOLD}${pub_ip}${PLAIN}"
    line
}

wx_update() {
    check_root
    if ! wx_installed; then
        err "尚未安装 WxChat, 请先执行安装"
        return 1
    fi
    load_wx_conf
    info "更新 WxChat (拉最新镜像重建容器, 端口沿用 ${WX_PORT})..."
    docker pull "$WX_IMAGE" && docker rm -f "$WX_NAME"
    docker run -d --name "$WX_NAME" --restart=always -p "${WX_PORT}:80" "$WX_IMAGE"
    info "更新完成"
}

wx_restart() {
    wx_installed && docker restart "$WX_NAME" >/dev/null 2>&1 \
        && info "WxChat 已重启" \
        || err "容器不存在或重启失败"
}

wx_stop() {
    wx_installed && docker stop "$WX_NAME" >/dev/null 2>&1 \
        && info "WxChat 已停止" \
        || err "容器不存在或停止失败"
}

wx_uninstall() {
    check_root
    if ! wx_installed; then
        err "尚未安装 WxChat"
        return 1
    fi
    if ask_yn "确认卸载 WxChat?" "Y"; then
        docker rm -f "$WX_NAME" >/dev/null 2>&1
        docker rmi "$WX_IMAGE" >/dev/null 2>&1
        rm -f "$WX_CONF"
        info "WxChat 已卸载"
    else
        info "已取消"
    fi
}

wx_status() {
    load_wx_conf
    if wx_running; then
        info "运行状态: ${GREEN}运行中${PLAIN} (端口 ${WX_PORT})"
        docker ps --filter "name=${WX_NAME}" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        info "健康探测:"
        curl -fsS --max-time 5 -o /dev/null -w "  HTTP %{http_code} (%{time_total}s)\n" "http://127.0.0.1:${WX_PORT}" \
            || echo -e "  ${RED}本机端口 ${WX_PORT} 无响应${PLAIN}"
    elif wx_installed; then
        warn "运行状态: ${RED}已停止${PLAIN}"
        docker ps -a --filter "name=${WX_NAME}" --format "table {{.Names}}\t{{.Status}}"
    else
        err "尚未安装 WxChat"
        return 1
    fi
    echo ""
    info "当前公网IP: $(get_pub_ip)  (企业微信可信IP填这个)"
}

wx_logs() {
    if wx_installed; then
        docker logs --tail 50 -f "$WX_NAME"
    else
        err "尚未安装 WxChat"
    fi
}

wx_menu() {
    while true; do
        load_wx_conf
        local tag="  ${RED}[未安装]${PLAIN}"
        wx_running && tag="  ${GREEN}[运行中 · 端口 ${WX_PORT}]${PLAIN}"
        wx_installed && ! wx_running && tag="  ${YELLOW}[已停止]${PLAIN}"
        clear
        echo -e "${CYAN}╔════════════════════════════════════════════╗"
        echo -e "║     ${BOLD}WxChat 微信通知代理 管理菜单${PLAIN}${CYAN}          ║"
        echo -e "╚════════════════════════════════════════════╝${PLAIN}"
        echo ""
        echo -e "  当前状态: ${tag}"
        echo ""
        echo -e "  ${GREEN}${BOLD}1${PLAIN}. 安装 WxChat"
        echo -e "  ${GREEN}${BOLD}2${PLAIN}. 更新 WxChat (拉最新镜像重建)"
        echo -e "  ${GREEN}${BOLD}3${PLAIN}. 重启 WxChat"
        echo -e "  ${GREEN}${BOLD}4${PLAIN}. 停止 WxChat"
        echo -e "  ${GREEN}${BOLD}5${PLAIN}. 卸载 WxChat"
        echo -e "  ${GREEN}${BOLD}6${PLAIN}. 查看运行状态 / 公网IP"
        echo -e "  ${GREEN}${BOLD}7${PLAIN}. 查看实时日志"
        echo -e "  ${RED}${BOLD}0${PLAIN}. 返回上级菜单"
        echo ""
        line
        read -rp "请输入选项 [0-7]: " sub
        case "$sub" in
            1) wx_install;    pause_back ;;
            2) wx_update;     pause_back ;;
            3) wx_restart;    pause_back ;;
            4) wx_stop;       pause_back ;;
            5) wx_uninstall;  pause_back ;;
            6) wx_status;     pause_back ;;
            7) wx_logs ;;
            0) return 0 ;;
            *) warn "无效选项, 请重新输入"; sleep 1 ;;
        esac
    done
}

# ============================================================
#  第二部分: frps 服务端 (frp 内网穿透)
# ============================================================

FRPS_INSTALL_DIR="/usr/local/frp"
FRPS_CONF_DIR="/etc/frp"
FRPS_CONF_FILE="${FRPS_CONF_DIR}/frps.toml"
FRPS_BIN="${FRPS_INSTALL_DIR}/frps"
FRPS_SERVICE="/etc/systemd/system/frps.service"
FRPS_CONF_BAK="${ZIYONG_DIR}/frps.toml.bak"

frps_installed() { [ -f "$FRPS_BIN" ]; }
frps_running()   { systemctl is-active --quiet frps 2>/dev/null; }

frps_install() {
    check_root
    local r1 r2 r3 r4
    r1=$(random_free_port); r2=$(random_free_port); r3=$(random_free_port); r4=$(random_free_port)
    echo ""
    if frps_installed; then
        warn "检测到已安装 frps, 重装将覆盖配置 (旧配置备份到 ${FRPS_CONF_BAK})"
        mkdir -p "$ZIYONG_DIR"
        cp -f "$FRPS_CONF_FILE" "$FRPS_CONF_BAK" 2>/dev/null
    fi
    read -rp "frp 通信端口 [直接回车=随机空闲端口 ${r1}]: " p1;        [ -n "$p1" ] && BIND_PORT="$p1" || BIND_PORT="$r1"
    read -rp "面板端口, 0不开 [直接回车=随机空闲端口 ${r2}]: " p2;      [ -n "$p2" ] && DASHBOARD_PORT="$p2" || DASHBOARD_PORT="$r2"
    read -rp "http穿透端口, 0不启用 [直接回车=随机空闲端口 ${r3}]: " p3;  [ -n "$p3" ] && VHOST_HTTP_PORT="$p3" || VHOST_HTTP_PORT="$r3"
    read -rp "https穿透端口, 0不启用 [直接回车=随机空闲端口 ${r4}]: " p4; [ -n "$p4" ] && VHOST_HTTPS_PORT="$p4" || VHOST_HTTPS_PORT="$r4"

    local ver arch url tmp
    ver=$(get_latest_version)
    arch=$(detect_arch)
    url="https://github.com/fatedier/frp/releases/download/v${ver}/frp_${ver}_linux_${arch}.tar.gz"
    info "下载 frp v${ver} (linux/${arch}) ..."
    tmp=$(mktemp -d)
    download "$url" "${tmp}/frp.tar.gz" || { err "下载失败, 请检查网络后重试"; rm -rf "$tmp"; return 1; }

    mkdir -p "$FRPS_INSTALL_DIR" "$FRPS_CONF_DIR" "$ZIYONG_DIR"
    tar -xzf "${tmp}/frp.tar.gz" -C "$tmp"
    cp "${tmp}/frp_${ver}_linux_${arch}/frps" "$FRPS_BIN" || { err "解压失败"; rm -rf "$tmp"; return 1; }
    chmod +x "$FRPS_BIN"
    rm -rf "$tmp"
    info "frps 二进制已安装到 ${FRPS_BIN}"

    local token dashboard_block dashboard_user dashboard_pwd
    token=$(gen_token)

    if [ "$DASHBOARD_PORT" != "0" ]; then
        dashboard_user="admin"
        dashboard_pwd=$(gen_token | head -c 12)
        dashboard_block="webServer.port = ${DASHBOARD_PORT}
webServer.user = \"${dashboard_user}\"
webServer.password = \"${dashboard_pwd}\""
    else
        dashboard_block=""
    fi

    {
        echo "bindPort = ${BIND_PORT}"
        echo "auth.token = \"${token}\""
        [ "$VHOST_HTTP_PORT" != "0" ]  && echo "vhostHTTPPort = ${VHOST_HTTP_PORT}"
        [ "$VHOST_HTTPS_PORT" != "0" ] && echo "vhostHTTPSPort = ${VHOST_HTTPS_PORT}"
        [ -n "$dashboard_block" ] && echo "$dashboard_block"
    } > "$FRPS_CONF_FILE"

    cat > "$FRPS_SERVICE" <<EOF
[Unit]
Description=frps service (frp server)
After=network.target

[Service]
Type=simple
ExecStart=${FRPS_BIN} -c ${FRPS_CONF_FILE}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now frps || { err "服务启动失败, 请查看: journalctl -u frps -e"; return 1; }
    sleep 1

    open_firewall_ports "$BIND_PORT" "$DASHBOARD_PORT" "$VHOST_HTTP_PORT" "$VHOST_HTTPS_PORT"

    local pub_ip
    pub_ip=$(get_pub_ip)
    echo ""
    line
    info "frps 安装完成并已启动!"
    echo -e "  ${BOLD}frp 通信地址:${PLAIN} ${pub_ip}:${BIND_PORT}"
    echo -e "  ${BOLD}token:${PLAIN} ${YELLOW}${BOLD}${token}${PLAIN}"
    if [ "$DASHBOARD_PORT" != "0" ]; then
        echo -e "  ${BOLD}面板地址:${PLAIN} http://${pub_ip}:${DASHBOARD_PORT}  (账号 ${dashboard_user} / ${dashboard_pwd})"
    fi
    [ "$VHOST_HTTP_PORT" != "0" ]  && echo -e "  ${BOLD}http穿透端口:${PLAIN} ${VHOST_HTTP_PORT}"
    [ "$VHOST_HTTPS_PORT" != "0" ] && echo -e "  ${BOLD}https穿透端口:${PLAIN} ${VHOST_HTTPS_PORT}"
    echo ""
    warn "配置文件: ${FRPS_CONF_FILE}   客户端 frpc.toml 需填同一 token"
    line
}

frps_update() {
    check_root
    if ! frps_installed; then
        err "尚未安装 frps, 请先执行安装"
        return 1
    fi
    info "当前版本: $("$FRPS_BIN" -v 2>/dev/null)"
    local ver arch url tmp
    ver=$(get_latest_version)
    arch=$(detect_arch)
    url="https://github.com/fatedier/frp/releases/download/v${ver}/frp_${ver}_linux_${arch}.tar.gz"
    info "更新到 v${ver} ..."
    tmp=$(mktemp -d)
    download "$url" "${tmp}/frp.tar.gz" || { err "下载失败"; rm -rf "$tmp"; return 1; }
    tar -xzf "${tmp}/frp.tar.gz" -C "$tmp"
    systemctl stop frps 2>/dev/null
    cp "${tmp}/frp_${ver}_linux_${arch}/frps" "$FRPS_BIN" && chmod +x "$FRPS_BIN"
    rm -rf "$tmp"
    systemctl start frps
    info "更新完成, 当前版本: $("$FRPS_BIN" -v 2>/dev/null)"
}

frps_restart() { frps_installed && systemctl restart frps && info "frps 已重启" || err "尚未安装 frps"; }
frps_start()   { frps_installed && systemctl start frps   && info "frps 已启动" || err "尚未安装 frps"; }
frps_stop()    { frps_installed && systemctl stop frps    && info "frps 已停止" || err "尚未安装 frps"; }

frps_uninstall() {
    check_root
    if ! frps_installed; then
        err "尚未安装 frps"
        return 1
    fi
    if ask_yn "确认卸载 frps? 配置和 token 将被删除" "Y"; then
        systemctl disable --now frps >/dev/null 2>&1
        rm -f "$FRPS_SERVICE" "$FRPS_BIN" "$FRPS_CONF_FILE" "$FRPS_CONF_BAK"
        systemctl daemon-reload
        info "frps 已卸载"
    else
        info "已取消"
    fi
}

frps_status() {
    if ! frps_installed; then
        err "尚未安装 frps"
        return 1
    fi
    info "版本: $("$FRPS_BIN" -v 2>/dev/null)"
    if frps_running; then
        info "运行状态: ${GREEN}运行中${PLAIN}"
    else
        warn "运行状态: ${RED}已停止${PLAIN}"
    fi
    echo ""
    info "端口监听:"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | grep -E "frps|$(grep -oE 'bindPort = [0-9]+' "$FRPS_CONF_FILE" 2>/dev/null | grep -oE '[0-9]+')" \
            || echo -e "  ${RED}无监听, 服务可能异常${PLAIN}"
    fi
    echo ""
    if [ -f "$FRPS_CONF_FILE" ]; then
        info "当前配置 (${FRPS_CONF_FILE}):"
        grep -E "bindPort|token|vhost|webServer" "$FRPS_CONF_FILE" | sed 's/^/  /'
    fi
    echo ""
    info "当前公网IP: $(get_pub_ip)"
}

frps_logs() {
    if frps_installed; then
        journalctl -u frps -n 50 --no-pager
        echo ""
        warn "以上为最近50行, 实时跟踪: journalctl -u frps -f"
    else
        err "尚未安装 frps"
    fi
}

frps_show_token() {
    if [ -f "$FRPS_CONF_FILE" ]; then
        info "配置内容 (${FRPS_CONF_FILE}):"
        cat "$FRPS_CONF_FILE"
    else
        err "尚未安装 frps"
    fi
}

frps_edit() {
    check_root
    if [ ! -f "$FRPS_CONF_FILE" ]; then
        err "尚未安装 frps"
        return 1
    fi
    ${EDITOR:-vi} "$FRPS_CONF_FILE"
    if ask_yn "配置已修改, 立即重启 frps?" "Y"; then
        systemctl restart frps && info "frps 已重启"
    else
        info "已跳过重启, 请手动执行: systemctl restart frps"
    fi
}

frps_menu() {
    while true; do
        local tag="  ${RED}[未安装]${PLAIN}"
        frps_running && tag="  ${GREEN}[运行中]${PLAIN}"
        frps_installed && ! frps_running && tag="  ${YELLOW}[已停止]${PLAIN}"
        clear
        echo -e "${CYAN}╔════════════════════════════════════════════╗"
        echo -e "║       ${BOLD}frps 服务端 (内网穿透) 管理菜单${PLAIN}${CYAN}     ║"
        echo -e "╚════════════════════════════════════════════╝${PLAIN}"
        echo ""
        echo -e "  当前状态: ${tag}"
        echo ""
        echo -e "  ${GREEN}${BOLD}1${PLAIN}.  安装 frps"
        echo -e "  ${GREEN}${BOLD}2${PLAIN}.  更新 frps (拉取最新版本)"
        echo -e "  ${GREEN}${BOLD}3${PLAIN}.  重启 frps"
        echo -e "  ${GREEN}${BOLD}4${PLAIN}.  启动 frps"
        echo -e "  ${GREEN}${BOLD}5${PLAIN}.  停止 frps"
        echo -e "  ${GREEN}${BOLD}6${PLAIN}.  卸载 frps"
        echo -e "  ${GREEN}${BOLD}7${PLAIN}.  查看状态 / 配置 / 公网IP"
        echo -e "  ${GREEN}${BOLD}8${PLAIN}.  查看日志 (最近50行)"
        echo -e "  ${GREEN}${BOLD}9${PLAIN}.  查看 token / 配置文件"
        echo -e "  ${GREEN}${BOLD}10${PLAIN}. 编辑配置文件 (改端口/token)"
        echo -e "  ${RED}${BOLD}0${PLAIN}.  返回上级菜单"
        echo ""
        line
        read -rp "请输入选项 [0-10]: " sub
        case "$sub" in
            1)  frps_install;    pause_back ;;
            2)  frps_update;     pause_back ;;
            3)  frps_restart;    pause_back ;;
            4)  frps_start;      pause_back ;;
            5)  frps_stop;       pause_back ;;
            6)  frps_uninstall;  pause_back ;;
            7)  frps_status;     pause_back ;;
            8)  frps_logs;       pause_back ;;
            9)  frps_show_token; pause_back ;;
            10) frps_edit ;;
            0)  return 0 ;;
            *)  warn "无效选项, 请重新输入"; sleep 1 ;;
        esac
    done
}

# ============================================================
#  主菜单
# ============================================================

show_main_menu() {
    local wx_tag="  ${RED}[未安装]${PLAIN}"
    local frps_tag="  ${RED}[未安装]${PLAIN}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "wxchat"; then
        wx_tag="  ${GREEN}[运行中]${PLAIN}"
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "wxchat"; then
        wx_tag="  ${YELLOW}[已停止]${PLAIN}"
    fi
    if systemctl is-active --quiet frps 2>/dev/null; then
        frps_tag="  ${GREEN}[运行中]${PLAIN}"
    elif [ -f "/etc/systemd/system/frps.service" ]; then
        frps_tag="  ${YELLOW}[已停止]${PLAIN}"
    fi
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════╗"
    echo -e "║      ${BOLD}ziyong 自用 VPS 服务 一键管理脚本${PLAIN}${CYAN}      ║"
    echo -e "╚════════════════════════════════════════════╝${PLAIN}"
    echo ""
    echo -e "  ${GREEN}${BOLD}1${PLAIN}. WxChat 微信通知转发代理 (Docker)${wx_tag}"
    echo -e "  ${GREEN}${BOLD}2${PLAIN}. frps 服务端 (frp 内网穿透)${frps_tag}"
    echo -e "  ${RED}${BOLD}0${PLAIN}. 退出"
    echo ""
    line
    read -rp "请选择要管理的服务 [0-2]: " main_choice
}

main() {
    setup_shortcut
    while true; do
        show_main_menu
        case "$main_choice" in
            1) wx_menu ;;
            2) frps_menu ;;
            0) info "再见!"; exit 0 ;;
            *) warn "无效选项, 请重新输入"; sleep 1 ;;
        esac
    done
}

main "$@"
