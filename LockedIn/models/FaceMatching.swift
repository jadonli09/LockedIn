//
//  FaceMatching.swift
//  LockedIn
//
//  Pure embedding math and the enrolled-identity model: cosine similarity,
//  template averaging, and the two-sided threshold match. No Vision, no
//  Defaults — compiled straight into the unit-test target.
//
//  Adapted from Glance (github.com/jonnyoo/glance, MIT).
//

import Foundation

enum FaceEmbedding {
    /// Scales `vector` to unit length; matters once vectors are combined (see `average`).
    static func l2Normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Cosine similarity, range -1...1. ArcFace same-person cutoffs sit around 0.55–0.70.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Normalize each sample, average, then renormalize — a plain element-wise
    /// mean would let a larger-magnitude sample silently dominate.
    static func average(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let count = Float(vectors.count)
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == first.count {
            let normalized = l2Normalized(vector)
            for i in 0..<normalized.count { sum[i] += normalized[i] }
        }
        let mean = sum.map { $0 / count }
        return l2Normalized(mean)
    }
}

struct FaceSample: Codable, Equatable {
    let embedding: [Float]
    /// Which guided-enrollment pose this came from ("center", "left", …).
    let pose: String?
    let capturedAt: Date
    /// Vision's capture-quality score (0...1), or nil if unavailable.
    let quality: Float?
}

struct FaceIdentity: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var samples: [FaceSample]
    /// Which embedder produced these samples — different models' embeddings
    /// live in unrelated vector spaces, so a mismatch means "re-enroll".
    var modelIdentifier: String
    var embeddingDimension: Int
    var createdAt: Date

    /// The single vector actually compared against at recognition time.
    var template: [Float]? {
        FaceEmbedding.average(samples.map(\.embedding))
    }

    func isStale(comparedTo modelIdentifier: String) -> Bool {
        self.modelIdentifier != modelIdentifier
    }
}

struct ScoredIdentity {
    let identity: FaceIdentity
    /// Similarity against the identity's averaged template.
    let centroidSimilarity: Float
    /// Similarity against the single closest sample — catches cases where
    /// averaging blurred together poses that shouldn't be blended.
    let maxSampleSimilarity: Float
}

/// Named strictness levels over the raw cosine threshold. Seeded from
/// Glance's real-device tuning for the w600k_mbf ArcFace model.
enum FaceMatchStrictness: String, CaseIterable, Identifiable, Codable {
    case relaxed
    case standard
    case strict

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .relaxed: "Less strict"
        case .standard: "Default"
        case .strict: "More strict"
        }
    }

    var threshold: Float {
        switch self {
        case .relaxed: 0.58
        case .standard: 0.63
        case .strict: 0.68
        }
    }
}

enum FaceMatcher {
    /// Sorted by centroid similarity descending. Stale identities (different
    /// embedder) are scored too; `bestMatch` is what excludes them.
    static func score(_ embedding: [Float], against identities: [FaceIdentity]) -> [ScoredIdentity] {
        identities.compactMap { identity in
            guard let template = identity.template, !identity.samples.isEmpty else { return nil }
            let centroid = FaceEmbedding.cosineSimilarity(embedding, template)
            let maxSample = identity.samples
                .map { FaceEmbedding.cosineSimilarity(embedding, $0.embedding) }
                .max() ?? centroid
            return ScoredIdentity(identity: identity, centroidSimilarity: centroid, maxSampleSimilarity: maxSample)
        }
        .sorted { $0.centroidSimilarity > $1.centroidSimilarity }
    }

    /// Both the averaged template and the closest single sample must clear the
    /// threshold. No runner-up margin: one person may be enrolled twice (with
    /// and without glasses), and those legitimately score close together.
    static func bestMatch(in scored: [ScoredIdentity], threshold: Float, modelIdentifier: String) -> ScoredIdentity? {
        guard let first = scored.first, !first.identity.isStale(comparedTo: modelIdentifier) else { return nil }
        guard first.centroidSimilarity >= threshold, first.maxSampleSimilarity >= threshold else { return nil }
        return first
    }
}
