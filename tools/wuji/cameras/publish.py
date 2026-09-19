#!/usr/bin/env python3
"""One serial-bound, color-only RealSense publisher. No robot control interfaces.

Each camera has its own process and PUB endpoint. Messages contain one fresh JPEG
only, using Dredd's images/name/base64 envelope. Consumers MUST expire a frame
using their own receive clock; producer monotonic clocks are not comparable.
"""
import argparse
import base64
import json
import logging
import os
from pathlib import Path
import signal
import threading
import time
import uuid


def load_camera(path, role):
    cameras = json.loads(Path(path).read_text())
    if len({c["serial"] for c in cameras.values()}) != len(cameras):
        raise ValueError("Camera serials must be unique")
    if len({c["port"] for c in cameras.values()}) != len(cameras):
        raise ValueError("Camera ports must be unique")
    camera = cameras[role]
    for key in ("width", "height", "fps", "port"):
        if not isinstance(camera[key], int) or camera[key] <= 0:
            raise ValueError("Invalid camera " + key)
    return camera


def envelope(role, serial, session, sequence, frame_number, jpeg, processing_ms):
    return {
        "images": {role: base64.b64encode(jpeg).decode("ascii")},
        "camera": role, "serial": serial, "session": session,
        "sequence": sequence, "frame_number": frame_number,
        # Diagnostic processing time, NOT end-to-end latency or capture age.
        "processing_ms": processing_ms,
    }


def write_status(path, status):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(status, indent=2) + "\n")
    os.replace(str(temporary), str(path))


def run(args):
    # Import before starting any camera. Installation preflight checks these too.
    import cv2
    import msgpack
    import numpy as np
    import pyrealsense2 as rs
    import zmq

    camera = load_camera(args.config, args.camera)
    stopped = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopped.set())
    cv2.setNumThreads(1)
    context = zmq.Context()
    publisher = context.socket(zmq.PUB)
    publisher.setsockopt(zmq.SNDHWM, 1)
    publisher.setsockopt(zmq.LINGER, 0)
    publisher.bind("tcp://{}:{}".format(args.bind, camera["port"]))
    status_path = Path(args.status_dir) / (args.camera + ".json")
    status = dict(camera=camera, role=args.camera, state="starting", frames=0)
    sequence = 0
    write_status(status_path, status)
    try:
        while not stopped.is_set():
            pipeline = rs.pipeline()
            started = False
            try:
                config = rs.config()
                config.enable_device(camera["serial"])
                config.enable_stream(rs.stream.color, camera["width"],
                                     camera["height"], rs.format.bgr8, camera["fps"])
                # SDK drops older frames when this one-frame queue is full.
                queue = rs.frame_queue(1)
                pipeline.start(config, queue)
                started = True
                session = uuid.uuid4().hex
                previous_number = None
                report_at = time.monotonic()
                report_count = sequence
                logging.info("%s streaming serial %s", args.camera, camera["serial"])
                while not stopped.is_set():
                    frame = queue.wait_for_frame(2000).as_frameset().get_color_frame()
                    received = time.monotonic()
                    if not frame:
                        continue
                    number = frame.get_frame_number()
                    if number == previous_number:
                        continue
                    previous_number = number
                    pixels = np.asanyarray(frame.get_data())
                    ok, jpeg = cv2.imencode(".jpg", pixels, [cv2.IMWRITE_JPEG_QUALITY, 85])
                    elapsed = time.monotonic() - received
                    if not ok or elapsed > .25:
                        continue
                    sequence += 1
                    packet = envelope(args.camera, camera["serial"], session,
                                      sequence, number, jpeg.tobytes(), elapsed * 1000)
                    publisher.send(msgpack.packb(packet, use_bin_type=True))
                    now = time.monotonic()
                    if now - report_at >= 1:
                        status.update(state="streaming", error=None, frames=sequence,
                                      fps=(sequence-report_count)/(now-report_at),
                                      updated_monotonic_s=now,
                                      processing_ms=elapsed*1000, session=session)
                        write_status(status_path, status)
                        report_count, report_at = sequence, now
            except Exception as exc:
                logging.exception("%s camera failed; reconnecting", args.camera)
                status.update(state="reconnecting", error=str(exc),
                              updated_monotonic_s=time.monotonic())
                write_status(status_path, status)
            finally:
                if started:
                    try:
                        pipeline.stop()
                    except Exception:
                        logging.exception("Camera stop failed")
            stopped.wait(2)
    finally:
        status.update(state="stopped", updated_monotonic_s=time.monotonic())
        write_status(status_path, status)
        publisher.close()
        context.term()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--camera", choices=("head", "left", "right"), required=True)
    parser.add_argument("--config", default=str(Path(__file__).with_name("cameras.json")))
    parser.add_argument("--bind", default="192.168.123.164")
    parser.add_argument("--status-dir", default=str(Path.home()/".local/state/wuji-cameras"))
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    run(parser.parse_args())
