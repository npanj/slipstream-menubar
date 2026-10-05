import Foundation

/// The settings the app starts `slipstream serve` with.
///
/// The API key is not part of this file: it lives in the Keychain and reaches the
/// server through its environment, never its command line.
public struct ServerConfig: Codable, Equatable, Sendable {
    /// Run a source checkout instead of the installed release.
    public var useCheckout: Bool
    /// The Slipstream source checkout that holds the `slipstream` launcher, used when
    /// `useCheckout` is on.
    public var repoPath: String
    /// GitHub `owner/repo` that "Install Slipstream…" downloads releases from.
    public var releaseRepository: String
    /// A local model directory (GGUF shards or a prepared package) or a Hub repo id.
    public var model: String
    public var port: Int
    /// e.g. "100K"; empty means the server's automatic choice.
    public var maxContext: String
    /// e.g. "48G"; empty means the server's automatic choice.
    public var maxMemory: String
    public var allowedHosts: [String]
    public var noWebUI: Bool
    /// Listen on all interfaces (`--host 0.0.0.0`) instead of 127.0.0.1 only.
    public var listenOnNetwork: Bool
    /// Start the server when the app launches if it is not already running.
    public var startServerOnLaunch: Bool
    /// Look for a newer release of this app about once a day, and offer it.
    public var checkForAppUpdates: Bool
    /// On a 64 GB Mac, set `iogpu.wired_limit_mb` to `gpuWiredLimitMB` before starting
    /// the server (asks for an administrator password; the value resets at boot).
    public var raiseGPULimit: Bool
    public var gpuWiredLimitMB: Int
    /// Models added with "New Model…", offered next to the catalog.
    public var customModels: [ModelSpec]
    /// Keep a downloaded GGUF model's files once it is prepared (`--keep-gguf`). Off, the
    /// first start uses them up while converting, so it needs little more disk than the model.
    public var keepGGUFFiles: Bool
    /// A Slipstream release outside `~/.local`, chosen in setup: its `bin/slipstream`.
    /// Searched before `~/.local/bin` and PATH.
    public var slipstreamPath: String
    /// Setup ran to the end (or was not needed): it no longer opens at launch.
    public var setupCompleted: Bool

    public static let defaultReleaseRepository = "npanj/slipstream"

    public init(
        useCheckout: Bool = false,
        repoPath: String = ServerConfig.defaultRepoPath(),
        releaseRepository: String = ServerConfig.defaultReleaseRepository,
        model: String = "",
        port: Int = 8090,
        maxContext: String = "",
        maxMemory: String = "",
        allowedHosts: [String] = [],
        noWebUI: Bool = false,
        listenOnNetwork: Bool = false,
        startServerOnLaunch: Bool = false,
        checkForAppUpdates: Bool = true,
        raiseGPULimit: Bool = true,
        gpuWiredLimitMB: Int = GPUMemoryLimit.recommendedMB,
        customModels: [ModelSpec] = [],
        keepGGUFFiles: Bool = false,
        slipstreamPath: String = "",
        setupCompleted: Bool = false
    ) {
        self.useCheckout = useCheckout
        self.repoPath = repoPath
        self.releaseRepository = releaseRepository
        self.model = model
        self.port = port
        self.maxContext = maxContext
        self.maxMemory = maxMemory
        self.allowedHosts = allowedHosts
        self.noWebUI = noWebUI
        self.listenOnNetwork = listenOnNetwork
        self.startServerOnLaunch = startServerOnLaunch
        self.checkForAppUpdates = checkForAppUpdates
        self.raiseGPULimit = raiseGPULimit
        self.gpuWiredLimitMB = gpuWiredLimitMB
        self.customModels = customModels
        self.keepGGUFFiles = keepGGUFFiles
        self.slipstreamPath = slipstreamPath
        self.setupCompleted = setupCompleted
    }

