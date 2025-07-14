#!/bin/bash
# 启用严格错误检查
set -euo pipefail
# ------------------------------ 配置 ------------------------------
# 定义颜色变量
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # 恢复默认颜色

# 使用的容器命令，支持 docker 或 nerdctl -nk8s.io
#container_cmd="docker"
container_cmd="nerdctl"
# 登录Docker仓库
echo "35lRrgBcLhF" | $container_cmd login --username=acrpush@yunshan --password-stdin hub.deepflow.yunshan.net
# 定义镜像仓库地址
repo="hub.deepflow.yunshan.net/dev/"
# 定义镜像列表文件
patch_image_list="patch_image_tag_list.txt"
# 定义保存镜像的目录
save_dir="$(pwd)"

echo "镜像文件将保存到当前目录: $save_dir"

# 检查镜像列表文件
if [ ! -f "$patch_image_list" ]; then
    echo -e "${RED}错误: 镜像列表文件 $patch_image_list 不存在${NC}"
    exit 1
fi

# 处理镜像列表
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
    

    echo -e "${GREEN}正在拉取镜像: $full_image_name${NC}"
    if ! $container_cmd pull "$full_image_name"; then
        echo -e "${RED}错误: 拉取镜像失败: $full_image_name${NC}"
        exit 1
        #sleep 2  # 添加2秒停顿
    fi

    save_file="$save_dir/${clean_image_name}_${image_tag}.tar"
    echo -e "${GREEN}正在保存镜像到: $save_file${NC}"
    if ! $container_cmd save -o "$save_file" "$full_image_name"; then
        echo -e "${RED}错误: 保存镜像失败: $full_image_name${NC}"
        exit 1
    fi
done < "$patch_image_list"

echo -e "${GREEN}"所有镜像处理完成！"${NC}"