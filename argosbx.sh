#!/bin/sh
export LANG=en_US.UTF-8

# === 0. 强制检查变量 ===
if [ -z "$ARGO_AUTH" ] || [ -z "$ARGO_DOMAIN" ]; then
    echo "❌ 错误：必须提供 ARGO_AUTH (Token) 和 ARGO_DOMAIN (域名)！"
    echo "请先 export 这两个变量再运行脚本。"
    exit 1
fi

# 1. 变量初始化
export uuid=${uuid:-''}
export port_vm_ws=${vmpt:-10086} # 默认端口 10086
export name=${name:-'FixedArgo'}
v46url="https://icanhazip.com"

# 2. 环境准备
hostname=$(uname -a | awk '{print $2}')
case $(uname -m) in
aarch64) cpu=arm64;;
x86_64) cpu=amd64;;
*) echo "不支持当前架构" && exit
esac
mkdir -p "$HOME/agsbx"
mkdir -p "$HOME/bin"

# 生成 UUID
if [ -z "$uuid" ] && [ ! -e "$HOME/agsbx/uuid" ]; then
    uuid=$(cat /proc/sys/kernel/random/uuid)
    echo "$uuid" > "$HOME/agsbx/uuid"
elif [ -n "$uuid" ]; then
    echo "$uuid" > "$HOME/agsbx/uuid"
fi
uuid=$(cat "$HOME/agsbx/uuid")

