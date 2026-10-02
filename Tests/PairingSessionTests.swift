import Foundation

// Compile with the production AppModel and Models, replacing only network and
// Keychain dependencies. This executable never connects to or revokes a Mac.
struct HistoryItem { let role: String; let content: String }
enum ClientError: Error { case invalidAddress, invalidResponse, notPaired, server(String) }
enum KeychainStore {
    static var token: String?
    static var failDelete = false
    static func readToken() -> String? { token }
    static func saveToken(_ value: String) throws { token = value }
    static func deleteToken() throws {
        if failDelete { throw ClientError.server("fixture failure") }
        token = nil
    }
}
final class MacLinkClient {
    static var clients: [MacLinkClient] = []
    static var delayPair = false
    static var pairReply: CheckedContinuation<PairResponse, Never>?
    static var revokeReply: CheckedContinuation<ActionResult, Never>?
    let profile: PairingProfile
    var cancelled = false
    init(profile: PairingProfile, token: String?) {
        self.profile = profile
        Self.clients.append(self)
    }
    func cancelRequests() { cancelled = true }
    func pair(code: String) async throws -> PairResponse {
        if Self.delayPair { return await withCheckedContinuation { Self.pairReply = $0 } }
        return PairResponse(token: "fixture", name: profile.host)
    }
    func status() async throws -> HostStatus {
        return HostStatus(name: profile.host, platform: "fixture", connectionMode: nil, uptimeSeconds: 0, screenWidth: 1, screenHeight: 1, assistantRuntimeAvailable: false)
    }
    func revoke() async throws -> ActionResult {
        await withCheckedContinuation { Self.revokeReply = $0 }
    }
    func files(path: String) async throws -> FileListing { fatalError("unexpected request") }
    func uploadFile(data: Data, path: String) async throws -> ActionResult { fatalError("unexpected request") }
    func downloadFile(path: String) async throws -> Data { fatalError("unexpected request") }
    func deleteFile(path: String) async throws -> ActionResult { fatalError("unexpected request") }
    func createFolder(path: String) async throws -> ActionResult { fatalError("unexpected request") }
    func screen() async throws -> Data { fatalError("unexpected request") }
    func input(action: String, x: Double?, y: Double?, endX: Double?, endY: Double?, text: String?, key: String?) async throws -> ActionResult { fatalError("unexpected request") }
    func assistant(message: String, history: [HistoryItem]) async throws -> AssistantReply { fatalError("unexpected request") }
    func assistantStream(message: String, history: [HistoryItem]) async throws -> URLSession.AsyncBytes { fatalError("unexpected request") }
    func confirmAction(id: String) async throws -> ActionResult { fatalError("unexpected request") }
}

@main struct PairingSessionTests {
    @MainActor static func main() async throws {
        precondition(AppModel.connectionDiagnosis(for: URLError(.cannotConnectToHost)).contains("Tailscale"))
        precondition(AppModel.connectionDiagnosis(for: ClientError.server("未配對或授權失效")).contains("拒絕"))
        precondition(AppModel.connectionDiagnosis(for: URLError(.secureConnectionFailed)).contains("TLS"))
        print("PASS: connection diagnoses distinguish unreachable network, invalid pairing, and TLS trust failures")

        let suite = "MacLink.PairingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        let initialID = model.pairingSessionID
        let fingerprint = String(repeating: "A", count: 64)
        try await model.pair(host: "10.0.0.1", port: 8766, code: "123456", fingerprint: fingerprint)
        precondition(model.isPaired && model.pairingSessionID != initialID)
        let oldID = model.pairingSessionID
        let oldClient = MacLinkClient.clients.last!
        let revoke = Task { @MainActor in
            do { try await model.disconnect(); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        for _ in 0..<1000 {
            if MacLinkClient.revokeReply != nil { break }
            await Task.yield()
        }
        precondition(MacLinkClient.revokeReply != nil, "revoke did not start")
        try await model.pair(host: "10.0.0.2", port: 8766, code: "123456", fingerprint: fingerprint)
        precondition(oldClient.cancelled && model.pairingSessionID != oldID)
        let newID = model.pairingSessionID
        MacLinkClient.revokeReply!.resume(returning: ActionResult(message: "revoked old pairing"))
        MacLinkClient.revokeReply = nil
        let rejectedOldReply = await revoke.value
        precondition(rejectedOldReply)
        precondition(model.isPaired && model.profile?.host == "10.0.0.2")
        precondition(model.pairingSessionID == newID && KeychainStore.token != nil)
        let currentClient = MacLinkClient.clients.last!
        KeychainStore.failDelete = true
        do { try model.forgetLocalPairing(); fatalError("delete must fail") } catch {}
        precondition(model.isPaired && model.pairingSessionID == newID && !currentClient.cancelled)
        KeychainStore.failDelete = false
        try model.forgetLocalPairing()
        precondition(!model.isPaired && model.pairingSessionID != newID)
        precondition(currentClient.cancelled && model.hostStatus == nil && KeychainStore.token == nil)
        precondition(defaults.data(forKey: "maclink.profile.v1") == nil)
        MacLinkClient.delayPair = true
        let pending = Task { @MainActor in
            do {
                try await model.pair(host: "10.0.0.3", port: 8766, code: "123456", fingerprint: fingerprint)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        for _ in 0..<1000 {
            if MacLinkClient.pairReply != nil { break }
            await Task.yield()
        }
        precondition(MacLinkClient.pairReply != nil)
        let pendingClient = MacLinkClient.clients.last!
        try model.forgetLocalPairing()
        MacLinkClient.pairReply!.resume(returning: PairResponse(token: "late-fixture", name: "old reply"))
        MacLinkClient.pairReply = nil
        let rejectedLatePair = await pending.value
        precondition(rejectedLatePair && pendingClient.cancelled)
        precondition(!model.isPaired && KeychainStore.token == nil)
        precondition(defaults.data(forKey: "maclink.profile.v1") == nil)
        print("PASS: late pairing after forget rejected")
        print("PASS: pairing identity, old request cancellation, late revoke isolation, failed credential deletion preservation, local forget cleanup")
    }
}
