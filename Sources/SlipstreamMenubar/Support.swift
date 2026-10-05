import Foundation
import Security
import SlipstreamMenubarCore
import SwiftUI

/// The server's API key, kept in the login Keychain rather than the config file.
enum APIKeyStore {
    private static let service = "Slipstream"
    private static let account = "server-api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ key: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    /// 32 random bytes, hex encoded.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum Format {
    static func tokens(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fK", value / 1_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return String(format: "%.0f", value)
    }

    /// Context sizes the way the server prints them: 262144 is "256K".
    static func contextTokens(_ value: Int) -> String {
        value % 1024 == 0 ? "\(value / 1024)K" : tokens(Double(value))
    }

    static func rate(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: value >= 100 ? "%.0f tok/s" : "%.1f tok/s", value)
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func gigabytes(_ value: Double) -> String {
        String(format: "%.1f GB", value / 1_073_741_824)
    }

    /// Short form for chart axes: "47G".
    static func axisGigabytes(_ value: Double) -> String {
        String(format: "%.0fG", value / 1_073_741_824)
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value >= 1000 ? String(format: "%.1f s", value / 1000) : String(format: "%.0f ms", value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.0f%%", value * 100)
    }
}

extension ServerStatus {
    var color: NSColor {
        switch self {
        case .running: return .systemGreen
        case .starting, .preparing, .loading, .stopping: return .systemOrange
        case .unresponsive, .failed: return .systemRed
        case .stopped: return .secondaryLabelColor
        }
    }
}

/// Reads the engine build id the About box shows.
enum EngineBuild {
    static func identifier(repo: URL) -> String? {
        let url = repo.appendingPathComponent("build/engine/build-identity.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let build = object["build_id"] as? String else { return nil }
        return String(build.prefix(16))
    }
}
