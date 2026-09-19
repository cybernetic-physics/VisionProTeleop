# Nonfatal live workspace boundary — 2026-09-19

The reported 10:34:59 crash is reproduced from `bridge-20260919T173446Z-30483988/flight-history.json`. The final left palm target crossed the 8 cm forward-workspace margin by only 0.000132744 m (0.133 mm). It was still in front of the shoulder. The prior implementation raised a RuntimeError for any crossing, terminating the coordinated hand/arm session.

The deployed Sharewear source on Thor now projects an out-of-range live target's forward component onto that same 8 cm margin, leaving its lateral position, height and palm orientation intact. It keeps the original calibration and immediately follows the same mapping again as the target returns to range. Initial calibration validation, actual IK branch/shoulder checks, following-error stops, and joint speed/acceleration constraints remain in place.

Diagnostics retain the raw `mapped_palm` and add `feasible_palm`, `workspace_limited` and `workspace_correction_m`. Thus replay can distinguish requested motion from workspace saturation rather than hiding the input change.

The original replay failed at input 125; the corrected version processes all 125 available calibrated inputs with no fault. At the previously failing step, both arms remain live, maximum reference displacement is 0.004964 rad, maximum generated velocity is 0.24861 rad/s, and maximum velocity change is 0.03002 rad/s. This is command-generation replay against recorded encoders, not a simulation of robot dynamics or live motor validation.

The full replay's finite-difference speed/acceleration summary includes the pre-existing initial projection of tolerated negative elbow encoder feedback into the forward command branch. Those startup summary peaks should not be confused with the boundary step or taken as certification of every startup transition; that startup behavior was not changed in this patch.

Regression coverage includes both hands crossing the boundary without stopping the coordinated finger backend, projection with rotated workspace and measured waist tilt, gradual boundary crossing/return without recapture or renewed recovery blending, and preservation of existing real solver branch and following-error stops.

Thor files changed for this fix: `~/Projects/shoot/sharewear/src/sharewear/dredd_mink.py` and `tests/test_dredd_mink.py`. Existing unrelated edits in collision_guard.py and teleop_safety.py were preserved. No commit or tag was made.

The already-running hands process was not restarted. It retains the prior imported Python code; the fix takes effect on the next hands-process restart. No motor session was started by the agent.

Validation: **79 tests passed** across IK, continuity, recovery, diagnostic writing, grip hold and optical input. Repository whitespace validation passed. Replay evidence is in `docs/runtime/wuji-workspace-boundary-2026-09-19/`.
