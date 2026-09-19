# Capture posture restriction correction — 2026-09-19

The user reported capture failure in bridge-20260919T174322Z-9159c497: right shoulder pitch -0.3355 rad and elbow -0.3213 rad. The prior hard-coded encoder posture rule rejected negative elbow deviation beyond 0.30 rad. The model/URDF elbow range is [-1.0472, 2.0944] rad; the recorded elbow is within that physical range. Both modeled palms were in front of the shoulders.

Changes on Thor in Sharewear's dredd_mink.py:

- Removed the fixed 0.30-rad/0.60-rad measured-posture rejection and its debounce. Measured joints are validated against finite values and their model/URDF ranges. The independent 0.6-rad-for-250-ms following-error stop is unchanged.
- Keep a restricted command branch, but adapt its two artificial bounds at each capture to include the measured starting posture. Nominal bounds remain shoulder pitch <=0.8 and elbow >=0 rad. A captured joint outside that nominal box gets 0.05 rad of additional room, clipped to its physical joint range. Repeated captures reset the bounds rather than accumulating extra range.
- Startup and recovery seed projection now use those captured bounds. An accepted negative elbow does not jump to zero at the first live tracking step.
- Log command_posture_bounds_rad with palm diagnostics. Physical position limits, 3 rad/s manipulation velocity, 10 rad/s² acceleration, measured-posture IK, palm-side checks and following-error stops remain.

The exact failed capture frame at monotonic time 7018.476585472 was extracted at the countdown-to-preview transition. The original implementation reproduces the reported capture rejection. The new implementation accepts that same frame, with initial reference exactly equal to measured encoder positions (maximum difference 0 rad). Its captured elbow minima are -0.224466 left / -0.371321 right. No transport or motor driver was opened for this verification.

Tests include startup from multiple negative elbow values, restoration of nominal bounds on recapture, physical-limit rejection, and the actual recorded arm/head/hand geometry. A six-second fixed-target startup exercise passes with ideal feedback and a simulated 200 ms first-order controller lag. These are offline kinematic/trajectory checks, not live robot performance claims.

The earlier boundary-failure recording (125 calibrated samples) also replays fully without faults. Peak generated reference speed is 0.94797 rad/s, peak acceleration 10 rad/s², peak command-to-recorded-encoder difference 0.27305 rad. This removes the initial projection discontinuity noted in the previous boundary report for that recording.

The existing hands process was not restarted or armed by the agent. Updated Python source loads on its next restart. The separate gRPC connection-refused messages concern the headset streaming service and are not bypassed by this posture change.

Validation: **88 tests passed** across IK, continuity, recovery, optical input, grip hold and diagnostic writing. Repository whitespace checks passed. No commit/tag was created; pre-existing unrelated work was preserved.
