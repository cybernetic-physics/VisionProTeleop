# Wuji teleop responsiveness and wrist-camera refinement — 2026-09-19

No real motor commands were issued by this investigation or its tests. Dredd/teleop were initially stopped; a user-started native Dredd body process appeared at final verification, without a sharewear.dredd_session bridge. We did not interrupt that user session. The implementation was validated on the existing working branches. The subsequent commit request records this refinement and its required input-runtime/protocol dependencies; unrelated signing settings and experiments remain outside the commits. No new tag was requested.

## Findings

The final ten seconds of bridge-20260919T161920Z-2a2236a1 contain about 192 distinct optical samples (19 Hz) while the bridge itself runs at 50 Hz. Input age: median 32.6 ms, p95 100.4 ms. Recovery blend is 1 throughout these samples, so the reported slowness is not solely recovery. IK solve median 6.1 ms, p95 7.7 ms; loop work median 8.5 ms, p95 10.7 ms. Native Dredd input age was small; approximate reference-to-measured arm lag from cross-correlation is 140 ms, not a calibrated end-to-end latency measurement.

The old bridge event records shared a mutable arm-state dictionary. Historical recovery-event labels are therefore unreliable. This is fixed by copying each state at event creation.

The app performed synchronous texture generation on every hand-overlay redraw, recreated unchanged plane geometry, and recorded network video in both its renderer and its RealityView. Predictive hand polling also ran on the main actor. These mechanisms allowed video/UI load to stall hand samples.

Final device build: **31**. Build 30 supplied the tracking measurements below; build 31 additionally separates camera connection lifetime from tracking subscriptions.

## Installed changes

- Video conversion uses a dedicated serial worker, one active frame plus one replaceable pending frame. UI publication completes before another conversion is scheduled; queues cannot accumulate old video.
- CombinedStreamingView uploads only a new image/configuration, uses asynchronous RealityKit texture creation, and caches plane geometry. Entity mutation stays on RealityKit's required main actor. SDR camera images use the color texture semantic.
- Network recording happens once at the renderer. Recording admission permits only one queued/in-flight video frame; encoding remains on the recording worker. UVC recording is deduplicated by image identity.
- ARKit hand polling/serialization runs in a detached high-priority task at a 120 Hz deadline, through Apple's Sendable HandTrackingProvider. A locked latest-sample store feeds gRPC; the display copies poses independently. Provider validity, timestamps and stale-input rejection remain intact. Existing main-actor head polling uses deadlines instead of sleeping for a full period after work.
- Thor's control and motor watchdog remain coordinated. A bounded diagnostic worker performs JSON encoding and disk writes. It saves full-run samples.jsonl, including optical points, finger targets/references/feedback, current and temperature when the SDK supplies them. Queue drops and write errors are reported. Final shutdown disables outputs before flushing diagnostics.
- Fingers hold the last issued reference during optical loss and resume from that reference. Previously, substituting measured position removed object-contact preload. Current remains capped at 0.5 A by default; speed, watchdog and hardware-fault handling are unchanged.
- First arm capture keeps its >=1 s blend. Subsequent recovery uses a 0.2 s minimum while retaining distance/rotation-based duration (15 cm/s and 0.75 rad/s approach) and all joint velocity/acceleration checks. The 300 ms distinct-sample tracking gate is unchanged.
- Tracking subscriber disconnection no longer clears the independent video advertisement or stops its renderer. A camera advertisement can establish local video without a tracking subscriber.

## Cameras

Both wrist views are now 464 x 261, versus approximately 272 x 153: about 2.9 times the area, without cropping the field of view. Head video and both Wuji Hand 2 Beta 2 models remain visible. The output is still 1280 x 720 at 30 FPS. Correct physical assignment remains left 260322274506, right 260322274429.

PC2 wrist sensors accepted and read back brightness 10 (was 0), gamma 400 (was 300), auto-exposure enabled. Reported exposure was approximately 31,979 microseconds and both streams stayed at 30 FPS. We did not increase exposure duration, which could worsen motion blur. The publisher selects the sensor carrying color; on D405 that is the stereo module, as described in [RealSense's exposure guidance](https://support.realsenseai.com/hc/en-us/community/posts/23848900451987-Setting-D405-Camera-Exposure-in-Python). Configuration and exposure metadata are retained in each camera's status file. These are brightness adjustments, not HDR or added scene lighting.

## Validation

Build 30 was installed and measured with the operator wearing the headset. Its worker logs maintained approximately 120 samples/s while video was recording. The 30 s tracking test delivered 3,031 distinct samples per hand (~101/s), estimated valid-sample age median 7.85 ms and p95 25.59 ms, with no samples rejected as stale. There were 144 left and 5 right untracked samples; real optical occlusion still exists. That interval includes a camera reconnect: rates are whole-window averages, not a controlled before/after motor-speed comparison. Video-on worker logs separately verify the 120 Hz sampler.

The earlier video-worker-only build still had main-actor hand sampling: 1,164 distinct samples/30 s (~39 Hz), p95 input age 80.45 ms and 26 stale observations per hand. The independent hand worker removes that remaining main-thread scheduling dependency.

Input ages use source timestamps and minimum observed clock offset; they are estimates and exclude an unknown fixed network delay. No claim of 120 Hz ARKit sensor acquisition or end-to-end motor response is implied. The bridge still commands at 50 Hz.

84 relevant Python tests passed across the diagnostic, grip-hold, recovery, continuity, keyboard, Wuji and writer-guard suites. Seven native HUD tests passed. Device builds succeeded. Grip tests cover preload preservation, bounded resumption and stale-feedback shutdown; recovery tests cover small/large pose gaps and trajectory limits. Diagnostic tests deliberately stall file writes and verify bounded, nonblocking submission and final flush.

Motor-free replay of 6,305 distinct samples from the earlier 09:15 recording found SDK modeled thumb/index tip gaps during operator pinches below 20 mm: median 1.6 mm left, 5.4 mm right, with large transient gaps (p95 ~40–45 mm). This confirms that the SDK can converge close in the model and that transient following deserves attention. It does not establish physical contact, grip force or closure in the last 09:19 run. That run did not record per-joint current or finger targets; the new recorder fills that gap.

Physical cable-grip strength and actual robot responsiveness require a controlled live test. Do not interpret the tracking benchmark as proof of a secure grasp or raise current limits based solely on it. Existing Thor startup commands load the bridge changes on the next run.

## Final build 31 device check

With video connected throughout a 15 s read-only tracking check, Thor received 1,520 distinct samples per hand (~101/s). Estimated valid-input age was median 8.27 ms, p95 21.70 ms, maximum 99.39 ms; there were no stale-hand observations. Actual untracked samples: left 150, right 5. The sampler logs stayed near 120 Hz. After closing the tracking subscriber, the camera service remained connected and the app continued recording fresh video frames, verifying the independent-video-lifetime fix. All three camera feeds stayed live (roughly 27–30 FPS in this interval). No further headset restart is needed for this build.
