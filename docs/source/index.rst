VisionProTeleop Documentation
==============================

.. image:: ../../assets/new-logo.png
   :width: 340
   :align: center

|

This is Cybernetic Physics’ fork of VisionProTeleop, adding native **Surreal Touch**
controller poses and independent buttons, triggers, grips, and thumbsticks to the
Vision Pro app and Python SDK. Existing hand/head tracking, video streaming,
simulation, and recording remain available.

.. note::
   Use this fork’s app and SDK source builds for controller support. Upstream
   App Store and PyPI distributions are separate. Device/simulator builds and
   automated controller tests passed; real-controller tracking and headset-origin
   alignment still require hardware validation.

Installation
------------

.. code-block:: bash

   git clone https://github.com/cybernetic-physics/VisionProTeleop.git
   cd VisionProTeleop
   python3 -m venv .venv
   source .venv/bin/activate
   python -m pip install -e .

Build the **VisionProTeleop** scheme from ``Tracking Streamer.xcodeproj`` and run
it on your paired Vision Pro. See :doc:`installation` and :doc:`surreal_touch`.

Quick Start
-----------

.. code-block:: python

   from avp_stream import VisionProStreamer
   
   avp_ip = "10.31.181.201"  # example IP
   s = VisionProStreamer(ip=avp_ip)
   
   # Optional: Start video streaming
   s.start_streaming(device="/dev/video0", format="v4l2",
                          size="640x480", fps=30, stereo=False)
   
   while True:
       r = s.latest
       print(r['head'], r['right_wrist'], r['right_fingers'])

Citation
--------

If you use this repository in your work, please cite:

.. code-block:: bibtex

   @software{park2024avp,
       title={Using Apple Vision Pro to Train and Control Robots},
       author={Park, Younghyo and Agrawal, Pulkit},
       year={2024},
       url = {https://github.com/Improbable-AI/VisionProTeleop},
   }

Contents
--------

.. toctree::
   :maxdepth: 2
   :caption: User Guide

   installation
   surreal_touch
   quickstart

.. toctree::
   :maxdepth: 2
   :caption: API Reference

   api/modules

.. toctree::
   :maxdepth: 1
   :caption: Additional Information

   acknowledgements
   license

Indices and tables
==================

* :ref:`genindex`
* :ref:`modindex`
* :ref:`search`
