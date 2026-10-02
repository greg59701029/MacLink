import SwiftUI
import Darwin

@main
struct MacLinkCompanionApp: App {
    var body: some Scene {
        WindowGroup("MacLink Companion") { CompanionView() }
            .windowResizability(.contentSize)
    }
}

struct CompanionView: View {
    @State private var output = "先在這台 Mac 安裝 Tailscale、Python 3.10 以上與 OpenSSL，然後檢查環境。正式 App 已內含桌面控制工具；不需 Xcode。"
    @State private var working = false
    @State private var confirmRemoval = false

    private var bridge: URL {
        Bundle.main.resourceURL!.appendingPathComponent("MacBridge", isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MacLink Companion").font(.title2.bold())
            Text("只連接你自己的 Mac。服務安裝在目前使用者帳號，並監聽 Tailscale 私人位址。首次啟動才在這台 Mac 建立專屬憑證與配對碼。")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("檢查環境") { execute(.check) }
                Button("安裝／更新") { execute(.install) }
                Button("顯示配對資訊") { execute(.pairing) }
            }
            HStack {
                Button("檢查連線與權限") { execute(.diagnostics) }
                Button("停止服務") { execute(.stop) }
                Button("移除程式") { confirmRemoval = true }
            }
            .disabled(working)
            ScrollView {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 220)
            .padding(10)
            .background(.quaternary.opacity(0.3))
            Text("螢幕錄製及輔助使用權限須由你在 macOS 系統設定授予 Python。移除程式會保留此 Mac 的配對憑證、設定與記錄；停止服務也不會刪除它們。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 650)
        .confirmationDialog("移除 MacLink 服務程式？", isPresented: $confirmRemoval) {
            Button("移除服務程式，保留配對資料", role: .destructive) { execute(.remove) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會停止服務並移除登入啟動項與已安裝程式；不刪除憑證、權杖或記錄。")
        }
    }

    private enum Operation: Equatable { case check, install, pairing, diagnostics, stop, remove }

    private func execute(_ operation: Operation) {
        guard !working else { return }
        working = true
        output = "正在執行…"
        let resourcePath = bridge.path
        Task.detached {
            let result = Self.run(operation, resourcePath: resourcePath)
            await MainActor.run { output = result; working = false }
        }
    }

    nonisolated private static func python() -> String? {
        for path in ["/opt/homebrew/bin/python3.13", "/usr/local/bin/python3.13",
                     "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    nonisolated private static func run(_ operation: Operation, resourcePath: String) -> String {
        let manager = FileManager.default
        guard let python = python() else { return "找不到 Python 3.10 以上；請先安裝，再按「檢查環境」。" }
        let home = manager.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/MacLink")
        let launchAgent = home.appendingPathComponent("Library/LaunchAgents/com.adam.maclink.plist")
        let command: String
        let arguments: [String]
        switch operation {
        case .check, .install:
            command = python
            arguments = ["-B", resourcePath + "/install_service.py"] + (operation == .check ? ["--check"] : [])
        case .pairing:
            command = "/bin/zsh"; arguments = [resourcePath + "/show-pairing.command"]
        case .diagnostics:
            command = python; arguments = ["-B", resourcePath + "/diagnostics.py"]
        case .stop, .remove:
            command = "/bin/launchctl"
            arguments = ["bootout", "gui/\(getuid())/com.adam.maclink"]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOME"] = home.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "無法執行：\(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: data.prefix(16_384), as: UTF8.self)
        if operation == .remove {
            guard process.terminationStatus == 0 else {
                return "未確認服務已停止，因此沒有移除程式。請先按「停止服務」並檢查狀態。\n" + message
            }
            var failures: [String] = []
            for item in [launchAgent] + ["server.py", "assistant_actions.py", "agent_transport.py", "codex_tasks.py",
                                          "input_helper.swift", "input-helper", "screen_stream.py", "screen_stream.swift", "screen-stream", "diagnostics.py",
                                          "install_service.py", "install.command", "run.command", "check-connection.command",
                                          "show-pairing.command", "SETUP.md"].map({ support.appendingPathComponent("Bridge/" + $0) }) {
                guard manager.fileExists(atPath: item.path) else { continue }
                do { try manager.removeItem(at: item) }
                catch { failures.append(item.lastPathComponent) }
            }
            if !failures.isEmpty { return "部分程式未移除：" + failures.joined(separator: "、") }
            return "服務程式與登入啟動項已移除。配對憑證、權杖及記錄仍保存在這台 Mac；如需刪除，請另行管理。"
        }
        return message.isEmpty ? (process.terminationStatus == 0 ? "完成。" : "操作未完成（代碼 \(process.terminationStatus)）。") : message
    }
}
