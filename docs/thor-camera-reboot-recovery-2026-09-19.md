# Camera recovery after PC2 power loss

PC2 rebooted during the robot battery change. Its three enabled camera services
resumed at 30 fps, but Thor's existing camera subscriptions remained silent for
more than 12 minutes. A separate subscriber immediately received all three feeds.
WebRTC was connected throughout the stale-camera condition.

On Thor, `services/g1-dredd/crates/dredd-video/src/zmqcam.rs` now recreates a
camera's subscription after two seconds without messages. This acts independently
of the headset connection and leaves the other cameras running. Retry attempts
are bounded to one per two seconds. Existing stale-frame display handling remains.

Validation: all 20 dredd-video tests passed, including a real publisher/subscriber
test that receives frames, forces the silence deadline, and receives new frames
after recreating the subscription. The release HUD built and was installed at
`~/.local/bin/wuji-camera-hud`; its user service was restarted. After installation,
the headset answered and connected, all three feeds were live at roughly 28–30
fps, and frame ages were 22–28 ms. A physical PC2 power cycle was not repeated.

The separate 12:00:56 arm stop was confirmed in
`direct-arm-1789844103-145105.jsonl`: left shoulder pitch (hardware index 15)
reached motor/driver temperatures [100, 64] C. Its motor temperature was 70 C
60 seconds before the stop and 97 C one second before it. This was the configured
100 C motor temperature cutoff, not stale tracking. Motor fault codes were zero.
No thermal thresholds or motor-control settings were changed in this repair.
