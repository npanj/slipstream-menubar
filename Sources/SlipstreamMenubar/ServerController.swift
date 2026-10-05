import AppKit
import Darwin
import SlipstreamMenubarCore

/// Starts, stops and watches the Slipstream server.
///
/// The server is found through the launcher's `build/runtime/serve.lock`, so a
/// server started from a terminal, or by an earlier run of this app, is picked
/// up the same way as one started here. Quitting the app leaves it running: it
/// is spawned in its own session with its output going to a log file, so it
/// does not depend on this process.
@MainActor
final class ServerController: ObservableObject {
    @Published private(set) var status: ServerStatus = .stopped
    /// The pid the status refers to, when one is alive.
    @Published private(set) var pid: Int32?
    @Published private(set) var port: Int
    @Published private(set) var model: String?
    /// Running, but not started by this app (or an earlier run of it).
    @Published private(set) var external = false
    /// The running server accepts connections from other machines.
    @Published private(set) var listensOnNetwork = false
    /// The Slipstream that Start runs: the installed release, or a checkout if the
    /// settings ask for one. Nil means nothing is installed.
    @Published private(set) var installation: SlipstreamInstallation?
    /// The release the running server was started from (nil for a checkout or no server).
    /// It differs from `installation` after an update until the server restarts.
    @Published private(set) var runningVersion: String?
    /// The last preparation of this app's server ran without an MTP draft head.
    @Published private(set) var missingMTPDraftHead = false
    /// Seconds left of a first-start GGUF preparation, from its pace so far.
    @Published private(set) var preparationSecondsLeft: TimeInterval?
    private var preparationStart: (time: Date, parts: Int)?

    var config: ServerConfig {
        didSet {
            if !status.isActive { port = config.port }
            locate()
        }
    }
    /// Directories searched for `slipstream` after ~/.local/bin: the app's PATH, and
    /// the login shell's once it is known.
    private(set) var searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    var apiKey: String?

    /// `SLIPSTREAM_MENUBAR_LOG` points a test instance at another log.
    static let logURL = ProcessInfo.processInfo.environment["SLIPSTREAM_MENUBAR_LOG"]
        .map(URL.init(fileURLWithPath:))
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Slipstream/server.log")
    private static let spawnedPidKey = "spawnedServerPid"

    private var exitSource: DispatchSourceProcess?
    private var exitDescription: String?
    private var stopping = false
    private var stopDeadline: Date?
    private var healthFailures = 0
    private let session: URLSession

    init(config: ServerConfig, apiKey: String?) {
        self.config = config
        self.apiKey = apiKey
        self.port = config.port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        session = URLSession(configuration: configuration)
        locate()
    }

    /// The pid this app last spawned, remembered across app restarts.
    private var spawnedPid: Int32? {
        get {
            let value = Int32(UserDefaults.standard.integer(forKey: Self.spawnedPidKey))
            return value > 0 ? value : nil
        }
        set { UserDefaults.standard.set(Int(newValue ?? 0), forKey: Self.spawnedPidKey) }
    }

    // MARK: Installation

    func locate() {
        let found = installation(for: config)
        if found != installation { installation = found }
    }

    /// The installed release is newer than the one the running server uses: a restart updates it.
    var pendingUpdate: String? {
        guard status.isActive, let running = runningVersion, let installed = installation?.version,
              running != installed else { return nil }
        return installed
    }

    /// What Start would run with these settings, for the settings window.
    func installation(for config: ServerConfig) -> SlipstreamInstallation? {
        InstallationLocator.find(config: config, searchPath: searchPath)
    }

    /// Adds the login shell's PATH (Homebrew, profile additions) to the search; it is
    /// read off the main thread because a shell profile can take a moment.
    func learnLoginShellPath() async {
        let path = await Task.detached { InstallationLocator.loginShellPath() }.value
        searchPath += path.filter { !searchPath.contains($0) }
        locate()
    }

