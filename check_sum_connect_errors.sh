#!/bin/bash

# 定义定时任务时间，默认每分钟执行一次，可按需修改
CRON_TIME="* * * * *"

# 定义 MySQL 登录密码，可根据实际情况修改
#PASSWORD="security421"
PASSWORD="YSDeepFlow@3q302"
# 备用密码，可在需要时取消注释使用
# ALTERNATE_PASSWORD="YSDeepFlow@3q302"

SCRIPT_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")

# 定义日志文件路径
LOG_FILE="/tmp/check_sum_connect_errors_$(date +%Y%m%d).log"

# 定义日志函数
log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$timestamp $level $message" >> "$LOG_FILE"
}

# 定义获取 mysql pod 名的函数
get_mysql_pod() {
    kubectl get pod -n deepflow | grep mysql | awk '{print $1}'
}

# 定义获取 proxysql pod 名的函数
get_proxysql_pod() {
    kubectl get pod -n deepflow | grep proxysql | awk '{print $1}'
}

# 定义执行 SQL 查询的函数
execute_sql() {
    local pod_name=$(get_mysql_pod)
    local sql="$1"
    # 尝试当前密码
    result=$(kubectl exec -n deepflow "$pod_name" -- mysql -p"$PASSWORD" -e "$sql" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "$result"
        return
    fi
    # 如果当前密码失败，尝试备用密码（如果未注释）
    if [ -n "${ALTERNATE_PASSWORD+x}" ]; then
        result=$(kubectl exec -n deepflow "$pod_name" -- mysql -p"$ALTERNATE_PASSWORD" -e "$sql" 2>/dev/null)
        if [ $? -eq 0 ]; then
            echo "$result"
            return
        fi
    fi
    log "ERROR" "Failed to execute SQL query with all provided passwords."
}

# 检测 sum_connect_errors 的函数
check_sum_connect_errors() {
    local result=$(execute_sql "SELECT host,ip,sum_connect_errors from performance_schema.host_cache  where sum_connect_errors >= 1;")
    if [ -n "$result" ]; then
        log "ERROR" "Found sum_connect_errors >= 1:"
        echo "$result" | tail -n +2 | while read -r line; do
            log "ERROR" "$line"
        done
        # 打印 proxysql pod 的最近 50 条日志
        local proxysql_pod=$(get_proxysql_pod)
        log "INFO" "Printing last 50 lines of proxysql pod ($proxysql_pod) logs:"
        kubectl logs -n deepflow "$proxysql_pod" --tail=50 >> "$LOG_FILE"
    else
        log "INFO" "No sum_connect_errors >= 1 found."
    fi
}

# 删除包含当前脚本名称的历史定时任务
delete_cron_jobs() {
    local script_name=$(basename "$0")
    local current_crontab=$(crontab -l 2>/dev/null)
    if echo "$current_crontab" | grep -q "$script_name"; then
        new_crontab=$(echo "$current_crontab" | grep -v "$script_name")
        echo "$new_crontab" | crontab -
        log "INFO" "Deleted all cron jobs containing $script_name."
    fi
}

# 添加定时任务
add_cron_job() {
    local script_name=$(basename "$0")
    (crontab -l 2>/dev/null; echo "$CRON_TIME bash $SCRIPT_DIR/$script_name") | crontab -
    log "INFO" "Added cron job to run $script_name at schedule: $CRON_TIME"
}

# 执行主逻辑
delete_cron_jobs
add_cron_job
check_sum_connect_errors
