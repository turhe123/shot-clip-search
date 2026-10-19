import ServiceManagement
import SwiftUI

/// Settings window: retention, storage cap, recognition language, launch at login, hotkey and support.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("retentionDays") private var retentionDays = 30
    @AppStorage("maxImages") private var maxImages = 500
    @AppStorage("ocrLanguage") private var ocrLanguage = "auto"
    @AppStorage("hotkeyEnabled") private var hotkeyEnabled = true
    @AppStorage("hotkeyKey") private var hotkeyKey = "V"
    @AppStorage("hotkeyCmd") private var hotkeyCmd = true
    @AppStorage("hotkeyShift") private var hotkeyShift = true
    @AppStorage("hotkeyOption") private var hotkeyOption = false
    @AppStorage("hotkeyControl") private var hotkeyControl = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var hotkeyError: String?

    private let languages = TextRecognizer.supportedLanguages

    var body: some View {
        Form {
            Section("Storage") {
                Picker("Keep images for", selection: $retentionDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }
                Stepper(value: $maxImages, in: 50...1000, step: 50) {
                    Text("Maximum stored images: \(maxImages)")
                }
                Text("Pinned images never expire and don't count toward removal.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Text Recognition") {
                Picker("Language", selection: $ocrLanguage) {
                    Text("Automatic").tag("auto")
                    ForEach(languages, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                Text("Recognition runs entirely on this Mac. Images over 40 megapixels are stored but not indexed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Global shortcut opens the gallery", isOn: $hotkeyEnabled)
                HStack {
                    Toggle("⌘", isOn: $hotkeyCmd)
                    Toggle("⇧", isOn: $hotkeyShift)
                    Toggle("⌥", isOn: $hotkeyOption)
                    Toggle("⌃", isOn: $hotkeyControl)
                    Picker("", selection: $hotkeyKey) {
                        ForEach(HotKey.keyCodes.keys.sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 70)
                }
                .disabled(!hotkeyEnabled)
                if let hotkeyError {
                    Text(hotkeyError).font(.caption).foregroundStyle(.red)
                }
                Text("Only the clipboard is read — no Screen Recording or Accessibility permission is needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("ShotClipSearch is free and open source.")
                    Spacer()
                    Button("Support / Donate ❤️") { AppState.openDonate() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: retentionDays) { state.enforceRetention() }
        .onChange(of: maxImages) { state.enforceRetention() }
        .onChange(of: hotkeyEnabled) { updateHotKey() }
        .onChange(of: hotkeyKey) { updateHotKey() }
        .onChange(of: hotkeyCmd) { updateHotKey() }
        .onChange(of: hotkeyShift) { updateHotKey() }
        .onChange(of: hotkeyOption) { updateHotKey() }
        .onChange(of: hotkeyControl) { updateHotKey() }
    }

    private func updateHotKey() {
        if hotkeyEnabled && !(hotkeyCmd || hotkeyShift || hotkeyOption || hotkeyControl) {
            hotkeyError = "Pick at least one modifier key."
        } else if !HotKey.shared.registerFromDefaults() {
            hotkeyError = "That shortcut is already used by another app."
        } else {
            hotkeyError = nil
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't update login item: \(error.localizedDescription). You can manage it in System Settings › General › Login Items."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
