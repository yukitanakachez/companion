#!/usr/bin/env bash
set -euo pipefail

# Env files are gitignored, so copy them
# from the root checkout. Never overwrite.
for f in .env .env.local; do
  if [ -f "$SUPERSET_ROOT_PATH/$f" ] && [ ! -e "$f" ]; then
    cp "$SUPERSET_ROOT_PATH/$f" "$f"
  fi
done

# Install dependencies per the lockfile.
if [ -f bun.lock ] || [ -f bun.lockb ]; then
  bun install
elif [ -f pnpm-lock.yaml ]; then
  pnpm install --frozen-lockfile
elif [ -f yarn.lock ]; then
  yarn install
elif [ -f package-lock.json ]; then
  npm ci
elif [ -f uv.lock ]; then
  uv sync
fi
