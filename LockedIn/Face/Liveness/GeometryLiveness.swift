//
//  GeometryLiveness.swift
//  LockedIn
//
//  Planar-vs-3D liveness (the `flatVs3D` confirm cue). Fits a homography to
//  the roughly-planar landmark regions across frames and measures how badly
//  the held-out nose points miss it: a photo fits, a real face has depth.
//
//  Ported from Glance (github.com/jonnyoo/glance, MIT).
//

import CoreGraphics
import Foundation

struct GeometryTuning {
    /// Excess (`probeResidual / fitResidual`) at which the planar signal starts ramping off 0.
    var excessFloor: CGFloat = 1.15
    /// Excess at which the planar signal saturates at 1.
    var excessCeiling: CGFloat = 2.0
    /// `|mean residual| / mean(|residual|)` below this reads as landmark noise, not parallax.
    var coherenceFloor: CGFloat = 0.35
    /// Minimum mean fit-set displacement (interocular units) before geometry votes at all.
    var motionGate: CGFloat = 0.008
    /// Minimum yaw range (degrees) before geometry votes — closes the "smooth phone wobble" case.
    var minYawRangeDegrees: CGFloat = 12

    static let `default` = GeometryTuning()
}

struct GeometryLivenessResult: Equatable {
    let planarResidualScore: Float
    let planarConfidence: Float
    let pairsAnalyzed: Int

    static let empty = GeometryLivenessResult(planarResidualScore: 0, planarConfidence: 0, pairsAnalyzed: 0)

    var planarReading: CueReading {
        CueReading(level: planarResidualScore, confidence: planarConfidence)
    }
}

/// Regions on roughly one shallow surface, with enough spread to constrain a homography.
private let geometryFitRegions: Set<LandmarkRegion> = [.leftEye, .rightEye, .leftEyebrow, .rightEyebrow, .outerLips]
/// Protruding landmarks inside the fit hull, so leftover error is depth, not extrapolation.
private let geometryProbeRegions: Set<LandmarkRegion> = [.nose, .noseCrest, .medianLine]

enum GeometryLiveness {
    static func evaluate(_ window: [LivenessFrame], tuning: GeometryTuning = .default) -> GeometryLivenessResult {
        guard window.count >= 3 else { return .empty }

        let yawRange = yawRangeDegrees(window)
        let yawGateOK = (yawRange ?? 0) >= tuning.minYawRangeDegrees

        var excesses: [CGFloat] = []
        var coherences: [CGFloat] = []
        var weights: [CGFloat] = []
        var skippedForMotion = 0

        for (i, j, weight) in pairIndices(count: window.count) {
            guard let sample = pairGeometry(from: window[i], to: window[j]) else { continue }
            if sample.motion < tuning.motionGate {
                skippedForMotion += 1
                continue
            }
            excesses.append(sample.excess)
            coherences.append(sample.coherence)
            weights.append(weight)
        }

        let pairsAnalyzed = excesses.count
        let excess = weightedMedian(excesses, weights: weights)
        let coherence = weightedMedian(coherences, weights: weights)

        // Abstention is (level 0, confidence 0).
        var planarScore: Float = 0
        var planarConf: Float = 0
        if yawGateOK, let excess, let coherence, pairsAnalyzed >= 2 {
            let coherenceFactor = Float(clamp((coherence - tuning.coherenceFloor) / max(1 - tuning.coherenceFloor, 0.01), 0, 1))
            let excessScore = Float(clamp((excess - tuning.excessFloor) / max(tuning.excessCeiling - tuning.excessFloor, 0.01), 0, 1))
            planarScore = excessScore * (0.35 + 0.65 * coherenceFactor)
            planarConf = Float(clamp(Double(pairsAnalyzed) / 6.0, 0, 1)) * (0.5 + 0.5 * coherenceFactor)
        }
        _ = skippedForMotion

        return GeometryLivenessResult(planarResidualScore: planarScore, planarConfidence: planarConf, pairsAnalyzed: pairsAnalyzed)
    }

    private static func yawRangeDegrees(_ window: [LivenessFrame]) -> CGFloat? {
        let yawsDegrees = window.compactMap { $0.yaw }.map { CGFloat($0) * 180 / .pi }
        guard yawsDegrees.count >= 3, let lo = yawsDegrees.min(), let hi = yawsDegrees.max() else { return nil }
        return hi - lo
    }

    private struct PairSample {
        let excess: CGFloat
        let coherence: CGFloat
        let motion: CGFloat
    }

