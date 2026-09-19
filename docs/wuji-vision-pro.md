# Wuji Hand 2 Beta 2 + Vision Pro + G1-Dredd

Deployment guide and source checkpoint, 19 September 2026.

This describes the setup on Luc's MacBook, Thor, PC2 and the G1. Commands marked
**Thor** run as `g1gen5` on Thor, not in a local Mac terminal. No controller or
motor session is started merely by saving this guide.

## 1. Where everything lives

| Component | Host and folder |
| --- | --- |
| Vision Pro app and Python tracking SDK | Mac: `/Users/luc/wagmi/VisionProTeleop` |
| Dredd repository | Thor: `/home/g1gen5/Projects/dredd-teach-mode-adam` |
| G1-Dredd Rust workspace | Thor: `/home/g1gen5/Projects/dredd-teach-mode-adam/services/g1-dredd` |
| Dredd executable | Thor: `~/Projects/dredd-teach-mode-adam/services/g1-dredd/target/release/dredd` |
| Main Wuji launcher | Thor: `~/Projects/dredd-teach-mode-adam/services/g1-dredd/tools/start_wuji.sh` |
| Python tracking, workspace mapping, Mink IK and Wuji control | Thor: `/home/g1gen5/Projects/shoot/sharewear` |
| Python runtime | Thor: `~/Projects/shoot/sharewear/.venv/bin/python` |
| Teleop recordings | Thor: `~/Projects/shoot/dredd-recordings` |
| Installed camera compositor | Thor: `~/.local/bin/wuji-camera-hud` |
| Camera capture scripts/configuration | PC2: `/home/unitree/.local/share/wuji-cameras/` |
| Wrist RGB-D recordings | PC2: `/home/unitree/wuji-rgbd-recordings/` |

Network addresses at this checkpoint:

- Thor: `192.168.50.23` on Wi-Fi; Tailscale SSH `g1gen5@100.87.202.8`.
- Robot-facing Ethernet on Thor: `enP2p1s0`, with `192.168.123.222/24` and
  `192.168.1.10/24` when connected.
- Vision Pro: `192.168.50.236`; tracking/signaling advertisement endpoint port `12345`.
- PC2: `unitree@192.168.123.164`, reached from Thor.
- Left Wuji: `192.168.1.110`, serial `WH2JA01260820042`.
- Right Wuji: `192.168.1.111`, serial `WH2KA01260824015`.

From the Mac, open two Thor terminals using:

```bash
ssh g1gen5@100.87.202.8
```

The paths beginning `~/Projects/...` below refer to Thor's home directory.

## 2. What we changed and why

The arm problem was more than a slow IK calculation. Earlier runs showed large
joint rearrangements for nearly identical palm positions, reference limiting,
and delayed tracking samples. We changed several separate parts:

1. **Workspace mapping:** a shared absolute workspace for both hands, with
   calibrated forward direction and Wuji Beta 2 palm frames. The forward frame
   stays fixed until explicit recapture, so looking around does not steer the arms.
2. **IK and continuity:** seed from measured arm posture, retain a stable elbow
   preference, constrain joint motion and hold a feasible reference when a
   workspace boundary or temporary IK infeasibility is encountered. Tiny encoder
   excursions up to 0.020 rad beyond model limits are projected for the IK seed;
   commanded joint limits are unchanged.
3. **Response:** the current `urdf` profile removes extra Cartesian smoothing and
   uses per-joint URDF velocity ceilings, with a 30 rad/s² acceleration limit.
   These ceilings do not guarantee equal actual motor speed or zero latency.
4. **Vision Pro scheduling:** hand sampling/serialization runs on a separate
   high-priority worker. Video conversion and recording use bounded background
   work, so old video frames cannot accumulate and block hand tracking.
5. **Thor scheduling:** diagnostics/recording are asynchronous, and Wuji feedback
   is continuously drained to newest-message storage even before capture.
6. **Grip continuity:** tracking loss holds the last issued finger reference
   instead of relaxing to measured finger position and losing contact preload.
