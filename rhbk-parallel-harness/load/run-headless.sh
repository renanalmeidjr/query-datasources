#!/usr/bin/env bash
set -euo pipefail

: "${TARGET_HOST:?Set TARGET_HOST, ex: http://rhbk-parallel-harness.default.svc.cluster.local:8080}"
: "${USERS:=3000}"
: "${SPAWN_RATE:=10}"
: "${DURATION:=5m}"
: "${CSV_PREFIX:=locust-results}"

locust \
  -f locustfile.py \
  --headless \
  --host "${TARGET_HOST}" \
  --users "${USERS}" \
  --spawn-rate "${SPAWN_RATE}" \
  --run-time "${DURATION}" \
  --csv "${CSV_PREFIX}" \
  --only-summary
