# Fine-control review of the 09:45–09:53 Wuji run

Reviewed bridge-20260919T164545Z-023da8ac and native recording real-20260919T164429Z-884cd2. The bridge has a complete 402 MB diagnostic stream with no dropped records or writer errors. No live motor session was started or controller gains changed during this review.

## What the run shows

The background-tracking change helped source freshness, but it did not remove the arm-control bottleneck. Across 22,524 samples with palm diagnostics (459 seconds):

| Measurement | Left | Right |
|---|---:|---:|
| Input age, median / p95 | 11.8 / 78.0 ms | 11.8 / 78.0 ms |
| Distinct samples consumed by the 50 Hz bridge | 41.7/s | 41.7/s |
| Recovery blending fraction | 1.58% | 1.41% |
| Live mapped target → measured modeled palm, median | 41.5 mm | 40.9 mm |
| Live mapped target → IK commanded palm, median | 22.6 mm | 6.2 mm |
| Live commanded → measured modeled palm, median | 26.0 mm | 34.5 mm |
| Estimated mapped → commanded motion lag | 40 ms | 40 ms |
| Estimated commanded → measured motion lag | 200 ms | 160 ms |
| Commanded elbow < 0.05 rad | 45.2% | 38.3% |
| Per-sample largest commanded joint speed, p95 | 0.414 rad/s | 0.456 rad/s |

The position errors above are separate vector norms and cannot be added as scalar contributions. They are model-based palm positions, not externally measured endpoint accuracy. The mount model is kinematic and not hardware-surveyed. Lag estimates maximize cross-correlation of 100 ms position differences over continuously live windows, in 20 ms bins; correlations were 0.676 left and 0.651 right for commanded→measured. They are approximate, not calibrated end-to-end latency.

For live 100 ms windows with 2–15 mm mapped movement, median mapped/commanded/measured movement was 3.45/2.69/1.39 mm left and 3.25/2.53/1.27 mm right. This illustrates delayed/attenuated short motions; it is not a claim that the robot permanently achieves only 40% of commanded travel.

The native Dredd arm owner was Active throughout the analyzed native interval. Input age there was median 7.17 ms, p95 16.62 ms. Actual servo gains were about kp 14.25 / kd 0.907 at the shoulders/elbows/wrist roll and kp 16.78 / kd 1.068 at wrist pitch/yaw. The launcher uses `--arm-owner reference`: SONIC consumes the requested upper-body pose and produces the arm motor commands. The reference is not sent directly to arm motors.

Eight brief tracking-loss events occurred after the initial capture, concentrated near the end. Stable motion was also sluggish; recovery cannot explain the general feel. The final stop was a right palm target behind/too close to the permitted shoulder plane, not a control-loop timing fault. Median solve time was 6.99 ms and p95 9.57 ms; bridge loop work was 11.44 / 14.64 ms. Raising the 3 rad/s ceiling would not address the observed low-speed behavior.

## Offline tuning experiment

A 349-step continuously live recorded window was replayed without transport or motor access, preserving the recorded encoder feedback and comparing identical initialization across variants. The startup blend was skipped to isolate live behavior. The elbow preference was seeded from the window's initial measured posture, so this is a controlled comparison between variants, not a bit-exact reproduction of the original session.

Reducing measured-posture weight from 1.0 to 0.7 only changed median target→command error from 38.61/25.11 mm to 36.26/24.52 mm, while peak joint lead grew from 0.440 to 0.525 rad. Raising Cartesian gain from 12/s to 18/s made little further difference. Weights 0.4 and 0.2 hit the unchanged 0.6-rad following-error stop after about 30 steps. Those candidates were discarded; no tuning changes were deployed. Recorded-feedback replay cannot predict how the robot would respond to a different controller, but it rejects the idea of simply relaxing the measured-posture anchor against the existing recorded behavior.

## Implications for the next change

1. Preserve the tracking/threading fixes and existing following-error protection. Neither another speed-limit increase nor additional smoothing addresses the main result.
2. Establish a task workspace where the robot has elbow bend at the plug. A straight elbow removes useful motion directions and makes fine manipulation difficult. Recenter/position the robot relative to the panel, then choose mapping gain around that workable pose. Merely increasing absolute workspace scale can worsen saturation.
3. Evaluate the existing hybrid arm path separately: direct arm references, 500 Hz command interpolation, bounded velocity feed-forward and measured gain tuning while SONIC continues the body. This changes physical arm control and needs supported-arm commissioning before manipulating a cable. Its stock gravity compensation is not a validated Wuji payload model, so do not claim it solves the hardware problem from replay alone.
4. Only after the controller follows small motions accurately, evaluate a lower local motion gain or clutch for precise plug alignment. A smaller gain on top of the current tracking lag would feel even mushier.

The review establishes remaining bottlenecks; it does not establish a live-validated replacement controller or claim the issue is fixed.
