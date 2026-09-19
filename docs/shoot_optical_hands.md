# Vision Pro optical hands, no gloves or controllers

Use bare hands. In Tracking Streamer **build 24+**, tap **Use Vision Pro hands only**.
Vision Pro supplies head pose, optical wrist poses and finger articulation. All poses
are in the same native ARKit world, so Surreal world/mount calibration is unnecessary.
Robot neutral-pose mapping is still a separate step. Positions are metres.

## Current left-hand setup

On Thor:

```bash
cd ~/Projects/shoot
sharewear/.venv/bin/sharewear inspect --mode optical --hands left
```

Use `--hands both` for both robot hands. Finger selection does not hide an independently
tracked second wrist. Missing wrists remain missing: SONIC's full three-point target
requires both wrists and the head, even during left-finger development. Fingers can
operate independently without body readiness. Optical mode never generates locomotion
from gestures or controller buttons.

## One shared Wuji finger controller for all three stacks

The tested 20-joint Wuji bridge now lives in `sharewear.wuji`. It consumes the same
`VisionProSource(mode="optical")` as the three adapters. Run it with the existing Wuji
SDK environment (2026.8.31); `PYTHONPATH` makes the shared package importable without
altering that working environment:

```bash
cd ~/Projects/shoot
# Preview retargeting and read robot feedback only:
PYTHONPATH="$PWD/sharewear/src" ~/wuji-venv/bin/python -m sharewear.wuji --side left --duration 10
# Control fingers (one command producer per robot):
PYTHONPATH="$PWD/sharewear/src" ~/wuji-venv/bin/python -m sharewear.wuji --side left --enable-motors
```

Stop any earlier `visionpro_hands.py` sender before enabling the shared bridge.
Do not run this alongside HumDex's Wuji motor server for the same hand. No arm or
body controller is started by this command. Left robot serial `WH2JA01260820042`
and right `WH2KA01260824015` are checked against their configured IPs/handedness.

Tracking loss freezes measured finger positions with motors enabled at 0.5 A.
After 300 ms of valid tracking and at least five distinct samples, motion resumes
from measured positions at at most 1.5 rad/s. Each side recovers independently.
Repeated/old packets cannot refresh tracking. A robot fault, missing robot feedback,
or stalled command loop disables control; Ctrl+C also disables it. The original live
bridge showed encoder-quality and stall warnings: do not interpret this input-layer
integration as validation for higher currents or loads.

## Three entry points

Run these from `~/Projects/shoot` using the shared CPU environment; all are previews:

```bash
sharewear/.venv/bin/python GR00T-WholeBodyControl/gear_sonic/scripts/sharewear_teleop.py --mode optical --hands left
sharewear/.venv/bin/python HumDex/scripts/sharewear_teleop.py --mode optical --hands left
sharewear/.venv/bin/python Humanoid-Teleop/teleop/sharewear_preview.py --mode optical --hands left
```

**SONIC / GR00T:** optical wrists/head replace controller three-point inputs. Supply
`--reference path/to/g1-reference.json` and type `c` + Enter to capture an explicit
operator neutral pose. The existing `--publish`, then `e` + Enter, enables ZMQ output
only; it does not install or start a policy. The Wuji process above handles fingers
separately; no 20-joint Wuji values are put into SONIC's Dex3 fields. Existing body
tracking-loss behavior still stops and requires explicit engagement/reference capture.
Automatic finger recovery does not mean automatic reactivation of a walking robot.

**HumDex:** its standalone three-point route uses the same SONIC adapter. For fingers
with HumDex's existing full-body source instead, select the optical reader:

```bash
cd ~/Projects/shoot/HumDex
SHAREWEAR_MODE=optical SHAREWEAR_HEADSET=192.168.50.236 bash scripts/teleop.sh --policy sonic --body slimevr --hand sharewear -- --hands left
```

That command requires HumDex's policy environment, installed Sharewear, body source,
and hardware stack; it is not a preview. A fingers-only Redis preview is
`sharewear humdex --mode optical --hands left`. Adding `--humdex-redis-url` enables the
existing explicitly engaged publisher. Its downstream motor behavior belongs to
HumDex; use the shared `sharewear.wuji` process for the tested hold/resume behavior.
The actual HumDex 26-to-21 converter is exercised in tests with optical landmarks.

**Humanoid-Teleop:** the main app now selects the native Wuji backend with
`--hand wuji`, using the same shared hardware implementation as `sharewear.wuji`.
It supports left/right/both hands, session start/stop, 20-joint commands/feedback,
hold/recovery, optional Unitree arm IK and 40-slot recordings with explicit validity.
See [the native backend guide](humanoid_wuji_backend.md).

```bash
cd ~/Projects/shoot
PYTHONPATH="$PWD/sharewear/src" ~/wuji-venv/bin/python Humanoid-Teleop/teleop/main.py \
  --hand wuji --hands left --enable-motors --task_name optical-wuji
```

Stop earlier motor writers first. Type `s` + Enter to start, `q` to stop, and `exit`
to quit. The normal hands-only route needs neither the Unitree SDK nor Vuer. Add
`--arms` only in the installed Unitree/IK environment. The preview and input API
are still available independently.

## Validity and verification

Build-24 hand/wrist validity, sample sequence/time and prediction are required.
ARKit's inferred finger joints are accepted while hand/wrist tracking is valid.
Both stream silence and unchanged samples expire at 200 ms; timestamp age and
additional observed network delay also count. There is no absolute clock sync.
The head has independent timestamp expiry even with controllers disabled.

Canonical `sides[side].fingers` identifies `source=visionpro_optical`. `glove` and
`gloves_ready` remain compatibility aliases for existing adapters, not evidence of
glove input. Invalid coordinates are not exposed as current targets. Run
`sharewear/.venv/bin/pytest -q sharewear/tests` to check geometry, wire compatibility,
mode selection, missing sides, stale data and hold/recovery behavior with fake hardware.

The original direct optical Wuji bridge was physically tested on the left robot.
All three new entry points now accept optical mode and pass automated integration
checks. Their first live preview attempts found the headset unavailable; full body
policies, IK and real robot deployment are not validated by these tests.

The native Humanoid-Teleop backend has additionally been tested with both real
Wuji hands in read-only mode and with synthetic optical gRPC input through the real
SDK retargeter. Main-app live headset actuation and physical Unitree arms remain
unverified while the optical stream is unavailable. See its guide for the detailed evidence.
