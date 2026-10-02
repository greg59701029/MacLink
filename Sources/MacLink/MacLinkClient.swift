import CryptoKit
import Foundation
import Security

struct MacLinkClient {
    let profile: PairingProfile
    let token: String?
    private let session: URLSession

    init(profile: PairingProfile, token: String?) {
        self.profile = profile
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        self.session = URLSession(configuration: configuration, delegate: CertificatePinDelegate(fingerprint: profile.certificateFingerprint), delegateQueue: nil)
    }

    func cancelRequests() {
        session.invalidateAndCancel()
    }

    func pair(code: String) async throws -> PairResponse {
        try await send("/api/pair", method: "POST", body: PairRequest(code: code), authenticated: false)
    }

    func status() async throws -> HostStatus {
        try await send("/api/status", method: "GET", authenticated: true)
    }

    func codexTasks(cursor: String? = nil) async throws -> CodexTaskList {
        try await send("/api/codex/tasks" + (cursor.map { "?cursor=\($0.urlQueryValue)" } ?? ""), method: "GET", authenticated: true)
    }
    func codexTask(id: String) async throws -> CodexTaskDetail {
        try await send("/api/codex/task?id=\(id.urlQueryValue)", method: "GET", authenticated: true)
    }
    func codexCalls(thread: String) async throws -> CodexCallList {
        try await send("/api/codex/calls?thread=\(thread.urlQueryValue)", method: "GET", authenticated: true)
    }
    func codexCallTranscript(id: String, thread: String) async throws -> CodexCallTranscript {
        try await send("/api/codex/call?id=\(id.urlQueryValue)&thread=\(thread.urlQueryValue)", method: "GET", authenticated: true)
    }
    func codexModels() async throws -> CodexModelList {
        try await send("/api/codex/models", method: "GET", authenticated: true)
    }
    func codexSend(id: String, message: String, model: String = "") async throws -> ActionResult {
        var body = ["id": id, "message": message]
        if !model.isEmpty { body["model"] = model }
        return try await send("/api/codex/send", method: "POST", body: body, authenticated: true)
    }
    func codexApproval(id: String, approval: String, decision: String) async throws -> ActionResult {
        try await send("/api/codex/approval", method: "POST", body: ["id": id, "approval": approval, "decision": decision], authenticated: true)
    }
    func codexCall(id: String) async throws -> ActionResult {
        try await send("/api/codex/call", method: "POST", body: ["id": id], authenticated: true)
    }
    func codexStop(id: String) async throws -> ActionResult {
        try await send("/api/codex/stop", method: "POST", body: ["id": id], authenticated: true)
    }

    func files(path: String) async throws -> FileListing {
        try await send("/api/files?path=\(path.urlQueryValue)", method: "GET", authenticated: true)
    }

    func assistant(message: String, history: [HistoryItem]) async throws -> AssistantReply {
        try await send("/api/assistant", method: "POST", body: AssistantRequest(message: message, history: history), authenticated: true)
    }

