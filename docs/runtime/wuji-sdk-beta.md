# Wuji Hand 2 Beta 2 runtime

This rig uses **Wuji Hand 2 Beta 2 robot hands**. It does not use the archived
original Wuji Hand driver (`wujihandpy`). Optical input comes from Vision Pro;
Wuji wearable gloves and Surreal controllers are not required.

## Pinned deployment

- Official Python package: `wuji-sdk==2026.8.31`.
- Native API: `SdkManager`, `DeviceType.WujiHand2`,
  `RetargetSession.for_hand(HandModel.WujiHand2)` and `JointCommand`.
- Left serial: `WH2JA01260820042`, address `192.168.1.110`.
- Right serial: `WH2KA01260824015`, address `192.168.1.111`.
- `A01` in serial positions 5–7 identifies Beta 2. `A00` is Beta 1.
- Official model source: `https://github.com/wuji-technology/wuji-description`,
  commit `c2cd7f8d1ef8b6dc8cb907c17daa5a88b4442d95`,
  directory `hand2/hand2_beta2/body`.

2026.8.31 is the newest published SDK version found on 2026-09-19, including
pre-release versions. “Beta 2” identifies the hand hardware/model revision; it
is not a separate beta-named pip package. Firmware has not been changed.

At startup the shared motor backend verifies the installed distribution's exact
version and import location, required Hand 2 APIs, selected device serial, address,
handedness and twenty online joints. It rejects a legacy checkout shadowing the
installed SDK. Status records include the SDK version/path and model revision.
Tests using an explicitly injected fake SDK do not access hardware.

Restore the pinned SDK and official model checkout with `bash scripts/setup_wuji_beta2.sh` from Sharewear.
The script refuses to silently replace a different or edited model revision.

Use the shared environment on Thor:

```bash
cd ~/Projects/shoot
sharewear/.venv/bin/python -m sharewear.wuji --side both --duration 5
```

This command reads live feedback and retargets optical landmarks without enabling
motors. `--side left` and `--side right` are supported. Read-only verification on
2026-09-19 discovered both expected Beta 2 hands, read all twenty positions per hand,
and retargeted live optical tracking with **zero commands and motors disabled**.

Humanoid-Teleop's `--hand wuji` route, the shared optical finger process used with
HumDex/SONIC, and Sharewear's G1-Dredd session all import this shared backend.
HumDex's old `server_wuji_hand_redis.py` and
`server_wuji_hand_qpos_target_redis.py` still belong to the archived hand hardware;
do not use them for this rig. A body-input preview is not a running robot policy.

## Collision geometry correction

The previous combined preview incorrectly loaded archived first-generation Wuji
meshes from HumDex's retargeting checkout. The builder now refuses those models and
uses the official Beta 2 links, twenty anatomical joints per hand, and fingertip
sensor geometry. It preserves the manufacturer's explicit assembly-overlap pairs.
The Beta 2 fingers extend along local -Z; the G1 mount rotates this to wrist +X,
with a 5 mm axial surface gap and the original palm-normal orientation. The wrist
mesh extends about 7 mm behind its root frame; the builder includes this offset
instead of treating the root as the rear mounting surface.

The combined model is for kinematic checks. It is not a verified inverse-dynamics
model: the source G1 wrist inertia includes the removed Dex assembly. The actual
mount, cover and camera envelope must agree with the model before physical clearance
can be claimed. Correct SDK selection does not certify the startup/collision guard.

References:
- https://docs.wuji.tech/docs/en/wuji-sdk/latest/release-notes/
- https://docs.wuji.tech/docs/en/wuji-hand/latest/version-compatibility/

## Guard development status

The new MuJoCo projection checks measured geometry, blocks closing motion at a
protected boundary, permits retreat, and checks sampled nonlinear target paths.
HumDex and Wuji writers now have final command-filter hooks, tested after release
transforms and on hold commands. These hooks are not yet connected to a complete
live session coordinator. Startup planning, body/finger synchronization, native
writer supervision and physical profile validation remain necessary before this
is a running guarded HumDex teleoperation session. No motors were enabled here.
