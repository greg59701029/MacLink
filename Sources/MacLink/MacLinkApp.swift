import SwiftUI

@main
struct MacLinkApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

struct AppShell: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .home
    @State private var showingPairing = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(showPairing: $showingPairing, selectedTab: $selectedTab)
            }
            .tabItem { Label("總覽", systemImage: "square.grid.2x2.fill") }
            .tag(AppTab.home)

            NavigationStack {
                ScreenView(pairingSessionID: model.pairingSessionID, isSelected: selectedTab == .screen)
                    .id(model.pairingSessionID)
                    .toolbar { homeButton }
            }
            .tabItem { Label("桌面", systemImage: "display") }
            .tag(AppTab.screen)

            NavigationStack {
                FilesView(pairingSessionID: model.pairingSessionID, returnHome: { selectedTab = .home })
                    .id(model.pairingSessionID)
            }
            .tabItem { Label("檔案", systemImage: "folder.fill") }
            .tag(AppTab.files)

            NavigationStack {
                AssistantView(pairingSessionID: model.pairingSessionID)
                    .id(model.pairingSessionID)
                    .toolbar { homeButton }
            }
            .tabItem { Label("助理", systemImage: "sparkles") }
            .tag(AppTab.assistant)
            NavigationStack {
                CodexTasksView().id(model.pairingSessionID)
            }
            .tabItem { Label("Codex", systemImage: "checklist") }
            .tag(AppTab.codex)
        }
        .tint(MacLinkTheme.lime)
        .sheet(isPresented: $showingPairing) {
            PairingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .task(id: "\(scenePhase)-\(model.pairingSessionID)") {
            guard scenePhase == .active, model.isPaired else { return }
            await model.monitorConnection()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.invalidateConnectionStatus() }
        }
    }

    private var homeButton: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { selectedTab = .home } label: {
                Label("回首頁", systemImage: "chevron.left")
            }
            .accessibilityLabel("返回首頁")
        }
    }
}

enum AppTab: Hashable {
    case home, screen, files, assistant, codex
}

struct CodexModelList: Decodable { let models: [CodexModel] }
struct CodexModel: Decodable, Identifiable { let id: String; let name: String }

struct CodexTaskList: Decodable { let tasks: [CodexTaskRow]; let pinnedTasks: [CodexTaskRow]?; let warning: String?; let nextCursor: String? }
struct CodexTaskRow: Decodable, Identifiable { let id: String; let title: String; let project: String? }
struct CodexApproval: Decodable, Identifiable { let id: String; let details: String }
struct CodexTaskDetail: Decodable {
    struct Message: Decodable, Equatable { let role: String; let text: String }
    let id: String
    let messages: [Message]
    let activeTurn: String?
    let latestTurnStatus: String?
    let approvals: [CodexApproval]?
    let notice: String?
}
struct CodexCallList: Decodable { let calls: [CodexCallRecord] }
struct CodexCallRecord: Decodable, Identifiable {
    let id: String
    let thread: String
    let created: Double
    let status: String
    let dial_status: String?
    let requested_at: Double?
    let connected_at: Double?
    let ended_at: Double?
    let detail: String?
    let transcriptTurns: Int
}
struct CodexCallTranscript: Decodable {
    struct Turn: Decodable, Identifiable {
        var id: Int { seq }
        let role: String
        let content: String
        let created: Double
        let seq: Int
    }
    let id: String
    let thread: String
    let status: String
    let detail: String?
    let transcript: [Turn]
}

