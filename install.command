#!/bin/bash
set -euo pipefail
umask 077

LABEL='com.gdou.autoconnect'
SERVICE='GDOU-AutoConnect'
MARKER='GDOU-AutoConnect Shell installation v2'
APP_DIR="$HOME/Library/Application Support/GDOU-AutoConnect"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_DIR/$LABEL.plist"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
LOG_PATH="$HOME/Library/Logs/gdou-autoconnect.log"
SOURCE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
GUI_DOMAIN="gui/$(/usr/bin/id -u)"
UPGRADE=0
USERNAME=''
SSID=''

fail() { printf '安装失败：%s\n' "$*" >&2; exit 1; }
valid_line() {
    local value="$1"
    [[ -n "$value" && ! "$value" =~ [[:cntrl:]] ]]
}
plist_belongs() {
    [[ "$(/usr/bin/plutil -extract Label raw -o - "$PLIST" 2>/dev/null)" == "$LABEL" &&
       "$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$PLIST" 2>/dev/null)" == "$APP_DIR/gdou-connect.sh" ]]
}
xml_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    value="${value//\'/&apos;}"
    printf '%s' "$value"
}
write_plist() {
    local script_path
    script_path="$(xml_escape "$APP_DIR/gdou-connect.sh")"
    cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$script_path</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>60</integer>
    <key>StandardOutPath</key><string>/dev/null</string>
    <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
EOF
}

find_python() {
    local candidate resolved
    for candidate in /Library/Frameworks/Python.framework/Versions/Current/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        [[ -x "$candidate" ]] || continue
        if [[ "$candidate" == /usr/bin/python3 ]] && ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
            continue
        fi
        if resolved="$("$candidate" -B -c 'import os,sys; assert sys.version_info >= (3,9); print(os.path.realpath(sys.executable))' 2>/dev/null)"; then
            printf '%s' "$resolved"
            return 0
        fi
    done
    return 1
}

