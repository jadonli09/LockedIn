//
//  FaceRecognitionPipeline.swift
//  LockedIn
//
//  Detect → align → embed. The only place that constructs a FaceEmbedder, so
//  every consumer (unlock, presence, enrollment, identity gate) scores in the
//  same vector space.
//
//  Ported from Glance (github.com/jonnyoo/glance, MIT).
//

import CoreGraphics
import Foundation
import os

struct FaceRecognitionResult {
    let embedding: [Float]
    /// What was actually fed to the embedder.
    let alignedImage: CGImage
    let alignmentTier: AlignmentTier
    let quality: Float?
    let face: DetectedFace
}

enum FaceRecognitionPipelineError: LocalizedError {
    case noFaceDetected
    case alignmentFailed

    var errorDescription: String? {
        switch self {
        case .noFaceDetected: "No face detected in frame."
        case .alignmentFailed: "Could not align the detected face."
        }
    }
}

final class FaceRecognitionPipeline: @unchecked Sendable {
    /// One pipeline for the whole app: the Core ML model is ~7 MB and loads once.
    static let shared = FaceRecognitionPipeline()

    let embedder: FaceEmbedder
    /// Set when ArcFace failed to load and the weaker Vision feature print is in use.
    let usingFallbackEmbedder: Bool
    let fallbackReason: String?

    /// Below this fraction of frame width a face is a bystander, not a candidate.
    static let minimumProminentFaceWidth: Float = 0.19
    /// Max normalized-coordinate drift between frames still counted as "the same person".
    private static let continuityDistanceTolerance: CGFloat = 0.3

    private init() {
        do {
            embedder = try ArcFaceEmbedder()
            usingFallbackEmbedder = false
            fallbackReason = nil
        } catch {
            embedder = VisionFeaturePrintEmbedder()
            usingFallbackEmbedder = true
            fallbackReason = error.localizedDescription
        }
    }

    /// Loads the model and runs one throwaway pass through Vision and Core ML, so
    /// the first real scan doesn't pay model load + graph compile (hundreds of ms
    /// on a cold start). Idempotent; call from a background task.
    func warmUp() {
        guard !Self.isWarm.withLock({ $0 }) else { return }
        let side = 112
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { return }
        _ = try? FaceDetector.detectFaces(in: image)
        _ = try? embedder.embedding(for: image)
        Self.isWarm.withLock { $0 = true }
    }

    private static let isWarm = OSAllocatedUnfairLock(initialState: false)

    /// Runs detect/align/embed on the dominant face. Call from a background task.
    func recognize(in frame: CGImage, preferNear previousBoundingBox: CGRect? = nil) throws -> FaceRecognitionResult {
        let faces = try FaceDetector.detectFaces(in: frame)
        guard let face = Self.selectDominantFace(in: faces, preferNear: previousBoundingBox) else {
            throw FaceRecognitionPipelineError.noFaceDetected
        }
        return try recognize(face, in: frame)
    }

    /// Aligns and embeds an already-chosen face (enrollment bypasses the prominence
    /// filter so a too-small face reads as "move closer" rather than "nobody there").
    func recognize(_ face: DetectedFace, in frame: CGImage) throws -> FaceRecognitionResult {
        let inputImage: CGImage
        let tier: AlignmentTier
        if embedder.requiresAlignment {
            guard let aligned = FaceAligner.align(face, from: frame) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = aligned.image
            tier = aligned.tier
        } else {
            guard let cropped = FaceDetector.crop(face, from: frame) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = cropped
            tier = .paddedCrop
        }
        let embedding = try embedder.embedding(for: inputImage)
        return FaceRecognitionResult(embedding: embedding, alignedImage: inputImage, alignmentTier: tier, quality: face.quality, face: face)
    }

    static func largestFace(in faces: [DetectedFace]) -> DetectedFace? {
        faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    /// Picks the person actually at the camera, not a bystander, preferring
    /// continuity with the previous frame so two similar faces can't flip-flop.
    static func selectDominantFace(in faces: [DetectedFace], preferNear previousBoundingBox: CGRect? = nil) -> DetectedFace? {
        let candidates = faces.filter { $0.normalizedBoundingBox.width >= CGFloat(minimumProminentFaceWidth) }
        guard !candidates.isEmpty else { return nil }

        if let previous = previousBoundingBox {
            let previousCenter = CGPoint(x: previous.midX, y: previous.midY)
            if let nearest = candidates.min(by: { distance(from: $0, to: previousCenter) < distance(from: $1, to: previousCenter) }),
               distance(from: nearest, to: previousCenter) < continuityDistanceTolerance {
                return nearest
            }
        }
        return largestFace(in: candidates)
    }

    private static func distance(from face: DetectedFace, to point: CGPoint) -> CGFloat {
        let center = CGPoint(x: face.normalizedBoundingBox.midX, y: face.normalizedBoundingBox.midY)
        return hypot(center.x - point.x, center.y - point.y)
    }

    // MARK: - Matching against enrolled identities

    func score(_ embedding: [Float], against identities: [FaceIdentity]) -> [ScoredIdentity] {
        FaceMatcher.score(embedding, against: identities)
    }

    func bestMatch(in scored: [ScoredIdentity], threshold: Float) -> ScoredIdentity? {
        FaceMatcher.bestMatch(in: scored, threshold: threshold, modelIdentifier: embedder.modelIdentifier)
    }
}
