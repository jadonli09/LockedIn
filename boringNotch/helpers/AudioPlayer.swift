//
//  AudioPlayer.swift
//  boringNotch
//
//  Gapless loop player with linear fades, used for the focus sounds.
//

import AVFoundation
import Foundation

final class LoopingSoundPlayer {
    private var player: AVAudioPlayer?

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Starts looping `resource` with a 400ms fade-in at the given volume.
    func play(resource: String, volume: Float) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "wav"),
              let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        player?.stop()
        newPlayer.numberOfLoops = -1
        newPlayer.volume = 0
        newPlayer.play()
        newPlayer.setVolume(volume, fadeDuration: 0.4)
        player = newPlayer
    }

    /// 400ms fade-out, then stop.
    func stop() {
        guard let player, player.isPlaying else { return }
        player.setVolume(0, fadeDuration: 0.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak player] in
            player?.stop()
            if self?.player === player { self?.player = nil }
        }
    }

    func setVolume(_ volume: Float) {
        player?.setVolume(volume, fadeDuration: 0.1)
    }
}
