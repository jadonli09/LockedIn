//
//  FaceSettingsSection.swift
//  LockedIn
//
//  The "Face ID" part of Settings: permission + setup status rows, the lock
//  screen unlock switches, presence detection, and identity-gated exits.
//  Everything camera-related is off until switched on here.
//

import AVFoundation
import AppKit
import Defaults
import SwiftUI

/// Async status the section needs from the helper and the system.
@MainActor
final class FaceSetupModel: ObservableObject {
    @Published var accessibilityGranted = false
    @Published var passwordStored = false
    @Published var passwordInput = ""
    @Published var busy = false
    @Published var message: String?

    func refresh() {
        CameraManager.shared.refreshPermission()
        Task {
            accessibilityGranted = await XPCHelperClient.shared.isAccessibilityAuthorized()
            passwordStored = UnlockCredentialStore.exists()
        }
    }

    func requestAccessibility() {
        Task {
            _ = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
            refresh()
        }
    }

    func requestCamera() {
        Task {
            _ = await CameraManager.shared.requestPermission()
            if CameraManager.shared.permission == .denied,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func savePassword() {
        let password = passwordInput
        guard !password.isEmpty else { return }
        passwordInput = ""
        do {
            try UnlockCredentialStore.save(password)
            message = "Password stored in the Keychain."
            passwordStored = true
        } catch {
            message = error.localizedDescription
        }
        FaceUnlockCoordinator.shared.refreshHelperStatus()
    }

    func clearPassword() {
        do {
            try UnlockCredentialStore.delete()
            message = "Password removed."
            passwordStored = false
        } catch {
            message = error.localizedDescription
        }
        FaceUnlockCoordinator.shared.refreshHelperStatus()
    }
}

struct FaceSettingsSection: View {
    @StateObject private var setup = FaceSetupModel()
    @ObservedObject private var store = FaceEnrollmentStore.shared
    @ObservedObject private var gate = IdentityGate.shared
    @ObservedObject private var camera = CameraManager.shared
    @ObservedObject private var unlock = FaceUnlockCoordinator.shared
    @ObservedObject private var presence = PresenceMonitor.shared

    @Default(.faceUnlockEnabled) private var faceUnlockEnabled
    @Default(.faceUnlockOnWake) private var onWake
    @Default(.faceUnlockOnLock) private var onLock
    @Default(.faceLivenessLevel) private var livenessLevel
    @Default(.faceMatchStrictness) private var strictness
    @Default(.faceCameraID) private var cameraID
    @Default(.faceScanSeconds) private var scanSeconds
    @Default(.presenceDetectionEnabled) private var presenceEnabled
    @Default(.presenceAwayThresholdSeconds) private var awayThreshold
    @Default(.requireFaceToEndSession) private var requireFaceToEnd

    @State private var devices: [CameraDevice] = []
    @State private var confirmDelete = false

    private var enrollmentReady: Bool { store.hasEnrollment && !store.isStale }
    private var unlockReady: Bool { enrollmentReady && setup.passwordStored && setup.accessibilityGranted && camera.permission == .granted }

    var body: some View {
        setupSection
        unlockSection
        presenceSection
            .onAppear {
                setup.refresh()
                devices = CameraDeviceCatalog.availableDevices()
            }
    }

    private var setupSection: some View {
        Section("Face ID") {
            statusRow(
                title: "Camera",
                ok: camera.permission == .granted,
                detail: camera.permission == .granted ? "Allowed" : (camera.permission == .denied ? "Denied" : "Not asked yet"),
                action: camera.permission == .granted ? nil : RowAction(label: "Allow…") { setup.requestCamera() }
            )
            statusRow(
                title: "Accessibility (helper)",
                ok: setup.accessibilityGranted,
                detail: setup.accessibilityGranted ? "Granted" : "Needed to type your password on the lock screen",
                action: setup.accessibilityGranted ? nil : RowAction(label: "Grant…") { setup.requestAccessibility() }
            )
            enrollmentRow
            passwordRow

            if let failure = store.loadFailure {
                Text(failure).font(.callout).foregroundStyle(.secondary)
            }
            if FaceRecognitionPipeline.shared.usingFallbackEmbedder {
                Text("The ArcFace model didn't load (\(FaceRecognitionPipeline.shared.fallbackReason ?? "unknown")); recognition is running on Apple's weaker feature print.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var unlockSection: some View {
        Section("Face unlock") {
            Toggle("Unlock the Mac with my face", isOn: $faceUnlockEnabled)
                .onChange(of: faceUnlockEnabled) { FaceUnlockCoordinator.shared.refreshHelperStatus() }
            Toggle("On wake", isOn: $onWake).disabled(!faceUnlockEnabled)
            Toggle("On lock", isOn: $onLock).disabled(!faceUnlockEnabled)
            Picker("Liveness", selection: $livenessLevel) {
                ForEach(LivenessLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            Text(livenessLevel.summary).font(.callout).foregroundStyle(.secondary)
            Picker("Match strictness", selection: $strictness) {
                ForEach(FaceMatchStrictness.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            Picker("Camera", selection: $cameraID) {
                Text("Built-in / default").tag(String?.none)
                ForEach(devices) { device in
                    Text(device.name).tag(String?.some(device.id))
                }
            }
            Stepper("Look for \(scanSeconds)s per attempt", value: $scanSeconds, in: 3...12)
            if faceUnlockEnabled && !unlockReady {
                Text("Face unlock needs camera access, Accessibility for the helper, an enrolled face, and a stored password.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Status: \(unlock.statusMessage)").font(.callout).foregroundStyle(.secondary)
            Text("A photo or a phone held up is rejected; a replayed video may not be. The island shows the scan on the lock screen, and a green dot whenever the camera is on.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var awayThresholdLabel: String {
        if awayThreshold >= 60 {
            let minutes = Double(awayThreshold) / 60
            return minutes == minutes.rounded() ? "Away after \(Int(minutes)) min" : String(format: "Away after %.1f min", minutes)
        }
        return "Away after \(awayThreshold)s"
    }

    private var presenceSection: some View {
        Section("Presence") {
            Toggle("Pause the session when I leave the desk", isOn: $presenceEnabled)
                .disabled(!enrollmentReady)
            Stepper(awayThresholdLabel, value: $awayThreshold, in: 30...600, step: 30)
                .disabled(!presenceEnabled)
            Text(presenceStatus).font(.callout).foregroundStyle(.secondary)
            Toggle("Require my face to end a session early", isOn: $requireFaceToEnd)
                .disabled(!enrollmentReady)
            Text("Ending a session or removing a blocked app mid-session needs a quick face check. If the camera can't see you, a 15-second hold still works.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var presenceStatus: String {
        guard presenceEnabled else { return "Checks the camera every few seconds at ~2 fps during focus periods; away time never counts toward the session." }
        guard presence.isWatching else { return "Idle — starts with the next focus period." }
        switch presence.state {
        case .present: return "Watching — you're here."
        case .unsure: return "Watching — haven't seen you for a moment."
        case .away: return "Away — session paused until you're back."
        }
    }

    // MARK: - Rows

    private struct RowAction {
        let label: String
        let perform: () -> Void
    }

    private func statusRow(title: String, ok: Bool, detail: String, action: RowAction?) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(detail).foregroundStyle(.secondary)
                if let action {
                    Button(action.label, action: action.perform)
                }
            }
        } label: {
            Label(title, systemImage: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.primary : Color.secondary)
        }
    }

    private var enrollmentRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let identity = store.primary {
                    Text(store.isStale ? "Re-enroll needed" : "\(identity.samples.count) samples")
                        .foregroundStyle(.secondary)
                    Button("Try Face ID") {
                        Task { _ = await IdentityGate.shared.verify(force: true) }
                    }
                    .disabled(store.isStale || gate.phase == .verifying)
                    .help("Runs a scan and shows it in the island, like the lock screen does.")
                    Button("Re-enroll") { enroll() }
                    Button("Delete", role: .destructive) { confirmDelete = true }
                } else {
                    Text("Not enrolled").foregroundStyle(.secondary)
                    Button("Enroll…") { enroll() }
                }
            }
        } label: {
            Label(store.primary.map { "Face: \($0.name)" } ?? "Face", systemImage: enrollmentReady ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(enrollmentReady ? Color.primary : Color.secondary)
        }
        .confirmationDialog("Delete the enrolled face?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deleteAll()
                FaceUnlockCoordinator.shared.refreshHelperStatus()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Face unlock, presence detection, and identity-gated exits stop working until you enroll again.")
        }
    }

    private var passwordRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                HStack(spacing: 8) {
                    if setup.passwordStored {
                        Text("Stored in the helper").foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) { setup.clearPassword() }.disabled(setup.busy)
                    } else {
                        SecureField("Mac password", text: $setup.passwordInput)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 180)
                            .onSubmit { setup.savePassword() }
                        Button("Save") { setup.savePassword() }
                            .disabled(setup.busy || setup.passwordInput.isEmpty)
                    }
                }
            } label: {
                Label("Mac password", systemImage: setup.passwordStored ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(setup.passwordStored ? Color.primary : Color.secondary)
            }
            if let message = setup.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Text("Typed into the lock screen by the unsandboxed helper after a match; it's kept in your Keychain and only read after a match.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func enroll() {
        FaceEnrollmentWindowController.shared.present { _ in
            setup.refresh()
            FaceUnlockCoordinator.shared.refreshHelperStatus()
        }
    }
}
