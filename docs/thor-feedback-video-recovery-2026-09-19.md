# Feedback, capture keys, and video recovery — 2026-09-19

The 11:30:02 PDT stop is a different failure from the earlier wrist endpoint guard. Thor's `direct-arm-1789842499-131030.jsonl` records `stop_detail: robot motor reports an error` at Unix time 1789842602.4879217. The native guard checks all 29 G1 motors. That old trace did not record motor error words, so the exact motor/code cannot be reconstructed from it. The Wuji finger warnings are a separate device diagnostic.

A read-only, 20-second DDS capture subsequently collected 17,838 frames with no nonzero motor error words (`/tmp/wuji-motor-fault-observe.bin` on Thor). This does not establish that the original fault was harmless or identify its cause.

Changes on Thor:

- Native motor faults now name every affected joint, hardware index, and raw hexadecimal error word. They use `motor_error` instead of `runtime_error`. Traces record current error words plus the latched original fault words, even if the hardware clears them during shutdown. The motor-fault stop is unchanged.
- Wuji subscriptions are continuously drained by one dedicated receiver, including preview and workspace countdown. Only the newest feedback is passed to the command loop, with its actual receive timestamp. Every diagnostics frame is checked before coalescing, so an intervening fault cannot disappear behind a later healthy frame.
- Request 200 Hz state and 50 Hz diagnostics telemetry. Unsupported rate control produces a visible fallback message; draining and freshness checks remain active at the native rate.
- SDK error logging remains enabled. Repeated per-frame SDK warnings are replaced by application summaries on warning changes, limited to at most one summary per hand every two seconds. Full current warning metadata remains in session telemetry. Unknown/non-warning diagnostic codes still latch a stop and disable owned hands.
- Capture accepts uppercase C as well as lowercase c. Terminal escape sequences, including split arrow sequences, cannot trigger capture. Both q/Q quit. Earlier 11:31–11:33 runs recorded no capture requests; the following run did capture and reported both arms live. This does not prove why those earlier keystrokes failed.
- HUD reconnect grace is measured from the last connected frame, rather than the age of the entire connection. A rebuilt peer triggers prompt advertisement of its new offer.

Headset app changes:

- Close the retired local WebRTC peer before creating its replacement; reject retired-peer callbacks, including callbacks queued to the main actor.
- Keep a concrete peer throughout asynchronous SDP negotiation and reject canceled/obsolete exchanges.
- Duplicate adverts for a healthy, unchanged endpoint no longer force a reconnect.
- Allow transient ICE disconnects to recover; delayed retries verify the connection generation and status before acting. Preserve the video-enabled flag during a transient disconnect.

Camera input and rendering remained approximately 29–30 fps with all three feeds live in the original service logs. Those logs showed repeated SDP exchanges and peer rebuilds, so the reconnect path needed correction. Long-run headset stability still requires observation after installing the new app.

Validation: 225 Python tests passed; 199 Dredd binary tests passed; native hardware release build and camera HUD release build succeeded. A two-second native read-only preview exited normally with zero dropped trace samples and no motor writer. New tests cover bounded feedback storage during six seconds of preview, original receive-time staleness, an error between healthy diagnostic frames, warning summaries/clear notifications, and uppercase/split-escape keyboard input. Simulator app compile passed. Device build/deployment status is recorded in the task reply.

Existing running motor sessions were not restarted or actuated by this investigation. Changes to those sessions take effect on their next user-controlled restart. No speed, current, following-error, or joint-limit thresholds were loosened in this patch.

## Fault reproduced and deployment completed

A second read-only DDS capture caught the fault during a user-controlled run: left shoulder roll, hardware index 16, error word 512 (`0x00000200`). First flagged sample: reported motor/driver temperatures 131/56 C, position -0.19382 rad, velocity 0.01534 rad/s, estimated torque -21.125 Nm. The error appeared in 4,327 of 35,982 samples over 40 seconds. The raw capture is preserved on Thor at `/home/g1gen5/Projects/shoot/dredd-recordings/motor-fault-20260919T1840.bin`; its hash and summary are in `runtime/wuji-feedback-video-2026-09-19/motor-fault-summary.json`.

The matching direct-arm trace names the same motor/code. In the last ten seconds, temperature rose from 74 to 131 C while the target advanced from approximately -0.45 to -0.73 rad, but measured position remained near -0.18 to -0.19 rad. This is strong evidence of excessive sustained load/overheating. It does not establish whether the source is torso contact, suspension interference, or another mechanical/control problem. User has not yet inspected for obstruction.

Added latched software arm-temperature cutoffs at 100 C for the reported motor channel and 80 C for the driver channel, checked before acquiring a writer and during control. These are conservative software cutoffs, not a claim about the exact motor's rated operating limits. Existing firmware fault handling remains. Final Rust suite: 200 passed; hardware release build succeeded; new read-only preview succeeded.

After both arm-control sessions exited, held the existing body/hand ownership locks temporarily during deployment to prevent a concurrent motor restart. Installed and launched headset build 32; confirmed running executable belongs to the newly installed app container. Installed/restarted Thor HUD service. All three camera inputs live and WebRTC connected at about 29–30 fps after restart. Extended live stability still needs observation.

Read-only Wuji hardware smoke test: both hands accepted 200 Hz state / 50 Hz diagnostics rates. After five seconds both had fresh feedback, no warnings, `enabled=false`, and zero motor commands. Ownership locks released after installation and smoke tests. No motor session was started by the agent. Physical shoulder inspection and cooling remain prerequisites for resuming motor tests.

Final video verification limit: the updated HUD connected and streamed initially, then the peer disconnected. Relaunched build 32 with console capture while motor sessions were absent; app/server startup succeeded, but no streaming-view start or SDP exchange appeared afterward. User needs to reopen the streaming view with motor output off before continuous video stability can be verified. Do not treat the initial connected interval as proof that all video drops are resolved. The temporary Mac console attachment was ended without terminating the headset app.
