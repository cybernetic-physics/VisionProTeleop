import base64
import json
import threading
import time
from copy import deepcopy

import numpy as np
import pytest
from google.protobuf import descriptor_pb2, descriptor_pool, message_factory

from avp_stream.controllers import (
    INPUT_NAMES, controller_snapshot, decode_controllers, empty_controllers, rigid_transform,
)
from avp_stream.grpc_msg import handtracking_pb2 as pb
from avp_stream.streamer import VisionProStreamer, TrackingData, YUP2ZUP
from avp_stream.utils.recording_loader import load_jsonl


def matrix(value):
    return pb.Matrix4x4(**{f"m{r}{c}": value[r, c] for r in range(4) for c in range(4)})


def pose(x=0, y=0, z=0, yaw=0):
    c, s = np.cos(yaw), np.sin(yaw)
    return np.array([[c, 0, s, x], [0, 1, 0, y], [-s, 0, c, z], [0, 0, 0, 1.]])


def packet():
    p = pb.ControllerTracking(version=1, enabled=True, source="surreal_touch", timestamp_ns=1_000_000_000, sequence=10)
    p.head_pose.CopyFrom(matrix(pose(1, 2, 3, np.pi / 2)))
    p.head_pose_valid = True
    for side, x in (("left", -0.2), ("right", 0.3)):
        state = getattr(p, side)
        state.active = state.pose_valid = True
        # Known offset/orientation in head space, translated and rotated into world.
        state.pose.CopyFrom(matrix(pose(1, 2, 3, np.pi / 2) @ pose(x, -0.1, -0.5)))
        for i, name in enumerate(INPUT_NAMES[side]):
            is_boolean = name not in ("trigger", "grip", "thumbstick_x", "thumbstick_y")
            state.inputs.add(name=name, active=True, is_boolean=is_boolean,
                             value=1 if is_boolean else 0.75, pressed=is_boolean,
                             last_change_time_ns=100 + i)
    return p


def update(with_hands=True):
    message = pb.HandUpdate(controllers=packet(), Head=matrix(np.eye(4)))
    if with_hands:
        for hand in (message.left_hand, message.right_hand):
            hand.wristMatrix.CopyFrom(matrix(np.eye(4)))
            for _ in range(27):
                hand.skeleton.jointMatrices.add().CopyFrom(matrix(np.eye(4)))
    return message


@pytest.fixture
def streamer():
    # Exercise real transport parsing without starting servers or connecting to hardware.
    s = VisionProStreamer.__new__(VisionProStreamer)
    s.axis_transform = YUP2ZUP.copy()
    s.origin = "avp"
    s._attach_to_mat = np.eye(4)
    s._controller_lock = threading.Lock()
    s._controller_origin = np.eye(4)
    s._controller_data = empty_controllers()
    s._latest_lock = threading.Lock()
    s._stylus_lock = threading.Lock()
    s._stylus_data = None
    s._markers_lock = threading.Lock()
    s._detected_markers = {}
    s._tracked_images = {}
    s._webrtc_hand_ready = False
    s.ht_backend = "grpc"
    s._cross_network_mode = False
    s._log = lambda *args, **kwargs: None
    s.record = False
    s.recording = []
    s.latest = None
    return s


def test_head_relative_uses_rotation_translation_and_not_legacy_head_correction():
    data = decode_controllers(packet(), axis_transform=YUP2ZUP)
    np.testing.assert_allclose(data["left"]["pose_head"], pose(-0.2, -0.1, -0.5), atol=1e-6)
    np.testing.assert_allclose(data["right"]["pose_head"], pose(0.3, -0.1, -0.5), atol=1e-6)
    np.testing.assert_allclose(data["left"]["pose"], YUP2ZUP[0] @ data["left"]["pose_avp"])


def test_pose_diagnostic_survives_transport_without_enabling_invalid_pose():
    p = packet()
    p.left.pose_valid = False
    p.left.pose_status = "SDK returned its untracked placeholder (100, 100, −100 m)"
    decoded = decode_controllers(pb.ControllerTracking.FromString(p.SerializeToString()))
    assert decoded["left"]["pose_status"] == p.left.pose_status
    assert not decoded["left"]["pose_valid"]
    assert decoded["left"]["pose_head"] is None
    assert decoded["left"]["buttons"]["x"] is True
    p.left.active = False
    assert decode_controllers(p)["left"]["pose_status"] == p.left.pose_status


def test_sim_origin_changes_world_pose_but_not_head_pose():
    p = packet()
    normal = decode_controllers(p)
    sim = decode_controllers(p, stream_from_avp=np.linalg.inv(pose(4, 5, 6)), axis_transform=YUP2ZUP)
    np.testing.assert_allclose(normal["left"]["pose_head"], sim["left"]["pose_head"])
    np.testing.assert_allclose(sim["left"]["pose"], np.linalg.inv(pose(4, 5, 6)) @ YUP2ZUP[0] @ normal["left"]["pose_avp"])


