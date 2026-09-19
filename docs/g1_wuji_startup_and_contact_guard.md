# G1 + Wuji Hand 2: staged startup and contact-aware teleoperation

Date: 2026-09-19. Scope: G1-Dredd/Mink, Humanoid-Teleop, GR00T/SONIC and HumDex on Thor.

**Status:** the command paths have been audited. Shared startup-state and local velocity-projection primitives are implemented in `~/Projects/shoot/sharewear/src/sharewear/teleop_safety.py`, with 10 passing tests. They do not move hardware and are **not yet connected to the production writers**. No physical one-inch clearance claim is made. A verified combined robot/mount model and final-writer integration remain required. Existing startup motions and collision behavior have not been silently changed.

## Recommended behavior

One common geometry profile, collision policy and startup state machine should govern every implementation. Each stack needs an adapter at its actual motor-command boundary; sharing only the optical-input adapter is insufficient.

The startup sequence is:

```text
IDLE → PRECHECK → CLEAR BODY → PRESENT TO CAMERA → MATCH USER → TELEOP
                                                           ↓
                                                   TRACKING HOLD
                                                           ↓
                                          MATCH HELD POSE → TELEOP
```

1. **Prepare is explicit.** Opening an app or receiving a headset packet must not move the robot. The operator starts preparation through the existing session control. Verify fresh body and finger feedback, sole command ownership, a stable balance controller, the correct geometry profile, and joint limits. Disable operator walking during preparation; the balance controller still runs.
2. **Start from measured positions.** Do not interpolate straight from an arbitrary pose to a canned front-of-camera pose. Hold finger positions initially. Plan an outward corridor for wrists *and elbows*, away from the pelvis, thighs and torso. If fingers need to open, do it after sufficient clearance exists, through the same guard.
3. **Present slowly.** Follow a bounded-velocity, bounded-acceleration path forward and upward into the calibrated camera's view. Avoid swinging forearms across the chest. Check the whole swept path, including hand shells and fingertips. The final pose is a verified robot-profile parameter, not a universal hard-coded shoulder angle.
4. **Use measured completion.** Advance only when the real arms reach the waypoint and settle. Sending a target or waiting a fixed number of seconds does not prove completion. If the path is blocked, hold and report the blocking link pair. Do not force the robot through the obstruction to finish startup.
5. **Wait for the operator.** Keep the robot in the presentation pose while showing ghost-hand position/orientation targets in the headset or camera preview. Compare the user's wrists in the calibrated head-relative frame against the inverse-mapped robot presentation targets. Start with configurable matching tolerances around 4–5 cm and 10–15 degrees, plus low hand speed; these are commissioning values, not established hardware tolerances. Require a one-second dwell with distinct fresh samples from every selected hand. A missing unselected hand does not block left-only operation.
6. **Lock without a jump.** Capture the operator-to-robot mapping at the measured presentation pose, then blend operator authority from zero. Finger teleop starts only after this gate. Keep joint speed and acceleration limits on both arms and fingers throughout the transition.
7. **Tracking loss holds.** Freeze the affected measured arm/finger pose. Return tracking must match the held pose before regaining authority; the robot does not repeat the outward/startup sweep or chase motion made while invisible. Initial startup matching requires camera visibility. A later tracking hold need not require the robot to return to its initial camera pose. Per-side runtime recovery should remain independent when the other hand is valid.

The coordinator prototype currently gates the selected cohort together. Per-side runtime recovery and the headset ghost-target UI still need production integration.

## Contact policy

Distances refer to **surface-to-surface separation**, including finger geometry, not wrist-center distance.

| Pair | Nominal boundary | Response |
|---|---:|---|
| Either hand versus head/camera, torso, pelvis, thighs or other body parts | 25.4 mm | Remove closing motion; preserve safe sliding/retreat |
| Either hand versus either arm, except an explicitly reviewed mounting interface | 25.4 mm | Same |
| Nonadjacent arm versus body or other arm | 25.4 mm | Same |
| Left hand versus right hand | 0 mm contact boundary | Allow touching; constrain penetration and limit approach speed/effort |
| Internal hand surfaces | Contact-aware 0 mm boundary | Preserve valid finger articulation; exclude reviewed designed interfaces |
| Connected mechanical interfaces | Explicit pair-specific exemption | Do not demand an impossible air gap across a wrist, elbow or mounting plate |