[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail '只能在 macOS 上安装。'
[[ "$(/usr/bin/id -u)" -ne 0 ]] || fail '请以当前登录用户运行，不要使用 sudo。'
[[ -t 0 ]] || fail '请在终端交互运行 install.command，以安全输入账号和密码。'
for tool in /usr/bin/security /usr/sbin/networksetup /usr/bin/curl /usr/bin/lockf /usr/bin/plutil /bin/launchctl; do
    [[ -x "$tool" ]] || fail "缺少 macOS 系统命令：$tool"
done
for name in gdou-connect.sh auth.sh srun_auth.py pause.command resume.command status.command; do
    [[ -f "$SOURCE_DIR/$name" ]] || fail "安装包缺少 $name。"
done
[[ ! -L "$APP_DIR" && ! -L "$PLIST" ]] || fail '目标路径为符号链接，请手动检查后重试。'
for name in config monitor.lock paused .gdou-autoconnect-installation; do
    [[ ! -L "$APP_DIR/$name" ]] || fail "安装目标为符号链接：$name"
done
if [[ -e "$APP_DIR" && ! -f "$APP_DIR/.gdou-autoconnect-installation" ]]; then
    fail "目标目录已经存在且不是本项目安装：$APP_DIR"
fi
if [[ -e "$PLIST" && ! -f "$APP_DIR/.gdou-autoconnect-installation" ]]; then
    fail "LaunchAgent 文件已经存在且无法确认归属：$PLIST"
fi
if [[ -e "$PLIST" ]]; then
    plist_belongs || fail "LaunchAgent 内容不属于本项目，拒绝覆盖：$PLIST"
fi
[[ -f "$LOGIN_KEYCHAIN" ]] || fail "找不到登录钥匙串：$LOGIN_KEYCHAIN"
PYTHON="$(find_python)" || fail '需要 Python 3.9 或更新版本来运行 SRun 认证。'

# An existing validated installation is upgraded in place. The plist supplies
# the live directory, so upgrades do not silently assume a source location.
if [[ -f "$APP_DIR/.gdou-autoconnect-installation" && -f "$APP_DIR/config" && ! -L "$APP_DIR/config" ]]; then
    existing_username="$(/usr/bin/sed -n 's/^username=//p' "$APP_DIR/config" | /usr/bin/head -n 1)"
    existing_ssid="$(/usr/bin/sed -n 's/^ssid=//p' "$APP_DIR/config" | /usr/bin/head -n 1)"
    if valid_line "$existing_username" && valid_line "$existing_ssid"; then
        UPGRADE=1
        USERNAME="$existing_username"
        SSID="$existing_ssid"
    fi
fi

wifi_device="$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null | /usr/bin/awk '
    /^Hardware Port: (Wi-Fi|AirPort)$/ { wifi=1; next }
    wifi && /^Device: / { sub(/^Device: /, ""); print; exit }
    /^Hardware Port: / { wifi=0 }
')" || true
printf '安装 GDOU-AutoConnect\n'
if [[ -n "$wifi_device" ]]; then
    printf '检测到 Wi-Fi 接口：%s\n' "$wifi_device"
else
    printf '暂未检测到 Wi-Fi 接口。安装仍可继续，运行时会重新检测。\n'
fi

if (( UPGRADE )); then
    printf '检测到已安装版本，将保留现有账号、SSID、检测间隔和钥匙串密码。\n'
else
    read -r -p '校园网账号：' USERNAME
    valid_line "$USERNAME" || fail '账号不能为空或含控制字符。'
    [[ ${#USERNAME} -le 256 ]] || fail '账号过长。'
    read -r -p 'SSID [GDOU.NET]：' SSID
    SSID="${SSID:-GDOU.NET}"
    valid_line "$SSID" || fail 'SSID 不能为空或含控制字符。'
    [[ ${#SSID} -le 32 ]] || fail 'SSID 超过 32 字节。'
fi
valid_line "$HOME" || fail '用户目录路径含控制字符，无法安全生成 plist。'

# Metadata lookup never reads the password. An upgrade keeps an existing item;
# a fresh installation (or a missing item) asks security itself for it.
if /usr/bin/security find-generic-password -a "$USERNAME" -s "$SERVICE" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
    keychain_present=1
else
    keychain_present=0
fi
if (( ! UPGRADE || ! keychain_present )); then
    keychain_default="$(/usr/bin/security default-keychain -d user 2>/dev/null)" \
        || fail '无法查询默认钥匙串。'
    keychain_default="${keychain_default#"${keychain_default%%[![:space:]]*}"}"
    keychain_default="${keychain_default#\"}"
    keychain_default="${keychain_default%\"}"
    [[ "$keychain_default" == "$LOGIN_KEYCHAIN" ]] \
        || fail '默认钥匙串不是 login.keychain-db；已停止，未写入密码。'
    printf '密码将由 macOS security 直接提示并写入登录钥匙串；终端不会回显。\n'
    /usr/bin/security add-generic-password -U -a "$USERNAME" -s "$SERVICE" \
        -T /usr/bin/security -w \
        || fail '钥匙串保存失败。请确认登录钥匙串已解锁。'
    /usr/bin/security find-generic-password -a "$USERNAME" -s "$SERVICE" \
        "$LOGIN_KEYCHAIN" >/dev/null 2>&1 \
        || fail '无法在登录钥匙串确认保存的条目。'
fi

/bin/mkdir -p "$APP_DIR" "$LAUNCH_DIR" "$HOME/Library/Logs"
/bin/chmod 700 "$APP_DIR"

# 先停止旧服务并取得同一把锁，避免覆盖正在运行的脚本。
if /bin/launchctl print "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1; then
    /bin/launchctl bootout "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 \
        || fail '无法停止旧 LaunchAgent。'
fi
exec 9>> "$APP_DIR/monitor.lock"
/usr/bin/lockf -s -t 20 9 || fail '旧监控进程仍在运行，请稍后重试。'

/usr/bin/install -m 700 "$SOURCE_DIR/gdou-connect.sh" "$APP_DIR/gdou-connect.sh"
/usr/bin/install -m 700 "$SOURCE_DIR/auth.sh" "$APP_DIR/auth.sh"
/usr/bin/install -m 700 "$SOURCE_DIR/srun_auth.py" "$APP_DIR/srun_auth.py"
/usr/bin/install -m 700 "$SOURCE_DIR/pause.command" "$APP_DIR/pause.command"
/usr/bin/install -m 700 "$SOURCE_DIR/resume.command" "$APP_DIR/resume.command"
/usr/bin/install -m 700 "$SOURCE_DIR/status.command" "$APP_DIR/status.command"
if (( ! UPGRADE )); then
    config_tmp="$(/usr/bin/mktemp "$APP_DIR/.config.XXXXXX")"
    {
        printf 'username=%s\n' "$USERNAME"
        printf 'ssid=%s\n' "$SSID"
        printf 'check_interval=30\n'
        printf 'auth_min_interval=60\n'
    } > "$config_tmp"
    /bin/chmod 600 "$config_tmp"
    /bin/mv -f "$config_tmp" "$APP_DIR/config"
fi
printf '%s\n' "$PYTHON" > "$APP_DIR/python.path"
/bin/chmod 600 "$APP_DIR/python.path"
printf '%s\n' "$MARKER" > "$APP_DIR/.gdou-autoconnect-installation"
/bin/chmod 600 "$APP_DIR/.gdou-autoconnect-installation" "$APP_DIR/monitor.lock"

plist_tmp="$(/usr/bin/mktemp "$LAUNCH_DIR/.$LABEL.XXXXXX")"
write_plist "$plist_tmp"
/usr/bin/plutil -lint "$plist_tmp" >/dev/null || fail '生成的 LaunchAgent plist 无效。'
/bin/chmod 600 "$plist_tmp"
/bin/mv -f "$plist_tmp" "$PLIST"
exec 9>&-

/bin/launchctl enable "$GUI_DOMAIN/$LABEL" || fail '无法启用 LaunchAgent。'
/bin/launchctl bootstrap "$GUI_DOMAIN" "$PLIST" || fail '无法加载 LaunchAgent，请检查当前图形登录会话。'
/bin/launchctl print "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || fail 'LaunchAgent 没有成功注册。'
printf '\n安装成功。后台监控已随 LaunchAgent 启动。\n'
printf '运行状态：%s\n' "$APP_DIR/status.command"
printf '日志：%s（轮换保留 4 份）\n' "$LOG_PATH"
printf '卸载：%s\n' "$SOURCE_DIR/uninstall.command"
printf 'SRun 认证已配置；可执行 %s/auth.sh --check 做无登录的连通性检查。\n' "$APP_DIR"
