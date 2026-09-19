"""Inspect Surreal Touch controllers independently of hand tracking.

Run: python examples/17_surreal_touch.py --ip <Vision-Pro-IP-or-room-code>
"""
import argparse
import json
import time

from avp_stream import VisionProStreamer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip", required=True, help="Vision Pro IP address or room code")
    parser.add_argument("--origin-transform", help="JSON 4x4 transform from Surreal LOCAL to ARKit world (optional calibration)")
    args = parser.parse_args()
    streamer = VisionProStreamer(ip=args.ip)
    if args.origin_transform:
        with open(args.origin_transform) as file:
            streamer.set_controller_origin(json.load(file))
    try:
        while True:
            data = streamer.get_controllers()
            if not data["supported"]:
                print("Waiting for the controller-enabled Tracking Streamer app…", flush=True)
            elif data["stale"]:
                print("Controller stream stopped — poses and inputs unavailable", flush=True)
            elif not data["enabled"]:
                print("Enable Settings → Surreal Touch in the app", flush=True)
            else:
                for side in ("left", "right"):
                    controller = data[side]
                    transform = controller["pose_head"]
                    position = "unavailable" if transform is None else ", ".join(f"{x:+.3f}" for x in transform[:3, 3])
                    buttons = " ".join(f"{k}={v}" for k, v in controller["buttons"].items())
                    axes = " ".join(f"{k}={'—' if v is None else f'{v:+.3f}'}" for k, v in controller["axes"].items())
                    print(f"{side:5} active={controller['active']} head XYZ=({position}) | {buttons} | {axes}", flush=True)
            time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    finally:
        streamer.cleanup()


if __name__ == "__main__":
    main()
