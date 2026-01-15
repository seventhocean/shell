#!/bin/bash

function show_help() {
    echo "Usage: $0 [options] <pod_name> <namespace>"
    echo "Options:"
    echo "  --help       Display this help message"
    echo "Examples:"
    echo "  $0 mypod namespace"
    echo "  $0 --help"
}

if [ "$1" == "--help" ]; then
    show_help
    exit 0
fi

if [ $# -lt 2 ]; then
    echo "Error: Insufficient arguments. Use --help for usage information."
    exit 1
fi

pod_name=$1
namespace=$2

pod_info=$(kubectl describe pod $pod_name -n $namespace 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "Error: Failed to get pod information. Check pod name and namespace."
    exit 1
fi

pod_id=$(echo "$pod_info" | grep "containerd://" | awk 'NR==1')
container_id=$pod_id
extracted_id=$(echo "$container_id" | awk -F'containerd://' '{print $2}')

if [ -z "$extracted_id" ]; then
    echo "获取 Pod 的 Container ID 失败，可能是输入的 Pod 信息有误或者格式不匹配。"
    exit 1
else
    echo "获取到的 Pod 的 Container ID 为:$extracted_id"
fi

pid=$(crictl inspect $extracted_id 2>/dev/null | grep -i "\"pid\"" | awk 'NR==1 && /"pid":\s*[0-9]+,/ {split($0, a, ":\\s*"); sub(/,$/, "", a[2]); print a[2]}')
if [ $? -ne 0 -o -z "$pid" ]; then
    echo "获取 PID 失败. 可能是容器信息有误或者 crictl 出现问题。"
    exit 1
else
    echo "获取到的 PID 为:$pid"
fi

# 进入网络命名空间
nsenter -n -t$pid

# # 进行网络测试
# # 测试是否能访问外网的一个地址
# ping_output=$(ping -c 3 8.8.8.8 2>&1)
# if [ $? -eq 0 ]; then
#     echo "成功 Ping 通 8.8.8.8"
# else
#     echo "无法 Ping 通 8.8.8.8"
# fi

# # 查看当前路由表
# route_output=$(route -n)
# echo "当前路由表："
# echo "$route_output"

# # 进行一个域名的 DNS 解析测试
# nslookup_output=$(nslookup google.com 2>&1)
# if [ $? -eq 0 ]; then
#     echo "DNS 解析 google.com 成功"
# else
#     echo "DNS 解析 google.com 失败"
# fi
# echo "DNS 解析输出："
# echo "$nslookup_output"