7. **Recovery and startup:** workspace/IK holds can recover; an AR session change
   requires `c` to recapture. MotionSwitcher startup uses a five-second RPC timeout
   with bounded timeout retries instead of a 20 ms timeout.
8. **Video:** flat MAGI HUD with head and two enlarged wrist camera views, plus
   the correct Wuji Hand 2 Beta 2 hand models. There is no full 3D robot scene.
   Wrist brightness/gamma were adjusted; the right display is rotated 180°.
9. **Camera reboot recovery:** Thor recreates an individual camera subscription
   after two seconds without messages, avoiding a connection stuck across PC2
   power loss. The headset video connection can remain independent.

The hand model is pinned to revision
`c2cd7f8d1ef8b6dc8cb907c17daa5a88b4442d95`, subdirectory
`hand2/hand2_beta2/body`, with 20 joints per hand. The installed Wuji SDK is
`2026.8.31` and uses `RetargetSession.for_hand(HandModel.WujiHand2)`.

## 3. Choose the control mode

| Mode | Who commands the arm motors? | What the operator uses |
| --- | --- | --- |
| SONIC + gamepad only | SONIC policy | Thor's 8BitDo gamepad for body intent; no optical hand control |
| SONIC + Vision Pro/Wuji | SONIC policy follows external arm references; Wuji SDK controls fingers | Gamepad starts/stops body CONTROL; headset supplies arm and finger poses |
| Supported direct arms + Vision Pro/Wuji | Direct 500 Hz arm controller; no SONIC | Headset supplies arm/finger poses; no gamepad Start required |

Only one body controller may run at a time. Stop the previous body and hand
sessions before changing modes. **Direct-arm mode provides no balance: keep the
robot physically supported/suspended.**

### A. SONIC policy with the gamepad, without optical hand control

Run on **Thor** from the Dredd repository root:

```bash
cd ~/Projects/dredd-teach-mode-adam
services/g1-dredd/target/release/dredd run enP2p1s0 \
  --robot --input-type evdev --arm-owner sonic --no-hand-output \
  --engine-dir .third_party/engines/sonic-v1.1/trt-10.13.3.9-cuda13.0-sm110 \
  --obs-config .third_party/src/GR00T-WholeBodyControl/gear_sonic_deploy/policy/sonic_v1_1/observation_config.yaml \
  --motion-data .third_party/src/GR00T-WholeBodyControl/gear_sonic_deploy/reference/example \
  --publish-output true --zmq-out-port 5557 --writer-cpu 12 \
  --no-auto-wiggle --no-intro --log-file /tmp/dredd-wuji-live.log \
  --record-root ~/Projects/shoot/dredd-recordings --allow-dirty
```

Wait for initialization and use the normal Dredd CONTROL transition:

- Gamepad **Start** starts CONTROL; **Select** stops.
- In the body terminal, `]` starts and `o` stops; Ctrl-C exits.
- The backtick key switches the TUI between MONITOR and PILOT. In PILOT,
  Enter toggles the planner. Check the displayed planner state before using
  walking commands; do not toggle it blindly if it is already enabled.
- With planner body control active: left stick requests walking, right stick
  requests turning, L1/R1 change mode, L2/R2 adjust speed, B requests idle.

`--input-type evdev` means the Bluetooth/wired 8BitDo connected to **Thor**.
`--input-type gamepad` is a different backend: the Unitree wireless remote.
These are also distinct from Surreal Touch controllers paired to Vision Pro.

This command uses `--arm-owner sonic`: the policy owns arm behavior. It does not
start the Wuji optical companion and does not command the Wuji fingers.

### B. SONIC policy with Vision Pro arm and Wuji finger control

Open Tracking Streamer on the headset and enter its streaming view. On **Thor**:

Terminal 1 — SONIC body:

```bash
~/Projects/dredd-teach-mode-adam/services/g1-dredd/tools/start_wuji.sh body enP2p1s0
```

Terminal 2 — Vision Pro arms and fingers:

```bash
~/Projects/dredd-teach-mode-adam/services/g1-dredd/tools/start_wuji.sh hands \
  --headset 192.168.50.236 --workspace-scale 1.0 \
  --enable-arms --enable-motors
```

