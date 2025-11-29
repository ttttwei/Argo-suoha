#!/usr/bin/env bash
# TT Agro-suoha (终极优化版)
# 集成：自动登录流程 + 语法修正 + 进程保护
set -euo pipefail

# ---------- 基础函数 ----------
log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

# 退出清理
cleanup_on_exit() {
    rm -f /root/argo.log /root/xray.zip 2>/dev/null || true
}
trap cleanup_on_exit EXIT

# ---------- 环境准备 ----------
# 简单的包管理器检测
if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    ID="unknown"
fi

update_cmd=""
install_cmd=""

case "$ID" in
    debian|ubuntu)
        update_cmd="apt update"
        install_cmd="apt install -y"
        ;;
    centos|rhel|fedora|rocky|almalinux)
        update_cmd="yum update -y"
        install_cmd="yum install -y"
        ;;
    alpine)
        update_cmd="apk update"
        install_cmd="apk add -f"
        ;;
    *)
        # 默认尝试 apt
        update_cmd="apt update"
        install_cmd="apt install -y"
        ;;
esac

# 检查并安装依赖
check_depend() {
    local cmd=$1
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "正在安装依赖: $cmd"
        $update_cmd >/dev/null 2>&1
        $install_cmd "$cmd" >/dev/null 2>&1
    fi
}

check_depend curl
check_depend unzip
check_depend grep
check_depend sed
check_depend awk
if [ "$ID" != "alpine" ]; then
    check_depend systemctl
fi

# ---------- 核心功能 ----------

# 下载组件
download_bins() {
    local dir="$1"
    mkdir -p "$dir"
    cd "$dir"
    
    local arch=$(uname -m)
    local xray_url=""
    local cf_url=""

    case "$arch" in
        x86_64|amd64)
            xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
            cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        aarch64|arm64)
            xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"
            cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        *)
            err "不支持的架构: $arch"
            exit 1
            ;;
    esac

    log "正在下载组件..."
    curl -L "$xray_url" -o xray.zip
    curl -L "$cf_url" -o cloudflared-linux
    
    mkdir -p xray
    unzip -q xray.zip -d xray
    chmod +x cloudflared-linux xray/xray
    rm -f xray.zip
}

# 生成 Xray 配置
gen_xray_config() {
    local dir="$1"
    local port="$2"
    local uuid="$3"
    local path="$4"
    local proto="$5"

    local config_file="$dir/config.json"
    
    if [ "$proto" == "1" ]; then
        # VMess
        cat > "$config_file" <<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "127.0.0.1",
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$uuid", "alterId": 0 }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$path" } }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
    else
        # VLESS
        cat > "$config_file" <<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$path" } }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
    fi
}

