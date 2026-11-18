# DeviceNap

DeviceNap 是一款 macOS 菜单栏应用。它在 Mac 睡眠前断开你选中的一台蓝牙设备，并在唤醒或登录后尝试重连。其他蓝牙设备照常使用。

[English](README.md) · [贡献指南](CONTRIBUTING.md) · [MIT 许可证](LICENSE)

## 构建和使用

需要 macOS 13 或更新版本和 Xcode 命令行工具（`xcode-select --install`）。从项目根目录运行：

```sh
./build.sh
open build/DeviceNap.app
```

1. 点击菜单栏的月亮图标，在「睡眠时断开的设备」中选择一台已配对的设备。通过蓝牙地址后缀区分同名设备，已连接的设备排在前面。
2. 如需登录时自动重连上次选择的设备，先把 App 移到「应用程序」，再勾选「登录时启动」。
3. 如果系统要求蓝牙权限，在「系统设置 → 隐私与安全性 → 蓝牙」里允许 DeviceNap。测试前请先退出其他管理睡眠蓝牙状态的工具。

DeviceNap 使用 macOS 自带框架，选择保存在本机。应用在断开设备后会保持整机蓝牙开启，系统或外设仍可能在睡眠中自动重连。能否防止鼠标误唤醒取决于设备和 macOS。

## 排查

如果没有自动重连，唤醒蓝牙设备并选择「立即连接」。在菜单栏选择「查看日志」可查看、刷新或复制最近 30 分钟的记录。也可以在终端排查：

```sh
build/DeviceNap.app/Contents/MacOS/DeviceNap --check
log show --last 30m --predicate 'subsystem == "local.devicenap"' --info
```

公开提交日志之前，请隐藏蓝牙地址和含个人信息的设备名称。卸载时先取消「登录时启动」，再退出应用并把 App 移到废纸篓。
