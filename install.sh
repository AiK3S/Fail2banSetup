#!/bin/bash

# ============================================================================
# Fail2Ban 自动安装配置脚本
# 作者: AiKeS
# 描述: 自动安装和配置 Fail2Ban，保护 SSH 服务免受暴力破解攻击
# ============================================================================

set -e

# 颜色定义（仅在终端输出时启用，避免重定向到文件时污染日志）
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ----------------------------------------------------------------------------
# 前置检查
# ----------------------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        print_info "请使用: sudo $0"
        exit 1
    fi
}

check_os() {
    if ! command -v apt &> /dev/null; then
        print_error "此脚本仅支持 Debian/Ubuntu 系统（需要 apt 包管理器）"
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# 输入校验
# ----------------------------------------------------------------------------

# 校验时间格式: <数字>[s|m|h|d|w]，如 1d, 30m, 3600s
validate_time() {
    local name="$1" value="$2"
    if ! [[ "$value" =~ ^[0-9]+[smhdw]?$ ]]; then
        print_error "无效的${name}: '${value}'（格式: <数字>[s|m|h|d|w]，如 1d、30m、3600s）"
        exit 1
    fi
}

# 校验正整数
validate_positive_int() {
    local name="$1" value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
        print_error "无效的${name}: '${value}'（必须为正整数）"
        exit 1
    fi
}

# 校验单个 IP 或 CIDR 地址
validate_ip() {
    local ip="$1"

    # IPv4 或 IPv4/CIDR
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]{1,2}))?$ ]]; then
        local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}"
        local o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}"
        local cidr="${BASH_REMATCH[6]}"
        for o in "$o1" "$o2" "$o3" "$o4"; do
            if [ "$o" -gt 255 ]; then
                return 1
            fi
        done
        if [ -n "$cidr" ] && [ "$cidr" -gt 32 ]; then
            return 1
        fi
        return 0
    fi

    # IPv6 或 IPv6/CIDR（基本校验：十六进制+冒号，可选 /前缀长度）
    if [[ "$ip" =~ ^[0-9a-fA-F:]+(/([0-9]{1,3}))?$ ]] && [[ "$ip" == *:* ]]; then
        if [[ "$ip" == */* ]]; then
            local v6cidr="${ip#*/}"
            if [ "$v6cidr" -gt 128 ]; then
                return 1
            fi
        fi
        return 0
    fi

    return 1
}

# 校验可信 IP 列表：禁止换行符/heredoc 注入，逐个验证 IP 格式
validate_trusted_ips() {
    if [ -z "$TRUSTED_IPS" ]; then
        return 0
    fi

    # 防止 heredoc delimiter 注入：禁止换行符
    if [[ "$TRUSTED_IPS" == *$'\n'* ]]; then
        print_error "可信 IP 列表不能包含换行符"
        exit 1
    fi

    # 逐个校验 IP（禁用 glob 展开，防止 * ? 等通配符匹配文件名）
    local ip
    set -f
    for ip in $TRUSTED_IPS; do
        if ! validate_ip "$ip"; then
            set +f
            print_error "无效的 IP 地址: '${ip}'"
            exit 1
        fi
    done
    set +f
}

