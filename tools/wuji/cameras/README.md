# MAGI camera HUD + Wuji Hand 2 Beta 2

Camera-only service on Thor, independent of the body and hand motor controllers.
The Vision Pro receives one flat 1280×720 H.264 view: head RealSense in the center,
Wuji Beta 2 hand models above the two wrist-camera panes. No synthesized stereo
or full-body mesh. All camera images preserve their full field of view.

## Start / stop

On Thor, `systemctl --user restart wuji-camera-hud` starts/restarts the view.
`systemctl --user stop wuji-camera-hud` stops it. The enabled user service starts
with the existing g1gen5 user session. This installer does not change system-wide
login/linger behavior or start any robot motor services.

On PC2, the three enabled user services are `wuji-camera@head`,
`wuji-camera@left`, and `wuji-camera@right`. PC2's existing user linger setting
keeps these available across SSH logouts. Each camera reconnects independently.

Open the Vision Pro app and select START. The current headset endpoint is
192.168.50.236:12345, with signaling advertised at Thor 192.168.50.23:9999.
Override HEADSET, ADVERTISE_HOST or PC2 in `~/.config/wuji-camera-hud.env` on Thor,
then restart the HUD service. Camera endpoint ports are 5560, 5561 and 5562.

## Hand models and state

Models come from the official `wuji-technology/wuji-description` checkout at
c2cd7f8d1ef8b6dc8cb907c17daa5a88b4442d95, `hand2/hand2_beta2/body`.
Both sides retain all 20 anatomical joints, fixed links and fingertip sensor
geometry. Display meshes use 0.5 mm vertex clustering. Source hashes, joint
orders, and resulting asset hashes are in the HUD assets' wuji_beta2_manifest.json.
The upstream MIT license is included as WUJI-LICENSE. `bake_wuji.py` reproduces
these assets from that checkout; it does not change robot kinematics.

Measured joint angles are read from the existing Sharewear session's atomic
`/tmp/dredd-wuji-mink.json`, with file age, feedback age, validity and finite-angle
checks. The HUD never opens a separate SDK connection and never commands hands.
Without fresh measured feedback, a model is explicitly marked REFERENCE POSE or
FEEDBACK LOST / HELD. No operator tracking is misrepresented as measured motion.

## Camera bindings

| View | Serial | Color mode |
| --- | --- | --- |
| Head D435i | 254322072098 | 848×480, 30 fps |
| Left D405 | 260322274506 | 480×270, 30 fps |
| Right D405 | 260322274429 | 480×270, 30 fps |

The head serial was re-enumerated after Thor restarted; it differs from the
previous inventory. The user identified the original wrist assignments as reversed;
the serial bindings above correct that mapping. Configuration is stored in PC2's
`~/.local/share/wuji-cameras/cameras.json`.

## Installation and diagnostics

`bash tools/camera-hud/install-thor.sh` builds and installs the camera HUD.
Copy `pc2/` to PC2 and run its `install.sh`. PC2 reuses system OpenCV, NumPy,
ZeroMQ and pyrealsense2, with MessagePack installed into a private vendor directory.
It does not require root or a global Python package upgrade. For offline PC2,
place the msgpack 1.0.8 cp38 manylinux2014_aarch64 wheel in a `wheels/` subdirectory
beside install.sh before running it. Existing camera assignments are preserved.

Thor writes `/tmp/wuji-camera-hud.json` and `/tmp/wuji-camera-hud.png` (every 5s).
Check the service is active and the status file is updating; the file may remain
on disk after shutdown. PC2 status is in `~/.local/state/wuji-cameras/*.json`.
Producer and consumer monotonic clocks must not be compared across machines.
Camera FPS in the HUD is the rate consumed by the compositor; PC2 reports capture
rate separately. Network RTT and compositor time are not end-to-end latency.

Stale images clear after 500 ms, independently per camera. Preview compression
runs off the render thread. No robot motors are enabled by any of these tools.

Validation performed: three simultaneous live color streams near 30 fps; received
and decoded real images on Thor; hardware H.264 encoding exercised offline; stopped
one wrist service and verified only its view became unavailable, then verified
independent recovery; baked assets reproduced byte-for-byte from the pinned official
checkout. Native HUD tests cover asset/joint integrity, aspect-ratio preservation,
and stale-frame recovery. See the deployment report for final headset validation.

The HUD binds its UDP socket to ADVERTISE_HOST so the receive destination matches
the ICE host candidate. The headset app must have Local Network permission enabled.
A socket connection alone is not a media connection: verify answer_applied and
connected in the Thor status file, increasing encoded_bytes, and a live picture
in the headset. Signaling and peer rebuild reasons are recorded in the service log.

If frames are decoded but the panel is invisible, use Network Stream and the
video panel Reset control. App build 27 corrects the old positive-Z default that
placed the screen behind the head, preserves centered height, and converts the
iOS positive distance setting to RealityKit negative Z.
