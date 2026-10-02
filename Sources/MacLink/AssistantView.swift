import SwiftUI

struct AssistantView: View {
    let pairingSessionID: UUID
    @EnvironmentObject private var model: AppModel
    @State private var messages: [ChatMessage] = [
        ChatMessage(role: .assistant, text: "我可以在你確認後開啟 App、輸入文字、捲動畫面與按鍵。例如「開啟計算機」或「輸入文字：你好」。切到桌面可查看操作結果。")
    ]
    @State private var inputText = ""
    @State private var isSending = false
    @State private var isConfirming = false
    @State private var pendingActionID: String?
    @State private var pendingActionSummary: String?
    @State private var showingActionConfirmation = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topStatus
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 15) {
                        ForEach(messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }
                        if isSending {
                            HStack {
                                ProgressView().tint(MacLinkTheme.lime)
                                Text("Mac 本機助理正在回覆…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(MacLinkTheme.muted)
                                Spacer()
                            }
                            .padding(.horizontal, 18)
                        }
                    }
                    .padding(.vertical, 18)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: messages.last?.text) { _, _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            quickCommands
            composer
        }
        .background(MacLinkTheme.background.ignoresSafeArea())
        .navigationTitle("Jarvis 助理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if inputFocused {
                    Button("收起鍵盤") { inputFocused = false }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起鍵盤") { inputFocused = false }
            }
        }
        .confirmationDialog(pendingActionSummary ?? "執行這項 Mac 操作？", isPresented: $showingActionConfirmation, titleVisibility: .visible) {
            Button("確認執行") { Task { await confirmAction() } }
            Button("取消", role: .cancel) { pendingActionID = nil; pendingActionSummary = nil }
        } message: {
            Text("請確認目前 Mac 前景視窗。輸入文字與按鍵會作用於該視窗；實際執行前仍由你確認。")
        }
    }

    private var quickCommands: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["電腦狀態", "開啟計算機", "開啟備忘錄", "向下捲動"], id: \.self) { command in
                    Button(command) {
                        inputText = command
                        send()
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .foregroundStyle(MacLinkTheme.lime)
                    .background(MacLinkTheme.panel, in: Capsule())
                    .disabled(isSending || isConfirming || model.hostStatus == nil || pendingActionID != nil)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private var topStatus: some View {
        HStack(spacing: 9) {
            Circle().fill(model.hostStatus != nil ? MacLinkTheme.lime : Color.orange).frame(width: 7, height: 7)
            Text(model.hostStatus != nil ? (model.hostStatus?.assistantRuntimeAvailable == false ? "Mac 尚未安裝助理 · 可先查詢電腦狀態" : "Mac 已連線 · 使用這台電腦的本機模型") : model.isPaired ? "等待 Mac 連線" : "請先配對 Mac")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MacLinkTheme.muted)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(MacLinkTheme.panel)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("傳送訊息給 Jarvis…", text: $inputText, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send() }
                .foregroundStyle(.white)
                .tint(MacLinkTheme.lime)
                .padding(.vertical, 10)
            Button(action: send) {
                Image(systemName: isSending ? "hourglass" : "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(MacLinkTheme.background)
                    .frame(width: 36, height: 36)
                    .background(MacLinkTheme.lime, in: Circle())
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || isConfirming || pendingActionID != nil || model.hostStatus == nil)
            .accessibilityLabel("傳送訊息")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(MacLinkTheme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(MacLinkTheme.line, lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(MacLinkTheme.background)
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isConfirming, pendingActionID == nil,
              model.hostStatus != nil, model.pairingSessionID == pairingSessionID else { return }
        inputText = ""
        inputFocused = false
        messages.append(ChatMessage(role: .user, text: text))
        let history = messages.suffix(12).map { item in
            HistoryItem(role: item.role == .user ? "user" : "assistant", content: item.text)
        }
        isSending = true
        Task {
            defer { isSending = false }
            do {
                guard model.pairingSessionID == pairingSessionID else { return }
                let bytes = try await model.assistantStream(message: text, history: Array(history))
                var receivedText = false
                var completed = false
                for try await line in bytes.lines {
                    guard model.pairingSessionID == pairingSessionID else { return }
                    guard let data = line.data(using: .utf8),
                          let event = try? JSONDecoder().decode(AssistantStreamEvent.self, from: data) else {
                        throw ClientError.invalidResponse
                    }
                    switch event.type {
                    case "delta":
                        guard let fragment = event.text else { throw ClientError.invalidResponse }
                        if !receivedText {
                            messages.append(ChatMessage(role: .assistant, text: fragment))
                            receivedText = true
                        } else if let index = messages.indices.last {
                            messages[index].text += fragment
                        }
                    case "done":
                        completed = true
                        if let actionID = event.actionID, let summary = event.actionSummary {
                            pendingActionID = actionID
                            pendingActionSummary = summary
                            showingActionConfirmation = true
                        }
                    case "error":
                        throw ClientError.server(event.text ?? "Mac 本機助理暫時無法回覆。")
                    default:
                        throw ClientError.invalidResponse
                    }
                }
                if !completed || !receivedText { throw ClientError.invalidResponse }
            } catch {
                guard model.pairingSessionID == pairingSessionID else { return }
                messages.append(ChatMessage(role: .assistant, text: "目前無法連到 Mac 本機助理：\(error.localizedDescription)"))
            }
        }
    }

    private func confirmAction() async {
        guard model.hostStatus != nil, model.pairingSessionID == pairingSessionID, !isConfirming,
              let actionID = pendingActionID else { return }
        isConfirming = true
        pendingActionID = nil
        pendingActionSummary = nil
        defer { isConfirming = false }
        do {
            let result = try await model.confirmAssistantAction(actionID)
            guard model.pairingSessionID == pairingSessionID else { return }
            messages.append(ChatMessage(role: .assistant, text: result))
        } catch {
            guard model.pairingSessionID == pairingSessionID else { return }
            messages.append(ChatMessage(role: .assistant, text: error.localizedDescription))
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 45) }
            Text(message.text)
                .font(.system(size: 14))
                .foregroundStyle(message.role == .user ? MacLinkTheme.background : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(message.role == .user ? MacLinkTheme.lime : MacLinkTheme.panelRaised, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            if message.role == .assistant { Spacer(minLength: 45) }
        }
        .padding(.horizontal, 14)
    }
}
