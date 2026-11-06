# Fail2Ban 自动安装配置脚本

一个用于自动安装和配置 Fail2Ban 的 Bash 脚本，保护 SSH 服务免受暴力破解攻击。

## 功能特性

- 一键安装 Fail2Ban
- 自定义 SSH 端口配置
- 可信 IP 白名单设置
- 可配置封禁时长和重试次数
- 累犯加重处罚机制 (Recidive)
- 可选 UFW 防火墙集成
- 自动备份现有配置
- f2b 快捷命令（替代 fail2ban-client，输入 f2b 即可查看所有命令用法）

## 系统要求
- 操作系统: Debian / Ubuntu
- 权限: root 或 sudo
- 依赖: apt, systemd

## 文件结构
```
fail2ban-setup/
├── install.sh # 安装脚本
├── jail.local.template # 配置模板
└── README.md # 说明文档
```

## 快速部署

### 一键安装（默认配置，22端口）

```bash
git clone https://github.com/AiK3S/Fail2banSetup.git && cd Fail2banSetup && chmod +x install.sh && sudo ./install.sh
```

### 自定义 SSH 端口（修改最后的端口号）

```bash
git clone https://github.com/AiK3S/Fail2banSetup.git && cd Fail2banSetup && chmod +x install.sh && sudo ./install.sh -p 22222
```

### 自定义端口 + 可信 IP

```bash
git clone https://github.com/AiK3S/Fail2banSetup.git && cd Fail2banSetup && chmod +x install.sh && sudo ./install.sh -p 52222 -t "192.168.1.100 10.0.0.1"
```

### 完整配置示例

```bash
sudo ./install.sh -p 22222 -t "192.168.1.100" -b 2d -m 5 -u
```

## 分步执行
```bash
# 1. 克隆仓库
git clone https://github.com/AiK3S/Fail2banSetup.git

# 2. 进入目录
cd Fail2banSetup

# 3. 添加执行权限
chmod +x install.sh

# 4. 运行安装脚本
sudo ./install.sh -p 你的SSH端口
```

## 命令行参数
| 参数 | 长参数 | 说明 | 默认值 |
|------|--------|------|--------|
| -p | --port | SSH 端口号 | 22 |
| -t | --trusted-ips | 可信 IP 列表 (空格分隔) | 无 |
| -b | --bantime | 默认封禁时长 | 1d |
| -f | --findtime | 查找时间窗口 | 2m |
| -m | --maxretry | 最大重试次数 | 3 |
| -u | --use-ufw | 启用 UFW 集成 | 否 |
| -h | --help | 显示帮助信息 | - |

### 时间单位
- s - 秒
- m - 分钟
- h - 小时
- d - 天
- w - 周

## 默认策略
| 监狱 | 封禁时长 | 重试次数 | 时间窗口 |
|------|----------|----------|----------|
| sshd | 1 周 | 3 次 | 2 分钟 |
| recidive | 2 周 | 3 次 | 1 天 |

## f2b 快捷命令

安装脚本会自动在 `/usr/local/bin/f2b` 创建封装脚本，替代冗长的 `fail2ban-client`。

- **直接输入 `f2b`**：显示简介和所有命令的示例与用法
- **输入 `f2b` + 参数**：直接转发给 `fail2ban-client`，用法完全一致
- 在交互终端、脚本、cron 中均可使用

```bash
# 直接输入 f2b 查看所有命令
f2b
```

## 常用管理命令

### 服务管理
```bash
# 查看状态
systemctl status fail2ban

# 启动/停止/重启
systemctl start fail2ban
systemctl stop fail2ban
systemctl restart fail2ban

# 开机自启
systemctl enable fail2ban
systemctl disable fail2ban
```

### 封禁管理
```bash
# 查看所有监狱状态
f2b status

# 查看 SSH 监狱详情
f2b status sshd

# 手动封禁 IP
f2b set sshd banip 192.168.1.50

# 手动解封 IP
f2b set sshd unbanip 192.168.1.50

# 查看被封禁的 IP
f2b get sshd banned
```

### 白名单管理
```bash
# 将 IP 加入白名单（永不封禁，自动 reload）
f2b whitelist 192.168.1.100

# 将 IP 从白名单移除（自动 reload）
f2b unwhitelist 192.168.1.100

# 也可以用 ignore / unignore 别名
f2b ignore 10.0.0.1
f2b unignore 10.0.0.1
```

### 日志查看
```bash
# 实时查看日志
tail -f /var/log/fail2ban.log

# 查看封禁记录
grep "Ban" /var/log/fail2ban.log | tail -20

# 查看解封记录
grep "Unban" /var/log/fail2ban.log | tail -20
```

## 故障排除
### 服务启动失败
```bash
# 检查配置语法
f2b -t

# 查看错误日志
journalctl -u fail2ban -n 50
```

### 误封自己的 IP
```bash
# 解封 IP
f2b set sshd unbanip <你的IP>

# 将 IP 加入白名单
# 编辑 /etc/fail2ban/jail.local 的 ignoreip 行
# 然后重启服务
systemctl restart fail2ban
```

### 卸载
```bash
systemctl stop fail2ban
systemctl disable fail2ban
apt remove --purge fail2ban
rm -f /usr/local/bin/f2b        # 删除快捷命令
rm -rf /etc/fail2ban            # 可选：删除配置
```

## 更新与清理
```bash
# 更新脚本
cd Fail2banSetup && git pull

# 安装后清理（可选）
cd .. && rm -rf Fail2banSetup
```
