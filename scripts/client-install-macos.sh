#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/usr/local/etc/sing-box"
CONFIG="$CONFIG_DIR/config.json"
WORK_DIR="/usr/local/var/lib/sing-box"
BIN="/usr/local/bin/sing-box"
PLIST="/Library/LaunchDaemons/com.singbox.cli.plist"
SERVICE="com.singbox.cli"

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


need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "请使用 sudo 运行"; exit 1; }; }
readp(){ local var="$1" msg="$2" def="${3:-}"; read -r -p "$msg${def:+ [$def]}: " v; printf -v "$var" '%s' "${v:-$def}"; }

install_singbox(){
  if [ -x "$BIN" ]; then "$BIN" version || true; return; fi
  if command -v brew >/dev/null 2>&1; then
    brew install sing-box || true
  fi
  [ -x "$BIN" ] || { echo "未找到 $BIN，请先安装 Homebrew 或手动安装 sing-box。"; exit 1; }
}

parse_vless(){
  local url="$1"
  python3 - "$url" <<'PY'
import sys, urllib.parse
u=sys.argv[1].strip()
p=urllib.parse.urlparse(u)
q=urllib.parse.parse_qs(p.query)
print('SERVER='+p.hostname)
print('PORT='+str(p.port or 443))
print('UUID='+p.username)
print('SNI='+(q.get('sni') or q.get('servername') or ['www.cloudflare.com'])[0])
print('PBK='+(q.get('pbk') or [''])[0])
print('SID='+(q.get('sid') or [''])[0])
print('FLOW='+(q.get('flow') or ['xtls-rprx-vision'])[0])
PY
}

make_config(){
  mkdir -p "$CONFIG_DIR" "$WORK_DIR"
  cat > "$CONFIG" <<EOF2
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "type": "https", "tag": "ali-dns", "server": "223.5.5.5", "server_port": 443, "path": "/dns-query", "tls": { "enabled": true, "server_name": "dns.alidns.com" } },
      { "type": "https", "tag": "remote-dns", "server": "1.1.1.1", "server_port": 443, "path": "/dns-query", "tls": { "enabled": true, "server_name": "cloudflare-dns.com" }, "detour": "proxy" }
    ],
    "rules": [
      { "rule_set": ["geosite-cn"], "server": "ali-dns" },
      { "rule_set": ["geosite-geolocation-!cn"], "server": "remote-dns" }
    ],
    "final": "remote-dns"
  },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "interface_name": "", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"], "mtu": 1380, "auto_route": true, "strict_route": false, "stack": "system" }
  ],
  "outbounds": [
    { "type": "vless", "tag": "proxy", "server": "$SERVER", "server_port": $PORT, "uuid": "$UUID", "flow": "$FLOW", "tls": { "enabled": true, "server_name": "$SNI", "utls": { "enabled": true, "fingerprint": "chrome" }, "reality": { "enabled": true, "public_key": "$PBK", "short_id": "$SID" } } },
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      { "ip_cidr": ["$SERVER/32"], "outbound": "direct" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" },
      { "rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct" }
    ],
    "rule_set": [
      { "type": "remote", "tag": "geosite-cn", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs", "download_detour": "proxy" },
      { "type": "remote", "tag": "geosite-geolocation-!cn", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs", "download_detour": "proxy" },
      { "type": "remote", "tag": "geoip-cn", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs", "download_detour": "proxy" }
    ],
    "final": "proxy",
    "default_domain_resolver": { "server": "remote-dns" }
  }
}
EOF2
}

install_daemon(){
  cat > "$PLIST" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$SERVICE</string>
<key>ProgramArguments</key><array><string>$BIN</string><string>run</string><string>-c</string><string>$CONFIG</string><string>-D</string><string>$WORK_DIR</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>/var/log/sing-box.log</string>
<key>StandardErrorPath</key><string>/var/log/sing-box.err.log</string>
</dict></plist>
EOF2
  chown root:wheel "$PLIST"; chmod 644 "$PLIST"
  launchctl bootout system/$SERVICE 2>/dev/null || true
  launchctl bootstrap system "$PLIST"
  launchctl kickstart -k system/$SERVICE
}

menu(){
  need_root
  while true; do
    clear || true
    show_ad_notice
    echo
    echo "===== macOS sing-box 客户端安装器 ====="
    echo "1) 安装 / 重装客户端"
    echo "2) 启动"
    echo "3) 停止"
    echo "4) 重启"
    echo "5) 状态"
    echo "6) 日志"
    echo "7) 卸载 daemon"
    echo "0) 退出"
    read -r -p "请选择: " c
    case "$c" in
      1)
        install_singbox
        read -r -p "请输入 vless:// 分享链接（留空则手动输入）: " URL
        if [ -n "$URL" ]; then eval "$(parse_vless "$URL")"; else readp SERVER "服务器地址"; readp PORT "端口" "11584"; readp UUID "UUID"; readp PBK "Reality Public Key"; readp SID "Reality Short ID"; readp SNI "SNI" "www.cloudflare.com"; FLOW="xtls-rprx-vision"; fi
        make_config
        "$BIN" check -c "$CONFIG"
        install_daemon
        networksetup -setdnsservers Wi-Fi 1.1.1.1 8.8.8.8 2>/dev/null || true
        echo "安装完成。" ;;
      2) launchctl kickstart -k system/$SERVICE ;;
      3) launchctl bootout system/$SERVICE 2>/dev/null || true ;;
      4) launchctl kickstart -k system/$SERVICE ;;
      5) launchctl print system/$SERVICE | grep state || true; ps aux | grep '[s]ing-box' || true ;;
      6) tail -f /var/log/sing-box.log /var/log/sing-box.err.log ;;
      7) launchctl bootout system/$SERVICE 2>/dev/null || true; rm -f "$PLIST"; echo "已卸载 daemon，配置保留：$CONFIG" ;;
      0) exit 0 ;;
    esac
  done
}
menu
