import SwiftUI
import AppKit
import MacshCore

/// Multi-tab Settings window styled after Maccy / Apple's native preferences:
/// toolbar at top with icon+label per tab, flat background (no vibrancy),
/// right-aligned label column inside each tab. We don't use SwiftUI's
/// `Settings` scene because macsh runs as `LSUIElement=true` (no Dock icon,
/// no app menu), so we host this in a regular NSWindow via NSHostingController.
struct SettingsView: View {
    let loginItemManager: LoginItemManager
    let prefs: UserPreferences

    enum Tab: String, CaseIterable, Identifiable {
        case general, rclone, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: return "General"
            case .rclone:  return "rclone"
            case .about:   return "About"
            }
        }
        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .rclone:  return "shippingbox"
            case .about:   return "info.circle"
            }
        }
    }

    @State private var selection: Tab = .general

    var body: some View {
        VStack(spacing: 0) {
            tabbar
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(20)
        }
        .frame(width: 540, height: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tabbar: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(Tab.allCases) { tab in
                TabButton(tab: tab, selected: selection == tab) {
                    selection = tab
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selection {
        case .general: GeneralPane(loginItemManager: loginItemManager, prefs: prefs)
        case .rclone:  RclonePane(prefs: prefs)
        case .about:   AboutPane()
        }
    }
}

// MARK: - Tab button (toolbar-style segmented selector)

private struct TabButton: View {
    let tab: SettingsView.Tab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                Text(tab.label)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
            }
            .frame(width: 64, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General

private struct GeneralPane: View {
    let loginItemManager: LoginItemManager
    let prefs: UserPreferences
    @State private var launchAtLogin: Bool
    @State private var defaultProtocol: MountProtocol

    init(loginItemManager: LoginItemManager, prefs: UserPreferences) {
        self.loginItemManager = loginItemManager
        self.prefs = prefs
        _launchAtLogin = State(initialValue: loginItemManager.isEnabled)
        _defaultProtocol = State(initialValue: prefs.defaultProtocol)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Launch") {
                    Toggle("Launch macsh at login", isOn: $launchAtLogin)
                        .toggleStyle(.checkbox)
                        .onChange(of: launchAtLogin) { _, newValue in
                            do { try loginItemManager.setEnabled(newValue) }
                            catch { launchAtLogin = loginItemManager.isEnabled }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LabeledContent("Default protocol") {
                    Picker("", selection: $defaultProtocol) {
                        Text("WebDAV").tag(MountProtocol.webdav)
                        Text("NFS").tag(MountProtocol.nfs)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    .onChange(of: defaultProtocol) { _, p in prefs.defaultProtocol = p }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - rclone

private struct RclonePane: View {
    let prefs: UserPreferences
    @State private var customRclonePath: String
    @State private var rclonePathStatus: (text: String, ok: Bool)?

    init(prefs: UserPreferences) {
        self.prefs = prefs
        _customRclonePath = State(initialValue: prefs.customRclonePath ?? "")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Custom path") {
                    HStack(spacing: 6) {
                        TextField("", text: $customRclonePath,
                                  prompt: Text("/opt/homebrew/bin/rclone"))
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…", action: pickRclone)
                        Button("Save", action: saveRclonePath)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                if let status = rclonePathStatus {
                    LabeledContent(" ") {
                        Text(status.text)
                            .font(.caption)
                            .foregroundStyle(status.ok ? Color.secondary : Color.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } header: {
                Text("rclone binary")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Leave empty to use the bundled rclone, then Homebrew (`brew install rclone`).")
                    Text("Takes effect after the next launch.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func pickRclone() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            customRclonePath = url.path
            saveRclonePath()
        }
    }

    private func saveRclonePath() {
        let trimmed = customRclonePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            prefs.customRclonePath = nil
            rclonePathStatus = ("Cleared. Will fall back to bundled / Homebrew.", true)
            return
        }
        if !FileManager.default.isExecutableFile(atPath: trimmed) {
            rclonePathStatus = ("Not executable: \(trimmed)", false)
            return
        }
        prefs.customRclonePath = trimmed
        rclonePathStatus = ("Saved.", true)
    }
}

// MARK: - About

private struct AboutPane: View {
    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    var bundleName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "macsh"
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            Text(bundleName)
                .font(.title2.weight(.semibold))
            Text("Version \(version) (\(build))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Link("github.com/AyonPal/macsh",
                 destination: URL(string: "https://github.com/AyonPal/macsh")!)
                .font(.caption)
            Spacer()
            Text("Released under the Apache License 2.0.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
