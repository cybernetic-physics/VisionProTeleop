# Vision Pro optical hands → Mink → G1-Dredd + Wuji Hand 2

Use bare hands in Tracking Streamer (build 24 or newer), with **Use Vision Pro hands only** selected. No wearable gloves or Surreal controllers are needed. Left-only, right-only and both-hand operation are supported.

The Python companion solves the selected G1 arm(s) with **Mink 1.3**, MuJoCo and DAQP. It publishes 14 arm targets through G1-Dredd's existing packed `arm` interface. Dredd remains the sole Unitree body writer and consumes those targets in **reference** mode. The shared `WujiHandBackend` separately retargets 21 optical landmarks to each selected hand's **20 real finger joints** using the Wuji SDK. It does not squeeze Wuji commands into Dredd's 7-slot Dex3 buffers.

## Installed paths on Thor

- Dredd: `~/Projects/dredd-teach-mode-adam/services/g1-dredd`
- Shared adapter: `~/Projects/shoot/sharewear/src/sharewear/dredd_mink.py`
- Session/transport: `~/Projects/shoot/sharewear/src/sharewear/dredd_session.py`
- Python: `~/Projects/shoot/sharewear/.venv/bin/python`
- Default model: Dredd repository's `.third_party/src/GR00T-WholeBodyControl/gear_sonic_deploy/g1/g1_29dof.xml`

Install the optional dependencies into an isolated Python 3.12 environment:

```bash
cd ~/Projects/shoot
uv pip install --python sharewear/.venv/bin/python -e 'sharewear[mink,wuji]'
```

## Dredd setup

Build the updated Dredd binary. The companion requires the new measured-state/ownership telemetry; older binaries remain usable for their existing modes but cannot enable this companion. On this Thor the pinned TensorRT distribution has a Debian layout, exposed through an include/lib symlink directory for Dredd's build:

```bash
cd ~/Projects/dredd-teach-mode-adam/services/g1-dredd
SONIC_TENSORRT_ROOT="$HOME/Projects/dredd-teach-mode-adam/.third_party/install/tensorrt-10.13.3.9-dredd-layout" \
  ~/.cargo/bin/cargo build --offline --release -p dredd --bin dredd --features hardware
```

Add these flags to the commissioned Dredd launch command that already specifies the robot interface, engines and observation/motion assets:

```text
--arm-source zmq --arm-owner reference --no-hand-output
--arm-zmq-host 127.0.0.1 --arm-zmq-port 5570
--publish-output true --zmq-out-port 5557
```

Use the existing gamepad/keyboard body input, **not the built-in AVP finger/arm bridge at the same time**. Dredd's initialization, balance policy and operator stop retain their existing behavior. `--no-hand-output` does not suppress the body startup ramp. Keep Dredd's normal stop control available. Do not start a second body controller alongside it.

## Preview, calibrate, then control

Run the companion on **the same Thor host as Dredd**: freshness checks compare their `CLOCK_MONOTONIC` timestamps. The headset can stream over the LAN. Defaults are headset `192.168.50.236`, Dredd feedback port `5557`, arm port `5570`.

Start with a preview; it creates no arm publisher and does not access Wuji hardware:

```bash
cd ~/Projects/shoot
sharewear/.venv/bin/python -m sharewear.dredd_session --hands left
```

Once Dredd is in CONTROL, hold your bare hand in a comfortable neutral pose, look approximately forward, type **c**, and press Enter. The status should move from reacquiring to live. Preview computes the same IK and writes `/tmp/dredd-wuji-mink.json` (targets, arm joints, per-side state, head pose), without sending commands. Add `--wuji-feedback` to read actual Wuji feedback and evaluate SDK retargeting without enabling its motors.

For the coordinated arm + Wuji session:

```bash
cd ~/Projects/shoot
sharewear/.venv/bin/python -m sharewear.dredd_session \
  --hands left --enable-arms --enable-motors
```

Capture neutral with **c + Enter**. Use `--hands right` or `--hands both` for those setups. An unselected Wuji hand is never connected or enabled. The unselected G1 arm receives its measured pose in the 14-joint reference. `--enable-arms` alone sends arm targets while leaving Wuji hardware alone. Both flags are explicit; neither is the default.

