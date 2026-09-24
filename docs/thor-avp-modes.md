# Vision Pro teleoperation on Thor

Implemented modes:

| Mode | Hands | Head / ankles | Arm / body controller |
| --- | --- | --- | --- |
| `ik` (default) | Surreal | Existing setup | Mink velocity IK |
| `5point` | Surreal | Three HTC Ultimate trackers | SONIC five-point |
| `avp` | AVP optical wrists; thumb–index pinch | AVP head establishes forward at calibration | Existing Mink velocity IK and Dex1 grippers |
| `avp5point` | AVP optical wrists | AVP headset + two HTC ankles; optional third HTC head tracker | SONIC five-point; separate Mink output blocked |

## Start

On Thor, in `/home/g1gen5/Projects/production-sonic-controls`:

```sh
./scripts/setup_avp.sh
.venv/bin/python -m production.app --mode avp --setup-only
# Or:
.venv/bin/python -m production.app --mode avp5point --setup-only
```

The AVP setup preview is available at http://100.87.202.8:18087/ with output disabled. The temporary AVP5point preview was stopped after browser validation so it cannot compete with the existing HTC receiver on port 18085. Stop the HTC receiver on the old setup instance before moving to a new AVP5point instance.

`--avp-ip <headset-IP>` connects at startup; otherwise enter its IP in the web page. The TCP gRPC port is 12345. The headset and Thor need a reachable network. No PC relay or video stream is required. `--setup-only` never opens robot hardware. For an intentional robot session, stop the setup instance and launch the same command without `--setup-only`; output still requires the web Enable button and the existing telemetry, ownership, recording and tracking preflights. Do not run multiple hardware owners.

`avp` retains the existing `--low-body none|stiff|unitree|sonic` options; default `none`. `avp5point` automatically selects SONIC and rejects conflicting lower-body modes. `PRODUCTION_PORT` selects the web port; `PRODUCTION_STATE` selects a separate locked state directory. Existing Surreal assignments/calibrations are not overwritten by AVP home capture.

## Headset app

Use the updated local project `/Users/luc/wagmi/VisionProTeleop`, scheme `VisionProTeleop`. The `cybernetic` remote is `cybernetic-physics/VisionProTeleop`; the local checkout already contains newer optical tracking validity/timestamp work than that fork's main branch. This feature extends that local protocol, rather than reverting it to the older remote version.

Install the new signed visionOS build through Xcode or `xcrun devicectl device install app --device <device-ID> <app-path>`. Open the app, allow its existing tracking permissions, enter its immersive tracking view, and leave that view active. Thor accepts optical wrists, head tracking and source validity directly; Surreal controller pairing inside the headset is not needed.

The updated app sends `tracking_metadata_version=1` and a tracking-session UUID. Old builds are deliberately rejected with an actionable error. The session identity changes when ARKit starts or head tracking changes validity. Reconnection or world reset invalidates calibration. The schema additions are backward compatible for existing protobuf clients.

## Mink arms: `avp`

1. Connect the headset. Wait until head and both hands show live.
2. Face forward, elbows beside your ribs, forearms horizontal and pointing forward. Keep both hands below/in front of the headset, still for one second.
3. Enter height and press **Capture L pose**. The captured wrist poses map to the G1's existing bent-elbow resting FK targets.
4. Inspect the G1 preview. Forward/left/up movement and wrist rotations should follow your hands. Looking around does not rotate the captured mapping basis.
5. In a hardware session, **Enable AVP arms** explicitly enables the existing Mink transport. Thumb–index separation from 55 mm to 15 mm controls open-to-closed Dex1 targets. If finger tips are not tracked, retain the previous gripper target.
6. **Stop AVP output** invokes the existing controlled arm release. To reorient, stop, face the new direction, and capture the L pose again. There are no AVP controller buttons or controller haptics.

## Whole body: `avp5point`