validate_port() {
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        print_error "无效的端口号: ${SSH_PORT}（范围 1-65535）"
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# 帮助信息
# ----------------------------------------------------------------------------

show_help() {
    cat << EOF
用法: $0 [选项]

选项:
    -p, --port PORT         SSH 端口号 (默认: 22)
    -t, --trusted-ips IPS   额外的可信 IP，用空格分隔 (可选)
    -b, --bantime TIME      默认封禁时长 (默认: 1d)
    -f, --findtime TIME     查找时间窗口 (默认: 2m)
    -m, --maxretry NUM      最大重试次数 (默认: 3)
    -u, --use-ufw           Fail2Ban 通过 UFW 封禁（ufw status 可见封禁规则）
        --no-ufw            不设置 UFW 防火墙（已自行管理防火墙时使用）
    -h, --help              显示此帮助信息

时间单位: s(秒) m(分钟) h(小时) d(天) w(周)

示例:
    $0 -p 52222
    $0 -p 52222 -t "192.168.1.100 10.0.0.1"
    $0 -p 22222 -t "192.168.1.100" -b 2d -m 5 -u

EOF
}

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------

# 默认配置
SSH_PORT="22"
TRUSTED_IPS=""
BANTIME="1d"
FINDTIME="2m"
MAXRETRY="3"
USE_UFW="false"
SETUP_UFW="true"

# 默认忽略的 IP（始终包含）
DEFAULT_IGNORE_IPS="127.0.0.1/8 ::1"

# 检查选项是否有参数值，防止 shift 2 越界
require_arg() {
    if [ -z "$2" ]; then
        print_error "选项 '$1' 需要一个参数值"
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--port)          require_arg "$1" "$2"; SSH_PORT="$2"; shift 2 ;;
            -t|--trusted-ips)   require_arg "$1" "$2"; TRUSTED_IPS="$2"; shift 2 ;;
            -b|--bantime)       require_arg "$1" "$2"; BANTIME="$2"; shift 2 ;;
            -f|--findtime)      require_arg "$1" "$2"; FINDTIME="$2"; shift 2 ;;
            -m|--maxretry)      require_arg "$1" "$2"; MAXRETRY="$2"; shift 2 ;;
            -u|--use-ufw)       USE_UFW="true"; shift ;;
            --no-ufw)           SETUP_UFW="false"; USE_UFW="false"; shift ;;
            -h|--help)          show_help; exit 0 ;;
            *)                  print_error "未知选项: $1"; show_help; exit 1 ;;
        esac
    done
}

# 构建完整的忽略 IP 列表
build_ignore_ips() {
    IGNORE_IPS="$DEFAULT_IGNORE_IPS"
    if [ -n "$TRUSTED_IPS" ]; then
        IGNORE_IPS="$IGNORE_IPS $TRUSTED_IPS"
    fi
}

# ----------------------------------------------------------------------------
# 安装与配置
# ----------------------------------------------------------------------------

ensure_ufw() {
    if [ "$SETUP_UFW" = "false" ]; then
        return 0
    fi

    # ① 检查是否安装 UFW，未安装则自动安装
    if ! command -v ufw &> /dev/null; then
        print_info "UFW 未安装，正在自动安装..."
        apt install -y ufw
        print_success "UFW 安装完成"
    fi

    # ② 放行 SSH 端口（在启用 UFW 之前，防止锁死自己）
    print_info "放行 SSH 端口 ${SSH_PORT}/tcp..."
    ufw allow "${SSH_PORT}/tcp" comment "ssh"

    # ③ 检查 UFW 是否已启用，未启用则启用
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        print_info "启用 UFW 防火墙..."
        ufw --force enable
    fi

    # ④ 验证 UFW 确已启用
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        print_error "UFW 启用失败，请手动检查"
        exit 1
    fi

    print_success "UFW 已就绪"
}

install_ufw_hook() {
    # 只在「设置了 UFW 防火墙」且「Fail2Ban 不通过 UFW 封禁」时才需要钩子
    # （USE_UFW=true 时封禁走 UFW，不会被 ufw reload 冲掉，不需要钩子）
    if [ "$SETUP_UFW" = "false" ]; then
        return 0
    fi
    if [ "$USE_UFW" = "true" ]; then
        return 0
    fi

    local hook_file="/etc/ufw/after.init"
    local marker="# BEGIN Fail2Ban 自动恢复钩子"

    # 如果已有钩子，跳过
    if [ -f "$hook_file" ] && grep -q "$marker" "$hook_file" 2>/dev/null; then
        print_info "UFW 自动恢复钩子已存在，跳过"
        return 0
    fi

    # 写入钩子（追加重复执行不会重复添加）
    cat >> "$hook_file" << 'UFW_HOOK'

# BEGIN Fail2Ban 自动恢复钩子（Fail2banSetup）
# UFW 操作后自动重启 Fail2Ban，恢复被 ufw reload 刷掉的 iptables 封禁规则
case "$1" in
    post-start|force-reload)
        systemctl restart fail2ban 2>/dev/null || true
        ;;
esac
# END Fail2Ban 自动恢复钩子（Fail2banSetup）
UFW_HOOK

    chmod +x "$hook_file"
    print_success "UFW 自动恢复钩子已安装（/etc/ufw/after.init）"
}

