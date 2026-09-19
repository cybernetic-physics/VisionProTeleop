import importlib.util
from pathlib import Path
from types import SimpleNamespace as NS
import time
import numpy as np
import pytest
from avp_stream.controllers import decode_controllers, controller_snapshot
from avp_stream.grpc_msg import handtracking_pb2 as pb
from test_controllers import matrix, pose, packet

spec = importlib.util.spec_from_file_location('glove_sender', Path(__file__).parents[1] / 'tools/wuji/stream_gloves.py')
sender = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sender)


def fused():
    p = packet()
    p.gloves.version = 1
    s = p.gloves.left
    s.valid = True
    s.timestamp_ns = p.timestamp_ns - 20_000_000
    s.source_timestamp_us = 1_700_000_000_000_000
    s.sequence = 8
    s.uncertainty_ms = 2
    points = np.zeros((21, 3)); points[1:, 2] = np.linspace(.01, .2, 20)
    s.points_wrist.extend(points.flat)
    s.confidence.extend([1]*21)
    s.head_world.CopyFrom(matrix(pose(1, 2, 3, .4)))
    s.wrist_world.CopyFrom(matrix(pose(1, 2, 3, .4) @ pose(.2, -.3, -.4, .3)))
    return p, points


def test_wrist_and_skeleton_share_correct_head_world_and_stream_frames():
    p, points = fused()
    correction, axis, stream = pose(.1, 0, 0), pose(yaw=.5), pose(0, .2, 0)
    g = decode_controllers(p, world_from_surreal=correction, axis_transform=axis, stream_from_avp=stream)['gloves']['left']
    assert g['valid']
    local = np.column_stack([points, np.ones(21)])
    expected = correction @ pose(1, 2, 3, .4) @ pose(.2, -.3, -.4, .3)
    np.testing.assert_allclose(g['joints_avp'], (expected @ local.T).T[:, :3], atol=1e-6)
    np.testing.assert_allclose(g['joints'], (stream @ axis @ expected @ local.T).T[:, :3], atol=1e-6)
    np.testing.assert_allclose(g['joints_head'], (np.linalg.solve(pose(1,2,3,.4), expected) @ local.T).T[:, :3], atol=1e-6)
    assert not decode_controllers(p)['gloves']['right']['valid']


@pytest.mark.parametrize('case', ['old', 'future', 'low_confidence', 'bad_confidence', 'bad_points', 'count', 'clock_error', 'bad_wrist'])
def test_invalid_fusion_has_no_joint_arrays_and_does_not_affect_buttons(case):
    p, _ = fused(); s = p.gloves.left
    if case == 'old': s.timestamp_ns = 1
    elif case == 'future': s.timestamp_ns += 100_000_000
    elif case == 'low_confidence': s.confidence[5] = .1
    elif case == 'bad_confidence': s.confidence[5] = float('nan')
    elif case == 'bad_points': s.points_wrist[5] = float('inf')
    elif case == 'count': del s.points_wrist[-1]
    elif case == 'clock_error': s.uncertainty_ms = 31
    elif case == 'bad_wrist': s.wrist_world.m00 = 9
    decoded = decode_controllers(p)
    assert not decoded['gloves']['left']['valid']
    assert decoded['gloves']['left']['joints_avp'] is None
    assert decoded['left']['buttons']['x'] is True


def test_expiry_clears_gloves_and_old_packets_still_work():
    p, _ = fused()
    d = decode_controllers(p, received_at=10)
    assert controller_snapshot(d, now=10.1)['gloves']['left']['valid']
    assert not controller_snapshot(d, now=10.3)['gloves']['left']['valid']
    assert not decode_controllers(packet())['gloves']['supported']
    assert decode_controllers(pb.ControllerTracking.FromString(p.SerializeToString()), live=False)['gloves']['left']['valid']


def test_four_timestamp_clock_mapping_and_expiry():
    c = sender.ClockSync()
    for i in range(3):
        assert c.observe(10+i, 110.002+i, 110.003+i, 10.005+i)
    offset, error = c.estimate(12.01)
    assert offset == pytest.approx(100)
    assert error == pytest.approx(.002)
    assert c.estimate(20) is None
    assert not c.observe(1, 2, 3, 1.5)
    assert not c.observe(1, 101, 101, 2)
    assert not c.observe(1, float('nan'), 2, 3)


def test_sender_preserves_acquisition_time_and_rejects_unsynchronized_clock():
    frame = NS(header=NS(timestamp_us=int((time.time()-.02)*1e6), seq=42, frame_id='l_wrist'),
               joints=[NS(pose=NS(position=[0,0,0]), confidence=1)]*21)
    m = sender.skeleton_message(frame, 'left', 'test', .001, 'session')
    assert m is not None and .015 < time.monotonic()-m['captureMono'] < .05
    frame.header.timestamp_us = 123456
    assert sender.skeleton_message(frame, 'left', 'test', .001, 'session') is None


def test_glove_expires_by_capture_age_even_when_controller_packet_is_recent():
    p, _ = fused()
    p.gloves.left.timestamp_ns = p.timestamp_ns - 240_000_000
    d = decode_controllers(p, received_at=10)
    assert controller_snapshot(d, now=10.005)['gloves']['left']['valid']
    assert not controller_snapshot(d, now=10.02)['gloves']['left']['valid']
    assert controller_snapshot(d, now=10.02)['left']['pose_valid']