Do **not** exempt an entire hand from collision checking. Do **not** exempt every link within two kinematic joints without reviewing its geometry. A finger can strike its own forearm even though the assembly is close in the kinematic tree. Each allowed-contact pair should have a reason in the profile.

Hand-to-hand contact is not unrestricted hand-to-hand penetration. Keep those pairs in the distance model with a different margin. Relative approach speed and joint effort need limits near contact; permitting contact geometrically does not establish safe contact force, especially without calibrated force sensing.

## Directional guard

Use a small constrained optimization that stays close to the desired motion while satisfying pair-distance constraints and joint speed/acceleration limits. Near a boundary, remove only the velocity component that closes the gap. If the user keeps pushing inward, the robot should stop in that direction and display the blocked pair; tangential and outward movement should remain possible.

A useful local constraint is:

```text
J_distance · joint_velocity + motion_of_other_body
    >= -max(distance - required_margin, 0) / time_horizon
```

Both sides of a pair matter: pelvis/waist motion can approach a stationary hand. The body policy must supply measured/predicted motion to the guard. Leg balance commands must not be independently clamped to zero by an arm guard; if no arm-only avoidance is feasible, request a coordinated locomotion stop/stable hold through the existing body controller.

If startup begins inside the required margin, zero commanded motion does not magically restore clearance. Allow only non-worsening/escape motion, display the deficit, and refuse to declare the robot ready until the staged route reaches the required clearances. Infeasible avoidance is different from an ordinary boundary: do not label a zero arm command safe while the body is still moving toward it.

**25.4 mm is the requested physical floor, not a sufficient raw software threshold.** The planning/slowdown margin also needs model/mount error, joint-feedback error, processing/transport latency, and braking distance. A useful allowance is `closing_speed × latency + closing_speed² / (2 × validated_deceleration)`, added to the geometry uncertainty and requested clearance. Commission those quantities; do not invent a universal 1-inch guarantee from approximate meshes.

After the local optimization, perform a nonlinear swept-segment check on the actual candidate command. An endpoint-only distance check can miss a forearm or finger sweeping through the body. The final writer must validate that the candidate's feedback generation, finger geometry and approval have not expired. Carrying a boolean `safe` from an earlier control tick is insufficient.

## Geometry requirements

The audited workspace contains separate G1 body and articulated Wuji hand descriptions, but no verified assembled model for this black-pelvis robot and its actual mounting plates. The current Dredd Mink model still contains factory rubber-hand geometry; Dredd's native baked collision model uses its existing hand model. Pelvis color alone does not identify a verified mechanical model.

The shared profile needs:

- Exact G1 body revision and collision meshes, including the pelvis shell, camera/head housing and relevant protrusions.
- Left/right wrist-to-Wuji transforms, mounting-plate geometry, shell geometry and the full 20-joint finger chains.
- Confirmation that the available Wuji description matches the installed Hand 2 revision and its SDK joint order/zero offsets. The HumDex dependency was previously substituted because its pinned upstream object was unavailable; it is not yet hardware-verified.
- Camera intrinsics, camera-to-robot transform and a presentation pose whose **entire hand envelope**, not merely the wrist center, is in view with edge margin and no body occlusion.
- A reviewed contact-pair table and explicit connected-interface exclusions.
- Mesh-decomposition error bounds, joint limits, validated motion limits and a model/config hash carried in runtime telemetry.

Use fine convex decomposition near shoulders, pelvis corners, wrist mounts and fingers. A single convex hull around a concave torso/arm arrangement can incorrectly close usable space. MuJoCo's documented collision representation is generally convex, so importing a detailed visual mesh alone does not preserve all its concavities: [MuJoCo collision documentation](https://mujoco.readthedocs.io/en/latest/computation/).

Include both installed hands as obstacles even in left-only operation. If an inactive hand's joint feedback is unavailable, use a conservatively bounded finger envelope or block preparation; do not substitute an open-hand pose and call it measured.

