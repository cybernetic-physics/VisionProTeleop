import importlib.util
from pathlib import Path
from types import SimpleNamespace
import numpy as np
import pytest
from avp_stream.grpc_msg import handtracking_pb2 as pb

spec=importlib.util.spec_from_file_location('wuji_optical',Path(__file__).parents[1]/'tools/wuji/visionpro_hands.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

def hand():
    h=pb.Hand(tracking_version=1,tracked=True,sample_timestamp_ns=1_000_000_000,sample_sequence=1)
    h.joint_tracked.extend([True]*27)
    for i in range(27): h.skeleton.jointMatrices.add(m00=1,m11=1,m22=1,m33=1)
    for f,base in enumerate((1,5,9,13,17)):
        for j in range(4):
            p=h.skeleton.jointMatrices[m.LANDMARKS[base+j]]
            p.m03=(f-2)*.02;p.m13=.04+j*.025
    return h

def test_landmarks_omit_metacarpals_and_forearm_and_center_wrist():
    h=hand();p=m.keypoints(h,1_010_000_000)
    assert p.shape==(21,3)
    np.testing.assert_allclose(p[0],0)
    np.testing.assert_allclose(p[5],[ -.02,.04,0],atol=1e-7)
    h.skeleton.jointMatrices[5].m03=99
    np.testing.assert_array_equal(m.keypoints(h,1_010_000_000),p)
    for j in h.skeleton.jointMatrices:j.m03+=.1
    np.testing.assert_allclose(m.keypoints(h,1_010_000_000),p,atol=1e-7)

@pytest.mark.parametrize('change',[lambda h:setattr(h,'tracking_version',0),lambda h:setattr(h,'tracked',False),
    lambda h:setattr(h,'sample_timestamp_ns',1),lambda h:setattr(h,'sample_timestamp_ns',2_000_000_000),
    lambda h:h.joint_tracked.__setitem__(0,False),lambda h:setattr(h,'prediction_ms',500),
    lambda h:setattr(h.skeleton.jointMatrices[6],'m03',float('nan'))])
def test_invalid_tracking_cannot_drive_robot(change):
    h=hand();change(h)
    with pytest.raises(ValueError):m.keypoints(h,1_010_000_000)

def test_rate_limit_and_invalid_retarget_output():
    q=m.bounded_target(np.zeros(20),np.ones(20),.01)
    np.testing.assert_allclose(q,.015)
    np.testing.assert_allclose(m.bounded_target(np.zeros(20),np.ones(20),10),.075)
    for q in (np.zeros(19),np.full(20,np.nan),np.full(20,100)):
        with pytest.raises(ValueError):m.bounded_target(np.zeros(20),q,.01)

def test_robot_feedback_is_mapped_by_node_id_not_arrival_order():
    frame=SimpleNamespace(joints=[SimpleNamespace(nid=n,position=float(i)) for i,n in enumerate(m.NODE_IDS)][::-1])
    np.testing.assert_array_equal(m.read_feedback(frame),np.arange(20))
    frame.joints.pop()
    with pytest.raises(ValueError):m.read_feedback(frame)

def test_old_cached_sample_expires_even_while_transport_is_alive():
    import threading,time
    source=m.Source.__new__(m.Source);source.lock=threading.Lock();source.status='receiving'
    source.latest={'left':(np.ones((21,3)),time.monotonic()-.5,(1,1),None)}
    assert source.get('left')[0] is None


def test_current_inferred_fingers_allowed_while_wrist_is_tracked():
    h=hand()
    for i in range(1,25):h.joint_tracked[i]=False
    assert m.keypoints(h,1_010_000_000).shape==(21,3)
    h.tracked=False
    with pytest.raises(ValueError):m.keypoints(h,1_010_000_000)


def test_tracking_gate_requires_stable_distinct_samples_after_every_loss():
    gate=m.TrackingGate()
    sample=lambda i:(None,0,(i,i),None)
    assert gate.update(0,None,'lost')=='holding'
    for i,t in enumerate((.01,.10,.20,.25)):
        assert gate.update(t,sample(i),None)=='reacquiring'
    assert gate.update(.32,sample(4),None)=='live'
    assert gate.update(.4,None,'stale')=='holding'
    assert gate.update(.41,sample(5),None)=='reacquiring'
    assert gate.update(.6,None,'lost again')=='holding'
    for i,t in enumerate((.61,.70,.80,.85)):
        assert gate.update(t,sample(i+6),None)=='reacquiring'
    assert gate.update(.92,sample(10),None)=='live'


def test_duplicate_samples_cannot_rearm_tracking_gate():
    gate=m.TrackingGate()
    for t in (0,.1,.2,.3,.4,1):
        assert gate.update(t,(None,0,(1,1),None),None)=='reacquiring'


def test_control_loop_holds_and_automatically_resumes_without_reenabling(monkeypatch,tmp_path):
    import sys,time,types
    commands=[];events=[];started=[None];pose=np.zeros(20)
    class Subscription:
        def __init__(self,diagnostics=False):self.diagnostics=diagnostics;self.pending=True
        def recv(self):
            self.pending=not self.pending
            if not self.pending:
                return SimpleNamespace(joints=[SimpleNamespace(nid=n,position=pose[i],error_code_current=0) for i,n in enumerate(m.NODE_IDS)])
            return None
        def close(self):pass
    class Publisher:
        def send(self,values):
            pose[:]=[v.q for v in values]
            commands.append((time.monotonic()-started[0],pose.copy()))
        def close(self):pass
    class Hand:
        def handedness(self):return SimpleNamespace(get=lambda:'left')
        def online_joints_count(self):return SimpleNamespace(get=lambda:20)
        def joint_states(self):return SimpleNamespace(subscribe=Subscription)
        def joint_diagnostics(self):return SimpleNamespace(subscribe=Subscription)
        def effort_limit(self):return SimpleNamespace(set=lambda x:None)
        def mit_params(self):return SimpleNamespace(set=lambda x:None)
        def joint_command(self):return SimpleNamespace(publish=Publisher)
        def enable(self):events.append('enable')
        def disable(self):events.append('disable')
    class Manager:
        def scan(self):return [SimpleNamespace(sn=m.HANDS['left'][0],address=m.HANDS['left'][1],device_type='wuji')]
        def connect(self,**kw):return Hand()
        def disconnect_all(self):pass
    class Retarget:
        def step(self,points):return np.ones(20)
        def reset(self):pass
    class Source:
        def __init__(self,*args):started[0]=time.monotonic()
        def get(self,side):
            now=time.monotonic();t=now-started[0]
            if .42<=t<.60:return None,'optical hand not tracked'
            return (np.zeros((21,3)),now,(int(t*1000),1),None),None
        def close(self):pass
    fake=types.ModuleType('wuji_sdk')
    fake.SdkManager=SimpleNamespace(instance=Manager)
    fake.DeviceType=SimpleNamespace(WujiHand2='wuji')
    fake.HandModel=SimpleNamespace(WujiHand2='wuji')
    fake.Handedness=SimpleNamespace(Left='left',Right='right')
    fake.RetargetSession=SimpleNamespace(for_hand=lambda *a,**k:Retarget())
    fake.JointCommand=lambda q,v,e:SimpleNamespace(q=q)
    fake.WujiHand2=SimpleNamespace(describe_error=lambda c:None)
    fake.set_log_level=lambda level:None
    monkeypatch.setitem(sys.modules,'wuji_sdk',fake)
    monkeypatch.setattr(m,'Source',Source)
    monkeypatch.setattr(m.signal,'signal',lambda *a:None)
    monkeypatch.setattr(sys,'argv',['bridge','--enable-motors','--duration','1.15','--status-file',str(tmp_path/'status.json')])
    m.main()
    assert events==['enable','disable']  # dropout does not disable/re-enable motors
    held=[q for t,q in commands if .46<t<.88]
    assert len(held)>10
    for q in held:np.testing.assert_array_equal(q,held[0])
    assert commands[-1][1][0]>held[0][0]  # recovery actually sends new movement
    for (t0,q0),(t1,q1) in zip(commands,commands[1:]):
        assert np.max(np.abs(q1-q0))<=1.5*min(t1-t0+.003,.053)
