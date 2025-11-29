#!/usr/bin/env bash
# suoha (优化版) — 修复语法/兼容/安全问题
set -euo pipefail

# ---------- 基础函数 ----------
log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
cleanup_on_exit() {
  rm -f "$ARGO_LOG" "$TMPDIR"/suoha.* 2>/dev/null || true
}
trap cleanup_on_exit EXIT

# ---------- 变量与环境检测 ----------
TMPDIR="$(mktemp -d -t suoha.XXXX)"
ARGO_LOG="$TMPDIR/argo.log"
ARCH="$(uname -m)"
OS_ID=""
if [ -f /etc/os-release ]; then
  # prefer ID (debian/ubuntu/centos/fedora/alpine/etc.)
  . /etc/os-release
  OS_ID="${ID,,}"
fi

# 简单包管理器映射
pkg_update=""
pkg_install=""
case "$OS_ID" in
  debian|ubuntu)
    pkg_update="apt update -y || apt update"
    pkg_install="apt -y install"
    ;;
  centos|rhel|rocky|almalinux)
    pkg_update="yum -y update || dnf -y update"
    pkg_install="yum -y install || dnf -y install"
    ;;
  fedora)
    pkg_update="dnf -y update"
    pkg_install="dnf -y install"
    ;;
  alpine)
    pkg_update="apk update"
    pkg_install="apk add -f"
    ;;
  *)
    # 未识别系统，默认尝试 apt
    pkg_update="apt update -y || apt update"
    pkg_install="apt -y install"
    ;;
esac

# ---------- Helper: check command ----------
ensure_cmd() {
  local cmd="$1" pkgname="${2:-$1}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "检测到缺少命令: $cmd，尝试安装 ($pkgname)"
    if [ -z "$pkg_install" ]; then
      err "无法确定包管理器，请手动安装: $pkgname"
      return 1
    fi
    eval "$pkg_update"
    if ! eval "$pkg_install $pkgname"; then
      err "安装 $pkgname 失败，请手动安装后重试"
      return 1
    fi
  fi
  return 0
}

# ---------- Helper: choose free port ----------
choose_free_port() {
  local p
  # 选随机端口 10000-20000，最多尝试 100 次
  for _ in $(seq 1 100); do
    p=$((RANDOM % 10000 + 10000))
    # 使用 ss 或 netstat 检测
    if command -v ss >/dev/null 2>&1; then
      if ! ss -ltn | awk '{print $4}' | grep -q ":$p$"; then
        printf '%s' "$p"
        return 0
      fi
    elif command -v netstat >/dev/null 2>&1; then
      if ! netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then
        printf '%s' "$p"
        return 0
      fi
    else
      # 最后一招：尝试绑定端口（临时）
      (exec 3<>"/dev/tcp/127.0.0.1/$p") >/dev/null 2>&1 || { printf '%s' "$p"; return 0; }
    fi
  done
  err "未能在指定范围内找到可用端口"
  return 1
}

# ---------- Helper: download with checks ----------
dl() {
  local url="$1" out="$2"
  if ! curl -fsSL "$url" -o "$out"; then
    err "下载失败: $url"
    return 1
  fi
}

