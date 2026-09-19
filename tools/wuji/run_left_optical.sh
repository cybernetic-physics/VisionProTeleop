#!/usr/bin/env bash
set -euo pipefail
# Run on the Mac. Ctrl+C is forwarded to the remote process for cleanup.
exec ssh -t g1gen5@100.87.202.8 'cd /home/g1gen5/wuji-sdk && /home/g1gen5/wuji-venv/bin/python -u examples/python/retargeting/visionpro_hands.py --side left --enable-motors'