**q + Enter** or Ctrl-C releases the external arm source and disables the Wuji motors owned by this process. Dredd continues to own body balance; use its own operator stop to stop Dredd. A Dredd stop, stale measured-state stream, released arm ownership or changed ownership configuration stops the companion and disables its Wuji output. Restart and recapture neutral after these events.

## Coordinates and recovery

- The model's fixed-pelvis frame is the robot reference. Only selected arm DOFs can change; leg, waist and unselected-arm IK velocities are fixed at zero. Measured body joints refresh the kinematic geometry every cycle.
- Neutral capture stores measured robot wrist poses and optical wrist poses. The headset's yaw defines forward once: ARKit right/up/back becomes robot forward/left/up. Translation is mapped 1:1 with a 45 cm displacement leash. Wrist rotation is relative to neutral, so an arbitrary operator wrist orientation does not snap the robot to it.
- Head rotation after calibration does **not** steer the arms. This is a calibrated pelvis-relative manipulation reference, not head-following or whole-body walking retargeting.
- A missing/stale optical wrist holds that side at the measured robot joint pose captured on loss. The other selected side continues. Return requires 300 ms and at least five distinct samples. The returning arm re-anchors at the held pose, so motion made while out of sight is not replayed. Finger tracking resumes through its own bounded-speed gate.
- A new headset streaming session invalidates the arm calibration. Capture neutral again. This differs from a brief occlusion within one session, which resumes automatically.
- Defaults: arm target speed 0.5 rad/s, finger target speed 1.5 rad/s, Wuji current limit 0.5 A. Joint bounds, bounded command lead, fresh feedback, SDK diagnostics, exclusive Wuji ownership and the backend's independent stall watchdog remain enforced.

## Hardware and validation boundaries

The Wuji backend verifies each configured robot hand's serial, IP, handedness, node IDs and 20-joint count. Defaults are left `WH2JA01260820042` at `192.168.1.110`, right `WH2KA01260824015` at `192.168.1.111`; these are robot-hand addresses, not wearable gloves.

The IK target is the **G1 wrist-yaw mounting frame**. The supplied 29-DOF G1 model contains factory rubber-hand geometry, not a measured Wuji mounting assembly. This integration does not claim calibrated Wuji palm/tool offsets, finger collision geometry, hand payload inertia, or dynamic whole-body policy validation with that payload. Dredd's existing collision guard likewise retains its existing hand model. Actual Wuji mounts and payload behavior need a physical commissioning check before unrestricted arm motion. The existing Surreal G1 Thor GUI is unchanged; this is the separate Mink-to-Dredd companion.

Automated checks exercise the actual Mink/MuJoCo model, axis mapping, per-side selection, speed bounds, optical loss/recovery, telemetry freshness, coordinated stop, preview output isolation, real ZMQ transport, real Wuji SDK 20-joint retargeting, and a Python-produced packet decoded by Dredd's Rust arm owner. These are offline checks; they do not demonstrate live headset-to-whole-body performance.

```bash
cd ~/Projects/shoot
sharewear/.venv/bin/pytest -q sharewear/tests Humanoid-Teleop/tests
```

## Validation on Thor (2026-09-19)

- Python: 88 tests passed across Sharewear and Humanoid-Teleop; the subsequently added encoder/fixture consistency check also passed (89 checks total).
- Native: 6 output tests, 142 runtime tests (including the Python wire fixture), and 184 Dredd CLI tests passed.
- Hardware release build succeeded. `ldd` confirms pinned TensorRT 10.13.3.9, CUDA 13 and repository Unitree/CycloneDDS libraries.
- Preview CLI starts and shuts down without motor output. The headset stream at 192.168.50.236:12345 timed out and Dredd feedback at localhost:5557 was not listening, so no live arm/hand motion was attempted.
- Broader workspace tests are blocked by missing Fontconfig development metadata in the unrelated HUD crate. Strict Clippy hits existing approximate-pi constants in dredd-core; global formatting checks report existing formatting differences outside this change. These checks are not claimed passing.