struct CodexTasksView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tasks: [CodexTaskRow] = []
    @State private var pinnedTasks: [CodexTaskRow] = []
    @State private var search = ""
    @State private var pinnedWarning: String?
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Text("使用這台 Mac 已登入的 Codex；任務內容會傳送至 OpenAI。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.orange) }
            Section("置頂任務") {
                if let pinnedWarning { Text(pinnedWarning).foregroundStyle(.orange) }
                else if pinnedTasks.isEmpty { Text(loading ? "讀取置頂任務…" : "這台 Mac 尚無置頂任務").foregroundStyle(.secondary) }
                ForEach(pinnedTasks.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { task in
                    NavigationLink { CodexTaskView(task: task, pairingSessionID: model.pairingSessionID) } label: {
                        Label(task.title, systemImage: "pin.fill").lineLimit(3)
                    }
                }
            }
            ForEach(projects, id: \.self) { project in
              Section(project) {
                ForEach(otherTasks.filter { ($0.project ?? "一般任務") == project }) { task in
                    NavigationLink { CodexTaskView(task: task, pairingSessionID: model.pairingSessionID) } label: {
                        Text(task.title).lineLimit(3)
                    }
                }
              }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if nextCursor != nil { Button("載入更多任務") { Task { await refresh(more: true) } }.padding().disabled(loading) }
        }
        .navigationTitle("Codex 任務")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refresh() } } label: {
                    Label("重新整理任務", systemImage: "arrow.clockwise")
                }.disabled(loading || model.hostStatus == nil)
            }
        }
        .searchable(text: $search, prompt: "搜尋已載入的任務")
        .task(id: model.pairingSessionID) { await refresh() }
        .onChange(of: model.hostStatus != nil) { _, connected in
            if connected { Task { await refresh() } }
        }
        .refreshable { await refresh() }
    }
    private var otherTasks: [CodexTaskRow] {
        tasks.filter { task in
            !pinnedTasks.contains(where: { $0.id == task.id }) &&
            (search.isEmpty || task.title.localizedCaseInsensitiveContains(search) || (task.project ?? "").localizedCaseInsensitiveContains(search))
        }
    }
    private var projects: [String] { Array(Set(otherTasks.map { $0.project ?? "一般任務" })).sorted() }
    private func refresh(more: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await model.requiredClient().codexTasks(cursor: more ? nextCursor : nil)
            if more {
                let existing = Set(tasks.map(\.id))
                tasks += result.tasks.filter { !existing.contains($0.id) }
            } else { tasks = result.tasks }
            if let pinned = result.pinnedTasks { pinnedTasks = pinned }
            pinnedWarning = result.warning
            nextCursor = result.nextCursor
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }
}

