#!/bin/bash

# ==================================================
# Realm 一键端口转发管理脚本 (纯 SSH 终端交互版)
# 特性: 纯终端字符界面、TOML 配置精准读写、内建 TCPing 隧道握手测速、配置备份恢复
# ==================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
BOLD='\033[1m'

REALM_BIN_PATH="/usr/local/bin/realm"
WORK_DIR="/etc/realm"
REALM_CONFIG_PATH="${WORK_DIR}/config.toml"
REALM_SERVICE_PATH="/etc/systemd/system/realm.service"
BACKUP_DIR="/root/realm_backup"
DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/v2.9.2-2/realm-x86_64-unknown-linux-musl.tar.gz"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 检查基础依赖
check_dependencies() {
    local need_install=0
    for cmd in python3 wget tar; do
        if ! command -v $cmd >/dev/null 2>&1; then
            need_install=1
            break
        fi
    done

    if [ $need_install -eq 1 ]; then
        echo -e "${YELLOW}正在安装必要依赖环境 (python3, wget, tar)...${PLAIN}"
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y python3 wget tar >/dev/null 2>&1
        elif [ -x "$(command -v yum)" ]; then
            yum install -y python3 wget tar >/dev/null 2>&1
        fi
    fi
}

# 检查并初始化配置环境
init_env() {
    mkdir -p "$WORK_DIR"
    mkdir -p "$BACKUP_DIR"
    if [ ! -f "$REALM_CONFIG_PATH" ]; then
        cat > "$REALM_CONFIG_PATH" <<EOF
[network]
no_tcp = false
use_udp = true
zero_copy = true

[[endpoints]]
listen = "[::]:20000"
remote = "127.0.0.1:22000"
# remark: Realm示例
EOF
    elif ! grep -q "\[\[endpoints\]\]" "$REALM_CONFIG_PATH"; then
        cat >> "$REALM_CONFIG_PATH" <<EOF

[[endpoints]]
listen = "[::]:20000"
remote = "127.0.0.1:22000"
# remark: Realm示例
EOF
    fi
}

# 安装 / 重新安装 Realm 核心
install_realm() {
    clear
    echo -e "${SKYBLUE}==========================================${PLAIN}"
    echo -e "${BOLD}              安装 / 更新 Realm            ${PLAIN}"
    echo -e "${SKYBLUE}==========================================${PLAIN}"
    echo -e " 1. 在线拉取官方预编译包 (v2.9.2-2 musl)"
    echo -e " 2. 本地包安装 (需预先将压缩包上传至 /tmp/realm.tar.gz)"
    echo -e " 0. 返回主菜单"
    echo -e "${SKYBLUE}==========================================${PLAIN}"
    read -p "请输入选项 [0-2]: " method
    case "$method" in
        1)
            echo -e "${YELLOW}正在下载 Realm 二进制文件...${PLAIN}"
            wget -N --no-check-certificate "$DOWNLOAD_URL" -O /tmp/realm.tar.gz
            if [ $? -ne 0 ]; then
                echo -e "${RED}下载失败，请检查网络连接！${PLAIN}"
                return
            fi
            tar -zxvf /tmp/realm.tar.gz -C /tmp/ >/dev/null
            chmod +x /tmp/realm
            mv -f /tmp/realm "$REALM_BIN_PATH"
            rm -f /tmp/realm.tar.gz
            ;;
        2)
            if [ ! -f "/tmp/realm.tar.gz" ]; then
                echo -e "${RED}未在 /tmp/ 目录下找到 realm.tar.gz 文件！${PLAIN}"
                return
            fi
            tar -zxvf /tmp/realm.tar.gz -C /tmp/ >/dev/null
            chmod +x /tmp/realm
            mv -f /tmp/realm "$REALM_BIN_PATH"
            ;;
        0) return ;;
        *) echo -e "${RED}输入无效！${PLAIN}"; return ;;
    esac

    init_env

    # 注册 systemd 服务
    cat > "$REALM_SERVICE_PATH" <<EOF
[Unit]
Description=realm
After=network.target
Wants=network.target

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
    systemctl enable realm >/dev/null 2>&1
    systemctl restart realm
    echo -e "${GREEN}Realm 安装并配置成功，已设置为开机自启！${PLAIN}"
}

