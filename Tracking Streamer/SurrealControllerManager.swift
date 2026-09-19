import SwiftUI
import RealityKit
import ARKit
import QuartzCore
import simd
import surreal_interactive_openxr_framework

/// A single immutable protobuf frame is shared by the gRPC, WebRTC and recording paths.
final class ControllerSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frame = Handtracking_ControllerTracking()
    private var updatedAt: TimeInterval = 0

    func update(_ value: Handtracking_ControllerTracking) {
        lock.lock()
        frame = value
        updatedAt = CACurrentMediaTime()
        lock.unlock()
    }

    func snapshot() -> Handtracking_ControllerTracking {
        lock.lock()
        defer { lock.unlock() }
        var result = frame
        // Never retransmit a held button or pose after the polling task stops.
        if CACurrentMediaTime() - updatedAt > 0.25 {
            result.left = Handtracking_ControllerState()
            result.right = Handtracking_ControllerState()
            result.headPoseValid = false
            result.clearHeadPose()
            result.clearGloves()
        }
        return result
    }
}

@MainActor
final class SurrealControllerManager: ObservableObject {
    static let shared = SurrealControllerManager()
    nonisolated static let snapshots = ControllerSnapshotStore()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "surrealControllersEnabled") }
    }
    @Published var showControllerOverlay: Bool {
        didSet { UserDefaults.standard.set(showControllerOverlay, forKey: "surrealControllerOverlay") }
    }
    @Published private(set) var status = "Start streaming to connect controllers"
    @Published private(set) var displayFrame = Handtracking_ControllerTracking()
    @Published var reviewCalibrationOnStartup: Bool {
        didSet { UserDefaults.standard.set(reviewCalibrationOnStartup, forKey: "controllerCalibrationAtStartup") }
    }
    @Published private(set) var calibration = ControllerCalibrationProfile()
    @Published private(set) var isCalibrating = false
    @Published private(set) var adjustmentBasis: simd_float4x4?
    @Published private(set) var reviewedThisSession = false
    @Published private(set) var canUndoCalibration = false
    private var previousCalibration: ControllerCalibrationProfile?
    private var calibrationUndo: [ControllerCalibrationProfile] = []
    private let calibrationKey = "surrealManualCalibrationV1"
    var isForeground = true
    @Published private(set) var isTracking = false
    private var sequence: UInt64 = 0

    private init() {
        reviewCalibrationOnStartup = UserDefaults.standard.object(forKey: "controllerCalibrationAtStartup") as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: calibrationKey),
           let saved = try? JSONDecoder().decode(ControllerCalibrationProfile.self, from: data), saved.isValid {
            calibration = saved
        }
        isEnabled = UserDefaults.standard.object(forKey: "surrealControllersEnabled") as? Bool ?? true
        showControllerOverlay = UserDefaults.standard.object(forKey: "surrealControllerOverlay") as? Bool ?? true
    }

    /// Owns the vendor runtime only while the immersive view's task is alive.
    /// This task does not wait for a hand anchor, a pinch, or hand-tracking updates.
    func run(headPoseAt: @escaping @MainActor (TimeInterval) -> simd_float4x4?) async {
        guard !isTracking else { return }
        isTracking = true
        WujiGloveManager.shared.start()
        reviewedThisSession = false
        var runtime: SurrealRuntime?
        var retryAt: TimeInterval = 0
        var lastDisplay: TimeInterval = 0
        defer {
            runtime?.close()
            WujiGloveManager.shared.stop()
            isTracking = false
            cancelCalibration()
            reviewedThisSession = false
            publishEmpty()
            setStatus("Controller tracking stopped")
        }
        while !Task.isCancelled {
            let now = CACurrentMediaTime()
            var frame = Handtracking_ControllerTracking()
            frame.version = 1
            frame.source = "surreal_touch"
            frame.enabled = isEnabled && isForeground
            frame.timestampNs = UInt64(now * 1_000_000_000)
            sequence &+= 1
            frame.sequence = sequence
#if targetEnvironment(simulator)
            setStatus("Controller hardware requires a Vision Pro")
#else
            if frame.enabled {
                if runtime == nil && now >= retryAt {
                    do {
                        runtime = try SurrealRuntime()
                        reviewedThisSession = false
                        adjustmentBasis = nil
                        setStatus("Pair Surreal Touch in Settings → Bluetooth")
                    } catch {
                        setStatus(error.localizedDescription)
                        retryAt = now + 2
                    }
                }
                if let activeRuntime = runtime {
                    do {
                        try activeRuntime.poll(into: &frame)
                        let count = [frame.left, frame.right].filter { $0.active }.count
                        setStatus(count == 0 ? "Waiting for Surreal Touch controllers" : "\(count) controller(s) active")
                    } catch {
                        activeRuntime.close()
                        runtime = nil
                        frame.left = Handtracking_ControllerState()
                        frame.right = Handtracking_ControllerState()
                        setStatus(error.localizedDescription)
                        retryAt = now + 2
                    }
                }
            } else {
                runtime?.close()
                runtime = nil
                retryAt = 0
                setStatus(isEnabled ? "Controller tracking paused" : "Controller tracking off")
            }
#endif
            // Head tracking is independent of whether a controller runtime is enabled.
            if let head = headPoseAt(now) {
                frame.headPose = createMatrix4x4(from: head)
                frame.headPoseValid = true
            }
            applyCalibration(to: &frame)
            frame.gloves = WujiGloveManager.shared.update(frame)
            Self.snapshots.update(frame)
            if now - lastDisplay >= 0.1 {
                displayFrame = frame
                lastDisplay = now
            }
            do { try await Task.sleep(nanoseconds: 11_111_111) } catch { break }
        }
    }

    func beginCalibration() {
        guard !isCalibrating else { return }
        previousCalibration = calibration
        calibrationUndo = []
        canUndoCalibration = false
        adjustmentBasis = nil
        isCalibrating = true
    }
    func captureAdjustmentBasis() {
        guard displayFrame.headPoseValid, displayFrame.hasHeadPose else { return }
        adjustmentBasis = controllerMatrix(displayFrame.headPose)
    }
    private func checkpointCalibration() {
        calibrationUndo.append(calibration)
        if calibrationUndo.count > 200 { calibrationUndo.removeFirst() }
        canUndoCalibration = true
    }
    func nudgeCalibration(target: Int, axis: Int, amount: Float, rotate: Bool) {
        guard isCalibrating, (0...4).contains(target), (0...2).contains(axis),
              target != 0 || adjustmentBasis != nil else { return }
        checkpointCalibration()
        calibration.nudge(target: target, axis: axis, amount: amount, rotate: rotate,
                          basis: adjustmentBasis ?? matrix_identity_float4x4)
    }
    func resetCalibrationTarget(_ target: Int) {
        guard isCalibrating else { return }
        checkpointCalibration()
        calibration.set(target, matrix_identity_float4x4)
    }
    func undoCalibration() {
        guard let previous = calibrationUndo.popLast() else { return }
        calibration = previous
        canUndoCalibration = !calibrationUndo.isEmpty
    }
    var canSaveCalibration: Bool {
        let gloves = WujiGloveManager.shared
        return isCalibrating && calibration.isValid && ControllerCalibrationProfile.trackingReady(
            side: gloves.trackingSide, head: displayFrame.headPoseValid,
            left: displayFrame.left.poseValid, right: displayFrame.right.poseValid)
    }
    func saveCalibration() {
        guard canSaveCalibration else { return }
        calibration.saved = true
        guard let data = try? JSONEncoder().encode(calibration) else { return }
        UserDefaults.standard.set(data, forKey: calibrationKey)
        reviewedThisSession = true
        previousCalibration = nil
        isCalibrating = false
        adjustmentBasis = nil
        calibrationUndo = []
        canUndoCalibration = false
    }
    func cancelCalibration() {
        guard isCalibrating else { return }
        if let previous = previousCalibration { calibration = previous }
        previousCalibration = nil
        isCalibrating = false
        adjustmentBasis = nil
        calibrationUndo = []
        canUndoCalibration = false
    }
    private func applyCalibration(to frame: inout Handtracking_ControllerTracking) {
        var metadata = Handtracking_ControllerCalibration()
        metadata.worldFromLocal = createMatrix4x4(from: calibration.matrix(0))
        metadata.leftGripOffset = createMatrix4x4(from: calibration.matrix(1))
        metadata.rightGripOffset = createMatrix4x4(from: calibration.matrix(2))
        metadata.leftWristOffset = createMatrix4x4(from: calibration.matrix(3))
        metadata.rightWristOffset = createMatrix4x4(from: calibration.matrix(4))
        metadata.saved = calibration.saved
        metadata.preview = isCalibrating
        metadata.reviewedThisSession = reviewedThisSession
        frame.calibration = metadata
        func correct(_ state: inout Handtracking_ControllerState, left: Bool) {
            guard state.active, state.poseValid, state.hasPose else { return }
            let raw = controllerMatrix(state.pose)
            let world = calibration.corrected(raw, left: left)
            // Vendor occasionally returns a flagged-valid pose around (100,100,-100)m.
            // Reject impossible room-scale measurements; inputs remain independent.
            let p = ControllerCalibrationProfile.xyz(raw.columns.3)
            let head = controllerMatrix(frame.headPose)
            let distance = simd_distance(ControllerCalibrationProfile.xyz(world.columns.3), ControllerCalibrationProfile.xyz(head.columns.3))
            let sentinel = abs(p.x - 100) < 1 && abs(p.y - 100) < 1 && abs(p.z + 100) < 1
            if sentinel || (frame.headPoseValid && distance > 10) || !ControllerCalibrationProfile.encode(world).allSatisfy(\.isFinite) {
                state.poseStatus = sentinel ? "SDK returned its untracked placeholder (100, 100, −100 m)"
                    : !ControllerCalibrationProfile.encode(world).allSatisfy(\.isFinite) ? "Calibration produced a non-finite pose"
                    : String(format: "Calibrated controller is %.1f m from head; check world alignment", distance)
                state.poseValid = false
                state.clearPose()
                state.clearPoseWorld()
            } else {
                state.poseWorld = createMatrix4x4(from: world)
            }
        }
        // Work on copies so the head metadata isn't accessed during an inout borrow.
        var left = frame.left
        var right = frame.right
        correct(&left, left: true)
        correct(&right, left: false)
        frame.left = left
        frame.right = right
    }

    private func setStatus(_ value: String) {
        if status != value { status = value }
    }

    private func publishEmpty() {
        var frame = Handtracking_ControllerTracking()
        frame.version = 1
        frame.source = "surreal_touch"
        frame.timestampNs = UInt64(CACurrentMediaTime() * 1_000_000_000)
        Self.snapshots.update(frame)
        displayFrame = frame
    }
}

