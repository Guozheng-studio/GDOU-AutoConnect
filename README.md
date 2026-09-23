# GDOU-AutoConnect

适用于 macOS 的广东海洋大学校园网自动连接与自动登录认证工具。

## 功能

- 登录 macOS 后自动后台运行
- Wi-Fi 断开后自动尝试重新连接 `GDOU.NET`
- 校园网认证失效后自动重新登录
- 使用 macOS 钥匙串保存校园网密码
- 已连接其他可正常上网的 Wi-Fi 或手机热点时不会强制切换
- 支持暂停、恢复、查看状态和卸载

## 使用要求

- macOS
- Python 3.9 或更高版本
- 广东海洋大学 `GDOU.NET` 校园网

## 安装

1. 在 Releases 页面下载 `GDOU-AutoConnect.zip`
2. 解压
3. 双击 `install.command`
4. 按提示输入校园网账号和密码
5. 安装完成后程序会自动在后台运行

如果 macOS 不允许直接双击，可在终端进入项目目录后运行：

```bash
bash install.command