# 彻底卸载 Realm
uninstall_realm() {
    read -p "确定要彻底卸载 Realm 及其所有配置文件吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        systemctl stop realm >/dev/null 2>&1
        systemctl disable realm >/dev/null 2>&1
        rm -f "$REALM_SERVICE_PATH" "$REALM_BIN_PATH"
        rm -rf "$WORK_DIR"
        systemctl daemon-reload
        echo -e "${GREEN}Realm 已彻底从本机卸载！${PLAIN}"
    else
        echo -e "${YELLOW}操作已取消。${PLAIN}"
    fi
}

# 读取并列出所有转发节点
list_nodes() {
    python3 - <<EOF
import os

CFG_PATH = "$REALM_CONFIG_PATH"
if not os.path.exists(CFG_PATH):
    print("\033[0;33m暂无配置文件。\033[0m")
    exit(0)

with open(CFG_PATH, 'r') as f:
    content = f.read()

blocks = content.split('[[endpoints]]')
nodes = []
for b in blocks[1:]:
    node = {'remark': '无备注', 'listen': '', 'remote': ''}
    for line in b.split('\n'):
        line = line.strip()
        if line.startswith('# remark:'):
            node['remark'] = line.split(':', 1)[1].strip()
        elif line.startswith('listen'):
            node['listen'] = line.split('=')[1].strip().strip('"')
        elif line.startswith('remote'):
            node['remote'] = line.split('=')[1].strip().strip('"')
    if node['listen'] and node['remote']:
        nodes.append(node)

if not nodes:
    print("\033[0;33m当前未添加任何端口转发规则！\033[0m")
else:
    print(f"\033[1m{'ID':<4}{'备注':<18}{'本地监听 (Listen)':<22}{'远端目标 (Remote)':<22}\033[0m")
    print("-" * 66)
    for idx, n in enumerate(nodes, 1):
        print(f"{idx:<4}{n['remark']:<18}{n['listen']:<22}{n['remote']:<22}")
EOF
}

# 添加转发规则
add_node() {
    echo -e "${SKYBLUE}>>> 添加新的端口转发规则${PLAIN}"
    read -p "请输入备注信息 (如: 香港落地01): " remark
    remark=${remark:-"未命名节点"}

    read -p "请输入本地监听入口地址 (默认: [::]): " in_ip
    in_ip=${in_ip:-"[::]"}

    while true; do
        read -p "请输入本地监听端口 (1-65535): " in_port
        if [[ "$in_port" =~ ^[0-9]+$ ]] && [ "$in_port" -ge 1 ] && [ "$in_port" -le 65535 ]; then
            break
        else
            echo -e "${RED}端口格式不正确，请输入 1-65535 之间的整数！${PLAIN}"
        fi
    done

    while true; do
        read -p "请输入目标落地地址 (IP或域名): " out_ip
        [ -n "$out_ip" ] && break
        echo -e "${RED}目标地址不能为空！${PLAIN}"
    done

    while true; do
        read -p "请输入目标端口 (1-65535): " out_port
        if [[ "$out_port" =~ ^[0-9]+$ ]] && [ "$out_port" -ge 1 ] && [ "$out_port" -le 65535 ]; then
            break
        else
            echo -e "${RED}端口格式不正确，请输入 1-65535 之间的整数！${PLAIN}"
        fi
    done

    # 写入配置
    cat >> "$REALM_CONFIG_PATH" <<EOF

[[endpoints]]
listen = "${in_ip}:${in_port}"
remote = "${out_ip}:${out_port}"
# remark: ${remark}
EOF

    systemctl restart realm
    echo -e "${GREEN}转发规则添加成功并已重启生效！[${in_port} -> ${out_ip}:${out_port}]${PLAIN}"
}

