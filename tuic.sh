#!/bin/bash
# =========================================
# TUIC v5 over QUIC NAT 专用自动部署脚本（免 root）
# 修复点：避免 restful 与 server 端口冲突、IPv6/IPv4 自动兼容、日志捕获
# =========================================
set -euo pipefail
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"
LOCAL_PORT=443   # 容器/内网实际监听端口（一般 443）
LOG_FILE="tuic.log"

# ===================== 随机 SNI =====================
random_sni() {
  local list=( "www.bing.com" "www.cloudflare.com" "www.microsoft.com" "www.google.com" "cdn.jsdelivr.net" )
  echo "${list[$RANDOM % ${#list[@]}]}"
}

# ===================== 读取外网端口/外部端口 =====================
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

  echo "⚠️ 未指定外网端口，建议传入（panel/宿主映射的端口），否则生成的链接端口可能无效。"
  TUIC_NAT_PORT=0
}

# ===================== 加载已有配置 =====================
load_existing_config() {
  if [[ -f "$SERVER_TOML" ]]; then
    # 提取 server 配置（忽略格式复杂情况）
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
  if ! command -v openssl >/dev/null 2>&1; then
    echo "❌ openssl 未安装，请先安装 openssl（非 root 主机请手动准备证书）"
    exit 1
  fi
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM" || true
  chmod 644 "$CERT_PEM" || true
}

# ===================== 检查/下载 tuic-server =====================
check_tuic_server() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ tuic-server 已存在"
    return
  fi
  echo "📥 下载 tuic-server..."
  # 固定 release 二进制（你可以换成你信任的 URL）
  curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
  chmod +x "$TUIC_BIN"
}

# ===================== 生成配置文件（修复 restful 端口冲突 & 支持 IPv6 绑定） =====================
generate_config() {
  # 选择 restful 本地端口，避免与 LOCAL_PORT 冲突
  REST_PORT=$(( (LOCAL_PORT + 1000) % 60000 + 1024 ))
  # server_listen: 优先 IPv6 通配符，若失败 tuic 会回退或报错；但我们生成配置为 IPv6 格式以覆盖 IPv4/IPv6 场景
  SERVER_LISTEN="[::]:${LOCAL_PORT}"

cat > "$SERVER_TOML" <<EOF
log_level = "warn"
server = "${SERVER_LISTEN}"

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
addr = "127.0.0.1:${REST_PORT}"
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

  echo "🔧 配置生成：server=${SERVER_LISTEN}, restful=127.0.0.1:${REST_PORT}"
}

# ===================== 获取公网 IP（优先 IPv6） =====================
get_server_ip() {
  # 尝试 IPv6 公网 IP，再尝试 IPv4
  ip6=$(curl -6 -s --connect-timeout 3 https://api64.ipify.org || true)
  if [[ -n "$ip6" && "$ip6" != "127.0.0.1" ]]; then
    echo "$ip6"
    return
  fi
  ip4=$(curl -4 -s --connect-timeout 3 https://api.ipify.org || true)
  if [[ -n "$ip4" ]]; then
    echo "$ip4"
    return
  fi
  echo "127.0.0.1"
}

# ===================== 生成 TUIC 链接（IPv6 使用方括号） =====================
generate_link() {
  local ip="$1"
  local hostpart="$ip"
  if [[ "$ip" == *:* ]]; then
    hostpart="[$ip]"
  fi
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${hostpart}:${TUIC_NAT_PORT}?congestion_control=cubic&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF
  echo "🔗 TUIC 链接已生成并保存到 ${LINK_TXT}"
  echo "🔗 内容："; sed -n '1p' "$LINK_TXT"
}

# ===================== 启动并记录日志（每次崩溃会打印最后 40 行日志帮助排错） =====================
run_background_loop() {
  echo "🚀 启动 TUIC 服务 (监听本地端口 ${LOCAL_PORT}, 映射外网 ${TUIC_NAT_PORT}) ..."
  mkdir -p "$(dirname "$LOG_FILE")"
  # 清理旧日志（保留）
  touch "$LOG_FILE"
  while true; do
    echo "----- $(date +'%F %T') 启动 tuic-server -----" >> "$LOG_FILE"
    # 启动并把 stdout/stderr 都写入日志
    "$TUIC_BIN" -c "$SERVER_TOML" >> "$LOG_FILE" 2>&1 || true
    echo "⚠️ tuic-server 退出，5秒后重启..." | tee -a "$LOG_FILE"
    # 打印最近日志帮助定位原因
    echo "---- 最近 tuic.log（尾部 40 行） ----"
    tail -n 40 "$LOG_FILE" || true
    sleep 5
  done
}

# ===================== 主流程 =====================
main() {
  read_port "$@"

  if ! load_existing_config; then
    # 生成 uuid/password
    TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "auto-$(date +%s)")"
    TUIC_PASSWORD="$(openssl rand -hex 16 2>/dev/null || head -c16 /dev/urandom | xxd -p -c16)"
    echo "🔑 UUID: $TUIC_UUID"
    echo "🔑 PASSWORD: $TUIC_PASSWORD"
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
