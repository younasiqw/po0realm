#!/bin/bash

# ==================================================
# Realm 一键转发管理脚本
# 支持系统: Ubuntu/Debian/CentOS
# 说明: 适配 /tmp 目录本地安装包
# ==================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 变量定义
# 指定的下载链接和文件名
DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/v2.6.0/realm-x86_64-unknown-linux-musl.tar.gz"
FILE_NAME="realm-x86_64-unknown-linux-musl.tar.gz"
LOCAL_PKG_PATH="/tmp/${FILE_NAME}"

REALM_BIN_PATH="/usr/local/bin/realm"
REALM_CONFIG_PATH="/etc/realm/config.toml"
REALM_SERVICE_PATH="/etc/systemd/system/realm.service"
WORK_DIR="/etc/realm"

# 检查是否为 Root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 1. 安装 Realm
install_realm() {
    # 检查是否已安装
    if [ -f "$REALM_BIN_PATH" ]; then
        echo -e "${YELLOW}检测到 Realm 已安装，跳过安装步骤。${PLAIN}"
    else
        echo -e "${GREEN}选择安装方式:${PLAIN}"
        echo -e " 1. 在线下载安装 (使用预设 v2.6.0 musl 链接)"
        echo -e " 2. 本地文件安装 (请先将 $FILE_NAME 上传至 /tmp 目录)"
        read -p "请输入选项 [1-2]: " install_method

        if [ "$install_method" == "1" ]; then
            # 在线下载逻辑
            echo -e "${GREEN}正在下载 Realm...${PLAIN}"
            wget -N --no-check-certificate "$DOWNLOAD_URL" -O "$FILE_NAME"
            
            if [ $? -ne 0 ]; then
                echo -e "${RED}下载失败，请检查网络或尝试本地安装。${PLAIN}"
                rm -f "$FILE_NAME"
                return
            fi
            
            echo -e "${GREEN}正在解压...${PLAIN}"
            tar -xvf "$FILE_NAME"
            chmod +x realm
            mv realm "$REALM_BIN_PATH"
            rm -f "$FILE_NAME"

        elif [ "$install_method" == "2" ]; then
            # 本地安装逻辑 - 针对 /tmp 目录
            if [ -f "$LOCAL_PKG_PATH" ]; then
                echo -e "${GREEN}检测到 /tmp 目录下存在安装包，开始安装...${PLAIN}"
                
                # 解压到 /tmp 并提取 realm 二进制文件
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
                echo -e "${YELLOW}请确认文件已上传且名称完全一致。${PLAIN}"
                return
            fi
        else
            echo -e "${RED}无效选项${PLAIN}"
            return
        fi
    fi

    # 创建配置目录和基础配置文件
    # 修复核心：必须添加至少一个 endpoints 块，否则 realm 会 panic
    mkdir -p "$WORK_DIR"
    if [ ! -f "$REALM_CONFIG_PATH" ]; then
        echo -e "${GREEN}生成默认配置 (包含一条默认本地规则以防止启动崩溃)...${PLAIN}"
        cat > "$REALM_CONFIG_PATH" <<EOF
[network]
no_tcp = false
use_udp = true

# 默认占位规则，防止服务启动崩溃，可稍后删除
[[endpoints]]
listen = "127.0.0.1:20000"
remote = "1.1.1.1:443"
EOF
    fi

    # 创建 Systemd 服务
    # 去掉了 Wants=network-online.target 防止防火墙卡死
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
    
    echo -e "${GREEN}正在启动服务...${PLAIN}"
    systemctl start realm
    
    sleep 1
    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}Realm 安装并启动成功！${PLAIN}"
    else
        echo -e "${RED}Realm 启动失败，请检查日志 (journalctl -u realm)${PLAIN}"
    fi
}

# 2. 卸载 Realm
uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f "$REALM_SERVICE_PATH"
    rm -f "$REALM_BIN_PATH"
    rm -rf "$WORK_DIR"
    systemctl daemon-reload
    echo -e "${GREEN}Realm 已彻底卸载并删除开机自启。${PLAIN}"
}

