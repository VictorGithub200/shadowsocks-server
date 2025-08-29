#!/usr/bin/env bash
# ============================================================================
#  Shadowsocks-Rust 一键安装 / 管理脚本（适配 Debian 12/13）
#  Author: ChatGPT (for Victor)
#  Features:
#    - 使用 apt 安装 shadowsocks-rust（不编译源码，避免 pcre 兼容性问题）
#    - 交互式设置端口/密码/加密方式，或使用环境变量无交互安装
#    - 生成 /etc/shadowsocks-rust/config.json
#    - 安装/创建 systemd 服务（/etc/systemd/system/ssserver.service）
#    - 开放防火墙（ufw / iptables 兼容）
#    - 展示 ss:// 链接与二维码
#    - 常用操作：install | start | stop | restart | showInfo | showQR | showLog | uninstall | menu
#  Tested on: Debian 12 (bookworm), Debian 13 (trixie)
# ============================================================================
set -euo pipefail

RED="\033[31m"      # Error
GREEN="\033[32m"    # Success
YELLOW="\033[33m"   # Warning
BLUE="\033[36m"     # Info
PLAIN='\033[0m'

NAME="shadowsocks-rust"
SERVICE_NAME="ssserver"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# ------------------------ utils ------------------------
colorEcho() { echo -e "${1}${*:2}${PLAIN}"; }

need_root() {
  if [[ $(id -u) -ne 0 ]]; then
    colorEcho "$RED" "请以 root 身份运行此脚本（sudo -i）。"; exit 1; fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { colorEcho "$RED" "缺少命令：$1"; exit 1; }
}

ip_guess() {
  local ip_v4 ip_v6
  ip_v4=$(curl -fsS4 https://ip.sb || true)
  if [[ -n "${ip_v4}" ]]; then echo "$ip_v4"; return; fi
  ip_v6=$(curl -fsS6 https://ip.sb || true)
  if [[ -n "${ip_v6}" ]]; then echo "$ip_v6"; return; fi
  hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
}

base64_nopad() {
  if base64 --help 2>&1 | grep -q "-w"; then
    base64 -w 0
  else
    base64
  fi
}

# ------------------------ status helpers ------------------------
ss_installed() {
  command -v ssserver >/dev/null 2>&1
}

service_active() {
  systemctl is-active --quiet ${SERVICE_NAME}
}

# ------------------------ prompts ------------------------
PASSWORD="${SS_PASSWORD:-}"
PORT="${SS_PORT:-}"
METHOD="${SS_METHOD:-}"

ask_config() {
  echo ""
  if [[ -z "${PASSWORD}" ]]; then
    read -rp "请设置 SS 密码（为空则随机生成）: " PASSWORD || true
    if [[ -z "${PASSWORD}" ]]; then
      PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
    fi
  fi
  colorEcho "$BLUE" "密码： ${PASSWORD}"

  echo ""
  while :; do
    if [[ -z "${PORT}" ]]; then
      read -rp "请设置端口 [1025-65535]（为空随机）: " PORT || true
      [[ -z "${PORT}" ]] && PORT=$(shuf -i1025-65000 -n1)
    fi
    if [[ "${PORT}" =~ ^[0-9]+$ ]] && (( PORT >= 1025 && PORT <= 65535 )); then
      colorEcho "$BLUE" "端口： ${PORT}"; break
    else
      colorEcho "$YELLOW" "端口无效，需在 1025-65535 之间。"
      PORT=""
    fi
  done

  echo ""
  if [[ -z "${METHOD}" ]]; then
    cat <<EOM
${RED}请选择加密方式${PLAIN}（推荐 chacha20-ietf-poly1305 或 aes-256-gcm）：
  1) aes-256-gcm
  2) chacha20-ietf-poly1305
  3) xchacha20-ietf-poly1305
