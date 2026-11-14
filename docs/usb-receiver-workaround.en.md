# Can a USB mouse receiver prevent dock disconnects?

[简体中文](usb-receiver-workaround.md) | **English** | [Back to README](../README.en.md)

**For the repeated whole-dock disconnect/reconnect observed while this system was idle, leaving an existing wireless mouse receiver in the TH3P4G3 USB-A port is a simple workaround supported by this system's measurements. It is not an established fix for DX11 initialization failures or all `LiveKernelEvent 141` errors.**

## Receiver and connection

[![Example of a USB wireless mouse receiver](https://upload.wikimedia.org/wikipedia/commons/7/7d/Logitech_unifying_receiver.jpg)](https://commons.wikimedia.org/wiki/File:Logitech_unifying_receiver.jpg)

Photo: MiNe (sfmine79), [Wikimedia Commons source and license](https://commons.wikimedia.org/wiki/File:Logitech_unifying_receiver.jpg), [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/). Unmodified, externally embedded. This identifies the type of accessory; **it does not identify the receiver used in this experiment or endorse a brand**. Its license is separate from the tools' MIT license.

```text
Laptop ── Thunderbolt cable ── TH3P4G3 dock ── A770
                                  │
                                  └─ USB-A port ← wireless mouse USB receiver
```

Connect it to a USB data port on the **dock**. Start with a working receiver already paired with your mouse. Connecting a mouse directly to the computer over Bluetooth does not add a device to the dock's USB branch. Arbitrary receivers, unpaired receivers and other USB placeholders have not been shown to produce the same result.

Ejecting the dock also temporarily disconnects its mouse; the laptop touchpad remains an alternative input. The receiver does not replace closing GPU applications, checking attached peripherals or waiting for device code 47 before unplugging. Automatic discovery uses an empty USB allowlist, so remove the receiver before ejecting, or explicitly allow its full instance path in a local configuration.

## Measurements from this system

These are existing measurements in [evidence.json → ab_experiment](../evidence.json), not new tests performed while editing this document. The xHCI controller policy was unchanged in all three phases.

| Phase | Receiver | Dock Root Hub allowed to save power | Observation | Whole-dock removals | New 141 |
| --- | --- | --- | --- | --- | --- |
| B | Removed | Yes | 161.3 s | 2 | 0 |
| A2 | Inserted | Yes | 602.8 s | 0 | 0 |
| C | Removed again | No | 901.0 s | 0 | 0 |

The results support trying the receiver workaround on this system. To keep the USB port free, the alternative tested here was changing only the dock Root Hub's power permission, following the [Device Manager guide](../README.en.md#device-manager-guide). The phases had different lengths and few samples, so they cannot establish a long-term failure rate. The logs also do not establish whether mouse activity is necessary for the receiver's effect.

## What external sources establish

Microsoft documents per-port USB selective suspend and notes that an unsuspended device may keep a host controller's transfer schedule active. **Our inference** is that the receiver changed the conditions for this USB branch to enter low power; the underlying driver, firmware or hardware cause remains unproven. Microsoft recommends leaving selective suspend enabled, so this guide does not prescribe a system-wide disable. [Microsoft: USB selective suspend](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/usb-selective-suspend)

An [original TH3P4G2/G3 review](https://egpu.io/forums/thunderbolt-enclosures/exp-gdc-th3p4g2-thunderbolt-gpu-dock-review/) also describes a wireless mouse connected through the dock and mouse stuttering under heavy peripheral load. It does not establish that a receiver fixes A770 DX11/141 errors. The direct evidence for this workaround is the local comparison above.

`0x141` identifies a display engine that did not respond in time. It does not, by itself, establish a physical whole-dock disconnect. [Microsoft: VIDEO_ENGINE_TIMEOUT_DETECTED](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/bug-check-0x141---video-engine-timeout-detected)

## Checking your own system

Keep the cable, port, driver and power supply unchanged. Compare receiver-absent and receiver-present phases during idle and after load ends. Track dock/A770 presence, PnP removals and new 141 reports separately. Exclude manual unplugging, safe ejection and delayed reports of older WER faults.

After whole-dock stability improves, run the separate [DX11 idle/wake test](dx11-wake.en.md). The latest four initializations in this repository passed within their observation window; that result does not establish a causal receiver fix for DX11/141.
