#!/usr/bin/env python3
"""Vision Pro optical hands -> Wuji Hand 2. Dry-run unless --enable-motors.

Requires build 24 tracking metadata. Left-only by default. No gloves/controllers.
Tracking loss holds position; stable tracking resumes with bounded joint speed.
"""
from __future__ import annotations
import argparse
import contextlib
import json
import signal
import socket
import threading
import time
from pathlib import Path
import numpy as np

# ARKit's published 27-joint order -> MediaPipe's 21 landmarks.
LANDMARKS = (0, 1, 2, 3, 4, 6, 7, 8, 9, 11, 12, 13, 14, 16, 17, 18, 19, 21, 22, 23, 24)
# Wuji Hand 2 feedback node IDs, in firmware finger-major command order.
NODE_IDS = tuple(finger * 5 + joint for finger in range(5) for joint in range(1, 5))
HANDS = {"left": ("WH2JA01260820042", "192.168.1.110"),
         "right": ("WH2KA01260824015", "192.168.1.111")}
MAX_AGE = .20
REACQUIRE_SECONDS = .30


class TrackingGate:
    """Per-hand recovery; duplicate samples cannot satisfy reacquisition."""
    def __init__(self):
        self.live = False
        self.since = None
        self.identity = None
        self.frames = 0

    def update(self, now, sample, error):
        if error or sample is None:
            self.live = False
            self.since = None
            self.identity = None
            self.frames = 0
            return 'holding'
        if self.live:
            return 'live'
        identity = sample[2]
        if self.since is None:
            self.since = now
        if identity != self.identity:
            self.identity = identity
            self.frames += 1
        if self.frames >= 5 and now-self.since >= REACQUIRE_SECONDS:
            self.live = True
            return 'live'
        return 'reacquiring'


def keypoints(hand, sent_ns):
    if hand.tracking_version != 1:
        raise ValueError("Vision Pro build 24 or newer required (tracking validity missing)")
    if not hand.tracked:
        raise ValueError("optical hand not tracked")
    age = (sent_ns - hand.sample_timestamp_ns) / 1e9
    if not hand.sample_timestamp_ns or not 0 <= age <= MAX_AGE:
        raise ValueError("optical hand sample stale")
    if not np.isfinite(hand.prediction_ms) or not 0 <= hand.prediction_ms <= 50:
        raise ValueError("set hand prediction to 0–50 ms")
    if len(hand.skeleton.jointMatrices) < 25 or len(hand.joint_tracked) < 25:
        raise ValueError("incomplete optical skeleton")
    if not hand.joint_tracked[0]:
        raise ValueError("optical wrist untracked")
    # ARKit supplies a current articulated hand model even for occluded joints.
    # Joint flags are diagnostic; hand/wrist validity + freshness gate actuation.
    points = np.array([[getattr(hand.skeleton.jointMatrices[i], f'm{r}3')
                        for r in range(3)] for i in LANDMARKS], dtype=np.float32)
    points -= points[0].copy()
    if not np.isfinite(points).all() or np.max(np.abs(points)) > .4:
        raise ValueError("invalid hand coordinates")
    for base in (1, 5, 9, 13, 17):
        lengths = np.linalg.norm(np.diff(points[base:base+4], axis=0), axis=1)
        if np.any(lengths < .003) or np.any(lengths > .10):
            raise ValueError("degenerate finger geometry")
    return points


def bounded_target(previous, requested, dt, speed=1.5):
    target = np.asarray(requested, dtype=float)
    if target.shape != (20,) or not np.isfinite(target).all() or np.max(np.abs(target)) > 3.2:
        raise ValueError("invalid retarget output")
    return previous + np.clip(target-previous, -speed*min(dt,.05), speed*min(dt,.05))