# 3. 添加转发
add_forward() {
    if [ ! -f "$REALM_CONFIG_PATH" ]; then
        echo -e "${RED}Realm 未安装或配置文件丢失！${PLAIN}"
        return
    fi

    echo -e "${GREEN}=== 添加转发规则 ===${PLAIN}"
    echo -e "${YELLOW}注意: 本机已封禁端口 (80,443等)，请使用高位端口 (如 10000-60000)${PLAIN}"
    read -p "请输入本地监听端口 (例如 20000): " listen_port
    read -p "请输入目标 IP (例如 1.1.1.1): " remote_ip
    read -p "请输入目标端口 (例如 443): " remote_port

    # 追加写入配置
    cat >> "$REALM_CONFIG_PATH" <<EOF

[[endpoints]]
listen = "0.0.0.0:$listen_port"
remote = "$remote_ip:$remote_port"
EOF

    restart_realm
    echo -e "${GREEN}转发规则已添加: 0.0.0.0:$listen_port -> $remote_ip:$remote_port (TCP+UDP)${PLAIN}"
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

    # 显示列表
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

    if [ "$delete_index" == "0" ] || [ -z "$delete_index" ]; then
        return
    fi

    # 检查是否删除了最后一条规则
    if [ "$rules_count" -eq 1 ]; then
        echo -e "${RED}警告: Realm 必须至少保留一条规则才能运行。${PLAIN}"
        echo -e "${YELLOW}如果删除了最后一条规则，服务将无法启动。${PLAIN}"
        read -p "是否确定清空并让服务停止? (y/n): " confirm
        if [ "$confirm" != "y" ]; then return; fi
    fi

    # 使用 awk 删除指定的 block
    awk -v target="$delete_index" '
    BEGIN { count=0; print_block=1 }
    /^\[\[endpoints\]\]/ {
        count++
        if (count == target) {
            print_block=0
        } else {
            print_block=1
        }
    }
    {
        if (print_block == 1) print $0
    }
    ' "$REALM_CONFIG_PATH" > "${REALM_CONFIG_PATH}.tmp" && mv "${REALM_CONFIG_PATH}.tmp" "$REALM_CONFIG_PATH"

    # 清理连续空行
    sed -i '/^$/N;/^\n$/D' "$REALM_CONFIG_PATH"
    
    restart_realm
    echo -e "${GREEN}规则已删除！${PLAIN}"
}

# 重启服务
restart_realm() {
    systemctl restart realm
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}服务已重启生效。${PLAIN}"
    else
        echo -e "${RED}服务重启失败，请检查配置！${PLAIN}"
        systemctl status realm
    fi
}

# 显示状态
show_status() {
    if systemctl is-active --quiet realm; then
        echo -e "Realm 状态: ${GREEN}运行中${PLAIN}"
    else
        echo -e "Realm 状态: ${RED}未运行${PLAIN}"
    fi
}

# 主菜单
show_menu() {
    clear
    echo -e "============================================"
    echo -e "           Realm 转发管理脚本               "
    echo -e "============================================"
    show_status
    echo -e "--------------------------------------------"
    echo -e "  1. 安装 Realm 转发并开机自启"
    echo -e "  2. 卸载 Realm 转发并删除自启"
    echo -e "  3. 添加转发规则 (TCP+UDP)"
    echo -e "  4. 删除转发规则 (列表显示)"
    echo -e "  5. 查看当前配置"
    echo -e "  6. 重启 Realm 服务"
    echo -e "  0. 退出脚本"
    echo -e "============================================"
    read -p " 请输入选项 [0-6]: " num

    case "$num" in
        1) install_realm ;;
        2) uninstall_realm ;;
        3) add_forward ;;
        4) delete_forward ;;
        5) cat "$REALM_CONFIG_PATH" && read -p "按回车继续..." ;;
        6) restart_realm ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入${PLAIN}" ;;
    esac
}

# 循环运行菜单
while true; do
    show_menu
    echo -e ""
    read -p "按回车键返回主菜单..." 
done
