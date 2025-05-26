#!/bin/bash

# 安装 NTP 服务
sudo yum install -y ntp

# 备份原有的配置文件
sudo cp /etc/ntp.conf /etc/ntp.conf.bak

# 配置 NTP 服务器
sudo sed -i '/server 0.centos.pool.ntp.org/d' /etc/ntp.conf
sudo sed -i '/server 1.centos.pool.ntp.org/d' /etc/ntp.conf
sudo sed -i '/server 2.centos.pool.ntp.org/d' /etc/ntp.conf
sudo sed -i '/server 3.centos.pool.ntp.org/d' /etc/ntp.conf

sudo echo "server ntp.aliyun.com" >> /etc/ntp.conf

# 启动 NTP 服务
sudo systemctl start ntpd

# 设为开机启动
sudo systemctl enable ntpd

# 检查 NTP 服务状态
sudo systemctl status ntpd
