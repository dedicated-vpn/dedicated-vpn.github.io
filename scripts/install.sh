#!/usr/bin/env bash
set -euo pipefail
trap 'echo "\n错误：脚本在第 ${LINENO} 行失败。失败命令：${BASH_COMMAND}" >&2' ERR

APP_DIR="/root/sbox"
BIN="$APP_DIR/sing-box"
CONFIG="$APP_DIR/sbconfig_server.json"
CLIENT_ENV="$APP_DIR/client.env"
CLIENT_JSON_TUN="$APP_DIR/sbconfig_client_tun.json"
CLIENT_JSON_PROXY="$APP_DIR/sbconfig_client_proxy.json"
CLIENT_CLASH_META="$APP_DIR/clash-meta-client.yaml"
LOG_FILE="$APP_DIR/nohup.out"
SERVICE="sing-box-server"
SYSTEMD_FILE="/etc/systemd/system/${SERVICE}.service"
WATCH_SCRIPT="/usr/local/bin/sbserver-watch"
WATCH_TIMER="/etc/systemd/system/sbserver-watch.timer"
WATCH_SERVICE="/etc/systemd/system/sbserver-watch.service"
DEFAULT_PORT="11584"
DEFAULT_SNI="www.cloudflare.com"

show_ad_notice() {
  cat <<'AD'
****************************************************************************************************************
搬瓦工：梯子专用机，CN2 GIA线路，高性能，低延迟，99.99%高可用，跨境电商、外贸首选VPS
https://bwh.awesome-vps.com

丽萨主机：双ISP美国、新加坡、台湾原生住宅IP，tiktok运营，ChatGPT/Facebook/YouTube/Twitter/Netflix 等，流媒体全解锁，全新IP段，纯净IP，三网大陆优化线路（CN2 GIA/9929/4827）
https://lisahost.awesome-vps.com
****************************************************************************************************************
AD
}


banner() {
  clear || true
  show_ad_notice
  echo
  cat <<'BANNER'
============================================================
 sing-box VLESS Reality 一键安装脚本
 功能：
 - Linux VPS 服务端安装/管理
 - VLESS + Reality
 - 自动生成客户端链接、二维码、sing-box JSON、Clash Meta 配置
 - systemd 开机自启
 - watchdog 异常自动重启

 提醒：
 - 请在干净 VPS 上使用
 - 请确保安全组/防火墙已放行端口
 - 本脚本仅用于合法网络访问和个人学习
============================================================
BANNER
}

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请使用 root 运行：sudo bash install.sh"
    exit 1
  fi
}

pause() { read -r -p "按回车继续..." _; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  if has_cmd apt-get; then
    apt-get update -y
    apt-get install -y curl wget tar gzip jq qrencode openssl ca-certificates systemd iproute2
  elif has_cmd yum; then
    yum install -y curl wget tar gzip jq qrencode openssl ca-certificates systemd iproute
  elif has_cmd dnf; then
    dnf install -y curl wget tar gzip jq qrencode openssl ca-certificates systemd iproute
  else
    echo "无法识别包管理器，请手动安装 curl wget tar gzip jq qrencode openssl"
  fi
}

arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "不支持的架构：$(uname -m)" >&2; exit 1 ;;
  esac
}

download_sing_box() {
  mkdir -p "$APP_DIR"
  local arch version url tmp
  arch="$(arch_name)"
  version="${SING_BOX_VERSION:-}"
  if [ -z "$version" ]; then
    version="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
  fi
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
  tmp="/tmp/sing-box-${version}.tar.gz"
  echo "下载 sing-box v${version} (${arch})..."
  curl -fL "$url" -o "$tmp"
  tar -xzf "$tmp" -C /tmp
  install -m 755 "/tmp/sing-box-${version}-linux-${arch}/sing-box" "$BIN"
  "$BIN" version
}

gen_uuid() {
  if has_cmd uuidgen; then uuidgen | tr 'A-Z' 'a-z'; else cat /proc/sys/kernel/random/uuid; fi
}

gen_short_id() { openssl rand -hex 4; }

get_server_ip() {
  curl -4 -fsSL https://api.ipify.org || hostname -I | awk '{print $1}'
}

