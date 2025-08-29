#!/bin/bash
#########################################################
# Function : DeepFlow 资源预计及统计工具                   #
# Platform : All Linux Based Platform                   #
# Version  : 1.0                                        #
# Date     : 2024-05-20                                 #
# Author   : yongshun                                     #
# Contact  : yongshun@yunshan.net                         #
# Company  : YunShan                                    #
# 备注：
# 1. 仅支持在部署了 deepflow 的环境快速评估 ClickHouse 磁盘容量 #
# 2. 必须在首节点执行 #
# 3. 必须能够使用 k8s node 名称 ssh #
#########################################################

# 任何命令返回非零退出状态（即失败）时立即退出，不再往下执行
set -o errexit
# 尝试访问未定义的变量时立即退出，不继续w往下执行
set -o nounset
# 管道命令返回最后一个非零退出状态的值作为整个管道的退出状态，而不是默认情况下只返回最后一个命令的退出状态
# set -o pipefail

# Set logging colors
NORMAL_COL="\033[0m"
RED_COL="\033[1;31m"
GREEN_COL="\033[1;32m"
YELLOW_COL="\033[1;33m"
BLUE_COL="\033[1;36m"
WHITE_COL="\033[1;37m"

debuglog(){ printf "${NORMAL_COL}%s${NORMAL_COL}\n" "$@"; }
infolog(){ printf "${GREEN_COL}%s${NORMAL_COL}\n" "$@"; }
warnlog(){ printf "${YELLOW_COL}%s${NORMAL_COL}\n" "$@"; }
errorlog(){ printf "${RED_COL}%s${NORMAL_COL}\n" "$@"; }

# ClickHouse 查询SQL
## 时序图最早保留时间
L4_PACKET_LOCAL_SQL="select partition,database,table,formatReadableSize(sum(bytes_on_disk)),disk_name from system.parts where database='flow_log' and table='l4_packet_local' group by partition,database,table,disk_name order by partition asc limit 10;"
## 调用日志最早保留时间
L7_FLOW_LOG_SQL="select partition,database,table,formatReadableSize(sum(bytes_on_disk)),disk_name from system.parts where database='flow_log' and table='l7_flow_log_local' group by partition,database,table,disk_name order by partition asc limit 10;"
## 流日志最早保留时间
L4_FLOW_LOG_SQL="select partition,database,table,formatReadableSize(sum(bytes_on_disk)),disk_name from system.parts where database='flow_log' and table='l4_flow_log_local' group by partition,database,table,disk_name order by partition asc limit 10;"
## 指标数据最早保留时间
FLOW_METRICS_SQL="select partition,database,table,formatReadableSize(sum(bytes_on_disk)),disk_name from system.parts where database='flow_metrics' group by partition,database,table,disk_name order by partition asc limit 10;"
# 指获取 Clickhouse 每节点每个表指定时间段内的磁盘消耗量，重点关注 L4/L7 flow_log
# 默认获取最近一天的数据量，可以通过传参指定时间
START_TIME=${2:-$(date -d "1 day ago" +"%Y-%m-%d %H:%M:%S")}
END_TIME=${3:-$(date +"%Y-%m-%d %H:%M:%S")}
SPACE_PER_TABLE_PER_NODE="select database,table,formatReadableSize(sum(bytes_on_disk)) from system.parts where partition>='$START_TIME' and partition<'$END_TIME' group by database,table order by sum(bytes_on_disk) desc"

# 获取操作类型
OP_TYPE=${1:-""}
# 定义作用名称空间
NAMESPACE=deepflow
# 定义作用 kubectl 客户端
KUBECTL=`which kubectl`

if [ x"${KUBECTL}" == x"" ]; then
  errorlog "【ERROR】kubectl 客户端不存在; 请先检查当前机器是否安装 kubectl 且拥有 kubenertes 集群管理权限！！！"
  exit 0
fi

# 定义 clickhouse 服务相关信息
CK_POD_NAME=(`${KUBECTL} get pod -n ${NAMESPACE} | grep clickhouse | awk '{print $1}'`)
NODE_NAME=(`${KUBECTL} get pod -n ${NAMESPACE} -owide | grep clickhouse | awk '{print $(NF-2)}'`)


