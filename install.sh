#!/bin/bash
set -e

# ========== HiaPortFusion (HAProxy+GOST) ==========
# 一键聚合 TCP (HAProxy) + UDP (GOST) 端口转发，多平台自适应！
# ===================================

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
SCRIPT_URL="https://raw.githubusercontent.com/hiapb/HiaPortFusion/main/install.sh"  # 请根据你的仓库地址调整

mkdir -p "$LOG_DIR"
touch "$RULES_FILE" "$GOST_LOG" "$HAPROXY_LOG"

# ======= GOST 安装函数，多平台自动适配 =======
function install_gost() {
    arch=$(uname -m)
    case $arch in
        x86_64|amd64)   GOST_URL="https://github.com/go-gost/gost/releases/download/v3.0.0/gost-linux-amd64-3.0.0.gz" ;;
        armv7l)         GOST_URL="https://github.com/go-gost/gost/releases/download/v3.0.0/gost-linux-arm-3.0.0.gz" ;;
        aarch64|arm64)  GOST_URL="https://github.com/go-gost/gost/releases/download/v3.0.0/gost-linux-arm64-3.0.0.gz" ;;
        *) echo -e "${RED}不支持的架构: $arch${RESET}"; exit 1 ;;
    esac
    TMPDIR=$(mktemp -d)
    wget -O "$TMPDIR/gost.gz" "$GOST_URL"
    gunzip "$TMPDIR/gost.gz"
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
    # 升级本体
    wget -O "$SCRIPT_PATH" "$SCRIPT_URL" && chmod +x "$SCRIPT_PATH"
    # 升级依赖
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
function restart_haproxy() { systemctl restart haproxy || true; }

function start_gost_udps() {
    pkill -f "$GOST_BIN -L=udp" || true
    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        IFS=" " read -r PORT TARGET <<<"$line"
        nohup $GOST_BIN -L=udp://:$PORT/$TARGET >> "$LOG_DIR/gost-$PORT.log" 2>&1 &
    done < "$RULES_FILE"
}

function reload_all() { restart_haproxy; start_gost_udps; }
function add_rule() {
    echo -ne "${GREEN}请输入本机监听端口:${RESET} "
    read PORT
    echo -ne "${GREEN}请输入目标 IP:PORT（如 1.2.3.4:5678）:${RESET} "
    read TARGET
    sed -i "/^$PORT /d" "$RULES_FILE"
    echo "$PORT $TARGET" >> "$RULES_FILE"
    sed -i "/^listen combo-$PORT\b/,/^$/d" "$HAPROXY_CFG"
    cat >> "$HAPROXY_CFG" <<EOF

listen combo-$PORT
    bind *:$PORT
    mode tcp
    server s1 $TARGET
EOF
    reload_all
    echo -e "${GREEN}已添加：$PORT <=> $TARGET（TCP+UDP）${RESET}"
}
function del_rule() {
    if [[ ! -s $RULES_FILE ]]; then echo -e "${RED}暂无规则。${RESET}"; return; fi
    nl -w2 -s'. ' "$RULES_FILE"
    echo -ne "${GREEN}输入要删除的序号:${RESET} "
    read IDX
    PORT=$(awk "NR==$IDX{print \$1}" "$RULES_FILE")
    sed -i "${IDX}d" "$RULES_FILE"
    sed -i "/^listen combo-$PORT\b/,/^$/d" "$HAPROXY_CFG"
    pkill -f "$GOST_BIN -L=udp://:$PORT" || true
    reload_all
    echo -e "${GREEN}已删除端口 $PORT 的 TCP+UDP 转发规则。${RESET}"
}
function del_all_rules() {
    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        IFS=" " read -r PORT _ <<<"$line"
        pkill -f "$GOST_BIN -L=udp://:$PORT" || true
    done < "$RULES_FILE"
    > "$RULES_FILE"
    grep -E '^listen combo-' "$HAPROXY_CFG" | awk '{print $2}' | sed 's/combo-//' | while read port; do
        sed -i "/^listen combo-$port\b/,/^$/d" "$HAPROXY_CFG"
    done
    reload_all
    echo -e "${GREEN}已清空所有规则。${RESET}"
}
function view_rules() {
    if [[ ! -s $RULES_FILE ]]; then
        echo -e "${RED}暂无转发规则。${RESET}"
    else
        nl -w2 -s'. ' "$RULES_FILE"
    fi
}
function view_logs() {
    echo -e "${YELLOW}--- HAProxy 日志 ---${RESET}"
    tail -n 20 "$HAPROXY_LOG" 2>/dev/null || echo "(暂无日志)"
    echo -e "${YELLOW}--- GOST UDP 日志（最新端口） ---${RESET}"
    ls -t $LOG_DIR/gost-*.log 2>/dev/null | head -n 1 | xargs -r tail -n 20 || echo "(暂无日志)"
}

while true; do
    echo -e "${GREEN}
=========== HiaPortFusion (HAProxy+GOST) ===========

  1. 安装 HiaPortFusion
  2. 更新 HiaPortFusion
  3. 卸载 HiaPortFusion

  4. 添加转发规则
  5. 删除单条规则
  6. 清空全部规则
  7. 查看当前规则
  8. 查看日志

  0. 退出
=====================================

${RESET}"
    echo -ne "${GREEN}选择操作 [0-8]:${RESET} "
    read opt
    case $opt in
        1) install_hipf ;;
        2) upgrade_hipf ;;
        3) uninstall_hipf ;;
        4) add_rule ;;
        5) del_rule ;;
        6) del_all_rules ;;
        7) view_rules ;;
        8) view_logs ;;
        0) exit 0 ;;
        *) ;;
    esac
done
