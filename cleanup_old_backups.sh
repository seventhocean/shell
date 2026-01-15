#!/bin/bash

RETAIN_DAYS=3
TARGET_DIR="/root"
LOG_FILE="/var/log/cleanup_backups.log"

NOW=$(date '+%Y-%m-%d %H:%M:%S')
CUTOFF_DATE=$(date -d "$RETAIN_DAYS days ago" '+%Y%m%d')

echo "[$NOW] 开始清理 $TARGET_DIR 中早于 $CUTOFF_DATE 的备份文件..." >> "$LOG_FILE"

find "$TARGET_DIR" \
  -maxdepth 1 \
  \( \
    -name '[0-9]*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-00000-ALL' \
    -o -name '[0-9]*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-00000-ALL.md' \
    -o -name '[0-9]*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-00000-ALL.tar.gz' \
  \) \
  \( -type f -o -type d \) | while read -r item; do

    if [[ "$item" =~ [0-9]+-([0-9]{8})-00000-ALL ]]; then
        file_date="${BASH_REMATCH[1]}"
        if [[ "$file_date" -lt "$CUTOFF_DATE" ]]; then
            echo "  删除: $item (日期: $file_date)" >> "$LOG_FILE"
            rm -rf "$item"
        fi
    fi
done

echo "[$NOW] 清理完成。" >> "$LOG_FILE"
echo "----------------------------------------" >> "$LOG_FILE"