#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate
xcodebuild -project Companion.xcodeproj -scheme Companion -configuration Debug -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/Companion.app