def test_explicit_alignment_is_applied_before_head_inverse():
    correction = pose(0.5, -0.3, 0.4, 0.3)
    data = decode_controllers(packet(), world_from_surreal=correction)
    expected = np.linalg.inv(pose(1, 2, 3, np.pi / 2)) @ correction @ data["left"]["pose_local"]
    np.testing.assert_allclose(data["left"]["pose_head"], expected, atol=1e-6)


@pytest.mark.parametrize("side,name", [(side, name) for side, names in INPUT_NAMES.items() for name in names])
def test_every_input_is_independent(side, name):
    p = packet()
    for side_name in INPUT_NAMES:
        for item in getattr(p, side_name).inputs:
            item.value = 0
            item.pressed = False
    for item in getattr(p, side).inputs:
        if item.name == name:
            item.value = 0.875
            item.pressed = True
    result = decode_controllers(p)
    for side_name in INPUT_NAMES:
        for input_name, item in result[side_name]["inputs"].items():
            if (side_name, input_name) == (side, name):
                assert item["value"]
            else:
                assert not item["value"]
    assert "a" not in result["left"]["buttons"]
    assert "x" not in result["right"]["buttons"]


def test_tracking_loss_does_not_disable_buttons():
    p = packet()
    p.left.pose_valid = False
    data = decode_controllers(p)
    assert data["left"]["pose_head"] is None
    assert data["left"]["buttons"]["x"] is True
    assert data["right"]["pose_head"] is not None


def test_head_loss_keeps_controller_pose_and_inputs():
    p = packet()
    p.head_pose_valid = False
    data = decode_controllers(p)
    assert data["left"]["pose_head"] is None
    assert data["left"]["pose"] is not None
    assert data["left"]["buttons"]["x"] is True


def test_inactive_controller_and_input_clear_held_buttons():
    p = packet()
    p.left.active = False
    p.right.inputs[0].active = False
    data = decode_controllers(p)
    assert data["left"]["pose"] is None
    assert data["left"]["buttons"]["x"] is None
    assert data["right"]["buttons"]["a"] is None
    assert data["right"]["buttons"]["b"] is True


def test_stale_live_frame_clears_both_poses_and_inputs_without_mutating_sample():
    data = decode_controllers(packet(), received_at=10)
    current = controller_snapshot(data, now=10.1)
    expired = controller_snapshot(data, now=10.3)
    assert not current["stale"] and current["left"]["buttons"]["x"]
    assert expired["stale"] and expired["left"]["pose_head"] is None
    assert expired["left"]["buttons"]["x"] is None
    assert data["left"]["buttons"]["x"] is True


def test_invalid_pose_and_nan_input_cannot_become_valid_data():
    p = packet()
    p.left.pose.m00 = float("nan")
    p.right.pose.m00 = 9  # finite but not a rotation
    p.left.inputs[0].value = float("nan")
    data = decode_controllers(p)
    assert not data["left"]["pose_valid"] and not data["right"]["pose_valid"]
    assert data["left"]["buttons"]["x"] is None
    assert data["left"]["buttons"]["y"] is True


@pytest.mark.parametrize("mutate", [lambda p: setattr(p, "enabled", False), lambda p: setattr(p, "version", 9)])
def test_disabled_or_unknown_packet_cannot_publish_inputs(mutate):
    p = packet()
    mutate(p)
    data = decode_controllers(p)
    assert not data["left"]["active"]
    assert data["left"]["pose_head"] is None


def test_controller_only_packets_work_without_hand_joints(streamer):
    streamer._process_hand_update(update(with_hands=False))
    data = streamer.get_latest()
    assert data.controllers["left"]["buttons"]["x"] is True
    assert streamer.get_controllers()["right"]["pose_head"] is not None


def test_grpc_and_webrtc_preserve_hands_and_controllers(streamer):
    message = update()
    streamer._process_hand_update(message, source="grpc")
    grpc = streamer.get_latest()
    streamer._handle_webrtc_hand_message(message.SerializeToString())
    webrtc = streamer.get_latest()
    np.testing.assert_array_equal(grpc["left_wrist"], webrtc["left_wrist"])
    np.testing.assert_array_equal(grpc["left_arm"], webrtc["left_arm"])
    np.testing.assert_array_equal(grpc.controllers["right"]["pose_head"], webrtc.controllers["right"]["pose_head"])
    assert webrtc["left_arm"].shape == (27, 4, 4)
    assert webrtc.controllers["right"]["buttons"]["a"]


def test_older_sender_clears_controller_state(streamer):
    message = update()
    streamer._process_hand_update(message)
    message.ClearField("controllers")
    streamer._process_hand_update(message)
    assert not streamer.get_controllers()["supported"]
    assert streamer.get_latest().controllers["left"]["buttons"]["x"] is None


def test_retransmitted_frame_does_not_refresh_input_freshness(streamer):
    message = update()
    streamer._process_hand_update(message)
    streamer._controller_data["received_at_monotonic"] = time.monotonic() - 2
    streamer._process_hand_update(message)
    assert streamer.get_controllers()["stale"]
    assert streamer.get_latest()["controllers"]["stale"]
    assert streamer.get_latest().get("controllers")["left"]["buttons"]["x"] is None


