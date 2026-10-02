import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showPairing: Bool
    @Binding var selectedTab: AppTab
    @State private var showingReviewDemo = false

    private var pairingWasRejected: Bool {
        model.connectionIssue?.contains("拒絕了這支 iPhone 的配對憑證") == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                connectionCard
                if !model.isPaired {
                    Button { showingReviewDemo = true } label: {
                        Label("先看安全示範", systemImage: "rectangle.on.rectangle.angled")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(MacLinkTheme.lime)
                    .accessibilityHint("瀏覽使用範例資料的展示，不連線到任何 Mac")
                }
                quickActions
                footerNote
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 30)
        }
        .background(MacLinkTheme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingReviewDemo) {
            ReviewDemoView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .refreshable { await model.refreshStatus() }
        .alert("連線狀態", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MACLINK")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(MacLinkTheme.lime)
                Text("你的 Mac，\n就在手邊。")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineSpacing(1)
                Text("專屬連線 · 私人控制中心")
                    .font(.system(size: 14))
                    .foregroundStyle(MacLinkTheme.muted)
            }
            Spacer(minLength: 10)
            Button { showPairing = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(MacLinkTheme.panelRaised, in: Circle())
            }
            .accessibilityLabel("連線設定")
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(model.hostStatus != nil ? "Mac 已連線" : model.isPaired ? (model.isRefreshing ? "正在連線…" : "等待重新連線") : "尚未配對", systemImage: model.hostStatus == nil ? "circle.dashed" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.hostStatus == nil ? MacLinkTheme.muted : MacLinkTheme.lime)
                Spacer()
                if model.isRefreshing {
                    ProgressView().tint(MacLinkTheme.lime)
                } else {
                    Button { Task { await model.refreshStatus() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(MacLinkTheme.muted)
                    }
                    .accessibilityLabel("重新連線")
                }
            }

            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(MacLinkTheme.lime.opacity(0.12))
                        .frame(width: 64, height: 64)
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(MacLinkTheme.lime)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.hostStatus?.name ?? model.profile?.host ?? "尚未設定 Mac")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(model.hostStatus.map { "\($0.connectionMode == "tailnet" ? "Tailscale 私人連線" : "私人區域網路") · \($0.screenWidth) × \($0.screenHeight)" } ?? "透過 Tailscale 從外面連回這台 Mac")
                        .font(.system(size: 12))
                        .foregroundStyle(MacLinkTheme.muted)
                }
                Spacer(minLength: 0)
            }

            if model.connectionIssue != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("暫時無法連到 Mac，會自動重試。")
                        .font(.system(size: 13, weight: .medium))
                    Text(model.connectionIssue ?? "請確認 iPhone 與 Mac 的 Tailscale 都已連線。")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Color.orange)
                .accessibilityElement(children: .combine)
            }

            Button { showPairing = true } label: {
                HStack {
                    Text(model.isPaired ? (pairingWasRejected ? "修復配對" : "管理連線") : "開始配對這台 Mac")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MacLinkTheme.background)
                .padding(.horizontal, 18)
                .frame(height: 52)
                .background(MacLinkTheme.lime, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [MacLinkTheme.panelRaised, MacLinkTheme.panel], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 25, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(MacLinkTheme.line, lineWidth: 1))
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("控制中心")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("常用功能")
                    .font(.system(size: 12))
                    .foregroundStyle(MacLinkTheme.muted)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                QuickActionCard(title: "遠端桌面", detail: "畫面、點按、輸入", icon: "cursorarrow.motionlines", tint: MacLinkTheme.lime) {
                    selectedTab = .screen
                }
                QuickActionCard(title: "我的檔案", detail: "瀏覽、上傳、下載", icon: "folder", tint: Color(red: 0.56, green: 0.77, blue: 1)) {
                    selectedTab = .files
                }
                QuickActionCard(title: "Jarvis 助理", detail: "連到 Mac 本機模型", icon: "sparkles", tint: Color(red: 0.9, green: 0.68, blue: 1)) {
                    selectedTab = .assistant
                }
                QuickActionCard(title: "快速狀態", detail: "主機連線與顯示資訊", icon: "waveform.path.ecg", tint: Color(red: 1, green: 0.69, blue: 0.42)) {
                    Task { await model.refreshStatus() }
                }
            }
        }
    }

    private var footerNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(MacLinkTheme.lime)
            Text("Tailscale 私人網路 · TLS 憑證鎖定 · 金鑰存於 iPhone Keychain")
                .font(.system(size: 11))
                .foregroundStyle(MacLinkTheme.muted)
        }
        .padding(.horizontal, 2)
    }
}

/// A no-network, synthetic-data tour for App Review and first-time users.
/// Nothing in this screen reads files, calls Codex, starts a phone call, or controls a Mac.
private struct ReviewDemoView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text("這是安全示範。所有畫面均使用虛構範例，不連線、不讀寫任何 Mac 資料，也不會撥打電話。")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "lock.shield.fill").foregroundStyle(MacLinkTheme.lime)
                    }
                    .padding(.vertical, 4)
                }

                Section("遠端桌面 · 範例畫面") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Circle().fill(Color.yellow).frame(width: 8, height: 8)
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Spacer()
                            Text("示範桌面").font(.caption).foregroundStyle(.secondary)
                        }
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 0.10, green: 0.14, blue: 0.18))
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.system(size: 30))
                                        .foregroundStyle(MacLinkTheme.lime)
                                    Text("Mac 桌面預覽")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                    Text("示範影像 · 無鍵鼠操作")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.65))
                                }
                            }
                            .frame(height: 145)
                    }
                    .padding(.vertical, 6)
                    Text("正式連線後，已配對的 iPhone 才能在你授權下查看畫面並傳送操作。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("檔案 · 虛構項目") {
                    Label("產品介紹.pdf", systemImage: "doc.text")
                    Label("示範圖片.png", systemImage: "photo")
                    Label("專案資料夾", systemImage: "folder")
                    Text("示範項目無法下載、上傳或刪除。正式模式只存取你選擇的 Mac。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Jarvis 助理 · 範例對話") {
                    demoMessage("你", "電腦目前狀態？")
                    demoMessage("Jarvis", "這是虛構示範回覆。正式模式會連到你 Mac 上設定的本機助理。")
                    Text("正式模式中的操作仍會先顯示確認。此示範不執行任何指令。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Codex 任務 · 虛構項目") {
                    Label("整理產品文件", systemImage: "pin.fill")
                    Label("檢查版本更新", systemImage: "checklist")
                    Text("此處是示範內容，不會讀取或傳送任何真實任務。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("通話 · 示範記錄") {
                    Label("未撥出電話 · 僅為範例", systemImage: "phone.badge.waveform")
                    Text("通話狀態與逐字稿只會在實際通話後顯示；此示範沒有撥號，也沒有真實逐字稿。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(MacLinkTheme.background)
            .navigationTitle("功能安全示範")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .tint(MacLinkTheme.lime)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @Environment(\.dismiss) private var dismiss

    private func demoMessage(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(MacLinkTheme.lime)
            Text(text).font(.subheadline)
        }
        .padding(.vertical, 3)
    }
}

private struct QuickActionCard: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text(detail).font(.system(size: 11)).foregroundStyle(MacLinkTheme.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(MacLinkTheme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(MacLinkTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
