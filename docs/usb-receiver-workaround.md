# 插一个 USB 鼠标接收器，能解决掉线吗？

**简体中文** | [English](usb-receiver-workaround.en.md) | [返回主页](../README.md)

**对于本机已经复现的“闲置时整坞反复断开、重连”，把现有无线鼠标的 USB 接收器插在 TH3P4G3 的 USB-A 口，是有实测支持、操作最少的绕过办法。它还不能被称为 DX11 初始化失败或所有 `LiveKernelEvent 141` 的修复。**

## 接收器与插入位置

[![USB 无线鼠标接收器外观示例](https://upload.wikimedia.org/wikipedia/commons/7/7d/Logitech_unifying_receiver.jpg)](https://commons.wikimedia.org/wiki/File:Logitech_unifying_receiver.jpg)

图片：MiNe（sfmine79），[Wikimedia Commons 原图与许可](https://commons.wikimedia.org/wiki/File:Logitech_unifying_receiver.jpg)，[CC BY 2.0](https://creativecommons.org/licenses/by/2.0/)。图片未修改，通过外链展示。它仅用于辨认这类 USB 接收器，**不是本机测试接收器的型号证明，也不是品牌推荐**；图片许可独立于工具源码的 MIT 许可。

```text
笔记本 ── 雷电线 ── TH3P4G3 显卡坞 ── A770
                         │
                         └─ USB-A 口 ← 插入无线鼠标的 USB 接收器
```

这里说的是插入**显卡坞**的 USB 数据口。沿用已经与鼠标配对、工作正常的接收器即可先做对照；仅把鼠标通过蓝牙连到电脑，并没有在坞的 USB 分支增加设备。尚未验证任意接收器、未配对接收器或其他“占位”USB 设备能否得到相同结果。

安全弹出显卡坞时，坞上的鼠标也会暂时离线，可使用笔记本触控板继续操作。接收器并不替代热拔插工具的应用关闭、外设检查和代码 47 确认。自动识别模式的 USB 白名单默认为空，因此弹出前需先拔下接收器；若要保留接收器，请在本机配置中明确加入其完整实例路径。

## 本机对照数据

以下来自仓库已有的 [evidence.json → ab_experiment](../evidence.json)，不是此次编辑说明时新跑的测试。三个阶段均保留 xHCI 控制器原策略。

| 阶段 | 接收器 | 坞内 Root Hub 允许省电 | 观察时长 | 整坞移除 | 新 141 |
| --- | --- | --- | --- | --- | --- |
| B | 拔出 | 是 | 161.3 秒 | 2 | 0 |
| A2 | 插回 | 是 | 602.8 秒 | 0 | 0 |
| C | 再拔出 | 否 | 901.0 秒 | 0 | 0 |

这组结果支持在本机优先尝试接收器绕过；若不想占用 USB 口，也可以按[设备管理器图解](../README.md#device-manager-guide)只调整坞内 Root Hub 的省电权限。阶段时长不同、样本较少，不能据此估计长期故障率。日志也不足以判断接收器是否必须配合鼠标活动才能产生效果。

## 网页资料能说明什么

Microsoft 说明，USB 选择性挂起可单独挂起某个端口；未挂起的设备可能影响 USB 主控制器停止传输调度。**据此推测**，插入接收器改变了本机 USB 分支进入低功耗的条件，但本实验尚未定位具体驱动、固件或硬件原因。Microsoft 默认建议保留选择性挂起，因此这里不提供全局关闭 USB 省电的做法。[Microsoft：USB selective suspend](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/usb-selective-suspend)

网页检索还找到了实际使用 TH3P4G2/G3 USB 口连接无线鼠标的[原始评测](https://egpu.io/forums/thunderbolt-enclosures/exp-gdc-th3p4g2-thunderbolt-gpu-dock-review/)。它记录的是外设使用和重负载下的鼠标卡顿，并未证明“接收器可修好 A770 的 DX11/141”。本文接收器绕过的直接证据来自上面的本机对照。

`0x141` 表示显示引擎未及时响应；它本身不表示整坞发生了物理断连。[Microsoft：VIDEO_ENGINE_TIMEOUT_DETECTED](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/bug-check-0x141---video-engine-timeout-detected)

## 如何确认对自己的设备有效

保持同一线材、端口、驱动和电源，分别记录接收器拔出、插入时的空闲和负载退出后的表现。比较整坞/A770 在位变化、PnP 移除与新增 141；不要将手动拔线、安全弹出或旧 WER 的延迟上报计为新故障。

整坞掉线改善后，仍需另外运行 [DX11 闲置唤醒测试](dx11-wake.md)。本仓库最新一轮四次初始化通过，说明那次观察窗口成功；接收器对 DX11/141 的因果作用仍未被该测试确立。
