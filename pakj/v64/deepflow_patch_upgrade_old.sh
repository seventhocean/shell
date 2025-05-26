#!/bin/bash

# 设置脚本在遇到错误时立即退出
set -e

# 定义容器命令选择变量，可取值为"docker"或者"nerdctl -nk8s.io"，用于决定脚本后续使用哪种命令来操作镜像
#CONTAINER_COMMAND="docker"
CONTAINER_COMMAND="nerdctl -nk8s.io"

# 升级后版本变量，修改最后的数字版本号即可
UPGRADE_VERSION="DeepFlow-V6.4.9-106"

# 脚本名称，用于在帮助信息中显示，可根据实际情况修改
SCRIPT_NAME="deepflow_patch_upgrade.sh"

# 全局变量，用于记录当前操作步骤
CURRENT_STEP=0

# 定义镜像文件所在路径变量，默认与脚本在同一目录。
IMAGE_DIR_PATH="."
# 定义 patch_image_tag_list 文件路径变量，默认与脚本在同一目录。
PATCH_IMAGE_TAG_LIST_PATH="patch_image_tag_list.txt"

# 定义 values.yaml 文件路径变量，可根据实际情况修改
VALUES_YAML_PATH="/usr/local/deepflow/templates/values.yaml"
# 定义 values-custom.yaml 文件路径变量，可根据实际情况修改
VALUES_CUSTOM_YAML_PATH="/usr/local/deepflow/templates/values-custom.yaml"

# 定义镜像原本所在仓库地址变量，可根据实际情况修改
ORIGINAL_REPOSITORY_ADDRESS="hub.deepflow.yunshan.net/dev"
# 定义镜像要推送的目标仓库地址变量，可根据实际情况修改
#TARGET_REPOSITORY_ADDRESS="hubmgt-uat.paic.com.cn/deepflow"
TARGET_REPOSITORY_ADDRESS="sealos.hub:5000"

# 显示帮助信息
usage() {
    echo -e "\e[1;33m用法：$SCRIPT_NAME [ --help || -h | --upgrade || -u | --push || -p | --rollback || -r ]\e[0m"
    echo -e "  \e[1;32m--help 或 -h\e[0m: 显示此帮助信息"
    echo -e "  \e[1;32m--push 或 -p\e[0m: 仅执行导入镜像、镜像推送到仓库的操作"
    echo -e "  \e[1;32m--upgrade 或 -u\e[0m: 按顺序执行所有升级步骤（备份文件、替换标签、升级组件）。"
    echo -e "  \e[1;32m--rollback 或 -r\e[0m: 回退到初始状态。"
    echo ""
    echo -e "\e[1;33m更新前准备工作：\e[0m"
    echo -e "  \e[\e[1;32m执行脚本前修改脚本内头部变量 UPGRADE_VERSION="DeepFlow-V6.4.9-xx" 为本次更新版本号"
    echo -e "  \e[1;35m举例\e[0m: 本次更新88号patch,即修改为UPGRADE_VERSION="DeepFlow-V6.4.9-88""
    echo -e "  \e[1;35m注意\e[0m: 执行脚本之前，确保该脚本和售后同学提供的 patch_image_tag_list.txt 在同一目录下"
    echo ""
    echo -e "\e[1;34m脚本执行步骤说明：\e[0m"
    echo -e "  \e[1;35m0\e[0m: 将镜像推送到目标仓库，使新的镜像版本可供使用，推送过程需确保网络连接正常以及认证信息无误。"
    echo -e "  \e[1;35m1\e[0m: 备份 values.yaml 文件，用于在出现问题时可以恢复到原始配置状态。"
    echo -e "  \e[1;35m2\e[0m: 使用 patch_image_tag_list 文件替换 values.yaml 中的镜像标签，确保配置文件与新镜像版本匹配。"
    echo -e "  \e[1;35m3\e[0m: 更新 values-custom.yaml 文件中的 deepflowVersion。"
    echo -e "  \e[1;35m4\e[0m: 依据 patch_image_tag_list 文件，升级本次有变动的组件，完成整个升级流程。"
    echo ""
    echo -e "\e[1;34m以下路径可在脚本头部作为变量进行配置：\e[0m"
    echo -e "  \e[1;36mCONTAINER_COMMAND\e[0m: 用于镜像操作的命令，可取值为'docker'或者'nerdctl -nk8s.io'，默认值：'$CONTAINER_COMMAND'"
    echo -e "  \e[1;36mIMAGE_DIR_PATH\e[0m: 存放 Docker 镜像文件（.tar格式）的目录路径。默认值：'$IMAGE_DIR_PATH'"
    echo -e "  \e[1;36mORIGINAL_REPOSITORY_ADDRESS\e[0m: 镜像原本所在的仓库地址。默认值：'$ORIGINAL_REPOSITORY_ADDRESS'"
    echo -e "  \e[1;36mTARGET_REPOSITORY_ADDRESS\e[0m: 镜像要推送的目标仓库地址。默认值：'$TARGET_REPOSITORY_ADDRESS'"
    echo -e "  \e[1;36mPATCH_IMAGE_TAG_LIST_PATH\e[0m: 包含镜像标签的 patch_image_tag_list.txt 文件的路径。默认值：'$PATCH_IMAGE_TAG_LIST_PATH'"
    echo -e "  \e[1;36mVALUES_YAML_PATH\e[0m: 在升级过程中将会被修改的 values.yaml 文件的路径。默认值：'$VALUES_YAML_PATH'"
    echo -e "  \e[1;36mVALUES_CUSTOM_YAML_PATH\e[0m: 在升级过程中将会被修改的 values-custom.yaml 文件的路径。默认值：'$VALUES_CUSTOM_YAML_PATH'"
}

