import AppKit
import OSLog
import SlipstreamMenubarCore
import SwiftUI

/// Updates the app itself from its GitHub releases: checks about once a day (or when
/// asked), offers a newer version with its changes, and on request downloads the zip,
/// verifies it against the release's checksums, puts the new bundle in place of this
/// one, and relaunches. The server keeps running throughout.
@MainActor
final class AppUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(received: Int64, total: Int64)
        case verifying
        case installing
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .checking, .downloading, .verifying, .installing: return true
            default: return false
            }
        }

        /// For the log.
        var summary: String {
            switch self {
            case .available(let release): return "available \(release.version)"
            case .downloading(_, let total): return "downloading \(total) bytes"
            case .failed(let message): return "failed: \(message)"
            default: return "\(self)"
            }
        }
    }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var phase: Phase = .idle {
        didSet {
            if case .downloading = phase, case .downloading = oldValue { return }  // progress only
            Self.log.notice("update: \(self.phase.summary, privacy: .public)")
        }
    }
    /// `log show --predicate 'subsystem == "local.slipstream.menubar"'`
    static let log = Logger(subsystem: "local.slipstream.menubar", category: "update")
    /// The newest release seen that is newer than this app, for the menu.
    @Published private(set) var available: AppRelease?

    let currentVersion: String
    private let repository: String
    private let session = URLSession(configuration: .ephemeral)
    private let download = FileDownload()
    private var task: Task<Void, Never>?

    /// Asked before quitting for the relaunch (a running model download, say).
    var canQuit: () -> Bool = { true }
    /// Shows the window; called when an automatic check finds something new.
    var present: () -> Void = {}

    private static let lastCheckKey = "AppUpdateLastCheck"
    private static let lastAttemptKey = "AppUpdateLastAttempt"
    private static let skippedKey = "AppUpdateSkippedVersion"

    init(repository: String = ProcessInfo.processInfo.environment["SLIPSTREAM_MENUBAR_UPDATE_REPO"]
            ?? AppUpdate.repository,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0") {
        self.repository = repository
        self.currentVersion = currentVersion
    }

    /// The app runs from a bundle it can replace (not `swift run`).
    var canInstall: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    // MARK: Checking

    /// The daily check: quiet unless it finds a version the user has not skipped.
    func checkIfDue(enabled: Bool) {
        let defaults = UserDefaults.standard
        guard enabled, !phase.isRunning,
              AppUpdate.isCheckDue(lastCheck: defaults.object(forKey: Self.lastCheckKey) as? Date,
                                   lastAttempt: defaults.object(forKey: Self.lastAttemptKey) as? Date)
        else { return }
        defaults.set(Date(), forKey: Self.lastAttemptKey)
        task = Task {
            let release: AppRelease
            do {
                release = try await latestRelease()
            } catch {
                Self.log.notice("update: automatic check failed: \(error.localizedDescription, privacy: .public)")
                return  // offline, say: the next try is in an hour
            }
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            guard AppUpdate.isNewer(release.version, than: currentVersion) else { return }
            available = release
            guard UserDefaults.standard.string(forKey: Self.skippedKey) != release.version,
                  phase == .idle || phase == .upToDate else { return }
            phase = .available(release)
            present()
        }
    }

    /// "Check for Updates…": always reports, and ignores a skipped version.
    func checkNow() {
        guard !phase.isRunning else { return }
        phase = .checking
        task = Task {
            do {
                let release = try await latestRelease()
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                if AppUpdate.isNewer(release.version, than: currentVersion) {
                    available = release
                    phase = .available(release)
                } else {
                    available = nil
                    phase = .upToDate
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Shows a release found earlier, e.g. after "Later".
    func offer(_ release: AppRelease) {
        guard !phase.isRunning else { return }
        phase = .available(release)
    }

    func skip(_ release: AppRelease) {
        UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        phase = .idle
    }

    func cancel() {
        guard phase != .installing else { return }  // the bundle is being swapped; the app quits next
        download.cancel()
        task?.cancel()
        if phase.isRunning { phase = available.map { .available($0) } ?? .idle }
    }

    func reset() {
        if !phase.isRunning { phase = .idle }
    }

    /// One retry for errors a second attempt usually gets past.
    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as URLError where [.networkConnectionLost, .timedOut, .cannotConnectToHost,
                                               .notConnectedToInternet].contains(error.code) {
            try await Task.sleep(for: .seconds(2))
            return try await operation()
        }
    }

    private func latestRelease() async throws -> AppRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError(message: "Invalid repository \(repository)")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await withRetry { try await session.data(for: request) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw UpdateError(message: code == 404 ? "\(repository) has no published release"
                                                   : "GitHub answered \(code) for the latest release")
        }
        guard let release = AppRelease(json: data) else {
            throw UpdateError(message: "Could not read the latest release of \(repository)")
        }
        return release
    }

    // MARK: Installing

    func install(_ release: AppRelease) {
        guard !phase.isRunning else { return }
        task = Task {
            do {
                try await update(to: release)
            } catch is CancellationError {
                phase = .available(release)
            } catch let error as URLError where error.code == .cancelled {
                phase = .available(release)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func update(to release: AppRelease) async throws {
        guard canInstall else { throw UpdateError(message: "Only an app bundle can update itself") }
        guard let zipURL = release.assets[release.zipName], let sumsURL = release.assets[release.checksumsName] else {
            throw UpdateError(message: "Release \(release.tag) has no \(release.zipName) with checksums")
        }
        let (sumsData, sumsResponse) = try await withRetry { try await session.data(from: sumsURL) }
        guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected = AppUpdate.checksum(for: release.zipName, in: String(decoding: sumsData, as: UTF8.self))
        else { throw UpdateError(message: "Could not read the checksums of \(release.tag)") }

        let known = release.sizes[release.zipName] ?? 0
        phase = .downloading(received: 0, total: known)
        download.onProgress = { [weak self] received, total in
            guard let self, case .downloading = self.phase else { return }
            self.phase = .downloading(received: received, total: total > 0 ? total : known)
        }
        let zip = try await download.run(zipURL)
        defer { try? FileManager.default.removeItem(at: zip) }
        try Task.checkCancellation()

        phase = .verifying
        let digest = try await Task.detached { try ReleaseInstaller.sha256(of: zip) }.value
        guard digest == expected else { throw UpdateError(message: "Checksum mismatch for \(release.zipName)") }
        let staged = try await Task.detached { [currentVersion] in
            try Self.unpack(zip, expecting: release.version, replacing: currentVersion)
        }.value

        phase = .installing
        guard canQuit() else {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            phase = .available(release)
            return
        }
        try swapAndRelaunch(staged)
    }

    /// Unzips the release and checks that it is this app, at the expected version, with
    /// an intact signature. Returns the new bundle, in a folder of its own.
    nonisolated private static func unpack(_ zip: URL, expecting version: String,
                                           replacing current: String) throws -> URL {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("slipstream-menubar-update-\(UUID().uuidString)")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path], failure: "Could not unpack the update")
            guard let name = try fileManager.contentsOfDirectory(atPath: folder.path).first(where: { $0.hasSuffix(".app") })
            else { throw UpdateError(message: "The update holds no app") }
            let app = folder.appendingPathComponent(name)
            guard let bundle = Bundle(url: app),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version
            else { throw UpdateError(message: "The update is not Slipstream \(version)") }
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
                    failure: "The update's code signature is broken")
            return app
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError(message: failure) }
    }

    /// Moves the new bundle into this one's place (asking for an administrator password
    /// when its folder is not writable), starts a helper that opens it once this
    /// process has exited, and quits.
    private func swapAndRelaunch(_ staged: URL) throws {
        let app = Bundle.main.bundleURL
        let backup = staged.deletingLastPathComponent().appendingPathComponent("previous.app")
        let command = AppUpdate.swapCommand(app: app, staged: staged, backup: backup)
        if FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path),
           FileManager.default.isWritableFile(atPath: app.path) {
            try Self.run("/bin/sh", ["-c", command], failure: "Could not replace \(app.path)")
        } else {
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let source = "do shell script \"\(escaped)\" with prompt \"Slipstream replaces itself "
                + "with the new version.\" with administrator privileges"
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                throw UpdateError(message: (error[NSAppleScript.errorMessage] as? String) ?? "Could not replace the app")
            }
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", AppUpdate.relaunchScript(pid: ProcessInfo.processInfo.processIdentifier,
                                                           app: app, backup: staged.deletingLastPathComponent())]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        // canQuit already asked; skip the question on the way out.
        UpdateQuit.approved = true
        NSApp.terminate(nil)
    }
}