# 修改现有规则
edit_node() {
    clear
    echo -e "${SKYBLUE}>>> 当前转发规则列表${PLAIN}"
    list_nodes
    echo ""
    read -p "请输入要修改的规则序号 (ID, 输入0取消): " edit_id
    [[ "$edit_id" == "0" || -z "$edit_id" ]] && return

    python3 - <<EOF
import sys

CFG_PATH = "$REALM_CONFIG_PATH"
with open(CFG_PATH, 'r') as f:
    content = f.read()

parts = content.split('[[endpoints]]')
header = parts[0]
blocks = parts[1:]

idx = int("$edit_id") - 1
if idx < 0 or idx >= len(blocks):
    print("\033[0;31m无效的规则序号！\033[0m")
    sys.exit(1)

target = blocks[idx]
node = {'remark': '', 'in_ip': '', 'in_port': '', 'out_ip': '', 'out_port': ''}
for line in target.split('\n'):
    line = line.strip()
    if line.startswith('# remark:'): node['remark'] = line.split(':', 1)[1].strip()
    elif line.startswith('listen'):
        val = line.split('=')[1].strip().strip('"')
        node['in_ip'], node['in_port'] = val.rsplit(':', 1)
    elif line.startswith('remote'):
        val = line.split('=')[1].strip().strip('"')
        node['out_ip'], node['out_port'] = val.rsplit(':', 1)

print(f"\n当前备注: {node['remark']}")
nr = input("输入新备注 (回车保持不变): ").strip()
if nr: node['remark'] = nr

print(f"当前监听端口: {node['in_port']}")
np = input("输入新本地端口 (回车保持不变): ").strip()
if np: node['in_port'] = np

print(f"当前目标地址: {node['out_ip']}")
nip = input("输入新目标地址 (回车保持不变): ").strip()
if nip: node['out_ip'] = nip

print(f"当前目标端口: {node['out_port']}")
nop = input("输入新目标端口 (回车保持不变): ").strip()
if nop: node['out_port'] = nop

new_block = f'\nlisten = "{node["in_ip"]}:{node["in_port"]}"\nremote = "{node["out_ip"]}:{node["out_port"]}"\n# remark: {node["remark"]}\n'
blocks[idx] = new_block

with open(CFG_PATH, 'w') as f:
    f.write(header + '[[endpoints]]'.join([''] + blocks))

print("\033[0;32m规则修改完成！\033[0m")
EOF
    if [ $? -eq 0 ]; then
        systemctl restart realm
        echo -e "${GREEN}服务已重启生效。${PLAIN}"
    fi
}

# 删除规则
del_node() {
    clear
    echo -e "${SKYBLUE}>>> 当前转发规则列表${PLAIN}"
    list_nodes
    echo ""
    read -p "请输入要删除的规则序号 (ID, 输入0取消): " del_id
    [[ "$del_id" == "0" || -z "$del_id" ]] && return

    python3 - <<EOF
import sys

CFG_PATH = "$REALM_CONFIG_PATH"
with open(CFG_PATH, 'r') as f:
    content = f.read()

parts = content.split('[[endpoints]]')
header = parts[0]
blocks = parts[1:]

idx = int("$del_id") - 1
if idx < 0 or idx >= len(blocks):
    print("\033[0;31m无效的规则序号！\033[0m")
    sys.exit(1)

del blocks[idx]

with open(CFG_PATH, 'w') as f:
    if blocks:
        f.write(header + '[[endpoints]]' + '[[endpoints]]'.join(blocks))
    else:
        f.write(header.strip() + '\n')

print("\033[0;32m规则已成功移除！\033[0m")
EOF
    if [ $? -eq 0 ]; then
        systemctl restart realm
        echo -e "${GREEN}Realm 服务已重启同步配置。${PLAIN}"
    fi
}

# ================= 内置 Python TCPing 引擎 =================
run_tcping() {
    local target_ip="$1"
    local target_port="$2"
    local count="${3:-4}"

    python3 - <<EOF
import socket, time, sys

ip = "$target_ip"
port = int("$target_port")
count = int("$count")

print(f"\n\033[1;36m正在对 [{ip}:{port}] 发起 TCPing 握手探测 (共 {count} 次)...\033[0m")
delays = []
success = 0

for i in range(1, count + 1):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(2.0)
    start_time = time.time()
    try:
        s.connect((ip, port))
        elapsed = (time.time() - start_time) * 1000
        delays.append(elapsed)
        success += 1
        print(f"序号 {i}: 握手成功 -> 来源到目标端口 RTT = \033[0;32m{elapsed:.2f} ms\033[0m")
        s.close()
    except socket.timeout:
        print(f"序号 {i}: \033[0;31m连接超时 (Connection Timeout)\033[0m")
    except ConnectionRefusedError:
        print(f"序号 {i}: \033[0;31m端口拒绝连接 (Connection Refused)\033[0m")
    except Exception as e:
        print(f"序号 {i}: \033[0;31m连接失败 ({e})\033[0m")
    time.sleep(0.3)

loss_rate = int(((count - success) / count) * 100)
print("-" * 50)
print(f"TCPing 统计结果: 已发送 = {count}, 成功 = {success}, 失败 = {count - success}, 丢包率 = {loss_rate}%")
if delays:
    min_delay = min(delays)
    max_delay = max(delays)
    avg_delay = sum(delays) / len(delays)
    print(f"RTT 延迟数据: 最短 = {min_delay:.2f}ms, 最长 = {max_delay:.2f}ms, 平均 = \033[1;32m{avg_delay:.2f}ms\033[0m")
else:
    print("\033[0;31m提示: 无法完成任何 TCP 三次握手，请检查目标主机防火墙、安全组或落地服务状态！\033[0m")
print("-" * 50)
EOF
}

