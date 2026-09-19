"""Wuji skeletons placed by independently tracked, manually calibrated controllers."""
import numpy as np


def empty_glove():
    return dict(valid=False, status='Unavailable', serial=None, sequence=0,
                source_timestamp_us=0, timestamp_ns=0, uncertainty_ms=None,
                points_wrist=None, confidence=None, wrist_avp=None, wrist_head=None,
                joints_avp=None, joints_head=None, joints=None)


def empty_gloves():
    return dict(supported=False, left=empty_glove(), right=empty_glove())


def decode_gloves(packet, *, controller_timestamp_ns, correction, axis, stream):
    from .controllers import _matrix
    result = empty_gloves()
    if packet is None or packet.version != 1:
        return result
    result['supported'] = True
    for side in ('left', 'right'):
        m, state = getattr(packet, side), result[side]
        state.update(status=m.status, serial=m.serial, sequence=m.sequence,
                     source_timestamp_us=m.source_timestamp_us, timestamp_ns=m.timestamp_ns,
                     uncertainty_ms=m.uncertainty_ms)
        age = (controller_timestamp_ns - m.timestamp_ns) / 1e9
        if not m.valid or not -.02 <= age <= .25 or len(m.points_wrist) != 63 or len(m.confidence) != 21:
            continue
        if not np.isfinite(m.uncertainty_ms) or not 0 <= m.uncertainty_ms <= 30:
            continue
        points = np.array(m.points_wrist, dtype=float).reshape(21, 3)
        confidence = np.array(m.confidence, dtype=float)
        wrist, head = _matrix(m.wrist_world), _matrix(m.head_world)
        if (wrist is None or head is None or not np.isfinite(points).all()
                or np.max(np.abs(points)) > 1 or np.max(np.abs(points[0])) >= .005
                or not np.isfinite(confidence).all() or np.any(confidence < .5) or np.any(confidence > 1)):
            continue
        # Receiver controller-origin correction applies consistently to mounted wrists.
        wrist = correction @ wrist
        local = np.column_stack((points, np.ones(21)))
        world = (wrist @ local.T).T
        wrist_head = np.linalg.solve(head, wrist)
        state.update(valid=True, points_wrist=points, confidence=confidence,
                     wrist_avp=wrist, wrist_head=wrist_head,
                     joints_avp=world[:, :3], joints_head=(wrist_head @ local.T).T[:, :3],
                     joints=(stream @ axis @ world.T).T[:, :3])
    return result
