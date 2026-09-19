# Spatial debug bench

Temporary local, read-only live visualization. From the repository root:

```sh
npm install --prefix scratch/surreal-debug
.venv/bin/python scratch/surreal-debug/server.py --ip 192.168.50.236
```

Open http://127.0.0.1:8917. Keep Tracking Streamer START/immersion active.
Uses native ARKit Y-up coordinates without the legacy Python head-axis adjustment.
Native manual world/grip calibration (build 19+) is respected, including live preview. Older packets retain the unverified identity assumption. Hand
packets do not expose per-hand validity, so cached hand data is explicitly labeled.
Controller input validity, controller freshness, and transport freshness are separate.
Only incoming tracking is read; this dashboard sends no robot commands.

Drag to orbit, scroll to zoom, right-drag to pan. Switch world/head frames, focus,
pause for inspection, and save JSON snapshots locally. The event list observes
sampled button transitions, not a lossless hardware-event queue. Reference controller
and headset meshes are schematic and not surveyed geometry. Optional marker/image
and stylus poses are shown when present; their metadata is included in JSON snapshots.
