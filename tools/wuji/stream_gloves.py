#!/usr/bin/env python3
"""Read Wuji gloves on Thor and send timestamped wrist-local skeletons to Vision Pro.
No robot-hand connection, motor command, retargeting, or calibration fitting.
Requires wuji-sdk on the source machine; the transport uses Python stdlib only.
"""
import argparse
from collections import deque
import json
import math
import signal
import socket
import threading
import time
import uuid

RIGS = {
    'left': ('WG1JA06260806019', '192.168.1.100'),
    'right': ('WG1KA06260806542', '192.168.1.101'),
}


class ClockSync:
    def __init__(self):
        self.samples = deque(maxlen=20)

    def observe(self, t0, t1, t2, t3):
        if not all(math.isfinite(t) for t in (t0, t1, t2, t3)) or t2 < t1 or t3 < t0:
            return False
        rtt = (t3 - t0) - (t2 - t1)
        if not 0 <= rtt <= .060:
            return False
        self.samples.append((t3, rtt, ((t1-t0) + (t2-t3))/2))
        return True

    def estimate(self, now):
        recent = [s for s in self.samples if 0 <= now-s[0] < 5]
        if len(recent) < 3:
            return None
        _, rtt, offset = min(recent, key=lambda s: s[1])
        return offset, rtt / 2


def skeleton_message(frame, side, serial, device_error, session):
    """Reject pre-sync timestamps and preserve sensor capture time, not arrival time."""
    utc, mono = time.time(), time.monotonic()
    timestamp = int(frame.header.timestamp_us)
    age = utc - timestamp / 1e6
    if not 0 <= age <= .25 or str(frame.header.frame_id) != side[0] + '_wrist':
        return None
    if len(frame.joints) != 21:
        return None
    points = [[float(x) for x in joint.pose.position] for joint in frame.joints]
    confidence = [float(joint.confidence) for joint in frame.joints]
    if (any(len(p) != 3 or not all(math.isfinite(x) and abs(x) <= 1 for x in p) for p in points)
            or not all(math.isfinite(c) and 0 <= c <= 1 for c in confidence)
            or any(abs(x) >= .005 for x in points[0])):
        return None
    return dict(kind='skeleton', version=1, session=session, side=side, serial=serial,
                frame=str(frame.header.frame_id), sequence=int(frame.header.seq),
                sourceTimestampUs=timestamp, captureMono=mono-age,
                deviceError=device_error, points=points, confidence=confidence)


