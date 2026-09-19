import Foundation
import simd

/// Fixed rigid transforms only. No hand samples, fitting, or automatic alignment.
struct ControllerCalibrationProfile: Codable {
    var world: [Float] = ControllerCalibrationProfile.encode(matrix_identity_float4x4)
    var left: [Float] = ControllerCalibrationProfile.encode(matrix_identity_float4x4)
    var right: [Float] = ControllerCalibrationProfile.encode(matrix_identity_float4x4)
    var leftWrist: [Float] = ControllerCalibrationProfile.encode(matrix_identity_float4x4)
    var rightWrist: [Float] = ControllerCalibrationProfile.encode(matrix_identity_float4x4)
    var saved = false
    init() {}
    enum CodingKeys: String, CodingKey { case world, left, right, leftWrist, rightWrist, saved }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        world = try c.decode([Float].self, forKey: .world)
        left = try c.decode([Float].self, forKey: .left)
        right = try c.decode([Float].self, forKey: .right)
        leftWrist = try c.decodeIfPresent([Float].self, forKey: .leftWrist) ?? Self.encode(matrix_identity_float4x4)
        rightWrist = try c.decodeIfPresent([Float].self, forKey: .rightWrist) ?? Self.encode(matrix_identity_float4x4)
        saved = try c.decodeIfPresent(Bool.self, forKey: .saved) ?? false
    }

    static func encode(_ m: simd_float4x4) -> [Float] {
        (0..<4).flatMap { c in (0..<4).map { r in m[c][r] } }
    }
    static func decode(_ a: [Float]) -> simd_float4x4? {
        guard a.count == 16, a.allSatisfy(\.isFinite) else { return nil }
        let m = simd_float4x4(columns: (SIMD4(a[0],a[1],a[2],a[3]), SIMD4(a[4],a[5],a[6],a[7]),
                                     SIMD4(a[8],a[9],a[10],a[11]), SIMD4(a[12],a[13],a[14],a[15])))
        let r = simd_float3x3(columns: (xyz(m.columns.0), xyz(m.columns.1), xyz(m.columns.2)))
        let gram = r.transpose * r
        guard abs(m[0][3]) < 0.00001, abs(m[1][3]) < 0.00001, abs(m[2][3]) < 0.00001,
              abs(m[3][3] - 1) < 0.00001, abs(simd_determinant(r) - 1) < 0.002,
              (0..<3).allSatisfy({ c in (0..<3).allSatisfy { r in abs(gram[c][r] - (c == r ? 1 : 0)) < 0.002 } }) else { return nil }
        return m
    }
    static func trackingReady(side: String, head: Bool, left: Bool, right: Bool) -> Bool {
        guard head else { return false }
        switch side {
        case "left": return left
        case "right": return right
        case "both": return left && right
        default: return false
        }
    }
    static func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
    var isValid: Bool { Self.decode(world) != nil && Self.decode(left) != nil && Self.decode(right) != nil && Self.decode(leftWrist) != nil && Self.decode(rightWrist) != nil }
    func matrix(_ target: Int) -> simd_float4x4 {
        Self.decode(target == 0 ? world : target == 1 ? left : target == 2 ? right : target == 3 ? leftWrist : rightWrist) ?? matrix_identity_float4x4
    }
    mutating func set(_ target: Int, _ matrix: simd_float4x4) {
        let a = Self.encode(matrix)
        if target == 0 { world = a } else if target == 1 { left = a } else if target == 2 { right = a } else if target == 3 { leftWrist = a } else { rightWrist = a }
    }
    func corrected(_ raw: simd_float4x4, left: Bool) -> simd_float4x4 {
        matrix(0) * raw * matrix(left ? 1 : 2)
    }
    /// World edits use a frozen head basis and pivot. Grip edits use controller-local axes.
    mutating func nudge(target: Int, axis: Int, amount: Float, rotate: Bool, basis: simd_float4x4) {
        var m = matrix(target)
        var direction = SIMD3<Float>(repeating: 0)
        direction[axis] = 1
        if target == 0 { direction = Self.xyz(basis[axis]) }
        if rotate {
            let rotation = simd_float4x4(simd_quatf(angle: amount, axis: direction))
            if target == 0 {
                var pivot = matrix_identity_float4x4
                pivot.columns.3 = SIMD4(Self.xyz(basis.columns.3), 1)
                m = pivot * rotation * simd_inverse(pivot) * m
            } else {
                let position = m.columns.3
                m = rotation * m
                m.columns.3 = position
            }
        } else {
            m.columns.3 += SIMD4(direction * amount, 0)
        }
        set(target, m)
    }
}