class Source:
    def __init__(self, ip, sides):
        self.ip, self.sides = ip, sides
        self.lock = threading.Lock()
        self.latest = {}
        self.status = "connecting to Vision Pro"
        self.stop = threading.Event()
        self.channel = None
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        import grpc
        try:
            import handtracking_pb2 as pb  # standalone deployment next to this file
        except ImportError:
            from avp_stream.grpc_msg import handtracking_pb2 as pb
        while not self.stop.is_set():
            try:
                with grpc.insecure_channel(self.ip + ':12345') as channel:
                    self.channel = channel
                    grpc.channel_ready_future(channel).result(timeout=5)
                    request = pb.HandUpdate()
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                        sock.connect((self.ip,12345))
                        a = list(map(float,sock.getsockname()[0].split('.')))
                    request.Head.m00 = 888
                    request.Head.m01,request.Head.m02,request.Head.m03,request.Head.m10 = a
                    request.Head.m30 = 25200
                    stream = channel.unary_stream('/handtracking.HandTrackingService/StreamHandUpdates',
                        request_serializer=pb.HandUpdate.SerializeToString,
                        response_deserializer=pb.HandUpdate.FromString)
                    identities = {}
                    min_offset = None
                    for packet in stream(request):
                        now = time.monotonic()
                        offset = now - packet.timestamp_ns/1e9
                        min_offset = offset if min_offset is None else min(min_offset,offset)
                        delay = max(0, offset-min_offset)
                        for side in self.sides:
                            hand = getattr(packet, side+'_hand')
                            identity = (hand.sample_sequence, hand.sample_timestamp_ns)
                            if identities.get(side) == identity:
                                continue  # Repeated packets never refresh a cached hand.
                            identities[side] = identity
                            try:
                                points = keypoints(hand, packet.timestamp_ns)
                                age = (packet.timestamp_ns-hand.sample_timestamp_ns)/1e9 + delay
                                sample = (points, now-age, identity, None)
                            except ValueError as exc:
                                sample = (None, now, identity, str(exc))
                            with self.lock:
                                self.latest[side] = sample
                                self.status = "receiving optical hands"
                        if self.stop.is_set(): break
            except Exception as exc:
                with self.lock:
                    self.latest.clear()
                    self.status = f"Vision Pro connection: {type(exc).__name__}"
                self.stop.wait(1)

    def get(self, side):
        with self.lock:
            sample = self.latest.get(side)
            if sample is None: return None, self.status
            points, received, identity, error = sample
            if error: return None, error
            if time.monotonic()-received > MAX_AGE: return None, "optical hand/network stale"
            return sample, None

    def close(self):
        self.stop.set()
        if self.channel: self.channel.close()
        self.thread.join(timeout=2)


def drain(sub):
    latest = None
    for _ in range(256):
        frame = sub.recv()
        if frame is None: break
        latest = frame
    return latest


def read_feedback(frame):
    entries = {j.nid: j.position for j in frame.joints}
    if set(entries) != set(NODE_IDS): raise ValueError("incomplete robot joint feedback")
    q = np.array([entries[nid] for nid in NODE_IDS])
    if not np.isfinite(q).all(): raise ValueError("invalid robot joint feedback")
    return q


