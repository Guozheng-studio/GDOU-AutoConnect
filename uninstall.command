#!/bin/bash
set -euo pipefail
umask 077

LABEL='com.gdou.autoconnect'
SERVICE='GDOU-AutoConnect'
MARKER='GDOU-AutoConnect Shell installation v2'
APP_DIR="$HOME/Library/Application Support/GDOU-AutoConnect"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
GUI_DOMAIN="gui/$(/usr/bin/id -u)"

fail() { printf '卸载失败：%s\n' "$*" >&2; exit 1; }
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail '只能在 macOS 上运行。'
[[ "$(/usr/bin/id -u)" -ne 0 ]] || fail '请以当前登录用户运行，不要使用 sudo。'
[[ ! -L "$APP_DIR" && ! -L "$PLIST" ]] || fail '发现符号链接，已停止以避免误删。'
if [[ -e "$APP_DIR" ]]; then
    [[ -f "$APP_DIR/.gdou-autoconnect-installation" ]] || fail '安装标记缺失，无法确认目录归属。'
    [[ "$(/bin/cat "$APP_DIR/.gdou-autoconnect-installation")" == "$MARKER" ]] \
        || fail '安装标记不匹配，无法确认目录归属。'
fi
if [[ -e "$PLIST" && ! -e "$APP_DIR" ]]; then
    fail 'LaunchAgent 文件存在但安装目录缺失，无法确认归属。'
fi
if [[ -e "$PLIST" ]]; then
    [[ "$(/usr/bin/plutil -extract Label raw -o - "$PLIST" 2>/dev/null)" == "$LABEL" &&
       "$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$PLIST" 2>/dev/null)" == "$APP_DIR/gdou-connect.sh" ]] \
        || fail 'LaunchAgent 内容不属于本项目，拒绝删除。'
fi
if [[ ! -e "$APP_DIR" && ! -e "$PLIST" ]]; then
    printf '未发现 GDOU-AutoConnect 安装。\n'
    exit 0
fi

account=''
if [[ -f "$APP_DIR/config" ]]; then
    account="$(/usr/bin/sed -n 's/^username=//p' "$APP_DIR/config" | /usr/bin/head -n 1)"
fi

if /bin/launchctl print "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1; then
    /bin/launchctl bootout "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 \
        || fail '无法停止 LaunchAgent。'
fi

if [[ -d "$APP_DIR" ]]; then
    exec 9>> "$APP_DIR/monitor.lock"
    /usr/bin/lockf -s -t 20 9 || fail '监控进程仍在运行，请稍后重试。'
fi

# 仅移除本项目的确切文件；用户后来放入此目录的其他文件会保留。
/bin/rm -f -- "$PLIST"
if [[ -d "$APP_DIR" ]]; then
    /bin/rm -f -- "$APP_DIR/gdou-connect.sh" "$APP_DIR/auth.sh" "$APP_DIR/srun_auth.py" \
        "$APP_DIR/pause.command" "$APP_DIR/resume.command" "$APP_DIR/status.command" "$APP_DIR/config" "$APP_DIR/.gdou-autoconnect-installation" \
        "$APP_DIR/retry.state" "$APP_DIR/python.path" "$APP_DIR/paused"
    exec 9>&-
    /bin/rm -f -- "$APP_DIR/monitor.lock"
    /bin/rmdir "$APP_DIR" 2>/dev/null || printf '目录中还有其他文件，已保留：%s\n' "$APP_DIR"
fi
printf '已停止并卸载 GDOU-AutoConnect。日志仍保留供查看。\n'

if [[ -t 0 ]]; then
    read -r -p '同时删除本项目保存在登录钥匙串中的校园网密码？[y/N] ' answer
    case "$answer" in
        y|Y|yes|YES)
            if [[ -z "$account" ]]; then
                read -r -p '请输入要删除的校园网账号：' account
            fi
            [[ -n "$account" && ! "$account" =~ [[:cntrl:]] ]] \
                || fail '账号无效，未删除钥匙串内容。'
            [[ -f "$LOGIN_KEYCHAIN" ]] || fail '登录钥匙串不存在，未删除钥匙串内容。'
            if /usr/bin/security delete-generic-password -a "$account" -s "$SERVICE" \
                "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
                printf '已删除该账号在 %s 服务下的钥匙串密码。\n' "$SERVICE"
            else
                printf '未找到对应钥匙串项，或删除未完成；其他项未受影响。\n'
            fi
            ;;
        *) printf '已保留钥匙串密码。\n' ;;
    esac
else
    printf '当前非交互终端；已保留钥匙串密码。\n'
fi
