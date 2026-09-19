"""Local, read-only spatial debugger. Run with the repository's .venv Python."""
import argparse
from collections import deque
from copy import deepcopy
import json
from pathlib import Path
import socket
import threading
import time
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

import grpc
import numpy as np
from avp_stream.controllers import decode_controllers, controller_snapshot, empty_controllers, rigid_transform
from avp_stream.grpc_msg import handtracking_pb2 as pb, handtracking_pb2_grpc as rpc

ROOT = Path(__file__).resolve().parent
SIDES = ('left', 'right')


def matrix(p, packed=False):
    a = np.array([[getattr(p, f'm{r}{c}') for c in range(4)] for r in range(4)], dtype=float)
    if packed:
        a[3] = [0, 0, 0, 1]
    try:
        return rigid_transform(a)
    except ValueError:
        return None


def serial(value):
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, dict):
        return {k: serial(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [serial(v) for v in value]
    return value


class Feed:
    def __init__(self, ip):
        self.ip = ip
        self.lock = threading.Lock()
        self.controller = empty_controllers()
        self.head = None
        self.hands = {}
        self.extras = []
        self.events = deque(maxlen=40)
        self.arrivals = deque(maxlen=300)
        self.sequence_times = deque(maxlen=300)
        self.received = None
        self.packet = 0
        self.status = 'Connecting to headset'
        self.event_id = 0
        self.stop = threading.Event()
        threading.Thread(target=self.receive, daemon=True).start()

    def accept(self, p):
        if p.Head.m00 == 777:
            return
        now = time.monotonic()
        ctrl = decode_controllers(p.controllers if p.HasField('controllers') else None, received_at=now)
        hands = {}
        for side in SIDES:
            hand = getattr(p, side + '_hand')
            wrist = matrix(hand.wristMatrix)
            joints = [matrix(j) for j in hand.skeleton.jointMatrices[:27]]
            # The legacy hand packet has no tracking-validity bit. Do not invent one.
            usable = wrist is not None and len(joints) >= 25 and all(j is not None for j in joints)
            validity = 'not supplied by hand protocol'
            if hand.tracking_version == 1:
                age = (p.timestamp_ns - hand.sample_timestamp_ns) / 1e6
                usable = usable and hand.tracked and hand.sample_timestamp_ns > 0 and 0 <= age <= 200
                validity = f'ARKit: {sum(hand.joint_tracked[:25])}/25 joints tracked · {age:.0f} ms'
            if usable:
                world = [wrist @ j for j in joints]
                positions = [m[:3, 3].tolist() for m in world]
                # Exclude the sender's all-identity startup placeholders.
                usable = np.ptp(np.array(positions), axis=0).max() > .005
            hands[side] = {'present': bool(usable), 'validity': validity,
                           'tracking_version': hand.tracking_version, 'tracked': hand.tracked,
                           'joint_tracked': list(hand.joint_tracked),
                           'wrist': wrist.tolist() if usable else None,
                           'joints': positions if usable else [],
                           'joint_poses': [m.tolist() for m in world] if usable else [],
                           'pinch_m': float(np.linalg.norm(world[4][:3,3] - world[9][:3,3])) if usable else None}
        extras = []
        joints = list(p.right_hand.skeleton.jointMatrices)
        idx = 27
        if len(joints) > idx and abs(joints[idx].m00 - 666) < .1:
            count = max(0, min(128, int(joints[idx].m01)))
            for j in joints[idx+1:idx+1+count]:
                pose = matrix(j, packed=True)
                if pose is not None:
                    extras.append({'kind':'marker' if j.m30 < .5 else 'image', 'id':int(j.m33),
                                   'pose':pose.tolist(), 'tracked':j.m31 > .5, 'fixed':j.m32 > .5})
            idx += 1 + count
        if len(joints) > idx and abs(joints[idx].m00 - 777) < .1:
            for j in joints[idx+1:idx+1+max(0,min(8,int(joints[idx].m01)))]:
                pose = matrix(j, packed=True)
                if pose is not None:
                    extras.append({'kind':'stylus','id':0,'pose':pose.tolist(),'tracked':True,
                                   'tip_pressure':j.m30,'primary_pressure':j.m31,'secondary_pressure':j.m32,
                                   'raw_flags':j.m33})
        with self.lock:
            old = self.controller
            same = (ctrl['timestamp_ns'],ctrl['sequence']) == (old['timestamp_ns'],old['sequence'])
            if same:
                ctrl['received_at_monotonic'] = old['received_at_monotonic']
            elif ctrl['supported']:
                self.sequence_times.append(now)
                old_live = not controller_snapshot(old, now=now)['stale']
                for side in SIDES:
                    for name,value in ctrl[side]['buttons'].items():
                        before = old[side]['buttons'][name]
                        if old_live and value is not None and before is not None and value != before:
                            self.event_id += 1
                            self.events.appendleft({'id':self.event_id,'time':time.strftime('%H:%M:%S'),
                                                    'side':side,'name':name,'pressed':value})
            self.controller = ctrl
            self.head = matrix(p.Head)
            self.hands = hands
            self.extras = extras
            self.received = now
            self.arrivals.append(now)
            self.packet += 1
            self.status = 'Receiving'

    def receive(self):
        while not self.stop.is_set():
            try:
                with grpc.insecure_channel(self.ip + ':12345') as channel:
                    grpc.channel_ready_future(channel).result(timeout=5)
                    request = pb.HandUpdate()
                    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:
                        sock.connect((self.ip,12345))
                        parts = [float(i) for i in sock.getsockname()[0].split('.')]
                    request.Head.m00 = 888
                    request.Head.m01,request.Head.m02,request.Head.m03,request.Head.m10 = parts
                    request.Head.m30 = 25200
                    for p in rpc.HandTrackingServiceStub(channel).StreamHandUpdates(request):
                        self.accept(p)
            except Exception as exc:
                with self.lock:
                    self.status = 'Reconnecting: ' + (exc.code().name if isinstance(exc,grpc.RpcError) else type(exc).__name__)
            self.stop.wait(1)

    def snapshot(self):
        now = time.monotonic()
        with self.lock:
            age = None if self.received is None else (now-self.received)*1000
            live = age is not None and age < 250
            c = controller_snapshot(self.controller, now=now)
            rate = lambda q: round((len(q)-1)/(q[-1]-q[0]),1) if live and len(q)>1 and q[-1]>q[0] else 0
            data = {'ip':self.ip,'live':live,'status':self.status,'age_ms':age,'packet':self.packet,
                    'packet_hz':rate(self.arrivals),'controller_hz':rate(self.sequence_times) if not c['stale'] else 0,
                    'controller_age_ms':None if c['received_at_monotonic'] is None else (now-c['received_at_monotonic'])*1000,
                    'controllers':c,'head': c['head_pose_avp'],
                    'head_source':'synchronized ARKit' if c['head_pose_avp'] is not None else 'unavailable',
                    'hands':deepcopy(self.hands) if live else {},'extras':deepcopy(self.extras) if live else [],
                    'events':list(self.events),'coordinates':'ARKit world: +X right, +Y up, -Z forward; meters',
                    'alignment':('Manual calibration preview' if c.get('calibration', {}).get('preview') else 'Saved manual calibration' if c.get('calibration', {}).get('reviewed_this_session') else 'Manual profile: review alignment this session') if c.get('calibration') else 'Identity assumption; not physically calibrated',
                    'hand_validity':'Build 24+ supplies explicit hand/joint validity; legacy streams may contain cached hands.'}
        return serial(data)


class Handler(SimpleHTTPRequestHandler):
    def __init__(self,*a,**kw):
        super().__init__(*a,directory=str(ROOT),**kw)
    def log_message(self,*a): pass
    def do_GET(self):
        if self.path in ('/api/state','/api/snapshot'):
            payload = json.dumps(self.server.feed.snapshot(),allow_nan=False,separators=(',',':')).encode()
            self.send_response(200)
            self.send_header('Content-Type','application/json')
            self.send_header('Cache-Control','no-store')
            self.send_header('Content-Length',str(len(payload)))
            self.end_headers(); self.wfile.write(payload)
        elif self.path == '/events':
            self.send_response(200)
            self.send_header('Content-Type','text/event-stream')
            self.send_header('Cache-Control','no-store')
            self.end_headers()
            try:
                while True:
                    payload = json.dumps(self.server.feed.snapshot(),allow_nan=False,separators=(',',':'))
                    self.wfile.write(('data: '+payload+'\n\n').encode()); self.wfile.flush()
                    time.sleep(1/30)
            except (BrokenPipeError,ConnectionResetError): pass
        elif self.path == '/' or self.path == '/index.html' or self.path == '/app.js' or self.path.startswith('/node_modules/three/'):
            super().do_GET()
        else:
            self.send_error(404)

if __name__ == '__main__':
    p=argparse.ArgumentParser(); p.add_argument('--ip',required=True); p.add_argument('--port',type=int,default=8917)
    args=p.parse_args(); server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler); server.daemon_threads=True
    server.feed=Feed(args.ip)
    print(f'Spatial debugger: http://127.0.0.1:{args.port} • headset {args.ip}',flush=True)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:server.feed.stop.set();server.server_close()
