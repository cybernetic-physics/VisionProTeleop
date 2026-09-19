# Wuji gloves placed by Surreal Touch controllers

Build 22 adds **Start tracking** inside the calibration panel, including when that window is restored before a session starts. Build 21 supports left-only, right-only, or both hands. Build 20 introduced a native Vision Pro overlay of the Wuji glove skeleton, placed by
an independently tracked controller attached to each glove. Python SDK 2.52.0
exposes the same fused samples through `get_gloves()`. Optical ARKit hands,
controller inputs, and glove skeletons remain separate channels.

## Data path

1. `tools/wuji/stream_gloves.py` runs on the machine connected to the Wuji gloves.
   It checks each glove's serial, IP, and handedness, synchronizes its clock, and
   subscribes to its 21-point wrist-local skeleton. It does not connect to robot
   hands, enable motors, change the user's hand calibration, or issue commands.
2. The sender exchanges four timestamps with the headset over UDP port 12346.
   Recent low-round-trip exchanges map source-host monotonic time into headset
   monotonic time. SDK acquisition timestamps (host UTC after device sync) are
   converted to source-host monotonic time before that mapping.
3. The headset keeps one second of raw controller/head pose history. It interpolates
   position and orientation at each glove frame's capture time, then applies the
   manually saved world and controller-to-wrist transforms.
4. The native overlay and outgoing controller protobuf carry the same fused result.
   gRPC, WebRTC, native recordings, and the desktop debugger inherit that channel.

```text
worldFromWrist = worldFromSurreal × surrealFromController(t) × controllerFromWujiWrist
worldJoint    = worldFromWrist × wristLocalJoint
headJoint     = inverse(worldFromHead(t)) × worldJoint
```

Wuji skeleton points are meters in the calibrated `l_wrist` / `r_wrist` frame,
MediaPipe order: wrist, four thumb points, then four points for each remaining
finger. Left and right points are consumed as reported; no extra reflection or
optical hand snapping is performed. The manual mounting transform includes the
required axis rotation. Controller grip offsets and Wuji wrist offsets are separate.

## Start the rig

The source host and Vision Pro must have a routable local-network path. Tailscale
can be used to manage Thor from the Mac; the glove datagrams themselves currently
travel directly over the shared Wi-Fi. There is no cloud relay or authentication
in this prototype UDP protocol; use it on the trusted rig network.

On Thor, using the environment with `wuji-sdk` installed:

```bash
python examples/python/retargeting/visionpro_glove_stream.py --headset VISION_PRO_IP --side left
```

The same standalone sender is maintained in this repository at
`tools/wuji/stream_gloves.py`. Its default inventory is this rig's two gloves;
`--left-serial`, `--left-ip`, `--right-serial`, `--right-ip`, and `--side` override it.
The default is left-only; pass `--side right` or `--side both` for other setups. It retries selected absent gloves independently. It sends each new acquisition once,
never restamps old frames as fresh, and resumes clock synchronization after the
headset restarts. Stop it with Ctrl+C. Start only one copy per source host.

Open Tracking Streamer on Vision Pro and press **START**. The UDP receiver runs
only with the controller polling/immersive session. If the calibration window opens first, press **Start tracking** there; you do not need to close it or save calibration first. Accept local-network and
tracking permissions if prompted. In the calibration panel, **Show Wuji glove
skeletons** enables the overlay; the left/right status shows acquisition age and
an estimated clock error. Optical hand visualization can be switched off.

## Manual calibration

1. Fix the controllers rigidly to the gloves and leave their cameras exposed.
   The mounting relationship must remain stable when the wrists bend.
2. Adjust **Both · world alignment** if the controller world differs from ARKit.
3. Select **Left · Wuji wrist**. With the hand open, translate and rotate the
   colored Wuji skeleton until its wrist and fingers align with the physical glove.
   Use the glove and its actual finger locations as references, not unreliable
   optical hand tracking. Repeat with **Right · Wuji wrist**.
4. Translation uses the raw controller axes, while rotation turns the skeleton
   around the selected wrist origin. Fine steps are 1 mm / 0.25 degrees; larger
   steps, undo, reset, and cancel remain available.
5. Verify open/closed fingers, different wrist rotations, and several arm positions.
   Rotate your head while holding both hands still. Then **Save & use calibration**.

Choose **Left only**, **Right only**, or **Both hands** in **Glove setup**. Saving requires the head and only the selected controller pose(s). The initial default is left-only; an absent right glove or controller does not block left-hand operation. A
saved profile can persist across launches, but startup review is enabled by default.
Recheck world alignment after tracking restarts/recentering, and wrist alignment
after changing either mount. The app never estimates these transforms from hands.
Old build-19 profiles retain their world/grip settings and initialize the new
wrist transforms to identity; they do not establish glove alignment.

