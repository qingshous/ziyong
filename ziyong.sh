#!/usr/bin/env bash
# ============================================================
#  ziyong.sh - 自用 VPS 服务合集 一键脚本 (SSH 可视化菜单)
#  作者: nono哥
#  用法:
#    本地执行:   bash ziyong.sh
#    一键远程:   bash <(curl -fsSL https://raw.githubusercontent.com/qingshous/ziyong/main/ziyong.sh)
#  当前包含:
#    1. WxChat (Docker 版)   官方镜像 ddsderek/wxchat
#    2. WxChat (nginx 版)    nginx 原生反代, 无需Docker, 兼容低配NAT机
#    3. frps                 frp 服务端 (官方二进制 + systemd)
#    4. sing-box            节点管理 (调度: qingshous/sing-box-sh)
#    5. realm (xwPF)        端口转发管理 (调度: qingshous/realm-xwPF)
#    6. realm (轻量版)      精简转发管理 (调度: qingshous/realm-installer, 快捷命令 rl)
#    7. iperf3              测速服务端 (原生软件包 + 三通道托管, 测完可一键停用)
#  特性:
#    - 端口默认随机分配(自动避开占用), 回车即可, 输入有合法性校验
#    - NAT 网络自动检测, 提醒使用服务商映射端口
#    - y/n 交互默认 Y, 回车=默认, 误触空格等无效输入会重新询问
#    - 安装信息持久化 (/etc/ziyong/), 重跑脚本不丢配置
#    - 兼容无 systemd 的 NAT 机 (nginx/frps 自动切 OpenRC 或 nohup 模式)
#    - 端口输入有合法性+占用双重校验
#    - token 相关文件权限收紧 600
#    - 运行状态以端口真实响应为准, 不依赖 pgrep/ss/curl
#    - 自动检测 ufw/firewalld 并放行端口
#    - 快捷命令: 首次运行后任意位置输入 slib 打开本脚本
#    - 主菜单可一键自更新 (对比 VERSION)
# ============================================================

set -o pipefail

VERSION="1.14.0"

# ================= 通用基础 =================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

ZIYONG_DIR="/etc/ziyong"
WX_NGINX_CONF_PERSIST="${ZIYONG_DIR}/wxchat.conf"
WX_DOCKER_CONF_PERSIST="${ZIYONG_DIR}/wxchat-docker.conf"

line() { echo -e "${CYAN}────────────────────────────────────────────${PLAIN}"; }
info() { echo -e "${GREEN}[信息]${PLAIN} $*"; }
warn() { echo -e "${YELLOW}[注意]${PLAIN} $*"; }
err()  { echo -e "${RED}[错误]${PLAIN} $*"; }

# 版本号数字比较: 返回 0 表示 $1 < $2 (即 $2 更新)。仅支持 x.y.z 纯数字段。
ver_lt() {
    local a="$1" b="$2" pa pb
    IFS='.' read -r -a pa <<< "$a"
    IFS='.' read -r -a pb <<< "$b"
    local i=0
    while [ "$i" -lt 3 ]; do
        local na="${pa[$i]:-0}" nb="${pb[$i]:-0}"
        # 非纯数字段按字符串比较, 避免 10 < 9 的坑
        case "$na" in *[!0-9]*) [ "$na" = "$nb" ] || { [ "$na" \< "$nb" ] && return 0; return 1; } ;; esac
        case "$nb" in *[!0-9]*) [ "$na" = "$nb" ] || { [ "$na" \< "$nb" ] && return 0; return 1; } ;; esac
        if [ "$na" -lt "$nb" ]; then return 0; fi
        if [ "$na" -gt "$nb" ]; then return 1; fi
        i=$((i+1))
    done
    return 1   # 相等或超出 3 段
}

pause_back() { read -rp "按回车返回菜单..." _; }

# ask_yn "提示文字" [默认Y|N]  -> 返回0=是
# 只有回车才走默认值, 空格/乱输入视为无效重新询问 (防误触确认)
ask_yn() {
    local prompt="$1" def="${2:-Y}" ans
    while :; do
        if [ "$def" = "Y" ]; then
            read -rp "${prompt} [回车=是, n=否]: " ans
        else
            read -rp "${prompt} [y=是, 回车=否]: " ans
        fi
        case "$ans" in
            "")                 [ "$def" = "Y" ] && return 0 || return 1 ;;
            y|Y|yes|YES|Yes)    return 0 ;;
            n|N|no|NO|No)       return 1 ;;
            *) echo -e "${YELLOW}[注意]${PLAIN} 无效输入, 请输 y 或 n (回车=默认)" ;;
        esac
    done
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

# 获取公网 IPv4 (仅 v4, 无则空)
get_pub_ipv4() {
    local ip=""
    ip=$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -4 -fsSL --max-time 5 https://ip.sb 2>/dev/null) \
        || ip=$(curl -4 -fsSL --max-time 5 https://4.ipw.cn 2>/dev/null)
    # 校验为纯 IPv4 才返回, 否则空 (防代理出口返回 v6)
    case "$ip" in
        *[!0-9.]*) return 0 ;;
    esac
    [ -n "$ip" ] && echo "$ip"
}

# 获取本机公网 IPv6 (探测本机网卡上的公网段, 非出口地址)
# NAT 机的出口 v6 可能是上游 NAT66 地址, 不可入站; 本机网卡上 2000:~3fff: 段才是真正可用的公网 v6
get_pub_ipv6() {
    local line addr
    if command -v ip >/dev/null 2>&1; then
        while read -r line; do
            addr=$(printf '%s\n' "$line" | sed -n 's/.*inet6 \([0-9a-fA-F:]*\)\/.*/\1/p')
            [ -z "$addr" ] && continue
            case "$addr" in
                ::1|fe80:*|fd*|fc*) continue ;;   # 跳过回环/链路本地/ULA 私有段
            esac
            case "$addr" in
                2[0-9a-fA-F]*|3[0-9a-fA-F]*) echo "$addr"; return ;;   # 2/3 开头 = 公网可路由段
            esac
        done < <(ip -6 addr show 2>/dev/null)
    elif command -v ifconfig >/dev/null 2>&1; then
        while read -r line; do
            addr=$(printf '%s\n' "$line" | sed -n 's/.*inet6 addr: *\([0-9a-fA-F:]*\)\/.*/\1/p')
            [ -z "$addr" ] && continue
            case "$addr" in
                ::1|fe80:*|fd*|fc*) continue ;;
            esac
            case "$addr" in
                2[0-9a-fA-F]*|3[0-9a-fA-F]*) echo "$addr"; return ;;
            esac
        done < <(ifconfig 2>/dev/null)
    fi
    # 本机网卡上无公网 v6 -> 空 (NAT 机/无 v6 机器)
}

gen_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32
    fi
}

# 是否有可用 systemd (NAT 机/容器常没有)
has_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

# 是否有运行中的 OpenRC (Alpine 等, rc-service 可用)
has_openrc() { command -v rc-service >/dev/null 2>&1 && [ -d /run/openrc ]; }

# 通用 TCP 端口探测 (纯 bash /dev/tcp, 不依赖 ss/netstat/curl —— 低配机这些可能全缺)
tcp_port_alive() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
    return 1
}

# 随机取一个 20000-59999 的空闲 TCP 端口 (避开系统保留/常用段)
random_free_port() {
    local port
    while :; do
        port=$(( (RANDOM * 32768 + RANDOM) % 40000 + 20000 ))
        # tcp_port_alive 是权威探测 (低配机 ss/netstat 可能全缺); ss/netstat 仅作附加校验
        if tcp_port_alive "$port"; then continue; fi
        if (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | grep -q ":${port} "; then continue; fi
        echo "$port"; return
    done
}

# 端口合法性校验 (1-65535 纯数字)
is_valid_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# ask_port "提示" 默认值 [allow_zero] [放行端口] -> 输出合法端口
# 空输入=默认值, 非法/被占用重输; 放行端口用于重装场景容忍服务自己正在用的端口
# 注意: 函数内所有提示必须走 >&2, 否则会被 $( ) 捕获
ask_port() {
    local prompt="$1" def="$2" allow_zero="${3:-no}" allow_in_use="${4:-}" p
    while :; do
        read -rp "${prompt} [直接回车=${def}]: " p
        p="${p:-$def}"
        if ! is_valid_port "$p" && ! { [ "$allow_zero" = "yes" ] && [ "$p" = "0" ]; }; then
            echo -e "${YELLOW}[注意]${PLAIN} 端口无效: ${p} (应为 1-65535 的数字)" >&2
            continue
        fi
        if [ "$p" != "0" ] && [ "$p" != "$allow_in_use" ] && tcp_port_alive "$p"; then
            echo -e "${YELLOW}[注意]${PLAIN} 端口 ${p} 已被其他服务占用, 请换一个" >&2
            continue
        fi
        echo "$p"; return
    done
}

# NAT 网络检测 (公网IP != 本机IP), 结果缓存
# NAT 机只有服务商面板映射的端口能从外网访问, 随机端口无效
NAT_CACHE=""
is_nat() {
    [ -n "$NAT_CACHE" ] && return "$NAT_CACHE"
    local pub local_ip
    pub=$(get_pub_ip)
    local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ "$pub" = "获取失败" ] || [ -z "$local_ip" ] || [ "$pub" = "$local_ip" ]; then
        NAT_CACHE=1
    else
        NAT_CACHE=0
    fi
    return "$NAT_CACHE"
}

