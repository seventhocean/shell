#!/bin/bash

SEARCH_DIR="/root/"

if [ ! -d "$SEARCH_DIR" ]; then
    echo "错误：目录 $SEARCH_DIR 不存在"
    exit 1
fi

# 查找所有以ALL.tar.gz结尾的文件，且文件名格式符合xxx-xxxxxxxxx-xxxxx-ALL.tar.gz
find "$SEARCH_DIR" -maxdepth 1 -type f -regex '.*/[0-9]*-[0-9]*-[0-9]*-ALL\.tar\.gz$' | while read -r file; do
    echo "找到符合条件的文件：$file"
    
    echo "正在执行命令：/usr/local/deepflow/bin/deepflow-patch -a $file"
    /usr/local/deepflow/bin/deepflow-patch -a "$file"
    
    if [ $? -eq 0 ]; then
        echo "命令执行成功：$file"
    else
        echo "命令执行失败：$file"
    fi
    echo "----------------------------------------"
done

echo "所有符合条件的文件处理完毕"
    