# ---------- quick tunnel (梭哈模式) ----------
quicktunnel() {
  # 准备
  rm -rf "$TMPDIR"/xray "$TMPDIR"/cloudflared* || true
  mkdir -p "$TMPDIR/xray"

  # 下载 xray & cloudflared：根据架构选择
  case "$ARCH" in
    x86_64|x64|amd64) dl "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" "$TMPDIR/xray.zip"; dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" "$TMPDIR/cloudflared";;
    i386|i686) dl "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip" "$TMPDIR/xray.zip"; dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386" "$TMPDIR/cloudflared";;
    armv8|aarch64|arm64) dl "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip" "$TMPDIR/xray.zip"; dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" "$TMPDIR/cloudflared";;
    armv7l|armv7) dl "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip" "$TMPDIR/xray.zip"; dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" "$TMPDIR/cloudflared";;
    *)
      err "当前架构 $ARCH 未适配"
      return 1
      ;;
  esac

  unzip -q "$TMPDIR/xray.zip" -d "$TMPDIR/xray"
  chmod +x "$TMPDIR/cloudflared" "$TMPDIR/xray/xray"

  uuid="$(cat /proc/sys/kernel/random/uuid)"
  urlpath="${uuid%%-*}"
  port="$(choose_free_port)"

  # 生成 config.json（vmess/vless 二选一）
  if [ "$protocol" = "1" ]; then
    cat >"$TMPDIR/xray/config.json" <<-EOF
{
  "inbounds":[
    {
      "port":$port,
      "listen":"127.0.0.1",
      "protocol":"vmess",
      "settings":{"clients":[{"id":"$uuid","alterId":0}]},
      "streamSettings":{"network":"ws","wsSettings":{"path":"$urlpath"}}
    }
  ],
  "outbounds":[{"protocol":"freedom","settings":{}}]
}
EOF
  else
    cat >"$TMPDIR/xray/config.json" <<-EOF
{
  "inbounds":[
    {
      "port":$port,
      "listen":"127.0.0.1",
      "protocol":"vless",
      "settings":{"decryption":"none","clients":[{"id":"$uuid"}]},
      "streamSettings":{"network":"ws","wsSettings":{"path":"$urlpath"}}
    }
  ],
  "outbounds":[{"protocol":"freedom","settings":{}}]
}
EOF
  fi

  # 启动 xray
  "$TMPDIR/xray/xray" run -c "$TMPDIR/xray/config.json" >/dev/null 2>&1 &
  XRAY_PID=$!

  # 启动 cloudflared quick tunnel
  "$TMPDIR/cloudflared" tunnel --url "http://127.0.0.1:$port" --no-autoupdate --edge-ip-version "$ips" --protocol http2 >"$ARGO_LOG" 2>&1 &
  CF_PID=$!

  # 等待 cloudflared 输出 trycloudflare 地址（最多等待 60 秒）
  local tries=0 argo_url=""
  while [ $tries -lt 60 ]; do
    if grep -qi 'trycloudflare' "$ARGO_LOG"; then
      # 尝试提取第一个 trycloudflare 的完整 URL 或 host
      argo_url="$(grep -Eo 'https?://[^ \"'\''<>[:space:]]*trycloudflare[^ \"'\''<>[:space:]]*' "$ARGO_LOG" | head -n1 || true)"
      # 若未包含协议，尝试抓取 host 字段
      if [ -z "$argo_url" ]; then
        argo_url="$(grep -Eo '[A-Za-z0-9.-]+trycloudflare.com' "$ARGO_LOG" | head -n1 || true)"
        [ -n "$argo_url" ] && argo_url="https://$argo_url"
      fi
    fi
    if [ -n "$argo_url" ]; then
      break
    fi
    sleep 1
    tries=$((tries+1))
  done

  if [ -z "$argo_url" ]; then
    err "未能获取 trycloudflare 地址（cloudflared 可能超时）"
    # 尝试将 log 打印出来供诊断
    err "cloudflared 日志片段："
    tail -n 40 "$ARGO_LOG" || true
    kill "$XRAY_PID" "$CF_PID" >/dev/null 2>&1 || true
    return 1
  fi

  # 输出 v2ray 连接信息
  v2file="/root/v2ray.txt"
  : >"$v2file"

  # host_in_config 用作客户端 Host（脚本原逻辑用 www.visa.com.sg）
  host_in_config="${argo_url#https://}"
  host_in_config="${host_in_config%%/*}"

  if [ "$protocol" = "1" ]; then
    # vmess base64
    json1=$(printf '{"add":"www.visa.com.sg","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s","port":"443","ps":"%s_tls","tls":"tls","type":"none","v":"2"}' "$host_in_config" "$uuid" "$urlpath" "${isp:-unknown}")
    json2=$(printf '{"add":"www.visa.com.sg","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s","port":"80","ps":"%s","tls":"","type":"none","v":"2"}' "$host_in_config" "$uuid" "$urlpath" "${isp:-unknown}")
    echo "vmess://"$(printf "%s" "$json1" | base64 -w 0) > "$v2file"
    echo >> "$v2file"
    echo "端口 443 可改为 2053 2083 2087 2096 8443" >> "$v2file"
    echo >> "$v2file"
    echo "vmess://"$(printf "%s" "$json2" | base64 -w 0) >> "$v2file"
    echo >> "$v2file"
    echo "端口 80 可改为 8080 8880 2052 2082 2086 2095" >> "$v2file"
  else
    # vless
    echo "vless://$uuid@www.visa.com.sg:443?encryption=none&security=tls&type=ws&host=$host_in_config&path=$urlpath#$isp_tls" > "$v2file"
    echo >> "$v2file"
    echo "端口 443 可改为 2053 2083 2087 2096 8443" >> "$v2file"
    echo >> "$v2file"
    echo "vless://$uuid@www.visa.com.sg:80?encryption=none&security=none&type=ws&host=$host_in_config&path=$urlpath" >> "$v2file"
    echo >> "$v2file"
    echo "端口 80 可改为 8080 8880 2052 2082 2086 2095" >> "$v2file"
  fi

  log ""
  log "生成完成 — Cloudflare 地址: $argo_url"
  log "配置已保存到: $v2file"
  log "（梭哈模式重启后失效）"

  # 打印 v2ray 内容到屏幕
  cat "$v2file"
}

