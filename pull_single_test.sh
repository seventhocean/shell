#!/bin/bash
# 启用严格错误检查
set -euo pipefail
# ------------------------------ 配置 ------------------------------
# 定义颜色变量
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # 恢复默认颜色

# 使用的容器命令，默认使用docker
#container_cmd="docker"
container_cmd="nerdctl"
# 定义镜像仓库地址
repo="hub.deepflow.yunshan.net/dev/"
# 定义镜像列表文件
patch_image_list="patch_image_tag_list.txt"
# 定义保存镜像的目录
save_dir="$(pwd)"

# 登录Docker仓库
echo "35lRrgBcLhF" | $container_cmd login --username=acrpush@yunshan --password-stdin hub.deepflow.yunshan.net

# 处理单个镜像的函数
pull_and_save_single() {
    local full_image_name="$1"
    
    echo -e "${GREEN}正在拉取镜像: $full_image_name${NC}"
    if ! $container_cmd pull "$full_image_name"; then
        echo -e "${RED}错误: 拉取镜像失败: $full_image_name${NC}"
        exit 1
    fi

    # 从完整镜像名中提取名称和标签
    local image_name=$(echo "$full_image_name" | awk -F':' '{print $1}' | awk -F'/' '{print $NF}')
    local image_tag=$(echo "$full_image_name" | awk -F':' '{print $2}')
    
    local save_file="$save_dir/${image_name}_${image_tag}.tar"
    echo -e "${GREEN}正在保存镜像到: $save_file${NC}"
    if ! $container_cmd save -o "$save_file" "$full_image_name"; then
        echo -e "${RED}错误: 保存镜像失败: $full_image_name${NC}"
        exit 1
    fi
}

# 处理从文件读取镜像列表
pull_from_file() {
    echo "镜像文件将保存到当前目录: $save_dir"

    if [ ! -f "$patch_image_list" ]; then
        echo -e "${RED}错误: 镜像列表文件 $patch_image_list 不存在${NC}"
        exit 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过空行和注释
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        # 提取镜像名和标签（处理 _tag: 情况）
        if [[ "$line" =~ _tag:[[:space:]]* ]]; then
            # 格式为 name_tag: vx.x.x
            image_name=$(echo "$line" | sed 's/_tag:[[:space:]]*v[0-9].*//')
            image_tag="$(echo "$line" | grep -oP '_tag:[[:space:]]*\Kv?[0-9.]+')"
        else
            # 格式为 name: vx.x.x
            image_name=$(echo "$line" | awk -F':' '{print $1}' | xargs)
            image_tag=$(echo "$line" | awk -F':' '{print $2}' | xargs)
        fi

        # 构建正确的镜像名称（去掉 _tag 后缀）
        clean_image_name=$(echo "$image_name" | sed 's/_tag$//')
        full_image_name="${repo}${clean_image_name}:${image_tag}"
        
        pull_and_save_single "$full_image_name"
    done < "$patch_image_list"
}

# 主逻辑
if [ $# -eq 0 ]; then
    # 无参数时从文件读取
    pull_from_file
else
    # 有参数时直接处理指定镜像
    for image in "$@"; do
        # 如果镜像名不包含仓库地址，自动添加默认仓库前缀
        if [[ ! "$image" =~ ^hub\.deepflow\.yunshan\.net/ ]]; then
            image="${repo}${image}"
        fi
        pull_and_save_single "$image"
    done
fi

echo -e "${GREEN}所有镜像处理完成！${NC}"