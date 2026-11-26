import Foundation
import AppKit

// ============================================================
// 风冷屏显驱动 —— macOS 菜单栏常驻 App (v1.3)
// 架构：主进程只管菜单栏 UI；驱动由内置的两个 helper 子进程完成
//   smc_helper     -> 读 SMC 输出 JSON
//   helper_driver  -> 读 JSON, 用纯 IOKit 同步通道驱动数显屏
// 子进程隔离避免 AppKit 主进程环境干扰 HID 写入
// v1.2 变更：开机自启自动安装到 ~/Applications（避免 DMG 路径失效）、
//            正常退出不再被 launchd 拉起、增加单实例检测
// v1.3 变更：菜单栏标题改为「CPU：XX°  风扇：XXXX」
// ============================================================

func appLog(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    if let h = FileHandle(forWritingAtPath: "/tmp/lcd_app.log") {
        h.seekToEndOfFile()
        if let d = line.data(using: .utf8) { h.write(d) }
        h.closeFile()
    } else {
        try? line.write(toFile: "/tmp/lcd_app.log", atomically: true, encoding: .utf8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var smcProc: Process?
    var drvProc: Process?
    let stateLock = NSLock()
    var running = true
    let label = NSMenuItem(title: "启动中…", action: nil, keyEquivalent: "")
    let autoStartItem = NSMenuItem(title: "登录后自动启动", action: #selector(toggleAutoStart), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("=== 风冷屏显驱动 v1.3 启动 ===")

        // 单实例检测：已有一个实例在跑就直接退出，避免两个进程抢 USB 设备
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.lcddisplay.driver")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            appLog("检测到已有实例，本实例退出")
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = "CPU：—°  风扇：—"
            btn.font = NSFont.menuBarFont(ofSize: 0)
            btn.toolTip = "风冷屏显驱动：CPU 温度 / 风扇转速"
        }
        let menu = NSMenu()
        menu.addItem(label)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(autoStartItem)
        menu.addItem(NSMenuItem(title: "关于", action: #selector(about), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        updateAutoStartCheck()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.startHelpers()
        }
    }

    private func resource(_ name: String) -> String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name)").path
    }

    private func startHelpers() {
        let smcPath = resource("smc_helper")
        let drvPath = resource("helper_driver")
        guard FileManager.default.fileExists(atPath: smcPath),
              FileManager.default.fileExists(atPath: drvPath) else {
            appLog("helper 缺失: \(smcPath) / \(drvPath)")
            setLabel("⚠ 组件缺失")
            setTitle("CPU：⚠  风扇：⚠")
            return
        }

        let smc = Process()
        smc.executableURL = URL(fileURLWithPath: smcPath)
        let pipe = Pipe()
        smc.standardOutput = pipe
        smc.standardError = FileHandle.nullDevice
        self.smcProc = smc

        let drv = Process()
        drv.executableURL = URL(fileURLWithPath: drvPath)
        drv.standardInput = pipe
        let outPipe = Pipe()
        drv.standardOutput = outPipe
        drv.standardError = FileHandle.nullDevice
        self.drvProc = drv

        do {
            try smc.run()
            try drv.run()
            appLog("helper 已启动 smc=\(smc.processIdentifier) drv=\(drv.processIdentifier)")
        } catch {
            appLog("helper 启动失败: \(error)")
            setLabel("⚠ 启动失败")
            return
        }

        setLabel("正在显示 · 读取中")

        let handle = outPipe.fileHandleForReading
        var buffer = ""
        while running && drv.isRunning {
            let data = handle.availableData
            if data.isEmpty { break }
            buffer += String(data: data, encoding: .utf8) ?? ""
            while let nl = buffer.range(of: "\n") {
                let line = String(buffer[..<nl.lowerBound])
                buffer = String(buffer[nl.upperBound...])
                parseDriverLine(line)
            }
        }
        appLog("helper 读取循环结束")
    }

    private func parseDriverLine(_ line: String) {
        if line.contains("温度=") && line.contains("风扇=") {
            let tempStr = line.components(separatedBy: "温度=").last?.components(separatedBy: "°").first ?? ""
            let fanStr = line.components(separatedBy: "风扇=").last?.components(separatedBy: "/").first ?? ""
            if let t = Int(tempStr.trimmingCharacters(in: .whitespaces)) {
                let fan = fanStr.trimmingCharacters(in: .whitespaces)
                setTitle("CPU：\(t)°  风扇：\(fan)")
                setLabel("CPU \(t)°C  ·  风扇 \(fan) RPM")
            }
        } else if line.contains("握手回包") {
            setLabel("已连接 · 正在显示")
        }
    }

    private func setTitle(_ t: String) {
        DispatchQueue.main.async { [weak self] in self?.statusItem.button?.title = t }
    }
    private func setLabel(_ t: String) {
        DispatchQueue.main.async { [weak self] in self?.label.title = t }
    }

    @objc private func quit() {
        appLog("用户退出")
        running = false
        smcProc?.terminate()
        drvProc?.terminate()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "风冷屏显驱动 v1.3"
        alert.informativeText = """
        macOS 原生驱动 · 让黑苹果的数显屏显示 CPU 温度与风扇。

        屏幕显示：
          红色数字 = CPU 温度（°C）
          绿色条   = CPU 风扇转速（RPM）

        菜单栏「CPU：XX°  风扇：XXXX」实时显示当前温度与风扇转速。
        点菜单栏 →「登录后自动启动」可开关开机自启（首次开启会把 App 装到 ~/Applications）。
        基于 Windows 原版抓包帧格式，纯 IOKit 同步通道，无外部依赖。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 开机自启

    private func agentPath() -> String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.lcddisplay.driver.plist"
    }

    /// 把当前 App 复制到 ~/Applications（若已在那儿则直接用），返回稳定路径
    private func ensureInstalledInApplications() -> String? {
        let fm = FileManager.default
        let target = NSHomeDirectory() + "/Applications/风冷屏显驱动.app"
        let bundle = Bundle.main.bundleURL
        if bundle.path == target { return target }
        if fm.fileExists(atPath: target) { try? fm.removeItem(atPath: target) }
        do {
            try fm.copyItem(at: bundle, to: URL(fileURLWithPath: target))
            appLog("已安装到 ~/Applications: \(target)")
            return target
        } catch {
            appLog("安装到 ~/Applications 失败: \(error)")
            return nil
        }
    }

    private func updateAutoStartCheck() {
        let on = FileManager.default.fileExists(atPath: agentPath())
        autoStartItem.state = on ? .on : .off
        autoStartItem.title = on ? "登录后自动启动 ✓" : "登录后自动启动"
    }

    @objc private func toggleAutoStart() {
        let p = agentPath()
        let fm = FileManager.default
        if fm.fileExists(atPath: p) {
            try? fm.removeItem(atPath: p)
            setLabel("已关闭开机自启")
            updateAutoStartCheck()
            return
        }

        guard let appPath = ensureInstalledInApplications() else {
            let alert = NSAlert()
            alert.messageText = "无法开启开机自启"
            alert.informativeText = "未能把 App 安装到 ~/Applications，请手动把「风冷屏显驱动.app」拖进「应用程序」文件夹后重试。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }

        // 用 open -a 启动完整 App，保证 Bundle 路径正确；
        // KeepAlive 只在异常退出时重启，正常点「退出」不会被拉起。
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>com.lcddisplay.driver</string>
        <key>ProgramArguments</key>
        <array>
            <string>/usr/bin/open</string>
            <string>-a</string>
            <string>\(appPath)</string>
        </array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key>
        <dict><key>SuccessfulExit</key><false/></dict>
        </dict></plist>
        """
        do {
            try plist.write(toFile: p, atomically: true, encoding: .utf8)
            setLabel("已开启开机自启 · 下次登录生效")
            appLog("开机自启已开启，指向 \(appPath)")
        } catch {
            appLog("写 LaunchAgent 失败: \(error)")
            setLabel("⚠ 开启自启失败")
        }
        updateAutoStartCheck()
    }

    func applicationWillTerminate(_ notification: Notification) {
        running = false
        smcProc?.terminate()
        drvProc?.terminate()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
