import Foundation
import AppKit

// 生成"风冷屏显驱动"图标：深色金属面板 + 数显屏(温度) + 风扇转速条
// 用法: swiftc make_icon.swift -o make_icon && ./make_icon

let workDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = workDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(Int, Bool)] = [
    (16, false), (16, true), (32, false), (32, true), (64, false),
    (128, false), (128, true), (256, false), (256, true), (512, false), (512, true),
]

func renderImage(_ s: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let u = s / 1024  // 比例单位

    // 背景：深蓝灰渐变圆角方块
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 230*u, yRadius: 230*u)
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(srgbRed: 0.19, green: 0.25, blue: 0.33, alpha: 1).cgColor,
                                   NSColor(srgbRed: 0.07, green: 0.10, blue: 0.15, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.saveGState()
    bgPath.addClip()
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    // 金属边框
    let bezel = NSBezierPath(roundedRect: CGRect(x: 96*u, y: 250*u, width: 832*u, height: 524*u),
                             xRadius: 60*u, yRadius: 60*u)
    NSColor(srgbRed: 0.55, green: 0.62, blue: 0.70, alpha: 1).setFill()
    bezel.fill()
    let bezelInner = NSBezierPath(roundedRect: CGRect(x: 112*u, y: 266*u, width: 800*u, height: 492*u),
                                  xRadius: 48*u, yRadius: 48*u)
    NSColor(srgbRed: 0.30, green: 0.36, blue: 0.44, alpha: 1).setFill()
    bezelInner.fill()

    // 屏幕（黑底带微光）
    let screen = NSBezierPath(roundedRect: CGRect(x: 140*u, y: 292*u, width: 744*u, height: 440*u),
                              xRadius: 30*u, yRadius: 30*u)
    NSColor(srgbRed: 0.03, green: 0.05, blue: 0.07, alpha: 1).setFill()
    screen.fill()
    ctx.saveGState(); screen.addClip()
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(srgbRed: 0.0, green: 0.5, blue: 0.4, alpha: 0.18).cgColor,
                                   NSColor.clear.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s/2, y: 500*u), startRadius: 0,
                           endCenter: CGPoint(x: s/2, y: 500*u), endRadius: 500*u, options: [])
    ctx.restoreGState()

    // 温度数字 "43°"（七段风格：用粗等宽字体模拟）
    let tempFont = NSFont(name: "Menlo-Bold", size: 250*u) ?? NSFont.boldSystemFont(ofSize: 250*u)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let tempAttrs: [NSAttributedString.Key: Any] = [
        .font: tempFont,
        .foregroundColor: NSColor(srgbRed: 1.0, green: 0.42, blue: 0.20, alpha: 1),
        .paragraphStyle: para,
    ]
    "43°".draw(in: CGRect(x: 140*u, y: 360*u, width: 744*u, height: 300*u), withAttributes: tempAttrs)

    // 风扇转速条（青绿色）
    let barX = 200*u, barY = 340*u, barW = 624*u, barH = 26*u
    let barBg = NSBezierPath(roundedRect: CGRect(x: barX, y: barY, width: barW, height: barH),
                             xRadius: 13*u, yRadius: 13*u)
    NSColor(srgbRed: 0.12, green: 0.20, blue: 0.24, alpha: 1).setFill(); barBg.fill()
    let barFill = NSBezierPath(roundedRect: CGRect(x: barX, y: barY, width: barW*0.72, height: barH),
                               xRadius: 13*u, yRadius: 13*u)
    NSColor(srgbRed: 0.10, green: 0.85, blue: 0.65, alpha: 1).setFill(); barFill.fill()

    // 底部小风扇符号（三个叶片圆）
    let fanCx = 512*u, fanCy = 155*u, fanR = 92*u
    NSColor(srgbRed: 0.35, green: 0.42, blue: 0.50, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: fanCx-fanR, y: fanCy-fanR, width: 2*fanR, height: 2*fanR)).fill()
    NSColor(srgbRed: 0.85, green: 0.90, blue: 0.95, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: fanCx-0.28*fanR, y: fanCy-0.28*fanR, width: 0.56*fanR, height: 0.56*fanR)).fill()

    img.unlockFocus()
    return img
}

func savePNG(_ img: NSImage, _ s: Int, _ name: String) {
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: iconset.appendingPathComponent(name))
}

for (s, is2x) in sizes {
    let px = is2x ? s*2 : s
    let suffix = is2x ? "@2x" : ""
    let name = "icon_\(s)x\(s)\(suffix).png"
    savePNG(renderImage(CGFloat(px)), px, name)
    print("生成 \(name) (\(px)x\(px))")
}
print("ICONSET=\(iconset.path)")
