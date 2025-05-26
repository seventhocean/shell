udo cp /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.bak
# 下载新的 yum 源配置文件（以阿里云为例）
sudo curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo
# 清除 Yum 缓存
sudo yum clean all
# 生成新的 Yum 缓存
sudo yum makecache

yum install -y wget

# 再次下载新的 yum 源配置文件
sudo wget -O /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo
# 清除 Yum 缓存
sudo yum clean all
# 生成新的 Yum 缓存
sudo yum makecache
# 升级软件
yum update -y
# 常用包
yum install -y vim

yum install -y tree 