install_fail2ban() {
    print_info "更新软件包列表..."
    apt update

    print_info "安装 Fail2Ban..."
    apt install -y fail2ban

    print_success "Fail2Ban 安装完成"
}

# 创建 f2b 快捷命令（封装脚本），替代冗长的 fail2ban-client
# 无参数调用时显示简介与命令列表，有参数时透传给 fail2ban-client
setup_f2b_alias() {
    local f2b_path="/usr/local/bin/f2b"

    if ! command -v fail2ban-client &> /dev/null; then
        print_warning "未找到 fail2ban-client，跳过 f2b 快捷命令创建"
        return 0
    fi

    # 如果已存在（旧链接或旧文件），先移除
    if [ -e "$f2b_path" ] || [ -L "$f2b_path" ]; then
        rm -f "$f2b_path"
    fi

    # 获取脚本所在目录（源码仓库路径），用于 f2b update
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # 写入脚本头部（引号 delimiter，不做变量展开）
    cat > "$f2b_path" << 'F2B_HEADER'
#!/bin/bash
# f2b - fail2ban-client 快捷封装
# 无参数调用时显示简介与命令列表，否则透传给 fail2ban-client
# 源码仓库路径（由 install.sh 写入，供 f2b update 使用）
F2B_HEADER

    # 安全写入 REPO_DIR（printf %q 转义路径中的特殊字符，防止 shell 元字符注入）
    printf 'REPO_DIR=%q\n' "$script_dir" >> "$f2b_path"

    # 写入脚本主体（引号 delimiter，不做变量展开）
    cat >> "$f2b_path" << 'F2B_SCRIPT'
if [ $# -eq 0 ]; then
    cat << 'F2B_HELP'
f2b - Fail2Ban 快捷命令 (fail2ban-client 封装)

不带参数时显示此帮助，带参数时直接转发给 fail2ban-client。
所有 f2b 命令均可直接替换为 fail2ban-client，用法完全一致。

【状态查看】
  f2b status                        查看所有监狱概览
  f2b status sshd                   查看 SSH 监狱详情（封禁数、日志路径等）
  f2b status recidive               查看累犯监狱详情
  f2b get sshd banned               查看当前被封禁的 IP 列表
  f2b get sshd logpath              查看 SSH 监狱监控的日志文件路径
  f2b ping                          检查 fail2ban 服务是否正常响应

【封禁管理】
  f2b set sshd banip <IP>           手动封禁指定 IP（SSH 监狱）
  f2b set sshd unbanip <IP>         手动解封指定 IP（SSH 监狱）
  f2b set recidive banip <IP>       手动封禁 IP（累犯监狱，封所有端口）
  f2b set recidive unbanip <IP>     手动解封 IP（累犯监狱）

【白名单管理】
  f2b whitelist <IP>              将 IP 加入白名单（永不封禁）
  f2b unwhitelist <IP>            将 IP 从白名单移除
  (也可用 f2b ignore / f2b unignore 别名)

【更新管理】
  f2b update                       检查并更新到最新版本

【配置管理】
  f2b -t                            校验配置语法（改配置后建议先跑）
  f2b reload                        重新加载配置（修改 jail.local 后执行）
  f2b reload sshd                   仅重新加载 sshd 监狱
  f2b restart                       重启 fail2ban（reload 不够时用）

【服务管理 (systemctl)】
  systemctl status fail2ban         查看服务运行状态
  systemctl restart fail2ban        重启服务
  systemctl enable fail2ban         设置开机自启
  systemctl disable fail2ban        取消开机自启

【日志查看】
  tail -f /var/log/fail2ban.log             实时跟踪封禁日志
  grep "Ban" /var/log/fail2ban.log          查看封禁记录
  grep "Unban" /var/log/fail2ban.log        查看解封记录
F2B_HELP
    exit 0
fi

# --- IP 格式校验（防止注入 sed/配置文件） ---
validate_ip() {
    local ip="$1"
    # IPv4 或 IPv4/CIDR
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]{1,2}))?$ ]]; then
        local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}"
        local o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}"
        local cidr="${BASH_REMATCH[6]}"
        for o in "$o1" "$o2" "$o3" "$o4"; do
            [ "$o" -gt 255 ] && return 1
        done
        if [ -n "$cidr" ] && [ "$cidr" -gt 32 ]; then
            return 1
        fi
        return 0
    fi
    # IPv6 或 IPv6/CIDR（基本校验：十六进制+冒号，可选 /前缀长度）
    if [[ "$ip" =~ ^[0-9a-fA-F:]+(/([0-9]{1,3}))?$ ]] && [[ "$ip" == *:* ]]; then
        if [[ "$ip" == */* ]]; then
            local v6cidr="${ip#*/}"
            [ "$v6cidr" -gt 128 ] && return 1
        fi
        return 0
    fi
    return 1
}

