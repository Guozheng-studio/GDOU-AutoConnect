# GDOU-AutoConnect

GDOU-AutoConnect 是运行在 macOS 当前用户会话中的轻量校园网监控工具。它用 LaunchAgent 在登录后启动，先判断互联网是否正常；只有断网时才检查 Wi-Fi 并按需恢复 `GDOU.NET`。已接入广东海洋大学 SRun 门户：`10.129.1.1`、动态探测并校验的 `ac_id`、`srun_bx1`。

## 暂停与恢复自动连接

双击 `pause.command`，或运行已安装目录中的 `gdou-connect.sh --pause`，会持久化暂停自动连接。暂停后 LaunchAgent 可以继续运行，但不会打开 Wi-Fi、切换网络、认证或重置会话；手动连接热点和手动关闭 Wi-Fi 都不会被干预。双击 `resume.command` 或运行 `--resume` 恢复自动连接。暂停状态保存在当前用户应用目录的普通 `paused` 文件中，重启后仍然有效；重复暂停或恢复都是幂等操作。`status.command` 会显示 `Automation: ACTIVE` 或 `Automation: PAUSED`。

它不会使用 `sudo`、Homebrew、第三方 Python 包，也不会修改 DNS、路由、SIP 或系统安全设置。

## 安装或升级

将整个 `GDOU-AutoConnect` 文件夹保留在同一位置，双击 `install.command`，或在终端运行：

```bash
bash install.command
```

请在图形登录会话中以当前用户运行，不要使用 `sudo`。首次安装会要求输入校园网账号、SSID（回车为 `GDOU.NET`），然后由 macOS `security` 以隐藏输入方式要求输入密码。程序会安装到：

```text
~/Library/Application Support/GDOU-AutoConnect/
```

并创建、加载：

```text
~/Library/LaunchAgents/com.gdou.autoconnect.plist
```

升级已安装版本时，安装器保留原有账号、SSID、检测间隔和同服务名的 Keychain 条目，不会要求再次输入密码；会更新 Shell 脚本、`srun_auth.py`、Python 解释器记录和 LaunchAgent。安装完成后服务立即启动。

安装需要可用的 Python 3.9 或更高版本。它只使用 Python 标准库；未安装可用 Python 时，安装器会停止且不会写入密码。

## 密码与安全

密码只保存在当前用户登录钥匙串的精确条目中：服务名 `GDOU-AutoConnect`，账号为校园网账号。`config` 仅保存账号、SSID、检查间隔与认证冷却时间；密码不进入配置、plist、源码、日志、临时文件或环境变量文件。

认证时，`auth.sh` 使用 `security find-generic-password -w` 将密码的标准输出直接通过管道交给 `srun_auth.py` 的标准输入。Shell 不把密码赋给变量，Python 也不接受密码命令行参数。认证 URL、Cookie、令牌及门户原始响应都不会写入日志。SRun 使用真实登录所需的 HTTP 请求；请只在可信校园网中使用。

运行下面的检查不会提交登录，只验证 SRun 门户、Python、账号配置和 Keychain 条目是否可用：

```bash
bash "$HOME/Library/Application Support/GDOU-AutoConnect/auth.sh" --check
```

需要手动做一次真实认证测试时才运行：

```bash
bash "$HOME/Library/Application Support/GDOU-AutoConnect/auth.sh" --test
```

`--test` 会提交一次 SRun 登录请求。不要在调试命令、截图或日志中粘贴密码、Cookie 或完整认证 URL。

若 `--test` 失败，可运行下面的脱敏诊断。它会进行一次真实 challenge 与登录请求，但只显示阶段、HTTP 状态、响应类型、YES/NO 标志和已知 SRun 状态码；不会显示密码、IP、challenge、token、`ac_id`、加密参数或 URL：

```bash
bash "$HOME/Library/Application Support/GDOU-AutoConnect/auth.sh" --diagnose
```

## 网络行为

每轮检查先用短超时的 `curl` 检测真实互联网。互联网正常时立即结束，无论 SSID 是什么。因此连接 iPhone 热点、其他正常 Wi-Fi 或网线时保持静默，绝不会自动切回 `GDOU.NET`。

只有在下列情形才可能恢复校园网：

- Wi-Fi 没有关联网络，或 Wi-Fi 被关闭；
- 已关联 `GDOU.NET` 但互联网失效；
- 当前网络无互联网、能可靠读到其他 SSID、确认 `GDOU.NET` 可见且复查后关联状态未变化；
- SSID 因 macOS 隐私限制显示 `UNKNOWN`，但本机直接探测到 GDOU SRun 门户。

`UNKNOWN` 不代表未连接。若 SSID 无法读取且互联网正常，程序不做任何操作；若 SSID 无法读取、互联网也异常且 SRun 门户未被确认，程序同样保留当前 Wi-Fi，不切网也不认证。

