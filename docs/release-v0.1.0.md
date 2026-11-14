# v0.1.0 — TH3P4G3 + Arc A770 tools

## 中文

首次工具打包发布：下载 `th3p4g3-a770-tools-v0.1.0.zip` 并完整解压，使用 PowerShell 7 运行 `tools/eGPU-Hotplug.cmd`。

- 默认自动识别受支持的 A770 与 TH3P4G3 连接拓扑；保留本机 JSON 配置覆盖。遇到多个候选或无法核对的设备树时停止。
- 关闭占用 A770 的应用后请求 Windows 弹出，确认代码 47；重连后确认驱动就绪。保留 `-WhatIf` 和外设检查。
- 附带真实热拔插截图、DX11 闲置唤醒复测源码、监测脚本及 USB 鼠标接收器绕过方法的资料链接。
- 包内仅含公开源码、文档及截图；无本机配置、原始日志、转储或预编译程序。DX11 源码需另用 .NET 10 SDK 构建。

验证范围：此前本机路径版本已完成真实弹出/重连，截图记录代码 47 与恢复后的代码 0。本次自动识别版本通过 17 项合成拓扑与外设保护测试，以及本机只读状态、连续 5 秒就绪、`Eject -WhatIf` 检查，不将其说成又做了一次物理拔插。已公布的原生 DX11 复测 4/4 通过，但仍不能认定间歇性 141 根因已修复。

ZIP 的 SHA-256 见同名 `.zip.sha256` 附件。工具源码采用 MIT 许可证。完整测试条件与限制见仓库说明。

## English

First packaged release. Download and extract `th3p4g3-a770-tools-v0.1.0.zip`, then run `tools/eGPU-Hotplug.cmd` with PowerShell 7 installed.

- Discovers the supported A770/TH3P4G3 topology automatically, with a local JSON override and fail-closed handling of ambiguous or unsupported trees.
- Closes applications using the A770 before requesting Windows ejection; requires code 47 before unplugging and checks readiness after reconnection. Retains `-WhatIf` and accessory guards.
- Includes the real console screenshot, native DX11 wake-test source, monitoring scripts, and a sourced explanation of the USB receiver workaround.
- Contains public source, documentation, and screenshot only. No private configuration, raw logs, dumps, or prebuilt executables. Building the DX11 test requires the .NET 10 SDK.

Validation boundary: the prior machine-configured script completed physical eject/reconnect, producing the code 47 / recovered code 0 screenshot. The new discovery path passed 17 synthetic topology/accessory tests, plus live read-only status, five-second readiness, and `Eject -WhatIf` checks; this is not another physical unplug test. The published DX11 wake retest passed 4/4 launches, without establishing a root-cause fix for intermittent 141.

The companion `.zip.sha256` asset contains the ZIP checksum. Tool source uses the MIT License. See the repository for full test conditions and limitations.
