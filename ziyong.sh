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
# ============================================================

set -o pipefail

# ================= 通用基础 =================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

line() { echo -e "${CYAN}────────────────────────────────────────────${PLAIN}"; }
info() { echo -e "${GREEN}[信息]${PLAIN} $*"; }
warn() { echo -e "${YELLOW}[注意]${PLAIN} $*"; }
err()  { echo -e "${RED}[错误]${PLAIN} $*"; }

pause_back() { read -rp "按回车返回菜单..." _; }

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

# ============================================================
#  第一部分: WxChat 微信通知转发代理
# ============================================================

WX_IMAGE="ddsderek/wxchat:latest"
WX_NAME="wxchat"
WX_PORT="15680"

wx_install() {
    check_root
    install_docker || return 1
    echo ""
    read -rp "请输入宿主机端口 [默认 ${WX_PORT}]: " input_port
    [ -n "$input_port" ] && WX_PORT="$input_port"

    if docker ps -a --format '{{.Names}}' | grep -qx "$WX_NAME"; then
        warn "检测到已存在的 ${WX_NAME} 容器, 先删除旧容器..."
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
    if ! docker ps -a --format '{{.Names}}' | grep -qx "$WX_NAME"; then
        err "尚未安装 WxChat, 请先执行安装"
        return 1
    fi
    info "更新 WxChat (拉最新镜像重建容器)..."
    docker pull "$WX_IMAGE" && docker rm -f "$WX_NAME"
    docker run -d --name "$WX_NAME" --restart=always -p "${WX_PORT}:80" "$WX_IMAGE"
    info "更新完成"
}

wx_restart() {
    docker restart "$WX_NAME" >/dev/null 2>&1 \
        && info "WxChat 已重启" \
        || err "容器不存在或重启失败"
}

wx_stop() {
    docker stop "$WX_NAME" >/dev/null 2>&1 \
        && info "WxChat 已停止" \
        || err "容器不存在或停止失败"
}

wx_uninstall() {
    check_root
    read -rp "确认卸载 WxChat? [y/N]: " confirm
    case "$confirm" in
        [yY]|[yY][eE][sS])
            docker rm -f "$WX_NAME" >/dev/null 2>&1
            docker rmi "$WX_IMAGE" >/dev/null 2>&1
            info "WxChat 已卸载"
            ;;
        *) info "已取消" ;;
    esac
}

wx_status() {
    if docker ps --format '{{.Names}}' | grep -qx "$WX_NAME"; then
        info "运行状态: ${GREEN}运行中${PLAIN}"
        docker ps --filter "name=${WX_NAME}" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        info "健康探测:"
        curl -fsS --max-time 5 -o /dev/null -w "  HTTP %{http_code} (%{time_total}s)\n" "http://127.0.0.1:${WX_PORT}" \
            || echo -e "  ${RED}本机端口 ${WX_PORT} 无响应${PLAIN}"
    elif docker ps -a --format '{{.Names}}' | grep -qx "$WX_NAME"; then
        warn "运行状态: ${RED}已停止${PLAIN}"
        docker ps -a --filter "name=${WX_NAME}" --format "table {{.Names}}\t{{.Status}}"
    else
        err "尚未安装 WxChat"
    fi
    echo ""
    info "当前公网IP: $(get_pub_ip)  (企业微信可信IP填这个)"
}

wx_logs() {
    if docker ps -a --format '{{.Names}}' | grep -qx "$WX_NAME"; then
        docker logs --tail 50 -f "$WX_NAME"
    else
        err "尚未安装 WxChat"
    fi
}

wx_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔════════════════════════════════════════════╗"
        echo -e "║     ${BOLD}WxChat 微信通知代理 管理菜单${PLAIN}${CYAN}          ║"
        echo -e "╚════════════════════════════════════════════╝${PLAIN}"
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
BIND_PORT="7000"
DASHBOARD_PORT="7500"
VHOST_HTTP_PORT="8080"
VHOST_HTTPS_PORT="8443"

