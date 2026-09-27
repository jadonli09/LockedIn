//
//  ContentView.swift
//  LockedIn
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import Combine
import Defaults
import SwiftUI

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: IslandViewModel
    @ObservedObject var coordinator = IslandCoordinator.shared
    @ObservedObject var focus = FocusSessionManager.shared
    @ObservedObject var passCenter = PassCenter.shared
    @ObservedObject var interaction = PanelInteractionState.shared
    @ObservedObject var faceUnlock = FaceUnlockCoordinator.shared
    @ObservedObject var identityGate = IdentityGate.shared
    @ObservedObject var camera = CameraManager.shared
    @Default(.focusAccent) var accent
    @Default(.showRemainingMinutes) var showRemainingMinutes

    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false
    @State private var pulseOpacity: Double = 0

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    /// A face presentation (lock-screen unlock or identity gate) grows the
    /// closed island into the Dynamic-Island-style Face ID card.
    private var faceExpanded: Bool {
        vm.notchState == .closed && (faceUnlock.phase.isPresenting || identityGate.phase != .idle)
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: faceExpanded
                ? FaceIsland.bottomCornerRadius
                : ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()

        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .overlay {
                        currentNotchShape
                            .stroke(accent.color, lineWidth: 2)
                            .blur(radius: 1.5)
                            .opacity(pulseOpacity)
                            .allowsHitTesting(false)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )

                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil)
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(FaceIsland.spring, value: faceExpanded)
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: focus.endPulse) { _, _ in
                        pulseOpacity = 0.85
                        withAnimation(.easeOut(duration: 0.5)) {
                            pulseOpacity = 0
                        }
                    }
                    .onChange(of: interaction.holdOpen) { _, holding in
                        // When the blocklist popover closes with the cursor
                        // already elsewhere, finish the deferred island close.
                        if !holding && !isHovering && vm.notchState == .open {
                            vm.close()
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        Divider()
                        Button("Quit LockedIn", role: .destructive) {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: vm.closedNotchSize.width, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    LockInAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: openNotchSize.width - 96,
                        height: 96
                    )
                    .padding(.top, 24)
                    Spacer()
                } else if vm.notchState == .open {
                    Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: max(24, vm.effectiveClosedNotchHeight))
                } else if faceExpanded {
                    FaceClosedContent(
                        notchWidth: vm.closedNotchSize.width,
                        notchHeight: max(24, vm.effectiveClosedNotchHeight)
                    )
                } else if !vm.hideOnClosed,
                          (focus.hasSession && showRemainingMinutes) || focus.transientEvent != nil || passCenter.soonest != nil || camera.isRunning {
                    FocusClosedContent(
                        notchWidth: vm.closedNotchSize.width,
                        notchHeight: vm.effectiveClosedNotchHeight
                    )
                } else {
                    Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                }
            }
            .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    FocusPanelView()
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
    }

    private func doOpen() {
        if faceUnlock.isScreenLocked { return }
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        // On the lock screen the island only ever shows the scan state.
        if faceUnlock.isScreenLocked { return }
        hoverTask?.cancel()

        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }

            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }

            guard vm.notchState == .closed,
                  Defaults[.openNotchOnHover] else { return }

            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering else { return }

                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }

                    if self.vm.notchState == .open && !PanelInteractionState.shared.holdOpen {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            gestureProgress = .zero
            vm.close()

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

#Preview {
    let vm = IslandViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