# NAT 环境端口提醒 (安装时调用, 交互场景直接用, 不走 $( ))
nat_port_hint() {
    if is_nat; then
        warn "检测到本机是 NAT 网络: 随机端口外网无法访问!"
        warn "请填写服务商后台分配给你的【映射端口】, 不确定就去服务商面板查"
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
        || curl -fL --max-time 120 --connect-timeout 10 "https://ghfast.top/${url}" -o "$out" 2>/dev/null \
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

# 防火墙自动放行 UDP 端口 (iperf3 -u 用)
open_firewall_ports_udp() {
    local p
    for p in "$@"; do
        [ "$p" = "0" ] && continue
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw allow "${p}/udp" >/dev/null 2>&1 && info "ufw 已放行 ${p}/udp"
        fi
        if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1 \
                && firewall-cmd --reload >/dev/null 2>&1 \
                && info "firewalld 已放行 ${p}/udp"
        fi
    done
}

# 自动安装 Docker (Docker 版 wxchat 用)
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        info "Docker 已安装: $(docker -v)"
        return 0
    fi
    if ! has_systemd; then
        err "本机无 systemd, Docker 版不适用; 请返回主菜单选 2 (nginx 版, 无需 Docker)"
        return 1
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

# 安装信息持久化 (WxChat 两个版本各自独立, 权限 600 防普通用户读取)
save_wx_conf()  { mkdir -p "$ZIYONG_DIR"; chmod 700 "$ZIYONG_DIR"; echo "WX_PORT=${WX_PORT}" > "$WX_NGINX_CONF_PERSIST"; chmod 600 "$WX_NGINX_CONF_PERSIST"; }
load_wx_conf()  { WX_PORT="15680"; [ -f "$WX_NGINX_CONF_PERSIST" ] && . "$WX_NGINX_CONF_PERSIST"; }
save_wxd_conf() { mkdir -p "$ZIYONG_DIR"; chmod 700 "$ZIYONG_DIR"; echo "WXD_PORT=${WXD_PORT}" > "$WX_DOCKER_CONF_PERSIST"; chmod 600 "$WX_DOCKER_CONF_PERSIST"; }
load_wxd_conf() { WXD_PORT="15680"; [ -f "$WX_DOCKER_CONF_PERSIST" ] && . "$WX_DOCKER_CONF_PERSIST"; }

# slib 快捷命令: 任意位置输入 slib 打开本脚本
SHORTCUT="/usr/local/bin/slib"
CACHE_SCRIPT="${ZIYONG_DIR}/ziyong.sh"

setup_shortcut() {
    # 非 root 直接跳过 (无权限写 /usr/local/bin)
    [ "$(id -u)" -eq 0 ] || return 0
    # 缓存脚本自身 (bash 文件方式运行时)
    if [ -f "${BASH_SOURCE[0]}" ]; then
        mkdir -p "$ZIYONG_DIR"
        cat "${BASH_SOURCE[0]}" > "$CACHE_SCRIPT" 2>/dev/null
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
   || curl -fsSL --max-time 15 https://ghproxy.net/https://raw.githubusercontent.com/qingshous/ziyong/main/ziyong.sh -o /tmp/ziyong.sh 2>/dev/null \
   || curl -fsSL --max-time 15 https://gh-proxy.com/https://raw.githubusercontent.com/qingshous/ziyong/main/ziyong.sh -o /tmp/ziyong.sh 2>/dev/null \
   || curl -fsSL --max-time 15 https://ghfast.top/https://raw.githubusercontent.com/qingshous/ziyong/main/ziyong.sh -o /tmp/ziyong.sh 2>/dev/null; then
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
#  第一部分: WxChat 微信通知转发代理 (Docker 版)
#  官方镜像 ddsderek/wxchat:latest
# ============================================================

WXD_IMAGE="ddsderek/wxchat:latest"
WXD_NAME="wxchat"

wxd_installed() { command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$WXD_NAME"; }
wxd_running()   { command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$WXD_NAME"; }

wxd_install() {
    check_root
    load_wxd_conf
    install_docker || return 1
    if wx_installed; then
        warn "提示: nginx 版 WxChat 也在这台机器上, 注意两个版本用不同端口"
    fi
    echo ""
    nat_port_hint
    local allow=""
    wxd_installed && { load_wxd_conf; allow="$WXD_PORT"; }
    WXD_PORT=$(ask_port "请输入宿主机端口" "$(random_free_port)" no "$allow")

    if wxd_installed; then
        warn "检测到已存在的 ${WXD_NAME} 容器, 先删除旧容器..."
        docker rm -f "$WXD_NAME" >/dev/null 2>&1
    fi

    info "拉取镜像 ${WXD_IMAGE} ..."
    docker pull "$WXD_IMAGE" || { err "镜像拉取失败, 请检查网络后重试"; return 1; }

    info "启动容器 (端口 ${WXD_PORT} -> 80) ..."
    docker run -d \
        --name "$WXD_NAME" \
        --restart=always \
        -p "${WXD_PORT}:80" \
        "$WXD_IMAGE" || { err "容器启动失败"; return 1; }

    save_wxd_conf
    open_firewall_ports "$WXD_PORT"

    local pub_ip
    pub_ip=$(get_pub_ip)
    echo ""
    line
    info "WxChat (Docker 版) 安装完成!"
    echo -e "  ${BOLD}访问地址:${PLAIN} http://${pub_ip}:${WXD_PORT}"
    echo -e "  ${BOLD}通知代理:${PLAIN} http://${pub_ip}:${WXD_PORT} (同地址)"
    echo ""
    warn "重要: 请到 企业微信后台 -> 应用 -> 可信IP, 填入: ${YELLOW}${BOLD}${pub_ip}${PLAIN}"
    is_nat && warn "NAT 机注意: 请确认端口 ${WXD_PORT} 已在服务商面板做映射, 否则外网访问不到"
    line
}

wxd_update() {
    check_root
    if ! wxd_installed; then
        err "尚未安装 WxChat (Docker 版), 请先执行安装"
        return 1
    fi
    load_wxd_conf
    info "更新 WxChat (拉最新镜像重建容器, 端口沿用 ${WXD_PORT})..."
    if ! docker pull "$WXD_IMAGE"; then
        err "镜像拉取失败, 请检查网络后重试"; return 1
    fi
    docker rm -f "$WXD_NAME" >/dev/null 2>&1
    if ! docker run -d --name "$WXD_NAME" --restart=always -p "${WXD_PORT}:80" "$WXD_IMAGE"; then
        err "容器启动失败 (端口 ${WXD_PORT} 可能被占用), 更新未完成"; return 1
    fi
    info "更新完成"
}

wxd_restart() {
    wxd_installed && docker restart "$WXD_NAME" >/dev/null 2>&1 \
        && info "WxChat 已重启" \
        || err "容器不存在或重启失败"
}

wxd_stop() {
    wxd_installed && docker stop "$WXD_NAME" >/dev/null 2>&1 \
        && info "WxChat 已停止" \
        || err "容器不存在或停止失败"
}

wxd_uninstall() {
    check_root
    if ! wxd_installed; then
        err "尚未安装 WxChat (Docker 版)"
        return 1
    fi
    if ask_yn "确认卸载 WxChat (Docker 版)?" "Y"; then
        docker rm -f "$WXD_NAME" >/dev/null 2>&1
        docker rmi "$WXD_IMAGE" >/dev/null 2>&1
        rm -f "$WX_DOCKER_CONF_PERSIST"
        info "WxChat (Docker 版) 已卸载"
    else
        info "已取消"
    fi
}

wxd_status() {
    load_wxd_conf
    if wxd_running; then
        info "运行状态: ${GREEN}运行中${PLAIN} (Docker, 端口 ${WXD_PORT})"
        docker ps --filter "name=${WXD_NAME}" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        info "健康探测:"
        curl -fsS --max-time 5 -o /dev/null -w "  HTTP %{http_code} (%{time_total}s)\n" "http://127.0.0.1:${WXD_PORT}" \
            || echo -e "  ${RED}本机端口 ${WXD_PORT} 无响应${PLAIN}"
    elif wxd_installed; then
        warn "运行状态: ${RED}已停止${PLAIN}"
        docker ps -a --filter "name=${WXD_NAME}" --format "table {{.Names}}\t{{.Status}}"
    else
        err "尚未安装 WxChat (Docker 版)"
        return 1
    fi
    echo ""
    info "当前公网IP: $(get_pub_ip)  (企业微信可信IP填这个)"
}

wxd_logs() {
    if wxd_installed; then
        docker logs --tail 50 -f "$WXD_NAME"
    else
        err "尚未安装 WxChat (Docker 版)"
    fi
}

wxd_menu() {
    while true; do
        load_wxd_conf
        local tag="  ${RED}[未安装]${PLAIN}"
        wxd_running && tag="  ${GREEN}[运行中 · 端口 ${WXD_PORT}]${PLAIN}"
        wxd_installed && ! wxd_running && tag="  ${YELLOW}[已停止]${PLAIN}"
        clear
        echo -e "${CYAN}╔════════════════════════════════════════════╗"
        echo -e "║  ${BOLD}WxChat 微信通知代理 管理菜单 (Docker)${PLAIN}${CYAN}    ║"
        echo -e "╚════════════════════════════════════════════╝${PLAIN}"
        echo ""
        echo -e "  当前状态: ${tag}"
        echo ""
        echo -e "  ${GREEN}${BOLD}1${PLAIN}. 安装 WxChat (Docker 版)"
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
            1) wxd_install;   pause_back ;;
            2) wxd_update;    pause_back ;;
            3) wxd_restart;   pause_back ;;
            4) wxd_stop;      pause_back ;;
            5) wxd_uninstall; pause_back ;;
            6) wxd_status;    pause_back ;;
            7) wxd_logs ;;
            0) return 0 ;;
            *) warn "无效选项, 请重新输入"; sleep 1 ;;
        esac
    done
}

# ============================================================
#  第二部分: WxChat 微信通知转发代理 (nginx 原生, 无需 Docker)
#  原理: 官方镜像 ddsderek/wxchat 本质 = nginx 反代企业微信API
#  此处直接以 nginx 原生实现, 兼容无 Docker 的低配 NAT 机
# ============================================================

WX_NGINX_CONF_NAME="wxchat.conf"
WX_WEB_DIR="/var/www/wxchat"

# 各发行版 nginx 站点配置目录 (Alpine=http.d, Debian/CentOS=conf.d)
wx_nginx_dir() {
    if [ -d /etc/nginx/http.d ]; then
        echo "/etc/nginx/http.d"
    elif [ -d /etc/nginx/conf.d ]; then
        echo "/etc/nginx/conf.d"
    else
        mkdir -p /etc/nginx/conf.d
        echo "/etc/nginx/conf.d"
    fi
}

wx_conf_path()     { echo "$(wx_nginx_dir)/${WX_NGINX_CONF_NAME}"; }
wx_conf_disabled() { echo "$(wx_nginx_dir)/${WX_NGINX_CONF_NAME}.disabled"; }

wx_installed() { [ -f "$(wx_conf_path)" ] || [ -f "$(wx_conf_disabled)" ]; }

# 端口真实探测 (权威判据, 不依赖 pgrep —— 低配 NAT 机常缺 procps)
wx_port_alive() {
    curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:${WX_PORT}/" 2>/dev/null && return 0
    command -v wget >/dev/null 2>&1 && wget -q -T 2 -O /dev/null "http://127.0.0.1:${WX_PORT}/" 2>/dev/null && return 0
    return 1
}

# nginx 进程检测 (pgrep 缺失时扫 /proc 兜底, 仅用于诊断展示)
wx_proc_alive() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x nginx >/dev/null 2>&1 && return 0
    fi
    grep -qs '^nginx$' /proc/[0-9]*/comm 2>/dev/null && return 0
    return 1
}

# 运行判定 = 站点配置存在 且 端口真实响应
wx_running() {
    load_wx_conf
    [ -f "$(wx_conf_path)" ] && wx_port_alive
}