# ---------- installtunnel（永久安装模式） ----------
installtunnel() {
  mkdir -p /opt/suoha || true
  rm -rf "$TMPDIR"/xray "$TMPDIR"/cloudflared* || true

  # 下载二进制（同 quicktunnel）
  case "$ARCH" in
    x86_64|x64|amd64) dl "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" "$TMPDIR/xray.zip"; dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" "$TMPDIR/cloudflared";;
    i386|i686) dl "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip" "$TMPDIR/xray.zip"; dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386" "$TMPDIR/cloudflared";;
    armv8|aarch64|arm64) dl "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip" "$TMPDIR/xray.zip"; dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" "$TMPDIR/cloudflared";;
    armv7l|armv7) dl "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip" "$TMPDIR/xray.zip"; dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" "$TMPDIR/cloudflared";;
    *)
      err "当前架构 $ARCH 未适配"
      return 1
      ;;
  esac

  unzip -q "$TMPDIR/xray.zip" -d "$TMPDIR/xray"
  chmod +x "$TMPDIR/cloudflared" "$TMPDIR/xray/xray"
  mv "$TMPDIR/cloudflared" /opt/suoha/cloudflared-linux
  mv "$TMPDIR/xray/xray" /opt/suoha/xray

  uuid="$(cat /proc/sys/kernel/random/uuid)"
  urlpath="${uuid%%-*}"
  port="$(choose_free_port)"

  # 生成 /opt/suoha/config.json
  if [ "$protocol" = "1" ]; then
    cat >/opt/suoha/config.json <<-EOF
{
  "inbounds":[
    {
      "port":$port,
      "listen":"127.0.0.1",
      "protocol":"vmess",
      "settings":{"clients":[{"id":"$uuid","alterId":0}]},
      "streamSettings":{"network":"ws","wsSettings":{"path":"$urlpath"}}
    }
  ],
  "outbounds":[{"protocol":"freedom","settings":{}}]
}
EOF
  else
    cat >/opt/suoha/config.json <<-EOF
{
  "inbounds":[
    {
      "port":$port,
      "listen":"127.0.0.1",
      "protocol":"vless",
      "settings":{"decryption":"none","clients":[{"id":"$uuid"}]},
      "streamSettings":{"network":"ws","wsSettings":{"path":"$urlpath"}}
    }
  ],
  "outbounds":[{"protocol":"freedom","settings":{}}]
}
EOF
  fi

  # 引导用户登录 cloudflared（会打开网页授权）
  log "请复制下面命令到浏览器窗口并完成 Cloudflare 授权（会跳转生成 JSON 凭证）:"
  log "/opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel login"
  read -p "按回车继续（完成授权后）"

  # 列出 tunnel
  /opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel list >"$ARGO_LOG" 2>&1 || true
  log "当前已绑定的 TUNNEL："
  sed -n '3,999p' "$ARGO_LOG" | awk '{print $2}' || true

  read -rp "输入你要绑定的完整二级域名 (例如 sub.example.com): " domain
  if [ -z "$domain" ] || ! echo "$domain" | grep -q '\.'; then
    err "域名格式不正确或为空，退出"
    return 1
  fi

  name="${domain%%.*}"

  # 如果 tunnel 不存在则创建
  if ! sed -n '3,999p' "$ARGO_LOG" | awk '{print $2}' | grep -qw "$name"; then
    /opt/suoha/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel create "$name" >"$ARGO_LOG" 2>&1
    log "TUNNEL $name 创建完成"
  else
    log "TUNNEL $name 已存在，尝试清理并重建证书（若需要）"
    # 若凭证文件不存在则 cleanup + create
    id_line=$(sed -n '3,999p' "$ARGO_LOG" | grep -w "$name" | awk '{print $1}' | head -n1 || true)
    if [ -n "$id_line" ] && [ ! -f "/root/.cloudflared/${id_line}.json" ]; then
      /opt/suoha/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel cleanup "$name" >"$ARGO_LOG" 2>&1 || true
      /opt/suoha/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel delete "$name" >"$ARGO_LOG" 2>&1 || true
      /opt/suoha/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel create "$name" >"$ARGO_LOG" 2>&1 || true
    fi
  fi

  # 绑定 DNS
  /opt/suoha/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel route dns --overwrite-dns "$name" "$domain" >"$ARGO_LOG" 2>&1
  # 从 argo.log 中试图提取 tunnel uuid
  tunneluuid="$(grep -Eo 'tunnel[[:space:]]+[0-9a-fA-F-]+' "$ARGO_LOG" | awk '{print $2}' || true)"
  if [ -z "$tunneluuid" ]; then
    # fallback: try to parse "Created tunnel ... (id: ...)"
    tunneluuid="$(grep -Eo '[0-9a-fA-F-]{36}' "$ARGO_LOG" | head -n1 || true)"
  fi

  # 生成 v2ray 文本并写入 /opt/suoha/v2ray.txt
  v2file="/opt/suoha/v2ray.txt"
  : >"$v2file"
  host_in_config="$domain"

  if [ "$protocol" = "1" ]; then
    json1=$(printf '{"add":"www.visa.com.sg","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s","port":"443","ps":"%s_tls","tls":"tls","type":"none","v":"2"}' "$host_in_config" "$uuid" "$urlpath" "${isp:-unknown}")
    json2=$(printf '{"add":"www.visa.com.sg","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s","port":"80","ps":"%s","tls":"","type":"none","v":"2"}' "$host_in_config" "$uuid" "$urlpath" "${isp:-unknown}")
    echo "vmess://"$(printf "%s" "$json1" | base64 -w 0) > "$v2file"
    echo >> "$v2file"
    echo "vmess://"$(printf "%s" "$json2" | base64 -w 0) >> "$v2file"
  else
    echo "vless://$uuid@www.visa.com.sg:443?encryption=none&security=tls&type=ws&host=$host_in_config&path=$urlpath#$isp_tls" > "$v2file"
    echo >> "$v2file"
    echo "vless://$uuid@www.visa.com.sg:80?encryption=none&security=none&type=ws&host=$host_in_config&path=$urlpath" >> "$v2file"
  fi

  # 生成 cloudflared config.yaml
  cat >/opt/suoha/config.yaml <<-EOF
