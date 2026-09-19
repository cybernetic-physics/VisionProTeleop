# Wuji supported direct arms — 2026-09-19

Thor now has a policy-free `arm-direct` controller. It does not load SONIC or require gamepad Start/CONTROL. The robot must remain physically supported/suspended: this mode provides no standing balance. Existing AVP tracking, camera HUD, Wuji SDK, and RGB-D logging remain independent.

## Launch on Thor

Stop the old body and hands sessions first. The shared robot lock refuses concurrent Dredd motor writers. In the first Thor terminal:

```bash
~/Projects/dredd-teach-mode-adam/services/g1-dredd/tools/start_wuji.sh direct-body enP2p1s0 --enable-motors
```

In the second Thor terminal:

```bash
~/Projects/dredd-teach-mode-adam/services/g1-dredd/tools/start_wuji.sh hands --headset 192.168.50.236 --workspace-scale 1.0 --enable-arms --enable-motors
```

The body acquires the measured arm pose over two seconds. In the hands terminal, press `c`, face forward, and show open hands through the countdown. No Start button or SONIC CONTROL is involved. Begin with small supported movements; physical response and gains have not been commissioned in this mode.

`q` in the hands terminal (after capture) or Ctrl-C in the body terminal releases arm stiffness over ten seconds, then sends passive damping for one second. Leave the body terminal running until release finishes. Before capture, `q` only exits the companion; Ctrl-C the body to release its measured-pose hold. A runtime fault enters passive damping immediately, latches, and exits; restart direct-body before recapturing. Wuji finger cleanup remains owned by the hands companion.

Omit `--enable-motors` from direct-body for read-only feedback. It creates no DDS writer, does not release controllers, and never advertises motor output active. Preview alongside an existing body process requires a separate feedback port, e.g. `--zmq-out-port 5567 --preview-seconds 10`; use `hands --feedback tcp://127.0.0.1:5567` without motor flags.

## Controller behavior and limits

- Dedicated 500 Hz arm loop, CPU 12 by default; asynchronous debug output and JSONL recording. A one-sample output queue prevents telemetry backlog.
- Hardware arm slots 15–28 only. Lower-body target is refreshed to measured position with the existing masked-damping stiffness floor 0.05 (the DDS wire validator requires positive stiffness on mixed frames). No lower-body velocity target or feedforward torque; this is effectively damping, not a body pose hold.
- Direct PD gains: shoulder/elbow 40/2, wrists 12/1. No modeled gravity or inertia feedforward; Wuji payload compensation has not been validated.
- Final target trajectory bounded to 3 rad/s and 10 rad/s², with velocity feedforward. First enabled target must be within 0.15 rad of fresh measured arms. This checks handover continuity, not a nominal posture.
- Actual hardware joint bounds, 100 ms command/feedback freshness, monotonic sequence and original source timestamp checks, 20 ms actuator deadline, and the existing 0.6 rad/250 ms following-error threshold. Faults cannot auto-resume on new packets.
- Physical startup requires explicit motor/support flags, the shared robot lock, successful MotionSwitcher RPC, and confirmed empty controller identity. Existing SONIC release behavior is unchanged.
- Records `~/Projects/shoot/dredd-recordings/direct-arm-*.jsonl`: measured feedback, feasible incoming goal, actual final servo q/dq/gains, timestamps, and stop reason. These are direct-mode JSONL traces, not SONIC MCAP sessions.

## Validation

195 Dredd unit tests passed, including ten new direct-arm tests: physical bounds, trajectory velocity/acceleration, small-motion settling, first-target continuity, normal release, malformed/stale/replayed commands, CLI motor admission, lower-body damping, and a 300-sample (~6 s) replay from the last run. Replay uses the recorded SONIC measurements; it does not simulate direct-controller dynamics.

A ten-second read-only run on Thor published fresh feedback accepted by the existing Wuji companion: 201/201 sampled messages accepted and ready, zero active-motor reports. Camera HUD and robot-state recording services remained active. No live direct-arm motor test has been performed; improvement under load remains to be measured.
