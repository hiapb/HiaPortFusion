#!/bin/bash
set -e

# ========== HiaPortFusion (HAProxy+GOST, IPv4/IPv6增强, 调试版) ==========
# 支持 TCP (HAProxy) + UDP (GOST) 端口聚合，多平台自适应！
# 每条规则独立支持 IPv4/IPv6，格式自动兼容，带详细DEBUG日志
# ======================================================================

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
GOST_BIN="/usr/local/bin/gost"
RULES_FILE="/etc/hipf-rules.txt"
LOG_DIR="/var/log/hipf"
GOST_LOG="$LOG_DIR/gost.log"
HAPROXY_LOG="$LOG_DIR/haproxy.log"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_URL="https://raw.githubusercontent.com/hiapb/HiaPortFusion/main/install.sh"

DEBUG_LOG="/tmp/gost_start_debug.log"

mkdir -p "$LOG_DIR"
touch "$RULES_FILE" "$GOST_LOG" "$HAPROXY_LOG"

# ======= GOST 安装函数，多平台自动适配 =======
function install_gost() {
    arch=$(uname -m)
    case $arch in
        x86_64|amd64)   GOST_URL="https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_amd64.tar.gz" ;;
        aarch64|arm64)  GOST_URL="https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_arm64.tar.gz" ;;
        *)
            echo -e "${RED}暂不支持的架构: $arch${RESET}"
            exit 1
            ;;
    esac
    TMPDIR=$(mktemp -d)
    wget -O "$TMPDIR/gost.tar.gz" "$GOST_URL"
    tar -xf "$TMPDIR/gost.tar.gz" -C "$TMPDIR"
    install -m 755 "$TMPDIR/gost" "$GOST_BIN"
    rm -rf "$TMPDIR"
    echo -e "${GREEN}GOST 安装完成！${RESET}"
}

# ======= HiaPortFusion 安装/更新/卸载 =======
function install_hipf() {
    echo -e "${YELLOW}正在安装 HAProxy...${RESET}"
    apt update
    apt install -y haproxy
    systemctl enable haproxy
    systemctl start haproxy
    if [ ! -f "$HAPROXY_CFG" ]; then
        mkdir -p "$(dirname $HAPROXY_CFG)"
        cat > "$HAPROXY_CFG" <<EOF
global
    daemon
    maxconn 10240
    log 127.0.0.1 local0 info
defaults
    mode tcp
    timeout connect 5s
    timeout client  60s
    timeout server  60s
EOF
        systemctl restart haproxy
    fi
    echo -e "${YELLOW}正在安装 GOST...${RESET}"
    install_gost
    echo -e "${GREEN}HiaPortFusion 安装完成！${RESET}"
}

function upgrade_hipf() {
    echo -e "${YELLOW}正在升级 HiaPortFusion...${RESET}"
    if [[ $SCRIPT_URL == *你的仓库* ]]; then
        echo -e "${RED}请设置正确的 SCRIPT_URL！${RESET}"
        return
    fi
    wget -O "$SCRIPT_PATH" "$SCRIPT_URL" && chmod +x "$SCRIPT_PATH"
    apt update
    apt install -y --only-upgrade haproxy
    install_gost
    systemctl restart haproxy
    pkill -f "$GOST_BIN -L=udp" || true
    start_gost_udps
    echo -e "${GREEN}HiaPortFusion 及依赖已全部升级！${RESET}"
}

function uninstall_hipf() {
    echo -e "${YELLOW}即将卸载 HiaPortFusion（含依赖、规则、日志及脚本自身），确认请按 y：${RESET}"
    read Y
    [[ "$Y" == "y" || "$Y" == "Y" ]] || exit 0
    pkill -f "$GOST_BIN -L=udp" || true
    apt purge -y haproxy
    rm -rf "$RULES_FILE" "$LOG_DIR" "$GOST_BIN"
    rm -f "$SCRIPT_PATH"
    echo -e "${GREEN}已卸载 HiaPortFusion 及全部依赖。${RESET}"
    exit 0
}

# =========== 端口聚合核心功能 ===========

function restart_haproxy() {
    systemctl restart haproxy || true
    echo "DEBUG: restart_haproxy at $(date)" >> "$DEBUG_LOG"
}

function start_gost_udps() {
    pkill -f "$GOST_BIN -L=udp" || true
    echo "DEBUG: start_gost_udps at $(date)" >> "$DEBUG_LOG"
    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        IFS=" " read -r PORT TARGET LISTEN_ADDR <<<"$line"
        echo "DEBUG: 启动 GOST: $GOST_BIN -L=udp://$LISTEN_ADDR:$PORT/$TARGET" >> "$DEBUG_LOG"
        nohup $GOST_BIN -L=udp://$LISTEN_ADDR:$PORT/$TARGET >> "$LOG_DIR/gost-$PORT.log" 2>&1 &
    done < "$RULES_FILE"
}

function reload_all() {
    echo "DEBUG: reload_all at $(date)" >> "$DEBUG_LOG"
    restart_haproxy
    start_gost_udps
}

function add_rule() {
    echo -ne "${GREEN}请输入本机监听端口:${RESET} "
    read PORT
    echo -ne "${GREEN}请输入目标 IP:PORT（如 1.2.3.4:5678 或 [2408:8000::8b6:7c48]:5678）:${RESET} "
    read TARGET
    echo -ne "${GREEN}请选择协议族：1) IPv4  2) IPv6  [1/2] 默认1:${RESET} "
    read PROTO

    if [[ "$PROTO" == "2" ]]; then
        LISTEN_ADDR="[::]"
        # 自动补全 IPv6 目标中括号
        if [[ ! "$TARGET" =~ ^\[.*\]:[0-9]+$ ]]; then
            IP=$(echo "$TARGET" | awk -F: '{OFS=":"; for(i=1;i<NF-1;i++) printf $i (i<NF-1?OFS:""); }')
            PORTV6=$(echo "$TARGET" | awk -F: '{print $NF}')
            TARGET="[$IP]:$PORTV6"
        fi
    else
        LISTEN_ADDR="0.0.0.0"
        TARGET=$(echo "$TARG
