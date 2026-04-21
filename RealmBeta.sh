#!/bin/bash

# ==================================================
# Realm 一键转发管理脚本 (纯净增强版)
# 支持系统: Ubuntu/Debian/CentOS
# 说明: 适配 /tmp 目录本地安装包，支持 IPv4+IPv6 双栈监听
# 增强: 集成 nftables 精准流量统计、流量阈值熔断封禁、TCP 延迟测速诊断
# ==================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 变量定义
DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/v2.9.2-2/realm-x86_64-unknown-linux-musl.tar.gz"
FILE_NAME="realm-x86_64-unknown-linux-musl.tar.gz"
LOCAL_PKG_PATH="/tmp/${FILE_NAME}"

REALM_BIN_PATH="/usr/local/bin/realm"
REALM_CONFIG_PATH="/etc/realm/config.toml"
REALM_SERVICE_PATH="/etc/systemd/system/realm.service"
WORK_DIR="/etc/realm"
BACKUP_DIR="/root/realmconfig"

# 流量与配额变量
TRAFFIC_FILE="/etc/realm/traffic.log"
QUOTA_FILE="/etc/realm/quota.txt"
MONTH_FILE="/etc/realm/month.txt"
DAEMON_BIN_PATH="/usr/local/bin/realm-daemon.sh"
DAEMON_SERVICE_PATH="/etc/systemd/system/realm-daemon.service"

