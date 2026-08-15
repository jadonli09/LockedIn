//
//  SettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
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
}
