//
//  FaceUnlockDefaults.swift
//  LockedIn
//
//  Every face-related preference in one place. All camera use is opt-in:
//  nothing here defaults to on except the sub-toggles that only matter once
//  the master switch above them is flipped.
//

import Defaults
import Foundation

extension LivenessLevel: Defaults.Serializable {}
extension FaceMatchStrictness: Defaults.Serializable {}

extension Defaults.Keys {
    // MARK: Face unlock (lock screen)
    static let faceUnlockEnabled = Key<Bool>("faceUnlockEnabled", default: false)
    static let faceUnlockOnWake = Key<Bool>("faceUnlockOnWake", default: true)
    static let faceUnlockOnLock = Key<Bool>("faceUnlockOnLock", default: true)
    static let faceLivenessLevel = Key<LivenessLevel>("faceLivenessLevel", default: .light)
    static let faceMatchStrictness = Key<FaceMatchStrictness>("faceMatchStrictness", default: .standard)
    /// AVCaptureDevice.uniqueID; nil = the built-in / system default camera.
    static let faceCameraID = Key<String?>("faceCameraID", default: nil)
    /// How long a lock-screen scan looks for a face before giving up.
    static let faceScanSeconds = Key<Int>("faceScanSeconds", default: 6)

    // MARK: Presence during focus sessions
    static let presenceDetectionEnabled = Key<Bool>("presenceDetectionEnabled", default: false)
    /// Seconds without the enrolled face before the session auto-pauses.
    static let presenceAwayThresholdSeconds = Key<Int>("presenceAwayThresholdSeconds", default: 60)

    // MARK: Identity-gated exits
    static let requireFaceToEndSession = Key<Bool>("requireFaceToEndSession", default: false)
}
