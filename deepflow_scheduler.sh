#!/bin/bash
NAMESPACE="deepflow"

# 定义副本数
declare -A DEPLOYMENTS=(
    ["acl-controller-deployment"]="1" #控制平面入口点，提供gRPC和HTTP接口
    ["df-web-core-deployment"]="1" #DeepFlow Web界面
    ["master-deepflow-server"]="1" #DeepFlow Server的主控制器
    ["querier-js-deployment"]="1" #提供查询API接口，数据查询的主要入口点
    ["grafana-deployment"]="1" #Grafana Web界面
)
LOG_FILE="/var/log/deepflow_scheduler.log"

RESET='\033[0m'       # 重置颜色为白色
RED='\033[31m'        # 红色 - ERROR 等级
GREEN='\033[32m'      # 绿色 - INFO 等级
YELLOW='\033[33m'     # 黄色 - WARN 等级

log() {
    local level=$1
    local module=$2
    local message=$3
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')

    case $level in
        "INFO") colored_level="${GREEN}[${level}]${RESET}" ;;
        "WARN") colored_level="${YELLOW}[${level}]${RESET}" ;;
        "ERROR") colored_level="${RED}[${level}]${RESET}" ;;
        *) colored_level="[$level]" ;;
    esac

    if [[ "$message" == "脚本执行开始" || "$message" == "脚本执行结束" ]]; then
        local log_line="[$timestamp] ${colored_level} --- ${message} ---"
    else
        local log_line="[$timestamp] ${colored_level} ${message}"
    fi
    
    echo -e "${log_line}" >> "$LOG_FILE"
}


stop_system() {
    for deploy in "${!DEPLOYMENTS[@]}"; do
        log "INFO"  "" "正在停止: $deploy"
        kubectl scale deployments.apps "$deploy" --replicas=0 -n "$NAMESPACE" 2>> "$LOG_FILE"
        if [ $? -eq 0 ]; then
            log "INFO" "" "成功停止: $deploy（副本数已设为0）"
        else
            log "ERROR" "" "停止 $deploy 失败"
        fi
    done
}

start_system() {
    for deploy in "${!DEPLOYMENTS[@]}"; do
        target_replicas=${DEPLOYMENTS[$deploy]}
        log "INFO" "" "正在启动: $deploy（目标副本数: $target_replicas）"
        kubectl scale deployments.apps "$deploy" --replicas="$target_replicas" -n "$NAMESPACE" 2>> "$LOG_FILE"
        if [ $? -eq 0 ]; then
            log "INFO" "" "成功启动: $deploy（副本数已恢复为 $target_replicas）"
        else
            log "ERROR" "" "启动 $deploy 失败（目标副本数: $target_replicas）"
        fi
    done
}


get_current_replicas() {
    local deploy=$1
    kubectl get deployments.apps "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>> "$LOG_FILE"
}

should_stop_system() {
    local hour=$(date +%H)
    local weekday=$(date +%u)  # 1-5=工作日，6-7=周末
    local current_minutes=$((10#$hour * 60 + 10#$(date +%M)))

    # 工作日：16:00-21:00（960-1260分钟）
    if [ $weekday -ge 1 ] && [ $weekday -le 5 ]; then
        [ $current_minutes -ge 960 ] && [ $current_minutes -le 1260 ] && return 0
    # 周末：9:00-21:00（540-1260分钟）
    else
        [ $current_minutes -ge 540 ] && [ $current_minutes -le 1260 ] && return 0
    fi
    return 1
}


main() {
    log "INFO" "" "脚本执行开始"

    for deploy in "${!DEPLOYMENTS[@]}"; do
        if ! kubectl get deployments.apps "$deploy" -n "$NAMESPACE" >/dev/null 2>> "$LOG_FILE"; then
            log "ERROR" "" " $deploy 在命名空间 $NAMESPACE 中不存在，脚本终止"
            exit 1
        fi
    done

    main_deploy="master-deepflow-server"
    current_replicas=$(get_current_replicas "$main_deploy")
    if [ -z "$current_replicas" ]; then
        log "ERROR" "" "无法获取 $main_deploy 的当前副本数，脚本终止"
        exit 1
    fi
    log "INFO" "" "当前系统状态：$main_deploy 副本数 = $current_replicas"


    if should_stop_system; then
        log "INFO" "" "当前处于【关闭时间范围】（工作日16:00-21:00/周末9:00-21:00）"
        if [ "$current_replicas" -ne 0 ]; then
            log "INFO" "" "系统未关闭，执行停止操作"
            stop_system
        else
            log "INFO" "" "系统已关闭（副本数为0），无需操作"
        fi
    else
        log "INFO" "" "当前处于【启动时间范围】"
        target_replicas=${DEPLOYMENTS[$main_deploy]}
        if [ "$current_replicas" -ne "$target_replicas" ]; then
            log "INFO" "" "系统未启动（当前副本数 $current_replicas ≠ 目标副本数 $target_replicas），执行启动操作"
            start_system
        else
            log "INFO" "" "系统已启动（副本数 $current_replicas = 目标副本数 $target_replicas），无需操作"
        fi
    fi

    log "INFO" "" "脚本执行结束"
    echo "" >> "$LOG_FILE"
}

main