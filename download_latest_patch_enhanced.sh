#!/bin/bash

# 配置
OSS_PATH="oss://df-patch-no-delete/patch/6.6/6.6.9/latest/"
DOWNLOAD_DIR="/root"
LOG_FILE="/var/log/patch_download.log"
MAX_RETRIES=3
RETRY_DELAY=30

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# 错误处理函数
error_exit() {
    log "错误: $1"
    exit 1
}

# 创建目录
mkdir -p "$DOWNLOAD_DIR"
mkdir -p $(dirname "$LOG_FILE")

log "开始检查最新补丁"

# 检查ossutil
if ! command -v ossutil &> /dev/null; then
    error_exit "ossutil 未安装"
fi

# 获取最新文件
for ((i=1; i<=MAX_RETRIES; i++)); do
    LATEST_FILE=$(ossutil ls "$OSS_PATH" 2>> "$LOG_FILE" | grep -i "\.tar\.gz$" | tail -1 | awk '{print $NF}')
    
    if [ -n "$LATEST_FILE" ]; then
        break
    fi
    
    if [ $i -eq $MAX_RETRIES ]; then
        error_exit "无法获取文件列表，重试次数已达上限"
    fi
    
    log "第 $i 次获取文件列表失败，${RETRY_DELAY}秒后重试..."
    sleep $RETRY_DELAY
done

log "找到最新文件: $LATEST_FILE"

# 下载文件
FILENAME=$(basename "$LATEST_FILE")
LOCAL_PATH="$DOWNLOAD_DIR/$FILENAME"

if [ -f "$LOCAL_PATH" ]; then
    log "文件已存在，跳过下载: $FILENAME"
    exit 0
fi

# 下载（带重试机制）
for ((i=1; i<=MAX_RETRIES; i++)); do
    log "开始下载 (尝试 $i/$MAX_RETRIES): $FILENAME"
    
    if ossutil cp "$LATEST_FILE" "$LOCAL_PATH" >> "$LOG_FILE" 2>&1; then
        log "下载成功: $FILENAME"
        
        # 验证文件大小（可选）
        OSS_SIZE=$(ossutil ls "$LATEST_FILE" | awk 'NR>1 {print $5}')
        LOCAL_SIZE=$(stat -c%s "$LOCAL_PATH" 2>/dev/null || wc -c < "$LOCAL_PATH")
        
        if [ "$OSS_SIZE" -eq "$LOCAL_SIZE" ]; then
            log "文件大小验证成功: $LOCAL_SIZE bytes"
            
            # 清理旧文件（保留最近5个）
            cd "$DOWNLOAD_DIR" && ls -t *.tar.gz 2>/dev/null | tail -n +6 | xargs rm -f --
            
            exit 0
        else
            log "文件大小不匹配: OSS=$OSS_SIZE, 本地=$LOCAL_SIZE"
            rm -f "$LOCAL_PATH"
        fi
    fi
    
    if [ $i -eq $MAX_RETRIES ]; then
        error_exit "下载失败，重试次数已达上限"
    fi
    
    log "下载失败，${RETRY_DELAY}秒后重试..."
    sleep $RETRY_DELAY
done
