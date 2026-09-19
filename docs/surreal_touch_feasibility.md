# Surreal Touch feasibility

> Historical investigation. Implementation is now in the app and Python SDK; see
> [Surreal Touch setup and API](surreal_touch.md). The notes below describe the
> state before implementation.

Investigated on 2026-09-18 using Xcode 26.6 (17F113).

## Existing checkout

Use `/Users/luc/wagmi/VisionProTeleop`, whose origin is
`https://github.com/Improbable-AI/VisionProTeleop.git`, at commit `4c54990`.
It already contains local signing, bundle identifier, and cloud configuration
changes. Another checkout of the same upstream exists at
`/Users/luc/wagmi/VisionProTeleop-Improbable-AI`; the `-G-structure` directory
is a different fork. No additional app clone is needed.

The existing application **passed unsigned Debug builds for physical visionOS
and the ARM64 visionOS simulator**, using scheme `VisionProTeleop` and
`CODE_SIGNING_ALLOWED=NO`. This verifies
compilation and linking of the current app, not installation, signing, or Surreal
integration. Existing local app configuration was preserved.

## Feasibility and current limits

Surreal provides a native [Swift SDK](https://github.com/surreal-interactive/SwiftSDK)
with separate left/right grip poses, buttons, triggers, and sticks. It targets
visionOS 2 or newer. Unity is not required. This checkout does **not** yet
integrate that SDK; its existing `AccessoryTrackingManager` handles `GCStylus`.
Declaring `SpatialGamepad` in the app's plist does not establish Surreal support.

The SDK's Swift wrapper at `d3eba221afdea3d2a7029317d66cc6e904da8075`
compiled against the device visionOS SDK on this Mac. A separate link probe
against the current [binary SDK](https://github.com/surreal-interactive/SwiftSDKBinary)
at `a42deb007c7f12afb543b235b75464e86e00125a` failed with duplicate
`_global_instance` definitions in the vendor archive's `instance.o`, `session.o`,
`action.o`, `action_set.o`, and `space.o`. Repeating the link with `-dead_strip`
succeeded, producing `/tmp/libSurrealIntegrationProbe.dylib` with the OpenXR entry
points present. The duplicate definition is still reported as a warning. A future
application integration should verify its `DEAD_CODE_STRIPPING` setting and check
both Debug and Release builds; the successful standalone probe is not an app or
hardware test. The vendor warning should be reported upstream when appropriate.

No Vision Pro was listed as connected by `xcrun devicectl list devices` during
the investigation. Pairing, tracking accuracy, runtime permission behavior,
coexistence with the app's ARKit session, and origin alignment remain untested.

## Head-relative coordinates

For a root attached to the current headset position **and orientation**, use:

```text
headFromController = inverse(worldFromHead) * worldFromController
```

The translation column gives the controller position in meters in the headset
frame. The rotation gives the controller orientation relative to the headset.
Subtracting positions alone keeps the room's axes; it does not account for
turning the head.

Both poses must use the same timestamp and world frame. The Surreal wrapper
locates controller poses in `XR_REFERENCE_SPACE_TYPE_LOCAL`; the application
gets its head pose from ARKit `originFromAnchorTransform`. The inspected wrapper
does not document a guarantee that these origins are identical. If they differ,
use a measured alignment:

```text
headFromController = inverse(arkitWorldFromHead)
                   * arkitWorldFromSurrealLocal
                   * surrealLocalFromController
```

An alternative to investigate is locating the controller directly against an
OpenXR `VIEW` reference space in the vendor runtime. The public wrapper does not
expose this, and the presence of the OpenXR enum in a header is not proof that
the runtime implements it.

The Python client currently applies `axis_transform` and then a fixed -90 degree
X rotation to the head (`rotate_head`). Define new head-relative fields explicitly
in the raw headset frame (X right, Y up, -Z forward), or document a deliberate
robot-frame conversion. Do not silently mix that adjusted Python head basis with
raw controller poses. A fixed initial head root or a yaw-only body root would
require a different, explicitly named transform.

## Integration points

1. Pin and link the Surreal binary with the verified build setting, then add a controller manager with
   explicit start/stop and permission handling. Add Bluetooth usage descriptions;
   the app already declares hand-tracking usage through its build settings.
2. Bind `/user/hand/left/input/grip/pose` and
   `/user/hand/right/input/grip/pose` to the Surreal interaction profile, following
   the vendor's native sample. Track each side's validity separately and clear
   stale poses after tracking loss or disconnection.
3. Sample controller and head transforms at a common time. The app polls head
   tracking in `AppModel.queryAndProcessLatestDeviceAnchor`; the vendor clock uses
   `CACurrentMediaTime` converted to nanoseconds. Confirm the world alignment on
   hardware and repeat that check after recentering or relocalization.
4. Extend the tracking message with dedicated controller poses, tracking flags,
   timestamps, and optional inputs. Update both the Swift sender and Python
   receiver, retaining hand/wrist data as separate fields. Proposed Python output:
   `controllers["left"]["pose_head"]` and
   `controllers["right"]["pose_head"]`, each a 4-by-4 transform when valid.
5. Validate on the headset: move each controller independently; hold controllers
   still while rotating/translating the head; check left/right assignment, axes,
   and metric scale; disconnect/reconnect; leave/reenter immersion; and test
   recentering. No stale or unaligned pose should be published as valid.

## Probe logs

Temporary investigation files on this Mac:

- `/tmp/visionpro-surreal-baseline-arm64-build.log`: app ARM64 simulator build.
- `/tmp/visionpro-surreal-device-baseline-build.log`: unsigned device build.
- `/tmp/visionpro-surreal-sdk-compile.log`: native SDK wrapper compilation.
- `/tmp/visionpro-surreal-sdk-link.log`: native SDK device link probe.
- `/tmp/visionpro-surreal-sdk-link-dead-strip.log`: successful link probe with
  dead-code stripping enabled.

The initial generic simulator build was stopped after discovering that it also
requested x86_64, whereas the checked-in OpenCV simulator framework supports
ARM64 only. The simulator check was restarted explicitly for ARM64.

The SDK was downloaded into `/tmp/visionpro-surreal-sdk-binary` for inspection;
it has not been added as an application dependency.