/// Set once the update has asked everything a quit would ask.
@MainActor
enum UpdateQuit {
    static var approved = false
}

// MARK: - Window

@MainActor
final class AppUpdateWindowController: NSObject, NSWindowDelegate {
    let updater: AppUpdater
    private var window: NSWindow?

    init(updater: AppUpdater) {
        self.updater = updater
        super.init()
        updater.present = { [weak self] in self?.show() }
    }

    /// Shows the window; with `check` it starts a check first.
    func show(check: Bool = false) {
        if check { updater.checkNow() }
        let view = AppUpdateView(updater: updater, close: { [weak self] in self?.window?.close() })
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Software Update"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        updater.cancel()
        updater.reset()
    }
}

private struct AppUpdateView: View {
    @ObservedObject var updater: AppUpdater
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch updater.phase {
            case .idle, .checking:
                Text("Slipstream \(updater.currentVersion)").font(.headline)
                ProgressView().progressViewStyle(.linear)
                Text("Looking for a newer version…").font(.caption)
            case .upToDate:
                Text("Slipstream is up to date").font(.headline)
                Text(verbatim: "Version \(updater.currentVersion) is the latest.").font(.callout).foregroundStyle(.secondary)
            case .available(let release):
                offer(release)
            case .downloading(let received, let total):
                Text("Updating to \(updater.available?.version ?? "the new version")").font(.headline)
                if total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text("Downloading: \(bytes(received)) of \(total > 0 ? bytes(total) : "…")")
                    .font(.caption).monospacedDigit()
            case .verifying:
                Text("Updating to \(updater.available?.version ?? "the new version")").font(.headline)
                ProgressView().progressViewStyle(.linear)
                Text("Verifying the checksum and signature…").font(.caption)
            case .installing:
                Text("Updating to \(updater.available?.version ?? "the new version")").font(.headline)
                ProgressView().progressViewStyle(.linear)
                Text("Installing and relaunching…").font(.caption)
            case .failed(let message):
                Text("The update did not work").font(.headline)
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                if case .available(let release) = updater.phase {
                    Button("Skip This Version") { updater.skip(release); close() }
                    Spacer()
                    Button("Later", action: close).keyboardShortcut(.cancelAction)
                    Button("Update and Relaunch") { updater.install(release) }
                        .keyboardShortcut(.defaultAction).disabled(!updater.canInstall)
                } else if updater.phase.isRunning {
                    Spacer()
                    Button("Cancel") { updater.cancel() }.keyboardShortcut(.cancelAction)
                        .disabled(updater.phase == .installing)
                } else {
                    Spacer()
                    if case .failed = updater.phase, let release = updater.available {
                        Button("Try Again") { updater.install(release) }
                    }
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private func offer(_ release: AppRelease) -> some View {
        Text("Slipstream \(release.version) is available").font(.headline)
        Text(verbatim: "You have \(updater.currentVersion). The server keeps running while the app updates.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if !release.changes.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(release.changes.enumerated()), id: \.offset) { _, change in
                        Text("• " + change).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        }
        if let page = release.page {
            Link("Release notes on GitHub", destination: page).font(.caption)
        }
        if !updater.canInstall {
            Text("This copy is not an app bundle, so it cannot replace itself.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
