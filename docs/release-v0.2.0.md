# v0.2.0 — 自动识别鼠标接收器 / Automatic mouse-receiver recognition

## 中文

鼠标接收器不必每次从显卡坞拔下，也不必逐个加入白名单：本版可自动放行直接连接、功能可确认的纯 HID 鼠标或键鼠接收器，同时保留移动硬盘等外设的弹出保护。

下载 `th3p4g3-a770-tools-v0.2.0.zip`，完整解压后使用 PowerShell 7 运行 `tools/eGPU-Hotplug.cmd`。

- 检查完整 USB 设备子树，要求至少一个标准鼠标集合，所有节点在线正常、全部 USB 硬件接口均属于支持的 HID 功能；符合条件的有线鼠标也可通过。
- 允许已核对 `HidUsb` 接口下符合严格类别、标识及厂商匹配条件的 `SoftwareComponent` 叶节点：无关联功能驱动服务、无子设备且父关系正确。它不算额外 USB 硬件功能；不放行其他未知 `SWD` 节点，也不代表软件包不含 Win32 服务。
- USBSTOR/UASP/SCSI 存储、磁盘和卷、额外 USB Hub、未知或未就绪节点、混合非 HID 硬件功能仍会阻止弹出；仅发现一个鼠标接口不会放行整个复合设备。
- 旧 `AllowedUsbInstanceIds` 字段保留配置兼容，不能绕过分类或存储检查。多次设备树快照不一致时也停止。
- 保留 A770/TH3P4G3 拓扑自动识别、应用关闭、`-WhatIf`、下游雷电设备检查，以及拔线前确认代码 47 的步骤。
- 新增“接收器插在显卡坞 USB-A 口”的 AI 连接示意和卖家安装资料链接。示意图不是实拍或硬件测试证据；原单独接收器照片的 CC BY 2.0 归属继续保留。

识别按 Windows 已枚举的功能和受支持的标准驱动判断，不能保证所有厂商自定义接收器都能通过，也不能证明设备一定是无线接收器。无法确认时会阻止弹出；成功弹出后坞上的鼠标也会暂时离线。

验证结果：50 项合成设备树与外设保护测试全部通过，并经独立复核。本机直接插在坞上的 Logitech Unifying 接收器被自动放行：1 个复合设备根、3 个 HidUsb 接口、8 个标准 HID 集合和 1 个受限软件组件叶节点。公开脚本及本机原入口的 `Eject -WhatIf` 均通过，随后 A770 仍为代码 0、显卡坞和 USB Hub 在线。此次没有关闭应用或实际弹出；仍未替代接收器插着时的实际安全弹出和物理重连测试。仓库控制台截图来自此前版本的真实代码 47 / 重连代码 0 过程，不作为本版新增物理拔插的证明。

接收器减轻整坞空闲掉线的对照数据沿用已有记录，未因本次工具更新重跑。卖家资料未承诺接收器能修复掉线或 141，本版也不宣称修复 DX11 初始化失败或 `LiveKernelEvent 141` 根因。

ZIP 仅含公开源码、文档与图片，无本机配置、原始日志、转储或预编译程序。DX11 源码需另用 .NET 10 SDK 构建。SHA-256 见同名 `.zip.sha256` 附件；工具源码采用 MIT 许可证。

## English

A compatible mouse receiver can remain in the dock without a per-device allowlist. This release automatically accepts directly connected, verifiable HID-only mice and mouse/keyboard receivers while retaining ejection guards for external drives and other accessories.

Download and extract `th3p4g3-a770-tools-v0.2.0.zip`, then run `tools/eGPU-Hotplug.cmd` with PowerShell 7 installed.

- Checks the complete USB device subtree: at least one standard mouse collection, every node present and healthy, and only supported HID hardware interfaces. A wired mouse meeting these conditions also passes.
- Allows a `SoftwareComponent` leaf under a verified `HidUsb` interface only with strictly checked class/identifiers and matching vendor, no associated function-driver service, no children and the correct parent. It is not an additional USB hardware function. This does not accept other unknown `SWD` nodes or claim that the software package has no Win32 services.
- USBSTOR/UASP/SCSI storage, disks and volumes, additional USB hubs, unknown or unhealthy nodes, and mixed non-HID hardware functions still block ejection. One mouse interface does not exempt an entire composite device.
- Retains the legacy `AllowedUsbInstanceIds` field for configuration compatibility, without allowing it to bypass classification or storage checks. Inconsistent repeated device-tree snapshots also stop the operation.
- Preserves automatic A770/TH3P4G3 topology discovery, application closing, `-WhatIf`, downstream Thunderbolt checks, and the requirement to confirm code 47 before unplugging.
- Adds an AI connection illustration showing the receiver in the dock USB-A port and links to seller-published installation material. The illustration is not a photograph or hardware test evidence; attribution for the separate CC BY 2.0 receiver photo remains intact.

Recognition uses functions currently enumerated by Windows and supported standard drivers. It does not guarantee acceptance of every vendor-specific receiver or prove that a device is wireless. Uncertain devices are blocked. Ejecting the dock temporarily disconnects its mouse as well.

Validation: all 50 synthetic topology/accessory checks passed and were independently reviewed. A Logitech Unifying receiver directly connected to this dock passed automatic classification: one composite root, three HidUsb interfaces, eight standard HID collections and one restricted software-component leaf. Both the public script and the updated local launcher passed `Eject -WhatIf`; subsequent status showed A770 code 0 with the dock and USB hub online. No applications were closed and no device was actually ejected. This does not replace a real safe-eject and physical reconnect test with the receiver attached. The console screenshot records code 47 / recovered code 0 from a prior tool version, not a new physical unplug test for this release.

The receiver workaround data is reused from the existing whole-dock idle-disconnect comparison; it was not rerun for this code update. The seller material does not promise a receiver-based fix for disconnects or 141. This release does not claim to fix the root cause of DX11 initialization failures or `LiveKernelEvent 141`.

The ZIP contains public source, documentation and images only: no private configuration, raw logs, dumps or prebuilt executables. Building the DX11 test requires the .NET 10 SDK. The companion `.zip.sha256` contains the ZIP checksum; tool source uses the MIT License.