# nginx 服务控制, 三通道: systemd / OpenRC / 裸进程
nginx_ctl() {
    local action="$1"
    if has_systemd; then
        case "$action" in
            enable)
                # 注意: apt 装完 nginx 会自动启动, enable --now 不会 reload 新配置
                # 所以已在跑就 reload, 没在跑才 start
                systemctl enable nginx >/dev/null 2>&1
                if systemctl is-active --quiet nginx; then
                    systemctl reload nginx 2>/dev/null || systemctl restart nginx
                else
                    systemctl start nginx
                fi
                ;;
            reload) systemctl reload nginx 2>/dev/null || systemctl restart nginx ;;
            *)      systemctl "$action" nginx ;;
        esac
    elif has_openrc; then
        case "$action" in
            enable)
                rc-update add nginx default >/dev/null 2>&1
                if rc-service nginx status >/dev/null 2>&1; then
                    rc-service nginx reload 2>/dev/null || rc-service nginx restart
                else
                    rc-service nginx start
                fi
                ;;
            reload) rc-service nginx reload 2>/dev/null || rc-service nginx restart ;;
            *)      rc-service nginx "$action" ;;
        esac
    else
        case "$action" in
            enable|start|reload) nginx -s reload 2>/dev/null || nginx ;;
            stop)                nginx -s quit ;;
            restart)             nginx -s quit 2>/dev/null; sleep 1; nginx ;;
        esac
    fi
}

# 多发行版安装 nginx
wx_install_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        info "nginx 已安装: $(nginx -v 2>&1 | cut -d'/' -f2)"
        return 0
    fi
    warn "未检测到 nginx, 开始自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y nginx
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nginx
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nginx
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache nginx
    else
        err "不支持的包管理器, 请手动安装 nginx 后重试"
        return 1
    fi
    hash -r 2>/dev/null
    command -v nginx >/dev/null 2>&1 || { err "nginx 安装失败"; return 1; }
    info "nginx 安装完成"
}

# 生成站点配置 (与官方镜像反代规则一致)
wx_write_config() {
    local v6=""
    # 仅在有 IPv6 的机器上加 ipv6 监听 (NAT 老内核可能无 IPv6)
    [ -f /proc/net/if_inet6 ] && v6="    listen [::]:${WX_PORT};"
    mkdir -p "$(wx_nginx_dir)"
    cat > "$(wx_conf_path)" <<EOF
# WxChat 微信通知转发代理 (由 ziyong.sh 生成, 等价 ddsderek/wxchat)
server {
    listen ${WX_PORT};
${v6}
    server_name _;
    client_max_body_size 20m;

    access_log /var/log/nginx/wxchat-access.log;
    error_log  /var/log/nginx/wxchat-error.log;

    location / {
        root ${WX_WEB_DIR};
        index index.html;
    }
    # 核心: 5 条反代, 与官方镜像完全一致
    location /cgi-bin/gettoken     { proxy_pass https://qyapi.weixin.qq.com; }
    location /cgi-bin/message/send { proxy_pass https://qyapi.weixin.qq.com; }
    location /cgi-bin/menu/create  { proxy_pass https://qyapi.weixin.qq.com; }
    location /cgi-bin/media/upload { proxy_pass https://qyapi.weixin.qq.com; }
    location /cgi-bin/media/get    { proxy_pass https://qyapi.weixin.qq.com; }
}
EOF
}

# 生成欢迎页
wx_write_webpage() {
    mkdir -p "$WX_WEB_DIR"
    cat > "${WX_WEB_DIR}/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>微信通知转发代理</title>
<style>
body{font-family:-apple-system,"Microsoft YaHei",sans-serif;display:flex;min-height:100vh;margin:0;align-items:center;justify-content:center;background:#f5f7fa}
.card{background:#fff;padding:48px 64px;border-radius:12px;box-shadow:0 4px 24px rgba(0,0,0,.08);text-align:center}
h1{color:#07c160;font-size:24px;margin:0 0 12px}
p{color:#666;font-size:14px;margin:4px 0}
</style>
</head>
<body>
<div class="card">
<h1>微信通知转发代理搭建成功!</h1>
<p>请在企业微信后台将应用「可信IP」设置为本机公网IP</p>
<p>代理地址: http://本机IP:端口/cgi-bin/xxx</p>
</div>
</body>
</html>
EOF
}

wx_install() {
    check_root
    load_wx_conf
    if wxd_installed; then
        warn "提示: Docker 版 WxChat 也在这台机器上, 注意两个版本用不同端口"
    fi
    wx_install_nginx || return 1
    echo ""
    nat_port_hint
    local allow=""
    wx_installed && allow="$WX_PORT"
    WX_PORT=$(ask_port "请输入监听端口" "$(random_free_port)" no "$allow")

    wx_write_webpage
    wx_write_config

    nginx -t 2>/dev/null || { err "nginx 配置测试失败, 请执行 nginx -t 查看详情"; return 1; }
    nginx_ctl enable || { err "nginx 启动失败"; return 1; }

    save_wx_conf
    sleep 1
    if ! wx_running; then
        err "nginx 已启动但端口 ${WX_PORT} 无响应"
        warn "请执行 tail -50 /var/log/nginx/error.log 查看原因, 然后回菜单选 3 重启"
        return 1
    fi
    open_firewall_ports "$WX_PORT"

    local pub_ip
    pub_ip=$(get_pub_ip)
    echo ""
    line
    info "WxChat (nginx 版) 安装完成! 无需 Docker, 低配 NAT 机可用"
    echo -e "  ${BOLD}访问地址:${PLAIN} http://${pub_ip}:${WX_PORT}"
    echo -e "  ${BOLD}通知代理:${PLAIN} http://${pub_ip}:${WX_PORT} (同地址)"
    echo ""
    warn "重要: 请到 企业微信后台 -> 应用 -> 可信IP, 填入: ${YELLOW}${BOLD}${pub_ip}${PLAIN}"
    is_nat && warn "NAT 机注意: 请确认端口 ${WX_PORT} 已在服务商面板做映射, 否则外网访问不到"
    line
}

wx_change_port() {
    check_root
    if ! wx_installed; then
        err "尚未安装 WxChat (nginx 版), 请先执行安装"
        return 1
    fi
    load_wx_conf
    nat_port_hint
    WX_PORT=$(ask_port "新端口 (当前 ${WX_PORT})" "$(random_free_port)" no "$WX_PORT")
    wx_write_config
    nginx -t 2>/dev/null || { err "nginx 配置测试失败"; return 1; }
    nginx_ctl reload || { err "nginx 重载失败"; return 1; }
    save_wx_conf
    sleep 1
    if wx_running; then
        info "端口已更换为 ${WX_PORT} 并生效"
    else
        err "重载后端口 ${WX_PORT} 无响应, 请执行 tail -50 /var/log/nginx/error.log 排查"
        return 1
    fi
    open_firewall_ports "$WX_PORT"
}

wx_restart() {
    if ! wx_installed; then
        err "尚未安装 WxChat (nginx 版)"
        return 1
    fi
    # 若处于停止状态(配置被禁用)先恢复
    [ -f "$(wx_conf_disabled)" ] && mv "$(wx_conf_disabled)" "$(wx_conf_path)"
    nginx_ctl restart || { err "重启命令执行失败"; return 1; }
    sleep 1
    load_wx_conf
    if wx_running; then
        info "WxChat 已重启 (端口 ${WX_PORT} 响应正常)"
    else
        err "重启后端口 ${WX_PORT} 无响应, 请执行 tail -50 /var/log/nginx/error.log 排查"
        return 1
    fi
}

wx_stop() {
    if [ ! -f "$(wx_conf_path)" ]; then
        err "WxChat 未在运行 (或尚未安装)"
        return 1
    fi
    # 停用 = 把站点配置挪为 .disabled 再重载, 不影响 nginx 其他站点
    mv "$(wx_conf_path)" "$(wx_conf_disabled)"
    nginx_ctl reload && info "WxChat 已停止 (nginx 其他站点不受影响)" || err "停止失败"
}

wx_uninstall() {
    check_root
    if ! wx_installed; then
        err "尚未安装 WxChat (nginx 版)"
        return 1
    fi
    if ask_yn "确认卸载 WxChat (nginx 版)? (仅移除站点配置, nginx 本体保留)" "Y"; then
        rm -f "$(wx_conf_path)" "$(wx_conf_disabled)"
        rm -rf "$WX_WEB_DIR"
        rm -f "$WX_NGINX_CONF_PERSIST"
        nginx_ctl reload 2>/dev/null
        info "WxChat (nginx 版) 已卸载 (nginx 保留, 如需连软件包一起删请选菜单 8)"
    else
        info "已取消"
    fi
}

# 卸载 nginx 本体 (软件包), 同时清掉 WxChat 站点残留
wx_uninstall_nginx() {
    check_root
    if ! command -v nginx >/dev/null 2>&1 && [ ! -d /etc/nginx ]; then
        err "未检测到 nginx, 无需卸载"
        return 1
    fi
    warn "将停止并卸载 nginx 软件包, 本机上所有依赖 nginx 的站点都会失效!"
    if wx_installed; then
        warn "WxChat 站点配置也会一并清除"
    fi
    if ! ask_yn "确认卸载 nginx 本体?" "Y"; then
        info "已取消"
        return 0
    fi
    # 先停服务
    nginx_ctl stop 2>/dev/null
    has_systemd && systemctl disable nginx >/dev/null 2>&1
    # 按包管理器卸载
    if command -v apt-get >/dev/null 2>&1; then
        apt-get remove -y nginx nginx-common >/dev/null 2>&1 || apt-get remove -y nginx
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y nginx
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y nginx
    elif command -v apk >/dev/null 2>&1; then
        apk del nginx
    else
        err "未识别的包管理器, 请手动卸载 nginx"
        return 1
    fi
    # 清理 WxChat 残留 (站点配置/欢迎页/持久化端口)
    rm -f "$(wx_conf_path)" "$(wx_conf_disabled)" 2>/dev/null
    rm -rf "$WX_WEB_DIR"
    rm -f "$WX_NGINX_CONF_PERSIST"
    # 清 bash 命令路径缓存, 否则 command -v 会命中卸载前的旧路径误报
    hash -r 2>/dev/null
    if ! command -v nginx >/dev/null 2>&1; then
        info "nginx 已卸载 (配置文件目录 /etc/nginx 如无用可手动删除)"
    else
        err "nginx 卸载可能未完成, 请手动检查"
        return 1
    fi
}

wx_status() {
    load_wx_conf
    if wx_running; then
        info "运行状态: ${GREEN}运行中${PLAIN} (nginx, 端口 ${WX_PORT})"
        echo ""
        info "健康探测:"
        curl -fsS --max-time 5 -o /dev/null -w "  欢迎页: HTTP %{http_code} (%{time_total}s)\n" "http://127.0.0.1:${WX_PORT}" \
            || echo -e "  ${RED}本机端口 ${WX_PORT} 无响应${PLAIN}"
        curl -fsS --max-time 5 -o /dev/null -w "  API反代: HTTP %{http_code} (%{time_total}s)\n" "http://127.0.0.1:${WX_PORT}/cgi-bin/gettoken" \
            || echo -e "  ${RED}反代路径无响应${PLAIN}"
    elif wx_installed; then
        warn "运行状态: ${RED}已停止${PLAIN}"
        echo ""
        info "自检 (帮助定位问题):"
        if [ -f "$(wx_conf_path)" ]; then
            echo -e "  站点配置: ${GREEN}存在${PLAIN} ($(wx_conf_path))"
        else
            echo -e "  站点配置: ${RED}缺失${PLAIN} (可能被停用, 选 3 重启会自动恢复)"
        fi
        if wx_proc_alive; then
            echo -e "  nginx进程: ${GREEN}运行中${PLAIN}"
        else
            echo -e "  nginx进程: ${RED}未运行${PLAIN} (选 3 重启)"
        fi
        if wx_port_alive; then
            echo -e "  端口 ${WX_PORT}: ${GREEN}有响应${PLAIN}"
        else
            echo -e "  端口 ${WX_PORT}: ${RED}无响应${PLAIN} (选 3 重启; 无效则 tail -50 /var/log/nginx/error.log)"
        fi
    else
        err "尚未安装 WxChat (nginx 版)"
        return 1
    fi
    echo ""
    info "当前公网IP: $(get_pub_ip)  (企业微信可信IP填这个)"
}

wx_logs() {
    if [ -f /var/log/nginx/wxchat-access.log ]; then
        tail -n 50 -f /var/log/nginx/wxchat-access.log
    elif [ -f /var/log/nginx/wxchat-error.log ]; then
        tail -n 50 -f /var/log/nginx/wxchat-error.log
    else
        err "尚未安装 WxChat (nginx 版) (或无日志)"
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
        echo -e "║  ${BOLD}WxChat 微信通知代理 管理菜单 (nginx)${PLAIN}${CYAN}     ║"
        echo -e "╚════════════════════════════════════════════╝${PLAIN}"
        echo ""
        echo -e "  当前状态: ${tag}"
        echo ""
        echo -e "  ${GREEN}${BOLD}1${PLAIN}. 安装 WxChat (nginx 原生, 无需 Docker)"
        echo -e "  ${GREEN}${BOLD}2${PLAIN}. 更换端口"
        echo -e "  ${GREEN}${BOLD}3${PLAIN}. 重启 WxChat"
        echo -e "  ${GREEN}${BOLD}4${PLAIN}. 停止 WxChat"
        echo -e "  ${GREEN}${BOLD}5${PLAIN}. 卸载 WxChat"
        echo -e "  ${GREEN}${BOLD}6${PLAIN}. 查看运行状态 / 公网IP"
        echo -e "  ${GREEN}${BOLD}7${PLAIN}. 查看实时日志"
        echo -e "  ${GREEN}${BOLD}8${PLAIN}. 卸载 nginx 本体 (连软件包一起删)"
        echo -e "  ${RED}${BOLD}0${PLAIN}. 返回上级菜单"
        echo ""
        line
        read -rp "请输入选项 [0-8]: " sub
        case "$sub" in
            1) wx_install;         pause_back ;;
            2) wx_change_port;     pause_back ;;
            3) wx_restart;         pause_back ;;
            4) wx_stop;            pause_back ;;
            5) wx_uninstall;       pause_back ;;
            6) wx_status;          pause_back ;;
            7) wx_logs ;;
            8) wx_uninstall_nginx; pause_back ;;
            0) return 0 ;;
            *) warn "无效选项, 请重新输入"; sleep 1 ;;
        esac
    done
}

