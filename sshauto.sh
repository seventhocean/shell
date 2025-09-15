#!/bin/bash
# 本地测试：每10秒触发一次SSH连接，用于分析TCP三次握手
# 服务器信息
SERVER_IP="10.50.99.138"
USER="root"
PASSWORD="yunshan3302"
# 连接间隔时间（秒）
INTERVAL=10

# 检查sshpass是否安装
if ! command -v sshpass &> /dev/null; then
    echo "错误：未安装sshpass，请先安装（本地测试环境使用）"
    echo "安装方式："
    echo "  Ubuntu/Debian: sudo apt install sshpass"
    echo "  CentOS/RHEL: sudo yum install sshpass"
    echo "  macOS: brew install sshpass"
    exit 1
fi

# 循环执行SSH连接
echo "=== 开始SSH连接测试（每${INTERVAL}秒一次），按Ctrl+C停止 ==="
count=1
while true; do
    echo -e "\n=== 第 $count 次连接尝试：$USER@$SERVER_IP ==="
    # 建立连接后立即退出，确保完整的TCP交互流程
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 $USER@$SERVER_IP "exit"
    
    # 显示下次连接时间
    echo "=== 等待${INTERVAL}秒后进行下一次连接 ==="
    count=$((count + 1))
    sleep $INTERVAL
done

