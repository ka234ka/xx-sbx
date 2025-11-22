#!/bin/sh
export LANG=en_US.UTF-8
# 1. 变量初始化与检查
[ -z "${vmpt+x}" ] || vmp=yes
[ -z "${warp+x}" ] || wap=yes
export uuid=${uuid:-''}
export port_vm_ws=${vmpt:-''}
export argo=${argo:-''}
export ARGO_DOMAIN=${agn:-''}
export ARGO_AUTH=${agk:-''}
export name=${name:-''}
v46url="https://icanhazip.com"

# 简化的帮助信息
showmode(){
echo "Argosbx 精简版 (仅VMess)"
echo "显示节点信息：agsbx list"
echo "重置/更新配置：agsbx rep (需先 export 变量)"
echo "卸载脚本：agsbx del"
echo "---------------------------------------------------------"
}

# 2. 系统检测与环境准备
hostname=$(uname -a | awk '{print $2}')
case $(uname -m) in
aarch64) cpu=arm64;;
x86_64) cpu=amd64;;
*) echo "目前脚本不支持$(uname -m)架构" && exit
esac
mkdir -p "$HOME/agsbx"

# WARP/网络环境检测函数
v4v6(){
v4=$( (command -v curl >/dev/null 2>&1 && curl -s4m5 -k "$v46url" 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -4 --tries=2 -qO- "$v46url" 2>/dev/null) )
v6=$( (command -v curl >/dev/null 2>&1 && curl -s6m5 -k "$v46url" 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -6 --tries=2 -qO- "$v46url" 2>/dev/null) )
}

warpsx(){
if [ -n "$name" ]; then echo "$name-" > "$HOME/agsbx/name"; fi
v4v6
if echo "$v6" | grep -q '^2a09' || echo "$v4" | grep -q '^104.28'; then
    # 已有WARP环境，设置为直连，避免套娃
    s1outtag=direct; x1outtag=direct; x2outtag=direct; xip='"::/0", "0.0.0.0/0"'; wap=warpargo
    echo "检测到已安装WARP，使用直连模式。"
else
    # 这里的逻辑保留原脚本的精髓，用于生成Xray的路由规则
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
# 设置WireGuard参数
case "$warp" in *x4*) wxryx='ForceIPv4' ;; *x6*) wxryx='ForceIPv6' ;; *) wxryx='ForceIPv4v6' ;; esac
if (command -v curl >/dev/null 2>&1 && curl -s6m5 -k "$v46url" >/dev/null 2>&1); then
    xryx='ForceIPv6v4'; xendip="[2606:4700:d0::a29f:c001]"; xsdns="[2001:4860:4860::8888]"
else
    case "$warp" in *x4*) xryx='ForceIPv4' ;; esac
    [ -z "$xryx" ] && xryx='ForceIPv4v6'
    xendip="162.159.192.1"; xsdns="8.8.8.8"
fi
}

# UUID生成
insuuid(){
if [ -z "$uuid" ] && [ ! -e "$HOME/agsbx/uuid" ]; then
    uuid=$(cat /proc/sys/kernel/random/uuid)
    echo "$uuid" > "$HOME/agsbx/uuid"
elif [ -n "$uuid" ]; then
    echo "$uuid" > "$HOME/agsbx/uuid"
fi
uuid=$(cat "$HOME/agsbx/uuid")
}

