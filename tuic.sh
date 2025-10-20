#!/bin/bash
# =========================================
# TUIC v5 over QUIC 自动部署脚本（免 root / 适配 Alpine / NAT VPS）
# 特性：
#  - 支持一键执行或指定端口参数（bash tuic.sh 443）
#  - 自动下载 musl 静态版 tuic-server
#  - 随机握手 SNI + 随机 MTU + BBR 拥塞控制
#  - 自动重启守护，无需 root
# =========================================

set -euo pipefail
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ===================== 随机生成函数 =====================
random_port() {
  echo $(( (RANDOM % 40000) + 20000 ))
}

random_sni() {
  local sni_list=("www.bing.com" "www.cloudflare.com" "www.microsoft.com" "www.google.com" "cdn.jsdelivr.net")
  echo "${sni_list[$RANDOM % ${#sni_list[@]}]}"
}

# ===================== 获取端口（支持参数传入） =====================
read_port() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_PORT="$1"
    echo "✅ 使用命令行端口: $TUIC_PORT"
    return
  fi

  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
    echo "✅ 使用环境变量端口: $TUIC_PORT"
    return
  fi

  TUIC_PORT=$(random_port)
  echo "🎲 未指定端口，自动分配随机端口: $TUIC_PORT"
}

# ===================== 加载现有配置 =====================
load_existing_config() {
  if [[ -f "$SERVER_TOML" ]]; then
    TUIC_PORT=$(grep '^server =' "$SERVER_TOML" | sed -E 's/.*:(.*)\"/\1/')
    TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}')
    echo "📂 检测到已有配置，加载中..."
    return 0
  fi
  return 1
}

# ===================== 生成自签证书 =====================
generate_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "🔐 检测到已有证书，跳过生成"
    return
  fi
  MASQ_DOMAIN=$(random_sni)
  echo "🔐 生成伪装证书 (${MASQ_DOMAIN})..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM"
  chmod 644 "$CERT_PEM"
}

# ===================== 检查并下载 tuic-server =====================
check_tuic_server() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ tuic-server 已存在"
    return
  fi

  echo "📥 下载 tuic-server (musl 静态编译版)..."
  ARCH=$(uname -m)
  if [[ "$ARCH" != "x86_64" ]]; then
    echo "❌ 暂不支持架构: $ARCH"
    exit 1
  fi

  TUIC_URL="https://github.com/EAimTY/tuic/releases/latest/download/tuic-server-x86_64-unknown-linux-musl"
  if curl -L -f -o "$TUIC_BIN" "$TUIC_URL"; then
    chmod +x "$TUIC_BIN"
    echo "✅ tuic-server 下载完成"
  else
    echo "❌ 下载失败，请检查网络或手动下载: $TUIC_URL"
    exit 1
  fi
}

# ===================== 生成配置文件 =====================
generate_config() {
cat > "$SERVER_TOML" <<EOF
log_level = "warn"
server = "0.0.0.0:${TUIC_PORT}"

udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "8s"
task_negotiation_timeout = "4s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${TUIC_PORT}"
secret = "$(openssl rand -hex 16)"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = $((1200 + RANDOM % 200))
min_mtu = 1200
gso = true
pmtu = true
send_window = 33554432
receive_window = 16777216
max_idle_time = "25s"

[quic.congestion_control]
controller = "bbr"
initial_window = 6291456
EOF
}

# ===================== 获取公网 IP =====================
get_server_ip() {
  ip=$(curl -s --connect-timeout 3 https://api64.ipify.org || true)
  echo "${ip:-127.0.0.1}"
}

# ===================== 生成 TUIC 链接 =====================
generate_link() {
  local ip="$1"
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF
  echo "🔗 TUIC 链接已生成并保存到 ${LINK_TXT}"
  echo "🔗 内容："
  cat "$LINK_TXT"
  echo ""
}

# ===================== 守护进程循环 =====================
run_background_loop() {
  echo "🚀 启动 TUIC 服务 (监听端口 ${TUIC_PORT}) ..."
  while true; do
    echo "----- $(date '+%F %T') 启动 tuic-server -----" >> tuic.log
    "$TUIC_BIN" -c "$SERVER_TOML" >> tuic.log 2>&1 || true
    echo "⚠️ tuic-server 异常退出，5秒后重启..." | tee -a tuic.log
    tail -n 40 tuic.log || true
    sleep 5
  done
}

# ===================== 主逻辑 =====================
main() {
  if ! load_existing_config; then
    read_port "$@"
    TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
    generate_cert
    check_tuic_server
    generate_config
  else
    generate_cert
    check_tuic_server
  fi

  ip="$(get_server_ip)"
  generate_link "$ip"
  run_background_loop
}

main "$@"