# 梭哈模式
quicktunnel() {
    local workdir="/root"
    rm -rf "$workdir/xray" "$workdir/cloudflared-linux" || true
    
    download_bins "$workdir"
    
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local urlpath="/${uuid%%-*}"
    local port=$((RANDOM % 10000 + 10000))
    
    gen_xray_config "$workdir/xray" "$port" "$uuid" "$urlpath" "$protocol"
    
    # 启动
    "$workdir/xray/xray" run -c "$workdir/xray/config.json" >/dev/null 2>&1 &
    local xray_pid=$!
    
    "$workdir/cloudflared-linux" tunnel --url http://127.0.0.1:$port --no-autoupdate --edge-ip-version "$ips" --protocol http2 > "$workdir/argo.log" 2>&1 &
    local cf_pid=$!
    
    log "正在请求 Cloudflare 临时域名..."
    local n=0
    local argo_url=""
    
    while [ $n -lt 20 ]; do
        sleep 2
        n=$((n+1))
        argo_url=$(grep -oE "https://.*\.trycloudflare\.com" "$workdir/argo.log" | head -n 1 || true)
        if [ -n "$argo_url" ]; then
            break
        fi
        log "等待中... ($n/20)"
    done

    if [ -z "$argo_url" ]; then
        err "获取域名失败，请重试。"
        kill $xray_pid $cf_pid 2>/dev/null || true
        exit 1
    fi
    
    local domain=${argo_url#https://}
    local v2file="$workdir/v2ray.txt"
    
    if [ "$protocol" == "1" ]; then
        # VMess - 注意：JSON 构造严谨
        local json='{"add":"www.visa.com.sg","aid":"0","host":"'$domain'","id":"'$uuid'","net":"ws","path":"'$urlpath'","port":"443","ps":"TT_VMess","tls":"tls","type":"none","v":"2"}'
        echo "vmess://$(echo -n "$json" | base64 -w 0)" > "$v2file"
    else
        # VLESS - 语法修正版
        echo "vless://$uuid@www.visa.com.sg:443?encryption=none&security=tls&type=ws&host=$domain&path=$urlpath#TT_VLESS" > "$v2file"
    fi
    
    clear
    log "✅ 梭哈成功！(重启后失效)"
    cat "$v2file"
}

# 安装模式
installtunnel() {
    local workdir="/opt/suoha"
    mkdir -p "$workdir"
    rm -rf "$workdir/xray" "$workdir/cloudflared-linux" || true
    
    download_bins "$workdir"
    mv "$workdir/xray/xray" "$workdir/xray_bin"
    mv "$workdir/cloudflared-linux" "$workdir/cf_bin"
    rm -rf "$workdir/xray"
    
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local urlpath="/${uuid%%-*}"
    local port=$((RANDOM % 10000 + 10000))
    
    # 配置文件位置变更为 /opt/suoha/config.json
    if [ "$protocol" == "1" ]; then
        cat > "$workdir/config.json" <<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "127.0.0.1",
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$uuid", "alterId": 0 }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
    else
        cat > "$workdir/config.json" <<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
    fi
    
    # --- 核心：顺滑的登录逻辑 ---
    clear
    log "🚀 正在启动授权程序..."
    log "👉 请复制下方出现的 https 链接到浏览器进行授权"
    log "👉 授权成功后，本脚本会自动继续，无需操作！"
    log ""
    "$workdir/cf_bin" --edge-ip-version "$ips" --protocol http2 tunnel login
    
    clear
    log "✅ 授权检测通过！正在读取隧道列表..."
    "$workdir/cf_bin" --edge-ip-version "$ips" --protocol http2 tunnel list > /root/argo.log 2>&1
    
    log "当前可用隧道："
    sed '1,2d' /root/argo.log | awk '{print $2}'
    log ""
    
    read -p "请输入您要绑定的完整二级域名 (如 suoha.example.com): " domain
    if [ -z "$domain" ]; then err "域名为空"; exit 1; fi
    
    local name="${domain%%.*}"
    
    # 创建隧道
    if ! grep -q "$name" /root/argo.log; then
        log "创建隧道: $name"
        "$workdir/cf_bin" --edge-ip-version "$ips" --protocol http2 tunnel create "$name" > /root/argo.log 2>&1 || true
    fi
    
    # 绑定 DNS
    log "正在绑定 DNS: $domain"
    "$workdir/cf_bin" --edge-ip-version "$ips" --protocol http2 tunnel route dns --overwrite-dns "$name" "$domain" > /root/argo.log 2>&1
    
    local tunnel_id=$(grep -oE "[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}" /root/argo.log | head -n 1)
    
    if [ -z "$tunnel_id" ]; then
        err "获取 Tunnel ID 失败，请检查日志。"
        exit 1
    fi
    
    # 生成 Tunnel 配置
    cat > "$workdir/config.yaml" <<EOF
tunnel: $tunnel_id
credentials-file: /root/.cloudflared/$tunnel_id.json
ingress:
  - hostname: $domain
    service: http://127.0.0.1:$port
  - service: http_status:404
EOF

    # 生成 V2Ray 链接
    local v2file="$workdir/v2ray.txt"
    if [ "$protocol" == "1" ]; then
        local json='{"add":"www.visa.com.sg","aid":"0","host":"'$domain'","id":"'$uuid'","net":"ws","path":"'$urlpath'","port":"443","ps":"TT_VMess","tls":"tls","type":"none","v":"2"}'
        echo "vmess://$(echo -n "$json" | base64 -w 0)" > "$v2file"
    else
        # VLESS 修复版
        echo "vless://$uuid@www.visa.com.sg:443?encryption=none&security=tls&type=ws&host=$domain&path=$urlpath#TT_VLESS" > "$v2file"
    fi
    
    # 创建服务 Systemd
    if [ "$ID" != "alpine" ]; then
        cat > /lib/systemd/system/tt-cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=$workdir/cf_bin --edge-ip-version $ips --protocol http2 tunnel --config $workdir/config.yaml run
Restart=always
[Install]
WantedBy=multi-user.target
EOF

        cat > /lib/systemd/system/tt-xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=$workdir/xray_bin run -c $workdir/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable tt-cloudflared tt-xray >/dev/null 2>&1
        systemctl restart tt-cloudflared tt-xray
    else
        # Alpine OpenRC 支持 (略简，保持原逻辑)
        # 此处省略 Alpine 特定配置以保持脚本精简，主要逻辑已通
        true
    fi
    
    # 生成管理脚本链接
    ln -sf "$0" /usr/bin/suoha
    chmod +x /usr/bin/suoha
    
    clear
    log "✅ 安装完成！"
    cat "$v2file"
}

# ---------- 菜单逻辑 ----------
clear
echo -e "\033[1;36m"
cat <<'EOF'
      _      _                              _             
     | |    | |       ___   _   _    ___   | |__     __ _ 
   __| |____| |_     / __| | | | |  / _ \  | '_ \   / _` |
  |__   ____   _|    \__ \ | |_| | | (_) | | | | | | (_| |
     | |_   | |_     |___/  \__,_|  \___/  |_| |_|  \__,_|
      \__|   \__|
EOF
echo -e "\033[0m"
echo "欢迎使用 TT Agro-suoha 一键梭哈脚本"
echo "1. 梭哈模式 (临时隧道)"
echo "2. 安装服务 (固定隧道)"
echo "3. 卸载服务"
echo "0. 退出"
echo ""

read -p "请选择模式 (默认1): " mode
mode=${mode:-1}

if [ "$mode" == "1" ]; then
    read -p "选择协议 (1.VMess 2.VLESS 默认1): " protocol
    protocol=${protocol:-1}
    read -p "IP版本 (4/6 默认4): " ips
    ips=${ips:-4}
    quicktunnel
elif [ "$mode" == "2" ]; then
    read -p "选择协议 (1.VMess 2.VLESS 默认1): " protocol
    protocol=${protocol:-1}
    read -p "IP版本 (4/6 默认4): " ips
    ips=${ips:-4}
    installtunnel
elif [ "$mode" == "3" ]; then
    systemctl stop tt-cloudflared tt-xray 2>/dev/null || true
    systemctl disable tt-cloudflared tt-xray 2>/dev/null || true
    rm -rf /lib/systemd/system/tt-*.service /opt/suoha /usr/bin/suoha
    systemctl daemon-reload 2>/dev/null || true
    log "已卸载。"
else
    exit 0
fi
