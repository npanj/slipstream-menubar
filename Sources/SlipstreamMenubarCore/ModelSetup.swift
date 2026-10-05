import Darwin
import Foundation

/// Slipstream's model store, shared with its command line: `slipstream pull <owner/repo>`
/// and `slipstream serve --model <owner/repo>` keep each model in `<root>/<owner>/<repo>`,
/// so a model is downloaded once whichever of them gets it first.
public enum ModelStore {
    /// What a GGUF download keeps next to the shards; `"downloaded": true` once it finished.
    public static let markerName = ".slipstream-gguf.json"

    /// `SLIPSTREAM_MODELS`, as Slipstream reads it, else `~/.slipstream/models`.
    public static var root: URL {
        if let value = getenv("SLIPSTREAM_MODELS").map({ String(cString: $0) }), !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".slipstream/models")
    }

    public static func folder(for repository: String) -> URL {
        root.appendingPathComponent(repository)
    }

    /// Whether `slipstream pull` finished this model: a GGUF download says so in its marker
    /// (or was already prepared), a package is a link to its verified Hub snapshot.
    public static func isDownloaded(_ repository: String, fileManager: FileManager = .default) -> Bool {
        let folder = folder(for: repository)
        if let data = fileManager.contents(atPath: folder.appendingPathComponent(markerName).path),
           let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           marker["downloaded"] as? Bool == true { return true }
        return fileManager.fileExists(atPath: folder.appendingPathComponent("prepared/manifest.json").path)
            || fileManager.fileExists(atPath: folder.appendingPathComponent("manifest.json").path)
    }

    /// Where `huggingface_hub` caches a repository: a package's files land there, and its
    /// store folder only links to them.
    public static func hubCacheFolder(for repository: String) -> URL {
        let environment = ProcessInfo.processInfo.environment
        let hub: URL
        if let cache = environment["HF_HUB_CACHE"], !cache.isEmpty {
            hub = URL(fileURLWithPath: (cache as NSString).expandingTildeInPath)
        } else if let home = environment["HF_HOME"], !home.isEmpty {
            hub = URL(fileURLWithPath: (home as NSString).expandingTildeInPath).appendingPathComponent("hub")
        } else {
            hub = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        }
        return hub.appendingPathComponent("models--" + repository.replacingOccurrences(of: "/", with: "--"))
    }
}

/// A model the app offers. "Download Model…" gets it with `slipstream pull <repository>`
/// into the model store, and Settings then serves it by its Hub id.
public struct ModelSpec: Codable, Equatable, Sendable {
    /// What the download is, which decides how the server gets it ready.
    public enum Kind: String, Codable, Sendable {
        /// GGUF shards of Qwen3.8-Flash-Next (`qwen4exp`): converted into `prepared/` on first start.
        case gguf
        /// A ready-to-run Slipstream package (`manifest.json` and packed weights).
        case package
    }

    /// A single file from another repository, downloaded into the model's folder.
    public struct ExtraFile: Codable, Equatable, Sendable {
        public var repository: String
        public var path: String

        public var treeURL: URL? {
            URL(string: "https://huggingface.co/api/models/\(repository)/tree/main?recursive=true")
        }
    }

    public var repository: String
    public var title: String
    public var extraFiles: [ExtraFile] = []
    public var kind: Kind = .gguf
    /// Below this the server is not expected to start.
    public var minimumMemoryGiB: Int = 64
    /// What the model's authors recommend.
    public var recommendedMemoryGiB: Int = 64

    /// The MTP draft head (speculative decoding) is only in the base model's repository;
    /// `slipstream pull` fetches it into the model's `MTP/` folder for a repository without
    /// one. Listed here for the download's size.
    public static let mtpDraftHead = ExtraFile(repository: "nitinpanj/qwen38-flash-next-v3",
                                               path: "MTP/mtp-shared-Q4_K_M.gguf")

    /// The setup's default: Swift V3, which drafts with the base model's MTP head.
    public static var swiftQwen38FlashNext: ModelSpec { ModelManifest.builtIn.entry(id: "swift-v3")!.spec! }

    /// The README's alternative: the dense base model, which ships its MTP head.
    public static var qwen38FlashNext: ModelSpec { ModelManifest.builtIn.entry(id: "qwen38-v3")!.spec! }

    /// The models the app offers, from the model manifest. The Slipstream v2 engine loads only
    /// Qwen3.8-Flash-Next (`splash-packed-q4-qwen4exp`, runtime/model/ModelDescriptor.mm): the
    /// incoai/Qwen3.8-27B-Splash and Qwen3.6-35B-A3B-Splash packages that its launcher still
    /// lists (inherited from Splash 1.0) fail with "unsupported weight format".
    public static var catalog: [ModelSpec] { ModelManifest.bundled.catalog }

    /// The catalog or custom model a configured model names: its Hub id, or its folder.
    public static func matching(model: String, in models: [ModelSpec]) -> ModelSpec? {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        let path = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
        return models.first { $0.repository == trimmed || $0.folderURL.standardizedFileURL.path == path }
    }