struct CodexTaskView: View {
    let task: CodexTaskRow
    let pairingSessionID: UUID
    @EnvironmentObject private var model: AppModel
    @State private var detail: CodexTaskDetail?
    @State private var actionError: String?
    @State private var selectedApproval: CodexApproval?
    @State private var callStatus: String?
    @State private var callRecords: [CodexCallRecord] = []
    @State private var callTranscripts: [String: CodexCallTranscript] = [:]
    @State private var expandedCallID: String?
    @State private var callHistoryError: String?
    @State private var text = ""
    @State private var error: String?
    @State private var isRefreshing = false
    @State private var busy = false
    @State private var followsLatest = true
    @State private var positionedInitially = false
    @State private var showingHandoffSummary = false
    @State private var showingDataConsent = false
    @State private var availableModels: [CodexModel] = []
    @State private var selectedModel = ""
    @State private var modelIssue: String?
    @FocusState private var focused: Bool
    var body: some View {
        VStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if detail == nil {
                        if let error {
                            Text(error).foregroundStyle(.orange).textSelection(.enabled)
                            Button("重新載入任務") { Task { await refresh() } }
                                .buttonStyle(.borderedProminent)
                        } else {
                            ProgressView(isRefreshing ? "正在載入 Codex 任務…" : "連線中…")
                        }
                    }
                    if let detail {
                        if detail.messages.isEmpty {
                            Text("這個任務目前沒有文字對話。請重新整理，或返回任務列表選擇其他任務。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(detail.messages.enumerated()), id: \.offset) { _, message in
                            VStack(alignment: .leading) {
                                Text(message.role == "user" ? "你" : "Codex").font(.caption).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(detail.approvals ?? []) { approval in
                            Button("查看待批准操作") { selectedApproval = approval }
                                .buttonStyle(.borderedProminent)
                        }
                        if detail.activeTurn != nil { ProgressView((detail.approvals ?? []).isEmpty ? "Codex 執行中" : "等待你的批准") }
                        if let status = detail.latestTurnStatus {
                            Text(status == "completed" ? "回合已完成 · 請核對實際結果" : status == "failed" ? "回合失敗 · 請查看回覆" : status == "interrupted" ? "回合已中止" : "回合進行中")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let notice = detail.notice { Text(notice).foregroundStyle(.orange) }
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                    if let actionError { Text(actionError).foregroundStyle(.orange).textSelection(.enabled) }
                    if let callStatus { Text(callStatus).foregroundStyle(.secondary) }
                    if !callRecords.isEmpty || callHistoryError != nil {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("通話記錄與逐字稿").font(.headline)
                            if let callHistoryError { Text(callHistoryError).font(.footnote).foregroundStyle(.orange) }
                            ForEach(callRecords) { record in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label(callStatusTitle(record), systemImage: record.status == "connected" || record.connected_at != nil ? "phone.fill" : "phone")
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text(Date(timeIntervalSince1970: record.created), style: .date)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text("建立：\(Date(timeIntervalSince1970: record.created).formatted(date: .omitted, time: .shortened))" + (record.connected_at.map { " · 接通：\(Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened))" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let detail = record.detail, !detail.isEmpty {
                                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                                    }
                                    if let transcript = callTranscripts[record.id], expandedCallID == record.id {
                                        if transcript.transcript.isEmpty {
                                            Text("這通電話沒有保存到逐字稿。").font(.footnote).foregroundStyle(.secondary)
                                        } else {
                                            ForEach(transcript.transcript) { turn in
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(turn.role == "user" ? "你" : "小秘書").font(.caption).foregroundStyle(.secondary)
                                                    Text(turn.content).font(.footnote).textSelection(.enabled)
                                                }.frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                        Button("收起逐字稿") { expandedCallID = nil }
                                            .font(.footnote)
                                    } else if callTranscripts[record.id] != nil {
                                        Button("顯示逐字稿") { expandedCallID = record.id }.font(.footnote)
                                    } else {
                                        Button(record.transcriptTurns > 0 ? "查看逐字稿（\(record.transcriptTurns) 段）" : "查看通話詳情") {
                                            Task { await loadCallTranscript(record) }
                                        }.font(.footnote)
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("latest-message")
                }.padding()
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .modifier(TaskLatestPosition(followsLatest: $followsLatest))
            .task(id: detail?.messages.last?.text) {
                guard detail?.messages.isEmpty == false,
                      !positionedInitially || followsLatest else { return }
                // Wait for SwiftUI to measure long Codex messages before scrolling.
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                guard !Task.isCancelled, !positionedInitially || followsLatest else { return }
                proxy.scrollTo("latest-message", anchor: .bottom)
                await Task.yield()
                proxy.scrollTo("latest-message", anchor: .bottom)
                positionedInitially = true
            }
            .onChange(of: focused) { _, _ in
                if followsLatest { proxy.scrollTo("latest-message", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button {
                        followsLatest = true
                        withAnimation { proxy.scrollTo("latest-message", anchor: .bottom) }
                    } label: { Label("最新訊息", systemImage: "arrow.down") }
                    .buttonStyle(.borderedProminent).padding()
                }
            }
            }
            VStack(alignment: .leading, spacing: 4) {
                Picker("Codex 模型", selection: $selectedModel) {
                    Text("沿用任務模型").tag("")
                    ForEach(availableModels) { option in Text(option.name).tag(option.id) }
                }.disabled(busy || detail?.activeTurn != nil)
                Text("目錄由 Mac 的 Codex 提供；使用權以實際任務結果為準。")
                    .font(.caption).foregroundStyle(.secondary)
                if let modelIssue {
                    Text(modelIssue).font(.caption).foregroundStyle(.orange)
                    Button("重載模型目錄") { Task { await loadModels() } }
                }
            }.padding(.horizontal)
            HStack {
                TextField("交辦或接續這個任務", text: $text, axis: .vertical)
                    .lineLimit(1...5).focused($focused)
                Button("送出") { focused = false; showingDataConsent = true }
                    .disabled(busy || model.hostStatus == nil || detail == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || detail?.activeTurn != nil)
            }.padding()
        }
        .sheet(isPresented: $showingHandoffSummary) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("先核對摘要，再自行選擇傳給小秘書或 dot。這是文字交接，不會連接同一會話或同步助理記憶。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(handoffSummary).textSelection(.enabled)
                        ShareLink(item: handoffSummary) { Label("選擇交接方式", systemImage: "square.and.arrow.up") }
                    }.padding()
                }
                .navigationTitle("任務交接摘要")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showingHandoffSummary = false } } }
            }
        }
        .confirmationDialog("同意將這次任務內容傳送至 OpenAI？", isPresented: $showingDataConsent, titleVisibility: .visible) {
            Button("同意並送出") { Task { await send() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("訊息會透過已配對的 Mac 交給 Codex，並由 OpenAI 處理；Codex 執行任務時也可能傳送相關對話及檔案內容。請先移除不想分享的私人資料。取消會保留草稿。")
        }
        .sheet(item: $selectedApproval) { approval in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("請核對操作內容。允許僅適用於這一次要求，不會授予永久權限。")
                        Text(approval.details).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        Button("允許這一次") { Task { await answer(approval, decision: "accept") } }
                            .buttonStyle(.borderedProminent).disabled(busy)
                        Button("拒絕", role: .destructive) { Task { await answer(approval, decision: "decline") } }.disabled(busy)
                        if let actionError { Text(actionError).foregroundStyle(.orange) }
                    }.padding()
                }
                .navigationTitle("操作批准")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("稍後") { selectedApproval = nil } } }
            }
        }
        .navigationTitle("Codex")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button { showingHandoffSummary = true } label: { Label("交接摘要", systemImage: "doc.text") }
                    .disabled(detail == nil)
            }
            ToolbarItem(placement: .bottomBar) {
                Button { Task { await call() } } label: { Label("請小秘書來電", systemImage: "phone") }
                    .disabled(busy)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if focused { Button("收起鍵盤") { focused = false } }
                else if detail?.activeTurn != nil {
                    Button("停止", role: .destructive) { Task {
                        do {
                            guard model.pairingSessionID == pairingSessionID else { return }
                            _ = try await model.requiredClient().codexStop(id: task.id)
                            await refresh()
                        }
                        catch { self.error = error.localizedDescription }
                    }}
                }
            }
        }
        .task {
            await loadModels()
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard model.pairingSessionID == pairingSessionID, !Task.isCancelled else { return }
            let result = try await model.requiredClient().codexTask(id: task.id)
            guard model.pairingSessionID == pairingSessionID, !Task.isCancelled else { return }
            detail = result
            error = nil
            let calls = try await model.requiredClient().codexCalls(thread: task.id)
            guard model.pairingSessionID == pairingSessionID, !Task.isCancelled else { return }
            callRecords = calls.calls
            callHistoryError = nil
        }
        catch {
            if !Task.isCancelled {
                if detail == nil { self.error = error.localizedDescription }
                else { callHistoryError = "無法讀取通話記錄：\(error.localizedDescription)" }
            }
        }
    }
    private func call() async {
        guard !busy, model.pairingSessionID == pairingSessionID else { return }
        busy = true
        focused = false
        defer { busy = false }
        do {
            callStatus = try await model.requiredClient().codexCall(id: task.id).message
            await refresh()
        }
        catch { callStatus = error.localizedDescription }
    }
    private func loadCallTranscript(_ record: CodexCallRecord) async {
        guard model.pairingSessionID == pairingSessionID else { return }
        do {
            let transcript = try await model.requiredClient().codexCallTranscript(id: record.id, thread: task.id)
            callTranscripts[record.id] = transcript
            expandedCallID = record.id
        } catch { callHistoryError = "無法讀取逐字稿：\(error.localizedDescription)" }
    }
    private func callStatusTitle(_ record: CodexCallRecord) -> String {
        switch record.status {
        case "connected", "active": return "已接通"
        case "ended": return record.connected_at != nil ? "曾接通，已結束" : "未接通，已結束"
        case "no_answer": return "未接聽"
        case "failed": return "撥號失敗"
        case "requested", "dial_requested", "dialing", "requested_unverified", "uncertain": return "已請求，尚未確認接通"
        case "not_dialed": return "未撥出"
        case "cancelled": return "已取消"
        case "simulated": return "模擬通話"
        default: return record.status
        }
    }
    private func answer(_ approval: CodexApproval, decision: String) async {
        guard !busy, model.pairingSessionID == pairingSessionID else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await model.requiredClient().codexApproval(id: task.id, approval: approval.id, decision: decision)
            selectedApproval = nil
            await refresh()
        } catch { actionError = error.localizedDescription }
    }
    private var handoffSummary: String {
        let recent = detail?.messages.suffix(3).map { "\($0.role == "user" ? "使用者" : "Codex")：\($0.text)" }.joined(separator: "\n\n") ?? "尚無對話"
        return "MacLink 任務交接\n任務：\(task.title)\n狀態：\(detail?.latestTurnStatus ?? "未知")\n\n最近對話（請先核對是否含私人資料）：\n\(recent)\n\n請先確認目前目標及下一步；此摘要不表示同一會話或已同步記憶。"
    }
    private func loadModels() async {
        do {
            guard model.pairingSessionID == pairingSessionID else { return }
            let result = try await model.requiredClient().codexModels()
            guard model.pairingSessionID == pairingSessionID else { return }
            availableModels = result.models
            if !availableModels.contains(where: { $0.id == selectedModel }) { selectedModel = "" }
            modelIssue = nil
        } catch { modelIssue = "模型目錄未載入，可沿用任務模型或重試。" }
    }
    private func send() async {
        guard !busy, model.hostStatus != nil, model.pairingSessionID == pairingSessionID, detail != nil, detail?.activeTurn == nil else { return }
        let submitted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else { return }
        text = ""
        actionError = nil
        busy = true
        focused = false
        defer { busy = false }
        do {
            _ = try await model.requiredClient().codexSend(id: task.id, message: submitted, model: selectedModel)
            text = ""
            await refresh()
        } catch {
            guard model.pairingSessionID == pairingSessionID else { return }
            actionError = "送出未確認，請先查看任務是否已收到，避免重複執行。\n\(error.localizedDescription)\n原訊息：\(submitted)"
        }
    }
}

enum MacLinkTheme {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.065)
    static let panel = Color(red: 0.075, green: 0.105, blue: 0.115)
    static let panelRaised = Color(red: 0.105, green: 0.145, blue: 0.15)
    static let lime = Color(red: 0.78, green: 0.96, blue: 0.40)
    static let muted = Color(red: 0.56, green: 0.64, blue: 0.65)
    static let line = Color.white.opacity(0.08)
}

/// Uses scroll geometry so reading older messages does not get interrupted by polling.
private struct TaskLatestPosition: ViewModifier {
    @Binding var followsLatest: Bool
    @State private var userScrolling = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 100
            } action: { _, nearBottom in
                if userScrolling { followsLatest = nearBottom }
            }
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
            }
        } else {
            content
        }
    }
}
