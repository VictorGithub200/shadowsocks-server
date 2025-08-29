# Shadowsocks Server端一键部署脚本：

## 快速用法（整套命令）：

### 1) 保存脚本
vim /root/ss-rust-install.sh  
把项目中的脚本内容粘贴进去，保存退出

### 2) 赋权并运行

#### 交互式安装：
chmod +x /root/ss-rust-install.sh  
bash /root/ss-rust-install.sh install


#### 无交互安装（提前指定环境变量）：

SS_PASSWORD='你的强密码' SS_PORT=443    SS_METHOD='chacha20-ietf-poly1305' \  
bash /root/ss-rust-install.sh install


## 常用命令：

### 查看配置 + ss:// 链接
bash /root/ss-rust-install.sh showInfo  

### 终端二维码
bash /root/ss-rust-install.sh showQR

### 启动服务
bash /root/ss-rust-install.sh start  

### 重启服务
bash /root/ss-rust-install.sh restart  

### 停止服务
bash /root/ss-rust-install.sh stop  

### 查看日志
bash /root/ss-rust-install.sh showLog  

### 重新交互配置
bash /root/ss-rust-install.sh reconfig   

### 卸载并清理
bash /root/ss-rust-install.sh uninstall  
