Surreal Touch controllers
=========================

The app streams dedicated left/right grip poses and all inputs exposed by the
integrated Surreal native API, independently of the hand skeletons. Unity and
SteamVR are not required.

Setup
-----

Build this fork’s VisionProTeleop scheme, pair both controllers in the headset’s
Settings → Bluetooth, allow Bluetooth and tracking permissions, and press START.
The app’s Settings → Surreal Touch panel displays per-side controls and positions.
The vendor may request hand tracking for calibration; our controller data does not
use hand pinches as button presses.

.. code-block:: bash

   python examples/17_surreal_touch.py --ip 192.168.1.100

Run from the repository root after :doc:`installation`. Replace the IP with your
headset’s address or room code. This diagnostic prints data and does not drive a robot.

Inputs and poses
----------------

* Left: X, Y, menu, and thumbstick-click buttons.
* Right: A, B, menu, and thumbstick-click buttons.
* Both: independent trigger/grip analog values (0–1), derived press booleans,
  thumbstick X/Y axes (−1 to 1), and position/orientation.
* OS-reserved buttons and capacitive signals absent from the vendor API are not synthesized.

.. code-block:: python

   controllers = streamer.get_controllers()
   left = controllers["left"]
   right = controllers["right"]
   if not controllers["stale"] and left["pose_head"] is not None:
       xyz_metres = left["pose_head"][:3, 3]
   a_pressed = right["buttons"]["a"]
   grip = left["axes"]["grip"]

Read repeatedly while streaming. Unavailable values are ``None``. Live data expires
after 250 ms by default; pose and input validity are independent. Snapshots are
sampled states, not a lossless queue of button edges.

Head-relative coordinates
-------------------------

``pose_head`` is a 4×4 transform relative to the current headset position and
orientation, with X right, Y up, −Z forward, in meters:

.. code-block:: text

   headFromController = inverse(arkitWorldFromHead)
                      * arkitWorldFromSurrealLocal
                      * surrealLocalFromController
                      * controllerFromCalibratedGrip

The head is queried at the controller polling timestamp. Native manual world and
per-side grip corrections are included. This is not a fixed initial root or a
yaw-only body frame. The optional Python origin transform is an additional
receiver-only correction after native calibration.

Validation and further details
------------------------------

The build-19 device build, Swift calibration math checks, and 44 Python/controller
and dashboard checks passed. Hardware packets and buttons have been observed;
manual calibration accuracy still requires checking against physical controllers. Verify measured offsets, independent controls,
head motion, reconnects, stale data, and recentering before relying on alignment.

The `complete controller guide <https://github.com/cybernetic-physics/VisionProTeleop/blob/main/docs/surreal_touch.md>`_
covers pairing, every field, calibration, troubleshooting, recording compatibility,
and the pinned vendor SDK. The `device installation guide <https://github.com/cybernetic-physics/VisionProTeleop/blob/main/docs/how_to_install.md>`_
covers signing and Xcode setup.

Manual calibration in the headset
---------------------------------

After START, the Place your controllers window opens by default. Capture editing
directions from your view, adjust Both (world alignment), then each grip offset.
Use the colored rings and physical controllers as references. Fine, medium, and
coarse translation/rotation steps, undo, reset, cancel, and Save & use are provided.
The raw SDK positions remain visible as white crosses during editing.

The saved rigid transforms are shared by overlays, recordings, and the updated
Python receiver: ``worldGrip = alignment @ rawPose @ gripOffset``. Hands are not
used to compute or update them. Review a saved profile after restarting or
recentering tracking. Calibration metadata exposes saved, preview, and reviewed
status; live preview edits also affect outgoing poses. Upgrade the app and SDK
together. Leave the optional Python ``set_controller_origin`` correction at
identity unless an additional receiver-only world correction is intended.

See the repository's ``docs/surreal_touch.md`` for the full guided procedure.