# 白名单管理: 添加可信 IP 到 ignoreip
if [ "$1" = "whitelist" ] || [ "$1" = "ignore" ]; then
    if [ $EUID -ne 0 ]; then
        echo "f2b: 白名单管理需要 root 权限" >&2
        exit 1
    fi
    IP="$2"
    if [ -z "$IP" ]; then
        echo "用法: f2b whitelist <IP>    示例: f2b whitelist 192.168.1.100" >&2
        exit 1
    fi
    if ! validate_ip "$IP"; then
        echo "f2b: 无效的 IP 地址: '${IP}'" >&2
        exit 1
    fi
    if [ ! -f /etc/fail2ban/jail.local ]; then
        echo "f2b: 配置文件 /etc/fail2ban/jail.local 不存在" >&2
        exit 1
    fi
    if grep "^ignoreip =" /etc/fail2ban/jail.local | tr -s ' ' '\n' | grep -qFx "$IP"; then
        echo "f2b: ${IP} 已在白名单中"
        exit 0
    fi
    sed -i "/^ignoreip =/ s|$| ${IP}|" /etc/fail2ban/jail.local
    if ! fail2ban-client reload 2>&1; then
        echo "f2b: reload 失败，IP 已写入配置但未生效，请检查" >&2
        exit 1
    fi
    echo "f2b: 已将 ${IP} 加入白名单"
    exit 0
fi

# 白名单管理: 移除可信 IP
if [ "$1" = "unwhitelist" ] || [ "$1" = "unignore" ]; then
    if [ $EUID -ne 0 ]; then
        echo "f2b: 白名单管理需要 root 权限" >&2
        exit 1
    fi
    IP="$2"
    if [ -z "$IP" ]; then
        echo "用法: f2b unwhitelist <IP>  示例: f2b unwhitelist 192.168.1.100" >&2
        exit 1
    fi
    if ! validate_ip "$IP"; then
        echo "f2b: 无效的 IP 地址: '${IP}'" >&2
        exit 1
    fi
    if [ ! -f /etc/fail2ban/jail.local ]; then
        echo "f2b: 配置文件 /etc/fail2ban/jail.local 不存在" >&2
        exit 1
    fi
    if ! grep "^ignoreip =" /etc/fail2ban/jail.local | tr -s ' ' '\n' | grep -qFx "$IP"; then
        echo "f2b: ${IP} 不在白名单中"
        exit 0
    fi
    # 使用 awk 精确匹配整词删除，避免 sed 子串误匹配（如 1.2.3.4 误删 1.2.3.40 的子串）
    awk -v ip="$IP" '
    /^ignoreip =/ {
        out = $1
        for (i = 2; i <= NF; i++) {
            if ($i != ip) out = out " " $i
        }
        print out
        next
    }
    {print}
    ' /etc/fail2ban/jail.local > /etc/fail2ban/jail.local.tmp && mv /etc/fail2ban/jail.local.tmp /etc/fail2ban/jail.local
    if ! fail2ban-client reload 2>&1; then
        echo "f2b: reload 失败，配置已修改但未生效，请检查" >&2
        exit 1
    fi
    echo "f2b: 已将 ${IP} 从白名单移除"
    exit 0
fi