def main():
    from wuji_sdk import SdkManager, DeviceType, HandModel, Handedness, RetargetSession, JointCommand, WujiHand2, set_log_level
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ip', default='192.168.50.236')
    parser.add_argument('--side', choices=['left','right','both'], default='left')
    parser.add_argument('--enable-motors', action='store_true')
    parser.add_argument('--duration', type=float, default=0)
    parser.add_argument('--rate', type=float, default=60)
    parser.add_argument('--effort-limit', type=float, default=.5)
    parser.add_argument('--max-speed', type=float, default=1.5, help='joint target speed, rad/s')
    parser.add_argument('--status-file', default='/tmp/wuji-visionpro-hands-status.json')
    args = parser.parse_args()
    if not 0 < args.rate <= 120 or not 0 < args.effort_limit <= 1.5 or not 0 < args.max_speed <= 3 or args.duration < 0:
        parser.error('invalid rate, current, speed, or duration')
    sides = ['left','right'] if args.side == 'both' else [args.side]
    stop = threading.Event()
    signal.signal(signal.SIGINT,lambda *_:stop.set())
    signal.signal(signal.SIGTERM,lambda *_:stop.set())
    set_log_level('warn')
    manager = SdkManager.instance()
    source = Source(args.ip,sides)
    runtimes = {}
    hardware_lock = threading.Lock()
    heartbeat = [time.monotonic()]
    fault = []
    watchdog = None

    def disable_all(reason):
        with hardware_lock:
            for side, r in runtimes.items():
                if r['enabled']:
                    try: r['hand'].disable()
                    except Exception as exc: print(f'{side} disable failed: {exc}',flush=True)
                    r['enabled'] = False
        if reason: print(reason,flush=True)

    def watch():
        while not stop.wait(.025):
            if any(r['enabled'] for r in runtimes.values()):
                if time.monotonic()-heartbeat[0] > .25:
                    fault.append('command loop stalled')
                    stop.set()
                    disable_all('STOP: '+fault[-1])

    try:
        devices = {d.sn:d for d in manager.scan()}
        for side in sides:
            serial, ip = HANDS[side]
            d = devices.get(serial)
            if d is None or str(d.address).split(':')[0] != ip or d.device_type != DeviceType.WujiHand2:
                raise RuntimeError(f'expected {side} robot {serial} at {ip} not found')
            hand = manager.connect(sn=serial, device_name='visionpro_'+side+'_hand')
            if str(hand.handedness().get()).lower() != side or hand.online_joints_count().get() != 20:
                raise RuntimeError(f'{side} robot handedness or joint count mismatch')
            r = dict(hand=hand, enabled=False, publisher=None, feedback=hand.joint_states().subscribe(),
                diagnostics=hand.joint_diagnostics().subscribe(),feedback_at=0,diagnostics_at=0,q=None,
                retarget=RetargetSession.for_hand(HandModel.WujiHand2,side=Handedness.Left if side=='left' else Handedness.Right),
                last_identity=None,target=None,frames=0,commands=0,status='waiting for optical hand',
                gate=TrackingGate(),tracking_state='holding',hold_q=None)
            runtimes[side] = r
            print(f'Verified {side} robot {serial} at {ip}; 20 joints. Motors '+('requested' if args.enable_motors else 'untouched (dry-run)'),flush=True)
        watchdog = threading.Thread(target=watch,daemon=True)
        watchdog.start()
        started = report_at = previous = time.monotonic()
        while not stop.is_set():
            now = time.monotonic(); dt = now-previous; previous=now; heartbeat[0]=now
            if args.duration and now-started >= args.duration: break
            for side,r in runtimes.items():
                feedback=drain(r['feedback'])
                if feedback is not None:
                    measured = read_feedback(feedback); r['feedback_at']=now
                    r['measured']=measured
                    if not r['enabled']: r['q']=measured
                diagnostics=drain(r['diagnostics'])
                if diagnostics is not None:
                    if len(diagnostics.joints)!=20: raise RuntimeError('incomplete robot diagnostics')
                    r['diagnostics_at']=now
                    for joint in diagnostics.joints:
                        code=int(joint.error_code_current)
                        info=WujiHand2.describe_error(code) if code else None
                        if code and (info is None or info.get('severity')!='Warning'):
                            raise RuntimeError(f'{side} robot fault: joint {joint.nid}, code {code}, {info}')
                robot_ready = now-r['feedback_at']<=.25 and now-r['diagnostics_at']<=.5
                if r['enabled'] and not robot_ready:
                    raise RuntimeError(f'{side} robot feedback/diagnostics stale')
                sample,error=source.get(side)
                state=r['gate'].update(now,sample,error)
                if state != r['tracking_state']:
                    print(f'{side}: {r["tracking_state"]} -> {state}'+(f' ({error})' if error else ''),flush=True)
                    if state == 'holding':
                        # Freeze at measured pose, not a target the robot is still chasing.
                        r['hold_q']=r['measured'].copy() if r['enabled'] else None
                        r['retarget'].reset(); r['last_identity']=None; r['target']=None
                    elif state == 'live' and r['enabled']:
                        r['q']=r['measured'].copy()
                    r['tracking_state']=state
                if state != 'live':
                    r['status']=('holding: '+error if error else 'reacquiring optical hand (300 ms)')
                    if r['enabled']:
                        with hardware_lock:
                            if stop.is_set():break
                            r['publisher'].send([JointCommand(float(q),0.,0.) for q in r['hold_q']])
                            r['commands']+=1
                    continue
                points, received, identity, _=sample
                if identity != r['last_identity']:
                    target=np.asarray(r['retarget'].step(points),dtype=float)
                    bounded_target(np.zeros(20),target,dt,args.max_speed)  # validate before enable
                    r['target']=target;r['last_identity']=identity;r['frames']+=1
                r['status']='optical hand live'
                if args.enable_motors:
                    if not robot_ready:
                        r['status']='waiting for robot feedback';continue
                    if source.get(side)[1] or stop.is_set():continue
                    if not r['enabled']:
                        r['hand'].effort_limit().set(args.effort_limit)
                        r['hand'].mit_params().set((3.0,.05))
                        r['publisher']=r['hand'].joint_command().publish()
                        with hardware_lock:
                            if stop.is_set():break
                            r['enabled']=True
                            r['hand'].enable()
                        print(f'ENABLED {side}: {args.effort_limit} A; Ctrl+C disables; tracking loss holds, then resumes.',flush=True)
                    r['q']=bounded_target(r['q'],r['target'],dt,args.max_speed)
                    with hardware_lock:
                        if stop.is_set():break
                        r['publisher'].send([JointCommand(float(q),0.,0.) for q in r['q']])
                        r['commands']+=1
            if now-report_at>=1:
                status={side:{'status':r['status'],'enabled':r['enabled'],'frames':r['frames'],'commands':r['commands'],
                    'tracking_state':r['tracking_state'],
                    'target':None if r['target'] is None else np.round(r['target'],4).tolist(),
                    'measured':None if r.get('measured') is None else np.round(r['measured'],4).tolist()} for side,r in runtimes.items()}
                status['mode']='live' if args.enable_motors else 'dry-run'
                status['updated_at']=time.time()
                path=Path(args.status_file);tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(status));tmp.replace(path)
                print(json.dumps(status),flush=True);report_at=now
            stop.wait(max(0,1/args.rate-(time.monotonic()-now)))
        if fault: raise RuntimeError(fault[-1])
    finally:
        stop.set()
        disable_all('Stopped; all hands enabled by this process disabled.')
        source.close()
        if watchdog: watchdog.join(timeout=2)
        for r in runtimes.values():
            for resource in (r['publisher'],r['feedback'],r['diagnostics']):
                if resource is not None:
                    with contextlib.suppress(Exception):resource.close()
        manager.disconnect_all()
        Path(args.status_file).write_text(json.dumps({'mode':'stopped','updated_at':time.time(),'reason':fault[-1] if fault else 'process stopped'}))

if __name__=='__main__':
    main()
