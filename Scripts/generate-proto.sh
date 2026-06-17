#!/usr/bin/env bash
# Scripts/generate-proto.sh
# Regenerates Sources/IMProto/Generated/WFCMessage.pb.swift from Proto/WFCMessage.proto.
# Run this after chat-proto/WFCMessage.proto changes; commit the regenerated output.
#
# Uses a repo-local modern protoc (.tools/protoc-35.1) and a protoc-gen-swift
# plugin built from the swift-protobuf SPM checkout — NEVER the system protoc,
# which is intentionally pinned to 2.5.0 for the sibling chat-proto Java build
# and is binary-incompatible with this plugin (confirmed: SIGILL on a modern
# CodeGeneratorRequest payload).
set -euo pipefail
cd "$(dirname "$0")/.."

PROTOC_BIN="${PROTOC_BIN:-.tools/protoc-35.1/bin/protoc}"
if [ ! -x "$PROTOC_BIN" ]; then
  echo "error: $PROTOC_BIN not found. Run the Step 2 download commands first." >&2
  exit 1
fi

PROTOC_GEN_SWIFT="${PROTOC_GEN_SWIFT:-}"
if [ -z "$PROTOC_GEN_SWIFT" ]; then
  PROTOC_GEN_SWIFT="$(find .build/checkouts/swift-protobuf/.build -name protoc-gen-swift -type f 2>/dev/null | head -1)"
fi
if [ -z "$PROTOC_GEN_SWIFT" ] || [ ! -x "$PROTOC_GEN_SWIFT" ]; then
  echo "Building protoc-gen-swift from the swift-protobuf SPM checkout..."
  (cd .build/checkouts/swift-protobuf && swift build -c release --product protoc-gen-swift)
  PROTOC_GEN_SWIFT="$(find .build/checkouts/swift-protobuf/.build -name protoc-gen-swift -type f | head -1)"
fi
echo "Using protoc: $PROTOC_BIN"
echo "Using protoc-gen-swift plugin: $PROTOC_GEN_SWIFT"

mkdir -p Sources/IMProto/Generated
"$PROTOC_BIN" \
  --proto_path=Proto \
  --plugin=protoc-gen-swift="$PROTOC_GEN_SWIFT" \
  --swift_out=Sources/IMProto/Generated \
  --swift_opt=Visibility=Public \
  Proto/WFCMessage.proto
echo "Generated Sources/IMProto/Generated/WFCMessage.pb.swift"