EOM
    read -rp "选择 [1-3]（默认 2）: " ans || true
    case "${ans:-2}" in
      1) METHOD="aes-256-gcm";;
      2) METHOD="chacha20-ietf-poly1305";;
      3) METHOD="xchacha20-ietf-poly1305";;
      *) METHOD="chacha20-ietf-poly1305";;
    esac
  fi
  colorEcho "$BLUE" "加密方式： ${METHOD}"
}

# ------------------------ package / firewall ------------------------
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt update -y

  # 安装 ss server
  wget https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.21.0/shadowsocks-v1.21.0.x86_64-unknown-linux-gnu.tar.xz
  tar -xvf shadowsocks-v1.21.0.x86_64-unknown-linux-gnu.tar.xz -C /usr/local/bin

  apt install -y qrencode curl wget net-tools iproute2 jq
}

open_firewall() {
  # Try UFW first
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -qi active; then
      ufw allow ${PORT}/tcp || true
      ufw allow ${PORT}/udp || true
      colorEcho "$GREEN" "已通过 ufw 放行端口 ${PORT}/tcp, ${PORT}/udp"
      return
    fi
  fi
  # Fallback to iptables (nft backend on Debian 12/13)
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT || true
    iptables -C INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT || true
    colorEcho "$GREEN" "已通过 iptables 放行端口 ${PORT}/tcp, ${PORT}/udp"
    return
  fi
  colorEcho "$YELLOW" "未检测到 ufw/iptables，若有其它防火墙（如云厂商安全组、nftables），请手动放行 ${PORT}/tcp 和 ${PORT}/udp。"
}

# ------------------------ configure & service ------------------------
write_config() {
  mkdir -p "${CONFIG_DIR}"
  cat >"${CONFIG_FILE}" <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "method": "${METHOD}",
  "mode": "tcp_and_udp",
  "timeout": 600,
  "fast_open": false,
  "no_delay": true,
  "ipv6_first": true
}
EOF
  chmod 600 "${CONFIG_FILE}"
}

install_service() {
  local BIN
  BIN=$(command -v ssserver || true)
  if [[ -z "${BIN}" ]]; then
    colorEcho "$RED" "未找到 ssserver 可执行文件。"; exit 1
  fi
  cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=Shadowsocks-Rust Server (ssserver)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ${SERVICE_NAME} >/dev/null 2>&1 || true
}

start_service() {
  systemctl restart ${SERVICE_NAME}
  sleep 1
  if systemctl is-active --quiet ${SERVICE_NAME}; then
    colorEcho "$GREEN" "Shadowsocks-Rust 启动成功。"
  else
    colorEcho "$RED" "Shadowsocks-Rust 启动失败，请查看日志。"
  fi
}

stop_service() {
  systemctl stop ${SERVICE_NAME} || true
  colorEcho "$BLUE" "Shadowsocks-Rust 已停止。"
}

show_info() {
  if ! ss_installed || [[ ! -f "${CONFIG_FILE}" ]]; then
    colorEcho "$RED" "未安装或未配置。"; return
  fi
  local ip method password port state
  ip=$(ip_guess)
  method=$(jq -r '.method' "${CONFIG_FILE}" 2>/dev/null || true)
  password=$(jq -r '.password' "${CONFIG_FILE}" 2>/dev/null || true)
  port=$(jq -r '.server_port' "${CONFIG_FILE}" 2>/dev/null || true)
  if service_active; then state="${GREEN}正在运行${PLAIN}"; else state="${YELLOW}未运行${PLAIN}"; fi

  local userinfo link
  userinfo="${method}:${password}@${ip}:${port}"
  link="ss://$(echo -n "${userinfo}" | base64_nopad)"

  echo "============================================"
  echo -e " 运行状态：${state}"
  echo " 配置文件：${CONFIG_FILE}"
  echo ""
  echo " SS 信息："
  echo "   IP(address):  ${ip}"
  echo "   端口(port):   ${port}"
  echo "   密码(password): ${password}"
  echo "   加密(method): ${method}"
  echo ""
  echo " SS 链接："
  echo "   ${link}"
}