    public init(repository: String, title: String, extraFiles: [ExtraFile] = [],
                kind: Kind = .gguf, minimumMemoryGiB: Int = 64, recommendedMemoryGiB: Int = 64) {
        self.repository = repository
        self.title = title
        self.extraFiles = extraFiles
        self.kind = kind
        self.minimumMemoryGiB = minimumMemoryGiB
        self.recommendedMemoryGiB = recommendedMemoryGiB
    }

    /// "Qwen3.8-27B (17.4 GB download, 36 GB Mac, 48 GB recommended)" style summary of needs.
    public var memoryNote: String {
        minimumMemoryGiB == recommendedMemoryGiB
            ? "\(minimumMemoryGiB) GB Mac"
            : "\(minimumMemoryGiB) GB Mac, \(recommendedMemoryGiB) GB recommended"
    }

    /// `SLIPSTREAM_MENUBAR_MODEL_REPO` swaps in a small repository to test the download flow
    /// without fetching 100 GB (`SLIPSTREAM_MODELS` keeps it out of the real store).
    public static var `default`: ModelSpec {
        let environment = ProcessInfo.processInfo.environment
        guard let repository = environment["SLIPSTREAM_MENUBAR_MODEL_REPO"], !repository.isEmpty else {
            return ModelManifest.bundled.defaultEntry?.spec ?? .swiftQwen38FlashNext
        }
        // SLIPSTREAM_MENUBAR_MODEL_EXTRA=owner/repo:path adds one extra file, like the MTP head.
        let extra = environment["SLIPSTREAM_MENUBAR_MODEL_EXTRA"]?.split(separator: ":", maxSplits: 1)
            .map(String.init)
        return ModelSpec(repository: repository,
                         title: repository,
                         extraFiles: extra?.count == 2 ? [ExtraFile(repository: extra![0], path: extra![1])] : [])
    }

    /// Where Slipstream keeps it. Not stored: settings saved by older versions name
    /// `~/models/<name>` folders, which the command line does not look in.
    public var folderURL: URL {
        if repository.hasPrefix("/") || repository.hasPrefix("~") || repository.hasPrefix(".") {
            return URL(fileURLWithPath: (repository as NSString).expandingTildeInPath)
        }
        return ModelStore.folder(for: repository)
    }
    /// `folderURL` for display, with `~`.
    public var folder: String { (folderURL.path as NSString).abbreviatingWithTildeInPath }
    public var treeURL: URL? {
        URL(string: "https://huggingface.co/api/models/\(repository)/tree/main?recursive=true")
    }

    /// The size of one file in a Hub `tree` listing.
    public static func size(of path: String, inTree data: Data) -> Int64? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return entries.first { $0["path"] as? String == path }
            .flatMap { ($0["size"] as? NSNumber)?.int64Value }
    }

    /// Sum of the file sizes in a Hub `tree` listing: what the download will total.
    public static func totalSize(ofTree data: Data) -> Int64? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let sizes = entries.compactMap { entry -> Int64? in
            guard entry["type"] as? String == "file" else { return nil }
            return (entry["size"] as? NSNumber)?.int64Value
        }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

