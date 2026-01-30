#!/bin/bash

#######################################################################################################
# ClickHouse 定时清理脚本
# 功能：通过kubectl exec进入ClickHouse Pod执行数据清理操作
#
# 使用方法：
#   ./clickhouse_cleanup.sh              # 正常执行（智能判断是否OPTIMIZE）
#   ./clickhouse_cleanup.sh --force-optimize  # 强制执行OPTIMIZE
#   ./clickhouse_cleanup.sh --skip-optimize   # 跳过OPTIMIZE
#
# Crontab 示例：
#   # 每天凌晨2点执行清理（OPTIMIZE会根据策略自动判断）
#   0 2 * * * /path/to/clickhouse_cleanup.sh >> /var/log/clickhouse_cleanup.log 2>&1
#
#   # 每周日凌晨3点执行并强制OPTIMIZE
#   0 3 * * 0 /path/to/clickhouse_cleanup.sh --force-optimize >> /var/log/clickhouse_cleanup.log 2>&1
#######################################################################################################

# 配置区域 - 请根据实际情况修改
NAMESPACE="deepflow"                    # ClickHouse所在的命名空间
CLICKHOUSE_POD_PREFIX="master-deepflow-clickhouse"     # ClickHouse Pod名称前缀
CLICKHOUSE_CONTAINER="clickhouse"      # ClickHouse容器名称（如果Pod中有多个容器）
CLICKHOUSE_USER="default"              # ClickHouse用户名
CLICKHOUSE_PASSWORD="YSDeepFlow@3q302" # ClickHouse密码（如果有）
LOG_DIR="/mnt/clickhouse_clean/log"        # 日志目录
RETENTION_DAYS=1                       # 保留数据天数（当前设置为1天）

# OPTIMIZE 优化策略配置（每天执行一次的场景）
OPTIMIZE_INTERVAL_DAYS=7               # OPTIMIZE执行间隔（天），默认每周执行一次
OPTIMIZE_MIN_PARTS=10                  # 触发OPTIMIZE的最小parts数量阈值
OPTIMIZE_ON_WEEKDAY=0                  # 指定星期几执行OPTIMIZE（0=周日,1=周一...6=周六,-1=不限制）
ENABLE_SMART_OPTIMIZE=true             # 启用智能OPTIMIZE判断（根据表状态自动决定）

# 运行时参数（通过命令行参数控制）
FORCE_OPTIMIZE=false                   # 强制执行OPTIMIZE（忽略所有检查）
SKIP_OPTIMIZE=false                    # 完全跳过OPTIMIZE

# 清理策略说明：
# - 删除1天前的数据
# - 仅删除正常响应（200、0或NULL）的记录
# - 协议范围：DNS, HTTP, MySQL, Redis, gRPC
# - 保留异常响应数据便于故障分析
#
# OPTIMIZE策略说明（针对每天执行一次的crontab）：
# - 默认每7天执行一次OPTIMIZE（避免每天都占用大量资源）
# - 智能判断：只有当parts数量 >= 10 时才执行
# - 可指定每周固定时间执行（如周日凌晨）
# - OPTIMIZE是重量级操作，建议在业务低峰期执行

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force-optimize)
                FORCE_OPTIMIZE=true
                shift
                ;;
            --skip-optimize)
                SKIP_OPTIMIZE=true
                shift
                ;;
            --help|-h)
                echo "ClickHouse 定时清理脚本"
                echo ""
                echo "用法: $0 [选项]"
                echo ""
                echo "选项："
                echo "  --force-optimize    强制执行OPTIMIZE（忽略所有智能判断）"
                echo "  --skip-optimize     完全跳过OPTIMIZE操作"
                echo "  --help, -h          显示此帮助信息"
                echo ""
                echo "配置参数（在脚本中修改）："
                echo "  RETENTION_DAYS=${RETENTION_DAYS}           # 数据保留天数"
                echo "  OPTIMIZE_INTERVAL_DAYS=${OPTIMIZE_INTERVAL_DAYS}  # OPTIMIZE执行间隔"
                echo "  OPTIMIZE_MIN_PARTS=${OPTIMIZE_MIN_PARTS}       # parts数量阈值"
                echo "  OPTIMIZE_ON_WEEKDAY=${OPTIMIZE_ON_WEEKDAY}      # 指定星期几执行（0=周日,-1=不限制）"
                exit 0
                ;;
            *)
                echo "未知参数: $1"
                echo "使用 --help 查看帮助信息"
                exit 1
                ;;
        esac
    done
}

# 日志配置
LOG_FILE="${LOG_DIR}/cleanup_$(date +%Y%m%d).log"
mkdir -p "${LOG_DIR}"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "${LOG_FILE}"
}

