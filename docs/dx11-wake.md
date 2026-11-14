# 原生 DX11 闲置唤醒复测

[English](dx11-wake.en.md) · [主报告](../README.md)

重新连接 TH3P4G3 并确认 Windows 正常识别 Intel Arc A770 后，4 次原生 Direct3D 11 初始化均成功。测试和最后的闲置观察期间，未观察到雷电掉线或新的 `LiveKernelEvent 141`。

Kryptex 全程关闭。每轮启动前通过 Windows 的 `DEVPKEY_Device_PowerData` 读取 A770 最近报告的设备电源状态，读数均为 **D3**。测试直接在 A770 上创建 Feature Level 11_0 设备，每批提交用 GPU fence 确认完成，每轮结束时回读并比对 4 个结果值。

| 轮次 | 启动前闲置 | 实际运行 | GPU 完成的 dispatch | 回读校验 |
|---|---:|---:|---:|---|
| 重连后首轮 | 已处于 D3 | 300.02 秒 | 2,181,248 | 4/4 通过 |
| 第 1 次闲置后重启 | 2 分钟 | 30.02 秒 | 219,072 | 4/4 通过 |
| 第 2 次闲置后重启 | 2 分钟 | 30.01 秒 | 218,816 | 4/4 通过 |
| 第 3 次闲置后重启 | 2 分钟 | 30.02 秒 | 218,880 | 4/4 通过 |

最后一轮后继续观察 2 分钟。日志未发现 Thunderbolt 断连、相关 PnP 意外移除、新的 WATCHDOG 转储或 `141`。结束后 A770 和显卡坞仍在线，A770 的设备问题代码为 `0`。

这是单机测试，复测时的线材和端口未记录。之前观察到的间歇性 DX11 初始化失败在这四轮里没有复现，故障原因仍待确定。

在 Windows 上安装 .NET 10 SDK 和 PowerShell 7。先按[主报告](../README.md)配置本机设备实例路径，连接 A770 并退出 Kryptex。从仓库根目录执行：

```powershell
dotnet build .\tools\Dx11ArcBatched\Dx11ArcBatched.csproj -c Release
.\tools\Test-Dx11Wake.ps1
```

[复测脚本](../tools/Test-Dx11Wake.ps1)的默认时长对应上表。结果写到 `tools/captures/`。在 `run.tsv` 查看各轮结果，当 `PrePower=D3` 时，该轮才覆盖 D3 唤醒。程序退出码用于判断 DX11 测试是否通过，掉线和 141 需查看 `timeline.tsv` 与 `events.jsonl`，按设备路径和转储文件核对。若有多块 A770，先只保留目标 A770 在线。日志可能含本机数据，分享前须脱敏。
