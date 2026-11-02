#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
swift test

if [ -d contracts/ts ]; then
  npx -y -p typescript@5 tsc -p contracts/ts --noEmit
else
  echo "Skipping contracts/ts type-check: contracts/ts is absent"
fi

if [ -f extension/package.json ]; then
  (cd extension && npm ci && npm test && npm run build)
fi

if [ -f ui-web/package.json ]; then
  (cd ui-web && npm ci && npm test)
fi