# 3. 安装 Xray 内核 (仅保留Xray，移除Sing-box)
installxray(){
echo "=========启用 Xray 内核 (VMess核心)========="
mkdir -p "$HOME/agsbx/xrk"
if [ ! -e "$HOME/agsbx/xray" ]; then
    url="https://github.com/ka234ka/go-sbx/releases/download/argosbx/xray-$cpu"
    out="$HOME/agsbx/xray"
    (command -v curl >/dev/null 2>&1 && curl -Lo "$out" -# --retry 2 "$url") || (command -v wget>/dev/null 2>&1 && timeout 3 wget -O "$out" --tries=2 "$url")
    chmod +x "$HOME/agsbx/xray"
fi
# 初始化 JSON 头部
cat > "$HOME/agsbx/xr.json" <<EOF
{
  "log": { "loglevel": "none" },
  "dns": { "servers": [ "${xsdns}" ] },
  "inbounds": [
EOF
}

# 4. 配置 VMess 协议
config_vmess(){
if [ "$vmp" = yes ]; then
    if [ -z "$port_vm_ws" ] && [ ! -e "$HOME/agsbx/port_vm_ws" ]; then
        port_vm_ws=$(shuf -i 10000-65535 -n 1)
        echo "$port_vm_ws" > "$HOME/agsbx/port_vm_ws"
    elif [ -n "$port_vm_ws" ]; then
        echo "$port_vm_ws" > "$HOME/agsbx/port_vm_ws"
    fi
    port_vm_ws=$(cat "$HOME/agsbx/port_vm_ws")
    echo "VMess-WS 端口：$port_vm_ws"

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

# 5. 配置出站与路由 (含WARP支持)
config_outbounds(){
# 结束inbounds数组，开始outbounds
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

# 6. 服务与持久化
start_services(){
# Systemd 服务
if pidof systemd >/dev/null 2>&1 && [ "$EUID" -eq 0 ]; then
cat > /etc/systemd/system/xr.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
ExecStart=/root/agsbx/xray run -c /root/agsbx/xr.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable xr; systemctl start xr
# OpenRC 服务
elif command -v rc-service >/dev/null 2>&1; then
cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service"
command="/root/agsbx/xray"
command_args="run -c /root/agsbx/xr.json"
command_background=yes
pidfile="/run/xray.pid"
depend() { need net; }
EOF
chmod +x /etc/init.d/xray; rc-update add xray default; rc-service xray start
else
nohup "$HOME/agsbx/xray" run -c "$HOME/agsbx/xr.json" >/dev/null 2>&1 &
fi
}

# 7. Argo 隧道 (如果开启)
install_argo(){
if [ "$argo" = yes ]; then
    echo "=========启用 Cloudflared Argo 隧道========="
    if [ ! -e "$HOME/agsbx/cloudflared" ]; then
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu"
        out="$HOME/agsbx/cloudflared"
        (command -v curl>/dev/null 2>&1 && curl -Lo "$out" -# --retry 2 "$url") || (command -v wget>/dev/null 2>&1 && timeout 3 wget -O "$out" --tries=2 "$url")
        chmod +x "$HOME/agsbx/cloudflared"
    fi
    
    # 启动 Argo，指向本地 VMess 端口
    port=$(cat "$HOME/agsbx/port_vm_ws")
    nohup "$HOME/agsbx/cloudflared" tunnel --url http://localhost:"${port}" --edge-ip-version auto --no-autoupdate --protocol http2 > "$HOME/agsbx/argo.log" 2>&1 &
    
    echo "申请Argo隧道中……请稍等"
    sleep 8
    argodomain=$(grep -a trycloudflare.com "$HOME/agsbx/argo.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
    if [ -n "${argodomain}" ]; then echo "Argo隧道申请成功: $argodomain"; else echo "Argo申请失败"; fi
fi
}

# 8. 写入系统环境 (Bashrc / Crontab)
persist_env(){
SCRIPT_PATH="$HOME/bin/agsbx"
mkdir -p "$HOME/bin"
# 这里为了演示，实际上应该下载这个脚本本身，这里简化处理
cat > "$SCRIPT_PATH" <<EOF
#!/bin/sh
echo "Argosbx 精简版 - 快捷命令"
if [ "\$1" = "list" ]; then
    cat "$HOME/agsbx/jh.txt"
elif [ "\$1" = "del" ]; then
    systemctl stop xr; rm -rf "$HOME/agsbx" /etc/systemd/system/xr.service; echo "卸载完成"
elif [ "\$1" = "rep" ]; then
    echo "请重新运行安装脚本进行重置"
fi
EOF
chmod +x "$SCRIPT_PATH"
sed -i '/export PATH="\$HOME\/bin:\$PATH"/d' ~/.bashrc
echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"

# Crontab 保活
crontab -l > /tmp/crontab.tmp 2>/dev/null
sed -i '/agsbx\/xray/d' /tmp/crontab.tmp
echo '@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/xray run -c $HOME/agsbx/xr.json >/dev/null 2>&1 &"' >> /tmp/crontab.tmp
crontab /tmp/crontab.tmp; rm /tmp/crontab.tmp
}

# 9. 输出节点链接
print_links(){
ip=$(curl -s4m5 https://icanhazip.com || curl -s6m5 https://icanhazip.com)
port=$(cat "$HOME/agsbx/port_vm_ws")
uuid=$(cat "$HOME/agsbx/uuid")
argodom=$(grep -a trycloudflare.com "$HOME/agsbx/argo.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
name_pre=$(cat "$HOME/agsbx/name" 2>/dev/null)
rm -f "$HOME/agsbx/jh.txt"

echo "========================================================="
echo "Argosbx 精简版 (VMess Only) 配置信息："
echo "UUID: $uuid"
echo "Port: $port"
echo

# VMess 直连链接
vm_link="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${name_pre}VMess-Direct\", \"add\": \"$ip\", \"port\": \"$port\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | base64 -w0)"
echo "1. VMess 直连节点:"
echo "$vm_link"
echo "$vm_link" >> "$HOME/agsbx/jh.txt"
echo

# Argo 链接
if [ -n "$argodom" ]; then
    vma_link="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${name_pre}VMess-Argo\", \"add\": \"yg1.ygkkk.dpdns.org\", \"port\": \"80\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodom\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | base64 -w0)"
    echo "2. VMess Argo 隧道节点 (防墙):"
    echo "$vma_link"
    echo "$vma_link" >> "$HOME/agsbx/jh.txt"
fi
echo "========================================================="
}

# === 主执行逻辑 ===
if [ "$1" = "del" ]; then
    systemctl stop xr >/dev/null 2>&1
    rm -rf "$HOME/agsbx" /etc/systemd/system/xr.service
    echo "卸载完成"
    exit
fi

# 开始安装
echo "Argosbx 精简版开始安装..."
setenforce 0 >/dev/null 2>&1
iptables -F >/dev/null 2>&1 # 清空防火墙确保连通

insuuid
warpsx
installxray
config_vmess
config_outbounds
install_argo
start_services
persist_env
print_links

echo "安装完毕！可通过 'agsbx list' 查看链接。"
