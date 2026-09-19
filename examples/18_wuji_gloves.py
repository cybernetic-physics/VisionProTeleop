"""Inspect Wuji/controller fusion. Prints data only; never issues robot commands."""
import argparse
import time
from avp_stream import VisionProStreamer

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ip', required=True)
args = parser.parse_args()
stream = VisionProStreamer(ip=args.ip)
try:
    while True:
        for side, state in stream.get_gloves().items():
            if side == 'supported':
                continue
            if state['valid']:
                print(side, 'wrist/head (m):', state['wrist_head'][:3, 3].round(3),
                      'confidence:', round(float(state['confidence'].min()), 2),
                      'clock error estimate (ms):', round(state['uncertainty_ms'], 2))
            else:
                print(side, state['status'])
        time.sleep(.5)
except KeyboardInterrupt:
    pass