install_server() {
  need_root
  install_deps
  download_sing_box

  echo
  read -r -p "请输入服务端监听端口 [${DEFAULT_PORT}]: " PORT
  PORT="${PORT:-$DEFAULT_PORT}"
  read -r -p "请输入 Reality SNI [${DEFAULT_SNI}]: " SNI
  SNI="${SNI:-$DEFAULT_SNI}"
  read -r -p "请输入服务器公网 IP 或域名 [自动检测]: " SERVER_ADDR
  SERVER_ADDR="${SERVER_ADDR:-$(get_server_ip)}"

  UUID="$(gen_uuid)"
  SHORT_ID="$(gen_short_id)"

  echo "生成 Reality 密钥..."
  KEYPAIR="$($BIN generate reality-keypair)"
  PRIVATE_KEY="$(printf '%s\n' "$KEYPAIR" | awk '/PrivateKey/ {print $2}')"
  PUBLIC_KEY="$(printf '%s\n' "$KEYPAIR" | awk '/PublicKey/ {print $2}')"

  cat > "$CONFIG" <<EOF2
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": $PORT,
      "users": [
        { "uuid": "$UUID", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$SNI", "server_port": 443 },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ]
}
EOF2

  VLESS_URL="vless://${UUID}@${SERVER_ADDR}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#sing-box-${SERVER_ADDR}"
  cat > "$CLIENT_ENV" <<EOF2
SERVER=${SERVER_ADDR}
PORT=${PORT}
UUID=${UUID}
SNI=${SNI}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
VLESS_URL=${VLESS_URL}
EOF2
  if [[ "$SERVER_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SERVER_BYPASS_RULE='{"ip_cidr":["'"$SERVER_ADDR"'/32"],"outbound":"direct"},'
  elif [[ "$SERVER_ADDR" == *:* ]]; then
    SERVER_BYPASS_RULE='{"ip_cidr":["'"$SERVER_ADDR"'/128"],"outbound":"direct"},'
  else
    SERVER_BYPASS_RULE='{"domain":["'"$SERVER_ADDR"'"],"outbound":"direct"},'
  fi

  if [[ "$SERVER_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SERVER_BYPASS_CLASH_RULE="- IP-CIDR,${SERVER_ADDR}/32,DIRECT,no-resolve"
  elif [[ "$SERVER_ADDR" == *:* ]]; then
    SERVER_BYPASS_CLASH_RULE="- IP-CIDR6,${SERVER_ADDR}/128,DIRECT,no-resolve"
  else
    SERVER_BYPASS_CLASH_RULE="- DOMAIN,${SERVER_ADDR},DIRECT"
  fi

  cat > "$CLIENT_JSON_TUN" <<EOF2
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "ali-dns",
        "server": "223.5.5.5",
        "server_port": 443,
        "path": "/dns-query",
        "tls": {
          "enabled": true,
          "server_name": "dns.alidns.com"
        }
      },
      {
        "type": "https",
        "tag": "remote-dns",
        "server": "1.1.1.1",
        "server_port": 443,
        "path": "/dns-query",
        "tls": {
          "enabled": true,
          "server_name": "cloudflare-dns.com"
        },
        "detour": "proxy"
      }
    ],
    "rules": [
      {
        "rule_set": ["geosite-cn"],
        "server": "ali-dns"
      },
      {
        "rule_set": ["geosite-geolocation-!cn"],
        "server": "remote-dns"
      }
    ],
    "final": "remote-dns"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "",
      "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "mtu": 1380,
      "auto_route": true,
      "strict_route": false,
      "stack": "system",
      "route_address": [
        "0.0.0.0/1",
        "128.0.0.0/1",
        "100::/8",
        "200::/7",
        "400::/6",
        "800::/5",
        "1000::/4",
        "2000::/3",
        "4000::/2",
        "8000::/1"
      ]
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "$SERVER_ADDR",
      "server_port": $PORT,
      "uuid": "$UUID",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "$PUBLIC_KEY",
          "short_id": "$SHORT_ID"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      $SERVER_BYPASS_RULE
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
      {
        "rule_set": ["geosite-cn", "geoip-cn"],
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "type": "remote",
        "tag": "geosite-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "proxy"
      },
      {
        "type": "remote",
        "tag": "geosite-geolocation-!cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs",
        "download_detour": "proxy"
      },
      {
        "type": "remote",
        "tag": "geoip-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "download_detour": "proxy"
      }
    ],
    "final": "proxy",
    "default_domain_resolver": {
      "server": "remote-dns"
    }
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "cache.db"
    }
  }
}
EOF2

  cat > "$CLIENT_JSON_PROXY" <<EOF2
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 7890
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "$SERVER_ADDR",
      "server_port": $PORT,
      "uuid": "$UUID",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "$PUBLIC_KEY",
          "short_id": "$SHORT_ID"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      $SERVER_BYPASS_RULE
      {
        "ip_is_private": true,
        "outbound": "direct"
      }
    ],
    "final": "proxy"
  }
}
EOF2



  cat > "$CLIENT_CLASH_META" <<EOF2
# Clash Meta / Mihomo 客户端配置
# 适用于 Clash Verge Rev、Mihomo Party、OpenClash、Nikki 等兼容内核
# 规则：大陆直连，其他走代理；Reality VLESS 使用 TCP + XTLS Vision

mixed-port: 7890
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: info
ipv6: true
tcp-concurrent: true
unified-delay: true

geodata-mode: true
geodata-loader: standard
geo-auto-update: true
geo-update-interval: 24

dns:
  enable: true
  listen: 127.0.0.1:1053
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  nameserver-policy:
    geosite:cn:
      - https://dns.alidns.com/dns-query
      - https://doh.pub/dns-query

proxies:
  - name: proxy
    type: vless
    server: $SERVER_ADDR
    port: $PORT
    uuid: $UUID
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: $SNI
    client-fingerprint: chrome
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - proxy
      - DIRECT

