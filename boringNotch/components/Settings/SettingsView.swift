//
//  SettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import Sparkle
import SwiftUI

struct SettingsView: View {
    let updaterController: SPUStandardUpdaterController?

    @Default(.menubarIcon) var menubarIcon
    @Default(.showOnAllDisplays) var showOnAllDisplays
    @Default(.openNotchOnHover) var openNotchOnHover
    @Default(.minimumHoverDuration) var minimumHoverDuration
    @Default(.enableHaptics) var enableHaptics
    @Default(.focusAccent) var focusAccent
    @Default(.showRemainingMinutes) var showRemainingMinutes
    @Default(.longBreaksEnabled) var longBreaksEnabled
    @Default(.idleAutoPauseEnabled) var idleAutoPauseEnabled
    @Default(.autoDNDEnabled) var autoDNDEnabled
    @Default(.blockedBundleIDs) var blockedBundleIDs
    @Default(.blockedDomains) var blockedDomains

    @State private var newDomain: String = ""

    var body: some View {
        Form {
            Section("General") {
                LaunchAtLogin.Toggle("Launch at login")
                Toggle("Menu bar icon", isOn: $menubarIcon)
                Toggle("Show on all displays", isOn: $showOnAllDisplays)
                    .onChange(of: showOnAllDisplays) {
                        NotificationCenter.default.post(name: Notification.Name.showOnAllDisplaysChanged, object: nil)
                    }
            }

            Section("Behavior") {
                Toggle("Open island on hover", isOn: $openNotchOnHover)
                Toggle("Haptic feedback", isOn: $enableHaptics)
                Slider(value: $minimumHoverDuration, in: 0...1, step: 0.1) {
                    Text("Hover delay: \(minimumHoverDuration, specifier: "%.1f")s")
                }
            }

            Section("Focus") {
                Picker("Accent", selection: $focusAccent) {
                    ForEach(FocusAccent.allCases) { accent in
                        Text(accent.displayName).tag(accent)
                    }
                }
                Toggle("Remaining minutes on the island", isOn: $showRemainingMinutes)
                Toggle("Long break every 4th cycle", isOn: $longBreaksEnabled)
                Toggle("Pause when idle for 5 minutes", isOn: $idleAutoPauseEnabled)
                Toggle("Enable Focus mode during sessions", isOn: $autoDNDEnabled)
                KeyboardShortcuts.Recorder("Start / pause session", name: .toggleFocusSession)
            }

            Section("Blocked apps") {
                ForEach(blockedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(appDisplayName(for: bundleID))
                        Spacer()
                        Button(role: .destructive) {
                            blockedBundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Add app…") { pickApp() }
            }

            Section("Blocked websites") {
                ForEach(blockedDomains, id: \.self) { domain in
                    HStack {
                        Text(domain)
                        Spacer()
                        Button(role: .destructive) {
                            blockedDomains.removeAll { $0 == domain }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("example.com", text: $newDomain)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addDomain() }
                    Button("Add") { addDomain() }
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Updates") {
                if let updaterController {
                    CheckForUpdatesView(updater: updaterController.updater)
                }
                Text("Version \(appVersion)")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 360)
    }

    private func addDomain() {
        let domain = newDomain
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        guard !domain.isEmpty, !blockedDomains.contains(domain) else { return }
        blockedDomains.append(domain)
        newDomain = ""
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let bundleID = Bundle(url: url)?.bundleIdentifier,
                   !Defaults[.blockedBundleIDs].contains(bundleID) {
                    Defaults[.blockedBundleIDs].append(bundleID)
                }
            }
        }
    }

    private func appDisplayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }
}