    func assistantStream(message: String, history: [HistoryItem]) async throws -> URLSession.AsyncBytes {
        guard let url = endpoint("/api/assistant/stream") else { throw ClientError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AssistantRequest(message: message, history: history))
        try addAuthorization(to: &request)
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count >= 4096 { break }
            }
            try Self.check(response, data: errorBody)
        }
        try Self.check(response)
        return bytes
    }

    func confirmAction(id: String) async throws -> ActionResult {
        try await send("/api/assistant/confirm", method: "POST", body: ConfirmActionRequest(actionID: id), authenticated: true)
    }

    func revoke() async throws -> ActionResult {
        try await send("/api/revoke", method: "POST", body: Optional<EmptyRequest>.none, authenticated: true)
    }

    func input(action: String, x: Double? = nil, y: Double? = nil, endX: Double? = nil, endY: Double? = nil, text: String? = nil, key: String? = nil) async throws -> ActionResult {
        try await send("/api/input", method: "POST", body: InputRequest(action: action, x: x, y: y, endX: endX, endY: endY, text: text, key: key), authenticated: true)
    }

    func deleteFile(path: String) async throws -> ActionResult {
        try await send("/api/files?path=\(path.urlQueryValue)", method: "DELETE", body: DeleteRequest(confirm: true), authenticated: true)
    }

    func createFolder(path: String) async throws -> ActionResult {
        try await send("/api/folders", method: "POST", body: CreateFolderRequest(path: path), authenticated: true)
    }

    func uploadFile(data: Data, path: String) async throws -> ActionResult {
        guard let url = endpoint("/api/files?path=\(path.urlQueryValue)") else { throw ClientError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        try addAuthorization(to: &request)
        let (reply, response) = try await session.upload(for: request, from: data)
        try Self.check(response, data: reply)
        return ActionResult(message: "檔案已傳到 Mac。")
    }

    func downloadFile(path: String) async throws -> Data {
        guard let url = endpoint("/api/file?path=\(path.urlQueryValue)") else { throw ClientError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try addAuthorization(to: &request)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        return data
    }

    func screen() async throws -> Data {
        guard let url = endpoint("/api/screen") else { throw ClientError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try addAuthorization(to: &request)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        return data
    }

    private func send<T: Decodable>(_ path: String, method: String, authenticated: Bool) async throws -> T {
        try await send(path, method: method, body: Optional<EmptyRequest>.none, authenticated: authenticated)
    }

    private func send<B: Encodable, T: Decodable>(_ path: String, method: String, body: B?, authenticated: Bool) async throws -> T {
        guard let url = endpoint(path) else { throw ClientError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated { try addAuthorization(to: &request) }
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func addAuthorization(to request: inout URLRequest) throws {
        guard let token, !token.isEmpty else { throw ClientError.notPaired }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func endpoint(_ path: String) -> URL? {
        guard let baseURL = profile.baseURL,
              var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let split = path.split(separator: "?", maxSplits: 1).map(String.init)
        parts.path = split.first ?? path
        if split.count == 2 {
            parts.percentEncodedQuery = split[1]
        }
        return parts.url
    }

    private static func check(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let data, let serverError = try? JSONDecoder().decode(ServerError.self, from: data) {
                throw ClientError.server(serverError.error)
            }
            throw ClientError.server("Mac 回傳錯誤（\(http.statusCode)）。")
        }
    }
}

private final class CertificatePinDelegate: NSObject, URLSessionTaskDelegate {
    let fingerprint: String

    init(fingerprint: String) {
        self.fingerprint = fingerprint
        super.init()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Companion API routes never redirect. Do not forward credentials or
        // pairing bodies to another URL, including an unencrypted endpoint.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        evaluate(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        evaluate(challenge, completionHandler: completionHandler)
    }

    private func evaluate(_ challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let certificateData = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: certificateData).map { String(format: "%02X", $0) }.joined()
        guard digest.caseInsensitiveCompare(fingerprint.filter(\.isHexDigit)) == .orderedSame else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let policy = SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private struct EmptyRequest: Encodable {}
private struct PairRequest: Encodable { let code: String; enum CodingKeys: String, CodingKey { case code = "pair_code" } }
private struct AssistantRequest: Encodable { let message: String; let history: [HistoryItem] }
private struct ConfirmActionRequest: Encodable { let actionID: String; enum CodingKeys: String, CodingKey { case actionID = "action_id" } }
private struct InputRequest: Encodable { let action: String; let x: Double?; let y: Double?; let endX: Double?; let endY: Double?; let text: String?; let key: String? }
private struct DeleteRequest: Encodable { let confirm: Bool }
private struct CreateFolderRequest: Encodable { let path: String }
private struct ServerError: Decodable { let error: String }

struct HistoryItem: Encodable {
    let role: String
    let content: String
}

enum ClientError: LocalizedError {
    case invalidAddress, invalidResponse, notPaired
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Mac 位址格式不正確。"
        case .invalidResponse: "Mac 回傳了無法辨識的內容。"
        case .notPaired: "尚未配對這台 Mac。"
        case .server(let message): message
        }
    }
}

private extension String {
    var urlQueryValue: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))) ?? self
    }
}
