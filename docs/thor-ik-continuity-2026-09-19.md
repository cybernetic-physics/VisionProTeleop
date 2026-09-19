# Thor IK continuity correction — 2026-09-19

Installed in `~/Projects/shoot/sharewear`. Dredd/SONIC remains the body controller;
this corrects the existing Mink optical companion. It does not switch to hybrid
arm control or replace the native body executable.

## Cause and correction

The previous solver advanced from its last command, used a weak arbitrary rest
posture, and permitted URDF hardware speeds (22–37 rad/s). With redundant arm
kinematics, it could change shoulder/elbow configuration drastically while the
modeled palm barely moved. The recorded peak command-to-encoder discrepancy was
2.013676 rad and requested speed reached 10.445289 rad/s.

Each live solve now uses an explicit measured-joint posture objective. A weaker
shoulder-roll/yaw and elbow objective retains the captured configuration, instead
of pulling toward an unrelated hardcoded rest posture. Cartesian and posture
correction gains scale with elapsed time. The previous command remains the
integration origin so the trajectory is continuous even with lagging encoders.

A single QP trajectory constraint bounds live velocity to the smaller of the
configured/URDF speed and **1.5 rad/s**, and acceleration to **3 rad/s²**. It also
reserves braking distance before joint/forward-posture boundaries. Invalid or
infeasible output faults before publication. Reacquisition preserves the held
reference rather than jumping to newly received encoder values.

The existing immediate tracking-loss measured hold, tolerated-feedback projection
into the forward posture, and shutdown/release behavior are retained; these
safety transitions are separate from the live trajectory acceleration guarantee.
The shared absolute workspace, calibrated anatomical palms, fixed working yaw,
measured waist geometry, and recovery to the original mapped target remain.

The **0.6 rad / 250 ms following-error stop**, feedback-posture thresholds,
**100 ms solve watchdog**, and native freshness checks are unchanged. A stalled
arm still faults in regression tests. No motor-enabled validation was performed.

## Validation

The installed Sharewear and Humanoid-Teleop suite passed **188 tests**, including
real Mink/MuJoCo solving, recorded failure replay, no redundant drift for a
stationary palm, two-handed reaches/rotations/reversals, nonzero waist angles,
0/80/200 ms simulated following lag, per-side loss/recovery, and invalid solver
output rejection. Existing motor coordination, cleanup and watchdog checks pass.

Three archived failures replayed to completion (84, 85 and 84 post-capture samples).
For `bridge-20260919T151123Z-9915f2f3`:

| Metric | Recorded old commands | Corrected replay |
| --- | ---: | ---: |
| Peak command / measured joint difference | 2.013676 rad | 0.434093 rad |
| Peak command speed | 10.445289 rad/s | 0.876397 rad/s |
| Peak command acceleration | not asserted | 3.0 rad/s² |
| Following-error fault | yes | no |

Replay uses the **original measured feedback**, not predicted feedback under new
commands. The short recording ends during the startup approach; its remaining
palm-position/orientation error is not evidence of achieved tracking. Older
recordings omitted sample receipt times, so replay assumes those samples fresh.
Freshness is covered separately by tests, and new recordings now save receipt
times and stale status. Live response, payload behavior and subjective feel remain
unverified. Model geometry commissioning limitations still apply.

Machine-readable results: `sharewear/deployment/ik-continuity-20260919.json`.
Reproduce without opening motor transports:

```bash
cd ~/Projects/shoot
sharewear/.venv/bin/python -m sharewear.dredd_replay \
  dredd-recordings/bridge-20260919T151123Z-9915f2f3/flight-history.json
sharewear/.venv/bin/pytest -q sharewear/tests Humanoid-Teleop/tests
```

The normal launcher loads the installed Python source on its next start; no body
binary rebuild is required. For read-only review, use `start_wuji.sh hands` without
either enable flag. Do not interpret these offline results as live commissioning.

Previous Python files are backed up at
`/home/g1gen5/thor-ik-backup-20260919T082042`.
