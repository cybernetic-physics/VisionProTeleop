import SwiftUI
import RealityKit
import Network
import QuartzCore
import simd

@MainActor
final class WujiGloveManager: ObservableObject {
    static let shared = WujiGloveManager()
    @Published var showOverlay = UserDefaults.standard.object(forKey: "wujiOverlay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showOverlay, forKey: "wujiOverlay") }
    }
    @Published var trackingSide = UserDefaults.standard.string(forKey: "wujiTrackingSide") ?? "left" {
        didSet { UserDefaults.standard.set(trackingSide, forKey: "wujiTrackingSide") }
    }
    func includes(_ side: String) -> Bool { trackingSide == "both" || trackingSide == side }
    @Published private(set) var networkStatus = "Starts with immersive tracking"
    @Published private(set) var leftStatus = "Waiting for glove"
    @Published private(set) var rightStatus = "Waiting for glove"
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var packets: [String: WujiSkeletonPacket] = [:]
    private var timeline = ControllerPoseTimeline()
    private var lastDisplay: Double = 0
    private var generation = UUID()

    func start() {
        guard listener == nil else { return }
        generation = UUID()
        let current = generation
        do {
            let listener = try NWListener(using: .udp, on: 12346)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    switch state {
                    case .ready: self.networkStatus = "Listening for Thor · UDP 12346"
                    case .failed(let error): self.networkStatus = "Glove receiver: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.generation == current else { connection.cancel(); return }
                    if self.connections.count >= 4 { self.connections.removeFirst().cancel() }
                    self.connections.append(connection)
                    connection.start(queue: .main)
                    self.receive(connection, generation: current)
                }
            }
            listener.start(queue: .main)
        } catch { networkStatus = "Glove receiver: \(error.localizedDescription)" }
    }
    func stop() {
        generation = UUID()
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections = []
        packets = [:]
        timeline.clear()
        networkStatus = "Glove receiver stopped"
        leftStatus = "Waiting for glove"
        rightStatus = "Waiting for glove"
    }
    private func receive(_ connection: NWConnection, generation: UUID) {
        connection.receiveMessage { [weak self] data, _, _, error in
            let receivedAt = CACurrentMediaTime()
            Task { @MainActor in
                guard let self, self.generation == generation, error == nil else { return }
                if let data, data.count <= 8192 { self.accept(data, at: receivedAt, connection: connection) }
                self.receive(connection, generation: generation)
            }
        }
    }
    private func accept(_ data: Data, at receivedAt: Double, connection: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String else { return }
        if kind == "ping", let t0 = object["t0"] as? Double, t0.isFinite,
           let nonce = object["nonce"] as? String, nonce.count < 80 {
            let response: [String: Any] = ["kind": "pong", "nonce": nonce, "t0": t0,
                                            "t1": receivedAt, "t2": CACurrentMediaTime()]
            if let reply = try? JSONSerialization.data(withJSONObject: response) {
                connection.send(content: reply, completion: .contentProcessed { _ in })
            }
            return
        }
        guard let packet = try? JSONDecoder().decode(WujiSkeletonPacket.self, from: data),
              packet.valid(at: receivedAt) else { return }
        if let previous = packets[packet.side] {
            guard packet.headsetTime > previous.headsetTime else { return }
            if packet.session == previous.session && packet.sequence <= previous.sequence { return }
        }
        packets[packet.side] = packet
    }
    func update(_ frame: Handtracking_ControllerTracking) -> Handtracking_WujiGloveTracking {
        let now = Double(frame.timestampNs) / 1e9
        timeline.append(.init(time: now,
            left: frame.enabled && frame.left.poseValid && frame.left.hasPose ? controllerMatrix(frame.left.pose) : nil,
            right: frame.enabled && frame.right.poseValid && frame.right.hasPose ? controllerMatrix(frame.right.pose) : nil,
            head: frame.headPoseValid ? controllerMatrix(frame.headPose) : nil))
        var result = Handtracking_WujiGloveTracking()
        result.version = 1
        result.left = fuse(side: "left", now: now)
        result.right = fuse(side: "right", now: now)
        // Explain missing current tracking before the less specific history-match message.
        for side in ["left", "right"] {
            let controller = side == "left" ? frame.left : frame.right
            var state = side == "left" ? result.left : result.right
            if state.status == "Waiting for matching controller/head pose" {
                if !frame.enabled { state.status = "Controller tracking is disabled or paused" }
                else if !controller.poseValid {
                    state.status = "\(side.capitalized) controller: \(controller.poseStatus.isEmpty ? "pose unavailable" : controller.poseStatus)"
                } else if !frame.headPoseValid { state.status = "Waiting for head tracking" }
                if side == "left" { result.left = state } else { result.right = state }
            }
        }
        if now - lastDisplay > 0.1 {
            leftStatus = result.left.status
            rightStatus = result.right.status
            lastDisplay = now
        }
        return result
    }
    private func fuse(side: String, now: Double) -> Handtracking_WujiGloveState {
        var result = Handtracking_WujiGloveState()
        result.status = "Not selected"
        guard includes(side) else { return result }
        result.status = "Waiting for glove"
        guard let packet = packets[side] else { return result }
        result.serial = packet.serial
        result.sequence = packet.sequence
        result.sourceTimestampUs = packet.sourceTimestampUs
        result.timestampNs = UInt64(max(0, packet.headsetTime) * 1e9)
        result.uncertaintyMs = Float(packet.uncertaintyMs)
        guard packet.valid(at: now) else { result.status = "Glove stale / timing unavailable"; return result }
        guard packet.confidence.allSatisfy({ $0 >= 0.5 }) else { result.status = "Glove confidence below 50%"; return result }
        guard let pose = timeline.pose(at: packet.headsetTime, side: side) else {
            result.status = "Waiting for matching controller/head pose"
            return result
        }
        let profile = SurrealControllerManager.shared.calibration
        let wrist = profile.matrix(0) * pose.controller * profile.matrix(side == "left" ? 3 : 4)
        result.valid = true
        result.pointsWrist = packet.points.flatMap { $0 }
        result.confidence = packet.confidence
        result.wristWorld = createMatrix4x4(from: wrist)
        result.headWorld = createMatrix4x4(from: pose.head)
        result.status = String(format: "Live · %.0f ms old · clock est. ±%.1f ms", (now - packet.headsetTime) * 1000, packet.uncertaintyMs)
        return result
    }
}