/// Use the vendor's C interface directly so return codes, pointer lifetimes,
/// pose validity and inactive inputs are checked rather than copied from the demo.
@MainActor
private final class SurrealRuntime {
    private var instance: XrInstance?
    private var session: XrSession?
    private var actionSet: XrActionSet?
    private var localSpace: XrSpace?
    private var sides: [Side] = []

    private struct Input {
        let name: String
        let action: XrAction
        let isBoolean: Bool
    }
    private struct Side {
        let poseAction: XrAction
        let space: XrSpace
        let inputs: [Input]
    }
    private struct Failure: LocalizedError {
        let operation: String
        let code: XrResult
        var errorDescription: String? { "Surreal Touch: \(operation) failed (\(code.rawValue))" }
    }

    init() throws {
        do { try open() } catch { close(); throw error }
    }

    private func check(_ result: XrResult, _ operation: String) throws {
        guard result == XR_SUCCESS else { throw Failure(operation: operation, code: result) }
    }

    private func path(_ value: String) throws -> XrPath {
        var result: XrPath = 0
        try check(value.withCString { xrStringToPath(instance, $0, &result) }, "bind \(value)")
        return result
    }

    private func cString<T>(_ string: String, into tuple: inout T) {
        withUnsafeMutableBytes(of: &tuple) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in string.utf8.prefix(bytes.count - 1).enumerated() { bytes[index] = byte }
        }
    }

    private func action(_ name: String, type: XrActionType) throws -> XrAction {
        var info = XrActionCreateInfo()
        info.type = XR_TYPE_ACTION_CREATE_INFO
        info.actionType = type
        cString(name, into: &info.actionName)
        cString(name, into: &info.localizedActionName)
        var handle: XrAction?
        try check(xrCreateAction(actionSet, &info, &handle), "create \(name)")
        guard let handle else { throw Failure(operation: "create \(name)", code: XR_ERROR_HANDLE_INVALID) }
        return handle
    }

    private func open() throws {
        var instanceInfo = XrInstanceCreateInfo()
        instanceInfo.type = XR_TYPE_INSTANCE_CREATE_INFO
        cString("VisionProTeleop", into: &instanceInfo.applicationInfo.applicationName)
        try check(xrCreateInstance(&instanceInfo, &instance), "create instance")
        var sessionInfo = XrSessionCreateInfo()
        sessionInfo.type = XR_TYPE_SESSION_CREATE_INFO
        sessionInfo.systemId = 1 // Vendor native sample uses its sole system (no graphics binding).
        try check(xrCreateSession(instance, &sessionInfo, &session), "create session")

        var referenceInfo = XrReferenceSpaceCreateInfo()
        referenceInfo.type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO
        referenceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL
        referenceInfo.poseInReferenceSpace.orientation.w = 1
        try check(xrCreateReferenceSpace(session, &referenceInfo, &localSpace), "create local space")

        var setInfo = XrActionSetCreateInfo()
        setInfo.type = XR_TYPE_ACTION_SET_CREATE_INFO
        cString("teleop_controllers", into: &setInfo.actionSetName)
        cString("Teleop Controllers", into: &setInfo.localizedActionSetName)
        try check(xrCreateActionSet(instance, &setInfo, &actionSet), "create action set")

        var bindings: [XrActionSuggestedBinding] = []
        for side in ["left", "right"] {
            let poseAction = try action("\(side)_pose", type: XR_ACTION_TYPE_POSE_INPUT)
            bindings.append(XrActionSuggestedBinding(action: poseAction, binding: try path("/user/hand/\(side)/input/grip/pose")))
            var spaceInfo = XrActionSpaceCreateInfo()
            spaceInfo.type = XR_TYPE_ACTION_SPACE_CREATE_INFO
            spaceInfo.action = poseAction
            spaceInfo.poseInActionSpace.orientation.w = 1
            var space: XrSpace?
            try check(xrCreateActionSpace(session, &spaceInfo, &space), "create \(side) pose space")
            guard let space else { throw Failure(operation: "create space", code: XR_ERROR_HANDLE_INVALID) }
            // Store immediately so a later binding error still releases this space.
            sides.append(Side(poseAction: poseAction, space: space, inputs: []))
            let faces = side == "left" ? ["x", "y"] : ["a", "b"]
            let definitions: [(String, String, Bool)] = [
                (faces[0], "\(faces[0])/click", true),
                (faces[1], "\(faces[1])/click", true),
                ("menu", "menu/click", true),
                ("thumbstick", "thumbstick/click", true),
                ("trigger", "trigger/value", false),
                ("grip", "squeeze/value", false),
                ("thumbstick_x", "thumbstick/x", false),
                ("thumbstick_y", "thumbstick/y", false)
            ]
            var inputs: [Input] = []
            for (name, suffix, isBoolean) in definitions {
                let inputAction = try action("\(side)_\(name)", type: isBoolean ? XR_ACTION_TYPE_BOOLEAN_INPUT : XR_ACTION_TYPE_FLOAT_INPUT)
                bindings.append(XrActionSuggestedBinding(action: inputAction, binding: try path("/user/hand/\(side)/input/\(suffix)")))
                inputs.append(Input(name: name, action: inputAction, isBoolean: isBoolean))
            }
            sides[sides.count - 1] = Side(poseAction: poseAction, space: space, inputs: inputs)
        }
        var profile = XrInteractionProfileSuggestedBinding()
        profile.type = XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING
        profile.interactionProfile = try path("/interaction_profiles/surreal_interactive/surreal_touch")
        try bindings.withUnsafeBufferPointer { buffer in
            profile.suggestedBindings = buffer.baseAddress
            profile.countSuggestedBindings = UInt32(buffer.count)
            try check(xrSuggestInteractionProfileBindings(instance, &profile), "suggest bindings")
        }
        var attach = XrSessionActionSetsAttachInfo()
        attach.type = XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO
        attach.countActionSets = 1
        var set = actionSet
        try withUnsafePointer(to: &set) { pointer in
            attach.actionSets = pointer
            try check(xrAttachSessionActionSets(session, &attach), "attach inputs")
        }
    }

    func close() {
        // The pinned vendor binary declares but does not export xrDestroySpace.
        // Follow its native sample: discard space handles with their owning session.
        sides.removeAll()
        localSpace = nil
        if let session { _ = xrDestroySession(session) }
        session = nil
        if let actionSet { _ = xrDestroyActionSet(actionSet) }
        actionSet = nil
        if let instance { _ = xrDestroyInstance(instance) }
        instance = nil
    }

    func poll(into frame: inout Handtracking_ControllerTracking) throws {
        var sync = XrActionsSyncInfo()
        sync.type = XR_TYPE_ACTIONS_SYNC_INFO
        sync.countActiveActionSets = 1
        var active = XrActiveActionSet(actionSet: actionSet, subactionPath: 0)
        try withUnsafePointer(to: &active) { pointer in
            sync.activeActionSets = pointer
            try check(xrSyncActions(session, &sync), "read controllers")
        }
        frame.left = read(sides[0], timestamp: XrTime(frame.timestampNs))
        frame.right = read(sides[1], timestamp: XrTime(frame.timestampNs))
    }

    private func read(_ side: Side, timestamp: XrTime) -> Handtracking_ControllerState {
        var result = Handtracking_ControllerState()
        result.poseStatus = "Controller pose action inactive"
        for input in side.inputs {
            var item = Handtracking_ControllerInput()
            item.name = input.name
            item.isBoolean = input.isBoolean
            var info = XrActionStateGetInfo()
            info.type = XR_TYPE_ACTION_STATE_GET_INFO
            info.action = input.action
            if input.isBoolean {
                var state = XrActionStateBoolean()
                state.type = XR_TYPE_ACTION_STATE_BOOLEAN
                if xrGetActionStateBoolean(session, &info, &state) == XR_SUCCESS && state.isActive != 0 {
                    item.active = true
                    item.pressed = state.currentState != 0
                    item.value = item.pressed ? 1 : 0
                    item.lastChangeTimeNs = UInt64(max(0, state.lastChangeTime))
                }
            } else {
                var state = XrActionStateFloat()
                state.type = XR_TYPE_ACTION_STATE_FLOAT
                if xrGetActionStateFloat(session, &info, &state) == XR_SUCCESS && state.isActive != 0 && state.currentState.isFinite {
                    item.active = true
                    let isStick = input.name.hasPrefix("thumbstick_")
                    item.value = min(1, max(isStick ? -1 : 0, state.currentState))
                    // Trigger/grip presses are derived from their analog travel, not hand pinches.
                    item.pressed = !isStick && item.value >= 0.5
                    item.lastChangeTimeNs = UInt64(max(0, state.lastChangeTime))
                }
            }
            result.active = result.active || item.active
            result.inputs.append(item)
        }
        var info = XrActionStateGetInfo()
        info.type = XR_TYPE_ACTION_STATE_GET_INFO
        info.action = side.poseAction
        var poseState = XrActionStatePose()
        poseState.type = XR_TYPE_ACTION_STATE_POSE
        let poseResult = xrGetActionStatePose(session, &info, &poseState)
        if poseResult != XR_SUCCESS { result.poseStatus = "Pose action error \(poseResult.rawValue)" }
        if poseResult == XR_SUCCESS && poseState.isActive != 0 {
            result.active = true
            var location = XrSpaceLocation()
            location.type = XR_TYPE_SPACE_LOCATION
            let flags = XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT
            let locateResult = xrLocateSpace(side.space, localSpace, timestamp, &location)
            result.poseStatus = locateResult != XR_SUCCESS ? "Locate pose error \(locateResult.rawValue)"
                : "SDK position/orientation unavailable (flags \(location.locationFlags))"
            if locateResult == XR_SUCCESS && location.locationFlags & flags == flags {
                let p = location.pose.position
                let q = location.pose.orientation
                let vector = SIMD4<Float>(q.x, q.y, q.z, q.w)
                result.poseStatus = "SDK pose contains invalid numbers"
                if [p.x, p.y, p.z, q.x, q.y, q.z, q.w].allSatisfy({ $0.isFinite }) && simd_length(vector) > 0.001 {
                    var matrix = simd_float4x4(simd_normalize(simd_quatf(vector: vector)))
                    matrix.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
                    result.pose = createMatrix4x4(from: matrix)
                    result.poseValid = true
                    result.poseStatus = "Pose live"
                }
            }
        }
        return result
    }
}

