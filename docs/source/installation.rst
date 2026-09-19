Installation
============

Python Package
--------------

Install the SDK from this fork to obtain the dedicated controller channels:

.. code-block:: bash

   git clone https://github.com/cybernetic-physics/VisionProTeleop.git
   cd VisionProTeleop
   python3 -m venv .venv
   source .venv/bin/activate
   python -m pip install -e .

The version is 2.51.0 in this source tree. This does not imply that this fork has
been published to PyPI.

Vision Pro App
--------------

Open ``Tracking Streamer.xcodeproj``, configure your team and signing capabilities,
select the **VisionProTeleop** scheme and a physical Vision Pro, then press Run.
Wireless Xcode pairing is supported; a Developer Strap is optional.

Follow the `full device installation guide <https://github.com/cybernetic-physics/VisionProTeleop/blob/main/docs/how_to_install.md>`_
for Developer Mode, provisioning, controller pairing, and the Python diagnostic.
The upstream App Store app is a separate distribution and does not install this
fork’s Surreal Touch integration. See :doc:`surreal_touch` for the data API.

Network Setup
--------------

WiFi Connection
^^^^^^^^^^^^^^^

For wireless operation, both your Vision Pro and the device running the Python package must be connected to the same WiFi network. No additional network configuration is required.

Wired Connection 
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

For optimal performance with the lowest latency, you can connect your Vision Pro via a wired USB-C connection. This requires:

- **Vision Pro Developer Strap** (available from Apple)
- USB-C cable connected from the developer strap to your computer

After physically connecting your Vision Pro via the developer strap, run the wired setup command:

.. code-block:: bash

   setup-avp-wired

This command (provided by the ``avp_stream`` package) configures the network bridge to enable communication over the USB-C connection. Wired connections typically provide significantly lower latency compared to WiFi - see the `benchmark documentation <https://github.com/Improbable-AI/VisionProTeleop/blob/main/docs/benchmark.md>`_ for detailed performance comparisons.

.. note::
   On the Vision Pro, the app displays the IP addresses registered on different network interfaces. You'll see separate IPs for WiFi and wired (USB-C) connections when both are available. Make sure to use the correct IP address corresponding to your connection type when connecting from Python.

