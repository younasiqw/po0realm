#!/bin/bash

# ==================================================
# Realm 一键转发管理脚本 (Web面板 终极完全体)
# 说明: 真实TOML读写、真实TCP测速、iptables精准单端口流量、Token鉴权
# ==================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/v2.6.0/realm-x86_64-unknown-linux-musl.tar.gz"
FILE_NAME="realm-x86_64-unknown-linux-musl.tar.gz"
LOCAL_PKG_PATH="/tmp/${FILE_NAME}"

REALM_BIN_PATH="/usr/local/bin/realm"
REALM_CONFIG_PATH="/etc/realm/config.toml"
REALM_SERVICE_PATH="/etc/systemd/system/realm.service"
WORK_DIR="/etc/realm"

PANEL_DIR="/etc/realm/panel"
PANEL_PORT=31337 # Web 网页端面板默认监听端口
PANEL_SERVICE_PATH="/etc/systemd/system/realm-panel.service"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

install_panel() {
    echo -e "${GREEN}正在部署 Web 可视化面板与环境...${PLAIN}"
    # 确保基础环境
    if [ -x "$(command -v apt-get)" ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y python3 iptables >/dev/null 2>&1
    elif [ -x "$(command -v yum)" ]; then
        yum install -y python3 iptables >/dev/null 2>&1
    fi

    mkdir -p "$PANEL_DIR"

    # 初始化鉴权与流量文件
    if [ ! -f "$PANEL_DIR/auth.json" ]; then
        echo '{"username": "admin", "password": "admin"}' > "$PANEL_DIR/auth.json"
    fi
    if [ ! -f "$PANEL_DIR/traffic.json" ]; then
        echo '{"month": "", "nodes": {}, "hourly": {}}' > "$PANEL_DIR/traffic.json"
    fi

    # ================= HTML 前端页面 =================
    cat > "$PANEL_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Realm 转发管理面板</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        :root { --primary-color: #4CAF50; --primary-dark: #388E3C; --sidebar-bg: #2c3e50; --sidebar-hover: #34495e; --danger-color: #e74c3c; --info-color: #3498db; --warning-color: #f39c12; --bg-color: #f4f7f6; --card-bg: #ffffff; --text-color: #333; --text-muted: #7f8c8d; }
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; }
        body { background-color: var(--bg-color); color: var(--text-color); display: flex; height: 100vh; overflow: hidden; }
        #login-wrapper { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: var(--sidebar-bg); display: flex; justify-content: center; align-items: center; z-index: 1000; }
        .login-box { background: var(--card-bg); padding: 40px; border-radius: 12px; box-shadow: 0 10px 25px rgba(0,0,0,0.2); width: 100%; max-width: 380px; text-align: center; }
        .login-box h2 { margin-bottom: 25px; color: var(--sidebar-bg); }
        .form-group { margin-bottom: 20px; text-align: left; }
        .form-group label { display: block; margin-bottom: 8px; font-weight: 600; color: #555; font-size: 14px; }
        .form-group input { width: 100%; padding: 12px; border: 1px solid #ccc; border-radius: 6px; font-size: 14px; outline: none; }
        .btn { width: 100%; padding: 12px; border: none; border-radius: 6px; font-size: 15px; font-weight: 600; cursor: pointer; color: white; transition: 0.3s; }
        .btn-primary { background: var(--primary-color); }
        .btn-danger { background: var(--danger-color); }
        .btn-info { background: var(--info-color); }
        .btn-warning { background: var(--warning-color); }
        .btn-small { padding: 6px 12px; font-size: 13px; width: auto; }
        #app-wrapper { display: none; width: 100%; height: 100%; }
        .sidebar { width: 250px; background: var(--sidebar-bg); color: white; display: flex; flex-direction: column; }
        .sidebar-header { padding: 20px; text-align: center; font-size: 20px; font-weight: bold; border-bottom: 1px solid #1a252f; }
        .nav-menu { flex: 1; padding: 20px 0; }
        .nav-item { padding: 15px 25px; cursor: pointer; font-size: 16px; border-left: 4px solid transparent; }
        .nav-item.active { background: var(--sidebar-hover); border-left-color: var(--primary-color); color: var(--primary-color); font-weight: bold; }
        .main-content { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
        .header { height: 70px; background: var(--card-bg); display: flex; justify-content: space-between; align-items: center; padding: 0 30px; box-shadow: 0 2px 10px rgba(0,0,0,0.05); }
        .status-badge { padding: 6px 12px; border-radius: 20px; font-size: 13px; font-weight: bold; color: white; background: var(--primary-color); }
        .content-body { flex: 1; padding: 30px; overflow-y: auto; }
        .view-section { display: none; }
        .view-section.active { display: block; }
        .card { background: var(--card-bg); border-radius: 10px; padding: 20px; margin-bottom: 25px; box-shadow: 0 4px 15px rgba(0,0,0,0.03); }
        .card-title { font-size: 16px; font-weight: 600; margin-bottom: 20px; color: var(--sidebar-bg); border-bottom: 2px solid #f0f0f0; padding-bottom: 10px; }
        .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 25px; }
        .stat-card { background: var(--card-bg); border-radius: 10px; padding: 25px 20px; text-align: center; box-shadow: 0 4px 15px rgba(0,0,0,0.03); }
        .stat-value { font-size: 36px; font-weight: bold; color: var(--primary-color); margin: 10px 0; }
        .stat-label { font-size: 14px; color: var(--text-muted); }
        .chart-container { position: relative; height: 350px; width: 100%; }
        .node-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 20px; }
        .node-card { background: var(--card-bg); border-radius: 10px; padding: 20px; border-top: 4px solid var(--info-color); box-shadow: 0 4px 15px rgba(0,0,0,0.05); }
        .node-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px; }
        .node-remark { font-weight: bold; font-size: 16px; color: var(--sidebar-bg); }
        .node-traffic { font-size: 12px; color: var(--text-muted); background: #f0f4f8; padding: 4px 8px; border-radius: 4px; }
        .node-info-line { font-size: 14px; margin-bottom: 8px; color: #555; }
        .node-actions { display: flex; gap: 8px; margin-top: 15px; padding-top: 15px; border-top: 1px dashed #eee; }
        .inline-form { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 15px; align-items: flex-end; }
        
        .modal-overlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.5); z-index: 2000; display: none; justify-content: center; align-items: center; }
        .modal { background: var(--card-bg); width: 100%; max-width: 400px; border-radius: 12px; overflow: hidden; transform: scale(0.9); transition: 0.2s; opacity: 0; }
        .modal.show { transform: scale(1); opacity: 1; }
        .modal-header { padding: 15px 20px; background: #f8f9fa; font-weight: bold; display: flex; justify-content: space-between; border-bottom: 1px solid #eee; }
        .modal-close { cursor: pointer; color: #888; font-size: 18px; }
        .modal-body { padding: 20px; font-size: 14px; }
        .modal-footer { padding: 15px 20px; border-top: 1px solid #eee; display: flex; justify-content: flex-end; gap: 10px; }
        .loader { border: 3px solid #f3f3f3; border-top: 3px solid var(--primary-color); border-radius: 50%; width: 24px; height: 24px; animation: spin 1s linear infinite; margin: 10px auto; display: none; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
    </style>
</head>
<body>
    <div id="login-wrapper">
        <div class="login-box">
            <h2>Realm 管理面板</h2>
            <div class="form-group"><label>用户名</label><input type="text" id="username"></div>
            <div class="form-group"><label>密码</label><input type="password" id="password"></div>
            <button class="btn btn-primary" onclick="login()">安全登录</button>
            <p id="login-error" style="color: var(--danger-color); margin-top: 15px; display: none;">凭证错误！</p>
        </div>
    </div>
    <div id="app-wrapper">
        <div class="sidebar">
            <div class="sidebar-header">Realm Panel</div>
            <div class="nav-menu">
                <div class="nav-item active" onclick="switchNav('dashboard')">📊 仪表盘</div>
                <div class="nav-item" onclick="switchNav('forwarding')">⚡ 转发管理</div>
                <div class="nav-item" onclick="switchNav('settings')">⚙️ 面板设置</div>
            </div>
        </div>
        <div class="main-content">
            <div class="header">
                <div style="font-size: 20px; font-weight: bold; color: #2c3e50;">Realm Dashboard</div>
                <div><span>状态: <span class="status-badge" id="status-badge">运行中</span></span> <button class="btn btn-danger btn-small" style="margin-left:15px;" onclick="logout()">退出登录</button></div>
            </div>
            <div class="content-body">
                <div id="view-dashboard" class="view-section active">
                    <div class="grid-2">
                        <div class="stat-card"><div class="stat-label">总计使用流量 (当月)</div><div class="stat-value" id="total-traffic">0 GB</div></div>
                        <div class="stat-card"><div class="stat-label">已启用转发节点</div><div class="stat-value" id="node-count">0 个</div></div>
                    </div>
                    <div class="card">
                        <div class="card-title">24小时节点总流量统计 (GB)</div>
                        <div class="chart-container"><canvas id="trafficChart"></canvas></div>
                    </div>
                    <div class="card">
                        <div class="card-title">快捷指令操作</div>
                        <div style="display: flex; gap: 15px;">
                            <button class="btn btn-primary btn-small" onclick="showInstallModal()">重置/安装</button>
                            <button class="btn btn-warning btn-small" onclick="apiCall('/api/sys', {action:'stop'})">停止 Realm</button>
                            <button class="btn btn-info btn-small" onclick="apiCall('/api/sys', {action:'restart'})">重启 Realm</button>
                        </div>
                    </div>
                </div>
                <div id="view-forwarding" class="view-section">
                    <div class="card">
                        <div class="card-title">➕ 添加转发节点</div>
                        <div class="inline-form">
                            <div class="form-group"><label>备注信息</label><input type="text" id="add-r" placeholder="如: 日本流媒体"></div>
                            <div class="form-group"><label>入口地址</label><input type="text" id="add-in" placeholder="[::]"></div>
                            <div class="form-group"><label>监听端口</label><input type="number" id="add-in-p" placeholder="20000"></div>
                            <div class="form-group"><label>目标地址</label><input type="text" id="add-out" placeholder="1.1.1.1"></div>
                            <div class="form-group"><label>目标端口</label><input type="number" id="add-out-p" placeholder="443"></div>
                            <button class="btn btn-primary" style="margin-bottom: 20px;" onclick="addNode()">确认添加</button>
                        </div>
                    </div>
                    <div class="card-title" style="margin-top: 10px; border:none;">🌟 已有转发节点</div>
                    <div class="node-grid" id="node-list"></div>
                </div>
                <div id="view-settings" class="view-section">
                    <div class="card" style="max-width: 400px;">
                        <div class="card-title">修改登录凭证</div>
                        <div class="form-group"><label>新用户名</label><input type="text" id="new-u"></div>
                        <div class="form-group"><label>新密码</label><input type="password" id="new-p"></div>
                        <button class="btn btn-primary" onclick="changeAuth()">保存修改</button>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <div class="modal-overlay" id="g-modal">
        <div class="modal" id="g-modal-box">
            <div class="modal-header"><span id="m-title">提示</span><span class="modal-close" onclick="closeM()">×</span></div>
            <div class="modal-body" id="m-body"></div>
            <div class="modal-footer" id="m-footer"></div>
        </div>
    </div>

    <script>
        let chartInst = null;
        const getToken = () => localStorage.getItem('realm_token');

        function login() {
            fetch('/api/login', { method:'POST', body:JSON.stringify({u:document.getElementById('username').value, p:document.getElementById('password').value}) })
            .then(r => r.json()).then(d => {
                if(d.token) { localStorage.setItem('realm_token', d.token); initApp(); }
                else { document.getElementById('login-error').style.display = 'block'; }
            });
        }

        function logout() { localStorage.removeItem('realm_token'); location.reload(); }

        function apiCall(url, data, method='POST') {
            return fetch(url, { method:method, headers:{'Authorization': getToken()}, body: data ? JSON.stringify(data) : null })
            .then(r => { if(r.status===401) logout(); return r.json(); });
        }

        function switchNav(id) {
            document.querySelectorAll('.nav-item').forEach(e => e.classList.remove('active'));
            event.target.classList.add('active');
            document.querySelectorAll('.view-section').forEach(e => e.classList.remove('active'));
            document.getElementById('view-'+id).classList.add('active');
        }

        function initApp() {
            if(!getToken()){ document.getElementById('login-wrapper').style.display='flex'; return; }
            document.getElementById('login-wrapper').style.display='none';
            document.getElementById('app-wrapper').style.display='flex';
            loadData();
            setInterval(loadData, 30000); // 30秒自动刷新流量
        }

        function loadData() {
            apiCall('/api/data', null, 'GET').then(d => {
                // 渲染图表
                if(!chartInst) {
                    chartInst = new Chart(document.getElementById('trafficChart').getContext('2d'), {
                        type: 'line', data: { labels: d.chart_labels, datasets: [{ label: '节点总流量', data: d.chart_data, borderColor: '#4CAF50', backgroundColor: 'rgba(76, 175, 80, 0.1)', fill: true }] },
                        options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { display: false }, tooltip: { callbacks: { title: c => '当前时间：' + c[0].label, label: c => '已消耗流量：' + c.parsed.y + ' GB' } } } }
                    });
                } else {
                    chartInst.data.labels = d.chart_labels; chartInst.data.datasets[0].data = d.chart_data; chartInst.update();
                }

                // 渲染统计
                document.getElementById('total-traffic').innerText = d.total_gb + ' GB';
                document.getElementById('node-count').innerText = d.nodes.length + ' 个';

                // 渲染节点
                const nl = document.getElementById('node-list');
                nl.innerHTML = '';
                d.nodes.forEach(n => {
                    nl.innerHTML += `
                        <div class="node-card">
                            <div class="node-header"><span class="node-remark">${n.remark || '未命名节点'}</span><span class="node-traffic">${n.gb} GB</span></div>
                            <div class="node-info-line"><strong>入口：</strong>${n.inIp}:${n.inPort}</div>
                            <div class="node-info-line"><strong>目标：</strong>${n.outIp}:${n.outPort}</div>
                            <div class="node-actions">
                                <button class="btn btn-info btn-small" onclick="editNode('${n.inPort}', '${n.remark}', '${n.outIp}', '${n.outPort}')">编辑</button>
                                <button class="btn btn-warning btn-small" onclick="diagNode('${n.outIp}', ${n.outPort})">诊断</button>
                                <button class="btn btn-danger btn-small" onclick="delNode('${n.inPort}')">删除</button>
                            </div>
                        </div>`;
                });
            });
        }

        function addNode() {
            const data = { r:document.getElementById('add-r').value, inIp:document.getElementById('add-in').value||'[::]', inPort:document.getElementById('add-in-p').value, outIp:document.getElementById('add-out').value, outPort:document.getElementById('add-out-p').value };
            if(!data.inPort || !data.outIp || !data.outPort) return showM("提示", "信息不全！");
            apiCall('/api/node', data, 'POST').then(d => { showM("成功", d.msg); loadData(); });
        }

        function delNode(port) {
            document.getElementById('m-title').innerText = '删除确认';
            document.getElementById('m-body').innerHTML = '<p style="color:red;font-weight:bold;">警告：即将删除监听端口为 '+port+' 的节点！</p>';
            document.getElementById('m-footer').innerHTML = `<button class="btn btn-small" style="background:#ddd;color:#333;" onclick="closeM()">取消</button> <button class="btn btn-danger btn-small" onclick="doDel('${port}')">确认删除</button>`;
            openM();
        }
        function doDel(port) { apiCall('/api/node', {port:port}, 'DELETE').then(d=>{ closeM(); loadData(); }); }

        function editNode(port, r, outIp, outPort) {
            document.getElementById('m-title').innerText = '编辑节点 (仅支持修改目标与备注)';
            document.getElementById('m-body').innerHTML = `
                <div class="form-group"><label>备注</label><input type="text" id="e-r" value="${r}"></div>
                <div class="form-group"><label>目标地址</label><input type="text" id="e-ip" value="${outIp}"></div>
                <div class="form-group"><label>目标端口</label><input type="number" id="e-p" value="${outPort}"></div>`;
            document.getElementById('m-footer').innerHTML = `<button class="btn btn-small" style="background:#ddd;color:#333;" onclick="closeM()">取消</button> <button class="btn btn-primary btn-small" onclick="doEdit('${port}')">保存</button>`;
            openM();
        }
        function doEdit(port) {
            apiCall('/api/node', { port:port, r:document.getElementById('e-r').value, outIp:document.getElementById('e-ip').value, outPort:document.getElementById('e-p').value }, 'PUT')
            .then(d=>{ closeM(); loadData(); });
        }

        function diagNode(ip, port) {
            document.getElementById('m-title').innerText = 'TCP 诊断';
            document.getElementById('m-body').innerHTML = `<div style="text-align:center;"><p>正在执行 5 次 TCP 握手...</p><div class="loader" style="display:block;"></div></div>`;
            document.getElementById('m-footer').innerHTML = ``;
            openM();
            apiCall('/api/diag', {ip:ip, port:port}).then(d => {
                document.getElementById('m-body').innerHTML = `
                    <div style="background:#f8f9fa; padding:15px; border-left:4px solid #4CAF50;">
                        <p>丢包率: <strong>${d.loss}%</strong></p>
                        <p>平均延迟: <strong>${d.delay} ms</strong></p>
                        <p style="font-size:12px; color:#888; margin-top:10px;">目标: ${ip}:${port}</p>
                    </div>`;
                document.getElementById('m-footer').innerHTML = `<button class="btn btn-small" style="background:#ddd;color:#333;" onclick="closeM()">关闭</button>`;
            });
        }

        function changeAuth() {
            apiCall('/api/sys', {action:'auth', u:document.getElementById('new-u').value, p:document.getElementById('new-p').value}).then(d=>{ showM("成功", "凭证已修改，请重新登录！"); setTimeout(logout, 2000); });
        }
        
        // 网页端在线安装功能
        function showInstallModal() {
            document.getElementById('m-title').innerText = '安装/重置 Realm';
            document.getElementById('m-body').innerHTML = `
                <div style="text-align:center; margin: 15px 0;">
                    <button class="btn btn-primary" onclick="doWebInstall()">🌐 自动拉取并安装</button>
                </div>
                <p style="font-size:12px; color:#666; text-align:center;">提示：自动拉取 Github 预设版本覆盖安装，并启动服务。</p>
            `;
            document.getElementById('m-footer').innerHTML = `<button class="btn btn-small" style="background:#ddd;color:#333;" onclick="closeM()">取消</button>`;
            openM();
        }
        function doWebInstall() {
            document.getElementById('m-body').innerHTML = '<div style="text-align:center;"><p>正在后台下载并安装...</p><div class="loader" style="display:block;"></div></div>';
            document.getElementById('m-footer').innerHTML = '';
            apiCall('/api/install', {}, 'POST').then(d => { showM("安装结果", d.msg); });
        }

        function openM() { document.getElementById('g-modal').style.display='flex'; setTimeout(()=>document.getElementById('g-modal-box').classList.add('show'), 10); }
        function closeM() { document.getElementById('g-modal-box').classList.remove('show'); setTimeout(()=>document.getElementById('g-modal').style.display='none', 200); }
        function showM(t, text) {
            document.getElementById('m-title').innerText = t;
            document.getElementById('m-body').innerHTML = `<p>${text}</p>`;
            document.getElementById('m-footer').innerHTML = `<button class="btn btn-primary btn-small" onclick="closeM()">确定</button>`;
            openM();
        }

        window.onload = initApp;
    </script>
</body>
</html>
EOF

    # ================= Python 3 后端服务 =================
    cat > "$PANEL_DIR/server.py" << 'EOF'
import http.server, socketserver, json, subprocess, os, threading, time, datetime, socket, uuid, re

TOKEN = ""
CFG_PATH = "/etc/realm/config.toml"
AUTH_FILE = "/etc/realm/panel/auth.json"
TRAF_FILE = "/etc/realm/panel/traffic.json"

def read_config():
    if not os.path.exists(CFG_PATH): return []
    nodes = []
    with open(CFG_PATH, 'r') as f: content = f.read()
    blocks = content.split('[[endpoints]]')
    for b in blocks[1:]:
        node = {'remark': '', 'inIp': '', 'inPort': '', 'outIp': '', 'outPort': ''}
        for line in b.split('\n'):
            line = line.strip()
            if line.startswith('# remark:'): node['remark'] = line.split(':', 1)[1].strip()
            elif line.startswith('listen'):
                val = line.split('=')[1].strip().strip('"')
                node['inIp'] = val.rsplit(':', 1)[0] + ']' if ']:' in val else val.rsplit(':', 1)[0]
                node['inPort'] = val.rsplit(':', 1)[1]
            elif line.startswith('remote'):
                val = line.split('=')[1].strip().strip('"')
                node['outIp'], node['outPort'] = val.rsplit(':', 1)[0], val.rsplit(':', 1)[1]
        if node['inPort']: nodes.append(node)
    return nodes

def write_config(nodes):
    out = "[network]\nno_tcp = false\nuse_udp = true\nzero_copy = true\n\n"
    for n in nodes:
        out += "[[endpoints]]\n"
        out += f"listen = \"{n['inIp']}:{n['inPort']}\"\n"
        out += f"remote = \"{n['outIp']}:{n['outPort']}\"\n"
        if n.get('remark'): out += f"# remark: {n['remark']}\n"
        out += "\n"
    with open(CFG_PATH, 'w') as f: f.write(out)
    subprocess.run("systemctl restart realm", shell=True)
    sync_iptables() # 每次修改配置后同步探针规则

# --------- iptables 流量探针核心逻辑 ---------
def sync_iptables():
    nodes = read_config()
    os.system("iptables -N REALM_ACCT 2>/dev/null; iptables -C INPUT -j REALM_ACCT 2>/dev/null || iptables -I INPUT -j REALM_ACCT; iptables -C OUTPUT -j REALM_ACCT 2>/dev/null || iptables -I OUTPUT -j REALM_ACCT")
    os.system("ip6tables -N REALM_ACCT 2>/dev/null; ip6tables -C INPUT -j REALM_ACCT 2>/dev/null || ip6tables -I INPUT -j REALM_ACCT; ip6tables -C OUTPUT -j REALM_ACCT 2>/dev/null || ip6tables -I OUTPUT -j REALM_ACCT")
    os.system("iptables -F REALM_ACCT; ip6tables -F REALM_ACCT 2>/dev/null")
    for n in nodes:
        p = n['inPort']
        os.system(f"iptables -A REALM_ACCT -p tcp --sport {p}; iptables -A REALM_ACCT -p udp --sport {p}; iptables -A REALM_ACCT -p tcp --dport {p}; iptables -A REALM_ACCT -p udp --dport {p}")
        os.system(f"ip6tables -A REALM_ACCT -p tcp --sport {p} 2>/dev/null; ip6tables -A REALM_ACCT -p udp --sport {p} 2>/dev/null; ip6tables -A REALM_ACCT -p tcp --dport {p} 2>/dev/null; ip6tables -A REALM_ACCT -p udp --dport {p} 2>/dev/null")

def traffic_daemon():
    sync_iptables()
    while True:
        time.sleep(60)
        try:
            with open(TRAF_FILE, 'r') as f: data = json.load(f)
            now = datetime.datetime.now()
            current_month = now.strftime("%Y-%m")
            current_hour = now.strftime("%Y-%m-%d %H")
            
            # 每月1号清空
            if data.get("month") != current_month:
                data = {"month": current_month, "nodes": {}, "hourly": {}}
            
            # 解析 iptables 字节数
            bytes_added = {}
            for cmd in ["iptables -nxvL REALM_ACCT", "ip6tables -nxvL REALM_ACCT 2>/dev/null"]:
                try:
                    out = subprocess.check_output(cmd, shell=True).decode()
                    for line in out.split('\n'):
                        parts = line.split()
                        if len(parts) > 6:
                            b_count = int(parts[1])
                            m = re.search(r'(?:spt|dpt):(\d+)', line)
                            if m and b_count > 0:
                                p = m.group(1)
                                bytes_added[p] = bytes_added.get(p, 0) + b_count
                except: pass
            
            # 探针归零
            os.system("iptables -Z REALM_ACCT; ip6tables -Z REALM_ACCT 2>/dev/null")
            
            # 累加存储
            hour_total = 0
            for p, b in bytes_added.items():
                data["nodes"][p] = data["nodes"].get(p, 0) + b
                hour_total += b
                
            data["hourly"][current_hour] = data["hourly"].get(current_hour, 0) + hour_total
            
            # 清理 48 小时前的历史数据防止文件膨胀
            cutoff = now - datetime.timedelta(hours=48)
            data["hourly"] = {k:v for k,v in data["hourly"].items() if datetime.datetime.strptime(k, "%Y-%m-%d %H") > cutoff}
            
            with open(TRAF_FILE, 'w') as f: json.dump(data, f)
        except Exception as e: print("Traffic daemon error:", e)

# 启动后台流量线程
threading.Thread(target=traffic_daemon, daemon=True).start()

# --------- HTTP API 服务器 ---------
class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/' or self.path == '/index.html':
            self.send_response(200); self.send_header('Content-type', 'text/html; charset=utf-8'); self.end_headers()
            with open('/etc/realm/panel/index.html', 'rb') as f: self.wfile.write(f.read())
            return
            
        # 鉴权
        if self.headers.get('Authorization') != TOKEN:
            self.send_response(401); self.end_headers(); return
            
        if self.path == '/api/data':
            nodes = read_config()
            try:
                with open(TRAF_FILE, 'r') as f: t_data = json.load(f)
            except: t_data = {"nodes": {}, "hourly": {}}
            
            # 组装节点数据 (GB)
            total_b = 0
            for n in nodes:
                b = t_data["nodes"].get(n["inPort"], 0)
                n["gb"] = round(b / 1073741824, 2)
                total_b += b
                
            # 组装 24 小时图表
            now = datetime.datetime.now()
            c_labels, c_data = [], []
            for i in range(23, -1, -1):
                t = now - datetime.timedelta(hours=i)
                hr_str = t.strftime("%Y-%m-%d %H")
                c_labels.append(t.strftime("%H:00"))
                c_data.append(round(t_data["hourly"].get(hr_str, 0) / 1073741824, 2))
                
            res = {"nodes": nodes, "total_gb": round(total_b / 1073741824, 2), "chart_labels": c_labels, "chart_data": c_data}
            self.send_response(200); self.send_header('Content-type', 'application/json'); self.end_headers()
            self.wfile.write(json.dumps(res).encode())

    def do_POST(self):
        len_b = int(self.headers.get('Content-Length', 0))
        data = json.loads(self.rfile.read(len_b).decode('utf-8')) if len_b > 0 else {}
        
        if self.path == '/api/login':
            with open(AUTH_FILE, 'r') as f: auth = json.load(f)
            if data.get('u') == auth['username'] and data.get('p') == auth['password']:
                global TOKEN; TOKEN = str(uuid.uuid4())
                self.send_response(200); self.end_headers(); self.wfile.write(json.dumps({"token": TOKEN}).encode())
            else:
                self.send_response(401); self.end_headers(); self.wfile.write(b"{}")
            return
            
        if self.headers.get('Authorization') != TOKEN:
            self.send_response(401); self.end_headers(); return
            
        res = {"msg": "ok"}
        if self.path == '/api/sys':
            if data['action'] == 'stop': subprocess.run("systemctl stop realm", shell=True)
            elif data['action'] == 'restart': subprocess.run("systemctl restart realm", shell=True)
            elif data['action'] == 'auth':
                with open(AUTH_FILE, 'w') as f: json.dump({"username": data['u'], "password": data['p']}, f)
        
        elif self.path == '/api/install':
            cmd = "wget -N --no-check-certificate https://github.com/zhboner/realm/releases/download/v2.6.0/realm-x86_64-unknown-linux-musl.tar.gz -O /tmp/realm.tar.gz && tar -xvf /tmp/realm.tar.gz -C /tmp/ && mv /tmp/realm /usr/local/bin/realm && chmod +x /usr/local/bin/realm && systemctl enable realm && systemctl restart realm"
            subprocess.run(cmd, shell=True)
            res = {"msg": "网页端安装/重置 Realm 核心成功，服务已启动！"}
            
        elif self.path == '/api/node':
            nodes = read_config()
            nodes.append({'remark': data['r'], 'inIp': data['inIp'], 'inPort': str(data['inPort']), 'outIp': data['outIp'], 'outPort': str(data['outPort'])})
            write_config(nodes)
            
        elif self.path == '/api/diag':
            success, delays = 0, []
            for _ in range(5):
                try:
                    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.settimeout(1.0)
                    start = time.time(); s.connect((data['ip'], int(data['port']))); s.close()
                    delays.append(time.time() - start); success += 1
                except: pass
            res = {"loss": int((5-success)/5*100), "delay": int((sum(delays)/len(delays)*1000)) if delays else 0}

        self.send_response(200); self.send_header('Content-type', 'application/json'); self.end_headers()
        self.wfile.write(json.dumps(res).encode())
        
    def do_PUT(self):
        if self.headers.get('Authorization') != TOKEN: self.send_response(401); self.end_headers(); return
        data = json.loads(self.rfile.read(int(self.headers.get('Content-Length'))).decode())
        nodes = read_config()
        for n in nodes:
            if n['inPort'] == str(data['port']):
                n['remark'], n['outIp'], n['outPort'] = data['r'], data['outIp'], str(data['outPort'])
        write_config(nodes)
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"msg":"ok"}')
        
    def do_DELETE(self):
        if self.headers.get('Authorization') != TOKEN: self.send_response(401); self.end_headers(); return
        data = json.loads(self.rfile.read(int(self.headers.get('Content-Length'))).decode())
        nodes = [n for n in read_config() if n['inPort'] != str(data['port'])]
        write_config(nodes)
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"msg":"ok"}')

with socketserver.TCPServer(("", 31337), Handler) as httpd: httpd.serve_forever()
EOF

    # 3. 创建面板 Systemd 服务
    cat > "$PANEL_SERVICE_PATH" <<EOF
[Unit]
Description=Realm Web Panel Backend
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$PANEL_DIR
ExecStart=/usr/bin/env python3 server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm-panel
    systemctl restart realm-panel
    
    echo -e "${GREEN}Web 面板部署完成！访问 http://你的服务器IP:${PANEL_PORT} 即可登录面板。${PLAIN}"
    echo -e "${YELLOW}面板默认账户密码均是: admin${PLAIN}"
}

install_realm() {
    if [ ! -f "$REALM_BIN_PATH" ]; then
        echo -e "${GREEN}选择安装方式:${PLAIN}"
        echo -e " 1. 在线下载安装 (使用预设 v2.6.0 musl 链接)"
        echo -e " 2. 本地文件安装 (请先将 $FILE_NAME 上传至 /tmp 目录)"
        echo -e " 3. 跳过当前 Realm 安装 (直接部署网页端，后续在网页内安装)"
        read -p "请输入选项 [1-3]: " install_method
        if [ "$install_method" == "1" ]; then
            wget -N --no-check-certificate "$DOWNLOAD_URL" -O "$FILE_NAME"
            tar -xvf "$FILE_NAME"; chmod +x realm; mv realm "$REALM_BIN_PATH"; rm -f "$FILE_NAME"
        elif [ "$install_method" == "2" ] && [ -f "$LOCAL_PKG_PATH" ]; then
            tar -xvf "$LOCAL_PKG_PATH" -C /tmp/; chmod +x /tmp/realm; mv /tmp/realm "$REALM_BIN_PATH"
        elif [ "$install_method" == "3" ]; then
            echo -e "${YELLOW}已跳过 Realm 核心安装。${PLAIN}"
        else
            echo -e "${RED}安装失败或无效选项！${PLAIN}"; return
        fi
    fi

    mkdir -p "$WORK_DIR"
    if [ ! -f "$REALM_CONFIG_PATH" ]; then
        cat > "$REALM_CONFIG_PATH" <<EOF
[network]
no_tcp = false
use_udp = true
zero_copy = true
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
    
    if [ "$install_method" != "3" ] && [ -f "$REALM_BIN_PATH" ]; then
        systemctl enable realm
    fi

    install_panel
    
    if [ "$install_method" != "3" ] && [ -f "$REALM_BIN_PATH" ]; then
        systemctl start realm
        echo -e "${GREEN}Realm 核心及面板安装启动完成！${PLAIN}"
    else
        echo -e "${GREEN}Web 面板已安装！(Realm 核心未运行，请进入网页端面板安装)${PLAIN}"
    fi
}

uninstall_realm() {
    systemctl stop realm-panel realm >/dev/null 2>&1
    systemctl disable realm-panel realm >/dev/null 2>&1
    rm -f "$PANEL_SERVICE_PATH" "$REALM_SERVICE_PATH" "$REALM_BIN_PATH"
    rm -rf "$WORK_DIR"
    systemctl daemon-reload; systemctl reset-failed realm.service realm-panel.service 2>/dev/null
    
    iptables -F REALM_ACCT 2>/dev/null
    ip6tables -F REALM_ACCT 2>/dev/null
    
    echo -e "${GREEN}Realm 及面板已彻底卸载！${PLAIN}"
}

show_status() {
    if systemctl is-active --quiet realm; then echo -e "Realm 状态: ${GREEN}运行中${PLAIN}"; else echo -e "Realm 状态: ${RED}未运行${PLAIN}"; fi
    if systemctl is-active --quiet realm-panel; then echo -e "Web 面板:   ${GREEN}运行中 (端口: $PANEL_PORT)${PLAIN}"; else echo -e "Web 面板:   ${RED}未运行${PLAIN}"; fi
}

while true; do
    clear
    echo -e "============================================"
    echo -e "      Realm 转发管理脚本 (面板完全体)       "
    echo -e "============================================"
    show_status
    echo -e "--------------------------------------------"
    echo -e "  1. 安装 Realm 转发并开启 Web 面板"
    echo -e "  2. 彻底卸载 Realm 及其 Web 面板"
    echo -e "  0. 退出脚本"
    echo -e "============================================"
    read -p " 请输入选项 [0-2]: " num
    case "$num" in
        1) install_realm ;;
        2) uninstall_realm ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
    echo -e ""
    read -p "按回车键返回主菜单..." 
done