# TCPing 诊断主菜单
tcping_menu() {
    clear
    echo -e "${SKYBLUE}==========================================${PLAIN}"
    echo -e "${BOLD}           TCPing 连通性测试诊断          ${PLAIN}"
    echo -e "${SKYBLUE}==========================================${PLAIN}"
    echo -e " 1. 测试现有规则中的 ${GREEN}本地转发端口${PLAIN} (验证本机 Realm 监听是否畅通)"
    echo -e " 2. 测试现有规则中的 ${GREEN}远端落地目标${PLAIN} (验证本机到落地服务器连通性)"
    echo -e " 3. 自定义 IP/域名与端口测试"
    echo -e " 0. 返回主菜单"
    echo -e "${SKYBLUE}==========================================${PLAIN}"
    read -p "请输入选项 [0-3]: " opt
    case "$opt" in
        1)
            list_nodes
            echo ""
            read -p "请输入要测试的规则 ID: " nid
            [ -z "$nid" ] && return
            local port=$(python3 -c "
import sys
blocks = open('$REALM_CONFIG_PATH').read().split('[[endpoints]]')[1:]
try:
    target = blocks[int('$nid') - 1]
    for line in target.split('\n'):
        if line.strip().startswith('listen'):
            print(line.split('=')[1].strip().strip('\"').rsplit(':', 1)[1])
            break
except: pass
")
            if [ -n "$port" ]; then
                run_tcping "127.0.0.1" "$port" 4
            else
                echo -e "${RED}无法定位对应规则的监听端口！${PLAIN}"
            fi
            ;;
        2)
            list_nodes
            echo ""
            read -p "请输入要测试的规则 ID: " nid
            [ -z "$nid" ] && return
            local remote_info=$(python3 -c "
import sys
blocks = open('$REALM_CONFIG_PATH').read().split('[[endpoints]]')[1:]
try:
    target = blocks[int('$nid') - 1]
    for line in target.split('\n'):
        if line.strip().startswith('remote'):
            r = line.split('=')[1].strip().strip('\"')
            ip, port = r.rsplit(':', 1)
            print(f'{ip} {port}')
            break
except: pass
")
            if [ -n "$remote_info" ]; then
                local r_ip=$(echo $remote_info | awk '{print $1}')
                local r_port=$(echo $remote_info | awk '{print $2}')
                run_tcping "$r_ip" "$r_port" 4
            else
                echo -e "${RED}无法定位对应规则的远端目标！${PLAIN}"
            fi
            ;;
        3)
            read -p "请输入目标 IP 或 域名: " c_ip
            read -p "请输入目标端口: " c_port
            if [[ -n "$c_ip" && "$c_port" =~ ^[0-9]+$ ]]; then
                run_tcping "$c_ip" "$c_port" 4
            else
                echo -e "${RED}输入的 IP 或端口格式不合法！${PLAIN}"
            fi
            ;;
        0) return ;;
        *) echo -e "${RED}无效选项！${PLAIN}" ;;
    esac
}

# 备份与恢复
backup_nodes() {
    mkdir -p "$BACKUP_DIR"
    local fname="realm_backup_$(date +%Y%m%d_%H%M%S).toml"
    cp "$REALM_CONFIG_PATH" "$BACKUP_DIR/$fname"
    echo -e "${GREEN}当前规则已备份至: $BACKUP_DIR/$fname${PLAIN}"
}

