# Wuji arm response and encoder endpoint correction — 2026-09-19

The Thor Wuji launcher now defaults to the `urdf` motion profile for both the hands companion and supported direct body controller. Existing launch commands select the new profile after both processes restart. Motor output was not activated during validation.

## Final behavior

- Workspace scale remains 1.0 in the launcher: shared translation mapping, constrained by robot reach and feasible posture.
- The extra Cartesian low-pass is removed in the URDF profile: each fresh mapped pose enters IK at unit task gain. The direct controller also removes its proportional position-response filter and tracks the target through the bounded trajectory. No added small-motion deadband exists in the inspected optical tracking path. Vision Pro still uses Apple's tracked/predicted poses; this does not bypass ARKit internals.
- Effective velocity ceilings come from the pinned URDF: 37 rad/s for shoulder, elbow, wrist roll; 22 rad/s for wrist pitch/yaw. The hidden 3 rad/s manipulation cap is removed in the new profile. Acceleration is bounded to 30 rad/s² in both IK and direct actuator admission.
- Native DDS velocity feedforward remains limited to 6 rad/s. That is separate from position-reference velocity; no DDS ABI safety gate was weakened. These rates are ceilings, not guaranteed measured motion.
- Capture/recovery transitions, measured-posture stabilization, physical joint boundaries, command/feedback freshness, and the 0.6 rad/250 ms following-error stop remain. The controller cannot reproduce untracked elbow motion or infeasible palm poses exactly.
- Direct braking now includes the next discrete integration step. The new fast-profile endstop test caught overshoot with the previous continuous braking formula; the corrected formula passes both physical wrist endpoints with acceleration bounds intact.

## Wrist crashes

Both exact reported readings are handled:

- Right wrist pitch: -1.6148383617401123 rad.
- Left wrist pitch: -1.6145148277282715 rad.
- Model lower boundary: -1.614429558 rad.

Measured feedback may differ from a boundary by at most 0.01 rad (0.57°), revised after the follow-up endpoint recordings. Within that tolerance, only the model seed / emitted hold is projected to the exact boundary. Original feedback remains in diagnostics and following-error comparisons. Larger violations still fail. No physical model or commanded target limit was widened.

The correction covers model initialization, preview, calibration, capture countdown, tracking-loss hold, recovery, unselected arms, and supported direct-controller startup. Finger configuration validation remains strict.

## Launch on Thor, robot physically supported

Stop old body/hands processes before starting these two terminals. No SONIC or gamepad Start is used.

```bash
~/Projects/dredd-teach-mode-adam/services/g1-dredd/tools/start_wuji.sh direct-body enP2p1s0 --enable-motors
```

```bash
~/Projects/dredd-teach-mode-adam/services/g1-dredd/tools/start_wuji.sh hands --headset 192.168.50.236 --workspace-scale 1.0 --enable-arms --enable-motors
```

Press `c` in the hands terminal and complete the capture countdown. The body initially acquires the measured arm pose over two seconds. It provides no balance; the robot must remain supported. Camera HUD and logging are independent.

For the earlier profile, prefix **both** commands with `WUJI_MOTION_PROFILE=manipulation`; it keeps 3 rad/s, 10 rad/s² and the earlier Cartesian response. Omitting `--enable-motors` from direct-body gives read-only preview and opens no motor writer.

After capture, `q` or body-terminal Ctrl-C releases arm stiffness over ten seconds. Faults enter passive damping immediately. Before capture, `q` exits only the companion; stop the body too to release its measured-pose hold.

## Validation

- 103 Python tests passed: measured limits, full IK suite, continuity, recovery, optical tracking, grip hold, keyboard handling, and diagnostics.
- 197 Dredd tests passed, including twelve direct-controller tests, exact wrist readings, fast physical-endpoint approaches and bounded acceleration.
- Offline 10 mm target-step test with ideal feedback: 50% IK response improved from 80 ms to 20 ms.
- Offline 0.25 mm amplitude, 5 Hz motion: commanded palm peak-to-peak 0.472 mm (requested approximately 0.476 mm at the sample times). This verifies small motion is not discarded.
- No live fast-profile motor response has been measured. These are software/model results, not claims of robot latency or grip strength under load.

Final motor-off integration: both processes started in URDF mode; the companion accepted 249 fresh robot feedback samples, emitted zero arm packets, and the native preview recorded 400 samples with zero motor frames. Both exited normally after the specified duration. The headset tracking server refused the connection during this final check; reopen the streaming view before capture. The earlier optical connection and model tests do not substitute for a live loaded test of this profile.
