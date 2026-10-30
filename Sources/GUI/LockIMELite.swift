// LockIME-lite 设置面板 —— 纯 GUI 壳，不含任何锁定逻辑。
// 职责：读写 config.json / 读 state.plist / 通过 launchctl 管理常驻服务。
// 与 daemon 的通信：文件 + 分布式通知（reload / state），无 XPC、无网络。

import SwiftUI
import Combine
import AppKit
import Carbon

// MARK: - 路径与常量

enum LitePaths {
    static let label = "com.lockime-lite.daemon"
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LockIME-lite")
    static let configURL = supportDir.appendingPathComponent("config.json")
    static let stateURL = supportDir.appendingPathComponent("state.plist")
    static let daemonURL = supportDir.appendingPathComponent("lockime-lite-daemon")
    static let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")
}

struct LiteConfig: Codable {
    var enabled: Bool = false
    var targetID: String? = nil
}

// MARK: - 输入源枚举（Carbon TIS）

struct InputSourceItem: Identifiable, Hashable {
    let id: String
    let name: String
}

enum TISBrowser {
    static func currentName() -> String {
        guard let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let p = TISGetInputSourceProperty(s, kTISPropertyLocalizedName)
        else { return "—" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    static func selectable() -> [InputSourceItem] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource]
        else { return [] }
        var out: [InputSourceItem] = []
        for s in list {
            func str(_ k: CFString) -> String? {
                guard let p = TISGetInputSourceProperty(s, k) else { return nil }
                return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            }
            func flag(_ k: CFString) -> Bool {
                guard let p = TISGetInputSourceProperty(s, k) else { return false }
                return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
            }
            guard str(kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String),
                  flag(kTISPropertyInputSourceIsEnabled),
                  flag(kTISPropertyInputSourceIsSelectCapable),
                  let sid = str(kTISPropertyInputSourceID)
            else { continue }
            out.append(InputSourceItem(id: sid, name: str(kTISPropertyLocalizedName) ?? sid))
        }
        return out.sorted { $0.name < $1.name }
    }
}

// MARK: - launchctl 服务管理

enum ServiceManager {
    @discardableResult
    static func launchctl(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out)
    }

    static var guiDomain: String { "gui/\(getuid())" }

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: LitePaths.plistURL.path)
    }

    static func isRunning() -> Bool {
        launchctl(["print", "\(guiDomain)/\(LitePaths.label)"]).0 == 0
    }

    /// 安装并启动：复制 daemon → 生成 plist → bootstrap（已加载则 kickstart 重载）
    static func install(daemonSource: URL) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: LitePaths.supportDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: LitePaths.daemonURL.path) {
                try fm.removeItem(at: LitePaths.daemonURL)
            }
            try fm.copyItem(at: daemonSource, to: LitePaths.daemonURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: LitePaths.daemonURL.path)

            let logPath = NSHomeDirectory() + "/Library/Logs/LockIME-lite.log"
            let plist: [String: Any] = [
                "Label": LitePaths.label,
                "ProgramArguments": [LitePaths.daemonURL.path],
                "RunAtLoad": true,                       // 登录即启动
                "KeepAlive": ["SuccessfulExit": false],  // 崩溃自动拉起
                "ThrottleInterval": 10,
                "ProcessType": "Background",
                "LowPriorityIO": true,
                "StandardOutPath": logPath,
                "StandardErrorPath": logPath,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try fm.createDirectory(at: LitePaths.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: LitePaths.plistURL)

            if isRunning() {
                let (rc, out) = launchctl(["kickstart", "-k", "\(guiDomain)/\(LitePaths.label)"])
                return rc == 0 ? nil : "kickstart 失败：\(out)"
            }
            let (rc, out) = launchctl(["bootstrap", guiDomain, LitePaths.plistURL.path])
            return rc == 0 ? nil : "bootstrap 失败：\(out)"
        } catch {
            return error.localizedDescription
        }
    }

    static func stop() -> String? {
        let (rc, out) = launchctl(["bootout", "\(guiDomain)/\(LitePaths.label)"])
        return (rc == 0 || rc == 36) ? nil : "bootout 失败：\(out)"   // 36 = 本来就没在跑
    }

    static func uninstall() -> String? {
        _ = stop()
        let fm = FileManager.default
        try? fm.removeItem(at: LitePaths.plistURL)
        try? fm.removeItem(at: LitePaths.daemonURL)
        return nil
    }
}

// MARK: - 配置存取

enum ConfigStore {
    static func load() -> LiteConfig {
        guard let data = try? Data(contentsOf: LitePaths.configURL),
              let cfg = try? JSONDecoder().decode(LiteConfig.self, from: data)
        else { return LiteConfig() }
        return cfg
    }

    static func save(_ cfg: LiteConfig) {
        let fm = FileManager.default
        try? fm.createDirectory(at: LitePaths.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cfg) {
            try? data.write(to: LitePaths.configURL, options: .atomic)
        }
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.lockime-lite.reload"), object: nil)
    }
}

