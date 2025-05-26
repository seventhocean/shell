#!/bin/bash

# 启用严格错误检查
set -euo pipefail

# ------------------------------ 颜色定义 ------------------------------
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # 重置颜色

# ------------------------------ 用户可配置变量 ------------------------------
container_cmd="nerdctl -nk8s.io"
upgrade_version="DeepFlow-V6.4.9-106"
script_name="deepflow_patch_upgrade.sh"

# 路径配置
image_dir="."
patch_image_list="patch_image_tag_list.txt"
values_yaml="/usr/local/deepflow/templates/values.yaml"
values_custom="/usr/local/deepflow/templates/values-custom.yaml"
source_registry="hub.deepflow.yunshan.net/dev"
target_registry="sealos.hub:5000"

# 组件列表
components=(
  openebs
  redis
  rabbitmq
  mysql
  mntnct
  opensource
  front-end
  rear-end
  df-help
  df-web-core
  df-web-metrics-explore
  querier-js
  talker
  acl-controller
  warrant
  postman
  log-cleaner
  deepflow
  alarm
  manager
  report
  statistics
  pcap
  dedicated-agent
  grafana
  check
  df-web-ai
  df-analyze
)

# ------------------------------ 函数定义 ------------------------------
usage() {
    echo -e "\n${BLUE}█▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀█${NC}"
    echo -e "${BLUE}█             ${NC}DeepFlow 升级脚本帮助信息             ${BLUE}█${NC}"
    echo -e "${BLUE}█▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄█${NC}"
    
    echo -e "\n${YELLOW}🛠️ 基本用法:${NC}"
    echo -e "  ${GREEN}./${script_name} ${BLUE}[选项]${NC}"
    
    echo -e "\n${YELLOW}📌 可用选项:${NC}"
    echo -e "  ${BLUE}-v, --version${NC}  显示脚本版本信息"
    echo -e "  ${BLUE}-h, --help${NC}     显示本帮助信息"
    echo -e "  ${BLUE}-p, --push${NC}     仅导入并推送镜像到仓库"
    echo -e "  ${BLUE}-u, --upgrade${NC}  执行完整升级流程"
    echo -e "  ${BLUE}-r, --rollback${NC} 回滚到升级前的状态"
    
    echo -e "\n${YELLOW}🔧 更新前准备工作:${NC}"
    echo -e "  • 修改脚本头部变量 ${BLUE}upgrade_version${NC} 为实际版本号"
    echo -e "  • 确保脚本和 ${BLUE}patch_image_tag_list.txt${NC} 在同一目录"
}

import_images() {
  echo -e "\n${BLUE}[步骤 1/$current_step] 导入镜像文件...${NC}"
  cd "$image_dir" || { echo -e "${RED}错误: 目录不存在: $image_dir${NC}"; exit 1; }
  
  for img_tar in *.tar; do
    [ -f "$img_tar" ] || continue
    echo "正在导入: $img_tar"
    if ! $container_cmd load -i "$img_tar"; then
      echo -e "${RED}错误: 导入失败: $img_tar${NC}"
      exit 1
    fi
  done
  echo -e "${GREEN}✓ 所有镜像导入成功${NC}"
  sleep 2
}

push_images() {
  echo -e "\n${BLUE}[步骤 2/$current_step] 推送镜像到仓库...${NC}"
  [ -f "$patch_image_list" ] || { echo -e "${RED}错误: 缺少文件: $patch_image_list${NC}"; exit 1; }

  while IFS=: read -r image_part tag; do
    image_part=$(echo "$image_part" | tr -d '\r' | xargs)
    tag=$(echo "$tag" | tr -d '\r' | xargs)
    image=${image_part%_tag}
    
    source_img="$source_registry/$image:$tag"
    target_img="$target_registry/$image:$tag"

    echo "处理镜像: $image:$tag"
    $container_cmd tag "$source_img" "$target_img" || { echo -e "${RED}错误: 标记失败: $image${NC}"; exit 1; }
    $container_cmd push "$target_img" || { echo -e "${RED}错误: 推送失败: $image${NC}"; exit 1; }
  done < "$patch_image_list"
  echo -e "${GREEN}✓ 所有镜像推送成功${NC}"
  sleep 2
}

