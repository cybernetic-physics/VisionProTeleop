"""Independent Surreal Touch controller packets and coordinate transforms.

`pose_head` always uses raw headset axes: +X right, +Y up, -Z forward,
meters. It deliberately does not use the legacy Python head-axis correction.
"""
from copy import deepcopy
import time
import numpy as np

INPUT_NAMES = {
    "left": ("x", "y", "menu", "thumbstick", "trigger", "grip", "thumbstick_x", "thumbstick_y"),
    "right": ("a", "b", "menu", "thumbstick", "trigger", "grip", "thumbstick_x", "thumbstick_y"),
}


def rigid_transform(value):
    """Validate and copy a right-handed 4x4 rigid transform (meters)."""
    matrix = np.asarray(value, dtype=np.float64)
    if matrix.shape != (4, 4) or not np.isfinite(matrix).all():
        raise ValueError("Expected a finite 4x4 rigid transform")
    rotation = matrix[:3, :3]
    if (not np.allclose(matrix[3], [0, 0, 0, 1], atol=1e-5)
            or not np.allclose(rotation.T @ rotation, np.eye(3), atol=2e-3)
            or not np.isclose(np.linalg.det(rotation), 1.0, atol=2e-3)):
        raise ValueError("Expected a rigid transform with a proper rotation and homogeneous last row")
    return matrix.copy()


def _matrix(message):
    try:
        return rigid_transform([[getattr(message, f"m{r}{c}") for c in range(4)] for r in range(4)])
    except (ValueError, AttributeError):
        return None


def empty_side(side):
    names = INPUT_NAMES[side]
    return {
        "active": False, "pose_valid": False,
        "pose": None, "pose_local": None, "pose_avp": None, "pose_head": None,
        "buttons": {name: None for name in names if not name.startswith("thumbstick_")},
        "axes": {name: None for name in names if name in ("trigger", "grip", "thumbstick_x", "thumbstick_y")},
        "inputs": {name: {"active": False, "value": None, "pressed": None,
                          "last_change_time_ns": 0} for name in names},
    }


def empty_controllers():
    return {"supported": False, "enabled": False, "source": None, "version": 0,
            "timestamp_ns": 0, "sequence": 0, "head_pose_avp": None,
            "stale": False, "received_at_monotonic": None,
            "left": empty_side("left"), "right": empty_side("right")}


def decode_controllers(packet, *, axis_transform=None, stream_from_avp=None,
                       world_from_surreal=None, received_at=None, live=True):
    """Decode a dedicated ControllerTracking protobuf, without consulting hands.

    world_from_surreal maps the vendor LOCAL space to the app's ARKit world.
    Identity follows the vendor native sample; an explicitly measured calibration
    can be supplied when origins differ. stream_from_avp maps raw world poses into
    the caller's configured (AVP or simulation) stream frame.
    """
    result = empty_controllers()
    if packet is None or packet.version != 1:
        return result
    result.update(supported=True, enabled=bool(packet.enabled), version=packet.version,
                  source=packet.source, timestamp_ns=packet.timestamp_ns, sequence=packet.sequence,
                  received_at_monotonic=(time.monotonic() if received_at is None else received_at) if live else None)
    if not packet.enabled:
        return result
    correction = rigid_transform(np.eye(4) if world_from_surreal is None else world_from_surreal)
    axis = np.eye(4) if axis_transform is None else np.asarray(axis_transform).reshape(4, 4)
    stream = np.eye(4) if stream_from_avp is None else np.asarray(stream_from_avp).reshape(4, 4)
    head = _matrix(packet.head_pose) if packet.head_pose_valid and packet.HasField("head_pose") else None
    result["head_pose_avp"] = head
    for side in ("left", "right"):
        message = getattr(packet, side)
        state = result[side]
        state["active"] = bool(message.active)
        if not message.active:
            continue
        if message.pose_valid and message.HasField("pose"):
            pose = _matrix(message.pose)
            if pose is not None:
                world_pose = correction @ pose
                state.update(pose_valid=True, pose_local=pose, pose_avp=world_pose,
                             pose=stream @ axis @ world_pose,
                             pose_head=None if head is None else np.linalg.solve(head, world_pose))
        for item in message.inputs:
            # Known input names are per-side: e.g. left X can never become right A.
            if item.name not in state["inputs"] or not item.active or not np.isfinite(item.value):
                continue
            is_axis = item.name in state["axes"]
            if bool(item.is_boolean) == is_axis:
                continue  # A malformed input type must not masquerade as a button.
            value = float(item.value) if is_axis else bool(item.pressed)
            if is_axis:
                lower = -1.0 if item.name.startswith("thumbstick_") else 0.0
                value = float(np.clip(value, lower, 1.0))
            pressed = None if item.name.startswith("thumbstick_") else (value >= 0.5 if is_axis else bool(value))
            state["inputs"][item.name] = {
                "active": True, "value": value, "pressed": pressed,
                "last_change_time_ns": item.last_change_time_ns,
            }
            if item.name in state["buttons"]:
                state["buttons"][item.name] = pressed
            if is_axis:
                state["axes"][item.name] = value
    return result


def controller_snapshot(data, max_age_ms=250, *, now=None):
    """Return an owned copy; expire poses AND held inputs after a stream stall.

    Recorded frames (received_at_monotonic=None) are not aged against a live clock.
    """
    if not np.isfinite(max_age_ms) or max_age_ms <= 0:
        raise ValueError("max_age_ms must be a positive finite number")
    result = deepcopy(data) if data is not None else empty_controllers()
    received = result["received_at_monotonic"]
    age = (time.monotonic() if now is None else now) - received if received is not None else 0
    if age > max_age_ms / 1000.0:
        result["stale"] = True
        result["head_pose_avp"] = None
        result["left"] = empty_side("left")
        result["right"] = empty_side("right")
    return result