// MARK: - GUI

@main
struct LockIMELiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("LockIME-lite") {
            ContentView()
                .frame(width: 480)
                .fixedSize(horizontal: false, vertical: true)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 420)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @State private var config = ConfigStore.load()
    @State private var sources = TISBrowser.selectable()
    @State private var currentName = TISBrowser.currentName()
    @State private var activations = 0
    @State private var backoffActive = false
    @State private var installed = ServiceManager.isInstalled()
    @State private var running = ServiceManager.isRunning()
    @State private var errorMessage: String?

    let refreshTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("常驻后台服务") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text("状态")
                    Spacer()
                    Text(serviceStatusText)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if !installed {
                        Button("安装并启动") { installService() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        if running {
                            Button("停止") { stopService() }
                        } else {
                            Button("启动") { startService() }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("重启") { restartService() }
                        Button("卸载", role: .destructive) { uninstallService() }
                    }
                }
                Text("安装后由系统接管：登录自动启动、后台静默运行、崩溃自动重启。\n「停止」只在本次登录生效，下次登录仍会自动启动；要彻底移除请用「卸载」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("输入法锁定") {
                Toggle("启用输入法锁定", isOn: Binding(
                    get: { config.enabled },
                    set: { config.enabled = $0; ConfigStore.save(config) }
                ))
                .disabled(!running)
                Text("临时的策略开关：关闭后仍可自由切换输入法，常驻服务继续在后台待命、随时秒级恢复。要彻底停掉进程请用上面的「停止 / 卸载」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("当前输入法", value: currentName)
                LabeledContent("生效次数", value: running ? "\(activations)" : "—")

                if backoffActive && running {
                    Label("检测到冲突，已暂停强制锁定", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if !installed {
                    HStack {
                        Label("常驻服务尚未安装，上方开关暂不可用", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Button("安装并启动") { installService() }
                            .buttonStyle(.link)
                    }
                } else if !running {
                    HStack {
                        Label("常驻服务已停止，上方开关暂不可用", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Button("立即启动") { startService() }
                            .buttonStyle(.link)
                    }
                }
            }

            Section("锁定目标") {
                Picker("输入法", selection: Binding(
                    get: { config.targetID ?? "" },
                    set: { config.targetID = $0.isEmpty ? nil : $0; ConfigStore.save(config) }
                )) {
                    Text("未选择").tag("")
                    ForEach(sources) { s in
                        Text(s.name).tag(s.id)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: refreshAll)
        .onReceive(refreshTimer) { _ in
            currentName = TISBrowser.currentName()
            readState()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name("com.lockime-lite.state")
        )) { _ in
            currentName = TISBrowser.currentName()
            readState()
        }
    }

    var statusColor: Color {
        if !installed { return .secondary }
        return running ? .green : .orange
    }

    var serviceStatusText: String {
        if !installed { return "未安装" }
        return running ? "运行中" : "已停止（本次登录不再生效）"
    }

    func refreshAll() {
        config = ConfigStore.load()
        sources = TISBrowser.selectable()
        currentName = TISBrowser.currentName()
        readState()
        installed = ServiceManager.isInstalled()
        running = ServiceManager.isRunning()
    }

    func readState() {
        guard let st = NSDictionary(contentsOf: LitePaths.stateURL) else { return }
        activations = (st["activations"] as? Int) ?? 0
        backoffActive = (st["backoffActive"] as? Bool) ?? false
    }

    func installService() {
        guard let bundled = Bundle.main.url(forResource: "lockime-lite-daemon", withExtension: nil) else {
            errorMessage = "找不到内嵌的 daemon（应位于 App 包 Resources 内）"
            return
        }
        errorMessage = ServiceManager.install(daemonSource: bundled)
        ConfigStore.save(config)   // 确保 daemon 起来即能读到最新配置
        installed = ServiceManager.isInstalled()
        running = ServiceManager.isRunning()
    }

    func startService() {
        let (rc, out) = ServiceManager.launchctl(["bootstrap", ServiceManager.guiDomain, LitePaths.plistURL.path])
        errorMessage = rc == 0 ? nil : "启动失败：\(out)"
        running = ServiceManager.isRunning()
    }

    func stopService() {
        errorMessage = ServiceManager.stop()
        running = ServiceManager.isRunning()
    }

    func restartService() {
        let (rc, out) = ServiceManager.launchctl(["kickstart", "-k", "\(ServiceManager.guiDomain)/\(LitePaths.label)"])
        errorMessage = rc == 0 ? nil : "重启失败：\(out)"
        running = ServiceManager.isRunning()
    }

    func uninstallService() {
        errorMessage = ServiceManager.uninstall()
        installed = ServiceManager.isInstalled()
        running = ServiceManager.isRunning()
    }
}