backup_files() {
  echo -e "\n${BLUE}[步骤 3/$current_step] 备份配置文件...${NC}"
  local timestamp=$(date +%Y%m%d%H%M%S)
  cp -v "$values_yaml" "${values_yaml}.bak.${timestamp}" || { echo -e "${RED}错误: 备份 values.yaml 失败${NC}"; exit 1; }
  cp -v "$values_custom" "${values_custom}.bak.${timestamp}" || { echo -e "${RED}错误: 备份 values-custom.yaml 失败${NC}"; exit 1; }
  sleep 2
}

update_image_tags() {
  echo -e "\n${BLUE}[步骤 4/$current_step] 更新镜像标签...${NC}"
  [ -f "$patch_image_list" ] || { echo -e "${RED}错误: 缺少文件: $patch_image_list${NC}"; exit 1; }

  while IFS=: read -r image tag; do
    image=$(echo "$image" | tr -d '\r' | xargs)
    tag=$(echo "$tag" | tr -d '\r' | xargs)
    
    echo "更新: $image → $tag"
    sed -i "s|\(${image}: \).*|\1${tag}|" "$values_yaml" || { echo -e "${RED}错误: 更新标签失败: $image${NC}"; exit 1; }
  done < "$patch_image_list"
  echo -e "${GREEN}✓ 标签更新完成${NC}"
  sleep 2
}

update_custom_version() {
  echo -e "\n${BLUE}[步骤 5/$current_step] 更新版本号...${NC}"
  sed -i "s/^deepflowVersion: .*/deepflowVersion: ${upgrade_version}/" "$values_custom" || { echo -e "${RED}错误: 更新版本号失败${NC}"; exit 1; }
  echo -e "${GREEN}✓ 版本号更新为 $upgrade_version${NC}"
  sleep 2
}

upgrade_components() {
  echo -e "\n${BLUE}[步骤 6/$current_step] 升级组件...${NC}"
  local deploy_tool="/usr/local/deepflow/bin/deepflow-deploy"
  [ -x "$deploy_tool" ] || { echo -e "${RED}错误: 找不到可执行文件: $deploy_tool${NC}"; exit 1; }

  for component in "${components[@]}"; do
    echo "升级: $component"
    $deploy_tool -uo "$component" || { echo -e "${RED}错误: 升级失败: $component${NC}"; exit 1; }
  done
  
  echo -e "${GREEN}✓ 所有组件升级完成${NC}"
  sleep 2
}

rollback_changes() {
  echo -e "\n${YELLOW}[回滚] 恢复配置文件...${NC}"
  local latest_values=$(ls -t "${values_yaml}".bak.* 2>/dev/null | head -1)
  local latest_custom=$(ls -t "${values_custom}".bak.* 2>/dev/null | head -1)

  if [ -n "$latest_values" ]; then
    cp -v "$latest_values" "$values_yaml" || { echo -e "${RED}错误: 恢复 values.yaml 失败${NC}"; exit 1; }
  fi
  if [ -n "$latest_custom" ]; then
    cp -v "$latest_custom" "$values_custom" || { echo -e "${RED}错误: 恢复 values-custom.yaml 失败${NC}"; exit 1; }
  fi

  echo -e "\n${YELLOW}[回滚] 重新应用旧配置...${NC}"
  upgrade_components
  sleep 2
}

# ------------------------------ 主逻辑 ------------------------------
main() {
  case "${1:-}" in
    -v|--version)
      echo -e "${GREEN}Version 1.1.2 for DeepFlow v6.6.9${NC}"
      ;;
    -h|--help)
      usage
      ;;
    -p|--push)
      current_step=2
      import_images
      push_images
      ;;
    -u|--upgrade)
      current_step=6
      backup_files
      update_image_tags
      update_custom_version
      upgrade_components
      ;;
    -r|--rollback)
      rollback_changes
      ;;
    *)
      echo -e "${RED}错误: 无效参数${NC}"
      usage
      exit 1
      ;;
  esac
}

main "$@"