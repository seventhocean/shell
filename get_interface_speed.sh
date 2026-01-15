#!/bin/bash
# 功能：统计指定网卡的实时进出口流量速率（rx/tx），自动转换单位
# 使用：./script.sh <网卡名> （例如：./script.sh eth0）

# ======================== 函数定义 ========================
# 单位转换函数：将字节数转换为合适的单位（B/s、KB/s、MB/s、GB/s）
convert_unit() {
    local bytes=$1
    local unit="B/s"
    local rate=$bytes

    # 按1024进制转换单位
    if (( rate >= 1024 )); then
        rate=$(echo "scale=2; $rate/1024" | bc)
        unit="KB/s"
    fi
    if (( $(echo "$rate >= 1024" | bc -l) )); then
        rate=$(echo "scale=2; $rate/1024" | bc)
        unit="MB/s"
    fi
    if (( $(echo "$rate >= 1024" | bc -l) )); then
        rate=$(echo "scale=2; $rate/1024" | bc)
        unit="GB/s"
    fi

    # 格式化输出（保留2位小数，去除末尾多余的0）
    printf "%.2f %s" "$rate" "$unit"
}

# 流量统计函数
monitor_traffic() {
    local nic=$1
    local interval=1  # 统计间隔（秒），可根据需求调整

    # 检查网卡是否存在
    if ! ip link show "$nic" >/dev/null 2>&1; then
        echo "错误：网卡 $nic 不存在！"
        exit 1
    fi

    # 首次获取流量数据（rx/tx）
    read -r rx1 tx1 <<< $(cat /sys/class/net/$nic/statistics/{rx_bytes,tx_bytes})
    if [[ -z "$rx1" || -z "$tx1" ]]; then
        echo "错误：无法读取网卡 $nic 的流量数据！"
        exit 1
    fi

    # 等待统计间隔
    sleep $interval

    # 第二次获取流量数据
    read -r rx2 tx2 <<< $(cat /sys/class/net/$nic/statistics/{rx_bytes,tx_bytes})

    # 计算每秒速率（字节数）
    rx_rate=$((rx2 - rx1))
    tx_rate=$((tx2 - tx1))

    # 转换单位并输出
    echo "========================================"
    echo "网卡 $nic 实时流量速率（统计间隔：$interval 秒）"
    echo "----------------------------------------"
    echo "接收速率（RX）：$(convert_unit $rx_rate)"
    echo "发送速率（TX）：$(convert_unit $tx_rate)"
    echo "========================================"
}

# ======================== 主逻辑 ========================
# 检查传参数量
if [[ $# -ne 1 ]]; then
    echo "使用方法：$0 <网卡名>"
    echo "示例：$0 eth0  或  $0 ens33"
    exit 1
fi

# 执行流量统计
monitor_traffic "$1"