# ============================================================
#  第三部分: frps 服务端 (frp 内网穿透)
# ============================================================

FRPS_INSTALL_DIR="/usr/local/frp"
FRPS_CONF_DIR="/etc/frp"
FRPS_CONF_FILE="${FRPS_CONF_DIR}/frps.toml"
FRPS_BIN="${FRPS_INSTALL_DIR}/frps"
FRPS_SERVICE="/etc/systemd/system/frps.service"
FRPS_CONF_BAK="${ZIYONG_DIR}/frps.toml.bak"

FRPS_PID_FILE="/run/frps.pid"
FRPS_LOG_FILE="/var/log/frps.log"
FRPS_OPENRC="/etc/init.d/frps"

# 生成 OpenRC init 脚本 (Alpine 等无 systemd 但有 OpenRC 的环境)
frps_write_openrc() {
    cat > "$FRPS_OPENRC" <<EOF
#!/sbin/openrc-run
name="frps"
description="frp server (ziyong)"
command="${FRPS_BIN}"
command_args="-c ${FRPS_CONF_FILE}"
command_background="yes"
pidfile="${FRPS_PID_FILE}"
output_log="${FRPS_LOG_FILE}"
error_log="${FRPS_LOG_FILE}"
EOF
    chmod +x "$FRPS_OPENRC"
}

frps_installed() { [ -f "$FRPS_BIN" ]; }

# 从配置解析 bindPort
frps_bind_port() { grep -m1 -oE '^bindPort *= *[0-9]+' "$FRPS_CONF_FILE" 2>/dev/null | grep -oE '[0-9]+$'; }

# frps 进程检测 (pgrep -> /proc 扫描 -> pidfile 三级兜底)
frps_proc_alive() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x frps >/dev/null 2>&1 && return 0
    fi
    grep -qs '^frps$' /proc/[0-9]*/comm 2>/dev/null && return 0
    [ -f "$FRPS_PID_FILE" ] && kill -0 "$(cat "$FRPS_PID_FILE" 2>/dev/null)" 2>/dev/null && return 0
    return 1
}

# 运行判定 = bindPort 真实可连接 (权威), 解析不到端口时退化为进程检测
frps_running() {
    frps_installed || return 1
    local bp
    bp=$(frps_bind_port)
    if [ -n "$bp" ]; then
        tcp_port_alive "$bp" && return 0
    fi
    frps_proc_alive
}

# 无 systemd 时杀掉全部 frps 进程
frps_kill_all() {
    [ -f "$FRPS_PID_FILE" ] && kill "$(cat "$FRPS_PID_FILE" 2>/dev/null)" 2>/dev/null
    command -v pkill >/dev/null 2>&1 && pkill -x frps 2>/dev/null
    local pid
    for pid in $(grep -ls '^frps$' /proc/[0-9]*/comm 2>/dev/null | cut -d/ -f3); do
        kill "$pid" 2>/dev/null
    done
}

# frps 服务控制, 三通道: systemd / OpenRC / nohup+pidfile
frps_ctl() {
    local action="$1"
    if has_systemd; then
        case "$action" in
            enable)  systemctl enable --now frps ;;
            disable) systemctl disable --now frps ;;
            *)       systemctl "$action" frps ;;
        esac
        return
    fi
    if has_openrc && [ -f "$FRPS_OPENRC" ]; then
        case "$action" in
            enable)  rc-update add frps default >/dev/null 2>&1; rc-service frps start ;;
            disable) rc-service frps stop >/dev/null 2>&1; rc-update del frps default >/dev/null 2>&1 ;;
            *)       rc-service frps "$action" ;;
        esac
        return
    fi
    case "$action" in
        enable|start)
            frps_proc_alive && return 0
            # 日志超 10MB 截断, 防 nohup 模式撑爆磁盘
            [ -f "$FRPS_LOG_FILE" ] && [ "$(stat -c%s "$FRPS_LOG_FILE" 2>/dev/null || echo 0)" -gt 10485760 ] && : > "$FRPS_LOG_FILE"
            nohup "$FRPS_BIN" -c "$FRPS_CONF_FILE" >>"$FRPS_LOG_FILE" 2>&1 &
            echo $! > "$FRPS_PID_FILE"
            sleep 1
            frps_proc_alive
            ;;
        stop)
            frps_kill_all
            rm -f "$FRPS_PID_FILE"
            sleep 1
            ! frps_proc_alive
            ;;
        restart)
            frps_ctl stop >/dev/null 2>&1
            sleep 1
            frps_ctl start
            ;;
        disable)
            frps_ctl stop
            ;;
    esac
}

# 无 systemd 时设置开机自启 (OpenRC 原生 / crontab @reboot 兜底)
frps_setup_autostart() {
    has_systemd && return 0
    if has_openrc; then
        info "已通过 OpenRC 设置开机自启 (rc-update add frps default)"
        return 0
    fi
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v 'ziyong-frps'; echo "@reboot ${FRPS_BIN} -c ${FRPS_CONF_FILE} >>${FRPS_LOG_FILE} 2>&1 &  # ziyong-frps" ) | crontab - \
            && { info "已通过 crontab @reboot 设置开机自启"; return 0; }
    fi
    warn "无 systemd/OpenRC 且未找到 crontab, 无法设置开机自启; 机器重启后需手动执行:"
    echo "    nohup ${FRPS_BIN} -c ${FRPS_CONF_FILE} >>${FRPS_LOG_FILE} 2>&1 &"
}

# 清理开机自启 (卸载时)
frps_remove_autostart() {
    has_systemd && return 0
    if has_openrc; then
        rc-update del frps default >/dev/null 2>&1
        return 0
    fi
    command -v crontab >/dev/null 2>&1 && ( crontab -l 2>/dev/null | grep -v 'ziyong-frps' ) | crontab - 2>/dev/null
    return 0
}

# 日志查看方式提示 (按环境)
frps_log_hint() {
    if has_systemd; then
        echo "journalctl -u frps -e"
    else
        echo "tail -50 ${FRPS_LOG_FILE}"
    fi
}

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
    echo ""
    nat_port_hint
    # 重装场景放行本服务正在使用的旧端口
    local allow_b="" allow_d="" allow_h="" allow_hs=""
    if frps_installed; then
        allow_b=$(frps_bind_port)
        allow_d=$(grep -m1 -oE '^webServer\.port *= *[0-9]+' "$FRPS_CONF_FILE" 2>/dev/null | grep -oE '[0-9]+$')
        allow_h=$(grep -m1 -oE '^vhostHTTPPort *= *[0-9]+' "$FRPS_CONF_FILE" 2>/dev/null | grep -oE '[0-9]+$')
        allow_hs=$(grep -m1 -oE '^vhostHTTPSPort *= *[0-9]+' "$FRPS_CONF_FILE" 2>/dev/null | grep -oE '[0-9]+$')
    fi
    BIND_PORT=$(ask_port "frp 通信端口" "$r1" no "$allow_b")
    DASHBOARD_PORT=$(ask_port "面板端口, 0不开" "$r2" yes "$allow_d")
    VHOST_HTTP_PORT=$(ask_port "http穿透端口, 0不启用" "$r3" yes "$allow_h")
    VHOST_HTTPS_PORT=$(ask_port "https穿透端口, 0不启用" "$r4" yes "$allow_hs")

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
    chmod 600 "$FRPS_CONF_FILE"  # 内含 token, 仅 root 可读
    [ -f "$FRPS_CONF_BAK" ] && chmod 600 "$FRPS_CONF_BAK"

    if has_systemd; then
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
    elif has_openrc; then
        frps_write_openrc
        info "未检测到 systemd, 使用 OpenRC 托管 (rc-service frps, 日志: ${FRPS_LOG_FILE})"
    else
        warn "未检测到 systemd/OpenRC, 使用 nohup 后台模式运行 (日志: ${FRPS_LOG_FILE})"
    fi

    # 重装场景: 先停掉可能还在跑旧配置的进程
    frps_ctl stop >/dev/null 2>&1
    frps_ctl enable || { err "服务启动失败, 请查看: $(frps_log_hint)"; return 1; }
    sleep 1
    if ! frps_running; then
        err "启动后端口 ${BIND_PORT} 无响应, 请查看: $(frps_log_hint)"
        return 1
    fi
    frps_setup_autostart

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
    if is_nat; then
        warn "NAT 机注意: bindPort 和每个 proxy 的 remotePort 都必须是服务商已映射的端口"
    fi
    echo ""
    info "frpc 客户端配置示例 (复制到客户端 frpc.toml 按需修改):"
    echo -e "${CYAN}"
    cat <<EOF
