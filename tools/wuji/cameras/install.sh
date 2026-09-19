#!/usr/bin/env bash
# Run on PC2. Installs only the three color camera services.
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
install_dir="$HOME/.local/share/wuji-cameras"
mkdir -p "$install_dir" "$HOME/.config/systemd/user"
if [[ -d "$source_dir/wheels" ]]; then
    python3 -m pip install --no-index --find-links "$source_dir/wheels" --target "$install_dir/vendor" 'msgpack==1.0.8'
else
    python3 -m pip install --target "$install_dir/vendor" 'msgpack==1.0.8'
fi
PYTHONPATH="$install_dir/vendor" python3 -c 'import cv2, numpy, msgpack, pyrealsense2, zmq'
install -m 644 "$source_dir/publish.py" "$install_dir/publish.py"
# Preserve a physically verified wrist assignment on subsequent installations.
if [[ ! -f "$install_dir/cameras.json" ]]; then
    install -m 644 "$source_dir/cameras.json" "$install_dir/cameras.json"
fi
install -m 644 "$source_dir/wuji-camera@.service" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable wuji-camera@head wuji-camera@left wuji-camera@right
systemctl --user restart wuji-camera@head wuji-camera@left wuji-camera@right
systemctl --user --no-pager status wuji-camera@head wuji-camera@left wuji-camera@right
