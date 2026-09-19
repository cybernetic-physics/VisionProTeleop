# Install the Surreal Touch app on a real Vision Pro

This guide installs Cybernetic Physics’ controller-enabled fork of
[VisionProTeleop](https://github.com/cybernetic-physics/VisionProTeleop).
Build this fork’s app and install its matching Python SDK; the upstream App Store
app does not contain the changes merely because you installed this Python package.

## Requirements

- A Mac with Xcode and the visionOS platform installed. The integration has been
  built with Xcode 26.6 and the visionOS 26.5 SDK; older Xcode versions are unverified.
- A real Vision Pro and a pair of Surreal Touch controllers for tracking tests.
  The app target’s minimum deployment version is visionOS 2.2, but runtime
  compatibility across supported OS versions still needs hardware verification.
- An Apple development team/provisioning setup capable of signing the app and its
  enabled capabilities, including iCloud if retained.
- The headset and Mac on the same network for wireless pairing and the first test.
  A Developer Strap is optional for this wireless workflow.

## 1. Clone and open the project

```bash
git clone https://github.com/cybernetic-physics/VisionProTeleop.git
cd VisionProTeleop
open "Tracking Streamer.xcodeproj"
```

Wait for Xcode to resolve the Swift packages. The Surreal binary dependency is
pinned in the project; no separate Unity or SteamVR installation is required.

## 2. Pair the headset with Xcode

1. On Vision Pro, open **Settings → General → Remote Devices**.
2. In Xcode on the Mac, open **Window → Devices and Simulators**, select the
   headset, and follow the pairing-code prompts. Newer Xcode versions may call
   the device-management window **Device Hub**.
3. On Vision Pro, open **Settings → Privacy & Security → Developer Mode**, enable
   it, restart, and confirm the on-device prompt. Developer Mode appears after
   pairing is initiated or the headset has previously been paired.
4. Keep the headset awake and unlocked until it appears as available in Xcode.

See [Apple’s pairing guidance](https://webkit.org/blog/15421/try-out-your-website-in-the-spatial-web/)
and [Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

## 3. Configure signing and install

1. Open the project settings and select the **Tracking Streamer** target.
2. Under **Signing & Capabilities**, select your development team, enable automatic
   signing, and choose a bundle identifier registered to your team. The repository
   retains upstream identifiers as defaults; it does not provide signing credentials.
3. Configure the enabled iCloud containers and shared Keychain group for your team.
   If using cloud storage or the companion viewer, keep the identifiers consistent
   in both targets’ entitlements, the app’s `Info.plist`, the Keychain managers,
   the viewer’s `CloudKitManager`, and `avp_stream/datasets/cloudkit.py`.
   Changing only the bundle identifier does not provision the original team’s cloud
   containers. Resolve any capability/provisioning errors reported by Xcode.
4. Select the **VisionProTeleop** scheme and your **physical Vision Pro** destination.
5. Press **Run**. Xcode builds, signs, installs, and launches the app. Accept any
   trust or development prompts on the headset.

A development-signed app is tied to its provisioning profile; an app archive
built by another developer is not a generally installable App Store release.

For a compile check without device signing:

```bash
xcodebuild -project "Tracking Streamer.xcodeproj" \
  -scheme VisionProTeleop -configuration Debug \
  -destination 'generic/platform=visionOS' CODE_SIGNING_ALLOWED=NO build
```

This checks compilation/linking only and does not produce an installable signed app.
For simulator builds use ARM64; the included OpenCV simulator framework does not
support x86_64. Simulator launch cannot validate physical controller tracking.

## 4. Pair controllers and start tracking

1. Charge and power on both controllers. Hold **X + Y** on the left and **A + B**
   on the right for about **3 seconds**, until their LEDs flash green.
2. In Vision Pro **Settings → Bluetooth**, pair each controller.
3. Launch **Tracking Streamer** and allow Bluetooth, local-network, and tracking
   permissions. Allow hand tracking for the vendor’s own tracking/calibration;
   the app keeps hand and controller output channels separate.
4. Press **START**. Keep the immersive tracking session active and open
   **Settings → Surreal Touch** to see tracking status and individual controls.

See the [vendor’s pairing instructions](https://github.com/surreal-interactive/SDK#step-by-step-instruction)
and [controller manual](https://manuals.plus/m/bab0f1a0fa430f003554eb8c8ebcdba3a70f497865f9a813ed012bf0a5249321_optim.pdf).

## 5. Test the Python SDK

From the repository root:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e .
python examples/17_surreal_touch.py --ip 192.168.1.100
```

Replace the example IP with the address shown in the headset app. The diagnostic
prints each side’s controls and head-relative XYZ without commanding a robot.
Follow the [hardware test and alignment checklist](surreal_touch.md#first-hardware-test)
before treating head-relative positions as physically calibrated.
