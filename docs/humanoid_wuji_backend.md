# Wuji Hand 2 with Vision Pro optical tracking

The **main application** now selects a native Wuji backend with `--hand wuji`.
It does not initialize Dex3/Inspire or send a skeleton into their seven-/six-joint
shared-memory fields. `WujiTaskmaster` in `teleop/wuji_session.py` owns the session,
uses Sharewear's `WujiHandBackend`, and records 20 joint positions per selected hand.
The original main-app path remains available without `--hand wuji`.

## Run on Thor

The current working SDK environment is `~/wuji-venv` (Python 3.12, Wuji SDK
2026.8.31, numpy, scipy, grpcio and protobuf). Sharewear supplies the optical input
and shared hardware implementation. No gloves or controllers are required.

1. On Vision Pro, open Tracking Streamer build 24+ and tap **Use Vision Pro hands only**.
2. Put your bare hand in view. Controller/world/mount calibration is unnecessary.
3. Stop the previous standalone motor bridge before starting a new motor session.
   The backend rejects the earlier `visionpro_hands.py --enable-motors` sender and
   uses per-hand process locks against other shared backends. Do not run a separate
   HumDex motor server or another SDK application commanding the same physical hand.
4. Run from the workspace root:

```bash
cd ~/Projects/shoot
# Read actual hardware and record, but never enable/send motor commands:
PYTHONPATH="$PWD/sharewear/src" ~/wuji-venv/bin/python Humanoid-Teleop/teleop/main.py \
  --hand wuji --hands left --start --duration 10 --task_name optical-check

# Interactive left-hand control and recording:
PYTHONPATH="$PWD/sharewear/src" ~/wuji-venv/bin/python Humanoid-Teleop/teleop/main.py \
  --hand wuji --hands left --enable-motors --task_name optical-wuji
```

Use **s + Enter** to start a session, **q + Enter** to stop, **d + Enter** to mark a
failed session and stop, and **exit + Enter** to quit. Ctrl+C and SIGTERM close the
session and disable the hands this session enabled. You can start another session
with `s` after a normal stop. Hardware/recording faults close the session and exit;
resolve the fault before restarting. `--start` starts immediately for scripts;
`--duration N` bounds the whole invocation. Without `--enable-motors` this is a
read-only hardware run. `--hands right` and `--hands both` are equally supported.

Only selected physical hands are connected. Left-only does not require a right hand
or any Unitree arm connection. The currently configured serial/IP pairs are:

| Side | Serial | IP |
| --- | --- | --- |
| Left | WH2JA01260820042 | 192.168.1.110 |
| Right | WH2KA01260824015 | 192.168.1.111 |

The backend verifies serial, IP, device type, handedness and 20 online joints before
use. The SDK's hand retargeter converts 21 optical landmarks to its 20-joint firmware
command order. Feedback is reordered by node ID, not packet arrival order.

## Tracking gaps and hardware faults

Each hand independently holds its **measured** position when optical data becomes
invalid or older than 200 ms. Motors remain enabled at the configured current limit.
After at least 300 ms of stable tracking and five distinct samples, control resumes
from measured positions at the configured slew rate. Old packets cannot refresh
tracking. Losing the left hand does not pause a valid right hand.

Defaults are 0.5 A, MIT gains `(3.0, 0.05)`, and 1.5 rad/s target slew. Feedback must
be fresh within 250 ms and diagnostics within 500 ms. Hardware faults and command
loop stalls latch a stop, disable enabled hands and require a new process/session.
Warning-severity codes are logged/recorded; the initial rig has shown encoder-quality
and stall warnings. Disable failures are surfaced rather than reported as success.

## Optional Unitree arms

Add `--arms --robot g1` (or `h1`) to a motor-enabled session to use this checkout's
existing arm controller and IK with optical head-relative wrist targets. This
requires its Unitree DDS, Pinocchio/CasADi, URDF/assets and robot environment. It
is not needed for fingers and was not physically exercised during this integration.
The installed Wuji-only environment does not imply the arm dependencies are installed.

Arm tracking requires the head and **both** wrists; finger selection is independent.
On tracking loss arms hold measured positions; recovery is gated for 300 ms and arm
joint targets are limited to 0.5 rad/s. Invalid IK, stale feedback and long IK solves
stop the session. The arm publisher also freezes its target if high-level commands
stall. Shutdown releases arm-control weight through the existing driver.

The existing robot URDF and wrist frames are reused. The project model still
contains its original hand inertial/collision geometry. Verify the installed Wuji
mount transform, payload model and arm environment before physical arm deployment;
passing unit tests is not a claim that the new hand payload is dynamically validated.

## Recordings and camera capture

Every session gets a unique directory under `data/wuji/<task_name>/` by default
(`--output` overrides the root):

- `metadata.json`: schema 2, side selection, node order, units and command settings.
- `robot_data.jsonl`: synchronized optical input, per-side feedback, actual sent
  joint targets, retarget goals, tracking state, warnings and optional arm state.
- `result.json`: completion/failure outcome and recorder errors.

`states.hand_state` and `actions.hand_command` each have **40 slots: left 20, right
20**. Unselected sides are null, with explicit per-side selected/valid flags; they
are never represented as a real zero-pose hand. Stale measured values carry false
validity and a feedback age. Commands are null when motors are disabled, including
dry-run. Pressure is null because this backend does not provide a pressure stream.
The joint units are radians; optical transforms/landmarks use metres. Records are
written at the control-loop rate, 60 Hz by default. Recording overflow/failure stops
hardware before flushing/closing files.

To reuse the existing RealSense server, add
`--camera-endpoint tcp://192.168.123.164:5556`. JPEG and compressed raw uint16 depth
are stored under `color/` and `depth/`; each control record includes the associated
camera receive timestamp and freshness. Camera acquisition runs separately and a
missing camera does not block motor control. This native optical path does not start
the old Vuer image relay or LIDAR recorder. Image/depth/LIDAR are explicitly null when
unavailable. The schema is distinct from legacy Dex3 training/replay data; the legacy
replay entry point rejects Wuji records rather than commanding the wrong driver.

## Verification

```bash
cd ~/Projects/shoot
sharewear/.venv/bin/pytest -q Humanoid-Teleop/tests sharewear/tests
```

Tests cover native main-app dispatch, 20-joint mapping, left/right/both selection,
tracking hold/recovery, motor/feedback faults, duplicate writers, session restart,
recording failure, arm gating/slew/invalid IK, and the camera transport.

Hardware checks on Thor read and recorded all **40 real joint positions** in a
bounded main-app dry run without sending motor commands. An end-to-end test used
**synthetic optical gRPC packets**, the **real Wuji SDK retargeter**, and **real robot
feedback**: it recorded 144 frames and verified left tracking loss/recovery while
right retargeting continued. Those synthetic inputs never enabled motors. The earlier
standalone optical bridge drove the left physical hand successfully. A live headset
run through this new main-app backend remains pending while the optical stream is unavailable;
physical Unitree arm control is also unverified.

Latest device check: the headset remains paired through Apple device services, but
Tracking Streamer's optical port is unavailable and its remote launch timed out.
The left robot subsequently stopped responding; the earlier live motor bridge
latched a feedback-loss stop. Both-hand feedback was verified earlier, but a new
live session requires restoring the left robot connection and the optical stream.
The current automated suite passes **75 tests**.