    // MARK: Status

    func refresh() async {
        locate()
        // A server may have been started by any installation, so look at every lock.
        var lock: ServeLock?
        var livePid: Int32?
        for url in InstallationLocator.serveLocks(installation: installation, config: config) {
            if let candidate = ServeLock.read(from: url), ServerProcessInspector.isSlipstreamServer(candidate.pid) {
                lock = candidate
                livePid = candidate.pid
                break
            }
        }
        if livePid == nil, let spawned = spawnedPid, ServerProcessInspector.isSlipstreamServer(spawned) {
            livePid = spawned  // between spawn and the launcher writing its lock
        }
        if livePid == nil {
            livePid = ServerProcessInspector.findListeningServer(port: config.port)
        }
        let probePort = livePid != nil ? (lock?.port ?? config.port) : config.port
        async let health = probe("/health", port: probePort)
        async let ready = probe("/ready", port: probePort)
        let (healthOK, readyOK) = await (health, ready)

        let ours = livePid != nil && livePid == spawnedPid
        healthFailures = (livePid != nil && !healthOK) ? healthFailures + 1 : 0
        // Only needed before the server has been seen as running: /ready is 503 while busy.
        let undecided = !(status == .running || status == .unresponsive)
        let served = livePid != nil && healthOK && !readyOK && undecided
            ? await hasServedRequests(port: probePort) : false
        let logProgress = ours || exitDescription != nil ? readLogProgress() : nil
        missingMTPDraftHead = ours && (logProgress?.missingMTPDraftHead ?? false)
        let observation = StatusObservation(
            processAlive: livePid != nil,
            healthOK: healthOK,
            readyOK: readyOK,
            logProgress: logProgress,
            stopping: stopping,
            previous: status,
            healthFailures: healthFailures,
            exitDescription: exitDescription,
            hasServedRequests: served
        )
        let resolved = StatusResolver.resolve(observation)

        if livePid == nil {
            stopping = false
            stopDeadline = nil
        } else if stopping, let deadline = stopDeadline, Date() > deadline, let livePid {
            kill(livePid, SIGKILL)  // did not exit after SIGTERM
        }
        if livePid != pid {  // argv only changes with the process
            runningVersion = livePid
                .flatMap(ServerProcessInspector.arguments(of:))
                .flatMap(SlipstreamInstallation.runningRoot(arguments:))
                .flatMap(SlipstreamInstallation.releaseVersion(ofRoot:))
        }
        pid = livePid
        port = probePort
        model = livePid != nil ? (lock?.model ?? config.model) : nil
        external = livePid == nil ? readyOK : !ours
        listensOnNetwork = livePid != nil && (lock?.listensOnNetwork ?? false)
        if status != resolved { status = resolved }
        estimatePreparation()
    }

    /// Time left of a preparation: its parts (48 layers, head, embedding, MTP, n-gram
    /// table) take similar time when run in parallel, so the pace of the parts done so far
    /// extrapolates well enough.
    private func estimatePreparation() {
        guard case .preparing(let parts) = status else {
            preparationStart = nil
            preparationSecondsLeft = nil
            return
        }
        guard let start = preparationStart else {
            preparationStart = (Date(), parts)
            return
        }
        let done = parts - start.parts
        let elapsed = Date().timeIntervalSince(start.time)
        guard done > 0, elapsed > 5 else { return }
        let remaining = max(0, LogProgress.preparationParts - parts)
        preparationSecondsLeft = elapsed / Double(done) * Double(remaining)
    }

