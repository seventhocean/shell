#!/bin/bash

# 定义日志目录和基础文件名
LOG_DIR="/var/log/deepflow/deepflow"
BASE_NAME="server.log"

# 获取当前日期（格式：YYYY-MM-DD）
CURRENT_DATE=$(date +%Y-%m-%d)

# 拼接完整的日志文件名
LOG_FILE="${LOG_DIR}/${BASE_NAME}.${CURRENT_DATE}"

# 检查文件是否存在
if [ -f "$LOG_FILE" ]; then
    echo "清理日志文件: $LOG_FILE"
    > "$LOG_FILE"  # 清空文件内容
fi