restore_nodes() {
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo -e "${RED}未找到任何备份文件！${PLAIN}"
        return
    fi
    echo -e "${SKYBLUE}可用的备份文件列表:${PLAIN}"
    local i=1
    local files=()
    for f in "$BACKUP_DIR"/*.toml; do
        files[$i]=$f
        echo -e " ${GREEN}${i}.${PLAIN} $(basename "$f")"
        ((i++))
    done
    echo ""
    read -p "请输入恢复序号 (1-$((i-1)), 输入0取消): " s_id
    [[ "$s_id" == "0" || -z "$s_id" ]] && return
    if [[ "$s_id" =~ ^[0-9]+$ ]] && [ "$s_id" -ge 1 ] && [ "$s_id" -lt $i ]; then
        cp "${files[$s_id]}" "$REALM_CONFIG_PATH"
        systemctl restart realm
        echo -e "${GREEN}配置已成功恢复并重启生效！${PLAIN}"
    else
        echo -e "${RED}序号无效！${PLAIN}"
    fi
}

# 服务控制
service_control() {
    clear
    echo -e "${SKYBLUE}==========================================${PLAIN}"
    echo -e "${BOLD}              Realm 服务控制              ${PLAIN}"
    echo -e "${SKYBLUE}==========================================${PLAIN}"
    echo -e " 1. 启动 Realm"
    echo -e " 2. 停止 Realm"
    echo -e " 3. 重启 Realm"
    echo -e " 4. 查看 Systemd 详细日志 (按 q 退出日志)"
    echo -e " 0. 返回主菜单"
    echo -e "${SKYBLUE}==========================================${PLAIN}"
    read -p "请输入选项 [0-4]: " s_opt
    case "$s_opt" in
        1) systemctl start realm && echo -e "${GREEN}已启动！${PLAIN}" ;;
        2) systemctl stop realm && echo -e "${YELLOW}已停止！${PLAIN}" ;;
        3) systemctl restart realm && echo -e "${GREEN}已重启！${PLAIN}" ;;
        4) journalctl -u realm -n 30 --no-pager ;;
        0) return ;;
        *) echo -e "${RED}无效选项！${PLAIN}" ;;
    esac
}

# 主菜单
main_menu() {
    check_dependencies
    init_env

    while true; do
        clear
        echo -e "${SKYBLUE}======================================================${PLAIN}"
        echo -e "${BOLD}             Realm 端口转发管理面板 (纯终端版)        ${PLAIN}"
        echo -e "${SKYBLUE}======================================================${PLAIN}"
        
        # 状态展示
        if [ -f "$REALM_BIN_PATH" ]; then
            if systemctl is-active --quiet realm; then
                echo -e "核心状态: ${GREEN}● 运行中${PLAIN}  |  开机自启: $(systemctl is-enabled realm 2>/dev/null || echo '未配置')"
            else
                echo -e "核心状态: ${RED}○ 未运行${PLAIN}  |  开机自启: $(systemctl is-enabled realm 2>/dev/null || echo '未配置')"
            fi
        else
            echo -e "核心状态: ${YELLOW}未安装 Realm${PLAIN}"
        fi
        echo -e "${SKYBLUE}------------------------------------------------------${PLAIN}"
        echo -e " ${BOLD}转发管理:${PLAIN}"
        echo -e "   ${GREEN}1.${PLAIN} 查看已有转发规则"
        echo -e "   ${GREEN}2.${PLAIN} 添加端口转发规则"
        echo -e "   ${GREEN}3.${PLAIN} 修改已有转发规则"
        echo -e "   ${GREEN}4.${PLAIN} 删除指定转发规则"
        echo -e "${SKYBLUE}------------------------------------------------------${PLAIN}"
        echo -e " ${BOLD}诊断与测试:${PLAIN}"
        echo -e "   ${GREEN}5.${PLAIN} ${BOLD}TCPing 隧道连通性握手测试${PLAIN} (测入口/测远端)"
        echo -e "${SKYBLUE}------------------------------------------------------${PLAIN}"
        echo -e " ${BOLD}系统与维护:${PLAIN}"
        echo -e "   ${GREEN}6.${PLAIN} Realm 服务控制 (启动/停止/重启/查看日志)"
        echo -e "   ${GREEN}7.${PLAIN} 备份当前规则"
        echo -e "   ${GREEN}8.${PLAIN} 恢复规则备份"
        echo -e "   ${GREEN}9.${PLAIN} 安装 / 更新 Realm"
        echo -e "   ${GREEN}10.${PLAIN} 彻底卸载 Realm"
        echo -e "   ${GREEN}0.${PLAIN} 退出脚本"
        echo -e "${SKYBLUE}======================================================${PLAIN}"
        read -p " 请输入选项 [0-10]: " choice

        case "$choice" in
            1) clear; echo -e "${SKYBLUE}>>> 转发规则列表${PLAIN}"; list_nodes ;;
            2) clear; add_node ;;
            3) edit_node ;;
            4) del_node ;;
            5) tcping_menu ;;
            6) service_control ;;
            7) backup_nodes ;;
            8) restore_nodes ;;
            9) install_realm ;;
            10) uninstall_realm ;;
            0) exit 0 ;;
            *) echo -e "${RED}请输入正确的选项！${PLAIN}" ;;
        esac
        echo ""
        read -p "按回车键返回主菜单..." dummy
    done
}

main_menu
