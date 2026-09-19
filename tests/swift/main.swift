import Foundation
import simd

func near(_ a: simd_float4x4, _ b: simd_float4x4, _ label: String) {
    assert(zip(ControllerCalibrationProfile.encode(a), ControllerCalibrationProfile.encode(b)).allSatisfy { abs($0 - $1) < 0.0001 }, label)
}
var profile = ControllerCalibrationProfile()
var basis = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
basis.columns.3 = SIMD4(1, 2, 3, 1)
profile.nudge(target: 0, axis: 0, amount: 0.1, rotate: false, basis: basis)
assert(abs(profile.matrix(0)[3][2] + 0.1) < 0.0001, "head basis transforms translation")
profile.set(0, matrix_identity_float4x4)
profile.nudge(target: 0, axis: 1, amount: .pi / 2, rotate: true, basis: basis)
let pivot = profile.matrix(0) * basis.columns.3
assert(simd_length(pivot - basis.columns.3) < 0.0001, "rotation keeps captured head pivot fixed")
profile.set(0, matrix_identity_float4x4)
profile.nudge(target: 1, axis: 2, amount: 0.13, rotate: false, basis: basis)
let raw = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
assert(abs(profile.corrected(raw, left: true)[3][0] - 0.13) < 0.0001, "grip offset rotates with controller")
near(profile.corrected(raw, left: false), raw, "other side stays independent")
profile.nudge(target: 1, axis: 0, amount: 0.2, rotate: true, basis: basis)
assert(abs(profile.matrix(1)[3][2] - 0.13) < 0.0001, "local rotation keeps grip translation")
let data = try JSONEncoder().encode(profile)
let restored = try JSONDecoder().decode(ControllerCalibrationProfile.self, from: data)
assert(restored.isValid)
near(restored.corrected(raw, left: true), profile.corrected(raw, left: true), "saved profile round trip")
assert(ControllerCalibrationProfile.decode([Float](repeating: 0, count: 16)) == nil)
var invalid = ControllerCalibrationProfile.encode(matrix_identity_float4x4)
invalid[0] = 2
assert(ControllerCalibrationProfile.decode(invalid) == nil, "reject scale")
invalid[0] = .nan
assert(ControllerCalibrationProfile.decode(invalid) == nil, "reject nonfinite")
print("Manual calibration math: all checks passed")

// Independent wrist calibration does not overwrite the controller grip calibration.
profile.nudge(target: 3, axis: 0, amount: 0.05, rotate: false, basis: basis)
assert(abs(profile.matrix(3)[3][0] - 0.05) < 0.0001)
assert(abs(profile.matrix(1)[3][0]) < 0.0001)
let oldJSON = "{\"world\":\(ControllerCalibrationProfile.encode(matrix_identity_float4x4)),\"left\":\(ControllerCalibrationProfile.encode(matrix_identity_float4x4)),\"right\":\(ControllerCalibrationProfile.encode(matrix_identity_float4x4)),\"saved\":true}"
let migrated = try JSONDecoder().decode(ControllerCalibrationProfile.self, from: Data(oldJSON.utf8))
assert(migrated.saved && migrated.isValid)
near(migrated.matrix(3), matrix_identity_float4x4, "old saved profile migrates wrist to identity")
var history = ControllerPoseTimeline()
var finish = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0,1,0)))
finish.columns.3.x = 1
history.append(.init(time: 1, left: matrix_identity_float4x4, right: nil, head: matrix_identity_float4x4))
history.append(.init(time: 1.02, left: finish, right: nil, head: matrix_identity_float4x4))
let middle = history.pose(at: 1.01, side: "left")!
assert(abs(middle.controller[3][0] - 0.5) < 0.0001, "capture-time interpolation")
assert(abs(middle.controller[0][0] - sqrt(0.5)) < 0.0001, "quaternion interpolation")
assert(history.pose(at: 1.01, side: "right") == nil, "sides are independent")
assert(history.pose(at: 1.03, side: "left") == nil, "never extrapolate")
history.append(.init(time: 1.03, left: nil, right: nil, head: matrix_identity_float4x4))
history.append(.init(time: 1.04, left: finish, right: nil, head: matrix_identity_float4x4))
assert(history.pose(at: 1.035, side: "left") == nil, "never interpolate across tracking loss")
history.append(.init(time: 1.2, left: finish, right: nil, head: matrix_identity_float4x4))
assert(history.pose(at: 1.1, side: "left") == nil, "reject long gaps")
func wire(time: Double = 1, confidence: Float = 1, count: Int = 21) -> WujiSkeletonPacket {
    WujiSkeletonPacket(kind: "skeleton", version: 1, session: "test", side: "left", serial: "test", frame: "l_wrist", sequence: 1, sourceTimestampUs: 1_700_000_000_000_000, headsetTime: time, uncertaintyMs: 1, points: Array(repeating: [0,0,0], count: count), confidence: Array(repeating: confidence, count: count))
}
assert(wire().valid(at: 1.1))
assert(!wire().valid(at: 1.3), "stale frame rejected")
assert(!wire(time: 2).valid(at: 1), "future frame rejected")
assert(!wire(confidence: .nan).valid(at: 1), "malformed confidence rejected")
assert(!wire(count: 20).valid(at: 1), "wrong joint count rejected")
print("Wuji packet, migration, and capture-time fusion checks passed")
assert(ControllerCalibrationProfile.trackingReady(side: "left", head: true, left: true, right: false), "left-only calibration ignores missing right controller")
assert(ControllerCalibrationProfile.trackingReady(side: "right", head: true, left: false, right: true))
assert(!ControllerCalibrationProfile.trackingReady(side: "both", head: true, left: true, right: false))
assert(!ControllerCalibrationProfile.trackingReady(side: "left", head: false, left: true, right: true))
assert(!ControllerCalibrationProfile.trackingReady(side: "left", head: true, left: false, right: true))
assert(!ControllerCalibrationProfile.trackingReady(side: "invalid", head: true, left: true, right: true))
print("Single-hand calibration checks passed")
