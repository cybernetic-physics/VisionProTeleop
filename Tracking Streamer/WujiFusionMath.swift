import Foundation
import simd

struct WujiSkeletonPacket: Codable {
    let kind: String
    let version: Int
    let session: String
    let side: String
    let serial: String
    let frame: String
    let sequence: UInt64
    let sourceTimestampUs: UInt64
    let headsetTime: Double
    let uncertaintyMs: Double
    let points: [[Float]]
    let confidence: [Float]

    func valid(at now: Double) -> Bool {
        kind == "skeleton" && version == 1 && !session.isEmpty && session.count < 80 &&
        ["left", "right"].contains(side) && frame == (side == "left" ? "l_wrist" : "r_wrist") &&
        sourceTimestampUs > 1_000_000_000_000_000 && headsetTime.isFinite &&
        now - headsetTime >= -0.02 && now - headsetTime <= 0.25 &&
        uncertaintyMs.isFinite && uncertaintyMs >= 0 && uncertaintyMs <= 30 &&
        points.count == 21 && confidence.count == 21 &&
        points.allSatisfy { $0.count == 3 && $0.allSatisfy { $0.isFinite && abs($0) <= 1 } } &&
        confidence.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } &&
        points[0].allSatisfy { abs($0) < 0.005 }
    }
}

struct ControllerPoseTimeline {
    struct Sample {
        let time: Double
        let left: simd_float4x4?
        let right: simd_float4x4?
        let head: simd_float4x4?
    }
    private(set) var samples: [Sample] = []
    mutating func append(_ sample: Sample) {
        if let last = samples.last, sample.time <= last.time { return }
        samples.append(sample)
        samples.removeAll { sample.time - $0.time > 1 }
    }
    mutating func clear() { samples.removeAll() }
    func pose(at time: Double, side: String) -> (controller: simd_float4x4, head: simd_float4x4)? {
        guard let upper = samples.firstIndex(where: { $0.time >= time }), upper > 0 else { return nil }
        let a = samples[upper - 1], b = samples[upper]
        // Do not bridge invalid samples, stalls, or extrapolate missing tracking.
        guard b.time - a.time <= 0.05,
              let ca = side == "left" ? a.left : a.right,
              let cb = side == "left" ? b.left : b.right,
              let ha = a.head, let hb = b.head else { return nil }
        let t = Float((time - a.time) / (b.time - a.time))
        return (Self.interpolate(ca, cb, t), Self.interpolate(ha, hb, t))
    }
    static func interpolate(_ a: simd_float4x4, _ b: simd_float4x4, _ t: Float) -> simd_float4x4 {
        var m = simd_float4x4(simd_slerp(simd_quatf(a), simd_quatf(b), t))
        m.columns.3 = a.columns.3 * (1 - t) + b.columns.3 * t
        return m
    }
}
