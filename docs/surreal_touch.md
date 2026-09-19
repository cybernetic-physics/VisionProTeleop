# Surreal Touch controllers

The Tracking Streamer app and `avp_stream` 2.51.0 now have dedicated left/right
controller channels alongside the existing hands, head, markers and stylus.
The app uses the native Surreal binary SDK; Unity and SteamVR are not required.

## Install and pair

Use the app and Python SDK from [Cybernetic Physics’ fork](https://github.com/cybernetic-physics/VisionProTeleop). The upstream App Store app and PyPI package do not establish that this integration is installed. SDK version 2.51.0 here is a source-build version, not a claim that this fork has been released on PyPI.

1. Follow [installing on a real Vision Pro](how_to_install.md) to pair the headset with your Mac, enable Developer Mode, configure signing, and run the **VisionProTeleop** scheme.
2. Charge and power on both Surreal Touch controllers. Hold **X + Y** on the left controller and **A + B** on the right for about **3 seconds**, until each LED flashes green. In the headset’s **Settings → Bluetooth**, select and pair each controller. The vendor manual describes solid green as connected. Pair with the headset itself.
3. Launch the app, grant Bluetooth and tracking permissions, and press **START**. Open **Settings → Surreal Touch** to inspect per-side tracking status, inputs, and head-relative XYZ. Controller tracking is enabled by default while the immersive session is active. Leaving immersion or suspending the app clears live input states.
4. The vendor SDK also requests hand tracking for its own tracking/calibration. Grant that permission for initial hardware testing. This integration never substitutes hand poses or pinches for controller inputs.
5. Install the matching Python SDK and run the diagnostic from the repository root:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e .
python examples/17_surreal_touch.py --ip 192.168.1.100
```

Replace the IP with the address shown in the app and use the same local network for the first test. The `--ip` option also accepts the app’s room code in External Network Mode. The diagnostic prints values only; it does not control a robot. You can also install a wheel built from this fork instead of the editable package.

Pairing references: [vendor SDK instructions](https://github.com/surreal-interactive/SDK#step-by-step-instruction) and [Surreal Touch manual](https://manuals.plus/m/bab0f1a0fa430f003554eb8c8ebcdba3a70f497865f9a813ed012bf0a5249321_optim.pdf).

## Python quick start

The first snapshot may not contain data yet. Call `get_controllers()` repeatedly while the app is streaming, as the diagnostic does.

```python
from avp_stream import VisionProStreamer

s = VisionProStreamer(ip="192.168.1.100")
controllers = s.get_controllers()
left = controllers["left"]
right = controllers["right"]

if not controllers["stale"] and left["pose_head"] is not None:
    left_xyz = left["pose_head"][:3, 3]  # meters, relative to the current head

# Each physical control is independent of hand tracking and the other controller.
a = right["buttons"]["a"]                 # True / False / None (unavailable)
x = left["buttons"]["x"]
left_grip = left["axes"]["grip"]           # 0..1, or None
right_trigger = right["axes"]["trigger"]   # 0..1, or None
right_stick_x = right["axes"]["thumbstick_x"]  # -1..1, or None
right_stick_y = right["axes"]["thumbstick_y"]

# Same controller data is also available in an ordinary tracking sample.
sample = s.get_latest()
if sample is not None:
    controllers = sample.controllers      # or sample["controllers"]
    hands = sample.left, sample.right     # unchanged HandData API
```

## Inputs

| Channel | Left | Right | Values |
|---|---|---|---|
| Face buttons | `x`, `y` | `a`, `b` | Boolean |
| Menu | `menu` | `menu` | Boolean |
| Stick click | `thumbstick` | `thumbstick` | Boolean |
| Trigger | `trigger` | `trigger` | Analog 0–1 and derived press |
| Grip/squeeze | `grip` | `grip` | Analog 0–1 and derived press |
| Stick horizontal | `thumbstick_x` | `thumbstick_x` | Analog −1–1 |
| Stick vertical | `thumbstick_y` | `thumbstick_y` | Analog −1–1 |

These are all the inputs exposed by the vendor's native example. OS-reserved
buttons and capacitive touch signals not exposed by that SDK are not synthesized.
Trigger/grip `buttons` use a 0.5 travel threshold; their full analog values remain
in `axes`. `inputs[name]` includes `active`, `value`, `pressed` and the vendor's
`last_change_time_ns`. Stick axes have no derived `pressed` state. Inactive inputs
are `None`, so applications can distinguish unavailable data from a released
button. Tracking loss can leave valid button data available even when poses are
unavailable. Input snapshots are sampled at approximately 90 Hz; this is not a
lossless button-event queue, and transport rates may be lower.

## Poses and origins

Each side includes:

- `pose_local`: 4×4 controller grip pose in the vendor's LOCAL space.
- `pose_avp`: pose after the configured LOCAL-to-ARKit-world alignment.
- `pose`: world pose in the Python stream's configured axes and AVP/simulation
  origin, consistent with the rest of the stream.
- `pose_head`: pose relative to the **current headset position and orientation**.
  Its axes are always X right, Y up, −Z forward; translation is in meters.
- `active`: runtime action activity (not a Bluetooth connection guarantee).
- `pose_valid`: whether this sample contains a valid controller pose.

Unavailable poses are `None`, never an identity matrix pretending to be tracking.
The sender samples a raw ARKit head pose at the same monotonic timestamp as the
controller poll and sends it in the controller packet. Python calculates:

```text
headFromController = inverse(arkitWorldFromHead)
                   * arkitWorldFromSurrealLocal
                   * surrealLocalFromController
```

This avoids the legacy head's fixed −90° axis adjustment and prevents mixed
head/controller timestamps. `pose_head` is unaffected by `set_origin("sim")`.
It follows the head as you turn; it is not a fixed initial root or a yaw-only body
root.

The default alignment is identity, following the vendor's native RealityKit
sample. Verify it physically, especially after recentering/relocalization. If your
tracking origins differ, set a measured rigid transform:

```python
s.set_controller_origin(arkit_world_from_surreal_local)  # finite rigid 4×4
```

This changes only controller poses, beginning with the next received sample. The
app's XYZ diagnostic shows the default native alignment; a Python correction only
changes the Python output. This software does not claim an unmeasured calibration
or silently derive one from a hand/controller offset.

## First hardware test

Builds and automated tests establish software behavior, not measured controller accuracy. Complete these checks on a real headset:

1. **Independent inputs:** press X/Y and A/B one at a time, then each menu and stick click. Sweep each trigger, grip, and stick through its range. Only the corresponding side/control should change. A hand pinch must not become a controller button press.
2. **Axes and scale:** hold a controller at a roughly measured offset from the headset. For example, 25 cm right, 30 cm below, and 40 cm forward should give approximately `(0.25, -0.30, -0.40)`. The pose represents the vendor’s grip origin, not an arbitrary point on the plastic shell. Move it a measured 20 cm and compare the change.
3. **Head motion:** leave the controller stationary and turn/translate your head. Its head-relative coordinates should change accordingly. Move your head and controller together while keeping their relative pose fixed; the reported relative pose should stay approximately constant.
4. **Origin alignment:** repeat in several positions and after recentering/relocalization. A persistent offset or rotated axes means the identity alignment is not adequate. Determine a rigid LOCAL-to-ARKit transform from measured corresponding poses and pass it to `set_controller_origin()`. One position alone cannot establish a full rotation/translation alignment. No automatic calibration is claimed.
5. **Tracking loss and lifecycle:** turn off one controller, leave/reenter immersion, disable/re-enable controller tracking, and interrupt the network. The other side and hands should remain separate; unavailable or stale data must not be mistaken for live data.

### Troubleshooting

| Symptom | Check |
|---|---|
| Controller missing in Bluetooth settings | Charge/power it on, enter pairing mode again, and pair each side separately. |
| Paired but no inputs | Keep the app’s immersive session active, enable Surreal Touch, allow Bluetooth/tracking permissions, and check the app’s status message. |
| Inputs work but pose is unavailable | Input validity and pose validity are independent. Check tracking permissions and the controller’s tracking environment. |
| Python says it is waiting for the controller-enabled app | Confirm the installed app and Python package came from this fork, START is active, and the IP/room code is correct. |
| Stream is stale | Restore the app/session or network connection. The default 250 ms expiration deliberately clears old poses and inputs. |
| Position has a consistent offset or wrong axes | Check metric scale and head movement, then measure the origin alignment; do not treat the default identity as a verified calibration. |

## Freshness and compatibility

`get_controllers(max_age_ms=250)` returns an owned snapshot. After a stream stall,
`stale` becomes true and both poses and inputs become unavailable. Duplicate
samples do not extend their freshness. Normal `sample.controllers` and
`sample["controllers"]` reads also expire live snapshots after 250 ms. Do not use
an old saved raw dictionary as a live control signal.

`timestamp_ns` is headset monotonic time, not Unix time and not directly comparable
to the client's clock. `sequence` increments each poll. `supported=False` means no
version-1 controller packet was received (including an older app). Disabling
controllers preserves hand tracking. Missing hand skeletons do not prevent the
receiver from processing controller-only packets.

The protocol adds `controllers` as field 4 of `HandUpdate`; fields 1–3 are
unchanged. Both gRPC and WebRTC carry the same message. Older protobuf receivers
ignore the new field. Python recording samples include `controllers`; native app
JSONL recordings store the dedicated protobuf as the optional base64
`controllerTracking` field. `load_jsonl()` decodes it into the same controller API
without applying live freshness expiry. Older recordings continue to load.

## Build and verification

The native dependency is pinned to
[`SwiftSDKBinary` a42deb007c7f12afb543b235b75464e86e00125a](https://github.com/surreal-interactive/SwiftSDKBinary/tree/a42deb007c7f12afb543b235b75464e86e00125a).
The app checks the vendor C API's return codes, initializes poses with an identity
quaternion, keeps native pointers alive during calls, and reads input validity
separately from pose validity. `DEAD_CODE_STRIPPING=YES` is required for this vendor
archive with the installed linker. The archive also declares `xrDestroySpace`
without exporting it; the integration follows the vendor sample's session
ownership instead of calling that missing symbol.

```bash
python -m pip install -e . pytest build
python -m pytest tests/test_controllers.py -q
python -m build
./build_and_install.sh build
./build_and_install.sh device
```

Regenerate protocol bindings with `scripts/generate_tracking_protocol.sh` using
`grpcio-tools==1.71.0` and `protoc-gen-swift` 1.33.3. Set `PYTHON` and
`PROTOC_GEN_SWIFT` to explicit executable paths if needed.

Automated tests cover every independent input, rotation/translation and origin
alignment, missing heads/hands, invalid poses, per-side tracking loss, inactive
inputs, stale packets, both transports, legacy protobuf readers, and recordings.
Physical Bluetooth operation, pose accuracy, SDK/ARKit coexistence and alignment
must be checked with real controllers and a Vision Pro. The simulator can verify
app startup and UI but cannot provide controller tracking.
