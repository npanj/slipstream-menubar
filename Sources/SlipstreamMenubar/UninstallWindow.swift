import AppKit
import ServiceManagement
import SlipstreamMenubarCore
import SwiftUI

/// "Uninstall and Cleanup": removes the Slipstream releases and their command, Slipstream's
/// data, the app's settings, logs and Keychain item, the chosen models, and the app itself.
@MainActor
final class UninstallWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let server: ServerController

    init(server: ServerController) {
        self.server = server
    }

    func show() {
        let items = Cleanup.allItems(models: server.config.availableModels, configuredModel: server.config.model,
                                     appBundle: Bundle.main.bundleURL)
        let model = UninstallModel(items: items)
        let view = UninstallView(model: model,
                                 uninstall: { [weak self] in self?.confirmAndRun(model) },
                                 cancel: { [weak self] in self?.window?.close() })
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Uninstall and Cleanup"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.measure()
    }

    private func confirmAndRun(_ model: UninstallModel) {
        let chosen = model.items.filter { !$0.isModel || model.keepModels[$0.id] != true }
        let alert = NSAlert()
        alert.messageText = "Remove Slipstream from this Mac?"
        alert.informativeText = "This deletes \(chosen.count) items, \(ByteCountFormatter.string(fromByteCount: model.size(of: chosen), countStyle: .file)) "
            + "in total, stops the server, and quits the app. It cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await run(chosen) }
    }

    private func run(_ items: [CleanupItem]) async {
        await server.stopAndWait()
        var failures: [String] = []
        for item in items where item.kind != .app {
            do { try Cleanup.remove(item) } catch { failures.append("\(item.title): \(error.localizedDescription)") }
        }
        // What the app keeps outside its folders.
        APIKeyStore.save(nil)
        try? await SMAppService.mainApp.unregister()
        if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
        UserDefaults.standard.removePersistentDomain(forName: "SlipstreamMenubar")  // unbundled test runs

        var trashed = false
        if let app = items.first(where: { $0.kind == .app }) {
            do {
                try await NSWorkspace.shared.recycle([app.url])
                trashed = true
            } catch {
                failures.append("\(app.title): \(error.localizedDescription)")
            }
        }
        let done = NSAlert()
        done.messageText = failures.isEmpty ? "Slipstream was removed" : "Slipstream was removed, with problems"
        done.informativeText = (failures.isEmpty ? "" : failures.joined(separator: "\n") + "\n\n")
            + (trashed ? "Slipstream is in the Trash. " : "")
            + "Homebrew and hf were left installed; remove hf with `brew uninstall hf` if you no longer need it."
        done.runModal()
        NSApp.terminate(nil)
    }
}

/// The items, their sizes, and which models to keep.
@MainActor
final class UninstallModel: ObservableObject {
    let items: [CleanupItem]
    @Published var sizes: [String: Int64] = [:]
    @Published var keepModels: [String: Bool] = [:]

    init(items: [CleanupItem]) {
        self.items = items
    }

    func measure() {
        for item in items {
            Task.detached {
                let size = ModelPresence.allocatedSize(of: item.url)
                await MainActor.run { self.sizes[item.id] = size }
            }
        }
    }

    func size(of items: [CleanupItem]) -> Int64 {
        items.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
    }
}

private struct UninstallView: View {
    @ObservedObject var model: UninstallModel
    let uninstall: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uninstall and Cleanup").font(.headline)
            Text("Stops the server and removes these. Untick a model to keep it.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            if item.isModel {
                                Toggle(isOn: Binding(get: { model.keepModels[item.id] != true },
                                                     set: { model.keepModels[item.id] = !$0 })) {
                                    row(item)
                                }
                            } else {
                                Image(systemName: "checkmark").foregroundStyle(.secondary).frame(width: 14)
                                row(item)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            Text("Not removed: Homebrew and hf, Hugging Face's cache in ~/.cache/huggingface, and any "
                 + "Slipstream source checkout.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                let chosen = model.items.filter { !$0.isModel || model.keepModels[$0.id] != true }
                Text("\(ByteCountFormatter.string(fromByteCount: model.size(of: chosen), countStyle: .file)) to free")
                    .font(.caption).monospacedDigit()
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Uninstall…", role: .destructive, action: uninstall)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func row(_ item: CleanupItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(item.title)
                Spacer()
                Text(model.sizes[item.id].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text((item.url.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
