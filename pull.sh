#!/bin/bash

echo "35lRrgBcLhF"| docker login --username=acrpush@yunshan --password-stdin hub.deepflow.yunshan.net

# 定义镜像标签数组
images=(
    "df-web-qiankun-core_tag:v6.6.18856"
    "df-web-qiankun-core-saas_tag:v6.6.18856"
)

# 定义仓库地址
repo="hub.deepflow.yunshan.net/dev/"

# 定义保存目录
save_dir="/root/gaoyuan/"

# 确保保存目录存在
if [ -d "$save_dir" ]; then
    echo "保存目录 $save_dir 已存在"
else
    mkdir -p "$save_dir"
    echo "创建保存目录 $save_dir"
fi

# 循环拉取并保存镜像
for image in "${images[@]}"; do
    full_image_name="$repo$image"
    echo "拉取镜像: $full_image_name"
    docker pull "$full_image_name"

    # 构建保存的文件名
    save_file="$save_dir${image//:/_}.tar"
    echo "保存镜像到: $save_file"
    docker save -o "$save_file" "$full_image_name"
done