# 3. 安装 Xray (VMess核心)
installxray(){
    echo "1. 安装 Xray 内核..."
    if [ ! -e "$HOME/agsbx/xray" ]; then
        url="https://github.com/ka234ka/go-sbx/releases/download/argosbx/xray-$cpu"
        out="$HOME/agsbx/xray"
        (command -v curl >/dev/null 2>&1 && curl -Lo "$out" -# --retry 2 "$url") || (command -v wget>/dev/null 2>&1 && timeout 3 wget -O "$out" --tries=2 "$url")
        chmod +x "$HOME/agsbx/xray"
    fi

    # 配置 VMess (监听在 localhost 或 0.0.0.0 供 Tunnel 连接)
    echo "2. 配置 VMess (端口: $port_vm_ws)..."
    cat > "$HOME/agsbx/xr.json" <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
        "tag": "vmess-xr",
        "listen": "0.0.0.0",
        "port": ${port_vm_ws},
        "protocol": "vmess",
        "settings": {
            "clients": [ { "id": "${uuid}" } ]
        },
        "streamSettings": {
            "network": "ws",
            "wsSettings": { "path": "/${uuid}-vm" }
        }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF
}

# 4. 安装 Cloudflared (强制)
install_argo(){
    echo "3. 安装 Cloudflared 隧道..."
    if [ ! -e "$HOME/agsbx/cloudflared" ]; then
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu"
        out="$HOME/agsbx/cloudflared"
        (command -v curl>/dev/null 2>&1 && curl -Lo "$out" -# --retry 2 "$url") || (command -v wget>/dev/null 2>&1 && timeout 3 wget -O "$out" --tries=2 "$url")
        chmod +x "$HOME/agsbx/cloudflared"
    fi
    
    # 记录域名供后续使用
    echo "$ARGO_DOMAIN" > "$HOME/agsbx/argodomain.log"
}

# 5. 配置系统服务与自启
setup_services(){
    echo "4. 配置系统服务 (Systemd/OpenRC)..."
    
    # Systemd (Debian/Ubuntu/CentOS)
    if pidof systemd >/dev/null 2>&1; then
        # Xray
        cat > /etc/systemd/system/xr.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=$HOME/agsbx/xray run -c $HOME/agsbx/xr.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        # Cloudflared (使用 run --token)
        cat > /etc/systemd/system/argo.service <<EOF
[Unit]
Description=Argo Tunnel
After=network.target
[Service]
ExecStart=$HOME/agsbx/cloudflared tunnel --no-autoupdate run --token ${ARGO_AUTH}
Restart=always
RestartSec=10s
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xr argo
        systemctl restart xr argo
        
    # OpenRC (Alpine)
    elif command -v rc-service >/dev/null 2>&1; then
        # Xray
        cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
command="$HOME/agsbx/xray"
command_args="run -c $HOME/agsbx/xr.json"
command_background=yes
pidfile="/run/xray.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/xray
        rc-update add xray default
        rc-service xray restart

        # Cloudflared
        cat > /etc/init.d/argo <<EOF
#!/sbin/openrc-run
command="$HOME/agsbx/cloudflared"
command_args="tunnel --no-autoupdate run --token ${ARGO_AUTH}"
command_background=yes
pidfile="/run/argo.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/argo
        rc-update add argo default
        rc-service argo restart
    else
        # Nohup fallback
        pkill -f "$HOME/agsbx/xray"
        pkill -f "$HOME/agsbx/cloudflared"
        nohup "$HOME/agsbx/xray" run -c "$HOME/agsbx/xr.json" >/dev/null 2>&1 &
        nohup "$HOME/agsbx/cloudflared" tunnel --no-autoupdate run --token "${ARGO_AUTH}" >/dev/null 2>&1 &
    fi
}

# 6. 看门狗 (Watchdog) - Crontab
install_watchdog(){
    echo "5. 配置看门狗 (Watchdog)..."
    crontab -l > /tmp/cron.bak 2>/dev/null
    sed -i '/agsbx/d' /tmp/cron.bak # 清理旧的
    
    # 写入检查逻辑 (每分钟)
    if pidof systemd >/dev/null 2>&1; then
        echo "*/1 * * * * systemctl is-active --quiet xr || systemctl start xr" >> /tmp/cron.bak
        echo "*/1 * * * * systemctl is-active --quiet argo || systemctl start argo" >> /tmp/cron.bak
    elif command -v rc-service >/dev/null 2>&1; then
        echo "*/1 * * * * rc-service xray status >/dev/null || rc-service xray start" >> /tmp/cron.bak
        echo "*/1 * * * * rc-service argo status >/dev/null || rc-service argo start" >> /tmp/cron.bak
    else
        echo "*/1 * * * * pgrep -f 'agsbx/xray' >/dev/null || nohup $HOME/agsbx/xray run -c $HOME/agsbx/xr.json >/dev/null 2>&1 &" >> /tmp/cron.bak
        echo "*/1 * * * * pgrep -f 'cloudflared' >/dev/null || nohup $HOME/agsbx/cloudflared tunnel --no-autoupdate run --token ${ARGO_AUTH} >/dev/null 2>&1 &" >> /tmp/cron.bak
    fi
    
    crontab /tmp/cron.bak
    rm /tmp/cron.bak
}

# 7. 卸载与快捷命令
persist_env(){
    SCRIPT_PATH="$HOME/bin/agsbx"
    cat > "$SCRIPT_PATH" <<EOF
#!/bin/sh
if [ "\$1" = "list" ]; then cat "$HOME/agsbx/jh.txt"; fi
if [ "\$1" = "del" ]; then 
  systemctl stop xr argo 2>/dev/null
  rc-service xray stop 2>/dev/null
  rc-service argo stop 2>/dev/null
  rm -rf "$HOME/agsbx" /etc/systemd/system/xr.service /etc/systemd/system/argo.service
  crontab -l | grep -v 'agsbx' | crontab -
  echo "卸载完成"
fi
EOF
    chmod +x "$SCRIPT_PATH"
    if ! grep -q "$HOME/bin" "$HOME/.bashrc"; then
        echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
    fi
}

# 8. 输出链接
print_links(){
    sleep 2 # 等待服务启动
    rm -f "$HOME/agsbx/jh.txt"
    
    echo "========================================================="
    echo "✅ 安装成功！(仅保留 Argo 固定隧道)"
    echo "---------------------------------------------------------"
    echo "UUID: $uuid"
    echo "本地端口: $port_vm_ws"
    echo "绑定域名: $ARGO_DOMAIN"
    echo "---------------------------------------------------------"
    echo "⚠️ 重要提示：请确保你在 CF Zero Trust 后台已配置："
    echo "Public Hostname -> Service: HTTP://localhost:$port_vm_ws"
    echo "---------------------------------------------------------"

    # 生成 VMess Argo 链接
    # 注意：Host 和 SNI 必须是你的固定域名，Address 可以是域名本身也可以是优选IP
    # 这里为了稳妥，Address 写为固定域名，端口 443，开启 TLS
    
    # 优选 IP 版 (Host混淆)
    vma_cdn_link="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${name}-Argo-CDN\", \"add\": \"www.visa.com.sg\", \"port\": \"443\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN\", \"path\": \"/${uuid}-vm\", \"tls\": \"tls\", \"sni\": \"$ARGO_DOMAIN\"}" | base64 -w0)"
    
    # 纯域名版
    vma_domain_link="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${name}-Argo-Domain\", \"add\": \"$ARGO_DOMAIN\", \"port\": \"443\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN\", \"path\": \"/${uuid}-vm\", \"tls\": \"tls\", \"sni\": \"$ARGO_DOMAIN\"}" | base64 -w0)"

    echo "🔗 节点链接 1 (使用优选IP+域名混淆):"
    echo "$vma_cdn_link"
    echo "$vma_cdn_link" >> "$HOME/agsbx/jh.txt"
    echo
    echo "🔗 节点链接 2 (纯域名连接):"
    echo "$vma_domain_link"
    echo "$vma_domain_link" >> "$HOME/agsbx/jh.txt"
    echo "========================================================="
}

# === 执行入口 ===
if [ "$1" = "del" ]; then
    systemctl stop xr argo >/dev/null 2>&1
    rc-service xray stop 2>/dev/null
    rc-service argo stop 2>/dev/null
    rm -rf "$HOME/agsbx" /etc/systemd/system/xr.service /etc/systemd/system/argo.service
    crontab -l | grep -v 'agsbx' | crontab -
    echo "已卸载。"
    exit
fi

echo "🚀 开始安装 (固定隧道版)..."
setenforce 0 >/dev/null 2>&1
iptables -F >/dev/null 2>&1 # 放行端口
installxray
install_argo
setup_services
install_watchdog
persist_env
print_links
