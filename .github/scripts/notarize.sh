#!/bin/bash
# Sends a file to Apple's notary service and waits for the answer.
# Used by the release workflow for the app (zipped) and then for the DMG.
# If Apple rejects it, prints Apple's log, which says exactly what's wrong.
#
# Expects NOTARY_KEY_ID, NOTARY_ISSUER_ID and the key at $RUNNER_TEMP/AuthKey.p8.
set -euo pipefail

FILE="$1"
RESULT=$(xcrun notarytool submit "$FILE" \
  --key "$RUNNER_TEMP/AuthKey.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
  --wait --timeout 30m --output-format json)
echo "$RESULT"

STATUS=$(echo "$RESULT" | jq -r '.status')
if [ "$STATUS" != "Accepted" ]; then
  ID=$(echo "$RESULT" | jq -r '.id')
  echo "::error::Notarization of $(basename "$FILE") ended with status: $STATUS"
  xcrun notarytool log "$ID" \
    --key "$RUNNER_TEMP/AuthKey.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
  exit 1
fi
