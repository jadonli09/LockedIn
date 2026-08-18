//
//  FocusPanelView.swift
//  boringNotch
//
//  The expanded island: one panel, one row.
//  Left — session control: hold 5s to pause (pausing unlocks distractions,
//  so it costs friction); tap to start / resume. While paused, a second
//  low-friction control appears: tap to reset the phase to full time (a
//  reset only ever adds focus). Center — remaining time + phase label,
//  display only; long-press 5s to end the session. Right — blocker shield,
//  sound toggle, and Now Playing with the album art washed softly into the
//  panel's edge (only when media is active). No second row. No tabs.
//

import Defaults
import SwiftUI

struct FocusPanelView: View {
    @ObservedObject var focus = FocusSessionManager.shared
    @ObservedObject var music = MusicManager.shared
    @ObservedObject var sound = FocusSoundManager.shared
    @ObservedObject var passCenter = PassCenter.shared
    @Default(.lastFocusPreset) var lastPreset
    @Default(.focusSoundVolume) var soundVolume
    @Default(.lastFocusSound) var lastSound

    @State private var endHoldProgress: CGFloat = 0
    @State private var isHoldingEnd = false
    @State private var pauseHoldProgress: CGFloat = 0
    @State private var isHoldingPause = false
    @State private var showBlockControls = false

    private var mediaActive: Bool { music.isPlaying || !music.isPlayerIdle }

    private var onBreak: Bool { focus.hasSession && !focus.isFocusPhase }

