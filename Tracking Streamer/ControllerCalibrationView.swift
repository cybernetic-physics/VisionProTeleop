import SwiftUI
import simd

struct ControllerCalibrationView: View {
    @ObservedObject private var manager = SurrealControllerManager.shared
    @ObservedObject private var gloves = WujiGloveManager.shared
    @ObservedObject private var dataManager = DataManager.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var target = 0
    @State private var step = 1
    private let distances: [Float] = [0.001, 0.005, 0.02]
    private let angles: [Float] = [0.25, 1, 5]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "viewfinder").font(.largeTitle).foregroundStyle(.cyan)
                    VStack(alignment: .leading) {
                        Text("Place your controllers").font(.title2.bold())
                        Text("Manual calibration · live preview").foregroundStyle(.secondary)
                    }
                }
                VisionProHandsStartButton()
                Text("Cyan is left. Orange is right. Match the colored ring to a repeatable point on each physical grip, then check several wrist rotations and arm positions. White crosses show the original SDK positions.")
                    .font(.callout)
                Text("Nothing snaps to your hands. These fixed adjustments are shared by the headset overlays, recordings, and the updated Python SDK.")
                    .font(.caption).foregroundStyle(.secondary)
                if manager.isTracking { HStack {
                    if gloves.includes("left") { poseStatus("Left", state: manager.displayFrame.left) }
                    if gloves.includes("right") { poseStatus("Right", state: manager.displayFrame.right) }
                    Label(manager.displayFrame.headPoseValid ? "Head tracked" : "Waiting for head", systemImage: "visionpro")
                }.font(.caption) }
                Toggle("Review calibration each startup", isOn: $manager.reviewCalibrationOnStartup)
                Toggle("Show hand skeleton reference", isOn: $dataManager.showHandJoints)
                WujiGlovePanel()
                Divider()
                Picker("Adjust", selection: $target) {
                    Text("Both · world alignment").tag(0)
                    Text("Left · grip offset").tag(1)
                    Text("Right · grip offset").tag(2)
                    if gloves.includes("left") { Text("Left · Wuji wrist").tag(3) }
                    if gloves.includes("right") { Text("Right · Wuji wrist").tag(4) }
                }.pickerStyle(.menu)
                Text(target == 0
                     ? "First adjust both controllers together. Move uses the directions you capture below; rotation pivots around that captured head position. Those directions stay fixed when you turn your head."
                     : target >= 3 ? "Align the Wuji skeleton with your gloved hand. Translation follows the raw controller axes; rotation turns the glove skeleton around its wrist. This mounting transform is separate from the controller grip offset. Start with an open hand, then check curled fingers and wrist rotations."
                     : "Fine-tune this grip in the raw controller’s own axes: red X, green Y, blue Z. Its offset will rotate with the physical controller. The wire outline is only a guide, not a scanned shell.")
                    .font(.caption).foregroundStyle(.secondary)
                if target == 0 {
                    Button(manager.adjustmentBasis == nil ? "Capture adjustment directions from my view" : "Recapture adjustment directions from my view") {
                        manager.captureAdjustmentBasis()
                    }.disabled(!manager.displayFrame.headPoseValid)
                    if manager.adjustmentBasis == nil {
                        Text("Look straight ahead and capture directions to enable world adjustments.").font(.caption).foregroundStyle(.orange)
                    }
                }
                Picker("Step", selection: $step) {
                    Text("Fine · 1 mm / ¼°").tag(0)
                    Text("Medium · 5 mm / 1°").tag(1)
                    Text("Coarse · 2 cm / 5°").tag(2)
                }.pickerStyle(.segmented)
                VStack(spacing: 10) {
                    nudgeRow("Move X", axis: 0, rotate: false, minus: target == 0 ? "Left" : "−X", plus: target == 0 ? "Right" : "+X")
                    nudgeRow("Move Y", axis: 1, rotate: false, minus: target == 0 ? "Down" : "−Y", plus: target == 0 ? "Up" : "+Y")
                    nudgeRow("Move Z", axis: 2, rotate: false, minus: target == 0 ? "Forward" : "−Z", plus: target == 0 ? "Back" : "+Z")
                    nudgeRow("Rotate X", axis: 0, rotate: true, minus: "−", plus: "+")
                    nudgeRow("Rotate Y", axis: 1, rotate: true, minus: "−", plus: "+")
                    nudgeRow("Rotate Z", axis: 2, rotate: true, minus: "−", plus: "+")
                }.disabled(!manager.isCalibrating || (target == 0 && manager.adjustmentBasis == nil))
                let m = manager.calibration.matrix(target)
                Text(String(format: "Offset  X %+.1f   Y %+.1f   Z %+.1f cm", m[3][0] * 100, m[3][1] * 100, m[3][2] * 100))
                    .font(.system(.caption, design: .monospaced))
                HStack {
                    Button("Undo last adjustment") { manager.undoCalibration() }.disabled(!manager.canUndoCalibration)
                    Button("Reset selected adjustment") { manager.resetCalibrationTarget(target) }
                }
                Divider()
                Text("Before saving: move both hands forward, sideways, and rotate your wrists. Turn your head while holding the controllers still. The overlays should stay on the same physical grip points. Recheck after recentering or restarting tracking.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel / keep previous") {
                        manager.cancelCalibration()
                        dismissWindow()
                    }
                    Spacer()
                    Button("Save & use calibration") {
                        manager.saveCalibration()
                        dismissWindow()
                    }.buttonStyle(.borderedProminent)
                        .disabled(!manager.canSaveCalibration)
                }
                Text("Saving requires head tracking and the controller(s) selected in Glove setup. An unused hand never blocks calibration.").font(.caption).foregroundStyle(.secondary)
                if manager.isTracking && !manager.isCalibrating {
                    Button("Begin calibration") { manager.beginCalibration() }
                }
            }.padding(28)
        }
        .frame(width: 700, height: 820)
        .onAppear { if manager.isTracking { manager.beginCalibration() } }
        .onChange(of: manager.isTracking) { _, tracking in
            if tracking { manager.beginCalibration() }
        }
        .onChange(of: gloves.trackingSide) { _, _ in target = 0 }
        .onDisappear { manager.cancelCalibration() }
    }
    private func poseStatus(_ title: String, state: Handtracking_ControllerState) -> some View {
        Label("\(title): \(state.poseValid ? "pose live" : "pose unavailable")", systemImage: state.poseValid ? "checkmark.circle" : "exclamationmark.circle")
            .foregroundStyle(state.poseValid ? Color.green : Color.orange)
    }
    private func nudgeRow(_ title: String, axis: Int, rotate: Bool, minus: String, plus: String) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Button(minus) { nudge(axis, rotate, -1) }.frame(maxWidth: .infinity)
            Text(rotate ? String(format: "%.2g°", angles[step]) : String(format: "%.0f mm", distances[step] * 1000))
                .font(.system(.caption, design: .monospaced)).frame(width: 70)
            Button(plus) { nudge(axis, rotate, 1) }.frame(maxWidth: .infinity)
        }
    }
    private func nudge(_ axis: Int, _ rotate: Bool, _ sign: Float) {
        manager.nudgeCalibration(target: target, axis: axis,
            amount: sign * (rotate ? angles[step] * .pi / 180 : distances[step]), rotate: rotate)
    }
}
