#!/bin/bash
# =========================================
# 🌀 TUIC v5 自动部署脚本 (自动端口 + 自动镜像)
# 兼容: Alpine / Debian / Ubuntu / Claw Cloud
# 支持: 环境变量 uuid (固定节点)
# by eishare / 2025-10
# =========================================

set -euo pipefail
IFS=$'\n\t'

TUIC_VERSION="1.5.2"
WORK_DIR="/root/tuic"
BIN_PATH="$WORK_DIR/tuic-server"
CONF_PATH="$WORK_DIR/server.toml"
CERT_PEM="$WORK_DIR/tuic-cert.pem"
KEY_PEM="$WORK_DIR/tuic-key.pem"
LINK_PATH="$WORK_DIR/tuic_link.txt"
LOG_FILE="$WORK_DIR/tuic.log"
START_SH="$WORK_DIR/start.sh"
MASQ_DOMAIN="www.bing.com"

# ------------------ 卸载 ------------------
if [[ "${1:-}" == "uninstall" ]]; then
    echo "🧹 正在卸载 TUIC..."
    pkill -f tuic-server || true
    rm -rf "$WORK_DIR"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable tuic-server.service 2>/dev/null || true
        rm -f /etc/systemd/system/tuic-server.service
        systemctl daemon-reload
    fi
    echo "✅ 卸载完成"
    exit 0
fi

# ------------------ 检查系统 ------------------
echo "🔍 检查系统信息..."
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]] && ARCH="x86_64"
[[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && ARCH="aarch64"

if grep -qi alpine /etc/os-release; then
    C_LIB_SUFFIX="-linux-musl"
    PKG_INSTALL="apk add --no-cache bash curl openssl procps iproute2 net-tools"
elif command -v apt >/dev/null 2>&1; then
    C_LIB_SUFFIX="-linux"
    PKG_INSTALL="apt update -y && apt install -y curl openssl uuid-runtime procps iproute2 net-tools"
elif command -v yum >/dev/null 2>&1; then
    C_LIB_SUFFIX="-linux"
    PKG_INSTALL="yum install -y curl openssl uuid procps-ng iproute net-tools"
else
    echo "❌ 不支持的系统类型"
    exit 1
fi

# ------------------ 安装依赖 ------------------
echo "🔧 检查并安装依赖..."
eval "$PKG_INSTALL" >/dev/null 2>&1
echo "✅ 依赖安装完成"

# ------------------ 自动选择端口 ------------------
echo "🎯 自动选择可用端口..."
for p in $(seq 30000 65000 | shuf); do
    if ! ss -tuln | grep -q ":$p "; then
        PORT="$p"
        break
    fi
done
echo "✅ 已自动分配端口: $PORT"

# ------------------ 创建目录 ------------------
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ------------------ 下载 TUIC ------------------
BASE_URL="https://github.com/Itsusinn/tuic/releases/download/v${TUIC_VERSION}/tuic-server-${ARCH}${C_LIB_SUFFIX}"
PROXY_URL="https://mirror.ghproxy.com/${BASE_URL}"

echo "⬇️ 尝试下载 TUIC: $BASE_URL"
if curl -L -f -o "$BIN_PATH" "$BASE_URL"; then
    echo "✅ 从 GitHub 下载成功"
else
    echo "⚠️ GitHub 下载失败，切换到镜像源..."
    if curl -L -f -o "$BIN_PATH" "$PROXY_URL"; then
        echo "✅ 从 ghproxy 镜像下载成功"
    else
        echo "❌ 所有源下载失败，请检查网络"
        exit 1
    fi
fi
chmod +x "$BIN_PATH"

# ------------------ 生成证书 ------------------
if [[ ! -f]()]()
