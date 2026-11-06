# Fail2BanSetup

> 一键安装配置 Fail2Ban，保护 SSH 服务免受暴力破解攻击。

专为 Debian/Ubuntu 设计，安装后提供 `f2b` 快捷命令，集成白名单管理与一键更新。

---

## 目录

- [功能特性](#功能特性)
- [系统要求](#系统要求)
- [快速开始](#快速开始)
- [命令行参数](#命令行参数)
- [默认策略](#默认策略)
- [f2b 快捷命令](#f2b-快捷命令)
  - [状态查看](#状态查看)
  - [封禁管理](#封禁管理)
  - [白名单管理](#白名单管理)
  - [一键更新](#一键更新)
  - [配置与服务](#配置与服务)
- [日志查看](#日志查看)
- [故障排除](#故障排除)
- [卸载](#卸载)
- [文件结构](#文件结构)
- [安全设计](#安全设计)
- [许可证](#许可证)

---

## 功能特性

- **一键安装** — 自动安装 Fail2Ban 并生成配置
- **SSH 保护** — 自定义端口，aggressive 模式，封禁暴力破解 IP
- **累犯加重** — Recidive 监狱自动惩罚反复被封的"惯犯" IP，封禁时长翻倍
- **白名单管理** — `f2b whitelist/unwhitelist <IP>` 命令直接增删可信 IP，自动 reload
- **一键更新** — `f2b update` 检查 GitHub 远程仓库，自动拉取并用原参数重新安装
- **f2b 快捷命令** — 封装 `fail2ban-client`，无参数时显示交互式帮助，有参数时透明转发
- **可选 UFW 集成** — 通过 UFW 防火墙执行封禁动作
- **配置校验** — 安装时自动校验语法，避免坏配置导致服务启动失败
- **自动备份** — 发现已有配置时自动备份再覆盖

---

## 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Debian / Ubuntu（需 apt 包管理器） |
| 权限 | root 或 sudo |
| 依赖 | apt、systemd |
| 可选 | UFW（使用 `-u` 参数时需要） |

---

## 快速开始

### 默认配置安装（SSH 端口 22）

```bash
git clone https://github.com/AiK3S/Fail2banSetup.git
cd Fail2banSetup
sudo ./install.sh
```

### 自定义 SSH 端口

```bash
sudo ./install.sh -p 22222
```

### 自定义端口 + 可信 IP

```bash
sudo ./install.sh -p 52222 -t "192.168.1.100 10.0.0.1"
```

### 完整参数示例

```bash
sudo ./install.sh -p 22222 -t "192.168.1.100" -b 2d -f 10m -m 5 -u
```

> 安装完成后，输入 `f2b` 即可查看所有可用命令。

---

## 命令行参数

| 参数 | 长参数 | 说明 | 默认值 |
|------|--------|------|--------|
| `-p` | `--port` | SSH 端口号 | `22` |
| `-t` | `--trusted-ips` | 可信 IP 列表，空格分隔，支持 CIDR | 无 |
| `-b` | `--bantime` | 默认封禁时长 | `1d` |
| `-f` | `--findtime` | 查找时间窗口 | `2m` |
| `-m` | `--maxretry` | 最大重试次数 | `3` |
| `-u` | `--use-ufw` | 启用 UFW 集成 | 否 |
| `-h` | `--help` | 显示帮助信息 | — |

**时间单位**：`s`（秒）、`m`（分钟）、`h`（小时）、`d`（天）、`w`（周）

示例：`-b 3600s`、`-b 30m`、`-b 1d`、`-b 1w`

---

## 默认策略

| 监狱 | 说明 | 封禁时长 | 重试次数 | 时间窗口 |
|------|------|----------|----------|----------|
| **sshd** | SSH 暴力破解防护 | 1 周 | 3 次 | 2 分钟 |
| **recidive** | 累犯加重处罚 | 2 周 | 3 次 | 1 天 |

- **sshd** 使用 `aggressive` 模式，能识别更多类型的攻击模式
- **recidive** 监控 Fail2Ban 自身日志，1 天内被封 3 次的 IP 将被封禁 2 周（所有端口）

---

## f2b 快捷命令

安装后自动创建 `/usr/local/bin/f2b`，是 `fail2ban-client` 的封装：

- **无参数调用 `f2b`** → 显示帮助信息与所有命令示例
- **带参数调用 `f2b <args>`** → 透明转发给 `fail2ban-client <args>`
- **自定义子命令** → `whitelist`、`unwhitelist`、`update`

所有 `fail2ban-client` 原生命令均可通过 `f2b` 调用，用法完全一致。

### 状态查看

```bash
f2b                          # 显示帮助（所有命令用法）
f2b status                   # 查看所有监狱概览
f2b status sshd              # 查看 SSH 监狱详情
f2b status recidive          # 查看累犯监狱详情
f2b get sshd banned          # 查看当前被封禁的 IP 列表
f2b ping                     # 检查 fail2ban 是否正常响应
```

### 封禁管理

```bash
f2b set sshd banip 1.2.3.4       # 手动封禁 IP（SSH 监狱）
f2b set sshd unbanip 1.2.3.4     # 手动解封 IP（SSH 监狱）
f2b set recidive banip 1.2.3.4   # 手动封禁 IP（累犯监狱，封所有端口）
f2b set recidive unbanip 1.2.3.4 # 手动解封 IP（累犯监狱）
```

### 白名单管理

白名单中的 IP 永远不会被封禁。命令直接修改 `/etc/fail2ban/jail.local` 中的 `ignoreip` 并自动 reload。

```bash
f2b whitelist 192.168.1.100      # 加入白名单
f2b unwhitelist 192.168.1.100    # 移出白名单

# 支持 CIDR 网段
f2b whitelist 10.0.0.0/24
f2b unwhitelist 10.0.0.0/24

# 也可以用 ignore / unignore 别名
f2b ignore 192.168.1.100
f2b unignore 192.168.1.100
```

特性：
- 重复添加会提示"已在白名单中"，不会重复写入
- 移除不存在的 IP 会提示"不在白名单中"
- 支持 IPv4、IPv6、CIDR 网段格式
- 需要 root 权限

### 一键更新

```bash
sudo f2b update
```

执行流程：
1. 从 GitHub 拉取远程仓库信息（`git fetch`）
2. 比较本地与远程版本，无更新时提示"已经是最新版"
3. 有更新时自动拉取代码（`git pull`）
4. 使用上次的安装参数重新运行 `install.sh`（参数保存在 `/etc/fail2ban/f2b.install_args`）
5. 安装失败时报错退出，不会静默忽略

> **注意**：如果仓库目录有本地修改导致 `git pull` 冲突，需先处理：
> ```bash
> cd Fail2banSetup
> git checkout -- install.sh   # 丢弃本地修改
> sudo f2b update              # 重新更新
> ```

### 配置与服务

```bash
# 配置管理
f2b -t                        # 校验配置语法（改配置后建议先跑）
f2b reload                    # 重新加载所有配置
f2b reload sshd               # 仅重新加载 sshd 监狱
f2b restart                   # 重启 fail2ban 服务

# 服务管理（systemctl）
systemctl status fail2ban     # 查看服务状态
systemctl restart fail2ban    # 重启服务
systemctl enable fail2ban     # 设置开机自启
systemctl disable fail2ban    # 取消开机自启
```

---

## 日志查看

```bash
# 实时跟踪封禁日志
tail -f /var/log/fail2ban.log

# 查看最近的封禁记录
grep "Ban" /var/log/fail2ban.log | tail -20

# 查看最近的解封记录
grep "Unban" /var/log/fail2ban.log | tail -20

# 查看服务日志
journalctl -u fail2ban -n 50 --no-pager
```

---

## 故障排除

### 服务启动失败

```bash
# 校验配置语法
f2b -t

# 查看详细错误
journalctl -u fail2ban -n 50 --no-pager
```

### 误封了自己的 IP

```bash
# 立即解封
f2b set sshd unbanip <你的IP>

# 加入白名单防止再次被封
f2b whitelist <你的IP>
```

### `f2b update` 提示本地修改冲突

```bash
cd Fail2banSetup
git diff install.sh            # 查看改了什么
git checkout -- install.sh     # 丢弃本地修改
sudo f2b update                # 重新更新
```

### `f2b update` 网络超时

GitHub 网络不稳定时 `git fetch` 可能超时，重试即可：

```bash
sudo f2b update
```

---

## 卸载

```bash
# 停止并禁用服务
systemctl stop fail2ban
systemctl disable fail2ban

# 卸载软件包
apt remove --purge fail2ban

# 删除快捷命令
rm -f /usr/local/bin/f2b

# 删除配置（可选）
rm -rf /etc/fail2ban
```

---

## 文件结构

```
Fail2banSetup/
├── install.sh              # 安装脚本（主文件）
├── jail.local.template     # 配置文件模板（供参考）
├── LICENSE                 # MIT 许可证
└── README.md               # 说明文档
```

安装后生成的文件：

```
/usr/local/bin/f2b                    # f2b 快捷命令
/etc/fail2ban/jail.local              # Fail2Ban 配置
/etc/fail2ban/f2b.install_args        # 安装参数（供 f2b update 使用）
```

---

## 安全设计

- **输入校验**：所有用户输入（IP、端口、时间、重试次数）均经过正则格式校验，非法输入直接拒绝
- **注入防护**：可信 IP 列表禁止换行符，防止 heredoc delimiter 注入
- **通配符防护**：校验 IP 时禁用 glob 展开，防止 `*` `?` 匹配文件名
- **配置校验**：安装时自动运行 `fail2ban-client -t` 校验语法，校验失败则不重启服务
- **权限检查**：白名单管理与更新命令检查 root 权限，非 root 运行时拒绝并提示
- **reload 检查**：白名单操作后检查 `fail2ban-client reload` 退出码，失败时报错

---

## 许可证

[MIT License](LICENSE) © 2026 AiKeS
