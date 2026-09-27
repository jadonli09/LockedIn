//
//  FaceDetector.swift
//  LockedIn
//
//  Vision face detection: rectangles + capture quality + landmarks in one pass.
//  Converts Vision's normalized, bottom-left-origin boxes into pixel-space,
//  top-left-origin rects ready to crop with.
//
//  Ported from Glance (github.com/jonnyoo/glance, MIT).
//

import CoreGraphics
import Vision

struct DetectedFace {
    /// Pixel-space bounding box, top-left origin.
    let boundingBox: CGRect
    /// Vision's original normalized box.
    let normalizedBoundingBox: CGRect
    /// 0...1 capture quality, roughly how suitable this frame is for recognition.
    let quality: Float?
    /// Head rotation in radians, when Vision could estimate it.
    let yaw: Float?
    let roll: Float?
    let pitch: Float?
    let landmarks: VNFaceLandmarks2D?
    let imageSize: CGSize
}

/// Pure, synchronous, CPU-bound work — run it on a background task.
enum FaceDetector {
    static func detectFaces(in image: CGImage) throws -> [DetectedFace] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let rectanglesRequest = VNDetectFaceRectanglesRequest()
        try handler.perform([rectanglesRequest])
        let faceObservations = rectanglesRequest.results ?? []
        guard !faceObservations.isEmpty else { return [] }

        // Chained to the rectangles results so results correspond 1:1 in order.
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        qualityRequest.inputFaceObservations = faceObservations
        landmarksRequest.inputFaceObservations = faceObservations
        try handler.perform([qualityRequest, landmarksRequest])

        let qualityResults = qualityRequest.results ?? []
        let landmarkResults = landmarksRequest.results ?? []
        let imageSize = CGSize(width: image.width, height: image.height)

        return faceObservations.enumerated().map { index, observation in
            DetectedFace(
                boundingBox: convertToImageSpace(observation.boundingBox, imageSize: imageSize),
                normalizedBoundingBox: observation.boundingBox,
                quality: qualityResults.indices.contains(index) ? qualityResults[index].faceCaptureQuality : nil,
                yaw: observation.yaw?.floatValue,
                roll: observation.roll?.floatValue,
                pitch: observation.pitch?.floatValue,
                landmarks: landmarkResults.indices.contains(index) ? landmarkResults[index].landmarks : nil,
                imageSize: imageSize
            )
        }
    }

    /// Cheap detection only (no quality/landmarks) — what the presence monitor
    /// uses on frames where nobody may be there at all.
    static func detectFaceRectangles(in image: CGImage) throws -> [CGRect] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectFaceRectanglesRequest()
        try handler.perform([request])
        return (request.results ?? []).map(\.boundingBox)
    }

    /// Vision's normalized rect has origin at bottom-left; `CGImage.cropping`
    /// expects pixel coordinates with origin at top-left.
    static func convertToImageSpace(_ normalizedRect: CGRect, imageSize: CGSize) -> CGRect {
        let x = normalizedRect.origin.x * imageSize.width
        let width = normalizedRect.width * imageSize.width
        let height = normalizedRect.height * imageSize.height
        let y = (1 - normalizedRect.origin.y) * imageSize.height - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Crops `face` out of `image`, padded slightly so the embedder sees a bit
    /// of context beyond just eyes/nose/mouth.
    static func crop(_ face: DetectedFace, from image: CGImage, paddingFraction: CGFloat = 0.2) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let padX = face.boundingBox.width * paddingFraction
        let padY = face.boundingBox.height * paddingFraction
        let padded = face.boundingBox.insetBy(dx: -padX, dy: -padY).intersection(imageBounds)
        guard !padded.isEmpty else { return nil }
        return image.cropping(to: padded)
    }
}
