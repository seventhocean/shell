#!/bin/bash
# 启用严格错误检查
set -euo pipefail

# ------------------------------ 基础配置（与项目对齐） ------------------------------
# 颜色变量
GREEN='\033[1;32m'    # 绿色：成功信息
RED='\033[0;31m'      # 红色：错误信息
YELLOW='\033[1;33m'   # 黄色：警告/进度信息
WHITE='\033[1;37m'    # 白色：标题/强调文本
CYAN='\033[0;36m'     # 青色：文件路径/URL高亮
NC='\033[0m'          # 重置：恢复默认终端颜色

# 项目基础目录（与其他脚本保持一致）
BASE_DIR="/home/auto_packing_no_delete"
# OSS路径（目标补丁包存放地址）
OSS_PATH="oss://df-patch-no-delete/patch/6.6/6.6.9/latest/"
# 临时下载目录（存放下载的tar.gz包和解压文件，可定期清理）
DOWNLOAD_DIR="$BASE_DIR/tmp_oss_download"
# 最终镜像列表输出目录（供pull_save.sh使用）
LATEST_LIST_DIR="$BASE_DIR/latest_image_list"
# 日志文件（统一存储到项目logs目录）
LOG_FILE="$BASE_DIR/logs/oss_processor.log"

# 重试配置（应对网络波动）
MAX_RETRIES=3    # 最大重试次数
RETRY_DELAY=30   # 重试间隔（秒）


# ------------------------------ 工具函数 ------------------------------
##日志函数（带时间戳，同时输出到文件和控制台）
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_content="[$timestamp] $1"
    echo -e "$log_content" >> "$LOG_FILE"
    echo -e "$log_content"
}


##错误处理函数（打印错误日志并退出）
error_exit() {
    log "${RED}错误：$1${NC}"
    exit 1
}

##清理临时文件（保留最近3天的文件，避免磁盘占满）
clean_temp_files() {
    log "${YELLOW}开始清理临时目录旧文件（保留最近3天）：$DOWNLOAD_DIR${NC}"
    # 清理3天前的文件
    find "$DOWNLOAD_DIR" -type f -mtime +3 -delete
    # 清理空目录
    find "$DOWNLOAD_DIR" -type d -empty -delete
    log "${GREEN}临时目录清理完成${NC}"
}


# ------------------------------ 主逻辑 ------------------------------
# 1. 初始化目录（确保所有目录存在）
log "===== 开始执行OSS补丁同步脚本 ====="
mkdir -p "$DOWNLOAD_DIR" "$LATEST_LIST_DIR" "$(dirname "$LOG_FILE")"
log "${YELLOW}初始化目录完成：${NC}"
log "  - 临时下载目录：$DOWNLOAD_DIR"
log "  - 镜像列表目录：$LATEST_LIST_DIR"
log "  - 日志目录：$(dirname "$LOG_FILE")"

# 2. 检查ossutil是否安装
if ! command -v ossutil &> /dev/null; then
    error_exit "ossutil 未安装或未配置到环境变量，请先安装并配置OSS密钥（执行 ossutil config）"
fi
log "${GREEN}ossutil 检查通过${NC}"

# 3. 从OSS获取最新的.tar.gz补丁包
log "${YELLOW}开始从OSS获取最新补丁包列表：$OSS_PATH${NC}"
LATEST_FILE=""
for ((i=1; i<=MAX_RETRIES; i++)); do
    # 列出OSS路径下的文件，筛选.tar.gz，取最后一个（最新）
    LATEST_FILE=$(ossutil ls "$OSS_PATH" 2>> "$LOG_FILE" | grep -i "\.tar\.gz$" | tail -1 | awk '{print $NF}')
    
    if [ -n "$LATEST_FILE" ]; then
        log "${GREEN}第$i次尝试成功，找到最新OSS文件：$LATEST_FILE${NC}"
        break
    fi
    
    # 重试次数达上限，退出
    if [ $i -eq $MAX_RETRIES ]; then
        error_exit "获取OSS文件列表失败，重试次数已达上限（$MAX_RETRIES次）"
    fi
    
    log "${YELLOW}第$i次尝试失败，$RETRY_DELAY秒后重试...${NC}"
    sleep $RETRY_DELAY
done

# 4. 提取文件名（不含扩展名）和本地保存路径
FILENAME=$(basename "$LATEST_FILE" .tar.gz)  # 示例：08-20250519-12345-ALL
TAR_FILE="$FILENAME.tar.gz"                  # 完整压缩包名
LOCAL_TAR_PATH="$DOWNLOAD_DIR/$TAR_FILE"     # 本地保存路径

# 5. 检查是否已处理过（通过MD5校验，避免重复处理）
EXISTING_MD5=""
if [ -f "$LATEST_LIST_DIR/patch_image_tag_list.txt" ]; then
    EXISTING_MD5=$(md5sum "$LATEST_LIST_DIR/patch_image_tag_list.txt" | awk '{print $1}')
    log "${YELLOW}已存在镜像列表文件，当前MD5：$EXISTING_MD5${NC}"