def produce(stop, latest, lock, rigs, session):
    from wuji_sdk import SdkManager, DeviceType, set_log_level
    set_log_level('warn')
    manager = SdkManager.instance()
    streams = {}
    last_scan = -10.0
    try:
        while not stop.is_set():
            now = time.monotonic()
            if len(streams) < len(rigs) and now-last_scan > 5:
                last_scan = now
                try:
                    devices = {d.sn: d for d in manager.scan()}
                    for side, (serial, ip) in rigs.items():
                        if side in streams or serial not in devices:
                            continue
                        d = devices[serial]
                        if d.device_type != DeviceType.WujiGlove or str(d.address).split(':')[0] != ip:
                            print(f'{side}: identity/IP mismatch; not connecting', flush=True)
                            continue
                        glove = manager.connect(sn=serial, device_name=f'visionpro_{side}_glove')
                        if str(glove.hand_side().get()).lower() != side:
                            raise RuntimeError(f'{side}: glove handedness mismatch')
                        sync = glove.sync_time()
                        error = max(0, float(sync.round_trip_us)) / 2e6
                        streams[side] = (glove, glove.hand_skeleton().subscribe(), error, now)
                        print(f'{side}: subscribed to {serial}; clock round trip {sync.round_trip_us} µs', flush=True)
                except Exception as exc:
                    print(f'Discovery: {type(exc).__name__}: {exc}', flush=True)
            for side, (glove, sub, error, last_good) in list(streams.items()):
                try:
                    newest = None
                    for _ in range(256):
                        frame = sub.recv()
                        if frame is None:
                            break
                        newest = frame
                    if newest is not None:
                        message = skeleton_message(newest, side, rigs[side][0], error, session)
                        if message:
                            with lock:
                                latest[side] = message
                            streams[side] = (glove, sub, error, now)
                    if now-last_good > 10:
                        # Force a fresh subscription/time sync after loss of acquisition.
                        raise TimeoutError('no usable synchronized skeleton for 10 seconds')
                except Exception as exc:
                    print(f'{side}: {type(exc).__name__}: {exc}; will reconnect', flush=True)
                    try:
                        sub.close()
                    except Exception:
                        pass
                    try:
                        manager.disconnect(f'visionpro_{side}_glove')
                    except Exception:
                        pass
                    del streams[side]
                    with lock:
                        latest.pop(side, None)
            stop.wait(.004)
    finally:
        for _, sub, _, _ in streams.values():
            sub.close()
        manager.disconnect_all()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--headset', required=True, help='Vision Pro local IPv4 address')
    parser.add_argument('--port', type=int, default=12346)
    parser.add_argument('--side', choices=['left', 'right', 'both'], default='left')
    for side, (serial, ip) in RIGS.items():
        parser.add_argument('--'+side+'-serial', default=serial)
        parser.add_argument('--'+side+'-ip', default=ip)
    args = parser.parse_args()
    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    latest, lock = {}, threading.Lock()
    rigs = {side: (getattr(args, side+'_serial'), getattr(args, side+'_ip'))
            for side in RIGS if args.side in (side, 'both')}
    session = str(uuid.uuid4())
    worker = threading.Thread(target=produce, args=(stop, latest, lock, rigs, session), daemon=True)
    worker.start()
    clock = ClockSync()
    pending, sent = {}, {}
    next_ping = next_report = 0
    totals = {'left': 0, 'right': 0}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.connect((args.headset, args.port))
    sock.settimeout(.005)
    print(f'Glove-only stream → {args.headset}:{args.port}; no robot control', flush=True)
    try:
        while not stop.is_set():
            now = time.monotonic()
            if now >= next_ping:
                nonce = str(uuid.uuid4())
                pending = {n: t for n, t in pending.items() if now-t < 2}
                pending[nonce] = now
                try:
                    sock.send(json.dumps(dict(kind='ping', nonce=nonce, t0=now)).encode())
                except OSError:
                    pass
                next_ping = now + .5
            try:
                reply = json.loads(sock.recv(8192))
                received = time.monotonic()
                nonce = reply.get('nonce')
                if reply.get('kind') == 'pong' and nonce in pending:
                    t0 = pending.pop(nonce)
                    if reply.get('t0') == t0:
                        clock.observe(t0, float(reply['t1']), float(reply['t2']), received)
            except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError):
                pass
            now = time.monotonic()
            estimate = clock.estimate(now)
            if estimate:
                offset, error = estimate
                with lock:
                    frames = list(latest.items())
                for side, message in frames:
                    if sent.get(side) == message['sourceTimestampUs'] or not 0 <= now-message['captureMono'] < .25:
                        continue
                    outgoing = dict(message)
                    outgoing['headsetTime'] = outgoing.pop('captureMono') + offset
                    outgoing['uncertaintyMs'] = (outgoing.pop('deviceError') + error) * 1000
                    if outgoing['uncertaintyMs'] > 30:
                        continue
                    try:
                        sock.send(json.dumps(outgoing, allow_nan=False, separators=(',', ':')).encode())
                    except OSError:
                        continue
                    sent[side] = message['sourceTimestampUs']
                    totals[side] += 1
            if now >= next_report:
                with lock:
                    quality = {side: {'age_ms': round((now-m['captureMono'])*1000),
                                      'min_confidence': round(min(m['confidence']), 3)}
                               for side, m in latest.items()}
                print(f'clock={"ready" if estimate else "waiting for headset"} sent={totals} gloves={quality}', flush=True)
                next_report = now + 5
            if not worker.is_alive() and not stop.is_set():
                raise RuntimeError('Wuji acquisition worker stopped')
    finally:
        stop.set()
        worker.join(timeout=5)
        sock.close()


if __name__ == '__main__':
    main()
