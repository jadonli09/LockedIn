//
//  SettingsView.swift
//  LockedIn
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

struct SettingsView: View {
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
    @Default(.lastFocusPreset) var lastPreset
    @Default(.mediaController) var mediaController
    @Default(.showSoundControls) var showSoundControls

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
                Stepper(
                    "Focus length: \(lastPreset.focusMinutes) min",
                    value: Binding(
                        get: { lastPreset.focusMinutes },
                        set: { lastPreset.focusMinutes = $0 }
                    ), in: 5...180, step: 5
                )
                Stepper(
                    "Break length: \(lastPreset.breakMinutes) min",
                    value: Binding(
                        get: { lastPreset.breakMinutes },
                        set: { lastPreset.breakMinutes = $0 }
                    ), in: 1...60
                )
                Toggle("Remaining minutes on the island", isOn: $showRemainingMinutes)
                Toggle("Long break every 4th cycle", isOn: $longBreaksEnabled)
                Toggle("Pause when idle for 5 minutes", isOn: $idleAutoPauseEnabled)
                Toggle("Enable Focus mode during sessions", isOn: $autoDNDEnabled)
                KeyboardShortcuts.Recorder("Start / pause session", name: .toggleFocusSession)
                LabeledContent {
                    Button("Open Shortcuts") {
                        NSWorkspace.shared.open(URL(string: "shortcuts://")!)
                    }
                } label: {
                    Text("Auto-Focus needs two Shortcuts named “LockedIn Focus On” and “LockedIn Focus Off”, each with a Set Focus action.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Blocked apps") {
                ForEach(blockedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(appDisplayName(for: bundleID))
                        Spacer()
                        Button(role: .destructive) {
                            IdentityGate.shared.performGated {
                                blockedBundleIDs.removeAll { $0 == bundleID }
                            }
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
                            IdentityGate.shared.performGated {
                                blockedDomains.removeAll { $0 == domain }
                            }
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

            Section("Focus sounds") {
                Toggle("Show sound control in the island", isOn: $showSoundControls)
                Text("Brown noise, rain, and ocean loops. Off keeps the island minimal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            FaceSettingsSection()

            Section("Media") {
                Picker("Source", selection: $mediaController) {
                    ForEach(MediaControllerType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .onChange(of: mediaController) {
                    NotificationCenter.default.post(name: .mediaControllerChanged, object: nil)
                }
                Text("Pick Spotify to show and control Spotify directly in the island; focus sounds duck automatically while it plays.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Text("LockedIn is open source under GPL-3.0, built on the notch engine from boring.notch by TheBoredTeam.")
                    .font(.callout)
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
