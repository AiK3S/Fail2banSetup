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

# 打印函数
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        print_info "请使用: sudo $0"
        exit 1
    fi
}

# 显示帮助
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
    -p, --port PORT         SSH 端口号 (默认: 22)
    -t, --trusted-ips IPS   可信 IP 列表，用空格分隔 (可选)
    -b, --bantime TIME      默认封禁时长 (默认: 1d)
    -f, --findtime TIME     查找时间窗口 (默认: 2m)
    -m, --maxretry NUM      最大重试次数 (默认: 3)
    -u, --use-ufw           启用 UFW 集成
    -h, --help              显示此帮助信息

示例:
    $0 -p 52222
    $0 -p 52222 -t "192.168.1.100 10.0.0.1"
    $0 -p 52222 -t "192.168.1.100" -b 2d -m 5 -u

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

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--port)
                SSH_PORT="$2"
                shift 2
                ;;
            -t|--trusted-ips)
                TRUSTED_IPS="$2"
                shift 2
                ;;
            -b|--bantime)
                BANTIME="$2"
                shift 2
                ;;
            -f|--findtime)
                FINDTIME="$2"
                shift 2
                ;;
            -m|--maxretry)
                MAXRETRY="$2"
                shift 2
                ;;
            -u|--use-ufw)
                USE_UFW="true"
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                print_error "未知选项: $1"
                show_help
                ;;
        esac
    done
}

# 验证端口号
validate_port() {
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        print_error "无效的端口号: $SSH_PORT (必须是 1-65535 之间的数字)"
        exit 1
    fi
}

# 安装 Fail2Ban
install_fail2ban() {
    print_info "更新软件包列表..."
    apt update -y

    print_info "安装 Fail2Ban..."
    apt install -y fail2ban

    print_success "Fail2Ban 安装完成"
}

# 备份现有配置
backup_config() {
    if [ -f /etc/fail2ban/jail.local ]; then
        BACKUP_FILE="/etc/fail2ban/jail.local.backup.$(date +%Y%m%d_%H%M%S)"
        print_warning "发现现有配置，备份到: $BACKUP_FILE"
        cp /etc/fail2ban/jail.local "$BACKUP_FILE"
    fi
}

# 生成配置文件
generate_config() {
    print_info "生成 Fail2Ban 配置文件..."

    # 构建 ignoreip 列表
    IGNORE_IPS="127.0.0.1/8 ::1"
    if [ -n "$TRUSTED_IPS" ]; then
        IGNORE_IPS="$IGNORE_IPS $TRUSTED_IPS"
    fi

    # UFW 配置行
    UFW_LINE="# banaction = ufw"
    if [ "$USE_UFW" = "true" ]; then
        UFW_LINE="banaction = ufw"
    fi

    # 获取脚本所在目录
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    TEMPLATE_FILE="$SCRIPT_DIR/jail.local.template"

    # 检查模板文件是否存在
    if [ -f "$TEMPLATE_FILE" ]; then
        print_info "使用模板文件生成配置..."
        sed -e "s|{{IGNORE_IPS}}|${IGNORE_IPS}|g" \
            -e "s|{{BANTIME}}|${BANTIME}|g" \
            -e "s|{{FINDTIME}}|${FINDTIME}|g" \
            -e "s|{{MAXRETRY}}|${MAXRETRY}|g" \
            -e "s|{{UFW_LINE}}|${UFW_LINE}|g" \
            -e "s|{{SSH_PORT}}|${SSH_PORT}|g" \
            -e "s|{{GENERATED_TIME}}|$(date '+%Y-%m-%d %H:%M:%S')|g" \
            "$TEMPLATE_FILE" > /etc/fail2ban/jail.local
    else
        print_info "模板文件不存在，使用内置配置..."
        generate_config_inline
    fi

    print_success "配置文件已生成: /etc/fail2ban/jail.local"
}

# 内置配置生成（当模板文件不存在时使用）
generate_config_inline() {
    cat > /etc/fail2ban/jail.local << EOF
# ============================================================================
# Fail2Ban 本地配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================================

[DEFAULT]
ignoreip = ${IGNORE_IPS}
bantime = ${BANTIME}
findtime = ${FINDTIME}
maxretry = ${MAXRETRY}
action = %(action_)s[name=%(__name__)s, port="%(port)s"]
${UFW_LINE}

[sshd]
enabled  = true
port     = ${SSH_PORT}
backend  = systemd
mode     = aggressive
maxretry = 3
bantime  = 1w

[recidive]
enabled  = true
backend  = systemd
action   = %(banaction_allports)s
findtime = 1d
maxretry = 3
bantime  = 2w
EOF
}

# 启动服务
start_service() {
    print_info "启动 Fail2Ban 服务..."
    systemctl restart fail2ban

    print_info "设置开机自启..."
    systemctl enable fail2ban

    print_success "Fail2Ban 服务已启动"
}

# 显示状态
show_status() {
    echo ""
    print_info "========== Fail2Ban 状态 =========="
    systemctl status fail2ban --no-pager || true
    
    echo ""
    print_info "========== 监狱状态 =========="
    fail2ban-client status || true
    
    echo ""
    print_info "========== SSH 封锁情况 =========="
    fail2ban-client status sshd || true
}

# 显示摘要
show_summary() {
    echo ""
    echo "=============================================="
    print_success "Fail2Ban 安装配置完成！"
    echo "=============================================="
    echo ""
    echo "配置摘要:"
    echo "  - SSH 端口: ${SSH_PORT}"
    echo "  - 可信 IP: ${IGNORE_IPS}"
    echo "  - 默认封禁时长: ${BANTIME}"
    echo "  - 查找时间窗口: ${FINDTIME}"
    echo "  - 最大重试次数: ${MAXRETRY}"
    echo "  - UFW 集成: ${USE_UFW}"
    echo ""
    echo "常用命令:"
    echo "  查看状态:       systemctl status fail2ban"
    echo "  查看封锁:       fail2ban-client status sshd"
    echo "  解封 IP:        fail2ban-client set sshd unbanip <IP>"
    echo "  封禁 IP:        fail2ban-client set sshd banip <IP>"
    echo ""
}

# 主函数
main() {
    echo ""
    echo "=============================================="
    echo "       Fail2Ban 自动安装配置脚本"
    echo "=============================================="
    echo ""

    check_root
    parse_args "$@"
    validate_port

    print_info "配置预览:"
    echo "  - SSH 端口: ${SSH_PORT}"
    echo "  - 可信 IP: ${TRUSTED_IPS:-无}"
    echo "  - 封禁时长: ${BANTIME}"
    echo ""

    read -p "是否继续安装? [Y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
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
