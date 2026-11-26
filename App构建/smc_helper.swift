import Foundation
import IOKit

// SMC 采样器：循环输出 JSON 行到 stdout，供 helper_driver 读取
// 字节布局与验证过的 SMCTest.swift 一致

func leU32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | (UInt32(b[o+1]) << 8) | (UInt32(b[o+2]) << 16) | (UInt32(b[o+3]) << 24)
}
func beU16(_ b: [UInt8], _ o: Int) -> UInt16 {
    (UInt16(b[o]) << 8) | UInt16(b[o+1])
}

func openSMC() -> io_connect_t? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var conn: io_connect_t = 0
    let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
    guard kr == kIOReturnSuccess else { return nil }
    return conn
}

func readKey(_ conn: io_connect_t, _ name: String) -> Double? {
    let keyBytes = Array(name.utf8)
    guard keyBytes.count == 4 else { return nil }
    var input = [UInt8](repeating: 0, count: 80)
    for i in 0..<4 { input[i] = keyBytes[3-i] }
    input[42] = 9
    var output = [UInt8](repeating: 0, count: 80)
    var outCnt = 80
    var kr: kern_return_t = -1
    input.withUnsafeBytes { ib in
        output.withUnsafeMutableBytes { ob in
            kr = IOConnectCallStructMethod(conn, 2, ib.baseAddress!, 80, ob.baseAddress!, &outCnt)
        }
    }
    guard kr == kIOReturnSuccess, output[40] == 0 else { return nil }
    let dataSize = Int(leU32(output, 28))
    guard dataSize > 0, dataSize <= 32 else { return nil }
    let dataType = String(bytes: [output[35],output[34],output[33],output[32]], encoding: .ascii) ?? "    "
    var input2 = [UInt8](repeating: 0, count: 80)
    for i in 0..<4 { input2[i] = keyBytes[3-i] }
    for i in 0..<12 { input2[28+i] = output[28+i] }
    input2[42] = 5
    var output2 = [UInt8](repeating: 0, count: 80)
    var outCnt2 = 80
    input2.withUnsafeBytes { ib in
        output2.withUnsafeMutableBytes { ob in
            kr = IOConnectCallStructMethod(conn, 2, ib.baseAddress!, 80, ob.baseAddress!, &outCnt2)
        }
    }
    guard kr == kIOReturnSuccess, output2[40] == 0 else { return nil }
    let raw = Array(output2[48..<(48+dataSize)])
    switch dataType {
    case "flt ": return Double(Float(bitPattern: leU32(raw, 0)))
    case "fpe2": return Double(beU16(raw, 0)) / 4.0
    case "sp78":
        let u = beU16(raw, 0)
        let s: Int16 = u < 0x8000 ? Int16(u) : Int16(Int32(u) - 65536)
        return Double(s) / 256.0
    case "ui8 ": return Double(raw[0])
    case "ui16": return Double(beU16(raw, 0))
    case "ui32": return Double(leU32(raw, 0))
    default: return nil
    }
}

guard let conn = openSMC() else {
    fputs("SMC 不可用\n", stderr); exit(1)
}
defer { IOServiceClose(conn) }

let fanKeys = ["F0Ac", "F1Ac", "F2Ac", "F3Ac", "F4Ac", "F5Ac"]
while true {
    let temp = readKey(conn, "TC0P") ?? readKey(conn, "TC0D") ?? 0
    var fans: [String: Double] = [:]
    for k in fanKeys {
        if let v = readKey(conn, k) { fans[k] = v.rounded() }
    }
    let tempR = temp.rounded()
    let fansJSON = fans.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
    print("{\"cpuTemp\":\(tempR),\"fans\":{\(fansJSON)},\"fnum\":\(fanKeys.count)}")
    fflush(stdout)
    Thread.sleep(forTimeInterval: 0.5)
}