1. Connect AVP. Start the HTC receiver; pair and complete native HTC room mapping using the existing Thor dongle/setup flow. This includes the installed Box64 workaround for HTC's mislabeled setup binary.
2. Select the head source. AVP head is the default; HTC head requires a third assigned tracker. Assign distinct trackers to the ankles (and head if selected) **before alignment**. Role changes invalidate alignment.
3. Set AVP hand prediction to **0 ms**. Secure one HTC tracker rigidly to the back of either hand. Keep the HTC cameras and the AVP view of your fingers unobstructed. Merely holding a loose tracker while rotating the wrist does not give a rigid calibration pair.
4. Select that tracker and **Align HTC using left/right hand**. Trace a broad, slow infinity in width, height and depth for 15–20 seconds, also rotating about multiple axes. Finish and validate. Only one capture is required because both optical hands share AVP's world and the HTC trackers share their room map.
5. Return trackers to their assigned body mounts. Stand upright with feet flat, facing forward, and hold the resting L pose. Enter height, then **Capture standing L pose**.
6. Check measured head/hands/ankles and the inferred skeleton. Enable whole body only after the five-point preview is correct. **Stop AVP output** stops SONIC. Native whole-body ownership and stop behavior are unchanged. Pinch gripper output is currently provided in Mink mode, not through the SONIC five-point stream.

The reused hand-eye fit solves `AVP_wrist(t) = AVP_from_HTC * HTC_tracker(t) * mounting_offset`. It fits the unknown fixed tracker-to-wrist offset along with the world transform and validates withheld samples. Applying the world transform to ankle/head trackers does not apply the temporary wrist mounting offset. Poor 3D/rotational excitation or excessive fit errors reject the capture. Prediction above 5 ms is rejected during alignment.

## Frames, timing and resets

Raw ARKit coordinates are right/up/back. Studio maps these to fixed forward/left/up with `(x,y,z) = (-ARKit.z,-ARKit.x,ARKit.y)`. These are world coordinates, not continuously head-relative coordinates. Mink freezes heading and wrist home rotations at L-pose capture and scales displacement by robot reach / estimated human arm length (`0.36 * height`). SONIC uses the shared reconstructed SMPL-24 reference already implemented for five-point tracking.

Source sequence/timestamps and tracked flags are required. Samples older than 120 ms, excess network queue delay, invalid rigid transforms and large pose discontinuities are rejected. Hand-eye samples pair within 25 ms; the five-point reference requires all sample times within 60 ms. Cross-device clock alignment uses the minimum observed receipt offset: it detects excess queued delay but does **not** measure absolute one-way network latency.

Loss of head/either hand requests a controlled stop. The request is latched even if tracking recovers before the next watchdog tick. Optical recovery never enables output automatically. A connection/world reset requires new L-pose capture and new HTC alignment. Calibration is session-bound and is not automatically restored across launches. Five-point tracker remapping/reassignment also invalidates the body fit.

AVP head/hand samples, pinch inputs, session identities, home profile, five-point transforms and existing solver/native-control records are included in recordings. Preview kinematics are not physical motor measurements.

## Validation and current limits

Software validation covers raw axis conversion, malformed/legacy packets, sample duplicates/backlog, pinch validity, real asynchronous gRPC discovery/streaming, stable L-pose capture, real Mink solves and lower-body preservation, HTC transform direction, synthetic rigid-motion fit, SONIC packet construction, world-reset stops, mode guards, web APIs, recording and existing Surreal behavior. Both web modes were inspected in a real browser. Signed and unsigned visionOS builds succeed.

Physical AVP streaming, a real HTC infinity fit and robot behavior remain unverified until the headset/trackers are available. The existing five-point reconstruction estimates pelvis, elbows and knees from proportions; five tracked points do not uniquely observe those joints. Its torso heading follows head orientation, so turn head and torso together during whole-body trials. Native HTC scanning still requires physical movement through the room.