# 导入镜像
import_images() {
    echo "导入当前目录下所有.tar 格式的 Docker 镜像文件..."
    cd $IMAGE_DIR_PATH
    for i in `ls *.tar`;
    do
        $CONTAINER_COMMAND load -i $i;
        if [ $? -eq 0 ]; then
            echo "导入镜像：$i"
        else
            echo "导入镜像文件 $i 时出现错误，请检查镜像文件完整性及 $CONTAINER_COMMAND 配置。"
            exit 1
        fi
    done
    # 展示已导入的镜像
    #$CONTAINER_COMMAND images
    CURRENT_STEP=5
}


# 镜像push到仓库
push_images_to_repository() {
    for image in $(cat $PATCH_IMAGE_TAG_LIST_PATH | awk -F _tag '{print $1$2}');
    do
        #$CONTAINER_COMMAND tag $ORIGINAL_REPOSITORY_ADDRESS/dev/$image $TARGET_REPOSITORY_ADDRESS/deepflow/$image;
        #$CONTAINER_COMMAND push $TARGET_REPOSITORY_ADDRESS/deepflow/$image;
        $CONTAINER_COMMAND tag $ORIGINAL_REPOSITORY_ADDRESS/$image $TARGET_REPOSITORY_ADDRESS/$image

        $CONTAINER_COMMAND push $TARGET_REPOSITORY_ADDRESS/$image
        if [ $? -eq 0 ]; then
            echo "推送镜像：$image 到仓库 $TARGET_REPOSITORY_ADDRESS"
        else
            echo "推送镜像 $image 到仓库时出错，请检查网络连接、镜像标签及认证信息。"
            exit 1
        fi
    done
    # 展示已推送至目标仓库的镜像
    $CONTAINER_COMMAND images | grep $TARGET_REPOSITORY_ADDRESS/deepflow/
    CURRENT_STEP=6
}


# 步骤一：备份文件
backup_values_yaml() {
    echo "步骤 1：正在备份 values.yaml 文件..."
    cp $VALUES_YAML_PATH $VALUES_YAML_PATH.bakup
    if [ -f $VALUES_YAML_PATH.bakup ]; then
        echo "已成功备份 $VALUES_YAML_PATH 文件，备份文件为 $VALUES_YAML_PATH.bakup，可在以下目录查看：$(dirname $VALUES_YAML_PATH)"
        CURRENT_STEP=1
    else
        echo "备份 values.yaml 文件失败，请检查相关权限及文件路径。"
        exit 1
    fi
    CURRENT_STEP=1
}


