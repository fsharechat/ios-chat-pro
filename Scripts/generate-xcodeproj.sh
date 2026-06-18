#!/usr/bin/env bash
# Scripts/generate-xcodeproj.sh
# Regenerates ios-chat-pro.xcodeproj from project.yml using xcodegen.
# Run this after project.yml changes; commit the regenerated .xcodeproj.
#
# Uses a repo-local xcodegen binary fetched directly from its GitHub release
# — Homebrew is unavailable in this environment (see Plan A's findings for
# protoc), so this mirrors Scripts/generate-proto.sh's approach.
set -euo pipefail
cd "$(dirname "$0")/.."

XCODEGEN_VERSION="2.45.4"
XCODEGEN_BIN=".tools/xcodegen-${XCODEGEN_VERSION}/xcodegen/bin/xcodegen"

if [ ! -x "$XCODEGEN_BIN" ]; then
  echo "Downloading xcodegen ${XCODEGEN_VERSION}..."
  mkdir -p ".tools/xcodegen-${XCODEGEN_VERSION}"
  curl -sL -o /tmp/xcodegen.zip "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
  unzip -q -o /tmp/xcodegen.zip -d ".tools/xcodegen-${XCODEGEN_VERSION}"
  rm /tmp/xcodegen.zip
fi

echo "Using xcodegen: $XCODEGEN_BIN ($("$XCODEGEN_BIN" --version))"
"$XCODEGEN_BIN" generate --spec project.yml
echo "Generated ios-chat-pro.xcodeproj"