Start body CONTROL with the gamepad Start button or `]` in Terminal 1. In
Terminal 2 press **`c`**, then look forward and show open hands in front through
the five-second countdown. No Enter is needed in an interactive terminal.

The `body` wrapper uses `--arm-source zmq --arm-owner reference`: the Python
companion computes arm joint references and sends them to Dredd; SONIC still
generates the whole-body motor commands. The companion independently owns the
Wuji fingers. Dredd uses `--no-hand-output` to avoid a second hand command owner.

Press **`q` in the hands terminal** to end that session and disable its Wuji
motors. Stop the SONIC body explicitly using Select, `o`, or Ctrl-C and let its
shutdown complete. Do not assume closing the hand companion also stops balance.

### C. Vision Pro direct-arm control without SONIC

Use only while the robot is physically supported/suspended. On **Thor**:

Terminal 1:

```bash
~/Projects/dredd-teach-mode-adam/services/g1-dredd/tools/start_wuji.sh direct-body enP2p1s0 --enable-motors
```

Terminal 2:

```bash
~/Projects/dredd-teach-mode-adam/services/g1-dredd/tools/start_wuji.sh hands \
  --headset 192.168.50.236 --workspace-scale 1.0 \
  --enable-arms --enable-motors
```

The direct controller acquires the measured arm pose over two seconds. Press
`c` in Terminal 2 and complete the capture countdown. **No Start button or SONIC
CONTROL is required.** Legs/waist are damped; there is no balance policy.

After capture, `q` in the hands terminal or Ctrl-C in the body terminal normally
releases arm stiffness over ten seconds and then sends passive damping. Before
capture, quitting the companion alone does not release the body pose hold:
Ctrl-C the body too. Leave it running until shutdown finishes. A real fault
enters passive damping immediately and requires a body restart before re-arming.

Direct arm gains are separate from finger gains: shoulder/elbow Kp/Kd = 40/2,
wrists = 12/1. No validated Wuji payload gravity compensation is enabled.

For read-only preview, omit `--enable-motors` from `direct-body` and omit both
`--enable-arms` and `--enable-motors` from `hands`. This does not create a robot
motor writer or release the Unitree controller.

### About gamepad arm manipulation

Dredd also contains `--arm-source joystick --arm-owner reference`: RB is the
arm dead-man, the sticks/triggers move a selected hand pose and wrist, and LB
modifies roll/elbow controls. That older path includes Dex3 grip presets. It is
**not the Wuji optical-finger workflow above**, and those presets should not be
treated as a tested Wuji finger mapping. See G1-Dredd `docs/arm-ik-servo.md` if
working on that separate path.

## 4. Workspace capture, speed and grip settings

`c` captures a working coordinate frame, **not maximum reach**. Look forward,
keep both optical hands visible, and show open hands in front. `--workspace-scale
1.0` requests a 1:1 workspace scale within the robot's feasible reach. Increasing
scale changes mapped distance; it does not give the robot a longer arm.

Normal hand occlusion holds the affected command. When tracking returns it uses
a bounded transition. If the app restarts and the AR world/session changes, press
`c` again to recapture; the system does not silently substitute a new offset.

Current defaults in the **Dredd hands companion**:

| Setting | Value |
| --- | --- |
| Motion profile | `urdf` from `start_wuji.sh` |
| Arm velocity ceilings | 37 rad/s shoulder/elbow/wrist roll; 22 rad/s wrist pitch/yaw |
| Arm acceleration limit | 30 rad/s² |
| Extra Cartesian response smoothing | Disabled in `urdf` profile |
| Finger current limit | 1.5 A per joint |
| Finger Kp / Kd | 10 / 0.05 |
| Finger speed limit | 2 rad/s |
| Finger feed-forward effort | 0 |

