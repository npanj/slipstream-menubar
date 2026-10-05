import Foundation

/// Something "Uninstall and Cleanup" can remove. Only these known locations are ever
/// deleted; model folders only when the app knows them and they hold a model.
public struct CleanupItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case releases       // ~/.local/share/slipstream
        case commandLink    // ~/.local/bin/slipstream, when it points into the releases
        case slipstreamData // ~/Library/Application Support/Slipstream-v2
        case appSettings    // ~/Library/Application Support/Slipstream
        case logs           // ~/Library/Logs/Slipstream
        case model(String)  // a model folder, by its title
        case app            // the app bundle (moved to the Trash)
    }

    public let kind: Kind
    public let url: URL
    public var id: String { url.path }

    public var title: String {
        switch kind {
        case .releases: return "Slipstream releases"
        case .commandLink: return "The slipstream command"
        case .slipstreamData: return "Slipstream data and caches"
        case .appSettings: return "Slipstream settings"
        case .logs: return "Server logs"
        case .model(let title): return title
        case .app: return "Slipstream app (to the Trash)"
        }
    }

    public var isModel: Bool {
        if case .model = kind { return true }
        return false
    }
}

public enum Cleanup {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var releasesFolder: URL { home.appendingPathComponent(".local/share/slipstream") }
    public static var commandLink: URL { InstallationLocator.defaultBinDirectory.appendingPathComponent("slipstream") }
    public static var appSettingsFolder: URL { home.appendingPathComponent("Library/Application Support/Slipstream") }
    public static var logsFolder: URL { home.appendingPathComponent("Library/Logs/Slipstream") }

    /// Model folders that exist and hold a model: the catalog's, added ones', and the
    /// configured one when it is a local folder.
    public static func modelItems(models: [ModelSpec], configuredModel: String,
                                  fileManager: FileManager = .default) -> [CleanupItem] {
        var items: [CleanupItem] = []
        var seen = Set<String>()
        func add(_ path: String, title: String) {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard ModelPresence.isAvailable(url.path, fileManager: fileManager),
                  url.path != home.path, seen.insert(url.path).inserted else { return }
            items.append(CleanupItem(kind: .model(title), url: url))
        }
        models.forEach { add($0.folder, title: $0.title) }
        let configured = configuredModel.trimmingCharacters(in: .whitespaces)
        if configured.hasPrefix("/") || configured.hasPrefix("~") {
            add(configured, title: (configured as NSString).lastPathComponent)
        }
        return items
    }

    /// Everything a full uninstall removes, existing items only.
    public static func allItems(models: [ModelSpec], configuredModel: String, appBundle: URL?,
                                fileManager: FileManager = .default) -> [CleanupItem] {
        var items: [CleanupItem] = []
        func add(_ kind: CleanupItem.Kind, _ url: URL) {
            if fileManager.fileExists(atPath: url.path) { items.append(CleanupItem(kind: kind, url: url)) }
        }
        add(.releases, releasesFolder)
        if linkPointsIntoReleases(fileManager: fileManager) {
            items.append(CleanupItem(kind: .commandLink, url: commandLink))
        }
        add(.slipstreamData, SlipstreamInstallation.releaseDataDirectory)
        add(.appSettings, appSettingsFolder)
        add(.logs, logsFolder)
        items += modelItems(models: models, configuredModel: configuredModel, fileManager: fileManager)
        if let appBundle, appBundle.pathExtension == "app" { add(.app, appBundle) }
        return items
    }

    /// Only a link the installer made is removed, never a slipstream installed otherwise.
    public static func linkPointsIntoReleases(fileManager: FileManager = .default) -> Bool {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: commandLink.path) else { return false }
        return URL(fileURLWithPath: target).standardizedFileURL.path.hasPrefix(releasesFolder.standardizedFileURL.path + "/")
    }

    /// Deletes one item (the app bundle goes through the caller, to the Trash).
    public static func remove(_ item: CleanupItem, fileManager: FileManager = .default) throws {
        switch item.kind {
        case .app:
            return
        case .commandLink:
            guard linkPointsIntoReleases(fileManager: fileManager) else { return }
            try fileManager.removeItem(at: item.url)
        default:
            if fileManager.fileExists(atPath: item.url.path) { try fileManager.removeItem(at: item.url) }
        }
    }
}