serverAddr = "${pub_ip}"
serverPort = ${BIND_PORT}
auth.token = "${token}"

[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 换一个映射端口
EOF
    echo -e "${PLAIN}"
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
    frps_ctl stop >/dev/null 2>&1
    cp "${tmp}/frp_${ver}_linux_${arch}/frps" "$FRPS_BIN" && chmod +x "$FRPS_BIN"
    rm -rf "$tmp"
    frps_ctl start || { err "更新后启动失败, 请查看: $(frps_log_hint)"; return 1; }
    info "更新完成, 当前版本: $("$FRPS_BIN" -v 2>/dev/null)"
}

frps_restart() {
    frps_installed || { err "尚未安装 frps"; return 1; }
    frps_ctl restart || { err "重启失败, 请查看: $(frps_log_hint)"; return 1; }
    sleep 1
    frps_running && info "frps 已重启" || { err "重启后端口无响应, 请查看: $(frps_log_hint)"; return 1; }
}
frps_start() {
    frps_installed || { err "尚未安装 frps"; return 1; }
    frps_ctl start && info "frps 已启动" || { err "启动失败, 请查看: $(frps_log_hint)"; return 1; }
}
frps_stop() {
    frps_installed || { err "尚未安装 frps"; return 1; }
    frps_ctl stop && info "frps 已停止" || err "停止失败"
}