struct SurrealControllerPanel: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var manager = SurrealControllerManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Surreal Touch controllers", isOn: $manager.isEnabled)
            Toggle("Show controller overlays", isOn: $manager.showControllerOverlay)
            WujiGlovePanel()
            Text("Cyan = left, orange = right. The ring marks the reported grip origin; each RGB axis is 10 cm with 2 cm ticks. The outlined grip is schematic, not a calibrated controller model. Overlays hide when poses are unavailable.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Manually calibrate controllers") {
                manager.beginCalibration()
                openWindow(id: "controllerCalibration")
            }
            Toggle("Review calibration each startup", isOn: $manager.reviewCalibrationOnStartup)
            Text(manager.isCalibrating ? "Manual calibration preview is live." : manager.reviewedThisSession ? "Manual calibration reviewed this session." : "Check alignment after starting or recentering tracking.")
                .font(.caption).foregroundStyle(.secondary)
            Text(manager.status).font(.callout).foregroundStyle(.secondary)
            Text("Pair both controllers in Settings → Bluetooth. Controller buttons and poses stream separately from your hands.")
                .font(.caption).foregroundStyle(.secondary)
            controller("Left", state: manager.displayFrame.left)
            controller("Right", state: manager.displayFrame.right)
            Text("Head-relative positions use the headset’s current position and rotation. X: right · Y: up · −Z: forward. Values are in meters.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
    private func controller(_ title: String, state: Handtracking_ControllerState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) · \(state.poseValid ? "Tracking" : state.active ? "Inputs active / pose unavailable" : "Inactive")")
                .font(.headline)
            if state.poseValid && manager.displayFrame.headPoseValid {
                Text(positionText(state.hasPoseWorld ? state.poseWorld : state.pose, head: manager.displayFrame.headPose))
                    .font(.system(.caption, design: .monospaced))
            }
            ForEach(state.inputs, id: \.name) { input in
                HStack {
                    Text(input.name.replacingOccurrences(of: "_", with: " ").capitalized)
                    Spacer()
                    Text(!input.active ? "Unavailable" : input.isBoolean ? (input.pressed ? "Pressed" : "Released") : String(format: "%.3f", input.value))
                        .foregroundStyle(input.pressed ? .green : .secondary)
                }.font(.caption)
            }
        }
    }
    private func positionText(_ pose: Handtracking_Matrix4x4, head: Handtracking_Matrix4x4) -> String {
        func matrix(_ m: Handtracking_Matrix4x4) -> simd_float4x4 {
            simd_float4x4(columns: (SIMD4(m.m00, m.m10, m.m20, m.m30), SIMD4(m.m01, m.m11, m.m21, m.m31), SIMD4(m.m02, m.m12, m.m22, m.m32), SIMD4(m.m03, m.m13, m.m23, m.m33)))
        }
        let position = (simd_inverse(matrix(head)) * matrix(pose)).columns.3
        return String(format: "Head-relative  X %+.3f  Y %+.3f  Z %+.3f", position.x, position.y, position.z)
    }
}