    private static func pairGeometry(from a: LivenessFrame, to b: LivenessFrame) -> PairSample? {
        guard b.hasReliableLandmarks, a.hasReliableLandmarks else { return nil }
        guard let iod = b.interocularDistance, iod > 0 else { return nil }
        let matched = correspondingPoints(a.landmarks, b.landmarks)
        let (fitSrc, fitDst) = flatten(matched, in: geometryFitRegions)
        let (probeSrc, probeDst) = flatten(matched, in: geometryProbeRegions)
        let (eyeSrc, eyeDst) = flatten(matched, in: [.leftEye, .rightEye])
        guard fitSrc.count >= 6, probeSrc.count >= 2 else { return nil }
        guard let homography = LandmarkGeometry.solveRobustHomography(from: fitSrc, to: fitDst) else { return nil }

        let eyeMags = zip(eyeSrc, eyeDst).map { hypot($1.x - homography.apply($0).x, $1.y - homography.apply($0).y) / iod }
        let probeVecs: [(CGFloat, CGFloat)] = zip(probeSrc, probeDst).map { src, dst in
            let predicted = homography.apply(src)
            return ((dst.x - predicted.x) / iod, (dst.y - predicted.y) / iod)
        }
        let probeMags = probeVecs.map { hypot($0.0, $0.1) }
        // Eyes are the rigid anchors — expression in the fit set must not set the noise scale.
        let noiseMags: [CGFloat] = eyeMags.count >= 2
            ? eyeMags
            : zip(fitSrc, fitDst).map { hypot($1.x - homography.apply($0).x, $1.y - homography.apply($0).y) / iod }
        let fitResidual = LandmarkGeometry.medianValue(noiseMags)
        let probeResidual = LandmarkGeometry.medianValue(probeMags)
        let excess = probeResidual / max(fitResidual, 0.002)

        let meanX = probeVecs.reduce(CGFloat(0)) { $0 + $1.0 } / CGFloat(probeVecs.count)
        let meanY = probeVecs.reduce(CGFloat(0)) { $0 + $1.1 } / CGFloat(probeVecs.count)
        let meanMag = probeMags.reduce(0, +) / CGFloat(probeMags.count)
        let coherence = meanMag > 1e-8 ? hypot(meanX, meanY) / meanMag : 0

        let motion = zip(fitSrc, fitDst).map { hypot($1.x - $0.x, $1.y - $0.y) }.reduce(0, +)
            / (CGFloat(fitSrc.count) * iod)

        return PairSample(excess: excess, coherence: coherence, motion: motion)
    }

    /// Points present, with matching per-region counts, in both frames.
    private static func correspondingPoints(
        _ a: [LandmarkPoint], _ b: [LandmarkPoint]
    ) -> [LandmarkRegion: (source: [CGPoint], destination: [CGPoint])] {
        let aByRegion = Dictionary(grouping: a, by: \.region)
        let bByRegion = Dictionary(grouping: b, by: \.region)
        var result: [LandmarkRegion: (source: [CGPoint], destination: [CGPoint])] = [:]
        for region in LandmarkRegion.allCases {
            guard let aPoints = aByRegion[region], let bPoints = bByRegion[region],
                  aPoints.count == bPoints.count, !aPoints.isEmpty else { continue }
            let aSorted = aPoints.sorted { $0.indexInRegion < $1.indexInRegion }
            let bSorted = bPoints.sorted { $0.indexInRegion < $1.indexInRegion }
            result[region] = (aSorted.map(\.point), bSorted.map(\.point))
        }
        return result
    }

    private static func flatten(
        _ byRegion: [LandmarkRegion: (source: [CGPoint], destination: [CGPoint])],
        in regions: Set<LandmarkRegion>
    ) -> (source: [CGPoint], destination: [CGPoint]) {
        var source: [CGPoint] = []
        var destination: [CGPoint] = []
        for region in LandmarkRegion.allCases where regions.contains(region) {
            guard let points = byRegion[region] else { continue }
            source += points.source
            destination += points.destination
        }
        return (source, destination)
    }

    private static func pairIndices(count: Int) -> [(Int, Int, CGFloat)] {
        guard count >= 2 else { return [] }
        var pairs: [(Int, Int, CGFloat)] = []
        for i in 0..<(count - 1) {
            pairs.append((i, i + 1, 1))
        }
        let half = max(count / 2, 2)
        if count > 4 {
            for i in 0..<(count - half) {
                pairs.append((i, i + half, 2))
            }
        }
        if count > 2 {
            pairs.append((0, count - 1, 3))
        }
        return pairs
    }

    private static func weightedMedian(_ values: [CGFloat], weights: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty, values.count == weights.count else { return nil }
        let sorted = zip(values, weights).sorted { $0.0 < $1.0 }
        let total = sorted.reduce(CGFloat(0)) { $0 + $1.1 }
        guard total > 0 else { return LandmarkGeometry.medianValue(values) }
        var acc: CGFloat = 0
        for (value, weight) in sorted {
            acc += weight
            if acc >= total / 2 { return value }
        }
        return sorted.last?.0
    }

    private static func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        min(max(value, lower), upper)
    }
}
