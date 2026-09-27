//
//  CameraManager.swift
//  LockedIn
//
//  One AVCaptureSession for the whole app, leased by clients (lock-screen
//  scan, presence monitor, enrollment, identity gate) so two features never
//  fight over the device. Each lease states the frame rate it needs; the
//  session runs at the highest one and drops back down when that lease ends
//  — presence detection alone keeps the sensor at ~2 fps.
//
//  `isRunning` is the single source of truth for "the camera is on", which
//  the island surfaces as a green dot whenever it's true.
//
//  Adapted from Glance (github.com/jonnyoo/glance, MIT).
//

@preconcurrency import AVFoundation
import Combine
import CoreImage
import Foundation

enum CameraPermission {
    case notDetermined
    case granted
    case denied
}

/// `source` is a lazy CIImage recipe, not rendered pixels — holding it costs
/// nothing until `renderCrop` uses it for a native-resolution glare crop.
struct CameraFrame {
    let id: UInt64
    let image: CGImage
    let source: CIImage
    let sourceSize: CGSize
}

@MainActor
final class CameraManager: ObservableObject {
    static let shared = CameraManager()

    @Published private(set) var permission: CameraPermission = .notDetermined
    @Published private(set) var isRunning = false
    @Published private(set) var currentFrame: CameraFrame?
    @Published private(set) var errorMessage: String?
    /// Human-readable lease names, for the "camera active" indicator's tooltip.
    @Published private(set) var activeClients: [String] = []

    /// Exposed read-only so the enrollment preview can attach a preview layer.
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.jadonli.lockedin.camera.session")
    private let framePublisher = FramePublisher()

    private struct Lease {
        let client: String
        let maxFPS: Double
    }
    private var leases: [UUID: Lease] = [:]
    private var isConfigured = false
    private var currentInput: AVCaptureDeviceInput?

    private init() {
        framePublisher.owner = self
        refreshPermission()
    }

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func refreshPermission() {
        switch Self.authorizationStatus {
        case .authorized: permission = .granted
        case .notDetermined: permission = .notDetermined
        default: permission = .denied
        }
    }

    /// Prompts the system camera dialog if it hasn't been shown yet.
    func requestPermission() async -> Bool {
        if Self.authorizationStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        refreshPermission()
        return permission == .granted
    }

    // MARK: - Leases

    /// Starts the camera (if it isn't already) and keeps it running until the
    /// returned token is released. `maxFPS` is a ceiling — the sensor rate is
    /// the highest ceiling among live leases.
    func acquire(client: String, maxFPS: Double) async -> UUID? {
        guard await requestPermission() else {
            errorMessage = "Camera access not granted. Enable LockedIn in System Settings › Privacy & Security › Camera."
            return nil
        }
        errorMessage = nil
        let token = UUID()
        leases[token] = Lease(client: client, maxFPS: maxFPS)
        activeClients = leases.values.map(\.client)

        configureSessionIfNeeded()
        reconcileDeviceIfNeeded()
        applyFrameRate()

        if !isRunning {
            isRunning = true
            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
            }
        }
        return token
    }

    func release(_ token: UUID?) {
        guard let token, leases.removeValue(forKey: token) != nil else { return }
        activeClients = leases.values.map(\.client)
        if leases.isEmpty {
            isRunning = false
            currentFrame = nil
            sessionQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        } else {
            applyFrameRate()
        }
    }

    // MARK: - Session setup

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        session.beginConfiguration()
        session.sessionPreset = .high
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(framePublisher, queue: sessionQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
    }

    /// Re-run on every acquire so a camera change in Settings takes effect without a relaunch.
    private func reconcileDeviceIfNeeded() {
        guard let device = CameraDeviceCatalog.resolvedDevice() else {
            errorMessage = "No camera found."
            return
        }
        guard device.uniqueID != currentInput?.device.uniqueID else { return }

        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
        }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        } else {
            currentInput = nil
            errorMessage = "Couldn't open the selected camera."
        }
        session.commitConfiguration()
    }

    /// Sets the sensor's frame-duration floor to the highest fps any lease
    /// wants, clamped to what the active format supports.
    private func applyFrameRate() {
        guard let device = currentInput?.device else { return }
        let wanted = leases.values.map(\.maxFPS).max() ?? 30
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        let floorFPS = ranges.map(\.minFrameRate).min() ?? 1
        let ceilFPS = ranges.map(\.maxFrameRate).max() ?? 30
        let fps = min(max(wanted, floorFPS), ceilFPS)
        framePublisher.minimumInterval = 1.0 / fps
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
            device.unlockForConfiguration()
        } catch {
            // Some virtual cameras refuse configuration; the publisher-side throttle still applies.
        }
    }

    fileprivate func publish(frame: CameraFrame) {
        guard isRunning else { return }
        currentFrame = frame
    }

    // MARK: - Native-resolution crops (for the glare cue)

    /// Renders a native-resolution crop of `imageRect` (working-frame pixel
    /// space, top-left origin) from `frame.source`, expanded ~1.3x so device
    /// edges/bezels are captured.
    nonisolated static func renderCrop(from frame: CameraFrame, imageRect: CGRect, maxEdge: CGFloat = 448) -> CGImage? {
        let workingWidth = CGFloat(frame.image.width)
        let workingHeight = CGFloat(frame.image.height)
        guard workingWidth > 0, workingHeight > 0 else { return nil }
        let scaleX = frame.sourceSize.width / workingWidth
        let scaleY = frame.sourceSize.height / workingHeight

        let expanded = imageRect.insetBy(dx: -imageRect.width * 0.15, dy: -imageRect.height * 0.15)
        let nativeX = expanded.origin.x * scaleX
        let nativeWidth = expanded.width * scaleX
        let nativeHeight = expanded.height * scaleY
        let nativeY = frame.sourceSize.height - (expanded.origin.y + expanded.height) * scaleY
        var nativeRect = CGRect(x: nativeX, y: nativeY, width: nativeWidth, height: nativeHeight)

        nativeRect = nativeRect.intersection(CGRect(origin: .zero, size: frame.sourceSize))
        guard !nativeRect.isEmpty else { return nil }

        var cropped = frame.source.cropped(to: nativeRect)
            .transformed(by: CGAffineTransform(translationX: -nativeRect.minX, y: -nativeRect.minY))
        let longEdge = max(nativeRect.width, nativeRect.height)
        if longEdge > maxEdge {
            let scale = maxEdge / longEdge
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return cropRenderContext.createCGImage(cropped, from: cropped.extent)
    }

    private nonisolated static let cropRenderContext = CIContext()

    /// Sample-buffer callbacks arrive on `sessionQueue`; this converts there, then hops to main.
    private final class FramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        weak var owner: CameraManager?
        /// Publisher-side throttle, in seconds between published frames.
        var minimumInterval: TimeInterval = 0
        private let ciContext = CIContext()
        private let maxLongEdge: CGFloat = 640
        private var nextFrameID: UInt64 = 0
        private var lastPublished: TimeInterval = 0

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            let now = CACurrentMediaTime()
            guard now - lastPublished >= minimumInterval * 0.9 else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            lastPublished = now

            let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
            let sourceExtent = sourceImage.extent
            var ciImage = sourceImage
            let longEdge = max(ciImage.extent.width, ciImage.extent.height)
            if longEdge > maxLongEdge {
                let scale = maxLongEdge / longEdge
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

            nextFrameID &+= 1
            let frame = CameraFrame(id: nextFrameID, image: cgImage, source: sourceImage, sourceSize: sourceExtent.size)
            Task { @MainActor [weak owner] in
                owner?.publish(frame: frame)
            }
        }
    }
}
