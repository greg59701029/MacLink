import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profile: PairingProfile?
    @Published private(set) var pairingSessionID = UUID()
    @Published private(set) var hostStatus: HostStatus?
    @Published private(set) var isRefreshing = false
    @Published private(set) var connectionIssue: String?
    @Published var errorMessage: String?
    @Published var connectedMessage: String?

    private var token: String?
    private var activeClient: MacLinkClient?
    private var statusRequestID: UUID?
    private var pairingRequestID: UUID?
    private var pairingClient: MacLinkClient?
    private let profileKey = "maclink.profile.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: profileKey),
           let saved = try? JSONDecoder().decode(PairingProfile.self, from: data) {
            profile = saved
        }
        token = KeychainStore.readToken()
        if let profile, let token {
            activeClient = MacLinkClient(profile: profile, token: token)
        }
    }

    var isPaired: Bool { profile != nil && token != nil }
    var connectionLabel: String { hostStatus?.name ?? profile?.host ?? "尚未連線" }

    func pair(host: String, port: Int, code: String, fingerprint: String) async throws {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFingerprint = fingerprint.filter(\.isHexDigit).uppercased()
        guard PairingProfile.isPrivateIPv4(cleanHost),
              (1...65535).contains(port), code.count == 6, code.allSatisfy(\.isNumber),
              cleanFingerprint.count == 64 else {
            throw ClientError.server("請使用 Mac 顯示的 Tailscale 或區域網路 IPv4 位址，並確認 6 位配對碼及 64 位憑證指紋。")
        }
        let next = PairingProfile(host: cleanHost, port: port, certificateFingerprint: cleanFingerprint)
        try Task.checkCancellation()
        pairingClient?.cancelRequests()
        let requestID = UUID()
        let originalSessionID = pairingSessionID
        let client = MacLinkClient(profile: next, token: nil)
        pairingRequestID = requestID
        pairingClient = client
        defer {
            client.cancelRequests()
            if pairingRequestID == requestID {
                pairingRequestID = nil
                pairingClient = nil
            }
        }
        let response = try await client.pair(code: code)
        try Task.checkCancellation()
        guard pairingRequestID == requestID, pairingSessionID == originalSessionID else {
            throw CancellationError()
        }
        try KeychainStore.saveToken(response.token)
        activeClient?.cancelRequests()
        invalidateConnectionStatus()
        token = response.token
        profile = next
        activeClient = MacLinkClient(profile: next, token: response.token)
        pairingSessionID = UUID()
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: profileKey)
        }
        connectedMessage = "已安全配對到 \(response.name)"
        errorMessage = nil
        await refreshStatus()
    }

    func refreshStatus(silent: Bool = false) async {
        guard statusRequestID == nil, !Task.isCancelled else { return }
        guard let client = makeClient() else { hostStatus = nil; return }
        let requestID = UUID()
        statusRequestID = requestID
        isRefreshing = true
        defer {
            if statusRequestID == requestID {
                statusRequestID = nil
                isRefreshing = false
            }
        }
        do {
            let status = try await client.status()
            guard statusRequestID == requestID, !Task.isCancelled else { return }
            hostStatus = status
            connectionIssue = nil
            errorMessage = nil
        } catch {
            guard statusRequestID == requestID, !Task.isCancelled else { return }
            hostStatus = nil
            let diagnosis = Self.connectionDiagnosis(for: error)
            connectionIssue = diagnosis
            if !silent { errorMessage = diagnosis }
        }
    }

    // A late reply from the previous foreground session or pairing must not
    // restore a stale connected badge.
    func invalidateConnectionStatus() {
        statusRequestID = nil
        isRefreshing = false
        hostStatus = nil
        connectionIssue = nil
        errorMessage = nil
    }

    func monitorConnection() async {
        invalidateConnectionStatus()
        var retrySeconds = 2
        while !Task.isCancelled && isPaired {
            await refreshStatus(silent: true)
            guard !Task.isCancelled else { return }
            let delay = hostStatus == nil ? retrySeconds : 5
            retrySeconds = hostStatus == nil ? min(retrySeconds * 2, 15) : 2
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
        }
    }

    func listFiles(path: String) async throws -> FileListing {
        try await requiredClient().files(path: path)
    }

    func upload(data: Data, path: String) async throws -> String {
        try await requiredClient().uploadFile(data: data, path: path).message
    }

    func download(path: String) async throws -> Data {
        try await requiredClient().downloadFile(path: path)
    }

    func delete(path: String) async throws -> String {
        try await requiredClient().deleteFile(path: path).message
    }

    func createFolder(path: String) async throws -> String {
        try await requiredClient().createFolder(path: path).message
    }

    func screen() async throws -> Data {
        try await requiredClient().screen()
    }

    func input(action: String, x: Double? = nil, y: Double? = nil, endX: Double? = nil, endY: Double? = nil, text: String? = nil, key: String? = nil) async throws {
        _ = try await requiredClient().input(action: action, x: x, y: y, endX: endX, endY: endY, text: text, key: key)
    }

    func assistant(message: String, history: [HistoryItem]) async throws -> AssistantReply {
        try await requiredClient().assistant(message: message, history: history)
    }

    func assistantStream(message: String, history: [HistoryItem]) async throws -> URLSession.AsyncBytes {
        try await requiredClient().assistantStream(message: message, history: history)
    }

    func confirmAssistantAction(_ id: String) async throws -> String {
        try await requiredClient().confirmAction(id: id).message
    }

    func disconnect() async throws {
        let revokedSessionID = pairingSessionID
        _ = try await requiredClient().revoke()
        guard pairingSessionID == revokedSessionID else { throw CancellationError() }
        try forgetLocalPairing()
    }

    // This only removes this phone's credentials; it cannot revoke access on
    // an unreachable Mac. The UI makes that distinction before confirmation.
    func forgetLocalPairing() throws {
        try KeychainStore.deleteToken()
        pairingRequestID = nil
        pairingClient?.cancelRequests()
        pairingClient = nil
        activeClient?.cancelRequests()
        invalidateConnectionStatus()
        token = nil
        profile = nil
        activeClient = nil
        pairingSessionID = UUID()
        hostStatus = nil
        defaults.removeObject(forKey: profileKey)
        connectedMessage = nil
    }

    private func makeClient() -> MacLinkClient? {
        guard let profile, let token else { return nil }
        if let activeClient { return activeClient }
        let client = MacLinkClient(profile: profile, token: token)
        activeClient = client
        return client
    }

    static func connectionDiagnosis(for error: Error) -> String {
        if let clientError = error as? ClientError {
            switch clientError {
            case .invalidAddress:
                return "Mac 位址格式不正確。請到連線設定確認已配對的 Mac 位址。"
            case .invalidResponse:
                return "MacLink 回傳內容無法辨識。請更新 MacLink companion 後重試。"
            case .notPaired:
                return "這支 iPhone 尚未完成配對。請使用 MacLink 顯示的一次性配對碼重新配對。"
            case .server(let message):
                if message.contains("配對") || message.contains("授權") {
                    return "MacLink 拒絕了這支 iPhone 的配對憑證。請在 Mac 重新配對這支手機。"
                }
                return message
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "iPhone 目前沒有可用網路。請確認 Tailscale 已在 iPhone 上連線。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                return "目前無法透過私人網路到達 Mac。請確認 iPhone 與 Mac 的 Tailscale 都顯示已連線，且 MacLink 服務正在執行。"
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return "TLS 憑證驗證失敗。請確認配對的 Mac 位址與憑證仍屬於同一台 Mac。"
            default:
                break
            }
        }
        return "MacLink 連線失敗。請確認 iPhone 的 Tailscale 與 MacLink 服務狀態，再點「重新連線」。"
    }

    func requiredClient() throws -> MacLinkClient {
        guard let client = makeClient() else { throw ClientError.notPaired }
        return client
    }
}
