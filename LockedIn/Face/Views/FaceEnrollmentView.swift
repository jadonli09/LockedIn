//
//  FaceEnrollmentView.swift
//  LockedIn
//
//  The guided-enrollment window content: circular mirrored preview inside the
//  tick ring, one instruction line, a quiet progress readout. Black, rounded
//  type, the one accent — the island's language in a window.
//

import AppKit
import Defaults
import SwiftUI

struct FaceEnrollmentView: View {
    @ObservedObject var controller: FaceEnrollmentController
    @ObservedObject private var camera = CameraManager.shared
    @Default(.focusAccent) private var accent
    let onClose: () -> Void

    private let previewDiameter: CGFloat = 200
    private let ringDiameter: CGFloat = 236

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 4) {
                Text(controller.stage == .done ? "You're enrolled" : "Enroll your face")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text(controller.instruction)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(height: 30)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: controller.instruction)
            }

            ZStack {
                EnrollmentRingView(controller: controller, diameter: ringDiameter, accent: accent.color)

                if controller.stage == .done {
                    Circle()
                        .fill(accent.color.opacity(0.12))
                        .frame(width: previewDiameter, height: previewDiameter)
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(accent.color)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else if case .failed = controller.stage {
                    Circle()
                        .fill(.white.opacity(0.06))
                        .frame(width: previewDiameter, height: previewDiameter)
                    Image(systemName: "camera.slash")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    CameraPreviewView(session: camera.session)
                        .frame(width: previewDiameter, height: previewDiameter)
                        .clipShape(Circle())
                        .overlay(
                            Circle().stroke(.white.opacity(controller.faceDetected ? 0.18 : 0.06), lineWidth: 1)
                        )
                        .opacity(controller.stage == .saving ? 0.4 : 1)
                }
            }
            .frame(width: ringDiameter + 40, height: ringDiameter + 40)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: controller.stage)

            HStack {
                if controller.stage == .capturing {
                    Text("\(controller.capturedSamples) of \(controller.totalSamples)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: controller.capturedSamples)
                }
                Spacer()
                Button(controller.stage == .done ? "Done" : "Cancel") {
                    onClose()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.1)))
                .keyboardShortcut(controller.stage == .done ? .defaultAction : .cancelAction)
            }
            .padding(.horizontal, 4)
        }
        .padding(28)
        .frame(width: 380)
        .background(.black)
        .preferredColorScheme(.dark)
        .onChange(of: controller.stage) { _, stage in
            guard stage == .done else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                onClose()
            }
        }
    }
}

/// Floating black panel that hosts the enrollment. One at a time; closing
/// it (any path) releases the camera lease.
@MainActor
final class FaceEnrollmentWindowController: NSWindowController, NSWindowDelegate {
    static let shared = FaceEnrollmentWindowController()

    private var controller: FaceEnrollmentController?
    private var completion: ((Bool) -> Void)?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.backgroundColor = .black
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isPresenting: Bool { controller != nil }

    /// Starts a fresh enrollment (replacing any existing one on success).
    func present(completion: ((Bool) -> Void)? = nil) {
        if let controller {
            controller.cancel()
        }
        let controller = FaceEnrollmentController()
        self.controller = controller
        self.completion = completion

        window?.contentView = NSHostingView(rootView: FaceEnrollmentView(controller: controller) { [weak self] in
            self?.close()
        })
        window?.setContentSize(NSSize(width: 380, height: 460))
        window?.center()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        controller.start()
    }

    override func close() {
        super.close()
        finish()
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }

    private func finish() {
        guard let controller else { return }
        let succeeded = controller.stage == .done
        controller.cancel()
        self.controller = nil
        window?.contentView = nil
        completion?(succeeded)
        completion = nil
        // Hand focus back the way the Settings window does.
        if SettingsWindowController.shared.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
