# 进行网络测试
# 测试是否能访问外网的一个地址
ping_output=$(ping -c 3 8.8.8.8 2>&1)
if [ $? -eq 0 ]; then
    echo "成功 Ping 通 8.8.8.8"
else
    echo "无法 Ping 通 8.8.8.8"
fi

# 查看当前路由表
route_output=$(route -n)
echo "当前路由表："
echo "$route_output"

# 进行一个域名的 DNS 解析测试
nslookup_output=$(nslookup google.com 2>&1)
if [ $? -eq 0 ]; then
    echo "DNS 解析 google.com 成功"
else
    echo "DNS 解析 google.com 失败"
fi
echo "DNS 解析输出："
echo "$nslookup_output"