frps_uninstall() {
    check_root
    if ! frps_installed; then
        err "尚未安装 frps"
        return 1
    fi
    if ask_yn "确认卸载 frps? 配置和 token 将被删除" "Y"; then
        frps_ctl disable >/dev/null 2>&1
        frps_remove_autostart
        rm -f "$FRPS_SERVICE" "$FRPS_OPENRC" "$FRPS_BIN" "$FRPS_CONF_FILE" "$FRPS_CONF_BAK" "$FRPS_PID_FILE"
        has_systemd && systemctl daemon-reload
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
        echo ""
        info "自检 (帮助定位问题):"
        if frps_proc_alive; then
            echo -e "  frps进程: ${GREEN}运行中${PLAIN}"
        else
            echo -e "  frps进程: ${RED}未运行${PLAIN} (菜单选 4 启动)"
        fi
        local bp
        bp=$(frps_bind_port)
        if [ -n "$bp" ]; then
            if tcp_port_alive "$bp"; then
                echo -e "  通信端口 ${bp}: ${GREEN}可连接${PLAIN}"
            else
                echo -e "  通信端口 ${bp}: ${RED}无响应${PLAIN} (菜单选 3 重启; 无效则 $(frps_log_hint))"
            fi
        fi
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
    if ! frps_installed; then
        err "尚未安装 frps"
        return 1
    fi
    if has_systemd; then
        journalctl -u frps -n 50 --no-pager
        echo ""
        warn "以上为最近50行, 实时跟踪: journalctl -u frps -f"
    elif [ -f "$FRPS_LOG_FILE" ]; then
        tail -n 50 "$FRPS_LOG_FILE"
        echo ""
        warn "以上为最近50行, 实时跟踪: tail -f ${FRPS_LOG_FILE}"
    else
        warn "暂无日志文件 (${FRPS_LOG_FILE} 不存在, 服务可能未以后台模式启动过)"
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
        frps_ctl restart && info "frps 已重启" || err "重启失败, 请查看: $(frps_log_hint)"
    else
        info "已跳过重启, 可在菜单选 3 重启"
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
#  sing-box 节点管理 (调度模式: 本体在 qingshous/sing-box-sh 仓库维护)
# ============================================================

SB_CMD="/usr/local/bin/sb"          # sing-box 脚本自己的快捷命令
SB_BIN_FILE="/usr/local/bin/sing-box"
SB_RAW="https://raw.githubusercontent.com/qingshous/sing-box-sh/main/install.sh"

sb_installed() { [ -f "$SB_CMD" ] || [ -x "$SB_BIN_FILE" ]; }

sb_running() {
    if has_systemd; then
        systemctl is-active --quiet sing-box 2>/dev/null && return 0
    elif has_openrc; then
        rc-service sing-box status >/dev/null 2>&1 && return 0
    fi
    # 兜底: 扫 /proc 进程名
    local p
    for p in /proc/[0-9]*/comm; do
        [ "$(cat "$p" 2>/dev/null)" = "sing-box" ] && return 0
    done
    return 1
}

# 检查并更新 sb 面板脚本 (已装时选 4 会先走这里, 拉到新版才替换, 失败保留旧版并提示)
sb_update_check() {
    local tmp="/tmp/sb_update.$$.sh"
    if ! download "$SB_RAW" "$tmp"; then
        warn "sing-box 面板更新检查失败 (网络问题), 继续使用当前已安装版本"
        rm -f "$tmp"; return 1
    fi
    # 复用 sing-box-sh 自带的 fetch_script 校验标记, 防止坏脚本覆盖
    if ! head -n 1 "$tmp" | grep -q '^#!/bin/bash' \
       || ! grep -q '^menu$' "$tmp" \
       || ! grep -q '^install_kernel() {' "$tmp" \
       || ! grep -q '^add_config() {' "$tmp" \
       || ! bash -n "$tmp" 2>/dev/null; then
        warn "sing-box 面板下载内容校验失败, 保留当前版本"
        rm -f "$tmp"; return 1
    fi
    # 对比是否需要更新 (本机 sb 与远程不同才替换)
    if [ -f "$SB_CMD" ] && cmp -s "$tmp" "$SB_CMD"; then
        rm -f "$tmp"; return 0   # 相同, 无需更新
    fi
    # 就地写覆盖 (不换 inode)
    if cat "$tmp" > "$SB_CMD" 2>/dev/null && chmod 755 "$SB_CMD" 2>/dev/null; then
        info "sing-box 面板已更新到最新版"
    else
        warn "sing-box 面板更新写入失败, 保留当前版本"
        rm -f "$tmp"; return 1
    fi
    rm -f "$tmp"
    return 0
}

# sing-box 主入口: 进入节点面板
sb_launch() {
    if [ -f "$SB_CMD" ]; then
        sb_update_check
        info "检测到本机已安装 sing-box 管理面板, 正在进入..."
        sleep 1
        bash "$SB_CMD"
        return
    fi
    local tmp="/tmp/sb_install.$$.sh"
    info "本机未安装 sing-box, 正在从 qingshous/sing-box-sh 拉取安装脚本..."
    if curl -fsSL --max-time 30 "$SB_RAW" -o "$tmp" 2>/dev/null \
       || curl -fsSL --max-time 30 "https://ghproxy.net/$SB_RAW" -o "$tmp" 2>/dev/null \
       || curl -fsSL --max-time 30 "https://gh-proxy.com/$SB_RAW" -o "$tmp" 2>/dev/null; then
        if ! head -n 1 "$tmp" | grep -q '^#!/bin/bash' || ! bash -n "$tmp" 2>/dev/null; then
            err "下载内容校验失败, 已取消"; rm -f "$tmp"; return 1
        fi
        info "校验通过, 启动 sing-box 安装/管理面板 (退出面板后返回本菜单)"
        sleep 1
        bash "$tmp"
        rm -f "$tmp"
        # 首次安装后 sb 快捷命令已生成, 提示用户
        [ -f "$SB_CMD" ] && info "sing-box 面板以后也可直接输入 sb 进入"
    else
        err "下载失败 (已尝试直连/ghproxy/gh-proxy), 请检查网络后重试"
        return 1
    fi
}

# ---- 已移除 cron 守护 ----
# 说明: sing-box 的自动重启由 sing-box-sh 仓库的 OpenRC supervise-daemon 托管
# (进程崩溃秒级自愈), 无需再叠加 cron 轮询守护, 避免双层守护打架。

# ============================================================
#  realm 端口转发管理 (调度模式: 本体在 qingshous/realm-xwPF 仓库维护)
# ============================================================

PF_ENTRY="/usr/local/bin/xwPF.sh"   # realm-xwPF 入口脚本
PF_CMD="/usr/local/bin/pf"          # 其自带快捷命令 (软链到入口)
PF_RAW="https://raw.githubusercontent.com/qingshous/realm-xwPF/main/xwPF.sh"

# 轻量版 realm 的路径常量 (前置于 pf_running, 供其状态判定引用)
RL_MENU="/usr/local/bin/rl"          # 轻量版快捷命令 (改为 rl, 原 realm 与 xwPF 内核抢路径)
RL_LEGACY="/usr/local/bin/realm"     # 旧版快捷命令路径 (仅在确认是本脚本时使用)
RL_BIN="/usr/local/bin/realm-bin"    # 内核

pf_installed() { [ -f "$PF_ENTRY" ]; }

# xwPF 的内核是 /usr/local/bin/realm (进程名 realm)
# 注意: 轻量版也用 realm.service 服务名, 所以服务状态只在轻量版未装时才作为依据
pf_running() {
    pf_installed || return 1
    local p
    for p in /proc/[0-9]*/comm; do
        [ "$(cat "$p" 2>/dev/null)" = "realm" ] && return 0
    done
    if [ ! -f "$RL_BIN" ] && [ ! -f "$RL_MENU" ] && [ ! -f "$RL_LEGACY" ]; then
        if has_systemd; then
            systemctl is-active --quiet realm 2>/dev/null && return 0
        elif has_openrc; then
            rc-service realm status >/dev/null 2>&1 && return 0
        fi
    fi
    return 1
}

# 已装 -> 直接调本机入口 (无参数=进主菜单); 未装 -> 拉引导脚本以 install 参数执行 (自动装 pf)
pf_launch() {
    if [ -f "$PF_ENTRY" ]; then
        info "检测到本机已安装 realm 转发管理, 正在进入..."
        sleep 1
        bash "$PF_ENTRY"
        return
    fi
    local tmp="/tmp/xwpf_install.$$.sh"
    info "本机未安装 realm 转发管理, 正在从 qingshous/realm-xwPF 拉取引导脚本..."
    if curl -fsSL --max-time 30 "$PF_RAW" -o "$tmp" 2>/dev/null \
       || curl -fsSL --max-time 30 "https://ghproxy.net/$PF_RAW" -o "$tmp" 2>/dev/null \
       || curl -fsSL --max-time 30 "https://gh-proxy.com/$PF_RAW" -o "$tmp" 2>/dev/null; then
        if ! head -n 1 "$tmp" | grep -q '^#!/bin/bash' || ! bash -n "$tmp" 2>/dev/null; then
            err "下载内容校验失败, 已取消"; rm -f "$tmp"; return 1
        fi
        info "校验通过, 开始安装 realm 转发管理 (退出面板后返回本菜单)"
        sleep 1
        bash "$tmp" install
        rm -f "$tmp"
        [ -f "$PF_CMD" ] && info "realm 转发管理以后也可直接输入 pf 进入"
    else
        err "下载失败 (已尝试直连/ghproxy/gh-proxy), 请检查网络后重试"
        return 1
    fi
}

# ============================================================
#  轻量版 realm (调度模式: 本体在 qingshous/realm-installer 仓库维护)
# ============================================================

RL_RAW="https://raw.githubusercontent.com/qingshous/realm-installer/main/install.sh"

# 该路径上的文件是否为本脚本 (避免把 xwPF 的内核误判为轻量版菜单)
rl_is_ours() { [ -f "$1" ] && grep -q 'Realm 一键安装与管理脚本' "$1" 2>/dev/null; }

rl_installed() {
    [ -f "$RL_BIN" ] && return 0
    [ -f "$RL_MENU" ] && return 0
    rl_is_ours "$RL_LEGACY" && return 0
    return 1
}

# 轻量版内核进程名为 realm-bin, 与 xwPF 的 realm 天然区分
rl_running() {
    rl_installed || return 1
    local p
    for p in /proc/[0-9]*/comm; do
        [ "$(cat "$p" 2>/dev/null)" = "realm-bin" ] && return 0
    done
    # 兜底: xwPF 未装时, realm.service 的归属才是轻量版
    if [ ! -f "$PF_ENTRY" ]; then
        if has_systemd; then
            systemctl is-active --quiet realm 2>/dev/null && return 0
        elif has_openrc; then
            rc-service realm status >/dev/null 2>&1 && return 0
        fi
    fi
    return 1
}

# 已装 -> 直接调本机 rl 菜单; 未装 -> 拉 install.sh 执行 (进其菜单选 1 安装)
rl_launch() {
    # 与 realm-xwPF 都用 realm.service + /etc/realm/config.toml, 共存会互相接管
    if [ -f "$PF_ENTRY" ]; then
        warn "检测到已安装 realm-xwPF (菜单 5), 两者服务名/配置路径相同, 请勿同时运行两套转发!"
    fi
    local rl_cmd=""
    if [ -f "$RL_MENU" ]; then
        rl_cmd="$RL_MENU"
    elif rl_is_ours "$RL_LEGACY"; then
        rl_cmd="$RL_LEGACY"   # 旧版快捷命令 (升级后会变成 rl)
    fi
    if [ -n "$rl_cmd" ]; then
        info "检测到本机已安装轻量版 realm, 正在进入..."
        sleep 1
        bash "$rl_cmd"
        return
    fi
    local tmp="/tmp/rl_install.$$.sh"
    info "本机未安装轻量版 realm, 正在从 qingshous/realm-installer 拉取安装脚本..."
    if curl -fsSL --max-time 30 "$RL_RAW" -o "$tmp" 2>/dev/null \
       || curl -fsSL --max-time 30 "https://ghproxy.net/$RL_RAW" -o "$tmp" 2>/dev/null \
       || curl -fsSL --max-time 30 "https://gh-proxy.com/$RL_RAW" -o "$tmp" 2>/dev/null; then
        if ! head -n 1 "$tmp" | grep -q '^#!/bin/bash' || ! bash -n "$tmp" 2>/dev/null; then
            err "下载内容校验失败, 已取消"; rm -f "$tmp"; return 1
        fi
        info "校验通过, 启动轻量版 realm 管理菜单 (选 1 安装, 退出后返回本菜单)"
        sleep 1
        bash "$tmp"
        rm -f "$tmp"
        [ -f "$RL_MENU" ] && info "轻量版 realm 以后也可直接输入 rl 进入"
    else
        err "下载失败 (已尝试直连/ghproxy/gh-proxy), 请检查网络后重试"
        return 1
    fi
}

# ============================================================
#  iperf3 测速服务端 (原生软件包 + systemd/OpenRC/nohup 三通道托管)
# ============================================================

IPF_SYS_UNIT="/etc/systemd/system/iperf3.service"       # CentOS 系无包自带 unit 时自建
IPF_DROPIN_DIR="/etc/systemd/system/iperf3.service.d"   # Debian 系改端口(不动包自带 unit)
IPF_DROPIN="${IPF_DROPIN_DIR}/ziyong.conf"
IPF_CONFD="/etc/conf.d/iperf3"                          # Alpine OpenRC 改端口
IPF_OPENRC="/etc/init.d/iperf3"
IPF_PID_FILE="/run/iperf3.pid"
IPF_LOG_FILE="/var/log/iperf3.log"
IPF_CONF_PERSIST="${ZIYONG_DIR}/iperf3.conf"
IPF_MARK="ziyong-iperf3"

save_ipf_conf() { mkdir -p "$ZIYONG_DIR"; chmod 700 "$ZIYONG_DIR"; echo "IPF_PORT=${IPF_PORT}" > "$IPF_CONF_PERSIST"; chmod 600 "$IPF_CONF_PERSIST"; }
load_ipf_conf() { IPF_PORT="5201"; [ -f "$IPF_CONF_PERSIST" ] && . "$IPF_CONF_PERSIST"; }

ipf_bin() { command -v iperf3 2>/dev/null; }
ipf_installed() { [ -n "$(ipf_bin)" ]; }

# 发行版包自带的 systemd unit (Debian/Ubuntu 等, 避免我们覆盖包文件)
ipf_pkg_unit() {
    local f
    for f in /lib/systemd/system/iperf3.service /usr/lib/systemd/system/iperf3.service; do
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

# 进程检测 (pgrep -> /proc 扫描 -> pidfile 三级兜底)
ipf_proc_alive() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x iperf3 >/dev/null 2>&1 && return 0
    fi
    grep -qs '^iperf3$' /proc/[0-9]*/comm 2>/dev/null && return 0
    [ -f "$IPF_PID_FILE" ] && kill -0 "$(cat "$IPF_PID_FILE" 2>/dev/null)" 2>/dev/null && return 0
    return 1
}

# 运行判定 = 监听端口真实可连接 (权威), 退化为进程检测
ipf_running() {
    ipf_installed || return 1
    [ -z "$IPF_PORT" ] && load_ipf_conf
    tcp_port_alive "$IPF_PORT" && return 0
    ipf_proc_alive
}

ipf_kill_all() {
    [ -f "$IPF_PID_FILE" ] && kill "$(cat "$IPF_PID_FILE" 2>/dev/null)" 2>/dev/null
    command -v pkill >/dev/null 2>&1 && pkill -x iperf3 2>/dev/null
    local pid
    for pid in $(grep -ls '^iperf3$' /proc/[0-9]*/comm 2>/dev/null | cut -d/ -f3); do
        kill "$pid" 2>/dev/null
    done
}

# 自建 systemd unit (发行版不提供 unit 时, 如 CentOS 系)
ipf_write_unit() {
    cat > "$IPF_SYS_UNIT" <<EOF
# managed by ${IPF_MARK}
[Unit]
Description=iperf3 server (ziyong)
After=network.target

[Service]
Type=simple
ExecStart=$(ipf_bin) --server --port ${IPF_PORT}
Restart=always
RestartSec=15
SuccessExitStatus=1

[Install]
WantedBy=multi-user.target
EOF
}

# 自建 OpenRC init (发行版不提供时兜底)
ipf_write_openrc() {
    cat > "$IPF_OPENRC" <<EOF
#!/sbin/openrc-run
# managed by ${IPF_MARK}
name="iperf3"
description="iperf3 server (ziyong)"
command="$(ipf_bin)"
command_args="--server --port ${IPF_PORT}"
command_background="yes"
pidfile="${IPF_PID_FILE}"
output_log="${IPF_LOG_FILE}"
error_log="${IPF_LOG_FILE}"
EOF
    chmod +x "$IPF_OPENRC"
}

# 把端口应用到当前系统的服务定义 (优先用包自带文件, 只写覆盖/自建)
ipf_apply_port() {
    if has_systemd; then
        if ipf_pkg_unit >/dev/null 2>&1; then
            mkdir -p "$IPF_DROPIN_DIR"
            cat > "$IPF_DROPIN" <<EOF
# managed by ${IPF_MARK}
[Service]
ExecStart=
ExecStart=$(ipf_bin) --server --port ${IPF_PORT}
EOF
        else
            ipf_write_unit
        fi
        systemctl daemon-reload >/dev/null 2>&1
        return
    fi
    if has_openrc; then
        if [ -f "$IPF_OPENRC" ] && grep -q "$IPF_MARK" "$IPF_OPENRC" 2>/dev/null; then
            ipf_write_openrc
        elif [ -f "$IPF_OPENRC" ]; then
            cat > "$IPF_CONFD" <<EOF
# managed by ${IPF_MARK}
command_args="--port ${IPF_PORT}"
EOF
        else
            ipf_write_openrc
        fi
    fi
}

# iperf3 服务控制, 三通道: systemd / OpenRC / nohup+pidfile
ipf_ctl() {
    local action="$1"
    if has_systemd; then
        case "$action" in
            enable)  systemctl enable --now iperf3 ;;
            disable) systemctl disable --now iperf3 ;;
            *)       systemctl "$action" iperf3 ;;
        esac
        return
    fi
    if has_openrc && [ -f "$IPF_OPENRC" ]; then
        case "$action" in
            enable)  rc-update add iperf3 default >/dev/null 2>&1; rc-service iperf3 start ;;
            disable) rc-service iperf3 stop >/dev/null 2>&1; rc-update del iperf3 default >/dev/null 2>&1 ;;
            *)       rc-service iperf3 "$action" ;;
        esac
        return
    fi
    case "$action" in
        enable|start)
            ipf_proc_alive && return 0
            [ -f "$IPF_LOG_FILE" ] && [ "$(stat -c%s "$IPF_LOG_FILE" 2>/dev/null || echo 0)" -gt 10485760 ] && : > "$IPF_LOG_FILE"
            nohup "$(ipf_bin)" --server --port "${IPF_PORT}" >>"$IPF_LOG_FILE" 2>&1 &
            echo $! > "$IPF_PID_FILE"
            sleep 1
            ipf_proc_alive
            ;;
        stop)
            ipf_kill_all
            rm -f "$IPF_PID_FILE"
            sleep 1
            ! ipf_proc_alive
            ;;
        restart)
            ipf_ctl stop >/dev/null 2>&1
            sleep 1
            ipf_ctl start
            ;;
        disable)
            ipf_ctl stop
            ;;
    esac
}

