#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "error: DEVELOPER_DIR not found at $DEVELOPER_DIR" >&2
  echo "Install full Xcode and/or set DEVELOPER_DIR." >&2
  exit 1
fi

# Fail fast if XCTest isn't available (Command Line Tools alone aren't enough).
if ! xcrun --find xctest >/dev/null 2>&1; then
  echo "error: XCTest not available under DEVELOPER_DIR=$DEVELOPER_DIR" >&2
  echo "Full Xcode is required for 'swift test'." >&2
  exit 1
fi

cd "$(dirname "$0")/.."
swift build
swift test
