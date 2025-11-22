#!/bin/bash
export LANG=en_US.UTF-8

# ==================================================
# 1. 变量初始化
# ==================================================
[ -n "$nix" ] && install_trigger="$nix"
[ -n "$uuid" ] && export UUID="$uuid"
[ -n "$vmpt" ] && export PORT="$vmpt"
[ -n "$argo" ] && export ENABLE_ARGO="$argo"
[ -n "$agn" ] && export ARGO_DOMAIN="$agn"
[ -n "$agk" ] && export ARGO_TOKEN="$agk"

export PORT=${PORT:-$(shuf -i 10000-65000 -n 1)}
if [ -z "$UUID" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "eac8c09c-8409-4c63-a56b-187ce1f7b048")
fi

if [ "$install_trigger" != "y" ]; then
    echo "提示：请在脚本前设置变量 nix=y 才能运行安装。"
    exit 1
fi

if [ "$ENABLE_ARGO" = "y" ] && ([ -z "$ARGO_TOKEN" ] || [ -z "$ARGO_DOMAIN" ]); then
    echo "错误：开启 Argo 必须提供 agn (域名) 和 agk (Token)。"
    exit 1
fi

# ==================================================
# 2. 系统检测与环境准备
# ==================================================
arch=$(uname -m)
case $arch in
    x86_64) 
        cpu_arch="amd64"
        xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
        argo_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
        ;;
    aarch64) 
        cpu_arch="arm64" 
        xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"
        argo_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
        ;;
    *) echo "不支持的架构: $arch" && exit 1 ;;
esac

echo "CPU架构：$cpu_arch"
echo "Argosbx脚本未安装，开始安装…………"

# 安装依赖 (包含 cron)
if [ -f /etc/alpine-release ]; then
    apk add --no-cache curl wget unzip tar ca-certificates bash dcron >/dev/null 2>&1
    rc-service crond start >/dev/null 2>&1
    rc-update add crond >/dev/null 2>&1
elif [ -f /etc/debian_version ]; then
    apt-get update >/dev/null 2>&1 && apt-get install -y curl wget unzip tar ca-certificates cron >/dev/null 2>&1
    systemctl enable cron >/dev/null 2>&1
    systemctl start cron >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget unzip tar ca-certificates cronie >/dev/null 2>&1
    systemctl enable crond >/dev/null 2>&1
    systemctl start crond >/dev/null 2>&1
fi

WORKDIR="$HOME/agsbx"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ==================================================
# 3. 安装核心组件
# ==================================================
echo
echo "=========启用xray内核========="
curl -L -o xray.zip "$xray_url" --progress-bar
unzip -q -o xray.zip
rm -f xray.zip geoip.dat geosite.dat
mv xray x
chmod +x x

xray_version=$(./x version 2>/dev/null | head -n 1 | awk '{print $2}')
echo "已安装Xray正式版内核：$xray_version"
echo "UUID密码：$UUID"
echo "Vmess-ws端口：$PORT"

# 生成配置
cat > config.json <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "$UUID" } ] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vm" } },
      "listen": "127.0.0.1"
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

echo
echo "=========启用Cloudflared-argo内核========="
echo "下载Cloudflared-argo最新正式版内核："
curl -L -o cloudflared "$argo_url" --progress-bar
chmod +x cloudflared

# ==================================================
# 4. 配置保活机制 (Watchdog) - 关键修改
# ==================================================
echo
echo "正在配置进程保活监控..."

# 创建守护脚本 keep_alive.sh
cat > "$WORKDIR/keep_alive.sh" <<EOF
#!/bin/bash
WORKDIR="$WORKDIR"
cd "\$WORKDIR"

# 检查 Xray
if ! pgrep -f "\$WORKDIR/x run" >/dev/null; then
    nohup ./x run -c config.json >/dev/null 2>&1 &
    echo "\$(date): Xray restarted" >> restart.log
fi

# 检查 Argo (如果有Token)
if [ -n "$ARGO_TOKEN" ]; then
    if ! pgrep -f "cloudflared tunnel" >/dev/null; then
        nohup ./cloudflared tunnel --no-autoupdate run --token "$ARGO_TOKEN" > argo.log 2>&1 &
        echo "\$(date): Argo restarted" >> restart.log
    fi
fi
EOF
chmod +x "$WORKDIR/keep_alive.sh"

# 初次运行守护脚本启动服务
bash "$WORKDIR/keep_alive.sh"

if [ "$ENABLE_ARGO" = "y" ]; then
    echo "申请Argo固定隧道中……请稍等"
    sleep 5
    if pgrep -f cloudflared >/dev/null; then
        echo "Argo固定隧道申请成功"
    else
        echo "Argo启动失败，请检查 Token 是否正确"
    fi
fi

# 添加到 Crontab (每分钟检查 + 开机自启)
crontab -l 2>/dev/null | grep -v "keep_alive.sh" > /tmp/cron.tmp
echo "* * * * * /bin/bash $WORKDIR/keep_alive.sh" >> /tmp/cron.tmp
echo "@reboot /bin/bash $WORKDIR/keep_alive.sh" >> /tmp/cron.tmp
crontab /tmp/cron.tmp
rm -f /tmp/cron.tmp

echo "Argosbx脚本进程启动成功，安装完毕"

# ==================================================
# 5. 状态与输出
# ==================================================
echo
echo "=========当前三大内核运行状态========="
echo "Sing-box：未启用"
if pgrep -f "$WORKDIR/x" >/dev/null; then echo "Xray：运行中"; else echo "Xray：未运行"; fi
if pgrep -f cloudflared >/dev/null; then echo "Argo：运行中"; else echo "Argo：未启用"; fi

echo
echo "=========当前服务器本地IP情况========="
v4=$(curl -s4m5 https://icanhazip.com)
v6=$(curl -s6m5 https://icanhazip.com)
[ -z "$v4" ] && v4="无IPV4"
[ -z "$v6" ] && v6="无IPV6"
echo "本地IPV4地址：$v4"
echo "本地IPV6地址：$v6"
echo "服务器地区：$(curl -s https://ipapi.co/country_name/ 2>/dev/null)"

echo
echo "*********************************************************"
echo "*********************************************************"
echo "Argosbx脚本输出节点配置如下："
echo

if [ "$ENABLE_ARGO" = "y" ]; then
    vmess_json=$(cat <<EOF
{
  "v": "2",
  "ps": "Argo-Fixed-$ARGO_DOMAIN",
  "add": "$ARGO_DOMAIN",
  "port": "443",
  "id": "$UUID",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "$ARGO_DOMAIN",
  "path": "/vm",
  "tls": "tls",
  "sni": "$ARGO_DOMAIN"
}
EOF
)
    vm_link="vmess://$(echo -n "$vmess_json" | base64 -w 0)"
    echo "💣【 VMess-Argo-Fixed 】节点信息如下："
    echo "$vm_link"
else
    echo "未启用 Argo，无输出。"
fi
echo