rules:
  $SERVER_BYPASS_CLASH_RULE
  - GEOSITE,cn,DIRECT
  - GEOIP,cn,DIRECT
  - MATCH,PROXY
EOF2

  cat > "$SYSTEMD_FILE" <<EOF2
[Unit]
Description=sing-box server
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$BIN run -c $CONFIG
Restart=always
RestartSec=5s
StartLimitIntervalSec=0
LimitNOFILE=infinity
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable --now "$SERVICE"
  install_watchdog "$PORT" false

  echo
  echo "========== 安装完成 =========="
  show_link
}

show_link() {
  if [ ! -f "$CLIENT_ENV" ]; then echo "未找到 $CLIENT_ENV，请先安装服务端。"; return 1; fi
  # shellcheck disable=SC1090
  source "$CLIENT_ENV"
  echo
  echo "========== 客户端参数 =========="
  cat "$CLIENT_ENV"
  echo
  echo "========== sing-box 客户端 JSON 配置 =========="
  echo "TUN 客户端配置：$CLIENT_JSON_TUN"
  echo "本地代理配置：$CLIENT_JSON_PROXY"
  echo "Clash Meta 配置：$CLIENT_CLASH_META"
  echo
  echo "========== Clash Meta / Mihomo 客户端配置 =========="
  echo "$CLIENT_CLASH_META"
  echo
  echo "========== VLESS 分享链接 =========="
  echo "$VLESS_URL"
  echo
  if has_cmd qrencode; then
    echo "========== Shadowrocket / 客户端扫码 =========="
    qrencode -t ANSIUTF8 "$VLESS_URL"
  else
    echo "未安装 qrencode，无法显示二维码。"
  fi
}

install_watchdog() {
  local port="${1:-$DEFAULT_PORT}"
  local ask="${2:-true}"
  need_root
  cat > "$WATCH_SCRIPT" <<EOF2
#!/usr/bin/env bash
SERVICE="$SERVICE"
PORT="$port"
LOG="$APP_DIR/watchdog.log"
ts(){ date +"%Y-%m-%d %H:%M:%S"; }
if ! systemctl is-active --quiet "\$SERVICE"; then
  echo "\$(ts) service not active, restarting" >> "\$LOG"
  systemctl restart "\$SERVICE"
  exit 0
fi
if ! ss -tulpen | grep -q ":\$PORT"; then
  echo "\$(ts) port \$PORT not listening, restarting" >> "\$LOG"
  systemctl restart "\$SERVICE"
  exit 0
fi
echo "\$(ts) ok" >> "\$LOG"
EOF2
  chmod +x "$WATCH_SCRIPT"
  cat > "$WATCH_SERVICE" <<EOF2
[Unit]
Description=sing-box watchdog check
[Service]
Type=oneshot
ExecStart=$WATCH_SCRIPT
EOF2
  cat > "$WATCH_TIMER" <<'EOF2'
[Unit]
Description=Run sing-box watchdog every minute
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
[Install]
WantedBy=timers.target
EOF2
  systemctl daemon-reload
  systemctl enable --now sbserver-watch.timer
  [ "$ask" = true ] && echo "watchdog 已安装，检测端口：$port"
}

server_update() {
  need_root
  cp -f "$BIN" "$BIN.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  download_sing_box
  "$BIN" check -c "$CONFIG"
  systemctl restart "$SERVICE"
  echo "更新完成。"
}

menu() {
  while true; do
    banner
    cat <<EOF2
请选择操作：
1) 安装 / 重装服务端（VLESS Reality + 二维码）
2) 查看状态
3) 启动服务
4) 停止服务
5) 重启服务
6) 查看日志
7) 更新 sing-box
8) 显示客户端链接和二维码
9) 安装 / 修复 watchdog
10) 查看 watchdog 状态
11) 卸载服务
0) 退出
EOF2
    read -r -p "请输入选项: " c
    case "$c" in
      1) install_server; pause ;;
      2) systemctl status "$SERVICE" --no-pager || true; ss -tulpen | grep sing-box || true; pause ;;
      3) systemctl start "$SERVICE"; pause ;;
      4) systemctl stop "$SERVICE"; pause ;;
      5) systemctl restart "$SERVICE"; pause ;;
      6) journalctl -u "$SERVICE" -f ;;
      7) server_update; pause ;;
      8) show_link; pause ;;
      9) read -r -p "请输入需要检测的端口 [${DEFAULT_PORT}]: " p; install_watchdog "${p:-$DEFAULT_PORT}" true; pause ;;
      10) systemctl status sbserver-watch.timer --no-pager || true; tail -50 "$APP_DIR/watchdog.log" 2>/dev/null || true; pause ;;
      11) systemctl disable --now "$SERVICE" 2>/dev/null || true; rm -f "$SYSTEMD_FILE"; systemctl daemon-reload; echo "服务已卸载，配置保留在 $APP_DIR"; pause ;;
      0) exit 0 ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

menu