frps_install() {
    check_root
    echo ""
    read -rp "frp 通信端口 [默认 ${BIND_PORT}]: " p1;      [ -n "$p1" ] && BIND_PORT="$p1"
    read -rp "面板端口, 0不开 [默认 ${DASHBOARD_PORT}]: " p2; [ -n "$p2" ] && DASHBOARD_PORT="$p2"
    read -rp "http穿透端口, 0不启用 [默认 ${VHOST_HTTP_PORT}]: " p3;  [ -n "$p3" ] && VHOST_HTTP_PORT="$p3"
    read -rp "https穿透端口, 0不启用 [默认 ${VHOST_HTTPS_PORT}]: " p4; [ -n "$p4" ] && VHOST_HTTPS_PORT="$p4"

    local ver arch url tmp
    ver=$(get_latest_version)
    arch=$(detect_arch)
    url="https://github.com/fatedier/frp/releases/download/v${ver}/frp_${ver}_linux_${arch}.tar.gz"
    info "下载 frp v${ver} (linux/${arch}) ..."
    tmp=$(mktemp -d)
    download "$url" "${tmp}/frp.tar.gz" || { err "下载失败, 请检查网络后重试"; rm -rf "$tmp"; return 1; }

    mkdir -p "$FRPS_INSTALL_DIR" "$FRPS_CONF_DIR"
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
    warn "防火墙/安全组请放行以上端口 (TCP)"
    line
}

frps_update() {
    check_root
    if [ ! -f "$FRPS_BIN" ]; then
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

frps_restart() { systemctl restart frps && info "frps 已重启"; }
frps_start()   { systemctl start frps   && info "frps 已启动"; }
frps_stop()    { systemctl stop frps    && info "frps 已停止"; }

frps_uninstall() {
    check_root
    read -rp "确认卸载 frps? 配置和 token 将被删除 [y/N]: " confirm
    case "$confirm" in
        [yY]|[yY][eE][sS])
            systemctl disable --now frps >/dev/null 2>&1
            rm -f "$FRPS_SERVICE" "$FRPS_BIN" "$FRPS_CONF_FILE"
            systemctl daemon-reload
            info "frps 已卸载"
            ;;
        *) info "已取消" ;;
    esac
}

frps_status() {
    if [ ! -f "$FRPS_BIN" ]; then
        err "尚未安装 frps"
        return 1
    fi
    info "版本: $("$FRPS_BIN" -v 2>/dev/null)"
    if systemctl is-active --quiet frps; then
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
    if [ ! -f "$FRPS_SERVICE" ]; then
        err "尚未安装 frps"
        return 1
    fi
    journalctl -u frps -n 50 --no-pager
    echo ""
    warn "以上为最近50行, 实时跟踪: journalctl -u frps -f"
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
    read -rp "配置已修改, 立即重启 frps? [Y/n]: " r
    case "$r" in
        [nN]*) info "已跳过重启, 请手动执行: systemctl restart frps" ;;
        *)     systemctl restart frps && info "frps 已重启" ;;
    esac
}

frps_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔════════════════════════════════════════════╗"
        echo -e "║       ${BOLD}frps 服务端 (内网穿透) 管理菜单${PLAIN}${CYAN}     ║"
        echo -e "╚════════════════════════════════════════════╝${PLAIN}"
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
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════╗"
    echo -e "║      ${BOLD}ziyong 自用 VPS 服务 一键管理脚本${PLAIN}${CYAN}      ║"
    echo -e "╚════════════════════════════════════════════╝${PLAIN}"
    echo ""
    echo -e "  ${GREEN}${BOLD}1${PLAIN}. WxChat 微信通知转发代理 (Docker)"
    echo -e "  ${GREEN}${BOLD}2${PLAIN}. frps 服务端 (frp 内网穿透)"
    echo -e "  ${RED}${BOLD}0${PLAIN}. 退出"
    echo ""
    line
    read -rp "请选择要管理的服务 [0-2]: " main_choice
}

main() {
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
