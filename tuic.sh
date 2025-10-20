#!/bin/sh
# TUIC v5 Alpine / LXC 兼容版（免 root、全自动）
# 支持随机或指定端口：bash tuic.sh [端口]

set -e

# =================== 参数与随机工具 ===================
RANDOM_PORT=$(( (RANDOM % 40000) + 20000 ))
PORT="${1:-$RANDOM_PORT}"
UUID=$(cat /proc/sys/kernel/random/uuid)
PASS=$(openssl rand -hex 16)
SNI_LIST="www.bing.com www.cloudflare.com www.google.com cdn.jsdelivr.net www.wikipedia.org"
SNI=$(echo $SNI_LIST | awk '{print $((RANDOM%NF+1))}')
CERT="tuic-cert.pem"
KEY="tuic-key.pem"
BIN="./tuic-server"
CONF="server.toml"

# =================== 环境检测与依赖 ===================
if ! command -v curl >/dev/null 2>&1; then
  echo "📦 安装 curl..."
  apk add --no-cache curl >/dev/null
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "📦 安装 openssl..."
  apk add --no-cache openssl >/dev/null
fi

# =================== 下载 TUIC 可执行文件 ===================
echo "📥 下载 TUIC 全静态 musl 版..."
TUIC_URL="https://github.com/InvisibleFutureLab/tuic-prebuilt/releases/download/fully-static/tuic-server-musl-x86_64"
curl -L -o "$BIN" "$TUIC_URL"
chmod +x "$BIN"

if ! "$BIN" -v >/dev/null 2>&1; then
  echo "❌ tuic-server 无法运行，请确认系统架构为 x86_64 Alpine"
  exit 1
fi

# =================== 生成证书 ===================
if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
  echo "🔐 生成证书 ($SNI)..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY" -out "$CERT" -subj "/CN=$SNI" -days 365 -nodes >/dev/null 2>&1
fi

# =================== 生成配置 ===================
cat > "$CONF" <<EOF
server = "0.0.0.0:$PORT"
log_level = "warn"

[users]
$UUID = "$PASS"

[tls]
certificate = "$CERT"
private_key = "$KEY"
alpn = ["h3"]

[quic]
congestion_control = "bbr"
max_idle_time = "25s"
initial_mtu = $((1200 + RANDOM % 200))
EOF

# =================== 生成 TUIC 链接 ===================
IP=$(curl -s --connect-timeout 3 https://api64.ipify.org || echo "127.0.0.1")
LINK="tuic://$UUID:$PASS@$IP:$PORT?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=$SNI&udp_relay_mode=native&reduce_rtt=1#TUIC-$IP"
echo "$LINK" > tuic_link.txt
echo "✅ TUIC 节点链接："
cat tuic_link.txt
echo ""

# =================== 启动守护进程 ===================
echo "🚀 启动 tuic-server (监听端口 $PORT)..."
while true; do
  echo "----- $(date '+%F %T') 启动 tuic-server -----" >> tuic.log
  "$BIN" -c "$CONF" >> tuic.log 2>&1 || true
  echo "⚠️ TUIC 异常退出，5秒后重启..." | tee -a tuic.log
  tail -n 20 tuic.log || true
  sleep 5
done