    /// Settings saved by an older version lack newer keys; those take their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerConfig()
        useCheckout = try container.decodeIfPresent(Bool.self, forKey: .useCheckout) ?? defaults.useCheckout
        repoPath = try container.decodeIfPresent(String.self, forKey: .repoPath) ?? defaults.repoPath
        releaseRepository = try container.decodeIfPresent(String.self, forKey: .releaseRepository)
            ?? defaults.releaseRepository
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        maxContext = try container.decodeIfPresent(String.self, forKey: .maxContext) ?? defaults.maxContext
        maxMemory = try container.decodeIfPresent(String.self, forKey: .maxMemory) ?? defaults.maxMemory
        allowedHosts = try container.decodeIfPresent([String].self, forKey: .allowedHosts) ?? defaults.allowedHosts
        noWebUI = try container.decodeIfPresent(Bool.self, forKey: .noWebUI) ?? defaults.noWebUI
        listenOnNetwork = try container.decodeIfPresent(Bool.self, forKey: .listenOnNetwork)
            ?? defaults.listenOnNetwork
        startServerOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .startServerOnLaunch)
            ?? defaults.startServerOnLaunch
        checkForAppUpdates = try container.decodeIfPresent(Bool.self, forKey: .checkForAppUpdates)
            ?? defaults.checkForAppUpdates
        raiseGPULimit = try container.decodeIfPresent(Bool.self, forKey: .raiseGPULimit) ?? defaults.raiseGPULimit
        gpuWiredLimitMB = try container.decodeIfPresent(Int.self, forKey: .gpuWiredLimitMB) ?? defaults.gpuWiredLimitMB
        customModels = (try? container.decodeIfPresent([ModelSpec].self, forKey: .customModels)) ?? defaults.customModels
        keepGGUFFiles = try container.decodeIfPresent(Bool.self, forKey: .keepGGUFFiles) ?? defaults.keepGGUFFiles
        slipstreamPath = try container.decodeIfPresent(String.self, forKey: .slipstreamPath) ?? defaults.slipstreamPath
        setupCompleted = try container.decodeIfPresent(Bool.self, forKey: .setupCompleted) ?? defaults.setupCompleted
    }

    /// The catalog, then the models added with "New Model…" (not repeating any).
    public var availableModels: [ModelSpec] {
        ModelSpec.catalog + customModels.filter { custom in
            !ModelSpec.catalog.contains { $0.repository == custom.repository }
        }
    }

    /// The address `--host` gets.
    public var host: String { listenOnNetwork ? "0.0.0.0" : "127.0.0.1" }

    public static func defaultRepoPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("git/slipstream").path
    }

    public var repoURL: URL { URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath) }
    /// The checkout's lock, also watched in release mode in case one runs from there.
    public var serveLockURL: URL { repoURL.appendingPathComponent("build/runtime/serve.lock") }

    /// Arguments after the launcher path, for `installation` when known.
    public func serveArguments(for installation: SlipstreamInstallation? = nil) -> [String] {
        var arguments = ["serve", "--model", (model as NSString).expandingTildeInPath, "--port", String(port)]
        // The default needs no flag, which keeps launchers without --host working.
        if listenOnNetwork { arguments += ["--host", host] }
        let context = maxContext.trimmingCharacters(in: .whitespaces)
        if !context.isEmpty { arguments += ["--max-context", context] }
        let memory = maxMemory.trimmingCharacters(in: .whitespaces)
        if !memory.isEmpty { arguments += ["--max-memory", memory] }
        for host in allowedHosts.map({ $0.trimmingCharacters(in: .whitespaces) }) where !host.isEmpty {
            arguments += ["--allowed-host", host]
        }
        if noWebUI { arguments.append("--no-webui") }
        // A Slipstream without the flag keeps the files anyway.
        if keepGGUFFiles, installation?.supportsKeepGGUF == true { arguments.append("--keep-gguf") }
        return arguments
    }

    /// Problems that would make `slipstream serve` fail immediately, for the settings
    /// window, given the installation the app found for these settings.
    public func validationErrors(installation: SlipstreamInstallation?) -> [String] {
        var errors: [String] = []
        if installation == nil {
            errors.append(useCheckout
                ? "No Slipstream checkout with a `slipstream` launcher in \(repoURL.path)"
                : "Slipstream is not installed (no `slipstream` in ~/.local/bin or on PATH)")
        }
        if model.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("No model selected")
        }
        if listenOnNetwork, let installation, !installation.supportsHost {
            errors.append("Listening on the network needs a Slipstream whose launcher has `serve --host`")
        }
        // Two comparisons, not a range: below 8 GB of memory (a CI runner) the range would be inverted and trap.
        if raiseGPULimit,
           gpuWiredLimitMB < 8192 || gpuWiredLimitMB > Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) {
            errors.append("GPU memory limit must be between 8192 MB and this Mac's memory")
        }
        if !(1...65535).contains(port) {
            errors.append("Port must be between 1 and 65535")
        }
        let size = #"^\s*$|^\s*(auto|\d+(\.\d+)?\s*[KkMmGg]?)\s*$"#
        if maxContext.range(of: size, options: .regularExpression) == nil {
            errors.append("Max context must look like 100K or be empty")
        }
        if maxMemory.range(of: size, options: .regularExpression) == nil {
            errors.append("Max memory must look like 48G or be empty")
        }
        return errors
    }
}

/// Loads and saves the configuration as JSON in Application Support.
public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL = ConfigStore.defaultURL()) {
        self.url = url
    }

    /// `SLIPSTREAM_MENUBAR_CONFIG` points a test instance at another file.
    public static func defaultURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["SLIPSTREAM_MENUBAR_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Slipstream/menubar.json")
    }

    public func load() -> ServerConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ServerConfig.self, from: data) else {
            return ServerConfig()
        }
        return config
    }

    public func save(_ config: ServerConfig) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