## Python and debugging

```python
from avp_stream import VisionProStreamer
s = VisionProStreamer(ip="VISION_PRO_IP")
# Read repeatedly; the first snapshot may be empty.
g = s.get_gloves()
if g["left"]["valid"]:
    world_points = g["left"]["joints_avp"]  # 21×3, ARKit world
    head_points = g["left"]["joints_head"]  # head frame at glove capture time
    stream_points = g["left"]["joints"]     # configured stream axes/origin
    wrist = g["left"]["wrist_avp"]          # 4×4
```

Each side also exposes `points_wrist`, `confidence`, `wrist_head`, source serial,
sequence, original UTC acquisition microseconds, mapped headset `timestamp_ns`,
status, and `uncertainty_ms`. `joints_head` uses the head pose at the glove's capture
time, while the live headset/browser rendering uses current view transforms on
the historical world geometry. No extrapolation or motion prediction is added.
The optional receiver controller-origin correction also applies to glove wrists.
Calibration preview status is in `get_controllers()["calibration"]`; live manual
adjustments affect outgoing data before Save. Both raw wrist-local points and
fused wrist/head poses are preserved in native controller recordings.

The localhost Spatial Lab debugger has separate **Optical hands** and **Wuji gloves**
checkboxes and per-side fusion status. Its saved JSON includes the fused glove data.
`examples/18_wuji_gloves.py` is a console-only diagnostic.

## Loss, timing, and validation

A side is unavailable rather than frozen if it is older than 250 ms, has a joint
confidence below 0.5, has invalid coordinates/timestamps, has estimated sync error
over 30 ms, or lacks bracketing controller/head poses. Interpolation never crosses
an invalid tracking sample or a gap longer than 50 ms. Future frames beyond 20 ms
are rejected. UDP duplication/reordering cannot refresh an older acquisition.
Button data and the other side remain independent. Low confidence is not a claim
of physical accuracy; the 0.5 threshold is an explicit prototype policy.

Clock uncertainty is an estimate from device and host-network round trips, not a
hardware synchronization guarantee. The glove's firmware and the SDK control its
capture clock; firmware that only synchronizes initially can accumulate error
between reconnects. Mount movement, electromagnetic interference, incorrect hand
calibration, and tracking drift still need physical testing. No robot arm mapping
or actuation is part of this feature.

References: [Wuji frames](https://docs.wuji.tech/docs/en/wuji-glove/latest/coordinate-frames/),
[Wuji capture timestamps](https://docs.wuji.tech/docs/en/wuji-sdk/latest/time-sync/),
[Wuji skeleton fields](https://docs.wuji.tech/docs/en/wuji-glove/latest/sdk-data-reference/hand-tracking/).

## Controller pose diagnostics (build 23)

Controller action activity is not a Bluetooth connection guarantee. A displayed
released button does not establish that a controller pose is valid. Build 23
transmits `pose_status` independently of `pose_valid`, and the glove panel reports
which required pose is missing. It distinguishes inactive pose actions, SDK call
errors, missing position/orientation flags, the SDK placeholder near
(100, 100, -100) meters, and a calibrated position more than 10 meters from the
head. Invalid poses remain excluded from glove fusion.

On September 19, a restart briefly restored the left controller, then all 20
samples over ten seconds returned the placeholder while head/glove data stayed
healthy. Build 23 exposed that failure. A restart alone did not fix it.

Inspection of the exact pinned vendor binary (`SwiftSDKBinary` commit
`a42deb007c7f12afb543b235b75464e86e00125a`, ARM64 archive SHA-256
`6f1770cdd38824a4fdf756325cd6fc21b0e77780aa0dd57122297ceef29b81f1`)
shows the OpenXR pose path calls `SIControllerPollPose`, then `GetRenderPose`,
then `HandControllerFusion::FusionResult`. The uninitialized state returns a
constant translation (100, 100, 100), converted by the OpenXR path to
(100, 100, -100). Its initialization transition calls a holding detector that
consumes both controller VIO and optical hand observations.

This means our independent application channels do **not** establish independence
inside the vendor pose engine. Glove occlusion or a back-of-hand mount may prevent
its normal initialization. A bare-hand versus mounted-glove comparison is still
needed to confirm that trigger on this rig. Manual world/wrist adjustments are
applied after the vendor pose and cannot repair this placeholder. Do not snap to
optical hands or subtract 100 meters as a workaround. Reliable operation without
optical hands may require a vendor-supported raw VIO pose interface or a supported
way to initialize and retain the controller/world alignment independently.