    var body: some View {
        ZStack {
            if mediaActive && !onBreak {
                AlbumArtVignette(image: music.albumArt)
                    .transition(.opacity)
            }

            HStack(spacing: 0) {
                sessionControls

                Spacer(minLength: 14)

                if onBreak {
                    breakScreen
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    // Media (when playing) takes the left-center over its own
                    // art and pushes the timer right; otherwise the timer sits
                    // centered.
                    if mediaActive {
                        nowPlaying
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                        Spacer(minLength: 16)
                    }
                    centerTimer
                }

                Spacer(minLength: 12)

                rightColumn
            }
            .padding(.horizontal, 18)
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: mediaActive)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: focus.isPaused)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: focus.hasSession)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: onBreak)
    }

    // MARK: - Break screen: quiet nudge + countdown + skip

    private var breakScreen: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(breakNudge)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Text("BREAK · \(focus.remainingTimeText)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .kerning(1.2)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.4))
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.42, dampingFraction: 0.8), value: focus.remainingTimeText)
            }

            Button {
                focus.skipBreak()
            } label: {
                Text("Skip break")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Start the next focus phase now")
        }
    }

    /// Rotates per break so it doesn't go stale, seeded by the break count.
    private var breakNudge: String {
        let nudges = [
            "Stand up. Look far away.",
            "Water, then a window.",
            "Shoulders down. Slow breath.",
            "Eyes off the screen for a bit.",
            "Walk to another room and back.",
        ]
        let index = focus.state?.completedFocusCount ?? 0
        return nudges[index % nudges.count]
    }

    // MARK: - Left: pause (hold) / play (tap), plus reset while paused

    private var sessionControls: some View {
        HStack(spacing: 10) {
            playPauseControl

            if focus.hasSession && focus.isPaused {
                Button {
                    focus.resetPhase()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.08))
                            .frame(width: 34, height: 34)
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
                .help("Reset to \(lastPreset.focusMinutes):00")
                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            }
        }
    }

    /// Running → hold 5s to pause (ring fills). Idle/paused → tap to start/resume.
    private var playPauseControl: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: 44, height: 44)

            if isHoldingPause {
                Circle()
                    .trim(from: 0, to: pauseHoldProgress)
                    .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 44, height: 44)
            }

            Image(systemName: focus.isRunning ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.symbolEffect(.replace))
        }
        .contentShape(Circle())
        .onTapGesture {
            // Tap only starts or resumes — pausing requires the hold.
            guard !focus.isRunning else { return }
            focus.toggle()
        }
        .onLongPressGesture(minimumDuration: 5.0) {
            guard focus.isRunning else { return }
            focus.pause()
            isHoldingPause = false
            pauseHoldProgress = 0
        } onPressingChanged: { pressing in
            guard focus.isRunning else { return }
            if pressing {
                isHoldingPause = true
                pauseHoldProgress = 0
                withAnimation(.linear(duration: 5.0)) {
                    pauseHoldProgress = 1
                }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                    isHoldingPause = false
                    pauseHoldProgress = 0
                }
            }
        }
        .help(focus.isRunning ? "Hold 5s to pause" : (focus.hasSession ? "Resume" : "Start"))
    }

    // MARK: - Center: time + label (display only), hold 5s to end

    private var centerTimer: some View {
        VStack(spacing: 2) {
            Text(focus.hasSession ? focus.remainingTimeText : idlePresetText)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.spring(response: 0.42, dampingFraction: 0.8), value: focus.remainingTimeText)

            Text(centerLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .overlay {
            if isHoldingEnd {
                Circle()
                    .trim(from: 0, to: endHoldProgress)
                    .stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 74, height: 74)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Idle only: cycle presets. During a session the time is display-only.
            guard !focus.hasSession else { return }
            cyclePreset()
        }
        .onLongPressGesture(minimumDuration: 5.0) {
            guard focus.hasSession else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
                focus.endSession()
            }
            isHoldingEnd = false
            endHoldProgress = 0
        } onPressingChanged: { pressing in
            guard focus.hasSession else { return }
            if pressing {
                isHoldingEnd = true
                endHoldProgress = 0
                withAnimation(.linear(duration: 5.0)) {
                    endHoldProgress = 1
                }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                    isHoldingEnd = false
                    endHoldProgress = 0
                }
            }
        }
    }

    private var centerLabel: String {
        guard focus.hasSession else { return "READY" }
        return focus.isPaused ? "PAUSED" : focus.phaseLabel.uppercased()
    }

    private var idlePresetText: String {
        String(format: "%02d:00", lastPreset.focusMinutes)
    }

    private func cyclePreset() {
        let presets = FocusPreset.islandPresets
        let index = presets.firstIndex(of: lastPreset) ?? 0
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            lastPreset = presets[(index + 1) % presets.count]
        }
    }

    // MARK: - Right: passes, shield, sound, Now Playing

    private var rightColumn: some View {
        HStack(spacing: 10) {
            if let pass = passCenter.soonest {
                passChip(pass)
            }

            blockControlButton

            if sound.isPlaying {
                Slider(value: Binding(
                    get: { soundVolume },
                    set: { sound.volume = $0 }
                ), in: 0...1)
                .controlSize(.mini)
                .tint(.white.opacity(0.5))
                .frame(width: 52)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }

            soundButton

            if !mediaActive {
                resumeMusicButton
            }
        }
    }

    /// Nothing playing: one quiet note. Tap → the media source resumes
    /// whatever it last had queued (launching the app if needed), so music can
    /// start from the island without opening the player.
    private var resumeMusicButton: some View {
        Button {
            music.play()
            // Ask the controller to refresh sooner than its next poll.
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                music.forceUpdate()
            }
        } label: {
            Image(systemName: "music.note")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .buttonStyle(.plain)
        .help("Play music (\(Defaults[.mediaController].rawValue))")
        .transition(.opacity)
    }

    /// Track title + artist over the art vignette, with play/pause. The art
    /// itself is the vignette behind, so no thumbnail here.
    private var nowPlaying: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: music.songTitle, font: .system(size: 12, weight: .semibold, design: .rounded), color: .white.opacity(0.9))
                    .frame(width: 118, height: 15)
                    .id(music.songTitle)
                Text(music.artistName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .frame(width: 118, alignment: .leading)
            }

            Button {
                music.playPause()
            } label: {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
        }
    }

    /// Active 2-min pass: countdown + one tap to cancel it early.
    private func passChip(_ pass: ActivePass) -> some View {
        Button {
            passCenter.cancel(id: pass.id)
        } label: {
            HStack(spacing: 4) {
                Text(passCountdown(pass))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Cancel the 2-min pass for \(pass.name)")
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private func passCountdown(_ pass: ActivePass) -> String {
        let total = Int(pass.remaining(at: passCenter.now).rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var blockControlButton: some View {
        Button {
            showBlockControls.toggle()
        } label: {
            Image(systemName: "shield")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(showBlockControls ? 0.9 : 0.4))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showBlockControls, arrowEdge: .bottom) {
            BlockControlView()
                .onAppear { PanelInteractionState.shared.holdOpen = true }
                .onDisappear { PanelInteractionState.shared.holdOpen = false }
        }
    }

    private var soundButton: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                sound.toggle()
            }
        } label: {
            Image(systemName: "water.waves")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(sound.isPlaying ? 0.9 : 0.4))
                .symbolEffect(.variableColor.iterative, isActive: sound.isPlaying)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(FocusSound.allCases) { choice in
                Button {
                    sound.select(choice)
                } label: {
                    if choice == lastSound {
                        Label(choice.displayName, systemImage: "checkmark")
                    } else {
                        Text(choice.displayName)
                    }
                }
            }
        }
        .help("Click to toggle; right-click to pick a sound")
    }
}

/// The album cover itself, dissolving into the island on all four sides —
/// long ease in from the left, soft top and bottom, gentle release on the
/// right before the timer — so the art is *in* the island under the track
/// info, never a block.
private struct AlbumArtVignette: View {
    let image: NSImage

    var body: some View {
        GeometryReader { geo in
            let zoneWidth = geo.size.width * 0.54
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: zoneWidth, height: geo.size.height)
                .clipped()
                .opacity(0.42)
                .mask(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.1), location: 0.2),
                        .init(color: .black.opacity(0.5), location: 0.42),
                        .init(color: .black, location: 0.6),
                        .init(color: .black, location: 0.8),
                        .init(color: .black.opacity(0.35), location: 0.93),
                        .init(color: .clear, location: 1.0),
                    ], startPoint: .leading, endPoint: .trailing)
                )
                .mask(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.32),
                        .init(color: .black, location: 0.68),
                        .init(color: .clear, location: 1.0),
                    ], startPoint: .top, endPoint: .bottom)
                )
                .position(x: geo.size.width * 0.36, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
    }
}
