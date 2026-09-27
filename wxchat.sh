#!/usr/bin/env bash
# ============================================================
#  WxChat 一键安装管理脚本 (VPS / SSH 可视化菜单)
#  作者: nono哥
#  用法:
#    本地执行:   bash wxchat.sh
#    一键远程:   bash <(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/<你的仓库名>/main/wxchat.sh)
#  功能:
#    1. 安装 WxChat (Docker)
#    2. 更新 / 重启 / 停止 / 卸载
#    3. 查看状态 / 日志 / 公网IP(企业微信可信IP)
# ============================================================

set -o pipefail

# ---------------- 可按需修改的配置 ----------------
APP_NAME="wxchat"
IMAGE="ddsderek/wxchat:latest"
PORT="15680"          # 宿主机端口, 安装时可修改
CONTAINER_PORT="80"
# --------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

line() { echo -e "${CYAN}────────────────────────────────────────────${PLAIN}"; }

info()    { echo -e "${GREEN}[信息]${PLAIN} $*"; }
warn()    { echo -e "${YELLOW}[注意]${PLAIN} $*"; }
err()     { echo -e "${RED}[错误]${PLAIN} $*"; }

# ---------- 环境检查 ----------
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

# ---------- Docker 安装 ----------
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
    command -v docker >/dev/null 2>&1 || { err "Docker 安装失败, 请手动安装后重试"; exit 1; }
    systemctl enable --now docker >/dev/null 2>&1
    info "Docker 安装完成: $(docker -v)"
}

# ---------- 核心操作 ----------
do_install() {
    check_root
    install_docker
    echo ""
    read -rp "请输入宿主机端口 [默认 ${PORT}]: " input_port
    [ -n "$input_port" ] && PORT="$input_port"

    if docker ps -a --format '{{.Names}}' | grep -qx "$APP_NAME"; then
        warn "检测到已存在的 ${APP_NAME} 容器, 先删除旧容器..."
        docker rm -f "$APP_NAME" >/dev/null 2>&1
    fi

    info "拉取镜像 ${IMAGE} ..."
    docker pull "$IMAGE" || { err "镜像拉取失败, 请检查网络后重试"; return 1; }

    info "启动容器 (端口 ${PORT} -> ${CONTAINER_PORT}) ..."
    docker run -d \
        --name "$APP_NAME" \
        --restart=always \
        -p "${PORT}:${CONTAINER_PORT}" \
        "$IMAGE" || { err "容器启动失败"; return 1; }

    PUB_IP=$(get_pub_ip)
    echo ""
    line
    info "WxChat 安装完成!"
    echo -e "  ${BOLD}访问地址:${PLAIN} http://${PUB_IP}:${PORT}"
    echo -e "  ${BOLD}通知代理:${PLAIN} http://${PUB_IP}:${PORT} (同地址)"
    echo ""
    warn "重要: 请到 企业微信后台 -> 应用 -> 可信IP, 填入: ${YELLOW}${BOLD}${PUB_IP}${PLAIN}"
    line
}

do_update() {
    check_root
    if ! docker ps -a --format '{{.Names}}' | grep -qx "$APP_NAME"; then
        err "尚未安装 ${APP_NAME}, 请先执行安装"
        return 1
    fi
    info "更新 WxChat (拉取最新镜像并重建容器)..."
    docker pull "$IMAGE" && docker rm -f "$APP_NAME"
    docker run -d --name "$APP_NAME" --restart=always -p "${PORT}:${CONTAINER_PORT}" "$IMAGE"
    info "更新完成"
}

do_restart() {
    docker restart "$APP_NAME" >/dev/null 2>&1 \
        && info "WxChat 已重启" \
        || err "容器不存在或重启失败"
}

do_stop() {
    docker stop "$APP_NAME" >/dev/null 2>&1 \
        && info "WxChat 已停止" \
        || err "容器不存在或停止失败"
}

do_uninstall() {
    check_root
    read -rp "确认卸载 WxChat? 数据将被删除 [y/N]: " confirm
    case "$confirm" in
        [yY]|[yY][eE][sS])
            docker rm -f "$APP_NAME" >/dev/null 2>&1
            docker rmi "$IMAGE" >/dev/null 2>&1
            info "WxChat 已卸载"
            ;;
        *) info "已取消" ;;
    esac
}

do_status() {
    if docker ps --format '{{.Names}}' | grep -qx "$APP_NAME"; then
        info "运行状态: ${GREEN}运行中${PLAIN}"
        docker ps --filter "name=${APP_NAME}" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        info "健康探测:"
        curl -fsS --max-time 5 -o /dev/null -w "  HTTP %{http_code} (%{time_total}s)\n" "http://127.0.0.1:${PORT}" \
            || echo -e "  ${RED}本机端口 ${PORT} 无响应${PLAIN}"
    elif docker ps -a --format '{{.Names}}' | grep -qx "$APP_NAME"; then
        warn "运行状态: ${RED}已停止${PLAIN}"
        docker ps -a --filter "name=${APP_NAME}" --format "table {{.Names}}\t{{.Status}}"
    else
        err "尚未安装 ${APP_NAME}"
    fi
    echo ""
    info "当前公网IP: $(get_pub_ip)  (企业微信可信IP填这个)"
}

do_logs() {
    if docker ps -a --format '{{.Names}}' | grep -qx "$APP_NAME"; then
        docker logs --tail 50 -f "$APP_NAME"
    else
        err "尚未安装 ${APP_NAME}"
    fi
}

# ---------- 菜单 ----------
show_menu() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════╗"
    echo -e "║        ${BOLD}WxChat 微信通知代理 管理脚本${PLAIN}${CYAN}        ║"
    echo -e "╚════════════════════════════════════════════╝${PLAIN}"
    echo ""
    echo -e "  ${GREEN}${BOLD}1${PLAIN}. 安装 WxChat"
    echo -e "  ${GREEN}${BOLD}2${PLAIN}. 更新 WxChat (拉最新镜像重建)"
    echo -e "  ${GREEN}${BOLD}3${PLAIN}. 重启 WxChat"
    echo -e "  ${GREEN}${BOLD}4${PLAIN}. 停止 WxChat"
    echo -e "  ${GREEN}${BOLD}5${PLAIN}. 卸载 WxChat"
    echo -e "  ${GREEN}${BOLD}6${PLAIN}. 查看运行状态 / 公网IP"
    echo -e "  ${GREEN}${BOLD}7${PLAIN}. 查看实时日志"
    echo -e "  ${RED}${BOLD}0${PLAIN}. 退出"
    echo ""
    line
    read -rp "请输入选项 [0-7]: " choice
}

main() {
    while true; do
        show_menu
        case "$choice" in
            1) do_install;   read -rp "按回车返回菜单..." _ ;;
            2) do_update;    read -rp "按回车返回菜单..." _ ;;
            3) do_restart;   read -rp "按回车返回菜单..." _ ;;
            4) do_stop;      read -rp "按回车返回菜单..." _ ;;
            5) do_uninstall; read -rp "按回车返回菜单..." _ ;;
            6) do_status;    read -rp "按回车返回菜单..." _ ;;
            7) do_logs ;;
            0) info "再见!"; exit 0 ;;
            *) warn "无效选项, 请重新输入"; sleep 1 ;;
        esac
    done
}

main "$@"
