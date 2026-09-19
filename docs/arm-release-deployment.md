# G1/Wuji arm release deployment — 19 September 2026

Software is installed on Thor in HumDex, Humanoid-Teleop, GR00T-WholeBodyControl
(SONIC), G1-Dredd, and the shared `sharewear` package. No robot session was
started and no motor commands were sent as part of this deployment.

## Implemented normal-stop behavior

- Ten-second quintic envelope for the 14 G1 arm joints (hardware indices 15–28).
- Freeze the position reference at measured arm positions. Do not request a home
  or zero-angle pose. Transfer the previous static commanded effort into bounded
  feed-forward to avoid dropping position-error/feed-forward effort immediately.
- Reduce arm stiffness and feed-forward to zero; retain at least the existing
  damping or 4 Nm·s/rad. **This is passive damping, not zero total motor torque.**
- Keep the command writer alive throughout the envelope. An envelope duration
  is not a measured descent-duration guarantee. Gravity, payload, support and
  actual motor feedback determine how fast the arms descend.
- Normal exits and detected controller faults remain separate. Process crashes,
  SIGKILL, power loss and firmware watchdog handoffs cannot be made gradual by a
  userspace signal handler.

| Stack | Installed path and behavior |
|---|---|
| HumDex / TWIST2 | `deploy_real/robot_control/g1_wrapper.py` applies the arm override to each outgoing command. The running policy continues updating leg/waist commands during release. Select, SIGINT and SIGTERM request the release. Setup cancellation stops its trajectory and releases from its last hold. |
| Humanoid-Teleop | `teleop/robot_control/robot_arm.py` performs release in its active DDS writer. It retains SDK ownership during the ramp instead of fading into another controller's target. Fresh feedback is required. Firmware behavior after the writer shuts down still needs validation. |
| SONIC | Native `g1_deploy_onnx_ref` rebuilt at `gear_sonic_deploy/target/release/`. Normal operator exits, SIGINT and SIGTERM use the arm envelope. Internal fault paths retain their shorter damping behavior. Feedback loss interrupts the long release. |
| G1-Dredd | Native hardware build rebuilt under `services/g1-dredd/target/release/`. Normal operator/signal stops use the last successfully published servo frame and the arm envelope. The feedback reader stays alive during shutdown. Emergency/stale-feedback conditions interrupt the long release. |

Python release helpers are shipped in both Python repos, byte-identical to
`sharewear/src/sharewear/arm_release.py`; shutdown does not depend on installing
Sharewear in the policy's Python environment.

**Lower-body ownership:** this patch does not replace either native stack's
existing lower-body stop policy. SONIC and Dredd still put the lower body into
damping on the original schedule. A ten-second arm ramp therefore does NOT
establish ten seconds of standing balance. Do not use this as an unsupported,
standing whole-robot shutdown. HumDex's policy continues during its normal arm
release; its process-exit/firmware handoff also needs hardware validation.

Exiting the Mink companion still relinquishes its target stream to Dredd's
measured/last-target hold. The native owner's stop is responsible for the effort
release; a position-reference publisher cannot independently change motor gains.

## Mount model and captured pose

User confirmed a **5 mm axial gap from the G1 wrist mounting face to the Wuji
base, with the original Dex palm orientations**. The generator removes the Dex
hand geometry and joints and grafts the two 20-joint Wuji Hand 2 models onto the
G1 wrist frames. It converts the models' different axis conventions separately
for left and right hands. The resulting model has 69 articulated coordinates.

The model is for kinematics and collision preview. Source G1 wrist inertias
still contain Dex hardware; do not use them as Wuji inverse-dynamics parameters.
The camera, pelvis cover and adapter hardware need comparison with the physical
robot. Joint slots are resolved by name because the 40 finger joints interleave
G1 joint order.

From `~/Projects/shoot`:

```bash
sharewear/.venv/bin/python -m sharewear.wuji_model \
  --g1 Humanoid-Teleop/assets/g1/g1_body29_hand14.xml \
  --wuji HumDex/wuji-retargeting/wuji_retargeting/wuji_hand_description \
  --output sharewear/calibration/models/g1_wuji_hand2.xml
MUJOCO_GL=egl sharewear/.venv/bin/python sharewear/scripts/audit_g1_wuji_model.py
```

The audit uses only the captured 14 arm angles. Legs/waist are zero for offline
analysis, and fingers use model zero clamped to limits: neither is live feedback
or a commanded target. See `calibration/models/g1-wuji-captured-pose.png` and
`captured-pose-audit.json`. The reference remains `reference_only: true`.

## Not yet a protected startup deployment

The outward-then-presentation trajectory, optical pose-match gate and 25.4 mm
final-command collision guard are **not integrated into all native writers**.
The shared startup/projection primitives and combined model do not themselves
provide a physical collision guarantee. Existing startup paths must not be
mistaken for the requested protected startup.

The audit finds wrist/shoulder assembly surfaces closer than 25.4 mm. Intended
mechanical interfaces need specific reviewed rules; never automatically exempt
all near pairs or reduce margins until the captured pose passes. Hand-to-hand
contact gets a zero-clearance, nonpenetration rule. Hand-to-body and hand-to-arm
clearance applies outside the reviewed attachment interfaces. Full deployment
also requires a swept-path check including current body and finger feedback,
latency/braking allowance, and the final motor command after policy/stabilizer
changes. **Hardware activation remains pending these items.**

## Verification

- Sharewear: 86 tests, including both actual Python writer methods, monotonic
  envelope, bounded initial effort, body-command preservation, 69-joint model,
  five-millimeter mounting transforms and identical shipped release helpers.
- Humanoid-Teleop: 22 tests covering Wuji sessions, optical tracking and arm paths.
- Dredd runtime: 143 tests; native hardware release build completed.
- SONIC: standalone C++ release tests, full native executable build, dynamic
  dependency inspection. No DDS connection is created by the release tests.

These are software checks, not physical descent, contact, balance or firmware
handoff validation. Build/commit hashes are in `deployment/arm-release.json`.
