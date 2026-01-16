#!/bin/bash

# ============================================================================
# Fail2Ban 自动安装配置脚本
# 作者: AiKeS
# 描述: 自动安装和配置 Fail2Ban，保护 SSH 服务免受暴力破解攻击
# ============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        print_info "请使用: sudo $0"
        exit 1
    fi
}

show_help() {
    cat << EOF
用法: $0 [选项]

选项:
    -p, --port PORT         SSH 端口号 (默认: 22)
    -t, --trusted-ips IPS   额外的可信 IP，用空格分隔 (可选)
    -b, --bantime TIME      默认封禁时长 (默认: 1d)
    -f, --findtime TIME     查找时间窗口 (默认: 2m)
    -m, --maxretry NUM      最大重试次数 (默认: 3)
    -u, --use-ufw           启用 UFW 集成
    -h, --help              显示此帮助信息

示例:
    $0 -p 52222
    $0 -p 52222 -t "192.168.1.100 10.0.0.1"

EOF
    exit 0
}

# 默认配置
SSH_PORT="22"
TRUSTED_IPS=""
BANTIME="1d"
FINDTIME="2m"
MAXRETRY="3"
USE_UFW="false"

# 默认忽略的 IP（始终包含）
DEFAULT_IGNORE_IPS="127.0.0.1/8 ::1"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--port) SSH_PORT="$2"; shift 2 ;;
            -t|--trusted-ips) TRUSTED_IPS="$2"; shift 2 ;;
            -b|--bantime) BANTIME="$2"; shift 2 ;;
            -f|--findtime) FINDTIME="$2"; shift 2 ;;
            -m|--maxretry) MAXRETRY="$2"; shift 2 ;;
            -u|--use-ufw) USE_UFW="true"; shift ;;
            -h|--help) show_help ;;
            *) print_error "未知选项: $1"; show_help ;;
        esac
    done
}

validate_port() {
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        print_error "无效的端口号: $SSH_PORT"
        exit 1
    fi
}

# 构建完整的忽略 IP 列表
build_ignore_ips() {
    IGNORE_IPS="$DEFAULT_IGNORE_IPS"
    if [ -n "$TRUSTED_IPS" ]; then
        IGNORE_IPS="$IGNORE_IPS $TRUSTED_IPS"
    fi
}

install_fail2ban() {
    print_info "更新软件包列表..."
    apt update -y

    print_info "安装 Fail2Ban..."
    apt install -y fail2ban

    print_success "Fail2Ban 安装完成"
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

# 封禁动作
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
# =============================================================================
[recidive]
enabled  = true
backend  = systemd
action   = %(banaction_allports)s
findtime = 1d
maxretry = 3
bantime  = 2w
EOF

    print_success "配置文件已生成: /etc/fail2ban/jail.local"
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
    fail2ban-client status sshd || true
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
    echo ""
    echo "常用命令:"
    echo "  查看状态:  fail2ban-client status sshd"
    echo "  解封 IP:   fail2ban-client set sshd unbanip <IP>"
    echo "  封禁 IP:   fail2ban-client set sshd banip <IP>"
    echo ""
}

main() {
    echo ""
    echo "=============================================="
    echo "       Fail2Ban 自动安装配置脚本"
    echo "=============================================="
    echo ""

    check_root
    parse_args "$@"
    validate_port
    build_ignore_ips

    print_info "配置预览:"
    echo "  - SSH 端口: ${SSH_PORT}"
    echo "  - 可信 IP: ${IGNORE_IPS}"
    echo "  - 封禁时长: ${BANTIME}"
    echo ""

    read -p "是否继续安装? [Y/n] (回车默认Y): " -r CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
        print_warning "安装已取消"
        exit 0
    fi

    install_fail2ban
    backup_config
    generate_config
    start_service
    show_summary
    show_status
}

main "$@"
