import Foundation

/// A release of the app on GitHub, as the update check reads it.
public struct AppRelease: Equatable, Sendable {
    public var tag: String
    /// The tag without its leading "v".
    public var version: String
    public var page: URL?
    /// The "## Changes" section of the release notes, one entry per line.
    public var changes: [String]
    public var assets: [String: URL]
    public var sizes: [String: Int64]

    /// `Slipstream-Menubar.app.<version>.zip`, as the release workflow names it.
    public var zipName: String { "Slipstream-Menubar.app.\(version).zip" }
    public var checksumsName: String { "SHA256SUMS.\(version).txt" }

    /// From the GitHub API's release object (`/releases/latest`).
    public init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, !tag.isEmpty else { return nil }
        self.tag = tag
        version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        page = (object["html_url"] as? String).flatMap(URL.init(string:))
        changes = Self.changes(fromNotes: object["body"] as? String ?? "")
        var assets: [String: URL] = [:]
        var sizes: [String: Int64] = [:]
        for asset in object["assets"] as? [[String: Any]] ?? [] {
            guard let name = asset["name"] as? String,
                  let link = asset["browser_download_url"] as? String, let url = URL(string: link) else { continue }
            assets[name] = url
            sizes[name] = (asset["size"] as? NSNumber)?.int64Value
        }
        self.assets = assets
        self.sizes = sizes
    }

    /// The bullet lines under a "## Changes" heading, up to the next heading.
    public static func changes(fromNotes notes: String) -> [String] {
        var lines: [String] = []
        var inside = false
        for raw in notes.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if inside { break }
                inside = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased() == "changes"
                continue
            }
            if inside, line.hasPrefix("- ") || line.hasPrefix("* ") {
                lines.append(String(line.dropFirst(2)))
            }
        }
        return lines
    }
}

public enum AppUpdate {
    public static let repository = "npanj/slipstream-menubar"
    /// An automatic check runs at most this often.
    public static let checkInterval: TimeInterval = 20 * 60 * 60
    /// After a failed automatic check (offline, say), the next try waits this long.
    public static let retryInterval: TimeInterval = 60 * 60

    /// Whether `latest` is newer than the running version. A build without a real
    /// version (0.0.0, an unbundled run) never offers an update.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard isVersion(latest), isVersion(current), current != "0.0.0" else { return false }
        return ReleasePackages.isOlder(current, latest)
    }

    static func isVersion(_ text: String) -> Bool {
        !text.isEmpty && text.first!.isNumber && text.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Whether an automatic check is due: a day after the last one that worked, and an
    /// hour after the last attempt, so being offline does not mean a request per poll.
    public static func isCheckDue(lastCheck: Date?, lastAttempt: Date?, now: Date = Date()) -> Bool {
        func elapsed(_ date: Date?, _ interval: TimeInterval) -> Bool {
            guard let date else { return true }
            return now.timeIntervalSince(date) >= interval || now < date  // or the clock moved back
        }
        return elapsed(lastCheck, checkInterval) && elapsed(lastAttempt, retryInterval)
    }

    /// The checksum for `name` in a `shasum -a 256` listing.
    public static func checksum(for name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2 else { continue }
            let file = fields[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if file == name { return fields[0].lowercased() }
        }
        return nil
    }

    /// `text` as a single-quoted shell word.
    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The shell commands that put `staged` in place of `app`, keeping the old bundle
    /// at `backup` until the new one is there, and put the old one back if that fails.
    public static func swapCommand(app: URL, staged: URL, backup: URL) -> String {
        let (a, s, b) = (shellQuoted(app.path), shellQuoted(staged.path), shellQuoted(backup.path))
        return "mv \(a) \(b) && { mv \(s) \(a) || { mv \(b) \(a); exit 1; }; }"
    }

    /// The detached helper: waits for the app (`pid`) to quit, deletes the old bundle
    /// and opens the new one.
    public static func relaunchScript(pid: Int32, app: URL, backup: URL) -> String {
        "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; "
            + "rm -rf \(shellQuoted(backup.path)); open \(shellQuoted(app.path))"
    }
}
