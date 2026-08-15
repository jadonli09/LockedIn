//
//  FocusPanelView.swift
//  boringNotch
//
//  The expanded island: one panel, one row.
//  Left — play/pause circle. Center — remaining time + phase label, with a
//  5-second hold-to-confirm ring to end early and preset cycling when idle.
//  Right — sound toggle and Now Playing title (only when media is active).
//  No second row. No tabs.
//

import Defaults
import SwiftUI

struct FocusPanelView: View {
    @ObservedObject var focus = FocusSessionManager.shared
    @ObservedObject var music = MusicManager.shared
    @ObservedObject var sound = FocusSoundManager.shared
    @Default(.lastFocusPreset) var lastPreset
    @Default(.focusSoundVolume) var soundVolume

    @State private var holdProgress: CGFloat = 0
    @State private var isHolding = false

    var body: some View {
        HStack(spacing: 0) {
            playPauseButton
                .frame(maxWidth: .infinity, alignment: .leading)

            centerTimer

            rightColumn
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Left: session play/pause

    private var playPauseButton: some View {
        Button {
            focus.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 44, height: 44)
                Image(systemName: focus.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Center: time + label + hold-to-end ring

    private var centerTimer: some View {
        VStack(spacing: 2) {
            Text(focus.hasSession ? focus.remainingTimeText : idlePresetText)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.spring(response: 0.42, dampingFraction: 0.8), value: focus.remainingTimeText)

            Text(focus.hasSession ? focus.phaseLabel.uppercased() : "READY")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .overlay {
            if isHolding {
                Circle()
                    .trim(from: 0, to: holdProgress)
                    .stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 74, height: 74)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !focus.hasSession else { return }
            cyclePreset()
        }
        .onLongPressGesture(minimumDuration: 5.0) {
            guard focus.hasSession else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
                focus.endSession()
            }
            isHolding = false
            holdProgress = 0
        } onPressingChanged: { pressing in
            guard focus.hasSession else { return }
            if pressing {
                isHolding = true
                holdProgress = 0
                withAnimation(.linear(duration: 5.0)) {
                    holdProgress = 1
                }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                    isHolding = false
                    holdProgress = 0
                }
            }
        }
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

    // MARK: - Right: sound toggle + Now Playing

    private var rightColumn: some View {
        HStack(spacing: 10) {
            if sound.isPlaying {
                Slider(value: Binding(
                    get: { soundVolume },
                    set: { sound.volume = $0 }
                ), in: 0...1)
                .controlSize(.mini)
                .tint(.white.opacity(0.5))
                .frame(width: 56)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }

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

            if music.isPlaying || !music.isPlayerIdle {
                MarqueeText(text: music.songTitle)
                    .frame(width: 78, height: 16)

                Button {
                    music.playPause()
                } label: {
                    Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
