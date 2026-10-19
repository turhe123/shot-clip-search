import AppKit
import SwiftUI

extension Notification.Name {
    static let showGallery = Notification.Name("ShotClipSearch.showGallery")
}

/// Wires the pasteboard watcher, store, recognizer, retention timer and global hotkey together.
@MainActor
final class AppState: ObservableObject {
    let store = ClipStore()
    let watcher = PasteboardWatcher()
    private lazy var recognizer = TextRecognizer(store: store)
    private var retentionTimer: Timer?

    init() {
        UserDefaults.standard.register(defaults: [
            "retentionDays": 30, "maxImages": 500, "ocrLanguage": "auto", "gridSize": 180.0,
            "hotkeyEnabled": true, "hotkeyKey": "V", "hotkeyCmd": true, "hotkeyShift": true,
        ])
        enforceRetention()
        // Resume recognition for anything still pending from a previous session (newest first wins the cap).
        for entry in store.entries.reversed() where entry.ocr == .pending { recognizer.enqueue(entry) }

        watcher.isCapturing = store.diskError == nil
        watcher.onImage = { [weak self] data, ext, app in self?.capture(data: data, ext: ext, app: app) }
        watcher.start()

        retentionTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enforceRetention() }
        }
        HotKey.shared.action = { NotificationCenter.default.post(name: .showGallery, object: nil) }
        HotKey.shared.registerFromDefaults()
    }

    private func capture(data: Data, ext: String, app: String?) {
        guard let entry = store.add(data: data, fileExtension: ext, sourceApp: app) else {
            if store.diskError != nil { watcher.isCapturing = false }
            return
        }
        recognizer.enqueue(entry)
        enforceRetention()
    }

    func enforceRetention() {
        let d = UserDefaults.standard
        store.enforceRetention(days: d.integer(forKey: "retentionDays"), maxCount: max(50, d.integer(forKey: "maxImages")))
    }

    /// Puts the original image back on the pasteboard without re-capturing it.
    func copyToPasteboard(_ entry: ClipEntry) {
        guard let data = try? Data(contentsOf: store.imageURL(for: entry)) else {
            store.diskError = "The image file for this entry is missing."
            return
        }
        let type: NSPasteboard.PasteboardType = entry.fileExtension == "jpg" ? .init("public.jpeg") : .png
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: type)
        if type != .tiff, let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        watcher.ignoreCurrentChange()
    }

    func resumeCapturing() {
        store.diskError = nil
        watcher.isCapturing = true
    }

    static func openDonate() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
    }
}

/// App entry point: the gallery window, a MenuBarExtra for quick access and the Settings window.
@main
struct ShotClipSearchApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("ShotClipSearch", id: "gallery") {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.store)
                .environmentObject(state.watcher)
        }
        .defaultSize(width: 900, height: 600)

        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(state)
                .environmentObject(state.store)
                .environmentObject(state.watcher)
        } label: {
            MenuBarLabel()
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

/// The always-alive menu bar icon; it also listens for the global hotkey so it can open the gallery.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "photo.on.rectangle.angled")
            .onReceive(NotificationCenter.default.publisher(for: .showGallery)) { _ in
                openWindow(id: "gallery")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

/// Menu shown from the menu bar: recent images, capture toggle, settings, donate and quit.
struct MenuBarMenu: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var watcher: PasteboardWatcher
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Gallery") {
            openWindow(id: "gallery")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        if store.entries.isEmpty {
            Text("No images copied yet")
        } else {
            Text("Recent — click to copy")
            ForEach(store.entries.prefix(5)) { entry in
                Button(entry.firstLine ?? entry.date.formatted(date: .abbreviated, time: .shortened)) {
                    state.copyToPasteboard(entry)
                }
            }
        }
        Divider()
        Toggle("Capture Images", isOn: Binding(
            get: { watcher.isCapturing },
            set: { $0 ? state.resumeCapturing() : (watcher.isCapturing = false) }
        ))
        SettingsLink { Text("Settings…") }
        Button("Support / Donate ❤️") { AppState.openDonate() }
        Divider()
        Button("Quit ShotClipSearch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