    private func probe(_ path: String, port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Whether `/metrics` shows submitted requests, i.e. the model is loaded.
    private func hasServedRequests(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/metrics") else { return false }
        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let sample = EngineSample(metrics: PrometheusText.parse(String(decoding: data, as: UTF8.self)),
                                        time: Date())
        else { return false }
        return sample.requestsSubmitted > 0
    }

    private func readLogProgress() -> LogProgress? {
        guard let handle = try? FileHandle(forReadingFrom: Self.logURL) else { return nil }
        defer { try? handle.close() }
        // The preparation and startup lines are near the start of the log.
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        return LogProgress.parse(String(decoding: data, as: UTF8.self))
    }

    // MARK: Control

    enum StartError: LocalizedError {
        case invalidConfig([String])
        case spawnFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidConfig(let errors): return errors.joined(separator: "\n")
            case .spawnFailed(let code): return "Could not start the launcher: \(String(cString: strerror(code)))"
            }
        }
    }

    func start() throws {
        guard !status.isActive else { return }
        locate()
        let errors = config.validationErrors(installation: installation)
        guard errors.isEmpty, let installation else { throw StartError.invalidConfig(errors) }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: Self.logURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let previousLog = Self.logURL.appendingPathExtension("1")
        try? fileManager.removeItem(at: previousLog)
        try? fileManager.moveItem(at: Self.logURL, to: previousLog)

        let launcher = installation.launcher.path
        let arguments = [launcher] + config.serveArguments(for: installation)
        var environment = ProcessInfo.processInfo.environment
        // Apps get a minimal PATH; the launcher's build steps need the usual tools.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let apiKey, !apiKey.isEmpty {
            environment["SLIPSTREAM_V2_API_KEY"] = apiKey
        }
        let pid = try spawn(launcher, arguments: arguments, environment: environment,
                            directory: installation.root.path, log: Self.logURL.path)

        spawnedPid = pid
        exitDescription = nil
        stopping = false
        healthFailures = 0
        watchExit(of: pid)
        self.pid = pid
        status = .starting
    }

    func stop() {
        guard let pid, status.isActive else { return }
        stopping = true
        stopDeadline = Date().addingTimeInterval(30)
        kill(pid, SIGTERM)
        status = .stopping
    }

    /// Stops the server and waits until it is gone (SIGKILL after the usual 30 s).
    func stopAndWait() async {
        await refresh()
        guard status.isActive else { return }
        stop()
        for _ in 0..<45 where status.isActive {
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        }
        if status.isActive { forceStop() }
    }

    /// Whether the running server serves the model in this folder.
    func isServing(folder: URL) -> Bool {
        guard status.isActive, let model else { return false }
        // A model served by its Hub id lives in the model store.
        let local = model.hasPrefix("/") || model.hasPrefix("~") || model.hasPrefix(".")
        let served = local ? URL(fileURLWithPath: (model as NSString).expandingTildeInPath) : ModelStore.folder(for: model)
        return served.standardizedFileURL.path == folder.standardizedFileURL.path
    }

    func forceStop() {
        guard let pid else { return }
        stopping = true
        kill(pid, SIGKILL)
        status = .stopping
    }

    /// posix_spawn in a new session, stdin from /dev/null and output to the log,
    /// so the server outlives the app and never inherits its descriptors.
    private func spawn(_ path: String, arguments: [String], environment: [String: String],
                       directory: String, log: String) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw StartError.spawnFailed(result) }
        return pid
    }

    /// Reaps a server this app spawned, so it does not linger as a zombie, and
    /// records how it ended for the status line.
    private func watchExit(of pid: Int32) {
        exitSource?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            MainActor.assumeIsolated {
                guard let self else { return }
                let code = (status >> 8) & 0xff
                let signal = status & 0x7f
                if !self.stopping, code != 0 || signal != 0 {
                    self.exitDescription = signal != 0
                        ? "Server ended by signal \(signal)" : "Server exited with status \(code)"
                }
                self.exitSource?.cancel()
                self.exitSource = nil
                Task { await self.refresh() }
            }
        }
        source.resume()
        exitSource = source
    }

    /// Clears a shown failure, e.g. when the user opens the menu after reading it.
    func acknowledgeFailure() {
        if case .failed = status {
            exitDescription = nil
            status = .stopped
        }
    }
}
