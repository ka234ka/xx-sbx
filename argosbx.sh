#!/bin/sh
export LANG=en_US.UTF-8

# 1. 变量初始化
[ -z "${vmpt+x}" ] || vmp=yes
[ -z "${warp+x}" ] || wap=yes
export uuid=${uuid:-''}
export port_vm_ws=${vmpt:-''}
export argo=${argo:-''}
export ARGO_DOMAIN=${ARGO_DOMAIN:-''}
export ARGO_AUTH=${ARGO_AUTH:-''}
export name=${name:-''}
v46url="https://icanhazip.com"

showmode(){
echo "Argosbx 精简版 (VMess + Argo + 看门狗保活)"
echo "显示链接：agsbx list"
echo "卸载脚本：agsbx del"
echo "---------------------------------------------------------"
}

# 2. 环境准备
hostname=$(uname -a | awk '{print $2}')
case $(uname -m) in
aarch64) cpu=arm64;;
x86_64) cpu=amd64;;
*) echo "不支持当前架构" && exit
esac
mkdir -p "$HOME/agsbx"

# WARP 检测
v4v6(){
v4=$( (command -v curl >/dev/null 2>&1 && curl -s4m5 -k "$v46url" 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -4 --tries=2 -qO- "$v46url" 2>/dev/null) )
v6=$( (command -v curl >/dev/null 2>&1 && curl -s6m5 -k "$v46url" 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -6 --tries=2 -qO- "$v46url" 2>/dev/null) )
}

warpsx(){
if [ -n "$name" ]; then echo "$name-" > "$HOME/agsbx/name"; fi
v4v6
if echo "$v6" | grep -q '^2a09' || echo "$v4" | grep -q '^104.28'; then
    s1outtag=direct; x1outtag=direct; x2outtag=direct; xip='"::/0", "0.0.0.0/0"'; wap=warpargo
    echo "系统已有WARP，使用直连模式。"
else
    if [ "$wap" != yes ]; then
        s1outtag=direct; x1outtag=direct; x2outtag=direct; xip='"::/0", "0.0.0.0/0"'; wap=warpargo
    else
        case "$warp" in
        ""|sx|xs) x1outtag=warp-out; x2outtag=warp-out; xip='"::/0", "0.0.0.0/0"'; wap=warp ;;
        s ) x1outtag=direct; x2outtag=direct; xip='"::/0", "0.0.0.0/0"'; wap=warp ;;
        x ) x1outtag=warp-out; x2outtag=warp-out; xip='"::/0", "0.0.0.0/0"'; wap=warp ;;
        * ) x1outtag=direct; x2outtag=direct; xip='"::/0", "0.0.0.0/0"'; wap=warpargo ;;
        esac
    fi
fi
case "$warp" in *x4*) wxryx='ForceIPv4' ;; *x6*) wxryx='ForceIPv6' ;; *) wxryx='ForceIPv4v6' ;; esac
if (command -v curl >/dev/null 2>&1 && curl -s6m5 -k "$v46url" >/dev/null 2>&1); then
    xryx='ForceIPv6v4'; xendip="[2606:4700:d0::a29f:c001]"; xsdns="[2001:4860:4860::8888]"
else
    case "$warp" in *x4*) xryx='ForceIPv4' ;; esac
    [ -z "$xryx" ] && xryx='ForceIPv4v6'
    xendip="162.159.192.1"; xsdns="8.8.8.8"
fi
}

insuuid(){
if [ -z "$uuid" ] && [ ! -e "$HOME/agsbx/uuid" ]; then
    uuid=$(cat /proc/sys/kernel/random/uuid)
    echo "$uuid" > "$HOME/agsbx/uuid"
elif [ -n "$uuid" ]; then
    echo "$uuid" > "$HOME/agsbx/uuid"
fi
uuid=$(cat "$HOME/agsbx/uuid")
}