/// Whether a configured model can be served without downloading it first.
public enum ModelPresence {
    /// True for a Hub id that `slipstream pull` finished in the model store, or a local
    /// folder holding GGUF shards or a prepared package.
    public static func isAvailable(_ model: String, fileManager: FileManager = .default) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let path = (trimmed as NSString).expandingTildeInPath
        let local = trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".")
        guard local else { return trimmed.contains("/") && ModelStore.isDownloaded(trimmed, fileManager: fileManager) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        if fileManager.fileExists(atPath: path + "/manifest.json")
            || fileManager.fileExists(atPath: path + "/prepared/manifest.json") { return true }
        let files = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
        return files.contains { $0.hasSuffix(".gguf") }
    }

    /// Bytes a folder takes on disk, including hf's `.incomplete` partial downloads.
    public static func allocatedSize(of folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

/// What this Mac brings to a 100 GB model.
public enum MachineCheck {
    public static let requiredMemoryGiB = 64

    public static var memoryGiB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    public static var hasEnoughMemory: Bool { memoryGiB >= requiredMemoryGiB }

    /// Only a 64 GB Mac needs the GPU wired limit raised: larger ones have room anyway.
    public static func needsGPULimitRaise(memoryGiB: Int = memoryGiB) -> Bool {
        memoryGiB >= requiredMemoryGiB && memoryGiB < 96
    }

    public static func freeDiskBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// `iogpu.wired_limit_mb`: how much memory the GPU may wire. macOS keeps it at about
/// 48 GiB on a 64 GB Mac; Slipstream wants 58 GiB (59392). It resets at every boot.
public enum GPUMemoryLimit {
    public static let recommendedMB = 59392
    public static let sysctlName = "iogpu.wired_limit_mb"

    /// The current value, or nil where the sysctl does not exist. 0 means the default.
    public static func currentMB() -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(sysctlName, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// The shell command that sets it; it needs administrator rights.
    public static func command(megabytes: Int) -> String {
        "/usr/sbin/sysctl \(sysctlName)=\(megabytes)"
    }
}

/// Download speed and time left from (time, bytes) samples over a sliding window.
public struct TransferEstimator: Sendable {
    public let window: TimeInterval
    private var samples: [(time: Date, bytes: Int64)] = []

    public init(window: TimeInterval = 20) {
        self.window = window
    }

    public mutating func add(bytes: Int64, at time: Date) {
        samples.append((time, bytes))
        samples.removeAll { time.timeIntervalSince($0.time) > window }
    }

    /// Bytes per second over the window; nil until two samples span a second.
    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let seconds = last.time.timeIntervalSince(first.time)
        guard seconds >= 1, last.bytes >= first.bytes else { return nil }
        return Double(last.bytes - first.bytes) / seconds
    }

    public func secondsRemaining(total: Int64) -> TimeInterval? {
        guard let rate = bytesPerSecond, rate > 0, let last = samples.last else { return nil }
        return Double(max(0, total - last.bytes)) / rate
    }

    /// "about 1 h 12 min", "about 4 min", "less than a minute".
    public static func describe(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "less than a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min" }
        return "about \(minutes / 60) h \(minutes % 60) min"
    }
}

/// Whether a model download fits on the disk.
public enum DiskCheck {
    /// Free space that must remain once the download is complete.
    public static let reserveBytes: Int64 = 10_000_000_000

    public enum Verdict: Equatable, Sendable {
        case ok
        /// The download would leave less than the reserve: it must not start.
        /// `shortBy` is how much more space it needs.
        case insufficient(shortBy: Int64)
        /// The download fits, but preparing it on the first start would not. A warning,
        /// not a block.
        case noRoomToPrepare(shortBy: Int64)
    }

    /// What the first start writes besides the download.
    public enum Preparation: Equatable, Sendable {
        /// A package: served as downloaded.
        case none
        /// GGUF files converted while they are used up (Slipstream with `--keep-gguf`, not
        /// passed): the package is a little larger than the files, and a few parts are
        /// written before their source is freed.
        case inPlace
        /// GGUF files kept: the prepared copy is about the size of the download again.
        case alongside

        public func bytes(total: Int64) -> Int64 {
            switch self {
            case .none: return 0
            // Slipstream's own estimate: a twentieth, plus up to 8 workers' 1.5 GiB layers.
            case .inPlace: return total / 20 + 12 * 1_073_741_824
            case .alongside: return total
            }
        }
    }

    /// `downloaded` is what an earlier, stopped download already left on disk.
    public static func evaluate(total: Int64, downloaded: Int64, free: Int64,
                                preparation: Preparation = .alongside) -> Verdict {
        let remaining = max(0, total - downloaded)
        let afterDownload = free - remaining
        if afterDownload < reserveBytes { return .insufficient(shortBy: reserveBytes - afterDownload) }
        let afterPreparing = afterDownload - preparation.bytes(total: total)
        if afterPreparing < reserveBytes { return .noRoomToPrepare(shortBy: reserveBytes - afterPreparing) }
        return .ok
    }
}

/// Discovers local model directories in ~/models and ~/.slipstream/models.
public enum LocalModelScanner {
    public static func scan(fileManager: FileManager = .default) -> [ModelSpec] {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("models"),
            ModelStore.root,
        ]
        var specs: [ModelSpec] = []
        var seenPaths = Set<String>()

        for dir in candidates {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: dir.path) else { continue }
            for entry in contents {
                guard !entry.hasPrefix(".") else { continue }
                let modelDir = dir.appendingPathComponent(entry)
                let standardized = modelDir.standardizedFileURL.path
                guard !seenPaths.contains(standardized) else { continue }

                if ModelPresence.isAvailable(modelDir.path, fileManager: fileManager) {
                    seenPaths.insert(standardized)
                    let title = prettyTitle(for: entry, at: modelDir, fileManager: fileManager)
                    let isPackage = fileManager.fileExists(atPath: modelDir.appendingPathComponent("manifest.json").path)
                        || fileManager.fileExists(atPath: modelDir.appendingPathComponent("prepared/manifest.json").path)
                    specs.append(ModelSpec(
                        repository: modelDir.path,
                        title: title,
                        extraFiles: [],
                        kind: isPackage ? .package : .gguf,
                        minimumMemoryGiB: 64,
                        recommendedMemoryGiB: 64
                    ))
                }
            }
        }
        return specs
    }

    private static func prettyTitle(for folderName: String, at url: URL, fileManager: FileManager) -> String {
        switch folderName {
        case "swift-qwen38-flash-next-v3":
            return "Swift-Qwen3.8-Flash-Next V3 (Local)"
        case "qwen38-flash-next-v3":
            return "Qwen3.8-Flash-Next V3 (Local)"
        case "swift-qwen38-27b-splash-hq":
            return "Swift-Qwen3.8-27B-Splash-HQ (Local)"
        default:
            return folderName
        }
    }
}

