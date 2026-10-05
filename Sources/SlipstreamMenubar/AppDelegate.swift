import AppKit
import SlipstreamMenubarCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConfigStore()
    private var server: ServerController!
    private let stats = StatsModel()
    private var menu: MenuController!
    private var panel: StatsPanelController!
    private var settings: SettingsWindowController!
    private var installer: InstallWindowController!
    private var modelWindow: ModelWindowController!
    private var uninstaller: UninstallWindowController!
    private var updater: AppUpdateWindowController!
    private var setup: SetupWindowController!
    private var pollTask: Task<Void, Never>?
    private var menuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        server = ServerController(config: store.load(), apiKey: APIKeyStore.load())
        panel = StatsPanelController(server: server, stats: stats) { [weak self] _ in self?.menu?.update() }
        installer = InstallWindowController(
            repository: { [weak self] in self?.server.config.releaseRepository ?? ServerConfig.defaultReleaseRepository },
            onInstalled: { [weak self] in
                self?.server.locate()
                self?.menu.update()
            })
        uninstaller = UninstallWindowController(server: server)
        updater = AppUpdateWindowController(updater: AppUpdater())
        modelWindow = ModelWindowController(
            searchPath: { [weak self] in self?.server.searchPath ?? [] },
            installation: { [weak self] in self?.server.installation },
            keepsGGUFFiles: { [weak self] in self?.server.config.keepGGUFFiles ?? false },
            installSlipstream: { [weak self] in self?.installer.show() },
            models: { [weak self] in self?.server.config.availableModels ?? ModelSpec.catalog },
            addModel: { [weak self] model in self?.addCustomModel(model) },
            onDownloaded: { [weak self] model in self?.useDownloadedModel(model) },
            startServer: { [weak self] in self?.start() },
            openSettings: { [weak self] in self?.settings.show() })
        // `--setup-preview`: setup to click through, with nothing installed, downloaded,
        // started or saved.
        let setupPreview = CommandLine.arguments.contains("--setup-preview")
        setup = SetupWindowController(coordinator: SetupCoordinator(
            server: server,
            preview: setupPreview,
            saveConfig: { [weak self] config in self?.saveConfig(config) },
            startServer: { [weak self] in self?.startServer() },
            openSettings: { [weak self] in self?.settings.show() },
            showStats: { [weak self] in
                guard let self, !self.panel.isVisible else { return }
                self.panel.show()
                self.menu.update()
            }))
        settings = SettingsWindowController(
            server: server,
            save: { [weak self] config, key, restart in self?.apply(config, apiKey: key, restart: restart) },
            install: { [weak self] in self?.installer.show() },
            downloadModel: { [weak self] model in
                guard let model else { self?.modelWindow.show(newModel: true); return }
                // One added in Settings may not be saved yet; the download keeps it listed.
                self?.addCustomModel(model)
                self?.modelWindow.show(model: model)
            },
            uninstall: { [weak self] in self?.uninstaller.show() },
            runSetup: { [weak self] in self?.setup.show() })
        menu = MenuController(server: server, actions: .init(
            start: { [weak self] in self?.start() },
            stop: { [weak self] in self?.server.stop(); self?.menu.update() },
            forceStop: { [weak self] in self?.server.forceStop(); self?.menu.update() },
            togglePanel: { [weak self] in self?.panel.toggle(); self?.menu.update() },
            install: { [weak self] in self?.installer.show() },
            downloadModel: { [weak self] in self?.modelWindow.show() },
            isPanelVisible: { [weak self] in self?.panel.isVisible ?? false },
            settings: { [weak self] in self?.settings.show() },
            about: { [weak self] in self?.showAbout() },
            checkForUpdates: { [weak self] in
                guard let self else { return }
                if case .available = self.updater.updater.phase {
                    self.updater.show()
                } else if let release = self.updater.updater.available, !self.updater.updater.phase.isRunning {
                    self.updater.updater.offer(release)
                    self.updater.show()
                } else {
                    self.updater.show(check: !self.updater.updater.phase.isRunning)
                }
            },
            availableUpdate: { [weak self] in self?.updater.updater.available?.version },
            menuOpened: { [weak self] open in self?.menuOpen = open },
            readout: { [weak self] in
                guard let rates = self?.stats.rates else { return (0, 0) }
                return (rates.promptTokensPerSecond, rates.outputTokensPerSecond)
            }
        ))

        // Detect a server that is already running before deciding to start one.
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.tick()
            // A slipstream that only the login shell's PATH reaches, e.g. Homebrew's.
            await self.server.learnLoginShellPath()
            // First run: setup, while Slipstream or a model is missing.
            if self.setup.coordinator.isNeeded || self.setup.coordinator.preview
                || CommandLine.arguments.contains("--setup") {
                self.setup.show()
                // Development aid: open setup at a step (1–4), for screenshots.
                if let index = CommandLine.arguments.firstIndex(of: "--setup-step"),
                   CommandLine.arguments.indices.contains(index + 1),
                   let number = Int(CommandLine.arguments[index + 1]),
                   let step = SetupStep(rawValue: number - 1) {
                    self.setup.coordinator.step = step
                }
                // Development aid: the Model step's Hugging Face dialog, checking the given id.
                if let index = CommandLine.arguments.firstIndex(of: "--setup-hub"),
                   CommandLine.arguments.indices.contains(index + 1) {
                    self.setup.coordinator.step = .model
                    self.setup.coordinator.openHubDialog(input: CommandLine.arguments[index + 1])
                    self.setup.coordinator.hubChecker.check()
                }
            } else {
                self.setup.coordinator.completeSilently()
                if self.server.config.startServerOnLaunch, !self.server.status.isActive {
                    self.start()
                }
            }
            while !Task.isCancelled {
                // At most once a day; a cheap date comparison otherwise.
                self.updater.updater.checkIfDue(enabled: self.server.config.checkForAppUpdates)
                try? await Task.sleep(for: .seconds(self.pollInterval))
                await self.tick()
            }
        }
        updater.updater.canQuit = { [weak self] in
            (self?.modelWindow.confirmQuit() ?? true) && (self?.setup.coordinator.confirmQuit() ?? true)
        }
        // Development aids: the update window with a check, or a check that installs
        // whatever newer version it finds without asking.
        if CommandLine.arguments.contains("--check-updates") { updater.show(check: true) }
        if CommandLine.arguments.contains("--update-now") { updateWithoutAsking() }
        if CommandLine.arguments.contains("--show-panel") { panel.show() }
        if CommandLine.arguments.contains("--show-settings") { settings.show() }
        // Development aid: opens the installer and starts the download at once.
        if CommandLine.arguments.contains("--install-latest") { installer.show(startImmediately: true) }
        // Development aids: the model picker, or one catalog model's download, at once.
        if CommandLine.arguments.contains("--download-model") { modelWindow.show() }
        if let index = CommandLine.arguments.firstIndex(of: "--download"),
           CommandLine.arguments.indices.contains(index + 1),
           let model = server.config.availableModels.first(where: { $0.repository == CommandLine.arguments[index + 1] }) {
            modelWindow.show(model: model)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if UpdateQuit.approved { return .terminateNow }
        return modelWindow.confirmQuit() && setup.coordinator.confirmQuit() ? .terminateNow : .terminateCancel
    }

    private func updateWithoutAsking() {
        let updater = updater.updater
        self.updater.show(check: true)
        Task { @MainActor in
            while updater.phase == .checking { try? await Task.sleep(for: .milliseconds(200)) }
            if case .available(let release) = updater.phase { updater.install(release) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()  // the server keeps running
    }

    /// Two seconds while serving or someone is looking (the rates average over three),
    /// one while the state is changing, three when stopped.
    private var pollInterval: Double {
        switch server.status {
        case .running, .unresponsive: return 2
        case .stopped, .failed: return panel.isVisible || menuOpen ? 2 : 3
        default: return 1
        }
    }

    private func tick() async {
        let wasPreparing: Bool
        if case .preparing = server.status { wasPreparing = true } else { wasPreparing = false }
        await server.refresh()
        // Show the preparation's progress bar when a first start begins converting.
        if case .preparing = server.status, !wasPreparing, !panel.isVisible { panel.show() }
        await stats.sample(port: server.port, apiKey: server.apiKey, serverReady: server.status == .running)
        menu.update()
    }

    private func start() {
        if let reason = startServer() { alert("The server could not be started", reason) }
    }

    /// Starts the server; returns why it could not, or nil.
    private func startServer() -> String? {
        server.acknowledgeFailure()
        defer { menu.update() }
        guard raiseGPULimitIfNeeded() else { return "The GPU memory limit was not raised." }
        do {
            try server.start()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// On a 64 GB Mac, sets `iogpu.wired_limit_mb` before a start: macOS keeps it near
    /// 48 GiB and resets it at boot. Asks for an administrator password through the
    /// standard macOS prompt. Returns false when the server should not start.
    private func raiseGPULimitIfNeeded() -> Bool {
        let config = server.config
        guard config.raiseGPULimit, MachineCheck.needsGPULimitRaise(),
              let current = GPUMemoryLimit.currentMB(), current != config.gpuWiredLimitMB else { return true }
        let command = GPUMemoryLimit.command(megabytes: config.gpuWiredLimitMB)
        let source = "do shell script \"\(command)\" with prompt "
            + "\"Slipstream raises the GPU memory limit to \(config.gpuWiredLimitMB) MB "
            + "for the model server.\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if GPUMemoryLimit.currentMB() == config.gpuWiredLimitMB { return true }
        let reason = (error?[NSAppleScript.errorMessage] as? String) ?? "The limit was not changed."
        let alert = NSAlert()
        alert.messageText = "The GPU memory limit was not raised"
        alert.informativeText = "\(reason)\n\nIt is \(current == 0 ? "the macOS default" : "\(current) MB"); "
            + "the model server expects \(config.gpuWiredLimitMB) MB on a 64 GB Mac and may fail to load "
            + "without it. You can turn this step off in Settings → Memory."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Start Anyway")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// A model added with New Model… is kept in the settings, next to the catalog.
    private func addCustomModel(_ model: ModelSpec) {
        var config = server.config
        guard !config.availableModels.contains(where: { $0.repository == model.repository }) else { return }
        config.customModels.append(model)
        saveConfig(config)
    }

    private func saveConfig(_ config: ServerConfig) {
        do {
            try store.save(config)
        } catch {
            alert("Settings could not be saved", error.localizedDescription)
        }
        server.config = config
        menu.update()
    }

    /// A finished download becomes the configured model, by its Hub id: the launcher finds
    /// it in the model store.
    private func useDownloadedModel(_ model: ModelSpec) {
        var config = server.config
        config.model = model.repository
        saveConfig(config)
    }

    private func apply(_ config: ServerConfig, apiKey: String?, restart: Bool) {
        do {
            try store.save(config)
        } catch {
            alert("Settings could not be saved", error.localizedDescription)
            return
        }
        APIKeyStore.save(apiKey)
        server.config = config
        server.apiKey = apiKey
        if restart { Task { await restartServer() } }
    }

    private func restartServer() async {
        server.stop()
        for _ in 0..<60 where server.status.isActive {
            try? await Task.sleep(for: .seconds(1))
            await server.refresh()
        }
        start()
    }

    private func showAbout() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        var lines = ["Start, stop and watch a local Slipstream server."]
        if let installation = server.installation {
            lines.append("\(installation.displayName): "
                         + (installation.root.path as NSString).abbreviatingWithTildeInPath)
            if installation.kind == .checkout, let build = EngineBuild.identifier(repo: installation.root) {
                lines.append("Engine build: \(build)")
            }
        } else {
            lines.append("Slipstream: not installed")
        }
        if let model = server.model ?? (server.config.model.isEmpty ? nil : server.config.model) {
            lines.append("Model: \((model as NSString).lastPathComponent)")
        }
        lines.append("Server log: ~/Library/Logs/Slipstream/server.log")
        credits.append(NSAttributedString(string: lines.joined(separator: "\n"), attributes: body))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Slipstream",
            .credits: credits,
        ])
    }

    /// Development aid: renders the stats panel to a PNG once some history exists,
    /// and the menu bar item, with and without readouts, beside it.
    private func snapshot(to url: URL) {
        let itemURL = url.deletingPathExtension().appendingPathExtension("menubar.png")
        writeMenuBarSample(to: itemURL)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))  // the readout appears once the server is seen
            let widths = menu.measuredWidths
            let text = "item \(widths.item) pt, image \(widths.image) pt\n"
            try? text.write(to: url.deletingPathExtension().appendingPathExtension("widths.txt"),
                            atomically: true, encoding: .utf8)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))
            let view = StatsContent(server: server, stats: stats)
                .frame(width: 460)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
        }
    }

    private func writeMenuBarSample(to url: URL) {
        let samples = [StatusItemImage.make(rates: nil), StatusItemImage.make(rates: (342, 41.2)),
                       StatusItemImage.make(rates: (12_400, 8.7)), StatusItemImage.make(rates: (0, 0))]
        let scale: CGFloat = 4
        let spacing: CGFloat = 12
        let width = samples.reduce(spacing) { $0 + $1.size.width + spacing }
        let size = NSSize(width: width * scale, height: StatusItemImage.height * scale)
        let canvas = NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.93, alpha: 1).setFill()
            rect.fill()
            var x = spacing
            for sample in samples {
                sample.draw(in: NSRect(x: x * scale, y: 0, width: sample.size.width * scale, height: size.height))
                x += sample.size.width + spacing
            }
            return true
        }
        if let tiff = canvas.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
