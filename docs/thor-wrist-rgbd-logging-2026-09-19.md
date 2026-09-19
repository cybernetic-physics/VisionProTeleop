# Wrist RGB-D logging deployment — 2026-09-19

Both PC2 D405 wrist cameras are recording native, unrotated lossless color PNGs and raw uint16 depth PNGs at 480×270, approximately 30 fps. The right wrist HUD retains its 180° display correction. The head stream remains color-only. No SLAM or motor-control changes were made.

Each dataset has factory color/depth intrinsics and distortion, depth-to-color extrinsics, depth scale, stream formats, camera serial, session and boot IDs, per-stream frame numbers, SDK timestamps/domains and metadata, and host receive wall/monotonic clocks. Depth is unaligned and unfiltered. Camera-to-wrist mounting transforms are explicitly unknown and still require calibration.

PC2 data location: `/home/unitree/wuji-rgbd-recordings/`. Initial verified datasets:

- `20260919T172738Z-left-1ccc1eb3`
- `20260919T172738Z-right-4ef59189`

Thor measured joint/body feedback is recorded through a read-only subscriber to the existing Dredd debug publisher, without opening a command socket. Data location: `/home/g1gen5/Projects/shoot/dredd-recordings/rgbd-robot-state/`. Current verified dataset: `20260919T173615Z-robot-f95951e5`. If Dredd stops, the logger waits for telemetry rather than substituting stale positions.

## Timing

PC2 wall time was approximately 478.64 seconds behind Thor. Dataset folder times therefore cannot be compared directly. A separate background worker records clock pairs every two seconds over persistent SSH, retaining both hosts' monotonic/wall timestamps and RTT uncertainty. Recent RTTs were 0.7–1.0 ms; the first handshake sample has much higher uncertainty. This establishes host-clock correspondence, not hardware exposure synchronization. Camera SDK timestamps reported `global_time`. Host arrival must not be treated as exposure time. Use boot IDs and clock-pair measurements when associating camera and robot samples; the first camera frames precede the first clock-pair measurement and require extrapolation if used.

## Operation

On Thor:

```bash
~/.local/bin/wuji-rgbd-record status
~/.local/bin/wuji-rgbd-record stop
~/.local/bin/wuji-rgbd-record start
```

Start/stop affects recording only; camera HUD streaming continues. Recording is currently enabled. The PC2 marker and enabled Thor logger persist across reboot until stopped.

Camera data is written by separate workers with eight-frame-pair queues; overload is counted and drops recording pairs instead of blocking camera capture. Recording errors or less than 20 GiB free stop disk logging while camera display continues. Existing recordings are not deleted. Observed lossless storage consumption was approximately 70 GB/hour combined, varying by scene. PC2 had approximately 1.8 TB free at setup.

## Verification

- Three PC2 tests passed: lossless color/depth round-trip with original orientation and copied SDK memory; disabled logging/disk guard; bounded queue saturation.
- One isolated fake-publisher integration test passed on Thor, verifying measured joint arrays and original/arrival timestamps.
- Read back 30 real pairs from each wrist: correct image dimensions, uint16 depth, complete calibration. Valid depth pixels averaged about 69% left / 66% right for that scene; invalid pixels remain zero.
- Both wrists passed 3,300 recorded pairs with zero recording-queue drops, missing depth, or camera frame-number gaps, near 30 fps.
- Thor passed 3,600 live measured joint samples with zero source-index gaps or decode errors.
- All three HUD panes remained live, with compositor approximately 29 fps in the final check.
- Python syntax, shell syntax and repository whitespace checks passed.

Implementation and installation sources are in Thor's Dredd repository under `services/g1-dredd/tools/camera-hud/`. The PC2 publisher/configuration and the independent Thor state-logger service are deployed. These changes are not committed yet.