The new finger settings are configured for the next hand-session launch. They
have passed software tests, not a measured grip-force qualification. Current is
in **amperes**, not calibrated fingertip force. A requested 2.5 A was not applied:
[Wuji documents](https://docs.wuji.tech/docs/en/wuji-hand/latest/control-guide/)
a 2.0 A device hard ceiling and recommends at most 1.5 A.

Explicit equivalent hand settings, appended to the hands command:

```bash
--effort-limit 1.5 --hand-kp 10 --hand-kd 0.05 --hand-speed 2
```

For the earlier slower arm profile, prefix **both** body and hands commands with
`WUJI_MOTION_PROFILE=manipulation`. That uses 3 rad/s and 10 rad/s² trajectory
limits. Finger settings are independent. URDF speed is a ceiling, not a promise
of actual tracking speed; high load, motor response and SONIC following still matter.

## 5. Vision Pro app: what we built

The installed application is **Tracking Streamer**, built from the Mac repository's
`Tracking Streamer.xcodeproj`, scheme `VisionProTeleop`, bundle ID
`com.lucchartier.VisionProTeleop`, current build **32**. The project now records
build 32 directly; earlier deployment commands overrode the build number.

It supplies head and optical hand tracking over gRPC, and receives the MAGI video
HUD over WebRTC. “Python connected” and “WebRTC connected” describe separate
connections. A connected WebRTC session can still have stale camera inputs.

Key app changes include independent hand sampling, bounded background video
processing, removal of duplicate frame recording, correct panel placement in
front of the user, and guards against old WebRTC callbacks tearing down a new
connection. Local signing, bundle IDs, entitlements and shared keychain groups
were updated for Luc's Apple development team. Surreal Touch/glove support is
also in the source checkpoint; the commands above use optical hands.

On Vision Pro, enable **Settings → Privacy & Security → Local Network → Tracking
Streamer**, allow hand tracking, and open the streaming view. If frames decode
but the panel is invisible, use the video panel's Reset placement control.

Build on the **Mac**:

```bash
cd /Users/luc/wagmi/VisionProTeleop
xcodebuild -project 'Tracking Streamer.xcodeproj' \
  -scheme VisionProTeleop -destination 'generic/platform=visionOS' \
  -configuration Debug \
  -derivedDataPath /Users/luc/.visionpro-build/VisionProTeleop \
  -allowProvisioningUpdates build
```

Install/launch on the paired development headset from the Mac:

```bash
xcrun devicectl list devices
xcrun devicectl device install app \
  --device 59D962B5-FE1E-50DC-A43C-7036884D6C6B \
  '/Users/luc/.visionpro-build/VisionProTeleop/Build/Products/Debug-xros/Tracking Streamer.app'
xcrun devicectl device process launch \
  --device 59D962B5-FE1E-50DC-A43C-7036884D6C6B \
  com.lucchartier.VisionProTeleop
```

Use the current device ID from `list devices` if pairing changes. Signing requires
the Apple developer account/provisioning available in Xcode; GitHub does not
contain its private signing key. This documentation checkpoint rebuilt the app
but did not reinstall it or interrupt the user's headset session.

## 6. Head/wrist cameras and MAGI HUD

PC2 runs three enabled user services, independent of robot control:

| Camera | Serial | Service | PUB port |
| --- | --- | --- | --- |
| Head | 254322072098 | `wuji-camera@head` | 5560 |
| Left wrist | 260322274506 | `wuji-camera@left` | 5561 |
| Right wrist | 260322274429 | `wuji-camera@right` | 5562 |

Thor receives those streams and renders a 1280×720, 30 fps flat HUD. The larger
wrist views preserve the field of view. Wrist auto exposure is enabled with
brightness 10 and gamma 400; the right HUD image rotates 180°. The HUD includes
Wuji Beta 2 hand models. Video is independent of whether SONIC or direct mode runs.

On **Thor**:

```bash
systemctl --user status wuji-camera-hud --no-pager
cat /tmp/wuji-camera-hud.json
systemctl --user restart wuji-camera-hud
```

The status should keep updating and report all three cameras `live: true`, plus
`connected: true` and `answer_applied: true` for headset transport. The rendered
preview is `/tmp/wuji-camera-hud.png`. A stale status file alone proves nothing.

Check/restart PC2 camera services **from Thor** when necessary:

```bash
ssh unitree@192.168.123.164 \
  'systemctl --user status wuji-camera@head wuji-camera@left wuji-camera@right --no-pager'
ssh unitree@192.168.123.164 \
  'systemctl --user restart wuji-camera@head wuji-camera@left wuji-camera@right'
```

PC2 configuration is `~/.local/share/wuji-cameras/cameras.json`; status files are
`~/.local/state/wuji-cameras/{head,left,right}.json`. Deployment sources are in
Dredd's `services/g1-dredd/tools/camera-hud/`. Thor's optional service overrides
are `~/.config/wuji-camera-hud.env` (`HEADSET`, `ADVERTISE_HOST`, `PC2`).

## 7. RGB-D logging: data collection, not running SLAM

Wrist color/depth logging is installed for later SLAM/reconstruction work. It does
not currently run a SLAM estimator or feed camera localization into arm control.
On **Thor**:

```bash
~/.local/bin/wuji-rgbd-record start
~/.local/bin/wuji-rgbd-record status
~/.local/bin/wuji-rgbd-record stop
```

PC2 stores native color + Z16 depth, intrinsics/extrinsics, frame numbers and
timestamps per wrist. Raw right-camera data retains its native orientation;
only the HUD rotates it. Wrist-to-camera mounting transforms remain uncalibrated.
Thor stores independent joint telemetry under
`~/Projects/shoot/dredd-recordings/rgbd-robot-state/` and clock-pair samples for
PC2/Thor alignment. Do not synchronize recordings by wall-clock filenames:
PC2's clock was substantially offset in earlier tests. The cameras are not
hardware synchronized. Recording can consume roughly 70 GB/hour for two wrists,
depending on scene content; `stop` stops recording without stopping live video.

## 8. Troubleshooting and stopping

- **Controller not working:** on Thor, check `bluetoothctl info E4:17:D8:2F:66:44`
  and `ls -l /dev/input/robonia-gamepad`. The paired device is the 8BitDo Ultimate
  2C Wireless. If its input permissions are wrong, run
  `sudo ~/Projects/dredd-teach-mode-adam/services/g1-dredd/tools/fix_wuji_controller.sh`.
- **Another session owns the robot/hand:** exit the owning session normally.
  Inspect `pgrep -af 'dredd|sharewear.dredd_session'`. Do not delete lock files or
  launch a competing writer. Body lock: `/run/user/1000/robonia-dredd-robot.lock`;
  hand locks: `/tmp/sharewear-wuji-<serial>.lock`.
- **`c` appears ineffective:** focus the hands terminal, keep the headset streaming
  and both optical hands fresh, and read the capture failure message. It is a
  five-second countdown, not an immediate enable command.
- **MotionSwitcher 3104:** this is a startup RPC timeout. Current direct mode has
  a longer timeout and bounded retries; do not proceed on an unconfirmed release.
- **Network after battery change:** check `ip -br addr show enP2p1s0` on Thor.
  No carrier means remote robot commands cannot be confirmed. Camera recovery
  is independent of robot mode selection.
- **Wuji Stall warnings:** repeated warning output is summarized; details remain
  in telemetry. Contact/stall does not establish that the pinch geometry is
  correct or that more current is appropriate.
- **Temperature stop:** this is distinct from tracking loss. A recorded left
  shoulder pitch rose from 70°C to the 100°C software cutoff in one minute;
  another run had a left shoulder roll hardware fault at 131°C. Keep motor control
  off, inspect load/obstructions and allow cooling. Cutoffs remain 100°C motor /
  80°C driver. Finger settings do not change these arm protections.
- **Zero torque versus damping:** a completed direct shutdown sends passive
  damping; that is not a verified Unitree zero-torque mode. The earlier remote
  zero-torque request failed while robot Ethernet was down. Releasing Unitree's
  `ai` controller frees its ownership; it is not itself proof of zero torque.
  After Ethernet returned, the operator-requested AI release succeeded:
  `CheckMode` changed from `name: ai` to an empty name, with SDK return code 0.
  This was a one-time action; subsequent boot or mode changes can restore `ai`.

Detailed logs: `/tmp/dredd-wuji-live.log` for the SONIC body, `direct-arm-*.jsonl`
for direct mode, and `bridge-*/samples.jsonl` plus stop/flight-history records for
the companion under `~/Projects/shoot/dredd-recordings/`.

## 9. Source commits and release history

These repositories have independent histories; use the matching checkpoint set.
Historical investigation notes may describe earlier limits. The commands and
defaults in this guide describe the checkpoint below.

### Current code checkpoint

| Repository | Branch | Commit | Contents |
| --- | --- | --- | --- |
| Mac VisionProTeleop | `codex/wuji-vision-pro-20260919` | `d0e8659b8356897dca57ab6c99061d3c5c63a282` | App build 32/signing, WebRTC recovery, tracking SDK/controller/glove tools, tests and investigation notes |
| Thor Dredd | `teach-mode` | `1e54989830a70abd82a72ae557596e634193cd63` | Supported direct arms, feedback/thermal handling, camera reconnect and RGB-D recording |
| Thor sharewear | `codex/sharewear-input` | `32644d7e52c4e1e3ad44d7d545dabdf10e85a5aa` | Measured-posture IK/recovery, feedback worker, new hand gains/current/speed, guard and observatory source checkpoint |

The guide is added in a subsequent Mac documentation commit. Raw robot recordings,
native build outputs, `.DS_Store` changes and local Xcode `xcuserdata` are excluded
from these source commits. Preserved diagnostic fixtures/reports are included.
Experimental tools in the checkpoints are not endorsements of separate live
control paths; use the launch commands above.

### Selected prior commits

| Repository | Commit / tag | Change |
| --- | --- | --- |
| Mac app | `7c0a6c9` | Hand tracking independent of video; wrist-view refinement |
| Mac app | `ff7797e`, tag **`wuig-video`** | WebRTC connection and visible HUD placement |
| Dredd | `a17b4c1c1` | Larger wrist views and brighter D405 images |
| Dredd | `01340d4c3`, tag **`wuig-video`** | Three-camera MAGI HUD and Wuji Beta 2 models |
| Dredd | `bfbf67b6d`, tag **`wuji-2`** | Arm reference limits and pinned optical companion |
| Dredd | `f97ae1e36`, tag **`wuji-1`** | External arm readiness and feedback budget |
| Dredd | `4e108c5b3` | Ten-second normal arm release |
| Dredd | `fea220164` | External Vision Pro/Mink/Wuji coordination |
| sharewear | `2697a4d` | Grip preservation and independent diagnostics |
| sharewear | `4f2fc01`, tag **`wuji-2`** | Measured-posture IK and absolute workspace |
| sharewear | `26e24ce` | Official SDK/Beta 2 geometry verification |

The spelling **`wuig-video`** is intentional: it is the existing tag, not `wuji-video`.

Mac GitHub destination:
`https://github.com/cybernetic-physics/VisionProTeleop`, branch
`codex/wuji-vision-pro-20260919`. `origin` still points at the original
`Improbable-AI/VisionProTeleop`; the deployment branch is pushed explicitly to the
`cybernetic` remote, preserving its existing `main`.

Thor Dredd's `origin` is a local bundle (`/tmp/teach-mode-adam.bundle`), not a
GitHub destination. Sharewear has no configured remote. Their checkpoint commits
are local on Thor; pushing the Mac app does not upload these repositories.

Inspect full histories:

```bash
# Mac
git -C /Users/luc/wagmi/VisionProTeleop log --oneline --decorate -20

# Thor
git -C ~/Projects/dredd-teach-mode-adam log --oneline --decorate -20
git -C ~/Projects/shoot/sharewear log --oneline --decorate -20
```

Validation for this checkpoint: Vision Pro build succeeded; 69 Mac Python tests,
216 sharewear tests, and 201 native Dredd tests passed. The camera reconnection
change previously passed all 20 dredd-video tests. These checks do not establish
safe high-load continuous grip force or solve the observed shoulder heating.
