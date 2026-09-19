# Direct-body stop at wrist endpoint — 2026-09-19

The reported bridge session `bridge-20260919T182326Z-7fc27e02` stopped after the native controller entered passive release. The triggering native trace is `direct-arm-1789842220-128995.jsonl`.

The first rejected measured right wrist pitch was -1.6165521144866943 rad versus the -1.61443 rad model boundary: 0.0021226 rad outside. This exceeded the recently added 0.002 rad feedback tolerance. Native traces immediately before and after that run show the same cause, at -1.6164442300796509 and -1.6164562702178955 rad. The bridge's `direct_releasing` error is downstream of this native stop. Wuji feedback was approximately 2.8 ms old and IK took 6.4 ms in the pasted final sample; the SDK backlog warnings were not the triggering native condition.

Changes on Thor:

- Align native and IK measured-feedback tolerance at 0.01 rad (0.57 degrees). Project only the IK/startup/hold seed to the original model boundary, preserving raw feedback and following-error checks. Physical command limits are unchanged; materially larger feedback violations still fail.
- Emit `measured_arm_joint_limit` to the companion when that causes release. Direct JSONL `stop_detail` now records the exact joint, measured value, limits and tolerance, instead of retaining only generic `runtime_error`.
- Fault damping uses the last successfully published, valid position array with zero stiffness/velocity/feedforward. Invalid sensor values cannot prevent a passive-damping packet from passing the DDS finite-value checks.

Validation: 16 targeted Python tests passed (including all three newly recorded values), 198 Dredd tests passed, and the hardware binary rebuilt successfully. No motor output was enabled during this fix. Restart both body and hands processes to load their matching new tolerance.
