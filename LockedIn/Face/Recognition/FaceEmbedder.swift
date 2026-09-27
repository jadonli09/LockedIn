//
//  FaceEmbedder.swift
//  LockedIn
//
//  Two embedders: `ArcFaceEmbedder` (the real face-discriminative Core ML
//  model, w600k_mbf, bundled as ArcFace.mlpackage) and `VisionFeaturePrintEmbedder`
//  (Apple's built-in, only a ~5-7% similarity gap between people — a fallback
//  so the app still runs if the model failed to compile, never the intended path).
//
//  Ported from Glance (github.com/jonnyoo/glance, MIT).
//

import CoreGraphics
import CoreML
import CoreVideo
import Vision

protocol FaceEmbedder: Sendable {
    var name: String { get }
    /// Persisted alongside every sample; matching refuses to compare across embedders.
    var modelIdentifier: String { get }
    var embeddingDimension: Int { get }
    /// Whether this embedder needs a canonically-aligned input (ArcFace) vs. a loose crop.
    var requiresAlignment: Bool { get }
    func embedding(for face: CGImage) throws -> [Float]
}

enum ArcFaceEmbedderError: LocalizedError {
    case modelNotFound
    case modelLoadFailed(String)
    case pixelBufferCreationFailed
    case unexpectedInputSize(got: (Int, Int), expected: Int)
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "ArcFace.mlmodelc not found in the app bundle."
        case .modelLoadFailed(let detail):
            return "Failed to load the ArcFace Core ML model: \(detail)"
        case .pixelBufferCreationFailed:
            return "Couldn't prepare the aligned face image for Core ML."
        case .unexpectedInputSize(let got, let expected):
            return "ArcFace expects a \(expected)x\(expected) aligned image, got \(got.0)x\(got.1)."
        case .unexpectedOutput(let detail):
            return "ArcFace produced an unexpected output: \(detail)"
        }
    }
}

final class ArcFaceEmbedder: FaceEmbedder, @unchecked Sendable {
    let name = "ArcFace (w600k_mbf)"
    let modelIdentifier = "arcface-w600k_mbf-v1"
    let embeddingDimension = 512
    let requiresAlignment = true

    private static let inputSize = FaceAligner.outputSize
    private static let inputName = "input_image"
    private static let outputName = "embedding"

    // Loaded once and reused — model load dominates a single inference.
    private let model: MLModel
    private let pixelBufferPool: CVPixelBufferPool

    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "ArcFace", withExtension: "mlmodelc") else {
            throw ArcFaceEmbedderError.modelNotFound
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do {
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            throw ArcFaceEmbedderError.modelLoadFailed(error.localizedDescription)
        }
        guard let pool = Self.makePixelBufferPool(size: Self.inputSize) else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        pixelBufferPool = pool
    }

    private static func makePixelBufferPool(size: Int) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    /// `MLModel.prediction(from:)` is synchronous — run off the main actor.
    func embedding(for face: CGImage) throws -> [Float] {
        guard face.width == Self.inputSize, face.height == Self.inputSize else {
            throw ArcFaceEmbedderError.unexpectedInputSize(got: (face.width, face.height), expected: Self.inputSize)
        }

        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBufferOut)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        try Self.render(face, into: pixelBuffer)

        let input = try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
        let output = try model.prediction(from: input)

        guard let multiArray = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw ArcFaceEmbedderError.unexpectedOutput("no '\(Self.outputName)' output found")
        }
        guard multiArray.count == embeddingDimension else {
            throw ArcFaceEmbedderError.unexpectedOutput("expected \(embeddingDimension) floats, got \(multiArray.count)")
        }

        var raw = [Float](repeating: 0, count: multiArray.count)
        for i in 0..<multiArray.count {
            raw[i] = multiArray[i].floatValue
        }
        return FaceEmbedding.l2Normalized(raw)
    }

    private static func render(_ image: CGImage, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}

enum FaceEmbedderError: LocalizedError {
    case noObservation
    case unsupportedElementType

    var errorDescription: String? {
        switch self {
        case .noObservation: "Vision did not produce a feature print for this image."
        case .unsupportedElementType: "Feature print used an unexpected element type."
        }
    }
}

struct VisionFeaturePrintEmbedder: FaceEmbedder {
    let name = "Vision Feature Print"
    let modelIdentifier = "vision-feature-print-v1"
    let embeddingDimension = 2048
    let requiresAlignment = false

    func embedding(for face: CGImage) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: face, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else {
            throw FaceEmbedderError.noObservation
        }
        let count = observation.elementCount
        var result = [Float](repeating: 0, count: count)
        switch observation.elementType {
        case .float:
            observation.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let buffer = raw.bindMemory(to: Float.self)
                for i in 0..<count { result[i] = buffer[i] }
            }
        case .double:
            observation.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let buffer = raw.bindMemory(to: Double.self)
                for i in 0..<count { result[i] = Float(buffer[i]) }
            }
        default:
            throw FaceEmbedderError.unsupportedElementType
        }
        return FaceEmbedding.l2Normalized(result)
    }
}