## Per-implementation changes

| Stack | Startup and desired-motion layer | Final authority / essential change |
|---|---|---|
| **G1-Dredd + Mink** | Add the shared stages to `sharewear/dredd_session.py`; replace unrestricted manual neutral capture with presentation matching. Add explicit pair limits inside `MinkArms`' QP and retain a nonlinear candidate check. | Dredd's policy can change a Mink **reference** target. Extend `dredd-guard` and the native writer admission path to validate the actual commanded body/arm targets against fresh Wuji geometry. Cover INIT and its default-pose ramp, not just CONTROL. |
| **Humanoid-Teleop** | Put staged arm paths and matching before live targets in `robot_control/wuji_arms.py`. Use constrained IK or a measured-state joint-space projection after its existing IK. | Guard the final clipped candidate in `robot_arm.py::_ctrl_motor_state` before publication. Reorder `wuji_session.py` so fingers cannot enable before startup/matching finishes. Coordinate arm and finger target approval. |
| **GR00T / SONIC C++** | Shape planner references through the staged corridor; observe real joint completion and pose matching before publishing operator targets. | Add the native guard after policy inference and at `G1Deploy::LowCommandWriter` admission. Its existing 500 Hz writer forwards `MotorCommand` targets directly. Protect the initialization path too. A guarded Python wrist publisher cannot guarantee policy-generated joint motion. |
| **HumDex** | Gate its body pipeline and independent hand publication with the same measured startup/match state. Existing Redis `is_active` alone is not a coordinated body/finger gate. | For its Python real G1 server, guard immediately before `G1RealWorldEnv.send_cmd` / `write_low_command`, accounting for joint remapping and actual motor count. For HumDex's SONIC backend, use the SONIC native guard above. Replace the arm portion of its straight 2-second `move_to_default_pos` interpolation with the staged route. |

Mink has a native `CollisionAvoidanceLimit` with explicit geom-pair groups and minimum distances, making it the first useful integration target: [Mink limits API](https://kevinzakka.github.io/mink/api/limits.html). This does not remove the need for downstream protection on policy-controlled paths.

**Dredd audit findings:** `GuardConfig` currently defaults to a 12 mm hard margin and `restrain_targets=false`. The constructor can reduce per-pair margins using rest-pose and corpus calibration and can drop close pairs. Its fixed geometry/7-slot hand input is not an articulated Wuji model. Merely setting `--guard-hard-margin 0.0254` does not implement this requirement. A strict profile must retain reviewed forbidden pairs and must not lower their requested clearance based on historical close approaches.

**Shared Wuji backend:** split retargeting and motor publication into proposal and commit phases. The coordinator needs candidate finger angles before approving the combined arm/hand swept motion. Guard finger-only motion too: an extended fingertip can hit the body while the wrist remains stationary. A shared in-process generation or acknowledged native transaction must couple the approvals; unrelated arm and Redis/SDK publishers must not independently advance stale geometry.

## Validation before physical enabling

1. Compare the combined model against the actual mounts and camera view; verify every joint axis and finger-node mapping.
2. Test the outward/front path from multiple measured start poses, including already-close hands, asymmetric arms and one-hand mode.
3. Test each forbidden pair, tangential sliding, retreat, hand-to-hand contact, fingers moving near a stationary body, and torso motion toward a stationary hand.
4. Test the full swept path and ensure model error allowances cannot be silently disabled by normal pose calibration.
5. Test stale/delayed feedback, solver stalls, missing finger states, reordered messages and writer-generation mismatches.
6. Run each real policy in simulation with its exact final-writer guard. Record minimum surface clearance and commanded/measured motion, not only visual screenshots of requested wrist targets.
7. Perform slow physical commissioning with verified mount geometry and existing operator stop available. No autonomous physical startup was attempted during this audit.

The ten current prototype tests cover the contact table, tangential/escape projection, multiple boundaries, uncertainty/speed bounds, invalid geometry rejection, measured stage transitions, selected-hand matching dwell, duplicate rejection, mismatch reset, and approaching-body infeasibility. They are mathematical/state-machine checks, not hardware-clearance validation.