# 检查是否为 Root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 安装与配置流量守护进程
install_traffic_daemon() {
    # 确保 nftables 环境
    if [ -x "$(command -v apt-get)" ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y nftables >/dev/null 2>&1
    elif [ -x "$(command -v yum)" ]; then
        yum install -y nftables >/dev/null 2>&1
    fi

    # 写入守护进程脚本
    cat > "$DAEMON_BIN_PATH" << 'EOF'
#!/bin/bash
TRAFFIC_FILE="/etc/realm/traffic.log"
QUOTA_FILE="/etc/realm/quota.txt"
MONTH_FILE="/etc/realm/month.txt"

sync_nftables() {
    nft add table inet realm_table 2>/dev/null
    nft add chain inet realm_table input_hook { type filter hook input priority 0 \; } 2>/dev/null
    nft add chain inet realm_table output_hook { type filter hook output priority 0 \; } 2>/dev/null
    nft add chain inet realm_table realm_acct 2>/dev/null

    nft flush chain inet realm_table input_hook 2>/dev/null
    nft add rule inet realm_table input_hook jump realm_acct 2>/dev/null
    nft flush chain inet realm_table output_hook 2>/dev/null
    nft add rule inet realm_table output_hook jump realm_acct 2>/dev/null

    nft add chain inet realm_table realm_drop { type filter hook input priority -1 \; } 2>/dev/null
    nft add set inet realm_table disabled_tcp { type inet_service \; } 2>/dev/null
    nft add set inet realm_table disabled_udp { type inet_service \; } 2>/dev/null
    
    nft flush chain inet realm_table realm_drop 2>/dev/null
    nft add rule inet realm_table realm_drop tcp dport @disabled_tcp drop 2>/dev/null
    nft add rule inet realm_table realm_drop udp dport @disabled_udp drop 2>/dev/null

    nft flush chain inet realm_table realm_acct 2>/dev/null

    if [ -f /etc/realm/config.toml ]; then
        ports=$(grep -o 'listen = "[^"]*"' /etc/realm/config.toml | awk -F':' '{print $NF}' | tr -d '"')
        for p in $ports; do
            nft add rule inet realm_table realm_acct tcp sport $p counter 2>/dev/null
            nft add rule inet realm_table realm_acct udp sport $p counter 2>/dev/null
            nft add rule inet realm_table realm_acct tcp dport $p counter 2>/dev/null
            nft add rule inet realm_table realm_acct udp dport $p counter 2>/dev/null
        done
    fi
}

while true; do
    current_month=$(date +"%Y-%m")
    last_month=$(cat $MONTH_FILE 2>/dev/null)
    if [ "$current_month" != "$last_month" ]; then
        echo "$current_month" > $MONTH_FILE
        > $TRAFFIC_FILE
        nft flush set inet realm_table disabled_tcp 2>/dev/null
        nft flush set inet realm_table disabled_udp 2>/dev/null
    fi

    sync_nftables
    stats=$(nft reset rules inet realm_table realm_acct 2>/dev/null | grep 'bytes')

    declare -A current_bytes
    while read -r line; do
        if [[ $line =~ (dport|sport)[[:space:]]+([0-9]+)[[:space:]]+counter[[:space:]]+packets[[:space:]]+[0-9]+[[:space:]]+bytes[[:space:]]+([0-9]+) ]]; then
            port="${BASH_REMATCH[2]}"
            b="${BASH_REMATCH[3]}"
            current_bytes[$port]=$((current_bytes[$port] + b))
        fi
    done <<< "$stats"

    declare -A total_bytes
    if [ -f $TRAFFIC_FILE ]; then
        while read p b; do
            total_bytes[$p]=$b
        done < $TRAFFIC_FILE
    fi

    > $TRAFFIC_FILE.tmp
    for p in "${!current_bytes[@]}"; do
        total_bytes[$p]=$(( total_bytes[$p] + current_bytes[$p] ))
    done
    for p in "${!total_bytes[@]}"; do
        echo "$p ${total_bytes[$p]}" >> $TRAFFIC_FILE.tmp
    done
    mv $TRAFFIC_FILE.tmp $TRAFFIC_FILE

    if [ -f $QUOTA_FILE ]; then
        while read q_port q_gb; do
            if [ -n "$q_gb" ] && [ "$q_gb" -gt 0 ]; then
                q_bytes=$(awk "BEGIN {printf \"%.0f\", $q_gb*1073741824}")
                t_bytes=${total_bytes[$q_port]:-0}
                if [ "$t_bytes" -ge "$q_bytes" ]; then
                    nft add element inet realm_table disabled_tcp { $q_port } 2>/dev/null
                    nft add element inet realm_table disabled_udp { $q_port } 2>/dev/null
                else
                    nft delete element inet realm_table disabled_tcp { $q_port } 2>/dev/null
                    nft delete element inet realm_table disabled_udp { $q_port } 2>/dev/null
                fi
            fi
        done < $QUOTA_FILE
    fi

    sleep 60
done
EOF

    chmod +x "$DAEMON_BIN_PATH"

    cat > "$DAEMON_SERVICE_PATH" <<EOF
[Unit]
Description=Realm Traffic Daemon
After=network.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=5
ExecStart=$DAEMON_BIN_PATH

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm-daemon >/dev/null 2>&1
    systemctl start realm-daemon
}

# 1. 安装 Realm
install_realm() {
    if [ -f "$REALM_BIN_PATH" ]; then
        echo -e "${YELLOW}检测到 Realm 已安装，跳过安装步骤。${PLAIN}"
    else
        echo -e "${GREEN}选择安装方式:${PLAIN}"
        echo -e " 1. 在线下载安装 (使用预设 v2.9.2-2 musl 链接)"
        echo -e " 2. 本地文件安装 (请先将 $FILE_NAME 上传至 /tmp 目录)"
        read -p "请输入选项 [1-2]: " install_method

        if [ "$install_method" == "1" ]; then
            echo -e "${GREEN}正在下载 Realm...${PLAIN}"
            wget -N --no-check-certificate "$DOWNLOAD_URL" -O "$FILE_NAME"
            if [ $? -ne 0 ]; then
                echo -e "${RED}下载失败，请检查网络或尝试本地安装。${PLAIN}"
                rm -f "$FILE_NAME"
                return
            fi
            tar -xvf "$FILE_NAME"
            chmod +x realm
            mv realm "$REALM_BIN_PATH"
            rm -f "$FILE_NAME"
        elif [ "$install_method" == "2" ]; then
            if [ -f "$LOCAL_PKG_PATH" ]; then
                echo -e "${GREEN}检测到 /tmp 目录下存在安装包，开始安装...${PLAIN}"
                tar -xvf "$LOCAL_PKG_PATH" -C /tmp/
                if [ -f "/tmp/realm" ]; then
                    chmod +x /tmp/realm
                    mv /tmp/realm "$REALM_BIN_PATH"
                    echo -e "${GREEN}二进制文件已部署。${PLAIN}"
                else
                    echo -e "${RED}解压失败或压缩包内未找到 'realm' 文件！${PLAIN}"
                    return
                fi
            else
                echo -e "${RED}未在 /tmp 下找到文件: $FILE_NAME ${PLAIN}"
                return
            fi
        else
            echo -e "${RED}无效选项${PLAIN}"
            return
        fi
    fi

    mkdir -p "$WORK_DIR"
    if [ ! -f "$REALM_CONFIG_PATH" ]; then
        echo -e "${GREEN}生成默认配置 (双栈监听 + 占位规则)...${PLAIN}"
        cat > "$REALM_CONFIG_PATH" <<EOF
[network]
no_tcp = false
use_udp = true
zero_copy = true

# 默认占位规则
[[endpoints]]
listen = "[::]:20000"
remote = "127.0.0.1:20001"
EOF
    fi

    cat > "$REALM_SERVICE_PATH" <<EOF
[Unit]
Description=realm
After=network.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=5
ExecStart=${REALM_BIN_PATH} -c ${REALM_CONFIG_PATH}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm
    
    install_traffic_daemon

    echo -e "${GREEN}正在启动服务...${PLAIN}"
    systemctl start realm
    sleep 1
    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}Realm 核心及流量控制守护进程安装并启动成功！${PLAIN}"
    else
        echo -e "${RED}Realm 启动失败，请检查日志${PLAIN}"
    fi
}