# 更新管理: 检查远程仓库并自动更新
if [ "$1" = "update" ]; then
    if [ $EUID -ne 0 ]; then
        echo "f2b: 更新需要 root 权限" >&2
        exit 1
    fi
    if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR" ]; then
        echo "f2b: 未找到源码仓库路径，无法自动更新" >&2
        echo "请手动进入仓库目录执行: git pull && sudo ./install.sh" >&2
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo "f2b: git 未安装，请先安装: apt install git" >&2
        exit 1
    fi
    cd "$REPO_DIR" || { echo "f2b: 无法进入仓库目录 $REPO_DIR" >&2; exit 1; }
    echo "f2b: 正在检查更新..."
    if ! git fetch origin 2>&1; then
        echo "f2b: 无法连接远程仓库，请检查网络" >&2
        exit 1
    fi
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse origin/main 2>/dev/null)
    if [ -z "$REMOTE" ]; then
        REMOTE=$(git rev-parse origin/master 2>/dev/null)
    fi
    if [ -z "$REMOTE" ]; then
        echo "f2b: 无法获取远程分支信息" >&2
        exit 1
    fi
    if [ "$LOCAL" = "$REMOTE" ]; then
        echo "f2b: 已经是最新版"
        exit 0
    fi
    echo "f2b: 发现新版本，正在拉取代码..."
    if ! git pull origin main 2>&1; then
        if ! git pull origin master 2>&1; then
            echo "f2b: 拉取代码失败，可能有本地修改冲突" >&2
            echo "请手动执行: cd \"$REPO_DIR\" && git checkout -- install.sh && sudo f2b update" >&2
            exit 1
        fi
    fi
    echo "f2b: 代码已更新，正在重新安装..."
    INSTALL_ARGS=()
    if [ -f /etc/fail2ban/f2b.install_args ]; then
        mapfile -d '' -t INSTALL_ARGS < /etc/fail2ban/f2b.install_args
    fi
    if [ ${#INSTALL_ARGS[@]} -gt 0 ]; then
        echo "f2b: 使用上次的安装参数: ${INSTALL_ARGS[*]}"
    fi
    if ! bash ./install.sh "${INSTALL_ARGS[@]}"; then
        echo "f2b: 重新安装失败，请检查错误信息" >&2
        exit 1
    fi
    exit 0
fi

# 透传给 fail2ban-client
if ! command -v fail2ban-client &> /dev/null; then
    echo "f2b: fail2ban-client 未找到，请确认 Fail2Ban 已安装" >&2
    exit 1
fi
exec fail2ban-client "$@"

F2B_SCRIPT

    chmod +x "$f2b_path"
    print_success "快捷命令已创建: f2b（输入 f2b 查看所有命令用法）"
}

backup_config() {
    if [ -f /etc/fail2ban/jail.local ]; then
        BACKUP_FILE="/etc/fail2ban/jail.local.backup.$(date +%Y%m%d_%H%M%S)"
        print_warning "发现现有配置，备份到: $BACKUP_FILE"
        cp /etc/fail2ban/jail.local "$BACKUP_FILE"
    fi
}

generate_config() {
    print_info "生成 Fail2Ban 配置文件..."

    # UFW 配置行
    UFW_LINE="# banaction = ufw"
    if [ "$USE_UFW" = "true" ]; then
        UFW_LINE="banaction = ufw"
    fi

    # 注意: heredoc 使用未引号 delimiter 以展开变量。
    # 安全性依赖上方 validate_* 函数对所有变量做了格式校验，
    # 确保不含换行符或 delimiter，防止注入。
    cat > /etc/fail2ban/jail.local << EOF
# ============================================================================
# Fail2Ban 本地配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================================

[DEFAULT]
# 忽略的 IP 地址（永不封禁）
ignoreip = ${IGNORE_IPS}

# 默认封禁时长
bantime = ${BANTIME}

# 查找时间窗口
findtime = ${FINDTIME}

# 最大重试次数
maxretry = ${MAXRETRY}

# 封禁动作（如需邮件通知，可改为 action_mwl）
action = %(action_)s[name=%(__name__)s, port="%(port)s"]

# UFW 集成
${UFW_LINE}

# =============================================================================
# SSH 保护
# =============================================================================
[sshd]
enabled  = true
port     = ${SSH_PORT}
backend  = systemd
mode     = aggressive
maxretry = 3
bantime  = 1w

# =============================================================================
# 累犯加重处罚
# 监控 Fail2Ban 自己的日志，惩罚短时间内被多次封禁的"惯犯" IP
# =============================================================================
[recidive]
enabled  = true
backend  = auto
logpath  = /var/log/fail2ban.log
action   = %(banaction_allports)s
findtime = 1d
maxretry = 3
bantime  = 2w
EOF

    print_success "配置文件已生成: /etc/fail2ban/jail.local"
}

# 在重启服务前校验配置语法，避免坏配置导致服务起不来
validate_config() {
    print_info "校验配置语法..."
    if ! fail2ban-client -t 2>&1; then
        print_error "配置语法校验失败，服务未重启"
        print_info "请检查 /etc/fail2ban/jail.local 或从备份恢复"
        exit 1
    fi
    print_success "配置语法校验通过"
}

start_service() {
    print_info "启动 Fail2Ban 服务..."
    systemctl restart fail2ban
    systemctl enable fail2ban
    print_success "Fail2Ban 服务已启动"
}

show_status() {
    echo ""
    print_info "========== 服务状态 =========="
    systemctl status fail2ban --no-pager || true
    echo ""
    print_info "========== SSH 封锁情况 =========="
    f2b status sshd || true
}

show_summary() {
    echo ""
    echo "=============================================="
    print_success "Fail2Ban 安装配置完成！"
    echo "=============================================="
    echo ""
    echo "配置摘要:"
    echo "  - SSH 端口: ${SSH_PORT}"
    echo "  - 可信 IP: ${IGNORE_IPS}"
    echo "  - 封禁时长: ${BANTIME}"
    echo "  - 时间窗口: ${FINDTIME}"
    echo "  - 重试次数: ${MAXRETRY}"
    echo "  - UFW 集成: ${USE_UFW}"
    if [ "$SETUP_UFW" = "true" ]; then
        echo "  - UFW 防火墙: 已启用"
        if [ "$USE_UFW" = "false" ]; then
            echo "  - UFW 自动恢复钩子: 已安装"
        fi
    fi
    echo ""
    echo "常用命令 (f2b = fail2ban-client):"
    echo "  查看所有命令:  f2b"
    echo "  查看状态:      f2b status"
    echo "  查看 SSH:      f2b status sshd"
    echo "  封禁 IP:       f2b set sshd banip <IP>"
    echo "  解封 IP:       f2b set sshd unbanip <IP>
  加入白名单:    f2b whitelist <IP>
  移除白名单:    f2b unwhitelist <IP>"
    echo "  查看封禁列表:  f2b get sshd banned"
    echo "  检查更新:      f2b update"
    echo ""
}

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------

main() {
    echo ""
    echo "=============================================="
    echo "       Fail2Ban 自动安装配置脚本"
    echo "=============================================="
    echo ""

    check_root
    check_os

    parse_args "$@"
    validate_port
    validate_time "封禁时长" "$BANTIME"
    validate_time "查找时间窗口" "$FINDTIME"
    validate_positive_int "最大重试次数" "$MAXRETRY"
    validate_trusted_ips
    build_ignore_ips

    print_info "配置预览:"
    echo "  - SSH 端口: ${SSH_PORT}"
    echo "  - 可信 IP: ${IGNORE_IPS}"
    echo "  - 封禁时长: ${BANTIME}"
    echo "  - UFW 集成: ${USE_UFW}"
    if [ "$SETUP_UFW" = "true" ]; then
        echo "  - UFW 将自动放行 SSH 端口 ${SSH_PORT} 并启用"
        if [ "$USE_UFW" = "false" ]; then
            echo "  - UFW 自动恢复钩子: ufw 操作后自动重启 Fail2Ban 恢复封禁"
        fi
    fi
    echo ""

    # || true 防止 Ctrl+D (EOF) 导致 set -e 异常退出
    read -p "是否继续安装? [Y/n] (回车默认Y): " -r CONFIRM || true
    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
        print_warning "安装已取消"
        exit 0
    fi

    ensure_ufw
    install_fail2ban
    install_ufw_hook
    setup_f2b_alias

    # 保存安装参数供 f2b update 使用（null 分隔，避免 eval）
    printf '%s\0' "$@" > /etc/fail2ban/f2b.install_args

    backup_config
    generate_config
    validate_config
    start_service
    show_summary
    show_status
}

main "$@"
