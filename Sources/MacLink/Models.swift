import Foundation

struct HostStatus: Decodable {
    let name: String
    let platform: String
    let connectionMode: String?
    let uptimeSeconds: Int
    let screenWidth: Int
    let screenHeight: Int
    let assistantRuntimeAvailable: Bool?

    enum CodingKeys: String, CodingKey {
        case name, platform
        case connectionMode = "connection_mode"
        case uptimeSeconds = "uptime_seconds"
        case screenWidth = "screen_width"
        case screenHeight = "screen_height"
        case assistantRuntimeAvailable = "assistant_runtime_available"
    }
}

struct PairResponse: Decodable {
    let token: String
    let name: String
}

struct FileListing: Decodable {
    let path: String
    let entries: [RemoteFile]
}

struct RemoteFile: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Double

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name, path, size, modified
        case isDirectory = "is_directory"
    }
}

struct AssistantReply: Decodable {
    let reply: String
    let actionID: String?
    let actionSummary: String?

    enum CodingKeys: String, CodingKey {
        case reply
        case actionID = "action_id"
        case actionSummary = "action_summary"
    }
}

struct ActionResult: Decodable {
    let message: String
}

struct PairingProfile: Codable {
    var host: String
    var port: Int
    var certificateFingerprint: String

    var baseURL: URL? {
        guard Self.isPrivateIPv4(host), (1...65535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        return components.url
    }

    // Match the private IPv4 ranges declared in Info.plist. Reject alternate
    // IP spellings and URL syntax before any pairing code or token is sent.
    static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var bytes: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(part), (0...255).contains(value), String(value) == part else { return false }
            bytes.append(value)
        }
        return bytes[0] == 10
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 100 && (64...127).contains(bytes[1]))
    }
}

struct ChatMessage: Identifiable {
    enum Role: Equatable {
        case user, assistant
    }

    let id = UUID()
    let role: Role
    var text: String
}

struct AssistantStreamEvent: Decodable {
    let type: String
    let text: String?
    let actionID: String?
    let actionSummary: String?

    enum CodingKeys: String, CodingKey {
        case type, text
        case actionID = "action_id"
        case actionSummary = "action_summary"
    }
}
