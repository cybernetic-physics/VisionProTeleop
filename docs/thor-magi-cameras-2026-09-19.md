# Thor MAGI HUD deployment — 2026-09-19

The camera service runs independently of Dredd/SONIC motor control. No arm or hand
motor output was enabled during this deployment. The existing wuji-2 tags were
not moved.

## Installed components

- PC2 (`unitree@192.168.123.164`, through Thor): three user services,
  `wuji-camera@head`, `wuji-camera@left`, `wuji-camera@right`, enabled and running.
  Publisher/configuration: `~/.local/share/wuji-cameras/`.
- Thor (`g1gen5@100.87.202.8`): enabled `wuji-camera-hud` user service,
  executable `~/.local/bin/wuji-camera-hud`. Starts with the existing user session.
  Source: `~/Projects/dredd-teach-mode-adam/services/g1-dredd/`, specifically
  `crates/dredd-hud/`, the Jetson library-path fix in `crates/dredd-stream/build.rs`,
  and reproducible installation/model tools in `tools/camera-hud/`.
- Vision Pro: app build 27, bundle `com.lucchartier.VisionProTeleop`, installed.
  Address confirmed by the user: `192.168.50.236`.

## Display

Original MAGI bezel, colors and typography. Flat 1280×720 video at a 30 fps target,
with the head RealSense centrally, official Wuji Hand 2 Beta 2 models on either
side, and both wrist cameras beneath them. No synthesized stereo or full-body
robot model. Camera images are letterboxed rather than cropped.

Official hand source: `wuji-technology/wuji-description` revision
`c2cd7f8d1ef8b6dc8cb907c17daa5a88b4442d95`, `hand2/hand2_beta2/body`.
Generated render assets match a second bake from the pinned Thor checkout
byte-for-byte. Each hand preserves twenty driven joints, all fixed transforms,
and the fingertip sensor geometry. The baked render geometry uses 0.5 mm vertex
clustering; no controller geometry or joint limits were modified.

Hand animation reads measured feedback from `/tmp/dredd-wuji-mink.json` only when
both the file and the feedback are fresh. Missing feedback is labeled REFERENCE
POSE; lost feedback holds the last pose with an explicit label. The HUD does not
create Wuji SDK sessions, enable motors, or substitute tracked operator fingers
for measured robot angles.

## Cameras

| View | Model | Serial | Actual stream |
| --- | --- | --- | --- |
| Head | D435i | 254322072098 | 848×480 color, ~30 fps |
| Left wrist | D405 | 260322274506 | 480×270 color, ~30 fps |
| Right wrist | D405 | 260322274429 | 480×270 color, ~30 fps |

Head serial was re-enumerated after Thor rebooted and corrected from the previous
inventory. The user identified the original wrist assignments as reversed, so
the left/right serial bindings were swapped. All devices bind by serial, never /dev/videoN.

## Connection correction

The app previously labeled receipt of a WebRTC advert as “connected,” and its
TCP helper reported “socket connected” after a fixed 100 ms sleep. Build 26
instead checks actual stream-open/error states, uses common run-loop modes,
closes streams on completion/cancellation, bounds connection/read/write waits,
and uses actual ICE state for the connection badge.

The installed app's Info.plist was also missing NSLocalNetworkUsageDescription.
Added the declaration and verified it exists in the built bundle. The updated
app exposed the previous hidden error: NSPOSIXErrorDomain 50, “Network is down.”
The user then confirmed Local Network access was off and enabled it. Apple
requires local-network privacy support for direct connections to local devices:
[Apple local-network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

The subsequent “Answer sent” / “ICE failed” problem was resolved by binding the
HUD UDP socket to the configured advertised Wi-Fi address (`192.168.50.23`) rather
than `0.0.0.0`. The transport passes its socket address to str0m as each received
packet's destination; it must match the advertised ICE candidate. After this
change the headset answer was applied and the peer connected immediately. Added
concise signaling/peer-rebuild diagnostics without logging SDP credentials.

## Validation

- All three PC2 streams simultaneously delivered ~30 fps; real JPEG images were
  received and decoded on Thor.
- Complete HUD visually inspected with real images and the correct Beta 2 models.
- Native tests: 8 passed, including asset integrity/joint motion, image aspect
  preservation, stale-image expiry/recovery, and the signaling exchange.
- Hardware H.264 encoding exercised independently: 3,864,000 encoded bytes in the
  six-second check. This check did not claim a connected headset.
- Stopped the left camera service: head/right remained live while left became
  unavailable. Restart restored the left feed without restarting the HUD.
- Final compositor samples: approximately 30 fps and ~15–17 ms render time.
  These are not end-to-end video latency measurements.
- Vision Pro build 26 compiled, signed and installed successfully. Final media
  transport connection was verified after permission and UDP address fixes:
  `answer_applied=true`, `connected=true`, and 18,966,688 encoded bytes after
  22 seconds, with receiver RTCP feedback (12.6 ms RTT in that sample). The HUD
  stayed near 30 fps. After restarting the app, headset logs also confirmed decoded 1280×720
  frames reaching VideoFrameRenderer and CombinedStreamingView. The user still
  saw no panel; investigation found the display-position bug described below.

Thor diagnostics: `/tmp/wuji-camera-hud.json` and `/tmp/wuji-camera-hud.png`.
Restart with `systemctl --user restart wuji-camera-hud`. Stop with
`systemctl --user stop wuji-camera-hud`. Verify the status file keeps updating;
it can remain after shutdown. Local preview: `docs/runtime/magi-wuji-beta2-2026-09-19.png`.

## Invisible panel correction (build 27)

The headset's saved preferences had no videoPlaneZDistance, videoPlaneYPosition,
or videoPlaneScale. The app therefore placed the panel at its old defaults:
Z=+1.6 and Y=+1.5, behind and above the head-following anchor. The WebRTC renderer
was receiving frames; the display position was wrong.

Use the existing Reset placement for new installations: Z=-10, Y=0, scale=1.
Preserve valid saved negative distances and zero height; convert legacy positive
saved distances to negative Z. iCloud uses a positive distance in the iOS control,
so incoming values now become negative Z and outgoing values use their magnitude.
The first-frame log now includes panel position, scale, and hidden state.
Build 27 compiled, signed, installed, and launched successfully. The restarted
headset reported live decoded frames and panel Z=-11, Y=0, scale=1, hidden=false
(the saved user distance was preserved). The user confirmed: “Yes, visible now.”
The live MAGI HUD is working in the headset. The user subsequently identified the wrist views as reversed. Left/right serial
bindings were corrected in the deployed PC2 configuration and installation sources.

## Release tag

`wuig-video` records the video changes in both repositories. Thor Dredd commit:
`01340d4c3f21e16972b1df8c41dd46d3276754f8`. The VisionProTeleop commit includes
only this session's video/app fixes and deployment sources; pre-existing local
controller, tracking, signing, and other edits remain outside the commit. The
installed build 27 was validated with those existing workspace edits present.
The prior `wuji-2` tags are unchanged. Tags are local; no push was requested.
