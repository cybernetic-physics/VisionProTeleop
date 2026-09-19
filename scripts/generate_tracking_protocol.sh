#!/usr/bin/env bash
# Requires grpcio-tools==1.71.0 and protoc-gen-swift from swift-protobuf 1.33.3.
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
python_command="${PYTHON:-python3}"
swift_plugin="${PROTOC_GEN_SWIFT:-$(command -v protoc-gen-swift || true)}"
if [ -z "$swift_plugin" ]; then
    echo "Set PROTOC_GEN_SWIFT to the protoc-gen-swift executable." >&2
    exit 1
fi
"$python_command" -m grpc_tools.protoc -I avp_stream/grpc_msg \
    --python_out=avp_stream/grpc_msg \
    --plugin="protoc-gen-swift=$swift_plugin" \
    --swift_opt=Visibility=Public --swift_out='Tracking Streamer/Proto' \
    avp_stream/grpc_msg/handtracking.proto
cp 'Tracking Streamer/Proto/handtracking.pb.swift' avp_stream/grpc_msg/handtracking.pb.swift