# 2. 卸载 Realm
uninstall_realm() {
    systemctl stop realm realm-daemon >/dev/null 2>&1
    systemctl disable realm realm-daemon >/dev/null 2>&1
    rm -f "$REALM_SERVICE_PATH" "$DAEMON_SERVICE_PATH"
    rm -f "$REALM_BIN_PATH" "$DAEMON_BIN_PATH"
    rm -rf "$WORK_DIR"
    systemctl daemon-reload
    systemctl reset-failed realm.service realm-daemon.service 2>/dev/null
    
    # 清理防火墙规则
    nft delete table inet realm_table 2>/dev/null
    
    echo -e "${GREEN}Realm 核心、流量控制及开机自启已彻底卸载。${PLAIN}"
}

# 3. 添加转发
add_forward() {
    if [ ! -f "$REALM_CONFIG_PATH" ]; then
        echo -e "${RED}Realm 未安装或配置文件丢失！${PLAIN}"
        return
    fi

    echo -e "${GREEN}=== 添加转发规则 (支持双栈) ===${PLAIN}"
    echo -e "${YELLOW}提示: 如果目标是 IPv6 地址，请输入 [地址]，例如 [2408:xxx:xxx]${PLAIN}"
    read -p "请输入本地监听端口 (例如 20000): " listen_port
    if ! [[ "$listen_port" =~ ^[0-9]+$ ]] || [ "$listen_port" -lt 1 ] || [ "$listen_port" -gt 65535 ]; then
        echo -e "${RED}错误: 监听端口必须是 1-65535 之间的数字！${PLAIN}"
        return
    fi
    
    read -p "请输入目标 IP (例如 1.1.1.1 或 [IPv6]): " remote_ip
    
    read -p "请输入目标端口 (例如 443): " remote_port
    if ! [[ "$remote_port" =~ ^[0-9]+$ ]] || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo -e "${RED}错误: 目标端口必须是 1-65535 之间的数字！${PLAIN}"
        return
    fi

    read -p "请输入流量上限(GB, 0为无限制) [默认0]: " quota_gb
    if [ -z "$quota_gb" ]; then quota_gb=0; fi
    if ! [[ "$quota_gb" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 流量上限必须是数字！${PLAIN}"
        return
    fi

    # 使用 [::] 监听实现双栈支持
    cat >> "$REALM_CONFIG_PATH" <<EOF

[[endpoints]]
listen = "[::]:$listen_port"
remote = "$remote_ip:$remote_port"
EOF

    # 更新配额配置
    sed -i "/^$listen_port /d" "$QUOTA_FILE" 2>/dev/null
    echo "$listen_port $quota_gb" >> "$QUOTA_FILE"

    restart_realm
    echo -e "${GREEN}转发规则已添加: [::]:$listen_port -> $remote_ip:$remote_port (流量上限: ${quota_gb} GB)${PLAIN}"
}

# 4. 删除转发
delete_forward() {
    if [ ! -f "$REALM_CONFIG_PATH" ]; then
        echo -e "${RED}配置文件不存在！${PLAIN}"
        return
    fi
    echo -e "${GREEN}=== 当前转发规则列表 ===${PLAIN}"
    rules_count=$(grep -c "\[\[endpoints\]\]" "$REALM_CONFIG_PATH")
    if [ "$rules_count" -eq 0 ]; then
        echo -e "${YELLOW}当前没有转发规则。${PLAIN}"
        return
    fi
    i=1
    grep -A 2 "\[\[endpoints\]\]" "$REALM_CONFIG_PATH" > /tmp/realm_rules_list.tmp
    while read -r line; do
        if [[ "$line" == "[[endpoints]]" ]]; then
            echo -n "$i. "
            ((i++))
        elif [[ "$line" == listen* ]]; then
            port=$(echo "$line" | cut -d '"' -f 2)
            echo -n "监听: ${SKYBLUE}$port${PLAIN}  -->  "
        elif [[ "$line" == remote* ]]; then
            dest=$(echo "$line" | cut -d '"' -f 2)
            echo -e "目标: ${YELLOW}$dest${PLAIN}"
        fi
    done < /tmp/realm_rules_list.tmp
    rm -f /tmp/realm_rules_list.tmp
    echo -e "------------------------"
    read -p "请输入要删除的规则序号 (输入 0 取消): " delete_index
    if [ "$delete_index" == "0" ] || [ -z "$delete_index" ]; then return; fi
    if [ "$rules_count" -eq 1 ]; then
        echo -e "${RED}警告: Realm 必须至少保留一条规则。${PLAIN}"
        read -p "是否确定清空? (y/n): " confirm
        if [ "$confirm" != "y" ]; then return; fi
    fi
    
    # 提取被删除的端口信息以清理限额配置
    target_port=$(grep -A 2 "\[\[endpoints\]\]" "$REALM_CONFIG_PATH" | awk -v target="$delete_index" 'BEGIN { count=0 } /^\[\[endpoints\]\]/ { count++ } { if (count == target && $0 ~ /listen/) { print $0 } }' | cut -d '"' -f 2 | awk -F':' '{print $NF}')

    awk -v target="$delete_index" 'BEGIN { count=0; print_block=1 } /^\[\[endpoints\]\]/ { count++; if (count == target) { print_block=0 } else { print_block=1 } } { if (print_block == 1) print $0 }' "$REALM_CONFIG_PATH" > "${REALM_CONFIG_PATH}.tmp"
    if [ -s "${REALM_CONFIG_PATH}.tmp" ]; then
        mv "${REALM_CONFIG_PATH}.tmp" "$REALM_CONFIG_PATH"
    else
        echo -e "${RED}处理配置文件时发生错误，已取消删除！${PLAIN}"
        rm -f "${REALM_CONFIG_PATH}.tmp"
        return
    fi
    
    sed -i '/^$/N;/^\n$/D' "$REALM_CONFIG_PATH"
    
    if [ -n "$target_port" ]; then
        sed -i "/^$target_port /d" "$QUOTA_FILE" 2>/dev/null
    fi

    restart_realm
    echo -e "${GREEN}规则及相关限流配置已成功删除！${PLAIN}"
}

# 5. 查看配置与流量统计
show_config_and_traffic() {
    if [ ! -f "$REALM_CONFIG_PATH" ]; then
        echo -e "${RED}配置文件不存在！${PLAIN}"
        return
    fi
    echo -e "${GREEN}=== 当前底层转发配置 ===${PLAIN}"
    cat "$REALM_CONFIG_PATH"

    echo -e "\n${GREEN}=== 节点流量统计 (仅当月生效) ===${PLAIN}"
    printf "%-12s %-18s %-18s %-15s\n" "监听端口" "已用流量(GB)" "配额上限(GB)" "当前状态"
    echo "------------------------------------------------------------------"
    
    ports=$(grep -o 'listen = "[^"]*"' /etc/realm/config.toml | awk -F':' '{print $NF}' | tr -d '"')
    for p in $ports; do
        used_bytes=0
        if [ -f "$TRAFFIC_FILE" ]; then
            b=$(grep "^$p " "$TRAFFIC_FILE" | awk '{print $2}')
            [ -n "$b" ] && used_bytes=$b
        fi
        used_gb=$(awk "BEGIN {printf \"%.3f\", $used_bytes/1073741824}")
        
        quota_gb="无限制"
        limit_bytes=0
        if [ -f "$QUOTA_FILE" ]; then
            q=$(grep "^$p " "$QUOTA_FILE" | awk '{print $2}')
            if [ -n "$q" ] && [ "$q" -gt 0 ]; then
                quota_gb="$q"
                limit_bytes=$(awk "BEGIN {printf \"%.0f\", $q*1073741824}")
            fi
        fi
        
        status="${GREEN}运行中${PLAIN}"
        if [ "$limit_bytes" -gt 0 ] && [ "$used_bytes" -ge "$limit_bytes" ]; then
            status="${RED}超限熔断停机${PLAIN}"
        fi
        
        printf "%-12s %-18s %-18s %b\n" "$p" "$used_gb" "$quota_gb" "$status"
    done
    
    echo ""
    read -p "按回车继续..."
}

# 6. 重启服务
restart_realm() {
    systemctl restart realm
    systemctl restart realm-daemon 2>/dev/null
    if [ $? -eq 0 ]; then echo -e "${GREEN}核心及守护服务已重启生效。${PLAIN}"; else echo -e "${RED}服务重启失败！${PLAIN}"; fi
}

# 7. 备份节点信息
backup_nodes() {
    mkdir -p "$BACKUP_DIR"
    if [ ! -f "$REALM_CONFIG_PATH" ]; then
        echo -e "${RED}未找到 Realm 配置文件 (/etc/realm/config.toml)，请先添加节点！${PLAIN}"
        return
    fi
    local backup_name="config_backup_$(date +%Y%m%d_%H%M%S).toml"
    cp "$REALM_CONFIG_PATH" "$BACKUP_DIR/$backup_name"
    # 同时备份流量与限额
    [ -f "$QUOTA_FILE" ] && cp "$QUOTA_FILE" "$BACKUP_DIR/${backup_name}.quota"
    
    echo -e "${GREEN}成功备份当前节点及限流信息至: $BACKUP_DIR/${PLAIN}"
}

# 8. 恢复节点信息
restore_nodes() {
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR"/*.toml 2>/dev/null)" ]; then
        echo -e "${RED}未在 $BACKUP_DIR 中找到任何配置文件备份！${PLAIN}"
        return
    fi
    
    echo -e "${SKYBLUE}==========================================${PLAIN}"
    echo -e "请选择要恢复的备份文件："
    local i=1
    local files=()
    for f in "$BACKUP_DIR"/*.toml; do
        files[$i]=$f
        echo -e " ${GREEN}${i}.${PLAIN} $(basename "$f")"
        ((i++))
    done
    echo -e "${SKYBLUE}==========================================${PLAIN}"
    
    read -p "请输入对应的序号 (1-$((i-1))，按0取消): " sel
    if [ "$sel" == "0" ]; then
        echo -e "${YELLOW}已取消恢复操作。${PLAIN}"
        return
    fi
    
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -lt $i ]; then
        cp "${files[$sel]}" "$REALM_CONFIG_PATH"
        [ -f "${files[$sel]}.quota" ] && cp "${files[$sel]}.quota" "$QUOTA_FILE"
        restart_realm
        echo -e "${GREEN}节点信息已成功恢复，且核心服务已自动重启生效！${PLAIN}"
    else
        echo -e "${RED}输入无效！${PLAIN}"
    fi
}

# 9. TCP 诊断节点测试
tcp_diag() {
    echo -e "${GREEN}=== 节点 TCP 延迟诊断 ===${PLAIN}"
    read -p "请输入要测试的目标 IP: " dip
    read -p "请输入要测试的目标端口: " dport
    if [ -z "$dip" ] || [ -z "$dport" ]; then
        echo -e "${RED}输入不能为空！${PLAIN}"
        return
    fi
    echo -e "${GREEN}正在执行 5 次 TCP 握手测试 (目标: $dip:$dport)...${PLAIN}"
    success=0
    total_time=0
    for i in {1..5}; do
        start=$(date +%s%3N)
        timeout 1 bash -c "</dev/tcp/$dip/$dport" 2>/dev/null
        if [ $? -eq 0 ]; then
            end=$(date +%s%3N)
            delay=$(( end - start ))
            total_time=$((total_time + delay))
            ((success++))
        fi
    done
    loss=$(((5-success)*20))
    avg=0
    if [ $success -gt 0 ]; then avg=$((total_time/success)); fi
    echo -e "------------------------"
    echo -e "丢包率: ${YELLOW}${loss}%${PLAIN}"
    echo -e "平均延迟: ${YELLOW}${avg} ms${PLAIN}"
}

# 显示状态
show_status() {
    if systemctl is-active --quiet realm; then echo -e "Realm 状态: ${GREEN}运行中${PLAIN}"; else echo -e "Realm 状态: ${RED}未运行${PLAIN}"; fi
    if systemctl is-active --quiet realm-daemon; then echo -e "流量守护进程: ${GREEN}运行中${PLAIN}"; else echo -e "流量守护进程: ${RED}未运行${PLAIN}"; fi
}

# 主菜单
show_menu() {
    clear
    echo -e "============================================"
    echo -e "               Realm 转发管理脚本               "
    echo -e "============================================"
    show_status
    echo -e "--------------------------------------------"
    echo -e "  1. 安装 Realm 转发并开机自启 (含流量控制)"
    echo -e "  2. 卸载 Realm 转发并删除自启"
    echo -e "  3. 添加转发规则 (TCP+UDP / 双栈 / 流量限制)"
    echo -e "  4. 删除转发规则 (列表显示)"
    echo -e "  5. 查看当前配置及流量统计"
    echo -e "  6. 重启 Realm 服务"
    echo -e "  7. 备份节点信息"
    echo -e "  8. 恢复节点信息"
    echo -e "  9. 节点 TCP 诊断 (延迟测速)"
    echo -e "  0. 退出脚本"
    echo -e "============================================"
    read -p " 请输入选项 [0-9]: " num
    case "$num" in
        1) install_realm ;;
        2) uninstall_realm ;;
        3) add_forward ;;
        4) delete_forward ;;
        5) show_config_and_traffic ;;
        6) restart_realm ;;
        7) backup_nodes ;;
        8) restore_nodes ;;
        9) tcp_diag ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
}

while true; do
    show_menu
    echo -e ""
    read -p "按回车键返回主菜单..." 
done
