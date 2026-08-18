//
//  BlockControlView.swift
//  LockedIn
//
//  Compact blocklist control, presented as a popover from the island's shield
//  button so blocking never needs the Settings window. Lists blocked apps and
//  websites with add/remove, plus active 2-minute passes with cancel.
//

import Defaults
import SwiftUI

/// Keeps the island open while a popover presented from it has the cursor.
@MainActor
final class PanelInteractionState: ObservableObject {
    static let shared = PanelInteractionState()
    @Published var holdOpen = false
    private init() {}
}

struct BlockControlView: View {
    @ObservedObject var passCenter = PassCenter.shared
    @Default(.blockedBundleIDs) var blockedBundleIDs
    @Default(.blockedDomains) var blockedDomains

    @State private var newDomain = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !passCenter.passes.isEmpty {
                section("Passes") {
                    ForEach(passCenter.passes) { pass in
                        row {
                            Text(pass.name)
                            Spacer()
                            Text(countdown(pass))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.5))
                            removeButton {
                                passCenter.cancel(id: pass.id)
                            }
                        }
                    }
                }
            }

            section("Apps") {
                ForEach(blockedBundleIDs, id: \.self) { bundleID in
                    row {
                        Text(appName(for: bundleID))
                        Spacer()
                        removeButton {
                            blockedBundleIDs.removeAll { $0 == bundleID }
                        }
                    }
                }
                Button {
                    pickApp()
                } label: {
                    Label("Add app", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.55))
            }

            section("Websites") {
                ForEach(blockedDomains, id: \.self) { domain in
                    row {
                        Text(domain)
                        Spacer()
                        removeButton {
                            blockedDomains.removeAll { $0 == domain }
                        }
                    }
                }
                HStack(spacing: 6) {
                    TextField("example.com", text: $newDomain)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
                        .onSubmit { addDomain() }
                    Button("Add") { addDomain() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(newDomain.trimmingCharacters(in: .whitespaces).isEmpty ? 0.25 : 0.7))
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 250)
    }

    // MARK: - Pieces

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .kerning(1.0)
                .foregroundStyle(.white.opacity(0.35))
            content()
        }
    }

    private func row(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
    }

    private func removeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .buttonStyle(.plain)
    }

    private func countdown(_ pass: ActivePass) -> String {
        let total = Int(pass.remaining(at: passCenter.now).rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
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
        PanelInteractionState.shared.holdOpen = true
        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    if let bundleID = Bundle(url: url)?.bundleIdentifier,
                       !Defaults[.blockedBundleIDs].contains(bundleID) {
                        Defaults[.blockedBundleIDs].append(bundleID)
                    }
                }
            }
        }
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }
}
