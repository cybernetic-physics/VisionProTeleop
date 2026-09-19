# Tolerant teleop recovery — 2026-09-19

The recent stops included two software issues that should not terminate a teleop session: a measured wrist endpoint crossed the old feedback tolerance by only 0.000056 rad, and two startup IK steps had palms already behind the shoulder plane. A separately observed left-shoulder motor fault at 131 C remains a real stop condition.

## Changes installed on Thor

- Python and native measured-joint tolerance is now 0.020 rad (approximately 1.15 degrees). Measured positions are projected into the unchanged URDF/model limits for the IK seed and initial reference; raw readings remain available for diagnostics and following-error checks. Command position and speed limits are not widened. Larger measured violations still stop.
- A palm-forward displacement constraint is part of the QP. If a captured palm is already behind the shoulder plane, the solver may move it forward from that position instead of aborting the first live step.
- An independent FK check catches nonlinear residual crossings. It retains the affected arm's previous reference instead of terminating both arms and hands. The unaffected arm continues. Infeasible bounded IK steps similarly retain references and retry. Native motor trajectory limiting remains in effect.
- IK/workspace holds do not restart the optical recovery blend. Optical recovery still uses the existing bounded transition.
- If the Vision Pro changes its AR session, the coordinator holds its existing arm references and hand commands and waits for explicit `c` recapture. It does not reuse an invalid mapping, silently recalibrate, or disable the arm owner solely because the source session changed.
- Calibration no longer requires hands to be at least 15 cm forward of the head. It still requires fresh optical input and a usable head frame. Live palm targets use the existing workspace projection.
- Direct-body MotionSwitcher RPC timeout changed from 20,000 microseconds (20 ms) to 5,000,000 microseconds (5 s), matching the existing native shim's documented reference setup. The installed Unitree header `robot/internal/internal_error.hpp` defines 3104 as an API timeout. Only that timeout is retried, twice, with a one-second interruptible wait. Lease/permission and other errors fail immediately. Empty ownership must be confirmed successfully before opening the motor writer; fresh robot feedback is rechecked afterward.

## Validation

- Full Python suite: 230 tests passed; subsequently added both exact shoulder-plane failure recordings as regressions. All seven recovery tests (including those two additions) pass.
- Native suite: 201 tests passed, including transient/exhausted startup timeouts, non-retryable ownership errors, interrupted startup, exact measured wrist excursions, gross range violations, motor faults, and temperature protection.
- Offline replay includes the final failing samples from each flight history, not just the samples written before the exception. Both shoulder-plane runs pass 17/17 samples and the wrist run passes 1,281/1,281, with no replay faults. See `runtime/wuji-tolerant-recovery-2026-09-19/replay.json`.
- Commands remain within original joint limits in these regressions. Native read-only preview passed after the tolerance update. No motor commands or controller release were initiated for tests.

The firmware/motor fault stop, software temperature stop, following-error protection, nonfinite/invalid commands, and ownership checks remain. These changes do not establish that the previously overloaded shoulder is mechanically unobstructed. Source/build updates do not hot-patch a running process; the final startup RPC change takes effect on the next direct-body launch.