# 使用方法
function usage() {
    echo  "【Usage】"
    echo -e "  ${BLUE_COL}$0 [show|get] [start_time] [end_time]${NORMAL_COL}"
    echo
    echo  "【Example】"
    echo -e "  计算所有数据节点每张表的数据量(默认查询最近一天): ${BLUE_COL}$0 get${NORMAL_COL}"
    echo -e "  计算所有数据节点每张表的数据量(自定义时间段): ${BLUE_COL}$0 get \"2024-05-14 12:00:00\" \"2024-05-15 00:00:00\"${NORMAL_COL}"
    echo -e "  查询所有数据节点的 ClickHouse 库数据占用情况(默认查询最近一天): ${BLUE_COL}$0 show${NORMAL_COL}"
    echo -e "  查询所有数据节点的 ClickHouse 库数据占用情况(自定义时间段): ${BLUE_COL}$0 show \"2024-05-14 12:00:00\" \"2024-05-15 00:00:00\"${NORMAL_COL}"
    echo
}

# clickhouse 登陆方法
function query_ck() {
  ${KUBECTL} exec -it  ${ck} -n ${NAMESPACE} -c clickhouse -- clickhouse-client --password "YSDeepFlow@3q302" -q "$1" | column -t -s $'\t'
}

function show_controller_base() {
  # 资源统计
  infolog "0. 资源统计"
  tsdb_count=(`echo ${NODE_NAME} | wc -l`)
  echo "总计 ${tsdb_count} 个数据节点"
  echo "总计 `deepflow-ctl agent list | grep -v EXCEPTIONS | wc -l` 个采集器"
  echo

  # 获取各个控制器节点的负载
  infolog "1. 获取各个数据节点的负载"
  for node in ${NODE_NAME[@]}; do
    infolog "➜ 「${node}」 CPU核心数:`ssh $node nproc`"
    ssh $node uptime
    echo
  done

  # 获取各个数据节点的 CPU 使用率
  infolog "2. 获取各个数据节点的 CPU 使用率"
  for node in ${NODE_NAME[@]}; do
    cpu_usage=$(ssh $node top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    infolog "➜ 「${node}」: ${cpu_usage}%"
    echo
  done

  # 获取各个控制器节点的内存使用率
  infolog "3. 获取各个数据节点的内存使用率"
  for node in ${NODE_NAME[@]}; do
    memory_usage=$(ssh $node /usr/bin/free |grep Mem|awk '{print int($3/$2 * 100)}')
    infolog "➜ 「${node}」: ${memory_usage}%"
    echo
  done

  # 获取各个控制器节点磁盘使用率
  infolog "4. 获取各个数据节点的磁盘使用率"
  for node in ${NODE_NAME[@]}; do
    infolog "➜ 「${node}」"
    ssh $node df -h|egrep -v "^shm|^over|^tmp"
    echo
  done

}

function show_ck_earliest_data() {
  # 5. 获取最早的调用日志
  infolog "5. 获取最早的调用日志"
  for ck in ${CK_POD_NAME[@]}; do
    infolog "➜ 「${ck}」"
    query_ck "${L7_FLOW_LOG_SQL}"
    echo
  done

  # 6. 获取最早的流日志
  infolog "6. 获取最早的流日志"
  for ck in ${CK_POD_NAME[@]}; do
    infolog "➜ 「${ck}」"
    query_ck "${L4_FLOW_LOG_SQL}"
    echo
  done

  # 7. 获取最早的指标数据
  infolog "7. 获取最早的指标数据"
  for ck in ${CK_POD_NAME[@]}; do
    infolog "➜ 「${ck}」"
    query_ck "${FLOW_METRICS_SQL}"
    echo
  done

  # 8. 获取最早的时序图
  infolog "8. 获取最早的时序图"
  for ck in ${CK_POD_NAME[@]}; do
    infolog "➜ 「${ck}」"
    query_ck "${L4_PACKET_LOCAL_SQL}"
    echo
  done
}

function show_ck_data_space() {
  # 9. 获取 Clickhouse 每节点每个表指定时间段内的磁盘消耗量，重点关注 L4/L7 flow_log
  infolog "9. Clickhouse 每个节点中每个表磁盘消耗量[ $START_TIME - $END_TIME ]"
  for ck in ${CK_POD_NAME[@]}; do
    infolog "➜ 「${ck}」"
    query_ck "${SPACE_PER_TABLE_PER_NODE}"
    echo
  done
}

function convert_to_same_unit() {
  size="$1"
  if [[ "$size" == *"MiB" ]]; then
      size=$(echo "$size" | sed 's/MiB//')
      size=$(echo "$size * 1" | bc)
  elif [[ "$size" == *"GiB" ]]; then
      size=$(echo "$size" | sed 's/GiB//')
      size=$(echo "$size * 1024" | bc)
  elif [[ "$size" == *"TiB" ]]; then
      size=$(echo "$size" | sed 's/TiB//')
      size=$(echo "$size * 1024 * 1024" | bc)
  elif [[ "$size" == *"KiB" ]]; then
      size=$(echo "$size" | sed 's/KiB//')
      size=$(echo "scale=2; $size / 1024" | bc)
  fi
  echo "$size"
}

function get_ck_data_space() {
  echo
  infolog "计算时间范围: [ $START_TIME - $END_TIME ]"
  echo
  infolog "1. 调用日志:"
  for ck in ${CK_POD_NAME[@]}; do
    query_ck "${SPACE_PER_TABLE_PER_NODE}"|grep "l7_flow_log_local"|awk "{print \"${ck}: \"\$3\" \"\$4}"
    echo
  done

  infolog "2. 流日志:"
  for ck in ${CK_POD_NAME[@]}; do
    query_ck "${SPACE_PER_TABLE_PER_NODE}"|grep "l4_flow_log_local"|awk "{print \"${ck}: \"\$3\" \"\$4}"
    echo
  done

  infolog "3. 时序图:"
  for ck in ${CK_POD_NAME[@]}; do
    query_ck "${SPACE_PER_TABLE_PER_NODE}"|grep "l4_packet_local"|awk "{print \"${ck}: \"\$3\" \"\$4}"
    echo
  done

  infolog "4. PCAP 数据:"
  for ck in ${CK_POD_NAME[@]}; do
    query_ck "${SPACE_PER_TABLE_PER_NODE}"|grep "l7_packet_local"|awk "{print \"${ck}: \"\$3\" \"\$4}"
    echo
  done

  infolog "5. Profile 数据:"
  for ck in ${CK_POD_NAME[@]}; do
    query_ck "${SPACE_PER_TABLE_PER_NODE}"|grep "in_process_local"|awk "{print \"${ck}: \"\$3\" \"\$4}"
    echo
  done

  infolog "6. 应用指标数据(秒级):"
  for ck in ${CK_POD_NAME[@]}; do
    vtap_app_1s_local=($(query_ck "${SPACE_PER_TABLE_PER_NODE}"|grep "vtap_app"|grep "1s_local" |awk '{print $3$4}'))
    [ ${#vtap_app_1s_local[@]} -eq 0 ] && echo && continue
    # 计算数组中各个元素的总和
    vtap_app_1s_local_size0=$(convert_to_same_unit "$(echo ${vtap_app_1s_local[0]} |tr -d '\r')")
    vtap_app_1s_local_size1=$(convert_to_same_unit "$(echo ${vtap_app_1s_local[1]} |tr -d '\r')")
    vtap_app_1s_local_total_size=$(echo "$vtap_app_1s_local_size0 + $vtap_app_1s_local_size1" | bc)
    if [ $(echo "${vtap_app_1s_local_total_size} >= 1024"|bc) -eq 1 ]; then
      vtap_app_1s_local_total_size=$(echo "scale=2; $vtap_app_1s_local_total_size / 1024" | bc)
      debuglog "${ck}: ${vtap_app_1s_local_total_size} GiB"
    else
      debuglog "${ck}: ${vtap_app_1s_local_total_size} MiB"
    fi
    echo
  done

  infolog "7. 应用指标数据(分钟级):"
  for ck in ${CK_POD_NAME[@]}; do
    vtap_app_1m_local=(`query_ck "${SPACE_PER_TABLE_PER_NODE}"|grep "vtap_app"|grep "1m_local" |awk '{print $3$4}'`)
    [ ${#vtap_app_1m_local[@]} -eq 0 ] && echo && continue
    # 计算数组中各个元素的总和
    vtap_app_1m_local_size0=$(convert_to_same_unit "$(echo ${vtap_app_1m_local[0]} |tr -d '\r')")
    vtap_app_1m_local_size1=$(convert_to_same_unit "$(echo ${vtap_app_1m_local[1]} |tr -d '\r')")
    vtap_app_1m_local_total_size=$(echo "$vtap_app_1m_local_size0 + $vtap_app_1m_local_size1" | bc)
    if [ $(echo "${vtap_app_1m_local_total_size} >= 1024"|bc) -eq 1 ]; then
      vtap_app_1m_local_total_size=$(echo "scale=2; $vtap_app_1m_local_total_size / 1024" | bc)
      debuglog "${ck}: ${vtap_app_1m_local_total_size} GiB"
    else
      debuglog "${ck}: ${vtap_app_1m_local_total_size} MiB"
    fi
    echo
  done

  infolog "8. 网络指标数据(秒级):"
  for ck in ${CK_POD_NAME[@]}; do
    vtap_flow_1s_local=(`query_ck "${SPACE_PER_TABLE_PER_NODE}"|grep "vtap_flow"|grep "1s_local" |awk '{print $3$4}'`)
    [ ${#vtap_flow_1s_local[@]} -eq 0 ] && echo && continue
    # 计算数组中各个元素的总和
    vtap_flow_1s_local_size0=$(convert_to_same_unit "$(echo ${vtap_flow_1s_local[0]} |tr -d '\r')")
    vtap_flow_1s_local_size1=$(convert_to_same_unit "$(echo ${vtap_flow_1s_local[1]} |tr -d '\r')")
    vtap_flow_1s_local_total_size=$(echo "$vtap_flow_1s_local_size0 + $vtap_flow_1s_local_size1" | bc)
    if [ $(echo "${vtap_flow_1s_local_total_size} >= 1024"|bc) -eq 1 ]; then
      vtap_flow_1s_local_total_size=$(echo "scale=2; $vtap_flow_1s_local_total_size / 1024" | bc)
      debuglog "${ck}: ${vtap_flow_1s_local_total_size} GiB"
    else
      debuglog "${ck}: ${vtap_flow_1s_local_total_size} MiB"
    fi
    echo
  done

  infolog "9. 网络指标数据(分钟级):"
  for ck in ${CK_POD_NAME[@]}; do
    vtap_flow_1m_local=(`query_ck "${SPACE_PER_TABLE_PER_NODE}"|grep "vtap_flow"|grep "1m_local" |awk '{print $3$4}'`)
    [ ${#vtap_flow_1m_local[@]} -eq 0 ] && echo && continue
    # 计算数组中各个元素的总和
    vtap_flow_1m_local_size0=$(convert_to_same_unit "$(echo ${vtap_flow_1m_local[0]} |tr -d '\r')")
    vtap_flow_1m_local_size1=$(convert_to_same_unit "$(echo ${vtap_flow_1m_local[1]} |tr -d '\r')")
    vtap_flow_1m_local_total_size=$(echo "$vtap_flow_1m_local_size0 + $vtap_flow_1m_local_size1" | bc)
    if [ $(echo "${vtap_flow_1m_local_total_size} >= 1024"|bc) -eq 1 ]; then
      vtap_flow_1m_local_total_size=$(echo "scale=2; $vtap_flow_1m_local_total_size / 1024" | bc)
      debuglog "${ck}: ${vtap_flow_1m_local_total_size} GiB"
    else
      debuglog "${ck}: ${vtap_flow_1m_local_total_size} MiB"
    fi
    echo
  done
}


if [ -z "${OP_TYPE}" ] || [ x"${OP_TYPE}" == x"-h" ] || [ x"${OP_TYPE}" == x"--help" ]; then
  usage
elif [ x"${OP_TYPE}" == x"show" ]; then
  TIME_PATTERN="^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"
  if echo ${START_TIME}|grep -qE "${TIME_PATTERN}" && echo ${END_TIME}|grep -qE "${TIME_PATTERN}"; then
    infolog "**********************************************************************************************"
    show_controller_base
    infolog "**********************************************************************************************"
    show_ck_earliest_data
    infolog "**********************************************************************************************"
    show_ck_data_space
  else
    errorlog "【ERROR】时间格式输入错误,请重新输入！！！"
    echo
    usage
  fi
elif [ x"${OP_TYPE}" == x"get" ]; then
  get_ck_data_space
else
  errorlog "【ERROR】命令执行错误,请重新输入！！！"
  echo
  usage
fi