struct WujiGlovePanel: View {
    @ObservedObject private var gloves = WujiGloveManager.shared
    @ObservedObject private var controllers = SurrealControllerManager.shared
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var startingTracking = false
    @State private var startMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !controllers.isTracking {
                Label("Tracking not started", systemImage: "pause.circle").foregroundStyle(.orange)
                Text("Start tracking here to connect the glove and controller, then calibrate using the live overlay.")
                    .font(.callout)
                Button(startingTracking ? "Starting tracking…" : "Start tracking") {
                    startingTracking = true
                    startMessage = nil
                    Task { @MainActor in
                        defer { startingTracking = false }
                        SignalingClient.shared.connect()
                        DataManager.shared.crossNetworkRoomCode = SignalingClient.shared.roomCode
                        let result = await openImmersiveSpace(id: "combinedStreamSpace")
                        if case .opened = result {
                            controllers.beginCalibration()
                        } else {
                            startMessage = "Tracking did not open. Close any other immersive app and try again."
                        }
                    }
                }.buttonStyle(.borderedProminent).disabled(startingTracking)
                if let startMessage { Text(startMessage).font(.caption).foregroundStyle(.orange) }
            } else if !controllers.isEnabled {
                Button("Enable controller tracking") { controllers.isEnabled = true }
                Text("The glove needs its controller pose to appear in space.").font(.caption)
            }
            Picker("Glove setup", selection: $gloves.trackingSide) {
                Text("Left only").tag("left")
                Text("Right only").tag("right")
                Text("Both hands").tag("both")
            }.pickerStyle(.segmented)
            Toggle("Show Wuji glove skeletons", isOn: $gloves.showOverlay)
            if controllers.isTracking {
                Text(gloves.networkStatus).font(.caption).foregroundStyle(.secondary)
                if gloves.includes("left") { Text("Left: \(gloves.leftStatus)").font(.caption).foregroundStyle(.cyan) }
                if gloves.includes("right") { Text("Right: \(gloves.rightStatus)").font(.caption).foregroundStyle(.orange) }
            }
            Text("Glove fingers + controller wrist tracking. Adjust Left/Right Wuji wrist in manual calibration. Low-confidence, stale, or unmatched data hides the skeleton.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct WujiGloveOverlayComponent: Component {}
struct WujiGloveOverlaySystem: System {
    private static let query = EntityQuery(where: .has(WujiGloveOverlayComponent.self))
    static let edges: [(Int, Int)] = (0..<5).flatMap { finger in
        let first = finger * 4 + 1
        return [(0, first), (first, first + 1), (first + 1, first + 2), (first + 2, first + 3)]
    }
    init(scene: RealityKit.Scene) {}
    func update(context: SceneUpdateContext) {
        let frame = SurrealControllerManager.snapshots.snapshot()
        let manager = SurrealControllerManager.shared
        let visible = WujiGloveManager.shared.showOverlay && manager.isForeground && frame.enabled
        for root in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            for (side, state) in [("left", frame.gloves.left), ("right", frame.gloves.right)] {
                guard let hand = root.findEntity(named: "wuji-\(side)") else { continue }
                let age = CACurrentMediaTime() - Double(state.timestampNs) / 1e9
                hand.isEnabled = visible && state.valid && age >= -0.02 && age < 0.25 && state.pointsWrist.count == 63
                guard hand.isEnabled else { continue }
                hand.setTransformMatrix(controllerMatrix(state.wristWorld), relativeTo: root)
                let points = (0..<21).map { i in SIMD3<Float>(state.pointsWrist[i*3], state.pointsWrist[i*3+1], state.pointsWrist[i*3+2]) }
                for i in 0..<21 { hand.findEntity(named: "joint-\(i)")?.position = points[i] }
                for (i, edge) in Self.edges.enumerated() {
                    guard let bone = hand.findEntity(named: "bone-\(i)") else { continue }
                    let a = points[edge.0], b = points[edge.1], delta = b - a
                    let length = simd_length(delta)
                    bone.isEnabled = length > 0.0001
                    if bone.isEnabled {
                        bone.position = (a + b) / 2
                        bone.scale = SIMD3(1, length, 1)
                        bone.orientation = simd_quatf(from: SIMD3(0, 1, 0), to: delta / length)
                    }
                }
            }
        }
    }
}

@MainActor
func makeWujiGloveOverlays() -> Entity {
    let root = Entity()
    root.components.set(WujiGloveOverlayComponent())
    for side in ["left", "right"] {
        let hand = Entity()
        hand.name = "wuji-\(side)"
        hand.isEnabled = false
        let material = UnlitMaterial(color: side == "left" ? .cyan : .orange)
        for i in 0..<21 {
            let joint = ModelEntity(mesh: .generateSphere(radius: i == 0 ? 0.006 : 0.003), materials: [material])
            joint.name = "joint-\(i)"
            hand.addChild(joint)
        }
        for i in WujiGloveOverlaySystem.edges.indices {
            let bone = ModelEntity(mesh: .generateCylinder(height: 1, radius: 0.0015), materials: [material])
            bone.name = "bone-\(i)"
            hand.addChild(bone)
        }
        let label = ModelEntity(mesh: .generateText(side == "left" ? "L WUJI WRIST" : "R WUJI WRIST",
            extrusionDepth: 0.0002, font: .systemFont(ofSize: 0.012)), materials: [material])
        label.position = SIMD3(0.01, 0.02, 0)
        hand.addChild(label)
        root.addChild(hand)
    }
    return root
}

/// Starts optical hand/head streaming without a controller or glove calibration gate.
struct VisionProHandsStartButton: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var starting = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(starting ? "Starting optical hands…" : "Use Vision Pro hands only") {
                starting = true
                message = nil
                Task { @MainActor in
                    defer { starting = false }
                    let controller = SurrealControllerManager.shared
                    controller.cancelCalibration()
                    controller.isEnabled = false
                    controller.reviewCalibrationOnStartup = false
                    controller.showControllerOverlay = false
                    WujiGloveManager.shared.showOverlay = false
                    DataManager.shared.showHandJoints = true
                    DataManager.shared.handPredictionOffset = 0
                    if controller.isTracking { dismissWindow(); return }
                    SignalingClient.shared.connect()
                    DataManager.shared.crossNetworkRoomCode = SignalingClient.shared.roomCode
                    if case .opened = await openImmersiveSpace(id: "combinedStreamSpace") {
                        dismissWindow()
                    } else { message = "Could not start tracking. Close any other immersive app and try again." }
                }
            }.buttonStyle(.borderedProminent).disabled(starting)
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
    }
}
