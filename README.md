# LOVINGCOOL-AP600-for-Macos
雷利酷LOVINGCOOLAP600数显散热器驱动 for Macos
概述

黑苹果（Hackintosh）环境下的数显屏原生驱动。原厂软件只有 Windows 版，
本 App 通过逆向其 USB HID 协议，用纯 macOS 原生 API 实现同样功能。

- **设备**：USB HID，VID `0x5131` / PID `0x2007`，usagePage `0xFF00`
- **报告**：64 字节 Output Report，无 Report ID，200ms 间隔持续发送
- **数据源**：SMC `TC0P`/`TC0D`（CPU 温度）、`F0Ac`/`F1Ac`/`F2Ac`（风扇）

## 关键排错历程（供以后参考）

整个项目历经多轮试错，最终定位到两个真正的病根：

1. **帧格式**：早期按旧版 1.0.2 逆向的帧头是 `01 00 01 02`，
   而 1.0.16 真实抓包是 `00 01 02`（整体错位 1 字节）。
   最终采用 Windows 1.0.16 抓包的完整真实帧模板，字段逐字节保留。

2. **回包被吞（真正的拦路虎）**：`node-hid`/hidapi 的异步回包机制在
   这块屏上会把设备的 input report "吞掉"却不交给应用层，造成
   "设备不回包/状态紊乱"的假象，握手无法完成，屏幕停在 88/8888 自检。
   改用底层同步调用 `IOHIDDeviceGetReport` / `IOHIDDeviceSetReport`
   后，握手回包与数据帧回显全部正常。

3. **必须常驻发送**：脚本发十几秒就退出，屏幕会熄灭。原版是常驻进程
   每 200ms 不停发帧。App 因此在菜单栏常驻，退出才停止。

## 曾排除的错误方向

- 段码协议（不适用于该设备）
- 4 步启动握手 / Feature Report / 65 字节前置 reportId
- 串口 RGB565 图片流（是另一条路径，不是这个 HID 屏）
- IAP 重枚举为 CH375（有变砖风险，且通信层本就正常，无需执行）

## 帧模板（64 字节，Windows 1.0.16 真实抓包）

```
000102350000472245285701053200000a11000a010a1e0000141a0b19163127032200000005000100000000001a430017002b00000000000000000000000000
```

关键字段：

- `[0..2]` 帧头 `00 01 02`
- `[3]` 温度整数（摄氏度）
- `[21][22]` CPU 风扇转速 高/低（除法拆位：高位 = rpm/100，低位 = rpm%100）
- `[23][24]` 风扇2 转速 高/低

## 源码与完整日志

- 工作目录：`/Volumes/StorageSpac/workbuddy工作目录/Claw/macOS-数显屏驱动/`
- App 源码：`App构建/main.swift`
- 图标源码：`App构建/make_icon.swift`
- 验证驱动：`驱动-实时.swift`（Python 采 SMC 版，已验证成功）
- 工作日志：`.workbuddy/memory/2026-11-25.md`

## v1.1 架构修正（重要）

v1.0 把驱动逻辑内嵌在 AppKit 主进程，实测 `IOHIDDeviceSetReport` 返回
`kIOReturnNotOpen (-536870195)`——AppKit 主进程环境会干扰 HID 写入，
导致握手和数据帧全部写不进去，屏幕不亮。

v1.1 改为**子进程隔离架构**：

- 主进程（菜单栏 UI）：NSApplication，只管图标/菜单/自启。
- `smc_helper` 子进程：读 SMC，输出 JSON 到 stdout。
- `helper_driver` 子进程：就是已验证成功的 `驱动-实时.swift` 原样编译，
  从 stdin 读 JSON，用纯 IOKit 同步通道驱动屏幕。
- 主进程用 Pipe 连接两者，并从 helper 输出解析温度更新菜单栏。

实测写入计数持续增长（200ms/帧），屏幕正常显示。这是最终交付架构。
