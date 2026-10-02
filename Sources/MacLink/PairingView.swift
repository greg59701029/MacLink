import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "8766"
    @State private var pairingCode = ""
    @State private var fingerprint = ""
    @State private var isPairing = false
    @State private var message: String?
    @State private var showingDisconnectConfirmation = false
    @State private var showingForgetConfirmation = false

    private var savedPairingWasRejected: Bool {
        model.connectionIssue?.contains("拒絕了這支 iPhone 的配對憑證") == true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    intro
                    if model.isPaired {
                        pairedStatus
                    } else {
                        pairingForm
                    }
                    if let message {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(message.hasPrefix("已") ? MacLinkTheme.lime : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22)
            }
            .background(MacLinkTheme.background.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("專屬連線設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label("返回", systemImage: "chevron.left") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.foregroundStyle(MacLinkTheme.lime)
                }
            }
            .confirmationDialog("撤銷這支 iPhone 的配對？", isPresented: $showingDisconnectConfirmation, titleVisibility: .visible) {
                Button("撤銷這支 iPhone", role: .destructive) {
                    Task {
                        do {
                            try await model.disconnect()
                            host = ""
                            pairingCode = ""
                            fingerprint = ""
                            message = "已撤銷這支 iPhone 的連線憑證，並清除此手機設定。請在 Mac 執行 show-pairing.command 取得配對碼。"
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("這項操作會撤銷這支 iPhone 的連線憑證。若本機仍使用舊版共用憑證，持有相同舊憑證的裝置也會失效。")
            }
            .confirmationDialog("只清除此 iPhone 的連線設定？", isPresented: $showingForgetConfirmation, titleVisibility: .visible) {
                Button("清除此手機設定", role: .destructive) {
                    do {
                        let savedHost = host
                        let savedPort = port
                        let savedFingerprint = fingerprint
                        try model.forgetLocalPairing()
                        host = savedHost
                        port = savedPort
                        pairingCode = ""
                        fingerprint = savedFingerprint
                        message = "已清除此手機設定；Mac 端授權未撤銷。請在 Mac 取得新的 6 位配對碼並輸入下方；位址、連接埠及指紋已保留，請確認與 Mac 顯示相同。"
                    } catch { message = error.localizedDescription }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("Mac 目前無法連線，因此這個操作只清除此手機的憑證，無法撤銷 Mac 端授權。之後必須重新配對；若懷疑憑證外洩，請在 Mac 撤銷舊授權。")
            }
        }
        .onAppear {
            if let profile = model.profile {
                host = profile.host
                port = String(profile.port)
                fingerprint = profile.certificateFingerprint
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "lock.iphone")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(MacLinkTheme.lime)
            Text("只配對你自己的 Mac")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(model.isPaired
                 ? "這支 iPhone 已保存 Mac 的連線資料。若憑證失效，請依下方提示重新配對。"
                 : "先確認 iPhone 與 Mac 的 Tailscale 都顯示已連線。在 Mac 開啟 MacLink companion 資料夾中的 show-pairing.command，照畫面填入 Mac 位址、連接埠 8766、6 位一次性配對碼及 TLS SHA-256 指紋。")
                .font(.system(size: 14))
                .foregroundStyle(MacLinkTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pairedStatus: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: model.hostStatus != nil ? "checkmark.circle.fill" : savedPairingWasRejected ? "key.slash" : "wifi.exclamationmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(model.hostStatus == nil ? Color.orange : MacLinkTheme.lime)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.hostStatus != nil ? "已配對並連線" : savedPairingWasRejected ? "這支手機的配對憑證已失效" : "配對已保存，Mac 暫時無法連線")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(model.hostStatus?.name ?? (savedPairingWasRejected ? "Mac 已拒絕這支 iPhone 的舊憑證" : "這支 iPhone 已配對到你的 Mac"))
                        .font(.system(size: 12))
                        .foregroundStyle(MacLinkTheme.muted)
                }
            }
            Text(model.hostStatus != nil
                 ? "連線設定已完成，不需要再輸入配對資料。點「完成」即可返回 app。"
                 : savedPairingWasRejected
                    ? "Mac 已明確拒絕這支手機的舊憑證。清除舊配對後，只需輸入 Mac 新產生的 6 位配對碼；位址、連接埠及指紋會保留，若 Mac 顯示不同資料再更新即可。"
                    : "目前無法連到 Mac。請確認 Mac 已開機、Tailscale 已連線且 MacLink 服務正在執行，再點「完成」回到首頁重試。")
                .font(.system(size: 13))
                .foregroundStyle(savedPairingWasRejected ? Color.orange : MacLinkTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if model.hostStatus == nil {
                Button(savedPairingWasRejected ? "清除舊憑證並重新配對" : "這支手機仍連不上？重新配對", role: .destructive) { showingForgetConfirmation = true }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }

            DisclosureGroup("進階安全設定") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("只撤銷這支 iPhone 的連線憑證；使用舊版共用憑證的裝置可能也需重新配對。")
                        .font(.system(size: 12))
                        .foregroundStyle(MacLinkTheme.muted)
                    Button("撤銷這支 iPhone 的配對", role: .destructive) { showingDisconnectConfirmation = true }
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 10)
            }
            .font(.system(size: 13, weight: .medium))
            .tint(MacLinkTheme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacLinkTheme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(MacLinkTheme.line, lineWidth: 1))
    }

    private var pairingForm: some View {
        Group {
            field("Mac 的私人連線位址", placeholder: "例如 100.101.102.103", text: $host, icon: "network")
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            HStack {
                Text("貼上 Mac 私人位址").font(.system(size: 13)).foregroundStyle(MacLinkTheme.muted)
                Spacer()
                PasteButton(payloadType: String.self) { values in
                    guard let value = values.first else { return }
                    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard PairingProfile.isPrivateIPv4(normalized) else {
                        message = "請只複製 Mac 的私人 IPv4 位址；尚未變更位址。"
                        return
                    }
                    host = normalized
                    message = nil
                }.tint(MacLinkTheme.lime).disabled(isPairing)
            }
            field("服務連接埠", placeholder: "8766", text: $port, icon: "dot.radiowaves.left.and.right")
                .keyboardType(.numberPad)
            field("一次性配對碼", placeholder: "輸入 Mac 顯示的 6 位數", text: $pairingCode, icon: "number")
                .keyboardType(.numberPad)
                .onChange(of: pairingCode) { _, value in pairingCode = String(value.filter(\.isNumber).prefix(6)) }
            HStack {
                Text("貼上一次性配對碼").font(.system(size: 13)).foregroundStyle(MacLinkTheme.muted)
                Spacer()
                PasteButton(payloadType: String.self) { values in
                    guard let value = values.first else { return }
                    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard normalized.count == 6, normalized.utf8.allSatisfy({ (48...57).contains($0) }) else {
                        message = "請只複製 6 位一次性配對碼；尚未變更配對碼。"
                        return
                    }
                    pairingCode = normalized
                    message = nil
                }.tint(MacLinkTheme.lime).disabled(isPairing)
            }
            field("TLS 憑證指紋", placeholder: "貼上 Mac 顯示的 SHA-256", text: $fingerprint, icon: "checkmark.shield")
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            HStack {
                Text("貼上 Mac 顯示的指紋")
                    .font(.system(size: 13))
                    .foregroundStyle(MacLinkTheme.muted)
                Spacer()
                PasteButton(payloadType: String.self) { values in
                    guard let value = values.first else { return }
                    let normalized = value.uppercased().filter { !$0.isWhitespace && $0 != ":" }
                    guard normalized.count == 64,
                          normalized.unicodeScalars.allSatisfy({ "0123456789ABCDEF".unicodeScalars.contains($0) }) else {
                        message = "請只複製 Mac 顯示的 64 位 TLS 指紋；尚未變更指紋。"
                        return
                    }
                    fingerprint = normalized
                    message = "已貼上指紋；請與 Mac 顯示的內容核對後再配對。"
                }
                .tint(MacLinkTheme.lime)
                .disabled(isPairing)
            }
            pairingButton
        }
    }

    private var pairingButton: some View {
        Button {
            guard let parsedPort = Int(port) else { message = "連接埠必須是數字。"; return }
            isPairing = true
            message = nil
            Task {
                defer { isPairing = false }
                do {
                    try await model.pair(host: host, port: parsedPort, code: pairingCode, fingerprint: fingerprint)
                    message = model.connectedMessage ?? "已完成配對。"
                } catch {
                    message = error.localizedDescription
                }
            }
        } label: {
            HStack {
                if isPairing { ProgressView().tint(MacLinkTheme.background) }
                Text(isPairing ? "正在安全配對…" : "建立專屬連線")
                Spacer()
                Image(systemName: "arrow.right")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(MacLinkTheme.background)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(MacLinkTheme.lime, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .disabled(isPairing || model.isPaired)
        .padding(.top, 4)
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(MacLinkTheme.lime).frame(width: 18)
                TextField(placeholder, text: text)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white)
                    .tint(MacLinkTheme.lime)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(MacLinkTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(MacLinkTheme.line, lineWidth: 1))
        }
    }
}