# 检查kubectl是否可用
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl命令不存在，请先安装kubectl"
        exit 1
    fi

    # 检查kubectl连接
    if ! kubectl cluster-info &> /dev/null; then
        log_error "无法连接到Kubernetes集群，请检查kubeconfig配置"
        exit 1
    fi

    log "kubectl检查通过"
}

# 获取ClickHouse Pod列表
get_clickhouse_pods() {
    local pods=$(kubectl get pods -n "${NAMESPACE}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[*].metadata.name}' \
        | tr ' ' '\n' \
        | grep "^${CLICKHOUSE_POD_PREFIX}")

    if [ -z "$pods" ]; then
        log_error "未找到运行中的ClickHouse Pod"
        exit 1
    fi

    echo "$pods"
}

# 在ClickHouse中执行SQL
execute_sql_on_pod() {
    local pod_name=$1
    local sql=$2

    log "在Pod ${pod_name} 上执行SQL: ${sql}"

    # 构建clickhouse-client命令
    local clickhouse_cmd="clickhouse-client"

    if [ -n "${CLICKHOUSE_USER}" ]; then
        clickhouse_cmd="${clickhouse_cmd} --user=${CLICKHOUSE_USER}"
    fi

    if [ -n "${CLICKHOUSE_PASSWORD}" ]; then
        clickhouse_cmd="${clickhouse_cmd} --password=${CLICKHOUSE_PASSWORD}"
    fi

    clickhouse_cmd="${clickhouse_cmd} --query=\"${sql}\""

    # 执行命令
    local result
    if [ -n "${CLICKHOUSE_CONTAINER}" ]; then
        result=$(kubectl exec -n "${NAMESPACE}" "${pod_name}" \
            -c "${CLICKHOUSE_CONTAINER}" \
            -- bash -c "${clickhouse_cmd}" 2>&1)
    else
        result=$(kubectl exec -n "${NAMESPACE}" "${pod_name}" \
            -- bash -c "${clickhouse_cmd}" 2>&1)
    fi

    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log "执行成功: ${result}"
        return 0
    else
        log_error "执行失败: ${result}"
        return 1
    fi
}

# 清理历史数据的SQL示例
cleanup_data() {
    local pod_name=$1
    local cutoff_date=$(date -u -d "${RETENTION_DAYS} days ago" +%Y-%m-%d)

    log "开始在Pod ${pod_name} 上清理 ${cutoff_date} 之前的数据"

    # ===== flow_log.l7_flow_log_local 表清理 =====

    # 1. 查询要删除的数据量
    log "正在统计待删除的数据量..."
    execute_sql_on_pod "${pod_name}" \
        "SELECT
            count(*) as will_delete_count,
            formatReadableSize(sum(data_uncompressed_bytes)) as will_delete_size
         FROM system.parts
         WHERE database = 'flow_log' AND table = 'l7_flow_log_local' AND active"

    execute_sql_on_pod "${pod_name}" \
        "SELECT count(*) as matching_rows
         FROM flow_log.l7_flow_log_local
         WHERE time < now() - INTERVAL 1 DAY
           AND l7_protocol_str IN ('DNS', 'HTTP', 'MySQL', 'Redis', 'gRPC')
           AND (response_code = 200 OR response_code = 0 OR response_code IS NULL)"

    # 2. 执行删除操作
    log "开始删除 l7_flow_log_local 表中1天前的正常响应数据..."
    execute_sql_on_pod "${pod_name}" \
        "ALTER TABLE flow_log.l7_flow_log_local
         DELETE WHERE
             time < now() - INTERVAL 1 DAY
             AND l7_protocol_str IN ('DNS', 'HTTP', 'MySQL', 'Redis', 'gRPC')
             AND (
                 response_code = 200
                 OR response_code = 0
                 OR response_code IS NULL
             )"

    if [ $? -eq 0 ]; then
        log "删除操作提交成功（异步执行中）"
    else
        log_error "删除操作失败"
        return 1
    fi

    # 3. 等待几秒让删除操作开始处理
    sleep 5

    # 4. 查看删除进度（兼容 ClickHouse 23.8.7）
    log "查询删除操作状态..."
    execute_sql_on_pod "${pod_name}" \
        "SELECT
            command,
            create_time,
            is_done,
            parts_to_do
         FROM system.mutations
         WHERE database = 'flow_log' AND table = 'l7_flow_log_local'
         ORDER BY create_time DESC
         LIMIT 5"

    log "Pod ${pod_name} 数据清理完成（异步执行中，可能需要一段时间完成）"
}

# 检查是否需要执行OPTIMIZE
should_run_optimize() {
    local pod_name=$1
    local current_weekday=$(date +%w)  # 0=周日, 1=周一, ..., 6=周六

    # 检查0: 命令行参数优先级最高
    if [ "$SKIP_OPTIMIZE" = "true" ]; then
        log "通过命令行参数跳过OPTIMIZE（--skip-optimize）"
        return 1
    fi

    if [ "$FORCE_OPTIMIZE" = "true" ]; then
        log "通过命令行参数强制执行OPTIMIZE（--force-optimize）"
        return 0
    fi

    # 检查1: 是否启用智能优化
    if [ "$ENABLE_SMART_OPTIMIZE" != "true" ]; then
        log "智能OPTIMIZE判断已禁用，跳过OPTIMIZE"
        return 1
    fi

    # 检查2: 检查是否到了指定的星期几
    if [ "$OPTIMIZE_ON_WEEKDAY" -ne -1 ] && [ "$current_weekday" -ne "$OPTIMIZE_ON_WEEKDAY" ]; then
        log "今天不是OPTIMIZE执行日（配置为星期${OPTIMIZE_ON_WEEKDAY}，今天是星期${current_weekday}），跳过OPTIMIZE"
        return 1
    fi

    # 检查3: 检查距离上次OPTIMIZE的时间
    local last_optimize_file="${LOG_DIR}/.last_optimize"
    if [ -f "$last_optimize_file" ]; then
        local last_optimize_time=$(cat "$last_optimize_file")
        local current_time=$(date +%s)
        local days_since_optimize=$(( (current_time - last_optimize_time) / 86400 ))

        if [ "$days_since_optimize" -lt "$OPTIMIZE_INTERVAL_DAYS" ]; then
            log "距离上次OPTIMIZE只有${days_since_optimize}天（配置间隔${OPTIMIZE_INTERVAL_DAYS}天），跳过OPTIMIZE"
            return 1
        fi
    fi

    # 检查4: 查询表的parts数量
    log "检查表的parts数量..."
    local parts_count=$(kubectl exec -n "${NAMESPACE}" "${pod_name}" \
        -c "${CLICKHOUSE_CONTAINER}" -- bash -c \
        "clickhouse-client --user=${CLICKHOUSE_USER} --password=${CLICKHOUSE_PASSWORD} \
         --query='SELECT count(*) FROM system.parts WHERE database='\''flow_log'\'' AND table='\''l7_flow_log_local'\'' AND active'" 2>/dev/null | tr -d '[:space:]')

    if [ -z "$parts_count" ] || ! [[ "$parts_count" =~ ^[0-9]+$ ]]; then
        log_error "无法获取parts数量，跳过OPTIMIZE"
        return 1
    fi

    log "当前表有 ${parts_count} 个活动parts（阈值: ${OPTIMIZE_MIN_PARTS}）"

    if [ "$parts_count" -lt "$OPTIMIZE_MIN_PARTS" ]; then
        log "parts数量未达到阈值，无需执行OPTIMIZE"
        return 1
    fi

    # 检查5: 检查是否有未完成的mutations
    local pending_mutations=$(kubectl exec -n "${NAMESPACE}" "${pod_name}" \
        -c "${CLICKHOUSE_CONTAINER}" -- bash -c \
        "clickhouse-client --user=${CLICKHOUSE_USER} --password=${CLICKHOUSE_PASSWORD} \
         --query='SELECT count(*) FROM system.mutations WHERE database='\''flow_log'\'' AND table='\''l7_flow_log_local'\'' AND is_done=0'" 2>/dev/null | tr -d '[:space:]')

    if [ -n "$pending_mutations" ] && [ "$pending_mutations" -gt 0 ]; then
        log "发现 ${pending_mutations} 个未完成的mutations，建议等待mutations完成后再执行OPTIMIZE"
        log "提示：可以下次执行时自动优化，或手动执行OPTIMIZE"
        return 1
    fi

    log "✓ 满足OPTIMIZE执行条件：parts数=${parts_count}, 无待处理mutations"
    return 0
}

# 优化表（智能执行）
optimize_tables() {
    local pod_name=$1

    log "开始检查是否需要执行表优化..."

    # 判断是否需要执行OPTIMIZE
    if ! should_run_optimize "${pod_name}"; then
        log "根据当前策略，跳过OPTIMIZE操作"
        return 0
    fi

    log "========== 开始执行 OPTIMIZE 操作 =========="

    # 优化 l7_flow_log_local 表，释放被删除数据占用的空间
    log "正在优化 l7_flow_log_local 表（这可能需要较长时间，请耐心等待）..."

    local optimize_start_time=$(date +%s)
    execute_sql_on_pod "${pod_name}" \
        "OPTIMIZE TABLE flow_log.l7_flow_log_local FINAL"

    if [ $? -eq 0 ]; then
        local optimize_end_time=$(date +%s)
        local optimize_duration=$((optimize_end_time - optimize_start_time))

        log "✓ 表优化完成，耗时: ${optimize_duration}秒，磁盘空间已释放"

        # 记录本次OPTIMIZE时间
        echo "$optimize_end_time" > "${LOG_DIR}/.last_optimize"

        # 查看表的当前状态
        log "查询优化后的表状态..."
        execute_sql_on_pod "${pod_name}" \
            "SELECT
                count(*) as total_parts,
                formatReadableSize(sum(data_uncompressed_bytes)) as total_size_uncompressed,
                formatReadableSize(sum(data_compressed_bytes)) as total_size_compressed,
                round(sum(data_compressed_bytes) * 100.0 / sum(data_uncompressed_bytes), 2) as compression_ratio
             FROM system.parts
             WHERE database = 'flow_log' AND table = 'l7_flow_log_local' AND active"
    else
        log_error "表优化失败"
        return 1
    fi

    log "========== OPTIMIZE 操作完成 =========="
}

# 生成执行摘要报告
generate_summary_report() {
    local pod_name=$1

    log ""
    log "========== 执行摘要报告 =========="

    # 查询当前表状态
    execute_sql_on_pod "${pod_name}" \
        "SELECT
            'flow_log.l7_flow_log_local' as table_name,
            count(*) as active_parts,
            formatReadableSize(sum(data_uncompressed_bytes)) as total_size_uncompressed,
            formatReadableSize(sum(data_compressed_bytes)) as total_size_compressed,
            round(sum(data_compressed_bytes) * 100.0 / sum(data_uncompressed_bytes), 2) as compression_ratio_percent
         FROM system.parts
         WHERE database = 'flow_log' AND table = 'l7_flow_log_local' AND active"

    # 查询最近的mutations状态
    log "最近的mutations状态:"
    execute_sql_on_pod "${pod_name}" \
        "SELECT
            command,
            create_time,
            is_done,
            formatReadableSize(parts_to_do) as parts_remaining
         FROM system.mutations
         WHERE database = 'flow_log' AND table = 'l7_flow_log_local'
         ORDER BY create_time DESC
         LIMIT 3"

    # 查询磁盘使用情况（修复：先计算百分比，再格式化容量）
    log "磁盘使用情况:"
    execute_sql_on_pod "${pod_name}" \
        "SELECT
            name,
            path,
            formatReadableSize(free_space) as free_space_readable,
            formatReadableSize(total_space) as total_space_readable,
            concat(toString(round((1 - free_space / total_space) * 100, 2)), '%') as used_percent
         FROM system.disks"

    log "=================================="
    log ""
}

# 清理旧日志文件
cleanup_old_logs() {
    log "清理7天前的日志文件"
    find "${LOG_DIR}" -name "cleanup_*.log" -mtime +7 -delete 2>/dev/null
    log "旧日志清理完成"
}

# 主函数
main() {
    log "========== ClickHouse 定时清理任务开始 =========="
    log "执行时间: $(date '+%Y-%m-%d %H:%M:%S %A')"
    log "配置: 保留${RETENTION_DAYS}天数据, OPTIMIZE间隔${OPTIMIZE_INTERVAL_DAYS}天"

    # 显示运行模式
    if [ "$FORCE_OPTIMIZE" = "true" ]; then
        log "运行模式: 强制OPTIMIZE"
    elif [ "$SKIP_OPTIMIZE" = "true" ]; then
        log "运行模式: 跳过OPTIMIZE"
    else
        log "运行模式: 智能OPTIMIZE（自动判断）"
    fi

    # 检查环境
    check_kubectl

    # 获取所有ClickHouse Pod
    local pods=$(get_clickhouse_pods)
    local pod_count=$(echo "$pods" | wc -l)

    log "找到 ${pod_count} 个ClickHouse Pod"

    while IFS= read -r pod; do
        log "========== 开始处理 Pod: ${pod} =========="

        # 执行数据清理（每天执行）
        cleanup_data "${pod}"

        # 执行表优化（智能判断，默认每周执行一次）
        # 会根据以下条件自动判断是否执行：
        # 1. 是否到了指定的执行日期（OPTIMIZE_INTERVAL_DAYS）
        # 2. 表的parts数量是否达到阈值（OPTIMIZE_MIN_PARTS）
        # 3. 是否有未完成的mutations
        # 4. 是否在指定的星期几（OPTIMIZE_ON_WEEKDAY）
        #optimize_tables "${pod}"

        # 生成执行摘要报告
        #generate_summary_report "${pod}"

        log "========== Pod ${pod} 处理完成 =========="
    done <<< "$pods"

    # 清理旧日志
    cleanup_old_logs

    log "========== ClickHouse 定时清理任务完成 =========="
}

# 解析命令行参数并执行主函数
parse_arguments "$@"
main

exit 0