// MARK: - Passthrough controller pose debugging

/// Only the render system owns these entities; data comes from the same immutable
/// snapshot used by the network stream. This adds no ARKit session or hand dependency.
struct SurrealControllerOverlayComponent: Component {}

struct SurrealControllerOverlaySystem: System {
    private static let query = EntityQuery(where: .has(SurrealControllerOverlayComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let frame = SurrealControllerManager.snapshots.snapshot()
        let manager = SurrealControllerManager.shared
        let visible = (manager.showControllerOverlay || manager.isCalibrating) && manager.isEnabled && manager.isForeground && frame.enabled
        for root in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            for (name, state) in [("leftControllerOverlay", frame.left), ("rightControllerOverlay", frame.right), ("leftRawOverlay", frame.left), ("rightRawOverlay", frame.right)] {
                guard let marker = root.findEntity(named: name) else { continue }
                // Never leave a last-known pose looking like a live measurement.
                guard visible, (!name.contains("Raw") || manager.isCalibrating), state.active, state.poseValid, state.hasPose else {
                    marker.isEnabled = false
                    continue
                }
                let m = name.contains("Raw") ? state.pose : (state.hasPoseWorld ? state.poseWorld : state.pose)
                let transform = simd_float4x4(columns: (
                    SIMD4(m.m00, m.m10, m.m20, m.m30), SIMD4(m.m01, m.m11, m.m21, m.m31),
                    SIMD4(m.m02, m.m12, m.m22, m.m32), SIMD4(m.m03, m.m13, m.m23, m.m33)))
                guard (0..<4).allSatisfy({ column in
                    (0..<4).allSatisfy { row in transform[column][row].isFinite }
                }) else {
                    marker.isEnabled = false
                    continue
                }
                // Root is at ARKit world identity, just like the hand overlays.
                // Calibrated pose is exactly the one published to receivers.
                marker.setTransformMatrix(transform, relativeTo: root)
                marker.isEnabled = true
            }
        }
    }
}

