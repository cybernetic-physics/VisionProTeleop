# Vision Pro optical hands → Wuji Hand 2

Build 24 adds a **Use Vision Pro hands only** button to the main and calibration
windows. It starts optical hand/head tracking, disables Surreal inputs/overlays and
Wuji glove overlays, skips controller calibration, and sets hand prediction to zero.
No controller or glove is required. Existing manual calibration profiles are retained.

The bridge `tools/wuji/visionpro_hands.py` reads Vision Pro directly on port 12345,
maps the native 27-joint order to 21 MediaPipe landmarks, and feeds the wrist-local
positions into `RetargetSession.for_hand(WujiHand2, side=...)`. It sends 20 finger-major
joint positions; this does not command a robot arm. The SDK's retargeter was checked
to be invariant to a 90-degree rotation of the supplied hand landmarks.

## Run on Thor

The rig currently has left robot `WH2JA01260820042` at `192.168.1.110` and right robot
`WH2KA01260824015` at `192.168.1.111`. Serial, IP, device type, handedness, and 20 online
joints are verified. The default is **left only**; an absent right hand does not block it.

Install `numpy`, `grpcio`, and `protobuf` alongside the existing `wuji-sdk` environment.
Deploy `tools/wuji/visionpro_hands.py` and the generated
`avp_stream/grpc_msg/handtracking_pb2.py` together to
`/home/g1gen5/wuji-sdk/examples/python/retargeting/`. The standalone bridge does not
need the full video/visualization dependencies of `avp-stream`.

```bash
cd /home/g1gen5/wuji-sdk
# Read hardware feedback and retarget, without configuring/enabling motors:
/home/g1gen5/wuji-venv/bin/python examples/python/retargeting/visionpro_hands.py --side left --duration 15
# Drive the left robot (Ctrl+C disables it):
/home/g1gen5/wuji-venv/bin/python examples/python/retargeting/visionpro_hands.py --side left --enable-motors
```

Use `--side right` or `--side both` for the other configurations. Only one motor
command producer should run for a given robot. The earlier glove sender has been stopped.
A Mac launcher is available at `tools/wuji/run_left_optical.sh`.

## Tracking and stopping

Build 24 supplies `tracking_version`, `tracked`, per-joint tracking flags, sample
sequence/timestamp, prediction amount, and packet timestamp. Legacy senders are
rejected by the robot bridge. Hand and wrist tracking must be valid, skeletons must
be complete and finite, and samples must be fresh (200 ms). Repeated packets cannot
make an old sample fresh. Network backlog is checked relative to the lowest observed
clock offset in the current connection; this is not an absolute clock synchronization.

ARKit's current hand model includes inferred positions for occluded finger joints.
Those estimates are used while the hand and wrist are tracked. Per-joint flags are
available in the desktop debugger; they are not a requirement that every intermediate
finger joint be directly observed in every frame.

The first run uses 0.5 A current, MIT gains `(3.0, 0.05)`, and a 1.5 rad/s target slew
limit starting at measured robot positions. Robot feedback and diagnostics are checked.
Tracking loss or a stale stream **holds the measured finger positions** at the existing
current limit. Motors remain enabled to hold that pose; the bridge does not keep
chasing the last optical target. The source reconnects after connection failures.
After at least 300 ms of continuously valid tracking and five distinct samples,
control resumes automatically, starting from measured positions and respecting the
same joint speed limit. A new dropout resets that recovery interval. Each side has
its own recovery state, so losing one hand does not pause the other.

Missing robot feedback/diagnostics, a stalled control loop, or a stop-severity robot
fault still disables control and requires restarting the command. A separate watchdog
checks the command-loop heartbeat even while holding. Ctrl+C and SIGTERM disable any
hands enabled by this process. Holding stays active through an extended optical outage;
use Ctrl+C when you want the motors off. These software checks are not a substitute
for a hardware emergency stop.

Status is written to `/tmp/wuji-visionpro-hands-status.json` on Thor. Live targets and
measured robot joints are included. During the first live test, more than 350 commands
were sent and feedback followed the targets. That initial version stopped on a
stale-source event; the current bridge holds and resumes instead.
Some finger joints reported `Enc1BitRate` encoder-quality **warnings**, which the SDK
classifies as warning/auto-clear rather than a stop fault. Investigate recurrent
warnings before increasing load or current.
