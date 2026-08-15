//
//  FocusSoundManager.swift
//  boringNotch
//
//  Ambient focus sounds: seamless loops, 400ms fades, auto-duck under system
//  media, session-scoped (ending a session fades the sound out).
//

import Combine
import Defaults
import SwiftUI

enum FocusSound: String, CaseIterable, Identifiable, Defaults.Serializable {
    case brownNoise
    case rain
    case ocean

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .brownNoise: "Brown Noise"
        case .rain: "Rain"
        case .ocean: "Ocean"
        }
    }

    var resourceName: String {
        switch self {
        case .brownNoise: "brownnoise"
        case .rain: "rain"
        case .ocean: "ocean"
        }
    }
}

extension Defaults.Keys {
    static let lastFocusSound = Key<FocusSound>("lastFocusSound", default: .brownNoise)
    static let focusSoundVolume = Key<Double>("focusSoundVolume", default: 0.6)
}

@MainActor
final class FocusSoundManager: ObservableObject {
    static let shared = FocusSoundManager()

    @Published private(set) var isPlaying = false
    /// True when system media interrupted the sound and it should come back.
    private var ducked = false

    private let player = LoopingSoundPlayer()
    private var cancellables: Set<AnyCancellable> = []

    var volume: Double {
        get { Defaults[.focusSoundVolume] }
        set {
            Defaults[.focusSoundVolume] = newValue
            player.setVolume(Float(newValue))
        }
    }

    private init() {
        // Auto-duck: pause under system Now Playing, resume when it stops.
        MusicManager.shared.$isPlaying
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mediaPlaying in
                guard let self else { return }
                if mediaPlaying, self.isPlaying {
                    self.player.stop()
                    self.isPlaying = false
                    self.ducked = true
                } else if !mediaPlaying, self.ducked {
                    self.ducked = false
                    self.start()
                }
            }
            .store(in: &cancellables)

        // Session-scoped: ending the session fades the sound out.
        NotificationCenter.default.addObserver(
            forName: .focusSessionDidEnd, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                FocusSoundManager.shared.stop()
            }
        }
    }

    func toggle() {
        isPlaying ? stop() : start()
    }

    /// Picks a sound (from the wave button's context menu); if one is already
    /// playing, crossfades straight into the new choice.
    func select(_ choice: FocusSound) {
        Defaults[.lastFocusSound] = choice
        if isPlaying {
            start()
        }
    }

    func start() {
        guard !MusicManager.shared.isPlaying else { return }
        player.play(resource: Defaults[.lastFocusSound].resourceName, volume: Float(volume))
        isPlaying = true
    }

    func stop() {
        player.stop()
        isPlaying = false
        ducked = false
    }
}