@MainActor
func makeSurrealControllerOverlays() -> Entity {
    let root = Entity()
    root.name = "surrealControllerOverlays"
    root.components.set(SurrealControllerOverlayComponent())

    func material(_ color: UIColor) -> UnlitMaterial {
        var value = UnlitMaterial()
        value.color = .init(tint: color)
        return value
    }
    func segment(_ start: SIMD3<Float>, _ end: SIMD3<Float>, radius: Float,
                 material: UnlitMaterial, parent: Entity) {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0 else { return }
        let entity = ModelEntity(mesh: .generateCylinder(height: length, radius: radius), materials: [material])
        entity.position = (start + end) / 2
        entity.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
        parent.addChild(entity)
    }
    for (side, color, letter) in [
        ("left", UIColor(red: 0.2, green: 0.9, blue: 0.85, alpha: 1), "L"),
        ("right", UIColor(red: 1, green: 0.65, blue: 0.25, alpha: 1), "R")
    ] {
        let rawMarker = Entity()
        rawMarker.name = "\(side)RawOverlay"
        rawMarker.isEnabled = false
        for axis in [SIMD3<Float>(1,0,0), SIMD3<Float>(0,1,0), SIMD3<Float>(0,0,1)] {
            segment(-axis * 0.015, axis * 0.015, radius: 0.0008, material: material(.lightGray), parent: rawMarker)
        }
        root.addChild(rawMarker)
        let marker = Entity()
        marker.name = "\(side)ControllerOverlay"
        marker.isEnabled = false
        root.addChild(marker)
        let accent = material(color)
        // 5 cm diameter ring and 6 mm diameter center mark locate the grip origin.
        let center = ModelEntity(mesh: .generateSphere(radius: 0.003), materials: [accent])
        marker.addChild(center)
        for i in 0..<32 {
            let a = Float(i) * 2 * .pi / 32
            let b = Float(i + 1) * 2 * .pi / 32
            segment(SIMD3(cos(a) * 0.025, sin(a) * 0.025, 0),
                    SIMD3(cos(b) * 0.025, sin(b) * 0.025, 0),
                    radius: 0.0007, material: accent, parent: marker)
        }
        // Open wire guide keeps the physical shell visible through passthrough.
        let corners: [SIMD3<Float>] = [
            [-0.025, -0.09, -0.025], [0.025, -0.09, -0.025],
            [0.025, 0.025, -0.025], [-0.025, 0.025, -0.025],
            [-0.025, -0.09, 0.025], [0.025, -0.09, 0.025],
            [0.025, 0.025, 0.025], [-0.025, 0.025, 0.025]
        ]
        for (a, b) in [(0,1),(1,2),(2,3),(3,0),(4,5),(5,6),(6,7),(7,4),(0,4),(1,5),(2,6),(3,7)] {
            segment(corners[a], corners[b], radius: 0.0006, material: accent, parent: marker)
        }
        for (direction, color, perpendicular) in [
            (SIMD3<Float>(1, 0, 0), UIColor.systemRed, SIMD3<Float>(0, 1, 0)),
            (SIMD3<Float>(0, 1, 0), UIColor.systemGreen, SIMD3<Float>(1, 0, 0)),
            (SIMD3<Float>(0, 0, 1), UIColor.systemBlue, SIMD3<Float>(0, 1, 0))
        ] {
            let axisMaterial = material(color)
            segment(.zero, direction * 0.1, radius: 0.001, material: axisMaterial, parent: marker)
            for tick in 1...5 {
                let point = direction * Float(tick) * 0.02
                segment(point - perpendicular * 0.004, point + perpendicular * 0.004,
                        radius: 0.0006, material: axisMaterial, parent: marker)
            }
        }
        // The short white arrow points along controller-local -Z.
        let white = material(.white)
        segment(.zero, SIMD3(0, 0, -0.08), radius: 0.0008, material: white, parent: marker)
        segment(SIMD3(-0.008, 0, -0.067), SIMD3(0, 0, -0.08), radius: 0.0008, material: white, parent: marker)
        segment(SIMD3(0.008, 0, -0.067), SIMD3(0, 0, -0.08), radius: 0.0008, material: white, parent: marker)
        let labelMesh = MeshResource.generateText(letter, extrusionDepth: 0.0003,
                                                  font: .systemFont(ofSize: 0.018, weight: .bold))
        let label = ModelEntity(mesh: labelMesh, materials: [accent])
        label.position = SIMD3(-0.006, 0.04, 0)
        marker.addChild(label)
    }
    return root
}

func controllerMatrix(_ m: Handtracking_Matrix4x4) -> simd_float4x4 {
    simd_float4x4(columns: (SIMD4(m.m00, m.m10, m.m20, m.m30), SIMD4(m.m01, m.m11, m.m21, m.m31),
                          SIMD4(m.m02, m.m12, m.m22, m.m32), SIMD4(m.m03, m.m13, m.m23, m.m33)))
}