tunnel: $tunneluuid
credentials-file: /root/.cloudflared/$tunneluuid.json

ingress:
  - hostname: $domain
    service: http://127.0.0.1:$port
EOF

  # systemd 服务文件（放 /etc/systemd/system 更标准）
  if [ "$OS_ID" = "alpine" ]; then
    # init.d / local.d
    cat >/etc/local.d/cloudflared.start <<-EOF
/opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel --config /opt/suoha/config.yaml run $name &
EOF
    cat >/etc/local.d/xray.start <<-EOF
/opt/suoha/xray run -c /opt/suoha/config.json &
EOF
    chmod +x /etc/local.d/cloudflared.start /etc/local.d/xray.start
    rc-update add local
    /etc/local.d/cloudflared.start >/dev/null 2>&1 || true
    /etc/local.d/xray.start >/dev/null 2>&1 || true
  else
    cat >/etc/systemd/system/cloudflared.service <<-EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel --config /opt/suoha/config.yaml run $name
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    cat >/etc/systemd/system/xray.service <<-EOF
[Unit]
Description=Xray
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/opt/suoha/xray run -c /opt/suoha/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || true
    systemctl enable cloudflared.service || true
    systemctl enable xray.service || true
    systemctl start cloudflared.service || true
    systemctl start xray.service || true
  fi

  chmod +x /opt/suoha/suoha.sh 2>/dev/null || true
  ln -sf /opt/suoha/suoha.sh /usr/bin/suoha || true

  log "安装完成，v2ray 信息保存在：/opt/suoha/v2ray.txt"
  cat /opt/suoha/v2ray.txt
}

