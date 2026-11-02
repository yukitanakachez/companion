#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <id>   (for example: $0 ws1-llm)" >&2
  exit 2
fi

git worktree add "../companion-$1" -b "ws/$1" main
echo "../companion-$1"
echo "Give your agent: Implement docs/superpowers/plans/2026-11-01-companion-$1.md"