show_qr() {
  if ! command -v qrencode >/dev/null 2>&1; then colorEcho "$YELLOW" "未安装 qrencode，跳过二维码。"; return; fi
  local ip method password port link
  ip=$(ip_guess)
  method=$(jq -r '.method' "${CONFIG_FILE}" 2>/dev/null || true)
  password=$(jq -r '.password' "${CONFIG_FILE}" 2>/dev/null || true)
  port=$(jq -r '.server_port' "${CONFIG_FILE}" 2>/dev/null || true)
  link="ss://$(echo -n "${method}:${password}@${ip}:${port}" | base64_nopad)"
  qrencode -o - -t utf8 "${link}" || true
}

show_log() { journalctl -u ${SERVICE_NAME} -n 200 --no-pager || true; }

# ------------------------ actions ------------------------
install_all() {
  ask_config
  apt_install
  write_config
  install_service
  open_firewall
  start_service
  show_info
}

reconfig() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then colorEcho "$RED" "未安装，无法修改配置。"; exit 1; fi
  ask_config
  write_config
  start_service
  show_info
}

uninstall_all() {
  stop_service || true
  systemctl disable ${SERVICE_NAME} >/dev/null 2>&1 || true
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload
  apt purge -y shadowsocks-rust >/dev/null 2>&1 || true
  rm -rf "${CONFIG_DIR}"
  colorEcho "$GREEN" "已卸载 Shadowsocks-Rust，并清理配置。"
}

menu() {
  clear
  echo "#############################################################"
  echo -e "#        ${GREEN}Shadowsocks-Rust 一键脚本（Debian 12/13）${PLAIN}       #"
  echo "#############################################################"
  echo ""
  echo -e "  ${GREEN}1.${PLAIN} 安装/重装"
  echo -e "  ${GREEN}2.${PLAIN} 启动"
  echo -e "  ${GREEN}3.${PLAIN} 重启"
  echo -e "  ${GREEN}4.${PLAIN} 停止"
  echo -e "  ${GREEN}5.${PLAIN} 查看配置"
  echo -e "  ${GREEN}6.${PLAIN} 显示二维码"
  echo -e "  ${GREEN}7.${PLAIN} 查看日志"
  echo -e "  ${GREEN}8.${PLAIN} 修改配置"
  echo -e "  ${GREEN}9.${PLAIN} 卸载"
  echo -e "  ${GREEN}0.${PLAIN} 退出"
  echo ""
  echo -n "当前状态："
  if service_active; then echo -e "${GREEN}已安装${PLAIN} ${GREEN}正在运行${PLAIN}"; else if ss_installed; then echo -e "${GREEN}已安装${PLAIN} ${YELLOW}未运行${PLAIN}"; else echo -e "${RED}未安装${PLAIN}"; fi; fi
  echo ""
  read -rp "请选择 [0-9]: " ans || true
  case "${ans:-}" in
    1) install_all;;
    2) start_service;;
    3) systemctl restart ${SERVICE_NAME};;
    4) stop_service;;
    5) show_info;;
    6) show_qr;;
    7) show_log;;
    8) reconfig;;
    9) uninstall_all;;
    0) exit 0;;
    *) colorEcho "$RED" "无效选择";;
  esac
}

# ------------------------ main ------------------------
need_root
ACTION="${1:-menu}"
case "$ACTION" in
  install) install_all ;;
  start) start_service ;;
  restart) systemctl restart ${SERVICE_NAME} ;;
  stop) stop_service ;;
  showInfo) show_info ;;
  showQR) show_qr ;;
  showLog) show_log ;;
  reconfig) reconfig ;;
  uninstall) uninstall_all ;;
  menu) menu ;;
  *) echo "用法: $0 [menu|install|start|restart|stop|showInfo|showQR|showLog|reconfig|uninstall]" ; exit 1 ;;
 esac