# 设置开机自启
ipf_setup_autostart() {
    if has_systemd; then systemctl enable iperf3 >/dev/null 2>&1; return 0; fi
    if has_openrc && [ -f "$IPF_OPENRC" ]; then rc-update add iperf3 default >/dev/null 2>&1; return 0; fi
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "$IPF_MARK"; echo "@reboot $(ipf_bin) --server --port ${IPF_PORT} >>${IPF_LOG_FILE} 2>&1 &  # $IPF_MARK" ) | crontab - \
            && { info "已通过 crontab @reboot 设置开机自启"; return 0; }
    fi
    warn "无 systemd/OpenRC/crontab, 未能设置开机自启 (重启后需手动启动)"
}

# 清理开机自启
ipf_remove_autostart() {
    if has_systemd; then systemctl disable iperf3 >/dev/null 2>&1; return 0; fi
    if has_openrc && [ -f "$IPF_OPENRC" ]; then rc-update del iperf3 default >/dev/null 2>&1; return 0; fi
    command -v crontab >/dev/null 2>&1 && ( crontab -l 2>/dev/null | grep -v "$IPF_MARK" ) | crontab - 2>/dev/null
    return 0
}

# 打印客户端测速命令
ipf_show_client() {
    local port="${1:-$IPF_PORT}" ip
    ip=$(get_pub_ip)
    echo ""
    echo -e "  ${BOLD}服务端地址:${PLAIN} ${ip}:${port}"
    echo ""
    echo -e "  ${BOLD}客户端测速命令 (复制到电脑/另一台机器执行):${PLAIN}"
    echo -e "    ${YELLOW}# 上行 (本机 -> 服务器)${PLAIN}"
    echo -e "    iperf3 -c ${ip} -p ${port}"
    echo -e "    ${YELLOW}# 下行 (服务器 -> 本机, 测下载)${PLAIN}"
    echo -e "    iperf3 -c ${ip} -p ${port} -R"
    echo -e "    ${YELLOW}# UDP (需指定带宽)${PLAIN}"
    echo -e "    iperf3 -c ${ip} -p ${port} -u -b 100M"
    echo -e "    ${YELLOW}# 4 线程并发 / 测 30 秒${PLAIN}"
    echo -e "    iperf3 -c ${ip} -p ${port} -P 4 -t 30"
}

# 按包管理器安装 iperf3 (CentOS 7 自动补 EPEL; Alpine 补 openrc 子包)
ipf_install_pkg() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y iperf3 || { dnf install -y epel-release >/dev/null 2>&1 && dnf install -y iperf3; }
    elif command -v yum >/dev/null 2>&1; then
        yum install -y iperf3 || { yum install -y epel-release >/dev/null 2>&1 && yum install -y iperf3; }
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache iperf3 iperf3-openrc
    else
        err "未识别的包管理器, 请手动安装 iperf3"; return 1
    fi
}

ipf_install() {
    check_root
    echo ""
    info "iperf3 测速服务端"
    line
    if ipf_installed; then
        info "iperf3 已安装: $(iperf3 --version 2>/dev/null | head -1)"
        info "继续配置/修复服务 (端口沿用已保存值)"
    else
        echo ""
        info "正在安装 iperf3 软件包 ..."
        ipf_install_pkg || { err "安装失败, 请检查网络/软件源"; return 1; }
        hash -r 2>/dev/null
        ipf_installed || { err "安装后未找到 iperf3 可执行文件"; return 1; }
        info "iperf3 已安装: $(iperf3 --version 2>/dev/null | head -1)"
    fi

    echo ""
    nat_port_hint
    load_ipf_conf
    # 首次安装给随机端口默认(避开公网扫描重灾区 5201), 重装则沿用已保存端口
    local ipf_def
    ipf_def="$IPF_PORT"
    [ ! -f "$IPF_CONF_PERSIST" ] && ipf_def="$(random_free_port)"
    IPF_PORT=$(ask_port "iperf3 监听端口" "$ipf_def" no "$IPF_PORT")

    if ! has_systemd && ! has_openrc; then
        warn "未检测到 systemd/OpenRC, 将使用 nohup 后台模式 (日志: ${IPF_LOG_FILE})"
    fi

    ipf_apply_port
    ipf_setup_autostart
    ipf_ctl restart >/dev/null 2>&1
    sleep 1
    if ! ipf_running; then
        err "服务启动后未存活, 请检查日志: ${IPF_LOG_FILE}"
        return 1
    fi

    save_ipf_conf
    open_firewall_ports "$IPF_PORT"
    open_firewall_ports_udp "$IPF_PORT"
    echo ""
    line
    info "iperf3 测速服务端 已启动!"
    ipf_show_client "$IPF_PORT"
    echo ""
    warn "测完建议回菜单选 2 (一键停用), 避免服务端长期暴露被他人占用带宽"
    line
}

ipf_change_port() {
    check_root
    ipf_installed || { err "尚未安装 iperf3"; return 1; }
    load_ipf_conf
    local old="$IPF_PORT"
    IPF_PORT=$(ask_port "新端口 (当前 ${old})" "$(random_free_port)" no "$old")
    if [ "$IPF_PORT" = "$old" ]; then
        info "端口未变化"
        return 0
    fi
    ipf_apply_port
    ipf_ctl restart >/dev/null 2>&1
    sleep 1
    if ! ipf_running; then
        err "重启后服务未存活, 请检查日志: ${IPF_LOG_FILE}"
        return 1
    fi
    save_ipf_conf
    open_firewall_ports "$IPF_PORT"
    open_firewall_ports_udp "$IPF_PORT"
    info "端口已更换为 ${IPF_PORT} 并生效 (旧端口 ${old} 的防火墙规则如需回收请手动关闭)"
    ipf_show_client "$IPF_PORT"
}

# 一键停用: 停止 + 关闭开机自启
ipf_disable() {
    check_root
    ipf_installed || { err "尚未安装 iperf3"; return 1; }
    ipf_ctl disable >/dev/null 2>&1
    ipf_remove_autostart
    sleep 1
    if ipf_running; then
        err "停止失败, 请检查"
        return 1
    fi
    info "iperf3 已停止并关闭开机自启 (需要时选 3 恢复)"
}

# 恢复启动 + 开机自启
ipf_enable() {
    check_root
    ipf_installed || { err "尚未安装 iperf3"; return 1; }
    load_ipf_conf
    ipf_apply_port
    ipf_setup_autostart
    ipf_ctl restart >/dev/null 2>&1
    sleep 1
    if ! ipf_running; then
        err "启动失败, 请检查日志: ${IPF_LOG_FILE}"
        return 1
    fi
    info "iperf3 已启动并设置开机自启"
    ipf_show_client "$IPF_PORT"
}

ipf_status() {
    ipf_installed || { err "尚未安装 iperf3"; return 1; }
    load_ipf_conf
    info "版本: $(iperf3 --version 2>/dev/null | head -1)"
    if ipf_running; then
        info "运行状态: ${GREEN}运行中${PLAIN}  (监听端口 ${IPF_PORT})"
    else
        warn "运行状态: ${RED}已停止${PLAIN}"
        if ipf_proc_alive; then
            echo -e "  iperf3 进程: ${GREEN}运行中${PLAIN} (但端口 ${IPF_PORT} 无响应)"
        else
            echo -e "  iperf3 进程: ${RED}未运行${PLAIN} (菜单选 3 启动)"
        fi
    fi
    if has_systemd; then
        if systemctl is-enabled --quiet iperf3 2>/dev/null; then
            echo -e "  开机自启: ${GREEN}已启用${PLAIN}"
        else
            echo -e "  开机自启: ${RED}已禁用${PLAIN} (菜单选 3 启用)"
        fi
    fi
    echo ""
    info "服务定义:"
    if has_systemd; then
        ipf_pkg_unit >/dev/null 2>&1 && echo -e "  $(ipf_pkg_unit) (包自带)"
        [ -f "$IPF_DROPIN" ] && echo -e "  ${IPF_DROPIN} (端口覆盖)"
        [ -f "$IPF_SYS_UNIT" ] && echo -e "  ${IPF_SYS_UNIT} (ziyong 自建)"
    elif has_openrc; then
        [ -f "$IPF_OPENRC" ] && echo -e "  ${IPF_OPENRC} + ${IPF_CONFD}"
    else
        echo -e "  nohup 模式 (日志: ${IPF_LOG_FILE})"
    fi
    ipf_show_client "$IPF_PORT"
    echo ""
    info "当前公网IP: $(get_pub_ip)"
}

ipf_logs() {
    ipf_installed || { err "尚未安装 iperf3"; return 1; }
    if has_systemd; then
        journalctl -u iperf3 -n 50 --no-pager 2>/dev/null || tail -n 50 "$IPF_LOG_FILE" 2>/dev/null
    elif [ -s "$IPF_LOG_FILE" ]; then
        tail -n 50 "$IPF_LOG_FILE"
    elif command -v logread >/dev/null 2>&1; then
        logread 2>/dev/null | grep -i iperf3 | tail -n 50
    else
        err "未找到日志 (iperf3 服务端仅在客户端连接时产生输出)"
    fi
    echo ""
    warn "以上为最近 50 行 (iperf3 空闲时通常无日志, 有客户端连接才输出)"
}

ipf_uninstall() {
    check_root
    ipf_installed || { err "尚未安装 iperf3"; return 1; }
    if ! ask_yn "确认卸载 iperf3 服务?" "Y"; then info "已取消"; return 0; fi

    ipf_ctl disable >/dev/null 2>&1
    ipf_remove_autostart
    # 清理 ziyong 添加的定义 (不动发行版包自带文件)
    rm -f "$IPF_DROPIN" 2>/dev/null
    rmdir "$IPF_DROPIN_DIR" 2>/dev/null
    if [ -f "$IPF_SYS_UNIT" ] && grep -q "$IPF_MARK" "$IPF_SYS_UNIT" 2>/dev/null; then
        rm -f "$IPF_SYS_UNIT"
    fi
    if [ -f "$IPF_OPENRC" ] && grep -q "$IPF_MARK" "$IPF_OPENRC" 2>/dev/null; then
        rm -f "$IPF_OPENRC"
    fi
    if [ -f "$IPF_CONFD" ] && grep -q "$IPF_MARK" "$IPF_CONFD" 2>/dev/null; then
        printf 'command_args=""\n' > "$IPF_CONFD"
    fi
    has_systemd && systemctl daemon-reload >/dev/null 2>&1
    rm -f "$IPF_CONF_PERSIST" "$IPF_PID_FILE"

    if ask_yn "是否同时卸载 iperf3 软件包?" "N"; then
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get purge -y iperf3
        elif command -v dnf >/dev/null 2>&1; then
            dnf remove -y iperf3
        elif command -v yum >/dev/null 2>&1; then
            yum remove -y iperf3
        elif command -v apk >/dev/null 2>&1; then
            apk del iperf3 iperf3-openrc
        fi
        hash -r 2>/dev/null
        if command -v iperf3 >/dev/null 2>&1; then
            err "软件包卸载可能未完成, 请手动检查"
        else
            info "iperf3 软件包已卸载"
        fi
    else
        info "已保留 iperf3 软件包 (仅移除服务配置)"
    fi
    info "iperf3 卸载完成"
}