else
    log "${YELLOW}未找到已存在的镜像列表文件，将执行全新处理${NC}"
fi

# 6. 下载OSS文件（仅当本地不存在或有更新时）
if [ ! -f "$LOCAL_TAR_PATH" ]; then
    log "${YELLOW}开始下载OSS文件：$LATEST_FILE → $LOCAL_TAR_PATH${NC}"
    for ((i=1; i<=MAX_RETRIES; i++)); do
        if ossutil cp "$LATEST_FILE" "$LOCAL_TAR_PATH" >> "$LOG_FILE" 2>&1; then
            log "${GREEN}第$i次尝试成功，文件下载完成：$LOCAL_TAR_PATH${NC}"
            break
        fi
        
        if [ $i -eq $MAX_RETRIES ]; then
            error_exit "文件下载失败，重试次数已达上限（$MAX_RETRIES次）"
        fi
        
        log "${YELLOW}第$i次下载失败，$RETRY_DELAY秒后重试...${NC}"
        sleep $RETRY_DELAY
        # 清理未下载完成的文件
        rm -f "$LOCAL_TAR_PATH"
    done
else
    log "${YELLOW}文件已存在，跳过下载：$LOCAL_TAR_PATH${NC}"
fi

# 7. 双层解压（外层tar.gz → 内层同名tar.gz）
log "${YELLOW}开始执行双层解压...${NC}"

# 7.1 解压外层tar.gz
log "第一步：解压外层文件：$LOCAL_TAR_PATH"
rm -rf "$DOWNLOAD_DIR/$FILENAME"  # 清理旧解压目录（避免冲突）
cd "$DOWNLOAD_DIR" || error_exit "无法进入临时下载目录：$DOWNLOAD_DIR"
if ! tar -xf "$TAR_FILE"; then
    error_exit "外层文件解压失败：$LOCAL_TAR_PATH"
fi
log "${GREEN}外层文件解压完成，生成目录：$DOWNLOAD_DIR/$FILENAME${NC}"

# 7.2 解压内层同名tar.gz
INNER_TAR_PATH="$DOWNLOAD_DIR/$FILENAME/$TAR_FILE"
if [ ! -f "$INNER_TAR_PATH" ]; then
    error_exit "未找到内层压缩文件：$INNER_TAR_PATH（外层解压结果异常）"
fi

log "第二步：解压内层文件：$INNER_TAR_PATH"
cd "$DOWNLOAD_DIR/$FILENAME" || error_exit "无法进入内层目录：$DOWNLOAD_DIR/$FILENAME"
if ! tar -xf "$TAR_FILE"; then
    error_exit "内层文件解压失败：$INNER_TAR_PATH"
fi
log "${GREEN}内层文件解压完成${NC}"

# 8. 提取目标镜像列表文件（patch_image_tag_list.txt）
# 目标文件路径：外层解压目录/6.6/6.6.9/文件名/patch_image_tag_list.txt
TARGET_FILE_PATH="$DOWNLOAD_DIR/$FILENAME/6.6/6.6.9/$FILENAME/patch_image_tag_list.txt"
if [ ! -f "$TARGET_FILE_PATH" ]; then
    error_exit "未找到目标镜像列表文件：$TARGET_FILE_PATH（内层解压结果异常）"
fi
log "${YELLOW}找到目标镜像列表文件：$TARGET_FILE_PATH${NC}"

# 9. 校验并更新镜像列表文件（MD5不同则更新）
NEW_MD5=$(md5sum "$TARGET_FILE_PATH" | awk '{print $1}')
if [ "$NEW_MD5" != "$EXISTING_MD5" ]; then
    # MD5不同，覆盖旧文件（更新镜像列表）
    cp "$TARGET_FILE_PATH" "$LATEST_LIST_DIR/"
    log "${GREEN}镜像列表文件已更新！${NC}"
    log "  - 旧MD5：$EXISTING_MD5"
    log "  - 新MD5：$NEW_MD5"
    log "  - 输出路径：$LATEST_LIST_DIR/patch_image_tag_list.txt"
else
    # MD5相同，无需更新
    log "${YELLOW}镜像列表文件无更新（MD5一致），跳过覆盖${NC}"
fi

# 10. 清理临时文件（保留最近3天的文件，避免磁盘占用过高）
clean_temp_files

# 11. 脚本执行完成
log "${GREEN}===== OSS补丁同步脚本执行完成 ====="
log "${WHITE}当前最新镜像列表路径：${CYAN}$LATEST_LIST_DIR/patch_image_tag_list.txt${NC}"
log "${WHITE}日志文件路径：${CYAN}$LOG_FILE${NC}"