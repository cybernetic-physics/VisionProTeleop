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

The head is queried at the controller polling timestamp. The default alignment
is identity, following the vendor example, but it is not a measured calibration.
Use ``streamer.set_controller_origin(transform)`` for an explicitly measured
LOCAL-to-ARKit rigid transform. This correction affects Python output; the app’s
diagnostic still uses the native identity alignment. This is not a fixed initial
root or a yaw-only body frame.

Validation and further details
------------------------------

Device and ARM64 simulator builds and 35 automated controller tests passed.
Physical Bluetooth behavior, accuracy, origin alignment, and SDK/ARKit coexistence
still require testing on hardware. Verify measured offsets, independent controls,
head motion, reconnects, stale data, and recentering before relying on alignment.

The `complete controller guide <https://github.com/cybernetic-physics/VisionProTeleop/blob/main/docs/surreal_touch.md>`_
covers pairing, every field, calibration, troubleshooting, recording compatibility,
and the pinned vendor SDK. The `device installation guide <https://github.com/cybernetic-physics/VisionProTeleop/blob/main/docs/how_to_install.md>`_
covers signing and Xcode setup.
