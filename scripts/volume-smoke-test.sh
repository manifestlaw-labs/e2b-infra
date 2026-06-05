#!/usr/bin/env bash
#
# volume-smoke-test.sh — end-to-end check for persistent volumes.
#
# Proves that a Filestore-backed persistent volume is shared across sandboxes:
# creates a volume, mounts it in sandbox A and writes a file, kills A, then
# mounts the same volume in sandbox B and reads the file back.
#
# Prerequisites:
#   - Persistent volumes enabled in the target env, e.g. in .env.<env>:
#       PERSISTENT_VOLUME_TYPES='{"shared": {"tier": "BASIC_HDD", "location": "<zone>", "capacity_gb": 1024, "allow_deletion": true}}'
#       DEFAULT_PERSISTENT_VOLUME_TYPE=shared
#     (regional sub-1TiB "small" instances are not available in every region;
#      BASIC_HDD 1 TiB is the cheapest floor where they aren't.)
#   - A team API key and the deployment domain.
#
# Usage:
#   E2B_API_KEY=... E2B_DOMAIN=manifestos-sandbox.com ./scripts/volume-smoke-test.sh
#
#   # or pull the key from GCP Secret Manager:
#   E2B_DOMAIN=manifestos-sandbox.com E2B_API_KEY="$(gcloud secrets versions access latest \
#       --secret=E2B_API_KEY --project=<project>)" ./scripts/volume-smoke-test.sh
#
# Optional env: TEMPLATE_ID (default "base"), ENVD_PORT (default 49983).
set -euo pipefail

: "${E2B_API_KEY:?set E2B_API_KEY (team API key)}"
: "${E2B_DOMAIN:?set E2B_DOMAIN, e.g. manifestos-sandbox.com}"
TEMPLATE_ID="${TEMPLATE_ID:-base}"
ENVD_PORT="${ENVD_PORT:-49983}"
API="https://api.${E2B_DOMAIN}"
MOUNT_PATH="/home/user/shared"
FILE_PATH="${MOUNT_PATH}/memory.md"
PENC="$(python3 -c "import urllib.parse;print(urllib.parse.quote('${FILE_PATH}', safe=''))")"
VOL="smoke-$(python3 -c 'import uuid;print(uuid.uuid4().hex[:8])')"
MARKER="WRITTEN_BY_SANDBOX_A_$(python3 -c 'import time;print(int(time.time()))')"

api()  { curl -fsS -H "X-API-KEY: ${E2B_API_KEY}" "$@"; }
jget() { python3 -c "import sys,json;print(json.load(sys.stdin).get('$1',''))"; }
mk_sbx() {
  api "${API}/sandboxes" -H "Content-Type: application/json" --max-time 60 -d \
    "{\"templateID\":\"${TEMPLATE_ID}\",\"timeout\":300,\"volumeMounts\":[{\"name\":\"${VOL}\",\"path\":\"${MOUNT_PATH}\"}]}"
}
envd_base() { echo "https://${ENVD_PORT}-$1-$2.${E2B_DOMAIN}"; }
cleanup() {
  [ -n "${SB:-}" ] && curl -fsS -X DELETE -H "X-API-KEY: ${E2B_API_KEY}" "${API}/sandboxes/${SB}" >/dev/null 2>&1 || true
  local vid
  vid="$(api "${API}/volumes" --max-time 20 | python3 -c "import sys,json;[print(v['volumeID']) for v in json.load(sys.stdin) if v.get('name')=='${VOL}']" 2>/dev/null || true)"
  [ -n "${vid}" ] && curl -fsS -X DELETE -H "X-API-KEY: ${E2B_API_KEY}" "${API}/volumes/${vid}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "1. create volume ${VOL}"
api "${API}/volumes" -H "Content-Type: application/json" -d "{\"name\":\"${VOL}\"}" --max-time 30 >/dev/null

echo "2. sandbox A: mount + write '${MARKER}'"
A="$(mk_sbx)"; SA="$(echo "$A" | jget sandboxID)"; CA="$(echo "$A" | jget clientID)"; SB="$SA"
TMP="$(mktemp)"; printf '%s\n' "${MARKER}" > "${TMP}"
curl -fsS --retry 6 --retry-delay 2 --retry-all-errors --max-time 40 \
  -F "file=@${TMP}" "$(envd_base "$SA" "$CA")/files?path=${PENC}&username=user" >/dev/null
rm -f "${TMP}"

echo "3. kill sandbox A (${SA})"
curl -fsS -X DELETE -H "X-API-KEY: ${E2B_API_KEY}" "${API}/sandboxes/${SA}" --max-time 30 >/dev/null; SB=""

echo "4. sandbox B: mount same volume + read"
B="$(mk_sbx)"; SBX="$(echo "$B" | jget sandboxID)"; CB="$(echo "$B" | jget clientID)"; SB="$SBX"
GOT="$(curl -fsS --retry 6 --retry-delay 2 --retry-all-errors --max-time 40 \
  "$(envd_base "$SBX" "$CB")/files?path=${PENC}&username=user")"

echo "5. verify"
if [ "${GOT}" = "${MARKER}" ]; then
  echo "PASS: sandbox B read the file written by sandbox A (${GOT})"
else
  echo "FAIL: expected '${MARKER}', got '${GOT}'"; exit 1
fi
