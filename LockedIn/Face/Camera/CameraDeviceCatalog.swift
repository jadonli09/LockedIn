//
//  CameraDeviceCatalog.swift
//  LockedIn
//
//  Lists available cameras and resolves the Settings preference into a device.
//
//  Adapted from Glance (github.com/jonnyoo/glance, MIT).
//

import AVFoundation
import Defaults

struct CameraDevice: Identifiable, Hashable {
    let id: String // AVCaptureDevice.uniqueID
    let name: String
}

enum CameraDeviceCatalog {
    static func availableDevices() -> [CameraDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The chosen camera if it's connected, else the built-in one, else anything.
    static func resolvedDevice() -> AVCaptureDevice? {
        if let preferredID = Defaults[.faceCameraID], let device = AVCaptureDevice(uniqueID: preferredID) {
            return device
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
    }
}
