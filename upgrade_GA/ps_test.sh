#!/bin/bash
set -euo pipefail

# 定义颜色变量
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # 恢复默认颜色

# 默认容器运行时
DEFAULT_CONTAINER_CMD="docker"
container_cmd="$DEFAULT_CONTAINER_CMD"

# 定义镜像仓库地址
repo="hub.deepflow.yunshan.net/dev/"
# 定义镜像列表文件
patch_image_list="patch_image_tag_list.txt"
# 定义保存镜像的目录
save_dir="$(pwd)"

# 显示帮助文档函数
show_help() {
    echo -e "${WHITE}使用说明:${NC}"
    echo -e "  ${CYAN}$0 [选项] [镜像名称1 镜像名称2 ...]${NC}\n"
    
    echo -e "${WHITE}选项:${NC}"
    echo -e "  ${GREEN}-h, --help     ${NC}显示此帮助信息"
    echo -e "  ${GREEN}-c, --cmd      ${NC}指定container (${BOLD}docker${NC}/${BOLD}nerdctl${NC}，默认为docker)\n"
    
    echo -e "${WHITE}使用示例:${NC}"
    echo -e "  ${BOLD}1.${NC} 从 ${YELLOW}patch_image_tag_list.txt${NC} 批量拉取镜像:"
    echo -e "     ${CYAN}$0${NC}\n"
    
    echo -e "  ${BOLD}2.${NC} 拉取单个镜像 (${CYAN}自动添加默认仓库前缀${NC}):"
    echo -e "     ${CYAN}$0 deepflow-server:v6.6.5550${NC}\n"
    
    echo -e "  ${BOLD}3.${NC} 拉取多个镜像 (${CYAN}自动添加默认仓库前缀${NC}):"
    echo -e "     ${CYAN}$0 deepflow-server:v6.6.5550 pcap:v6.6.220${NC}\n"
    
    echo -e "  ${BOLD}4.${NC} 拉取完整镜像地址:"
    echo -e "     ${CYAN}$0 hub.deepflow.yunshan.net/dev/deepflow-server:feature-scp-66${NC}\n"
    
    echo -e "  ${BOLD}5.${NC} 使用 ${BOLD}nerdctl${NC} 拉取镜像:"
    echo -e "     ${CYAN}$0 --cmd nerdctl deepflow-server:v6.6.5550${NC}\n"
    exit 0
}

# 解析命令行参数
POSITIONAL_ARGS=()
NEED_RUNTIME_CHECK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -c|--cmd)
            # 用户明确指定了运行时，跳过自动检测
            if [ -z "$2" ]; then
                echo -e "${RED}错误: --cmd 需要指定容器工具${NC}"
                exit 1
            fi
            container_cmd="$2"
            shift 2
            ;;
        -*)
            # 其他选项需要运行时
            NEED_RUNTIME_CHECK=true
            echo -e "${RED}错误: 未知选项 $1${NC}"
            show_help
            exit 1
            ;;
        *)
            # 位置参数需要运行时
            NEED_RUNTIME_CHECK=true
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# 检查容器运行时是否可用
check_container_runtime() {
    # 检查docker是否可用
    if command -v docker &> /dev/null && docker ps &> /dev/null; then
        echo -e "${GREEN}检测到 Docker 已安装且可正常使用${NC}"
        container_cmd="docker"
        return 0
    fi
    
    # 检查nerdctl是否可用
    if command -v nerdctl &> /dev/null; then
        echo -e "${YELLOW}未检测到 Docker，使用 nerdctl 替代${NC}"
        container_cmd="nerdctl"
        return 0
    fi
    
    echo -e "${RED}错误: 未找到任何容器运行时 (docker/nerdctl)${NC}"
    return 1
}

# 如果需要运行时且不是help命令，则检查运行时
if [ "$NEED_RUNTIME_CHECK" = true ] && [ "$container_cmd" = "$DEFAULT_CONTAINER_CMD" ]; then
    if ! check_container_runtime; then
        exit 1
    fi
fi

# 确保即使数组为空也不会报错
set -- "${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}"

# 登录Docker仓库（需要运行时）
if [ "$NEED_RUNTIME_CHECK" = true ]; then
    echo "35lRrgBcLhF" | $container_cmd login --username=acrpush@yunshan --password-stdin hub.deepflow.yunshan.net
fi

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

    # 检查镜像列表文件
    if [ ! -f "$patch_image_list" ]; then
        echo -e "${RED}错误: 镜像列表文件 $patch_image_list 不存在${NC}"
        exit 1
    fi

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

echo -e "${GREEN}"所有镜像处理完成！"${NC}"