在 `GDOU.NET` 或经本地 SRun 门户确认的 `UNKNOWN` 状态，认证辅助模块依次请求 `get_challenge`、按 Portal.js 的 xencode 和专用 Base64 规则生成 `info`、计算 HMAC-MD5 与 SHA-1 `chksum`，再请求 `srun_portal`。门户返回 `ok` 或 `login_ok` 后会重新验证互联网；`ip_already_online_error` 不会反复认证；`E2620` 只记录“在线设备数已达上限”，不会踢出任何设备。

登录接口返回成功不等于网络恢复。登录后程序等待 3 秒并连续进行两次真实互联网检测；只有任一次检测成功才记录 `INTERNET_RESTORED` 并视为成功。两次检测都失败时进入 `STALE_SESSION`：它再次确认本机仍处于 SRun 环境，再由 `rad_user_info` 查询**请求来源当前 IP**的会话。只有返回的 IP 与当前 Mac Wi-Fi IP 完全一致、账号也与配置完全一致时，才使用 Portal.js 的普通 `srun_portal?action=logout` 注销该会话一次。它绝不调用 `rad_user_dm`，不会操作账号下的其他设备。

注销后等待 3 秒，认证模块启动一个新的进程重新取得 challenge，并重新计算登录参数后仅登录一次。再次等待 3 秒并检测互联网；仍无网络时记录 `SESSION_RESET_FAILED`，进入既有退避，不再循环注销或登录。`last_session_reset` 存入私有重试状态文件，自动会话重置至少间隔 5 分钟。相关日志事件为 `AUTH_LOGIN_OK`、`AUTH_LOGIN_OK_BUT_OFFLINE`、`STALE_SESSION_DETECTED`、`SELF_LOGOUT`、`FRESH_REAUTH`、`INTERNET_RESTORED` 和 `SESSION_RESET_FAILED`，其中不含认证材料。

故障恢复采用持久化退避：5、10、20、30、60 秒，最大 60 秒。成功恢复互联网后清空失败次数，回到默认 30 秒检查。认证另有默认 60 秒最短间隔，避免反复请求门户。睡眠期间不会轮询；唤醒后下一轮继续检查。进程锁与 LaunchAgent 的 60 秒节流避免重复实例和异常重启循环。

## 状态、日志与手动控制

查看状态：

```bash
bash "$HOME/Library/Application Support/GDOU-AutoConnect/status.command"
launchctl print "gui/$(id -u)/com.gdou.autoconnect"
```

仅运行一轮检查和必要恢复，然后退出：

```bash
bash "$HOME/Library/Application Support/GDOU-AutoConnect/gdou-connect.sh" --once
```

日志在：

```bash
tail -n 80 "$HOME/Library/Logs/gdou-autoconnect.log"
```

单个日志最大 1 MiB，保留 `.1` 到 `.4` 四份历史文件。日志只记录时间、状态和非敏感结果；SSID 仅记录为 `TARGET`、`OTHER` 或 `UNKNOWN`，不会写入实际网络名称。

手动停止或重新启动服务：

```bash
launchctl bootout "gui/$(id -u)/com.gdou.autoconnect"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.gdou.autoconnect.plist"
```

## 修改 SSID 或密码

可编辑安装目录的 `config`，其中不能添加密码：

```text
username=你的账号
ssid=GDOU.NET
check_interval=30
auth_min_interval=60
```

修改后重启 LaunchAgent。若要换 SSID 或账号，请先卸载后重新安装，避免旧账号 Keychain 条目残留。若只更新同一账号的密码，重新运行 `install.command`；升级检测到现有 Keychain 条目时不会覆盖它，因此请先在“钥匙串访问”更新该条目，或删除服务名为 `GDOU-AutoConnect`、账号为该校园网账号的精确条目后再运行安装器。

## 卸载

双击 `uninstall.command`，或运行：

```bash
bash uninstall.command
```

它停止并卸载 LaunchAgent，删除本项目识别到的安装文件与 plist，再询问是否删除**该账号且服务名为 `GDOU-AutoConnect`** 的 Keychain 条目。默认保留密码，日志也会保留供排查。

## 验证恢复行为

1. 连上 `GDOU.NET` 且互联网正常，运行 `--once`：不会认证或切网。
2. 连上 `GDOU.NET` 后使互联网认证失效，运行 `--once`：会在冷却允许时尝试一次 SRun，再验证互联网。
3. 关闭或断开 Wi-Fi，运行 `--once`：会开启 Wi-Fi 并尝试关联 `GDOU.NET`。
4. 连上可正常上网的 iPhone 热点，运行 `--once`：不会切换到 `GDOU.NET`。
5. 观察 `status.command` 显示 `UNKNOWN` 时，若互联网正常，运行 `--once`：不会切网；若同时可确认 SRun 门户，才会尝试认证且不会切换 Wi-Fi。

较新 macOS 可能因隐私限制隐藏 SSID。本项目会依次使用 `networksetup`、`scutil`、`ipconfig` 和 `system_profiler`，但不会自行更改定位或隐私权限。无法确定 SSID 时始终采取保守策略。
