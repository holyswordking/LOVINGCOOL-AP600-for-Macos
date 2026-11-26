import Foundation
import IOKit
import IOKit.hid
import Darwin

// ============================================================
// 数显屏实时驱动（纯 IOKit 同步通道，绕开 hidapi 吞回包问题）
// 用法: python3 smc.py | ./驱动-实时
// 从 stdin 读 JSON 行 {"cpuTemp":..,"fans":{..},"fnum":..}
// 每 200ms 用 Windows 抓包完整真实帧发送，屏幕持续点亮
// ============================================================

func findDevice() -> IOHIDDevice? {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [String: Any] = [
        kIOHIDVendorIDKey as String: 0x5131,
        kIOHIDProductIDKey as String: 0x2007,
    ]
    IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
    guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
          let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return nil }
    return devs.first
}

guard let dev = findDevice() else {
    fputs("找不到数显设备 (VID 0x5131 / PID 0x2007)\n", stderr); exit(2)
}
let openSt = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
guard openSt == kIOReturnSuccess else {
    fputs("打开 HID 设备失败: \(openSt)\n", stderr); exit(3)
}

func sendReport(_ data: [UInt8]) -> IOReturn {
    data.withUnsafeBytes { p -> IOReturn in
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, p.baseAddress!, data.count)
    }
}
func recvReport() -> ([UInt8], IOReturn, Int) {
    var buf = [UInt8](repeating: 0, count: 64); var len = 64
    let kr = buf.withUnsafeMutableBytes { p -> IOReturn in
        IOHIDDeviceGetReport(dev, kIOHIDReportTypeInput, 0, p.baseAddress!, &len)
    }
    return (buf, kr, len)
}
func hex(_ a: [UInt8], _ n: Int) -> String {
    a.prefix(n).map { String(format:"%02x",$0) }.joined()
}
func hexToBytes(_ s: String) -> [UInt8] {
    var out: [UInt8] = []; var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!); i = j
    }
    return out
}

// ---- 共享状态（stdin 采样线程写，发送线程读）----
final class State {
    var temp: Double = 0
    var fan1: Double = 0
    var fan2: Double = 0
    var tempValid = false
    let lock = NSLock()
}
let state = State()

// Windows 1.0.16 抓包完整真实帧模板（52°C 代表帧，字段全保留）
let template = hexToBytes("000102350000472245285701053200000a11000a010a1e0000141a0b19163127032200000005000100000000001a430017002b00000000000000000000000000")

func buildFrame() -> [UInt8] {
    var b = template
    state.lock.lock()
    let t = state.temp; let f1 = state.fan1; let f2 = state.fan2
    let valid = state.tempValid
    state.lock.unlock()
    if valid {
        // 温度整数在 [3]，摄氏/小数保持抓包的 00 00
        b[3] = UInt8(max(0, min(255, Int(t.rounded()))))
        // 风扇：抓包 [21][22]=cpuFan 高/低，[23][24]=fan2 高/低
        let fanA = max(0, min(9999, Int(f1.rounded())))
        let fanB = max(0, min(9999, Int(f2.rounded())))
        b[21] = UInt8(fanA / 100); b[22] = UInt8(fanA % 100)
        b[23] = UInt8(fanB / 100); b[24] = UInt8(fanB % 100)
    }
    return b
}

// ---- stdin 采样线程 ----
DispatchQueue.global(qos: .utility).async {
    while let line = readLine(strippingNewline: true) {
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
        let t = (obj["cpuTemp"] as? NSNumber)?.doubleValue ?? 0
        var fans: [Double] = []
        if let fdict = obj["fans"] as? [String: Any] {
            for k in ["F0Ac", "F1Ac", "F2Ac"] {
                if let v = fdict[k] as? NSNumber { fans.append(v.doubleValue) }
            }
        }
        state.lock.lock()
        state.temp = t
        state.fan1 = fans.count > 0 ? fans[0] : 0
        state.fan2 = fans.count > 1 ? fans[1] : 0
        state.tempValid = t > 0
        state.lock.unlock()
    }
}

// ---- 握手 + 读回包 ----
var handshake = [UInt8](repeating: 0, count: 64)
[0x00,0x55,0x15,0x01,0x00,0x00].enumerated().forEach { handshake[$0.offset] = $0.element }
_ = sendReport(handshake)
Thread.sleep(forTimeInterval: 0.1)
let (hb, _, hlen) = recvReport()
print("握手回包: len=\(hlen) hex=\(hex(hb, min(hlen,12)))"); fflush(stdout)
Thread.sleep(forTimeInterval: 1.0)

print("=== 实时驱动启动，每 200ms 发送（Ctrl+C 退出）==="); fflush(stdout)
var sent = 0
var lastTemp = -1
while true {
    let frame = buildFrame()
    let wr = sendReport(frame)
    sent += 1
    let curTemp = Int(frame[3])
    if wr != 0 { print("写失败 \(wr) @帧\(sent)"); fflush(stdout) }
    if curTemp != lastTemp {
        print("帧#\(sent) 温度=\(curTemp)°C 风扇=\(Int(frame[21])*100+Int(frame[22]))/\(Int(frame[23])*100+Int(frame[24])) rpm"); fflush(stdout)
        lastTemp = curTemp; fflush(stdout)
    }
    Thread.sleep(forTimeInterval: 0.2)
}
