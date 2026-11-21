#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p macos/build
swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path macos/build/module-cache \
    macos/Sources/{Models,Deployment}.swift macos/Tests/*.swift -o macos/build/setup-checks
macos/build/setup-checks "$@"