# 步骤二：用 tag list 文件替换 values.yaml 中的 tag
replace_tags_in_values_yaml() {
    patch_image_tag_list=$PATCH_IMAGE_TAG_LIST_PATH
    values_yaml=$VALUES_YAML_PATH
    while read -r image_tag; do
        image=$(echo ${image_tag} | awk -F: '{print $1}')
        tag=$(echo ${image_tag} | awk -F: '{print $2}')
        echo "正在替换 $image 的标签为 $tag"
        # 替换镜像标签
        sed -i "s/$image:.*/${image}: ${tag}/g" $values_yaml
        # 去除替换后的标签后面可能存在的回车符
        sed -i 's/\r$//' $values_yaml
    done < "$patch_image_tag_list"
    echo "已完成替换 values.yaml 文件中镜像标签的操作，本次更新的镜像如下："
    # 展示修改后的 values.yaml 文件部分内容（可根据实际调整展示行数等）
    diff $VALUES_YAML_PATH $VALUES_YAML_PATH.bakup
    CURRENT_STEP=2
}


# 步骤三：更新 values-custom.yaml 中的 deepflowVersion
update_deepflowVersion() {
    new_version=$UPGRADE_VERSION
    # 使用 sed 命令替换 deepflowVersion: 后面的值
    sed -iE "s/^deepflowVersion: .*/deepflowVersion: $new_version/g" "$VALUES_CUSTOM_YAML_PATH"

    # 检查 sed 命令的返回状态
    if [ $? -eq 0 ]; then
        echo "已成功更新 values-custom.yaml 文件中的 deepflowVersion 为 $new_version"
        CURRENT_STEP=3
    else
        echo "更新 values-custom.yaml 文件中的 deepflowVersion 失败，请检查 sed 命令及文件权限。"
        exit 1
    fi
}


# 步骤四：升级所有组件
upgrade_deepflow_module() {
    local deepflow_deploy_path="/usr/local/deepflow/bin/deepflow-deploy"

    # 使用 find 命令获取需要升级的目录名
    local dir_names=$(find /usr/local/deepflow/templates/ -maxdepth 1 -type d | egrep -v "grafana-agent|opensource|kube-state-metrics|genesis|pcap-rest|influxdb|diagnose|monitor|telegraf|baseline|database|openebs|dedicated-agent|esxi-agent|bak" | awk -F/ '{print $NF}' | grep -v '^$')

    # 遍历获取到的目录名
    for folder_name in $dir_names; do
        if $deepflow_deploy_path -uo $folder_name; then
            echo "成功升级 $folder_name"
        else
            echo "升级 $folder_name 失败"
            return 1
        fi
    done
    # 如果所有组件都成功升级，输出完成信息
    echo "已完成所有组件升级操作."
    CURRENT_STEP=4
}


# 回退到上一步操作
rollback() {
    echo "正在回退到初始状态..."
    # 先处理 values.yaml 文件的恢复
    if [ -f $VALUES_YAML_PATH.bakup ]; then
        # 删除当前正在使用的 values.yaml 文件（如果存在）
        if [ -f $VALUES_YAML_PATH ]; then
            rm $VALUES_YAML_PATH
        fi
        # 将备份文件重命名为原始的 values.yaml 文件
        mv $VALUES_YAML_PATH.bakup $VALUES_YAML_PATH
        echo "已恢复 $VALUES_YAML_PATH 文件到初始未修改状态"
    else
        echo "没有可用的 values.yaml 备份文件，无法完整恢复到初始状态，回退可能存在问题，请检查。"
    fi
    # 重置当前步骤标记为 0，表示初始状态
    CURRENT_STEP=0
    echo "已回退到初始状态"
}


# 主程序入口，按顺序依次执行各个步骤或处理回退
main() {
    if [ "$1" == "--upgrade" ] || [ "$1" == "-u" ]; then
        # 一键执行所有步骤
        backup_values_yaml
        replace_tags_in_values_yaml
        update_deepflowVersion
        upgrade_deepflow_module
    elif [ "$1" == "--rollback" ] || [ "$1" == "-r" ]; then
        rollback
        upgrade_deepflow_module
    elif [ "$1" == "--push" ] || [ "$1" == "-p" ]; then
        import_images
        push_images_to_repository
    elif [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
        usage
    else
        usage
        exit 1
    fi
}


main "$@"
