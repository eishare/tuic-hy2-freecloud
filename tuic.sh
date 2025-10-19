#!/bin/bash
# =========================================
# TUIC v5 over QUIC NAT 优化版自动部署脚本（免 root）
# 特性：抗 QoS、随机握手、随机 SNI、自恢复、NAT 端口兼容
# =========================================
set -euo pipefail
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"
LOCAL_PORT=443   # 🧩 NAT VPS 内部监听端口（通常容器内开放443）

# ===================== 随机端口 & SNI =====================
random_port() {
  echo $(( (RANDOM % 40000) + 20000 ))
}
random_sni() {
  local list=( "www.bing.com" "www.cloudflare.com" "www.microsoft.com" "www.google.com" "cdn.jsdelivr.net" )
  echo "${list[$RANDOM % ${#list[@]}]}"
}

# ===================== 读取端口 =====================
read_port() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_NAT_PORT="$1"
    echo "✅ 使用命令行外网端口: $TUIC_NAT_PORT"
    return
  fi

  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_NAT_PORT="$SERVER_PORT"
    echo "✅ 使用环境变量外网端口: $TUIC_NAT_PORT"
    return
  fi

  TUIC_NAT_PORT=$(random_port)
  echo "🎲 自动分配外网端口: $TUIC_NAT_PORT"
}

# ===================== 加载已有配置 =====================
load_existing_config() {
  if [[ -f "$SERVER_TOML" ]]; then
    TUIC_NAT_PORT=$(grep '^server =' "$SERVER_TOML" | sed -E 's/.*:(.*)\"/\1/')
    TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}')
    echo "📂 已检测到配置文件，加载中..."
    return 0
  fi
  return 1
}

# ===================== 证书生成 =====================
generate_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "🔐 证书存在，跳过生成"
    return
  fi
  MASQ_DOMAIN=$(random_sni)
  echo "🔐 生成伪装证书 (${MASQ_DOMAIN})..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM"
  chmod 644 "$CERT_PEM"
}

# ===================== 检查 tuic-server =====================
check_tuic_server() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ tuic-server 已存在"
    return
  fi
  echo "📥 下载 tuic-server..."
  curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
  chmod +x "$TUIC_BIN"
}

# ===================== 生成配置文件 =====================
generate_config() {
cat > "$SERVER_TOML" <<EOF
log_level = "warn"
server = "0.0.0.0:${LOCAL_PORT}"

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
addr = "127.0.0.1:${LOCAL_PORT}"
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
controller = "cubic"
initial_window = 6291456
EOF
}

# ===================== 获取公网 IP =====================
get_server_ip() {
  curl -s --connect-timeout 3 https://api64.ipify.org || echo "127.0.0.1"
}

# ===================== 生成 TUIC 链接 =====================
generate_link() {
  local ip="$1"
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_NAT_PORT}?congestion_control=cubic&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF
  echo "🔗 TUIC 链接已生成: $(cat "$LINK_TXT")"
}

# ===================== 循环守护 =====================
run_background_loop() {
  echo "🚀 启动 TUIC 服务 (监听本地端口 ${LOCAL_PORT}, 映射外网 ${TUIC_NAT_PORT}) ..."
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 || true
    echo "⚠️ TUIC 异常退出，5秒后重启..."
    sleep 5
  done
}

# ===================== 主流程 =====================
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
