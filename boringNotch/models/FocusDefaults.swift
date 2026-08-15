//
//  FocusDefaults.swift
//  boringNotch
//
//  Defaults wiring for the focus models. Kept separate so FocusModels.swift
//  and BlocklistMatcher.swift stay dependency-free for the unit test target.
//

import Defaults
import Foundation

extension FocusPreset: Defaults.Serializable {}
extension FocusSessionState: Defaults.Serializable {}

extension Defaults.Keys {
    static let focusSessionState = Key<FocusSessionState?>("focusSessionState", default: nil)
    static let lastFocusPreset = Key<FocusPreset>("lastFocusPreset", default: .classic)
    static let longBreaksEnabled = Key<Bool>("longBreaksEnabled", default: true)
    static let showRemainingMinutes = Key<Bool>("showRemainingMinutes", default: true)
}
