import SwiftUI
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
    @Published private(set) var status = "Start streaming to connect controllers"
    @Published private(set) var displayFrame = Handtracking_ControllerTracking()
    var isForeground = true
    private var running = false
    private var sequence: UInt64 = 0

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: "surrealControllersEnabled") as? Bool ?? true
    }

    /// Owns the vendor runtime only while the immersive view's task is alive.
    /// This task does not wait for a hand anchor, a pinch, or hand-tracking updates.
    func run(headPoseAt: @escaping @MainActor (TimeInterval) -> simd_float4x4?) async {
        guard !running else { return }
        running = true
        var runtime: SurrealRuntime?
        var retryAt: TimeInterval = 0
        var lastDisplay: TimeInterval = 0
        defer {
            runtime?.close()
            running = false
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
                        setStatus("Pair Surreal Touch in Settings → Bluetooth")
                    } catch {
                        setStatus(error.localizedDescription)
                        retryAt = now + 2
                    }
                }
                if let activeRuntime = runtime {
                    do {
                        try activeRuntime.poll(into: &frame)
                        if let head = headPoseAt(now) {
                            frame.headPose = createMatrix4x4(from: head)
                            frame.headPoseValid = true
                        }
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
            Self.snapshots.update(frame)
            if now - lastDisplay >= 0.1 {
                displayFrame = frame
                lastDisplay = now
            }
            do { try await Task.sleep(nanoseconds: 11_111_111) } catch { break }
        }
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
        if xrGetActionStatePose(session, &info, &poseState) == XR_SUCCESS && poseState.isActive != 0 {
            result.active = true
            var location = XrSpaceLocation()
            location.type = XR_TYPE_SPACE_LOCATION
            let flags = XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT
            if xrLocateSpace(side.space, localSpace, timestamp, &location) == XR_SUCCESS && location.locationFlags & flags == flags {
                let p = location.pose.position
                let q = location.pose.orientation
                let vector = SIMD4<Float>(q.x, q.y, q.z, q.w)
                if [p.x, p.y, p.z, q.x, q.y, q.z, q.w].allSatisfy({ $0.isFinite }) && simd_length(vector) > 0.001 {
                    var matrix = simd_float4x4(simd_normalize(simd_quatf(vector: vector)))
                    matrix.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
                    result.pose = createMatrix4x4(from: matrix)
                    result.poseValid = true
                }
            }
        }
        return result
    }
}

struct SurrealControllerPanel: View {
    @ObservedObject private var manager = SurrealControllerManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Surreal Touch controllers", isOn: $manager.isEnabled)
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
                Text(positionText(state.pose, head: manager.displayFrame.headPose))
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