ipf_menu() {
    while true; do
        load_ipf_conf
        local tag="  ${RED}[未安装]${PLAIN}"
        ipf_running && tag="  ${GREEN}[运行中]${PLAIN}"
        ipf_installed && ! ipf_running && tag="  ${YELLOW}[已停止]${PLAIN}"
        clear
        echo -e "${CYAN}╔════════════════════════════════════════════╗"
        echo -e "║        ${BOLD}iperf3 测速服务端 管理菜单${PLAIN}${CYAN}         ║"
        echo -e "╚════════════════════════════════════════════╝${PLAIN}"
        echo ""
        echo -e "  当前状态: ${tag}"
        echo ""
        echo -e "  ${GREEN}${BOLD}1${PLAIN}.  安装 / 启动 iperf3 服务端"
        echo -e "  ${GREEN}${BOLD}2${PLAIN}.  一键停用 (停止 + 关闭自启)"
        echo -e "  ${GREEN}${BOLD}3${PLAIN}.  恢复启动 + 开机自启"
        echo -e "  ${GREEN}${BOLD}4${PLAIN}.  更换端口"
        echo -e "  ${GREEN}${BOLD}5${PLAIN}.  查看状态 / 测速命令"
        echo -e "  ${GREEN}${BOLD}6${PLAIN}.  查看日志 (最近50行)"
        echo -e "  ${RED}${BOLD}7${PLAIN}.  卸载 iperf3"
        echo -e "  ${RED}${BOLD}0${PLAIN}.  返回上级菜单"
        echo ""
        line
        read -rp "请输入选项 [0-7]: " sub
        case "$sub" in
            1) ipf_install;      pause_back ;;
            2) ipf_disable;      pause_back ;;
            3) ipf_enable;       pause_back ;;
            4) ipf_change_port;  pause_back ;;
            5) ipf_status;       pause_back ;;
            6) ipf_logs;         pause_back ;;
            7) ipf_uninstall;    pause_back ;;
            0) return 0 ;;
            *) warn "无效选项, 请重新输入"; sleep 1 ;;
        esac
    done
}

load_ipf_conf

# ============================================================
#  主菜单
# ============================================================

# 从 GitHub 拉取最新版脚本自更新
self_update() {
    local tmp="/tmp/ziyong_new.$$.sh" new_ver=""
    info "当前版本: v${VERSION}, 正在检查更新..."
    if download "https://raw.githubusercontent.com/qingshous/ziyong/main/ziyong.sh" "$tmp"; then
        new_ver=$(grep -m1 '^VERSION=' "$tmp" | cut -d'"' -f2)
        if [ -z "$new_ver" ]; then
            err "下载内容异常 (无版本号), 已取消更新"; rm -f "$tmp"; return 1
        fi
        if [ "$new_ver" = "$VERSION" ]; then
            info "已是最新版本 v${VERSION}"; rm -f "$tmp"; return 0
        fi
        # 版本号递增校验: 拒绝降级 (防止误发旧版本被当"更新")
        if ! ver_lt "$VERSION" "$new_ver"; then
            warn "远端版本 v${new_ver} 不高于当前 v${VERSION}, 已取消更新"; rm -f "$tmp"; return 0
        fi
        if ! bash -n "$tmp" 2>/dev/null; then
            err "下载的脚本语法校验失败, 已取消更新"; rm -f "$tmp"; return 1
        fi
        # 更新 slib 缓存 (slib 指向这里, 下次运行即新版)
        mkdir -p "$ZIYONG_DIR"
        # 就地写覆盖 (而非 cp 换 inode): 避免 slib 软链/硬链因 inode 脱钩而失效
        cat "$tmp" > "$CACHE_SCRIPT" 2>/dev/null
        # 文件方式运行时同时覆盖脚本本体 (就地写, 不换 inode)
        [ -f "${BASH_SOURCE[0]}" ] && cat "$tmp" > "${BASH_SOURCE[0]}" 2>/dev/null
        rm -f "$tmp"
        info "更新完成: v${VERSION} -> v${new_ver}"
        warn "请退出后重新运行 slib (或重跑本脚本) 使新版生效"
    else
        err "下载失败, 请检查网络后重试"
        return 1
    fi
}

# 卸载脚本自身 (slib 快捷命令 + /etc/ziyong 缓存), 不动已安装的服务
self_uninstall() {
    warn "将删除: slib 快捷命令, ${ZIYONG_DIR} 目录 (含端口持久化记录)"
    warn "已安装的服务 (WxChat/frps/sing-box/realm) 均不受影响, 但重跑脚本后端口需重新指定"
    if ask_yn "确认卸载脚本自身?" "Y"; then
        rm -f "$SHORTCUT"
        rm -rf "$ZIYONG_DIR"
        info "脚本自身已卸载, 再见!"
        exit 0
    fi
    info "已取消"
}

# 显示 VPS 的 IPv4 / IPv6 (进程内缓存, 首次探测后复用, 避免每次菜单刷新都 curl)
show_ip_info() {
    if [ -z "$_IP_CACHED" ]; then
        _IPV4_PUB="$(get_pub_ipv4)"
        _IPV6_PUB="$(get_pub_ipv6)"
        _IP_CACHED=1
    fi
    echo -e "  ${CYAN}IPv4:${PLAIN} $([ -n "$_IPV4_PUB" ] && echo "$_IPV4_PUB" || echo "${RED}无 IPv4${PLAIN}")"
    echo -e "  ${CYAN}IPv6:${PLAIN} $([ -n "$_IPV6_PUB" ] && echo "$_IPV6_PUB" || echo "${RED}无 IPv6${PLAIN}")"
}

show_main_menu() {
    local wxd_tag="  ${RED}[未安装]${PLAIN}"
    local wx_tag="  ${RED}[未安装]${PLAIN}"
    local frps_tag="  ${RED}[未安装]${PLAIN}"
    local sb_tag="  ${RED}[未安装]${PLAIN}"
    local pf_tag="  ${RED}[未安装]${PLAIN}"
    local rl_tag="  ${RED}[未安装]${PLAIN}"
    local ipf_tag="  ${RED}[未安装]${PLAIN}"
    if wxd_running; then
        wxd_tag="  ${GREEN}[运行中]${PLAIN}"
    elif wxd_installed; then
        wxd_tag="  ${YELLOW}[已停止]${PLAIN}"
    fi
    if wx_running; then
        wx_tag="  ${GREEN}[运行中]${PLAIN}"
    elif wx_installed; then
        wx_tag="  ${YELLOW}[已停止]${PLAIN}"
    fi
    if frps_running; then
        frps_tag="  ${GREEN}[运行中]${PLAIN}"
    elif frps_installed; then
        frps_tag="  ${YELLOW}[已停止]${PLAIN}"
    fi
    if sb_running; then
        sb_tag="  ${GREEN}[运行中]${PLAIN}"
    elif sb_installed; then
        sb_tag="  ${YELLOW}[已停止]${PLAIN}"
    fi
    if pf_running; then
        pf_tag="  ${GREEN}[运行中]${PLAIN}"
    elif pf_installed; then
        pf_tag="  ${YELLOW}[已停止]${PLAIN}"
    fi
    if rl_running; then
        rl_tag="  ${GREEN}[运行中]${PLAIN}"
    elif rl_installed; then
        rl_tag="  ${YELLOW}[已停止]${PLAIN}"
    fi
    if ipf_running; then
        ipf_tag="  ${GREEN}[运行中]${PLAIN}"
    elif ipf_installed; then
        ipf_tag="  ${YELLOW}[已停止]${PLAIN}"
    fi
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════╗"
    echo -e "║         ${BOLD}Slib 自用 VPS 服务管理脚本${PLAIN}${CYAN}         ║"
    echo -e "╚════════════════════════════════════════════╝${PLAIN}"
    echo -e "  ${CYAN}快捷命令: slib    版本: v${VERSION}${PLAIN}"
    show_ip_info
    echo ""
    echo -e "  ${GREEN}${BOLD}1${PLAIN}. WxChat 微信通知转发代理 (Docker 版)${wxd_tag}"
    echo -e "  ${GREEN}${BOLD}2${PLAIN}. WxChat 微信通知转发代理 (nginx 版)${wx_tag}"
    echo -e "  ${GREEN}${BOLD}3${PLAIN}. frps 服务端 (frp 内网穿透)${frps_tag}"
    echo -e "  ${GREEN}${BOLD}4${PLAIN}. sing-box 节点管理 (VLESS-REALITY/Hy2/TUIC等)${sb_tag}"
    echo -e "  ${GREEN}${BOLD}5${PLAIN}. realm 转发管理 xwPF版 (流量狗/链路测试)${pf_tag}"
    echo -e "  ${GREEN}${BOLD}6${PLAIN}. 轻量版 realm (realm-installer: 精简)${rl_tag}"
    echo -e "  ${GREEN}${BOLD}7${PLAIN}. iperf3 测速服务端 (带宽测速)${ipf_tag}"
    echo -e "  ${GREEN}${BOLD}8${PLAIN}. 更新脚本自身 (当前 v${VERSION})"
    echo -e "  ${GREEN}${BOLD}9${PLAIN}. 卸载脚本自身 (slib/缓存)"
    echo -e "  ${RED}${BOLD}0${PLAIN}. 退出"
    echo ""
    line
    read -rp "请选择要管理的服务 [0-9]: " main_choice
}

main() {
    check_root
    setup_shortcut
    while true; do
        show_main_menu
        case "$main_choice" in
            1) wxd_menu ;;
            2) wx_menu ;;
            3) frps_menu ;;
            4) sb_launch;      pause_back ;;
            5) pf_launch;      pause_back ;;
            6) rl_launch;      pause_back ;;
            7) ipf_menu ;;
            8) self_update;    pause_back ;;
            9) self_uninstall; pause_back ;;
            0) info "再见!"; exit 0 ;;
            *) warn "无效选项, 请重新输入"; sleep 1 ;;
        esac
    done
}

main "$@"