def test_returned_snapshot_does_not_mutate_internal_state(streamer):
    streamer._process_hand_update(update())
    external = streamer.get_controllers()
    external["left"]["pose_head"][0, 3] = 100
    external["left"]["buttons"]["x"] = False
    assert streamer.get_controllers()["left"]["buttons"]["x"]
    assert streamer.get_controllers()["left"]["pose_head"][0, 3] != 100


def test_protocol_is_backward_compatible():
    descriptor = descriptor_pb2.FileDescriptorProto.FromString(pb.DESCRIPTOR.serialized_pb)
    for message in descriptor.message_type:
        if message.name == "HandUpdate":
            del message.field[3:]
    del descriptor.message_type[4:8]  # ControllerInput, ControllerState, ControllerCalibration, ControllerTracking
    pool = descriptor_pool.DescriptorPool()
    pool.Add(descriptor)
    old_type = message_factory.GetMessageClass(pool.FindMessageTypeByName("handtracking.HandUpdate"))
    new = update()
    old = old_type.FromString(new.SerializeToString())
    assert len(old.left_hand.skeleton.jointMatrices) == 27
    # Unknown controller fields survive an old protobuf relay.
    roundtrip = pb.HandUpdate.FromString(old.SerializeToString())
    assert roundtrip.controllers.right.inputs[0].name == "a"


def test_native_recordings_roundtrip_controllers_and_do_not_expire(tmp_path):
    p = packet()
    path = tmp_path / "tracking.jsonl"
    path.write_text(json.dumps({"timestamp": 1.2, "controllerTracking": base64.b64encode(p.SerializeToString()).decode()}) + "\n")
    frame = load_jsonl(path)[0]
    assert frame.controllers["left"]["buttons"]["x"] is True
    assert frame.controllers["received_at_monotonic"] is None
    np.testing.assert_allclose(frame.controllers["left"]["pose_head"], pose(-0.2, -0.1, -0.5), atol=1e-6)


def test_old_recordings_remain_loadable(tmp_path):
    path = tmp_path / "tracking.jsonl"
    path.write_text('{"timestamp": 0}\n')
    assert not load_jsonl(path)[0].controllers["supported"]


def test_origin_validation_rejects_scale_and_reflection():
    for bad in (np.diag([2, 1, 1, 1]), np.diag([-1, 1, 1, 1]), np.zeros((4, 4))):
        with pytest.raises(ValueError):
            rigid_transform(bad)


def calibrated_packet():
    p = packet()
    alignment = pose(.1, -.05, .2, .3)
    p.calibration.world_from_local.CopyFrom(matrix(alignment))
    p.calibration.saved = True
    p.calibration.reviewed_this_session = True
    for side, x in [('left', -.025), ('right', .025)]:
        grip = pose(x, .04, .13, -.2)
        getattr(p.calibration, side + '_grip_offset').CopyFrom(matrix(grip))
        raw = np.array([[getattr(getattr(p, side).pose, f'm{r}{c}') for c in range(4)] for r in range(4)])
        getattr(p, side).pose_world.CopyFrom(matrix(alignment @ raw @ grip))
    return p


def test_native_calibration_world_and_head_use_same_pose_without_double_correction():
    p = calibrated_packet()
    result = decode_controllers(p)
    for side in ('left', 'right'):
        c = result['calibration']
        expected = c['world_from_local'] @ result[side]['pose_local'] @ c[side + '_grip_offset']
        np.testing.assert_allclose(result[side]['pose_avp'], expected, atol=1e-6)
        np.testing.assert_allclose(result['head_pose_avp'] @ result[side]['pose_head'], expected, atol=1e-6)
    assert result['calibration']['reviewed_this_session']
    assert result['left']['buttons']['x'] is True
    extra = pose(.03, 0, 0, .1)
    corrected = decode_controllers(p, world_from_surreal=extra)
    np.testing.assert_allclose(corrected['left']['pose_avp'], extra @ result['left']['pose_avp'])


@pytest.mark.parametrize('malformed', [False, True])
def test_native_calibration_missing_or_bad_pose_never_falls_back_to_raw(malformed):
    p = calibrated_packet()
    p.left.ClearField('pose_world')
    if malformed:
        p.left.pose_world.m00 = float('nan')
    decoded = decode_controllers(p)
    assert not decoded['left']['pose_valid']
    assert decoded['left']['buttons']['x'] is True
    assert decoded['right']['pose_valid']


def test_vendor_sentinel_pose_is_rejected_without_losing_buttons():
    p = packet()
    p.left.pose.CopyFrom(matrix(pose(100, 100.03, -100.06)))
    decoded = decode_controllers(p)
    assert not decoded['left']['pose_valid']
    assert decoded['left']['buttons']['x'] is True
    assert decoded['right']['pose_valid']


def test_calibration_survives_recording_serialization_and_preview_is_explicit():
    p = calibrated_packet()
    p.calibration.preview = True
    recorded = pb.ControllerTracking.FromString(p.SerializeToString())
    result = decode_controllers(recorded, live=False)
    assert result['calibration']['preview']
    assert result['received_at_monotonic'] is None
    np.testing.assert_allclose(result['left']['pose_avp'], decode_controllers(p)['left']['pose_avp'])