# ---------- 主菜单与入口 ----------
# 预先确保常用命令存在（curl unzip base64 grep awk）
ensure_cmd curl curl || true
ensure_cmd unzip unzip || true
ensure_cmd awk awk || true
ensure_cmd grep grep || true
ensure_cmd base64 base64 || true
ensure_cmd ss iproute2 || true || true || true

clear
# \033[1;36m 是亮青色， \033[0m 是重置颜色
echo -e "\033[1;36m"
cat <<'EOF'
      _         _
     | |       | |
    _| |__    _| |__
   |_   __|  |_   __|
     | |_      | |_
      \__|      \__|
EOF

echo
echo "欢迎使用 tt 一键梭哈 (优化版)"
echo "1) 梭哈模式 (Quick Tunnel, 临时隧道, 无需域名但重启后失效)"
echo "2) 安装服务 (固定隧道, 需 Cloudflare 托管的域名授权)"
echo "3) 卸载服务 (若需彻底删除CF授权记录,稍后请按提示手动执行)"
echo "4) 清空缓存 (删除临时下载文件)"
echo "5) 管理服务 (需先安装)"
echo "0) 退出"
echo

read -rp "请选择模式(默认1): " mode
mode="${mode:-1}"

case "$mode" in
  1)
    read -rp "请选择 xray 协议(1=vmess,2=vless, 默认1): " protocol
    protocol="${protocol:-1}"
    if [ "$protocol" != "1" ] && [ "$protocol" != "2" ]; then err "协议选择不正确"; exit 1; fi
    read -rp "请选择 argo 连接模式 (4/6, 默认4): " ips
    ips="${ips:-4}"
    if [ "$ips" != "4" ] && [ "$ips" != "6" ]; then err "IP 选择错误"; exit 1; fi
    # 探测 ISP info (保留脚本原用法，但失败不致命)
    if command -v curl >/dev/null 2>&1; then
      isp="$(curl -$ips -s https://speed.cloudflare.com/meta | awk -F\" '{print $26\"-\"$18\"-\"$30}' 2>/dev/null || true)"
      isp="${isp// /_}"
    fi
    quicktunnel
    ;;
  2)
    read -rp "请选择 xray 协议(1=vmess,2=vless, 默认1): " protocol
    protocol="${protocol:-1}"
    if [ "$protocol" != "1" ] && [ "$protocol" != "2" ]; then err "协议选择不正确"; exit 1; fi
    read -rp "请选择 argo 连接模式 (4/6, 默认4): " ips
    ips="${ips:-4}"
    if [ "$ips" != "4" ] && [ "$ips" != "6" ]; then err "IP 选择错误"; exit 1; fi
    if command -v curl >/dev/null 2>&1; then
      isp="$(curl -$ips -s https://speed.cloudflare.com/meta | awk -F\" '{print $26\"-\"$18\"-\"$30}' 2>/dev/null || true)"
      isp="${isp// /_}"
    fi
    installtunnel
    ;;
  3)
    if [ "$OS_ID" = "alpine" ]; then
      killall xray 2>/dev/null || true
      killall cloudflared-linux 2>/dev/null || true
      rm -rf /opt/suoha /etc/local.d/cloudflared.start /etc/local.d/xray.start /usr/bin/suoha ~/.cloudflared || true
      rc-update del local 2>/dev/null || true
    else
      systemctl stop cloudflared.service xray.service 2>/dev/null || true
      systemctl disable cloudflared.service xray.service 2>/dev/null || true
      pkill -f xray 2>/dev/null || true
      pkill -f cloudflared-linux 2>/dev/null || true
      rm -rf /opt/suoha /etc/systemd/system/cloudflared.service /etc/systemd/system/xray.service /usr/bin/suoha ~/.cloudflared || true
      systemctl daemon-reload 2>/dev/null || true
    fi
    log "卸载完成。如需彻底删除 Cloudflare 授权，请访问 https://dash.cloudflare.com/profile/api-tokens 删除对应 token。"
    ;;
  5)
    if [ -f /usr/bin/suoha ]; then
      /usr/bin/suoha
    else
      err "管理服务未安装，请先选择模式2安装"
    fi
    ;;
  4)
    rm -rf /tmp/suoha.* "$TMPDIR" xray cloudflared-linux v2ray.txt 2>/dev/null || true
    log "缓存已清理"
    ;;
  0)
    log "退出"
    ;;
  *)
    err "未知选项"
    ;;
esac

exit 0
