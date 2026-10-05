import AppKit
import SlipstreamMenubarCore

/// The status item and its menu:
///
///   ● Status · model · :port     (not clickable)
///   Start Server / Stop Server / Force Stop
///   ─────
///   Stats Panel
///   Open Web UI
///   ─────
///   Settings…  ⌘,
///   About Slipstream Menubar
///   Check for Updates… / Update to <version>…
///   ─────
///   Quit  ⌘Q
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let server: ServerController
    private let actions: Actions

    private let headerItem = NSMenuItem()
    private let detailItem = NSMenuItem()
    private var startItem: NSMenuItem!
    private var installItem: NSMenuItem!
    private var downloadModelItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var forceStopItem: NSMenuItem!
    private var panelItem: NSMenuItem!
    private var webUIItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var modelItem: NSMenuItem!
    private var modelMenu: NSMenu!

    struct Actions {
        var start: () -> Void
        var stop: () -> Void
        var forceStop: () -> Void
        var togglePanel: () -> Void
        /// Opens the installer, offered when no Slipstream is installed.
        var install: () -> Void
        /// Opens the model download, offered when the configured model is missing.
        var downloadModel: () -> Void
        var isPanelVisible: () -> Bool
        var settings: () -> Void
        var about: () -> Void
        var checkForUpdates: () -> Void
        /// A newer version of the app, once a check has found one.
        var availableUpdate: () -> String?
        var menuOpened: (Bool) -> Void
        /// Prompt and output tokens per second while serving.
        var readout: () -> (prompt: Double, output: Double)?
        var selectModel: (String) -> Void
        var chooseModelFolder: () -> Void
    }

    init(server: ServerController, actions: Actions) {
        self.server = server
        self.actions = actions
        super.init()
        build()
        update()
    }

    private func build() {
        menu.delegate = self
        menu.autoenablesItems = false
        headerItem.isEnabled = false
        detailItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(detailItem)
        menu.addItem(.separator())
        startItem = add("Start Server", #selector(start))
        installItem = add("Install Slipstream…", #selector(install))
        downloadModelItem = add("Download Model…", #selector(downloadModel))
        stopItem = add("Stop Server", #selector(stop))
        forceStopItem = add("Force Stop", #selector(forceStop))
        menu.addItem(.separator())
        modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelMenu = NSMenu(title: "Model")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)
        menu.addItem(.separator())
        panelItem = add("Stats Panel", #selector(togglePanel), key: "s")
        webUIItem = add("Open Web UI", #selector(openWebUI), key: "o")
        menu.addItem(.separator())
        add("Settings…", #selector(settings), key: ",")
        add("About Slipstream", #selector(about))
        updateItem = add("Check for Updates…", #selector(checkForUpdates))
        menu.addItem(.separator())
        add("Quit", #selector(quit), key: "q")
        statusItem.menu = menu
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    func update() {
        let status = server.status
        let running = status == .running
        let rates = running ? actions.readout() : nil
        let image = StatusItemImage.make(rates: rates)
        image.accessibilityDescription = "Slipstream \(status.title)"
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.appearsDisabled = !status.isActive
        statusItem.button?.toolTip = rates.map {
            "Slipstream: prompt \(Format.rate($0.prompt)), output \(Format.rate($0.output))"
        } ?? "Slipstream: \(status.title)"

        let header = NSMutableAttributedString(
            string: "● ", attributes: [.foregroundColor: status.color, .font: NSFont.menuFont(ofSize: 0)])
        let title = !status.isActive && server.installation == nil ? "Slipstream not installed" : status.title
        header.append(NSAttributedString(
            string: title + (server.external && status.isActive ? " (started elsewhere)" : ""),
            attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.boldSystemFont(ofSize: 0)]))
        headerItem.attributedTitle = header

        var detail: [String] = []
        if let model = server.model { detail.append((model as NSString).lastPathComponent) }
        if status.isActive { detail.append(server.listensOnNetwork ? "network :\(server.port)" : ":\(server.port)") }
        if let installed = server.pendingUpdate, let running = server.runningVersion {
            detail.append(ReleasePackages.isOlder(running, installed)
                          ? "restart to update to \(installed)" : "restart to switch to \(installed)")
        }
        if case .failed(let message) = status { detail.append(message) }
        detailItem.title = detail.joined(separator: " · ")
        detailItem.isHidden = detail.isEmpty

        // Without an installation there is nothing to start: offer to install one.
        let installed = server.installation != nil
        startItem.isHidden = status.isActive || !installed
        installItem.isHidden = status.isActive || installed
        downloadModelItem.isHidden = status.isActive || ModelPresence.isAvailable(server.config.model)
        stopItem.isHidden = !status.isActive
        stopItem.isEnabled = status != .stopping
        forceStopItem.isHidden = !(status == .unresponsive || status == .stopping)

        // Populate Model submenu
        modelMenu.removeAllItems()
        let localModels = LocalModelScanner.scan()
        var allModels = server.config.availableModels
        for m in localModels {
            if !allModels.contains(where: { $0.repository == m.repository || $0.folderURL.standardizedFileURL.path == m.folderURL.standardizedFileURL.path }) {
                allModels.append(m)
            }
        }
        let currentModel = server.config.model.trimmingCharacters(in: .whitespaces)
        let currentPath = URL(fileURLWithPath: (currentModel as NSString).expandingTildeInPath).standardizedFileURL.path

        for spec in allModels {
            let specPath = spec.folderURL.standardizedFileURL.path
            let isCurrent = (spec.repository == currentModel) || (!currentModel.isEmpty && specPath == currentPath)
            let item = NSMenuItem(title: spec.title, action: #selector(modelSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = spec.repository
            item.state = isCurrent ? .on : .off
            modelMenu.addItem(item)
        }

        modelMenu.addItem(.separator())
        let chooseItem = NSMenuItem(title: "Choose Folder…", action: #selector(chooseFolder), keyEquivalent: "")
        chooseItem.target = self
        modelMenu.addItem(chooseItem)

        panelItem.state = actions.isPanelVisible() ? .on : .off
        // The chat page is served at / unless the server runs with --no-webui.
        webUIItem.isEnabled = status == .running && !server.config.noWebUI
        webUIItem.toolTip = server.config.noWebUI ? "The web UI is turned off in Settings" : nil
        updateItem.title = actions.availableUpdate().map { "Update to \($0)…" } ?? "Check for Updates…"
    }

    /// The status item's on-screen width and its image's width, for layout checks.
    var measuredWidths: (item: CGFloat, image: CGFloat) {
        (statusItem.button?.frame.width ?? 0, statusItem.button?.image?.size.width ?? 0)
    }

    func menuWillOpen(_ menu: NSMenu) {
        actions.menuOpened(true)
        update()
    }

    func menuDidClose(_ menu: NSMenu) {
        actions.menuOpened(false)
    }

    @objc private func start() { actions.start() }
    @objc private func stop() { actions.stop() }
    @objc private func forceStop() { actions.forceStop() }
    @objc private func modelSelected(_ sender: NSMenuItem) {
        guard let repository = sender.representedObject as? String else { return }
        actions.selectModel(repository)
    }
    @objc private func chooseFolder() { actions.chooseModelFolder() }
    @objc private func togglePanel() { actions.togglePanel() }
    @objc private func openWebUI() {
        if let url = URL(string: "http://127.0.0.1:\(server.port)/") { NSWorkspace.shared.open(url) }
    }
    @objc private func install() { actions.install() }
    @objc private func downloadModel() { actions.downloadModel() }
    @objc private func settings() { actions.settings() }
    @objc private func about() { actions.about() }
    @objc private func checkForUpdates() { actions.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}