# 3. 安装 Xray
installxray(){
echo "=========启用 Xray 内核 (VMess)========="
mkdir -p "$HOME/agsbx/xrk"
if [ ! -e "$HOME/agsbx/xray" ]; then
    url="https://github.com/ka234ka/go-sbx/releases/download/argosbx/xray-$cpu"
    out="$HOME/agsbx/xray"
    (command -v curl >/dev/null 2>&1 && curl -Lo "$out" -# --retry 2 "$url") || (command -v wget>/dev/null 2>&1 && timeout 3 wget -O "$out" --tries=2 "$url")
    chmod +x "$HOME/agsbx/xray"
fi
cat > "$HOME/agsbx/xr.json" <<EOF
{
  "log": { "loglevel": "none" },
  "dns": { "servers": [ "${xsdns}" ] },
  "inbounds": [
EOF
}

# 4. 配置 VMess
config_vmess(){
if [ "$vmp" = yes ]; then
    if [ -z "$port_vm_ws" ] && [ ! -e "$HOME/agsbx/port_vm_ws" ]; then
        port_vm_ws=$(shuf -i 10000-65535 -n 1)
        echo "$port_vm_ws" > "$HOME/agsbx/port_vm_ws"
    elif [ -n "$port_vm_ws" ]; then
        echo "$port_vm_ws" > "$HOME/agsbx/port_vm_ws"
    fi
    port_vm_ws=$(cat "$HOME/agsbx/port_vm_ws")
    
    cat >> "$HOME/agsbx/xr.json" <<EOF
    {
        "tag": "vmess-xr",
        "listen": "::",
        "port": ${port_vm_ws},
        "protocol": "vmess",
        "settings": {
            "clients": [ { "id": "${uuid}" } ]
        },
        "streamSettings": {
            "network": "ws",
            "wsSettings": { "path": "${uuid}-vm" }
        },
        "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls", "quic"]
        }
    },
EOF
fi
}

# 5. 配置路由
config_outbounds(){
sed -i '${s/,\s*$//}' "$HOME/agsbx/xr.json"
cat >> "$HOME/agsbx/xr.json" <<EOF
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": { "domainStrategy":"${xryx}" }
    },
    {
      "tag": "x-warp-out",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "COAYqKrAXaQIGL8+Wkmfe39r1tMMR80JWHVaF443XFQ=",
        "address": [ "172.16.0.2/32", "2606:4700:110:8eb1:3b27:e65e:3645:97b0/128" ],
        "peers": [
          {
            "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
            "allowedIPs": [ "0.0.0.0/0", "::/0" ],
            "endpoint": "${xendip}:2408"
          }
        ],
        "reserved": [134, 63, 85]
      }
    },
    {
      "tag":"warp-out",
      "protocol":"freedom",
      "settings":{ "domainStrategy":"${wxryx}" },
      "proxySettings":{ "tag":"x-warp-out" }
    }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {
        "type": "field",
        "ip": [ ${xip} ],
        "network": "tcp,udp",
        "outboundTag": "${x1outtag}"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "${x2outtag}"
      }
    ]
  }
}
EOF
}

