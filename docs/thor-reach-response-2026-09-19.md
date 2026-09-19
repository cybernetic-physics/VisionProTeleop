# Thor forward reach and response update — 2026-09-19

The installed optical companion now defaults to a 1.0 shared workspace scale
(previously 0.8), with live joint speed capped at 3 rad/s, acceleration at
10 rad/s², and Cartesian/posture correction gain at 12/s (previously 1.5, 3,
and 4 respectively). These ceilings remain below the per-joint URDF ratings.
Numeric `--arm-speed` can lower the live speed cap. Existing library callers
retain their previous default workspace scale; the optical session CLI defaults
to 1.0. The launcher uses that CLI default.

The new operator recordings showed that only about 0–5% of fully acquired
samples touched the old 1.5 rad/s ceiling. Raising the ceiling alone would not
address the slow response. The solver's correction rate and acceleration were
also increased. The shared scale now maps 10 cm of tracked hand displacement to
10 cm of requested robot palm displacement, within physical reach. The previous
scale mapped that movement to 8 cm.

## Capture the workspace

With Dredd CONTROL ready and the hands session running, face the working
 direction and press `c` in the hands terminal. During the five-second countdown,
look straight ahead and show both open hands in front of your chest, at least
15 cm ahead of the headset. Hold still during the initial approach. This captures
the working frame and palm orientation; it does not learn arm length or maximum
reach. Looking around afterward does not steer the workspace. Explicitly press
`c` again to recenter.

`--workspace-scale 1.0` is now the default. A larger requested workspace cannot
extend the robot beyond its joint geometry. The initial capture/recovery approach
remains gradual; the faster gains apply to live tracking.

## Validation

The installed Sharewear and Humanoid-Teleop suite passed **192 tests**. Coverage
includes both 0.8 and 1.0 scales, two-handed reaches, rotations and reversals,
nonzero waist angles, 0/80/200 ms synthetic following lag, recorded IK failures,
tracking loss, watchdogs and a forward-response regression.

In the same model test with an 8 cm operator forward step, scale 0.8, and an
80 ms first-order synthetic controller lag, 90% of achieved palm travel was
reached in **0.50 seconds versus 1.04 seconds** before the update. Achieved travel
was essentially unchanged at 4.29 cm. This reports 90% of the achieved motion,
not 90% of an unreachable target and not a measured live SONIC response. With
scale 1.0 the equivalent test starts closer to full extension, so it has less
remaining travel; these times must not be compared as equal-distance motions.

All three earlier failure recordings replayed without a fault. In the main
shoulder-rearrangement recording the new peak requested speed was 2.410 rad/s,
peak acceleration 10 rad/s², and peak command/measured discrepancy 0.271 rad.
These replays retain the original measured trajectory and original calibration
scale, and do not predict the hardware's response to changed commands.

Measured-posture anchoring, captured elbow preference, braking constraints,
the 0.6 rad / 250 ms following-error stop, and the 100 ms solve watchdog remain.
No controller or motor process was started as part of tuning. Live feel still
needs an operator check after restarting the hands process.

Machine-readable comparisons are saved on Thor at
`~/Projects/shoot/sharewear/deployment/reach-response-20260919.json`.
The previous installed source and continuity tests are backed up at
`/home/g1gen5/thor-response-backup-20260919T082827`.