# 6. 安装 Argo (固定/临时)
install_argo(){
if [ "$argo" = yes ]; then
    echo "=========启用 Cloudflared Argo 隧道========="
    if [ ! -e "$HOME/agsbx/cloudflared" ]; then
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu"
        out="$HOME/agsbx/cloudflared"
        (command -v curl>/dev/null 2>&1 && curl -Lo "$out" -# --retry 2 "$url") || (command -v wget>/dev/null 2>&1 && timeout 3 wget -O "$out" --tries=2 "$url")
        chmod +x "$HOME/agsbx/cloudflared"
    fi

    # 生成 Argo 启动脚本/命令
    if [ -n "$ARGO_AUTH" ] && [ -n "$ARGO_DOMAIN" ]; then
        echo "配置固定隧道: $ARGO_DOMAIN"
        echo "$ARGO_DOMAIN" > "$HOME/agsbx/argodomain.log"
        # 记录启动命令供服务文件使用
        echo "$HOME/agsbx/cloudflared tunnel --no-autoupdate run --token ${ARGO_AUTH}" > "$HOME/agsbx/argo_cmd.sh"
    else
        echo "配置临时隧道 (TryCloudflare)..."
        port=$(cat "$HOME/agsbx/port_vm_ws")
        rm -f "$HOME/agsbx/argodomain.log"
        # 记录启动命令
        echo "$HOME/agsbx/cloudflared tunnel --url http://localhost:${port} --edge-ip-version auto --no-autoupdate --protocol http2" > "$HOME/agsbx/argo_cmd.sh"
    fi
    chmod +x "$HOME/agsbx/argo_cmd.sh"
fi
}

# 7. 服务保活与开机自启 (Systemd / OpenRC)
setup_services(){
echo "配置系统服务 (System Service)..."

# --- SYSTEMD (Debian/Ubuntu/CentOS) ---
if pidof systemd >/dev/null 2>&1 && [ "$EUID" -eq 0 ]; then
    # Xray Service
    cat > /etc/systemd/system/xr.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
ExecStart=/root/agsbx/xray run -c /root/agsbx/xr.json
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xr
    systemctl restart xr

    # Argo Service
    if [ "$argo" = yes ]; then
        cat > /etc/systemd/system/argo.service <<EOF
[Unit]
Description=Argo Tunnel Service
After=network.target
[Service]
Type=simple
ExecStart=/bin/sh /root/agsbx/argo_cmd.sh
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable argo
        systemctl restart argo
        
        # 如果是临时隧道，等待日志生成
        if [ -z "$ARGO_AUTH" ]; then
            echo "等待临时隧道申请..."
            sleep 8
        fi
    fi

# --- OPENRC (Alpine) ---
elif command -v rc-service >/dev/null 2>&1; then
    # Xray Service
    cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service"
command="/root/agsbx/xray"
command_args="run -c /root/agsbx/xr.json"
command_background=yes
pidfile="/run/xray.pid"
depend() { need net; }
EOF
    chmod +x /etc/init.d/xray
    rc-update add xray default
    rc-service xray restart

    # Argo Service
    if [ "$argo" = yes ]; then
        cat > /etc/init.d/argo <<EOF
#!/sbin/openrc-run
description="Argo Tunnel Service"
command="/bin/sh"
command_args="/root/agsbx/argo_cmd.sh"
command_background=yes
pidfile="/run/argo.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/argo
        rc-update add argo default
        rc-service argo restart
        if [ -z "$ARGO_AUTH" ]; then sleep 8; fi
    fi

# --- Fallback (Nohup) ---
else
    nohup "$HOME/agsbx/xray" run -c "$HOME/agsbx/xr.json" >/dev/null 2>&1 &
    if [ "$argo" = yes ]; then
        nohup /bin/sh "$HOME/agsbx/argo_cmd.sh" > "$HOME/agsbx/argo.log" 2>&1 &
        sleep 8
    fi
fi
}

# 8. 安装看门狗 (Watchdog) - Crontab
install_watchdog(){
echo "配置看门狗 (Watchdog) 到 Crontab..."
# 备份现有的 crontab
crontab -l > /tmp/cron.bak 2>/dev/null
# 清理旧的 agsbx 相关任务
sed -i '/agsbx/d' /tmp/cron.bak
sed -i '/systemctl.*xr/d' /tmp/cron.bak
sed -i '/rc-service.*xray/d' /tmp/cron.bak

# 生成每分钟检查逻辑
# 1. 针对 Systemd
if pidof systemd >/dev/null 2>&1; then
    # 检查 Xray
    echo "*/1 * * * * /bin/bash -c 'if ! systemctl is-active --quiet xr; then systemctl start xr; fi'" >> /tmp/cron.bak
    # 检查 Argo (如果开启)
    if [ "$argo" = yes ]; then
        echo "*/1 * * * * /bin/bash -c 'if ! systemctl is-active --quiet argo; then systemctl start argo; fi'" >> /tmp/cron.bak
    fi

# 2. 针对 OpenRC
elif command -v rc-service >/dev/null 2>&1; then
    # 检查 Xray
    echo "*/1 * * * * /bin/sh -c 'if ! rc-service xray status >/dev/null 2>&1; then rc-service xray start; fi'" >> /tmp/cron.bak
    # 检查 Argo
    if [ "$argo" = yes ]; then
        echo "*/1 * * * * /bin/sh -c 'if ! rc-service argo status >/dev/null 2>&1; then rc-service argo start; fi'" >> /tmp/cron.bak
    fi

# 3. 针对 Nohup (通过进程匹配)
else
    # 检查 Xray
    echo "*/1 * * * * /bin/sh -c 'pgrep -f \"agsbx/xray\" >/dev/null || nohup $HOME/agsbx/xray run -c $HOME/agsbx/xr.json >/dev/null 2>&1 &'" >> /tmp/cron.bak
    # 检查 Argo
    if [ "$argo" = yes ]; then
        echo "*/1 * * * * /bin/sh -c 'pgrep -f \"cloudflared\" >/dev/null || nohup /bin/sh $HOME/agsbx/argo_cmd.sh > $HOME/agsbx/argo.log 2>&1 &'" >> /tmp/cron.bak
    fi
fi

# 应用 Crontab
crontab /tmp/cron.bak
rm /tmp/cron.bak
echo "看门狗配置完成。"
}

# 9. 快捷命令与环境
persist_env(){
SCRIPT_PATH="$HOME/bin/agsbx"
mkdir -p "$HOME/bin"
cat > "$SCRIPT_PATH" <<EOF
#!/bin/sh
if [ "\$1" = "list" ]; then cat "$HOME/agsbx/jh.txt"; fi
if [ "\$1" = "del" ]; then 
  systemctl stop xr argo 2>/dev/null
  rc-service xray stop 2>/dev/null
  rc-service argo stop 2>/dev/null
  rm -rf "$HOME/agsbx" /etc/systemd/system/xr.service /etc/systemd/system/argo.service /etc/init.d/xray /etc/init.d/argo
  crontab -l | grep -v 'agsbx' | crontab -
  echo "卸载完成"
fi
EOF
chmod +x "$SCRIPT_PATH"
sed -i '/export PATH="\$HOME\/bin:\$PATH"/d' ~/.bashrc
echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
}

# 10. 输出链接
print_links(){
ip=$(curl -s4m5 https://icanhazip.com || curl -s6m5 https://icanhazip.com)
port=$(cat "$HOME/agsbx/port_vm_ws")
uuid=$(cat "$HOME/agsbx/uuid")
name_pre=$(cat "$HOME/agsbx/name" 2>/dev/null)

if [ -f "$HOME/agsbx/argodomain.log" ]; then
    argodom=$(cat "$HOME/agsbx/argodomain.log")
    argo_remark="Fixed"
else
    # 尝试从 nohup 日志读取 (Systemd下Argo输出到journal, 但这里为了简化, 临时隧道也尝试兼容)
    argodom=$(grep -a trycloudflare.com "$HOME/agsbx/argo.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
    # 如果是临时隧道且用了Systemd，可能需要从文件读取(如果之前步骤生成了log)
    if [ -z "$argodom" ] && [ -f "$HOME/agsbx/argo.log" ]; then
         argodom=$(grep -a trycloudflare.com "$HOME/agsbx/argo.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
    fi
    argo_remark="Temp"
fi

rm -f "$HOME/agsbx/jh.txt"
echo "========================================================="
echo "Argosbx 精简增强版配置信息"
echo "UUID: $uuid"
echo "Port: $port"
echo

vm_link="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${name_pre}VMess-Direct\", \"add\": \"$ip\", \"port\": \"$port\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | base64 -w0)"
echo "1. VMess 直连 (IP):"
echo "$vm_link"
echo "$vm_link" >> "$HOME/agsbx/jh.txt"
echo

if [ -n "$argodom" ]; then
    vma_link="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${name_pre}VMess-Argo-${argo_remark}\", \"add\": \"yg1.ygkkk.dpdns.org\", \"port\": \"80\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodom\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | base64 -w0)"
    echo "2. VMess Argo 隧道 ($argo_remark):"
    echo "$vma_link"
    echo "$vma_link" >> "$HOME/agsbx/jh.txt"
else
    if [ "$argo" = yes ]; then
        echo "Argo 域名尚未生成或获取失败，请稍后运行 'cat ~/agsbx/argo.log' 查看。"
    fi
fi
echo "========================================================="
}

# === 执行入口 ===
if [ "$1" = "del" ]; then
    systemctl stop xr argo >/dev/null 2>&1
    rc-service xray stop 2>/dev/null
    rc-service argo stop 2>/dev/null
    rm -rf "$HOME/agsbx" /etc/systemd/system/xr.service /etc/systemd/system/argo.service /etc/init.d/xray /etc/init.d/argo
    crontab -l | grep -v 'agsbx' | crontab -
    echo "卸载完成"
    exit
fi

echo "开始安装 Argosbx (VMess + Watchdog)..."
setenforce 0 >/dev/null 2>&1
iptables -F >/dev/null 2>&1
insuuid
warpsx
installxray
config_vmess
config_outbounds
install_argo
setup_services   # 启动服务
install_watchdog # 配置看门狗
persist_env
print_links
